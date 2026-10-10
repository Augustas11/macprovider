# R6 (verification only) — CODE lane (omc ask codex)


R5-M1 — FIXED — Phase `eligibility` and failure class `trust_state_lost` assertions distinguish post-drain refusal from the later `swap` refusal (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2409–2410).
R5-L1 — FIXED — Pending marker is read before fixture destruction; tests assert absence after drain and `awaitingPreviousReadiness` with previous version `1.8.233` after eviction (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2390,2404,2428–2429).
R5-L2 — FIXED — Tampering rewrites valid JSON while retaining the original signature and identity fields; signature verification rejects the changed bytes (scripts/ops/test-entrypoints.sh:780–789; scripts/ops/cli-release.sh:418–430).
VERDICT: C=0 H=0 M=0 L=0
