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
const PARTITA_VECCHIA = 'aaaaaaaa-0000-0000-0000-000000000003';    // iscrizioni tardive
const PARTITA_CORREZIONE = 'aaaaaaaa-0000-0000-0000-000000000004'; // correzione del punteggio
const PARTITA_ADMIN = 'aaaaaaaa-0000-0000-0000-000000000005';      // moderazione

const CIRCOLO_NOME = 'Padel Agropoli';
const TORNEO = 'cccccccc-0000-0000-0000-000000000001';
const TORNEO_PARITA = 'cccccccc-0000-0000-0000-000000000002';
const TORNEO_FINALI = 'cccccccc-0000-0000-0000-000000000003';

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
  -- le colonne su cui l'aggiornamento n.7 impone i limiti agli avatar.
  create schema storage;
  create table storage.buckets (
    id text primary key,
    name text,
    public boolean default false,
    -- Colonne con cui Supabase applica i limiti di caricamento:
    -- il servizio Storage le legge PRIMA di scrivere il file, quindi
    -- il controllo non e' aggirabile dal browser.
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
 * Le regole della contestazione (aggiornamento n.9).
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
 * (aggiornamento n.9). Prima bastava un update dalla console del browser.
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

  // Si ripristinano i permessi come li lascia la migrazione n.9
  await db.exec('reset role');
  await db.exec('revoke update on public.profiles from authenticated');
  await db.exec(`grant update (nome, cognome, telefono, full_name, level, avatar_url)
                 on public.profiles to authenticated`);

  // La strada legittima: il codice circolo.
  //
  // Si usa un codice diverso da quello di testCodiceCircolo, e un utente
  // diverso da Ester: quel blocco verifica la protezione dai tentativi
  // ripetuti, e ha bisogno di trovare Ester ancora giocatrice e non
  // bloccata. Due test che si passano lo stato sono due test che prima o
  // poi si rompono a vicenda.
  await db.exec('reset role');
  await db.query(
    `insert into public.club_codes (code, circolo, uso_singolo)
     values ('CAPACCIO-2026', 'Padel Capaccio', false)`,
  );

  await come(U.nuovo);
  await db.exec('set role authenticated');

  await deveRiuscire('con un codice valido si diventa gestore', () => db.query(
    `select public.usa_codice_circolo('CAPACCIO-2026')`,
  ));

  const { rows } = await db.query('select role, circolo from public.mio_profilo()');
  uguale('il ruolo risulta gestore', 'gestore', rows[0].role);
  uguale('il circolo arriva dal codice, non dall utente', 'Padel Capaccio', rows[0].circolo);

  // Dall'aggiornamento sui tentativi ripetuti la funzione non solleva piu'
  // un'eccezione sui codici errati, ma restituisce l'esito: un'eccezione
  // annullerebbe la transazione, e con essa il contatore dei tentativi.
  const { rows: esitoErrato } = await db.query(
    `select public.usa_codice_circolo('CODICE-INVENTATO') as esito`,
  );
  const risposta = typeof esitoErrato[0].esito === 'string'
    ? JSON.parse(esitoErrato[0].esito)
    : esitoErrato[0].esito;
  esito(
    'un codice inesistente viene rifiutato',
    risposta.ok === false && /non valido/i.test(risposta.errore),
    `esito: ${JSON.stringify(risposta)}`,
  );

  await db.exec('reset role');
}

/**
 * La data nel passato la rifiuta il database (aggiornamento n.9), non
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
 * (aggiornamento n.10): prima erano due scritture separate, e una
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
 * Limiti sugli avatar e proprieta' dei file (aggiornamento n.10).
 */
