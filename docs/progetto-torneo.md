# Modalità torneo — progetto

Documento di progetto, non codice. Serve a decidere **cosa** costruire prima di
costruirlo.

In fondo c'è l'elenco delle **decisioni ancora aperte**: sono le uniche cose che
bloccano l'inizio dei lavori.

---

## 1. Le tre decisioni prese

Sono la base di tutto il resto, e insieme cambiano il progetto molto più di
quanto sembri leggendole una per una.

1. **Il torneo è una gestione separata**, non collegata alle partite normali.
2. **Non entra nella classifica** né nelle statistiche personali.
3. **Lo gestisce il circolo**: creazione, gironi, squadre e **risultati**.

### Cosa comportano, messe insieme

La terza è la più pesante, e vale la pena dirla per esteso: **il punteggio lo
inserisce il circolo, non i giocatori.** Da qui discende che nel torneo non
esistono la conferma dell'avversario, la contestazione, le 48 ore di convalida
automatica. Non servono: l'organizzatore è l'autorità, e se sbaglia corregge.

È una semplificazione enorme rispetto alle partite normali, dove tutta quella
impalcatura esiste perché **non c'è nessuna autorità**: quattro persone alla
pari devono mettersi d'accordo su chi ha vinto, e il database fa da arbitro. Nel
torneo l'arbitro c'è, ed è il circolo.

### Perché il documento precedente diceva il contrario

La prima stesura sconsigliava un sistema separato e proponeva di riusare le
partite normali. Quell'argomento era: "così non riscriviamo registrazione,
conferma, contestazione, correzione, statistiche".

Con le decisioni 2 e 3 quell'elenco si svuota. Non c'è conferma da riusare, non
c'è contestazione, non ci sono statistiche da alimentare. Restava così poco da
condividere che forzare gli incontri di torneo dentro `matches` avrebbe portato
più danni che vantaggi: partite che compaiono nel feed e a cui nessuno può
iscriversi, filtri da aggiungere in ogni schermata, il conteggio dei posti
liberi che non significa più niente.

**Una parte dell'obiezione però resta valida**, ed è nel capitolo 6: chi decide
il vincitore guardando un punteggio deve restare uno solo.

---

## 2. Il prerequisito, ora più piccolo: i circoli

Perché un torneo appartenga a un circolo, il circolo deve essere una cosa. Oggi
non lo è: è una **stringa di testo** in due posti scollegati.

| Dove | Cos'è oggi |
|---|---|
| `profiles.circolo` | testo, assegnato da `usa_codice_circolo()` |
| `club_codes.circolo` | testo, scritto a mano quando si crea il codice |

Finché è testo, "Padel Village", "padel village" e "Village" sono tre circoli
diversi, e non c'è modo di verificare che *questo* gestore possa toccare
*quel* torneo.

Serve quindi la tabella `circoli`:

```
circoli
  id          uuid, chiave primaria
  nome        text, non nullo
  zona        text  (paestum | capaccio | agropoli | altro)
  indirizzo   text, facoltativo
  telefono    text, facoltativo
  attivo      boolean, default vero
  created_at  timestamptz
```

La scrive **solo l'amministratore**: un circolo è un dato anagrafico, non
qualcosa che ci si crea da soli, altrimenti si torna alle stringhe diverse.

**Il circolo è anche un cliente**, e un cliente ha un ciclo di vita. Due campi lo
governano: `attivo` (la decisione manuale: sospeso, chiuso) e
`abbonamento_scade_il` (nullo = nessuna scadenza). Un circolo non in regola
**resta visibile insieme ai suoi tornei** — sono fatti accaduti, non si
cancellano perché non ha rinnovato — ma non può più creare o modificare niente,
né abilitare nuovi gestori con un codice. L'amministratore continua a poter
intervenire ovunque.

Sono due colonne e un controllo, ed è il motivo per cui vanno messe subito:
aggiungerle dopo significa rimettere le mani in ogni permesso.

Poi due collegamenti:

- `profiles.circolo_id` → di quale circolo sono gestore
- `club_codes.circolo_id` → a quale circolo abilita questo codice

