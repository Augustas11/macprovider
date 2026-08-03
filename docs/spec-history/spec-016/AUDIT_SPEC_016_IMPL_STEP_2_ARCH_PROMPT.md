# IMPL audit prompt — SPEC-016 Step 2, **ARCHITECTURE REVIEW lane**

Lane 3 of 3 parallel codex audit lanes for SPEC-016 Step 2 IMPL
on branch `impl/spec-016`. Master shared-context preamble lives
in `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Expected wall-clock: 40–60 min.

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 2
IMPL. Two sibling lanes (code-reviewer + security-reviewer) fire
in parallel; your scope is ARCHITECTURE ONLY.

## Shared context

Read `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md` for the FULL
shared-context preamble. Under the single-PR plan all four steps
land on this branch; your lens is "what will Step 3 / Step 4
have to fight?"

SPEC v0.1.21 LOCKED at `f0152c0`. Step 2 IMPL HEAD at `db5c9ba`.

## Lane scope: architecture review

### Focus areas

1. **PayoutClaimer boundary (runner.go ↔ billing.Store).**
   - SPEC §4.1 normative: payout/ may import billing/; billing/
     MUST NOT import payout/. The Step 1 importgraph_test still
     enforces.
   - The Runner declares PayoutClaimer interface locally rather
     than importing billing.Store. Confirm this is the right
     abstraction — does the v0.2 KMS-Signer split benefit from
     the same indirection?
   - main.go's setupPayout currently leaves opts.Claimer = nil
     and relies on a follow-up to wire billingStore. Confirm the
     gap is documented + the runner.Start() invocation is
     ALSO left for follow-up (no half-wired state at startup).

2. **§4.7 SPEC drift workaround (reorg.go).**
   - SPEC v0.1.21 §4.7 query references payout_attempts.id +
     payout_external_id (which don't exist in §4.5). Step 2
     implements via (payout_id, attempt_seq, tx_hash) per Step 1
     architect r2 recommendation.
   - Verify the workaround does NOT leak into Step 3's
     /admin/payout/record-orphan endpoint (Step 3 will need to
     bridge to ledger_payout_ready.payout_external_id; flag if
     Step 2 made that bridge harder).
   - Re-validate: is this STILL a deferred SPEC v0.1.22 candidate,
     or should Step 2 raise the urgency?

3. **Lease lifecycle vs runner lifecycle.**
   - Acquire happens in setupPayout BEFORE NewRunner. Heartbeat
     ticker runs from runner.Start. If setupPayout succeeds but
     runner.Start is never called (e.g. a follow-up bug),
     heartbeat doesn't fire and the lease stays "fresh" indefinitely.
     Probe: is there a lifecycle gap where the lease is held
     without a heartbeat?
   - On shutdown, payoutS2.stopFn calls Release. Confirm the
     shutdown ordering in main.go's signal handler invokes
     stopFn BEFORE the runner.Stop, OR document why the
     ordering matters.

4. **Two-RPC abstraction (rpc.go).**
   - TwoRPCs is a value-type bundle; both clients share the
     same HTTP timeout config. Probe: should each have its own
     timeout per the §4.4 trust-separation requirement?
   - SPKI pinning: tunable hooks declared in config but NOT
     wired through to HTTPRPCClient.HTTPClient.Transport. Flag
     as Step 4 follow-up (Step 2 audit can record this).

5. **Signer abstraction (signer.go + signer.SignTx contract).**
   - The Signer interface is minimal per §6.3.1 (no
     SignMessage). Probe: is the contract clear enough for a
     v0.2 KMS substitution to honour without code changes in
     the runner?
   - LocalFileSigner ships an env-var dev path. Flag the
     production gap: LoadCredential= integration is a follow-up.

6. **Mux extension (mux.go).**
   - step2PathTable extends step1; chi router uses
     operator-key middleware. Verify path-table parity check
     catches a route added without table update — same Step 1
     [arch:1.2] concern but extended to admin routes.
   - The /admin/payout/* surface is currently inside the chi
     router rooted at /providers/ — wait, is it? Re-read
     NewMuxStep2; how does main.go mount it? If the router is
     mounted as the /providers/ handler in main.go, /admin/*
     routes inside it would NOT match. Flag the wiring mistake
     if you find it.

7. **Step 2 → Step 3 readiness.**
   - Step 3 will land /admin/payout/record-orphan,
     /admin/payout/record-funding (C1/C2 v0.1.21 deltas),
     /admin/payout/pause-registration, /admin/payout/resume-registration.
   - Probe: does Step 2's path-table extension model scale to
     Step 3 (each new route added to step3PathTable)?
   - Probe: does Step 2's mux composition leave Step 3 a clean
     way to add admin routes without re-writing existing
     handlers?

8. **Step 2 → Step 4 readiness.**
   - Step 4 lands §6.5 dual-loader split, §7.4 reconcile.sql,
     SIGHUP-only tuning reload, bound re-enforcement, the M5
     conservation invariant query.
   - Probe: does Step 2's config struct (Step 2-C1) leave Step
     4 a clean way to add hot-reload semantics? The current
     PayoutTuningConfig is read once at startup; Step 4 will
     need to atomically replace it on SIGHUP.

9. **Topology hook usage.**
   - Step 2 flipped HandlerEnabled+!RunnerCoResident from
     advisory to fail-fast. Confirm there's no main.go branch
     that would pass HandlerEnabled=true while skipping
     setupPayout's runner construction (Step 3/4 hook gap).

10. **§7.1 event coverage.**
    - The full §7.1 table has ~40 events. Step 2 emits ~12
      (payout_run_started, payout_run_finished, payout_paid,
      payout_failed, payout_capped, payout_invariant_violation,
      payout_chain_value_mismatch, payout_rpc_disagreement,
      payout_signer_unavailable, payout_attempt_abandoned,
      payout_reorg_revert, payout_reorg_poll_rpc_error,
      payout_runner_lease_taken_over, payout_runner_lease_lost).
    - Probe: is every event field-set complete vs §7.1 table?
      Architect lens is the cleanness of the emit surface — are
      the events a sustainable API or a snowflake collection?

Findings format:

```
[arch:N.M] [SEVERITY] <short title>
  What: <one-paragraph description>
  Trade-off: <what's gained vs lost>
  Suggestion: <concrete refactor or follow-up>
```

Severity scale per master prompt (CRITICAL = blocks Step 3/4
from implementing the SPEC).

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-arch-r1-audit.md`.

Include a Step 2 → Step 3 readiness matrix in the report (rows:
record-orphan endpoint, record-funding endpoint, pause/resume,
chi mux composition). Each row READY / FRICTION / BLOCKED.

## Discipline

- Frame every finding through "what will Step 3/4 fight?".
- BLOCK only if you can name a SPEC §-rule a future step can't
  implement without unwinding Step 2's choice.

You may run shell commands. You MUST NOT modify any file.

You may take up to 50 min wall-clock.

=== END PROMPT ===
```
