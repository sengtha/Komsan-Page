// Komsan Page — presign an R2 upload (owner only).
//
// Page Studio calls this to upload images/audio/covers straight to the Page's
// OWN Cloudflare R2 bucket. Media never passes through Komsan. Returns a
// presigned PUT URL and the eventual public URL.
//
// Deploy with "Verify JWT" ON (owner only).
//
// Required Edge Function secrets:
//   SILO_JWT_SECRET     - authorise the owner token
//   R2_ACCOUNT_ID       - Cloudflare account id
//   R2_BUCKET           - bucket name
//   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY - R2 S3 API token
//   R2_PUBLIC_BASE      - public base URL for the bucket (e.g. https://cdn.yourpage.com)

import { jwtVerify } from 'npm:jose@5.2.0';
import { AwsClient } from 'npm:aws4fetch@1.0.20';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const EXT_OK = /^[a-z0-9]{1,5}$/;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? '';
    const { payload } = await jwtVerify(token, new TextEncoder().encode(Deno.env.get('SILO_JWT_SECRET')!));
    if ((payload as any)?.app_metadata?.silo_role !== 'owner') {
      return new Response(JSON.stringify({ error: 'owner only' }), { status: 403, headers: corsHeaders });
    }

    const { content_type, ext } = await req.json();
    if (!content_type || !ext || !EXT_OK.test(String(ext))) {
      return new Response(JSON.stringify({ error: 'bad request' }), { status: 400, headers: corsHeaders });
    }

    const key = `uploads/${crypto.randomUUID()}.${ext}`;
    const endpoint = `https://${Deno.env.get('R2_ACCOUNT_ID')}.r2.cloudflarestorage.com/${Deno.env.get('R2_BUCKET')}/${key}`;

    const aws = new AwsClient({
      accessKeyId: Deno.env.get('R2_ACCESS_KEY_ID')!,
      secretAccessKey: Deno.env.get('R2_SECRET_ACCESS_KEY')!,
      service: 's3',
      region: 'auto',
    });
    const signed = await aws.sign(new Request(endpoint, { method: 'PUT', headers: { 'Content-Type': content_type } }), {
      aws: { signQuery: true },
    });

    return new Response(
      JSON.stringify({
        upload_url: signed.url,
        public_url: `${Deno.env.get('R2_PUBLIC_BASE')!.replace(/\/$/, '')}/${key}`,
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch {
    return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: corsHeaders });
  }
});
