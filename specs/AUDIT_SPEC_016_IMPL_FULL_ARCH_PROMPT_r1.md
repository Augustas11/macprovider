# IMPL audit prompt — SPEC-016 FULL implementation, **ARCHITECTURE REVIEW lane, r1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing the FULL SPEC-016
implementation — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`. HEAD: `47e4f24`.
Holistic architecture audit of Step 1+2+3+4 together. Per
`[[audit-cycles-are-design-discovery]]`, look for the
authority-bug-classes the per-Step audits could not have caught.

## Architecture focus (FULL)

### A. Authority enumeration

The 4 Step audits established these authorities. Verify each is
used CONSISTENTLY across all 4 Steps' code:

1. **TuningProvider** — live source of truth for §6.5 reloadable
   keys. Already audit-declared exhaustive in Step 4 r4. Re-check
   that no Step 2 or Step 3 code captures a tuning value at
   construction.
2. **Halt primitive (Runner.RequestHalt/IsHalted)** — single
   authority for "stop processing". Verify every payout-cycle
   entry point gates on it.
3. **RunNowController** — single authority for §4.2 admin
   run-now contract.
4. **Lease (Step 2 LeaseState)** — single authority for "I am
   the sole runner". Verify every chain-write critical section
   self-fences.
5. **Pause flag (Step 3 runtime_flags table)** — single authority
   for "registration paused". Verify pre-auth gate at Step 1
   addresses.go uses it.
6. **Bootstrap sentinel (Step 3 runtime_flags_bootstrapped)** —
   single authority for "first-cycle seed has run". Verify
   intra-txn confirmed_at_utc EXISTS gate (Step 3 r1 sec:1
   CRITICAL closure).
7. **§4.1 import boundary** — payout → billing one-way. Verify.
8. **§6.3 co-residency** — handler runs in same process as
   runner. Verify topology.go assertion is hit on every startup.

### B. Cross-step composition

1. **5-background shutdown ordering.** Step 4 added the chain-balance
   worker; Step 3 added the reaper; Step 2 added the reorgPoller;
   Step 4 also added the SIGHUP listener. main.go shutdown
   closure stops 4 of them; SIGHUP listener exits via
   shutdownCtx. Verify:
   - Order: chainWorker → runner → reorgPoller → reaper
   - Release lease only on runnerClean && pollerClean
   - chainWorker.Stop + reaper.Stop don't gate Release
   - SIGHUP listener cleanup is implicit via ctx.Done()
   - No deadlock between RequestHalt and Stop()
2. **Migration ordering across Steps.** Walk
   `phase4-coordinator/internal/payout/migrations/` —
   monotonic numbering, no gaps, each Step adds only
   new files (not edits to prior). Idempotent.
3. **Single PR readiness.** The branch will land in ONE PR
   covering Steps 1+2+3+4. Verify:
   - No dead/unused code from earlier-Step versions
   - No TODOs that should block PR
   - No FIXMEs naming the current branch
   - Step 3 advisory [arch:4.5] for ProduceStaleOutboxRows LIMIT
     + chronic RPC outage telemetry is documented as deferred
     to a tracking issue (NOT silently dropped)

### C. Per-Step audit closure verification

Don't re-flag closed findings. Spot-check that each Step's
final convergence claim still holds at HEAD:
- Step 1: 0/0/0 across code + sec + arch (r2)
- Step 2: 0/0/0 across code + sec + arch (r4)
- Step 3: 0/0/0 across code + sec + arch (r3)
- Step 4: 0/0/0 across code + sec + arch (r8 with arch
  CONVERGENT at r4 + security at r5)

If any earlier-Step closure has regressed during a later-Step
fix-pass — flag it.

### D. New defects unique to the holistic view

1. Does any data flow cross a Step boundary in an undocumented
   way? Example: Step 4 chainWorker writes nothing to the DB
   (read-only); Step 2 runner writes payout_attempts; Step 3
   reaper writes the outbox sync flag. Verify no cross-write
   creates an undocumented invariant.
2. Does any Step's state machine touch another Step's state
   machine? Example: payout_attempts has columns added by
   multiple Steps; verify each column has a single owner.
3. Does the §7.1 event surface have any drift between what one
   Step emits and what a downstream consumer (in another Step)
   expects?

### E. Spec-vs-code §7.4 reconcile suite

Step 4 reconcile.sql ships 6 labeled queries (A..F) + 3 unlabeled
regression. Walk SPEC §7.4 normative text and verify EVERY
labeled query matches the SPEC formula byte-for-byte. The audit
prompt for Step 4 already verified this; re-confirm against
SPEC source.

### F. Topology + co-residency

`AssertPayoutRuntimeTopology` (Step 1 [arch:1.3] closure) runs on
boot. Verify main.go calls it BEFORE mounting any payout route.
Verify it asserts: runner present, signer present (if
payout.enabled), TwoRPCs constructed.

### G. Final PR-readiness matrix (FULL)

| Row | Verdict |
|-----|---------|
| §3.2 EIP-712 register | ? |
| §3.3 cooling-off + pre-auth pause | ? |
| §3.4 audit-log emits | ? |
| §4.1 import boundary (payout → billing one-way) | ? |
| §4.2 admin run-now contract | ? |
| §4.3 9-step runner cycle | ? |
| §4.4 two-RPC discipline | ? |
| §4.6 abandon endpoint | ? |
| §4.7 reorg detection + carve-out | ? |
| §4.8a reaper | ? |
| §4.8b lease | ? |
| §4.8c stale-transition CAS + outbox | ? |
| §4.9 record-funding | ? |
| §6.2 balance monitoring emits | ? |
| §6.3 co-residency + dev-mode gate | ? |
| §6.4.1 pause/resume | ? |
| §6.5 dual-namespace loader split + SIGHUP | ? |
| §7.1 event field-name compliance | ? |
| §7.3 provider-scoped read endpoint | ? |
| §7.4 reconciliation queries + chain-balance worker | ? |
| Ops bundle (yaml.example + deploy gate + runbook) | ? |
| 5-background shutdown composition | ? |
| TuningProvider authoritative across consumers | ? |
| Halt primitive authoritative across entry points | ? |
| Migration ordering monotonic + idempotent | ? |
| Step 3 advisories tracked or deferred | ? |

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-arch-r1-audit.md`.
Standard structure. If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Cross-step focus + final PR readiness.
- Wall-clock target: 35-45 min.

=== END PROMPT ===
```
