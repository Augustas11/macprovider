# SPEC-016 v0.1.13 Codex Round 15 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.13 at commit `3cf8658` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.14.
**Date:** 2026-06-25.

---

## Codex verdict

**NOT CONVERGED — 0 CRITICAL / 2 MAJOR / 1 MEDIUM**

Round-14 closure itself is present: §4.3 step 5 filters `is_cancel_self_transfer = 0`, live cancel rows are pre-checked, cancel confirmation uses cancel-specific constants, `ClaimPayoutReady` is forbidden for cancels, and §7.1 includes `cancel_self_transfer_mismatch`.

**MAJOR-1 — cancel broadcast path lacks provider-grade preflight + can strand a never-broadcast cancel**

Refs: [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2055), [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2569)

Confusion/attack path: §4.6 says the abandon endpoint signs and persists cancel `raw_signed_tx + tx_hash + broadcast_at_utc` before commit, but actual `eth_sendRawTransaction` happens after commit. If the process crashes or both RPC sends fail after commit, the row looks broadcast because `broadcast_at_utc` is non-null. The new §4.3 cancel pre-check then treats it as “broadcast, unconfirmed” and only polls, so it may never rebroadcast the bytes it was supposed to recover.

The same path also lacks the §4.3 step 6 pre-broadcast Signer-output verification. A compromised Signer can return a malicious signed cancel envelope, and the spec only catches it after confirmation via cancel-specific verification, after funds/gas may already have moved.

Paste-ready fix:

```md
**Cancel self-transfer broadcast discipline (NORMATIVE).**
The §4.6 cancel-row INSERT MUST persist `raw_signed_tx` and
`tx_hash` with `broadcast_at_utc = NULL`. `broadcast_at_utc`
MUST be set only after at least one configured RPC accepts
`eth_sendRawTransaction` for the exact persisted bytes.

Before any §4.6 initial cancel broadcast or §4.3 cancel
rebroadcast, IMPL MUST locally decode the persisted signed
envelope and assert: `nonce == payout_attempts.nonce`,
`chain_id == 8453`, `to == payout.security.hot_wallet_address`,
`value == 1 wei`, `input` is empty, fee fields are within the
§4.6 capped values, locally recomputed `tx_hash` equals the
stored/returned tx hash, and ecrecover(sender) equals
`payout.security.hot_wallet_address`. Any mismatch MUST emit
`payout_chain_value_mismatch mismatch_class='prebroadcast_signed_tx'`
and MUST NOT broadcast.

After at least one RPC accepts the send, stamp broadcast with a
CAS:
`UPDATE payout_attempts SET broadcast_at_utc=:now, updated_at_utc=:now
 WHERE payout_id=:payout_id AND attempt_seq=:attempt_seq
 AND is_cancel_self_transfer=1 AND broadcast_at_utc IS NULL
 AND confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL`.
If both RPCs reject, leave `broadcast_at_utc` NULL so the next
cadence's unbroadcast-cancel branch rebroadcasts bit-for-bit.
```

**MAJOR-2 — confirmed cancel reorg recovery is not specified**

Ref: [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2760)

Confusion path: §4.7 is written for provider payouts: consumed ledger rows, `payout_external_id`, `payout_reorg_orphans`, and compensation. Cancel rows do not consume `ledger_payout_ready`. If a confirmed cancel is reorged out, the nonce gap is live again, but §4.3 will still see `confirmed_at_utc IS NOT NULL` and proceed to fresh allocation. A cold IMPL could apply the provider orphan flow to a cancel and never refill the nonce gap.

Paste-ready fix:

```md
§4.7 applies to provider-payout attempts only when
`is_cancel_self_transfer = 0`.

If a previously confirmed cancel self-transfer
(`is_cancel_self_transfer = 1`) is no longer canonical on either RPC,
IMPL MUST emit `payout_reorg_revert` with
`is_cancel_self_transfer=1`, MUST NOT insert
`payout_reorg_orphans`, MUST NOT call or affect
`ledger_payout_ready`, and MUST mark the cancel row live again in one
`BEGIN IMMEDIATE` transaction:
`confirmed_at_utc=NULL, block_number=NULL, gas_used_native_wei=NULL,
last_error='cancel_self_transfer_reorged:<tx_hash>',
updated_at_utc=:now`
provided the row is still non-abandoned. The next §4.3 cancel
pre-check MUST halt fresh non-cancel allocation and rebroadcast/poll
the existing cancel bytes until the nonce gap is filled or the
operator abandons/replaces the cancel via §4.6.
```

**MEDIUM-1 — “record cancel confirmation in §7.4 observability” is not concrete**

Refs: [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:2070), [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:4294)

Confusion path: §4.3 says to record confirmed cancels in §7.4 observability, but §7.4 has no cancel-specific query or record. Existing reconciliation intentionally excludes `is_cancel_self_transfer=1`, so an IMPL author could set `confirmed_at_utc` and miss the intended operator-visible audit surface.

Paste-ready fix:

```md
On cancel confirmation, IMPL MUST update `confirmed_at_utc`,
`block_number`, and `gas_used_native_wei` on the cancel row and emit:

`payout_cancel_self_transfer_confirmed`
fields: `run_id, payout_id, attempt_seq, nonce, tx_hash,
block_number, gas_used_native_wei, ts_utc`.

§7.4 MUST include a cancel observability query:
`SELECT payout_id, attempt_seq, nonce, tx_hash, confirmed_at_utc,
block_number, gas_used_native_wei
 FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND confirmed_at_utc >= :from_utc
   AND confirmed_at_utc < :to_utc
 ORDER BY confirmed_at_utc ASC;`
This query is observability only and MUST NOT be included in provider
outflow sums.
```

**Hygiene Evidence**

Fences are balanced, `git diff --check 3cf8658^..3cf8658 -- specs/SPEC-016-payout-pipeline.md` is clean, and the four deferred round-11 LOWs remain explicitly listed. v0.1.13 did not introduce a markdown-structure failure.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-13-commit-3cf8658-branch-spec-016-payout-2026-06-25T05-13-25-544Z.md`
- Fix pass commit message: see `git log 3cf8658..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.14 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
