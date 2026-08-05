-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.28
-- Il circolo mette in campo anche chi ha l'app
--
-- PERCHE' ADESSO
-- L'aggiornamento n.27 permette al circolo di riempire i posti con
-- nomi scritti a mano. Ma meta' dei giocatori che chiamano per
-- prenotare l'app ce l'hanno gia': scriverli come testo vuol dire
-- che la partita non entra nelle loro statistiche e che il loro
-- profilo non sa di averla giocata. E' lo stesso problema che nei
-- tornei si risolve collegando la coppia a un account.
--
-- IL PUNTO DELICATO: IL CONSENSO
-- Iscrivere qualcuno e' un atto compiuto da un terzo. Finora un
-- giocatore finiva in una partita solo scegliendolo, e da quella
-- scelta discendeva anche la condivisione del numero di telefono
-- con gli altri tre (contatti_partita).
--
-- Quella catena qui si spezza, quindi il telefono va protetto: chi
-- e' stato messo in campo da qualcun altro compare in formazione,
-- gioca e conta nelle statistiche, ma il suo numero resta nascosto
-- finche' non e' lui a decidere. Chi non ci sta si toglie da solo:
-- la disiscrizione esisteva gia' e continua a funzionare.
-- =========================================================


-- =========================================================
-- PARTE 1 — CHI HA MESSO IN CAMPO CHI
-- =========================================================

-- Nullo = si e' iscritto da solo, ed e' il caso di tutte le righe
-- esistenti. Valorizzato = ce l'ha messo l'organizzatore.
alter table public.match_players
  add column if not exists aggiunto_da uuid references public.profiles(id) on delete set null;


-- =========================================================
-- PARTE 2 — METTERE IN CAMPO UN ACCOUNT
-- =========================================================

create or replace function public.partita_aggiungi_giocatore(
  p_match_id uuid,
  p_spot smallint,
  p_user_id uuid
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

  if not exists (
    select 1 from public.profiles
    where id = p_user_id and eliminato_il is null
  ) then
    raise exception 'Giocatore inesistente';
  end if;

  select * into partita from public.matches where id = p_match_id;
  if partita.id is null then
    raise exception 'Partita inesistente';
  end if;

  if (partita.match_date + partita.match_time) < (now() at time zone 'Europe/Rome') then
    raise exception 'La partita e'' gia'' iniziata';
  end if;

  if exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = p_user_id
  ) then
    raise exception 'Quel giocatore e'' gia'' in campo';
  end if;

  begin
    insert into public.match_players (match_id, spot, user_id, aggiunto_da)
    values (p_match_id, p_spot, p_user_id, auth.uid())
    returning * into riga;
  exception when unique_violation then
    raise exception 'Quel posto e'' gia'' occupato';
  end;

  return riga;
end;
$$;

grant execute on function public.partita_aggiungi_giocatore(uuid, smallint, uuid) to authenticated;


-- L'ospite adesso porta con se' chi ce l'ha messo, come il giocatore
-- registrato: e' cio' che permette di distinguere "sono entrato io" da
-- "mi ha messo il circolo".
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

  if (partita.match_date + partita.match_time) < (now() at time zone 'Europe/Rome') then
    raise exception 'La partita e'' gia'' iniziata';
  end if;

  begin
    insert into public.match_players (match_id, spot, ospite, aggiunto_da)
    values (p_match_id, p_spot, trim(p_nome), auth.uid())
    returning * into riga;
  exception when unique_violation then
    raise exception 'Quel posto e'' gia'' occupato';
  end;

  return riga;
end;
$$;

grant execute on function public.partita_aggiungi_ospite(uuid, smallint, text) to authenticated;


-- =========================================================
-- PARTE 3 — TOGLIERE CHI E' STATO MESSO
-- =========================================================

-- Si allarga a chiunque sia stato messo in campo dall'organizzatore,
-- non piu' ai soli nomi scritti a mano: se l'ha messo lui, puo'
-- togliere anche lui. Chi si e' iscritto da solo resta intoccabile —
-- se ne va da solo, o interviene l'amministratore con gli strumenti
-- di moderazione che ha gia'.
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
    and (ospite is not null or aggiunto_da is not null);

  get diagnostics quante = row_count;

  if quante = 0 then
    raise exception 'In quel posto c'' e'' un giocatore che si e'' iscritto da solo';
  end if;
end;
$$;

grant execute on function public.partita_togli_ospite(uuid, smallint) to authenticated;


-- =========================================================
-- PARTE 4 — IL TELEFONO DI CHI NON HA SCELTO
-- =========================================================

-- Il numero compare solo se quel giocatore e' entrato di sua volonta',
-- oppure se sta guardando il proprio. Chi e' stato messo in campo da
-- altri resta in formazione con nome e cognome, ma senza numero:
-- condividerlo sarebbe una decisione presa da qualcun altro al posto
-- suo. Appena si iscrive a una partita da solo, li' il numero c'e'.
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

  if not exists (
    select 1 from public.match_players mp
    where mp.match_id = p_match_id and mp.user_id = auth.uid()
  ) then
    raise exception 'I contatti sono visibili solo ai giocatori di questa partita';
  end if;

  return query
  select mp.user_id, p.nome, p.cognome,
         (case when mp.aggiunto_da is null or mp.user_id = auth.uid()
               then p.telefono else null end),
         mp.spot,
         (case when mp.spot < 2 then 'A' else 'B' end)::char(1)
  from public.match_players mp
  join public.profiles p on p.id = mp.user_id
  where mp.match_id = p_match_id
  order by mp.spot;
end;
$$;

grant execute on function public.contatti_partita(uuid) to authenticated;
