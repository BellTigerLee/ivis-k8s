CREATE OR REPLACE FUNCTION public.ivis_begin_execution(base_name text, run_token uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    run_name text := base_name || '/' || run_token::text;
    new_id integer;
    began timestamptz := clock_timestamp();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.ivis_projection WHERE name = base_name AND status = 'active') THEN
        RAISE EXCEPTION 'execution_base_generation_not_active';
    END IF;
    INSERT INTO public.ivis_projection(name, status) VALUES (run_name, 'active') RETURNING generation_id INTO new_id;
    INSERT INTO public.ivis_commit(generation_id, revision, kind, published_at_ns, state_digest, changed_objects)
    VALUES (new_id, 0, 'init', (extract(epoch FROM began)*1000000000)::numeric(30,0), repeat('0',64), 0);
    INSERT INTO public.ivis_checkpoint(generation_id, revision, bootstrapped, positions, metadata, state_digest)
    VALUES (new_id, 0, false, '{}'::jsonb,
            jsonb_build_object('execution_generation',jsonb_build_object(
                'id',run_token::text,'name',run_name,'base',base_name,'started_at',began,
                'cross_generation_continuity','not_guaranteed',
                'snapshot_stream_boundary','per_kind_list_request_start_capture_time',
                'snapshot_stream_overlap','unverified','previous_cursor_inherited',false)),repeat('0',64));
    RETURN run_name;
END;
$$;
REVOKE ALL ON FUNCTION public.ivis_begin_execution(text, uuid) FROM PUBLIC;
