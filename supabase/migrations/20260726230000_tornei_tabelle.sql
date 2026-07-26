-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.14
-- Le tabelle del torneo: tornei, gironi, squadre, incontri
--
-- Sono indipendenti dalle partite normali: nessun collegamento a
-- matches, match_players o match_results, e nessun effetto su
-- statistiche e classifica generale. Il torneo e' un mondo a parte,
-- gestito dal circolo.
--
-- L'unico pezzo condiviso con il resto del progetto e'
-- valida_punteggio() (aggiornamento n.12), che decide chi ha vinto
-- guardando un punteggio. Un punto di contatto solo, scelto.
-- =========================================================


-- =========================================================
-- PARTE 1 — I TORNEI
-- =========================================================

create table if not exists public.tornei (
  id                     uuid primary key default gen_random_uuid(),
  circolo_id             uuid not null references public.circoli(id) on delete cascade,

  nome                   text not null,
  descrizione            text,
  livello                text not null default 'open'
                           check (livello in ('principiante', 'intermedio', 'avanzato', 'open')),
  data_inizio            date,
  data_fine              date,

  stato                  text not null default 'bozza'
                           check (stato in ('bozza', 'iscrizioni', 'in_corso', 'concluso', 'annullato')),
  formato                text not null default 'gironi_e_finali'
                           check (formato in ('solo_gironi', 'gironi_e_finali')),
  qualificate_per_girone int not null default 2 check (qualificate_per_girone between 1 and 4),
  finale_terzo_posto     boolean not null default false,

  creato_da              uuid references public.profiles(id) on delete set null,
  created_at             timestamptz not null default now()
);

create index if not exists idx_tornei_circolo on public.tornei (circolo_id, stato);

alter table public.tornei enable row level security;


-- ---------------------------------------------------------
-- 1.1  LE DUE DOMANDE DEL TORNEO
-- Tutte le policy che seguono si appoggiano a queste, cosi' la
-- regola sta scritta in un posto solo.
-- ---------------------------------------------------------

-- Un torneo in bozza lo vede solo chi lo sta preparando. Tutto il
-- resto e' pubblico, anche senza accesso: un tabellone serve a
-- essere letto, e per un circolo e' il motivo per cui sta sull'app.
create or replace function public.torneo_visibile(p_torneo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tornei t
    where t.id = p_torneo_id
      and (t.stato <> 'bozza' or public.e_gestore_del_circolo(t.circolo_id))
  );
$$;

-- Un torneo concluso o annullato non si tocca piu', nemmeno dal
-- circolo che l'ha organizzato: e' un fatto accaduto. Se proprio
-- serve rimetterci mano, c'e' l'amministratore.
create or replace function public.puo_gestire_torneo(p_torneo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tornei t
    where t.id = p_torneo_id
      and public.e_gestore_del_circolo(t.circolo_id)
      and (t.stato not in ('concluso', 'annullato') or public.e_amministratore())
  );
$$;

grant execute on function public.torneo_visibile(uuid) to authenticated, anon;
grant execute on function public.puo_gestire_torneo(uuid) to authenticated, anon;

-- Le funzioni su cui queste si appoggiano devono essere eseguibili
-- anche da chi non ha effettuato l'accesso: una policy che le
-- interroga viene valutata anche per il ruolo "anon", e senza il
-- permesso la lettura pubblica fallirebbe invece di rispondere "no".
grant execute on function public.e_amministratore() to anon;
grant execute on function public.e_gestore_del_circolo(uuid) to anon;


-- ---------------------------------------------------------
-- 1.2  PERMESSI SUI TORNEI
-- ---------------------------------------------------------
create policy "I tornei pubblicati sono visibili a tutti"
  on public.tornei for select
  using ( stato <> 'bozza' or public.e_gestore_del_circolo(circolo_id) );

create policy "Il circolo crea i propri tornei"
  on public.tornei for insert
  to authenticated
  with check ( public.e_gestore_del_circolo(circolo_id) and creato_da = auth.uid() );

create policy "Il circolo modifica i propri tornei"
  on public.tornei for update
  to authenticated
  using ( public.puo_gestire_torneo(id) )
  with check ( public.e_gestore_del_circolo(circolo_id) );

create policy "Il circolo elimina i propri tornei"
  on public.tornei for delete
  to authenticated
  using ( public.puo_gestire_torneo(id) );


-- =========================================================
-- PARTE 2 — I GIRONI
-- =========================================================

create table if not exists public.tornei_gironi (
  id        uuid primary key default gen_random_uuid(),
  torneo_id uuid not null references public.tornei(id) on delete cascade,
  nome      text not null,
  ordine    int not null default 0,
  unique (torneo_id, nome)
);

