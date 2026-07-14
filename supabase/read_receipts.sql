-- ============================================================
--  Tin Can — POTWIERDZENIA ODCZYTU (read receipts)
--  Uruchom RAZ w Supabase → SQL Editor.
--  Znacznik read_at na rysunku: kiedy ODBIORCA go zobaczył w apce.
-- ============================================================

-- 1) Kolumna z czasem odczytu (null = nieprzeczytany).
alter table public.drawings
  add column if not exists read_at timestamptz;

-- 2) REPLICA IDENTITY FULL — żeby realtime UPDATE (odczyt) dało się
--    filtrować po nadawcy i poprawnie przeszło przez RLS.
alter table public.drawings replica identity full;

-- 3) RPC: odbiorca oznacza rysunek jako przeczytany (security definer,
--    ustawia tylko read_at i tylko dla własnych odebranych rysunków).
create or replace function public.mark_read(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.drawings
     set read_at = now()
   where id = p_id
     and recipient = auth.uid()
     and read_at is null;
end;
$$;

grant execute on function public.mark_read(uuid) to authenticated;
