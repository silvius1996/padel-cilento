-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.12
-- Una sola funzione decide chi ha vinto
--
-- PERCHE'
-- Ricavare il vincitore da un punteggio, e rifiutare i punteggi
-- impossibili, e' una quarantina di righe. Oggi esistono in DUE
-- copie: dentro registra_risultato e, identiche, dentro
-- correggi_risultato. La modalita' torneo ne vorrebbe una terza.
--
-- Tre copie sono tre posti che possono dare risposte diverse sullo
-- stesso punteggio. Basta correggere un limite in due su tre, e per
-- mesi nessuno se ne accorge: il torneo dichiara un vincitore, la
-- partita normale un altro.
--
-- Qui la logica diventa una funzione sola. Le regole non cambiano di
-- una virgola, nemmeno i messaggi d'errore: e' un riordino, non una
-- modifica di comportamento, e i test lo verificano.
-- =========================================================


-- ---------------------------------------------------------
-- 1. LA FUNZIONE
-- Riceve il punteggio come elenco di set  [[6,4],[3,6],[7,5]]  e
-- restituisce 'A' o 'B'. Se il punteggio non sta in piedi, solleva
-- l'eccezione con il messaggio che l'utente leggera'.
--
-- E' "immutable": dipende solo dal suo argomento, non legge nulla.
-- PostgreSQL puo' quindi chiamarla anche dentro un vincolo, se un
-- giorno servisse.
-- ---------------------------------------------------------
create or replace function public.valida_punteggio(p_sets jsonb)
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
  if n_set < 2 or n_set > 3 then
    raise exception 'Una partita si decide su 2 o 3 set';
  end if;

  for i in 0 .. n_set - 1 loop
    if jsonb_typeof(p_sets -> i) <> 'array' or jsonb_array_length(p_sets -> i) <> 2 then
      raise exception 'Ogni set richiede due punteggi';
    end if;

    -- Si passa da ->> (testo) invece di -> (jsonb): la conversione a
    -- numero e' cosi' valida su qualunque versione di PostgreSQL.
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

grant execute on function public.valida_punteggio(jsonb) to authenticated;


-- ---------------------------------------------------------
-- 2. REGISTRAZIONE DEL RISULTATO
-- Identica a prima, tolte le righe che ora stanno nella funzione.
-- ---------------------------------------------------------
create or replace function public.registra_risultato(p_match_id uuid, p_sets jsonb)
returns public.match_results
language plpgsql
security definer
set search_path = public
as $$
declare
  partita     public.matches;
  n_giocatori int;
  vincitore   char(1);
  risultato   public.match_results;
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into partita from public.matches where id = p_match_id;
  if partita is null then
    raise exception 'Partita inesistente';
  end if;

  if not exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = auth.uid()
  ) then
    raise exception 'Solo chi ha giocato la partita puo'' registrarne il risultato';
  end if;

  -- L'orario della partita e' un'ora locale italiana, mentre now() e' in UTC:
  -- senza la conversione una partita delle 20:00 risulterebbe "non iniziata"
  -- fino alle 22:00 ora locale.
  if ((partita.match_date + partita.match_time) at time zone 'Europe/Rome') > now() then
    raise exception 'La partita non e'' ancora iniziata';
  end if;

  select count(*) into n_giocatori
  from public.match_players where match_id = p_match_id;

  if n_giocatori <> 4 then
    raise exception 'Serve una formazione completa di 4 giocatori (attuali: %)', n_giocatori;
  end if;

  vincitore := public.valida_punteggio(p_sets);

  insert into public.match_results (match_id, sets, winner_team, registrato_da)
  values (p_match_id, p_sets, vincitore, auth.uid())
  returning * into risultato;

  return risultato;
end;
$$;

grant execute on function public.registra_risultato(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------
-- 3. CORREZIONE DEL PUNTEGGIO
-- Idem: le regole su chi puo' correggere e quando restano quelle
-- dell'aggiornamento n.11.
-- ---------------------------------------------------------
create or replace function public.correggi_risultato(p_match_id uuid, p_sets jsonb)
returns public.match_results
language plpgsql
security definer
set search_path = public
as $$
declare
  risultato public.match_results;
  vincitore char(1);
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into risultato from public.match_results where match_id = p_match_id;

  if risultato is null then
    raise exception 'Non c''e'' nessun risultato da correggere';
  end if;

  if not exists (
    select 1 from public.match_players
    where match_id = p_match_id and user_id = auth.uid()
  ) then
    raise exception 'Solo chi ha giocato la partita puo'' correggerne il risultato';
  end if;

  if risultato.stato = 'confermato' then
    raise exception 'Il risultato e'' stato confermato da un avversario: non si puo'' piu'' correggere';
  end if;

  if risultato.stato = 'in_attesa' and risultato.registrato_da <> auth.uid() then
    raise exception 'Questo punteggio l''ha inserito un altro giocatore: se non e'' giusto, contestalo';
  end if;

  vincitore := public.valida_punteggio(p_sets);

  update public.match_results
  set sets = p_sets,
      winner_team = vincitore,
      stato = 'in_attesa',
      registrato_da = auth.uid(),
      registrato_il = now(),
      confermato_da = null,
      confermato_il = null,
      nota_contestazione = null
  where match_id = p_match_id
  returning * into risultato;

  return risultato;
end;
$$;

grant execute on function public.correggi_risultato(uuid, jsonb) to authenticated;
