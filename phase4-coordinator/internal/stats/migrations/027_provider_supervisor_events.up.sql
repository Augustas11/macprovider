-- Supervisor telemetry: coordinator-observable provider liveness recovery
-- (RFC-001 §7 / F5, #1386; SPEC-025 §5.4).
--
-- The companion watchdog publishes a best-effort latest-state BEACON that the
-- provider CLI carries on every heartbeat/state_update as `last_supervisor_event`
-- (SEPARATE from `last_autoupdate_event`; never merged into
-- provider_autoupdate_events). Unlike migration 026's append-only autoupdate
-- ingest, this is an UPSERT of ONE row per (provider_id, boot_id): the beacon is
-- latest-state, ordered by `seq` alone, so the coordinator keeps the highest-seq
-- observation plus coordinator-derived rollups (frequency + flap history) rather
-- than one row per event. Observability-only: nothing here gates admission,
-- routing, serving, trust, rewards, autoupdate, or any authority (SPEC-025 §5.4).
--
-- Free-form client-reported text fields carry NO enum CHECK (matching
-- provider_autoupdate_events); the client-side taxonomy evolves independently.
CREATE TABLE IF NOT EXISTS provider_supervisor_events (
    provider_id                   TEXT NOT NULL,
    boot_id                       TEXT NOT NULL,
    schema                        TEXT NOT NULL DEFAULT '',
    -- Observation bookkeeping (coordinator wall-clock).
    first_seen_at                 TIMESTAMPTZ NOT NULL,
    last_observed_at              TIMESTAMPTZ NOT NULL,
    prev_observed_at              TIMESTAMPTZ,
    last_seq                      BIGINT NOT NULL DEFAULT 0,
    kind                          TEXT NOT NULL DEFAULT '',
    supervisor_label              TEXT NOT NULL DEFAULT '',
    supervisor_version            TEXT NOT NULL DEFAULT '',
    -- Monotonic recovery counters (high-water) + the prior-observation values so
    -- an observation-time rate = (restarts_total - prev_restarts_total) over
    -- (last_observed_at - prev_observed_at) is reconstructable without a per-event log.
    restarts_total                BIGINT NOT NULL DEFAULT 0,
    deferrals_total               BIGINT NOT NULL DEFAULT 0,
    prev_restarts_total           BIGINT NOT NULL DEFAULT 0,
    prev_deferrals_total          BIGINT NOT NULL DEFAULT 0,
    -- Sticky last_restart detail (carried on every beacon once it occurs).
    last_restart_seq              BIGINT NOT NULL DEFAULT 0,
    last_restart_ts               TEXT NOT NULL DEFAULT '',
    last_restart_cooldown_state   TEXT NOT NULL DEFAULT '',
    last_restart_service_instance TEXT NOT NULL DEFAULT '',
    last_restart_model_liveness   JSONB,
    -- Acceptance-window anchor: coordinator wall-clock when it FIRST observed the
    -- current last_restart_seq (never the provider's self-reported ts).
    last_restart_observed_at      TIMESTAMPTZ,
    -- Sticky last_deferral detail.
    last_deferral_seq             BIGINT NOT NULL DEFAULT 0,
    last_deferral_ts              TEXT NOT NULL DEFAULT '',
    -- Coordinator-derived flap rollup (RFC-001 §7: flap loops must be observable,
    -- not just total restart frequency). dwell_state is one of
    -- {unknown, correlated_pending, held, flap, artifact_confounded}.
    flaps_total                   BIGINT NOT NULL DEFAULT 0,
    last_flap_observed_at         TIMESTAMPTZ,
    last_restart_dwell_state      TEXT NOT NULL DEFAULT '',
    recorded_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider_id, boot_id)
);

CREATE INDEX IF NOT EXISTS idx_provider_supervisor_events_observed
    ON provider_supervisor_events(provider_id, last_observed_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_supervisor_events_recorded_at
    ON provider_supervisor_events(recorded_at);

-- Operator/analytics only. The runtime role upserts (SELECT/INSERT/UPDATE); no
-- buyer- or provider-portal-facing role may read supervisor telemetry.
GRANT SELECT, INSERT, UPDATE ON provider_supervisor_events TO provider_onboarding;
GRANT SELECT ON provider_supervisor_events TO stats_rollup;
REVOKE ALL ON provider_supervisor_events FROM stats_reader, provider_portal;

CREATE OR REPLACE FUNCTION prune_provider_supervisor_events(retain_for INTERVAL DEFAULT INTERVAL '30 days')
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    IF retain_for < INTERVAL '7 days' THEN
        RAISE EXCEPTION 'retain_for must be at least 7 days';
    END IF;

    DELETE FROM provider_supervisor_events
     WHERE recorded_at < NOW() - retain_for;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION prune_provider_supervisor_events(INTERVAL) FROM PUBLIC;
REVOKE ALL ON FUNCTION prune_provider_supervisor_events(INTERVAL) FROM provider_onboarding;
