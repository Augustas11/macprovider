-- Autotune admission must compare a verified benchmark with the provider's
-- current verified capacity tuple. Keep provider_onboarding read access
-- column-limited to only the fields required for that decision.

GRANT SELECT (
    provider_id,
    chip_normalized,
    unified_memory_gb,
    verified
) ON provider_hardware_profiles TO provider_onboarding;

GRANT SELECT (
    chip_normalized,
    unified_memory_gb
) ON hardware_verification_jobs TO provider_onboarding;
