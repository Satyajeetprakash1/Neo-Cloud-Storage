-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "ltree";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Users table
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_id UUID UNIQUE, -- Links to Supabase auth.users
    public_key TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Nodes table (Files and Folders)
CREATE TABLE IF NOT EXISTS public.nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL, -- Encrypted filename
    is_directory BOOLEAN DEFAULT FALSE,
    path ltree NOT NULL, -- Hierarchical path
    parent_id UUID REFERENCES public.nodes(id) ON DELETE CASCADE,
    size_bytes BIGINT DEFAULT 0,
    encrypted_fek TEXT, -- Zero-knowledge encrypted file key
    version_id UUID DEFAULT gen_random_uuid(), -- Optimistic concurrency
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_nodes_path ON public.nodes USING GIST (path);
CREATE INDEX idx_nodes_parent_id ON public.nodes (parent_id);
CREATE INDEX idx_nodes_user_id ON public.nodes (user_id);

-- Global chunks (Deduplication registry)
CREATE TABLE IF NOT EXISTS public.global_chunks (
    chunk_hash TEXT PRIMARY KEY, -- SHA-256 hash of the ciphertext
    r2_object_key TEXT NOT NULL,
    size_bytes INT NOT NULL,
    reference_count INT DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- File chunks (Maps file nodes to global chunks)
CREATE TABLE IF NOT EXISTS public.file_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id UUID NOT NULL REFERENCES public.nodes(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    chunk_hash TEXT NOT NULL REFERENCES public.global_chunks(chunk_hash) ON DELETE RESTRICT,
    size_bytes INT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (node_id, chunk_index)
);

-- Deleted chunks queue (Garbage collection)
CREATE TABLE IF NOT EXISTS public.deleted_chunks_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    r2_object_key TEXT NOT NULL UNIQUE,
    queued_at TIMESTAMPTZ DEFAULT NOW()
);

-- Garbage Collection Trigger Logic
CREATE OR REPLACE FUNCTION decrement_chunk_reference()
RETURNS TRIGGER AS $$
BEGIN
    -- Decrement reference count
    UPDATE public.global_chunks
    SET reference_count = reference_count - 1
    WHERE chunk_hash = OLD.chunk_hash;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION handle_global_chunk_zero_references()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.reference_count <= 0 THEN
        -- Move to deleted queue
        INSERT INTO public.deleted_chunks_queue (r2_object_key)
        VALUES (NEW.r2_object_key)
        ON CONFLICT (r2_object_key) DO NOTHING;
        
        -- Delete from global chunks
        DELETE FROM public.global_chunks WHERE chunk_hash = NEW.chunk_hash;
        
        RETURN NULL; -- Cancel the UPDATE since we DELETEd the row
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger when file_chunks are deleted
CREATE TRIGGER trigger_file_chunk_deleted
AFTER DELETE ON public.file_chunks
FOR EACH ROW
EXECUTE FUNCTION decrement_chunk_reference();

-- Trigger when global_chunks are updated
CREATE TRIGGER trigger_global_chunk_updated
AFTER UPDATE OF reference_count ON public.global_chunks
FOR EACH ROW
EXECUTE FUNCTION handle_global_chunk_zero_references();

-- Row Level Security (RLS) Policies
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.file_chunks ENABLE ROW LEVEL SECURITY;

-- Note: global_chunks and deleted_chunks_queue are managed by the Edge Worker
-- using the Supabase Service Role Key. This ensures clients cannot scan global_chunks
-- to confirm the existence of arbitrary files (preventing confirmation-of-file attacks).

CREATE POLICY "Users can manage their own nodes"
ON public.nodes
FOR ALL
USING (
    user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid())
);

CREATE POLICY "Users can manage their own file chunks"
ON public.file_chunks
FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM public.nodes 
        WHERE id = file_chunks.node_id 
        AND user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid())
    )
);
