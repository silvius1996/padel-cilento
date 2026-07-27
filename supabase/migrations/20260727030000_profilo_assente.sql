-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.18  (PROFILO ASSENTE)
--
-- IL DIFETTO
-- mio_profilo() era dichiarata "returns public.profiles", cioe'
-- restituisce UN record. Quando la riga non esiste, PostgreSQL non
-- restituisce zero righe: restituisce una riga con tutte le colonne
-- a null. Attraverso PostgREST quella riga arriva al browser come un
-- oggetto {id: null, nome: null, ...} che in JavaScript e' "vero".
--
-- Il codice del browser faceva:
--     const { data } = await supabaseClient.rpc('mio_profilo');
--     if (data) return data;          // <-- sempre vero
-- e quindi non si accorgeva mai che il profilo mancava: non lo
-- creava, e mostrava una scheda vuota con l'iniziale "G" di
-- "Giocatore", il valore di ripiego.
--
-- COME CI SI ARRIVA
-- Serve un utente autenticato senza riga in "profiles". Succede a
-- chi elimina l'account e si registra di nuovo con la stessa email:
-- il nuovo account ha un id nuovo, e con la conferma via email
-- attiva la registrazione non apre subito una sessione, quindi il
-- profilo non viene creato in quel momento. Al primo accesso vero
-- sarebbe stato creato da loadProfile(), che pero' non se ne
-- accorgeva mai per via di questa riga fantasma.
--
-- LA CORREZIONE
-- "setof": nessun profilo significa nessuna riga. PostgREST
-- restituisce un elenco vuoto, che in JavaScript si distingue
-- benissimo da un profilo vero.
--
-- Il difetto gemello sta nel browser (salvaProfilo non guardava
-- quante righe venivano modificate, quindi un salvataggio a vuoto
-- diceva comunque "Profilo aggiornato"): e' corretto in index.html.
-- =========================================================

-- Il tipo restituito cambia, quindi non basta "create or replace".
drop function if exists public.mio_profilo();

create function public.mio_profilo()
returns setof public.profiles
language sql
security definer
set search_path = public
as $$
  select * from public.profiles where id = auth.uid();
$$;

grant execute on function public.mio_profilo() to authenticated;
