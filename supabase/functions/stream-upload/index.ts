// Komsan Page — presign a Cloudflare Stream (VOD) upload (owner only).
//
// Page Studio calls this to get a one-time direct-upload URL on the Page's OWN
// Cloudflare Stream account. The browser then POSTs the video file to that URL
// (multipart form, field `file`). Playback is adaptive HLS served by Stream;
// the media never touches Komsan.
//
// Store the returned `playback_url` on the video row's `hls_url` (and `uid` on
// `stream_uid`, if you added that column).
//
// Deploy with "Verify JWT" ON (owner only).
//
// Required Edge Function secrets:
//   SILO_JWT_SECRET     - authorise the owner token
//   CF_ACCOUNT_ID       - Cloudflare account id (the Page's own account)
//   CF_STREAM_TOKEN     - API token with Stream:Edit on that account

import { jwtVerify } from 'npm:jose@5.2.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
    const { payload } = await jwtVerify(token, new TextEncoder().encode(Deno.env.get('SILO_JWT_SECRET')!));
    if ((payload as any)?.app_metadata?.silo_role !== 'owner') {
      return new Response(JSON.stringify({ error: 'owner only' }), { status: 403, headers: corsHeaders });
    }

    const { max_duration_seconds } = await req.json().catch(() => ({}));
    const acct = Deno.env.get('CF_ACCOUNT_ID')!;

    const cf = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acct}/stream/direct_upload`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${Deno.env.get('CF_STREAM_TOKEN')!}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        maxDurationSeconds: Math.min(Math.max(Number(max_duration_seconds) || 3600, 1), 21600),
        requireSignedURLs: false,
        allowedOrigins: ['*'],
      }),
    });
    const j = await cf.json();
    if (!cf.ok || !j?.result?.uploadURL) {
      return new Response(JSON.stringify({ error: 'stream error', details: j?.errors ?? null }), { status: 502, headers: corsHeaders });
    }

    const uid: string = j.result.uid;
    return new Response(
      JSON.stringify({
        upload_url: j.result.uploadURL,           // POST the file here (multipart, field `file`)
        uid,
        playback_url: `https://videodelivery.net/${uid}/manifest/video.m3u8`,
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch {
    return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: corsHeaders });
  }
});
