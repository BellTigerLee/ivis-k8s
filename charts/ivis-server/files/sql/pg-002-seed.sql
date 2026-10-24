-- ivis-server: create (or find) ONE state generation and its empty revision-0 head. Safe to re-run: an existing
-- generation of the same name is left untouched (nothing is overwritten, nothing is dropped).
-- Run as the schema owner AFTER 001_schema.sql:
--   psql "$IVIS_ADMIN_DSN" -v ON_ERROR_STOP=1 -f sql/postgres/002_init_generation.sql
--
-- EDIT ONLY the value marked below. It must equal the application's IVIS_POSTGRES_GENERATION (default: default).
-- No version number is written here: the server records and checks its own rule version in the checkpoint.
BEGIN;
WITH params AS (
    SELECT 'default'::text AS generation_name       -- <== EDIT: generation name
),
created AS (
    INSERT INTO ivis_projection (name, status)
    SELECT generation_name, 'active' FROM params
    ON CONFLICT (name) DO NOTHING
    RETURNING generation_id
),
root AS (
    INSERT INTO ivis_commit (generation_id, revision, kind, published_at_ns, state_digest, changed_objects)
    SELECT generation_id, 0, 'init', (extract(epoch FROM clock_timestamp()) * 1000000000)::numeric(30,0),
           repeat('0', 64), 0
    FROM created
    RETURNING generation_id
)
INSERT INTO ivis_checkpoint (generation_id, revision, bootstrapped, positions, metadata, state_digest)
SELECT generation_id, 0, false, '{}'::jsonb, '{}'::jsonb, repeat('0', 64) FROM root;
COMMIT;

SELECT p.generation_id, p.name, p.status, c.revision, c.bootstrapped
FROM ivis_projection AS p
LEFT JOIN ivis_checkpoint AS c USING (generation_id)
ORDER BY p.generation_id;
