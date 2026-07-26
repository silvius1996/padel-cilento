-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.7  (CORREZIONI DI SICUREZZA)
--
-- Chiude tre falle verificate con prove riproducibili:
--
--   1. RUOLO GESTORE AGGIRABILE
--      La policy di UPDATE su profiles concedeva la modifica di
--      TUTTE le colonne, "role" compresa: dalla console del browser
--      bastava  update profiles set role='gestore'  per diventare
--      gestore di un circolo inventato, senza alcun codice. Il
--      controllo in usa_codice_circolo era una porta blindata
--      accanto a una finestra aperta.
--
--   2. UN RISULTATO CONFERMATO SI POTEVA ANNULLARE
--      contesta_risultato non guardava lo stato del risultato ne'
--      chi la stesse chiamando: chi aveva perso poteva contestare
--      una partita GIA' confermata dall'avversario e far sparire la
--      sconfitta dalle statistiche. Anche l'autore del punteggio
--      poteva annullare il proprio inserimento.
--
--   3. I POSTI OCCUPATI SI POTEVANO FALSIFICARE
--      increment_filled_slots / decrement_filled_slots sono
--      "security definer" senza alcun controllo su chi chiama, e
--      dopo l'aggiornamento n.5 non servono piu' a nessuno: ora
--      filled_slots lo mantiene un trigger. Restavano pero'
--      eseguibili da qualunque utente su qualunque partita.
-- =========================================================


-- =========================================================
-- PARTE 1 — IL RUOLO NON SI SCRIVE DAL BROWSER
-- =========================================================

-- ---------------------------------------------------------
-- 1.1  PERMESSI PER COLONNA, COME GIA' FATTO PER "telefono"
-- Lo stesso principio dell'aggiornamento n.6, applicato alla
-- scrittura: si azzera il permesso sulla tabella e si riconcede
-- solo sulle colonne che l'utente ha diritto di cambiare.
-- "role" e "circolo" restano fuori dall'elenco.
--
-- Nota per il futuro: aggiungendo una colonna a profiles che
-- l'utente deve poter modificare, va aggiunta anche qui.
-- ---------------------------------------------------------
revoke insert, update on public.profiles from authenticated;

grant insert (
  id,
  nome,
  cognome,
  telefono,
  full_name,
  level,
  avatar_url
) on public.profiles to authenticated;

grant update (
  nome,
  cognome,
  telefono,
  full_name,
  level,
  avatar_url
) on public.profiles to authenticated;

-- Un visitatore non autenticato non scrive nulla. Le policy RLS lo
-- bloccavano gia' (richiedono auth.uid() = id, che per "anon" e'
-- nullo), questo e' un lucchetto indipendente in piu'.
revoke insert, update, delete on public.profiles from anon;


-- ---------------------------------------------------------
-- 1.2  LA POLICY, SCRITTA PER ESTESO
-- "using" da solo vale anche come controllo sulla riga nuova, ma
-- lasciarlo implicito e' proprio cio' che ha reso difficile
-- accorgersi del problema. Meglio dirlo.
-- ---------------------------------------------------------
drop policy if exists "Un utente può modificare solo il proprio profilo" on public.profiles;
drop policy if exists "Un utente puo modificare solo il proprio profilo" on public.profiles;

create policy "Un utente puo modificare solo il proprio profilo"
  on public.profiles for update
  to authenticated
  using ( auth.uid() = id )
  with check ( auth.uid() = id );


