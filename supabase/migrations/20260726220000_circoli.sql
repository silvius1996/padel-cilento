-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.13
-- Il circolo diventa un'entita', non piu' una stringa
--
-- PERCHE' ADESSO
-- I tornei appartengono a un circolo e li gestisce un circolo.
-- Finche' "circolo" e' testo scritto a mano, "Padel Village",
-- "padel village" e "Village" sono tre circoli diversi, e non c'e'
-- modo di verificare che QUESTO gestore possa toccare QUEL torneo.
--
-- C'e' una seconda ragione, non tecnica: al circolo l'accesso viene
-- venduto. Un cliente ha un ciclo di vita — attivo, scaduto — e
-- quella distinzione va messa ora. Aggiungerla dopo significa
-- rimettere le mani in ogni controllo dei permessi.
--
-- COSA NON VIENE TOCCATO
-- La tabella "matches". Nel primo progetto della modalita' torneo
-- gli incontri sarebbero stati partite normali, e serviva anche
-- matches.circolo_id. Ora i tornei sono separati, quindi le partite
-- restano esattamente come sono. Il campo di una partita continua a
-- essere testo libero, ed e' giusto: si gioca anche su campi che non
-- sono circoli in elenco.
-- =========================================================


-- =========================================================
-- PARTE 1 — LA TABELLA
-- =========================================================

create table if not exists public.circoli (
  id                   uuid primary key default gen_random_uuid(),
  nome                 text not null,
  zona                 text not null default 'altro'
                         check (zona in ('paestum', 'capaccio', 'agropoli', 'altro')),
  indirizzo            text,
  telefono             text,

  -- L'interruttore commerciale. "attivo" e' la decisione manuale
  -- (sospeso, chiuso), la data e' la scadenza dell'abbonamento.
  -- Nulla = nessuna scadenza.
  attivo               boolean not null default true,
  abbonamento_scade_il date,

  created_at           timestamptz not null default now()
);

-- Il punto di tutta questa migrazione: due circoli non possono
-- chiamarsi allo stesso modo, e "Padel Village" e "padel village"
-- sono lo stesso nome. Senza questo indice si torna al problema di
-- prima, solo con una tabella in mezzo.
create unique index if not exists idx_circoli_nome
  on public.circoli (lower(trim(nome)));

alter table public.circoli enable row level security;

-- I circoli sono pubblici: servono a chi cerca un campo, e i
-- tabelloni dei tornei li deve poter leggere chiunque.
create policy "I circoli sono visibili a tutti"
  on public.circoli for select
  using ( true );

-- Li crea e li modifica solo l'amministratore. Un circolo e' un dato
-- anagrafico e un cliente: se ognuno potesse crearsene uno, si
-- tornerebbe alle stringhe diverse per la stessa cosa.
create policy "Solo l amministratore crea un circolo"
  on public.circoli for insert
  to authenticated
  with check ( public.e_amministratore() );

create policy "Solo l amministratore modifica un circolo"
  on public.circoli for update
  to authenticated
  using ( public.e_amministratore() )
  with check ( public.e_amministratore() );

create policy "Solo l amministratore elimina un circolo"
  on public.circoli for delete
  to authenticated
  using ( public.e_amministratore() );


-- =========================================================
-- PARTE 2 — I COLLEGAMENTI
-- =========================================================

alter table public.profiles
  add column if not exists circolo_id uuid references public.circoli(id) on delete set null;

alter table public.club_codes
  add column if not exists circolo_id uuid references public.circoli(id) on delete cascade;

-- La colonna va aggiunta all'elenco dei permessi di lettura, che
-- dall'aggiornamento n.6 e' concesso colonna per colonna: senza
-- questa riga l'app non riuscirebbe a leggerla.
grant select (circolo_id) on public.profiles to authenticated;

-- In scrittura NON viene concessa: come "role" e "circolo", la
-- imposta solo usa_codice_circolo().


-- =========================================================
-- PARTE 3 — I DATI CHE CI SONO GIA'
-- Si creano i circoli a partire dai nomi gia' scritti nelle due
-- tabelle, poi si collegano le righe. Le colonne di testo restano
-- dove sono: se qualcosa non tornasse, il dato vecchio e' ancora li'
-- da guardare invece che da ricostruire.
-- =========================================================

insert into public.circoli (nome)
select distinct trim(nome_trovato)
from (
  select circolo as nome_trovato from public.profiles where circolo is not null
  union
  select circolo from public.club_codes where circolo is not null
) as nomi
where trim(nome_trovato) <> ''
on conflict do nothing;

update public.profiles p
set circolo_id = c.id
from public.circoli c
where p.circolo is not null
  and lower(trim(p.circolo)) = lower(trim(c.nome))
  and p.circolo_id is null;

