#!/usr/bin/env node
/* =========================================================
   PADEL CILENTO — Dati dimostrativi

   Riempie il database con un circolo e un torneo finiti, per poter
   riprendere l'app piena invece che vuota: gironi, calendario,
   risultati, classifiche, tabellone e medaglie.

   Uso:
     npm run dati:demo           crea tutto
     npm run dati:demo pulisci   cancella tutto quello che ha creato

   ATTENZIONE: scrive sul database indicato in .env, cioe' quello
   VERO. Tutto quello che crea porta il marchio qui sotto, e
   "pulisci" lo rimuove senza toccare nient'altro.

   Nota: NON crea utenti finti. Le coppie di un torneo sono nomi
   scritti a mano — e' proprio il motivo per cui la modalita' torneo
   funziona senza obbligare nessuno a registrarsi.
========================================================= */

import pg from 'pg';
import fs from 'node:fs';
import path from 'node:path';

const MARCHIO = 'Padel Demo Cilento';   // il circolo dimostrativo
const RADICE = process.cwd();

function urlDatabase() {
  const file = path.join(RADICE, '.env');
  const env = { ...process.env };

  if (fs.existsSync(file)) {
    for (const riga of fs.readFileSync(file, 'utf8').split('\n')) {
      const p = riga.trim();
      if (!p || p.startsWith('#')) continue;
      const i = p.indexOf('=');
      if (i === -1) continue;
      let v = p.slice(i + 1).trim();
      if (/^(".*"|'.*')$/.test(v)) v = v.slice(1, -1);
      if (!env[p.slice(0, i).trim()]) env[p.slice(0, i).trim()] = v;
    }
  }

  if (!env.SUPABASE_DB_URL) {
    console.error('\nManca SUPABASE_DB_URL: copia .env.example in .env e incolla la stringa.\n');
    process.exit(1);
  }
  return env.SUPABASE_DB_URL;
}

const COPPIE = [
  ['Marco Rossi', 'Luca Bianchi'],
  ['Anna Verdi', 'Sara Neri'],
  ['Paolo Gialli', 'Marco Blu'],
  ['Elena Viola', 'Ugo Grigi'],
  ['Gennaro Esposito', 'Ciro Rullo'],
  ['Giulia Fontana', 'Rita Greco'],
  ['Anna Coppola', 'Luisa Ruggi'],
  ['Nino Ferrara', 'Peppe Longo'],
];

// Punteggi verosimili, uno per ogni incontro possibile
const PUNTEGGI = [
  [[6, 4], [6, 3]], [[7, 5], [3, 6], [6, 2]], [[6, 2], [6, 4]],
  [[4, 6], [6, 3], [7, 5]], [[6, 1], [6, 4]], [[6, 7], [6, 4], [6, 3]],
  [[6, 3], [4, 6], [6, 4]], [[6, 0], [6, 2]], [[7, 6], [6, 4]],
  [[5, 7], [6, 2], [6, 1]], [[6, 4], [6, 4]], [[6, 2], [3, 6], [7, 5]],
];

