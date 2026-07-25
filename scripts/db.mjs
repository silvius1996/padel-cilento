#!/usr/bin/env node
/* =========================================================
   PADEL CILENTO — Gestione delle migrazioni di database
   =========================================================

   Comandi disponibili:
     npm run db:baseline   una volta sola: segna come "gia applicate"
                           le migrazioni eseguite a mano dall'editor SQL
     npm run db:push       applica al database le migrazioni mancanti
     npm run db:status     elenca lo stato delle migrazioni

   La stringa di connessione NON sta in questo file: viene letta da
   .env, che resta sul tuo computer e non viene mai pubblicato.
   Vedi .env.example per le istruzioni.
========================================================= */

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const RADICE = process.cwd();
const FILE_ENV = path.join(RADICE, '.env');
const CARTELLA_MIGRAZIONI = path.join(RADICE, 'supabase', 'migrations');

// Le migrazioni applicate a mano nell'editor SQL di Supabase prima che
// esistesse questa automazione. "db:baseline" le registra come applicate
// senza rieseguirle: se venissero rilanciate darebbero errore, perche'
// contengono istruzioni non ripetibili (create policy, add constraint...).
const GIA_APPLICATE_A_MANO = [
  '20260724100000', // schema iniziale
  '20260724120000', // profilo e avatar
  '20260724123000', // ruoli e origine partita
  '20260724131000', // codici circolo
  '20260725100000', // privacy RLS
];

// ---------------------------------------------------------
function leggiEnv() {
  if (!fs.existsSync(FILE_ENV)) return {};

  const env = {};
  for (const riga of fs.readFileSync(FILE_ENV, 'utf8').split('\n')) {
    const pulita = riga.trim();
    if (!pulita || pulita.startsWith('#')) continue;
    const i = pulita.indexOf('=');
    if (i === -1) continue;
    const chiave = pulita.slice(0, i).trim();
    let valore = pulita.slice(i + 1).trim();
    // Si tolgono eventuali apici o virgolette intorno al valore
    if (/^(".*"|'.*')$/.test(valore)) valore = valore.slice(1, -1);
    env[chiave] = valore;
  }
  return env;
}

function urlDatabase() {
  const env = { ...leggiEnv(), ...process.env };
  const url = env.SUPABASE_DB_URL;

  if (!url) {
    console.error(`
Manca la stringa di connessione al database.

  1. Copia .env.example in .env
  2. Incolla la tua stringa in SUPABASE_DB_URL

La trovi nel pannello Supabase:
  Project Settings  ->  Database  ->  Connection string  ->  URI

Il file .env resta sul tuo computer: non finisce nel sito pubblicato
(viene pubblicata solo la cartella public/).
`);
    process.exit(1);
  }

  if (url.includes('[YOUR-PASSWORD]') || url.includes('[PASSWORD]')) {
    console.error('\nNella stringa di connessione c\'e ancora il segnaposto della password.');
    console.error('Sostituiscilo con la password reale del database in .env\n');
    process.exit(1);
  }

  return url;
}

/**
 * Esegue il CLI Supabase mostrandone l'output, senza mai stampare la password.
 *
 * Il CLI viene invocato con "node" sul suo wrapper, NON tramite shell:
 * passando per la shell gli argomenti vengono soltanto concatenati, e una
 * password che contiene caratteri speciali (!, %, &, virgolette) verrebbe
 * interpretata dalla shell invece di arrivare intatta al programma.
 */
function supabase(argomenti, url) {
  const wrapper = path.join(RADICE, 'node_modules', 'supabase', 'dist', 'supabase.js');

  if (!fs.existsSync(wrapper)) {
    console.error('\nCLI Supabase non trovato. Esegui prima:  npm install\n');
    return 1;
  }

  console.log(`\n> supabase ${argomenti.join(' ')} --db-url ***\n`);

  const r = spawnSync(
    process.execPath,
    [wrapper, ...argomenti, '--db-url', url],
    { stdio: 'inherit' },
  );

  return r.status ?? 1;
}

function elencoMigrazioni() {
  return fs.readdirSync(CARTELLA_MIGRAZIONI)
    .filter((f) => f.endsWith('.sql'))
    .sort();
}

// ---------------------------------------------------------
function comandoBaseline() {
  const url = urlDatabase();

  console.log('Registrazione delle migrazioni gia applicate a mano.');
  console.log('Nessuna istruzione SQL viene eseguita: si aggiorna solo il');
  console.log('registro delle migrazioni del database.\n');

  elencoMigrazioni().forEach((f) => {
    const versione = f.split('_')[0];
    const stato = GIA_APPLICATE_A_MANO.includes(versione) ? 'da segnare come applicata' : 'verra applicata da db:push';
    console.log(`  ${versione}  ${stato}`);
  });

  const codice = supabase(
    ['migration', 'repair', '--status', 'applied', ...GIA_APPLICATE_A_MANO],
    url,
  );

  if (codice === 0) {
    console.log('\nFatto. Ora esegui:  npm run db:push');
  }
  return codice;
}

function comandoPush() {
  const url = urlDatabase();
  console.log('Applicazione delle migrazioni mancanti al database remoto.');
  return supabase(['db', 'push'], url);
}

function comandoStatus() {
  const url = urlDatabase();
  return supabase(['migration', 'list'], url);
}

// ---------------------------------------------------------
const comando = process.argv[2];
const comandi = {
  baseline: comandoBaseline,
  push: comandoPush,
  status: comandoStatus,
};

if (!comandi[comando]) {
  console.error(`\nComando non riconosciuto: ${comando || '(nessuno)'}`);
  console.error('Usa uno tra: baseline, push, status\n');
  process.exit(1);
}

process.exit(comandi[comando]());
