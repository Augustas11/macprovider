# R6 (verification only) — ARCHITECTURE lane (omc ask codex)


R5-M1 — FIXED — phase and failure-class assertions distinguish post-drain refusal from the later swap gate (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2409).
R5-L1 — FIXED — pending marker is captured before fixture cleanup; tests assert absence after drain and restored-build readiness state/version after eviction (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2390, :2404, :2428).
R5-L2 — FIXED — tampering preserves valid JSON and release identity while retaining the original signature; the changed field is not an identity-parser rejection condition (scripts/ops/test-entrypoints.sh:783).
VERDICT: C=0 H=0 M=0 L=0
