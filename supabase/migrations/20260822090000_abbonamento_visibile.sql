-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.31
-- L'abbonamento del circolo smette di essere muto
--
-- PERCHE' ADESSO
-- Il cancello commerciale c'e' dall'aggiornamento n.13: "attivo" e
-- "abbonamento_scade_il", controllati da circolo_utilizzabile() dentro
-- e_gestore_del_circolo(), che regge tutti i permessi dei tornei. Il
-- cancello funziona, ma non parla: un gestore con l'abbonamento
-- scaduto non legge "scaduto", legge "Non hai i permessi per questa
-- operazione" — il messaggio generico che l'app ricava da un rifiuto
-- delle policy RLS. Pensa che l'app sia rotta e telefona, invece di
-- rinnovare.
--
-- Un cancello che non dice perche' e' chiuso non e' un cancello: e'
-- un guasto. Qui gliela si fa dire, in tre pezzi.
--
-- COSA NON CAMBIA
-- Nessuna regola di accesso. Chi poteva creare un torneo prima puo'
-- ancora, chi non poteva riceve lo stesso rifiuto — solo scritto in
-- italiano. Le date di scadenza restano una decisione manuale
-- dell'amministratore: l'incasso avviene fuori dall'app, qui si
-- registra soltanto fino a quando il cliente e' in regola.
-- =========================================================


-- =========================================================
-- PARTE 1 — LA SCADENZA NON E' UN DATO PUBBLICO
--
-- I circoli sono leggibili da tutti, e devono restarlo: i tabelloni
-- dei tornei li guarda anche chi non ha l'account. Ma "attivo" e
-- "abbonamento_scade_il" non sono anagrafica, sono il contratto: da
-- oggi il rapporto commerciale con un circolo si legge solo tramite
-- la funzione della Parte 2, che risponde al diretto interessato e
-- all'amministratore.
--
-- Vale la lezione dell'aggiornamento n.6: Supabase concede SELECT a
-- livello di TABELLA, quindi una revoca sulla singola colonna non
-- avrebbe alcun effetto. Si azzera la tabella e si riconcede colonna
-- per colonna.
--
-- Nota per il futuro: aggiungendo una colonna a "circoli", va
-- aggiunta anche qui, altrimenti l'app non riuscira' a leggerla.
-- =========================================================

revoke select on public.circoli from anon;
revoke select on public.circoli from authenticated;

grant select (
  id,
  nome,
  zona,
  indirizzo,
  telefono,
  created_at
) on public.circoli to anon, authenticated;

-- "attivo" resta leggibile: l'amministratore, quando sceglie per
-- quale circolo organizzare, deve vedere quali sono sospesi. Non
-- dice niente sui soldi, dice se il circolo e' in piedi.
grant select (attivo) on public.circoli to authenticated;


-- =========================================================
-- PARTE 2 — "FINO A QUANDO SONO IN REGOLA?"
--
-- La domanda ha due soli titolari: il gestore, per il proprio
-- circolo, e l'amministratore, per chiunque. Chiamata senza
-- argomento risponde sul circolo di chi la sta chiamando; con un
-- circolo indicato risponde solo all'amministratore.
--
-- E' "security definer" perche' deve leggere le due colonne che la
-- Parte 1 ha appena chiuso: e' l'unica porta che restituisce quel
-- dato, e la si attraversa solo avendone diritto.
-- =========================================================
create or replace function public.stato_abbonamento(p_circolo_id uuid default null)
returns table (
  circolo_id     uuid,
  nome           text,
  attivo         boolean,
  scade_il       date,
  giorni_rimasti int,
  utilizzabile   boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with richiesto as (
    select case
      -- Un circolo indicato lo puo' chiedere solo l'amministratore:
      -- per tutti gli altri la richiesta non esiste e non risponde.
      when p_circolo_id is not null then
        case when public.e_amministratore() then p_circolo_id else null end
      -- Senza argomento: il proprio circolo, qualunque sia il ruolo.
      -- Un giocatore non ne ha, e non ottiene nessuna riga.
      else (select p.circolo_id from public.profiles p where p.id = auth.uid())
    end as id
  )
  select
    c.id,
    c.nome,
    c.attivo,
    c.abbonamento_scade_il,
    case
      when c.abbonamento_scade_il is null then null
      else (c.abbonamento_scade_il - (now() at time zone 'Europe/Rome')::date)::int
    end,
    public.circolo_utilizzabile(c.id)
  from public.circoli c
  join richiesto r on r.id = c.id;
$$;

grant execute on function public.stato_abbonamento(uuid) to authenticated;


-- =========================================================
-- PARTE 3 — IL RIFIUTO DICE PERCHE'
--
-- Un trigger BEFORE su "tornei" si esegue prima che PostgreSQL
-- valuti la clausola WITH CHECK delle policy: e' l'unico punto in
-- cui si puo' sostituire il rifiuto muto delle RLS con una frase.
--
-- Parla solo a chi ha diritto di sapere: il gestore collegato a
-- QUEL circolo. Per chiunque altro il trigger tace e il rifiuto
-- resta quello delle policy — un estraneo non deve poter usare
-- l'inserimento di un torneo per scoprire lo stato commerciale di
-- un circolo che non e' suo.
--
-- Solo sull'inserimento, e non e' una dimenticanza: nella modifica
-- la clausola USING della policy scarta la riga PRIMA che qualunque
-- trigger si esegua, quindi non resta niente da intercettare — la
-- modifica non fallisce, semplicemente non trova righe. Li' a
-- spiegare e' l'avviso in cima alla pagina Tornei, che si vede
-- prima di provarci.
-- =========================================================
create or replace function public.spiega_circolo_non_utilizzabile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
begin
  -- L'amministratore interviene ovunque, anche sul torneo di un
  -- cliente che ha smesso di pagare: per lui non c'e' niente da
  -- spiegare.
  if public.e_amministratore() then
    return new;
  end if;

  if public.circolo_utilizzabile(new.circolo_id) then
    return new;
  end if;

  if not exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role = 'gestore'
      and circolo_id = new.circolo_id
  ) then
    return new;  -- non e' affare suo: rifiutera' la policy
  end if;

  select attivo, abbonamento_scade_il into c
  from public.circoli where id = new.circolo_id;

  if not c.attivo then
    raise exception 'Il circolo e'' sospeso: non puo'' creare o modificare tornei. I tornei gia'' pubblicati restano online.';
  end if;

  raise exception 'L''abbonamento del circolo e'' scaduto il %. I tornei gia'' pubblicati restano online e continuano a vedersi: per crearne di nuovi o modificarli serve il rinnovo.',
    to_char(c.abbonamento_scade_il, 'DD/MM/YYYY');
end;
$$;

drop trigger if exists trg_spiega_circolo_non_utilizzabile on public.tornei;
create trigger trg_spiega_circolo_non_utilizzabile
  before insert on public.tornei
  for each row
  execute function public.spiega_circolo_non_utilizzabile();
