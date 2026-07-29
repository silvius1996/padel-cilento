-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.22  (GIRONI A ELIMINAZIONE)
--
-- Finora un girone era sempre all'italiana: tutti contro tutti. Con
-- quattro coppie sono sei incontri, e sei incontri su un campo solo
-- sono tre ore. Il torneo di paese si organizza al contrario: si
-- parte dalle ore di campo disponibili e si decide la formula.
--
-- La formula che i circoli usano davvero, con quattro coppie e due
-- ore, e' un piccolo tabellone dentro il girone:
--
--     A vs B                  \__ vincente A-B  vs  vincente C-D   (1a e 2a)
--     C vs D                  /__ perdente A-B  vs  perdente C-D   (3a e 4a)
--
-- Quattro incontri invece di sei, e ogni coppia ne gioca due. In
-- piu' la classifica non ha bisogno di criteri di parita': le
-- posizioni le dicono i due incontri decisivi, non la differenza
-- game. Chi passa il turno non si discute.
--
-- Il meccanismo per portare avanti vincente e perdente esiste gia':
-- e' quello del tabellone finale (aggiornamento n.16), fatto di
-- "prossimo_incontro_id" e "perdente_incontro_id". Qui viene
-- riusato tale e quale dentro il girone — il trigger che fa avanzare
-- le squadre non distingue le fasi, quindi non va toccato.
-- =========================================================


-- ---------------------------------------------------------
-- 1. LA FORMULA, DETTA DAL TORNEO
-- All'italiana resta il default: i tornei che esistono gia' non
-- cambiano di una virgola.
-- ---------------------------------------------------------
alter table public.tornei
  add column if not exists formato_girone text not null default 'all_italiana';

alter table public.tornei
  drop constraint if exists tornei_formato_girone_check;

alter table public.tornei
  add constraint tornei_formato_girone_check
  check (formato_girone in ('all_italiana', 'eliminazione_4'));


-- ---------------------------------------------------------
-- 2. NEMMENO LA FORMULA SI CAMBIA A TORNEO INIZIATO
-- Stessa ragione del formato di punteggio: cambiarla vorrebbe dire
-- rigenerare il calendario, e il calendario non si rigenera quando
-- ci sono gia' dei risultati.
-- ---------------------------------------------------------
create or replace function public.blocca_cambio_formato_punteggio()
returns trigger
language plpgsql
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if (new.formato_punteggio is distinct from old.formato_punteggio
      or new.formato_punteggio_finali is distinct from old.formato_punteggio_finali
      or new.formato_girone is distinct from old.formato_girone)
     and public.torneo_ha_risultati(old.id) then
    raise exception 'In questo torneo si e'' gia'' giocato: la formula non si cambia piu''.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_blocca_cambio_formato on public.tornei;

create trigger trg_blocca_cambio_formato
  before update of formato_punteggio, formato_punteggio_finali, formato_girone
  on public.tornei
  for each row
  execute function public.blocca_cambio_formato_punteggio();


-- =========================================================
-- 3. IL CALENDARIO, NELLE DUE FORMULE
--
-- La parte all'italiana e' identica all'aggiornamento n.15: stesso
-- metodo del girone a rotazione, stessi turni. Cambia solo che ora
-- c'e' un bivio prima.
-- =========================================================

