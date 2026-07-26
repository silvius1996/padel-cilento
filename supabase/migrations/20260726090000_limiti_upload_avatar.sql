-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.7
-- Limiti di caricamento sugli avatar (dimensione e tipo di file)
--
-- PERCHE' SERVE
-- Il bucket "avatars" accettava qualunque file da qualunque utente
-- autenticato: la policy verifica solo che ci sia un accesso, non
-- COSA viene caricato. Il filtro accept="image/*" del modulo e' solo
-- lato browser, quindi aggirabile chiamando l'API di Storage a mano.
-- Un utente registrato poteva caricare file enormi o non-immagine in
-- un bucket pubblico.
--
-- I limiti impostati qui sono applicati dal servizio Storage prima
-- che il file venga scritto, quindi non sono aggirabili dal browser.
-- =========================================================


-- ---------------------------------------------------------
-- 1. DIMENSIONE MASSIMA E FORMATI AMMESSI
-- 2 MB bastano ampiamente per una foto profilo: l'app la mostra
-- al massimo a 80x80 punti.
-- I formati sono quelli che ogni browser sa produrre e mostrare;
-- restano fuori SVG (puo' contenere script) e i file non-immagine.
-- ---------------------------------------------------------
update storage.buckets
set file_size_limit = 2097152,  -- 2 MB, espressi in byte
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'avatars';


-- ---------------------------------------------------------
-- 2. NOTA SUGLI AVATAR GIA' CARICATI
-- I limiti valgono solo per i caricamenti futuri: le immagini
-- gia' presenti restano accessibili e non vengono toccate.
-- ---------------------------------------------------------


-- ---------------------------------------------------------
-- 3. VERIFICA (opzionale)
-- Dopo l'esecuzione questa query deve mostrare il limite e i
-- tre tipi ammessi.
-- ---------------------------------------------------------
-- select id, file_size_limit, allowed_mime_types
-- from storage.buckets where id = 'avatars';
