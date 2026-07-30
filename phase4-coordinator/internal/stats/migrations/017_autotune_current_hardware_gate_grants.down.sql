REVOKE SELECT (
    chip_normalized,
    unified_memory_gb,
    verified
) ON provider_hardware_profiles FROM provider_onboarding;

REVOKE SELECT (
    chip_normalized,
    unified_memory_gb
) ON hardware_verification_jobs FROM provider_onboarding;
