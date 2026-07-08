-- SPEC-MALIBU-EMISSION-LEDGER v0.1.0 — MALIBU bootstrap emission schema.
-- Extends provider_rewards_ledger; adds cap aggregate, per-provider state,
-- payout-address projection, and rewards_writer role.

-- ===== provider_rewards_ledger MALIBU extension =====
ALTER TABLE provider_rewards_ledger
    ALTER COLUMN amount_usd DROP NOT NULL;

ALTER TABLE provider_rewards_ledger
    ADD COLUMN IF NOT EXISTS amount_malibu NUMERIC(24,8) NULL,
    ADD COLUMN IF NOT EXISTS withdrawal_hold_reason TEXT NULL;

ALTER TABLE provider_rewards_ledger
    DROP CONSTRAINT IF EXISTS provider_rewards_ledger_amount_check;

ALTER TABLE provider_rewards_ledger
    ADD CONSTRAINT provider_rewards_ledger_amount_check
    CHECK (amount_usd IS NOT NULL OR amount_malibu IS NOT NULL);

ALTER TABLE provider_rewards_ledger
    DROP CONSTRAINT IF EXISTS provider_rewards_ledger_hold_reason_check;

ALTER TABLE provider_rewards_ledger
    ADD CONSTRAINT provider_rewards_ledger_hold_reason_check
    CHECK (
        withdrawal_hold_reason IS NULL
        OR withdrawal_hold_reason IN (
            'trust_tier_provisional',
            'per_wallet_daily_cap',
            'demotion_cooldown'
        )
    );

CREATE INDEX IF NOT EXISTS provider_rewards_ledger_malibu_pid_ts_idx
    ON provider_rewards_ledger (provider_id, unix_ts)
    WHERE amount_malibu IS NOT NULL;

CREATE INDEX IF NOT EXISTS provider_rewards_ledger_withdrawable_malibu_idx
    ON provider_rewards_ledger (provider_id)
    WHERE amount_malibu IS NOT NULL AND withdrawal_hold_reason IS NULL;

-- ===== wallet_daily_malibu_emission aggregate =====
CREATE TABLE IF NOT EXISTS wallet_daily_malibu_emission (
    bound_wallet  TEXT NOT NULL,
    emission_day  DATE NOT NULL,
    sum_malibu    NUMERIC(24,8) NOT NULL DEFAULT 0 CHECK (sum_malibu >= 0),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bound_wallet, emission_day)
);

-- ===== provider_emission_state cross-track =====
CREATE TABLE IF NOT EXISTS provider_emission_state (
    provider_id             TEXT PRIMARY KEY,
    trust_tier              TEXT NOT NULL DEFAULT 'provisional'
                            CHECK (trust_tier IN ('provisional', 'trusted')),
    bound_wallet            TEXT NULL,
    cap_replay_pending      BOOLEAN NOT NULL DEFAULT FALSE,
    provider_day_malibu     NUMERIC(24,8) NOT NULL DEFAULT 0 CHECK (provider_day_malibu >= 0),
    emission_day            DATE NULL,
    demotion_cooldown_until TIMESTAMPTZ NULL,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS provider_emission_state_wallet_idx
    ON provider_emission_state (bound_wallet)
    WHERE bound_wallet IS NOT NULL;

CREATE INDEX IF NOT EXISTS provider_emission_state_cap_replay_idx
    ON provider_emission_state (cap_replay_pending)
    WHERE cap_replay_pending = TRUE;

-- ===== SPEC-016 payout address Postgres projection =====
CREATE TABLE IF NOT EXISTS provider_payout_addresses_proj (
    provider_id       TEXT NOT NULL,
    chain             TEXT NOT NULL CHECK (chain = 'base-mainnet'),
    address           TEXT NOT NULL,
    payout_allowed    INTEGER NOT NULL DEFAULT 1 CHECK (payout_allowed IN (0, 1)),
    registered_at_utc TIMESTAMPTZ NOT NULL,
    source_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider_id, chain)
);

CREATE INDEX IF NOT EXISTS provider_payout_addresses_proj_address_idx
    ON provider_payout_addresses_proj (address);

-- ===== rewards_writer role =====
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewards_writer') THEN
        CREATE ROLE rewards_writer NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO rewards_writer;

GRANT SELECT, INSERT ON provider_rewards_ledger TO rewards_writer;
GRANT USAGE, SELECT ON SEQUENCE provider_rewards_ledger_id_seq TO rewards_writer;

GRANT SELECT, INSERT, UPDATE ON wallet_daily_malibu_emission TO rewards_writer;
GRANT SELECT, INSERT, UPDATE ON provider_emission_state TO rewards_writer;
GRANT SELECT, INSERT, UPDATE ON provider_payout_addresses_proj TO rewards_writer;
GRANT SELECT ON provider_identities TO rewards_writer;

-- Explicit denies: rewards_writer must not touch rollup internals or partner keys.
REVOKE ALL ON
    stats_overview_current,
    stats_timeseries_rpm_30m,
    stats_timeseries_tpm_30m,
    stats_leaderboard_24h,
    stats_leaderboard_7d,
    stats_leaderboard_30d,
    stats_leaderboard_all,
    stats_components_health,
    stats_late_events,
    stats_rewards_populated,
    partner_keys,
    provider_visibility,
    provider_visibility_audit
FROM rewards_writer;

-- stats_rollup keeps SELECT-only on provider_rewards_ledger (unchanged from 004).