async function crea(client) {
  // Le funzioni del torneo verificano chi le chiama guardando
  // auth.uid(), che su una connessione diretta e' vuoto. Ci si
  // presenta quindi come l'amministratore, che e' esattamente cio'
  // che si sta facendo.
  const { rows: admin } = await client.query(
    `select id from public.profiles where role = 'admin' limit 1`,
  );
  if (admin.length === 0) {
    console.error(`
Nessun amministratore nel database.

Prima nominati amministratore dall'Editor SQL di Supabase:

  update public.profiles set role = 'admin'
  where id = (select id from auth.users where email = 'tua@email.it');
`);
    process.exit(1);
  }

  await client.query(
    `select set_config('request.jwt.claims', json_build_object('sub', $1::text)::text, true)`,
    [admin[0].id],
  );

  console.log('Circolo dimostrativo...');
  const { rows: circolo } = await client.query(
    `insert into public.circoli (nome, zona, telefono, abbonamento_scade_il)
     values ($1, 'paestum', '0828 000000', current_date + 365)
     returning id`, [MARCHIO],
  );
  const idCircolo = circolo[0].id;

  await client.query(
    `insert into public.club_codes (code, circolo, circolo_id, uso_singolo)
     values ('DEMO-2026', $1, $2, false)`, [MARCHIO, idCircolo],
  );

  console.log('Torneo, gironi e squadre...');
  const { rows: torneo } = await client.query(
    `insert into public.tornei
       (circolo_id, nome, descrizione, livello, data_inizio, data_fine,
        qualificate_per_girone, finale_terzo_posto, creato_da)
     values ($1, 'Torneo del Cilento 2026', 'Torneo dimostrativo a due gironi',
             'intermedio', current_date - 7, current_date, 2, true, $2)
     returning id`, [idCircolo, admin[0].id],
  );
  const idTorneo = torneo[0].id;

  const gironi = [];
  for (const [i, nome] of ['A', 'B'].entries()) {
    const { rows } = await client.query(
      `insert into public.tornei_gironi (torneo_id, nome, ordine)
       values ($1, $2, $3) returning id`, [idTorneo, nome, i + 1],
    );
    gironi.push(rows[0].id);
  }

  for (const [i, [g1, g2]] of COPPIE.entries()) {
    await client.query(
      `insert into public.torneo_squadre (torneo_id, giocatore_1, giocatore_2, girone_id)
       values ($1, $2, $3, $4)`,
      [idTorneo, g1, g2, gironi[i < 4 ? 0 : 1]],
    );
  }

  console.log('Calendario...');
  const { rows: cal } = await client.query(
    'select public.torneo_genera_calendario($1) as n', [idTorneo],
  );
  console.log(`  ${cal[0].n} incontri`);

  await client.query(`select public.torneo_cambia_stato($1, 'iscrizioni')`, [idTorneo]);
  await client.query(`select public.torneo_cambia_stato($1, 'in_corso')`, [idTorneo]);

  console.log('Risultati dei gironi...');
  const { rows: incontri } = await client.query(
    `select id from public.torneo_incontri
     where torneo_id = $1 and fase = 'girone' order by girone_id, turno, ordine`, [idTorneo],
  );
  for (const [i, inc] of incontri.entries()) {
    await client.query('select public.torneo_registra_risultato($1, $2::jsonb)',
      [inc.id, JSON.stringify(PUNTEGGI[i % PUNTEGGI.length])]);
  }

  console.log('Tabellone...');
  const { rows: tab } = await client.query(
    'select public.torneo_genera_tabellone($1) as n', [idTorneo],
  );
  console.log(`  ${tab[0].n} incontri`);

  // Semifinali, poi finali: l'ordine conta, il vincitore sale da solo
  for (const fase of ['semifinale', 'finale_3_4', 'finale']) {
    const { rows } = await client.query(
      `select id from public.torneo_incontri
       where torneo_id = $1 and fase = $2 and squadra_casa is not null
         and squadra_ospite is not null order by ordine`, [idTorneo, fase],
    );
    for (const [i, inc] of rows.entries()) {
      await client.query('select public.torneo_registra_risultato($1, $2::jsonb)',
        [inc.id, JSON.stringify(PUNTEGGI[(i + 3) % PUNTEGGI.length])]);
    }
  }

  await client.query(`select public.torneo_cambia_stato($1, 'concluso')`, [idTorneo]);

  const { rows: albo } = await client.query(
    `select a.posizione, s.giocatore_1, s.giocatore_2
     from public.albo_torneo($1) a
     join public.torneo_squadre s on s.id = a.squadra_id
     order by a.posizione`, [idTorneo],
  );

  console.log('\nPodio:');
  const medaglie = ['1º', '2º', '3º'];
  albo.forEach((r) => console.log(`  ${medaglie[r.posizione - 1]}  ${r.giocatore_1} / ${r.giocatore_2}`));

  console.log(`
Fatto. Nell'app trovi il torneo completo sotto il pulsante Tornei.

Per collegare una medaglia al TUO profilo — cosi' si vede anche la
bacheca — sostituisci una coppia con il tuo account dall'Editor SQL:

  update public.torneo_squadre
  set user_id_1 = (select id from auth.users where email = 'tua@email.it')
  where id = (select squadra_id from public.albo_torneo('${idTorneo}') where posizione = 1);

Quando hai finito di registrare:  npm run dati:demo pulisci
`);
}

async function pulisci(client) {
  const { rows } = await client.query('select id from public.circoli where nome = $1', [MARCHIO]);
  if (rows.length === 0) {
    console.log('Niente da pulire: il circolo dimostrativo non c\'e\'.');
    return;
  }

  // I tornei, i gironi, le squadre e gli incontri se ne vanno in
  // cascata dietro al circolo. I codici pure.
  await client.query('delete from public.circoli where nome = $1', [MARCHIO]);
  console.log('Rimosso il circolo dimostrativo e tutto quello che conteneva.');
}

// ---------------------------------------------------------
const comando = process.argv[2] || 'crea';
const client = new pg.Client({ connectionString: urlDatabase(), ssl: { rejectUnauthorized: false } });

await client.connect();
try {
  await client.query('begin');
  if (comando === 'pulisci') await pulisci(client);
  else await crea(client);
  await client.query('commit');
} catch (e) {
  await client.query('rollback');
  console.error('\nErrore, niente e stato scritto:\n', e.message, '\n');
  process.exitCode = 1;
} finally {
  await client.end();
}
