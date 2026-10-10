-- Operator rollback artifact for migration 031 (SPEC-033 v0.7.0 automatic
-- trust for attested hardware). The embedded migration runner applies only
-- *.up.sql; run this manually, and before the 019 rollback artifact, which
-- cannot drop hardware_trust_definer while 031's function and grants exist.
--
-- It removes the automatic path and every app_attest trust root. Profiles whose
-- only active trust backing was an app_attest root are demoted first, so
-- admission never keeps trusting a root this script deletes. The
-- hardware_trust_grants audit rows, their four audit columns, the widened
-- grant_source CHECK and the app_attest grant index are retained on purpose:
-- they are history, and the 019 rollback drops that table anyway. The widened
-- revoke_hardware_trust_approval stays: with no app_attest rows left and the
-- source CHECK restored it behaves exactly like the 019 body.

\set ON_ERROR_STOP on

BEGIN;

UPDATE provider_hardware_profiles ph
   SET verified = FALSE
 WHERE ph.verified = TRUE
   AND ph.source <> 'operator'
   AND NOT EXISTS (
       SELECT 1
         FROM hardware_verification_jobs j
         JOIN hardware_verification_trust t
           ON t.provider_id = j.provider_id
          AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
          AND t.chip_normalized = j.chip_normalized
          AND t.unified_memory_gb = j.unified_memory_gb
          AND t.source <> 'app_attest'
          AND (t.expires_at IS NULL OR t.expires_at > now())
        WHERE j.status = 'verified'
          AND j.provider_id = ph.provider_id
          AND j.chip_normalized = ph.chip_normalized
          AND j.unified_memory_gb = ph.unified_memory_gb
          AND j.os_version = ph.macos_version
          AND j.binary_version = ph.app_version
          AND j.generated_at = ph.last_reported_at
   );

DELETE FROM hardware_verification_trust WHERE source = 'app_attest';

ALTER TABLE hardware_verification_trust
    DROP CONSTRAINT IF EXISTS hardware_verification_trust_source_check;
ALTER TABLE hardware_verification_trust
    ADD CONSTRAINT hardware_verification_trust_source_check
        CHECK (source IN ('inventory', 'operator_api'));

DROP FUNCTION IF EXISTS auto_trust_attested_hardware(BIGINT);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_definer') THEN
        REVOKE SELECT (provider_id, attested, app_attest_key_id) ON provider_identities FROM hardware_trust_definer;
        REVOKE SELECT (evidence_sha256) ON hardware_verification_jobs FROM hardware_trust_definer;
    END IF;
END $$;

DELETE FROM schema_migrations_spec017 WHERE version = 31;

COMMIT;
