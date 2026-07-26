#!/usr/bin/env node
/* =========================================================
   PADEL CILENTO — I video di presentazione

   Dentro il telefono che si vede nei video gira l'APP VERA:
   public/index.html, con le sue schermate e i suoi modali. Non e'
   una copia disegnata per l'occasione.

   Per farla funzionare senza internet, le sue chiamate al database
   vengono intercettate e a ognuna si risponde con dati di esempio.
   L'app non se ne accorge: esegue il suo codice di sempre.

   Uso:
     npm run spot              registra tutti e due i video
     npm run spot giocatori

   I file finiscono in  video/  come MP4.
========================================================= */

import { chromium } from 'playwright';
import { spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const RADICE = process.cwd();
const PUBBLICA = path.join(RADICE, 'public');
const USCITA = path.join(RADICE, 'video');
const PORTA = 8901;
const RIF = 'eyxvgowdxcyxegktrgxp';           // riferimento del progetto Supabase
const IO = '11111111-1111-1111-1111-111111111111';

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
  role: 'gestore', circolo: 'Padel Arena', circolo_id: 'c1',
  eliminato_il: null, created_at: oggi.toISOString(),
};

const p = (id, ora, club, zona, livello, pieni, giorni, origine) => ({
  id, club, zona, match_date: giorno(giorni), match_time: ora, level: livello,
  total_slots: 4, filled_slots: pieni, created_by: IO, origin: origine,
  created_at: oggi.toISOString(),
});

const PARTITE = [
  p('m1', '19:30:00', 'Padel Arena', 'paestum', 'intermedio', 3, 0, 'circolo'),
  p('m2', '21:00:00', 'Circolo Le Torri', 'agropoli', 'open', 2, 0, 'giocatore'),
  p('m3', '18:00:00', 'Sporting Kaleido', 'capaccio', 'avanzato', 4, 1, 'circolo'),
  p('m4', '20:30:00', 'Padel Arena', 'paestum', 'principiante', 1, 1, 'giocatore'),
  p('m5', '19:00:00', 'Circolo Le Torri', 'agropoli', 'intermedio', 3, 2, 'giocatore'),
];

const g = (nome, cognome, livello) => ({ nome, cognome, full_name: `${nome} ${cognome}`, level: livello, avatar_url: null });
const PARTECIPANTI = [
  { user_id: IO, spot: 0, joined_at: oggi.toISOString(), profiles: g('Andrea', 'Costa', 'intermedio') },
  { user_id: 'u2', spot: 1, joined_at: oggi.toISOString(), profiles: g('Luca', 'Bianchi', 'intermedio') },
  { user_id: 'u3', spot: 2, joined_at: oggi.toISOString(), profiles: g('Marco', 'Rossi', 'intermedio') },
];

const CLASSIFICA = [
  { user_id: 'u3', nome: 'Marco', cognome: 'Rossi', avatar_url: null, level: 'avanzato', partite: 18, vittorie: 14, percentuale_vittorie: 78 },
  { user_id: IO, nome: 'Andrea', cognome: 'Costa', avatar_url: null, level: 'intermedio', partite: 14, vittorie: 10, percentuale_vittorie: 71 },
  { user_id: 'u4', nome: 'Anna', cognome: 'Verdi', avatar_url: null, level: 'intermedio', partite: 12, vittorie: 8, percentuale_vittorie: 67 },
  { user_id: 'u2', nome: 'Luca', cognome: 'Bianchi', avatar_url: null, level: 'intermedio', partite: 15, vittorie: 9, percentuale_vittorie: 60 },
  { user_id: 'u5', nome: 'Gennaro', cognome: 'Esposito', avatar_url: null, level: 'open', partite: 11, vittorie: 6, percentuale_vittorie: 55 },
];

const TORNEI = [{
  id: 't1', circolo_id: 'c1', nome: 'Torneo del Cilento 2026',
  descrizione: 'Due gironi, otto coppie', livello: 'intermedio',
  data_inizio: giorno(-6), data_fine: giorno(0), stato: 'in_corso',
  formato: 'gironi_e_finali', qualificate_per_girone: 2, finale_terzo_posto: true,
  creato_da: IO, created_at: oggi.toISOString(), circoli: { nome: 'Padel Arena' },
}];

