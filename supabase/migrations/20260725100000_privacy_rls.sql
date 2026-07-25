-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.4  (PRIVACY / SICUREZZA)
-- Esegui nell'Editor SQL di Supabase DOPO schema_update_3.sql
--
-- PROBLEMA RISOLTO
-- Le policy scritte come "using ( true )" si applicano al ruolo
-- "public", che comprende anche "anon" (visitatore non autenticato).
-- Poiche' la chiave anon e' pubblica dentro l'app, chiunque poteva
-- leggere l'intera tabella profiles, TELEFONI COMPRESI.
-- =========================================================


-- ---------------------------------------------------------
-- 1. PROFILI: visibili solo a chi ha effettuato l'accesso
-- ---------------------------------------------------------
drop policy if exists "I profili sono visibili a tutti gli utenti autenticati" on public.profiles;

create policy "I profili sono visibili solo agli utenti autenticati"
  on public.profiles for select
  to authenticated              -- <<< la clausola che mancava
  using ( true );


-- ---------------------------------------------------------
-- 2. TELEFONO: nascosto anche agli altri utenti registrati
-- RLS filtra le righe, non le colonne: per proteggere un singolo
-- campo servono i permessi di colonna.
-- Ognuno continua a vedere il PROPRIO numero (punto 4).
--
-- !! ATTENZIONE: QUESTA RIGA NON FUNZIONA — vedi schema_update_6.sql
-- Supabase concede SELECT sull'intera TABELLA: una revoca su una
-- singola COLONNA non annulla un privilegio concesso sulla tabella.
-- La correzione (revoca sulla tabella + grant per colonna) e' in
-- schema_update_6.sql. Questa riga resta solo per non alterare la
-- sequenza degli script, ma e' inefficace.
-- ---------------------------------------------------------
revoke select (telefono) on public.profiles from anon, authenticated;


-- ---------------------------------------------------------
-- 3. ISCRIZIONI: visibili solo a chi ha effettuato l'accesso
-- ---------------------------------------------------------
drop policy if exists "Le partecipazioni sono visibili a tutti gli utenti autenticati" on public.match_players;

create policy "Le partecipazioni sono visibili solo agli utenti autenticati"
  on public.match_players for select
  to authenticated
  using ( true );


-- ---------------------------------------------------------
-- 4. IL PROPRIO PROFILO COMPLETO (telefono incluso)
-- Serve alla schermata "Il tuo profilo".
-- ---------------------------------------------------------
create or replace function public.mio_profilo()
returns public.profiles
language sql
security definer
set search_path = public
as $$
  select * from public.profiles where id = auth.uid();
$$;

grant execute on function public.mio_profilo() to authenticated;


-- ---------------------------------------------------------
-- 5. LE PARTITE RESTANO PUBBLICHE
-- Orario, circolo, livello e posti liberi non sono dati personali:
-- vederli senza registrarsi e' cio' che invoglia a iscriversi.
-- Nessuna modifica: la policy su "matches" va bene com'e'.
-- ---------------------------------------------------------


-- ---------------------------------------------------------
-- 6. INTEGRITA': non si entra in una partita al completo
-- Finora il limite di 4 giocatori era garantito solo dalla RPC.
-- Chiamando l'API a mano si poteva inserire un 5o giocatore
-- direttamente in match_players. Ora lo blocca il database.
-- ---------------------------------------------------------
create or replace function public.controlla_capienza_partita()
returns trigger
language plpgsql
as $$
declare
  iscritti int;
  capienza int;
begin
  select count(*) into iscritti
  from public.match_players
  where match_id = new.match_id;

  select total_slots into capienza
  from public.matches
  where id = new.match_id;

  if iscritti >= coalesce(capienza, 4) then
    raise exception 'Questa partita e'' gia'' al completo';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_controlla_capienza on public.match_players;

create trigger trg_controlla_capienza
  before insert on public.match_players
  for each row
  execute function public.controlla_capienza_partita();


-- ---------------------------------------------------------
-- 7. VERIFICA (opzionale)
-- Dopo aver eseguito lo script, questa query deve restituire
-- solo policy con roles = {authenticated} per profiles e match_players.
-- ---------------------------------------------------------
-- select tablename, policyname, roles, cmd
-- from pg_policies
-- where schemaname = 'public' and cmd = 'SELECT'
-- order by tablename;
