-- Komsan-Page (silo) — run in the Page's own Supabase.
-- Adds a per-post Khmer font so Page posts honour the author's font choice,
-- matching Komsan Hub posts. The Hub's Page Studio composer writes this column
-- and PageFeed reads it; no edge-function change is needed.

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS font_family text;

-- Refresh PostgREST's schema cache so the column is writable immediately.
NOTIFY pgrst, 'reload schema';
