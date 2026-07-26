# Da lanciare — aggiornamenti n.7 e n.8

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
npm test            # deve dire: TUTTO A POSTO — 110 verifiche superate

npm run db:push     # applica le migrazioni n.7 e n.8 al database vero
npm run db:status   # controllo

npm run deploy      # rigenera il CSS e pubblica il sito
```

**L'ordine conta.** `db:push` va prima di `deploy`: l'interfaccia nuova chiama
funzioni (`crea_partita`, `elimina_mio_account`) che senza il `db:push` nel
database non esistono ancora. Al contrario, se pubblichi solo il database e non
il sito, non si rompe niente: l'app vecchia continua a funzionare.

**Se `npm test` non arriva a 110, fermati** senza lanciare `db:push`: vuol dire
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
`grant` delle migrazioni n.6 / n.7: basta aggiungerla li'.

## Cosa contiene l'aggiornamento n.7 — sicurezza

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

## Cosa contiene l'aggiornamento n.8 — account, partite, avatar

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
3. **Limiti sugli avatar**: massimo 2 MB, solo immagini, e ognuno puo' scrivere
   soltanto i propri file (prima qualunque utente registrato poteva riempire il
   bucket).

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

## Cosa resta aperto

- **Privacy — da chiudere prima di aprire al pubblico.** In `public/privacy.html`
  restano quattro dati da compilare: nome o ragione sociale del titolare del
  trattamento, indirizzo o P.IVA, email di contatto per le richieste privacy, e i
  giorni entro cui evadi le richieste gestite a mano. Il resto della pagina e'
  aggiornato, compresa la descrizione di cosa fa esattamente la cancellazione
  dell'account.
- **Font di Google sul percorso critico** (vedi sopra): si possono servire in
  locale, ma la degradazione attuale e' accettabile.
