=================== code
## Raw output

```text
CODE lane gate: **PASS** at `822f1bb4a`. Complete diff, callers, and SPEC-014 v0.12 reviewed. No files edited.

- **R1 missing-index failure — FIXED.** [unlock.go:226](/Users/augstar/macprovider-1925/phase4-coordinator/internal/rewards/unlock.go:226) checks index availability and selects the unpinned query when absent or renamed. Regression passes for shared and standalone readers; cancellation remains an error.
- **R1 idle-prewarm contract mismatch — FIXED.** [SPEC-014:598](/Users/augstar/macprovider-1925/specs/SPEC-014-provider-portal.md:598) explicitly exempts optional telemetry. The pre-existing empty-counter fallback now matches the contract.

**No new findings.** Lifetime/week/today totals, sorted models, date ranges, and range-independent pending preserve prior semantics. Shared pool ownership is safe; financial read failures propagate as generic 503 responses. Portal and Swift callers handle 503 without signing out.

Validation: **12 targeted Go tests passed**, including both fixes, totals equivalence, pending/ranges, cookie authorization, and failure logging. `git diff --check` passed. Full suites and hardware tests were not run.

C/H/M/L = 0/0/0/0
=================== security
## Raw output

```text
SECURITY Round 2: **PASS at `822f1bb4a` — 0 C/H/M.** Reviewed the complete diff, callers, and SPEC-014 v0.12. No files edited.

Round 1 verification:

- **FIXED — Missing-index failure.** [unlock.go:226](/Users/augstar/macprovider-1925/phase4-coordinator/internal/rewards/unlock.go:226) checks index availability and uses an unpinned fallback. Regression tests pass for shared and per-call readers; cancellation still propagates.
- **FIXED — Idle-prewarm contract mismatch.** [SPEC-014:598](/Users/augstar/macprovider-1925/specs/SPEC-014-provider-portal.md:598) scopes mandatory 503 responses to financial/settlement reads and explicitly exempts optional telemetry.

Remaining finding:

- **LOW — Pre-existing: subsequent 503 silently leaves stale balances displayed.** [index.html:2056](/Users/augstar/macprovider-1925/frontdoor/provider-portal/index.html:2056)  
  **Scenario:** earnings loads successfully, then polling receives 503. The client retains cached balances and renders the error only when no cached data exists, concealing the outage. An in-memory portal probe reproduced this.  
  **Fix:** display the retryable error alongside retained balances and mark them stale; add a successful-load → 503 regression test.

No new security blockers found. Auth and cookie ownership checks remain unchanged; both earnings credentials share the limiter, including failed reads. Error bodies are generic and uncacheable. New logs contain no credential inputs, and token-redaction tests pass. Shared pool ownership is preserved.

Validation: **13 focused Go tests passed**, plus `git diff --check`. Portal probing confirmed no sign-out on 503 and exposed the LOW finding above. Swift handling was source-reviewed only.

C/H/M/L = 0/0/0/1
=================== architecture
## Raw output

```text
Architecture gate: **FAIL — 1 MEDIUM finding.** Reviewed the complete diff at `822f1bb4a`, callers, SPEC-014 v0.12, and #1909’s retention patch. No files edited.

Round 1 verification:

- **FIXED — missing-index failure.** [unlock.go:227](/Users/augstar/macprovider-1925/phase4-coordinator/internal/rewards/unlock.go:227) selects the unpinned query when the index is absent. Regression coverage passes for shared and standalone readers; cancellation still propagates.
- **FIXED — idle-prewarm contract mismatch.** [SPEC-014:598](/Users/augstar/macprovider-1925/specs/SPEC-014-provider-portal.md:598) explicitly exempts optional telemetry. Existing failure/timeout fallback tests pass.

New finding:

- **MEDIUM — A 503 after successful loading silently preserves stale balances.** [index.html:2056](/Users/augstar/macprovider-1925/frontdoor/provider-portal/index.html:2056), [SPEC-014:14](/Users/augstar/macprovider-1925/specs/SPEC-014-provider-portal.md:14).  
  **Scenario:** earnings loads successfully, then subsequent polls return 503. `earnFetch` retains the previous data, while `renderEarn` displays errors only when data is absent. Both cookie and bearer probes reproduced old balances remaining visible without an error notice. This rendering behavior is **pre-existing**, but contradicts this PR’s new promise that 503 appears as an inline, retryable dashboard error.  
  **Fix:** show the error alongside cached balances and explicitly mark them stale, or clear the balances on 503. Add 200→503→200 rendering tests for both auth modes.

Additional observations:

- **INFO — Recovery remains nonfatal.** Neither portal auth mode signs out on 503; polling continues. Malibu’s earnings fetch uses `try?`, allowing metrics collection to continue.
- **INFO — Retention integration remains necessary.** #1909 modifies the same receipt count to include archived verdicts in one snapshot. Preserve that addition and this index/fallback logic when integrating. Earnings remains linear in provider ledger history, a **pre-existing** scaling limit.
- No new schema migration or shared-pool ownership problem found.

Validation: **9 targeted Go tests passed**, **8 portal harness tests passed**, and both post-success 503 rendering probes reproduced the finding. `git diff --check` passed; checkout remains clean.

C/H/M/L = 0/0/1/0