async function testAvatar() {
  console.log('\nDI CHI SONO I FILE DEGLI AVATAR');

  // Dimensione massima e formati ammessi sono verificati in
  // testLimitiAvatar: qui si controlla solo di chi sono i file.
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
 * Cancellazione dell'account (aggiornamento n.10): i dati personali
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

/**
 * Non ci si iscrive a una partita gia' iniziata (aggiornamento n.11).
 */
async function testIscrizioneTardiva() {
  console.log('\nNON CI SI ISCRIVE A PARTITE GIA GIOCATE');

  await db.exec('reset role');
  await db.query(
    `insert into public.matches (id, club, zona, match_date, match_time, level, created_by)
     values ($1, 'Campo vecchio', 'paestum', current_date - 30, '20:00', 'intermedio', $2)`,
    [PARTITA_VECCHIA, U.aldo],
  );

  await come(U.bea);
  await db.exec('set role authenticated');

  await deveFallire(
    'una partita di un mese fa non accetta iscrizioni',
    () => db.query(
      'insert into public.match_players (match_id, user_id, spot) values ($1, $2, 0)',
      [PARTITA_VECCHIA, U.bea],
    ),
    'gia',
  );

  // Bea occupa gia' un posto in PARTITA_FUTURA (test della formazione):
  // per il caso positivo serve un giocatore che non ci sia ancora.
  await come(U.carlo);
  await db.exec('set role authenticated');
  await deveRiuscire('una partita futura le accetta', () => db.query(
    'insert into public.match_players (match_id, user_id, spot) values ($1, $2, 3)',
    [PARTITA_FUTURA, U.carlo],
  ));

  await db.exec('reset role');
  await db.query('delete from public.match_players where match_id = $1 and user_id = $2',
    [PARTITA_FUTURA, U.carlo]);
}

/**
 * La correzione del punteggio (aggiornamento n.11): prima, se si
 * sbagliava a digitare, non c'era rimedio.
 */
async function testCorrezioneRisultato() {
  console.log('\nCORREZIONE DEL PUNTEGGIO');

  // Partita conclusa a se stante, per non disturbare le statistiche
  await db.exec('reset role');
  await db.query(
    `insert into public.matches (id, club, zona, match_date, match_time, level, created_by)
     values ($1, 'Campo prova', 'capaccio', current_date - 1, '19:00', 'intermedio', $2)`,
    [PARTITA_CORREZIONE, U.aldo],
  );
  for (const [uid, spot] of [[U.aldo, 0], [U.bea, 1], [U.carlo, 2], [U.ester, 3]]) {
    await db.query(
      'insert into public.match_players (match_id, user_id, spot) values ($1, $2, $3)',
      [PARTITA_CORREZIONE, uid, spot],
    );
  }

  await come(U.aldo);
  await db.query('select public.registra_risultato($1, $2::jsonb)',
    [PARTITA_CORREZIONE, '[[6, 4], [6, 3]]']);

  await come(U.bea);
  await deveFallire(
    'il punteggio altrui non si corregge, si contesta',
    () => db.query('select public.correggi_risultato($1, $2::jsonb)',
      [PARTITA_CORREZIONE, '[[1, 6], [1, 6]]']),
    'contestalo',
  );

  await come(U.aldo);
  await deveRiuscire('chi ha sbagliato corregge il proprio punteggio', () => db.query(
    'select public.correggi_risultato($1, $2::jsonb)', [PARTITA_CORREZIONE, '[[6, 4], [3, 6], [6, 2]]'],
  ));

  const { rows: dopo } = await db.query(
    'select sets, winner_team, stato from public.match_results where match_id = $1',
    [PARTITA_CORREZIONE],
  );
  uguale('il punteggio e aggiornato', 3, dopo[0].sets.length);
  uguale('il vincitore viene ricalcolato', 'A', dopo[0].winner_team);
  uguale('torna in attesa di conferma', 'in_attesa', dopo[0].stato);

  // Il caso che prima non aveva uscita: risultato contestato
  await come(U.carlo);
  await db.query('select public.contesta_risultato($1, $2)',
    [PARTITA_CORREZIONE, 'il terzo set fu 6-4']);

  await deveRiuscire('da una contestazione si esce correggendo', () => db.query(
    'select public.correggi_risultato($1, $2::jsonb)', [PARTITA_CORREZIONE, '[[6, 4], [3, 6], [6, 4]]'],
  ));

  const { rows: risolto } = await db.query(
    'select stato, registrato_da, nota_contestazione from public.match_results where match_id = $1',
    [PARTITA_CORREZIONE],
  );
  uguale('la contestazione e sciolta', 'in_attesa', risolto[0].stato);
  uguale('il punteggio e ora di chi ha corretto', U.carlo, risolto[0].registrato_da);
  uguale('la nota di contestazione viene azzerata', null, risolto[0].nota_contestazione);

  // Una volta confermato, non si torna indietro
  await come(U.aldo);
  await db.query('select public.conferma_risultato($1)', [PARTITA_CORREZIONE]);

  await come(U.carlo);
  await deveFallire(
    'un risultato confermato non si corregge',
    () => db.query('select public.correggi_risultato($1, $2::jsonb)',
      [PARTITA_CORREZIONE, '[[6, 0], [6, 0]]']),
    'confermato',
  );

  await come(U.ester);
  await deveFallire(
    'chi non ha giocato non corregge',
    () => db.query('select public.correggi_risultato($1, $2::jsonb)',
      [PARTITA, '[[6, 0], [6, 0]]']),
    'ha giocato',
  );
}

/**
 * L'amministratore (aggiornamento n.11).
 */
async function testAmministratore() {
  console.log('\nL AMMINISTRATORE');

  // Il ruolo si assegna solo da fuori: dal browser e' bloccato
  await come(U.bea);
  await db.exec('set role authenticated');
  await deveFallire(
    'nessuno si nomina amministratore da solo',
    () => db.query(`update public.profiles set role = 'admin' where id = $1`, [U.bea]),
    'permission denied',
  );

  await db.exec('reset role');
  await db.query(`update public.profiles set role = 'admin' where id = $1`, [U.bea]);

  await come(U.bea);
  await db.exec('set role authenticated');
  const { rows: chi } = await db.query('select public.e_amministratore() as si');
  uguale('viene riconosciuto come amministratore', true, chi[0].si);

  // Una partita di un altro utente
  await db.exec('reset role');
  await db.query(
    `insert into public.matches (id, club, zona, match_date, match_time, level, created_by)
     values ($1, 'Partita da moderare', 'agropoli', current_date + 2, '20:00', 'open', $2)`,
    [PARTITA_ADMIN, U.aldo],
  );

  await come(U.carlo);
  await db.exec('set role authenticated');
  await db.query(`update public.matches set club = 'Manomessa' where id = $1`, [PARTITA_ADMIN]);
  const { rows: intatta } = await db.query(
    'select club from public.matches where id = $1', [PARTITA_ADMIN],
  );
  uguale('un utente qualunque non modifica le partite altrui', 'Partita da moderare', intatta[0].club);

  await come(U.bea);
  await db.exec('set role authenticated');
  await deveRiuscire('l amministratore corregge una partita altrui', () => db.query(
    `update public.matches set club = 'Nome corretto' where id = $1`, [PARTITA_ADMIN],
  ));
  const { rows: corretta } = await db.query(
    'select club from public.matches where id = $1', [PARTITA_ADMIN],
  );
  uguale('la correzione viene salvata', 'Nome corretto', corretta[0].club);

  await deveRiuscire('l amministratore elimina una partita altrui', () => db.query(
    'delete from public.matches where id = $1', [PARTITA_ADMIN],
  ));
  const { rows: sparita } = await db.query(
    'select id from public.matches where id = $1', [PARTITA_ADMIN],
  );
  uguale('la partita e sparita', 0, sparita.length);

  // Il caso che prima era impossibile per chiunque
  await deveRiuscire('l amministratore elimina una partita CONCLUSA', () => db.query(
    'delete from public.matches where id = $1', [PARTITA_CORREZIONE],
  ));

  const { rows: iscrizioni } = await db.query(
    'select id from public.match_players where match_id = $1', [PARTITA_CORREZIONE],
  );
  uguale('spariscono anche le iscrizioni', 0, iscrizioni.length);

  // Annullare un risultato: l'uscita di sicurezza da una contestazione
  await db.exec('reset role');
  await db.query(`update public.match_results set stato = 'contestato' where match_id = $1`, [PARTITA]);

  await come(U.bea);
  await db.exec('set role authenticated');
  await deveRiuscire('l amministratore annulla un risultato', () => db.query(
    'delete from public.match_results where match_id = $1', [PARTITA],
  ));

  await db.exec('reset role');
  const { rows: senzaRisultato } = await db.query(
    'select match_id from public.match_results where match_id = $1', [PARTITA],
  );
  uguale('il risultato e stato annullato', 0, senzaRisultato.length);

  // Bea torna giocatrice, per non lasciare in giro poteri nei test futuri
  await db.query(`update public.profiles set role = 'giocatore' where id = $1`, [U.bea]);
}

async function testLimitiAvatar() {
  console.log('\nLIMITI DI CARICAMENTO DEGLI AVATAR');

  const { rows } = await db.query(
    'select file_size_limit, allowed_mime_types from storage.buckets where id = $1',
    ['avatars'],
  );

  esito('il bucket avatars esiste', rows.length === 1);

  const limite = rows[0]?.file_size_limit;
  uguale('la dimensione massima e 2 MB', 2097152, limite);

  const tipi = rows[0]?.allowed_mime_types || [];
  esito('sono ammesse le immagini JPEG', tipi.includes('image/jpeg'), `tipi: ${tipi}`);
  esito('sono ammesse le immagini PNG', tipi.includes('image/png'), `tipi: ${tipi}`);
  esito('sono ammesse le immagini WebP', tipi.includes('image/webp'), `tipi: ${tipi}`);
  esito('i PDF non sono ammessi', !tipi.includes('application/pdf'), `tipi: ${tipi}`);
  esito(
    'gli SVG non sono ammessi (possono contenere script)',
    !tipi.includes('image/svg+xml'),
    `tipi: ${tipi}`,
  );
}

/** Legge l'esito jsonb restituito da usa_codice_circolo. */
async function provaCodice(codice) {
  const { rows } = await db.query('select public.usa_codice_circolo($1) as esito', [codice]);
  const e = rows[0].esito;
  return typeof e === 'string' ? JSON.parse(e) : e;
}

async function testCodiceCircolo() {
  console.log('\nCODICE CIRCOLO E PROTEZIONE DAI TENTATIVI RIPETUTI');

  await db.query(
    `insert into public.club_codes (code, circolo, uso_singolo)
     values ('PAESTUM-2026', 'Padel Club Paestum', false)`,
  );

  // ----- Il registro dei tentativi non e' leggibile dal browser -----
  await come(U.ester);
  await db.exec('set role authenticated');
  await deveFallire(
    'il registro dei tentativi non e leggibile da un utente registrato',
    () => db.query('select * from public.tentativi_codice_circolo'),
    'permission denied',
  );
  await db.exec('reset role');

  // ----- Quattro tentativi sbagliati: si puo' ancora riprovare -----
  await come(U.ester);
  let esitoCorrente;
  for (let i = 1; i <= 4; i++) {
    esitoCorrente = await provaCodice('CODICE-INVENTATO');
  }
  esito('dopo 4 tentativi sbagliati non si e ancora bloccati',
    esitoCorrente.ok === false && /non valido/i.test(esitoCorrente.errore),
    `esito: ${JSON.stringify(esitoCorrente)}`);

  // ----- Il quinto fa scattare il blocco -----
  esitoCorrente = await provaCodice('CODICE-INVENTATO');
  esito('al quinto tentativo sbagliato scatta il blocco',
    esitoCorrente.ok === false && /troppi tentativi/i.test(esitoCorrente.errore),
    `esito: ${JSON.stringify(esitoCorrente)}`);

  // ----- Il blocco vale anche per il codice CORRETTO -----
  // E' la proprieta' che rende utile la protezione: se il codice giusto
  // continuasse a funzionare, basterebbe insistere per aggirarla.
  esitoCorrente = await provaCodice('PAESTUM-2026');
  esito('durante il blocco non funziona nemmeno il codice corretto',
    esitoCorrente.ok === false && /troppi tentativi/i.test(esitoCorrente.errore),
    `esito: ${JSON.stringify(esitoCorrente)}`);

  const { rows: ruoloEster } = await db.query(
    'select role from public.profiles where id = $1', [U.ester],
  );
  uguale('chi e bloccato non diventa gestore', 'giocatore', ruoloEster[0].role);

  // ----- Il blocco riguarda solo chi ha sbagliato -----
  await come(U.dina);
  const esitoDina = await provaCodice('PAESTUM-2026');
  esito('un altro utente non e coinvolto dal blocco',
    esitoDina.ok === true && esitoDina.circolo === 'Padel Club Paestum',
    `esito: ${JSON.stringify(esitoDina)}`);

  const { rows: ruoloDina } = await db.query(
    'select role, circolo from public.profiles where id = $1', [U.dina],
  );
  uguale('il codice valido promuove a gestore', 'gestore', ruoloDina[0].role);
  uguale('il circolo viene assegnato', 'Padel Club Paestum', ruoloDina[0].circolo);

  // ----- Un uso riuscito azzera il contatore -----
  const { rows: registro } = await db.query(
    'select count(*)::int as n from public.tentativi_codice_circolo where user_id = $1',
    [U.dina],
  );
  uguale('un uso riuscito azzera il contatore', 0, registro[0].n);

  // ----- Un codice disattivato non funziona -----
  await db.query(`update public.club_codes set attivo = false where code = 'PAESTUM-2026'`);
  await come(U.carlo);
  const esitoDisattivato = await provaCodice('PAESTUM-2026');
  esito('un codice disattivato viene rifiutato',
    esitoDisattivato.ok === false && /attivo/i.test(esitoDisattivato.errore),
    `esito: ${JSON.stringify(esitoDisattivato)}`);

  // ----- Senza autenticazione la funzione rifiuta -----
  await come(null);
  await deveFallire(
    'senza autenticazione il codice non e utilizzabile',
    () => db.query(`select public.usa_codice_circolo('PAESTUM-2026')`),
    'autenticato',
  );
}

/**
 * Il circolo come entita' (aggiornamento n.13). Prima era una stringa
 * scritta a mano, e "Padel Village" e "padel village" erano due circoli.
 */
async function testCircoli() {
  console.log('\nIL CIRCOLO COME ENTITA');

  // Solo l'amministratore crea circoli
  await come(U.carlo);
  await db.exec('set role authenticated');
  await deveFallire(
    'un utente qualunque non crea un circolo',
    () => db.query(`insert into public.circoli (nome, zona) values ('Circolo Abusivo', 'paestum')`),
    'row-level security',
  );

  await db.exec('reset role');
  await db.query(`update public.profiles set role = 'admin' where id = $1`, [U.carlo]);

  await come(U.carlo);
  await db.exec('set role authenticated');
  await deveRiuscire('l amministratore crea un circolo', () => db.query(
    `insert into public.circoli (nome, zona, telefono) values ($1, 'agropoli', '0974000000')`,
    [CIRCOLO_NOME],
  ));

  // Il punto di tutta la migrazione
  await deveFallire(
    'due circoli non possono avere lo stesso nome',
    () => db.query(`insert into public.circoli (nome, zona) values ($1, 'paestum')`, [CIRCOLO_NOME]),
    'duplicate key',
  );
  await deveFallire(
    'il confronto ignora maiuscole e spazi',
    () => db.query(`insert into public.circoli (nome, zona) values ($1, 'paestum')`,
      [`  ${CIRCOLO_NOME.toUpperCase()}  `]),
    'duplicate key',
  );

  await db.exec('reset role');
  const { rows: circolo } = await db.query(
    'select id, attivo from public.circoli where nome = $1', [CIRCOLO_NOME],
  );
  const idCircolo = circolo[0].id;

  // Visibili a tutti: i tabelloni dei tornei li legge anche chi non ha l'account
  await come(null);
  await db.exec('set role anon');
  const { rows: visti } = await db.query('select nome from public.circoli');
  esito('i circoli sono visibili anche senza accesso', visti.length >= 1, `visti: ${visti.length}`);
  await db.exec('reset role');

  // ----- Il codice assegna il circolo, non piu' solo il nome -----
  await db.query(
    `insert into public.club_codes (code, circolo, circolo_id, uso_singolo)
     values ('AGROPOLI-2027', $1, $2, false)`, [CIRCOLO_NOME, idCircolo],
  );

  // Non Ester: testCodiceCircolo la porta di proposito a cinque tentativi
  // falliti, quindi qui sarebbe ancora bloccata. E' la protezione che
  // funziona, non un intoppo.
  await come(U.bea);
  await db.exec('set role authenticated');
  const esitoCodice = await provaCodice('AGROPOLI-2027');
  esito('il codice funziona', esitoCodice.ok === true, JSON.stringify(esitoCodice));

  const { rows: profilo } = await db.query('select circolo_id, role from public.mio_profilo()');
  uguale('il gestore viene collegato al circolo', idCircolo, profilo[0].circolo_id);
  uguale('ed e gestore', 'gestore', profilo[0].role);

  // ----- Chi gestisce cosa -----
  const gestisce = async (uid, idc) => {
    await come(uid);
    const { rows } = await db.query('select public.e_gestore_del_circolo($1) as si', [idc]);
    return rows[0].si;
  };

  uguale('il gestore gestisce il proprio circolo', true, await gestisce(U.bea, idCircolo));
  uguale('un altro utente no', false, await gestisce(U.aldo, idCircolo));
  uguale('l amministratore gestisce qualunque circolo', true, await gestisce(U.carlo, idCircolo));

  // ----- L'interruttore commerciale -----
  await db.exec('reset role');
  await db.query(`update public.circoli set attivo = false where id = $1`, [idCircolo]);

  uguale('un circolo sospeso non e utilizzabile', false,
    (await db.query('select public.circolo_utilizzabile($1) as si', [idCircolo])).rows[0].si);
  uguale('e il suo gestore perde i poteri', false, await gestisce(U.bea, idCircolo));
  uguale('ma l amministratore interviene lo stesso', true, await gestisce(U.carlo, idCircolo));

  await db.exec('reset role');
  await db.query(
    `update public.circoli set attivo = true, abbonamento_scade_il = current_date - 1 where id = $1`,
    [idCircolo],
  );
  uguale('un abbonamento scaduto vale come sospeso', false,
    (await db.query('select public.circolo_utilizzabile($1) as si', [idCircolo])).rows[0].si);

  // Un cliente che non rinnova non abilita nuovi gestori
  await db.query(
    `insert into public.club_codes (code, circolo, circolo_id, uso_singolo)
     values ('AGROPOLI-SCADUTO', $1, $2, false)`, [CIRCOLO_NOME, idCircolo],
  );
  await come(U.dina);
  const esitoScaduto = await provaCodice('AGROPOLI-SCADUTO');
  esito('con l abbonamento scaduto il codice non funziona',
    esitoScaduto.ok === false && /abbonamento/i.test(esitoScaduto.errore),
    JSON.stringify(esitoScaduto));

  await db.exec('reset role');
  await db.query(
    `update public.circoli set abbonamento_scade_il = current_date + 365 where id = $1`,
    [idCircolo],
  );
  uguale('rinnovando torna utilizzabile', true,
    (await db.query('select public.circolo_utilizzabile($1) as si', [idCircolo])).rows[0].si);

  // ----- Il legame non si scrive dal browser -----
  await come(U.aldo);
  await db.exec('set role authenticated');
  await deveFallire(
    'un utente non si collega da solo a un circolo',
    () => db.query('update public.profiles set circolo_id = $1 where id = $2', [idCircolo, U.aldo]),
    'permission denied',
  );

  await db.exec('reset role');
  await db.exec('grant update on public.profiles to authenticated');
  await come(U.aldo);
  await db.exec('set role authenticated');
  await deveFallire(
    'anche con i permessi riaperti il trigger lo impedisce',
    () => db.query('update public.profiles set circolo_id = $1 where id = $2', [idCircolo, U.aldo]),
    'codice circolo',
  );

  await db.exec('reset role');
  await db.exec('revoke update on public.profiles from authenticated');
  await db.exec(`grant update (nome, cognome, telefono, full_name, level, avatar_url)
                 on public.profiles to authenticated`);

  // Carlo torna giocatore: i poteri non si lasciano in giro
  await db.query(`update public.profiles set role = 'giocatore' where id = $1`, [U.carlo]);
}

/**
 * La modalita' torneo (aggiornamenti n.14 e n.15): un torneo intero,
 * dalla creazione alla classifica, come lo userebbe un circolo.
 */
async function testTornei() {
  console.log('\nMODALITA TORNEO');

  // Bea e' gestore di CIRCOLO_NOME dal blocco precedente
  await db.exec('reset role');
  const { rows: c } = await db.query('select id from public.circoli where nome = $1', [CIRCOLO_NOME]);
  const idCircolo = c[0].id;

  // ----- Creazione -----
  await come(U.aldo);
  await db.exec('set role authenticated');
  await deveFallire(
    'un giocatore non crea tornei',
    () => db.query(
      `insert into public.tornei (circolo_id, nome, creato_da) values ($1, 'Torneo abusivo', $2)`,
      [idCircolo, U.aldo],
    ),
    'row-level security',
  );

  await come(U.bea);
  await db.exec('set role authenticated');
  await deveRiuscire('il circolo crea il proprio torneo', () => db.query(
    `insert into public.tornei (id, circolo_id, nome, livello, creato_da)
     values ($1, $2, 'Torneo d estate', 'intermedio', $3)`,
    [TORNEO, idCircolo, U.bea],
  ));

  // ----- Un torneo in bozza non e' pubblico -----
  await come(null);
  await db.exec('set role anon');
  const { rows: bozzaAnon } = await db.query('select id from public.tornei where id = $1', [TORNEO]);
  uguale('un torneo in bozza non si vede da fuori', 0, bozzaAnon.length);
  await db.exec('reset role');

  // ----- Gironi e squadre -----
  await come(U.bea);
  await db.exec('set role authenticated');

  for (const [nome, ordine] of [['A', 1], ['B', 2]]) {
    await db.query(
      `insert into public.tornei_gironi (torneo_id, nome, ordine) values ($1, $2, $3)`,
      [TORNEO, nome, ordine],
    );
  }
  const { rows: gironi } = await db.query(
    'select id, nome from public.tornei_gironi where torneo_id = $1 order by ordine', [TORNEO],
  );
  uguale('i gironi sono due', 2, gironi.length);
  const gironeA = gironi[0].id;

  // Quattro coppie nel girone A, due nel B: nomi scritti a mano dal
  // circolo, senza che i giocatori abbiano un account.
  const coppieA = [
    ['Rossi Mario', 'Bianchi Luca'],
    ['Verdi Anna', 'Neri Sara'],
    ['Gialli Paolo', 'Blu Marco'],
    ['Viola Elena', 'Grigi Ugo'],
  ];
  for (const [g1, g2] of coppieA) {
    await db.query(
      `insert into public.torneo_squadre (torneo_id, giocatore_1, giocatore_2, girone_id)
       values ($1, $2, $3, $4)`, [TORNEO, g1, g2, gironeA],
    );
  }
  await db.query(
    `insert into public.torneo_squadre (torneo_id, giocatore_1, giocatore_2, girone_id)
     values ($1, 'Alfa Uno', 'Alfa Due', $2), ($1, 'Beta Uno', 'Beta Due', $2)`,
    [TORNEO, gironi[1].id],
  );

  await deveRiuscire('si iscrive una coppia collegata a due account', () => db.query(
    `insert into public.torneo_squadre
       (torneo_id, giocatore_1, giocatore_2, user_id_1, user_id_2, girone_id)
     values ($1, 'Aldo Rossi', 'Carlo Verdi', $2, $3, $4)`,
    [TORNEO, U.aldo, U.carlo, gironi[1].id],
  ));

  await deveFallire(
    'lo stesso giocatore non entra in due coppie',
    () => db.query(
      `insert into public.torneo_squadre (torneo_id, giocatore_1, giocatore_2, user_id_1, girone_id)
       values ($1, 'Aldo Rossi', 'Altro Tizio', $2, $3)`,
      [TORNEO, U.aldo, gironi[1].id],
    ),
    'gia',
  );

  await deveFallire(
    'una coppia non gioca con se stessa',
    () => db.query(
      `insert into public.torneo_squadre (torneo_id, giocatore_1, giocatore_2, user_id_1, user_id_2)
       values ($1, 'X', 'Y', $2, $2)`, [TORNEO, U.dina],
    ),
    'violates check constraint',
  );

  // ----- Il calendario -----
  await deveFallire(
    'il torneo non parte senza calendario',
    () => db.query(`select public.torneo_cambia_stato($1, 'in_corso')`, [TORNEO]),
    'iscrizioni',
  );

  await deveRiuscire('si aprono le iscrizioni', () => db.query(
    `select public.torneo_cambia_stato($1, 'iscrizioni')`, [TORNEO],
  ));

  const { rows: gen } = await db.query('select public.torneo_genera_calendario($1) as n', [TORNEO]);
  // Girone A: 4 squadre = 6 incontri. Girone B: 3 squadre = 3 incontri.
  uguale('il calendario genera 9 incontri', 9, gen[0].n);

  const { rows: turniA } = await db.query(
    `select turno, count(*)::int as n from public.torneo_incontri
     where girone_id = $1 group by turno order by turno`, [gironeA],
  );
  uguale('il girone da 4 squadre ha 3 turni', 3, turniA.length);
  esito('in ogni turno si giocano 2 incontri', turniA.every((t) => t.n === 2),
    JSON.stringify(turniA));

  // Nessuna squadra gioca due volte nello stesso turno: e' il punto
  // del metodo all'italiana.
  const { rows: doppioni } = await db.query(
    `select turno, sq, count(*)::int as n from (
       select turno, squadra_casa as sq from public.torneo_incontri where girone_id = $1
       union all
       select turno, squadra_ospite from public.torneo_incontri where girone_id = $1
     ) x group by turno, sq having count(*) > 1`, [gironeA],
  );
  uguale('nessuna squadra gioca due volte nello stesso turno', 0, doppioni.length);

  const { rows: coppie } = await db.query(
    `select count(distinct least(squadra_casa::text, squadra_ospite::text)
              || greatest(squadra_casa::text, squadra_ospite::text))::int as n
     from public.torneo_incontri where girone_id = $1`, [gironeA],
  );
  uguale('ogni coppia di squadre si incontra una volta sola', 6, coppie[0].n);

  // ----- Avvio e risultati -----
  await deveRiuscire('il torneo si avvia', () => db.query(
    `select public.torneo_cambia_stato($1, 'in_corso')`, [TORNEO],
  ));

  await deveFallire(
    'lo stato non si cambia scrivendolo a mano',
    () => db.query(`update public.tornei set stato = 'concluso' where id = $1`, [TORNEO]),
    'torneo_cambia_stato',
  );

  const { rows: incontriA } = await db.query(
    `select id, squadra_casa, squadra_ospite from public.torneo_incontri
     where girone_id = $1 order by turno, ordine`, [gironeA],
  );

  await deveRiuscire('il circolo registra un risultato', () => db.query(
    'select public.torneo_registra_risultato($1, $2::jsonb)',
    [incontriA[0].id, '[[6,4],[6,3]]'],
  ));

  const { rows: primo } = await db.query(
    'select vincitore, registrato_da from public.torneo_incontri where id = $1', [incontriA[0].id],
  );
  uguale('il vincitore lo calcola il database', 'C', primo[0].vincitore);
  uguale('resta scritto chi lo ha inserito', U.bea, primo[0].registrato_da);

  await deveFallire(
    'un punteggio impossibile viene rifiutato',
    () => db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
      [incontriA[1].id, '[[6,4]]']),
    '2 o 3 set',
  );

  await come(U.dina);
  await deveFallire(
    'un estraneo non inserisce risultati',
    () => db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
      [incontriA[1].id, '[[6,0],[6,0]]']),
    'solo il circolo',
  );

  // ----- La classifica -----
  await come(U.bea);
  await db.exec('set role authenticated');
  for (let i = 1; i < incontriA.length; i++) {
    await db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
      [incontriA[i].id, '[[6,2],[6,2]]']);
  }

  await db.exec('reset role');
  const { rows: cls } = await db.query('select * from public.classifica_girone($1)', [gironeA]);
  uguale('la classifica ha una riga per squadra', 4, cls.length);
  uguale('la prima e in posizione 1', 1, cls[0].posizione);
  uguale('chi ha giocato 3 partite le ha tutte contate', 3, cls[0].partite);
  esito('i punti sono 3 per vittoria',
    cls.every((r) => r.punti === r.vittorie * 3), JSON.stringify(cls.map((r) => [r.punti, r.vittorie])));
  esito('la classifica e ordinata per punti',
    cls.every((r, i) => i === 0 || cls[i - 1].punti >= r.punti),
    JSON.stringify(cls.map((r) => r.punti)));
  esito('il nome della squadra si compone dai due giocatori',
    cls.every((r) => r.nome.includes(' / ')), cls[0].nome);

  // Somma di controllo: 6 incontri, 12 partecipazioni, 6 vittorie
  const totPartite = cls.reduce((s, r) => s + r.partite, 0);
  const totVittorie = cls.reduce((s, r) => s + r.vittorie, 0);
  uguale('le partite giocate tornano', 12, totPartite);
  uguale('le vittorie tornano', 6, totVittorie);

  // ----- Ora il torneo e' pubblico -----
  await come(null);
  await db.exec('set role anon');
  const { rows: pubblico } = await db.query('select nome from public.tornei where id = $1', [TORNEO]);
  uguale('un torneo avviato lo vedono tutti', 1, pubblico.length);
  const { rows: clsAnon } = await db.query('select * from public.classifica_girone($1)', [gironeA]);
  uguale('e la classifica si legge anche senza account', 4, clsAnon.length);
  await db.exec('reset role');
}

