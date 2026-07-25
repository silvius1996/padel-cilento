-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.5
-- Squadre reali, risultati confermati, statistiche, contatti
-- Esegui nell'Editor SQL di Supabase DOPO schema_update_4.sql
--
-- COSA INTRODUCE
--  1. Ogni iscritto occupa un POSTO preciso in campo (0-3).
--     Posti 0-1 = Squadra A   |   Posti 2-3 = Squadra B
--  2. Il risultato di una partita, valido solo se confermato
--     da un avversario (o dopo 48 ore senza contestazioni).
--  3. Statistiche per giocatore, DERIVATE dai risultati.
--  4. Numeri di telefono visibili solo tra chi gioca insieme.
-- =========================================================


-- =========================================================
-- PARTE 1 — IL POSTO IN CAMPO
-- =========================================================

alter table public.match_players
  add column if not exists spot smallint;

-- Le iscrizioni esistenti vengono assegnate ai posti secondo
-- l'ordine di iscrizione: e' esattamente il criterio che l'app
-- usava finora per disegnarle sul campo, quindi nulla cambia
-- visivamente per le partite gia' create.
with ordinati as (
  select id,
         row_number() over (partition by match_id order by joined_at) - 1 as posto
  from public.match_players
)
update public.match_players mp
set spot = o.posto
from ordinati o
where mp.id = o.id
  and mp.spot is null;

alter table public.match_players
  drop constraint if exists match_players_spot_check;

alter table public.match_players
  add constraint match_players_spot_check check (spot >= 0 and spot <= 3);

alter table public.match_players
  alter column spot set not null;

-- Due giocatori non possono occupare lo stesso posto: lo impedisce
-- il database, non l'interfaccia.
create unique index if not exists idx_match_players_spot
  on public.match_players (match_id, spot);


-- ---------------------------------------------------------
-- POSTI OCCUPATI SEMPRE COERENTI
-- Ogni posto corrisponde a un account: filled_slots non e' piu'
-- un dato da aggiornare a mano, ma il semplice conteggio degli
-- iscritti. Lo mantiene il database, quindi non puo' divergere.
-- ---------------------------------------------------------
create or replace function public.sincronizza_posti_occupati()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  id_partita uuid;
begin
  id_partita := coalesce(new.match_id, old.match_id);

  update public.matches
  set filled_slots = (
    select count(*) from public.match_players where match_id = id_partita
  )
  where id = id_partita;

  return null;
end;
$$;

drop trigger if exists trg_sincronizza_posti on public.match_players;

create trigger trg_sincronizza_posti
  after insert or delete on public.match_players
  for each row
  execute function public.sincronizza_posti_occupati();

-- Riallineamento una volta sola dei dati esistenti
update public.matches m
set filled_slots = (
  select count(*) from public.match_players mp where mp.match_id = m.id
);


-- =========================================================
-- PARTE 2 — IL RISULTATO
-- =========================================================

create table if not exists public.match_results (
  match_id uuid primary key references public.matches(id) on delete cascade,

  -- Punteggio come elenco di set: [[6,4],[3,6],[7,5]]
  -- Il primo numero e' sempre della Squadra A (posti 0-1).
  sets jsonb not null,

  -- Ricavato dal punteggio dal database, non dichiarato dall'app
  winner_team char(1) not null check (winner_team in ('A', 'B')),

  stato text not null default 'in_attesa'
    check (stato in ('in_attesa', 'confermato', 'contestato')),

  registrato_da uuid not null references public.profiles(id),
  registrato_il timestamptz not null default now(),
  confermato_da uuid references public.profiles(id),
  confermato_il timestamptz,
  nota_contestazione text
);

alter table public.match_results enable row level security;

-- Lettura consentita agli utenti registrati: le statistiche sono sociali.
create policy "I risultati sono visibili agli utenti autenticati"
  on public.match_results for select
  to authenticated
  using ( true );

-- Nessuna policy di INSERT / UPDATE / DELETE:
-- si scrive solo tramite le funzioni controllate qui sotto.


-- ---------------------------------------------------------
-- FORMAZIONE CONGELATA
-- Con un risultato registrato nessuno entra o esce dalla partita:
-- altrimenti una sconfitta si cancellerebbe disiscrivendosi.
-- ---------------------------------------------------------
create or replace function public.blocca_formazione_se_conclusa()
returns trigger
language plpgsql
as $$
declare
  id_partita uuid;
