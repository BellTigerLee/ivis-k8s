-- IVIS 0.4.0: KumeC current metadata of one server run + signal task/binding current projections.
-- Current rows only. The run_id isolates a server start; nothing here is read back at startup (no restore).
-- Versions are Kubernetes metadata.resourceVersion strings; there is no KumeC revision column.
CREATE SCHEMA IF NOT EXISTS ivis_kumec;
CREATE SCHEMA IF NOT EXISTS ivis_signal;

CREATE TABLE IF NOT EXISTS ivis_kumec.run (
    run_id text PRIMARY KEY CHECK (length(run_id) BETWEEN 1 AND 128),
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    app_version text,
    coverage jsonb NOT NULL DEFAULT '{}'::jsonb,
    initialized_at timestamptz
);

-- One row per native Node/Pod (uid + materialized RV) or derived ContainerDefinition/ContainerRuntime (no own RV;
-- source_refs names the Pod entity and the Pod RV it was derived from).
CREATE TABLE IF NOT EXISTS ivis_kumec.entity (
    run_id text NOT NULL REFERENCES ivis_kumec.run(run_id),
    entity_id text NOT NULL,
    kind text NOT NULL,
    uid text,
    api_group text NOT NULL,
    resource text,
    cluster_uid text,
    cluster_name text,
    namespace text,
    name text NOT NULL,
    lifecycle text NOT NULL CHECK (lifecycle IN ('present', 'deleted')),
    materialized_resource_version text,
    deleted_at timestamptz,
    source_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (run_id, entity_id),
    CHECK ((uid IS NULL) = (materialized_resource_version IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS kumec_entity_native
    ON ivis_kumec.entity (run_id, coalesce(cluster_uid, ''), coalesce(cluster_name, ''), api_group, resource, uid)
    WHERE uid IS NOT NULL;
CREATE INDEX IF NOT EXISTS kumec_entity_name ON ivis_kumec.entity (run_id, kind, namespace, name, entity_id);

CREATE TABLE IF NOT EXISTS ivis_kumec.state (
    run_id text NOT NULL,
    entity_id text NOT NULL,
    state_type text NOT NULL,
    state_value text,
    reason text,
    source_transition_at text,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_entity_id text NOT NULL,
    source_rv text NOT NULL,
    PRIMARY KEY (run_id, entity_id, state_type),
    FOREIGN KEY (run_id, entity_id) REFERENCES ivis_kumec.entity (run_id, entity_id)
);

CREATE TABLE IF NOT EXISTS ivis_kumec.label (
    run_id text NOT NULL,
    entity_id text NOT NULL,
    label_key text NOT NULL,
    label_value text NOT NULL,
    source_rv text NOT NULL,
    PRIMARY KEY (run_id, entity_id, label_key),
    FOREIGN KEY (run_id, entity_id) REFERENCES ivis_kumec.entity (run_id, entity_id)
);
CREATE INDEX IF NOT EXISTS kumec_label_value ON ivis_kumec.label (run_id, label_key, label_value, entity_id);

CREATE TABLE IF NOT EXISTS ivis_kumec.attribute (
    run_id text NOT NULL,
    entity_id text NOT NULL,
    attrs jsonb NOT NULL CHECK (jsonb_typeof(attrs) = 'object' AND octet_length(attrs::text) <= 16384),
    source_rv text NOT NULL,
    PRIMARY KEY (run_id, entity_id),
    FOREIGN KEY (run_id, entity_id) REFERENCES ivis_kumec.entity (run_id, entity_id)
);

-- Pod -> Node (node_entity_id NULL = unresolved, node_name kept); container -> Pod (+ runtime -> definition).
CREATE TABLE IF NOT EXISTS ivis_kumec.placement (
    run_id text NOT NULL,
    entity_id text NOT NULL,
    node_entity_id text,
    node_name text,
    pod_entity_id text,
    definition_entity_id text,
    source_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
    PRIMARY KEY (run_id, entity_id),
    FOREIGN KEY (run_id, entity_id) REFERENCES ivis_kumec.entity (run_id, entity_id)
);
CREATE INDEX IF NOT EXISTS kumec_placement_node ON ivis_kumec.placement (run_id, node_entity_id, entity_id)
    WHERE node_entity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS kumec_placement_pod ON ivis_kumec.placement (run_id, pod_entity_id, entity_id)
    WHERE pod_entity_id IS NOT NULL;

-- Final lifecycle state per kernel task identity (node boot + pid + start basis). Every event is in ClickHouse.
CREATE TABLE IF NOT EXISTS ivis_signal.task_current (
    run_id text NOT NULL,
    task_id text NOT NULL CHECK (length(task_id) = 64),
    source_id text NOT NULL,
    cluster_uid text NOT NULL,
    cluster_name text NOT NULL,
    node_uid text NOT NULL,
    node_name text NOT NULL,
    boot_id text NOT NULL,
    pid bigint NOT NULL CHECK (pid > 0),
    tgid bigint NOT NULL CHECK (tgid > 0),
    task_start_ns numeric(20, 0) NOT NULL,
    start_basis text NOT NULL,
    lifecycle text NOT NULL CHECK (lifecycle IN ('running', 'exited')),
    first_kind text NOT NULL,
    parent_task_id text NOT NULL,
    comm text NOT NULL,
    filename text NOT NULL,
    exec_count integer NOT NULL CHECK (exec_count >= 0),
    exit_code integer,
    exited_at_ns numeric(20, 0),
    last_event_id text NOT NULL,
    last_at_ns numeric(20, 0) NOT NULL,
    clock_basis text NOT NULL,
    alias_key text NOT NULL,
    binding_status text NOT NULL,
    event_count integer NOT NULL,
    quality text[] NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (run_id, task_id)
);
CREATE INDEX IF NOT EXISTS signal_task_node ON ivis_signal.task_current (run_id, node_name, boot_id, pid);

-- One row per producer resource alias (scope + claim), not per task or sample.
CREATE TABLE IF NOT EXISTS ivis_signal.resource_binding (
    run_id text NOT NULL,
    alias_key text NOT NULL CHECK (length(alias_key) = 64),
    status text NOT NULL CHECK (status IN ('resolved', 'unresolved', 'ambiguous', 'conflict', 'host',
                                           'kumec_unavailable')),
    reason text NOT NULL,
    node_entity_id text,
    pod_entity_id text,
    runtime_entity_id text,
    reported jsonb NOT NULL,
    dependency_refs jsonb NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (run_id, alias_key)
);
CREATE INDEX IF NOT EXISTS signal_binding_pod ON ivis_signal.resource_binding (run_id, pod_entity_id)
    WHERE pod_entity_id IS NOT NULL;