**Buona notizia: `matches` non va toccata.** Nella prima stesura serviva anche
`matches.circolo_id`, perché gli incontri di torneo sarebbero stati partite. Ora
che i tornei sono separati, le partite normali restano esattamente come sono, e
il prerequisito si riduce a una tabella nuova e due colonne. È la prima cosa che
la tua decisione ci fa risparmiare.

Le colonne di testo si tengono ancora per un po', accanto alle nuove: se
qualcosa non torna si guarda il dato vecchio invece di ricostruirlo.

---

## 3. Il modello dati

Quattro tabelle nuove, indipendenti da tutto il resto.

### 3.1 `tornei`

```
tornei
  id                     uuid
  circolo_id             → circoli, non nullo
  nome                   text        ("Torneo d'estate 2026")
  descrizione            text, facoltativo
  livello                text        (principiante | intermedio | avanzato | open)
  data_inizio            date
  data_fine              date
  stato                  text        (bozza | iscrizioni | in_corso | concluso | annullato)
  formato                text        (solo_gironi | gironi_e_finali)
  qualificate_per_girone int         (di norma 2)
  finale_terzo_posto     boolean
  creato_da              → profiles
  created_at             timestamptz
```

Lo **stato** non è decorativo: decide cosa si può fare.

| Stato | Cosa è permesso |
|---|---|
| `bozza` | lo vede solo il circolo; si modifica tutto |
| `iscrizioni` | pubblico, si aggiungono squadre, i gironi non sono fissati |
| `in_corso` | gironi e calendario fissati, si inseriscono i risultati |
| `concluso` | sola lettura, resta consultabile per sempre |
| `annullato` | sola lettura, marcato come annullato |

Il passaggio da uno stato all'altro è una funzione controllata dal database, non
un campo che l'app aggiorna: da `iscrizioni` a `in_corso` si passa **solo** se
ogni squadra ha un girone e il calendario è stato generato. Altrimenti si finisce
con tornei "in corso" senza calendario, e nessuno capisce più cosa sta
succedendo.

### 3.2 `torneo_squadre`

```
torneo_squadre
  id              uuid
  torneo_id       → tornei
  nome            text, facoltativo    (se assente: "Rossi / Bianchi")
  giocatore_1     text, non nullo      nome e cognome, scritti dal circolo
  giocatore_2     text, non nullo
  user_id_1       → profiles, facoltativo
  user_id_2       → profiles, facoltativo
  girone_id       → tornei_gironi, nullo finché non è assegnata
  stato           text  (iscritta | ritirata)
  created_at      timestamptz
```

**I nomi sono testo, il collegamento all'account è facoltativo.** È la scelta che
rende il torneo utilizzabile davvero: un circolo deve poter iscrivere le sedici
coppie che ha sul foglio, stasera, senza chiedere a trentadue persone di
scaricare un'app e registrarsi. Se il giocatore è anche un utente
dell'applicazione lo si collega, e in cambio vedrà il torneo fra i suoi; se non
lo è, il torneo funziona lo stesso.

Il collegamento serve a una cosa sola: mostrare il torneo nell'app di chi ci
gioca. Non alimenta statistiche né classifica — decisione 2.

### 3.3 `tornei_gironi`

```
tornei_gironi
  id          uuid
  torneo_id   → tornei
  nome        text     ('A', 'B', 'C'...)
  ordine      int
```

### 3.4 `torneo_incontri`

Qui vive il risultato: nel torneo, non in `match_results`.

```
torneo_incontri
  id             uuid
  torneo_id      → tornei
  girone_id      → tornei_gironi, nullo nelle fasi finali
  fase           text   (girone | ottavi | quarti | semifinale | finale | finale_3_4)
  turno          int    (giornata del girone, o turno del tabellone)
  ordine         int
  squadra_casa   → torneo_squadre, nullo finché il tabellone non è definito
  squadra_ospite → torneo_squadre, nullo idem
  data           date, facoltativa
  ora            time, facoltativa
  campo          text, facoltativo

  sets           jsonb, nullo finché non si gioca    [[6,4],[3,6],[7,5]]
  vincitore      char(1), nullo                      'C' casa | 'O' ospite
  registrato_da  → profiles
  registrato_il  timestamptz
```

