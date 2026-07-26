/* =========================================================
   PADEL CILENTO — Test automatici della logica di database
   Esecuzione:  npm test
=========================================================

   Non serve Docker ne' un progetto Supabase: le migrazioni vengono
   applicate a un PostgreSQL reale compilato in WebAssembly (PGlite).
   Cio' che Supabase fornisce di suo (i ruoli anon/authenticated, lo
   schema auth con auth.uid(), lo schema storage) viene ricreato qui
   in modo fedele, cosi' i permessi e le policy RLS si comportano
   come in produzione.

   ATTENZIONE: questo file non tocca in alcun modo il database di
   produzione. Ogni esecuzione parte da un database vuoto in memoria.
========================================================= */

import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';

const CARTELLA_MIGRAZIONI = path.join(process.cwd(), 'supabase', 'migrations');

// Identita' usate nei test
const U = {
  aldo:  '11111111-1111-1111-1111-111111111111', // Squadra A, posto 0, organizzatore
  bea:   '22222222-2222-2222-2222-222222222222', // Squadra A, posto 1
  carlo: '33333333-3333-3333-3333-333333333333', // Squadra B, posto 2
  dina:  '44444444-4444-4444-4444-444444444444', // Squadra B, posto 3
  ester: '55555555-5555-5555-5555-555555555555', // non gioca: serve ai test negativi
  nuovo: '66666666-6666-6666-6666-666666666666', // si registra a test in corso
};

const PARTITA = 'aaaaaaaa-0000-0000-0000-000000000001';
const PARTITA_FUTURA = 'aaaaaaaa-0000-0000-0000-000000000002';

let db;
let passati = 0;
const falliti = [];

// ---------------------------------------------------------
// Utilita' di test
// ---------------------------------------------------------
function esito(nome, condizione, dettaglio = '') {
  if (condizione) {
    passati++;
    console.log(`  OK   ${nome}`);
  } else {
    falliti.push(`${nome}${dettaglio ? ` — ${dettaglio}` : ''}`);
    console.log(`  FAIL ${nome}${dettaglio ? ` — ${dettaglio}` : ''}`);
  }
}

function uguale(nome, atteso, ottenuto) {
  esito(nome, String(atteso) === String(ottenuto), `atteso ${atteso}, ottenuto ${ottenuto}`);
}

/** Verifica che un'operazione venga RIFIUTATA dal database. */
async function deveFallire(nome, fn, frammentoAtteso) {
  try {
    await fn();
    esito(nome, false, 'l\'operazione e\' stata accettata invece di essere rifiutata');
  } catch (e) {
    const msg = String(e.message || e);
    const combacia = !frammentoAtteso ||
      msg.toLowerCase().includes(frammentoAtteso.toLowerCase());
    esito(nome, combacia, combacia ? '' : `messaggio inatteso: ${msg}`);
  }
}

async function deveRiuscire(nome, fn) {
  try {
    const r = await fn();
    esito(nome, true);
    return r;
  } catch (e) {
    esito(nome, false, String(e.message || e));
    return null;
  }
}

/** Esegue le query successive come se fosse l'utente indicato. */
async function come(uid) {
  await db.query(`select set_config('test.uid', $1, false)`, [uid || '']);
}

// ---------------------------------------------------------
// 1. Ambiente: cio' che Supabase mette a disposizione
// ---------------------------------------------------------
const IMPALCATURA = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin;

  grant usage on schema public to anon, authenticated, service_role;

  -- Supabase concede per impostazione predefinita l'accesso alle tabelle
  -- del cosiddetto schema pubblico: e' proprio questa concessione a
  -- livello di TABELLA che rendeva inefficace la revoca sulla colonna
  -- "telefono", e va quindi riprodotta fedelmente.
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

  -- Schema di autenticazione
  create schema auth;
  create table auth.users (
    id uuid primary key,
    email text unique
  );
  grant usage on schema auth to anon, authenticated;

  -- auth.uid() restituisce l'utente "collegato". Nei test si cambia
  -- identita' impostando la variabile di sessione test.uid.
  create function auth.uid() returns uuid
  language sql stable as $fn$
    select nullif(current_setting('test.uid', true), '')::uuid
  $fn$;

  -- Schema di archiviazione file (usato dalle policy sugli avatar).
  -- file_size_limit e allowed_mime_types esistono anche su Supabase: sono
  -- le colonne su cui l'aggiornamento n.8 impone i limiti agli avatar.
  create schema storage;
  create table storage.buckets (
    id text primary key,
    name text,
    public boolean default false,
    file_size_limit bigint,
    allowed_mime_types text[]
  );
  create table storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text,
    owner uuid,
    name text
  );
  alter table storage.objects enable row level security;

  -- Supabase concede l'accesso allo schema storage ai ruoli pubblici:
  -- e' l'API Storage a passare da qui, quindi le policy sugli oggetti
  -- vanno verificate con questi permessi attivi.
  grant usage on schema storage to anon, authenticated;
  grant select, insert, update, delete on storage.objects to anon, authenticated;
  grant select on storage.buckets to anon, authenticated;
