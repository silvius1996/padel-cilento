-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.29
-- Quando i numeri finiscono, decide lo spareggio
--
-- PERCHE' ADESSO
--
-- Il girone da tre a set unico ha un caso che gli altri non hanno.
-- Se ognuna vince una partita, tutte e tre stanno a tre punti; lo
-- scontro diretto non separa niente, perche' la classifica ridotta
-- fra le tre e' la classifica del girone; la differenza set e' zero
-- per tutte, visto che a set unico chi vince ne prende uno e chi
-- perde nessuno. Resta la differenza game, poi i game fatti. Se anche
-- quelli sono pari, oggi decide l'ordine alfabetico del nome — e non
-- lo dice a nessuno.
--
-- Un torneo vero non finisce cosi': il circolo fa giocare uno
-- spareggio e stabilisce chi passa. Questo aggiornamento gli da' il
-- posto dove scriverlo.
--
-- DOVE SI INFILA
--
-- Come ULTIMO criterio, subito prima del nome. Non e' un dettaglio di
-- ordine: significa che una posizione assegnata a mano non ribalta
-- mai un risultato del campo. Finche' punti, scontro diretto, set,
-- differenza game e game fatti dicono qualcosa, comandano loro. Il
-- circolo entra solo dove prima entrava l'alfabeto.
--
-- Ne segue che la colonna si puo' anche compilare per sbaglio senza
-- fare danni: se le squadre non sono in parita' totale, non viene
-- nemmeno guardata.
-- =========================================================


-- ---------------------------------------------------------
-- 1. LA COLONNA
-- Vuota per tutte, sempre: e' l'eccezione, non la regola. Il numero
-- e' la posizione che il circolo assegna nel girone (1 = passa).
-- ---------------------------------------------------------
alter table public.torneo_squadre
  add column if not exists spareggio int;

alter table public.torneo_squadre
  drop constraint if exists torneo_squadre_spareggio_check;

alter table public.torneo_squadre
  add constraint torneo_squadre_spareggio_check
  check (spareggio is null or spareggio > 0);

-- Due coppie dello stesso girone non possono essere entrambe prime
-- dopo lo spareggio: sarebbe di nuovo una parita', cioe' il problema
-- che questa colonna serve a chiudere.
create unique index if not exists idx_torneo_squadre_spareggio
  on public.torneo_squadre (girone_id, spareggio)
  where spareggio is not null;


-- =========================================================
-- 2. LA CLASSIFICA
--
-- Rispetto all'aggiornamento n.24 cambiano due cose sole: la colonna
-- "spareggio" esce insieme al resto, cosi' chi legge la classifica
-- vede da dove viene quella posizione, e l'ordinamento la guarda per
-- ultimo. Tutti gli altri criteri sono identici, nelle due formule.
--
-- La funzione va cancellata e riscritta invece che sostituita: le
-- colonne restituite cambiano, e "create or replace" non lo permette.
-- =========================================================

drop function if exists public.classifica_girone(uuid);

create function public.classifica_girone(p_girone_id uuid)
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
  game_subiti  int,
  spareggio    int
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
                    trim(s.giocatore_1) || ' / ' || trim(s.giocatore_2)) as nome,
           s.spareggio
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
    select s.id, s.nome, s.spareggio,
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
  -- restano punti, differenza game, game fatti. Lo spareggio invece
  -- vale in tutte e due le formule: e' l'ultima parola, e arriva
  -- quando i numeri non ne hanno piu'.
  numerata as (
    select
      (row_number() over (
         order by punti desc,
                  (case when a_eliminazione then 0 else m_punti end)     desc,
                  (case when a_eliminazione then 0 else m_diff_set end)  desc,
                  (case when a_eliminazione then 0 else m_diff_game end) desc,
                  (case when a_eliminazione then 0 else sv - sp end)     desc,
                  (gf - gs) desc, gf desc,
                  spareggio asc nulls last,
                  nome
       ))::int as pos,
      id, nome, partite, vittorie, sconfitte, punti, sv, sp, gf, gs, spareggio
    from ordinata
  )
  select pos, id, nome, partite, vittorie, sconfitte, punti, sv, sp, gf, gs, spareggio
  from numerata
  order by pos;
$$;

grant execute on function public.classifica_girone(uuid) to authenticated, anon;
