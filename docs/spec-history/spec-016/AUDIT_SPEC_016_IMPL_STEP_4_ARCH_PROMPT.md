# IMPL audit prompt — SPEC-016 Step 4, **ARCHITECTURE REVIEW lane, round 1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 4
IMPL — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md`. HEAD: `dbf7e78`.

## Architecture-review focus

Step 4 is the LAST step. The architecture-lane review is the
last gate before the single PR opens. Focus on:

1. The §6.5 security/tuning loader split — is the architectural
   invariant ("a security key is unreachable from the tuning
   reload path") preserved?
2. The Step 1+2+3+4 composition — do all four backgrounds (runner,
   poller, reaper, chain-worker) shut down in a coherent order
   with bool-return Stop primitives?
3. The §7.4 reconcile.sql as a checked-in artifact — is the file
   organisation maintainable as the SPEC evolves?
4. The PR-opening readiness — any deferred items that should be
   tracking-issue'd instead of silently dropped?

### A. §6.5 security/tuning split

1. `config_tuning.go` has a unit test
   (`TestTuningStaticCheck_NoSecurityNamespaceReference`)
   asserting zero references to security-namespace
   identifiers. Verify this is a true compile-time / static-AST
   guarantee, not a string-match that could be evaded by a
   refactor.
2. `TuningProvider` has NO field of type `SecurityConfig` or
   any `payout.security.*` Go-side name.
3. The cross-field `low_balance_threshold <= 2 × per_day_cap`
   uses an IMMUTABLE perDayCap captured at NewTuningProvider
   time. Verify it cannot drift.
4. SIGHUP listener re-reads YAML but ignores `payout.security.*`
   keys — only `payout.tuning.*` keys flow into the candidate
   snapshot.
5. SPEC §6.5 normative: "In-flight `pending_until_utc` rows
   MUST NOT be recomputed on `address_cooling_off_period`
   reload — NEW registrations cool off against the NEW value;
   in-flight rows keep their original `pending_until_utc`."
   Verify the addresses.go handler reads the snapshot at
   write-time (not at runner-cycle time), so old in-flight
   rows are unaffected.

### B. 4-background shutdown composition

1. main.go's shutdown closure stops:
   - chainWorker (read-only RPC; no lease)
   - runner (lease holder; chain-write critical section)
   - reorgPoller (read-only RPC; no lease)
   - reaper (read-only DB writes via CAS-claim)
2. Lease release is gated on `runnerClean && pollerClean`
   only. chainWorker.Stop and reaper.Stop don't gate Release
   because their Stop timeouts cannot corrupt chain state.
3. Verify the order: chainWorker first so a final reconcile
   can fire on clean shutdown. Then runner so any in-flight
   broadcast completes. Then poller so any in-flight RPC poll
   completes. Then reaper.
4. Each Stop returns `bool` per the Step 2 [arch:3.1-r2]
   pattern. main.go composes the bools correctly.

### C. §7.4 reconcile.sql organisation

1. The SQL file is checked in verbatim with `-- @label: X`
   directives. Operators can edit it without recompiling (the
   SPEC §7.4 lines are cited in each comment block so the
   diff vs SPEC is auditable).
2. `ParseLabeledQueries` is a parser, not a hardcoded map —
   future SPEC additions (G, H, ...) automatically picked up.
3. `splitStatements` handles `;` inside comments via line-
   comment stripping. If a future SPEC version adds `/* */`
   block comments OR string literals containing `;`, the
   parser breaks. Flag as a Step-5 advisory if relevant.

### D. PR-opening readiness

1. Run the full coordinator test suite. Verify Step 4 does
   NOT regress any Step 1/2/3 test.
2. Verify all 4 audit-prompt files for Step 4 will be picked
   up by the audit loop (file naming + path).
3. Any deferred LOW from Step 3 that Step 4 should have
   closed but didn't? Check the Step 3 convergence file
   (`specs/SPEC-016-IMPL-STEP_3-r4-convergence.md`).

### E. Step 4 advisories from Step 3 r3 architect

The Step 3 r3 architect surfaced three forward-looking
advisories. Verify Step 4 either addressed them OR explicitly
deferred:

1. **Per-cycle stale producer cap.** Has Step 4 added a
   `LIMIT` or `MaxRowsPerStaleProduce` to
   `ProduceStaleOutboxRows`?
2. **Chronic single-RPC outage telemetry.** Has Step 4 added
   a separate operator signal for "primary RPC down >1h"?
3. **SIGHUP tuning as lifecycle-aware rebuild.** Step 4
   implements SIGHUP as atomic.Value swap, NOT as
   stop-and-rebuild of the runner. Verify the existing
   approach correctly handles all 8 tuning fields without a
   restart (e.g. does the runner pick up a new `RunInterval`?
   It currently captures `r.opts.RunInterval` at construction
   and uses it in the cadence ticker — a SIGHUP change to
   RunInterval does NOT take effect until restart). Document
   as a known limitation if so.

## Step 4 → PR readiness matrix

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | ? |
| §7.4 reconciliation queries verbatim | ? |
| §7.4 chain-balance worker drift detection | ? |
| §6.2 balance monitoring emits | ? |
| §7.3 provider-scoped read endpoint | ? |
| Ops bundle (yaml.example + deploy gate + runbook) | ? |
| 4-background shutdown composition | ? |
| Step 3 advisories addressed or deferred | ? |

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-arch-r1-audit.md`. Standard
structure.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
