-- Issue #381 / SPEC-017 follow-up: provider idle prewarm telemetry.
--
-- Events are recorded by the authenticated provider WebSocket path through the
-- stats_rollup role, then summarized into stats_overview_current so public
-- stats handlers remain read-only.

ALTER TABLE stats_overview_current
    ADD COLUMN IF NOT EXISTS idle_prewarm_pool_pct_with_b1_active INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS idle_prewarm_skips_by_reason_last_1h JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS stats_idle_prewarm_events (
    id            BIGSERIAL PRIMARY KEY,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    provider_id   TEXT NOT NULL,
    event         TEXT NOT NULL CHECK (event IN (
        'idle_prewarm_fired',
        'idle_prewarm_completed',
        'idle_prewarm_skipped',
        'idle_prewarm_cancelled_by_real_request',
        'idle_prewarm_failed'
    )),
    reason        TEXT CHECK (
        reason IS NULL OR reason IN (
            'disabled',
            'busy',
            'not_idle_yet',
            'thermal_pressure',
            'on_battery',
            'model_not_loaded'
        )
    ),
    CHECK (
        (event = 'idle_prewarm_skipped' AND reason IS NOT NULL)
        OR (event <> 'idle_prewarm_skipped' AND reason IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS stats_idle_prewarm_events_recorded_at_idx
    ON stats_idle_prewarm_events (recorded_at);
CREATE INDEX IF NOT EXISTS stats_idle_prewarm_events_provider_recorded_at_idx
    ON stats_idle_prewarm_events (provider_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS stats_idle_prewarm_events_skip_reason_recorded_at_idx
    ON stats_idle_prewarm_events (reason, recorded_at)
    WHERE event = 'idle_prewarm_skipped';

GRANT SELECT, INSERT, DELETE ON stats_idle_prewarm_events TO stats_rollup;
GRANT USAGE, SELECT ON SEQUENCE stats_idle_prewarm_events_id_seq TO stats_rollup;
GRANT SELECT ON stats_idle_prewarm_events TO stats_reader;

REVOKE ALL ON stats_idle_prewarm_events FROM provider_portal;
