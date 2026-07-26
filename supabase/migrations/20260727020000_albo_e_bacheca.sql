-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.17
-- L'albo d'oro dei tornei e la bacheca sul profilo
--
-- Chi vince un torneo si porta a casa una medaglia, visibile sul
-- proprio profilo. Vale per chi e' collegato a un account: le coppie
-- iscritte a nome e cognome senza account restano nell'albo del
-- torneo, ma non hanno un profilo su cui comparire.
--
-- LA MEDAGLIA NON VIENE SALVATA
-- Nessuna tabella "premi", nessun contatore. Il podio si ricava dal
-- tabellone ogni volta che serve, come le statistiche e le
-- classifiche. Il motivo e' sempre lo stesso: un premio salvato a
-- parte, il giorno che si corregge il risultato di una finale,
-- resterebbe appeso al profilo sbagliato.
-- =========================================================


-- =========================================================
-- PARTE 1 — IL PODIO DI UN TORNEO
--
-- Primo e secondo escono dalla finale, il terzo dalla finalina se
-- c'e' stata. Nei tornei a soli gironi la finale non esiste: se il
-- girone e' uno solo, il podio e' quello della sua classifica; se
-- sono piu' di uno, non c'e' un vincitore unico e l'albo resta
-- vuoto — sarebbe inventarsi un confronto fra gironi diversi.
-- =========================================================

create or replace function public.albo_torneo(p_torneo_id uuid)
returns table (posizione int, squadra_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  torneo  public.tornei;
  finale  public.torneo_incontri;
  terzo   public.torneo_incontri;
  n_gironi int;
  unico_girone uuid;
begin
  select * into torneo from public.tornei where id = p_torneo_id;
  if torneo is null or torneo.stato = 'annullato' then
    return;
  end if;

  select * into finale
  from public.torneo_incontri
  where torneo_id = p_torneo_id and fase = 'finale' and vincitore is not null
  limit 1;

  if finale.id is not null then
    posizione := 1;
    squadra_id := case when finale.vincitore = 'C' then finale.squadra_casa else finale.squadra_ospite end;
    return next;

    posizione := 2;
    squadra_id := case when finale.vincitore = 'C' then finale.squadra_ospite else finale.squadra_casa end;
    return next;

    select * into terzo
    from public.torneo_incontri
    where torneo_id = p_torneo_id and fase = 'finale_3_4' and vincitore is not null
    limit 1;

    if terzo.id is not null then
      posizione := 3;
      squadra_id := case when terzo.vincitore = 'C' then terzo.squadra_casa else terzo.squadra_ospite end;
      return next;
    end if;

    return;
  end if;

  -- Nessuna finale: vale solo il torneo a girone unico, e solo da
  -- concluso. Prima della fine la classifica cambia ancora.
  if torneo.stato <> 'concluso' then
    return;
  end if;

  select count(*), min(id) into n_gironi, unico_girone
  from public.tornei_gironi where torneo_id = p_torneo_id;

  if n_gironi <> 1 then
    return;
  end if;

  return query
  select c.posizione, c.squadra_id
  from public.classifica_girone(unico_girone) c
  where c.posizione <= 3 and c.partite > 0;
end;
$$;

grant execute on function public.albo_torneo(uuid) to authenticated, anon;


-- =========================================================
-- PARTE 2 — LA BACHECA DI UN GIOCATORE
-- I tornei in cui e' salito sul podio, dal piu' recente.
-- =========================================================

create or replace function public.bacheca_giocatore(p_user_id uuid default null)
returns table (
  torneo_id  uuid,
  torneo     text,
  circolo    text,
  data       date,
  posizione  int,
  squadra    text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.id,
    t.nome,
    c.nome,
    coalesce(t.data_fine, t.data_inizio),
    a.posizione,
    coalesce(nullif(trim(s.nome), ''),
             trim(s.giocatore_1) || ' / ' || trim(s.giocatore_2))
  from public.tornei t
  join public.circoli c on c.id = t.circolo_id
  cross join lateral public.albo_torneo(t.id) a
  join public.torneo_squadre s on s.id = a.squadra_id
  where t.stato <> 'annullato'
    and coalesce(p_user_id, auth.uid()) in (s.user_id_1, s.user_id_2)
  order by coalesce(t.data_fine, t.data_inizio) desc nulls last, t.created_at desc;
$$;

grant execute on function public.bacheca_giocatore(uuid) to authenticated;
