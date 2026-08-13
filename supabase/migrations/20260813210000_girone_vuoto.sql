-- =========================================================
-- PADEL CILENTO — I GIRONI VUOTI NON CONTANO
--
-- Un girone creato per sbaglio e rimasto senza squadre bloccava il
-- tabellone: il conto delle qualificate lo includeva lo stesso, e
-- due gironi veri con due qualificate ciascuno diventavano "sei
-- qualificate" invece di quattro. L'errore chiedeva di cambiare il
-- numero di gironi, ma nessuna schermata permetteva di togliere il
-- girone di troppo.
--
-- Qui il conto guarda solo i gironi che hanno almeno una squadra: un
-- girone vuoto non manda nessuno alle finali, quindi non ha voce nel
-- calcolo. Il pulsante per cancellarlo sta nella pagina del torneo.
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

  -- I gironi rimasti vuoti non mandano nessuno alle finali: contarli
  -- gonfierebbe il totale delle qualificate e basterebbe un girone
  -- creato per sbaglio a rendere il tabellone impossibile.
  select count(*) into n_gironi
  from public.tornei_gironi g
  where g.torneo_id = p_torneo_id
    and exists (select 1 from public.torneo_squadre s where s.girone_id = g.id);

  totale := n_gironi * torneo.qualificate_per_girone;

  if totale not in (2, 4, 8) then
    raise exception 'Le qualificate devono essere 2, 4 o 8 (ora sarebbero %): cambia il numero di gironi o di qualificate per girone', totale;
  end if;

  -- In fila per merito: prima tutte le prime, poi tutte le seconde...
  qualificate := array_fill(null::uuid, array[totale]);

  for girone in
    select g.id from public.tornei_gironi g
    where g.torneo_id = p_torneo_id
      and exists (select 1 from public.torneo_squadre s where s.girone_id = g.id)
    order by g.ordine, g.nome
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
