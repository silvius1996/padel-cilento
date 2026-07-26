# Da lanciare — aggiornamenti dal n.7 al n.11

Promemoria per applicare le modifiche del branch `claude/project-visibility-aqdi5f`.
**Cancella questo file quando hai finito**: vale una volta sola.

## Prima di tutto: sei allineato?

```bash
git status          # dev'essere vuoto
git log --oneline -3
```

Se hai lavoro locale non ancora su GitHub, salvalo prima:

```bash
git add -A && git commit -m "lavoro locale" && git push origin master
```

## I comandi, in questo ordine

```bash
git fetch origin
git checkout claude/project-visibility-aqdi5f

npm install         # serve: e' stata aggiunta una dipendenza (tailwindcss)
npm test            # deve dire: TUTTO A POSTO — 153 verifiche superate

npm run db:push     # applica al database le cinque migrazioni mancanti
npm run db:status   # controllo

npm run deploy      # rigenera il CSS e pubblica il sito
```

**L'ordine conta.** `db:push` va prima di `deploy`: l'interfaccia nuova chiama
funzioni (`crea_partita`, `elimina_mio_account`, `correggi_risultato`) che senza
il `db:push` nel database non esistono ancora. Al contrario, se pubblichi solo il database e non
il sito, non si rompe niente: l'app vecchia continua a funzionare.

**Se `npm test` non arriva a 153, fermati** senza lanciare `db:push`: vuol dire
che il database di produzione non corrisponde a quello che descrivono le
migrazioni, e va capito perche' prima.

## Dopo il deploy, cinque prove a mano

I test girano su uno schema ricostruito dalle migrazioni, non sul database vero.
Queste prove chiudono il cerchio:

1. **Apri il sito** — deve essere impaginato come sempre. Se lo vedi come testo
   nudo senza stile, manca `public/styles.css`: rilancia `npm run build:css` e
   `npm run deploy`.
2. **Organizza una partita** — deve comparire nel feed con te già in campo nel
   posto che hai scelto.
3. **Salva il profilo** (nome, telefono, livello, foto) — deve funzionare.
4. **Prova a caricare una foto da più di 2 MB** — deve dare un errore chiaro
   invece di caricarla.
5. **Registra un utente nuovo di prova, poi eliminalo** dal suo profilo
   (Elimina il mio account) — e verifica che con quelle credenziali non si entri
   piu'.

Se il salvataggio del profilo desse errore, la causa piu' probabile e' una
colonna aggiunta a mano dall'Editor SQL che non compare negli elenchi dei
`grant` delle migrazioni n.6 / n.9: basta aggiungerla li'.

## I tuoi due aggiornamenti, n.7 e n.8

Erano gia' scritti sul tuo computer e non ancora applicati. Sono stati uniti
al resto senza modifiche.

- **n.7** `20260726090000_limiti_upload_avatar.sql` — dimensione massima (2 MB)
  e formati ammessi sul bucket degli avatar.
- **n.8** `20260726091000_antibruteforce_codice_circolo.sql` — dopo 5 tentativi
  falliti sul codice circolo l'utente resta bloccato 15 minuti, e durante il
  blocco non funziona nemmeno il codice corretto. La funzione ora restituisce
  l'esito invece di sollevare un'eccezione, perche' un'eccezione annullerebbe
  la transazione e con essa il contatore dei tentativi.

## Cosa contiene l'aggiornamento n.9 — sicurezza

`supabase/migrations/20260726120000_permessi_ruolo_e_contestazione.sql`

1. **Il ruolo "gestore" non si autoassegna.** La policy di UPDATE su `profiles`
   concedeva la scrittura di tutte le colonne, `role` compresa: dalla console del
   browser bastava un `update` per diventare gestore di un circolo inventato, e
   `usa_codice_circolo` diventava decorativa. Ora i permessi sono per colonna,
   con un trigger come secondo lucchetto.
2. **Un risultato confermato non si annulla.** `contesta_risultato` non guardava
   ne' lo stato ne' chi la chiamava: chi perdeva poteva contestare una partita
   gia' confermata e cancellare la sconfitta dalle statistiche. Ora si contesta
   solo un risultato ancora in attesa, non il proprio, ed entro le 48 ore.
3. **I posti occupati non si falsificano.** `increment_filled_slots` e
   `decrement_filled_slots` erano eseguibili da chiunque su qualunque partita e
   non servivano piu' a nessuno. Rimosse.
4. **Niente partite con data nel passato.** Il controllo esisteva solo
   nell'attributo `min` del campo data, quindi era aggirabile dalla console.

## Cosa contiene l'aggiornamento n.10 — account, partite, avatar

`supabase/migrations/20260726150000_account_partita_atomica_avatar.sql`

