-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.27
-- Il circolo pubblica il campo senza giocarci
--
-- PERCHE' ADESSO
-- Un circolo che pubblica un'ora libera non sta giocando: sta
-- offrendo un campo. Ma crea_partita iscriveva sempre chi crea a un
-- posto, quindi il circolo compariva fra i giocatori e i posti liberi
-- erano tre invece di quattro. E' anche cio' che promette la
-- presentazione per i circoli — "pubblichi un'ora vuota, te la
-- riempiono loro" — e finora non era vero.
--
-- L'altra meta' del problema: al telefono il circolo ha gia' due
-- giocatori confermati, e non poteva metterli in campo. La policy di
-- inserimento su match_players dice "auth.uid() = user_id", cioe'
-- ognuno iscrive solo se stesso. E' una buona regola e non viene
-- toccata: si aggiungono due funzioni "security definer" che
-- verificano una condizione piu' stretta — sei TU che hai creato
-- QUESTA partita — invece di allargare la policy a tutti.
--
-- I nomi sono testo, come nei tornei: a una partita di circolo
-- partecipa anche chi l'app non ce l'ha. Il collegamento a un account
-- resta possibile, ma da parte del diretto interessato, che si iscrive
-- da solo al posto libero.
-- =========================================================


-- =========================================================
-- PARTE 1 — IL GIOCATORE SENZA ACCOUNT
-- =========================================================

alter table public.match_players
  add column if not exists ospite text;

-- Un posto e' occupato da un account oppure da un nome scritto a mano,
-- mai da tutti e due e mai da nessuno dei due: senza questo vincolo
-- esisterebbero righe che occupano un posto senza dire chi c'e'.
alter table public.match_players
  drop constraint if exists match_players_chi_check;

alter table public.match_players
  add constraint match_players_chi_check check (
    (user_id is not null and ospite is null)
    or
    (user_id is null and ospite is not null and length(trim(ospite)) > 0)
  );

-- L'indice univoco sul posto (aggiornamento n.5) continua a valere e
-- vale anche per gli ospiti: due persone non stanno nello stesso posto.
-- Quello su (match_id, user_id) non da' fastidio, perche' in PostgreSQL
-- piu' righe con user_id nullo convivono in un indice univoco.


-- =========================================================
-- PARTE 2 — CREARE UNA PARTITA SENZA GIOCARCI
-- =========================================================

-- Cambia solo il significato di p_spot nullo: prima era un errore, ora
-- vuol dire "pubblico il campo, io non gioco". La firma resta la stessa,
-- quindi le versioni dell'app gia' aperte in un browser continuano a
-- funzionare: passano un numero, e si comportano come prima.
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

  -- p_spot nullo e' ammesso e significa "non gioco". Un numero fuori
  -- dai quattro posti resta un errore.
  if p_spot is not null and (p_spot < 0 or p_spot > 3) then
    raise exception 'Il posto in campo deve essere compreso fra 0 e 3';
  end if;

  if p_club is null or length(trim(p_club)) = 0 then
    raise exception 'Il circolo e'' obbligatorio';
  end if;

  if p_match_date < (now() at time zone 'Europe/Rome')::date then
    raise exception 'Non si puo'' organizzare una partita in una data passata';
  end if;

  insert into public.matches (
    club, zona, match_date, match_time, level, total_slots, filled_slots, created_by
  )
  values (
    trim(p_club), p_zona, p_match_date, p_match_time, p_level, 4, 0, auth.uid()
  )
  returning * into partita;

  if p_spot is not null then
    insert into public.match_players (match_id, user_id, spot)
    values (partita.id, auth.uid(), p_spot);
  end if;

  -- filled_slots lo tiene il trigger: si rilegge, per non restituire
  -- all'app un conteggio vecchio di una riga.
  select * into partita from public.matches where id = partita.id;

  return partita;
end;
$$;

grant execute on function public.crea_partita(text, text, date, time, text, smallint) to authenticated;


-- =========================================================
-- PARTE 3 — CHI ORGANIZZA RIEMPIE I POSTI
-- =========================================================

-- Vero solo per chi ha creato QUESTA partita, o per l'amministratore.
-- Non basta essere un gestore di circolo: un gestore non deve poter
-- toccare la formazione di una partita altrui, nemmeno se si gioca
-- sul suo campo.
create or replace function public.organizza_questa_partita(p_match_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.matches m
    where m.id = p_match_id
      and (m.created_by = auth.uid() or public.e_amministratore())
  );
$$;

grant execute on function public.organizza_questa_partita(uuid) to authenticated;


create or replace function public.partita_aggiungi_ospite(
  p_match_id uuid,
  p_spot smallint,
  p_nome text
)
returns public.match_players
language plpgsql
security definer
set search_path = public
as $$
declare
  partita public.matches;
  riga    public.match_players;
begin
  if not public.organizza_questa_partita(p_match_id) then
    raise exception 'Solo chi ha organizzato la partita puo'' aggiungere un giocatore';
  end if;

  if p_spot is null or p_spot < 0 or p_spot > 3 then
    raise exception 'Il posto in campo deve essere compreso fra 0 e 3';
  end if;

  if p_nome is null or length(trim(p_nome)) = 0 then
    raise exception 'Serve il nome del giocatore';
  end if;

  select * into partita from public.matches where id = p_match_id;
  if partita.id is null then
    raise exception 'Partita inesistente';
  end if;

  -- Stessa regola di chi si iscrive da solo: a partita iniziata la
  -- formazione non si tocca piu'.
  if (partita.match_date + partita.match_time) < (now() at time zone 'Europe/Rome') then
    raise exception 'La partita e'' gia'' iniziata';
  end if;

  begin
    insert into public.match_players (match_id, spot, ospite)
    values (p_match_id, p_spot, trim(p_nome))
    returning * into riga;
  exception when unique_violation then
    raise exception 'Quel posto e'' gia'' occupato';
  end;

  return riga;
end;
$$;

grant execute on function public.partita_aggiungi_ospite(uuid, smallint, text) to authenticated;


-- Toglie un ospite dal campo: il giocatore che ha dato buca, o il nome
-- scritto male. Non tocca chi si e' iscritto con il proprio account —
-- quello se ne va da solo, o lo rimuove l'amministratore con gli
-- strumenti di moderazione che ha gia'.
create or replace function public.partita_togli_ospite(
  p_match_id uuid,
  p_spot smallint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  quante int;
begin
  if not public.organizza_questa_partita(p_match_id) then
    raise exception 'Solo chi ha organizzato la partita puo'' togliere un giocatore';
  end if;

  delete from public.match_players
  where match_id = p_match_id
    and spot = p_spot
    and user_id is null;

  get diagnostics quante = row_count;

  if quante = 0 then
    raise exception 'In quel posto non c'' e'' un giocatore aggiunto a mano';
  end if;
end;
$$;

grant execute on function public.partita_togli_ospite(uuid, smallint) to authenticated;