/**
 * Il criterio di parita' con tre squadre a pari punti: e' il caso che
 * rompe quasi tutte le classifiche fatte in casa.
 */
async function testParitaClassifica() {
  console.log('\nCLASSIFICA: TRE SQUADRE A PARI PUNTI');

  await db.exec('reset role');
  const { rows: c } = await db.query('select id from public.circoli where nome = $1', [CIRCOLO_NOME]);

  await come(U.bea);
  await db.exec('set role authenticated');
  await db.query(
    `insert into public.tornei (id, circolo_id, nome, creato_da) values ($1, $2, 'Torneo parita', $3)`,
    [TORNEO_PARITA, c[0].id, U.bea],
  );
  await db.query(
    `insert into public.tornei_gironi (torneo_id, nome, ordine) values ($1, 'A', 1)`, [TORNEO_PARITA],
  );
  const { rows: g } = await db.query(
    'select id from public.tornei_gironi where torneo_id = $1', [TORNEO_PARITA],
  );
  const girone = g[0].id;

  // Tre squadre che si battono in cerchio: A>B, B>C, C>A.
  // Tutte a 3 punti: lo scontro diretto singolo non decide niente,
  // e la classifica ridotta deve guardare set e game.
  const squadre = {};
  for (const nome of ['Alfa', 'Beta', 'Gamma']) {
    const { rows } = await db.query(
      `insert into public.torneo_squadre (torneo_id, nome, giocatore_1, giocatore_2, girone_id)
       values ($1, $2, $3, $4, $5) returning id`,
      [TORNEO_PARITA, nome, `${nome} Uno`, `${nome} Due`, girone],
    );
    squadre[nome] = rows[0].id;
  }

  const incontro = async (casa, ospite, sets) => {
    const { rows } = await db.query(
      `insert into public.torneo_incontri
         (torneo_id, girone_id, fase, turno, squadra_casa, squadra_ospite)
       values ($1, $2, 'girone', 1, $3, $4) returning id`,
      [TORNEO_PARITA, girone, squadre[casa], squadre[ospite]],
    );
    await db.query(`update public.torneo_incontri set sets = $2::jsonb where id = $1`,
      [rows[0].id, sets]);
  };

  await db.exec('reset role');
  await incontro('Alfa', 'Beta', '[[6,0],[6,0]]');   // Alfa +12 game
  await incontro('Beta', 'Gamma', '[[6,4],[6,4]]');  // Beta +4
  await incontro('Gamma', 'Alfa', '[[7,5],[7,5]]');  // Gamma +4

  const { rows: cls } = await db.query('select * from public.classifica_girone($1)', [girone]);

  esito('tutte e tre hanno gli stessi punti',
    cls.every((r) => r.punti === 3), JSON.stringify(cls.map((r) => [r.nome, r.punti])));

  // Con tutte e tre a pari punti la classifica ridotta coincide con
  // quella totale: decide la differenza game. Alfa ha fatto 24 game e
  // ne ha subiti 18 (+6), Gamma 22 subiti 22 (0), Beta 20 subiti 24 (-4).
  uguale('davanti c e chi ha la differenza game migliore', 'Alfa', cls[0].nome);
  uguale('e in fondo chi ce l ha peggiore', 'Beta', cls[2].nome);

  const diff = cls.map((r) => r.game_fatti - r.game_subiti);
  esito('l ordine segue la differenza game',
    diff[0] >= diff[1] && diff[1] >= diff[2], JSON.stringify(diff));
}

