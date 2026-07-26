# Da lanciare — aggiornamento n.7 (correzioni di sicurezza)

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

## I quattro comandi

```bash
git fetch origin
git checkout claude/project-visibility-aqdi5f

npm test            # deve dire: TUTTO A POSTO — 84 verifiche superate
npm run db:push     # solo ora cambia il database vero
npm run db:status   # controllo finale
```

**Se `npm test` non arriva a 84, fermati** senza lanciare `db:push`: vuol dire
che il database di produzione non corrisponde a quello che descrivono le
migrazioni, e va capito prima perche'.

`npm run deploy` **non serve**: `public/index.html` non e' stato toccato.

## Dopo il db:push, due prove a mano sul sito

I test girano su uno schema ricostruito dalle migrazioni, non sul database
vero. Queste due prove chiudono il cerchio:

1. **Salva il profilo** (nome, telefono, livello, foto) — deve funzionare.
2. **Registra un utente nuovo di prova** — deve entrare come `giocatore`.

Sono i due percorsi toccati dai nuovi permessi per colonna su `profiles`.
Se il salvataggio del profilo desse errore, la causa piu' probabile e' una
colonna aggiunta a mano dall'Editor SQL che non compare nell'elenco dei
`grant` della migrazione n.7: basta aggiungerla li'.

## Cosa contiene l'aggiornamento n.7

Un solo file nuovo, `supabase/migrations/20260726120000_permessi_ruolo_e_contestazione.sql`,
piu' i test che lo coprono. Chiude quattro cose:

1. **Il ruolo "gestore" non si autoassegna.** La policy di UPDATE su
   `profiles` concedeva la scrittura di tutte le colonne, `role` compresa:
   dalla console del browser bastava un `update` per diventare gestore di un
   circolo inventato, e `usa_codice_circolo` diventava decorativa. Ora i
   permessi sono per colonna, con un trigger come secondo lucchetto.

2. **Un risultato confermato non si annulla.** `contesta_risultato` non
   guardava ne' lo stato ne' chi la chiamava: chi perdeva poteva contestare
   una partita gia' confermata e cancellare la sconfitta dalle statistiche.
   Ora si contesta solo un risultato ancora in attesa, non il proprio, ed
   entro le 48 ore.

3. **I posti occupati non si falsificano.** `increment_filled_slots` e
   `decrement_filled_slots` erano eseguibili da chiunque su qualunque
   partita e dall'aggiornamento n.5 non servivano piu' a nessuno. Rimosse.

4. **Niente partite con data nel passato.** Il controllo esisteva solo
   nell'attributo `min` del campo data, quindi era aggirabile dalla console.
   Ora e' un trigger.

## Cosa resta aperto

- **Privacy — da chiudere prima di aprire al pubblico.** `public/privacy.html`
  e' online con i segnaposto vuoti: email di contatto, dati del titolare del
  trattamento, giorni di conservazione. Manca anche la cancellazione
  dell'account dall'app.
- **Minori.** Avatar senza limite di dimensione o tipo file; creazione della
  partita e iscrizione del creatore non atomiche (`index.html:1390`), con un
  rollback a mano che se fallisce lascia una partita a zero giocatori;
  Tailwind da CDN sul percorso critico.
