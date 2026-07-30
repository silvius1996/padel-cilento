# Padel Cilento

App per organizzare e trovare partite di padel nel Cilento (Paestum, Capaccio, Agropoli).

Online su **https://padel-cilento.vercel.app**

## Com'e fatto

| | |
|---|---|
| Interfaccia | `public/index.html` — una sola pagina, JavaScript senza framework. Tailwind e la libreria Supabase sono serviti dal nostro dominio, non da CDN esterni |
| Database | Supabase (PostgreSQL) — tabelle, permessi e regole in `supabase/migrations/` |
| Pubblicazione | Vercel — viene pubblicata **solo** la cartella `public/` |
| Test | `test/db.test.mjs` — esegue le migrazioni su un PostgreSQL in WebAssembly |

Il principio di fondo: **le regole stanno nel database, non nell'interfaccia.** Chi
puo iscriversi, chi puo registrare un risultato, chi puo vedere un numero di
telefono: tutto e applicato da PostgreSQL tramite policy RLS e funzioni
`security definer`. Modificare il codice della pagina dalla console del browser
non permette di aggirare nulla.

## Pubblicare

**Non serve fare niente a mano.** Quando il lavoro arriva nel ramo principale,
GitHub esegue da solo, in quest'ordine: i test, l'aggiornamento del database, la
pubblicazione del sito. Se i test falliscono si ferma li' e non pubblica nulla.

L'automazione e in `.github/workflows/pubblica.yml`. Si puo anche far ripartire
a mano dalla scheda **Actions** del progetto su GitHub, senza modificare niente.

Perche l'ordine conta: il database va aggiornato **prima** del sito, altrimenti
per qualche minuto la pagina nuova cerca funzioni che nel database non esistono
ancora. I tre passi sono legati fra loro, quindi quell'ordine e garantito.

Servono quattro segreti, impostati una volta sola in
*Settings -> Secrets and variables -> Actions*:

| Segreto | Cos'e |
|---|---|
| `SUPABASE_DB_URL` | la stringa di connessione al database, la stessa che sta in `.env` |
| `VERCEL_TOKEN` | una chiave creata su [vercel.com/account/tokens](https://vercel.com/account/tokens) |
| `VERCEL_ORG_ID` | identificativo dell'account Vercel |
| `VERCEL_PROJECT_ID` | identificativo del progetto Vercel |

Gli ultimi due si leggono dal file `.vercel/project.json`, che compare sul
computer dopo aver lanciato una volta `npx vercel link` (il file resta locale:
e nell'elenco di quelli ignorati da git).

### Perche il deploy lo fa GitHub e non Vercel

Vercel e collegato al repository e, di suo, pubblicherebbe a ogni push. Ma
pubblicherebbe **subito**, senza aspettare le migrazioni: per qualche minuto il
sito nuovo cercherebbe funzioni che nel database non esistono ancora. E
esattamente il problema che l'ordine dei tre passi evita.

Per questo in `vercel.json` la pubblicazione automatica sul ramo `master` e
disattivata:

```json
"git": { "deploymentEnabled": { "master": false } }
```

L'unica strada che porta in produzione e quindi il workflow, che pubblica solo
dopo che test e migrazioni sono andati a buon fine. Gli altri rami restano
liberi: se ne apri uno, Vercel genera come sempre la sua anteprima.

## Comandi

Servono solo per lavorare in locale: la pubblicazione e automatica.

```bash
npm test            # verifica la logica del database (non tocca la produzione)
npm run spot        # registra i due video di presentazione in video/
npm run dati:demo   # riempie il database con un torneo dimostrativo
npm run build:css   # rigenera public/styles.css
npm run db:status   # mostra lo stato delle migrazioni
npm run db:verify   # controlla com'e fatto il database di produzione

npm run deploy      # pubblica a mano (di norma non serve: lo fa GitHub)
npm run db:push     # applica le migrazioni a mano (idem)
```

### Presentazioni e dati dimostrativi

`npm run spot` registra i due video di presentazione — uno per i giocatori, uno
per i circoli — e li salva in `video/` come MP4.

Dentro il telefono che si vede nei video **gira l'app vera**: `public/index.html`
dentro un iframe, con le sue schermate, i suoi modali e le sue animazioni. Non e
una copia disegnata per l'occasione. Per farla funzionare senza collegarsi al
database, le sue chiamate vengono intercettate e a ognuna si risponde con dati
di esempio: l'app non se ne accorge ed esegue il suo codice di sempre.

Intorno al telefono ci sono solo la macchina da presa e le didascalie
(`public/presentazione/spot.html`); il copione — che schermata aprire, quando
muovere la camera, che testo mostrare — sta in `scripts/spot.mjs` ed e la
prima cosa da toccare per cambiare ritmo o parole.

`npm run dati:demo` crea un circolo e un torneo completi — gironi, calendario,
risultati, tabellone, medaglie — per poter riprendere l'app piena invece che
vuota. Scrive sul database vero, marca tutto con un nome riconoscibile, e
`npm run dati:demo pulisci` lo rimuove senza toccare altro. Non crea utenti
finti: le coppie di un torneo sono nomi scritti a mano, ed e proprio il motivo
per cui la modalita torneo funziona senza obbligare nessuno a registrarsi.

### Il foglio di stile

Le classi Tailwind vengono compilate in `public/styles.css` da `npm run build:css`,
che legge la configurazione (colori, font, ombre) da `tailwind.config.js`. Il
`deploy` lo rigenera da solo — e' il `buildCommand` scritto in `vercel.json` —
quindi normalmente non serve lanciarlo a mano: serve solo se vuoi vedere
l'effetto di una classe nuova aprendo il file in locale.

Prima Tailwind arrivava dal CDN e compilava gli stili nel browser a ogni apertura:
comodo, ma se il CDN era lento o bloccato la pagina si apriva come testo nudo,
illeggibile. Stesso discorso per la libreria Supabase, che ora sta in
`public/vendor/`: senza quella l'app si apriva ma non riusciva a leggere nemmeno
l'elenco delle partite.

## Prima configurazione

Serve una volta sola, su un computer nuovo.

1. **Dipendenze**

   ```bash
   npm install
   ```

2. **Accesso a Vercel** (si apre il browser, poi collega la cartella al
   progetto gia esistente)

   ```bash
   npx vercel login
   npx vercel link
   ```

   `link` crea `.vercel/project.json`, da cui si leggono `VERCEL_ORG_ID` e
   `VERCEL_PROJECT_ID`. Serve solo per lavorare o pubblicare a mano: se ti
   limiti a fare `push`, questo passo si puo saltare.

3. **Accesso al database**: copia `.env.example` in `.env` e incolla la stringa di
   connessione (pannello Supabase, pulsante **Connect**).

   Usa la versione **Session pooler**, non la connessione diretta:

   ```
   postgresql://postgres.<ref>:<password>@aws-1-eu-west-2.pooler.supabase.com:5432/postgres
   ```

   Il motivo: `db.<ref>.supabase.co` ha solo un indirizzo IPv6, e la maggior
   parte delle reti domestiche italiane non ha IPv6. Il risultato e un errore
   generico "failed to connect" che sembra una password sbagliata ma non lo e.
   Il pooler risponde in IPv4 e funziona sempre.

   Questo progetto e ospitato nella regione **eu-west-2** (Londra), quindi
   l'indirizzo del pooler e quello scritto sopra. Nota che l'utente diventa
   `postgres.<ref>` e non semplicemente `postgres`.

   Il file `.env` contiene una password: resta sul tuo computer e non viene
   pubblicato (online va solo `public/`).

4. **Allineamento del registro migrazioni** — solo la prima volta:

   ```bash
   npm run db:baseline
   ```

   Le prime migrazioni sono state applicate a mano dall'editor SQL, quando questa
   automazione non esisteva. Questo comando le segna come gia applicate senza
   rieseguirle: se venissero rilanciate darebbero errore, perche contengono
   istruzioni non ripetibili (`create policy`, `add constraint`).

## Come si aggiunge una modifica al database

1. Crea un file in `supabase/migrations/` con un nome che inizia per data e ora,
   in modo che l'ordine sia esplicito: `20260801093000_descrizione_breve.sql`
2. `npm test` — le migrazioni vengono applicate a un database usa e getta e la
   logica viene verificata
3. `npm run db:push` — applica la modifica al database vero
4. `npm run deploy` — se hai cambiato anche l'interfaccia

**L'ordine conta.** Se l'interfaccia usa una tabella o una funzione nuova, il
passo 3 va fatto prima del passo 4, altrimenti per qualche minuto l'app cerca
qualcosa che nel database non esiste ancora.

## Come funziona una partita

Un campo da padel ha 4 posti: **0 e 1 sono la Squadra A**, **2 e 3 la Squadra B**.
Chi si iscrive scegle il proprio posto toccandolo sul campo disegnato, quindi le
coppie sono reali — ed e questo che rende possibile registrare un risultato
sensato.

A partita conclusa, chi ha giocato inserisce il punteggio. Il vincitore lo calcola
il database dal punteggio, non lo dichiara l'app. Il risultato conta per le
statistiche solo se **confermato da un avversario**, oppure se nessuno lo contesta
entro 48 ore. Un risultato contestato non entra nelle statistiche di nessuno.

Le statistiche e la classifica non sono contatori salvati sul profilo: vengono
**ricalcolate dai risultati** a ogni lettura. Un contatore separato dai fatti prima
o poi divergerebbe dai fatti, ed e un errore che in questo progetto era gia
capitato due volte con il conteggio dei posti occupati.

## I tornei

Un mondo separato dalle partite: li organizza un **circolo**, i risultati li
inserisce il circolo, e non entrano nella classifica generale ne nelle
statistiche personali.

- I nomi dei giocatori sono **testo**: il circolo iscrive le coppie che ha sul
  foglio, senza che i giocatori debbano registrarsi. Il collegamento a un
  account e facoltativo.
- Il calendario dei gironi si genera da solo, a **girone all'italiana**: in ogni
  turno una squadra gioca al massimo una volta.
- La **classifica** e ricalcolata dai risultati a ogni lettura. A pari punti
  decidono, in ordine: la classifica ridotta fra le sole squadre in parita'
  (che con due squadre coincide con lo scontro diretto), poi differenza set,
  differenza game, game fatti. Cosi nel girone all'italiana, dove tutte si
  incontrano.

  Nel girone a **eliminazione** a quattro coppie i criteri sono due soli: punti
  e differenza game (poi i game fatti). Li ogni coppia gioca due incontri su
  tre avversarie possibili, quindi chi finisce a pari punti a volte si e
  affrontato e a volte no: tenere lo scontro diretto vorrebbe dire cambiare
  regola da un girone all'altro. L'esito degli incontri decisivi non ordina la
  classifica, la riempie.
- Lo **stato** del torneo (bozza, iscrizioni, in corso, concluso) non si scrive
  a mano: passa da `torneo_cambia_stato()`, che rifiuta di avviare un torneo
  senza calendario o con squadre non assegnate a un girone.

- Le **fasi finali** si generano a gironi conclusi. Le qualificate vengono messe
  in fila per merito — tutte le prime, poi tutte le seconde — e accoppiate prima
  con ultima: con due gironi questo basta a evitare che due squadre dello stesso
  girone si rincontrino subito. Poi il tabellone va avanti da solo: chi vince
  compare nel turno successivo, chi perde una semifinale nella finale per il
  terzo posto.

- Chi sale sul podio di un torneo si porta una **medaglia sul profilo**, con il
  nome del torneo e il circolo. Vale per chi e collegato a un account: le coppie
  iscritte solo a nome e cognome restano nell'albo del torneo, ma non hanno un
  profilo su cui comparire.

  La medaglia **non e un dato salvato**: si ricava dal tabellone a ogni lettura,
  come le statistiche. Se il circolo corregge il risultato di una finale, la
  bacheca si aggiorna da sola — e un premio appeso al profilo sbagliato non puo
  esistere.

Il circolo e anche un **cliente**: `circoli.attivo` e
`circoli.abbonamento_scade_il` decidono se puo ancora creare. Chi non rinnova
resta visibile con i suoi tornei, ma non crea piu nulla.

## Privacy

- Le **partite** sono pubbliche: orario, circolo, livello e posti liberi si vedono
  senza registrarsi. E cio che invoglia a iscriversi.
- **Nomi e formazioni** richiedono l'accesso.
- Il **numero di telefono** non e leggibile da nessuno, nemmeno dagli altri utenti
  registrati: il permesso e concesso colonna per colonna, escludendo `telefono`.
  L'unica eccezione e tra chi condivide una partita, tramite la funzione
  `contatti_partita`.
- L'**amministratore** (ruolo `admin`) puo' moderare qualunque partita:
  modificarla, eliminarla, togliere un giocatore, annullare un risultato. Si
  nomina solo dall'Editor SQL di Supabase, mai dall'app.
- Il **ruolo di gestore** si ottiene solo con un codice circolo valido: le colonne
  `role` e `circolo` non sono scrivibili dall'app, e un trigger le protegge una
  seconda volta.
- L'**account si cancella dall'app** (Il tuo profilo → Elimina il mio account).
  I dati personali vengono cancellati e le credenziali eliminate, ma le partite
  giocate restano intestate a "Giocatore eliminato": un risultato e un fatto
  condiviso fra quattro persone, e cancellarlo altererebbe le statistiche degli
  altri tre. E un'anonimizzazione, non una rimozione delle righe.