alter table public.tornei_gironi enable row level security;

create policy "I gironi seguono la visibilita del torneo"
  on public.tornei_gironi for select
  using ( public.torneo_visibile(torneo_id) );

create policy "Il circolo gestisce i gironi del proprio torneo"
  on public.tornei_gironi for all
  to authenticated
  using ( public.puo_gestire_torneo(torneo_id) )
  with check ( public.puo_gestire_torneo(torneo_id) );


-- =========================================================
-- PARTE 3 — LE SQUADRE
--
-- I nomi dei giocatori sono TESTO. Il collegamento a un account
-- dell'app e' facoltativo, e serve a una cosa sola: far comparire il
-- torneo fra quelli di chi ci gioca. E' cio' che rende la modalita'
-- usabile davvero — un circolo deve poter iscrivere le sedici coppie
-- che ha sul foglio stasera, senza chiedere a trentadue persone di
-- registrarsi.
--
-- NOTA su una scelta cambiata rispetto al documento di progetto:
-- li' i giocatori stavano in una tabella a parte, per rendere
-- dichiarativo il vincolo "una persona in una coppia sola". Qui sono
-- due colonne, con un trigger a fare quel controllo. Il motivo: una
-- coppia di padel e' esattamente due persone, sempre. La tabella a
-- parte avrebbe permesso squadre da uno o da tre — stati che il
-- gioco non ammette — e ogni lettura avrebbe richiesto di
-- ricomporre la coppia.
-- =========================================================

create table if not exists public.torneo_squadre (
  id          uuid primary key default gen_random_uuid(),
  torneo_id   uuid not null references public.tornei(id) on delete cascade,

  nome        text,
  giocatore_1 text not null,
  giocatore_2 text not null,
  user_id_1   uuid references public.profiles(id) on delete set null,
  user_id_2   uuid references public.profiles(id) on delete set null,

  girone_id   uuid references public.tornei_gironi(id) on delete set null,
  stato       text not null default 'iscritta' check (stato in ('iscritta', 'ritirata')),
  created_at  timestamptz not null default now(),

  check (length(trim(giocatore_1)) > 0 and length(trim(giocatore_2)) > 0),
  -- Una persona non gioca con se stessa
  check (user_id_1 is null or user_id_2 is null or user_id_1 <> user_id_2)
);

create index if not exists idx_torneo_squadre_torneo on public.torneo_squadre (torneo_id);
create index if not exists idx_torneo_squadre_girone on public.torneo_squadre (girone_id);

alter table public.torneo_squadre enable row level security;

create policy "Le squadre seguono la visibilita del torneo"
  on public.torneo_squadre for select
  using ( public.torneo_visibile(torneo_id) );

create policy "Il circolo gestisce le squadre del proprio torneo"
  on public.torneo_squadre for all
  to authenticated
  using ( public.puo_gestire_torneo(torneo_id) )
  with check ( public.puo_gestire_torneo(torneo_id) );


-- ---------------------------------------------------------
-- 3.1  COERENZA DELLE SQUADRE
-- Due controlli che l'interfaccia non puo' garantire:
--   - il girone assegnato dev'essere un girone DI QUESTO torneo;
--   - un account collegato compare in una coppia sola per torneo.
-- Il secondo vale solo per i giocatori collegati: due omonimi
-- scritti a mano restano due righe di testo, e il database non ha
-- modo di sapere se sono la stessa persona.
-- ---------------------------------------------------------
create or replace function public.controlla_squadra_torneo()
returns trigger
language plpgsql
as $$
begin
  if new.girone_id is not null then
    if not exists (
      select 1 from public.tornei_gironi g
      where g.id = new.girone_id and g.torneo_id = new.torneo_id
    ) then
      raise exception 'Il girone appartiene a un altro torneo';
    end if;
  end if;

  if exists (
    select 1 from public.torneo_squadre s
    where s.torneo_id = new.torneo_id
      and s.id is distinct from new.id
      and (
        (new.user_id_1 is not null and new.user_id_1 in (s.user_id_1, s.user_id_2))
        or
        (new.user_id_2 is not null and new.user_id_2 in (s.user_id_1, s.user_id_2))
      )
  ) then
    raise exception 'Questo giocatore e'' gia'' iscritto al torneo in un''altra coppia';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_controlla_squadra on public.torneo_squadre;

create trigger trg_controlla_squadra
  before insert or update on public.torneo_squadre
  for each row
  execute function public.controlla_squadra_torneo();


-- =========================================================
-- PARTE 4 — GLI INCONTRI
--
-- Data e ora sono facoltative di proposito: un torneo di paese si
-- gioca a scorrimento, quando si libera il campo. Cio' che conta e'
-- l'ORDINE — "turno" e "ordine" — non l'orario.
-- =========================================================

