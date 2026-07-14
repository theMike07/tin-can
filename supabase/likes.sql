-- ============================================================
--  Tin Can — LAJKI rysunków (serce, jak w komunikatorach)
--  Uruchom RAZ w Supabase → SQL Editor (najlepiej PO read_receipts.sql,
--  bo korzysta z REPLICA IDENTITY FULL ustawionego tam).
--  Lajkuje ODBIORCA — na swoim odebranym rysunku. Nadawca widzi serce.
-- ============================================================

-- 1) Znacznik polubienia (null = niepolubiony).
alter table public.drawings
  add column if not exists liked_at timestamptz;

-- 2) Na wszelki wypadek (gdyby read_receipts.sql nie był uruchomiony):
alter table public.drawings replica identity full;

-- 3) RPC: odbiorca lubi / odlubia własny odebrany rysunek.
create or replace function public.set_like(p_id uuid, p_liked boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.drawings
     set liked_at = case when p_liked then now() else null end
   where id = p_id
     and recipient = auth.uid();
end;
$$;

grant execute on function public.set_like(uuid, boolean) to authenticated;
