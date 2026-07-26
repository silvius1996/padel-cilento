-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.16
-- Le fasi finali: il tabellone
--
-- Dai gironi escono le qualificate, e dalle qualificate nasce il
-- tabellone. Poi il torneo si gioca da solo: appena un risultato
-- viene inserito, chi ha vinto compare nel turno successivo senza
-- che il circolo debba comporre gli accoppiamenti a mano.
-- =========================================================


-- =========================================================
-- PARTE 1 — DOVE VA CHI VINCE
--
-- L'accoppiamento del turno successivo non si ricava dal nulla: ogni
-- incontro sa gia' in quale casella finisce il suo vincitore, e in
-- quale il suo perdente (serve alla finale per il terzo posto).
-- Scriverlo esplicitamente costa due colonne e rende inutile
-- qualunque calcolo basato su convenzioni di numerazione, che e' il
-- genere di cosa che si rompe il giorno che si aggiunge un formato.
-- =========================================================

alter table public.torneo_incontri
  add column if not exists prossimo_incontro_id uuid references public.torneo_incontri(id) on delete set null;
alter table public.torneo_incontri
  add column if not exists prossimo_lato char(1) check (prossimo_lato in ('C', 'O'));

alter table public.torneo_incontri
  add column if not exists perdente_incontro_id uuid references public.torneo_incontri(id) on delete set null;
alter table public.torneo_incontri
  add column if not exists perdente_lato char(1) check (perdente_lato in ('C', 'O'));


-- =========================================================
-- PARTE 2 — I GIRONI SONO FINITI?
-- Il tabellone si genera solo quando ogni incontro di girone ha un
-- risultato: altrimenti le qualificate non sono ancora quelle.
-- =========================================================

create or replace function public.torneo_gironi_conclusi(p_torneo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from public.torneo_incontri
    where torneo_id = p_torneo_id and fase = 'girone' and sets is null
  ) and exists (
    select 1 from public.torneo_incontri
    where torneo_id = p_torneo_id and fase = 'girone'
  );
$$;

grant execute on function public.torneo_gironi_conclusi(uuid) to authenticated, anon;


