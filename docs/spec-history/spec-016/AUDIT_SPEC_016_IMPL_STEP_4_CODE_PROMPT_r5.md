# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 5**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r5.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 2) auditing SPEC-016 Step 4
IMPL — round 5. Architecture lane CONVERGED at r4.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r5.md`. HEAD: `bc1409f`.

The r4 audit returned 0/0/4/1 — recommendation COMMENT (no
HIGH/CRITICAL). The r4 fix-pass landed at `bc1409f`. Verify closure
of all r4 findings + look for new defects + confirm no
regression of r1/r2/r3 closures.

## Files priority focus

r4 fix-pass touched:
- `phase4-coordinator/cmd/coordinator/main.go` (YAML-load failure structured emit)
- `phase4-coordinator/internal/payout/config_tuning.go` (BoundViolationError field rename + Actor field)
- `phase4-coordinator/internal/payout/config_tuning_test.go` (3 new tests)
- `phase4-coordinator/internal/payout/reconcile.go` (hot_wallet field on chain-balance disagreement)
- `phase4-coordinator/internal/payout/rpc_test.go` (CloseIdleConnections + SIGHUP composition tests)
- `phase4-coordinator/internal/payout/runner_test.go` (stale-producer snap.RunInterval test)
- `phase4-coordinator/internal/payout/step4_test.go` (hot_wallet emit test)
- `phase4-coordinator/dist/payout-runbook.md` (SPKI rotation §6 corrections)

## Code-review checklist (r5)

### A. r4 finding closure verification

For each r4 finding, verify CLOSED:
- [code:r4-1]/[sec:r4-1] — YAML-load failure structured emit
- [code:r4-2] — hot_wallet on chain-balance disagreement
- [code:r4-3] — CloseIdleConnections regression test
- [code:r4-4] — Runner.RunOnce stale-producer test proves snap.RunInterval
- [code:r4-5] — BoundViolationError field rename

### B. Structured YAML-load rejection

1. The emit shape exactly matches SPEC §7.1:
   `key, attempted_value, bound, actor, ts_utc, severity`.
2. `attempted_value` is the literal `"config_load_failed"` — NOT the
   raw YAML contents. Verify no path leaks YAML body to the log.
3. `actor` is `"operator_key:coordinator"` (or another non-bearer
   identifier).
4. The unit test
   `TestEmitRejected_YAMLParseFailure_EmitsStructuredS71Fields`
   asserts the field set.

### C. BoundViolationError rename

1. Public fields are `Field, Attempted, Bound, Actor`.
2. All call sites (validateBounds + emitRejected + tests) use the new
   field names.
3. The wire emit names (`key, attempted_value`) are unchanged — these
   are SPEC §7.1 field NAMES, not Go struct field names.
4. `errors.As` extraction from the SIGHUP handler works against the
   renamed type.

### D. CloseIdleConnections tests

1. `TestHTTPRPCClient_CloseIdleConnections` covers:
   (a) nil-receiver safe (defensive)
   (b) real transport: after a request lands an idle conn in the pool,
       CloseIdleConnections empties the pool.
2. `TestSIGHUPCloseIdleComposition` is table-driven and covers:
   (a) SPKI key change → both primary AND secondary clients closed
   (b) non-SPKI key change → NEITHER client closed
   This proves the SIGHUP handler's set-membership check is correct.

### E. Runner stale-producer snap.RunInterval test

1. `TestRunner_RunOnce_StaleProducerUsesLiveSnapRunInterval` exercises
   the boundary: opts.RunInterval=60m (so 3×60=180m threshold) +
   live snap.RunInterval=10m (so 3×10=30m threshold) + seed row at
   31m old.
2. Asserts the stale row IS produced (would fail if RunOnce used
   r.opts.RunInterval).
3. Test reads cleanly and is deterministic.

### F. chain-balance hot_wallet field

1. `payout_chain_balance_rpc_disagreement` emit includes
   `Str("hot_wallet", w.cfg.HotWalletAddr)`.
2. `TestChainBalanceWorker_RPCDisagreementEmitsHotWallet` asserts it.

### G. §7.1 sweep — every Step 4 event

Walk SPEC §7.1 lines 3712-3732 for every Step 4-related event and
verify the implementation emits the §7.1-mandated fields:

- `payout_run_started` — run_id, ts_utc
- `payout_run_finished` — run_id, ts_utc, paid, capped, failed, skipped_no_addr, skipped_funds, error_text
- `payout_run_now_invoked` — run_id, actor, ts_utc (+ outcome as defensive extension)
- `payout_paid` — run_id, payout_id, attempt_seq, provider_id, amount_usdc_base_units, tx_hash, block_number, nonce, ts_utc
- `payout_failed` — run_id, payout_id, attempt_seq, provider_id, stage, error_class, error_text, ts_utc
- `payout_capped` — run_id, payout_id, provider_id, reason, ts_utc
- `payout_low_balance` — from_address, usdc_base_units, threshold_usdc_base_units, ts_utc
- `payout_low_native_balance` — from_address, native_wei, threshold_wei, ts_utc
- `payout_insufficient_funds` — run_id, payout_id, provider_id, required_usdc_base_units, available_usdc_base_units, ts_utc
- `payout_daily_cap_tripped` — run_id, window_paid_usdc_base_units, cap_usdc_base_units, ts_utc
- `payout_reorg_revert` — payout_id, attempt_seq, tx_hash, last_seen_block, rpc_source, is_cancel_self_transfer, observed_via, ts_utc
- `payout_reorg_poll_rpc_error` — payout_id, attempt_seq, tx_hash, rpc_source, error_class, ts_utc
- `payout_rpc_disagreement` — payout_id, attempt_seq, rpc_a_state, rpc_b_state, ts_utc (the SPEC payout-row schema; chain-balance uses payout_chain_balance_rpc_disagreement)
- `payout_chain_balance_drift_positive` — from_address, in_db_expected_usdc_base_units, on_chain_usdc_base_units, drift_usdc_base_units, ts_utc
- `payout_chain_balance_drift_negative` — same as positive + severity=PAGE
- `payout_nonce_cold_start_within_tolerance` — from_address, rpc_a_nonce, rpc_b_nonce, chosen_nonce, ts_utc
- `payout_config_reloaded` — key, old_value, new_value, actor, ts_utc + severity=PAGE
- `payout_config_reload_rejected` — key, attempted_value, bound, actor, ts_utc + severity=PAGE
- `payout_registration_paused` — actor, reason, ts_utc + severity=PAGE

Step 4-specific events not in SPEC §7.1:
- `payout_runner_halted` (Step 4 r1 addition) — verify field set
- `payout_runner_halted_skipping_cycle` (Step 4 r1) — verify
- `payout_balance_probe_rpc_error` (Step 4) — defensive observability
- `payout_chain_balance_rpc_disagreement` (Step 4 r3) — chain-balance-only event
- `payout_chain_balance_rpc_error` (Step 4) — defensive observability

### H. No regressions

Spot-check that the r4 fix-pass did NOT regress:
- r1: TuningProvider plumbing into 4 consumers; runner halt primitive
- r2: RunNowController; SPKI live-read; AST forbidden set; §7.1
  alert field names
- r3: CloseIdleConnections; runner stale-producer snap.RunInterval;
  RunOnce run_id correlation; payout_config_* field names; chain-
  balance event rename; halt-race interface

### I. Tests + race

- `go test -count=1 ./...` from `phase4-coordinator/` — clean
- `go test -race -count=1 ./internal/payout/...` — clean
- `git diff --check bc1409f^..bc1409f` — clean

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-code-r5-audit.md`. Standard structure.

**If 0/0/0/0 — declare CONVERGENT.** This is the FINAL audit round
before PR-open. If you find any defect, please grade it precisely
so the human can decide whether to fix-pass again or defer.

## Discipline

- Don't re-flag closed findings; verify closure.
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```
