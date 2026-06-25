# SPEC-016 v0.1.11 Codex Round 13 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.11 at commit `0fba334` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.12.
**Date:** 2026-06-25.

---

## Codex verdict

NOT CONVERGED

Verdict: 0 CRITICAL, 0 MAJOR, 1 MEDIUM. The round-12 MAJOR closure mostly landed, but v0.1.11 introduced one §4.6 SQL-contract ambiguity that an IMPL audit would re-flag.

**MEDIUM**
1. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2351) — §4.6 new runner-active SQL block can still abandon already-confirmed or already-abandoned attempts if copied literally.

Scenario: the response table says `409 Conflict — attempt already confirmed; nothing to abandon` at lines 2289-2290, but the new normative SQL block updates by only `(payout_id, attempt_seq)`. A cold implementer can mark a confirmed payout attempt abandoned, which removes it from “confirmed non-abandoned” reconciliation queries and breaks the canonical receipt/audit model. This is not an immediate double-payment path by itself because `ledger_payout_ready` should already be consumed, but it is a contract gap in the money-out state machine.

Paste-ready fix:

```sql
UPDATE payout_attempts
   SET abandoned_at_utc = :now,
       abandoned_reason = :reason,
       updated_at_utc   = :now
 WHERE payout_id = :payout_id
   AND attempt_seq = :attempt_seq
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL;
-- If row count = 0, IMPL MUST re-read the row in this SAME
-- BEGIN IMMEDIATE transaction and return without inserting a
-- cancel row:
--   - no row exists: 404 not_found
--   - confirmed_at_utc IS NOT NULL: 409 already_confirmed
--   - abandoned_at_utc IS NOT NULL: 409 already_abandoned
-- The cancel-row INSERT is permitted ONLY after the UPDATE
-- affects exactly one live, unconfirmed row.
```

**LOW**
1. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1899) — “FK on `payout_runner_lease`” is factually wrong. `payout_attempts` has no FK to the lease table.

Paste-ready fix:

```text
no row exists: should be impossible because §4.3 steps 3-5 just INSERTed the row and `payout_attempts.payout_id` references `ledger_payout_ready(id) ON DELETE RESTRICT`; SPEC-016 defines no FK cascade that can delete it.
```

2. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1925) — side-channel prohibition is normative, but no required IMPL test catches accidental logging of discarded envelope data.

Paste-ready fix:

```text
IMPL test required: force each discard-envelope path (`attempt_state_changed_during_sign`, already-persisted bytes, and lease-lost-after-sign) with a fake Signer and captured zerolog output. Assert no log field or message contains `raw_signed_tx`, the discarded envelope's `tx_hash`, any `discarded_tx_hash`-style alias, or sign+CAS duration/timing fields. The only allowed invariant fields are `(payout_id, attempt_seq, where, detail, ts_utc)`.
```

3. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3542) — §6.4 rotation step 2 references §4.6, but does not remind operators that v0.1.11 may return `runner_active` until the lease is released or stale.

Paste-ready fix:

```text
If §4.6 returns `409 {"error":"runner_active"}` during this step, follow the §4.6 runner-stop runbook: wait for the `payout.enabled: false` stop to release the lease, restart the coordinator for clean lease release, or wait up to `3 * payout.tuning.run_interval` for lease staleness before retrying abandon.
```

**Known-Open LOWs Still Deferred**
The four round-11 LOWs remain LOW and did not elevate:
- §4.3 self-fencing still uses `payout_runner_lease_conflict` where `payout_runner_lease_lost` would be clearer: line 1766.
- §4.8a reaper CAS shorthand still omits `RETURNING id`: line 2923.
- Section order remains §4.8 → §4.8b → §4.8a: lines 2658 and 2776.
- Stale “§4.3 step 5” signer-behavior cross-ref remains: line 3535.

**Closure Check**
Round-12 MAJOR-1 runner side is closed: CAS includes `raw_signed_tx IS NULL`, `confirmed_at_utc IS NULL`, and `abandoned_at_utc IS NULL` at lines 1879-1883, with same-transaction disambiguation at lines 1897-1921 and side-channel discipline at lines 1925-1935.

Operator side is mostly closed: `runner_active` response/runbook lands at lines 2292-2323 and 2362-2372, and the lease check is in the same `BEGIN IMMEDIATE` block as the abandon update/cancel insert at lines 2332-2359. The remaining MEDIUM is the missing live-row predicate and row-count disambiguation inside that new block.

I also checked the v0.1.11 diff, markdown fence count, `§9.6` references, lease staleness alignment with §4.8b, and the replay/MEV/signer/reorg/race/operator-key surfaces. No CRITICAL or MAJOR path surfaced.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-11-commit-0fba334-branch-spec-016-payout-2026-06-25T04-59-09-375Z.md`
- Fix pass commit message: see `git log 0fba334..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.12 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
