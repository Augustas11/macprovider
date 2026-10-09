=================== code codex-you-are-the-code-lane-auditor-for-pr-1926-augustas11-macprov-2026-10-09T16-24-38-584Z.md
## Raw output

```text
CODE lane gate: **FAIL — 2 MEDIUM findings.** Reviewed the complete diff, callers, and SPEC-014 v0.12. No files edited.

1. **MEDIUM — Missing index permanently breaks wallet/accrual reads.**  
   [unlock.go:187](/Users/augstar/macprovider-1925/phase4-coordinator/internal/rewards/unlock.go:187)  
   If `idx_srv_provider_recent` is missing or renamed, `INDEXED BY` fails with `no such index`. The error propagates through trust projection, making both endpoints return 500 and preventing background trust evaluation. Normal billing migration creates the index, but a separately configured read-only payout database receives no repair. SQLite reproduction confirmed the pinned query fails while the unpinned query returns the correct count.  
   **Fix:** retry without the index clause specifically when that index is unavailable; preserve cancellation and other errors. Add missing/renamed-index regression tests for shared and standalone readers.

2. **MEDIUM — Idle-prewarm failures contradict the new mandatory read-failure contract.**  
   [endpoints.go:1345](/Users/augstar/macprovider-1925/phase4-coordinator/internal/billing/endpoints.go:1345), [SPEC-014:594](/Users/augstar/macprovider-1925/specs/SPEC-014-provider-portal.md:594)  
   When idle-prewarm reading fails or exceeds its 250 ms budget, earnings substitutes empty counters and can still return 200. SPEC-014 v0.12 requires 503 with `Retry-After: 5` when **any earnings read** fails. This fallback is **pre-existing**, but the contradiction is introduced by this PR’s contract. Existing tests explicitly assert the conflicting 200 behavior.  
   **Fix:** route the failure through `unavailable("idle_prewarm", err)` and update failure/timeout tests, including cookie authorization.

Validation: all 9 selected Go tests and 16 targeted portal tests passed; `git diff --check` passed. Covered totals, models, and range-independent pending retain their prior semantics. No connection ownership leak found. Portal and CLI callers handle earnings 503 without signing out.

C/H/M/L = 0/0/2/0
=================== security codex-you-are-the-security-lane-auditor-for-pr-1926-augustas11-mac-2026-10-09T16-24-49-994Z.md
## Raw output

```text
**MEDIUM — Missing index permanently disables reward reads and trust evaluation.** [unlock.go:187](/Users/augstar/macprovider-1925/phase4-coordinator/internal/rewards/unlock.go:187)

If `idx_srv_provider_recent` is missing or renamed while the verdict table remains readable, `INDEXED BY` returns `no such index`. The error propagates to wallet/accrual handlers as 500 and prevents background trust evaluation from reaching promotion or demotion. Every retry fails until schema repair. This dependency is **new**, not pre-existing.

Verified using the exact query against an in-memory fixture: pinned query failed; unpinned query returned the correct count.

**Fix:** retain the preferred index, add narrowly scoped recovery for a missing index without swallowing other errors, and preserve cancellation/read budgets. Add missing/renamed-index regression coverage.

No additional security findings:

- Bearer subject matching and cookie ownership checks remain intact.
- Both earnings credentials use the same rate limiter; failed reads consume quota.
- Earnings 503 responses retain private/no-store headers and expose generic text.
- New logs contain no credential inputs; token-redaction tests pass.
- Portal 503 handling remains inline; Swift callers handle the failed fetch without signing out.

Validation: five targeted billing/rewards tests passed, including cookie/bearer isolation, shared rate limiting, retryable 503, index selection, and log redaction. `git diff --check` passed. No files changed.

**Gate: FAIL — one MEDIUM availability finding.**

C/H/M/L = 0/0/1/0
=================== architecture codex-you-are-the-architecture-lane-auditor-for-pr-1926-augustas11-2026-10-09T16-24-39-982Z.md
## Raw output

```text
Architecture gate: **FAIL — 2 MEDIUM findings.** Reviewed complete diff at `2b21c118`, callers, SPEC-014 v0.12, and PR #1909’s retention changes. No files edited.

- **MEDIUM — Required index can permanently break wallet/accrual reads.** [unlock.go:187](/Users/augstar/macprovider-1925/phase4-coordinator/internal/rewards/unlock.go:187)  
  **Scenario:** the configured external payout database contains verdicts but lacks `idx_srv_provider_recent`, or a future migration renames it. `INDEXED BY` fails with `no such index`; projection error propagation makes both endpoints fail every request. Normal coordinator startup creates the index in its primary billing database, but the separately configured payout database opens read-only without migrations.  
  **Fix:** retain the indexed fast path, with a bounded unpinned fallback specifically for a missing-index error. Add missing-index tests for shared-reader and per-call paths. An in-memory SQLite probe reproduced the failure; the unpinned equivalent returned the correct count.

- **MEDIUM — SPEC-014’s new “any earnings read” guarantee contradicts implementation.** [SPEC-014-provider-portal.md:594](/Users/augstar/macprovider-1925/specs/SPEC-014-provider-portal.md:594), [endpoints.go:1343](/Users/augstar/macprovider-1925/phase4-coordinator/internal/billing/endpoints.go:1343)  
  **Scenario:** idle-prewarm reading fails or exceeds its timeout while financial reads succeed. The endpoint still returns **200** with empty telemetry, whereas v0.12 requires **503 + Retry-After: 5** when any earnings read fails. This fallback is **pre-existing**, but the contract contradiction is introduced here. Existing tests explicitly require the 200 fallback.  
  **Fix:** precisely scope the new contract to mandatory financial/settlement reads and document optional idle-prewarm telemetry’s fallback; align the changelog and tests.

- **INFO — Client recovery is compatible.** Portal 503 handling stays inline and polling continues; an in-memory extension of the existing cookie-mode harness passed. Malibu’s CLI catches earnings fetch failures through `try?` and continues metrics collection; no fatal or sign-out path was found. Neither client consumes `Retry-After`, but portal automatic polling uses a 60-second cadence.

- **INFO — Retention integration remains necessary.** #1909 modifies this same receipt-count function to combine hot and archived counts in one SQL snapshot. Integration must preserve that addition **and** this provider-index optimization. Earnings remains linear in retained ledger history; evidence retention alone does not bound that scan. No new schema migration is introduced by #1926.

Validation: source review, lightweight SQLite probe, and portal harness; Go/Swift suites were not rerun.

C/H/M/L = 0/0/2/0
