-- 月岳 第二階段：資料表與權限（RLS）
-- 原則：每個人只能讀寫自己的資料；別人只看得到「公開個人頁」和「已驗證的登頂」。
-- 驗證結果（金章 gps／銀章 checkin）只能由後台寫入，手機只能寫 self（補登）或 pending（待驗證）。

-- 個人資料 ---------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null default '山友' check (char_length(nickname) between 1 and 20),
  avatar_url text,
  is_public boolean not null default true,       -- 「也爬過這座山的山友」裡要不要出現
  level int not null default 1,
  xp int not null default 0,
  gear jsonb not null default '{}'::jsonb,         -- 公開的裝備摘要（套裝名稱、件數、顏色）
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profiles: 公開的人誰都能看，自己也能看" on public.profiles
  for select using (is_public or id = auth.uid());
create policy "profiles: 只能建立自己的" on public.profiles
  for insert with check (id = auth.uid());
create policy "profiles: 只能改自己的" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- 登入後自動建個人資料（用 Google 名字和大頭貼）
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, nickname, avatar_url)
  values (new.id,
          left(coalesce(new.raw_user_meta_data->>'name', new.raw_user_meta_data->>'full_name', '山友'), 20),
          new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 登頂紀錄 ---------------------------------------------------------------
create table if not exists public.climbs (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  peak_key text not null,                          -- 百岳 '1'～'100'，小百岳 'x12'，小山 's3'
  verified text not null default 'pending' check (verified in ('gps','checkin','self','pending')),
  climbed_on date,
  summit_time text,
  distance_km numeric, gain_m int, max_ele int, duration_min int, summit_d int,
  style text, source text,
  track text,                                      -- 軌跡（只有自己看得到）
  checkin jsonb,                                   -- 打卡定位（只有自己看得到）
  photo_path text, thumb_path text,                -- 照片在 storage 的路徑（只有自己看得到）
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, peak_key)
);
alter table public.climbs enable row level security;
create policy "climbs: 只能看自己的完整紀錄" on public.climbs
  for select using (user_id = auth.uid());
create policy "climbs: 手機只能寫補登或待驗證" on public.climbs
  for insert with check (user_id = auth.uid() and verified in ('self','pending'));
create policy "climbs: 手機改的時候也不能自己升章" on public.climbs
  for update using (user_id = auth.uid()) with check (user_id = auth.uid() and verified in ('self','pending'));
create policy "climbs: 只能刪自己的" on public.climbs
  for delete using (user_id = auth.uid());

-- 「也爬過這座山的山友」：只露出已驗證、而且本人公開的紀錄；不含軌跡、照片、定位
create or replace view public.peak_climbers as
  select c.peak_key, c.verified, c.climbed_on, p.id as user_id, p.nickname, p.avatar_url, p.level
  from public.climbs c join public.profiles p on p.id = c.user_id
  where c.verified in ('gps','checkin') and p.is_public;

-- 行程與登山計劃 -----------------------------------------------------------
create table if not exists public.trips (
  id text not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.trips enable row level security;
create policy "trips: 只能讀寫自己的" on public.trips
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 裝備（完整資料只有自己看得到；公開摘要放在 profiles.gear）--------------------------
create table if not exists public.gear (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.gear enable row level security;
create policy "gear: 只能讀寫自己的" on public.gear
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- updated_at 自動更新 ----------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$ begin new.updated_at = now(); return new; end $$;
create trigger t_profiles before update on public.profiles for each row execute function public.touch_updated_at();
create trigger t_climbs before update on public.climbs for each row execute function public.touch_updated_at();
create trigger t_trips before update on public.trips for each row execute function public.touch_updated_at();
create trigger t_gear before update on public.gear for each row execute function public.touch_updated_at();

-- 權限：沒開「自動開放」，所以一張一張給 ------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.climbs, public.trips, public.gear to authenticated;
grant select on public.peak_climbers to anon, authenticated;

-- 照片：私人 bucket，路徑第一層是自己的 user id ------------------------------------------
insert into storage.buckets (id, name, public) values ('photos','photos',false) on conflict (id) do nothing;
create policy "photos: 只能讀自己的" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: 只能傳到自己的資料夾" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: 只能刪自己的" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
