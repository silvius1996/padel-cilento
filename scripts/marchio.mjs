// Genera gli asset del marchio Padel Cilento a partire da un'unica geometria.
//
// La racchetta e' un solo profilo continuo: testa a goccia, strozzatura e manico
// sono la stessa linea, cosi' non ci sono contorni che si attraversano.
// Da qui escono l'icona dell'app (senza onda, regge fino a 28px) e il marchio
// esteso (con l'onda della costa) usato in grande.
//
//   npm run marchio        genera public/icons/* e public/marchio/*
//
import { mkdir, writeFile } from 'node:fs/promises';
import { chromium } from 'playwright';

const LIME = '#C6FF3D';
const SCURO = '#0B0F0E';
const VERDE_SCURO = '#3D7A00';

// Disegnata attorno all'origine, dentro il riquadro x -26..26, y -80..18.
const PROFILO = [
  'M0 -80',
  'C17 -80, 26 -68, 26 -54',
  'C26 -40, 17 -28, 8 -20',   // scende nella strozzatura
  'L8 10',                     // fianco destro del manico
  'A8 8 0 0 1 -8 10',          // fondo arrotondato
  'L-8 -20',                   // fianco sinistro del manico
  'C-17 -28, -26 -40, -26 -54',
  'C-26 -68, -17 -80, 0 -80 Z',
].join(' ');

const FORI = [
  [-8, -68], [8, -68],
  [-18, -57], [-6, -57], [6, -57], [18, -57],
  [-12, -46], [0, -46], [12, -46],
  [-6, -35], [6, -35],
];

const RIQUADRO = { x0: -26, y0: -80, x1: 26, y1: 18 };
const ONDA = 'M15 94 C28 85, 37 103, 52 94 S76 85, 97 94';

function racchetta(colore, spessore) {
  const fori = FORI.map(([x, y]) => `<circle cx="${x}" cy="${y}" r="3.4" fill="${colore}"/>`).join('');
  return `<path d="${PROFILO}" fill="none" stroke="${colore}" stroke-width="${spessore}" stroke-linejoin="round"/>${fori}`;
}

/** Scala il riquadro all'altezza voluta e lo centra su cx, partendo dall'alto. */
function inquadra(cx, alto, altezza) {
  const s = altezza / (RIQUADRO.y1 - RIQUADRO.y0);
  const tx = cx - ((RIQUADRO.x0 + RIQUADRO.x1) / 2) * s;
  const ty = alto - RIQUADRO.y0 * s;
  return { transform: `translate(${tx.toFixed(2)},${ty.toFixed(2)}) scale(${s.toFixed(3)})`, s };
}

/**
 * Il segno dentro un riquadro 112x112.
 * @param {object} o
 * @param {string} o.tratto      colore del disegno
 * @param {string} o.sfondo      colore del fondo, o null per fondo trasparente
 * @param {boolean} o.onda       se includere l'onda della costa
 * @param {number} o.raggio      raggio degli angoli del fondo
 * @param {number} o.margine     quanto rimpicciolire il disegno (per le icone maskable)
 */
function segno({ tratto, sfondo, onda = false, raggio = 30, margine = 1, spessore = 5.5 }) {
  const altezza = (onda ? 76 : 86) * margine;
  const alto = (onda ? 9 : 13) * margine + (112 * (1 - margine)) / 2;
  const { transform, s } = inquadra(56, alto, altezza);
  const fondo = sfondo === null ? '' : `<rect width="112" height="112" rx="${raggio}" fill="${sfondo}"/>`;
  const riga = onda
    ? `<path d="${ONDA}" stroke="${tratto}" stroke-width="5" stroke-linecap="round" fill="none"/>`
    : '';
  return `${fondo}<g transform="${transform}">${racchetta(tratto, spessore / s)}</g>${riga}`;
}

function svg(contenuto, lato = 512) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 112 112" width="${lato}" height="${lato}">${contenuto}</svg>`;
}

/** Il marchio esteso: il segno con l'onda piu' il nome accanto. */
function marchioEsteso(sfondo = 'scuro') {
  const [fondo, tratto, nome, sotto] =
    sfondo === 'scuro' ? [LIME, SCURO, '#FFFFFF', LIME] : [SCURO, LIME, SCURO, VERDE_SCURO];
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 440 150" width="440" height="150" fill="none">
  <g transform="translate(14,14) scale(1.02)">${segno({ tratto, sfondo: fondo, onda: true })}</g>
  <text x="146" y="68" font-family="Space Grotesk, system-ui, sans-serif" font-size="44" font-weight="700"
        letter-spacing="-1.5" fill="${nome}">PADEL</text>
  <text x="148" y="100" font-family="Space Grotesk, system-ui, sans-serif" font-size="24" font-weight="600"
        letter-spacing="8.5" fill="${sotto}">CILENTO</text>
</svg>`;
}

// L'icona normale sta dentro un quadrato con gli angoli arrotondati.
// Quella maskable viene ritagliata da Android dentro un cerchio che ne copre
// circa l'80%, quindi ha il fondo a tutta pagina e il disegno piu' piccolo.
const ICONA = svg(segno({ tratto: SCURO, sfondo: LIME }));
const ICONA_MASKABLE = svg(segno({ tratto: SCURO, sfondo: LIME, raggio: 0, margine: 0.72 }));

/** Il segno da mettere in linea nell'HTML, senza intestazione XML. */
export function segnoInLinea({ tratto = SCURO, sfondo = LIME, lato = 36 } = {}) {
  return `<svg viewBox="0 0 112 112" width="${lato}" height="${lato}" aria-hidden="true">${segno({ tratto, sfondo })}</svg>`;
}

async function png(browser, sorgente, lato, destinazione) {
  const pagina = await browser.newPage({ viewport: { width: lato, height: lato } });
  await pagina.setContent(
    `<style>html,body{margin:0;padding:0;background:transparent}</style>${sorgente.replace(/width="\d+" height="\d+"/, `width="${lato}" height="${lato}"`)}`,
  );
  await pagina.locator('svg').screenshot({ path: destinazione, omitBackground: true });
  await pagina.close();
}

async function main() {
  await mkdir('public/icons', { recursive: true });
  await mkdir('public/marchio', { recursive: true });

  await writeFile('public/icons/icon.svg', ICONA);
  await writeFile('public/icons/icon-maskable.svg', ICONA_MASKABLE);
  await writeFile('public/marchio/logo-scuro.svg', marchioEsteso('scuro'));
  await writeFile('public/marchio/logo-chiaro.svg', marchioEsteso('chiaro'));

  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || undefined,
  });
  try {
    await png(browser, ICONA, 192, 'public/icons/icon-192.png');
    await png(browser, ICONA, 512, 'public/icons/icon-512.png');
    await png(browser, ICONA, 180, 'public/icons/apple-touch-icon.png');
    await png(browser, ICONA_MASKABLE, 192, 'public/icons/icon-maskable-192.png');
    await png(browser, ICONA_MASKABLE, 512, 'public/icons/icon-maskable-512.png');
  } finally {
    await browser.close();
  }

  console.log('Marchio generato: icone SVG e PNG in public/icons, marchio esteso in public/marchio.');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await main();
}
