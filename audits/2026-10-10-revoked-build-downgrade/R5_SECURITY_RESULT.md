# R5 (verification only) — SECURITY lane (omc ask codex)


F1 — FIXED — DEBUG guards exclude the injectable seam from release builds; production retains validated preparation (`AutoUpdater.swift:97–102,385–426`). Withdrawal tests cover drain refusal, rollback-only restart after eviction, abort events, and the authorized control (`AutoUpdateTests.swift:2368–2436`).

F2 — FIXED — Signature verification uses the train’s SHA-256 digest and public key; canonical fields form the full identity, compared exactly before mutation or completion (`scripts/ops/cli-release.sh:412–483,499–515`). Tests cover signed mismatch, tampering, and missing signature (`scripts/ops/test-entrypoints.sh:775–788`).

LOW — AutoUpdateTests.swift:2389,2402 — Returned store outlives `TempHome`, whose destructor deletes the fixture; the pending-marker assertion therefore passes even if cleanup failed — inspect pending state before returning, or retain the fixture through assertions.

Static verification only; shell syntax and Python AST checks passed. Behavioral tests were not run.

VERDICT: C=0 H=0 M=0 L=1
