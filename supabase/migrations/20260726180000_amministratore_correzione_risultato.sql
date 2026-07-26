-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.11
-- Amministratore, correzione del risultato, iscrizioni a
-- partite gia' giocate, eliminazione di partite concluse
-- =========================================================


-- =========================================================
-- PARTE 1 — L'AMMINISTRATORE
--
-- Serve qualcuno che possa intervenire sui contenuti: cancellare
-- una partita inventata, correggere un orario sbagliato, chiudere
-- una contestazione che i giocatori non risolvono da soli. Finora
-- non esisteva, e l'unico modo era l'Editor SQL di Supabase.
--
-- L'amministratore NON si autoproclama: il trigger introdotto
-- nell'aggiornamento n.9 impedisce di scrivere "role" dal browser,
-- e resta valido anche per questo ruolo. Si nomina a mano
-- dall'Editor SQL — vedi il fondo di questo file.
-- =========================================================

alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check check (role in ('giocatore', 'gestore', 'admin'));


-- ---------------------------------------------------------
-- 1.1  "SONO AMMINISTRATORE?"
-- E' "security definer" per due motivi: legge una colonna che le
-- policy proteggono, e soprattutto evita la ricorsione infinita
-- che nascerebbe interrogando profiles dentro una policy su
-- profiles.
-- ---------------------------------------------------------
create or replace function public.e_amministratore()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

grant execute on function public.e_amministratore() to authenticated;


-- ---------------------------------------------------------
-- 1.2  PUO' GESTIRE QUALUNQUE PARTITA
-- Le policy esistenti restano: il creatore continua a gestire le
-- proprie. Queste si aggiungono, non sostituiscono.
-- ---------------------------------------------------------
drop policy if exists "L amministratore puo modificare qualunque partita" on public.matches;
drop policy if exists "L amministratore puo eliminare qualunque partita" on public.matches;

create policy "L amministratore puo modificare qualunque partita"
  on public.matches for update
  to authenticated
  using ( public.e_amministratore() )
  with check ( public.e_amministratore() );

create policy "L amministratore puo eliminare qualunque partita"
  on public.matches for delete
  to authenticated
  using ( public.e_amministratore() );


-- ---------------------------------------------------------
-- 1.3  PUO' TOGLIERE UN GIOCATORE DA UNA PARTITA
-- Serve per rimuovere chi occupa un posto per dispetto. Il
-- congelamento della formazione a partita conclusa vale anche per
-- l'amministratore: un risultato registrato non si tocca togliendo
-- un giocatore, semmai si annulla il risultato (punto 1.4).
-- ---------------------------------------------------------
drop policy if exists "L amministratore puo togliere un giocatore" on public.match_players;

create policy "L amministratore puo togliere un giocatore"
  on public.match_players for delete
  to authenticated
  using ( public.e_amministratore() );


-- ---------------------------------------------------------
-- 1.4  PUO' ANNULLARE UN RISULTATO
-- E' la via d'uscita definitiva da una contestazione che i
-- giocatori non chiudono: annullato il risultato, la partita torna
-- come se non fosse mai stato inserito e si puo' ricominciare.
-- ---------------------------------------------------------
drop policy if exists "L amministratore puo annullare un risultato" on public.match_results;

create policy "L amministratore puo annullare un risultato"
  on public.match_results for delete
  to authenticated
  using ( public.e_amministratore() );


-- =========================================================
-- PARTE 2 — UNA PARTITA CONCLUSA SI PUO' ELIMINARE
--
-- Il trigger che congela la formazione bloccava anche la
-- cancellazione a cascata: eliminando una partita con un risultato
-- registrato, la rimozione automatica delle iscrizioni faceva
-- scattare il divieto. Risultato: NESSUNO poteva eliminare una
-- partita conclusa, nemmeno chi l'aveva creata.
--
-- Il divieto ha senso solo finche' la partita esiste: serve a
-- impedire che una sconfitta si cancelli uscendo dalla formazione.
-- Se la partita intera se ne sta andando, non c'e' niente da
-- proteggere. Quando PostgreSQL propaga la cancellazione ai figli,
-- la riga di matches e' gia' sparita: basta accorgersene.
-- =========================================================

create or replace function public.blocca_formazione_se_conclusa()
returns trigger
language plpgsql
as $$
declare
  id_partita uuid;
begin
  id_partita := coalesce(new.match_id, old.match_id);

  -- La partita non c'e' piu': siamo dentro la sua cancellazione.
  if not exists (select 1 from public.matches where id = id_partita) then
    return coalesce(new, old);
  end if;

  if exists (select 1 from public.match_results where match_id = id_partita) then
    raise exception 'La partita ha un risultato registrato: la formazione non si puo'' piu'' modificare';
  end if;

  return coalesce(new, old);
end;
$$;


-- =========================================================
-- PARTE 3 — NON CI SI ISCRIVE A UNA PARTITA GIA' GIOCATA
--
-- Si impediva di creare una partita nel passato, ma non di entrare
-- in una gia' finita: bastava chiamare l'API per infilarsi in una
-- partita di un mese fa e comparire nella formazione.
--
-- Il controllo guarda data e ora insieme, non solo il giorno: una
-- partita delle 20:00 e' "iniziata" alle 20:00, non a mezzanotte.
-- Come per gli altri trigger, si esaminano solo le scritture che
-- arrivano dai ruoli pubblici del browser, cosi' le funzioni
-- controllate (crea_partita) e l'Editor SQL restano liberi.
-- =========================================================

