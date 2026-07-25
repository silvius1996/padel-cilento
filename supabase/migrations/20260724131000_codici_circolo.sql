-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.3
-- Codici circolo + gestione partite (modifica / eliminazione)
-- Esegui nell'Editor SQL di Supabase DOPO schema_update_2.sql
-- =========================================================

-- ---------------------------------------------------------
-- 1. TABELLA CODICI CIRCOLO
-- Ogni codice abilita chi lo usa al ruolo "gestore".
-- ---------------------------------------------------------
create table if not exists public.club_codes (
  code text primary key,
  circolo text not null,
  attivo boolean not null default true,
  uso_singolo boolean not null default false,
  usato_da uuid references public.profiles(id) on delete set null,
  usato_il timestamptz,
  created_at timestamptz default now()
);

alter table public.club_codes enable row level security;

-- IMPORTANTE: nessuna policy di SELECT.
-- Nessun utente puo' leggere l'elenco dei codici dal browser.
-- La verifica avviene solo tramite la funzione sicura qui sotto.


-- ---------------------------------------------------------
-- 2. FUNZIONE SICURA: usa_codice_circolo
-- Il browser invia solo il codice e riceve un esito.
-- La validazione avviene interamente lato database, quindi
-- non e' aggirabile dalla console del browser.
-- ---------------------------------------------------------
create or replace function public.usa_codice_circolo(p_code text)
returns text
language plpgsql
security definer
as $$
declare
  riga public.club_codes;
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into riga
  from public.club_codes
  where upper(trim(code)) = upper(trim(p_code));

  if riga is null then
    raise exception 'Codice circolo non valido';
  end if;

  if not riga.attivo then
    raise exception 'Codice circolo non piu attivo';
  end if;

  if riga.uso_singolo and riga.usato_da is not null then
    raise exception 'Codice circolo gia utilizzato';
  end if;

  update public.profiles
  set role = 'gestore',
      circolo = riga.circolo
  where id = auth.uid();

  update public.club_codes
  set usato_da = auth.uid(),
      usato_il = now()
  where code = riga.code;

  return riga.circolo;
end;
$$;

grant execute on function public.usa_codice_circolo(text) to authenticated;


-- ---------------------------------------------------------
-- 3. PERMESSI DI GESTIONE PARTITE
-- Solo chi ha creato la partita puo' modificarla o eliminarla.
-- (le policy vengono ricreate per sicurezza)
-- ---------------------------------------------------------
drop policy if exists "Il creatore puo modificare/cancellare la propria partita" on public.matches;
drop policy if exists "Il creatore può modificare/cancellare la propria partita" on public.matches;
drop policy if exists "Il creatore puo cancellare la propria partita" on public.matches;
drop policy if exists "Il creatore può cancellare la propria partita" on public.matches;

create policy "Il creatore puo modificare la propria partita"
  on public.matches for update
  using ( auth.uid() = created_by );

create policy "Il creatore puo eliminare la propria partita"
  on public.matches for delete
  using ( auth.uid() = created_by );

-- Quando una partita viene eliminata, spariscono anche le iscrizioni
-- (garantito dal ON DELETE CASCADE gia presente su match_players)


-- ---------------------------------------------------------
-- 4. INDICE PER IL FEED
-- ---------------------------------------------------------
create index if not exists idx_matches_feed on public.matches (match_date, match_time, filled_slots);


-- ---------------------------------------------------------
-- 5. COME CREARE UN CODICE PER UN CIRCOLO
-- Modifica i valori ed esegui solo queste righe.
--
-- uso_singolo = false -> il codice vale per piu persone dello stesso circolo
-- uso_singolo = true  -> il codice funziona una volta sola
-- ---------------------------------------------------------
-- insert into public.club_codes (code, circolo, uso_singolo)
-- values ('PAESTUM-2026', 'Padel Club Paestum', false);

-- Per revocare un codice (chi e' gia gestore resta gestore):
-- update public.club_codes set attivo = false where code = 'PAESTUM-2026';

-- Per vedere i codici esistenti (solo da qui, non dall'app):
-- select code, circolo, attivo, uso_singolo, usato_il from public.club_codes;