`squadra_casa` e `squadra_ospite` possono essere nulli perché nel tabellone la
semifinale esiste come casella prima di sapere chi la giocherà.

**Il vincitore è una colonna calcolata dal database, non un dato che l'app
dichiara** — stessa regola delle partite normali, e per lo stesso motivo: chi
scrive il punteggio non deve poter scrivere anche chi ha vinto.

---

## 4. Chi fa cosa

| Chi | Cosa può fare |
|---|---|
| Chiunque, anche senza accesso | vedere i tornei pubblicati: gironi, calendario, classifiche, tabellone |
| Giocatore registrato | vedere i tornei in cui è iscritto, se il circolo lo ha collegato |
| Gestore del circolo | **tutto** sui tornei del **proprio** circolo: crearli, iscrivere squadre, fare i gironi, generare il calendario, inserire e correggere i risultati |
| Amministratore | tutto, su qualunque torneo |

La verifica che conta è una sola: `torneo.circolo_id` deve coincidere con il
circolo del gestore. Applicata dalle policy del database, come tutto il resto —
nascondere un pulsante non è una protezione.

I nomi dei giocatori nei tornei sono **pubblici**: un tabellone serve a essere
letto, anche da chi non ha l'app. È diverso dalle partite normali, dove i nomi
richiedono l'accesso, e va scritto nella pagina della privacy. Nessun numero di
telefono compare da nessuna parte.

---

## 5. La classifica dei gironi

È la parte dove nascono le discussioni, quindi è la parte che deve essere
**scritta, pubblica e calcolata dal database**.

Come le statistiche personali, si ricalcola dai risultati a ogni lettura: non è
un contatore salvato. Il progetto ha già pagato due volte l'errore opposto.

### Punteggio

**3 punti a vittoria, 0 a sconfitta.**

Una cosa che di solito sfugge: nel padel il pareggio non esiste, quindi ordinare
per punti e ordinare per vittorie **è la stessa cosa**. I punti sono solo un modo
tradizionale di scriverlo. Ne segue che a decidere le posizioni sono quasi sempre
i criteri di parità — ed è per questo che vanno definiti bene.

### Criteri di parità, in ordine

1. **Punti** (cioè vittorie)
2. **Scontro diretto**, se le squadre a pari punti sono esattamente due
3. **Differenza set** (set vinti meno set persi)
4. **Differenza game**
5. **Game fatti**
6. **Decisione del circolo** (sorteggio), registrata e visibile

Il caso che rompe quasi tutte le classifiche fatte in casa: **con tre o più
squadre a pari punti lo scontro diretto singolo non ha senso.** Si costruisce
allora una mini-classifica fra le sole squadre coinvolte, contando solo le
partite giocate fra loro, e si applicano gli stessi criteri dal punto 3 in poi.

Va fatto così dall'inizio: aggiungerlo dopo significa cambiare classifiche già
pubblicate, cioè dare torto a qualcuno a cose fatte.

L'ultimo criterio è una decisione umana e deve **restare scritta**: chi ha
deciso, quando, con quale motivazione. Una classifica che cambia senza lasciare
traccia è peggio di una classifica sbagliata.

---

## 6. L'unica cosa che NON va duplicata

Da un punteggio come `[[6,4],[3,6],[7,5]]` bisogna ricavare chi ha vinto, e
rifiutare i punteggi impossibili: meno di due set, un set finito in parità, un
punteggio che non indica un vincitore.

Quella logica **esiste già** nel progetto, e conta una quarantina di righe. Sta
in `registra_risultato` ed è stata copiata in `correggi_risultato`: due copie,
già oggi.

Scriverne una terza per i tornei significa avere tre posti che possono dare
risposte diverse sullo stesso punteggio. Prima o poi succede.

**Quindi: prima di scrivere i tornei, si estrae quella logica in una funzione
sola** — `valida_punteggio(sets)` che restituisce il vincitore o rifiuta — e la
usano tutti e tre. È mezz'ora di lavoro, ripaga il debito che c'è già, ed è
l'unico punto di contatto fra tornei e partite normali. Un punto di contatto solo
e ben scelto, non un sistema condiviso.

