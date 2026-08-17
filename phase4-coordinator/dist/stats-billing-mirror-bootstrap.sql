-- Bootstrap for the stats billing mirror sidecar.
--
-- Apply as the database owner/admin, then place a DSN for
-- stats_billing_mirror_writer in:
--   /etc/macprovider-stats/stats-billing-mirror.env
--
-- Create the login role with an operator-generated password before applying:
--   CREATE ROLE stats_billing_mirror_writer LOGIN PASSWORD '<generated-password>';

CREATE TABLE IF NOT EXISTS ledger_request_credits (
    id BIGSERIAL PRIMARY KEY,
    sqlite_lrc_id BIGINT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK (attempt_n >= 0),
    provider_id TEXT NOT NULL,
    ts_utc TIMESTAMPTZ NOT NULL,
    created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at_utc TIMESTAMPTZ,
    prompt_tokens BIGINT CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0),
    completion_tokens BIGINT CHECK (completion_tokens IS NULL OR completion_tokens >= 0),
    estimated_completion_tokens BIGINT CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0),
    usage_source TEXT NOT NULL DEFAULT 'provider_reported' CHECK (usage_source IN ('provider_reported','byte_estimated','null_error')),
    provider_credits BIGINT NOT NULL DEFAULT 0 CHECK (provider_credits >= 0),
    fault_flag TEXT NOT NULL DEFAULT 'none' CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error')),
    quarantined BOOLEAN NOT NULL DEFAULT FALSE,
    settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy' CHECK (settlement_policy_mode IN ('legacy','observe','enforce')),
    spec022_verified BOOLEAN NOT NULL DEFAULT FALSE
);
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS sqlite_lrc_id BIGINT;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS request_id TEXT;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS attempt_n INTEGER;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_id TEXT;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS ts_utc TIMESTAMPTZ;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS created_at_utc TIMESTAMPTZ DEFAULT now();
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS updated_at_utc TIMESTAMPTZ;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS prompt_tokens BIGINT;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS completion_tokens BIGINT;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS estimated_completion_tokens BIGINT;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS usage_source TEXT DEFAULT 'provider_reported';
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_credits BIGINT DEFAULT 0;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS fault_flag TEXT DEFAULT 'none';
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS quarantined BOOLEAN DEFAULT FALSE;
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS settlement_policy_mode TEXT DEFAULT 'legacy';
ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS spec022_verified BOOLEAN DEFAULT FALSE;

UPDATE ledger_request_credits SET settlement_policy_mode = 'legacy' WHERE settlement_policy_mode IS NULL;
UPDATE ledger_request_credits SET spec022_verified = FALSE WHERE spec022_verified IS NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_attempt_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_attempt_nonnegative CHECK (attempt_n >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_prompt_tokens_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_prompt_tokens_nonnegative CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_completion_tokens_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_completion_tokens_nonnegative CHECK (completion_tokens IS NULL OR completion_tokens >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_estimated_completion_tokens_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_estimated_completion_tokens_nonnegative CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_usage_source_enum') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_usage_source_enum CHECK (usage_source IN ('provider_reported','byte_estimated','null_error'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_provider_credits_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_provider_credits_nonnegative CHECK (provider_credits >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_fault_flag_enum') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_fault_flag_enum CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_settlement_policy_mode_enum') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_settlement_policy_mode_enum CHECK (settlement_policy_mode IN ('legacy','observe','enforce'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_spec022_verified_not_null') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_not_null CHECK (spec022_verified IS NOT NULL);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_spec022_verified_enforce_check') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_enforce_check CHECK (spec022_verified = FALSE OR settlement_policy_mode = 'enforce');
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_lrc_mirror_unique_attempt ON ledger_request_credits(request_id, attempt_n, provider_id);
CREATE INDEX IF NOT EXISTS idx_lrc_mirror_provider_ts ON ledger_request_credits(provider_id, ts_utc);

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

