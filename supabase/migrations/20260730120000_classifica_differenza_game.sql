-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.23
-- La differenza game vale in tutti e due i formati di girone
--
-- Con l'aggiornamento n.22 il girone a eliminazione ordinava la
-- classifica sul tabellone: chi perdeva la finale era secondo, chi
-- vinceva la finale di consolazione terzo. Sulla carta ha una sua
-- logica; sul campo no. Chi perde 3-6 con la prima e vince 6-0
-- l'altro incontro si vede messo dietro a chi ha perso allo stesso
-- modo e ha vinto 6-1: stessi punti, differenza game peggiore,
-- posizione migliore. E' la prima cosa che si nota guardando la
-- classifica, e non c'e' modo di spiegarla a bordo campo.
--
-- Da qui in avanti la regola e' una sola, per tutti e due i formati:
--
--   1. punti
--   2. scontro diretto (la classifica ridotta fra le squadre in parita')
--   3. differenza set nella classifica ridotta
--   4. differenza game nella classifica ridotta
--   5. differenza set totale
--   6. differenza game totale
--   7. game fatti, poi il nome
--
-- Nel girone a eliminazione le due coppie a pari punti spesso non si
-- sono mai incontrate: la classifica ridotta e' vuota, i criteri 2-4
-- non dicono niente e decide la differenza game. Che e' esattamente
-- quello che chiede chi guarda i risultati. Nei tornei a set unico i
-- criteri sui set non separano nessuno (un set vinto vale una
-- vittoria, gia' contata nei punti): li' si arriva sempre ai game.
--
-- Il tabellone del girone non sparisce: i due incontri decisivi
-- restano il modo in cui si gioca. Semplicemente non scavalcano piu'
-- i numeri quando l'ordine e' in discussione.
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
  with squadre as (
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
  ordinata as (
    select t.*,
           coalesce(m.punti, 0)     as m_punti,
           coalesce(m.diff_set, 0)  as m_diff_set,
           coalesce(m.diff_game, 0) as m_diff_game
    from totali t
    left join ridotta m on m.sq = t.id
  ),
  numerata as (
    select
      (row_number() over (
         order by punti desc, m_punti desc, m_diff_set desc, m_diff_game desc,
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
