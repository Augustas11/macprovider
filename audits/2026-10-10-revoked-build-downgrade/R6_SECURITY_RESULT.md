# R6 (verification only) — SECURITY lane (omc ask codex)


R5-M1 — FIXED — asserts eligibility phase and trust_state_lost, distinguishing post-drain refusal from swap-gate refusal (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2409).
R5-L1 — FIXED — snapshots pending marker before fixture deletion; asserts none after drain and awaitingPreviousReadiness with previous version 1.8.233 after eviction (phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2390, :2404, :2428).
R5-L2 — FIXED — rewrites valid JSON without replacing its signature; altered field leaves identity validation intact, isolating signature refusal (scripts/ops/test-entrypoints.sh:783; scripts/ops/cli-release.sh:418).
VERDICT: C=0 H=0 M=0 L=0
