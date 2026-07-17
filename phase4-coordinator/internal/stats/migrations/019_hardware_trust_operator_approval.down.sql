-- Operator rollback artifact for the durable operator hardware-trust approval
-- path (issue #582 PR1). The embedded migration runner intentionally applies
-- only *.up.sql; this file is validated by tests/runbooks and executed
-- manually by operators only during rollback.
--
-- FIX 4: the script is transactional (BEGIN/COMMIT + \set ON_ERROR_STOP on) so a
-- mid-script failure rolls the whole rollback back instead of leaving a
-- half-removed workflow, and it is re-runnable — every object-dependent step is
-- guarded (IF EXISTS on drops, column-existence and role-existence guards on the
-- REVOKE/DELETE steps) so a re-run after a partial or completed rollback is a
-- safe no-op rather than an error.
--
-- ROLLBACK SEQUENCING / BINARY COUPLING (operator, required): this script
-- restores migration 008's 2-column PRIMARY KEY (provider_id,
-- hardware_identity_hash). That schema is ONLY compatible with the pre-#582
-- stats-inventory-sync binary (2-column `ON CONFLICT`). It is INCOMPATIBLE with
-- the 3-column binary shipped by #582, which reconciles with `ON CONFLICT
-- (provider_id, hardware_identity_hash, source)` — running the 3-column binary
-- against this restored 2-column PK fails reconciliation. So schema rollback
-- MUST be paired with the matching binary swap: (1) stop + disable
-- stats-inventory-sync.timer / stats-inventory-sync.service, (2) run this
-- script, (3) restore the OLD 2-column stats-inventory-sync binary, (4) only
-- then re-enable the timer. Never run this rollback while the 3-column binary is
-- still enabled, and never re-enable the old 2-column binary while the 3-column
-- PK from the *.up.sql is still live.

\set ON_ERROR_STOP on

BEGIN;

-- FIX 4(a): demote BEFORE removing the operator_api roots. Any verified,
-- non-authoritative profile whose only active trust backing is an operator_api
-- root (no active source<>'operator_api' inventory root proves it) must be
-- unverified here; otherwise rollback would strand admission trusting a root
-- this script is about to DELETE. Mirrors applyTrustDemotions' proof join with
-- an added source<>'operator_api' filter. Guarded on the source column still
-- existing so a re-run after the column was already dropped is a no-op.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'hardware_verification_trust'
           AND column_name = 'source'
    ) THEN
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
                  AND t.source <> 'operator_api'
                  AND (t.expires_at IS NULL OR t.expires_at > now())
                WHERE j.status = 'verified'
                  AND j.provider_id = ph.provider_id
                  AND j.chip_normalized = ph.chip_normalized
                  AND j.unified_memory_gb = ph.unified_memory_gb
                  AND j.os_version = ph.macos_version
                  AND j.binary_version = ph.app_version
                  AND j.generated_at = ph.last_reported_at
           );

        -- Revoke operator-granted trust roots before the source column that
        -- distinguishes them disappears; otherwise rollback would strand
        -- un-revocable operator_api roots that the sync path
        -- (source='inventory'-scoped) can never reconcile away.
        DELETE FROM hardware_verification_trust WHERE source = 'operator_api';

        -- Restore migration 008's 2-column PRIMARY KEY
        -- (provider_id, hardware_identity_hash). 018 widened it to include source.
        -- DUPLICATE-RESOLUTION CHOICE: the DELETE above removed every operator_api
        -- row, leaving at most one row per (provider_id, hardware_identity_hash) —
        -- the inventory sync only ever writes a single source='inventory' row per
        -- tuple (its own upsert is keyed on the 3-column PK with a constant source),
        -- so the tuple is already unique on the 2-column key and the narrower PK
        -- re-adds cleanly with no further dedup needed. Drop the wider constraint,
        -- drop the source column (now free of PK dependency), then re-add the
        -- original 2-column key. Each step is guarded on the current constraint /
        -- column state so a re-run after a partial or completed rollback is a no-op.
        IF EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conname = 'hardware_verification_trust_pkey'
               AND conrelid = 'hardware_verification_trust'::regclass
        ) THEN
            ALTER TABLE hardware_verification_trust DROP CONSTRAINT hardware_verification_trust_pkey;
        END IF;
        ALTER TABLE hardware_verification_trust DROP COLUMN IF EXISTS source;
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conname = 'hardware_verification_trust_pkey'
               AND conrelid = 'hardware_verification_trust'::regclass
        ) THEN
            ALTER TABLE hardware_verification_trust ADD PRIMARY KEY (provider_id, hardware_identity_hash);
        END IF;
    END IF;
END
$$;

-- Drop the workflow functions and tables (IF EXISTS → re-runnable). Dropping
-- them also removes every grant on them, so the surviving-object REVOKEs below
-- only need to touch tables/columns/schema that persist past rollback.
DROP FUNCTION IF EXISTS revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS approve_hardware_trust_approval(UUID, TEXT);
DROP FUNCTION IF EXISTS request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT);
DROP TABLE IF EXISTS hardware_trust_grants;
DROP TABLE IF EXISTS hardware_trust_pending;

-- Surviving-object grant cleanup, guarded on grantee-role existence so the
-- script is re-runnable (REVOKE has no IF EXISTS for its grantee role). These
-- revokes are also REQUIRED before DROP ROLE: a role holding any privilege on a
-- surviving object cannot be dropped. 018 added the chip column grant and the
-- read-only hardware_verification_trust SELECT grant (FIX 4 admission re-check)
-- to provider_onboarding; decision_reason was granted by migration 015 and must
-- remain after this rollback.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'provider_onboarding') THEN
        REVOKE SELECT (chip) ON hardware_verification_jobs FROM provider_onboarding;
        -- FIX 4 (round-6): undo the admission re-check's read-only trust grant.
        REVOKE SELECT ON hardware_verification_trust FROM provider_onboarding;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_definer') THEN
        REVOKE UPDATE (status) ON hardware_verification_jobs FROM hardware_trust_definer;
        REVOKE SELECT (id, provider_id, status, chip_normalized, unified_memory_gb, os_version, binary_version, generated_at, evidence, decision_reason) ON hardware_verification_jobs FROM hardware_trust_definer;
        REVOKE UPDATE (verified) ON provider_hardware_profiles FROM hardware_trust_definer;
        REVOKE SELECT (provider_id, chip_normalized, unified_memory_gb, macos_version, app_version, last_reported_at, source, verified) ON provider_hardware_profiles FROM hardware_trust_definer;
        -- FIX 3 (round-8): undo the chip-profile existence-check read grant.
        REVOKE SELECT (chip_normalized) ON chip_hardware_profiles FROM hardware_trust_definer;
        REVOKE ALL ON hardware_verification_trust FROM hardware_trust_definer;
        REVOKE USAGE, CREATE ON SCHEMA public FROM hardware_trust_definer;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_requester') THEN
        REVOKE USAGE ON SCHEMA public FROM hardware_trust_requester;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hardware_trust_approver') THEN
        REVOKE USAGE ON SCHEMA public FROM hardware_trust_approver;
    END IF;
END
$$;

DROP ROLE IF EXISTS hardware_trust_approver;
DROP ROLE IF EXISTS hardware_trust_requester;
DROP ROLE IF EXISTS hardware_trust_definer;

-- FIX 1 (issue #582): 018 replaced the profile-promotion guard forward to compare
-- the backing trust root with clock_timestamp() instead of the frozen now().
-- Restore migration 016's guard body (now()) so rollback returns the trigger to
-- its exact pre-018 definition. Re-applying 018 re-installs the clock_timestamp()
-- fix.
CREATE OR REPLACE FUNCTION provider_hardware_profiles_guard_verification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_user = 'provider_onboarding' THEN
        IF TG_OP = 'INSERT' THEN
            NEW.verified := FALSE;
        ELSIF NEW.chip_normalized IS DISTINCT FROM OLD.chip_normalized
           OR NEW.unified_memory_gb IS DISTINCT FROM OLD.unified_memory_gb THEN
            NEW.verified := FALSE;
        ELSE
            NEW.verified := OLD.verified;
        END IF;

        RETURN NEW;
    END IF;

    IF current_user = 'stats_hardware_verifier' THEN
        IF TG_OP = 'UPDATE' AND NEW.last_reported_at < OLD.last_reported_at THEN
            RAISE EXCEPTION 'stats_hardware_verifier may not move hardware profile timestamps backward';
        END IF;

        IF NEW.verified IS DISTINCT FROM TRUE THEN
            RAISE EXCEPTION 'stats_hardware_verifier may only promote verified hardware profiles';
        END IF;

        IF NOT EXISTS (
            SELECT 1
              FROM hardware_verification_jobs j
              JOIN hardware_verification_trust t
                ON t.provider_id = j.provider_id
               AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
               AND t.chip_normalized = j.chip_normalized
               AND t.unified_memory_gb = j.unified_memory_gb
               AND (t.expires_at IS NULL OR t.expires_at > now())
              JOIN chip_hardware_profiles ch
                ON ch.chip_normalized = j.chip_normalized
             WHERE j.provider_id = NEW.provider_id
               AND j.chip_normalized = NEW.chip_normalized
               AND j.unified_memory_gb = NEW.unified_memory_gb
               AND j.os_version = NEW.macos_version
               AND j.binary_version = NEW.app_version
               AND j.generated_at = NEW.last_reported_at
               AND j.generated_at >= now() - interval '7 days'
               AND j.status IN ('pending', 'waiting_trust')
               AND j.benchmark_count > 0
               AND j.max_sustained_tps > 0
               AND COALESCE(j.evidence #>> '{hardware,hardware_identity_hash}', '') <> ''
        ) THEN
            RAISE EXCEPTION 'stats_hardware_verifier promotion requires matching trusted hardware evidence';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION provider_hardware_profiles_guard_verification() FROM PUBLIC;

-- (issue #582): remove 019's recorded row from the SPEC-017 version table
-- (schema_migrations_spec017, the table the embedded runner in
-- internal/stats/migrations/migrations.go tracks). The runner applies only
-- *.up.sql and skips any version already present, so without this DELETE a
-- rollback would leave version 19 recorded as applied while the feature is gone —
-- a subsequent `migrate` would never re-apply 019. Scoped to the transaction so a
-- mid-script failure rolls it back with the rest of the rollback. NOTE: scoped to
-- version 19 only — must never touch version 18 (018_apptrack_register_attempts).
DELETE FROM schema_migrations_spec017 WHERE version = 19;

COMMIT;
