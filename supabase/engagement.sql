-- Komsan-Page silo — engagement: reactions + comments.
-- Run in the Page's own Supabase SQL editor. Idempotent.
--
-- Visitors act as their real Komsan identity: the silo JWT's sub = the Komsan
-- user id, so author_uid / user_uid are Komsan user ids (the Hub resolves names).

-- Comments already exist in the starter schema; default author_uid so the
-- client doesn't have to send it (RLS still checks author_uid = auth.uid()).
ALTER TABLE public.comments ALTER COLUMN author_uid SET DEFAULT auth.uid();

-- One emoji reaction per user per item (change = upsert, remove = delete).
CREATE TABLE IF NOT EXISTS public.reactions (
  target_type text NOT NULL CHECK (target_type IN ('post', 'video', 'audio')),
  target_id   uuid NOT NULL,
  user_uid    uuid NOT NULL DEFAULT auth.uid(),
  emoji       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (target_type, target_id, user_uid)
);
ALTER TABLE public.reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read reactions"          ON public.reactions;
DROP POLICY IF EXISTS "insert own reaction"     ON public.reactions;
DROP POLICY IF EXISTS "update own reaction"     ON public.reactions;
DROP POLICY IF EXISTS "delete own reaction"     ON public.reactions;
CREATE POLICY "read reactions"      ON public.reactions FOR SELECT USING (true);
CREATE POLICY "insert own reaction" ON public.reactions FOR INSERT WITH CHECK (user_uid = auth.uid());
CREATE POLICY "update own reaction" ON public.reactions FOR UPDATE USING (user_uid = auth.uid());
CREATE POLICY "delete own reaction" ON public.reactions FOR DELETE USING (user_uid = auth.uid());
