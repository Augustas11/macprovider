# IMPL audit prompt — SPEC-016 Step 2, **SECURITY REVIEW lane, round 2**

Round 2 of the security-review lane against the Step 2 r1
fix-pass. Branch `impl/spec-016` HEAD: `3653516`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016
Step 2 IMPL — round 2. Round 1 returned 0/3 HIGH/0/0 (HIGH risk).
The fix-pass commit `3653516` addresses all 3 HIGHs plus the
two MAJORs that overlapped with security concerns.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.
Step 2 IMPL HEAD at `3653516`.

## Your r2 verification scope

### Verify [sec:2.1] HIGH closure — 24h gas cap with reservation

Migration `0010_cancel_gas_reservation.sql` added
`gas_reserved_native_wei` to payout_attempts. abandon.go now:
- stamps `gasEstimate` into the new column on cancel INSERT
- `sumCancelGasLast24h` sums `COALESCE(gas_used_native_wei,
  gas_reserved_native_wei)` over non-abandoned cancels

Probe (Adversary C — operator-key compromise):
- Fire `/admin/payout/abandon-attempt` repeatedly back-to-back
  with `broadcast_cancel_self_transfer=true`. Each call reserves
  gas; the next call's SUM includes the prior reservation;
  cap-rejection should kick in BEFORE the 24h ceiling is breached.
- Verify abandoned cancels (after a re-abandon) drop OUT of the
  SUM via `abandoned_at_utc IS NULL` filter.
- Confirm broadcast-rejection (both RPCs return error) does NOT
  bump the SUM falsely (the reservation lives on the row but the
  abandon endpoint's gate already authorized the spend).

### Verify [sec:2.2] HIGH closure — BOTH-RPC chain verification

`verifyChainSideTransfer(ctx, attempt, recA, recB)` now:
- both `receipt.To == USDC`
- both `tx.input` byte-equal
- both `tx.from == hot_wallet` AND mutual agreement
- exactly-one matching Transfer log on BOTH log arrays

Probe (Adversary E — lying primary RPC):
- Mock recA with the right block_hash + tx_hash + to but wrong
  Transfer log; mock recB honestly. ReceiptsAgree passes; the
  function MUST trip on the per-receipt log count mismatch.
- Mock primary tx-by-hash with wrong `from`; secondary honest →
  trip on `primary tx.from != hot_wallet`.
- Mock both rpcs agreeing on `from` but a third party — trip on
  `tx.from != hot_wallet`.

### Verify [sec:2.3] HIGH closure — production signer wiring

`loadPayoutSigner(cfg.Payout, logger)`:
- DevMode=false → LoadLocalFileSigner with KEK from systemd
  CREDENTIALS_DIRECTORY (preferred) or
  MACPROVIDER_PAYOUT_WALLET_KEK env (hex)
- DevMode=true → MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY env
  (loud WARN)
- config validate REJECTS EncryptedWalletPath="" + DevMode=false
  + payout.enabled=true at parse time

Probe:
- DevMode=true with empty env → fail-loud
- DevMode=false with missing CREDENTIALS_DIRECTORY + missing env →
  fail-loud
- DevMode=false with valid CREDENTIALS_DIRECTORY but wrong KEK
  bytes (32 bytes random) → LoadLocalFileSigner returns
  decrypt-failed without leaking key material
- KEK plaintext zeroed after `LoadLocalFileSigner` returns
  (`for i := range kek { kek[i] = 0 }`)

### Regression sweep — re-run high-leverage adversarial probes

- Independent ethers.js EIP-712 vector (Step 1 probe) — still
  passes after Step 2 surface additions.
- `govulncheck ./...` — 0 reachable vulnerabilities.
- 8-conn PRAGMA `synchronous=FULL` — still holds.
- Two-RPC cold-start ±1 — still enforced.
- M4 chain-nonce race — `SleepAfterPostCommitLeaseReread` hook
  stays at zero in production.

### New focus

- The Migrate function's new tracking table grants migration
  idempotency. Verify: a compromised actor who deletes a row
  from payout_schema_applied could trigger a re-run of an
  ALTER TABLE; ADD COLUMN re-run fails fast at SQLite layer (column
  already exists). Probe whether this is sufficient defense.
- `payout_schema_applied` lives in the same DB; confirm it's
  added to the AssertSameDB pin list (it should NOT be — it's a
  tracking table, not a money-path table; flag if you disagree).

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-security-r2-audit.md`.

Standard structure (Verdict, Counts, r1 closures verified,
Regression probe matrix, New findings, Tests run).

## Discipline

- Model the attacker explicitly per A/B/C/D/E adversary lenses.
- BLOCK only on new CRITICAL or critical-class regression.
- Cite `<file>:<line>` for every finding.

You may take up to 35 min wall-clock.

=== END PROMPT ===
```