---

## 7. Le fasi finali

Dalle qualificate di ogni girone nasce il tabellone. Accoppiamento classico, che
evita di far incontrare subito le prime dello stesso girone:

```
1ª girone A  ×  2ª girone B
1ª girone B  ×  2ª girone A
```

Le regole:

- il tabellone si genera **solo a gironi conclusi**, cioè quando ogni incontro di
  girone ha un risultato;
- il vincitore passa al turno successivo **da solo**, appena il risultato è
  inserito: il tabellone si aggiorna senza che il circolo faccia altro;
- se le qualificate non sono una potenza di due (6 squadre, per dire), le meglio
  piazzate saltano il primo turno. È la parte più noiosa: per la prima versione
  si accettano **solo 2, 4 o 8 qualificate** e i turni di riposo si rimandano;
- finale per il terzo posto: facoltativa, scelta alla creazione.

---

## 8. Le schermate

**Per il circolo**

1. *Crea torneo* — nome, date, livello, formato, numero di gironi, finale 3°/4°
2. *Squadre* — aggiungi coppia (due nomi, più il collegamento all'account se la
   persona usa l'app), elenco, ritiro
3. *Gironi* — distribuisci le squadre, con un pulsante "distribuisci a caso"
4. *Calendario* — genera tutti contro tutti dentro ogni girone; data, ora e campo
   sono facoltativi
5. *Risultati* — l'elenco degli incontri, si inserisce il punteggio e la
   classifica si aggiorna da sola
6. *Fasi finali* — genera il tabellone quando i gironi sono chiusi

**Per tutti**

1. *Tornei* — in corso, iscrizioni aperte, conclusi
2. *Dettaglio torneo* — gironi, calendario, classifiche, tabellone

---

## 9. Le fasi di lavoro

Ognuna è utile da sola: se ci si ferma dopo una qualsiasi, quello che c'è
funziona.

| | Cosa | Perché |
|---|---|---|
| ~~**0**~~ | ~~`valida_punteggio` estratta e condivisa~~ | **fatta** — aggiornamento n.12 |
| ~~**1**~~ | ~~Tabella `circoli` + collegamenti a profili e codici~~ | **fatta** — aggiornamento n.13 |
| ~~**2**~~ | ~~Tornei, squadre, gironi, calendario, risultati, classifica~~ | **fatta** — aggiornamenti n.14 e n.15 |
| ~~**2-bis**~~ | ~~Interfaccia: elenco, dettaglio, gestione, classifica pubblica~~ | **fatta** |
| **2** | Tornei, squadre, gironi, calendario, risultati, classifica | È il cuore: da qui un torneo si gioca per intero |
| ~~**3**~~ | ~~Fasi finali e tabellone~~ | **fatta** — aggiornamento n.16 |
| **4** | Rifiniture: collegamento ai giocatori, condivisione, stampa | Rende piacevole ciò che già funziona |

La fase 2 resta la più grande del progetto, ma è **più piccola di quanto sarebbe
stata** nella prima stesura: niente conferme, niente contestazioni, niente
intreccio con le statistiche.

---

## 10. Decisioni ancora aperte

1. ~~Il calendario ha orari veri o solo l'ordine?~~ **Deciso: basta l'ordine.**
   Data e ora restano facoltative, il calendario è fatto di turni.

2. **Un giocatore può stare in due tornei contemporaneamente?** Direi di sì,
   senza vincoli. Da confermare. (Dentro **lo stesso** torneo invece no: una
   persona in una coppia sola, e lo impedisce il database.)

3. **Le squadre hanno un nome proprio?** Facoltativo, con "Rossi / Bianchi" come
   ripiego automatico. Da confermare.

4. ~~Serve il formato "americano"?~~ **Deciso: no, le coppie sono fisse.**

5. **Un torneo può essere cancellato dopo essere iniziato?** Qui è previsto lo
   stato `annullato` che lo congela in sola lettura, senza cancellare niente.
   Alternativa: eliminarlo del tutto. Direi di no — un torneo giocato è un fatto,
   anche se finito male.
