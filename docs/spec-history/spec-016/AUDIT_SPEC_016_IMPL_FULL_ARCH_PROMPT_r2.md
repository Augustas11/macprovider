# IMPL audit prompt — SPEC-016 FULL implementation, **ARCHITECTURE REVIEW lane, r2**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r2.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing the FULL SPEC-016
implementation — round 2.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r2.md`. HEAD: `3b41c0d`.
r1 found 1 MEDIUM (LinuxRequired); fix-pass closed it.

## r1 closure verification

### [full-arch:r1-1] LinuxRequired=true

Walk `cmd/coordinator/main.go::setupPayout`. Verify:
- `LinuxRequired: true` is set when payout.enabled is true.
- The new comment ties the flip to SPEC §6.3 + Step 1 r2 carry.
- A regression test in `topology_test.go` exists
  (`TestAssertPayoutRuntimeTopology_LinuxRequiredGate`) that
  asserts the gate fires on non-linux and passes on linux.

## New cross-step probes

### A. Authority enumeration after r1

The r1 audit declared 8 authorities. r1 fix-pass added one more
that needs enumeration:

9. **Admin halt-bypass policy (withHaltObservability + EmitAdminInvokedWhileHalted)**
   — single source of truth for "what admin endpoints allow during
   halt + emit observability." Verify:
   - All 5 admin endpoints OTHER than run-now are wrapped at all
     applicable mux levels (Step2 has abandon + run-now; Step3 + Step4
     have all 6).
   - The wrapper composes correctly with operator-key auth — auth
     runs FIRST (returns 401 if bad), wrapper runs SECOND (emit if
     halted), handler runs THIRD.

Re-verify the original 8 authorities still hold at HEAD:
1. TuningProvider
2. Halt primitive
3. RunNowController
4. Lease / self-fence
5. Pause flag
6. Bootstrap sentinel
7. §4.1 import boundary
8. §6.3 co-residency + Linux gate (now AT topology authority post-r1)

### B. Cross-step composition after r1

1. **Halt + 5-background shutdown.** Walk main.go shutdown closure.
   Verify the halt primitive being toggled mid-cycle does NOT
   deadlock with the Stop() sequence. The order is chainWorker →
   runner → reorgPoller → reaper; chainWorker triggers halt;
   runner.Stop must complete the current row-loop break + return
   cleanly. Is this synchronization correct?

2. **TuningProvider + r1 changes.** The r1 fix didn't touch
   TuningProvider, but verify the Snapshot() reads inside the new
   r1 halt gates pick up the same per-cycle snapshot as the rest of
   the cycle. Specifically: the IsHalted gates use atomic.Bool not
   snapshot, so they're independent — that's correct.

3. **Migration ordering.** With the new
   `stripExistingColumnAlters` rewrite, verify:
   - The migration runner still applies migrations in lexicographic
     order.
   - The `payout_schema_applied` marker INSERT still fires after
     the rewritten statement, so re-runs of a partial-applied
     migration are idempotent.

### C. New defects unique to r1 + holistic view

1. Does the r1 halt gate at allocateBuildSignBroadcast (after
   COMMIT) leave any observability gap? The persisted bytes will
   be picked up by the next non-halted cycle's rebroadcastAndPoll
   — is that documented anywhere besides the inline comment?

2. The withHaltObservability wrapper requires Runner. Step1 mux
   doesn't have Runner (the runner isn't constructed yet at Step1).
   Verify the Step1 mux factory passes nil runner and the wrapper's
   nil-check actually fires.

3. The validatePayoutRPCURL runtime check + deploy-gate check
   share the same trust constraints but in DIFFERENT languages
   (Go vs Python). Is there a chance for drift over time? The
   audit prompt's r1 closure is "deploy gate is defense-in-depth;
   runtime is the trust root" — verify this division of labor is
   documented + audit-loop-stable.

### D. §7.4 reconcile + Step 3 advisory tracking

Step 3's [arch:4.5] advisories were deferred. Verify they remain
TRACKED (the convergence summary at
`specs/SPEC-016-IMPL-STEP_4-r8-convergence.md:105` references this).

### E. Final PR-readiness matrix (FULL, r2)

Re-emit the matrix from r1 with verdicts updated for the r1
fix-pass:

| Row | Verdict |
|-----|---------|
| §3.2 EIP-712 register | ? |
| §3.3 cooling-off + pre-auth pause | ? |
| §3.4 audit-log emits | ? |
| §4.1 import boundary | ? |
| §4.2 admin run-now contract | ? |
| §4.3 9-step runner cycle | ? |
| §4.4 two-RPC discipline | ? (must be PASS after r1-1 closure) |
| §4.6 abandon endpoint | ? (must be PASS with halt-bypass observability) |
| §4.7 reorg detection + carve-out | ? |
| §4.8a reaper | ? |
| §4.8b lease | ? |
| §4.8c stale-transition CAS + outbox | ? |
| §4.9 record-funding | ? (halt-bypass observability) |
| §6.2 balance monitoring emits | ? |
| §6.3 co-residency + Linux gate | ? (must be PASS after r1 LinuxRequired flip) |
| §6.4.1 pause/resume | ? (halt-bypass observability) |
| §6.5 dual-namespace loader split + SIGHUP | ? |
| §7.1 event field-name compliance + new payout_runner_halted_skipping_rows + payout_admin_invoked_while_halted | ? |
| §7.3 provider-scoped read endpoint | ? |
| §7.4 reconciliation queries + chain-balance worker | ? |
| Ops bundle | ? (deploy gate URL probe added) |
| 5-background shutdown composition | ? |
| TuningProvider authoritative across consumers | ? |
| Halt primitive authoritative across entry points | ? (must be PASS after r1-2 + r1-3 closures) |
| Migration ordering monotonic + idempotent | ? (must be PASS after r1-4 closure) |
| Step 3 advisories tracked or deferred | ? |
| Admin halt-bypass policy explicit | ? (NEW after r1-3) |
| Payout RPC URL trust constraints | ? (NEW after r1 [full-sec:r1-1]) |

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-arch-r2-audit.md`.
Standard structure. If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Verify r1 closures hold + check for new authority gaps.
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```
