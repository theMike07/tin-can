-- ============================================================
--  Tin Can v1.2.3 — DMy (czat tekstowy) + streak
--  Uruchom RAZ w Supabase → SQL Editor.
-- ============================================================

-- 1) Wiadomości tekstowe (DM 1:1). (Szyfrowanie E2E dodamy później.)
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  sender text not null,      -- user_id nadawcy
  recipient text not null,   -- user_id odbiorcy
  body text not null
);

alter table public.messages enable row level security;
alter table public.messages replica identity full;

-- select: tylko uczestnik rozmowy
drop policy if exists "msg select" on public.messages;
create policy "msg select" on public.messages
  for select to authenticated
  using (sender = auth.uid()::text or recipient = auth.uid()::text);

-- insert: tylko jako własny nadawca i tylko do zaakceptowanego znajomego
drop policy if exists "msg insert" on public.messages;
create policy "msg insert" on public.messages
  for insert to authenticated
  with check (
    sender = auth.uid()::text
    and exists (
      select 1 from public.connections c
      where c.status = 'accepted'
        and ((c.user_a::text = auth.uid()::text and c.user_b::text = recipient)
          or (c.user_b::text = auth.uid()::text and c.user_a::text = recipient))
    )
  );

-- realtime (idempotentnie — dodaj tylko jeśli jeszcze nie jest w publikacji)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- indeks pod historię rozmowy
create index if not exists messages_pair_idx
  on public.messages (sender, recipient, created_at);

-- 2) Streak: liczba KOLEJNYCH dni z interakcją (rysunek LUB wiadomość) między
--    zalogowanym a peerem. Streak żyje, jeśli ostatni dzień to dziś lub wczoraj.
create or replace function public.get_streak(p_peer uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  me   text := auth.uid()::text;
  peer text := p_peer::text;
  rec  record;
  streak int := 0;
  prev date := null;
begin
  if me is null then return 0; end if;
  for rec in
    select day from (
      select created_at::date as day from public.drawings
        where (sender = me and recipient = peer) or (sender = peer and recipient = me)
      union
      select created_at::date as day from public.messages
        where (sender = me and recipient = peer) or (sender = peer and recipient = me)
    ) t
    group by day
    order by day desc
  loop
    if prev is null then
      if rec.day < current_date - 1 then return 0; end if; -- ostatnia interakcja > wczoraj
      streak := 1;
    elsif rec.day = prev - 1 then
      streak := streak + 1;
    else
      exit; -- luka -> koniec streaka
    end if;
    prev := rec.day;
  end loop;
  return streak;
end;
$$;

grant execute on function public.get_streak(uuid) to authenticated;

-- 3) Reakcje na wiadomości (podstawowy pakiet emoji). Jedna reakcja na osobę
--    na wiadomość (zmiana = upsert, cofnięcie = delete).
create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id text not null,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.message_reactions enable row level security;
alter table public.message_reactions replica identity full;

-- select: reakcje na wiadomości z MOICH rozmów
drop policy if exists "reac select" on public.message_reactions;
create policy "reac select" on public.message_reactions
  for select to authenticated
  using (exists (
    select 1 from public.messages m
    where m.id = message_id
      and (m.sender = auth.uid()::text or m.recipient = auth.uid()::text)
  ));

-- insert/update/delete: tylko własne reakcje i tylko w mojej rozmowie
drop policy if exists "reac write" on public.message_reactions;
create policy "reac write" on public.message_reactions
  for all to authenticated
  using (user_id = auth.uid()::text)
  with check (
    user_id = auth.uid()::text
    and exists (
      select 1 from public.messages m
      where m.id = message_id
        and (m.sender = auth.uid()::text or m.recipient = auth.uid()::text)
    )
  );

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end $$;

-- 4) Obrazki / GIFy w wiadomościach: URL w wiadomości + publiczny bucket.
alter table public.messages add column if not exists image_url text;

insert into storage.buckets (id, name, public)
values ('chat-media', 'chat-media', true)
on conflict (id) do nothing;

-- odczyt publiczny (bucket public) + upload tylko dla zalogowanych
drop policy if exists "chat-media read" on storage.objects;
create policy "chat-media read" on storage.objects
  for select using (bucket_id = 'chat-media');

drop policy if exists "chat-media upload" on storage.objects;
create policy "chat-media upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'chat-media');
