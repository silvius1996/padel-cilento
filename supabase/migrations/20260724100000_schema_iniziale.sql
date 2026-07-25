-- =========================================================
-- PADEL PAESTUM — Schema SQL per Supabase
-- Incolla ed esegui questo script nell'Editor SQL di Supabase
-- =========================================================

-- ---------------------------------------------------------
-- 1. TABELLA PROFILES
-- Estende auth.users con dati pubblici del giocatore.
-- ---------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  level text default '2.5',
  avatar_url text,
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;

create policy "I profili sono visibili a tutti gli utenti autenticati"
  on public.profiles for select
  using ( true );

create policy "Un utente può creare solo il proprio profilo"
  on public.profiles for insert
  with check ( auth.uid() = id );

create policy "Un utente può modificare solo il proprio profilo"
  on public.profiles for update
  using ( auth.uid() = id );


-- ---------------------------------------------------------
-- 2. TABELLA MATCHES
-- Le partite organizzate dagli utenti.
-- ---------------------------------------------------------
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  club text not null,
  zona text not null check (zona in ('paestum', 'capaccio', 'agropoli', 'altro')),
  match_date date not null,
  match_time time not null,
  level text not null check (level in ('principiante', 'intermedio', 'avanzato', 'open')),
  total_slots int not null default 4,
  filled_slots int not null default 1 check (filled_slots >= 0 and filled_slots <= total_slots),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);

alter table public.matches enable row level security;

create policy "Le partite sono visibili a tutti gli utenti autenticati"
  on public.matches for select
  using ( true );

create policy "Un utente autenticato può creare una partita"
  on public.matches for insert
  with check ( auth.uid() = created_by );

create policy "Il creatore può modificare/cancellare la propria partita"
  on public.matches for update
  using ( auth.uid() = created_by );

create policy "Il creatore può cancellare la propria partita"
  on public.matches for delete
  using ( auth.uid() = created_by );


-- ---------------------------------------------------------
-- 3. TABELLA MATCH_PLAYERS (facoltativa ma consigliata)
-- Traccia chi si è unito a quale partita, evitando doppie iscrizioni.
-- ---------------------------------------------------------
create table if not exists public.match_players (
  id uuid primary key default gen_random_uuid(),
  match_id uuid references public.matches(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  joined_at timestamptz default now(),
  unique (match_id, user_id)
);

alter table public.match_players enable row level security;

create policy "Le partecipazioni sono visibili a tutti gli utenti autenticati"
  on public.match_players for select
  using ( true );

create policy "Un utente può iscriversi solo a proprio nome"
  on public.match_players for insert
  with check ( auth.uid() = user_id );


-- ---------------------------------------------------------
-- 4. FUNZIONE RPC: increment_filled_slots
-- Aggiorna in modo atomico i posti occupati quando qualcuno si unisce,
-- evitando race condition tra più utenti che si iscrivono contemporaneamente.
-- ---------------------------------------------------------
create or replace function public.increment_filled_slots(p_match_id uuid)
returns public.matches
language plpgsql
security definer
as $$
declare
  updated_row public.matches;
begin
  update public.matches
  set filled_slots = filled_slots + 1
  where id = p_match_id
    and filled_slots < total_slots
  returning * into updated_row;

  if updated_row is null then
    raise exception 'Partita al completo o inesistente';
  end if;

  return updated_row;
end;
$$;

-- Permette agli utenti autenticati di eseguire la funzione
grant execute on function public.increment_filled_slots(uuid) to authenticated;


-- ---------------------------------------------------------
-- 5. INDICI UTILI
-- ---------------------------------------------------------
create index if not exists idx_matches_date on public.matches (match_date, match_time);
create index if not exists idx_matches_zona on public.matches (zona);
