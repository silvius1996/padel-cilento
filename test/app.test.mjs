/* =========================================================
   PADEL CILENTO — Test automatici dell'app nel browser
   Esecuzione:  npm run test:app
=========================================================

   Il test apre public/index.html in un browser vero e usa l'app
   come la userebbe un circolo: apre il torneo, preme "Inserisci il
   punteggio", compila le caselle e salva. Le chiamate al database
   vengono intercettate e a ognuna si risponde con dati di esempio,
   come in scripts/spot.mjs: l'app non se ne accorge, esegue il suo
   codice di sempre.

   Cosa protegge: il salvataggio dei punteggi di un torneo. In un
   torneo a set unico il modulo disegna una casella sola, e il
   salvataggio ne cercava sempre tre: la casella mancante fermava
   tutto prima ancora di chiamare il database, senza nemmeno un
   messaggio d'errore. Da fuori sembrava che il pulsante non
   funzionasse. Qui si verifica che la chiamata parta davvero, con
   il punteggio giusto dentro.

   ATTENZIONE: nessuna chiamata esce dalla macchina, e il database
   di produzione non viene toccato in alcun modo.
========================================================= */

import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const RADICE = process.cwd();
const PUBBLICA = path.join(RADICE, 'public');
const PORTA = 8907;
const RIF = 'eyxvgowdxcyxegktrgxp';           // riferimento del progetto Supabase
const IO = '11111111-1111-1111-1111-111111111111';
const CIRCOLO = 'c1';

/**
 * Dove sta il browser. Su GitHub lo installa il workflow e Playwright
 * lo trova da solo; su alcune macchine di sviluppo e' gia' pronto in
 * una cartella fissa, e li' va indicato a mano. Indicare un percorso
 * che non esiste farebbe fallire l'avvio, quindi si guarda prima.
 */
const BROWSER_PRONTO = '/opt/pw-browsers/chromium';
const avvioBrowser = fs.existsSync(BROWSER_PRONTO)
  ? { executablePath: BROWSER_PRONTO }
  : {};

let passati = 0;
const falliti = [];

function esito(nome, condizione, dettaglio = '') {
  if (condizione) {
    passati++;
    console.log(`  OK   ${nome}`);
  } else {
    falliti.push(`${nome}${dettaglio ? ` — ${dettaglio}` : ''}`);
    console.log(`  FAIL ${nome}${dettaglio ? ` — ${dettaglio}` : ''}`);
  }
}

function titolo(t) {
  console.log(`\n${t.toUpperCase()}`);
}

// ---------------------------------------------------------
// I dati di esempio: quello che l'app crede di leggere
// ---------------------------------------------------------
const oggi = new Date();
const giorno = (n) => {
  const d = new Date(oggi); d.setDate(d.getDate() + n);
  return d.toISOString().slice(0, 10);
};

const PROFILO = {
  id: IO, nome: 'Andrea', cognome: 'Costa', full_name: 'Andrea Costa',
  level: 'intermedio', avatar_url: null, telefono: '3331234567',
  role: 'gestore', circolo: 'Padel Arena', circolo_id: CIRCOLO,
  eliminato_il: null, created_at: oggi.toISOString(),
};

/**
 * Un torneo per formato di punteggio. Il primo gioca tutto a set
 * unico, il secondo ha i gironi a set unico e le finali a due set
 * su tre: e' proprio la combinazione in cui il numero di caselle
 * cambia da un incontro all'altro dentro lo stesso torneo.
 */
const torneo = (id, formato, formatoFinali) => ({
  id, circolo_id: CIRCOLO, nome: `Torneo ${id}`,
  descrizione: null, livello: 'intermedio',
  data_inizio: giorno(-2), data_fine: giorno(0), stato: 'in_corso',
  formato: 'gironi_e_finali', formato_girone: 'all_italiana',
  qualificate_per_girone: 2, finale_terzo_posto: false,
  formato_punteggio: formato, formato_punteggio_finali: formatoFinali,
  creato_da: IO, created_at: oggi.toISOString(), circoli: { nome: 'Padel Arena' },
});

const TORNEI = {
  t_secco: torneo('t_secco', 'set_unico', null),
  t_misto: torneo('t_misto', 'set_unico', 'due_su_tre'),
  t_lungo: torneo('t_lungo', 'due_su_tre', null),
};

const GIRONI = [{ id: 'g1', torneo_id: null, nome: 'A', ordine: 1 }];

const sq = (id, a, b) => ({
  id, torneo_id: null, nome: null, giocatore_1: a, giocatore_2: b,
  user_id_1: null, user_id_2: null, girone_id: 'g1', stato: 'iscritta',
  created_at: oggi.toISOString(),
});
const SQUADRE = [
  sq('s1', 'Marco Rossi', 'Luca Bianchi'),
  sq('s2', 'Anna Verdi', 'Sara Neri'),
];

