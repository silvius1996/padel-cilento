#!/usr/bin/env node
/* =========================================================
   PADEL CILENTO — Il volantino "metti l'app sul telefono"

   Genera un'immagine 1080x1350 (il formato verticale di Instagram)
   con le istruzioni per aggiungere l'app alla schermata home, e il
   QR code del sito dentro la grafica.

     npm run volantino

   Il file esce in  grafiche/installa-app.png

   PERCHE' LE ISTRUZIONI SONO QUESTE
   L'app non sta su nessuno store: e' una pagina web che il telefono
   sa installare da sola (PWA). Quindi non c'e' niente da scaricare,
   nessun download da attendere e nessun pulsante "Installa" dentro
   la pagina. Su iPhone il comando sta nel menu di condivisione di
   Safari — e solo di Safari: da Chrome su iOS quella voce non
   esiste. Su Android lo propone Chrome dal suo menu.
========================================================= */

import { mkdir } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import QRCode from 'qrcode';
import { segnoInLinea } from './marchio.mjs';

const SITO = 'https://padel-cilento.vercel.app';
const LIME = '#C6FF3D';
const SCURO = '#0B0F0E';

const PASSI_IOS = [
  'Apri <b>padel-cilento.vercel.app</b> con <b>Safari</b>',
  'Tocca l\'icona <b>Condividi</b>, il quadrato con la freccia in su',
  'Scorri e tocca <b>Aggiungi a Home</b>',
];

const PASSI_ANDROID = [
  'Apri il link con <b>Chrome</b>',
  'Tocca i <b>tre puntini</b> in alto a destra',
  'Tocca <b>Installa app</b>, oppure <b>Aggiungi a schermata Home</b>',
];

function passi(elenco) {
  return elenco.map((t, i) => `
    <li>
      <span class="numero">${i + 1}</span>
      <span class="testo">${t}</span>
    </li>`).join('');
}

