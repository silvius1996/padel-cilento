-- =========================================================
-- PADEL CILENTO — AGGIORNAMENTO SQL n.8
-- Protezione contro i tentativi ripetuti sul codice circolo
--
-- PERCHE' SERVE
-- usa_codice_circolo() promuove chi indovina un codice al ruolo
-- "gestore", che puo' pubblicare partite a nome di un circolo.
-- Finora non c'era alcun limite ai tentativi: un utente registrato
-- poteva provare migliaia di codici via API finche' non ne trovava
-- uno valido, tanto piu' che i codici sono leggibili (PAESTUM-2026).
--
-- PERCHE' LA FUNZIONE NON SOLLEVA PIU' ECCEZIONI SUI CODICI ERRATI
-- In PostgreSQL un RAISE EXCEPTION annulla l'intera transazione:
-- annullerebbe anche la scrittura del contatore dei tentativi, che
-- quindi resterebbe sempre a zero e non bloccherebbe mai nessuno.
-- Per questo l'esito viene ora RESTITUITO come jsonb invece che
-- sollevato. L'app continua a comportarsi come prima: la funzione
-- JavaScript usaCodiceCircolo() traduce l'esito negativo in un
-- errore, quindi per chi la chiama non cambia nulla.
-- =========================================================


-- ---------------------------------------------------------
-- 1. REGISTRO DEI TENTATIVI
-- Una riga per utente. Non e' leggibile da nessuno dal browser:
-- ci accede solo la funzione security definer qui sotto.
-- ---------------------------------------------------------
create table if not exists public.tentativi_codice_circolo (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  tentativi_falliti int not null default 0,
  ultimo_tentativo timestamptz not null default now(),
  bloccato_fino timestamptz
);

alter table public.tentativi_codice_circolo enable row level security;

-- Nessuna policy: con RLS attiva e nessuna policy, nessun utente
-- puo' leggere o scrivere questa tabella direttamente.
-- La revoca esplicita e' comunque necessaria, perche' Supabase
-- concede per impostazione predefinita tutti i permessi sulle
-- tabelle dello schema pubblico (stessa lezione dell'aggiornamento n.6).
revoke all on public.tentativi_codice_circolo from anon;
revoke all on public.tentativi_codice_circolo from authenticated;


-- ---------------------------------------------------------
-- 2. LA FUNZIONE, CON IL LIMITE AI TENTATIVI
-- Dopo 5 tentativi falliti l'utente resta bloccato 15 minuti,
-- durante i quali NON funziona nemmeno un codice corretto.
-- Un uso riuscito azzera il contatore.
--
-- Il tipo restituito cambia (da text a jsonb), quindi la vecchia
-- versione va prima eliminata: CREATE OR REPLACE non basta.
-- ---------------------------------------------------------
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

  if riga.code is null then
    errore := 'Codice circolo non valido.';
  elsif not riga.attivo then
    errore := 'Codice circolo non piu'' attivo.';
  elsif riga.uso_singolo and riga.usato_da is not null then
    errore := 'Codice circolo gia'' utilizzato.';
  end if;

  -- ----- Tentativo fallito -----
  if errore is not null then
    insert into public.tentativi_codice_circolo (user_id, tentativi_falliti, ultimo_tentativo)
    values (auth.uid(), 1, now())
    on conflict (user_id) do update
      set tentativi_falliti = case
            -- Tentativi molto vecchi non si sommano ai nuovi:
            -- il contatore riparte da capo.
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
      circolo = riga.circolo
  where id = auth.uid();

  update public.club_codes
  set usato_da = auth.uid(),
      usato_il = now()
  where code = riga.code;

  -- Chi ci riesce riparte pulito.
  delete from public.tentativi_codice_circolo where user_id = auth.uid();

  return jsonb_build_object('ok', true, 'circolo', riga.circolo);
end;
$$;

grant execute on function public.usa_codice_circolo(text) to authenticated;


-- ---------------------------------------------------------
-- 3. VERIFICA (opzionale)
-- Stato dei blocchi in corso, da eseguire solo da qui:
-- ---------------------------------------------------------
-- select user_id, tentativi_falliti, bloccato_fino
-- from public.tentativi_codice_circolo
-- where bloccato_fino > now();
