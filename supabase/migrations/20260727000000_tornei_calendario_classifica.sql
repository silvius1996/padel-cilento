-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.15
-- Calendario dei gironi, risultati, classifica
-- =========================================================


-- =========================================================
-- PARTE 1 — LEGGERE UN PUNTEGGIO
-- Da  [[6,4],[3,6],[7,5]]  servono quattro numeri: set e game di
-- ognuna delle due squadre. Servono alla classifica, dove i criteri
-- di parita' si decidono a differenza set e differenza game.
-- =========================================================

create or replace function public.conteggi_punteggio(p_sets jsonb)
returns table (set_a int, set_b int, game_a int, game_b int)
language sql
immutable
as $$
  select
    coalesce(sum(case when (s ->> 0)::int > (s ->> 1)::int then 1 else 0 end), 0)::int,
    coalesce(sum(case when (s ->> 1)::int > (s ->> 0)::int then 1 else 0 end), 0)::int,
    coalesce(sum((s ->> 0)::int), 0)::int,
    coalesce(sum((s ->> 1)::int), 0)::int
  from jsonb_array_elements(coalesce(p_sets, '[]'::jsonb)) as s;
$$;

grant execute on function public.conteggi_punteggio(jsonb) to authenticated, anon;


-- =========================================================
-- PARTE 2 — IL CALENDARIO DEI GIRONI
--
-- Dentro ogni girone giocano tutti contro tutti, una volta sola.
-- Gli incontri non vengono messi in fila a caso: si usa il metodo
-- del girone all'italiana, quello con cui in ogni TURNO ciascuna
-- squadra gioca al massimo una volta. Con un numero dispari di
-- squadre, a ogni turno una riposa.
--
-- Serve perche' il calendario venga letto come "giornate": tutti
-- giocano la prima, poi tutti la seconda. Mettere gli incontri in
-- ordine qualsiasi vorrebbe dire far giocare la stessa coppia tre
-- volte di fila mentre un'altra aspetta.
--
-- Data e ora restano vuote: quello che conta e' l'ordine, il campo
-- si assegna quando si libera.
-- =========================================================

