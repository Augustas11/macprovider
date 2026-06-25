# IMPL audit prompt — SPEC-016 Step 4, **ARCHITECTURE REVIEW lane, round 3**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r3.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 4
IMPL — round 3.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r3.md`. HEAD: `fe6a699`.

The r2 audit returned 0 CRITICAL / 2 MAJOR / 0 MEDIUM / 0 LOW
(BLOCK). The r2 fix-pass landed at `fe6a699`. Verify closure AND
look for the next "is this primitive used everywhere it should be?"
question per [[audit-cycles-are-design-discovery]].

## Architecture focus (r3)

The r2 fix-pass introduced two cross-cutting changes that this
round must verify:

1. **`RunNowController`** — centralised run-now contract for all
   mux levels.
2. **Live-read SPKI** — `func() string` closure instead of captured
   value.

The r1+r2 fix arc has been: TuningProvider as authority across
4 consumers + halt primitive + run-now controller + SPKI live-read.
The architect lens at r3 must check whether the abstraction is NOW
exhaustive across `TuningSnapshot`.

### A. Enumerate every TuningSnapshot field

Open `phase4-coordinator/internal/payout/config_tuning.go` and list
every field of `TuningSnapshot`. For EACH field, verify ONE of:

(a) It has a live consumer at the right cycle boundary
(b) It has documented "restart-only" semantics (ticker cadence
    captured at Start) with an explicit code comment

If any field lacks both, that's a NEW architectural defect of the
same class as r1 + r2 — flag it.

Fields to enumerate:
- AddressCoolingOffPeriod
- RunInterval
- RunNowMinInterval
- ConfirmationBlocks
- MaxRowsPerRun
- ReorgPollWindow
- LowBalanceThreshold
- LowNativeThreshold
- RPCURLPrimaryPinSPKI
- RPCURLSecondaryPinSPKI

### B. RunNowController architectural soundness

1. **Single instance shared across all 3 mux levels.** The
   controller's `lastAccepted` state must be shared between
   Step2/3/4 — verify a SINGLE controller is constructed in main.go
   and passed through all three Options.
2. **Mutex composition.** Holds lock across lastAccepted update.
   Does NOT hold lock across `RunOnce` (which is potentially
   long-running). The release-then-RunOnce window is acceptable
   per the SPEC contract (the rate limit is about request
   admission, not cycle completion).
3. **Test path nil-handling.** When `tuning` is nil (test path),
   `fallbackInterval` is used. Verify the fallback can be `0` for
   tests that want no rate limit.

### C. SPKI live-read architecture

1. **Closure correctness.** `func() string` is constructed at RPC
   client construction time, closes over `tuningProvider`. Calls
   are race-safe because `Snapshot()` returns the atomic value by
   value.
2. **Idle-connection pool.** Go's `http.Transport` pools TLS
   connections. A SIGHUP after a pool connection is established
   does NOT invalidate the existing connection. Is this an
   architectural defect or an acceptable limitation? The runbook
   should document; flag if not.
3. **Construction ordering.** TuningProvider must be built BEFORE
   the RPC clients. Verify main.go's setupPayout order.

### D. Cross-step composition unchanged

1. Shutdown ordering still chainWorker → runner → reorgPoller →
   reaper, lease released only when runnerClean && pollerClean.
2. The new RunNowController has no Stop method — it doesn't own
   long-running state. Verify no goroutine leaked.
3. step3_test.go + step4_test.go updated to wire RunNow — verify
   the existing test paths don't break on the construction reorder.

### E. r2 finding closure verification

For each r2 finding, score CLOSED / PARTIAL / OPEN:
- [arch:r2-4.1] convergent MAJOR — run-now contract
- [arch:r2-4.2] MAJOR — SPKI live read

If both CLOSED at the architectural level, score the abstraction
as exhaustive (or call out the next gap).

### F. PR-opening readiness

Run the full coordinator test suite. Verify Step 4 does NOT
regress any Step 1/2/3 test. Verify all r1+r2 advisories have been
closed or explicitly deferred.

## Step 4 → PR readiness matrix (r3)

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | ? |
| §7.4 reconciliation queries verbatim | ? |
| §7.4 chain-balance worker drift detection | ? |
| §7.4 negative-drift halt | ? |
| §6.2 balance monitoring emits | ? |
| §7.3 provider-scoped read endpoint | ? |
| §4.2 admin run-now contract (rate-limit + event) | ? |
| §7.1 event field-name compliance | ? |
| TuningProvider authoritative across consumers | ? |
| Halt primitive authoritative across entry points | ? |
| Ops bundle (yaml.example + deploy gate + runbook) | ? |
| Construction ordering correctness | ? |
| Step 3 advisories addressed or deferred | ? |

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-arch-r3-audit.md`. Standard structure.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
