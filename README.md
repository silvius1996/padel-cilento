# Padel Cilento

App per organizzare e trovare partite di padel nel Cilento (Paestum, Capaccio, Agropoli).

Online su **https://padelcilento.silvius13-bet.workers.dev**

## Com'e fatto

| | |
|---|---|
| Interfaccia | `public/index.html` — una sola pagina, JavaScript senza framework. Tailwind e la libreria Supabase sono serviti dal nostro dominio, non da CDN esterni |
| Database | Supabase (PostgreSQL) — tabelle, permessi e regole in `supabase/migrations/` |
| Pubblicazione | Cloudflare Workers — viene pubblicata **solo** la cartella `public/` |
| Test | `test/db.test.mjs` — esegue le migrazioni su un PostgreSQL in WebAssembly |

Il principio di fondo: **le regole stanno nel database, non nell'interfaccia.** Chi
puo iscriversi, chi puo registrare un risultato, chi puo vedere un numero di
telefono: tutto e applicato da PostgreSQL tramite policy RLS e funzioni
`security definer`. Modificare il codice della pagina dalla console del browser
non permette di aggirare nulla.

## Comandi

```bash
npm test            # verifica la logica del database (non tocca la produzione)
npm run deploy      # rigenera il CSS e pubblica il sito
npm run build:css   # rigenera public/styles.css (lo fa già il deploy)
npm run db:push     # applica al database le migrazioni mancanti
npm run db:status   # mostra lo stato delle migrazioni
npm run db:verify   # controlla com'e fatto il database di produzione
```

### Il foglio di stile

Le classi Tailwind vengono compilate in `public/styles.css` da `npm run build:css`,
che legge la configurazione (colori, font, ombre) da `tailwind.config.js`. Il
`deploy` lo rigenera da solo, quindi normalmente non serve lanciarlo a mano: serve
solo se vuoi vedere l'effetto di una classe nuova aprendo il file in locale.

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

2. **Accesso a Cloudflare** (si apre il browser)

   ```bash
   npx wrangler login
   ```

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
