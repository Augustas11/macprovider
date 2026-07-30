# SPEC-016 v0.1.8 Codex Round 10 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.8 at commit `68a942e` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.9.
**Date:** 2026-06-25.

---

## Codex verdict

Audit result: **not converged**.

Counts: **CRITICAL 0, MAJOR 3, MEDIUM 5, LOW 7**. I verified the target at commit `68a942e3314f9eb3af615f0bcec5cdce56aeea52` and checked the ERC-20 constants with `cast`: `transfer(address,uint256) = 0xa9059cbb`, `Transfer(address,address,uint256) = 0xddf252ad...b3ef`.

**MAJOR**
1. [SPEC-016-payout-pipeline.md:1385](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1385) — Post-confirmation value verification catches a substituted signed tx only after funds move.
Scenario: a buggy/compromised `Signer` returns a valid raw tx for a different amount/recipient; the runner persists and broadcasts before §4.3 step 7 detects mismatch.
Fix wording: “After `SignTx` returns and BEFORE persisting or broadcasting, IMPL MUST locally decode `rawSignedTx`, recompute `tx_hash`, recover `from`, and assert nonce, chain_id, to=USDC, value=0, calldata, gas envelope, and sender all match the unsigned tx built by the runner. Any mismatch HALTS before broadcast and emits `payout_chain_value_mismatch mismatch_class='prebroadcast_signed_tx'`.”

2. [SPEC-016-payout-pipeline.md:1348](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1348) and [SPEC-016-payout-pipeline.md:1893](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1893) — Singleton lease is required but not implementable/stale-safe as written.
Scenario: the spec references `(host, pid, started_at_utc)` and heartbeat freshness, but `payout_runner_state` has no owner/heartbeat fields and no stale takeover/self-fencing algorithm.
Fix wording: “Add `payout_runner_lease(holder_host, holder_pid, holder_started_at_utc, holder_token, heartbeat_at_utc)` or equivalent columns. Lease acquire/takeover MUST run in `BEGIN IMMEDIATE`; takeover is allowed only when `heartbeat_at_utc < now - 3 * payout.tuning.run_interval`; every cadence and row MUST re-read `holder_token` and self-halt if ownership changed.”

3. [SPEC-016-payout-pipeline.md:1369](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1369) and [SPEC-016-payout-pipeline.md:2379](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2379) — Per-day cap accounting does not reserve live unbroadcast attempts.
Scenario: if the new lease fails open or two processes run, process A can insert an unbroadcast live attempt, process B’s cap query ignores it because `broadcast_at_utc IS NULL`, then both broadcast and exceed the day cap.
Fix wording: “The §5.3 cap query used inside §4.3 step 4 MUST count live reserved attempts as well as broadcasts: include non-abandoned attempts where `broadcast_at_utc >= :now_minus_24h` OR (`broadcast_at_utc IS NULL AND confirmed_at_utc IS NULL AND updated_at_utc >= :now_minus_24h`). The candidate amount is added before INSERT.”

**MEDIUM**
4. [SPEC-016-payout-pipeline.md:2030](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2030) — Bootstrap sentinel only defines one missing-row direction.
Scenario: sentinel missing but `runtime_flags` already populated is not defined; an implementer may treat sentinel absence as first-ever init and reseed.
Fix wording: “First-ever seed is allowed only when `runtime_flags_bootstrapped`, `runtime_flags`, and `runtime_flag_audit` are all empty. If any runtime table has rows but sentinel id=1 is missing, emit `payout_invariant_violation where='runtime_flags_bootstrap_sentinel_missing'` and HALT.”

5. [SPEC-016-payout-pipeline.md:1778](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1778) and [SPEC-016-payout-pipeline.md:3380](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3380) — Orphan compensation binds to current mutable ledger values.
Scenario: post-orphan mutation of `ledger_payout_ready.provider_credits` changes what compensation is allowed.
Fix wording: “Snapshot `observed_provider_id`, `observed_provider_credits`, `observed_gross_credits`, and `observed_amount_base_units` into `payout_reorg_orphans`; §9.5b.1 MUST bind compensation to those snapshot columns.”

6. [SPEC-016-payout-pipeline.md:3326](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3326) — 422 summary contradicts the detailed orphan-binding rule.
Scenario: summary says gross/operator credits match the original orphaned row; detail correctly says `gross_credits = orig.provider_credits` and `operator_credits = 0`.
Fix wording: “OR orphan-binding mismatch: request provider_id/provider_credits do not match orig.provider_id/orig.provider_credits, request gross_credits != orig.provider_credits, or request operator_credits != 0.”

7. [SPEC-016-payout-pipeline.md:2088](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2088) — Outbox reaper can double-emit flag audit rows.
Scenario: synchronous emitter logs but stalls before `emitted_to_log=1`; after 5 minutes the reaper emits the same row.
Fix wording: “Every emitted flag-audit log MUST include `event_id=runtime_flag_audit.id`; synchronous emitter and reaper MUST claim rows through one compare-and-set path before emitting, and downstream log consumers MUST de-dupe by `event_id`.”

8. [SPEC-016-payout-pipeline.md:3441](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3441) — BetterStack prerequisite list misses new v0.1.8 PAGE events.
Scenario: `payout_chain_value_mismatch` and `payout_runner_lease_conflict` are PAGE in §7.1 but absent from the go-live alert-filter prerequisite list.
Fix wording: “Item 6 MUST require the BetterStack filter to match every §7.1 event with severity=PAGE or WARN, explicitly including `payout_chain_value_mismatch`, `payout_runner_lease_conflict`, and `payout_flag_audit_reaped`.”

**LOW**
- [1419](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1419): replace `||` with `hex_concat(...)` and state 68-byte calldata length.
- [2035](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2035): fix malformed SQL comment around `name='registration_paused'`.
- [2148](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2148): “Both bootstrap triggers” should be “All three bootstrap-related triggers”.
- [2618](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2618): stale §4.3 step 5 reference should be step 6.
- [2814](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2814), [2944](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2944): dangling `§9.6`.
- [3445](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3445): singular `payout_chain_balance_drift` should be `payout_chain_balance_drift_*` or both exact event names.
- [3504](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3504): Appendix B does not explicitly carry all v0.1.7 deferred bullets.

Round-9 closure: the core fixes are present for CRIT-1/CRIT-2/MAJOR-3/4/5/6/7/MED-8/9, but the items above prevent the requested **0/0/0** bar.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-8-commit-68a942e-branch-spec-016-payout--2026-06-25T03-54-29-132Z.md`
- Fix pass commit message: see `git log 68a942e..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.9 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
