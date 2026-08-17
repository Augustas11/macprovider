-- SPEC-021 v0.2.0 — verified useful-work MALIBU reward source.
-- Keeps v0.1 bootstrap rows readable while adding an idempotent source
-- reference for settlement-derived reward rows.

CREATE UNIQUE INDEX IF NOT EXISTS provider_rewards_ledger_malibu_external_ref_idx
    ON provider_rewards_ledger (external_ref)
    WHERE amount_malibu IS NOT NULL AND external_ref IS NOT NULL;

ALTER TABLE IF EXISTS ledger_request_credits
    ADD COLUMN IF NOT EXISTS settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy',
    ADD COLUMN IF NOT EXISTS spec022_verified BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
    IF to_regclass('public.ledger_request_credits') IS NOT NULL THEN
        UPDATE ledger_request_credits
           SET settlement_policy_mode = 'legacy'
         WHERE settlement_policy_mode IS NULL;

        UPDATE ledger_request_credits
           SET spec022_verified = FALSE
         WHERE spec022_verified IS NULL;

        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_settlement_policy_mode_enum') THEN
            ALTER TABLE ledger_request_credits
                ADD CONSTRAINT lrc_mirror_settlement_policy_mode_enum
                CHECK (settlement_policy_mode IN ('legacy','observe','enforce'));
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_spec022_verified_not_null') THEN
            ALTER TABLE ledger_request_credits
                ADD CONSTRAINT lrc_mirror_spec022_verified_not_null
                CHECK (spec022_verified IS NOT NULL);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_spec022_verified_enforce_check') THEN
            ALTER TABLE ledger_request_credits
                ADD CONSTRAINT lrc_mirror_spec022_verified_enforce_check
                CHECK (spec022_verified = FALSE OR settlement_policy_mode = 'enforce');
        END IF;

        GRANT SELECT ON ledger_request_credits TO rewards_writer;
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS ledger_request_credit_spec022_verified_audit (
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    sqlite_lrc_id BIGINT,
    provider_credits BIGINT NOT NULL,
    settlement_policy_mode TEXT NOT NULL CHECK (settlement_policy_mode = 'enforce'),
    source TEXT NOT NULL DEFAULT 'stats_billing_mirror',
    mirrored_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (request_id, attempt_n, provider_id)
);

CREATE OR REPLACE FUNCTION stats_billing_mirror_upsert_request_credit(
    p_sqlite_lrc_id BIGINT,
    p_request_id TEXT,
    p_attempt_n INTEGER,
    p_provider_id TEXT,
    p_ts_utc TIMESTAMPTZ,
    p_created_at_utc TIMESTAMPTZ,
    p_updated_at_utc TIMESTAMPTZ,
    p_prompt_tokens BIGINT,
    p_completion_tokens BIGINT,
    p_estimated_completion_tokens BIGINT,
    p_usage_source TEXT,
    p_provider_credits BIGINT,
    p_fault_flag TEXT,
    p_quarantined BOOLEAN,
    p_settlement_policy_mode TEXT,
    p_spec022_verified BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_settlement_policy_mode TEXT := COALESCE(NULLIF(p_settlement_policy_mode, ''), 'legacy');
    v_spec022_verified BOOLEAN;
    v_was_spec022_verified BOOLEAN;
BEGIN
    IF v_settlement_policy_mode NOT IN ('legacy','observe','enforce') THEN
        RAISE EXCEPTION 'invalid settlement_policy_mode: %', v_settlement_policy_mode;
    END IF;

    v_spec022_verified :=
        v_settlement_policy_mode = 'enforce'
        AND COALESCE(p_spec022_verified, FALSE)
        AND COALESCE(p_provider_credits, 0) > 0
        AND NOT COALESCE(p_quarantined, FALSE);

    SELECT spec022_verified
      INTO v_was_spec022_verified
      FROM ledger_request_credits
     WHERE request_id = p_request_id
       AND attempt_n = p_attempt_n
       AND provider_id = p_provider_id
     FOR UPDATE;

    INSERT INTO ledger_request_credits (
        sqlite_lrc_id, request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
        prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
        provider_credits, fault_flag, quarantined, settlement_policy_mode, spec022_verified
    ) VALUES (
        p_sqlite_lrc_id, p_request_id, p_attempt_n, p_provider_id, p_ts_utc, p_created_at_utc, p_updated_at_utc,
        p_prompt_tokens, p_completion_tokens, p_estimated_completion_tokens, p_usage_source,
        p_provider_credits, p_fault_flag, COALESCE(p_quarantined, FALSE), v_settlement_policy_mode, v_spec022_verified
    )
    ON CONFLICT (request_id, attempt_n, provider_id) DO UPDATE SET
        sqlite_lrc_id = EXCLUDED.sqlite_lrc_id,
        ts_utc = EXCLUDED.ts_utc,
        created_at_utc = EXCLUDED.created_at_utc,
        updated_at_utc = EXCLUDED.updated_at_utc,
        prompt_tokens = EXCLUDED.prompt_tokens,
        completion_tokens = EXCLUDED.completion_tokens,
        estimated_completion_tokens = EXCLUDED.estimated_completion_tokens,
        usage_source = EXCLUDED.usage_source,
        provider_credits = EXCLUDED.provider_credits,
        fault_flag = EXCLUDED.fault_flag,
        quarantined = EXCLUDED.quarantined,
        settlement_policy_mode = EXCLUDED.settlement_policy_mode,
        spec022_verified = EXCLUDED.spec022_verified;

    IF v_spec022_verified AND NOT COALESCE(v_was_spec022_verified, FALSE) THEN
        INSERT INTO ledger_request_credit_spec022_verified_audit (
            request_id, attempt_n, provider_id, sqlite_lrc_id,
            provider_credits, settlement_policy_mode
        ) VALUES (
            p_request_id, p_attempt_n, p_provider_id, p_sqlite_lrc_id,
            p_provider_credits, v_settlement_policy_mode
        )
        ON CONFLICT (request_id, attempt_n, provider_id) DO NOTHING;
    END IF;
END;
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = 'stats_billing_mirror_upsert_request_credit'
           AND p.pronargs = 14
    ) THEN
        REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN) FROM PUBLIC;
    END IF;
    REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM PUBLIC;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
        REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) TO stats_billing_mirror_writer;
    END IF;
END
$$;
