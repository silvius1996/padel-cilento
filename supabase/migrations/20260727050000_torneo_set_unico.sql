-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.20  (TORNEI A SET UNICO)
--
-- I circoli organizzano tornei in una serata: con dieci coppie non
-- si giocano due set su tre, si gioca un set secco e via. Finora
-- valida_punteggio() rifiutava qualunque punteggio con meno di due
-- set, quindi quei tornei non si potevano registrare affatto.
--
-- La regola non sparisce, diventa una proprieta' del torneo: ogni
-- torneo dichiara come si vince, e il database controlla di
-- conseguenza. Le partite normali restano a due set su tre — li'
-- non c'e' un organizzatore che stabilisca il formato, quindi la
-- regola resta fissa.
-- =========================================================


-- ---------------------------------------------------------
-- 1. COME SI VINCE, DETTO DAL TORNEO
-- ---------------------------------------------------------
alter table public.tornei
  add column if not exists formato_punteggio text not null default 'due_su_tre';

alter table public.tornei
  drop constraint if exists tornei_formato_punteggio_check;

alter table public.tornei
  add constraint tornei_formato_punteggio_check
  check (formato_punteggio in ('due_su_tre', 'set_unico'));


-- ---------------------------------------------------------
-- 2. LA VALIDAZIONE ACCETTA UN INTERVALLO DI SET
-- La versione a un argomento resta identica per chi la usava gia'
-- (le partite normali): delega a questa con 2..3. Nessun chiamante
-- esistente cambia comportamento.
-- ---------------------------------------------------------
create or replace function public.valida_punteggio(
  p_sets       jsonb,
  p_set_minimi int,
  p_set_massimi int
)
returns char(1)
language plpgsql
immutable
as $$
declare
  n_set   int;
  set_a   int := 0;
  set_b   int := 0;
  punti_a int;
  punti_b int;
  i       int;
begin
  if jsonb_typeof(p_sets) <> 'array' then
    raise exception 'Punteggio non valido';
  end if;

  n_set := jsonb_array_length(p_sets);
  if n_set < p_set_minimi or n_set > p_set_massimi then
    if p_set_minimi = p_set_massimi and p_set_minimi = 1 then
      raise exception 'Questo torneo si gioca a set unico: serve un solo set';
    else
      raise exception 'Una partita si decide su % o % set', p_set_minimi, p_set_massimi;
    end if;
  end if;

  for i in 0 .. n_set - 1 loop
    if jsonb_typeof(p_sets -> i) <> 'array' or jsonb_array_length(p_sets -> i) <> 2 then
      raise exception 'Ogni set richiede due punteggi';
    end if;

    punti_a := (p_sets -> i ->> 0)::int;
    punti_b := (p_sets -> i ->> 1)::int;

    if punti_a is null or punti_b is null
       or punti_a < 0 or punti_b < 0
       or punti_a > 15 or punti_b > 15 then
      raise exception 'Punteggio del set % non valido', i + 1;
    end if;

    if punti_a = punti_b then
      raise exception 'Il set % non puo'' finire in parita''', i + 1;
    end if;

    if punti_a > punti_b then set_a := set_a + 1; else set_b := set_b + 1; end if;
  end loop;

  if set_a = set_b then
    raise exception 'Il punteggio non indica un vincitore';
  end if;

  return case when set_a > set_b then 'A' else 'B' end;
end;
$$;

create or replace function public.valida_punteggio(p_sets jsonb)
returns char(1)
language sql
immutable
as $$
  select public.valida_punteggio(p_sets, 2, 3);
$$;

grant execute on function public.valida_punteggio(jsonb) to authenticated;
grant execute on function public.valida_punteggio(jsonb, int, int) to authenticated;


-- ---------------------------------------------------------
-- 3. IL TRIGGER DEL TORNEO GUARDA IL FORMATO
-- Resta l'unico punto in cui si decide chi ha vinto un incontro di
-- torneo: chiunque scriva "sets", da qualunque strada, passa di qui.
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

  select t.formato_punteggio into formato
  from public.tornei t where t.id = new.torneo_id;

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
-- 4. IL FORMATO NON SI CAMBIA A TORNEO INIZIATO
-- Cambiarlo dopo renderebbe non validi i punteggi gia' inseriti:
-- resterebbero in tabella dei risultati che il database non
-- accetterebbe piu', e il vincitore calcolato non tornerebbe.
-- ---------------------------------------------------------
create or replace function public.blocca_cambio_formato_punteggio()
returns trigger
language plpgsql
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if new.formato_punteggio is distinct from old.formato_punteggio
     and public.torneo_ha_risultati(old.id) then
    raise exception 'In questo torneo si e'' gia'' giocato: il formato del punteggio non si cambia piu''.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_blocca_cambio_formato on public.tornei;

create trigger trg_blocca_cambio_formato
  before update of formato_punteggio on public.tornei
  for each row
  execute function public.blocca_cambio_formato_punteggio();