const inc = (id, fase, casa, osp) => ({
  id, torneo_id: null, girone_id: fase === 'girone' ? 'g1' : null, fase,
  turno: 1, ordine: 0, squadra_casa: casa, squadra_ospite: osp,
  data: null, ora: null, campo: null, sets: null, vincitore: null,
  registrato_da: null, registrato_il: null,
  prossimo_incontro_id: null, prossimo_lato: null,
  perdente_incontro_id: null, perdente_lato: null,
});

const INCONTRI = [
  inc('i_girone', 'girone', 's1', 's2'),
  inc('i_finale', 'finale', 's1', 's2'),
];

const CLASSIFICA_GIRONE = [
  { posizione: 1, squadra_id: 's1', nome: 'Marco Rossi / Luca Bianchi',
    partite: 0, vittorie: 0, sconfitte: 0, punti: 0,
    set_vinti: 0, set_persi: 0, game_fatti: 0, game_subiti: 0 },
  { posizione: 2, squadra_id: 's2', nome: 'Anna Verdi / Sara Neri',
    partite: 0, vittorie: 0, sconfitte: 0, punti: 0,
    set_vinti: 0, set_persi: 0, game_fatti: 0, game_subiti: 0 },
];

// ---------------------------------------------------------
// Le risposte, scelte in base a cosa l'app sta chiedendo
// ---------------------------------------------------------
function rispostaPer(url, torneoId) {
  const u = new URL(url);
  const via = u.pathname;

  if (via.includes('/auth/v1/user')) return { user: { id: IO, email: 'test@esempio.it' } };
  if (via.includes('/auth/v1/')) return {};

  if (via.endsWith('/rpc/mio_profilo')) return PROFILO;
  if (via.endsWith('/rpc/classifica_girone')) return CLASSIFICA_GIRONE;
  if (via.endsWith('/rpc/bacheca_giocatore')) return [];
  if (via.endsWith('/rpc/statistiche_giocatore')) return [];
  if (via.endsWith('/rpc/classifica')) return [];

  // Il torneo aperto viene letto con .single(): una riga sola, non
  // un elenco. Vale sia all'apertura sia a ogni ricarica.
  if (via.endsWith('/tornei')) return TORNEI[torneoId];

  if (via.endsWith('/tornei_gironi')) return GIRONI.map((g) => ({ ...g, torneo_id: torneoId }));
  if (via.endsWith('/torneo_squadre')) return SQUADRE.map((s) => ({ ...s, torneo_id: torneoId }));
  if (via.endsWith('/torneo_incontri')) return INCONTRI.map((i) => ({ ...i, torneo_id: torneoId }));
  if (via.endsWith('/profiles')) return [];

  return [];
}

/**
 * Ogni chiamata a torneo_registra_risultato finisce qui: e' quello
 * che il test vuole vedere arrivare, ed e' anche l'unico modo per
 * accorgersi che NON e' arrivata.
 */
const salvataggi = [];
let torneoAperto = 't_secco';

async function intercetta(context) {
  await context.route(/fonts\.(googleapis|gstatic)\.com|sentry/, (route) => route.abort());

  await context.route('**/*.supabase.co/**', async (route) => {
    const req = route.request();
    const url = req.url();

    if (url.includes('/rpc/torneo_registra_risultato')) {
      let corpo = {};
      try { corpo = JSON.parse(req.postData() || '{}'); } catch { /* niente */ }
      salvataggi.push(corpo);
      const incontro = INCONTRI.find((i) => i.id === corpo.p_incontro_id);
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        headers: { 'access-control-allow-origin': '*' },
        body: JSON.stringify({ ...incontro, sets: corpo.p_sets }),
      });
    }

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      headers: { 'access-control-allow-origin': '*' },
      body: JSON.stringify(rispostaPer(url, torneoAperto)),
    });
  });
}

// ---------------------------------------------------------
function avviaServer() {
  const TIPI = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript',
                 '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(req.url.split('?')[0]);
    if (p === '/') p = '/index.html';
    const f = path.join(PUBBLICA, p);
    if (!f.startsWith(PUBBLICA) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) {
      res.writeHead(404); return res.end();
    }
    res.writeHead(200, { 'Content-Type': TIPI[path.extname(f)] || 'application/octet-stream' });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise((r) => server.listen(PORTA, () => r(server)));
}

// ---------------------------------------------------------
// Le manovre sull'app
// ---------------------------------------------------------

/** Apre il torneo e aspetta che il tabellone sia disegnato. */
async function apri(page, torneoId) {
  torneoAperto = torneoId;
  await page.evaluate((id) => apriTorneo(id), torneoId);
  await page.waitForFunction(
    () => document.getElementById('torneo-loading')?.classList.contains('hidden'),
    { timeout: 15000 },
  );
}