begin
  id_partita := coalesce(new.match_id, old.match_id);

  if exists (select 1 from public.match_results where match_id = id_partita) then
    raise exception 'La partita ha un risultato registrato: la formazione non si puo'' piu'' modificare';
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_blocca_formazione on public.match_players;

create trigger trg_blocca_formazione
  before insert or delete on public.match_players
  for each row
  execute function public.blocca_formazione_se_conclusa();


-- ---------------------------------------------------------
-- REGISTRAZIONE DEL RISULTATO
-- Vincoli applicati dal database:
--   - chi registra deve aver giocato la partita
--   - la partita deve essere iniziata
--   - devono esserci 4 giocatori (2 contro 2)
--   - da 2 a 3 set, nessun set pari, un vincitore netto
-- ---------------------------------------------------------
create or replace function public.registra_risultato(p_match_id uuid, p_sets jsonb)
returns public.match_results
language plpgsql
security definer
set search_path = public
as $$
declare
  partita public.matches;
  n_set int;
  n_giocatori int;
  set_a int := 0;
  set_b int := 0;
  punti_a int;
  punti_b int;
  i int;
  vincitore char(1);
  risultato public.match_results;
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into partita from public.matches where id = p_match_id;
  if partita is null then
    raise exception 'Partita inesistente';
  end if;

  if not exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = auth.uid()
  ) then
    raise exception 'Solo chi ha giocato la partita puo'' registrarne il risultato';
  end if;

  -- L'orario della partita e' un'ora locale italiana, mentre now() e' in UTC:
  -- senza la conversione una partita delle 20:00 risulterebbe "non iniziata"
  -- fino alle 22:00 ora locale.
  if ((partita.match_date + partita.match_time) at time zone 'Europe/Rome') > now() then
    raise exception 'La partita non e'' ancora iniziata';
  end if;

  select count(*) into n_giocatori
  from public.match_players where match_id = p_match_id;

  if n_giocatori <> 4 then
    raise exception 'Serve una formazione completa di 4 giocatori (attuali: %)', n_giocatori;
  end if;

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

    -- Si passa da ->> (testo) invece di -> (jsonb): la conversione a
    -- numero e' cosi' valida su qualunque versione di PostgreSQL.
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

  insert into public.match_results (match_id, sets, winner_team, registrato_da)
  values (p_match_id, p_sets, vincitore, auth.uid())
  returning * into risultato;

  return risultato;
end;
$$;

grant execute on function public.registra_risultato(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------
-- CONFERMA DEL RISULTATO
-- Deve arrivare da un giocatore della squadra AVVERSARIA
-- rispetto a chi lo ha inserito: nessuno convalida se stesso.
-- ---------------------------------------------------------
create or replace function public.conferma_risultato(p_match_id uuid)
returns public.match_results
language plpgsql
security definer
set search_path = public
as $$
declare
  squadra_mia char(1);
  squadra_autore char(1);
  risultato public.match_results;
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into risultato from public.match_results where match_id = p_match_id;
  if risultato is null then
    raise exception 'Nessun risultato da confermare';
  end if;

  if risultato.stato = 'confermato' then
    raise exception 'Risultato gia'' confermato';
  end if;

  select case when spot < 2 then 'A' else 'B' end into squadra_mia
  from public.match_players
  where match_id = p_match_id and user_id = auth.uid();

  if squadra_mia is null then
    raise exception 'Non hai giocato questa partita';
  end if;

  select case when spot < 2 then 'A' else 'B' end into squadra_autore
  from public.match_players
  where match_id = p_match_id and user_id = risultato.registrato_da;

  if squadra_mia = squadra_autore then
    raise exception 'Il risultato deve essere confermato da un avversario';
  end if;

  update public.match_results
  set stato = 'confermato',
      confermato_da = auth.uid(),
      confermato_il = now()
  where match_id = p_match_id
  returning * into risultato;

  return risultato;
end;
$$;

grant execute on function public.conferma_risultato(uuid) to authenticated;


-- ---------------------------------------------------------
-- CONTESTAZIONE
-- E' la valvola di sicurezza che rende accettabile la
-- convalida automatica dopo 48 ore: un risultato contestato
-- non entra nelle statistiche di nessuno.
-- ---------------------------------------------------------
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

  if not exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = auth.uid()
  ) then
    raise exception 'Non hai giocato questa partita';
  end if;

  update public.match_results
  set stato = 'contestato',
      nota_contestazione = p_nota
  where match_id = p_match_id
  returning * into risultato;

  if risultato is null then
    raise exception 'Nessun risultato da contestare';
  end if;

  return risultato;
