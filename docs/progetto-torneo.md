# Modalità torneo — progetto

Documento di progetto, non codice. Serve a decidere **cosa** costruire prima di
costruirlo. Leggilo con la matita in mano: le parti che non corrispondono a come
si giocano i tornei dalle tue parti vanno corrette qui, dove costa una riga, non
dopo, dove costa una migrazione.

In fondo c'è l'elenco delle **decisioni ancora aperte**: sono le uniche cose che
bloccano l'inizio dei lavori.

---

## 1. Che cosa deve fare

Un circolo crea un torneo, apre le iscrizioni alle coppie, le distribuisce in
gironi, il calendario degli incontri si genera da solo, i risultati arrivano dai
giocatori come già avviene per le partite normali, la classifica di ogni girone
si aggiorna da sola, e dalle qualificate nasce il tabellone delle finali.

Il problema che risolve è concreto: oggi un torneo di paese vive su un gruppo
WhatsApp e un foglio a quadretti. I gironi sono scritti a penna, i risultati
arrivano a voce, e la classifica la ricalcola qualcuno a mano — che è anche il
motivo per cui si litiga. È esattamente il problema che l'app già risolve per la
singola partita.

**Chi può organizzare: solo un circolo.** Un giocatore non crea tornei. È una
decisione presa, e ha una conseguenza pesante descritta subito qui sotto.

---

## 2. Il prerequisito: il circolo deve esistere come entità

Oggi "circolo" non è una cosa, è **una stringa di testo scritta a mano**, in tre
posti diversi e senza alcun legame fra loro:

| Dove | Cos'è oggi |
|---|---|
| `profiles.circolo` | testo, assegnato da `usa_codice_circolo()` |
| `club_codes.circolo` | testo, scritto a mano quando si crea il codice |
| `matches.club` | testo libero, digitato da chi crea la partita |

Con questo modello un torneo non ha a chi appartenere. Peggio: io posso scrivere
"Padel Village", "padel village" e "Village" e per il database sono tre circoli
diversi. Un torneo non si può appendere a una stringa.

**Prima dei tornei serve quindi la tabella `circoli`**, e la migrazione dei dati
esistenti. Non è lavoro sprecato: è lo stesso pezzo che serve per dare al gestore
poteri sulle partite del proprio circolo — la cosa che avevamo lasciato in
sospeso. Costruire i tornei prima significherebbe pagarlo due volte.

### 2.1 Tabella `circoli`

```
circoli
  id            uuid, chiave primaria
  nome          text, non nullo
  zona          text  (paestum | capaccio | agropoli | altro)
  indirizzo     text, facoltativo
  telefono      text, facoltativo
  attivo        boolean, default vero
  created_at    timestamptz
```

Chi la scrive: **solo l'amministratore**. Un circolo è un dato anagrafico, non
qualcosa che si crea da soli — altrimenti torniamo alle tre stringhe diverse.

### 2.2 Cosa cambia nelle tabelle esistenti

- `profiles.circolo_id` → riferimento a `circoli`, sostituisce il testo.
- `club_codes.circolo_id` → idem: il codice abilita a **quel** circolo.
- `matches.circolo_id` → riferimento facoltativo. Resta anche `club` come testo
  per le partite su campi non in elenco ("il campo dietro casa di Mario"): è
  utile e non va perso.

La migrazione dei dati esistenti si fa in tre passi, dentro un'unica migrazione:
si creano i circoli a partire dai valori di testo già presenti, si collegano le
righe, e solo dopo si smette di usare le vecchie colonne. Le colonne di testo si
tengono ancora per un po', vuote ma presenti: se qualcosa non torna, si guarda
il dato vecchio invece di ricostruirlo.

---

## 3. Il nodo del modello: le squadre non esistono

È il punto più importante del documento.

Tutto il modello attuale è costruito sul **singolo giocatore che sceglie un posto
in campo**: `match_players` con `spot` da 0 a 3, e la squadra è *dedotta* dal
posto (0-1 = Squadra A, 2-3 = Squadra B). La coppia esiste solo dentro quella
partita e sparisce quando finisce.

Un torneo funziona al contrario: la coppia **Tizio + Caio** è un'entità che vive
per tutto il torneo, sta in un girone, accumula punti, va alle finali.

### La scelta di fondo

**Un incontro di torneo resta una partita normale.** La riga in `matches` c'è, i
quattro `match_players` ci sono, il punteggio si registra e si conferma come
sempre. L'unica differenza è che i quattro posti vengono riempiti in un colpo
solo dalle due coppie, invece che uno alla volta da chi si iscrive.

