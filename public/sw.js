// Service worker minimale per Padel Cilento.
// Mette in cache SOLO la shell statica dell'app (per l'installabilità/offline
// di base) e lascia passare alla rete, senza intercettarle, tutte le
// richieste verso Supabase, CDN esterni o qualunque dominio diverso dal
// proprio: i dati delle partite restano sempre live, mai serviti dalla cache.

const CACHE_NAME = 'padel-cilento-shell-v1';
const SHELL_ASSETS = ['/', '/index.html', '/manifest.json', '/icons/icon.svg'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;

  // Solo richieste GET sullo stesso dominio: tutto il resto (API Supabase,
  // Tailwind CDN, Google Fonts, ecc.) non viene toccato.
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) {
    return;
  }

  // Network-first con fallback alla cache, cosi' la shell resta aggiornata
  // quando c'e' connessione e disponibile offline quando manca.
  event.respondWith(
    fetch(request)
      .then((response) => {
        const responseClone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, responseClone));
        return response;
      })
      .catch(() => caches.match(request).then((cached) => cached || caches.match('/index.html')))
  );
});
