-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.8
-- Cancellazione dell'account, creazione atomica della partita,
-- limiti sugli avatar
-- =========================================================


-- =========================================================
-- PARTE 1 — CANCELLAZIONE DELL'ACCOUNT (GDPR)
--
-- PERCHE' NON E' UNA SEMPLICE "DELETE"
-- Cancellare la riga del profilo non funziona, e non per un dettaglio
-- tecnico: la storia delle partite e' fatta di fatti condivisi fra
-- quattro persone.
--   - match_results.registrato_da e confermato_da puntano a profiles
--     senza "on delete cascade": la cancellazione viene rifiutata;
--   - il trigger trg_blocca_formazione impedisce di togliere un
--     giocatore da una partita che ha un risultato, quindi nemmeno il
--     cascade su match_players potrebbe passare.
-- Forzare le due cose vorrebbe dire riscrivere il passato di altri tre
-- giocatori per ogni account cancellato.
--
-- COSA SI FA INVECE
-- Si cancellano i dati personali e si distrugge l'accesso:
--   - nome, cognome, telefono e foto vengono azzerati;
--   - l'account di autenticazione viene eliminato, quindi non si entra
--     piu' e l'indirizzo email non resta associato a nulla;
--   - le iscrizioni a partite ANCORA DA GIOCARE vengono rimosse, cosi'
--     il posto torna libero per qualcun altro;
--   - le partite gia' giocate restano, ma intestate a "Giocatore
--     eliminato": i risultati degli avversari non si toccano.
-- E' un'anonimizzazione, ed e' cio' che il GDPR chiede quando la
-- cancellazione pura entrerebbe in conflitto con i dati di altri.
-- =========================================================

-- ---------------------------------------------------------
-- 1.1  QUANDO E' STATO CANCELLATO
-- Serve a tenere fuori dalla classifica chi non c'e' piu': comparire
-- come "Giocatore eliminato" fra i primi dieci non ha senso.
-- ---------------------------------------------------------
alter table public.profiles
  add column if not exists eliminato_il timestamptz;

-- La colonna e' leggibile come le altre (l'elenco dei permessi per
-- colonna e' stato introdotto nell'aggiornamento n.6), ma NON
-- scrivibile dal browser: la imposta solo la funzione qui sotto.
grant select (eliminato_il) on public.profiles to authenticated;


-- ---------------------------------------------------------
-- 1.2  IL PROFILO SOPRAVVIVE ALL'ACCOUNT
-- profiles.id era legato ad auth.users con "on delete cascade":
-- eliminando l'account sparirebbe anche il profilo, e con esso il
-- riferimento nelle partite passate. Il vincolo viene rimosso: la
-- riga resta, vuota di dati personali, a fare da segnaposto nella
-- storia delle partite.
--
-- Non si perde integrita' verso l'esterno: la policy di INSERT
-- richiede comunque  auth.uid() = id , quindi dal browser si puo'
-- creare solo il profilo del proprio account, che esiste per
-- definizione.
-- ---------------------------------------------------------
alter table public.profiles
  drop constraint if exists profiles_id_fkey;


-- ---------------------------------------------------------
-- 1.3  LA FUNZIONE
-- ---------------------------------------------------------
create or replace function public.elimina_mio_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  io uuid := auth.uid();
begin
  if io is null then
    raise exception 'Devi essere autenticato';
  end if;

  -- 1. Fuori dalle partite non ancora giocate: il posto torna libero.
  --    Le partite gia' concluse restano, altrimenti si cancellerebbero
  --    i risultati degli avversari.
  delete from public.match_players mp
  using public.matches m
  where mp.match_id = m.id
    and mp.user_id = io
    and (m.match_date + m.match_time) at time zone 'Europe/Rome' > now();

  -- 2. Le partite future che aveva organizzato e che sono rimaste
  --    senza nessuno in campo non servono a nessuno.
  delete from public.matches m
  where m.created_by = io
    and (m.match_date + m.match_time) at time zone 'Europe/Rome' > now()
    and not exists (
      select 1 from public.match_players mp where mp.match_id = m.id
    );

  -- 3. I dati personali. La funzione e' "security definer", quindi
  --    scrive anche le colonne che il browser non puo' toccare.
  update public.profiles
  set nome = 'Giocatore',
      cognome = 'eliminato',
      full_name = 'Giocatore eliminato',
      telefono = null,
      avatar_url = null,
      circolo = null,
      role = 'giocatore',
      eliminato_il = now()
  where id = io;

  -- 4. L'accesso. Da qui in avanti non si entra piu' con quelle
  --    credenziali e l'email torna libera.
  delete from auth.users where id = io;
end;
$$;

grant execute on function public.elimina_mio_account() to authenticated;


-- ---------------------------------------------------------
-- 1.4  CHI NON C'E' PIU' NON STA IN CLASSIFICA
-- ---------------------------------------------------------
create or replace function public.classifica(p_min_partite int default 3)
returns table (
  user_id uuid,
  nome text,
  cognome text,
  avatar_url text,
  level text,
  partite int,
  vittorie int,
  percentuale_vittorie int
)
language sql
security definer
set search_path = public
as $$
  select
    s.user_id, p.nome, p.cognome, p.avatar_url, p.level,
    s.partite, s.vittorie, s.percentuale_vittorie
  from public.statistiche_giocatori s
  join public.profiles p on p.id = s.user_id
  where s.partite >= p_min_partite
    and p.eliminato_il is null
  order by s.percentuale_vittorie desc, s.vittorie desc
  limit 50;
