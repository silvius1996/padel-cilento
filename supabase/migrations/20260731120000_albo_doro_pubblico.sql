-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.25
-- L'albo d'oro, visibile a tutti
--
-- Con l'aggiornamento n.17 chi vince un torneo si porta una medaglia
-- sul profilo. Il difetto e' che quella medaglia la vede solo lui:
-- "bacheca_giocatore" parte da auth.uid(), quindi e' una vetrina
-- privata. Chi apre l'elenco dei tornei vede solo il cartellino
-- CONCLUSO, e per sapere chi ha vinto deve entrare nel torneo e
-- leggersi il tabellone.
--
-- Un torneo di paese e' esattamente il contrario: si vince davanti a
-- tutti. Questa funzione tira fuori i podi di piu' tornei in una
-- chiamata sola, cosi' l'elenco puo' scrivere il vincitore sotto il
-- nome di ogni torneo concluso senza fare una domanda al database per
-- ciascuno.
--
-- Non nasce nessuna tabella: il podio resta calcolato da
-- "albo_torneo", che a sua volta lo legge dal tabellone. Si corregge
-- il risultato di una finale e l'albo cambia da solo, come la
-- bacheca. E' la stessa scelta di sempre, e per lo stesso motivo.
--
-- I nomi delle coppie sono gia' pubblici (i tornei si leggono anche
-- senza account), quindi qui non si scopre niente di nuovo: si mette
-- in prima pagina quello che era gia' visibile in fondo al tabellone.
-- =========================================================

create or replace function public.albo_tornei(p_limite int default 20)
returns table (
  torneo_id  uuid,
  torneo     text,
  circolo    text,
  data       date,
  posizione  int,
  squadra_id uuid,
  squadra    text
)
language sql
stable
security definer
set search_path = public
as $$
  with ultimi as (
    select t.id, t.nome, c.nome as circolo,
           coalesce(t.data_fine, t.data_inizio) as data,
           t.created_at
    from public.tornei t
    join public.circoli c on c.id = t.circolo_id
    -- Solo i tornei conclusi: finche' si gioca il podio puo' cambiare,
    -- e un albo d'oro che cambia non e' un albo d'oro.
    where t.stato = 'concluso'
    order by coalesce(t.data_fine, t.data_inizio) desc nulls last, t.created_at desc
    limit greatest(coalesce(p_limite, 20), 1)
  )
  select u.id, u.nome, u.circolo, u.data,
         a.posizione, a.squadra_id,
         coalesce(nullif(trim(s.nome), ''),
                  trim(s.giocatore_1) || ' / ' || trim(s.giocatore_2))
  from ultimi u
  cross join lateral public.albo_torneo(u.id) a
  join public.torneo_squadre s on s.id = a.squadra_id
  order by u.data desc nulls last, u.created_at desc, a.posizione;
$$;

grant execute on function public.albo_tornei(int) to authenticated, anon;