update public.club_codes k
set circolo_id = c.id
from public.circoli c
where k.circolo is not null
  and lower(trim(k.circolo)) = lower(trim(c.nome))
  and k.circolo_id is null;


-- =========================================================
-- PARTE 4 — LE DUE DOMANDE CHE SERVIRANNO OVUNQUE
-- =========================================================

-- ---------------------------------------------------------
-- 4.1  "QUESTO CIRCOLO PUO' USARE L'APP?"
-- Un circolo sospeso o con l'abbonamento scaduto resta visibile, e
-- restano visibili i suoi tornei — sono fatti accaduti, non si
-- cancellano perche' non ha rinnovato. Semplicemente non puo' piu'
-- creare o modificare niente.
-- ---------------------------------------------------------
create or replace function public.circolo_utilizzabile(p_circolo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.circoli
    where id = p_circolo_id
      and attivo
      and (abbonamento_scade_il is null
           or abbonamento_scade_il >= (now() at time zone 'Europe/Rome')::date)
  );
$$;

grant execute on function public.circolo_utilizzabile(uuid) to authenticated, anon;


-- ---------------------------------------------------------
-- 4.2  "SONO IL GESTORE DI QUESTO CIRCOLO?"
-- E' la domanda su cui si appoggeranno tutti i permessi dei tornei.
-- L'amministratore risponde sempre di si': deve poter intervenire
-- ovunque, anche sul torneo di un cliente che ha smesso di pagare.
-- ---------------------------------------------------------
create or replace function public.e_gestore_del_circolo(p_circolo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.e_amministratore()
      or exists (
        select 1 from public.profiles
        where id = auth.uid()
          and role = 'gestore'
          and circolo_id = p_circolo_id
          and public.circolo_utilizzabile(p_circolo_id)
      );
$$;

grant execute on function public.e_gestore_del_circolo(uuid) to authenticated;


-- =========================================================
-- PARTE 5 — IL RUOLO SI ATTIVA SUL CIRCOLO GIUSTO
--
-- usa_codice_circolo() resta com'e' stata scritta nell'aggiornamento
-- n.8, protezione dai tentativi ripetuti compresa: cambia solo che
-- ora assegna anche circolo_id, e che rifiuta i codici di un circolo
-- non piu' attivo — un cliente che non rinnova non deve poter
-- continuare ad abilitare nuovi gestori.
-- =========================================================

drop function if exists public.usa_codice_circolo(text);

create function public.usa_codice_circolo(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  MAX_TENTATIVI  constant int      := 5;
  DURATA_BLOCCO  constant interval := interval '15 minutes';
  FINESTRA       constant interval := interval '15 minutes';

  riga    public.club_codes;
  circolo public.circoli;
  stato   public.tentativi_codice_circolo;
  errore  text;
  minuti  int;
begin
  if auth.uid() is null then
    raise exception 'Devi essere autenticato';
  end if;

  select * into stato
  from public.tentativi_codice_circolo
  where user_id = auth.uid();

  -- Blocco in corso: si esce subito, senza nemmeno guardare il codice.
  -- Il tentativo non viene conteggiato, cosi' insistere non allunga
  -- il blocco all'infinito.
  if stato.bloccato_fino is not null and stato.bloccato_fino > now() then
    minuti := ceil(extract(epoch from (stato.bloccato_fino - now())) / 60);
    return jsonb_build_object(
      'ok', false,
      'errore', format('Troppi tentativi non riusciti. Riprova tra %s minuti.', minuti)
    );
  end if;

  select * into riga
  from public.club_codes
  where upper(trim(code)) = upper(trim(p_code));

  if riga.code is not null and riga.circolo_id is not null then
    select * into circolo from public.circoli where id = riga.circolo_id;
  end if;

  if riga.code is null then
    errore := 'Codice circolo non valido.';
  elsif not riga.attivo then
    errore := 'Codice circolo non piu'' attivo.';
  elsif riga.uso_singolo and riga.usato_da is not null then
    errore := 'Codice circolo gia'' utilizzato.';
  elsif circolo.id is not null and not public.circolo_utilizzabile(circolo.id) then
    errore := 'L''abbonamento di questo circolo non e'' attivo. Contatta l''assistenza.';
  end if;

  -- ----- Tentativo fallito -----
  if errore is not null then
    insert into public.tentativi_codice_circolo (user_id, tentativi_falliti, ultimo_tentativo)
    values (auth.uid(), 1, now())
    on conflict (user_id) do update
      set tentativi_falliti = case
            when tentativi_codice_circolo.ultimo_tentativo < now() - FINESTRA then 1
            else tentativi_codice_circolo.tentativi_falliti + 1
          end,
          ultimo_tentativo = now()
    returning * into stato;

    if stato.tentativi_falliti >= MAX_TENTATIVI then
      update public.tentativi_codice_circolo
      set bloccato_fino = now() + DURATA_BLOCCO,
          tentativi_falliti = 0
      where user_id = auth.uid();

      errore := format(
        'Troppi tentativi non riusciti. Riprova tra %s minuti.',
        (extract(epoch from DURATA_BLOCCO) / 60)::int
      );
    end if;

    return jsonb_build_object('ok', false, 'errore', errore);
  end if;

  -- ----- Codice valido -----
  update public.profiles
  set role = 'gestore',
      circolo = riga.circolo,
      circolo_id = riga.circolo_id
  where id = auth.uid();

  update public.club_codes
  set usato_da = auth.uid(),
      usato_il = now()
  where code = riga.code;

  delete from public.tentativi_codice_circolo where user_id = auth.uid();

  return jsonb_build_object('ok', true, 'circolo', riga.circolo);
end;
$$;

grant execute on function public.usa_codice_circolo(text) to authenticated;


-- =========================================================
-- PARTE 6 — IL SECONDO LUCCHETTO COPRE ANCHE LA COLONNA NUOVA
-- Il trigger dell'aggiornamento n.9 impedisce di scrivere "role" e
-- "circolo" dal browser. Senza questa aggiunta, "circolo_id"
-- resterebbe scoperto: i permessi per colonna bastano, ma il
-- trigger e' il lucchetto che regge se un giorno qualcuno riconcede
-- la scrittura sull'intera tabella.
-- =========================================================

create or replace function public.blocca_cambio_ruolo()
returns trigger
language plpgsql
as $$
begin
  -- Solo le richieste dirette dal browser vengono esaminate.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.role is distinct from 'giocatore'
       or new.circolo is not null
       or new.circolo_id is not null then
      raise exception 'Il ruolo di gestore si ottiene solo con un codice circolo valido';
    end if;
  else
    if new.role is distinct from old.role
       or new.circolo is distinct from old.circolo
       or new.circolo_id is distinct from old.circolo_id then
      raise exception 'Il ruolo di gestore si ottiene solo con un codice circolo valido';
    end if;
  end if;

  return new;
end;
$$;


-- =========================================================
-- PARTE 7 — LA CANCELLAZIONE DELL'ACCOUNT AZZERA ANCHE IL LEGAME
-- elimina_mio_account() (aggiornamento n.10) azzera "circolo", che
-- allora era l'unico dato del legame. Ora ce n'e' un secondo: senza
-- questa riga, il profilo di un gestore cancellato resterebbe
-- collegato al circolo, e "e_gestore_del_circolo" continuerebbe a
-- rispondere di si' per un account che non esiste piu'.
-- =========================================================

create or replace function public.elimina_mio_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  io uuid := auth.uid();
begin
  if io is null then
    raise exception 'Devi essere autenticato';
  end if;

  -- 1. Fuori dalle partite non ancora giocate: il posto torna libero.
  delete from public.match_players mp
  using public.matches m
  where mp.match_id = m.id
    and mp.user_id = io
    and (m.match_date + m.match_time) at time zone 'Europe/Rome' > now();

  -- 2. Le partite future che aveva organizzato e che sono rimaste
  --    senza nessuno in campo non servono a nessuno.
  delete from public.matches m
  where m.created_by = io
    and (m.match_date + m.match_time) at time zone 'Europe/Rome' > now()
    and not exists (
      select 1 from public.match_players mp where mp.match_id = m.id
    );

  -- 3. I dati personali e ogni potere collegato al ruolo.
  update public.profiles
  set nome = 'Giocatore',
      cognome = 'eliminato',
      full_name = 'Giocatore eliminato',
      telefono = null,
      avatar_url = null,
      circolo = null,
      circolo_id = null,
      role = 'giocatore',
      eliminato_il = now()
  where id = io;

  -- 4. L'accesso.
  delete from auth.users where id = io;
end;
$$;

grant execute on function public.elimina_mio_account() to authenticated;


-- =========================================================
-- COME SI APRE UN CIRCOLO CLIENTE
-- Tre righe dall'Editor SQL: si crea il circolo, si crea il codice
-- che lo abilita, si consegna il codice al circolo.
-- =========================================================
-- insert into public.circoli (nome, zona, abbonamento_scade_il)
-- values ('Padel Club Paestum', 'paestum', '2027-07-31');
--
-- insert into public.club_codes (code, circolo, circolo_id, uso_singolo)
-- select 'PAESTUM-2027', c.nome, c.id, false
-- from public.circoli c where c.nome = 'Padel Club Paestum';
--
-- Per sospendere un cliente che non ha rinnovato (i tornei restano
-- visibili, non puo' piu' crearne):
-- update public.circoli set attivo = false where nome = 'Padel Club Paestum';