function pagina(qr) {
  return `<style>
  @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&display=swap');

  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    width: 1080px; height: 1350px; background: ${SCURO}; color: #fff;
    font-family: 'Space Grotesk', 'Segoe UI', system-ui, sans-serif;
    padding: 64px 72px 60px; position: relative; overflow: hidden;
    display: flex; flex-direction: column;
  }
  /* Un alone verde in alto a destra, come sull'anteprima del link */
  .alone {
    position: absolute; top: -300px; right: -220px;
    width: 700px; height: 700px; border-radius: 50%;
    background: ${LIME}; opacity: .07;
  }
  .testata { display: flex; align-items: center; gap: 18px; }
  .testata .nome { font-size: 30px; font-weight: 700; letter-spacing: -.5px; }
  .testata .zona { font-size: 15px; font-weight: 600; letter-spacing: 4px; color: ${LIME}; }

  h1 {
    font-size: 74px; font-weight: 700; line-height: 1.02;
    letter-spacing: -2.5px; margin-top: 48px;
  }
  h1 .verde { color: ${LIME}; }
  .sottotitolo {
    font-size: 25px; line-height: 1.4; color: #9AA5A0;
    margin-top: 20px; max-width: 620px;
  }

  .blocchi { display: flex; gap: 28px; margin-top: 56px; align-items: flex-start; }
  .blocco {
    flex: 1; border: 1px solid #2A332F; border-radius: 24px; padding: 28px 26px;
  }
  .blocco h2 {
    font-size: 22px; font-weight: 700; letter-spacing: 1px;
    text-transform: uppercase; color: ${LIME}; margin-bottom: 22px;
  }
  ol { list-style: none; display: flex; flex-direction: column; gap: 18px; }
  li { display: flex; gap: 14px; align-items: flex-start; }
  .numero {
    flex: 0 0 30px; height: 30px; border-radius: 9px;
    background: ${LIME}; color: ${SCURO};
    font-size: 16px; font-weight: 700;
    display: flex; align-items: center; justify-content: center;
  }
  .testo { font-size: 20px; line-height: 1.32; color: #E6EBE8; padding-top: 3px; }
  .testo b { color: #fff; font-weight: 700; }

  /* Lo spazio che avanza sta qui, e dice qualcosa: e' il momento in
     cui il lettore ha finito i passi e vuole sapere cosa ottiene. */
  /* Il testo sta dentro un <p>: se lo si mette direttamente nel
     contenitore flessibile, ogni <b> diventa una colonna a se'. */
  .esito { flex: 1; display: flex; align-items: center; }
  .esito p {
    font-size: 27px; line-height: 1.35; color: #E6EBE8; max-width: 800px;
  }
  .esito b { color: ${LIME}; font-weight: 700; }

  .piede {
    display: flex; align-items: center; gap: 34px;
    border-top: 1px solid #2A332F; padding-top: 36px; margin-top: 44px;
  }
  /* Il bordo bianco non e' decorazione: un QR senza margine chiaro
     intorno ai bordi non viene letto. Servono almeno quattro moduli,
     e qui un modulo misura circa sei pixel. */
  .qr { background: #fff; padding: 28px; border-radius: 18px; line-height: 0; }
  .qr svg { width: 190px; height: 190px; display: block; }
  .piede .invito { font-size: 30px; font-weight: 700; line-height: 1.2; }
  .piede .link { font-size: 26px; font-weight: 600; color: ${LIME}; margin-top: 10px; }
  .piede .nota { font-size: 17px; color: #9AA5A0; margin-top: 14px; line-height: 1.35; }
</style>

<div class="alone"></div>

<div class="testata">
  ${segnoInLinea({ lato: 58 })}
  <div>
    <div class="nome">PADEL CILENTO</div>
    <div class="zona">PAESTUM · CAPACCIO · AGROPOLI</div>
  </div>
</div>

<h1>Mettila sul telefono,<br><span class="verde">come un'app</span></h1>
<p class="sottotitolo">
  Non sta su nessuno store e non c'è niente da scaricare: il telefono la
  installa da solo in dieci secondi. Poi si apre a tutto schermo, senza la
  barra del browser.
</p>

<div class="blocchi">
  <div class="blocco">
    <h2>iPhone</h2>
    <ol>${passi(PASSI_IOS)}</ol>
  </div>
  <div class="blocco">
    <h2>Android</h2>
    <ol>${passi(PASSI_ANDROID)}</ol>
  </div>
</div>

<div class="esito">
  <p>
    Da quel momento l'icona sta fra le tue app, insieme alle altre.
    <b>Un tocco e vedi le partite di stasera</b> — chi gioca, dove, e quanti
    posti sono rimasti liberi.
  </p>
</div>

<div class="piede">
  <div class="qr">${qr}</div>
  <div>
    <div class="invito">Inquadra il codice</div>
    <div class="link">padel-cilento.vercel.app</div>
    <div class="nota">Su iPhone il passaggio funziona solo da Safari:<br>da Chrome quella voce non compare.</div>
  </div>
</div>`;
}

async function main() {
  await mkdir('grafiche', { recursive: true });

  // Correzione d'errore alta: il codice resta leggibile anche se la
  // grafica viene stampata, piegata o ripresa storta dalla fotocamera.
  const qr = await QRCode.toString(SITO, {
    type: 'svg', errorCorrectionLevel: 'H', margin: 0,
    color: { dark: SCURO, light: '#FFFFFF' },
  });

  // Il QR anche da solo: serve per una locandina, un adesivo sul
  // bancone, il cartello all'ingresso del circolo. Qui il margine
  // chiaro lo mette la libreria, perche' non c'e' una grafica intorno.
  await QRCode.toFile('grafiche/qr-padel-cilento.png', SITO, {
    type: 'png', errorCorrectionLevel: 'H', margin: 4, width: 1000,
    color: { dark: SCURO, light: '#FFFFFF' },
  });

  const browser = await chromium.launch();
  try {
    const pag = await browser.newPage({ viewport: { width: 1080, height: 1350 } });
    await pag.setContent(pagina(qr), { waitUntil: 'networkidle' });
    await pag.screenshot({ path: 'grafiche/installa-app.png' });
    await pag.close();
  } finally {
    await browser.close();
  }

  console.log('Generati: grafiche/installa-app.png e grafiche/qr-padel-cilento.png');
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
