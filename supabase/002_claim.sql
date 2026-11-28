-- 月岳 002：手機上判斷的章別（等後台驗證時參考），公開頁只看 verified
alter table public.climbs add column if not exists claim text check (claim in ('gps','checkin'));