-- =========================================================
-- PARTE 3 — GENERAZIONE DEL TABELLONE
--
-- COME SI ACCOPPIANO LE QUALIFICATE
-- Prima si mettono in fila per merito: tutte le prime dei gironi
-- (nell'ordine dei gironi), poi tutte le seconde, e cosi' via. Poi
-- si accoppia la prima con l'ultima, la seconda con la penultima —
-- il tabellone classico.
--
-- Con due gironi e due qualificate ciascuno l'ordine e'
-- A1, B1, A2, B2, e gli accoppiamenti diventano A1-B2 e B1-A2:
-- esattamente cio' che si vuole, cioe' due squadre dello stesso
-- girone che non si rincontrano subito. La stessa formula funziona
-- con quattro gironi e una qualificata, o con un girone solo e
-- quattro qualificate, senza casi particolari.
--
-- Per ora si accettano 2, 4 o 8 qualificate. I numeri intermedi
-- richiederebbero i turni di riposo, che sono la parte noiosa e
-- possono aspettare: un torneo di paese si organizza per avere un
-- tabellone pieno.
-- =========================================================

create or replace function public.torneo_genera_tabellone(p_torneo_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  torneo        public.tornei;
  n_gironi      int;
  qualificate   uuid[];
  totale        int;
  girone        record;
  pos_girone    int;   -- posizione dentro il girone, contata da 0
  indice_girone int := 0;
  riga          record;

  turni         text[];
  turno_nome    text;
  t             int;
  incontri_turno int;
  i             int;

  precedenti    uuid[];   -- gli incontri del turno appena creato
  correnti      uuid[];
  nuovo_id      uuid;
  finale_id     uuid;
  terzo_id      uuid;
  creati        int := 0;
begin
  select * into torneo from public.tornei where id = p_torneo_id;
  if torneo is null then
    raise exception 'Torneo inesistente';
  end if;

  if not public.puo_gestire_torneo(p_torneo_id) then
    raise exception 'Solo il circolo che organizza il torneo puo'' generarne il tabellone';
  end if;

  if torneo.formato <> 'gironi_e_finali' then
    raise exception 'Questo torneo e'' a soli gironi: non prevede fasi finali';
  end if;

  if not public.torneo_gironi_conclusi(p_torneo_id) then
    raise exception 'I gironi non sono ancora conclusi: mancano dei risultati';
  end if;

  if exists (
    select 1 from public.torneo_incontri
    where torneo_id = p_torneo_id and fase <> 'girone' and sets is not null
  ) then
    raise exception 'Ci sono gia'' risultati nelle fasi finali: il tabellone non si puo'' rigenerare';
  end if;

  delete from public.torneo_incontri where torneo_id = p_torneo_id and fase <> 'girone';

  select count(*) into n_gironi from public.tornei_gironi where torneo_id = p_torneo_id;
  totale := n_gironi * torneo.qualificate_per_girone;

  if totale not in (2, 4, 8) then
    raise exception 'Le qualificate devono essere 2, 4 o 8 (ora sarebbero %): cambia il numero di gironi o di qualificate per girone', totale;
  end if;

  -- In fila per merito: prima tutte le prime, poi tutte le seconde...
  qualificate := array_fill(null::uuid, array[totale]);

  for girone in
    select id from public.tornei_gironi where torneo_id = p_torneo_id order by ordine, nome
  loop
    pos_girone := 0;
    for riga in
      select squadra_id from public.classifica_girone(girone.id)
      order by classifica_girone.posizione limit torneo.qualificate_per_girone
    loop
      -- merito = (posizione nel girone) * numero di gironi + indice del girone
      qualificate[pos_girone * n_gironi + indice_girone + 1] := riga.squadra_id;
      pos_girone := pos_girone + 1;
    end loop;
    indice_girone := indice_girone + 1;
  end loop;

  if array_position(qualificate, null) is not null then
    raise exception 'Non ci sono abbastanza squadre qualificate: controlla che ogni girone abbia almeno % squadre', torneo.qualificate_per_girone;
  end if;

  -- I turni, dal piu' piccolo al piu' grande: si costruisce
  -- all'indietro, perche' ogni incontro deve conoscere la casella in
  -- cui mandare il vincitore, e quella casella deve esistere prima.
  turni := case totale
             when 2 then array['finale']
             when 4 then array['finale', 'semifinale']
             else array['finale', 'semifinale', 'quarti']
           end;

  precedenti := array[]::uuid[];

  for t in 1 .. array_length(turni, 1) loop
    turno_nome := turni[t];
    incontri_turno := power(2, t - 1)::int;
    correnti := array[]::uuid[];

    for i in 0 .. incontri_turno - 1 loop
      insert into public.torneo_incontri
        (torneo_id, fase, turno, ordine, prossimo_incontro_id, prossimo_lato)
      values (
        p_torneo_id,
        turno_nome,
        array_length(turni, 1) - t + 1,
        i,
        -- Due incontri confluiscono nello stesso incontro successivo:
        -- il primo entra come squadra di casa, il secondo come ospite.
        case when t = 1 then null else precedenti[(i / 2) + 1] end,
        case when t = 1 then null when i % 2 = 0 then 'C' else 'O' end
      )
      returning id into nuovo_id;

      correnti := correnti || nuovo_id;
      creati := creati + 1;

      if t = 1 then
        finale_id := nuovo_id;
      end if;
    end loop;

    precedenti := correnti;
  end loop;

  -- La finale per il terzo posto: la giocano i due perdenti delle
  -- semifinali, quindi esiste solo se le semifinali esistono.
  if torneo.finale_terzo_posto and totale >= 4 then
    insert into public.torneo_incontri (torneo_id, fase, turno, ordine)
    values (p_torneo_id, 'finale_3_4', 1, 1)
    returning id into terzo_id;

    creati := creati + 1;

    update public.torneo_incontri
    set perdente_incontro_id = terzo_id,
        perdente_lato = case when ordine = 0 then 'C' else 'O' end
    where torneo_id = p_torneo_id and fase = 'semifinale';
  end if;

  -- Il primo turno e' l'ultimo creato: ci si mettono le qualificate.
  -- precedenti contiene ora gli incontri del turno piu' numeroso.
  for i in 1 .. array_length(precedenti, 1) loop
    update public.torneo_incontri
    set squadra_casa   = qualificate[i],
        squadra_ospite = qualificate[totale - i + 1]
    where id = precedenti[i];
  end loop;

  return creati;
end;
$$;

grant execute on function public.torneo_genera_tabellone(uuid) to authenticated;


-- =========================================================
-- PARTE 4 — CHI VINCE AVANZA DA SOLO
--
-- Appena il risultato di un incontro a eliminazione viene inserito,
-- il vincitore compare nella casella del turno successivo. Se il
-- risultato viene annullato, la casella si svuota — ma solo se il
-- turno successivo non e' gia' stato giocato, altrimenti si
-- cancellerebbe una partita vera per correggerne un'altra.
-- =========================================================

create or replace function public.torneo_avanza_vincitore()
returns trigger
language plpgsql
as $$
declare
  vincente uuid;
  perdente uuid;
begin
  if new.prossimo_incontro_id is null and new.perdente_incontro_id is null then
    return null;
  end if;

  if new.vincitore is null then
    -- Risultato annullato: si svuotano le caselle a valle.
    if new.prossimo_incontro_id is not null then
      if exists (select 1 from public.torneo_incontri
                 where id = new.prossimo_incontro_id and sets is not null) then
        raise exception 'Il turno successivo e'' gia'' stato giocato: annulla prima quel risultato';
      end if;

      if new.prossimo_lato = 'C' then
        update public.torneo_incontri set squadra_casa = null where id = new.prossimo_incontro_id;
      else
        update public.torneo_incontri set squadra_ospite = null where id = new.prossimo_incontro_id;
      end if;
    end if;

    if new.perdente_incontro_id is not null then
      if new.perdente_lato = 'C' then
        update public.torneo_incontri set squadra_casa = null where id = new.perdente_incontro_id;
      else
        update public.torneo_incontri set squadra_ospite = null where id = new.perdente_incontro_id;
      end if;
    end if;

    return null;
  end if;

  vincente := case when new.vincitore = 'C' then new.squadra_casa else new.squadra_ospite end;
  perdente := case when new.vincitore = 'C' then new.squadra_ospite else new.squadra_casa end;

  if new.prossimo_incontro_id is not null then
    if new.prossimo_lato = 'C' then
      update public.torneo_incontri set squadra_casa = vincente where id = new.prossimo_incontro_id;
    else
      update public.torneo_incontri set squadra_ospite = vincente where id = new.prossimo_incontro_id;
    end if;
  end if;

  if new.perdente_incontro_id is not null then
    if new.perdente_lato = 'C' then
      update public.torneo_incontri set squadra_casa = perdente where id = new.perdente_incontro_id;
    else
      update public.torneo_incontri set squadra_ospite = perdente where id = new.perdente_incontro_id;
    end if;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_torneo_avanza on public.torneo_incontri;

create trigger trg_torneo_avanza
  after insert or update of sets on public.torneo_incontri
  for each row
  execute function public.torneo_avanza_vincitore();
