# Komsan Page — silo template (BYOI)

A **Komsan Page** is a sovereign node you run on **your own Supabase project**. Komsan
is only the *user layer*: Komsan users read your Page's feed / video / music
**directly** from your Supabase, using a short-lived token **your** silo mints.
Komsan never holds your signing secret, and you never hand Komsan your data — it
reads it live, gated by your own Row-Level Security.

> This folder is staged inside the `komsan` repo for development. It is meant to
> be lifted into a **public `Komsan-Page` repo** that third parties clone. See
> "Publishing this template" below.

## How the trust works (no shared secrets)

```
Komsan Hub                     Komsan client (browser)          Your silo (this repo)
   │  create_silo_ticket(page)        │                                 │
   │─────────────────────────────────▶│  ticket_id (one-time, 60s)      │
   │                                   │──── POST { ticket_id } ────────▶│ authenticate-hub-user
   │  redeem_silo_ticket(ticket_id)    │                                 │
   │◀──────────────────────────────────────────────────────────────────│  (Hub anon key)
   │  { user_id, email, silo_id, role }  (ticket invalidated)           │
   │───────────────────────────────────────────────────────────────────▶│ mint JWT (SILO_JWT_SECRET,
   │                                   │◀───── { token } (15m) ──────────│  sub = user_id)
   │                                   │  createClient(SILO_URL) + token → read feed/video/music
```

- The **ticket** is the only thing that crosses from Komsan; it is one-time and
  expires in 60s.
- Your silo signs the session token with **`SILO_JWT_SECRET`** (your project's
  own JWT secret). Komsan never sees it.
- `sub` on the minted token is the Komsan user id, so your RLS uses `auth.uid()`
  with no shadow-user provisioning.

## Setup

1. Create a Supabase project (this becomes your silo).
2. Deploy the edge function:
   ```bash
   supabase functions deploy authenticate-hub-user
   ```
   In the dashboard, set **Verify JWT = OFF** for `authenticate-hub-user` (the
   ticket is the credential, not a Supabase JWT).
3. Set the function secrets:
   ```
   HUB_URL          = https://<komsan-hub>.supabase.co
   HUB_ANON_KEY     = <komsan hub anon/publishable key>
   SILO_JWT_SECRET  = <this project's JWT secret>   # Settings → API → JWT
   ```
4. Create your content tables + RLS by running `supabase/schema.sql`. Each item
   has `status` (`draft`/`public`) and `publish_to_komsan` (default true).
   Visitors read `public` only; the **owner** (you) reads/writes everything via
   Page Studio. Comments are written as the visitor's own Komsan id.
5. Link your Page to Komsan (requires the **artist** role): call
   `register_page(name, silo_url, silo_anon_key, authenticate_url, logo_url)`.
   It returns your **`publish_secret`** — save it (shown once).
6. Deploy the Hub-sync function (Verify JWT = **ON** — owner only):
   ```bash
   supabase functions deploy sync-to-hub
   ```
   Secrets:
   ```
   HUB_INGEST_URL      = https://<komsan-hub>/api/pages/ingest
   PAGE_ID             = <id returned by register_page>
   PAGE_PUBLISH_SECRET = <publish_secret returned by register_page>
   # (SILO_JWT_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY already set)
   ```

## Media uploads (your own R2)

Page Studio uploads images / audio / covers straight to **your** Cloudflare R2 —
media never touches Komsan. Deploy the presign function (Verify JWT = **ON**):

```bash
supabase functions deploy sign-upload
```
Secrets:
```
R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
R2_PUBLIC_BASE = https://<your public bucket/CDN base>
# (SILO_JWT_SECRET already set)
```
Video today takes an HLS/mp4 URL (host on Cloudflare Stream or your own
packager); direct Stream upload can be wired later.

## Publishing to the Komsan Hub feed

When an item becomes `public` with `publish_to_komsan = true`, Page Studio calls
`sync-to-hub`, which pushes a **public projection** (title/snippet/thumbnail
only) to the Hub, HMAC-signed with your `publish_secret`. It appears in Komsan's
main feed; tapping it opens your Page with the full item loaded live from here.
Unpublishing or deleting sends a retract. Full content and media never leave the
silo.

## Live streaming (optional)

Deploy a **Normsar-DO** worker (a Cloudflare Durable Object that verifies your
silo's Supabase JWT and relays room chat/gifts). Then insert a row into
`live_streams` with `status = 'live'`, a `room_id`, and `ws_url` = your worker's
base `wss://` URL. Komsan's Live tab opens `${ws_url}/chat/${room_id}?token=<silo
token>`. Video frames go through Cloudflare Stream Live (your media plane); the
DO only relays lightweight JSON. Komsan hosts **no** worker for any of this — the
streaming plane is entirely yours.

## How Komsan reads this silo

The Komsan client (`lib/siloClient.ts` → `getSiloClient(pageId)`) mints a Hub
ticket, calls `authenticate-hub-user`, and creates a Supabase client bound to
this silo with the returned token. `views/PageView.tsx` renders Feed / Video /
Music / Live against it. Nothing is proxied through Komsan — the browser talks to
your silo directly.

## Publishing this template

To let third parties deploy their own Page, copy this `page-template/` folder
into a new **public** GitHub repo named `Komsan-Page` (mirrors how `Normsar-Silo`
is a public template). Nothing here contains secrets — all secrets are set as
Supabase Edge Function secrets at deploy time.