const GIRONI = [
  { id: 'g1', torneo_id: 't1', nome: 'A', ordine: 1 },
  { id: 'g2', torneo_id: 't1', nome: 'B', ordine: 2 },
];

const sq = (id, a, b, gir) => ({
  id, torneo_id: 't1', nome: null, giocatore_1: a, giocatore_2: b,
  user_id_1: null, user_id_2: null, girone_id: gir, stato: 'iscritta',
  created_at: oggi.toISOString(),
});
const SQUADRE = [
  sq('s1', 'Marco Rossi', 'Luca Bianchi', 'g1'), sq('s2', 'Anna Verdi', 'Sara Neri', 'g1'),
  sq('s3', 'Paolo Gialli', 'Marco Blu', 'g1'),  sq('s4', 'Elena Viola', 'Ugo Grigi', 'g1'),
  sq('s5', 'Gennaro Esposito', 'Ciro Rullo', 'g2'), sq('s6', 'Giulia Fontana', 'Rita Greco', 'g2'),
  sq('s7', 'Anna Coppola', 'Luisa Ruggi', 'g2'), sq('s8', 'Nino Ferrara', 'Peppe Longo', 'g2'),
];

const inc = (id, gir, fase, turno, ordine, casa, osp, sets, v) => ({
  id, torneo_id: 't1', girone_id: gir, fase, turno, ordine,
  squadra_casa: casa, squadra_ospite: osp, data: null, ora: null, campo: null,
  sets, vincitore: v, registrato_da: IO, registrato_il: oggi.toISOString(),
  prossimo_incontro_id: null, prossimo_lato: null,
  perdente_incontro_id: null, perdente_lato: null,
});

const INCONTRI = [
  inc('i1', 'g1', 'girone', 1, 0, 's4', 's1', [[4, 6], [3, 6]], 'O'),
  inc('i2', 'g1', 'girone', 1, 1, 's2', 's3', [[7, 5], [6, 4]], 'C'),
  inc('i3', 'g1', 'girone', 2, 0, 's4', 's2', [[6, 3], [6, 2]], 'C'),
  inc('i4', 'g1', 'girone', 2, 1, 's3', 's1', [[2, 6], [4, 6]], 'O'),
  inc('i5', 'g1', 'girone', 3, 0, 's4', 's3', null, null),
  inc('i6', 'g1', 'girone', 3, 1, 's1', 's2', null, null),
  inc('i7', 'g2', 'girone', 1, 0, 's8', 's5', [[6, 1], [6, 4]], 'C'),
  inc('i8', 'g2', 'girone', 1, 1, 's6', 's7', [[6, 4], [3, 6], [6, 2]], 'C'),
  // Tabellone
  inc('f1', null, 'semifinale', 2, 0, 's1', 's6', [[6, 4], [6, 3]], 'C'),
  inc('f2', null, 'semifinale', 2, 1, 's8', 's2', null, null),
  inc('f3', null, 'finale', 1, 0, 's1', null, null, null),
  inc('f4', null, 'finale_3_4', 1, 1, 's6', null, null, null),
];

const cls = (pos, id, nome, pt, v, sv, sp, gf, gs) => ({
  posizione: pos, squadra_id: id, nome, partite: v + (pt / 3 === v ? 2 - v : 0) || 2,
  vittorie: v, sconfitte: 2 - v, punti: pt,
  set_vinti: sv, set_persi: sp, game_fatti: gf, game_subiti: gs,
});
const CLASSIFICHE = {
  g1: [
    cls(1, 's1', 'Marco Rossi / Luca Bianchi', 6, 2, 4, 0, 24, 13),
    cls(2, 's2', 'Anna Verdi / Sara Neri', 3, 1, 2, 2, 22, 21),
    cls(3, 's4', 'Elena Viola / Ugo Grigi', 3, 1, 2, 2, 19, 22),
    cls(4, 's3', 'Paolo Gialli / Marco Blu', 0, 0, 0, 4, 15, 24),
  ],
  g2: [
    cls(1, 's8', 'Nino Ferrara / Peppe Longo', 3, 1, 2, 0, 12, 5),
    cls(2, 's6', 'Giulia Fontana / Rita Greco', 3, 1, 2, 1, 15, 12),
    cls(3, 's5', 'Gennaro Esposito / Ciro Rullo', 0, 0, 0, 2, 5, 12),
    cls(4, 's7', 'Anna Coppola / Luisa Ruggi', 0, 0, 1, 2, 12, 15),
  ],
};

