-- =========================================================
-- PADEL CILENTO — Script di AGGIORNAMENTO SQL
-- Esegui questo script nell'Editor SQL di Supabase DOPO schema.sql
-- (aggiunge campi profilo, gestione disiscrizione, storage avatar)
-- =========================================================

-- ---------------------------------------------------------
-- 1. NUOVI CAMPI SUL PROFILO: nome, cognome, telefono
-- (full_name resta per compatibilita, viene composto lato app)
-- ---------------------------------------------------------
alter table public.profiles add column if not exists nome text;
alter table public.profiles add column if not exists cognome text;
alter table public.profiles add column if not exists telefono text;


-- ---------------------------------------------------------
-- 2. POLICY DI CANCELLAZIONE SU match_players
-- Necessaria per permettere a un giocatore di disiscriversi
-- ---------------------------------------------------------
create policy "Un utente puo disiscriversi solo a proprio nome"
  on public.match_players for delete
  using ( auth.uid() = user_id );


-- ---------------------------------------------------------
-- 3. FUNZIONE RPC: decrement_filled_slots
-- Usata quando un giocatore si disiscrive da una partita:
-- libera un posto in modo atomico.
-- ---------------------------------------------------------
create or replace function public.decrement_filled_slots(p_match_id uuid)
returns public.matches
language plpgsql
security definer
as $$
declare
  updated_row public.matches;
begin
  update public.matches
  set filled_slots = greatest(filled_slots - 1, 0)
  where id = p_match_id
  returning * into updated_row;

  if updated_row is null then
    raise exception 'Partita inesistente';
  end if;

  return updated_row;
end;
$$;

grant execute on function public.decrement_filled_slots(uuid) to authenticated;


-- ---------------------------------------------------------
-- 4. STORAGE PER AVATAR PROFILO
-- Crea un bucket pubblico "avatars" per le foto profilo.
-- ---------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "Chiunque puo vedere gli avatar"
  on storage.objects for select
  using ( bucket_id = 'avatars' );

create policy "Un utente autenticato puo caricare il proprio avatar"
  on storage.objects for insert
  with check ( bucket_id = 'avatars' and auth.uid() is not null );

create policy "Un utente puo sovrascrivere solo il proprio avatar"
  on storage.objects for update
  using ( bucket_id = 'avatars' and owner = auth.uid() );
