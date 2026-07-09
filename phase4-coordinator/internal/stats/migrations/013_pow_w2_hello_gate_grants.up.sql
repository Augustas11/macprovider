-- W2 proof-of-weights hello gate: provider_onboarding must read verified
-- autotune evidence (generated_at + evidence JSON) when evaluating WS hello.

GRANT SELECT (
    generated_at,
    evidence
) ON hardware_verification_jobs TO provider_onboarding;
