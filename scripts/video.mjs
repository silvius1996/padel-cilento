#!/usr/bin/env node
/* =========================================================
   PADEL CILENTO — Registrazione dei video di presentazione

   Le due presentazioni sono pagine web che si animano da sole su
   una linea del tempo fissa (public/presentazione/). Questo script
   le apre in un browser senza finestra e ne registra lo schermo.

   Uso:
     npm run video              registra tutte e due
     npm run video giocatori    registra solo quella

   I file finiscono in  video/  e non vengono pubblicati.
========================================================= */

import { chromium } from 'playwright';
import { spawnSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const RADICE = process.cwd();
const CARTELLA_PUBBLICA = path.join(RADICE, 'public');
const USCITA = path.join(RADICE, 'video');
const PORTA = 8899;

// Durate scritte nelle pagine, piu' un margine per l'ultima dissolvenza
const VIDEO = {
  giocatori: { file: 'presentazione/giocatori.html', secondi: 48, titolo: 'Per i giocatori' },
  circoli:   { file: 'presentazione/circoli.html',   secondi: 56, titolo: 'Per i circoli' },
};

const TIPI = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.woff2': 'font/woff2',
};

function avviaServer() {
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(req.url.split('?')[0]);
    if (p === '/') p = '/index.html';
    const f = path.join(CARTELLA_PUBBLICA, p);
    if (!f.startsWith(CARTELLA_PUBBLICA) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) {
      res.writeHead(404); return res.end('non trovato');
    }
    res.writeHead(200, { 'Content-Type': TIPI[path.extname(f)] || 'application/octet-stream' });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise((r) => server.listen(PORTA, () => r(server)));
}

/**
 * Playwright salva in WebM. Il suo ffmpeg e' li' accanto: se c'e',
 * si produce anche un MP4, che e' il formato che tutti accettano
 * senza fare domande (WhatsApp, Instagram, presentazioni).
 */
function convertiInMp4(webm, mp4) {
  const cartella = path.join(RADICE, 'node_modules', 'playwright-core', '.local-browsers');
  const candidati = [
    process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers',
    cartella,
  ];

  let ffmpeg = null;
  for (const base of candidati) {
    if (!fs.existsSync(base)) continue;
    for (const d of fs.readdirSync(base)) {
      const tentativo = path.join(base, d, 'ffmpeg-linux');
      if (fs.existsSync(tentativo)) { ffmpeg = tentativo; break; }
    }
    if (ffmpeg) break;
  }

  if (!ffmpeg) {
    console.log('   (ffmpeg non trovato: resta il file WebM, che i browser leggono comunque)');
    return false;
  }

  const r = spawnSync(ffmpeg, [
    '-y', '-i', webm,
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'medium',
    '-movflags', '+faststart',
    mp4,
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  if (r.status !== 0) {
    console.log('   (conversione in MP4 non riuscita: resta il WebM)');
    return false;
  }
  return true;
}

async function registra(nome) {
  const conf = VIDEO[nome];
  if (!conf) {
    console.error(`Video sconosciuto: ${nome}. Disponibili: ${Object.keys(VIDEO).join(', ')}`);
    process.exit(1);
  }

  console.log(`\n${conf.titolo} — ${conf.secondi} secondi`);

  // Su questa macchina il browser e' fornito dall'ambiente, in una
  // posizione che non coincide con quella attesa da Playwright.
  const candidati = [
    process.env.PLAYWRIGHT_CHROMIUM,
    '/opt/pw-browsers/chromium',
  ].filter(Boolean);
  const eseguibile = candidati.find((c) => fs.existsSync(c));

  const browser = await chromium.launch({
    executablePath: eseguibile,
    args: ['--autoplay-policy=no-user-gesture-required'],
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    recordVideo: { dir: USCITA, size: { width: 1280, height: 720 } },
    deviceScaleFactor: 1,
  });

  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${PORTA}/${conf.file}`, { waitUntil: 'load' });

  // Si riparte da zero: la pagina potrebbe aver gia' consumato
  // qualche decimo di secondo di animazioni durante il caricamento.
  await page.evaluate(() => {
    document.getAnimations().forEach((a) => { a.currentTime = 0; });
  });

  await page.waitForTimeout(conf.secondi * 1000);

  await context.close();   // e' la chiusura del contesto che scrive il video
  await browser.close();

  // Playwright assegna un nome casuale: si rinomina.
  const generati = fs.readdirSync(USCITA)
    .filter((f) => f.endsWith('.webm'))
    .map((f) => ({ f, t: fs.statSync(path.join(USCITA, f)).mtimeMs }))
    .sort((a, b) => b.t - a.t);

  const webm = path.join(USCITA, `${nome}.webm`);
  fs.renameSync(path.join(USCITA, generati[0].f), webm);

  const dimensione = (fs.statSync(webm).size / 1024 / 1024).toFixed(1);
  console.log(`   ${path.relative(RADICE, webm)}  (${dimensione} MB)`);

  const mp4 = path.join(USCITA, `${nome}.mp4`);
  if (convertiInMp4(webm, mp4)) {
    const d = (fs.statSync(mp4).size / 1024 / 1024).toFixed(1);
    console.log(`   ${path.relative(RADICE, mp4)}  (${d} MB)`);
  }
}

// ---------------------------------------------------------
fs.mkdirSync(USCITA, { recursive: true });
const server = await avviaServer();

const richiesti = process.argv.slice(2).filter((a) => !a.startsWith('-'));
const daFare = richiesti.length > 0 ? richiesti : Object.keys(VIDEO);

for (const nome of daFare) await registra(nome);

server.close();
console.log('\nFatto.\n');
