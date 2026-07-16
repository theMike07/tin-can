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
-- 3) Storage chat-media — twardsze zasady uploadu (anty-abuse).
--    Było: każdy zalogowany mógł wrzucić DOWOLNY plik pod DOWOLNĄ ścieżkę bez
--    limitu (hosting/zapychanie na koszt projektu). Teraz: tylko do WŁASNEGO
--    folderu (name zaczyna się od twojego uid) + limit rozmiaru i typów MIME
--    egzekwowany po stronie serwera (apka i tak wysyła do '$uid/...').
-- ------------------------------------------------------------
drop policy if exists "chat-media upload" on storage.objects;
create policy "chat-media upload" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- opcjonalnie: kasowanie/nadpisywanie tylko własnych plików
drop policy if exists "chat-media update own" on storage.objects;
create policy "chat-media update own" on storage.objects
  for update to authenticated using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists "chat-media delete own" on storage.objects;
create policy "chat-media delete own" on storage.objects
  for delete to authenticated using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- limit 8 MB + tylko obrazki (serwerowo, nie tylko w apce)
update storage.buckets
   set file_size_limit = 8388608,
       allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp']
 where id = 'chat-media';

-- ------------------------------------------------------------
-- 4) (REKOMENDACJA — osobno) chat-media wciąż PUBLIC do ODCZYTU: każdy z
--    linkiem obejrzy obrazek/GIF. Docelowo bucket prywatny + signed URL
--    (z wygasaniem) albo szyfrowanie obrazków (kolejny etap E2E). Świadomie.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- 5) create_group — dodawaj do grupy TYLKO zaakceptowanych znajomych.
--    Było: można było wrzucić do grupy dowolne user_id (spam rysunkami do
--    osoby, która nie jest znajomym). Teraz członek musi być Twoim
--    zaakceptowanym połączeniem. Przetestuj tworzenie grupy po zmianie.
-- ------------------------------------------------------------
create or replace function public.create_group(p_name text, p_member_ids uuid[])
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare me uuid := auth.uid(); gid uuid; mid uuid;
begin
  if me is null then return null; end if;
  insert into public.groups (name, owner_id) values (trim(p_name), me) returning id into gid;
  insert into public.group_members (group_id, user_id) values (gid, me) on conflict do nothing;
  if p_member_ids is not null then
    foreach mid in array p_member_ids loop
      -- tylko zaakceptowany znajomy twórcy
      if exists (
        select 1 from public.connections c
        where c.status = 'accepted'
          and ((c.user_a = me and c.user_b = mid) or (c.user_b = me and c.user_a = mid))
      ) then
        insert into public.group_members (group_id, user_id) values (gid, mid) on conflict do nothing;
      end if;
    end loop;
  end if;
  return gid;
end $function$;

-- ------------------------------------------------------------
-- 6) set_public_key — limit długości (poprawny klucz X25519 b64 to ~44 znaki).
--    Chroni przed wrzuceniem gigantycznego „klucza" bloatującego profil.
-- ------------------------------------------------------------
create or replace function public.set_public_key(p_key text)
 returns void
 language sql
 security definer
 set search_path to 'public'
as $function$
  update public.profiles set public_key = p_key
   where id = auth.uid()
     and (p_key is null or length(p_key) <= 100);
$function$;

-- ------------------------------------------------------------
-- 7) (OPCJONALNIE, kosmetyka) po sekcjach 1–2 masz PODWÓJNE polityki —
--    Twoje istniejące już zamykały dostęp, więc moje z sekcji 1–2 są
--    zbędne (nieszkodliwe). Możesz je usunąć, żeby było czysto:
-- drop policy if exists "dt owner all" on public.device_tokens;              -- zostaw "own device tokens"
-- drop policy if exists "profiles select self+connections" on public.profiles; -- zostaw "read own or connected profile"
-- ------------------------------------------------------------
