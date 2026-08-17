-- SPEC-021 v0.3.0 — append-only MALIBU reward audit events.

CREATE TABLE IF NOT EXISTS malibu_reward_audit_events (
    id                     BIGSERIAL PRIMARY KEY,
    provider_id            TEXT NOT NULL,
    occurred_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type             TEXT NOT NULL CHECK (event_type IN (
                               'malibu_accrual_inserted',
                               'malibu_hold_applied',
                               'malibu_hold_cleared',
                               'wallet_daily_cap_applied',
                               'wallet_bind_projected',
                               'trust_tier_promoted',
                               'trust_tier_demoted',
                               'withdrawal_candidate_selected',
                               'withdrawal_candidate_skipped',
                               'eligibility_reason_changed'
                           )),
    ledger_id              BIGINT NULL REFERENCES provider_rewards_ledger(id),
    amount_malibu          NUMERIC(24,8) NULL CHECK (amount_malibu IS NULL OR amount_malibu >= 0),
    withdrawal_hold_reason TEXT NULL CHECK (
                               withdrawal_hold_reason IS NULL
                               OR withdrawal_hold_reason IN (
                                   'trust_tier_provisional',
                                   'per_wallet_daily_cap',
                                   'demotion_cooldown'
                               )
                           ),
    trust_tier             TEXT NULL CHECK (trust_tier IS NULL OR trust_tier IN ('provisional', 'trusted')),
    source_reason          TEXT NULL,
    safe_summary           TEXT NOT NULL,
    operator_correlation   JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS malibu_reward_audit_events_provider_id_idx
    ON malibu_reward_audit_events (provider_id, id DESC);

CREATE INDEX IF NOT EXISTS malibu_reward_audit_events_ledger_id_idx
    ON malibu_reward_audit_events (ledger_id)
    WHERE ledger_id IS NOT NULL;

GRANT SELECT, INSERT ON malibu_reward_audit_events TO rewards_writer;
GRANT USAGE, SELECT ON SEQUENCE malibu_reward_audit_events_id_seq TO rewards_writer;

-- Append-only by grant: rewards_writer intentionally receives no UPDATE,
-- DELETE, TRUNCATE, or DDL privilege on the audit table.