const BACHECA = [
  { torneo_id: 'tx', torneo: 'Trofeo di Primavera', circolo: 'Padel Arena', data: giorno(-90), posizione: 1, squadra: 'Andrea Costa / Luca Bianchi' },
  { torneo_id: 'ty', torneo: 'Open di Paestum', circolo: 'Sporting Kaleido', data: giorno(-160), posizione: 2, squadra: 'Andrea Costa / Marco Rossi' },
];

const STATISTICHE = [{
  user_id: IO, nome: 'Andrea', cognome: 'Costa', level: 'intermedio', avatar_url: null,
  partite: 14, vittorie: 10, sconfitte: 4, percentuale_vittorie: 71,
}];

// ---------------------------------------------------------
// Le risposte, scelte in base a cosa l'app sta chiedendo
// ---------------------------------------------------------
function rispostaPer(url) {
  const u = new URL(url);
  const via = u.pathname;
  const select = u.searchParams.get('select') || '';

  if (via.includes('/auth/v1/user')) return { user: { id: IO, email: 'demo@esempio.it' } };
  if (via.includes('/auth/v1/')) return {};

  if (via.endsWith('/rpc/mio_profilo')) return PROFILO;
  if (via.endsWith('/rpc/statistiche_giocatore')) return STATISTICHE;
  if (via.endsWith('/rpc/classifica')) return CLASSIFICA;
  if (via.endsWith('/rpc/bacheca_giocatore')) return BACHECA;
  if (via.endsWith('/rpc/contatti_partita')) {
    return PARTECIPANTI.map((x) => ({
      user_id: x.user_id, nome: x.profiles.nome, cognome: x.profiles.cognome,
      telefono: '3330000000', spot: x.spot, squadra: x.spot < 2 ? 'A' : 'B',
    }));
  }
  if (via.endsWith('/rpc/classifica_girone')) return null;   // deciso dal corpo, vedi sotto

  if (via.endsWith('/matches')) return PARTITE;
  if (via.endsWith('/match_players')) {
    return select.startsWith('match_id')
      ? [{ match_id: 'm1' }, { match_id: 'm3' }]
      : PARTECIPANTI;
  }
  if (via.endsWith('/match_results')) return [];
  if (via.endsWith('/tornei')) return TORNEI;
  if (via.endsWith('/tornei_gironi')) return GIRONI;
  if (via.endsWith('/torneo_squadre')) return SQUADRE;
  if (via.endsWith('/torneo_incontri')) return INCONTRI;

  return [];
}

async function intercetta(context) {
  // Font di Google e Sentry: da qui non si raggiungono, e aspettare
  // che scada l'attesa significa aprire il video su dieci secondi di
  // nero. Si rifiutano subito.
  await context.route(/fonts\.(googleapis|gstatic)\.com|sentry/, (route) => route.abort());

  await context.route('**/*.supabase.co/**', async (route) => {
    const req = route.request();
    const url = req.url();

    let corpo = rispostaPer(url);

    // La classifica di un girone dipende da quale girone si chiede
    if (url.includes('/rpc/classifica_girone')) {
      let girone = 'g1';
      try { girone = JSON.parse(req.postData() || '{}').p_girone_id || 'g1'; } catch { /* niente */ }
      corpo = CLASSIFICHE[girone] || [];
    }

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      headers: { 'access-control-allow-origin': '*' },
      body: JSON.stringify(corpo),
    });
  });
}

// ---------------------------------------------------------
// Utilita' di regia
// ---------------------------------------------------------
const attesa = (ms) => new Promise((r) => setTimeout(r, ms));

