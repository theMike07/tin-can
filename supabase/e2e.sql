-- ============================================================
--  Tin Can v1.3.0 — szyfrowanie end-to-end wiadomości DM (tekst)
--  Uruchom RAZ w Supabase → SQL Editor. Idempotentne.
-- ============================================================
--
-- Model: każdy użytkownik ma parę kluczy X25519. Klucz PUBLICZNY leży tu,
-- w profiles.public_key (jawny — to klucz publiczny, bezpieczny do pokazania).
-- Klucz PRYWATNY zostaje wyłącznie na urządzeniu użytkownika. Serwer NIGDY nie
-- widzi treści: messages.enc to szyfrogram (base64), a messages.body jest wtedy
-- puste. Stare wiadomości (body ustawione, enc null) zostają czytelne.

-- 1) Klucz publiczny w profilu (base64 32 bajtów X25519).
alter table public.profiles add column if not exists public_key text;

-- Zapis własnego klucza publicznego (security definer — omija ewentualny brak
-- polityki UPDATE na profiles; user pisze tylko swój wiersz).
create or replace function public.set_public_key(p_key text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles set public_key = p_key where id = auth.uid();
$$;

grant execute on function public.set_public_key(text) to authenticated;

-- 2) Szyfrogram wiadomości. Gdy ustawiony, body jest puste. RLS/GRANT z
--    messages_and_streak.sql już obejmują tę tabelę (nowa kolumna nie wymaga
--    osobnego grantu).
alter table public.messages add column if not exists enc text;
