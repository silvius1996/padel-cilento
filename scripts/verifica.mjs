/* Verifica dello stato reale del database di produzione dopo le migrazioni. */
import pg from 'pg';
import fs from 'node:fs';

const env = fs.readFileSync('./.env', 'utf8');
const url = env.split('\n').find((r) => r.trim().startsWith('SUPABASE_DB_URL='))
  .split('=').slice(1).join('=').trim();

const c = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await c.connect();

const q = async (sql) => (await c.query(sql)).rows;

console.log('=== STRUTTURA ===');
const spot = await q(`select data_type from information_schema.columns
  where table_schema='public' and table_name='match_players' and column_name='spot'`);
console.log(`colonna match_players.spot: ${spot.length ? spot[0].data_type : 'ASSENTE'}`);

const tab = await q(`select table_name from information_schema.tables
  where table_schema='public' and table_name='match_results'`);
console.log(`tabella match_results: ${tab.length ? 'presente' : 'ASSENTE'}`);

const fn = await q(`select routine_name from information_schema.routines
  where routine_schema='public' and routine_name in
  ('registra_risultato','conferma_risultato','contesta_risultato','classifica',
   'statistiche_giocatore','contatti_partita','mio_profilo') order by routine_name`);
console.log(`funzioni installate (${fn.length}/7): ${fn.map((r) => r.routine_name).join(', ')}`);

const vista = await q(`select table_name from information_schema.views
  where table_schema='public' and table_name='statistiche_giocatori'`);
console.log(`vista statistiche_giocatori: ${vista.length ? 'presente' : 'ASSENTE'}`);

const trig = await q(`select trigger_name from information_schema.triggers
  where trigger_schema='public' and event_object_table='match_players'
  group by trigger_name order by trigger_name`);
console.log(`trigger su match_players: ${trig.map((r) => r.trigger_name).join(', ')}`);

console.log('\n=== PERMESSI SULLA COLONNA TELEFONO ===');
const perm = await q(`select grantee, column_name from information_schema.column_privileges
  where table_schema='public' and table_name='profiles'
    and grantee in ('anon','authenticated') and privilege_type='SELECT'
    and column_name='telefono'`);
console.log(perm.length === 0
  ? 'telefono NON leggibile da anon/authenticated  <-- corretto'
  : `ATTENZIONE: ancora leggibile da ${perm.map((r) => r.grantee).join(', ')}`);

const colonne = await q(`select count(*)::int n from information_schema.column_privileges
  where table_schema='public' and table_name='profiles'
    and grantee='authenticated' and privilege_type='SELECT'`);
console.log(`colonne di profiles leggibili da authenticated: ${colonne[0].n}`);

console.log('\n=== DATI ESISTENTI ===');
const p = await q(`select id, filled_slots,
  (select count(*) from match_players mp where mp.match_id = m.id)::int iscritti
  from matches m order by match_date desc limit 5`);
p.forEach((r) => console.log(`  partita ${r.id.slice(0, 8)}  posti=${r.filled_slots}  iscritti=${r.iscritti}` +
  (r.filled_slots === r.iscritti ? '  coerente' : '  DISALLINEATO')));

const spots = await q(`select match_id, spot, user_id from match_players order by match_id, spot`);
console.log(`\niscrizioni con posto assegnato: ${spots.length}`);
spots.forEach((r) => console.log(`  ${r.match_id.slice(0, 8)}  posto ${r.spot}  squadra ${r.spot < 2 ? 'A' : 'B'}`));

await c.end();