Il guadagno è tutto ciò che non va riscritto: registrazione del punteggio,
calcolo del vincitore, conferma dell'avversario, contestazione, correzione,
congelamento della formazione, contatti dei giocatori, statistiche personali.

**L'errore da evitare** è costruire un secondo sistema di partite parallelo per i
tornei. È la trappola classica: sembra più semplice all'inizio, e sei mesi dopo
hai due posti in cui correggere ogni bug e statistiche che non tornano fra loro.

Mappatura fissa, da scrivere una volta e non discutere più:

```
squadra di casa    → posti 0 e 1 → Squadra A → winner_team = 'A'
squadra ospite     → posti 2 e 3 → Squadra B → winner_team = 'B'
```

---

## 4. Le tabelle nuove

### 4.1 `tornei`

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
  max_squadre            int
  qualificate_per_girone int         (di norma 2)
  creato_da              → profiles
  created_at             timestamptz
```

Lo **stato** non è decorativo, è ciò che decide cosa si può fare:

| Stato | Cosa è permesso |
|---|---|
| `bozza` | solo l'organizzatore lo vede; si modifica tutto |
| `iscrizioni` | visibile a tutti, le coppie si iscrivono, i gironi non sono fissati |
| `in_corso` | gironi e calendario fissati, si registrano i risultati, non si iscrive più nessuno |
| `concluso` | sola lettura, resta consultabile per sempre |
| `annullato` | sola lettura, marcato come annullato |

Il passaggio da uno stato al successivo è una funzione controllata dal database,
non un campo che l'app aggiorna: da `iscrizioni` a `in_corso` si passa solo se
ogni squadra ha un girone e il calendario è stato generato.

### 4.2 `torneo_squadre` e i suoi giocatori

```
torneo_squadre
  id           uuid
  torneo_id    → tornei
  nome         text, facoltativo   (se assente: "Rossi / Bianchi")
  girone_id    → tornei_gironi, nullo finché non è assegnata
  iscritta_il  timestamptz
  stato        text  (in_attesa | confermata | ritirata)
```

```
torneo_squadra_giocatori
  squadra_id   → torneo_squadre
  torneo_id    → tornei          (ripetuto di proposito, vedi sotto)
  user_id      → profiles
  chiave primaria (squadra_id, user_id)
  indice unico (torneo_id, user_id)
```

`torneo_id` è ripetuto qui dentro anche se si potrebbe ricavare dalla squadra.
Non è una svista: serve a quell'indice unico, che è ciò che impedisce **al
database** — non all'interfaccia — che una persona giochi in due coppie dello
stesso torneo. È lo stesso principio del posto unico in campo: una regola che
conta va applicata dove non si può aggirare.

Una tabella a parte invece di due colonne `giocatore_1` e `giocatore_2` costa una
riga di SQL in più nelle letture, ma rende quel vincolo dichiarativo. Con due
colonne servirebbe un trigger, cioè più codice e più modi di sbagliare.

### 4.3 `tornei_gironi`

```
tornei_gironi
  id          uuid
  torneo_id   → tornei
  nome        text     ('A', 'B', 'C'...)
  ordine      int
```

### 4.4 `torneo_incontri`

È la tabella che tiene insieme il torneo e le partite vere.

```
torneo_incontri
  id             uuid
  torneo_id      → tornei
  girone_id      → tornei_gironi, nullo per le fasi finali
  fase           text   (girone | ottavi | quarti | semifinale | finale | finale_3_4)
  turno          int    (giornata del girone, o turno del tabellone)
  squadra_casa   → torneo_squadre, può essere nullo nelle finali non ancora definite
  squadra_ospite → torneo_squadre, idem
  match_id       → matches, nullo finché l'incontro non è programmato
  ordine         int
