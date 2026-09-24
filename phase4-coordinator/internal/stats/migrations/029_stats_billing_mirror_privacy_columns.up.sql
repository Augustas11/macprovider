-- Keep the deployed stats-billing-mirror binary and Postgres writer contract
-- in lockstep. The binary has carried these four exclusion/privacy fields
-- since the September useful-work settlement rollout and calls the upsert
-- function with 20 arguments. Migration 022 installed the earlier 16-argument
-- function, so upgrading deployments need this forward migration rather than
-- a rewrite of already-recorded migration history.

ALTER TABLE IF EXISTS ledger_request_credits
    ADD COLUMN IF NOT EXISTS requested_privacy_mode TEXT DEFAULT 'none',
    ADD COLUMN IF NOT EXISTS effective_privacy_outcome TEXT DEFAULT 'plaintext',
    ADD COLUMN IF NOT EXISTS positive_verification_excluded BOOLEAN DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS rewards_excluded BOOLEAN DEFAULT FALSE;

DO $$
BEGIN
    IF to_regclass('public.ledger_request_credits') IS NOT NULL THEN
        UPDATE ledger_request_credits
           SET requested_privacy_mode = 'none'
         WHERE requested_privacy_mode IS NULL;
        UPDATE ledger_request_credits
           SET effective_privacy_outcome = 'plaintext'
         WHERE effective_privacy_outcome IS NULL;
        UPDATE ledger_request_credits
           SET positive_verification_excluded = FALSE
         WHERE positive_verification_excluded IS NULL;
        UPDATE ledger_request_credits
           SET rewards_excluded = FALSE
         WHERE rewards_excluded IS NULL;

        ALTER TABLE ledger_request_credits
            ALTER COLUMN requested_privacy_mode SET DEFAULT 'none',
            ALTER COLUMN requested_privacy_mode SET NOT NULL,
            ALTER COLUMN effective_privacy_outcome SET DEFAULT 'plaintext',
            ALTER COLUMN effective_privacy_outcome SET NOT NULL,
            ALTER COLUMN positive_verification_excluded SET DEFAULT FALSE,
            ALTER COLUMN positive_verification_excluded SET NOT NULL,
            ALTER COLUMN rewards_excluded SET DEFAULT FALSE,
            ALTER COLUMN rewards_excluded SET NOT NULL;
    END IF;
END
$$;

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
    p_spec022_verified BOOLEAN,
    p_requested_privacy_mode TEXT,
    p_effective_privacy_outcome TEXT,
    p_positive_verification_excluded BOOLEAN,
    p_rewards_excluded BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
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
        provider_credits, fault_flag, quarantined, settlement_policy_mode, spec022_verified,
        requested_privacy_mode, effective_privacy_outcome, positive_verification_excluded, rewards_excluded
    ) VALUES (
        p_sqlite_lrc_id, p_request_id, p_attempt_n, p_provider_id, p_ts_utc, p_created_at_utc, p_updated_at_utc,
        p_prompt_tokens, p_completion_tokens, p_estimated_completion_tokens, p_usage_source,
        p_provider_credits, p_fault_flag, COALESCE(p_quarantined, FALSE), v_settlement_policy_mode, v_spec022_verified,
        COALESCE(NULLIF(p_requested_privacy_mode, ''), 'none'), COALESCE(NULLIF(p_effective_privacy_outcome, ''), 'plaintext'),
        COALESCE(p_positive_verification_excluded, FALSE), COALESCE(p_rewards_excluded, FALSE)
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
        spec022_verified = EXCLUDED.spec022_verified,
        requested_privacy_mode = EXCLUDED.requested_privacy_mode,
        effective_privacy_outcome = EXCLUDED.effective_privacy_outcome,
        positive_verification_excluded = EXCLUDED.positive_verification_excluded,
        rewards_excluded = EXCLUDED.rewards_excluded;

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
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
            REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN) FROM stats_billing_mirror_writer;
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = 'stats_billing_mirror_upsert_request_credit'
           AND p.pronargs = 16
    ) THEN
        REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM PUBLIC;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
            REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM stats_billing_mirror_writer;
        END IF;
    END IF;
    REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) FROM PUBLIC;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
        REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) TO stats_billing_mirror_writer;
    END IF;
END
$$;
