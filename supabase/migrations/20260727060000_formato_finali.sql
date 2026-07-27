-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.21  (FINALI CON UN ALTRO FORMATO)
--
-- L'aggiornamento n.20 ha dato al torneo un formato di punteggio, ma
-- uno solo per tutto: gironi e fasi finali insieme. Il modo in cui i
-- circoli organizzano davvero e' spesso un altro — gironi a set secco
-- per far girare tanti incontri in poco tempo, e poi finali a due set
-- su tre, perche' li' vale la pena giocarsela.
--
-- Quindi il formato diventa due: quello dei gironi e quello delle
-- finali. Il secondo puo' restare vuoto, e allora vale il primo: i
-- tornei che esistono gia' non cambiano comportamento, e chi non ha
-- bisogno di distinguere non deve scegliere due volte.
--
-- Il punto di controllo resta uno: il trigger che calcola il
-- vincitore. Guarda la fase dell'incontro e applica il formato che le
-- corrisponde.
-- =========================================================


-- ---------------------------------------------------------
-- 1. IL FORMATO DELLE FINALI
-- Nullo = "come i gironi". Non si mette un default diverso apposta:
-- un torneo esistente a set unico deve continuare a giocare a set
-- unico anche le finali, esattamente come faceva ieri.
-- ---------------------------------------------------------
alter table public.tornei
  add column if not exists formato_punteggio_finali text;

alter table public.tornei
  drop constraint if exists tornei_formato_finali_check;

alter table public.tornei
  add constraint tornei_formato_finali_check
  check (formato_punteggio_finali is null
         or formato_punteggio_finali in ('due_su_tre', 'set_unico'));


-- ---------------------------------------------------------
-- 2. "CHE FORMATO VALE PER QUESTO INCONTRO?"
-- Una funzione sola, cosi' la risposta e' la stessa ovunque la si
-- chieda: dal trigger, dai test, o dall'app.
-- ---------------------------------------------------------
create or replace function public.torneo_formato_incontro(p_torneo_id uuid, p_fase text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when p_fase = 'girone' then t.formato_punteggio
           else coalesce(t.formato_punteggio_finali, t.formato_punteggio)
         end
  from public.tornei t
  where t.id = p_torneo_id;
$$;

grant execute on function public.torneo_formato_incontro(uuid, text) to authenticated;


-- ---------------------------------------------------------
-- 3. IL TRIGGER APPLICA IL FORMATO DELLA FASE
-- ---------------------------------------------------------
create or replace function public.torneo_calcola_vincitore()
returns trigger
language plpgsql
as $$
declare
  formato text;
  minimi  int;
  massimi int;
begin
  if new.sets is null then
    new.vincitore := null;
    new.registrato_il := null;
    return new;
  end if;

  formato := public.torneo_formato_incontro(new.torneo_id, new.fase);

  if formato = 'set_unico' then
    minimi := 1; massimi := 1;
  else
    minimi := 2; massimi := 3;
  end if;

  -- 'A' e' la squadra di casa, 'B' quella ospite.
  new.vincitore := case public.valida_punteggio(new.sets, minimi, massimi)
                     when 'A' then 'C' else 'O' end;

  if new.registrato_il is null then
    new.registrato_il := now();
  end if;

  return new;
end;
$$;

drop trigger if exists trg_torneo_vincitore on public.torneo_incontri;

create trigger trg_torneo_vincitore
  before insert or update on public.torneo_incontri
  for each row
  execute function public.torneo_calcola_vincitore();


-- ---------------------------------------------------------
-- 4. NESSUNO DEI DUE FORMATI SI CAMBIA A TORNEO INIZIATO
-- Vale anche per quello delle finali: i punteggi gia' inseriti
-- resterebbero in tabella pur non essendo piu' validi.
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
      or new.formato_punteggio_finali is distinct from old.formato_punteggio_finali)
     and public.torneo_ha_risultati(old.id) then
    raise exception 'In questo torneo si e'' gia'' giocato: il formato del punteggio non si cambia piu''.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_blocca_cambio_formato on public.tornei;

create trigger trg_blocca_cambio_formato
  before update of formato_punteggio, formato_punteggio_finali on public.tornei
  for each row
  execute function public.blocca_cambio_formato_punteggio();
