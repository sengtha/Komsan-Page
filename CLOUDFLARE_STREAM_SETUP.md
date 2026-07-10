# Cloudflare Stream for Komsan-Page (silo)

Drop these into your Komsan-Page repo to add Cloudflare Stream VOD upload + Live.
Everything runs on the Page's OWN Cloudflare account; Komsan never sees the media.

## 1. Edge functions
Copy into `supabase/functions/`:
- `stream-upload/index.ts` — presigns a Stream direct upload (VOD).
- `stream-live/index.ts`   — creates a Stream Live Input (RTMPS ingest + HLS).

Deploy both with **Verify JWT = ON** (owner only):
    supabase functions deploy stream-upload
    supabase functions deploy stream-live

## 2. Secrets (on both functions)
    SILO_JWT_SECRET   - this silo's Supabase JWT secret (same one the other fns use)
    CF_ACCOUNT_ID     - your Cloudflare account id
    CF_STREAM_TOKEN   - Cloudflare API token with **Stream:Edit**

## 3. Schema
Run `live_streams.sql` in the Page's Supabase SQL editor.

## 4. Test
- Page Studio → video → "ផ្ទុកទៅ Cloudflare Stream" → upload a clip.
- Page Studio → Live → "Create Cloudflare Stream Live" → copy the RTMPS URL +
  Stream Key into OBS → Go live → confirm the Live tab plays it.

## Playback domain note
The functions return `https://videodelivery.net/<uid>/manifest/video.m3u8`.
If your account uses a `customer-<code>.cloudflarestream.com` playback domain,
swap that base in both functions' `playback_url`.
