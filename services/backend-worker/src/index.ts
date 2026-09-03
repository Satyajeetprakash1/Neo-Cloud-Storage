import { createClient } from '@supabase/supabase-js';
import { AutoRouter, error, json } from 'itty-router';

export interface Env {
  STORAGE_BUCKET: R2Bucket;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
}

const router = AutoRouter();

// Helper to get Supabase client
const getSupabase = (env: Env) => {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
};

// POST /api/v1/auth/verify - Validates JWT
router.post('/api/v1/auth/verify', async (request, env: Env) => {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader) return error(401, 'Missing Authorization header');

  const supabase = getSupabase(env);
  const { data: { user }, error: authError } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''));
  
  if (authError || !user) {
    return error(401, 'Invalid token');
  }

  return json({ valid: true, user_id: user.id });
});

// POST /api/v1/upload/init - Deduplication & Presigned URLs
router.post('/api/v1/upload/init', async (request, env: Env) => {
  const { chunks, nodeId } = await request.json() as { chunks: string[], nodeId: string };
  if (!chunks || !Array.isArray(chunks)) return error(400, 'Invalid chunks array');

  const supabase = getSupabase(env);

  // 1. Query existing chunks in global_chunks
  const { data: existingChunks, error: dbError } = await supabase
    .from('global_chunks')
    .select('chunk_hash, r2_object_key')
    .in('chunk_hash', chunks);

  if (dbError) return error(500, dbError.message);

  const existingHashMap = new Map(existingChunks?.map(c => [c.chunk_hash, c.r2_object_key]) || []);

  const missingChunks = [];
  const existingList = [];
  
  for (const hash of chunks) {
    if (existingHashMap.has(hash)) {
      existingList.push({ hash, r2_object_key: existingHashMap.get(hash) });
    } else {
      missingChunks.push(hash);
    }
  }

  // Generate upload URLs for missing chunks using the Worker as a proxy to R2
  // We use the worker as a proxy here because native Web Streams directly into CF R2
  // is fully supported via the Worker's R2 Binding without needing AWS SDK S3 signatures.
  const uploadUrls = missingChunks.map(hash => ({
    hash,
    // Client will PUT to this worker endpoint, which pipes the stream to R2.
    uploadUrl: `/api/v1/upload/chunk/${hash}` 
  }));

  return json({
    existing: existingList,
    missing: uploadUrls
  });
});

// PUT /api/v1/upload/chunk/:hash - Receive chunk stream and pipe to R2
router.put('/api/v1/upload/chunk/:hash', async (request, env: Env) => {
  const hash = request.params.hash;
  if (!request.body) return error(400, 'Missing request body');

  // Stream directly to R2 using native Web Streams
  await env.STORAGE_BUCKET.put(`chunks/${hash}`, request.body, {
    httpMetadata: { contentType: 'application/octet-stream' }
  });

  return json({ success: true, hash });
});


// POST /api/v1/upload/complete - Commit transaction in Supabase
router.post('/api/v1/upload/complete', async (request, env: Env) => {
  const { nodeId, chunks, sizeBytes } = await request.json() as any;
  const supabase = getSupabase(env);

  // In a real implementation, we'd use a Supabase RPC function to handle the transaction safely:
  // 1. Insert into global_chunks (on conflict do update reference_count + 1)
  // 2. Insert into file_chunks
  // 3. Update nodes status
  
  return json({ success: true, nodeId });
});

// GET /api/v1/download/:nodeId - Returns R2 URLs (or streams)
router.get('/api/v1/download/:nodeId', async (request, env: Env) => {
  const nodeId = request.params.nodeId;
  const supabase = getSupabase(env);
  
  const { data: fileChunks, error: err } = await supabase
    .from('file_chunks')
    .select('chunk_index, chunk_hash, global_chunks(r2_object_key)')
    .eq('node_id', nodeId)
    .order('chunk_index', { ascending: true });

  if (err) return error(500, err.message);

  const downloadUrls = fileChunks?.map(fc => ({
    index: fc.chunk_index,
    hash: fc.chunk_hash,
    url: `/api/v1/download/chunk/${(fc.global_chunks as any).r2_object_key}`
  }));

  return json({ chunks: downloadUrls, encrypted_fek: "mock_encrypted_fek" });
});

// GET /api/v1/download/chunk/:r2key - Stream from R2 to client
router.get('/api/v1/download/chunk/:r2key', async (request, env: Env) => {
  const r2key = request.params.r2key;
  const object = await env.STORAGE_BUCKET.get(r2key);

  if (!object) return error(404, 'Chunk not found');

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('etag', object.httpEtag);

  return new Response(object.body, {
    headers,
  });
});

export default {
  fetch: router.fetch,

  // Scheduled CRON Worker for Garbage Collection
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil((async () => {
      const supabase = getSupabase(env);
      
      // 1. Fetch chunks to delete
      const { data: toDelete, error: fetchErr } = await supabase
        .from('deleted_chunks_queue')
        .select('id, r2_object_key')
        .limit(100);

      if (fetchErr || !toDelete || toDelete.length === 0) return;

      const r2Keys = toDelete.map(d => d.r2_object_key);
      const queueIds = toDelete.map(d => d.id);

      // 2. Delete from R2
      await env.STORAGE_BUCKET.delete(r2Keys);

      // 3. Remove from queue
      await supabase
        .from('deleted_chunks_queue')
        .delete()
        .in('id', queueIds);
        
      console.log(`Deleted ${r2Keys.length} chunks from R2 and cleared queue.`);
    })());
  }
} satisfies ExportedHandler<Env>;