CREATE TABLE IF NOT EXISTS provider_tokens (
    id BIGSERIAL PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL DEFAULT '',
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ
);
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS token_prefix TEXT DEFAULT '';
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_id TEXT DEFAULT '';
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_name TEXT DEFAULT '';
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_tokens_one_active_per_provider
    ON provider_tokens(provider_id)
    WHERE revoked_at IS NULL AND provider_id <> '';

CREATE TABLE IF NOT EXISTS stats_billing_mirror_state (
    source TEXT PRIMARY KEY,
    last_request_credit_id BIGINT NOT NULL DEFAULT 0,
    sweep_after_request_credit_id BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE stats_billing_mirror_state ADD COLUMN IF NOT EXISTS sweep_after_request_credit_id BIGINT NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION stats_billing_mirror_load_state(p_source TEXT)
RETURNS TABLE(last_request_credit_id BIGINT, sweep_after_request_credit_id BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO stats_billing_mirror_state (source, last_request_credit_id, sweep_after_request_credit_id)
    VALUES (p_source, 0, 0)
    ON CONFLICT (source) DO NOTHING;

    SELECT s.last_request_credit_id, s.sweep_after_request_credit_id
      FROM stats_billing_mirror_state s
     WHERE s.source = p_source;
$$;

CREATE OR REPLACE FUNCTION stats_billing_mirror_save_state(p_source TEXT, p_last_request_credit_id BIGINT, p_sweep_after_request_credit_id BIGINT)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO stats_billing_mirror_state (source, last_request_credit_id, sweep_after_request_credit_id, updated_at)
    VALUES (p_source, p_last_request_credit_id, p_sweep_after_request_credit_id, now())
    ON CONFLICT (source) DO UPDATE SET
        last_request_credit_id = GREATEST(stats_billing_mirror_state.last_request_credit_id, EXCLUDED.last_request_credit_id),
        sweep_after_request_credit_id = EXCLUDED.sweep_after_request_credit_id,
        updated_at = EXCLUDED.updated_at;
$$;

CREATE OR REPLACE FUNCTION stats_billing_mirror_ensure_provider(
    p_token_hash TEXT,
    p_provider_id TEXT,
    p_provider_name TEXT,
    p_created_at TIMESTAMPTZ,
    p_last_used_at TIMESTAMPTZ
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
    SELECT p_token_hash, 'stats-mirror', p_provider_id, p_provider_name, p_created_at, p_last_used_at
    WHERE NOT EXISTS (
        SELECT 1 FROM provider_tokens WHERE provider_id = p_provider_id AND provider_id <> ''
    )
    ON CONFLICT (token_hash) DO UPDATE SET
        provider_id = EXCLUDED.provider_id,
        provider_name = EXCLUDED.provider_name,
        last_used_at = EXCLUDED.last_used_at;
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
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
        RAISE EXCEPTION 'create role stats_billing_mirror_writer with an operator-generated password before applying this bootstrap';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_rollup') THEN
        GRANT SELECT ON ledger_request_credits TO stats_rollup;
        GRANT SELECT ON provider_tokens TO stats_rollup;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewards_writer') THEN
        GRANT SELECT ON ledger_request_credits TO rewards_writer;
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO stats_billing_mirror_writer;
REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
REVOKE ALL ON provider_tokens FROM stats_billing_mirror_writer;
REVOKE ALL ON stats_billing_mirror_state FROM stats_billing_mirror_writer;
REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer;
REVOKE ALL ON FUNCTION stats_billing_mirror_load_state(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM PUBLIC;

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
END $$;

GRANT EXECUTE ON FUNCTION stats_billing_mirror_load_state(TEXT) TO stats_billing_mirror_writer;
GRANT EXECUTE ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) TO stats_billing_mirror_writer;
GRANT EXECUTE ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO stats_billing_mirror_writer;
GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) TO stats_billing_mirror_writer;
