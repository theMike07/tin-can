-- ============================================================
--  Tin Can v1.3.0 — hardening dostępu (RLS)
--  Uruchamiaj ŚWIADOMIE, sekcja po sekcji. Po każdej przetestuj apkę
--  (dodawanie znajomego, czat, powiadomienia). Nie widzę Twoich obecnych
--  polityk, więc NAJPIERW diagnostyka (sekcja 0), potem reszta.
-- ============================================================

-- 0) DIAGNOSTYKA — zobacz obecne polityki (uruchom sam SELECT i przeczytaj):
--    Jeśli zobaczysz politykę SELECT typu "dla wszystkich" (qual = true) na
--    profiles/device_tokens, to właśnie ona za bardzo otwiera dane — trzeba ją
--    zdjąć (drop policy "…nazwa…" on public.tabela), zanim zadziałają poniższe.
-- select schemaname, tablename, policyname, cmd, qual, with_check
--   from pg_policies
--  where schemaname = 'public'
--    and tablename in ('profiles','device_tokens','messages','drawings')
--  order by tablename, policyname;

-- ------------------------------------------------------------
-- 1) device_tokens — tokeny push tylko dla właściciela.
--    (Token sam w sobie nie wyśle push bez klucza FCM, ale nie ma powodu, by
--    czyjeś tokeny były widoczne dla innych.) Edge function czyta je rolą
--    service_role, która i tak omija RLS — więc powiadomienia działają dalej.
-- ------------------------------------------------------------
alter table public.device_tokens enable row level security;

-- zdejmij ewentualną zbyt otwartą politykę (dopisz realne nazwy z diagnostyki):
drop policy if exists "device_tokens are viewable by everyone" on public.device_tokens;
drop policy if exists "Enable read access for all users" on public.device_tokens;

drop policy if exists "dt owner all" on public.device_tokens;
create policy "dt owner all" on public.device_tokens
  for all to authenticated
  using (user_id::text = auth.uid()::text)
  with check (user_id::text = auth.uid()::text);

-- ------------------------------------------------------------
-- 2) profiles — czytelne TYLKO: własny + osoby, z którymi masz połączenie
--    (znajomy/zaproszenie). Ukrywa e-maile/awatary reszty użytkowników.
--    Dodawanie po e-mailu działa dalej, bo idzie przez RPC add_connection
--    (security definer — omija RLS).
--    UWAGA: najpierw zdejmij istniejącą politykę SELECT „dla wszystkich"
--    (z diagnostyki), inaczej ta nowa niczego nie ograniczy (polityki są OR).
-- ------------------------------------------------------------
alter table public.profiles enable row level security;

drop policy if exists "Public profiles are viewable by everyone" on public.profiles;
drop policy if exists "profiles are viewable by everyone" on public.profiles;
drop policy if exists "Enable read access for all users" on public.profiles;

drop policy if exists "profiles select self+connections" on public.profiles;
create policy "profiles select self+connections" on public.profiles
  for select to authenticated
  using (
    id::text = auth.uid()::text
    or exists (
      select 1 from public.connections c
      where (c.user_a::text = auth.uid()::text and c.user_b::text = profiles.id::text)
         or (c.user_b::text = auth.uid()::text and c.user_a::text = profiles.id::text)
    )
  );

-- ------------------------------------------------------------
-- 3) (REKOMENDACJA — do zrobienia osobno) chat-media jest bucketem PUBLIC:
--    każdy z linkiem obejrzy obrazek/GIF z DM. Docelowo: bucket prywatny +
--    signed URL (z wygasaniem) albo szyfrowanie obrazków (kolejny etap E2E).
--    Zostawione świadomie — patrz notatki wydania 1.3.0.
-- ------------------------------------------------------------
