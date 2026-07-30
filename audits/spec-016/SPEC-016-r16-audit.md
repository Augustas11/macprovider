# SPEC-016 v0.1.14 Codex Round 16 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.14 at commit `7f7a4b4` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.15.
**Date:** 2026-06-25.

---

## Codex verdict

NOT CONVERGED — 0 CRITICAL, 0 MAJOR, 3 MEDIUM, 0 new LOW. The 4 known LOWs remain intentionally deferred.

**Findings**
MEDIUM-1 — Confirmed cancel event is specified as repeatable, not transition-only  
[file:2221](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2221)

Implementer-confusion path: §4.3 says every pre-check that sees `confirmed_at_utc IS NOT NULL` MUST emit `payout_cancel_self_transfer_confirmed`. A confirmed cancel row remains live/non-abandoned, so if fresh non-cancel allocation is blocked or delayed, later cycles can re-emit the same “confirmed” event. That breaks the “per-cancel-confirmation” contract in the changelog and makes INFO logs non-canonical.

Paste-ready fix:

```md
This event is emitted exactly once when the runner first transitions a
cancel self-transfer row from unconfirmed to confirmed, i.e. the
UPDATE that changes `confirmed_at_utc` from NULL to non-NULL after
cancel-specific §4.3 step 7 verification. A later pre-check that sees
an already-confirmed cancel row MUST NOT re-emit
`payout_cancel_self_transfer_confirmed`; it only treats the nonce gap
as filled and proceeds to fresh non-cancel allocation. §7.4 query (D)
is the crash-recovery canonical roll-up if the process dies after the
DB transition but before the INFO log emits.
```

MEDIUM-2 — `payout_reorg_revert` discriminator is required in §4.7 but missing from §7.1 event schema  
[file:3019](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3019), [file:4475](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:4475)

Implementer-confusion path: cancel reorg recovery requires emitting `payout_reorg_revert` with `is_cancel_self_transfer=1`, but the §7.1 minimum field table omits that field. A cold IMPL can satisfy the table while dropping the only log-level discriminator between provider-payout reorgs and cancel reorgs.

Paste-ready fix:

```md
| `payout_reorg_revert` | `payout_id, attempt_seq, tx_hash, last_seen_block, rpc_source, is_cancel_self_transfer, ts_utc` |

`is_cancel_self_transfer` MUST be present on every
`payout_reorg_revert` event: provider-payout reorgs emit `0`/`false`;
cancel self-transfer reorgs emit `1`/`true`.
```

MEDIUM-3 — Reorg-reactivated cancel has an operator path, but no objective stale/not-found trigger  
[file:3056](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3056)

Implementer-confusion path: the reorg path clears `confirmed_at_utc` while leaving `broadcast_at_utc IS NOT NULL`, so §4.3 will poll as broadcast-unconfirmed. The spec says if it “permanently fails to re-confirm” the operator MUST abandon-and-replace, but it does not define when both RPCs returning not found becomes operator-actionable. A literal IMPL can poll forever and silently hold fresh payouts for that `payout_id`.

Paste-ready fix:

```md
If a cancel row reactivated by this §4.7 path remains
`broadcast_at_utc IS NOT NULL AND confirmed_at_utc IS NULL` and BOTH
RPCs return "not found" for longer than `3 * payout.tuning.run_interval`
measured from the `updated_at_utc` written by the reorg UPDATE, the
runner MUST emit `payout_cancel_self_transfer_reconfirm_stale`
(severity=PAGE) with
`run_id, payout_id, attempt_seq, nonce, tx_hash, last_seen_block,
updated_at_utc, ts_utc`, and MUST continue to HALT fresh non-cancel
allocation until the operator resolves it via §4.6 abandon-and-replace.
This is an operator-recovery signal only; automatic re-signing remains
FORBIDDEN.
```

**Closure Checks**
Round-15 MAJOR-1 is substantively closed: cancel INSERT persists `broadcast_at_utc = NULL`, post-commit preflight checks nonce/chain/to/value/input/fees/hash/ecrecover, and CAS stamps only accepted cancels with the correct predicates. Both-RPC rejection leaves NULL for rebroadcast.

Round-15 MAJOR-2 is substantively closed: §4.7 is provider-only for `is_cancel_self_transfer = 0`, and cancel reorg recovery avoids `payout_reorg_orphans`, avoids `ledger_payout_ready`, and reactivates the cancel row in `BEGIN IMMEDIATE` gated on `abandoned_at_utc IS NULL`.

Round-15 MEDIUM-1 is only partially closed because the event/query exist, but event emission is not transition-scoped.

**Hygiene**
Verified branch/commit: `spec/016-payout-pipeline-v0.1` at `7f7a4b4`. `git diff --check` is clean; fenced code blocks are balanced. Query (D) uses existing `payout_attempts` columns only. The 4 deferred round-11 LOWs are still explicitly carried in the changelog.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-14-commit-7f7a4b4-branch-spec-016-payout-2026-06-25T05-23-05-776Z.md`
- Fix pass commit message: see `git log 7f7a4b4..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.15 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