create table if not exists public.torneo_incontri (
  id             uuid primary key default gen_random_uuid(),
  torneo_id      uuid not null references public.tornei(id) on delete cascade,
  girone_id      uuid references public.tornei_gironi(id) on delete cascade,

  fase           text not null default 'girone'
                   check (fase in ('girone', 'ottavi', 'quarti', 'semifinale', 'finale', 'finale_3_4')),
  turno          int not null default 1,
  ordine         int not null default 0,

  squadra_casa   uuid references public.torneo_squadre(id) on delete cascade,
  squadra_ospite uuid references public.torneo_squadre(id) on delete cascade,

  data           date,
  ora            time,
  campo          text,

  -- Il risultato vive qui, non in match_results.
  sets           jsonb,
  vincitore      char(1) check (vincitore in ('C', 'O')),   -- Casa | Ospite
  registrato_da  uuid references public.profiles(id) on delete set null,
  registrato_il  timestamptz,

  -- O c'e' tutto, o non c'e' niente: un incontro con il punteggio ma
  -- senza vincitore, o viceversa, non deve poter esistere.
  check ((sets is null and vincitore is null) or (sets is not null and vincitore is not null)),
  check (squadra_casa is null or squadra_ospite is null or squadra_casa <> squadra_ospite)
);

create index if not exists idx_torneo_incontri_torneo on public.torneo_incontri (torneo_id, fase, turno, ordine);
create index if not exists idx_torneo_incontri_girone on public.torneo_incontri (girone_id);

alter table public.torneo_incontri enable row level security;

create policy "Gli incontri seguono la visibilita del torneo"
  on public.torneo_incontri for select
  using ( public.torneo_visibile(torneo_id) );

-- Il circolo puo' creare, spostare ed eliminare incontri. Il
-- RISULTATO pero' non si scrive da qui: passa dalla funzione
-- controllata dell'aggiornamento n.15, che calcola il vincitore dal
-- punteggio invece di accettarlo dall'app.
create policy "Il circolo gestisce gli incontri del proprio torneo"
  on public.torneo_incontri for all
  to authenticated
  using ( public.puo_gestire_torneo(torneo_id) )
  with check ( public.puo_gestire_torneo(torneo_id) );


-- ---------------------------------------------------------
-- 4.1  IL VINCITORE NON SI DICHIARA
-- Chi scrive il punteggio non deve poter scrivere anche chi ha
-- vinto: e' la stessa regola delle partite normali. Se l'app prova
-- a impostarli a mano, il trigger li ricalcola dal punteggio.
-- ---------------------------------------------------------
create or replace function public.torneo_ricalcola_vincitore()
returns trigger
language plpgsql
as $$
begin
  if new.sets is null then
    new.vincitore := null;
    new.registrato_il := null;
    return new;
  end if;

  -- 'A' e' la squadra di casa, 'B' quella ospite.
  new.vincitore := case public.valida_punteggio(new.sets) when 'A' then 'C' else 'O' end;

  if new.registrato_il is null then
    new.registrato_il := now();
  end if;

  return new;
end;
$$;

drop trigger if exists trg_torneo_vincitore on public.torneo_incontri;

create trigger trg_torneo_vincitore
  before insert or update on public.torneo_incontri
  for each row
  execute function public.torneo_ricalcola_vincitore();


-- ---------------------------------------------------------
-- 4.2  L'INCONTRO STA NEL SUO TORNEO
-- Girone e squadre devono appartenere allo stesso torneo
-- dell'incontro. Senza questo controllo si potrebbero comporre
-- incontri fra squadre di tornei diversi.
-- ---------------------------------------------------------
create or replace function public.controlla_incontro_torneo()
returns trigger
language plpgsql
as $$
begin
  if new.girone_id is not null and not exists (
    select 1 from public.tornei_gironi g
    where g.id = new.girone_id and g.torneo_id = new.torneo_id
  ) then
    raise exception 'Il girone appartiene a un altro torneo';
  end if;

  if new.squadra_casa is not null and not exists (
    select 1 from public.torneo_squadre s
    where s.id = new.squadra_casa and s.torneo_id = new.torneo_id
  ) then
    raise exception 'La squadra di casa appartiene a un altro torneo';
  end if;

  if new.squadra_ospite is not null and not exists (
    select 1 from public.torneo_squadre s
    where s.id = new.squadra_ospite and s.torneo_id = new.torneo_id
  ) then
    raise exception 'La squadra ospite appartiene a un altro torneo';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_controlla_incontro on public.torneo_incontri;

create trigger trg_controlla_incontro
  before insert or update on public.torneo_incontri
  for each row
  execute function public.controlla_incontro_torneo();