`;

// ---------------------------------------------------------
// 2. Applicazione delle migrazioni
// ---------------------------------------------------------
async function applicaMigrazioni() {
  const file = fs.readdirSync(CARTELLA_MIGRAZIONI)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  console.log(`\nMigrazioni trovate: ${file.length}`);

  for (const f of file) {
    const sql = fs.readFileSync(path.join(CARTELLA_MIGRAZIONI, f), 'utf8');
    try {
      await db.exec(sql);
      console.log(`  OK   ${f}`);
      passati++;
    } catch (e) {
      falliti.push(`migrazione ${f}: ${e.message}`);
      console.log(`  FAIL ${f}\n       ${e.message}`);
      throw new Error(`Migrazione interrotta su ${f}`);
    }
  }
}

// ---------------------------------------------------------
// 3. Dati di prova
// ---------------------------------------------------------
async function seed() {
  const utenti = [
    [U.aldo, 'aldo@test.it', 'Aldo', 'Rossi', '3330000001'],
    [U.bea, 'bea@test.it', 'Bea', 'Bianchi', '3330000002'],
    [U.carlo, 'carlo@test.it', 'Carlo', 'Verdi', '3330000003'],
    [U.dina, 'dina@test.it', 'Dina', 'Neri', '3330000004'],
    [U.ester, 'ester@test.it', 'Ester', 'Gialli', '3330000005'],
  ];

  for (const [id, email, nome, cognome, tel] of utenti) {
    await db.query('insert into auth.users (id, email) values ($1, $2)', [id, email]);
    await db.query(
      `insert into public.profiles (id, nome, cognome, telefono, full_name, level)
       values ($1, $2, $3, $4, $5, 'intermedio')`,
      [id, nome, cognome, tel, `${nome} ${cognome}`],
    );
  }

  // Partita giocata due giorni fa
  await db.query(
    `insert into public.matches (id, club, zona, match_date, match_time, level, total_slots, filled_slots, created_by)
     values ($1, 'Padel Village', 'paestum', current_date - 2, '20:00', 'intermedio', 4, 0, $2)`,
    [PARTITA, U.aldo],
  );

  // Partita ancora da giocare, per i test sul divieto di anticipare il risultato
  await db.query(
    `insert into public.matches (id, club, zona, match_date, match_time, level, total_slots, filled_slots, created_by)
     values ($1, 'Padel Village', 'paestum', current_date + 3, '20:00', 'intermedio', 4, 0, $2)`,
    [PARTITA_FUTURA, U.aldo],
  );
}

// ---------------------------------------------------------
// 4. I test
// ---------------------------------------------------------
async function testFormazione() {
  console.log('\nFORMAZIONE E POSTI IN CAMPO');

  await deveRiuscire('quattro giocatori occupano i quattro posti', async () => {
    const coppie = [[U.aldo, 0], [U.bea, 1], [U.carlo, 2], [U.dina, 3]];
    for (const [uid, spot] of coppie) {
      await db.query(
        'insert into public.match_players (match_id, user_id, spot) values ($1, $2, $3)',
        [PARTITA, uid, spot],
      );
    }
  });

  const { rows } = await db.query(
    'select filled_slots from public.matches where id = $1', [PARTITA],
  );
  uguale('i posti occupati si aggiornano da soli', 4, rows[0].filled_slots);

  await deveFallire(
    'un quinto giocatore viene rifiutato',
    () => db.query(
      'insert into public.match_players (match_id, user_id, spot) values ($1, $2, 0)',
      [PARTITA, U.ester],
    ),
    'completo',
  );

  // Su una partita non piena, due giocatori non possono condividere il posto
  await db.query(
    'insert into public.match_players (match_id, user_id, spot) values ($1, $2, 1)',
    [PARTITA_FUTURA, U.bea],
  );
  await deveFallire(
    'due giocatori non possono occupare lo stesso posto',
    () => db.query(
      'insert into public.match_players (match_id, user_id, spot) values ($1, $2, 1)',
      [PARTITA_FUTURA, U.carlo],
    ),
    'duplicate key',
  );

  await deveFallire(
    'un posto fuori dal campo viene rifiutato',
    () => db.query(
      'insert into public.match_players (match_id, user_id, spot) values ($1, $2, 7)',
      [PARTITA_FUTURA, U.dina],
    ),
    'spot_check',
  );
}

async function testRegistrazioneRisultato() {
  console.log('\nREGISTRAZIONE DEL RISULTATO');

  await come(U.ester);
  await deveFallire(
    'chi non ha giocato non puo registrare il risultato',
    () => db.query('select public.registra_risultato($1, $2::jsonb)', [PARTITA, '[[6,4],[6,3]]']),
    'ha giocato',
  );

  // Bea e' iscritta alla partita futura: il controllo sulla data viene
  // valutato dopo quello sulla partecipazione, quindi serve un iscritto.
  await come(U.bea);
  await deveFallire(
    'non si registra il risultato di una partita non ancora giocata',
    () => db.query('select public.registra_risultato($1, $2::jsonb)', [PARTITA_FUTURA, '[[6,4],[6,3]]']),
    'ancora iniziata',
  );

  await come(U.aldo);
  await deveFallire(
    'un set finito in parita viene rifiutato',
    () => db.query('select public.registra_risultato($1, $2::jsonb)', [PARTITA, '[[6,6],[6,3]]']),
    'parit',
  );

  await deveFallire(
    'un solo set non basta',
    () => db.query('select public.registra_risultato($1, $2::jsonb)', [PARTITA, '[[6,4]]']),
    '2 o 3 set',
  );

  await deveFallire(
    'un punteggio senza vincitore viene rifiutato',
    () => db.query('select public.registra_risultato($1, $2::jsonb)', [PARTITA, '[[6,4],[3,6]]']),
    'vincitore',
  );

  // Aldo (Squadra A) registra: A vince il primo set, B il secondo e il terzo
  await come(U.carlo);
  await deveRiuscire('un giocatore registra il risultato', () => db.query(
    'select public.registra_risultato($1, $2::jsonb)', [PARTITA, '[[6,4],[3,6],[5,7]]'],
  ));

  const { rows } = await db.query(
    'select winner_team, stato, registrato_da from public.match_results where match_id = $1',
    [PARTITA],
  );
  uguale('il vincitore viene calcolato dal database', 'B', rows[0].winner_team);
  uguale('il risultato nasce in attesa di conferma', 'in_attesa', rows[0].stato);

  await deveFallire(
    'non si registra due volte lo stesso risultato',
    () => db.query('select public.registra_risultato($1, $2::jsonb)', [PARTITA, '[[6,0],[6,0]]']),
    'duplicate key',
  );
}

async function testFormazioneCongelata() {
  console.log('\nFORMAZIONE CONGELATA DOPO IL RISULTATO');

  await deveFallire(
    'con un risultato registrato non si puo uscire dalla partita',
    () => db.query(
      'delete from public.match_players where match_id = $1 and user_id = $2',
      [PARTITA, U.aldo],
    ),
    'risultato registrato',
  );
}

async function testConferma() {
  console.log('\nCONFERMA DEL RISULTATO');

  // Carlo ha registrato: Carlo e Dina sono la Squadra B
  await come(U.dina);
  await deveFallire(
    'un compagno di squadra non puo confermare',
    () => db.query('select public.conferma_risultato($1)', [PARTITA]),
    'avversario',
  );

  await come(U.ester);
  await deveFallire(
    'un estraneo non puo confermare',
    () => db.query('select public.conferma_risultato($1)', [PARTITA]),
    'non hai giocato',
  );

  await come(U.aldo);
  await deveRiuscire('un avversario conferma il risultato', () => db.query(
    'select public.conferma_risultato($1)', [PARTITA],
  ));

  const { rows } = await db.query(
    'select stato, confermato_da from public.match_results where match_id = $1', [PARTITA],
  );
  uguale('il risultato risulta confermato', 'confermato', rows[0].stato);
  uguale('viene registrato chi ha confermato', U.aldo, rows[0].confermato_da);

  await deveFallire(
    'non si conferma due volte',
    () => db.query('select public.conferma_risultato($1)', [PARTITA]),
    'gia',
  );
}

async function testStatistiche() {
  console.log('\nSTATISTICHE');

  const stat = async (uid) => {
    const { rows } = await db.query(
      'select * from public.statistiche_giocatore($1)', [uid],
    );
    return rows[0];
  };

  const carlo = await stat(U.carlo);
  uguale('il vincitore ha 1 partita', 1, carlo.partite);
  uguale('il vincitore ha 1 vittoria', 1, carlo.vittorie);
  uguale('il vincitore ha 0 sconfitte', 0, carlo.sconfitte);
  uguale('la percentuale del vincitore e 100', 100, carlo.percentuale_vittorie);

  const aldo = await stat(U.aldo);
  uguale('lo sconfitto ha 1 partita', 1, aldo.partite);
  uguale('lo sconfitto ha 0 vittorie', 0, aldo.vittorie);
  uguale('lo sconfitto ha 1 sconfitta', 1, aldo.sconfitte);

  const ester = await stat(U.ester);
  uguale('chi non ha giocato ha 0 partite', 0, ester.partite);

  // Il nome arriva dal profilo
  uguale('le statistiche includono il nome', 'Carlo', carlo.nome);
}

async function testStatisticheContestate() {
  console.log('\nUN RISULTATO CONTESTATO NON CONTA');

  // Si contesta solo un risultato ancora in attesa: la conferma di un
  // avversario e' definitiva (vedi testContestazioneRegole). Qui il
  // risultato viene riportato in attesa dall'esterno, per riprodurre la
  // situazione in cui nessuno ha ancora guardato il punteggio.
  await db.query(
    `update public.match_results set stato = 'in_attesa' where match_id = $1`, [PARTITA],
  );

  // Il punteggio l'ha inserito Carlo (Squadra B): Aldo e' un avversario
  await come(U.aldo);
  await deveRiuscire('un avversario contesta il risultato', () => db.query(
    'select public.contesta_risultato($1, $2)', [PARTITA, 'il terzo set non e mai stato giocato'],
  ));

  const { rows } = await db.query(
    'select * from public.statistiche_giocatore($1)', [U.carlo],
  );
  uguale('la partita contestata sparisce dalle statistiche', 0, rows[0].partite);

  // Si ripristina lo stato confermato per i test successivi
  await db.query(
    `update public.match_results set stato = 'confermato' where match_id = $1`, [PARTITA],
  );
  const dopo = await db.query('select * from public.statistiche_giocatore($1)', [U.carlo]);
  uguale('tornando confermata, la partita riappare', 1, dopo.rows[0].partite);
}

/**
 * Le regole della contestazione (aggiornamento n.7).
 * Senza questi limiti chi perdeva poteva contestare una partita gia'
 * confermata e cancellare la sconfitta dalle proprie statistiche.
 */
async function testContestazioneRegole() {
  console.log('\nLE REGOLE DELLA CONTESTAZIONE');

  // Il risultato di PARTITA e' confermato (fine del blocco precedente)
  await come(U.aldo);
  await deveFallire(
    'un risultato confermato non si puo piu contestare',
    () => db.query('select public.contesta_risultato($1, null)', [PARTITA]),
    'confermato',
  );

  await come(U.ester);
  await deveFallire(
    'chi non ha giocato non puo contestare',
    () => db.query('select public.contesta_risultato($1, null)', [PARTITA]),
    'non hai giocato',
  );

  await come(null);
  await deveFallire(
    'senza autenticazione non si contesta',
    () => db.query('select public.contesta_risultato($1, null)', [PARTITA]),
    'autenticato',
  );

  // Torniamo in attesa per provare i due casi che restano
  await db.query(
    `update public.match_results set stato = 'in_attesa' where match_id = $1`, [PARTITA],
  );

  await come(U.carlo);
  await deveFallire(
    'chi ha inserito il punteggio non puo contestarlo da solo',
    () => db.query('select public.contesta_risultato($1, null)', [PARTITA]),
    'hai inserito tu',
  );

  // Si invecchia il risultato oltre la finestra delle 48 ore: da qui in
  // avanti conta nelle statistiche di tutti, quindi non si tocca piu'.
  await db.query(
    `update public.match_results set registrato_il = now() - interval '72 hours'
     where match_id = $1`, [PARTITA],
  );

  await come(U.aldo);
  await deveFallire(
    'passate 48 ore la contestazione e chiusa',
    () => db.query('select public.contesta_risultato($1, null)', [PARTITA]),
    'scaduti',
  );

  // Si ripristina tutto per i test successivi
  await db.exec('reset role');
  await db.query(
    `update public.match_results
     set stato = 'confermato', registrato_il = now() where match_id = $1`, [PARTITA],
  );
}

/**
 * Il ruolo "gestore" si ottiene solo con un codice circolo valido
 * (aggiornamento n.7). Prima bastava un update dalla console del browser.
 */
async function testRuoloGestore() {
  console.log('\nIL RUOLO GESTORE NON SI AUTOASSEGNA');

  // La registrazione di un nuovo utente passa da un insert fatto dal
  // browser: i permessi per colonna non devono averla rotta.
  await db.exec('reset role');
  await db.query('insert into auth.users (id, email) values ($1, $2)', [U.nuovo, 'nuovo@test.it']);

  await come(U.nuovo);
  await db.exec('set role authenticated');

  await deveRiuscire('un nuovo utente crea il proprio profilo', () => db.query(
    `insert into public.profiles (id, nome, cognome, telefono, level, full_name)
     values ($1, 'Nuovo', 'Utente', '3331111111', 'intermedio', 'Nuovo Utente')`,
    [U.nuovo],
  ));

  const { rows: appena } = await db.query('select role, circolo from public.mio_profilo()');
  uguale('chi si registra nasce giocatore', 'giocatore', appena[0].role);
  uguale('chi si registra nasce senza circolo', null, appena[0].circolo);

  await come(U.ester);
  await db.exec('set role authenticated');

  // Primo lucchetto: "role" e "circolo" non sono fra le colonne
  // scrivibili, quindi il permesso viene negato prima di ogni altro
  // controllo.
  await deveFallire(
    'un utente non puo promuoversi gestore',
    () => db.query(
      `update public.profiles set role = 'gestore', circolo = 'Circolo Finto' where id = $1`,
      [U.ester],
    ),
    'permission denied',
  );

  await deveFallire(
    'un utente non puo nascere gestore',
    () => db.query(
      `insert into public.profiles (id, nome, cognome, full_name, role, circolo)
       values ($1, 'Finto', 'Gestore', 'Finto Gestore', 'gestore', 'Circolo Finto')`,
      ['77777777-7777-7777-7777-777777777777'],
    ),
    'permission denied',
  );

  // Cio' che l'utente deve poter fare continua a funzionare
  await deveRiuscire('il proprio profilo resta modificabile', () => db.query(
    `update public.profiles
     set nome = 'Ester', cognome = 'Gialli', telefono = '3339999999',
         level = 'avanzato', full_name = 'Ester Gialli', avatar_url = null
     where id = $1`,
    [U.ester],
  ));

  // La riga di un altro utente e' invisibile alla policy: l'update non
  // solleva un errore, semplicemente non tocca nulla. La verifica si fa
  // quindi sul risultato, non sull'eccezione.
  await db.query(`update public.profiles set nome = 'Manomesso' where id = $1`, [U.aldo]);

  const { rows: altrui } = await db.query(
    'select nome from public.profiles where id = $1', [U.aldo],
  );
  uguale('il profilo di un altro utente resta intatto', 'Aldo', altrui[0].nome);

  // Secondo lucchetto: si simula la distrazione di una migrazione futura
  // che riconcede la scrittura su tutta la tabella. I permessi di colonna
  // spariscono, il trigger deve reggere da solo.
  await db.exec('reset role');
  await db.exec('grant update on public.profiles to authenticated');

  await come(U.ester);
  await db.exec('set role authenticated');

  await deveFallire(
    'anche con i permessi riaperti il trigger blocca il cambio di ruolo',
    () => db.query(
      `update public.profiles set role = 'gestore', circolo = 'Circolo Finto' where id = $1`,
      [U.ester],
    ),
    'codice circolo',
  );

  // Si ripristinano i permessi come li lascia la migrazione n.7
  await db.exec('reset role');
  await db.exec('revoke update on public.profiles from authenticated');
  await db.exec(`grant update (nome, cognome, telefono, full_name, level, avatar_url)
                 on public.profiles to authenticated`);

  // La strada legittima: il codice circolo
  await db.exec('reset role');
  await db.query(
    `insert into public.club_codes (code, circolo, uso_singolo)
     values ('PAESTUM-2026', 'Padel Club Paestum', false)`,
  );

  await come(U.ester);
  await db.exec('set role authenticated');

  await deveRiuscire('con un codice valido si diventa gestore', () => db.query(
    `select public.usa_codice_circolo('PAESTUM-2026')`,
  ));

  const { rows } = await db.query('select role, circolo from public.mio_profilo()');
  uguale('il ruolo risulta gestore', 'gestore', rows[0].role);
  uguale('il circolo arriva dal codice, non dall utente', 'Padel Club Paestum', rows[0].circolo);

  await deveFallire(
    'un codice inesistente viene rifiutato',
    () => db.query(`select public.usa_codice_circolo('CODICE-INVENTATO')`),
    'non valido',
  );

  await db.exec('reset role');
}

/**
 * La data nel passato la rifiuta il database (aggiornamento n.7), non
 * piu' solo l'attributo "min" del campo data nel modulo di creazione.
 */
async function testDataPartita() {
  console.log('\nUNA PARTITA NON SI ORGANIZZA NEL PASSATO');

  const creaPartita = (giorni) => db.query(
    `insert into public.matches (club, zona, match_date, match_time, level, created_by)
     values ('Padel Village', 'paestum', current_date + ($1)::int, '20:00', 'intermedio', $2)`,
    [giorni, U.ester],
  );

  await come(U.ester);
  await db.exec('set role authenticated');

  await deveFallire(
    'una partita di ieri viene rifiutata',
    () => creaPartita(-1),
    'data passata',
  );

  await deveRiuscire('una partita di oggi si puo organizzare', () => creaPartita(0));
  await deveRiuscire('una partita di domani si puo organizzare', () => creaPartita(1));

  const { rows: mie } = await db.query(
    `select id from public.matches where created_by = $1 order by match_date`, [U.ester],
  );

  await deveFallire(
    'una partita non si puo spostare nel passato',
    () => db.query(
      `update public.matches set match_date = current_date - 5 where id = $1`, [mie[0].id],
    ),
    'data passata',
  );

  await deveRiuscire('una partita si puo correggere senza toccare la data', () => db.query(
    `update public.matches set club = 'Padel Village - campo 2' where id = $1`, [mie[0].id],
  ));

  await db.exec('reset role');

  // Le partite di prova appena create non devono disturbare i conteggi
  // dei test successivi, se in futuro qualcuno ne aggiungera'.
  await db.query('delete from public.matches where created_by = $1', [U.ester]);
}

/**
 * Le due funzioni sui posti sono state rimosse: erano scavalcabili e
 * dall'aggiornamento n.5 filled_slots lo mantiene un trigger.
 */
async function testPostiNonFalsificabili() {
  console.log('\nI POSTI OCCUPATI NON SI FALSIFICANO');

  await come(U.ester);
  await db.exec('set role authenticated');

  await deveFallire(
    'decrement_filled_slots non esiste piu',
    () => db.query('select public.decrement_filled_slots($1)', [PARTITA]),
    'does not exist',
  );

  await deveFallire(
    'increment_filled_slots non esiste piu',
    () => db.query('select public.increment_filled_slots($1)', [PARTITA]),
    'does not exist',
  );

  await db.exec('reset role');

  const { rows } = await db.query(
    `select filled_slots,
            (select count(*) from public.match_players where match_id = $1) as iscritti
     from public.matches where id = $1`, [PARTITA],
  );
  uguale('i posti occupati coincidono con gli iscritti', rows[0].iscritti, rows[0].filled_slots);
}

async function testClassifica() {
  console.log('\nCLASSIFICA');

  const { rows: conMinimo3 } = await db.query('select * from public.classifica(3)');
  uguale('con meno partite del minimo la classifica e vuota', 0, conMinimo3.length);

  const { rows } = await db.query('select * from public.classifica(1)');
  uguale('abbassando il minimo compaiono i 4 giocatori', 4, rows.length);
  uguale('in testa c e un vincitore', 100, rows[0].percentuale_vittorie);
  esito(
    'i vincitori precedono gli sconfitti',
    [U.carlo, U.dina].includes(rows[0].user_id),
    `primo in classifica: ${rows[0].user_id}`,
  );
  uguale('la classifica riporta il nome', true, Boolean(rows[0].nome));
}

async function testContatti() {
  console.log('\nCONTATTI DEI GIOCATORI');

  await come(U.ester);
  await deveFallire(
    'chi non gioca la partita non vede i contatti',
    () => db.query('select * from public.contatti_partita($1)', [PARTITA]),
    'solo ai giocatori',
  );

  await come(null);
  await deveFallire(
    'senza autenticazione i contatti non sono accessibili',
    () => db.query('select * from public.contatti_partita($1)', [PARTITA]),
    'autenticato',
  );

  await come(U.aldo);
  const { rows } = await db.query('select * from public.contatti_partita($1)', [PARTITA]);
  uguale('chi gioca vede i 4 compagni di partita', 4, rows.length);
  uguale('i contatti includono il telefono', '3330000001', rows[0].telefono);
  uguale('i contatti sono ordinati per posto', 0, rows[0].spot);
  uguale('la squadra viene calcolata dal posto', 'A', rows[0].squadra);
  uguale('il posto 2 appartiene alla squadra B', 'B', rows[2].squadra);
}

async function testPrivacyTelefono() {
  console.log('\nPROTEZIONE DELLA COLONNA TELEFONO');

  await come(U.aldo);
  await db.exec('set role authenticated');

  await deveFallire(
    'un utente registrato non puo leggere i telefoni altrui',
    () => db.query('select telefono from public.profiles'),
    'permission denied',
  );

  await deveRiuscire('le altre colonne restano leggibili', () => db.query(
    'select id, nome, cognome, level from public.profiles',
  ));

  const { rows } = await db.query('select * from public.mio_profilo()');
  uguale('ognuno vede il proprio numero', '3330000001', rows[0].telefono);

  await db.exec('reset role');
}

async function testPrivacyAnonimi() {
  console.log('\nACCESSO SENZA AUTENTICAZIONE');

  await come(null);
  await db.exec('set role anon');

  await deveFallire(
    'un anonimo non legge l anagrafica',
    () => db.query('select nome from public.profiles'),
    'permission denied',
  );

  const { rows: partite } = await db.query('select id from public.matches');
  esito('le partite restano pubbliche', partite.length >= 2, `trovate ${partite.length}`);

  const { rows: iscrizioni } = await db.query('select match_id from public.match_players');
  uguale('le iscrizioni non sono visibili agli anonimi', 0, iscrizioni.length);

  await db.exec('reset role');
}

/**
 * La partita e l'iscrizione dell'organizzatore nascono insieme
 * (aggiornamento n.8): prima erano due scritture separate, e una
 * connessione caduta a meta' lasciava una partita a zero giocatori.
 */
async function testCreazionePartita() {
  console.log('\nLA PARTITA NASCE CON IL SUO ORGANIZZATORE');

  await come(U.ester);
  await db.exec('set role authenticated');

  const { rows: creata } = await db.query(
    `select * from public.crea_partita('Padel Village', 'paestum',
       current_date + 4, '18:30', 'intermedio', 2::smallint)`,
  );
  uguale('la partita viene creata', 'Padel Village', creata[0].club);
  uguale('l organizzatore e gia in campo', 1, creata[0].filled_slots);

  const { rows: iscritti } = await db.query(
    'select user_id, spot from public.match_players where match_id = $1', [creata[0].id],
  );
  uguale('c e un solo iscritto', 1, iscritti.length);
  uguale('occupa il posto che ha scelto', 2, iscritti[0].spot);
  uguale('ed e chi ha creato la partita', U.ester, iscritti[0].user_id);

  await deveFallire(
    'un posto fuori dal campo viene rifiutato',
    () => db.query(
      `select public.crea_partita('X', 'paestum', current_date + 4, '18:30',
         'intermedio', 9::smallint)`,
    ),
    'fra 0 e 3',
  );

  await deveFallire(
    'un circolo vuoto viene rifiutato',
    () => db.query(
      `select public.crea_partita('   ', 'paestum', current_date + 4, '18:30',
         'intermedio', 0::smallint)`,
    ),
    'obbligatorio',
  );

  await deveFallire(
    'la data passata viene rifiutata anche da qui',
    () => db.query(
      `select public.crea_partita('X', 'paestum', current_date - 1, '18:30',
         'intermedio', 0::smallint)`,
    ),
    'data passata',
  );

  // Il punto della transazione: se la seconda scrittura fallisce, la
  // prima non deve restare. Il posto 2 e' gia' occupato da Ester, quindi
  // ricrearla identica fa fallire l'iscrizione.
  const { rows: prima } = await db.query('select count(*)::int as n from public.matches');

  await come(U.aldo);
  await db.exec('set role authenticated');
  await db.query(
    `insert into public.match_players (match_id, user_id, spot) values ($1, $2, 3)`,
    [creata[0].id, U.aldo],
  );

  // Aldo occupa gia' il posto 3 di quella partita: un secondo tentativo
  // sulla stessa partita non e' possibile, quindi si prova il caso
  // equivalente con un posto duplicato in una partita nuova.
  await db.exec('reset role');
  await db.exec(`create or replace function public.crea_partita_rotta()
    returns void language plpgsql security definer set search_path = public as $fn$
    declare p public.matches;
    begin
      insert into public.matches (club, zona, match_date, match_time, level, created_by)
      values ('Partita che non deve restare', 'paestum', current_date + 5, '19:00',
              'intermedio', auth.uid())
      returning * into p;
      -- Iscrizione impossibile: lo stesso giocatore su due posti
      insert into public.match_players (match_id, user_id, spot) values (p.id, auth.uid(), 0);
      insert into public.match_players (match_id, user_id, spot) values (p.id, auth.uid(), 1);
    end; $fn$;`);
  await db.exec('grant execute on function public.crea_partita_rotta() to authenticated');

  await come(U.aldo);
  await db.exec('set role authenticated');
  await deveFallire(
    'una seconda iscrizione impossibile annulla tutto',
    () => db.query('select public.crea_partita_rotta()'),
    'duplicate key',
  );

  await db.exec('reset role');
  const { rows: dopo } = await db.query('select count(*)::int as n from public.matches');
  uguale('nessuna partita fantasma e rimasta', prima[0].n, dopo[0].n);

  await db.exec('drop function public.crea_partita_rotta()');
  await db.query('delete from public.matches where id = $1', [creata[0].id]);
}

/**
 * Limiti sugli avatar e proprieta' dei file (aggiornamento n.8).
 */
async function testAvatar() {
  console.log('\nLIMITI SUGLI AVATAR');

  const { rows: bucket } = await db.query(
    `select file_size_limit, allowed_mime_types from storage.buckets where id = 'avatars'`,
  );
  uguale('il bucket accetta al massimo 2 MB', 2097152, bucket[0].file_size_limit);
  esito(
    'il bucket accetta solo immagini',
    bucket[0].allowed_mime_types.includes('image/jpeg')
      && !bucket[0].allowed_mime_types.some((t) => !t.startsWith('image/')),
    `tipi ammessi: ${bucket[0].allowed_mime_types}`,
  );

  await come(U.aldo);
  await db.exec('set role authenticated');

  await deveRiuscire('si carica un file col proprio identificativo', () => db.query(
    `insert into storage.objects (bucket_id, owner, name) values ('avatars', $1, $2)`,
    [U.aldo, `${U.aldo}-1700000000.png`],
  ));

  await deveFallire(
    'non si carica un file a nome di un altro',
    () => db.query(
      `insert into storage.objects (bucket_id, owner, name) values ('avatars', $1, $2)`,
      [U.aldo, `${U.bea}-1700000000.png`],
    ),
    'row-level security',
  );

  // La policy filtra le righe: la delete non solleva un errore,
  // semplicemente non trova nulla da cancellare. Si verifica quindi il
  // risultato, non l'eccezione.
  await db.exec('reset role');
  await db.query(
    `insert into storage.objects (bucket_id, owner, name) values ('avatars', $1, $2)`,
    [U.bea, `${U.bea}-1700000001.png`],
  );

  await come(U.aldo);
  await db.exec('set role authenticated');
  await db.query(`delete from storage.objects where name = $1`, [`${U.bea}-1700000001.png`]);

  await db.exec('reset role');
  const { rows: superstite } = await db.query(
    `select name from storage.objects where name = $1`, [`${U.bea}-1700000001.png`],
  );
  uguale('l avatar di un altro non si cancella', 1, superstite.length);
}

/**
 * Cancellazione dell'account (aggiornamento n.8): i dati personali
 * spariscono e l'accesso viene distrutto, ma le partite giocate
 * restano, altrimenti si riscriverebbe la storia degli avversari.
 */
async function testEliminaAccount() {
  console.log('\nCANCELLAZIONE DELL ACCOUNT');

  // Dina ha giocato la partita conclusa e ne ha una futura in programma
  await come(U.dina);
  await db.exec('set role authenticated');
  const { rows: futura } = await db.query(
    `select * from public.crea_partita('Padel Village', 'agropoli',
       current_date + 6, '21:00', 'avanzato', 0::smallint)`,
  );

  const statPrima = await db.query('select * from public.statistiche_giocatore($1)', [U.carlo]);

  await deveRiuscire('un utente cancella il proprio account', () => db.query(
    'select public.elimina_mio_account()',
  ));

  await db.exec('reset role');

  const { rows: profilo } = await db.query(
    'select nome, cognome, telefono, avatar_url, eliminato_il from public.profiles where id = $1',
    [U.dina],
  );
  uguale('il nome viene sostituito', 'Giocatore', profilo[0].nome);
  uguale('il telefono sparisce', null, profilo[0].telefono);
  uguale('la foto sparisce', null, profilo[0].avatar_url);
  esito('resta la data di cancellazione', Boolean(profilo[0].eliminato_il));

  const { rows: utente } = await db.query('select id from auth.users where id = $1', [U.dina]);
  uguale('l accesso non esiste piu', 0, utente.length);

  const { rows: partitaFutura } = await db.query(
    'select id from public.matches where id = $1', [futura[0].id],
  );
  uguale('la partita futura rimasta vuota viene rimossa', 0, partitaFutura.length);

  const { rows: ancoraInCampo } = await db.query(
    'select spot from public.match_players where match_id = $1 and user_id = $2',
    [PARTITA, U.dina],
  );
  uguale('resta in campo nella partita gia giocata', 1, ancoraInCampo.length);

  const statDopo = await db.query('select * from public.statistiche_giocatore($1)', [U.carlo]);
  uguale(
    'le statistiche del compagno non cambiano',
    statPrima.rows[0].partite, statDopo.rows[0].partite,
  );

  const { rows: classifica } = await db.query('select * from public.classifica(1)');
  esito(
    'chi ha cancellato l account non compare in classifica',
    !classifica.some((r) => r.user_id === U.dina),
    `in classifica: ${classifica.length} giocatori`,
  );
}

// ---------------------------------------------------------
// Avvio
// ---------------------------------------------------------
async function main() {
  console.log('='.repeat(60));
  console.log('PADEL CILENTO — test della logica di database (PGlite)');
  console.log('='.repeat(60));

  db = await PGlite.create();
  await db.exec(IMPALCATURA);

  await applicaMigrazioni();
  await seed();

  await testFormazione();
  await testRegistrazioneRisultato();
  await testFormazioneCongelata();
  await testConferma();
  await testStatistiche();
  await testStatisticheContestate();
  await testContestazioneRegole();
  await testClassifica();
  await testContatti();
  await testPrivacyTelefono();
  await testPrivacyAnonimi();
  await testRuoloGestore();
  await testDataPartita();
  await testPostiNonFalsificabili();
  await testCreazionePartita();
  await testAvatar();
  await testEliminaAccount();

  console.log('\n' + '='.repeat(60));
  if (falliti.length === 0) {
    console.log(`TUTTO A POSTO — ${passati} verifiche superate`);
  } else {
    console.log(`${passati} superate, ${falliti.length} FALLITE:`);
    falliti.forEach((f) => console.log(`  - ${f}`));
  }
  console.log('='.repeat(60));

  await db.close();
  process.exit(falliti.length ? 1 : 0);
}

main().catch((e) => {
  console.error('\nERRORE FATALE:', e.message);
  if (falliti.length) falliti.forEach((f) => console.error(`  - ${f}`));
  process.exit(1);
});
