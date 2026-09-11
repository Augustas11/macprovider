-- SPEC-017 v0.2.1 §5.2b — catalog-intake read model (BYOM v0.2 slice 5).
-- Widen the components_health CHECK for the new `intake` component, create
-- the singleton read model, seed its health row, and grant per §7.2.1/§7.2.2.

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
        'routability',
        'intake'
    ));

-- Aggregated counts only (SPEC-017 §5.2b.5): never a principal token, a
-- buyer account id, or a raw requested model string.
CREATE TABLE IF NOT EXISTS stats_intake_current (
    singleton                BOOLEAN PRIMARY KEY DEFAULT TRUE
                             CHECK (singleton = TRUE),
    generated_at             TIMESTAMPTZ NOT NULL,
    unmatched_models         JSONB NOT NULL,
    fleet_ram                JSONB NOT NULL
);

INSERT INTO stats_components_health (component, generated_at, last_ok_at)
VALUES ('intake', 'epoch'::timestamptz, 'epoch'::timestamptz)
ON CONFLICT (component) DO NOTHING;

GRANT SELECT ON stats_intake_current TO stats_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON stats_intake_current TO stats_rollup;
REVOKE ALL ON stats_intake_current FROM provider_portal;
REVOKE ALL ON stats_intake_current FROM rewards_writer;

-- SPEC-017 v0.2.1 §5.2b.6 / §7.2.2: the fleet histogram counts only
-- providers holding a hardware trust root active at the window end, so the
-- rollup role reads exactly the two columns that decide it — never the
-- hardware identity hash, chip, memory, or grantor recorded on the row.
GRANT SELECT (provider_id, expires_at) ON hardware_verification_trust TO stats_rollup;
