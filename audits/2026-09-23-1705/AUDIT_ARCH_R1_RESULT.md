## Raw output

```text
1. **HIGH — [MacProviderCLI.swift:1262](/Users/augstar/macprovider-1705/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:1262)**  
   The refresher accepts a new envelope using only unchanged `model_sha256`; it does not require unchanged row identity or `PolicyEquivalent`. If C changes `min_ram_gb`, `draft_candidates`, or `workload_profiles` while retaining the model hash/revision, the running provider adopts C’s row identity without applying its policy. Its next hello is treated as `current`, bypassing the coordinator’s older-document policy comparison at [server.go:3695](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/server.go:3695). Require the refreshed row identity to equal the process’s existing row identity before staging, update §3.6.1’s refresh wording, and add policy-change refresh tests.

2. **HIGH — [billing_recorder.go:739](/Users/augstar/macprovider-1705/phase4-coordinator/internal/buyer/billing_recorder.go:739)**  
   The branch is now two commits behind `origin/main` and the combined diff reverses #1694’s loopback settlement bar. Token counts relayed by an operator-controlled loopback are again recorded as `coordinator_observed`; companion routing and settlement checks are also removed. A loopback session can therefore supply usage that reaches positive settlement despite lacking a trusted usage source. Rebase onto `origin/main` and preserve commit `b5a9ee91` with its SPEC and regression coverage.

3. **MEDIUM — [settlement_reconcile.go:257](/Users/augstar/macprovider-1705/phase5-gateway/internal/router/settlement_reconcile.go:257)**  
   The combined diff also reverses #1710’s bounded retry and targeted recovery. A transient timeout, network error, 429, or coordinator 5xx during the one nudge deletes the deduplication key and abandons the hold; catch-up runs only on queue overflow, so the reservation can remain held until a manual bulk reconciliation. Rebase and preserve commit `afbee248`, including retry classification and exact-hold reconciliation.

4. **LOW — [CONFORMANCE.json:2526](/Users/augstar/macprovider-1705/specs/CONFORMANCE.json:2526)**  
   CONFORMANCE says the full AC-CAT-22 negative matrix is covered, but no listed test exercises artifact-derived identity under `row_continuity`. The relevant unit matrix at [artifact_identity_test.go:120](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/artifact_identity_test.go:120) omits that mode. A future change allowing its digest into the artifact index would pass the declared R010 suite. Add `row_continuity` to the non-binding modes and an end-to-end assertion that artifact-derived identity remains rejected.

5. **INFO — [autotune_window.py:319](/Users/augstar/macprovider-1688-a0/scripts/autotune_window.py:319)**  
   Open PR #1706’s validator contract recognizes only `current`, `retained`, and `restamp`, while its coordinator helper assumes every compatible entry after `.previous-target` is a restamp. When rebased with #1705, row-continuity evidence would be mislabeled—or rejected if the correct source name is emitted. Update #1706’s validator/result schema, source enum, and coverage tests to carry `row_continuity` explicitly; its exclusive `.previous-target` writer remains otherwise compatible.

VERDICT: C=0 H=2 M=1 L=1