create or replace function public.torneo_genera_calendario(p_torneo_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
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
begin
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
    select id from public.tornei_gironi where torneo_id = p_torneo_id order by ordine, nome
  loop
    select array_agg(s.id order by s.created_at, s.id)
    into squadre
    from public.torneo_squadre s
    where s.girone_id = girone.id and s.stato = 'iscritta';

    n := coalesce(array_length(squadre, 1), 0);
    if n < 2 then
      continue;   -- un girone con una squadra sola non ha incontri
    end if;

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
-- PARTE 3 — I RISULTATI
-- Li inserisce il circolo. Non c'e' conferma dell'avversario ne'
-- contestazione: nel torneo l'autorita' c'e', ed e' chi organizza.
-- Il vincitore lo calcola comunque il database dal punteggio
-- (trigger dell'aggiornamento n.14), non lo dichiara l'app.
-- =========================================================

create or replace function public.torneo_registra_risultato(p_incontro_id uuid, p_sets jsonb)
returns public.torneo_incontri
language plpgsql
security definer
set search_path = public
as $$
declare
  incontro public.torneo_incontri;
  torneo   public.tornei;
begin
  select * into incontro from public.torneo_incontri where id = p_incontro_id;
  if incontro is null then
    raise exception 'Incontro inesistente';
  end if;

  if not public.puo_gestire_torneo(incontro.torneo_id) then
    raise exception 'Solo il circolo che organizza il torneo puo'' inserire i risultati';
  end if;

  select * into torneo from public.tornei where id = incontro.torneo_id;
  if torneo.stato <> 'in_corso' then
    raise exception 'I risultati si inseriscono a torneo avviato (stato attuale: %)', torneo.stato;
  end if;

  if incontro.squadra_casa is null or incontro.squadra_ospite is null then
    raise exception 'Questo incontro non ha ancora entrambe le squadre';
  end if;

  -- valida_punteggio() rifiuta i punteggi impossibili e il trigger
  -- ricava il vincitore: qui non si decide niente a mano.
  update public.torneo_incontri
  set sets = p_sets,
      registrato_da = auth.uid(),
      registrato_il = now()
  where id = p_incontro_id
  returning * into incontro;

  return incontro;
end;
$$;

grant execute on function public.torneo_registra_risultato(uuid, jsonb) to authenticated;


create or replace function public.torneo_annulla_risultato(p_incontro_id uuid)
returns public.torneo_incontri
language plpgsql
security definer
set search_path = public
as $$
declare
  incontro public.torneo_incontri;
begin
  select * into incontro from public.torneo_incontri where id = p_incontro_id;
  if incontro is null then
    raise exception 'Incontro inesistente';
  end if;

  if not public.puo_gestire_torneo(incontro.torneo_id) then
    raise exception 'Solo il circolo che organizza il torneo puo'' annullare un risultato';
  end if;

  update public.torneo_incontri
  set sets = null,
      registrato_da = null
  where id = p_incontro_id
  returning * into incontro;

  return incontro;
end;
$$;

grant execute on function public.torneo_annulla_risultato(uuid) to authenticated;


-- =========================================================
-- PARTE 4 — LA CLASSIFICA DEL GIRONE
--
-- Ricalcolata dai risultati a ogni lettura, mai salvata: e' la
-- stessa regola delle statistiche personali, e per lo stesso motivo.
--
-- 3 punti a vittoria, 0 a sconfitta. Nel padel il pareggio non
-- esiste, quindi ordinare per punti equivale a ordinare per
-- vittorie: a decidere le posizioni sono quasi sempre i criteri di
-- parita', ed e' li' che si litiga.
--
-- LO SCONTRO DIRETTO, ANCHE A TRE
-- Il criterio "chi ha vinto lo scontro diretto" funziona con due
-- squadre. Con tre o piu' a pari punti non significa niente: A
-- batte B, B batte C, C batte A.
-- La soluzione e' una classifica ridotta fra le sole squadre in
-- parita', contando solo le partite giocate FRA LORO. Con due
-- squadre quella classifica ridotta E' lo scontro diretto — quindi
-- un solo meccanismo copre entrambi i casi, e non serve trattarli
-- separatamente.
--
-- Ordine completo:
--   1. punti
--   2. punti nella classifica ridotta fra le squadre a pari punti
--   3. differenza set nella classifica ridotta
--   4. differenza game nella classifica ridotta
--   5. differenza set totale
--   6. differenza game totale
--   7. game fatti
--   8. nome, per non avere un ordine casuale a parita' assoluta
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
    from totali t left join ridotta m on m.sq = t.id
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


-- =========================================================
-- PARTE 5 — GLI STATI DEL TORNEO
--
-- Il passaggio da uno stato all'altro non e' un campo che l'app
-- aggiorna: e' una funzione che verifica se ha senso. Altrimenti si
-- finisce con tornei "in corso" senza calendario, e nessuno capisce
-- piu' cosa sta succedendo.
-- =========================================================

create or replace function public.torneo_cambia_stato(p_torneo_id uuid, p_nuovo_stato text)
returns public.tornei
language plpgsql
security definer
set search_path = public
as $$
declare
  torneo    public.tornei;
  senza_girone int;
  incontri  int;
begin
  select * into torneo from public.tornei where id = p_torneo_id;
  if torneo is null then
    raise exception 'Torneo inesistente';
  end if;

  if not public.puo_gestire_torneo(p_torneo_id) then
    raise exception 'Solo il circolo che organizza il torneo puo'' cambiarne lo stato';
  end if;

  if p_nuovo_stato = torneo.stato then
    return torneo;
  end if;

  -- Annullare si puo' sempre: e' la valvola di sicurezza quando un
  -- torneo salta per pioggia o per iscrizioni insufficienti.
  if p_nuovo_stato = 'annullato' then
    null;

  elsif p_nuovo_stato = 'iscrizioni' then
    if torneo.stato <> 'bozza' then
      raise exception 'Le iscrizioni si aprono da un torneo in bozza';
    end if;

  elsif p_nuovo_stato = 'in_corso' then
    if torneo.stato <> 'iscrizioni' then
      raise exception 'Un torneo si avvia dalle iscrizioni';
    end if;

    select count(*) into senza_girone
    from public.torneo_squadre
    where torneo_id = p_torneo_id and stato = 'iscritta' and girone_id is null;

    if senza_girone > 0 then
      raise exception 'Ci sono % squadre senza girone: assegnale prima di avviare', senza_girone;
    end if;

    select count(*) into incontri
    from public.torneo_incontri where torneo_id = p_torneo_id;

    if incontri = 0 then
      raise exception 'Il calendario non e'' ancora stato generato';
    end if;

  elsif p_nuovo_stato = 'concluso' then
    if torneo.stato <> 'in_corso' then
      raise exception 'Si conclude un torneo in corso';
    end if;

  else
    raise exception 'Stato non riconosciuto: %', p_nuovo_stato;
  end if;

  update public.tornei set stato = p_nuovo_stato where id = p_torneo_id
  returning * into torneo;

  return torneo;
end;
$$;

grant execute on function public.torneo_cambia_stato(uuid, text) to authenticated;


-- ---------------------------------------------------------
-- 5.1  LO STATO NON SI SCRIVE A MANO
-- La policy permette al circolo di modificare il proprio torneo, e
-- fra le colonne ci sarebbe anche "stato": senza questo trigger si
-- potrebbe saltare la funzione, e con essa i controlli.
-- E' lo stesso lucchetto usato per il ruolo "gestore".
-- ---------------------------------------------------------
create or replace function public.blocca_cambio_stato_torneo()
returns trigger
language plpgsql
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if new.stato is distinct from old.stato then
    raise exception 'Lo stato del torneo si cambia con torneo_cambia_stato()';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_blocca_stato_torneo on public.tornei;

create trigger trg_blocca_stato_torneo
  before update on public.tornei
  for each row
  execute function public.blocca_cambio_stato_torneo();