function creaRegista(page, appFrame) {
  const palco = (fn, ...a) => page.evaluate(
    ({ f, args }) => window.spot[f](...args), { f: fn, args: a },
  );

  return {
    camera: (n) => palco('camera', n),
    titolo: (lato, occhiello, t, s) => palco('titolo', lato, occhiello, t, s),
    // Si aspetta che la didascalia sia sparita davvero prima di
    // cambiare schermata: altrimenti per un istante si vede il testo
    // di una scena sopra il contenuto di quella dopo.
    viaTitoli: async () => { await palco('nascondiTitoli'); await attesa(700); },
    apertura: (t, s) => palco('apertura', t, s),
    viaApertura: () => palco('viaApertura'),
    chiusura: () => palco('chiusura'),
    tocca: (x, y) => palco('tocca', x, y),
    attesa,
    /** Esegue del codice dentro l'app vera. */
    app: (fn, arg) => appFrame.evaluate(fn, arg),
  };
}

// ---------------------------------------------------------
// COPIONE 1 — I GIOCATORI
// ---------------------------------------------------------
async function copioneGiocatori(r) {
  await r.apertura('Gioca a <span class="verde">Padel</span><br>nel Cilento', 'Paestum · Capaccio · Agropoli');
  await r.attesa(3200);
  await r.viaApertura();
  await r.attesa(900);

  // --- Il feed ---
  await r.camera('sinistra');
  await r.titolo('sx', 'Le partite di oggi', 'Vedi chi gioca,\ne dove manca uno',
    'Orario, circolo e posti liberi si vedono anche senza registrarsi.');
  await r.attesa(4400);

  await r.app(() => {
    document.querySelector('main')?.scrollTo({ top: 260, behavior: 'smooth' });
    window.scrollTo({ top: 260, behavior: 'smooth' });
  });
  await r.attesa(2400);

  // --- Hai gia' il campo: cerchi i giocatori ---
  await r.viaTitoli();
  await r.tocca(640, 250);
  await r.app(() => {
    window.scrollTo({ top: 0 });
    openCreateModal();
  });
  await r.camera('destra');
  await r.attesa(1600);
  await r.titolo('dx', 'Hai gia\' prenotato?', 'Il campo ce l\'hai,\nmancano i giocatori',
    'Pubblichi l\'ora che hai prenotato e ti arriva chi manca. Bastano trenta secondi.');
  await r.attesa(5200);

  // --- Il campo: si sceglie il posto ---
  await r.viaTitoli();
  await r.app(() => { closeModal(el.modalCreate); apriDettaglioPartita('m1'); });
  await r.camera('vicino');
  await r.attesa(1800);
  await r.titolo('sx', 'Il campo', 'Scegli il tuo posto,\nnon un posto qualsiasi',
    'I posti 0 e 1 sono una coppia, 2 e 3 l\'altra: sai con chi giochi e contro chi.');
  await r.attesa(5000);

  // --- Il risultato ---
  await r.viaTitoli();
  await r.camera('alto');
  await r.attesa(1000);
  await r.titolo('dx', 'A fine partita', 'Il punteggio lo\nconferma l\'avversario',
    'Chi ha vinto lo calcola l\'app dal punteggio. Nessuno se lo assegna da solo.');
  await r.attesa(4600);

  // --- LA CLASSIFICA: il momento piu' importante del video ---
  await r.viaTitoli();
  await r.app(() => { closeModal(el.modalMatch); apriClassifica(); });
  await r.camera('centro');
  await r.attesa(1800);
  await r.titolo('sx', 'La classifica', 'Ora puoi vantarti\ncon i tuoi amici',
    'Chi vince davvero si vede. E resta scritto.');
  await r.attesa(4200);

  // Ci si avvicina: si legge chi e' davanti a chi
  await r.camera('vicino');
  await r.titolo('sx', 'La classifica', 'Ora puoi vantarti\ncon i tuoi amici',
    'Le percentuali le calcola l\'app dai risultati confermati, non dai racconti del bar.');
  await r.attesa(4600);

  // --- La bacheca ---
  await r.viaTitoli();
  await r.app(() => { closeModal(el.modalRanking); openProfileModal(); });
  await r.camera('destra');
  await r.attesa(1800);
  await r.titolo('dx', 'La tua bacheca', 'I tornei che hai vinto,\nsul tuo profilo',
    'Con il nome del circolo che li ha organizzati.');
  await r.attesa(4400);

  // --- Chiusura ---
  await r.viaTitoli();
  await r.camera('uscita');
  await r.attesa(1300);
  await r.chiusura();
  await r.attesa(3600);
}

