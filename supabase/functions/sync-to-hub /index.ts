// Komsan Page — project one item to the Komsan Hub feed (or retract it).
//
// Page Studio calls this (with the owner's silo token) after creating, updating,
// unpublishing or deleting an item. We read the current row and, if it is
// (status='public' AND publish_to_komsan), push a signed PUBLIC projection to the
// Hub ingest; otherwise we push a retract. Only public preview fields leave the
// silo — full content and media stay here.
//
// Deploy with "Verify JWT" ON (only the owner may call it).
//
// Required Edge Function secrets:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  - this silo
//   SILO_JWT_SECRET      - to authorise the owner token
//   HUB_INGEST_URL       - https://<komsan-hub>/api/pages/ingest
//   PAGE_ID              - this Page's id in the Komsan Hub
//   PAGE_PUBLISH_SECRET  - the publish_secret register_page returned

import { createClient } from 'npm:@supabase/supabase-js@2.39.3';
import { jwtVerify } from 'npm:jose@5.2.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const TABLE: Record<string, string> = { post: 'posts', video: 'videos', music: 'audio_tracks', product: 'products' };

function projectionFor(kind: string, row: any) {
  if (kind === 'post') return { kind, title: null, snippet: (row.content ?? '').slice(0, 140), thumbnail_url: row.media_url ?? null };
  if (kind === 'video') return { kind, title: row.title ?? null, snippet: null, thumbnail_url: row.thumbnail_url ?? null };
  if (kind === 'product')
    return { kind, title: row.name ?? null, snippet: `${row.price} ${row.currency ?? ''}`.trim(), thumbnail_url: row.image_url ?? null };
  return { kind, title: row.title ?? null, snippet: null, thumbnail_url: row.cover_art ?? null }; // music
}

async function sign(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    // Authorise: owner token only.
    const auth = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
    const { payload } = await jwtVerify(auth, new TextEncoder().encode(Deno.env.get('SILO_JWT_SECRET')!));
    if ((payload as any)?.app_metadata?.silo_role !== 'owner') {
      return new Response(JSON.stringify({ error: 'owner only' }), { status: 403, headers: corsHeaders });
    }

    const { kind, item_id } = await req.json();
    const table = TABLE[kind];
    if (!table || !item_id) return new Response(JSON.stringify({ error: 'bad request' }), { status: 400, headers: corsHeaders });

    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: row } = await sb.from(table).select('*').eq('id', item_id).maybeSingle();

    const live = row && row.status === 'public' && row.publish_to_komsan;
    const body = live
      ? { item_id, action: 'upsert', projection: { ...projectionFor(kind, row), published_at: row.created_at } }
      : { item_id, action: 'retract' };
    const raw = JSON.stringify(body);
    const ts = Date.now();

    const res = await fetch(Deno.env.get('HUB_INGEST_URL')!, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Page-Id': Deno.env.get('PAGE_ID')!,
        'X-Page-Timestamp': String(ts),
        'X-Page-Signature': await sign(Deno.env.get('PAGE_PUBLISH_SECRET')!, `${ts}.${raw}`),
      },
      body: raw,
    });

    return new Response(JSON.stringify({ ok: res.ok, synced: live ? 'upsert' : 'retract' }), {
      status: res.ok ? 200 : 502,
      headers: corsHeaders,
    });
  } catch {
    return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: corsHeaders });
  }
});
