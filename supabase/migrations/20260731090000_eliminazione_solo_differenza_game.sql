-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.24
-- Nel girone a quattro partite decide solo la differenza game
--
-- Con l'aggiornamento n.23 i due formati di girone hanno gli stessi
-- criteri di parita', scontro diretto compreso. All'italiana e'
-- giusto: ogni coppia incontra tutte le altre, quindi lo scontro
-- diretto c'e' sempre ed e' il criterio piu' onesto che esista.
--
-- Nel girone a eliminazione no. Li' ogni coppia gioca due incontri su
-- tre possibili avversarie, e chi finisce a pari punti a volte si e'
-- incontrato e a volte no. Il risultato e' una classifica che cambia
-- regola da girone a girone: in uno decide la differenza game, in
-- quello accanto la ribalta lo scontro diretto. Chi la guarda non
-- riesce a ricavarne la regola, e una classifica che non si spiega
-- guardandola vale meno di una classifica severa.
--
-- Da qui in avanti:
--
--   girone a eliminazione (4 coppie, 4 incontri)
--     1. punti
--     2. differenza game
--     3. game fatti, poi il nome
--
--   girone all'italiana (tutti contro tutti)
--     1. punti
--     2. scontro diretto (classifica ridotta fra chi e' in parita')
--     3. differenza set e differenza game della ridotta
--     4. differenza set e differenza game totali
--     5. game fatti, poi il nome
--
-- Una regola sola per formula, valida per tutti i gironi di quella
-- formula: e' l'unico modo perche' la classifica si spieghi da sola
-- a bordo campo.
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
    select t.formato_girone = 'eliminazione_4' as a_eliminazione
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
  -- La classifica ridotta: solo gli incontri fra squadre a pari punti.
  -- Serve all'italiana; nel girone a eliminazione non viene guardata.
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
           f.a_eliminazione,
           coalesce(m.punti, 0)     as m_punti,
           coalesce(m.diff_set, 0)  as m_diff_set,
           coalesce(m.diff_game, 0) as m_diff_game
    from totali t
    cross join formula f
    left join ridotta m on m.sq = t.id
  ),
  -- Nel girone a eliminazione i criteri intermedi vengono azzerati:
  -- restano punti, differenza game, game fatti.
  numerata as (
    select
      (row_number() over (
         order by punti desc,
                  (case when a_eliminazione then 0 else m_punti end)     desc,
                  (case when a_eliminazione then 0 else m_diff_set end)  desc,
                  (case when a_eliminazione then 0 else m_diff_game end) desc,
                  (case when a_eliminazione then 0 else sv - sp end)     desc,
                  (gf - gs) desc, gf desc, nome
       ))::int as pos,
      id, nome, partite, vittorie, sconfitte, punti, sv, sp, gf, gs
    from ordinata
  )
  select pos, id, nome, partite, vittorie, sconfitte, punti, sv, sp, gf, gs
  from numerata
  order by pos;
$$;

grant execute on function public.classifica_girone(uuid) to authenticated, anon;
