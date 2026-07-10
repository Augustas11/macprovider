# SPEC-016 v0.1.9 Codex Round 11 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.9 at commit `72d2c14` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.10.
**Date:** 2026-06-25.

---

## Codex verdict

Audit verdict for SPEC-016 v0.1.9 at `72d2c14`: not converged. I found **0 CRITICAL, 2 MAJOR, 2 MEDIUM, 4 LOW**.

**CRITICAL**
None.

**MAJOR**
1. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2828) — Stale live reservations age out of the day-cap query while still live.
§5.3 excludes unbroadcast live attempts once `updated_at_utc < now_minus_24h`, but the row remains non-abandoned and can still be recovered/broadcast later. A crash after attempt INSERT and before signing/broadcast can leave a live row with `broadcast_at_utc IS NULL`; after 24h it no longer counts against the cap, allowing later new reservations plus the stale attempt to exceed the intended rolling cap.
Paste-ready fix: “Unbroadcast non-abandoned attempts MUST NOT silently age out of cap accounting. Before the §5.3 cap sum, in the same `BEGIN IMMEDIATE` transaction, IMPL MUST detect any `broadcast_at_utc IS NULL AND confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL AND updated_at_utc < :now_minus_24h`; if any exist, HALT with `payout_invariant_violation where='stale_unbroadcast_attempt'` until the operator abandons or deterministically recovers them. The cap query MUST count all non-abandoned unbroadcast attempts regardless of age.”

2. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2304) — Step-6 self-fencing is only a standalone pre-step read, so takeover can happen before signing/persist/broadcast.
A runner can pass the token read before step 6, stall past the stale window, get taken over, then resume and sign/persist/broadcast. With nondeterministic ECDSA, both old and new holders can produce different valid tx hashes for the same nonce; §4.3’s ecrecover check only proves each envelope is valid, not that exactly one envelope won the attempt row. Chain nonce prevents two confirmations, but DB receipt tracking can chase the wrong hash after funds moved.
Paste-ready fix: “For §4.3 step 6, self-fencing MUST be repeated after `SignTx` and before any `payout_attempts` update. Persist `raw_signed_tx`, `tx_hash`, and `broadcast_at_utc` with a `BEGIN IMMEDIATE` CAS: re-read `holder_token`, require it matches the acquired token, and update only `WHERE raw_signed_tx IS NULL`. If token mismatch or CAS loses, discard the just-signed envelope and halt with `payout_runner_lease_lost`; if bytes already exist, only rebroadcast the persisted bytes. Re-read the holder token immediately before `eth_sendRawTransaction`; if lost after persistence, do not broadcast and let the current holder rebroadcast the persisted bytes.”

**MEDIUM**
1. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3397) — §7.1 omits the new `prebroadcast_signed_tx` enum value.
§4.3 mandates `mismatch_class='prebroadcast_signed_tx'`, but the canonical §7.1 field enum does not include it. Implementers or alert parsers built from §7.1 can reject/drop the new signer-compromise alert.
Paste-ready fix: add `prebroadcast_signed_tx` to the `payout_chain_value_mismatch` `mismatch_class` list.

2. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3959) — BetterStack verification requires only one synthetic alert per severity tier.
The filter must match every PAGE/WARN event, but “one per severity tier minimum” would not catch a typo or missing matcher for a specific event such as `payout_runner_lease_lost`.
Paste-ready fix: “Operator MUST verify with one synthetic alert for EACH enumerated PAGE/WARN event name before `payout.enabled: true`; one per severity tier is insufficient.”

**LOW**
1. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1531) — Self-fence mismatch emits `payout_runner_lease_conflict` in §4.3, but §4.8b says `payout_runner_lease_lost`.
Fix: use `payout_runner_lease_lost` for token mismatch after acquisition; reserve `payout_runner_lease_conflict` for acquire failure.

2. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2505) — Reaper CAS shorthand omits `RETURNING id`.
Fix: make the reaper SQL mirror the sync emitter exactly: `UPDATE runtime_flag_audit SET emitted_to_log=1 WHERE id=<row id> AND emitted_to_log=0 RETURNING id`.

3. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2240) — Section order is `4.8`, `4.8b`, then `4.8a`.
Fix: place `4.8a Runtime flags` before `4.8b Singleton-runner lease`, or rename to unlettered `4.8.1` / `4.8.2`.

4. [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:3079) — Stale step reference says no §4.3 step 5 change is required for Signer behavior.
Fix: change to “no §4.3 step 6 change”.

Round-10 closure summary: MAJOR-1 is substantively closed except the §7.1 enum miss; MAJOR-2 is not fully closed due step-6 self-fencing/CAS gap; MAJOR-3 is not fully closed due stale reservation expiry. MED-4/5/6 are clean. MED-7 has a low wording gap. MED-8 is partially closed but the synthetic-alert test is too weak. LOW-9 through LOW-15 mostly landed, with new low hygiene issues above.

No finding on SQLite deadlock between lease and runtime flags: `BEGIN IMMEDIATE` uses SQLite’s single writer lock, so this serializes rather than deadlocks. No finding on observed snapshot atomicity: §4.7 requires population at INSERT time from joins and immutable use in §9.5b.1.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-9-commit-72d2c14-branch-spec-016-payout--2026-06-25T04-33-06-446Z.md`
- Fix pass commit message: see `git log 72d2c14..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.10 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
