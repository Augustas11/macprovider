-- SPEC-017 v0.2.0 — public current-health/routability read model.
-- Existing deployments have the v0.1 seven-component CHECK constraint, so
-- widen it before seeding the new component row.

ALTER TABLE stats_components_health
    DROP CONSTRAINT IF EXISTS stats_components_health_component_check;

ALTER TABLE stats_components_health
    ADD CONSTRAINT stats_components_health_component_check
    CHECK (component IN (
        'overview',
        'timeseries_rpm',
        'timeseries_tpm',
        'leaderboard_24h',
        'leaderboard_7d',
        'leaderboard_30d',
        'leaderboard_all',
        'routability'
    ));

CREATE TABLE IF NOT EXISTS stats_routability_current (
    singleton                BOOLEAN PRIMARY KEY DEFAULT TRUE
                             CHECK (singleton = TRUE),
    generated_at             TIMESTAMPTZ NOT NULL,
    summary                  JSONB NOT NULL,
    models                   JSONB NOT NULL,
    providers                JSONB NOT NULL
);

INSERT INTO stats_components_health (component, generated_at, last_ok_at)
VALUES ('routability', 'epoch'::timestamptz, 'epoch'::timestamptz)
ON CONFLICT (component) DO NOTHING;

GRANT SELECT ON stats_routability_current TO stats_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON stats_routability_current TO stats_rollup;
REVOKE ALL ON stats_routability_current FROM provider_portal;
REVOKE ALL ON stats_routability_current FROM rewards_writer;
