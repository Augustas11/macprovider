# SPEC-016 v0.1.7 Codex Round 9 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.7 at commit `5f6266d` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.8.
**Date:** 2026-06-25.

---

## Codex verdict

Audit verdict: bar not met. Reviewed commit `5f6266d` on `spec/016-payout-pipeline-v0.1`; primary file was [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1). I found CRITICAL/MAJOR issues that should drive v0.1.8.

**CRITICAL**

1. [SPEC-016-payout-pipeline.md:2919](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2919) — Compensation insert is not bound to the original orphan’s provider/amount.

The §9.5b.1 check only proves an unresolved orphan exists for `(payout_id, attempt_seq)`. It does not require the admin insert’s `provider_id`, `provider_credits`, or `gross_credits` to match the original orphaned `ledger_payout_ready` row. A SPEC-005 author can implement this literally and let a compromised operator key use one real orphan as authorization to create a compensation row for the wrong provider or inflated amount, bounded only by per-call/per-day caps.

Paste-ready fix:

```md
The SPEC-005 IMPL MUST bind the compensation row to the original orphaned payout row in the SAME SQLite transaction as the INSERT. After parsing `orig_payout_id` and `orig_attempt_seq` from `idempotency_key`, join `payout_reorg_orphans pro` to `ledger_payout_ready orig ON orig.id = pro.payout_id` and require: `pro.payout_id = <orig_payout_id>`, `pro.attempt_seq = <orig_attempt_seq>`, `pro.compensation_settlement_id IS NULL`, request `provider_id = orig.provider_id`, request `provider_credits = orig.provider_credits`, request `gross_credits = orig.provider_credits`, and request `operator_credits = 0`. Miss or mismatch returns 422 `orphan_mismatch`.
```

2. [SPEC-016-payout-pipeline.md:1147](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1147) — Fresh-attempt creation lacks a live per-payout guard.

§4.3 orders cap check, attempt lookup, nonce allocation, and attempt persistence, but does not require a DB-backed singleton runner lease or a live non-cancel unique index. The existing per-payout unique index only applies after confirmation at lines 1281-1283. A multi-process deployment bug or run-now/cadence overlap can produce two pending non-cancel attempts for the same `payout_id`, with different nonces; one later claim loses, but both chain transfers can already be paid.

Paste-ready fix:

```md
§4.3 steps 1-5 MUST run under a DB-backed singleton runner lease and a `BEGIN IMMEDIATE` transaction for each fresh attempt. The transaction MUST re-read the row, re-run §5 caps, allocate the nonce, and insert the `payout_attempts` row before signing.

CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_live_non_cancel_per_payout
    ON payout_attempts(payout_id)
 WHERE abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;
```

**MAJOR**

3. [SPEC-016-payout-pipeline.md:1167](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1167) — Receipt confirmation does not verify the ERC-20 transfer log.

Step 6 only requires receipt agreement on `tx_hash`, `block_number`, `status`, and `to`; for USDC, `to` is just the token contract. A calldata/signing bug can produce a successful tx that does not transfer `amount_base_units` to `effective_address`, and §7.4 sums DB values rather than chain logs.

Fix wording:

```md
Step 6 receipt confirmation MUST verify on BOTH RPC receipts: `block_hash`, exact transaction input equals ABI `transfer(effective_address, amount_base_units)`, recovered sender equals `payout.security.hot_wallet_address`, and exactly one USDC `Transfer` log from hot wallet to `effective_address` for `amount_base_units`.
```

4. [SPEC-016-payout-pipeline.md:909](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:909) — Registration pause has a TOCTOU window.

The pre-auth 503 ordering is pinned, but there is no final pause check inside the `provider_payout_addresses` INSERT/UPDATE transaction. A request can pass the early check, then the operator pauses for rotation, then the in-flight request commits a row stamped against the old hot wallet.

Fix wording:

```md
The §3.3 handler MUST perform two pause checks: the existing pre-auth check, and a final check inside the SAME SQLite transaction that INSERTs/UPDATEs `provider_payout_addresses`. Use `BEGIN IMMEDIATE`, read `runtime_flags.value WHERE name='registration_paused'`, and rollback with 503 `rotation_in_progress` if value=1.
```

5. [SPEC-016-payout-pipeline.md:1696](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1696) — Runtime flag/event atomicity is impossible as written.

§4.8a says the flag update occurs in the same SQLite transaction that emits the §7.1 PAGE event, but §7.1.1 makes events journalctl/zerolog-only. A log write cannot be transactionally atomic with SQLite.

Fix wording:

```md
Every §6.4.1 endpoint MUST update `runtime_flags` and insert a durable SQL audit/outbox row in the SAME SQLite transaction. After commit, emit the §7.1 zerolog event from the committed row. If the SQL audit/outbox insert fails, rollback the flag update.
```

6. [SPEC-016-payout-pipeline.md:1684](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1684) — `INSERT OR IGNORE` can fail open after row deletion.

If `registration_paused` is deleted by a bad migration or raw DB write during rotation, startup recreates it as `0`, contradicting the restart-persistence guarantee.

Fix wording:

```md
The `runtime_flags` bootstrap seed is allowed only during first-ever DB initialization. On later startup, missing/duplicate/invalid `registration_paused` MUST emit `payout_invariant_violation` and halt before accepting traffic; startup MUST NOT recreate a missing runtime flag as value 0.
```

7. [SPEC-016-payout-pipeline.md:1773](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1773) — Manual-funding trigger assertion omits the one-way trigger.

The §4.9 same-transaction assertion checks only the two auto-flip triggers, not `trg_prs_bootstrap_one_way`, which prevents resetting `payout_bootstrap_complete` from 1 to 0.

Fix wording: require all three bootstrap triggers and reject `bootstrap_trigger_missing` unless `count = 3`.

**MEDIUM**

8. [SPEC-016-payout-pipeline.md:2848](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2848) — `Idempotency-Key` header and JSON `idempotency_key` are unrelated.

Replay behavior references the header, while reconciliation depends on the body/DB key. Require equality and use `ledger_payout_ready.idempotency_key` for replay detection.

9. [SPEC-016-payout-pipeline.md:2878](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2878) — SPEC-005 split invariant is under-specified.

The contract rejects only `provider_credits > gross_credits`, while SPEC-005 requires `provider_credits + operator_credits == gross_credits`. Since `operator_credits` is pinned to 0, require `gross_credits == provider_credits`.

**No Finding**

§6.5 namespace bucketing is clean in §3-§9: I found only `payout.security.*`, `payout.tuning.*`, and the explicit `payout.enabled` singleton carve-out. §3.3’s 503 body/event/pre-auth ordering is normatively pinned and matches §7.1.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-7-commit-5f6266d-branch-spec-016-payout--2026-06-25T03-36-52-213Z.md`
- Fix pass commit message: see `git log 5f6266d..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.8 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
