-- Komsan-Page silo — add Cloudflare Stream Live columns to live_streams.
-- Run in the Page's own Supabase SQL editor (idempotent).

ALTER TABLE public.live_streams ALTER COLUMN room_id DROP NOT NULL;
ALTER TABLE public.live_streams ALTER COLUMN ws_url  DROP NOT NULL;
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS stream_uid   text;  -- live input id
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS ingest_url   text;  -- RTMPS ingest (OBS)
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS stream_key   text;  -- RTMPS key (secret)
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS playback_url text;  -- HLS viewers watch