// ---------------------------------------------------------
// COPIONE 2 — I CIRCOLI
// Piu' lungo e piu' dettagliato dell'altro: qui non si emoziona
// nessuno, si fa vedere un prodotto a chi deve decidere se pagarlo.
// ---------------------------------------------------------
async function copioneCircoli(r) {
  await r.apertura('Il tuo circolo,<br>sull\'app del <span class="verde">Cilento</span>', 'Tornei, campi e giocatori. In un posto solo.');
  await r.attesa(3400);
  await r.viaApertura();
  await r.attesa(900);

  // --- 1. I campi liberi ---
  await r.camera('sinistra');
  await r.titolo('sx', 'I campi liberi', 'Pubblichi un\'ora vuota,\nte la riempiono loro',
    'Chi cerca una partita nel Cilento apre l\'app e trova il tuo circolo, con il tuo nome.');
  await r.attesa(4800);

  // --- 2. Si crea il torneo ---
  await r.viaTitoli();
  await r.app(() => { apriTornei(); });
  await r.camera('centro');
  await r.attesa(1500);
  await r.tocca(640, 232);
  await r.app(() => { el.btnNuovoTorneo.click(); });
  await r.attesa(1400);
  await r.app(() => {
    el.torneoNome.value = 'Torneo di Ferragosto';
    el.torneoLivello.value = 'intermedio';
  });
  await r.camera('vicino');
  await r.attesa(1200);
  await r.titolo('sx', 'Passo 1', 'Crei il torneo\nin trenta secondi',
    'Nome, date, livello. Nasce come bozza: lo vedi solo tu finche\' non apri le iscrizioni.');
  await r.attesa(5000);

  // --- 3. Gironi e squadre ---
  await r.viaTitoli();
  await r.app(() => { closeModal(el.modalCreaTorneo); apriTorneo('t1'); });
  await r.camera('destra');
  await r.attesa(2000);
  await r.titolo('dx', 'Passo 2', 'Iscrivi le coppie\nscrivendo due nomi',
    'Non serve che i giocatori si registrino: prendi il foglio che hai gia\' e lo copi.');
  await r.attesa(5000);

  // --- 4. Il calendario e la classifica ---
  await r.viaTitoli();
  await r.app(() => {
    document.querySelector('#modal-torneo .overflow-y-auto')
      ?.scrollTo({ top: 380, behavior: 'smooth' });
  });
  await r.camera('vicino');
  await r.attesa(2200);
  await r.titolo('sx', 'Passo 3', 'Il calendario\nse lo fa da solo',
    'Tutti contro tutti dentro il girone, diviso in turni. Un pulsante, non un pomeriggio.');
  await r.attesa(5000);

  await r.viaTitoli();
  await r.attesa(300);
  await r.titolo('dx', 'La classifica', 'Si aggiorna a ogni\nrisultato che inserisci',
    'Punti, set e game. A pari punti decide lo scontro diretto: le regole sono scritte, non discusse.');
  await r.attesa(5200);

  // --- 5. Il tabellone ---
  await r.viaTitoli();
  await r.app(() => {
    const c = document.querySelector('#modal-torneo .overflow-y-auto');
    c?.scrollTo({ top: c.scrollHeight, behavior: 'smooth' });
  });
  await r.camera('alto');
  await r.attesa(2400);
  await r.titolo('sx', 'Passo 4', 'Le finali\nvanno avanti da sole',
    'Inserisci il punteggio: chi vince compare nel turno dopo, senza che tu componga niente.');
  await r.attesa(5200);

  // --- 6. Le medaglie ---
  await r.viaTitoli();
  await r.app(() => { closeModal(el.modalTorneo); openProfileModal(); });
  await r.camera('centro');
  await r.attesa(1800);
  await r.titolo('dx', 'Dopo il torneo', 'Il nome del tuo circolo\nresta sul loro profilo',
    'Chi vince si porta il tuo torneo in bacheca. E lo fa vedere agli altri.');
  await r.attesa(4800);

  // --- Chiusura ---
  await r.viaTitoli();
  await r.camera('uscita');
  await r.attesa(1300);
  await r.chiusura();
  await r.attesa(3800);
}