/**
 * Il tabellone (aggiornamento n.16): dalle qualificate dei gironi
 * alla finale, con i vincitori che avanzano da soli.
 */
async function testTabellone() {
  console.log('\nTABELLONE DELLE FASI FINALI');

  await db.exec('reset role');
  const { rows: c } = await db.query('select id from public.circoli where nome = $1', [CIRCOLO_NOME]);

  await come(U.bea);
  await db.exec('set role authenticated');

  // Due gironi da due squadre: quattro qualificate, quindi semifinali
  // e finale. Con la finale per il terzo posto attiva.
  await db.query(
    `insert into public.tornei (id, circolo_id, nome, creato_da, qualificate_per_girone, finale_terzo_posto)
     values ($1, $2, 'Torneo con finali', $3, 2, true)`,
    [TORNEO_FINALI, c[0].id, U.bea],
  );

  const gironi = {};
  for (const [nome, ordine] of [['A', 1], ['B', 2]]) {
    const { rows } = await db.query(
      `insert into public.tornei_gironi (torneo_id, nome, ordine) values ($1, $2, $3) returning id`,
      [TORNEO_FINALI, nome, ordine],
    );
    gironi[nome] = rows[0].id;
  }

  const squadre = {};
  for (const [nome, girone] of [['A1', 'A'], ['A2', 'A'], ['B1', 'B'], ['B2', 'B']]) {
    const { rows } = await db.query(
      `insert into public.torneo_squadre (torneo_id, nome, giocatore_1, giocatore_2, girone_id)
       values ($1, $2, $3, $4, $5) returning id`,
      [TORNEO_FINALI, nome, `${nome} Uno`, `${nome} Due`, gironi[girone]],
    );
    squadre[nome] = rows[0].id;
  }

  await db.query('select public.torneo_genera_calendario($1)', [TORNEO_FINALI]);
  await db.query(`select public.torneo_cambia_stato($1, 'iscrizioni')`, [TORNEO_FINALI]);
  await db.query(`select public.torneo_cambia_stato($1, 'in_corso')`, [TORNEO_FINALI]);

  await deveFallire(
    'il tabellone non si genera a gironi aperti',
    () => db.query('select public.torneo_genera_tabellone($1)', [TORNEO_FINALI]),
    'non sono ancora conclusi',
  );

  // Si giocano i gironi: in ognuno vince la squadra "1"
  const { rows: incontriGirone } = await db.query(
    `select id, squadra_casa from public.torneo_incontri
     where torneo_id = $1 and fase = 'girone'`, [TORNEO_FINALI],
  );
  for (const i of incontriGirone) {
    const vinceCasa = i.squadra_casa === squadre.A1 || i.squadra_casa === squadre.B1;
    await db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
      [i.id, vinceCasa ? '[[6,1],[6,1]]' : '[[1,6],[1,6]]']);
  }

  const { rows: creati } = await db.query(
    'select public.torneo_genera_tabellone($1) as n', [TORNEO_FINALI],
  );
  // 2 semifinali + 1 finale + 1 finale terzo posto
  uguale('il tabellone ha 4 incontri', 4, creati[0].n);

  await db.exec('reset role');
  const semifinali = async () => (await db.query(
    `select id, ordine, squadra_casa, squadra_ospite, prossimo_incontro_id, prossimo_lato
     from public.torneo_incontri where torneo_id = $1 and fase = 'semifinale' order by ordine`,
    [TORNEO_FINALI],
  )).rows;

  const sf = await semifinali();
  uguale('ci sono due semifinali', 2, sf.length);

  // L'accoppiamento incrociato: prima di un girone contro seconda dell'altro
  const nomeDi = (id) => Object.keys(squadre).find((k) => squadre[k] === id);
  const accoppiamenti = sf.map((s) => [nomeDi(s.squadra_casa), nomeDi(s.squadra_ospite)].sort().join('-'));
  esito(
    'le prime non incontrano subito la seconda del proprio girone',
    accoppiamenti.includes('A1-B2') && accoppiamenti.includes('A2-B1'),
    JSON.stringify(accoppiamenti),
  );

  const { rows: finale } = await db.query(
    `select id, squadra_casa, squadra_ospite from public.torneo_incontri
     where torneo_id = $1 and fase = 'finale'`, [TORNEO_FINALI],
  );
  uguale('la finale esiste', 1, finale.length);
  uguale('e parte senza squadre', null, finale[0].squadra_casa);
  esito('le semifinali sanno dove mandare il vincitore',
    sf.every((s) => s.prossimo_incontro_id === finale[0].id), JSON.stringify(sf.map((s) => s.prossimo_incontro_id)));

  // ----- Si gioca la prima semifinale: il vincitore sale da solo -----
  await come(U.bea);
  await db.exec('set role authenticated');
  await db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
    [sf[0].id, '[[6,2],[6,2]]']);

  await db.exec('reset role');
  const vincitoreSf1 = sf[0].squadra_casa;
  const { rows: finaleDopo } = await db.query(
    'select squadra_casa, squadra_ospite from public.torneo_incontri where id = $1', [finale[0].id],
  );
  uguale('il vincitore della semifinale entra in finale', vincitoreSf1, finaleDopo[0].squadra_casa);
  uguale('l altra casella resta vuota', null, finaleDopo[0].squadra_ospite);

  const { rows: terzo } = await db.query(
    `select squadra_casa from public.torneo_incontri
     where torneo_id = $1 and fase = 'finale_3_4'`, [TORNEO_FINALI],
  );
  uguale('e il perdente va alla finale per il terzo posto', sf[0].squadra_ospite, terzo[0].squadra_casa);

  // ----- Seconda semifinale -----
  await come(U.bea);
  await db.exec('set role authenticated');
  await db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
    [sf[1].id, '[[6,3],[6,3]]']);

  await db.exec('reset role');
  const { rows: finalePiena } = await db.query(
    'select squadra_casa, squadra_ospite from public.torneo_incontri where id = $1', [finale[0].id],
  );
  esito('la finale ha entrambe le squadre',
    finalePiena[0].squadra_casa !== null && finalePiena[0].squadra_ospite !== null,
    JSON.stringify(finalePiena[0]));

  // ----- Annullare a monte quando a valle si e' gia' giocato -----
  await come(U.bea);
  await db.exec('set role authenticated');
  await db.query('select public.torneo_registra_risultato($1, $2::jsonb)',
    [finale[0].id, '[[6,4],[6,4]]']);

  await deveFallire(
    'non si annulla una semifinale se la finale e gia giocata',
    () => db.query('select public.torneo_annulla_risultato($1)', [sf[1].id]),
    'gia',
  );

  // Annullata la finale, la semifinale torna modificabile
  await deveRiuscire('annullata la finale, la semifinale si sblocca', async () => {
    await db.query('select public.torneo_annulla_risultato($1)', [finale[0].id]);
    await db.query('select public.torneo_annulla_risultato($1)', [sf[1].id]);
  });

  await db.exec('reset role');
  const { rows: finaleSvuotata } = await db.query(
    'select squadra_ospite from public.torneo_incontri where id = $1', [finale[0].id],
  );
  uguale('e la casella in finale si svuota', null, finaleSvuotata[0].squadra_ospite);
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
  await testCodiceCircolo();
  await testLimitiAvatar();
  await testDataPartita();
  await testPostiNonFalsificabili();
  await testCreazionePartita();
  await testAvatar();
  await testIscrizioneTardiva();
  await testCorrezioneRisultato();
  await testAmministratore();
  await testCircoli();
  await testTornei();
  await testParitaClassifica();
  await testTabellone();
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