$$;

grant execute on function public.classifica(int) to authenticated;


-- =========================================================
-- PARTE 2 — LA PARTITA NASCE IN UN COLPO SOLO
--
-- Finora l'app faceva due scritture in sequenza: prima la partita,
-- poi l'iscrizione dell'organizzatore al posto scelto. Se la seconda
-- non andava a buon fine, cancellava la prima per rimediare. Ma se
-- anche quella cancellazione falliva — connessione che cade a meta',
-- cosa normale da telefono — nel feed restava una partita fantasma a
-- zero giocatori che nessuno aveva organizzato.
--
-- Due scritture che devono valere insieme sono una transazione, e una
-- transazione si fa nel database. O nascono entrambe, o nessuna.
-- =========================================================

create or replace function public.crea_partita(
  p_club text,
  p_zona text,
  p_match_date date,
  p_match_time time,
  p_level text,
  p_spot smallint
)
returns public.matches
language plpgsql
security definer
set search_path = public
as $$
declare
  partita public.matches;
begin
  if auth.uid() is null then
    raise exception 'Devi accedere per creare una partita';
  end if;

  if p_spot is null or p_spot < 0 or p_spot > 3 then
    raise exception 'Il posto in campo deve essere compreso fra 0 e 3';
  end if;

  if p_club is null or length(trim(p_club)) = 0 then
    raise exception 'Il circolo e'' obbligatorio';
  end if;

  -- La data va controllata qui, non basta il trigger dell'aggiornamento
  -- n.7: questa funzione e' "security definer", gira quindi con i
  -- privilegi del proprietario, e il trigger esamina solo le scritture
  -- che arrivano dai ruoli pubblici del browser. Senza questa riga la
  -- funzione sarebbe una scorciatoia per rientrare dalla finestra.
  if p_match_date < (now() at time zone 'Europe/Rome')::date then
    raise exception 'Non si puo'' organizzare una partita in una data passata';
  end if;

  -- I vincoli di tabella pensano al resto: zona e livello ammessi,
  -- data non passata (trigger dell'aggiornamento n.7), origine
  -- ricavata dal ruolo (trigger dell'aggiornamento n.2).
  insert into public.matches (
    club, zona, match_date, match_time, level, total_slots, filled_slots, created_by
  )
  values (
    trim(p_club), p_zona, p_match_date, p_match_time, p_level, 4, 0, auth.uid()
  )
  returning * into partita;

  insert into public.match_players (match_id, user_id, spot)
  values (partita.id, auth.uid(), p_spot);

  -- filled_slots lo ha appena aggiornato il trigger: si rilegge, per
  -- non restituire all'app un conteggio vecchio di una riga.
  select * into partita from public.matches where id = partita.id;

  return partita;
end;
$$;

grant execute on function public.crea_partita(text, text, date, time, text, smallint) to authenticated;


-- =========================================================
-- PARTE 3 — LIMITI SUGLI AVATAR
--
-- Il bucket "avatars" e' pubblico e scrivibile da qualunque utente
-- registrato, senza limiti di dimensione ne' di tipo: si poteva
-- caricare un video da 200 MB rinominato .png. Con dieci amici non
-- succede niente; e' il genere di cosa che si scopre quando lo spazio
-- gratuito di Supabase e' finito.
-- =========================================================

-- ---------------------------------------------------------
-- 3.1  DUE MEGABYTE, SOLO IMMAGINI
-- Il limite lo applica Supabase Storage prima di scrivere il file,
-- quindi non e' aggirabile dal browser (il controllo aggiunto nella
-- pagina serve solo a dare un errore comprensibile subito).
-- ---------------------------------------------------------
update storage.buckets
set file_size_limit = 2097152,   -- 2 MB
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
where id = 'avatars';


-- ---------------------------------------------------------
-- 3.2  OGNUNO SCRIVE SOLO I PROPRI FILE
-- La policy precedente chiedeva soltanto di essere autenticati: il
-- nome del file era libero, quindi si potevano riempire di file il
-- bucket di tutti. L'app li nomina  <id utente>-<istante>.<est> ,
-- quindi basta pretendere il proprio identificativo come prefisso.
-- ---------------------------------------------------------
drop policy if exists "Un utente autenticato puo caricare il proprio avatar" on storage.objects;
drop policy if exists "Un utente puo sovrascrivere solo il proprio avatar" on storage.objects;

create policy "Un utente carica solo il proprio avatar"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and name like auth.uid()::text || '-%'
  );

create policy "Un utente sovrascrive solo il proprio avatar"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and name like auth.uid()::text || '-%'
  );

create policy "Un utente cancella solo il proprio avatar"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and name like auth.uid()::text || '-%'
  );


-- =========================================================
-- VERIFICA (opzionale)
-- =========================================================
-- select id, file_size_limit, allowed_mime_types from storage.buckets where id = 'avatars';
-- select nome, cognome, eliminato_il from public.profiles where eliminato_il is not null;
