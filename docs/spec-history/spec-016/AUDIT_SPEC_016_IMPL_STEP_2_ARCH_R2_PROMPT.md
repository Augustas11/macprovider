# IMPL audit prompt — SPEC-016 Step 2, **ARCHITECTURE REVIEW lane, round 2**

Round 2 of the architect lane against the Step 2 r1 fix-pass.
Branch `impl/spec-016` HEAD: `3653516`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 2
IMPL — round 2. Round 1 returned 0/2 MAJOR/2 MEDIUM/1 LOW
(FIX-THEN-PROCEED). The fix-pass commit `3653516` addresses
both MAJORs and both MEDIUMs. The LOW [arch:3.5] is a deferred
SPEC v0.1.22 candidate.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.
Step 2 IMPL HEAD at `3653516`.

## Your r2 verification scope

### Verify [arch:3.1] MAJOR closure — runner lifecycle

`setupPayout` now constructs the Runner with billing.Store as
Claimer; Acquire happens immediately before NewRunner. The
returned `payoutS2` carries (runner, reorg, state, stop).

Main.go (line ~318):
- calls `setupPayout(..., billingStore, ...)` — passes the
  PayoutClaimer.
- mounts `payoutMuxHandler` at BOTH `/providers/` AND
  `/admin/payout/`.
- `payoutS2.runner.Start(shutdownCtx)` after wiring.
- `startPayoutReorgPoller(shutdownCtx, payoutS2.reorg, RunInterval, ...)`.

Shutdown handler (line ~382):
- `stopBackground()` then `payoutS2.stop(stopCtx)` which calls
  `runner.Stop` then `Release`.

Probe:
- A clean SIGINT: runner finishes in-flight cycle; lease deleted.
- A SIGTERM during a payout cycle: 30s timeout; runner.Stop
  blocks until cycle completes; Release deletes the lease.
- payout.enabled=false: payoutS2 is nil; signal handler skips
  the payout shutdown branch (verify the nil check).

### Verify [arch:3.2] MAJOR closure — admin mux mounting

Probe end-to-end with curl simulation (or trace through code):
- POST /providers/{id}/payout-address → §3.3 handler (provider
  token auth)
- POST /admin/payout/abandon-attempt → operator-key middleware
  → AbandonService (chi route)
- POST /admin/payout/run-now → operator-key middleware → runner.RunOnce

Probe edge:
- /admin/payout/* without Authorization → 401
- /admin/payout/{unknown} → 404 via chi
- /providers/{id}/earnings → fallback handler (billing)
- /admin/payout/abandon-attempt with wrong operator key → 401

### Verify [arch:3.3] MEDIUM closure — SPKI pinning

`NewHTTPRPCClient(url, label, spkiPin, timeout)` now installs
a tls.Config with `VerifyPeerCertificate` when spkiPin is set.
`makeSPKIPinVerifier` compares sha256(cert.RawSubjectPublicKeyInfo)
against the pin.

Probe:
- spkiPin="" → no pinning (open TLS); test passes
- spkiPin=valid 64-hex but wrong → connection fails with
  "SPKI pin mismatch"
- Main.go threads cfg.Payout.Tuning.RPCURLPrimary/SecondaryPinSPKI
  to the constructor.

### Verify [arch:3.4] MEDIUM closure — §7.1 field sets

Walk the emit sites and assert §7.1 table compliance:
- `payout_run_started` — run_id, ts_utc (was complete already)
- `payout_run_finished` — run_id, paid, capped, failed,
  skipped_no_addr, skipped_funds, error_text, ts_utc
- `payout_paid` — run_id, payout_id, attempt_seq, provider_id,
  amount_usdc_base_units, tx_hash, block_number, nonce, ts_utc
- `payout_failed` — run_id, payout_id, attempt_seq, provider_id,
  stage, error_class, error_text, ts_utc
- `payout_capped` — run_id, payout_id, provider_id, reason, ts_utc
- `payout_signer_unavailable` — from_address, error_class, ts_utc
- `payout_invariant_violation` — where, detail, ts_utc, plus
  payout_id (Step 2's emitter)

Flag any event that still drops a §7.1 field. Architect lens:
do we need a typed event emitter helper to prevent drift?

### Validate [arch:3.5] LOW deferral

Re-read `specs/SPEC-016-IMPL-STEP_2-r1-deferrals.md` and confirm
the §4.7 SPEC drift is still SPEC-side, still tracked for SPEC
v0.1.22, and Step 2 reorg.go doesn't encode the broken SQL.

### Step 2 → Step 3 readiness re-assessment

| Row | r1 verdict | r2 verdict |
|-----|------------|------------|
| record-orphan endpoint | FRICTION | ? |
| record-funding endpoint | FRICTION | ? |
| pause/resume | FRICTION | ? |
| chi mux composition | BLOCKED | ? |

Probe Step 4 readiness too: is the runtime tuning ready for
SIGHUP hot-reload in Step 4 (or is the value-capture still a
problem)? Flag any pre-emptive seam needed.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-arch-r2-audit.md`.

Standard structure + Step 2 → Step 3 readiness matrix update.

## Discipline

- Frame every finding through "what will Step 3/4 fight?".
- BLOCK only on named SPEC §-rule violation a future step can't
  unwind.

You may take up to 30 min wall-clock.

=== END PROMPT ===
```
