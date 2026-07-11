# Page engagement (reactions + comments) — Komsan-Page silo

Run `supabase/engagement.sql` in the Page's Supabase SQL editor.

- Adds a `reactions` table (one emoji per user per item) with RLS.
- Sets `comments.author_uid` DEFAULT auth.uid() (the visitor's Komsan id).

The Hub UI (PageInteractions) reads/writes these directly with the visitor's
silo token and resolves commenter names from the Komsan `users` table.
No edge functions needed.
