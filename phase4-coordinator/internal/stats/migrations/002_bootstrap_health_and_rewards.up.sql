-- SPEC-017 v0.1.8 — bootstrap rows. The migration MUST seed these
-- so NOT NULL constraints on stats_components_health.generated_at /
-- last_ok_at hold even before the first rollup tick succeeds.
-- BUILD §A.9 + Step 2 "Bootstrap rule": all 7 component rows
-- pre-seeded at the epoch sentinel; /v1/stats/health derives
-- `status = "down"` until each component's first tick succeeds.
-- BUILD §9.1a: all 4 rewards_populated rows pre-seeded at `false`
-- (matches the v0.1 empty-ledger default).

INSERT INTO stats_components_health (component, generated_at, last_ok_at)
VALUES
    ('overview',         'epoch'::timestamptz, 'epoch'::timestamptz),
    ('timeseries_rpm',   'epoch'::timestamptz, 'epoch'::timestamptz),
    ('timeseries_tpm',   'epoch'::timestamptz, 'epoch'::timestamptz),
    ('leaderboard_24h',  'epoch'::timestamptz, 'epoch'::timestamptz),
    ('leaderboard_7d',   'epoch'::timestamptz, 'epoch'::timestamptz),
    ('leaderboard_30d',  'epoch'::timestamptz, 'epoch'::timestamptz),
    ('leaderboard_all',  'epoch'::timestamptz, 'epoch'::timestamptz)
ON CONFLICT (component) DO NOTHING;

INSERT INTO stats_rewards_populated (window_label, rewards_populated, generated_at)
VALUES
    ('24h', FALSE, 'epoch'::timestamptz),
    ('7d',  FALSE, 'epoch'::timestamptz),
    ('30d', FALSE, 'epoch'::timestamptz),
    ('all', FALSE, 'epoch'::timestamptz)
ON CONFLICT (window_label) DO NOTHING;