1. **Cancellazione dell'account** (`elimina_mio_account`), con il pulsante nel
   profilo. Non e' una `delete` delle righe: i dati personali vengono cancellati
   e le credenziali eliminate, ma le partite giocate restano intestate a
   "Giocatore eliminato". Cancellarle vorrebbe dire riscrivere le statistiche
   degli altri tre giocatori, ed e' anche il motivo tecnico per cui una `delete`
   non passerebbe: `match_results.registrato_da` e il trigger che congela le
   formazioni la bloccherebbero.
2. **La partita nasce con il suo organizzatore** (`crea_partita`), in
   un'unica transazione. Prima erano due scritture in sequenza con un rollback a
   mano: se cadeva la connessione a meta', nel feed restava una partita fantasma
   a zero giocatori.
3. **Avatar: di chi sono i file.** I limiti di dimensione e formato li mette
   gia' il tuo aggiornamento n.7; qui si aggiunge che ognuno puo' scrivere
   soltanto i propri file (prima il nome era libero, quindi chiunque poteva
   scrivere nel bucket di tutti). Unica aggiunta ai formati: HEIC, perche' iOS
   a volte consegna la foto senza convertirla in JPEG.

## Fuori dal database: gli asset non arrivano piu' da CDN

Tailwind veniva caricato da `cdn.tailwindcss.com` e la libreria Supabase da
jsdelivr. Con quei domini lenti o bloccati l'app si apriva illeggibile, oppure
si apriva ma non leggeva nemmeno l'elenco delle partite. Ora:

- `public/styles.css` (17 KB) e' generato da `npm run build:css`, che il
  `deploy` lancia da solo. La configurazione sta in `tailwind.config.js`.
- `public/vendor/supabase-js-2.js` e' la libreria, servita dal nostro dominio.
  Per aggiornarla in futuro:
  `npm install @supabase/supabase-js@2 && cp node_modules/@supabase/supabase-js/dist/umd/supabase.js public/vendor/supabase-js-2.js`

Restano su CDN esterni due cose che degradano bene: i **font di Google** (senza
di loro il testo usa il font di sistema, resta leggibile) e **Sentry** (protetto
da un `if`: se non carica, l'app non se ne accorge).

## Cosa contiene l'aggiornamento n.11 — amministratore e correzioni

`supabase/migrations/20260726180000_amministratore_correzione_risultato.sql`

1. **L'amministratore.** Nuovo ruolo `admin`, che puo' modificare ed eliminare
   qualunque partita, togliere un giocatore da una formazione e annullare un
   risultato. I pulsanti compaiono da soli nell'app quando il ruolo e' attivo.
2. **Il punteggio si puo' correggere.** Prima, se sbagliavi a digitare, non
   c'era rimedio: l'unica uscita era che un avversario confermasse il punteggio
   sbagliato. Ora si corregge finche' non e' confermato — da chi l'ha inserito
   se e' in attesa, da chiunque abbia giocato se e' contestato. E' cosi' che si
   scioglie una contestazione.
3. **Una partita conclusa si puo' eliminare.** Era un difetto che riguardava
   tutti, non solo l'amministratore: il trigger che congela la formazione
   bloccava anche la cancellazione a cascata, quindi *nessuno* poteva eliminare
   una partita con un risultato registrato, nemmeno chi l'aveva creata.
4. **Non ci si iscrive a una partita gia' iniziata.** Si impediva di crearne una
   nel passato, ma non di infilarsi in una gia' finita chiamando l'API.

### Come ti nomini amministratore

Dal browser non e' possibile, ed e' voluto: la colonna `role` non e' scrivibile
dall'app. Si fa una volta sola dall'**Editor SQL di Supabase**, sostituendo
l'email con la tua:

```sql
update public.profiles
set role = 'admin'
where id = (select id from auth.users where email = 'tua@email.it');
```

Poi esci e rientra nell'app: i pulsanti di gestione compaiono su tutte le
partite, non solo sulle tue.

## Cosa resta aperto

- **Privacy — da chiudere prima di aprire al pubblico.** In `public/privacy.html`
  restano quattro dati da compilare: nome o ragione sociale del titolare del
  trattamento, indirizzo o P.IVA, email di contatto per le richieste privacy, e i
  giorni entro cui evadi le richieste gestite a mano. Il resto della pagina e'
  aggiornato, compresa la descrizione di cosa fa esattamente la cancellazione
  dell'account.
- **Font di Google sul percorso critico** (vedi sopra): si possono servire in
  locale, ma la degradazione attuale e' accettabile.
- **Nessun limite alla creazione di partite**: un utente puo' crearne centinaia
  di fila e riempire il feed. Ora almeno l'amministratore puo' ripulire.
- **Il gestore di circolo** oggi gestisce solo le partite che ha creato lui,
  come qualunque altro utente. Dargli poteri sulle partite del proprio circolo
  create da altri e' il passo successivo, ancora da definire.