const COPIONI = {
  giocatori: { fn: copioneGiocatori, titolo: 'Per i giocatori' },
  circoli:   { fn: copioneCircoli,   titolo: 'Per i circoli' },
};

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

function inMp4(webm, mp4, taglioIniziale = 0) {
  const r = spawnSync('ffmpeg', [
    '-y', '-ss', taglioIniziale.toFixed(2), '-i', webm,
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '19', '-preset', 'slow',
    '-vf', 'fps=30', '-movflags', '+faststart', mp4,
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  return r.status === 0;
}

async function registra(nome) {
  const copione = COPIONI[nome];
  console.log(`\n${copione.titolo}`);

  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    recordVideo: { dir: USCITA, size: { width: 1280, height: 720 } },
    deviceScaleFactor: 1,
  });

  // L'app crede di avere una sessione aperta: cosi' mostra le
  // schermate di chi ha effettuato l'accesso, non quelle da visitatore.
  await context.addInitScript(({ rif, io }) => {
    const scadenza = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
    localStorage.setItem(`sb-${rif}-auth-token`, JSON.stringify({
      access_token: 'demo.demo.demo', token_type: 'bearer',
      expires_in: 604800, expires_at: scadenza, refresh_token: 'demo',
      user: {
        id: io, aud: 'authenticated', role: 'authenticated',
        email: 'demo@esempio.it', email_confirmed_at: new Date().toISOString(),
        user_metadata: { nome: 'Andrea', cognome: 'Costa' }, app_metadata: {},
        created_at: new Date().toISOString(),
      },
    }));
  }, { rif: RIF, io: IO });

  await intercetta(context);

  const avvio = Date.now();   // da qui Playwright sta gia' registrando

  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORTA}/presentazione/spot.html`, { waitUntil: 'load' });
  await attesa(1800);   // l'app dentro il telefono deve finire di caricare

  const appFrame = page.frames().find((f) => f.url().includes('index.html'));
  if (!appFrame) throw new Error('l\'app non e\' stata caricata nel telaio');

  const regista = creaRegista(page, appFrame);

  const inizioScena = (Date.now() - avvio) / 1000;
  await copione.fn(regista);

  await context.close();
  await browser.close();

  const generati = fs.readdirSync(USCITA).filter((f) => f.endsWith('.webm'))
    .map((f) => ({ f, t: fs.statSync(path.join(USCITA, f)).mtimeMs }))
    .sort((a, b) => b.t - a.t);

  const webm = path.join(USCITA, `${nome}.webm`);
  if (fs.existsSync(webm)) fs.unlinkSync(webm);
  fs.renameSync(path.join(USCITA, generati[0].f), webm);

  const mp4 = path.join(USCITA, `${nome}.mp4`);
  if (inMp4(webm, mp4, Math.max(0, inizioScena - 0.25))) {
    console.log(`   video/${nome}.mp4  (${(fs.statSync(mp4).size / 1048576).toFixed(1)} MB)`);
    fs.unlinkSync(webm);
  } else {
    console.log(`   video/${nome}.webm  (conversione in MP4 non riuscita)`);
  }
}

// ---------------------------------------------------------
fs.mkdirSync(USCITA, { recursive: true });
const server = await avviaServer();

const richiesti = process.argv.slice(2).filter((a) => !a.startsWith('-'));
for (const nome of (richiesti.length ? richiesti : Object.keys(COPIONI))) await registra(nome);

server.close();
console.log('\nFatto.\n');