end;
$$;

grant execute on function public.contesta_risultato(uuid, text) to authenticated;


-- =========================================================
-- PARTE 3 — LE STATISTICHE
-- Sono una VISTA, non dei contatori.
-- Un contatore separato dai fatti prima o poi divergera' dai
-- fatti (com'e' successo due volte con filled_slots): qui il
-- dato viene ricalcolato dai risultati, quindi non puo' mentire.
-- =========================================================

create or replace view public.statistiche_giocatori
with (security_invoker = true) as
with risultati_validi as (
  select *
  from public.match_results
  where stato = 'confermato'
     -- convalida automatica: nessuna contestazione entro 48 ore
     or (stato = 'in_attesa' and registrato_il < now() - interval '48 hours')
),
partite_giocate as (
  select
    mp.user_id,
    case when mp.spot < 2 then 'A' else 'B' end as squadra,
    r.winner_team,
    r.sets
  from public.match_players mp
  join risultati_validi r on r.match_id = mp.match_id
)
select
  user_id,
  count(*)::int as partite,
  count(*) filter (where squadra = winner_team)::int as vittorie,
  count(*) filter (where squadra <> winner_team)::int as sconfitte,
  case
    when count(*) = 0 then 0
    else round(100.0 * count(*) filter (where squadra = winner_team) / count(*))::int
  end as percentuale_vittorie
from partite_giocate
group by user_id;

grant select on public.statistiche_giocatori to authenticated;


-- ---------------------------------------------------------
-- STATISTICHE DI UN GIOCATORE (con dati anagrafici pubblici)
-- ---------------------------------------------------------
create or replace function public.statistiche_giocatore(p_user_id uuid default null)
returns table (
  user_id uuid,
  nome text,
  cognome text,
  level text,
  avatar_url text,
  partite int,
  vittorie int,
  sconfitte int,
  percentuale_vittorie int
)
language sql
security definer
set search_path = public
as $$
  select
    p.id,
    p.nome,
    p.cognome,
    p.level,
    p.avatar_url,
    coalesce(s.partite, 0),
    coalesce(s.vittorie, 0),
    coalesce(s.sconfitte, 0),
    coalesce(s.percentuale_vittorie, 0)
  from public.profiles p
  left join public.statistiche_giocatori s on s.user_id = p.id
  where p.id = coalesce(p_user_id, auth.uid());
$$;

grant execute on function public.statistiche_giocatore(uuid) to authenticated;


-- ---------------------------------------------------------
-- CLASSIFICA
-- Solo chi ha giocato almeno 3 partite valide: con una sola
-- partita vinta si comparirebbe primi al 100%.
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
  order by s.percentuale_vittorie desc, s.vittorie desc
  limit 50;
$$;

grant execute on function public.classifica(int) to authenticated;


-- =========================================================
-- PARTE 4 — I CONTATTI
-- Il telefono resta invisibile a tutti (schema_update_4.sql),
-- tranne che tra chi condivide una partita: quello e' l'unico
-- caso in cui serve davvero.
-- =========================================================

create or replace function public.contatti_partita(p_match_id uuid)
returns table (
  user_id uuid,
  nome text,
  cognome text,
  telefono text,
  spot smallint,
  squadra char(1)
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  -- Il filtro decisivo: i contatti li vede solo chi gioca la partita.
  -- Le colonne dichiarate in "returns table" sono variabili PL/pgSQL:
  -- senza il prefisso mp. il riferimento a user_id sarebbe ambiguo.
  if not exists (
    select 1 from public.match_players mp
    where mp.match_id = p_match_id and mp.user_id = auth.uid()
  ) then
    raise exception 'I contatti sono visibili solo ai giocatori di questa partita';
  end if;

  return query
  select mp.user_id, p.nome, p.cognome, p.telefono, mp.spot,
         (case when mp.spot < 2 then 'A' else 'B' end)::char(1)
  from public.match_players mp
  join public.profiles p on p.id = mp.user_id
  where mp.match_id = p_match_id
  order by mp.spot;
end;
$$;

grant execute on function public.contatti_partita(uuid) to authenticated;


-- =========================================================
-- VERIFICA (opzionale)
-- =========================================================
-- select match_id, spot, user_id from public.match_players order by match_id, spot;
-- select * from public.statistiche_giocatori;
