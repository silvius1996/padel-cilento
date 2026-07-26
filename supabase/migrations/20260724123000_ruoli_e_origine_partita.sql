-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.2
-- Ruoli (giocatore / gestore) e origine della partita
-- Esegui nell'Editor SQL di Supabase DOPO schema_update.sql
-- =========================================================

-- ---------------------------------------------------------
-- 1. RUOLO SUL PROFILO
-- 'giocatore' = utente normale (default)
-- 'gestore'   = gestore di un circolo
-- ---------------------------------------------------------
alter table public.profiles
  add column if not exists role text not null default 'giocatore';

alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check check (role in ('giocatore', 'gestore'));

-- Nome del circolo gestito (solo per i gestori)
alter table public.profiles
  add column if not exists circolo text;


-- ---------------------------------------------------------
-- 2. ORIGINE DELLA PARTITA
-- 'circolo'   = campo prenotato e pubblicato dal circolo
-- 'giocatore' = campo prenotato da un giocatore che cerca compagni
-- ---------------------------------------------------------
alter table public.matches
  add column if not exists origin text not null default 'giocatore';

alter table public.matches
  drop constraint if exists matches_origin_check;

alter table public.matches
  add constraint matches_origin_check check (origin in ('circolo', 'giocatore'));


-- ---------------------------------------------------------
-- 3. COERENZA LATO DATABASE
-- L'origine non viene decisa dal browser: e' il database a
-- ricavarla dal ruolo di chi crea la partita. Cosi' un utente
-- non puo' spacciare la propria partita per una del circolo.
-- ---------------------------------------------------------
create or replace function public.set_match_origin()
returns trigger
language plpgsql
security definer
as $$
declare
  ruolo_creatore text;
begin
  select role into ruolo_creatore
  from public.profiles
  where id = new.created_by;

  if ruolo_creatore = 'gestore' then
    new.origin := 'circolo';
  else
    new.origin := 'giocatore';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_set_match_origin on public.matches;

create trigger trg_set_match_origin
  before insert on public.matches
  for each row
  execute function public.set_match_origin();


-- ---------------------------------------------------------
-- 4. COME NOMINARE UN GESTORE
-- Sostituisci l'email con quella dell'account da promuovere,
-- poi esegui solo queste righe.
-- ---------------------------------------------------------
-- update public.profiles
-- set role = 'gestore', circolo = 'Padel Arena'
-- where id = (select id from auth.users where email = 'gestore@esempio.it');