-- ---------------------------------------------------------
-- 1.3  SECONDO LUCCHETTO: UN TRIGGER
-- I permessi per colonna bastano, ma un "grant all" scritto per
-- distrazione in una migrazione futura li annullerebbe in silenzio.
-- Questo trigger e' indipendente: il ruolo non cambia se la
-- richiesta arriva dai ruoli pubblici del browser.
--
-- Continuano a funzionare:
--   - usa_codice_circolo(), che e' "security definer" e viene
--     quindi eseguita con i privilegi del proprietario;
--   - le promozioni a mano dall'Editor SQL di Supabase
--     (documentate nell'aggiornamento n.2).
-- ---------------------------------------------------------
create or replace function public.blocca_cambio_ruolo()
returns trigger
language plpgsql
as $$
begin
  -- Solo le richieste diritte dal browser vengono esaminate.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.role is distinct from 'giocatore' or new.circolo is not null then
      raise exception 'Il ruolo di gestore si ottiene solo con un codice circolo valido';
    end if;
  else
    if new.role is distinct from old.role or new.circolo is distinct from old.circolo then
      raise exception 'Il ruolo di gestore si ottiene solo con un codice circolo valido';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_blocca_cambio_ruolo on public.profiles;

create trigger trg_blocca_cambio_ruolo
  before insert or update on public.profiles
  for each row
  execute function public.blocca_cambio_ruolo();


-- =========================================================
-- PARTE 2 — LA CONTESTAZIONE HA DELLE REGOLE
--
-- La contestazione esiste per una ragione precisa: rendere
-- accettabile la convalida automatica dopo 48 ore. E' una valvola
-- di sicurezza per un risultato che nessuno ha ancora guardato,
-- non un modo per rimettere in discussione una partita chiusa.
-- Da qui le quattro condizioni:
--
--   - la si usa solo su un risultato ancora "in_attesa":
--     una conferma dell'avversario e' definitiva;
--   - non la usa chi ha inserito il punteggio: chi sbaglia a
--     digitare non annulla, chiede all'avversario di non
--     confermare (oppure il punteggio resta contestabile da lui);
--   - entro le 48 ore, cioe' finche' il risultato non e' stato
--     convalidato dal tempo: dopo, una contestazione cancellerebbe
--     partite gia' entrate nelle statistiche di tutti;
--   - solo da chi ha giocato quella partita (gia' presente).
-- =========================================================

create or replace function public.contesta_risultato(p_match_id uuid, p_nota text default null)
returns public.match_results
language plpgsql
security definer
set search_path = public
as $$
declare
  risultato public.match_results;
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into risultato from public.match_results where match_id = p_match_id;

  if risultato is null then
    raise exception 'Nessun risultato da contestare';
  end if;

  if not exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = auth.uid()
  ) then
    raise exception 'Non hai giocato questa partita';
  end if;

  if risultato.stato = 'confermato' then
    raise exception 'Il risultato e'' stato confermato da un avversario: non si puo'' piu'' contestare';
  end if;

  if risultato.stato = 'contestato' then
    raise exception 'Il risultato e'' gia'' contestato';
  end if;

  if risultato.registrato_da = auth.uid() then
    raise exception 'Non puoi contestare il risultato che hai inserito tu';
  end if;

  if risultato.registrato_il < now() - interval '48 hours' then
    raise exception 'I tempi per contestare questo risultato sono scaduti (48 ore)';
  end if;

  update public.match_results
  set stato = 'contestato',
      nota_contestazione = p_nota
  where match_id = p_match_id
  returning * into risultato;

  return risultato;
end;
$$;

grant execute on function public.contesta_risultato(uuid, text) to authenticated;


-- =========================================================
-- PARTE 3 — VIA LE FUNZIONI CHE NON SERVONO PIU'
--
-- Dall'aggiornamento n.5 filled_slots e' il conteggio degli
-- iscritti, mantenuto dal trigger trg_sincronizza_posti.
-- L'interfaccia non chiama piu' queste due funzioni: restavano
-- solo come scorciatoia per falsificare i posti liberi di una
-- partita altrui. Il codice morto non va protetto, va rimosso
-- (resta nella storia del progetto, se mai servisse rileggerlo).
-- =========================================================

drop function if exists public.increment_filled_slots(uuid);
drop function if exists public.decrement_filled_slots(uuid);


-- =========================================================
-- PARTE 4 — LA DATA NEL PASSATO LA RIFIUTA IL DATABASE
--
-- Il modulo di creazione impedisce gia' di scegliere un giorno
-- passato (in index.html:  el.inputDate.min = oggiISO() ), ma quello
-- e' un controllo che vive solo nella pagina: basta togliere
-- l'attributo dagli strumenti sviluppatore, o chiamare l'API con la
-- chiave anon che e' pubblica, e la partita di tre giorni fa entra
-- nel feed. E' l'unico punto in cui una regola non era applicata dal
-- database.
--
-- La regola qui e' identica a quella del modulo — si guarda il
-- giorno, non l'ora — cosi' l'interfaccia non se ne accorge e nulla
-- cambia per chi usa l'app normalmente.
--
-- Sulle modifiche il controllo scatta solo se la data viene davvero
-- spostata: altrimenti non si potrebbe piu' correggere il nome del
-- circolo su una partita di ieri.
-- =========================================================

create or replace function public.controlla_data_partita()
returns trigger
language plpgsql
as $$
begin
  -- Come per il trigger sul ruolo, si esaminano solo le richieste che
  -- arrivano dal browser. Dall'Editor SQL resta possibile inserire una
  -- partita vecchia, se mai servisse recuperarne una a mano.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'UPDATE' and new.match_date is not distinct from old.match_date then
    return new;
  end if;

  -- L'ora italiana, non quella del server: a mezzanotte e mezza a Roma
  -- in UTC e' ancora il giorno prima.
  if new.match_date < (now() at time zone 'Europe/Rome')::date then
    raise exception 'Non si puo'' organizzare una partita in una data passata';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_controlla_data_partita on public.matches;

create trigger trg_controlla_data_partita
  before insert or update on public.matches
  for each row
  execute function public.controlla_data_partita();


-- =========================================================
-- VERIFICA (opzionale)
-- =========================================================
-- Le colonne scrivibili da "authenticated": non devono comparire
-- ne' "role" ne' "circolo".
--
-- select grantee, column_name, privilege_type
-- from information_schema.column_privileges
-- where table_schema = 'public' and table_name = 'profiles'
--   and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE')
-- order by privilege_type, column_name;
