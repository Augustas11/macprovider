-- Fleet autoupdate convergence telemetry (Epic #1235 Child B / B2).
--
-- The provider CLI already reports its most recent autoupdate outcome/reason
-- on every heartbeat and state_update (`last_autoupdate_event`), but the
-- coordinator only ever kept the LATEST one in memory (pool.Provider), exposed
-- through the operator admin API — it was never durably ingested, so
-- fleet-wide autoupdate convergence (how many providers landed a given
-- release, and why the rest didn't) was not measurable. This table is an
-- append-only ingest of each DISTINCT autoupdate event a provider reports;
-- the coordinator de-duplicates repeated heartbeat echoes of the same event
-- before inserting (see internal/ws heartbeat handling), so this is not one
-- row per heartbeat.
--
-- Free-form fields (source/phase/outcome/reason/failure_class/
-- current_version/target_version) mirror provider_hardware_profiles'
-- macos_version/app_version: client-reported text with NO enum CHECK, because
-- the client-side taxonomy (AutoUpdateEvent.swift) evolves independently of
-- this schema.
CREATE TABLE IF NOT EXISTS provider_autoupdate_events (
    id              BIGSERIAL PRIMARY KEY,
    provider_id     TEXT NOT NULL,
    observed_at     TIMESTAMPTZ NOT NULL,
    update_id       TEXT NOT NULL DEFAULT '',
    current_version TEXT NOT NULL DEFAULT '',
    target_version  TEXT NOT NULL DEFAULT '',
    source          TEXT NOT NULL DEFAULT '',
    phase           TEXT NOT NULL DEFAULT '',
    outcome         TEXT NOT NULL DEFAULT '',
    reason          TEXT NOT NULL DEFAULT '',
    failure_class   TEXT NOT NULL DEFAULT '',
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_provider_autoupdate_events_provider_observed
    ON provider_autoupdate_events(provider_id, observed_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_autoupdate_events_recorded_at
    ON provider_autoupdate_events(recorded_at);

-- Append-only from the runtime role, matching provider_register_attempts
-- (migration 018): the coordinator can record and read events but cannot
-- mutate or delete them.
GRANT SELECT ON provider_autoupdate_events TO provider_onboarding;
GRANT INSERT (
    provider_id, observed_at, update_id, current_version, target_version,
    source, phase, outcome, reason, failure_class
) ON provider_autoupdate_events TO provider_onboarding;
-- BIGSERIAL id: INSERT must be able to call nextval() on the owned sequence,
-- otherwise every runtime insert fails "permission denied for sequence" (the
-- boot smoke only SELECTs, so it would not catch this).
GRANT USAGE, SELECT ON SEQUENCE provider_autoupdate_events_id_seq TO provider_onboarding;

GRANT SELECT ON provider_autoupdate_events TO stats_rollup;
REVOKE ALL ON provider_autoupdate_events FROM stats_reader, provider_portal;

CREATE OR REPLACE FUNCTION prune_provider_autoupdate_events(retain_for INTERVAL DEFAULT INTERVAL '30 days')
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

    DELETE FROM provider_autoupdate_events
     WHERE recorded_at < NOW() - retain_for;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION prune_provider_autoupdate_events(INTERVAL) FROM PUBLIC;
REVOKE ALL ON FUNCTION prune_provider_autoupdate_events(INTERVAL) FROM provider_onboarding;
