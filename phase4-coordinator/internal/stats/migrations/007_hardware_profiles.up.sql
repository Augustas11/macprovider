-- Network stats hardware enrichment.
--
-- Provider-reported hardware identity is written by provider onboarding.
-- Operator-trusted chip capacity constants are kept separate so public
-- bandwidth/power/core totals never trust provider-submitted capacity claims.

CREATE TABLE IF NOT EXISTS provider_hardware_profiles (
    provider_id          TEXT PRIMARY KEY,
    chip                 TEXT NOT NULL,
    chip_normalized      TEXT NOT NULL,
    unified_memory_gb    INT NOT NULL CHECK (unified_memory_gb >= 0 AND unified_memory_gb <= 4096),
    macos_version        TEXT NOT NULL DEFAULT '',
    app_version          TEXT NOT NULL DEFAULT '',
    source               TEXT NOT NULL CHECK (source IN ('app_register', 'cli_hello', 'operator')),
    verified             BOOLEAN NOT NULL DEFAULT FALSE,
    last_reported_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_provider_hardware_profiles_chip_normalized
    ON provider_hardware_profiles(chip_normalized);

CREATE TABLE IF NOT EXISTS chip_hardware_profiles (
    chip_normalized              TEXT PRIMARY KEY,
    display_chip                 TEXT NOT NULL,
    memory_bandwidth_gb_per_s    BIGINT NOT NULL CHECK (memory_bandwidth_gb_per_s >= 0),
    network_power_kw             DOUBLE PRECISION NOT NULL CHECK (network_power_kw >= 0),
    gpu_cores                    INT NOT NULL CHECK (gpu_cores >= 0),
    cpu_cores                    INT NOT NULL CHECK (cpu_cores >= 0),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION provider_hardware_profiles_guard_verification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_user <> 'provider_onboarding' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.verified := FALSE;
    ELSIF NEW.chip_normalized IS DISTINCT FROM OLD.chip_normalized THEN
        NEW.verified := FALSE;
    ELSE
        NEW.verified := OLD.verified;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provider_hardware_profiles_guard_verification
    ON provider_hardware_profiles;

CREATE TRIGGER trg_provider_hardware_profiles_guard_verification
BEFORE INSERT OR UPDATE ON provider_hardware_profiles
FOR EACH ROW
EXECUTE FUNCTION provider_hardware_profiles_guard_verification();

REVOKE ALL ON FUNCTION provider_hardware_profiles_guard_verification() FROM PUBLIC;

GRANT SELECT (provider_id, last_reported_at) ON provider_hardware_profiles TO provider_onboarding;
GRANT INSERT (
    provider_id,
    chip,
    chip_normalized,
    unified_memory_gb,
    macos_version,
    app_version,
    source,
    last_reported_at
) ON provider_hardware_profiles TO provider_onboarding;
GRANT UPDATE (
    chip,
    chip_normalized,
    unified_memory_gb,
    macos_version,
    app_version,
    source,
    last_reported_at
) ON provider_hardware_profiles TO provider_onboarding;

GRANT SELECT ON
    provider_hardware_profiles,
    chip_hardware_profiles
TO stats_rollup;

REVOKE ALL ON
    provider_hardware_profiles,
    chip_hardware_profiles
FROM stats_reader, provider_portal;