create or replace function public.controlla_iscrizione_tardiva()
returns trigger
language plpgsql
as $$
declare
  inizio timestamptz;
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  select (m.match_date + m.match_time) at time zone 'Europe/Rome'
  into inizio
  from public.matches m
  where m.id = new.match_id;

  if inizio is not null and inizio < now() then
    raise exception 'Questa partita e'' gia'' iniziata: non ci si puo'' piu'' iscrivere';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_iscrizione_tardiva on public.match_players;

create trigger trg_iscrizione_tardiva
  before insert on public.match_players
  for each row
  execute function public.controlla_iscrizione_tardiva();


-- =========================================================
-- PARTE 4 — IL PUNTEGGIO SI PUO' CORREGGERE
--
-- IL VICOLO CIECO DI PRIMA
-- Chi sbagliava a digitare il punteggio non aveva rimedio:
-- registra_risultato sbatteva contro la chiave primaria e non
-- esisteva un modo per modificarlo. L'unica uscita era che un
-- avversario confermasse il punteggio SBAGLIATO. Quindi o contava
-- un risultato errato, o la partita non contava per nessuno.
--
-- LA REGOLA
-- Si corregge finche' il risultato non e' confermato:
--   - "in_attesa": lo corregge chi l'ha inserito (l'errore di
--     battitura e' suo, e nessun altro l'ha ancora guardato);
--   - "contestato": lo corregge chiunque abbia giocato, ed e'
--     questo che scioglie la contestazione;
--   - "confermato": non si tocca. La conferma di un avversario e'
--     definitiva, altrimenti tornerebbe il buco chiuso
--     nell'aggiornamento n.9.
-- Ogni correzione riporta il risultato in attesa e fa ripartire le
-- 48 ore: il punteggio nuovo va guardato da capo.
-- =========================================================

create or replace function public.correggi_risultato(p_match_id uuid, p_sets jsonb)
returns public.match_results
language plpgsql
security definer
set search_path = public
as $$
declare
  risultato public.match_results;
  n_set int;
  set_a int := 0;
  set_b int := 0;
  punti_a int;
  punti_b int;
  i int;
  vincitore char(1);
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into risultato from public.match_results where match_id = p_match_id;

  if risultato is null then
    raise exception 'Non c''e'' nessun risultato da correggere';
  end if;

  if not exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = auth.uid()
  ) then
    raise exception 'Solo chi ha giocato la partita puo'' correggerne il risultato';
  end if;

  if risultato.stato = 'confermato' then
    raise exception 'Il risultato e'' stato confermato da un avversario: non si puo'' piu'' correggere';
  end if;

  if risultato.stato = 'in_attesa' and risultato.registrato_da <> auth.uid() then
    raise exception 'Questo punteggio l''ha inserito un altro giocatore: se non e'' giusto, contestalo';
  end if;

  -- Le stesse verifiche sul punteggio di registra_risultato: da 2 a 3
  -- set, nessun set in parita', un vincitore netto.
  if jsonb_typeof(p_sets) <> 'array' then
    raise exception 'Punteggio non valido';
  end if;

  n_set := jsonb_array_length(p_sets);
  if n_set < 2 or n_set > 3 then
    raise exception 'Una partita si decide su 2 o 3 set';
  end if;

  for i in 0 .. n_set - 1 loop
    if jsonb_typeof(p_sets -> i) <> 'array' or jsonb_array_length(p_sets -> i) <> 2 then
      raise exception 'Ogni set richiede due punteggi';
    end if;

    punti_a := (p_sets -> i ->> 0)::int;
    punti_b := (p_sets -> i ->> 1)::int;

    if punti_a is null or punti_b is null
       or punti_a < 0 or punti_b < 0
       or punti_a > 15 or punti_b > 15 then
      raise exception 'Punteggio del set % non valido', i + 1;
    end if;

    if punti_a = punti_b then
      raise exception 'Il set % non puo'' finire in parita''', i + 1;
    end if;

    if punti_a > punti_b then set_a := set_a + 1; else set_b := set_b + 1; end if;
  end loop;

  if set_a = set_b then
    raise exception 'Il punteggio non indica un vincitore';
  end if;

  vincitore := case when set_a > set_b then 'A' else 'B' end;

  update public.match_results
  set sets = p_sets,
      winner_team = vincitore,
      stato = 'in_attesa',
      registrato_da = auth.uid(),
      registrato_il = now(),
      confermato_da = null,
      confermato_il = null,
      nota_contestazione = null
  where match_id = p_match_id
  returning * into risultato;

  return risultato;
end;
$$;

grant execute on function public.correggi_risultato(uuid, jsonb) to authenticated;


-- =========================================================
-- COME SI NOMINA UN AMMINISTRATORE
-- Solo dall'Editor SQL di Supabase: dal browser il ruolo non e'
-- scrivibile (aggiornamento n.9). Sostituisci l'email ed esegui.
-- =========================================================
-- update public.profiles
-- set role = 'admin'
-- where id = (select id from auth.users where email = 'tua@email.it');

-- Per verificare chi e' amministratore:
-- select p.nome, p.cognome, u.email
-- from public.profiles p join auth.users u on u.id = p.id
-- where p.role = 'admin';