create or replace function public.torneo_genera_calendario(p_torneo_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  torneo       public.tornei;
  girone       record;
  squadre      uuid[];
  n            int;    -- squadre vere
  m            int;    -- squadre arrotondate a pari (con il "riposo")
  r            int;    -- turno, contato da 0
  i            int;    -- posizione nell'accoppiamento del turno
  idx_casa     int;
  idx_ospite   int;
  id_casa      uuid;
  id_ospite    uuid;
  creati       int := 0;
  progressivo  int;
  id_finale    uuid;   -- vincente A-B vs vincente C-D
  id_finalina  uuid;   -- perdente A-B vs perdente C-D
begin
  select * into torneo from public.tornei where id = p_torneo_id;
  if torneo is null then
    raise exception 'Torneo inesistente';
  end if;

  if not public.puo_gestire_torneo(p_torneo_id) then
    raise exception 'Solo il circolo che organizza il torneo puo'' generarne il calendario';
  end if;

  -- Rigenerare significa ripartire da zero: si cancellano gli
  -- incontri di girone precedenti. Quelli con un risultato gia'
  -- inserito no, altrimenti si perderebbe il lavoro fatto.
  if exists (
    select 1 from public.torneo_incontri
    where torneo_id = p_torneo_id and fase = 'girone' and sets is not null
  ) then
    raise exception 'Ci sono gia'' risultati inseriti: il calendario non si puo'' rigenerare';
  end if;

  delete from public.torneo_incontri
  where torneo_id = p_torneo_id and fase = 'girone';

  for girone in
    select id, nome from public.tornei_gironi where torneo_id = p_torneo_id order by ordine, nome
  loop
    select array_agg(s.id order by s.created_at, s.id)
    into squadre
    from public.torneo_squadre s
    where s.girone_id = girone.id and s.stato = 'iscritta';

    n := coalesce(array_length(squadre, 1), 0);
    if n < 2 then
      continue;   -- un girone con una squadra sola non ha incontri
    end if;

    -- ---------------------------------------------------
    -- FORMULA A ELIMINAZIONE: quattro coppie, quattro incontri
    --
    -- I due incontri decisivi si creano PRIMA di quelli del primo
    -- turno: ogni incontro deve conoscere la casella in cui mandare
    -- il proprio vincitore, e quella casella deve gia' esistere.
    -- E' lo stesso ordine di costruzione del tabellone finale.
    -- ---------------------------------------------------
    if torneo.formato_girone = 'eliminazione_4' then
      if n <> 4 then
        raise exception
          'Il girone "%" ha % coppie: la formula a eliminazione ne richiede esattamente 4',
          girone.nome, n;
      end if;

      insert into public.torneo_incontri
        (torneo_id, girone_id, fase, turno, ordine)
      values (p_torneo_id, girone.id, 'girone', 2, 0)
      returning id into id_finale;

      insert into public.torneo_incontri
        (torneo_id, girone_id, fase, turno, ordine)
      values (p_torneo_id, girone.id, 'girone', 2, 1)
      returning id into id_finalina;

      insert into public.torneo_incontri
        (torneo_id, girone_id, fase, turno, ordine, squadra_casa, squadra_ospite,
         prossimo_incontro_id, prossimo_lato, perdente_incontro_id, perdente_lato)
      values
        (p_torneo_id, girone.id, 'girone', 1, 0, squadre[1], squadre[2],
         id_finale, 'C', id_finalina, 'C'),
        (p_torneo_id, girone.id, 'girone', 1, 1, squadre[3], squadre[4],
         id_finale, 'O', id_finalina, 'O');

      creati := creati + 4;
      continue;
    end if;

    -- ---------------------------------------------------
    -- FORMULA ALL'ITALIANA: tutti contro tutti, una volta sola
    -- ---------------------------------------------------

    -- Con un numero dispari si aggiunge un posto vuoto: chi ci
    -- capita contro, quel turno riposa.
    m := case when n % 2 = 1 then n + 1 else n end;

    for r in 0 .. m - 2 loop
      progressivo := 0;

      for i in 0 .. (m / 2) - 1 loop
        -- Una squadra resta ferma e le altre ruotano intorno: e' il
        -- metodo classico, e garantisce che ogni coppia si incontri
        -- una volta sola.
        if i = 0 then
          idx_casa   := m - 1;
          idx_ospite := r % (m - 1);
        else
          idx_casa   := (r + i) % (m - 1);
          idx_ospite := (r - i + (m - 1)) % (m - 1);
        end if;

        -- Gli indici oltre il numero di squadre vere sono il posto
        -- vuoto: quell'accoppiamento e' il turno di riposo.
        if idx_casa >= n or idx_ospite >= n then
          continue;
        end if;

        id_casa   := squadre[idx_casa + 1];    -- gli array partono da 1
        id_ospite := squadre[idx_ospite + 1];

        insert into public.torneo_incontri
          (torneo_id, girone_id, fase, turno, ordine, squadra_casa, squadra_ospite)
        values
          (p_torneo_id, girone.id, 'girone', r + 1, progressivo, id_casa, id_ospite);

        progressivo := progressivo + 1;
        creati := creati + 1;
      end loop;
    end loop;
  end loop;

  return creati;
end;
$$;

grant execute on function public.torneo_genera_calendario(uuid) to authenticated;


-- =========================================================
-- 4. LA CLASSIFICA, NELLE DUE FORMULE
--
-- All'italiana l'ordine e' quello dell'aggiornamento n.15, criteri
-- di parita' compresi: li' la classifica E' il risultato del girone.
--
-- A eliminazione no: la classifica non decide niente, la registra.
-- Chi vince la finale del girone e' primo, chi la perde secondo, e
-- lo stesso sotto con la finale di consolazione. Ordinare per punti
-- darebbe seconda e terza a pari merito (una vittoria a testa) e
-- toccherebbe alla differenza game separare due coppie che non si
-- sono mai incontrate: esattamente la discussione che questa
-- formula serve a evitare.
--
-- I numeri di vittorie, set e game restano calcolati come prima:
-- servono comunque a leggere il girone, non piu' a ordinarlo.
-- =========================================================

create or replace function public.classifica_girone(p_girone_id uuid)
returns table (
  posizione    int,
  squadra_id   uuid,
  nome         text,
  partite      int,
  vittorie     int,
  sconfitte    int,
  punti        int,
  set_vinti    int,
  set_persi    int,
  game_fatti   int,
  game_subiti  int
)
language sql
stable
security definer
set search_path = public
as $$
  with formula as (
    select t.formato_girone
    from public.tornei_gironi g
    join public.tornei t on t.id = g.torneo_id
    where g.id = p_girone_id
  ),
  squadre as (
    select s.id,
           coalesce(nullif(trim(s.nome), ''),
                    trim(s.giocatore_1) || ' / ' || trim(s.giocatore_2)) as nome
    from public.torneo_squadre s
    where s.girone_id = p_girone_id and s.stato = 'iscritta'
  ),
  giocati as (
    select i.squadra_casa, i.squadra_ospite, i.vincitore, c.*
    from public.torneo_incontri i
    cross join lateral public.conteggi_punteggio(i.sets) c
    where i.girone_id = p_girone_id and i.sets is not null
  ),
  -- Ogni incontro diventa due righe, una per squadra, viste dal suo lato
  righe as (
    select squadra_casa as sq, squadra_ospite as avversaria,
           (vincitore = 'C') as vinta,
           set_a as sv, set_b as sp, game_a as gf, game_b as gs
    from giocati
    union all
    select squadra_ospite, squadra_casa,
           (vincitore = 'O'),
           set_b, set_a, game_b, game_a
    from giocati
  ),
  base as (
    select sq,
           count(*)::int                                as partite,
           count(*) filter (where vinta)::int           as vittorie,
           count(*) filter (where not vinta)::int       as sconfitte,
           (count(*) filter (where vinta) * 3)::int     as punti,
           sum(sv)::int as sv, sum(sp)::int as sp,
           sum(gf)::int as gf, sum(gs)::int as gs
    from righe group by sq
  ),
  -- Il totale di ogni squadra, comprese quelle che non hanno ancora giocato
  totali as (
    select s.id, s.nome,
           coalesce(b.partite, 0) as partite, coalesce(b.vittorie, 0) as vittorie,
           coalesce(b.sconfitte, 0) as sconfitte, coalesce(b.punti, 0) as punti,
           coalesce(b.sv, 0) as sv, coalesce(b.sp, 0) as sp,
           coalesce(b.gf, 0) as gf, coalesce(b.gs, 0) as gs
    from squadre s left join base b on b.sq = s.id
  ),
  -- La classifica ridotta: solo gli incontri fra squadre a pari punti
  ridotta as (
    select r.sq,
           (count(*) filter (where r.vinta) * 3)::int as punti,
           (sum(r.sv) - sum(r.sp))::int               as diff_set,
           (sum(r.gf) - sum(r.gs))::int               as diff_game
    from righe r
    join totali t1 on t1.id = r.sq
    join totali t2 on t2.id = r.avversaria
    where t1.punti = t2.punti
    group by r.sq
  ),
  -- I due incontri del secondo turno, nella formula a eliminazione:
  -- il primo (ordine 0) assegna il 1o e il 2o posto, il secondo
  -- (ordine 1) il 3o e il 4o. Finche' non si giocano, la posizione
  -- resta indefinita e vale l'ordine per punti.
  piazzamenti as (
    select case when i.vincitore = 'C' then i.squadra_casa else i.squadra_ospite end as sq,
           (case when i.ordine = 0 then 1 else 3 end)::int as posto
    from public.torneo_incontri i
    cross join formula f
    where f.formato_girone = 'eliminazione_4'
      and i.girone_id = p_girone_id and i.fase = 'girone'
      and i.turno = 2 and i.vincitore is not null
    union all
    select case when i.vincitore = 'C' then i.squadra_ospite else i.squadra_casa end,
           (case when i.ordine = 0 then 2 else 4 end)::int
    from public.torneo_incontri i
    cross join formula f
    where f.formato_girone = 'eliminazione_4'
      and i.girone_id = p_girone_id and i.fase = 'girone'
      and i.turno = 2 and i.vincitore is not null
  ),
  ordinata as (
    select t.*,
           coalesce(m.punti, 0)     as m_punti,
           coalesce(m.diff_set, 0)  as m_diff_set,
           coalesce(m.diff_game, 0) as m_diff_game,
           coalesce(p.posto, 99)    as posto
    from totali t
    left join ridotta m on m.sq = t.id
    left join piazzamenti p on p.sq = t.id
  ),
  numerata as (
    select
      (row_number() over (
         order by posto,
                  punti desc, m_punti desc, m_diff_set desc, m_diff_game desc,
                  (sv - sp) desc, (gf - gs) desc, gf desc, nome
       ))::int as pos,
      id, nome, partite, vittorie, sconfitte, punti, sv, sp, gf, gs
    from ordinata
  )
  select pos, id, nome, partite, vittorie, sconfitte, punti, sv, sp, gf, gs
  from numerata
  order by pos;
$$;

grant execute on function public.classifica_girone(uuid) to authenticated, anon;
