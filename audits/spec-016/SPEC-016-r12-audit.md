# SPEC-016 v0.1.10 Codex Round 12 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.10 at commit `6749491` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.11.
**Date:** 2026-06-25.

---

## Codex verdict

NOT CONVERGED — 0 CRITICAL, 1 MAJOR, 0 MEDIUM, 4 known-open LOW.

**MAJOR-1 — CAS persist is not fenced against concurrent abandon/state changes**

`/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1769`

The v0.1.10 CAS only gates on `raw_signed_tx IS NULL`. While the runner is signing, `/admin/payout/abandon-attempt` can mark the same attempt abandoned and insert/broadcast a cancel row (`:2100`). The runner can then still CAS-persist and broadcast the original provider-transfer envelope because it never checks `abandoned_at_utc`, `confirmed_at_utc`, or row existence.

Attacker/confusion path: an operator-key holder races abandon against step 6 signing. The original payout tx and cancel tx then compete at the same nonce. If the original confirms after being marked abandoned, it is excluded from cap/reconciliation queries that filter `abandoned_at_utc IS NULL`, and later fresh attempts can exceed intended cap/accounting semantics.

Paste-ready fix wording:

```md
In §4.6, `/admin/payout/abandon-attempt` MUST reject with
409 `runner_active` unless no fresh `payout_runner_lease` row exists
(`heartbeat_at_utc < now - 3 * payout.tuning.run_interval`) or the
operator has first disabled/stopped the runner and released the lease.
The lease check MUST run in the same `BEGIN IMMEDIATE` transaction as
the abandon marker and cancel-row INSERT.

In §4.3 step 6, replace the CAS predicate with:

WHERE payout_id = :payout_id
  AND attempt_seq = :attempt_seq
  AND raw_signed_tx IS NULL
  AND confirmed_at_utc IS NULL
  AND abandoned_at_utc IS NULL

If the CAS affects 0 rows, the IMPL MUST re-read the row. If no row
exists, or `abandoned_at_utc IS NOT NULL`, or `confirmed_at_utc IS NOT
NULL`, discard the just-signed envelope, do NOT broadcast, do NOT log
the raw signed bytes, emit `payout_invariant_violation
where='attempt_state_changed_during_sign'`, and halt. Only if an
existing non-abandoned, unconfirmed row already has `raw_signed_tx IS
NOT NULL` may the runner discard the just-signed envelope and use the
persisted bytes.
```

**Known-Open LOWs**

LOW-1: `payout_runner_lease_conflict` is still used for post-acquire token loss at `:1660`; should say `payout_runner_lease_lost`.

LOW-2: reaper CAS shorthand still omits `RETURNING id` at `:2695`; sync emitter has it at `:2677`.

LOW-3: section order remains `§4.8`, `§4.8b`, `§4.8a` at `:2340`, `:2430`, `:2548`.

LOW-4: stale “§4.3 step 5 change” reference remains at `:3307`; should be step 6.

**Closure Checks**

Round-11 MAJOR-1 is otherwise closed: stale halt runs before the cap sum inside the same `BEGIN IMMEDIATE` (`:3017`), and the cap query counts all non-abandoned unbroadcast rows with no age bound (`:3048`).

MED-1 is closed: `prebroadcast_signed_tx` is in the §7.1 enum (`:3625`).

MED-2 is closed: BetterStack now requires one synthetic alert per event name, not per tier (`:4187`).

Markdown fences are balanced; I did not find revived `§9.6` dangling refs.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-10-commit-6749491-branch-spec-016-payout-2026-06-25T04-51-34-762Z.md`
- Fix pass commit message: see `git log 6749491..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.11 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
