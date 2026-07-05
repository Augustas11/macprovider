-- Autotune hardware evidence queue and minimized verifier role.
--
-- provider_onboarding can queue authenticated evidence and refresh the
-- untrusted provider profile. stats_hardware_verifier can promote a row to
-- verified=true only when operator-managed trust and chip inventory rows exist.

CREATE TABLE IF NOT EXISTS hardware_verification_jobs (
    id                         BIGSERIAL PRIMARY KEY,
    provider_id                TEXT NOT NULL,
    source                     TEXT NOT NULL CHECK (source IN ('autotune')),
    status                     TEXT NOT NULL CHECK (status IN ('pending', 'waiting_trust', 'verified', 'rejected')) DEFAULT 'pending',
    chip                       TEXT NOT NULL,
    chip_normalized            TEXT NOT NULL,
    unified_memory_gb          INT NOT NULL CHECK (unified_memory_gb >= 0 AND unified_memory_gb <= 4096),
    bandwidth_tier             TEXT NOT NULL DEFAULT '',
    os_version                 TEXT NOT NULL DEFAULT '',
    binary_version             TEXT NOT NULL DEFAULT '',
    benchmark_count            INT NOT NULL DEFAULT 0 CHECK (benchmark_count >= 0 AND benchmark_count <= 64),
    max_sustained_tps          DOUBLE PRECISION NOT NULL DEFAULT 0 CHECK (max_sustained_tps >= 0),
    generated_at               TIMESTAMPTZ NOT NULL,
    submitted_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at               TIMESTAMPTZ NULL,
    decision_reason            TEXT NOT NULL DEFAULT '',
    evidence                   JSONB NOT NULL,
    evidence_sha256            TEXT NOT NULL UNIQUE
);

CREATE INDEX IF NOT EXISTS idx_hardware_verification_jobs_pending
    ON hardware_verification_jobs(id)
    WHERE status IN ('pending', 'waiting_trust');

CREATE INDEX IF NOT EXISTS idx_hardware_verification_jobs_provider_submitted
    ON hardware_verification_jobs(provider_id, submitted_at DESC);

CREATE TABLE IF NOT EXISTS hardware_verification_trust (
    provider_id                 TEXT NOT NULL,
    hardware_identity_hash      TEXT NOT NULL,
    chip_normalized             TEXT NOT NULL,
    unified_memory_gb           INT NOT NULL CHECK (unified_memory_gb >= 0 AND unified_memory_gb <= 4096),
    trusted_by                  TEXT NOT NULL,
    trusted_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at                  TIMESTAMPTZ NULL,
    notes                       TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (provider_id, hardware_identity_hash)
);

CREATE INDEX IF NOT EXISTS idx_hardware_verification_trust_active
    ON hardware_verification_trust(provider_id, hardware_identity_hash)
    WHERE expires_at IS NULL;

CREATE OR REPLACE FUNCTION provider_hardware_profiles_guard_verification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_user = 'provider_onboarding' THEN
        IF TG_OP = 'INSERT' THEN
            NEW.verified := FALSE;
        ELSIF NEW.chip_normalized IS DISTINCT FROM OLD.chip_normalized THEN
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

CREATE OR REPLACE FUNCTION hardware_verification_jobs_guard_verifier_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_user = 'stats_hardware_verifier' THEN
        IF OLD.status NOT IN ('pending', 'waiting_trust') THEN
            RAISE EXCEPTION 'stats_hardware_verifier may not update finalized hardware verification jobs';
        END IF;

        IF NEW.status NOT IN ('waiting_trust', 'verified', 'rejected') THEN
            RAISE EXCEPTION 'stats_hardware_verifier may only move jobs to waiting_trust, verified, or rejected';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hardware_verification_jobs_guard_verifier_update
    ON hardware_verification_jobs;

CREATE TRIGGER trg_hardware_verification_jobs_guard_verifier_update
BEFORE UPDATE ON hardware_verification_jobs
FOR EACH ROW
EXECUTE FUNCTION hardware_verification_jobs_guard_verifier_update();

REVOKE ALL ON FUNCTION hardware_verification_jobs_guard_verifier_update() FROM PUBLIC;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_hardware_verifier') THEN
        CREATE ROLE stats_hardware_verifier NOLOGIN;
    ELSE
        ALTER ROLE stats_hardware_verifier NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO stats_hardware_verifier;

REVOKE ALL ON
    hardware_verification_jobs,
    hardware_verification_trust
FROM stats_reader, provider_portal, stats_rollup, provider_onboarding, stats_hardware_verifier;

GRANT SELECT (
    id,
    provider_id,
    status,
    submitted_at,
    evidence_sha256
) ON hardware_verification_jobs TO provider_onboarding;
GRANT INSERT (
    provider_id,
    source,
    status,
    chip,
    chip_normalized,
    unified_memory_gb,
    bandwidth_tier,
    os_version,
    binary_version,
    benchmark_count,
    max_sustained_tps,
    generated_at,
    evidence,
    evidence_sha256
) ON hardware_verification_jobs TO provider_onboarding;
GRANT USAGE, SELECT ON SEQUENCE hardware_verification_jobs_id_seq TO provider_onboarding;

GRANT SELECT ON hardware_verification_jobs TO stats_hardware_verifier;
GRANT UPDATE (
    status,
    processed_at,
    decision_reason
) ON hardware_verification_jobs TO stats_hardware_verifier;
GRANT SELECT ON hardware_verification_trust TO stats_hardware_verifier;
GRANT SELECT ON provider_hardware_profiles TO stats_hardware_verifier;
GRANT INSERT (
    provider_id,
    chip,
    chip_normalized,
    unified_memory_gb,
    macos_version,
    app_version,
    source,
    verified,
    last_reported_at
) ON provider_hardware_profiles TO stats_hardware_verifier;
GRANT UPDATE (
    chip,
    chip_normalized,
    unified_memory_gb,
    macos_version,
    app_version,
    source,
    verified,
    last_reported_at
) ON provider_hardware_profiles TO stats_hardware_verifier;
GRANT SELECT ON chip_hardware_profiles TO stats_hardware_verifier;
