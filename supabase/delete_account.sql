-- ============================================================
--  Tin Can — USUWANIE KONTA (wymóg Google Play i App Store)
--  Uruchom RAZ w Supabase → SQL Editor.
--  RPC kasuje dane użytkownika i samo konto auth. Nieodwracalne.
--  Odporne na różnice schematu (id jako uuid lub text, brak tabeli):
--  każde kasowanie danych aplikacji jest best-effort; na końcu twardo
--  kasujemy wiersz w auth.users (to odcina logowanie).
-- ============================================================

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  ut  text := auth.uid()::text;
begin
  if uid is null then
    raise exception 'not_authenticated';
  end if;

  -- rysunki (sender/recipient trzymane jako text)
  begin
    delete from public.drawings where sender = ut or recipient = ut;
  exception when others then null; end;

  -- tokeny push
  begin delete from public.device_tokens where user_id = uid; exception when others then null; end;
  begin delete from public.device_tokens where user_id = ut;  exception when others then null; end;

  -- członkostwo w grupach
  begin delete from public.group_members where user_id = uid; exception when others then null; end;
  begin delete from public.group_members where user_id = ut;  exception when others then null; end;

  -- połączenia (znajomi/zaproszenia)
  begin delete from public.connections where user_a = uid or user_b = uid; exception when others then null; end;
  begin delete from public.connections where user_a = ut  or user_b = ut;  exception when others then null; end;

  -- profil
  begin delete from public.profiles where id = uid; exception when others then null; end;

  -- na końcu: samo konto (loginy). Bez łapania wyjątku — jeśli się nie
  -- powiedzie, cała transakcja się cofa i apka pokaże błąd (nie wyloguje).
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
