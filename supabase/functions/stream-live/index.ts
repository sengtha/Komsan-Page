// Komsan Page — create a Cloudflare Stream Live input (owner only).
//
// Page Studio calls this to provision a live input on the Page's OWN Cloudflare
// Stream account. Returns the RTMPS ingest URL + stream key (point OBS / a phone
// encoder at these) and the HLS playback URL that viewers watch. Page Studio
// stores the playback/ingest details on the `live_streams` row.
//
// Chat stays on the Page's own realtime plane (the existing ws_url / room_id);
// this only provisions the video plane.
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

    const { name } = await req.json().catch(() => ({}));
    const acct = Deno.env.get('CF_ACCOUNT_ID')!;

    const cf = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acct}/stream/live_inputs`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${Deno.env.get('CF_STREAM_TOKEN')!}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        meta: { name: String(name || 'Komsan Page Live') },
        recording: { mode: 'automatic' }, // auto-save the broadcast as a replay VOD
      }),
    });
    const j = await cf.json();
    if (!cf.ok || !j?.result?.uid) {
      return new Response(JSON.stringify({ error: 'stream error', details: j?.errors ?? null }), { status: 502, headers: corsHeaders });
    }

    const r = j.result;
    const uid: string = r.uid;
    return new Response(
      JSON.stringify({
        uid,
        ingest_url: r.rtmps?.url ?? null,        // e.g. rtmps://live.cloudflare.com:443/live/
        stream_key: r.rtmps?.streamKey ?? null,  // secret — set it in OBS, keep it private
        playback_url: `https://videodelivery.net/${uid}/manifest/video.m3u8`,
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch {
    return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: corsHeaders });
  }
});