```

`match_id` nullo significa "incontro previsto ma non ancora messo a calendario":
serve per il tabellone, dove la semifinale esiste come casella prima di sapere
chi la giocherà.

Quando l'organizzatore programma un incontro (data, ora, campo), una funzione
crea la riga in `matches` e i quattro `match_players` ai posti giusti, in
un'unica transazione — come già fa `crea_partita()` per le partite normali.

---

## 5. I risultati: chi valida, e quando

Oggi un risultato diventa valido se lo conferma un avversario, oppure dopo 48 ore
di silenzio. **In un torneo le 48 ore non esistono**: la semifinale è tra un'ora e
bisogna sapere chi passa.

Proposta:

- le coppie inseriscono il punteggio come sempre, e la conferma dell'avversario
  continua a funzionare — è la strada normale, e quando funziona nessuno deve
  fare niente;
- **l'organizzatore del torneo può validare subito** un risultato, senza
  aspettare, e può correggerlo finché il torneo è `in_corso`;
- la convalida automatica dopo 48 ore **resta**, ma serve solo ai tornei che si
  giocano su più giorni.

Attenzione a un punto delicato: questo potere va concesso **solo** sugli incontri
che appartengono a un torneo di quel circolo. Il rischio, altrimenti, è
riaprire proprio il buco chiuso nell'aggiornamento n.9, dove chiunque poteva
manomettere i risultati altrui. La funzione dovrà verificare che la partita sia
legata a un `torneo_incontri` del torneo che quella persona organizza.

---

## 6. La classifica dei gironi

È la parte dove nascono le discussioni, quindi è la parte che deve essere
**scritta, pubblica e calcolata dal database** — mai a mano.

Come per le statistiche personali, la classifica del girone è **ricalcolata dai
risultati a ogni lettura**, non un contatore salvato. Il progetto ha già pagato
due volte l'errore opposto.

### Punteggio

Proposta: **3 punti a vittoria, 0 a sconfitta.**

Va detta una cosa che di solito sfugge: in una partita di padel il pareggio non
esiste, quindi ordinare per punti e ordinare per vittorie è **la stessa cosa**. I
punti sono solo un modo tradizionale di scriverlo. Ne segue che a decidere le
posizioni sono quasi sempre i criteri di parità, non i punti — ed è per questo
che vanno definiti bene.

### Criteri di parità, in ordine

1. **Punti** (cioè vittorie).
2. **Scontro diretto**, se le squadre a pari punti sono esattamente due.
3. **Differenza set** (set vinti meno set persi).
4. **Differenza game** (game vinti meno game persi).
5. **Game fatti.**
6. **Decisione dell'organizzatore** (sorteggio), registrata e visibile.

Il caso che rompe quasi tutte le classifiche fatte in casa: **se le squadre a
pari punti sono tre o più, lo scontro diretto singolo non ha senso**. In quel
caso si costruisce una mini-classifica fra le sole squadre coinvolte, contando
solo le partite giocate fra loro, e si applicano gli stessi criteri dal punto 3
in poi. Va implementato così fin dall'inizio: aggiungerlo dopo significa
cambiare le classifiche già pubblicate, cioè dare torto a qualcuno a cose fatte.

L'ultimo criterio è una decisione umana, e deve **restare scritta**: chi ha
deciso, quando, e con quale motivazione. Una classifica che cambia senza traccia
è peggio di una classifica sbagliata.

---

## 7. Le fasi finali

Dalle qualificate di ogni girone nasce il tabellone. Accoppiamento classico, che
evita di far incontrare subito le prime dello stesso girone:

```
1ª girone A  ×  2ª girone B
1ª girone B  ×  2ª girone A
```

Con più gironi lo schema si estende allo stesso modo. Le regole:

- il tabellone si genera **solo a gironi conclusi**, cioè quando ogni incontro di
  girone ha un risultato valido;
- se il numero di qualificate non è una potenza di due (6 squadre, per dire), le
  meglio piazzate saltano il primo turno. È la parte più noiosa da scrivere: per
  la prima versione si può accettare **solo 2, 4 o 8 qualificate** e rimandare i
  turni di riposo;
- il vincitore di un incontro passa al turno successivo **da solo**, appena il
  risultato è valido: il tabellone si aggiorna senza che l'organizzatore faccia
  niente;
- finale per il terzo posto: facoltativa, scelta alla creazione del torneo.

---

## 8. Permessi

Coerente con il resto del progetto: **le regole stanno nel database.** Nascondere
un pulsante non è una protezione.

| Chi | Cosa può fare |
|---|---|
| Chiunque, anche senza accesso | vedere i tornei pubblicati, gironi, calendario, classifiche, tabellone |
| Giocatore registrato | iscriversi in coppia, vedere i nomi, inserire e confermare i risultati dei propri incontri |
| Gestore del circolo | creare e gestire i tornei **del proprio circolo**: gironi, calendario, validazione dei risultati |
| Amministratore | tutto, su qualunque torneo |

Il gestore non deve poter toccare i tornei di un altro circolo: la verifica è
`torneo.circolo_id = profilo.circolo_id`, applicata dalle policy.

I nomi dei giocatori restano riservati a chi ha effettuato l'accesso, come già
avviene per le partite. I **numeri di telefono** non si vedono nemmeno nel
torneo, tranne fra chi condivide un incontro: vale la funzione `contatti_partita`
che già esiste. Il gestore vede i contatti delle coppie iscritte al proprio
torneo — serve per organizzare — ed è bene che la privacy policy lo dica.

---

## 9. Le schermate

**Per il circolo**

1. *Crea torneo* — nome, date, livello, formato, numero di gironi, squadre
   massime, finale per il terzo posto sì/no.
2. *Iscrizioni* — elenco delle coppie iscritte, con la possibilità di
   aggiungerne a mano (ci sarà sempre qualcuno che si iscrive per telefono).
3. *Assegna i gironi* — le squadre da distribuire, con un pulsante
   "distribuisci a caso" per chi non vuole ragionarci.
4. *Genera il calendario* — tutti contro tutti dentro ogni girone, poi data e ora
   per ciascun incontro.
5. *Gestione in corso* — risultati da validare, classifiche, genera le finali.

**Per il giocatore**

1. *Tornei* — elenco: in corso, iscrizioni aperte, conclusi.
2. *Dettaglio torneo* — gironi, calendario, classifiche, tabellone.
3. *Iscrizione* — scegli il compagno fra i giocatori registrati.
4. *I miei incontri* — dentro il torneo, con il pulsante per il punteggio.

---

## 10. Le fasi di lavoro

Ognuna è utile da sola: se ci si ferma dopo una qualsiasi, quello che c'è
funziona.

| | Cosa | Perché
|---|---|---|
| **0** | Circoli come entità + migrazione dei dati | Prerequisito. Sblocca anche i poteri del gestore sulle partite |
| **1** | Torneo, squadre, gironi, calendario, classifica dei gironi | È il cuore. Da qui un torneo si può già giocare per intero |
| **2** | Fasi finali e tabellone | Completa il torneo |
| **3** | Rifiniture: inviti al compagno, notifiche, condivisione | Rende piacevole ciò che già funziona |

Ordine di grandezza, per essere onesti: la **fase 1 da sola è più grande di tutto
il lavoro fatto finora** in questa conversazione. Non è una sessione, sono
diverse. La fase 0 è la più breve ma tocca dati esistenti, quindi è quella dove
conviene andare piano.

---

## 11. Decisioni ancora aperte

Sono le uniche cose che bloccano l'inizio. Rispondere qui, poi si costruisce.

1. **Gli incontri di torneo contano nelle statistiche personali e nella
   classifica generale?**
   Sono partite vere, quindi l'istinto dice di sì. Ma un torneo di otto coppie
   genera una ventina di partite in un pomeriggio: chi partecipa scavalca in
   classifica chi gioca il sabato tutto l'anno. Le tre strade: contano tutte;
   non contano; contano ma la classifica generale ha un interruttore per
   escluderle. Nota tecnica: le statistiche sono **calcolate**, non salvate,
   quindi questa scelta si può cambiare anche dopo senza perdere dati.

2. **Come si iscrive una coppia?** Uno dei due sceglie il compagno e la coppia è
   fatta, oppure il compagno deve accettare l'invito? La seconda è più corretta —
   nessuno ti iscrive a tua insaputa — ma è una funzionalità in più, con inviti
   da mostrare e scadenze da gestire.

3. **Un giocatore può stare in due tornei diversi contemporaneamente?**
   Direi di sì, senza vincoli. Da confermare.

4. **Il calendario ha orari veri o solo l'ordine degli incontri?** Un torneo di
   paese spesso si gioca "a scorrimento": si gioca quando si libera il campo. Se
   è così, l'orario dev'essere facoltativo, e il calendario è un elenco ordinato
   più che una griglia oraria. Questa la sai tu meglio di me.

5. **Le squadre hanno un nome?** Facoltativo, con "Rossi / Bianchi" come
   ripiego, oppure sempre i cognomi dei due giocatori?

6. **Che formati servono davvero?** Qui è previsto gironi ed eliminazione
   diretta. Nei tornei di padel si giocano spesso anche gli *americani* — dove le
   coppie cambiano a ogni turno e la classifica è individuale. È un modello di
   dati **diverso**, non una variante: se serve, va progettato a parte.
