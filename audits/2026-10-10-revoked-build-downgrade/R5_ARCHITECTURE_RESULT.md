# R5 (verification only) — ARCHITECTURE lane (omc ask codex)


F1 — FIXED — Static verification: the DEBUG-only seam substitutes release preparation while retaining authorization, swap and restart gates (`phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:97`, `:385`). Withdrawal tests assert no activation/restart during drain, and restored revoked bytes with only a rollback restart after eviction; both assert the abort reason. The authorized control proves older-release activation/restart (`phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2395`, `:2413`, `:2427`).

F2 — FIXED — Signed metadata is verified using the train’s same public key and SHA-256 digest (`scripts/ops/cli-release.sh:418`, `:1120`). Metadata fields are validated and the full identity must match before mutation selection or completion (`:427`, `:477`, `:499`, `:514`). This matches the runbook (`docs/runbooks/provider-cli-release-verification.md:112`). Ops tests cover identity mismatch, tampering and missing signature (`scripts/ops/test-entrypoints.sh:775`). Tests were inspected, not executed.

LOW — phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:2402 — The pending-marker assertion is vacuous: the helper’s `TempHome` is destroyed on return, deleting the directory before `readPending()` checks it (`:2304`, `:2389`, `:5220`). — Capture pending-marker state inside the helper before returning, or retain the fixture through the assertion.

VERDICT: C=0 H=0 M=0 L=1
