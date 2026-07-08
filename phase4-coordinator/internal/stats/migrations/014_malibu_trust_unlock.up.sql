-- SPEC-MALIBU-EMISSION-LEDGER Phase C2 — Trusted unlock evaluation state.
-- Tracks continuous criterion windows and operator dual-control promotions (E3).

CREATE TABLE IF NOT EXISTS provider_trust_eval_state (
    provider_id              TEXT PRIMARY KEY,
    uptime_ok_since          TIMESTAMPTZ NULL,
    wallet_balance_ok_since  TIMESTAMPTZ NULL,
    unlock_pair_ok_since     TIMESTAMPTZ NULL,
    last_balance_usdc_micro  BIGINT NULL,
    last_balance_check_at    TIMESTAMPTZ NULL,
    last_eval_at             TIMESTAMPTZ NULL,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS provider_trust_promotion_pending (
    pending_id    UUID PRIMARY KEY,
    provider_id   TEXT NOT NULL,
    requested_by  TEXT NOT NULL,
    reason        TEXT NOT NULL,
    incident_id   TEXT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    committed_at  TIMESTAMPTZ NULL,
    approved_by   TEXT NULL,
    status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'committed', 'rejected'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_trust_promotion_pending_open
    ON provider_trust_promotion_pending (provider_id)
    WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS provider_trust_operator_promotions (
    provider_id   TEXT PRIMARY KEY,
    promoted_by   TEXT NOT NULL,
    reason        TEXT NOT NULL,
    pending_id    UUID NOT NULL,
    promoted_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE ON provider_trust_eval_state TO rewards_writer;
GRANT SELECT, INSERT, UPDATE ON provider_trust_promotion_pending TO rewards_writer;
GRANT SELECT, INSERT, UPDATE ON provider_trust_operator_promotions TO rewards_writer;