/**
 * Trova la riga di un incontro e ne apre il modulo del punteggio.
 * Restituisce il selettore delle caselle di quella riga soltanto:
 * nella pagina ce n'e' anche un'altra, e confonderle nasconderebbe
 * proprio il tipo di errore che questo test cerca.
 */
async function apriModulo(page, indiceRiga) {
  const riga = page.locator('#torneo-contenuto .rounded-xl').filter({
    has: page.locator('button', { hasText: /punteggio/ }),
  }).nth(indiceRiga);
  await riga.locator('button', { hasText: 'Inserisci il punteggio' }).click();
  return riga;
}

async function compila(riga, punteggi) {
  const caselle = riga.locator('input[type="number"]');
  for (let i = 0; i < punteggi.length; i++) {
    await caselle.nth(i).fill(String(punteggi[i]));
  }
}

async function salva(riga) {
  await riga.locator('button', { hasText: 'Salva il punteggio' }).click();
}

/** Aspetta che il salvataggio arrivi; se non arriva, il test lo dira'. */
async function attendiSalvataggio(quanti, ms = 4000) {
  const scadenza = Date.now() + ms;
  while (salvataggi.length < quanti && Date.now() < scadenza) {
    await new Promise((r) => setTimeout(r, 100));
  }
  return salvataggi.length >= quanti;
}

// ---------------------------------------------------------
// I test
// ---------------------------------------------------------
async function testSetUnico(page) {
  titolo('Torneo a set unico: il punteggio si salva');

  await apri(page, 't_secco');

  const caselle = await page.locator('#torneo-contenuto input[type="number"]').count();
  esito('prima di aprire il modulo non ci sono caselle', caselle === 0, `trovate ${caselle}`);

  const riga = await apriModulo(page, 0);
  const quante = await riga.locator('input[type="number"]').count();
  esito('a set unico il modulo mostra un set solo', quante === 2, `caselle: ${quante}`);

  await compila(riga, [6, 3]);
  await salva(riga);

  const arrivato = await attendiSalvataggio(1);
  esito('il salvataggio raggiunge il database', arrivato,
    'la chiamata torneo_registra_risultato non e mai partita');

  if (arrivato) {
    const ultimo = salvataggi[salvataggi.length - 1];
    esito('viene salvato l incontro giusto', ultimo.p_incontro_id === 'i_girone',
      `incontro: ${ultimo.p_incontro_id}`);
    esito('con un set solo', Array.isArray(ultimo.p_sets) && ultimo.p_sets.length === 1,
      JSON.stringify(ultimo.p_sets));
    esito('e con il punteggio scritto', JSON.stringify(ultimo.p_sets) === '[[6,3]]',
      JSON.stringify(ultimo.p_sets));
  }
}

async function testDueSuTre(page) {
  titolo('Torneo a due set su tre: niente e cambiato');

  await apri(page, 't_lungo');

  const riga = await apriModulo(page, 0);
  const quante = await riga.locator('input[type="number"]').count();
  esito('il modulo mostra tre set', quante === 6, `caselle: ${quante}`);

  const prima = salvataggi.length;
  await compila(riga, [6, 4, 4, 6, 6, 2]);
  await salva(riga);

  const arrivato = await attendiSalvataggio(prima + 1);
  esito('il salvataggio raggiunge il database', arrivato);

  if (arrivato) {
    const ultimo = salvataggi[salvataggi.length - 1];
    esito('con tutti e tre i set', JSON.stringify(ultimo.p_sets) === '[[6,4],[4,6],[6,2]]',
      JSON.stringify(ultimo.p_sets));
  }
}

async function testTerzoSetFacoltativo(page) {
  titolo('Il terzo set resta facoltativo');

  await apri(page, 't_lungo');

  const riga = await apriModulo(page, 0);
  const prima = salvataggi.length;
  await compila(riga, [6, 4, 6, 3]);
  await salva(riga);

  const arrivato = await attendiSalvataggio(prima + 1);
  esito('due set bastano', arrivato);

  if (arrivato) {
    const ultimo = salvataggi[salvataggi.length - 1];
    esito('e ne vengono salvati due', JSON.stringify(ultimo.p_sets) === '[[6,4],[6,3]]',
      JSON.stringify(ultimo.p_sets));
  }
}

