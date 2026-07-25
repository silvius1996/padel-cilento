-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.6  (CORREZIONE)
-- Protezione REALE della colonna telefono
-- Esegui nell'Editor SQL di Supabase (anche prima di update_5)
--
-- PERCHE' SERVE
-- In schema_update_4.sql avevamo scritto:
--     revoke select (telefono) on public.profiles from anon, authenticated;
-- Quell'istruzione non ha avuto effetto: Supabase concede SELECT a
-- livello di TABELLA, e una revoca su una singola COLONNA non puo'
-- annullare un privilegio concesso sull'intera tabella.
-- Il modo corretto e' revocare il permesso sulla tabella e poi
-- riconcederlo solo sulle colonne che devono restare leggibili.
--
-- Verifica del problema (dall'esterno, senza login):
--   profiles?select=telefono  ->  rispondeva "200 OK" invece di negare
-- =========================================================


-- ---------------------------------------------------------
-- 1. SI AZZERA IL PERMESSO SULLA TABELLA
-- Da qui in avanti nessun ruolo pubblico puo' leggere "tutte le colonne".
-- Le policy RLS restano quelle di schema_update_4.sql.
-- ---------------------------------------------------------
revoke select on public.profiles from anon;
revoke select on public.profiles from authenticated;


-- ---------------------------------------------------------
-- 2. SI RICONCEDE COLONNA PER COLONNA — SENZA "telefono"
-- Nota per il futuro: aggiungendo una nuova colonna a profiles,
-- va aggiunta anche qui, altrimenti l'app non riuscira' a leggerla.
-- ---------------------------------------------------------
grant select (
  id,
  nome,
  cognome,
  full_name,
  level,
  avatar_url,
  role,
  circolo,
  created_at
) on public.profiles to authenticated;

-- Ad "anon" non viene concessa nessuna colonna: un visitatore non
-- autenticato non ha motivo di leggere l'anagrafica. Le policy RLS
-- lo bloccavano gia', questo e' un secondo lucchetto indipendente.


-- ---------------------------------------------------------
-- 3. IL PROPRIO TELEFONO RESTA ACCESSIBILE
-- La funzione mio_profilo() e' "security definer": viene eseguita
-- con i privilegi del proprietario, quindi ignora le restrizioni
-- di colonna e restituisce il profilo completo, ma solo a chi lo
-- possiede (filtra su auth.uid()).
-- Definita in schema_update_4.sql, qui si garantisce solo il permesso.
-- ---------------------------------------------------------
grant execute on function public.mio_profilo() to authenticated;


-- ---------------------------------------------------------
-- 4. SCRITTURA INVARIATA
-- Ognuno continua a poter salvare il proprio numero: la revoca
-- riguarda solo la lettura.
-- ---------------------------------------------------------
grant insert, update on public.profiles to authenticated;


-- ---------------------------------------------------------
-- 5. VERIFICA
-- Dopo l'esecuzione, questa query deve mostrare "telefono" NON
-- presente per il ruolo authenticated.
-- ---------------------------------------------------------
-- select grantee, column_name, privilege_type
-- from information_schema.column_privileges
-- where table_schema = 'public'
--   and table_name = 'profiles'
--   and grantee in ('anon', 'authenticated')
-- order by grantee, column_name;
