-- Issue #1880 / SPEC-033 v0.7.0 §5.7 (SPEC-033-R002) — automatic trust for
-- attested hardware.
--
-- Operator decision 2026-10-10: hardware whose attestation the coordinator has
-- already verified is trusted without operator approval; the migration-019
-- dual-control path stays for hardware without a verified attestation.
--
-- "Verified attestation" is a row in provider_app_attest_verifications. The
-- onboarding app-track register handler writes it only after
-- AppleAppAttestVerifier.Verify succeeds (SPEC-026 §5.3), and only through the
-- separate app_attest_recorder role. provider_onboarding cannot write it, so a
-- compromise of the network-facing onboarding role cannot fabricate an
-- attestation (provider_identities.attested, which onboarding can write, is
-- not read). Rows are insert-only: first verification per provider and per
-- key wins.
--
-- The only writer of source='app_attest' trust roots is
-- auto_trust_attested_hardware(job_id), a SECURITY DEFINER function owned by
-- hardware_trust_definer and executable only by stats_hardware_verifier, which
-- calls it inside its batch transaction for a job whose Evaluate result is
-- missing_trusted_hardware_identity. provider_onboarding gains no trust write
-- path and no EXECUTE.
--
-- The trust root has no expiry. Each newly created root is ledgered once in
-- hardware_trust_grants (grant_source='app_attest') with the bound job, the
-- job's evidence digest, and a digest of the App Attest key id. An existing
-- app_attest row is never updated, so an operator revoke (which expires it)
-- sticks. Any recorded action='revoke' grant for the provider, whatever
-- hardware hash it named, blocks automatic trust for that attested device
-- permanently: the hash is self-reported, the provider identity is the one
-- bound to the App Attest key. Only dual-control approval can trust it again.
--
-- No primary-key change: unlike 019, this migration carries no
-- stats-inventory-sync deploy sequencing constraint.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_attest_recorder') THEN
        CREATE ROLE app_attest_recorder NOLOGIN;
    END IF;
    ALTER ROLE app_attest_recorder NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
END
$$;