async function testFasiConFormatiDiversi(page) {
  titolo('Gironi a set unico, finali a due set su tre');

  await apri(page, 't_misto');

  const rigaGirone = await apriModulo(page, 0);
  const caselleGirone = await rigaGirone.locator('input[type="number"]').count();
  esito('l incontro di girone ha un set', caselleGirone === 2, `caselle: ${caselleGirone}`);

  const primaGirone = salvataggi.length;
  await compila(rigaGirone, [6, 2]);
  await salva(rigaGirone);
  const gironeOk = await attendiSalvataggio(primaGirone + 1);
  esito('e si salva', gironeOk);
  if (gironeOk) {
    esito('con un set solo',
      JSON.stringify(salvataggi[salvataggi.length - 1].p_sets) === '[[6,2]]',
      JSON.stringify(salvataggi[salvataggi.length - 1].p_sets));
  }

  // La riga della finale e' la seconda del tabellone
  await apri(page, 't_misto');
  const rigaFinale = await apriModulo(page, 1);
  const caselleFinale = await rigaFinale.locator('input[type="number"]').count();
  esito('la finale ne ha tre', caselleFinale === 6, `caselle: ${caselleFinale}`);

  const primaFinale = salvataggi.length;
  await compila(rigaFinale, [6, 4, 6, 4]);
  await salva(rigaFinale);
  const finaleOk = await attendiSalvataggio(primaFinale + 1);
  esito('e anche la finale si salva', finaleOk);
  if (finaleOk) {
    const ultimo = salvataggi[salvataggi.length - 1];
    esito('sull incontro della finale', ultimo.p_incontro_id === 'i_finale',
      `incontro: ${ultimo.p_incontro_id}`);
  }
}

async function testPunteggioIncompleto(page) {
  titolo('Un set a meta non parte, e lo dice');

  await apri(page, 't_lungo');

  const riga = await apriModulo(page, 0);
  const prima = salvataggi.length;

  await compila(riga, [6]);              // solo il primo numero del primo set
  await salva(riga);

  const messaggio = riga.locator('p.text-red-400');
  await messaggio.waitFor({ state: 'visible', timeout: 3000 });
  const testo = await messaggio.textContent();
  esito('compare un messaggio d errore', /entrambi/i.test(testo), testo);
  esito('e niente viene inviato al database', salvataggi.length === prima);

  // Corretto l'errore, il salvataggio riparte e il messaggio sparisce
  await compila(riga, [6, 4, 6, 3]);
  await salva(riga);
  const arrivato = await attendiSalvataggio(prima + 1);
  esito('corretto il punteggio, il salvataggio riparte', arrivato);
}

// ---------------------------------------------------------
async function main() {
  const server = await avviaServer();
  const browser = await chromium.launch(avvioBrowser);
  const context = await browser.newContext({ viewport: { width: 420, height: 900 } });

  // L'app crede di avere una sessione aperta: cosi' mostra le
  // schermate di chi ha effettuato l'accesso, e riconosce il gestore
  // del circolo che organizza il torneo.
  await context.addInitScript(({ rif, io }) => {
    const scadenza = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
    localStorage.setItem(`sb-${rif}-auth-token`, JSON.stringify({
      access_token: 'test.test.test', token_type: 'bearer',
      expires_in: 604800, expires_at: scadenza, refresh_token: 'test',
      user: {
        id: io, aud: 'authenticated', role: 'authenticated',
        email: 'test@esempio.it', email_confirmed_at: new Date().toISOString(),
        user_metadata: { nome: 'Andrea', cognome: 'Costa' }, app_metadata: {},
        created_at: new Date().toISOString(),
      },
    }));
  }, { rif: RIF, io: IO });

  await intercetta(context);

  const page = await context.newPage();

  // Un errore JavaScript nell'app e' di per se' un test fallito: e'
  // esattamente cosi' che il salvataggio si e' rotto la prima volta.
  const erroriPagina = [];
  page.on('pageerror', (e) => erroriPagina.push(e.message));

  await page.goto(`http://127.0.0.1:${PORTA}/index.html`, { waitUntil: 'load' });
  await page.waitForFunction(() => typeof window.apriTorneo === 'function', { timeout: 15000 });

  console.log('\n============================================================');
  console.log('PADEL CILENTO — L APP NEL BROWSER');
  console.log('============================================================');

  try {
    await testSetUnico(page);
    await testDueSuTre(page);
    await testTerzoSetFacoltativo(page);
    await testFasiConFormatiDiversi(page);
    await testPunteggioIncompleto(page);
  } finally {
    titolo('Errori JavaScript');
    esito('l app non ha sollevato eccezioni', erroriPagina.length === 0,
      erroriPagina.join(' | '));

    await context.close();
    await browser.close();
    server.close();
  }

  console.log('\n============================================================');
  if (falliti.length === 0) {
    console.log(`TUTTO A POSTO — ${passati} verifiche superate`);
    console.log('============================================================');
  } else {
    console.log(`${falliti.length} VERIFICHE FALLITE su ${passati + falliti.length}`);
    falliti.forEach((f) => console.log(`  · ${f}`));
    console.log('============================================================');
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
