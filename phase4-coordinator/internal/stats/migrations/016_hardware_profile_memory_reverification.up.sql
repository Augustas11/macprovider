-- A verified capacity tuple is valid only for the exact chip class and
-- unified-memory size that the verifier approved. Existing deployments have
-- already applied migrations 007/008, so replace the guard forward rather
-- than rewriting their recorded migration history.

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