CREATE TABLE IF NOT EXISTS provider_app_attest_verifications (
    provider_id       TEXT PRIMARY KEY,
    app_attest_key_id BYTEA NOT NULL UNIQUE CHECK (octet_length(app_attest_key_id) = 32),
    verified_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

REVOKE ALL ON provider_app_attest_verifications FROM PUBLIC;
REVOKE ALL ON provider_app_attest_verifications FROM provider_onboarding;
GRANT USAGE ON SCHEMA public TO app_attest_recorder;
GRANT SELECT, INSERT ON provider_app_attest_verifications TO app_attest_recorder;

ALTER TABLE hardware_verification_trust
    DROP CONSTRAINT IF EXISTS hardware_verification_trust_source_check;
ALTER TABLE hardware_verification_trust
    ADD CONSTRAINT hardware_verification_trust_source_check
        CHECK (source IN ('inventory', 'operator_api', 'app_attest'));

ALTER TABLE hardware_trust_grants
    DROP CONSTRAINT IF EXISTS hardware_trust_grants_grant_source_check;
ALTER TABLE hardware_trust_grants
    ADD CONSTRAINT hardware_trust_grants_grant_source_check
        CHECK (grant_source IN ('operator', 'app_attest'));

ALTER TABLE hardware_trust_grants ADD COLUMN IF NOT EXISTS job_id BIGINT NULL;
ALTER TABLE hardware_trust_grants ADD COLUMN IF NOT EXISTS evidence_sha256 TEXT NULL;
ALTER TABLE hardware_trust_grants ADD COLUMN IF NOT EXISTS attestation_basis TEXT NULL;
ALTER TABLE hardware_trust_grants ADD COLUMN IF NOT EXISTS attestation_digest TEXT NULL;

-- One automatic grant row per hardware identity: a re-run of the verifier, or a
-- later job for the same hardware, never writes a second audit row.
CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_grants_app_attest_identity
    ON hardware_trust_grants(provider_id, hardware_identity_hash)
    WHERE action = 'grant' AND grant_source = 'app_attest';

CREATE OR REPLACE FUNCTION auto_trust_attested_hardware(p_job_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_provider TEXT;
    v_locked BOOLEAN;
    job RECORD;
    v_key_id BYTEA;
    v_now TIMESTAMPTZ;
    v_inserted INT;
BEGIN
    IF p_job_id IS NULL OR p_job_id <= 0 THEN
        RETURN FALSE;
    END IF;

    SELECT j.provider_id INTO v_provider
      FROM hardware_verification_jobs j
     WHERE j.id = p_job_id
       AND j.status IN ('pending', 'waiting_trust');
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Same key as the 019 request/approve/revoke functions and the verifier's
    -- promoteJob. NON-blocking: the caller already holds the job row FOR UPDATE,
    -- while approve/revoke take this advisory lock first and the job row second;
    -- a blocking wait here would close that cycle into a deadlock. When the lock
    -- is held the job simply stays parked and is retried on the next timer run.
    -- Advisory locks are re-entrant per session, so promoteJob's later try-lock
    -- in the same transaction still succeeds.
    SELECT pg_try_advisory_xact_lock(582026, hashtext(v_provider)) INTO v_locked;
    IF NOT v_locked THEN
        RETURN FALSE;
    END IF;

    SELECT j.provider_id AS provider_id,
           j.chip_normalized AS chip_normalized,
           j.unified_memory_gb AS unified_memory_gb,
           j.evidence_sha256 AS evidence_sha256,
           NULLIF(BTRIM(COALESCE(j.evidence #>> '{hardware,hardware_identity_hash}', '')), '') AS hardware_identity_hash
      INTO job
      FROM hardware_verification_jobs j
     WHERE j.id = p_job_id
       AND j.status IN ('pending', 'waiting_trust')
     FOR SHARE;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    IF job.hardware_identity_hash IS NULL OR job.hardware_identity_hash !~ '^[0-9a-f]{64}$' THEN
        RETURN FALSE;
    END IF;
    IF NULLIF(BTRIM(COALESCE(job.chip_normalized, '')), '') IS NULL THEN
        RETURN FALSE;
    END IF;

    SELECT v.app_attest_key_id INTO v_key_id
      FROM provider_app_attest_verifications v
     WHERE v.provider_id = job.provider_id;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- An operator revoke is final for the automatic path for this attested
    -- device, under any hardware hash it reports later.
    IF EXISTS (
        SELECT 1
          FROM hardware_trust_grants g
         WHERE g.provider_id = job.provider_id
           AND g.action = 'revoke'
    ) THEN
        RETURN FALSE;
    END IF;

    v_now := clock_timestamp();

    INSERT INTO hardware_verification_trust (
        provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb,
        trusted_by, trusted_at, expires_at, notes, source
    ) VALUES (
        job.provider_id,
        job.hardware_identity_hash,
        job.chip_normalized,
        job.unified_memory_gb,
        'system:app_attest',
        v_now,
        NULL,
        'automatic: provider identity verified by Apple App Attest (SPEC-033 R002)',
        'app_attest'
    )
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 1 THEN
        INSERT INTO hardware_trust_grants (
            grant_id, pending_id, provider_id, hardware_identity_hash, chip_normalized,
            unified_memory_gb, action, grant_source, requested_by, approved_by,
            requested_until, reason, incident_id, granted_at,
            job_id, evidence_sha256, attestation_basis, attestation_digest
        ) VALUES (
            gen_random_uuid(),
            NULL,
            job.provider_id,
            job.hardware_identity_hash,
            job.chip_normalized,
            job.unified_memory_gb,
            'grant',
            'app_attest',
            'system:app_attest',
            'system:app_attest',
            NULL,
            'automatic trust: hardware evidence passed every verifier gate and the provider identity is App Attest verified',
            NULL,
            v_now,
            p_job_id,
            job.evidence_sha256,
            'apple_app_attest',
            encode(sha256(v_key_id), 'hex')
        )
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN EXISTS (
        SELECT 1
          FROM hardware_verification_trust t
         WHERE t.provider_id = job.provider_id
           AND t.hardware_identity_hash = job.hardware_identity_hash
           AND t.chip_normalized = job.chip_normalized
           AND t.unified_memory_gb = job.unified_memory_gb
           AND t.source = 'app_attest'
           AND (t.expires_at IS NULL OR t.expires_at > v_now)
    );
END;
$$;

-- Revoke now covers both operator-revocable sources: the dual-control
-- operator_api root and the automatic app_attest root. The body is the 019
-- function with the source predicate widened; the UPDATE runs in a CTE because
-- it can now expire two rows and PL/pgSQL rejects a multi-row RETURNING INTO.
-- The signature and output columns are unchanged.
CREATE OR REPLACE FUNCTION revoke_hardware_trust_approval(
    p_grant_id UUID,
    p_provider_id TEXT,
    p_hardware_identity_hash TEXT,
    p_revoked_by TEXT,
    p_reason TEXT
)
RETURNS TABLE (
    out_provider_id TEXT,
    out_hardware_identity_hash TEXT,
    out_chip_normalized TEXT,
    out_unified_memory_gb INT,
    out_now_untrusted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    revoke_time TIMESTAMPTZ;
    revoked RECORD;
    now_untrusted BOOLEAN;
BEGIN
    IF p_grant_id IS NULL THEN
        RAISE EXCEPTION 'grant_id is required';
    END IF;
    IF NULLIF(BTRIM(p_provider_id), '') IS NULL THEN
        RAISE EXCEPTION 'provider_id is required';
    END IF;
    IF NULLIF(BTRIM(p_hardware_identity_hash), '') IS NULL THEN
        RAISE EXCEPTION 'hardware_identity_hash is required';
    END IF;
    IF p_revoked_by !~ '^operator:[^[:space:]]+$' THEN
        RAISE EXCEPTION 'revoked_by must use operator:<admin_id>';
    END IF;
    IF NULLIF(BTRIM(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'reason is required';
    END IF;

    PERFORM pg_advisory_xact_lock(582026, hashtext(BTRIM(p_provider_id)));

    revoke_time := clock_timestamp();

    WITH expired AS (
        UPDATE hardware_verification_trust t
           SET expires_at = revoke_time
         WHERE t.provider_id = BTRIM(p_provider_id)
           AND t.hardware_identity_hash = BTRIM(p_hardware_identity_hash)
           AND t.source IN ('operator_api', 'app_attest')
           AND (t.expires_at IS NULL OR t.expires_at > revoke_time)
        RETURNING t.chip_normalized, t.unified_memory_gb, t.source
    )
    SELECT e.chip_normalized, e.unified_memory_gb
      INTO revoked
      FROM expired e
     ORDER BY (e.source = 'operator_api') DESC
     LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'active operator_api trust root not found';
    END IF;

    INSERT INTO hardware_trust_grants (
        grant_id, pending_id, provider_id, hardware_identity_hash, chip_normalized,
        unified_memory_gb, action, requested_by, approved_by, requested_until, reason,
        incident_id, granted_at
    ) VALUES (
        p_grant_id,
        NULL,
        BTRIM(p_provider_id),
        BTRIM(p_hardware_identity_hash),
        revoked.chip_normalized,
        revoked.unified_memory_gb,
        'revoke',
        BTRIM(p_revoked_by),
        BTRIM(p_revoked_by),
        NULL,
        BTRIM(p_reason),
        NULL,
        revoke_time
    );

    UPDATE provider_hardware_profiles ph
       SET verified = FALSE
     WHERE ph.provider_id = BTRIM(p_provider_id)
       AND ph.verified = TRUE
       AND ph.source <> 'operator'
       AND NOT EXISTS (
           SELECT 1
             FROM hardware_verification_jobs j
             JOIN hardware_verification_trust t
               ON t.provider_id = j.provider_id
              AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
              AND t.chip_normalized = j.chip_normalized
              AND t.unified_memory_gb = j.unified_memory_gb
              AND (t.expires_at IS NULL OR t.expires_at > revoke_time)
            WHERE j.status = 'verified'
              AND j.provider_id = ph.provider_id
              AND j.chip_normalized = ph.chip_normalized
              AND j.unified_memory_gb = ph.unified_memory_gb
              AND j.os_version = ph.macos_version
              AND j.binary_version = ph.app_version
              AND j.generated_at = ph.last_reported_at
       );

    now_untrusted := NOT EXISTS (
        SELECT 1
          FROM hardware_verification_trust t
         WHERE t.provider_id = BTRIM(p_provider_id)
           AND t.hardware_identity_hash = BTRIM(p_hardware_identity_hash)
           AND t.chip_normalized = revoked.chip_normalized
           AND t.unified_memory_gb = revoked.unified_memory_gb
           AND (t.expires_at IS NULL OR t.expires_at > revoke_time)
    );

    RETURN QUERY SELECT
        BTRIM(p_provider_id),
        BTRIM(p_hardware_identity_hash),
        revoked.chip_normalized,
        revoked.unified_memory_gb,
        now_untrusted;
END;
$$;

-- The definer reads the attestation flag and the job's evidence digest.
GRANT SELECT ON provider_app_attest_verifications TO hardware_trust_definer;
GRANT SELECT (evidence_sha256) ON hardware_verification_jobs TO hardware_trust_definer;

-- ALTER ... OWNER requires CREATE on the schema for the new owner; grant it only
-- for the ownership change, matching 019.
GRANT USAGE, CREATE ON SCHEMA public TO hardware_trust_definer;
REVOKE ALL ON FUNCTION auto_trust_attested_hardware(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION auto_trust_attested_hardware(BIGINT) FROM provider_onboarding;
GRANT EXECUTE ON FUNCTION auto_trust_attested_hardware(BIGINT) TO stats_hardware_verifier;
ALTER FUNCTION auto_trust_attested_hardware(BIGINT) OWNER TO hardware_trust_definer;
REVOKE ALL ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) FROM provider_onboarding;
GRANT EXECUTE ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) TO hardware_trust_approver;
ALTER FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) OWNER TO hardware_trust_definer;
REVOKE CREATE ON SCHEMA public FROM hardware_trust_definer;
