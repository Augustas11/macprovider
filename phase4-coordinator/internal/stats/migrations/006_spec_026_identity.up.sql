-- SPEC-026 v0.11 Phase 1a schema (§10 step 1).
-- Adds three tables backing App-track provider onboarding:
--   * provider_identities         — App-track identity + App Attest state
--   * provider_auth_policy        — cross-track WS proof-stage auth allowlist
--   * provider_auth_policy_pending — dual-approval workflow for admin exemptions
--
-- These live on the coordinator's Postgres stats DB. The money-path
-- provider_tokens table (SQLite, phase4-coordinator/internal/auth/tokens.go:248)
-- is unchanged; the mint transaction in SPEC-026 §4.1 step 7 needs to
-- coordinate across both DBs — implementer follows BUILD prompt.

CREATE TABLE IF NOT EXISTS provider_identities (
    provider_id       TEXT PRIMARY KEY,
    identity_pubkey   BYTEA NOT NULL,
    attested          BOOLEAN NOT NULL DEFAULT FALSE,
    app_attest_key_id BYTEA NULL UNIQUE,
    first_seen_ts     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_provider_identities_first_seen
    ON provider_identities(first_seen_ts);

-- Cross-track: rows for BOTH `p_`-prefixed App-track and CLI-track opaque IDs.
CREATE TABLE IF NOT EXISTS provider_auth_policy (
    provider_id             TEXT PRIMARY KEY,
    kind                    TEXT NOT NULL CHECK (kind IN ('app', 'cli')),
    signature_exempt_until  TIMESTAMPTZ NULL,
    granted_by              TEXT NOT NULL,
    granted_reason          TEXT NOT NULL,
    granted_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_provider_auth_policy_exempt_until
    ON provider_auth_policy(signature_exempt_until)
    WHERE signature_exempt_until IS NOT NULL;

-- Dual-approval workflow. Empty until an operator issues an exemption grant.
CREATE TABLE IF NOT EXISTS provider_auth_policy_pending (
    pending_id       UUID PRIMARY KEY,
    provider_id      TEXT NOT NULL,
    requested_by     TEXT NOT NULL,
    requested_until  TIMESTAMPTZ NOT NULL,
    reason           TEXT NOT NULL,
    incident_id      TEXT NULL,
    approved_by      TEXT NULL,
    approved_at      TIMESTAMPTZ NULL,
    committed_at     TIMESTAMPTZ NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (approved_by IS NULL OR approved_by <> requested_by)
);

CREATE INDEX IF NOT EXISTS idx_provider_auth_policy_pending_provider_id
    ON provider_auth_policy_pending(provider_id);

CREATE INDEX IF NOT EXISTS idx_provider_auth_policy_pending_committed
    ON provider_auth_policy_pending(committed_at)
    WHERE committed_at IS NULL;
