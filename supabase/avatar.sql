-- ============================================================
--  Tin Can — zdjęcie profilowe (avatar)
--  Uruchom RAZ w Supabase → SQL Editor.
--  Zdjęcie trzymamy jako base64 w kolumnie tekstowej profilu
--  (mały obrazek 256px/JPEG ~20–40 KB — bez osobnego bucketa).
-- ============================================================

-- 1) Kolumna na zdjęcie (base64). Bezpieczne przy ponownym uruchomieniu.
alter table public.profiles
  add column if not exists avatar_url text;

-- 2) RPC do zapisu/kasowania własnego zdjęcia (security definer, bez
--    otwierania ogólnej polityki UPDATE na profiles).
create or replace function public.set_avatar(p_url text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return 'not_authenticated';
  end if;
  -- limit ~600 000 znaków base64 (~450 KB) — chroni bazę przed dużymi wpisami
  if p_url is not null and length(p_url) > 600000 then
    return 'too_large';
  end if;
  update public.profiles
     set avatar_url = p_url
   where id = auth.uid();
  return 'ok';
end;
$$;

grant execute on function public.set_avatar(text) to authenticated;

-- (avatar_url czytany jest przez istniejące polityki SELECT na profiles —
--  te same, którymi apka pobiera nazwy/e-maile znajomych.)
