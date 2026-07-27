-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.19  (CORREGGERE UN ERRORE)
--
-- Chi organizza un torneo sbaglia: mette una coppia nel girone
-- sbagliato, o crea un torneo di prova e se lo ritrova in elenco.
-- Finora si poteva solo annullare il torneo, che e' una risposta
-- sproporzionata a un errore di battitura.
--
-- Il permesso c'era gia' (la policy su torneo_squadre e' "for all",
-- e i tornei hanno una policy di cancellazione), ma mancava la
-- regola che dice QUANDO si puo' fare. Senza, cancellare una coppia
-- a torneo in corso avrebbe portato via anche le sue partite —
-- torneo_incontri ha "on delete cascade" sulle squadre — e le
-- classifiche degli altri gironi si sarebbero riscritte da sole,
-- in silenzio.
--
-- LA REGOLA, la stessa che vale gia' per il calendario:
-- finche' nessuno ha inserito un risultato si puo' rifare tutto;
-- dal primo risultato in poi il torneo e' un fatto avvenuto e si
-- annulla, non si cancella.
--
-- Perche' nel database e non nell'interfaccia: nascondere un
-- pulsante non e' una protezione. Chi arriva da fuori (la console
-- del browser, uno strumento HTTP) trova comunque la porta.
-- =========================================================


-- ---------------------------------------------------------
-- 1. "IN QUESTO TORNEO SI E' GIA' GIOCATO?"
-- Un risultato inserito e' il confine: prima si sistema, dopo si
-- annulla soltanto.
-- ---------------------------------------------------------
create or replace function public.torneo_ha_risultati(p_torneo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.torneo_incontri
    where torneo_id = p_torneo_id and sets is not null
  );
$$;

grant execute on function public.torneo_ha_risultati(uuid) to authenticated;


-- ---------------------------------------------------------
-- 2. LE COPPIE: SI CANCELLANO E SI SPOSTANO SOLO PRIMA
-- Lo spostamento di girone rientra nella stessa regola: gli
-- incontri sono gia' stati generati su quel girone, e cambiarlo
-- dopo lascerebbe in piedi partite che non hanno piu' senso.
-- Il calendario si rigenera, ed e' proprio quello che va fatto.
-- ---------------------------------------------------------
create or replace function public.blocca_modifica_squadra_giocata()
returns trigger
language plpgsql
as $$
declare
  torneo uuid := coalesce(old.torneo_id, new.torneo_id);
begin
  -- Le richieste che non arrivano dal browser (manutenzione
  -- dall'Editor SQL, funzioni "security definer") non passano di qui.
  if current_user not in ('anon', 'authenticated') then
    return coalesce(new, old);
  end if;

  if tg_op = 'UPDATE' and new.girone_id is not distinct from old.girone_id then
    return new;   -- non e' un cambio di girone: nulla da controllare
  end if;

  if public.torneo_ha_risultati(torneo) then
    if tg_op = 'DELETE' then
      raise exception 'In questo torneo si e'' gia'' giocato: una coppia non si cancella piu''. Se si e'' ritirata, segnala il ritiro.';
    else
      raise exception 'In questo torneo si e'' gia'' giocato: il girone di una coppia non si cambia piu''.';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_blocca_modifica_squadra on public.torneo_squadre;

create trigger trg_blocca_modifica_squadra
  before delete or update of girone_id on public.torneo_squadre
  for each row
  execute function public.blocca_modifica_squadra_giocata();


-- ---------------------------------------------------------
-- 3. IL TORNEO: SI CANCELLA SOLO SE NON E' MAI PARTITO
-- Un torneo concluso non si cancella nemmeno volendo: le medaglie
-- sui profili dei vincitori arrivano da qui, e sparirebbero senza
-- che nessuno se ne accorga. Per quello c'e' "annullato", che
-- toglie il torneo dalla circolazione lasciando la storia dov'e'.
-- ---------------------------------------------------------
create or replace function public.blocca_cancellazione_torneo()
returns trigger
language plpgsql
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return old;
  end if;

  if public.torneo_ha_risultati(old.id) then
    raise exception 'In questo torneo si e'' gia'' giocato: non si cancella. Annullalo, cosi'' la storia resta.';
  end if;

  if old.stato = 'concluso' then
    raise exception 'Un torneo concluso non si cancella: le medaglie dei vincitori arrivano da qui.';
  end if;

  return old;
end;
$$;

drop trigger if exists trg_blocca_cancellazione_torneo on public.tornei;

create trigger trg_blocca_cancellazione_torneo
  before delete on public.tornei
  for each row
  execute function public.blocca_cancellazione_torneo();
