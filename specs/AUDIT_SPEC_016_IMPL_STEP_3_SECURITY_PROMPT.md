# IMPL audit prompt — SPEC-016 Step 3, **SECURITY REVIEW lane, round 1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016
Step 3 IMPL — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md`. HEAD: `191e3be`.

## Threat models

Step 3 surfaces are all operator-key-authenticated admin
endpoints. The adversary model is:

1. **Compromised operator-key holder** — has the bearer token
   AND raw DB write. Defeats the "audit trail" if any §6.4.1
   action bypasses the runtime_flag_audit row write or if
   the §4.9 source='manual' window can be re-opened.
2. **Lying RPC** — one of the two RPCs returns fabricated
   `eth_getTransactionReceipt` responses. §4.9
   source='rpc-confirmed' must verify on BOTH receipts.
3. **Reorg-period race** — a reorg-orphan record-write races
   with a fresh runner cycle. The cancel-vs-provider carve-
   out determines whether ledger_payout_ready reverts.
4. **Sync emitter crash mid-§4.8a** — the write commits but
   the post-commit CAS-emit panics. The reaper must pick up
   the row within 5 minutes and emit.

## High-leverage probes

### A. §4.8a defense-in-depth

1. **CAS-claim race.** Spawn two concurrent reapers or one
   reaper + one sync emitter against the same audit id. The
   CAS UPDATE with RETURNING id must guarantee at-most-once
   emit. Verify the `WHERE id = ? AND emitted_to_log = 0`
   clause is intact and not weakened to `WHERE id = ?`.
2. **DROP+UPDATE+CREATE attack on bootstrap triggers.** Inside
   the §4.9 source='manual' txn, count(*) MUST be 3. Verify
   the trigger names are the exact 3 SPEC-named ones; verify
   the WHERE clause uses `type='trigger'`; verify the txn is
   BEGIN IMMEDIATE so a concurrent DROP cannot slip between
   the count and the INSERT.
3. **Bootstrap-window re-open.** payout_bootstrap_complete
   has a one-way trigger (trg_prs_bootstrap_one_way) but an
   attacker with DB write could DROP it, set
   payout_bootstrap_complete=0, CREATE it back. Verify the
   trigger-presence check inside the source='manual' txn
   would catch this within ONE txn snapshot.
4. **Empty Idempotency-Key bypass.** Verify an empty header
   does NOT silently fall through to a UNIQUE-only path.

### B. §4.9 fake-funding attack

1. **Hot-wallet self-fund.** from == hot_wallet → 400. Verify
   the comparison is case-insensitive (EIP-55 vs lowercase).
2. **rpc-confirmed verification gaps.**
   - Status MUST be 1.
   - to MUST equal USDC contract.
   - block_number MUST match the request body.
   - At least ONE log MUST be a USDC Transfer with matching
     from/to/value.
3. **Value overflow.** The amount_base_units field is int64;
   verify the UNIT256-from-Data parser doesn't silently
   truncate a > uint64 value to look like a match.
4. **Topic[1]/Topic[2] indexed-address padding.** 32-byte
   ABI-encoded addresses are left-padded with zeros; verify
   addressFromTopic strips the high 12 bytes correctly.

### C. §6.4.1 rate-limit bypass

1. **Negative MinInterval.** NewPauseResumeService rejects.
2. **Clock skew between writer.now and DB timestamps.**
   Verify the rate-limit cutoff is computed from the most
   recent audit row's occurred_at_utc, NOT from a process
   wall clock that could be skewed across restarts.
3. **MinInterval=0 in production.** Config validate enforces
   `>= 1s` per SPEC; verify NewPauseResumeService doesn't
   silently accept 0 in production.

### D. Operator-key handling

1. **Actor string leak.** The Step 3 Actor string is
   "operator_key:coordinator" — verify this is NOT derived
   from the raw operator-key bytes (i.e. it's a non-secret
   label).
2. **Constant-time bearer compare.** The Step 2
   operatorKeyMiddleware uses subtle.ConstantTimeCompare;
   verify Step 3 routes use the SAME middleware.
3. **Idempotency-Key as side-channel.** A retry loop with a
   different Idempotency-Key but the same tx_hash MUST
   reject 422 idempotency_key_mismatch, NOT 409. The 422 vs
   409 distinction is observable; verify it doesn't leak
   tx_hash existence to the adversary.

### E. Reorg carve-out integrity

1. **ledger_payout_ready revert on cancel path.** Search the
   serveRecord cancel branch for ANY UPDATE / DELETE on
   ledger_payout_ready. v0.1.14 normative: must be zero.
2. **Snapshot column tampering window.** The observed_*
   columns are captured INSIDE the txn from a join. Verify
   no path mutates them after INSERT.

### F. Reaper

1. **DoS via unbounded reaper loop.** ListUnemittedOlderThan
   returns ALL eligible rows in one shot; verify the loop
   honors ctx.Done() between rows.
2. **Reaper after Stop.** Stop sets a sync.Once cancel;
   verify subsequent Start calls don't restart the cancelled
   loop in surprising ways.

## OWASP Top 10 sweep

- A01 Broken Access Control: operator-key middleware on all
  4 new routes.
- A02 Cryptographic Failures: no new crypto in Step 3 (signer
  still Step 2). Confirm.
- A03 Injection: SQL is parameterized everywhere.
- A04 Insecure Design: bootstrap-window narrowing,
  trigger-presence intra-txn check.
- A05 Security Misconfiguration: rate-limit immutability.
- A07 Authentication Failures: bearer compare constant-time.
- A09 Logging Failures: at-most-once emission via CAS;
  outbox guarantees no silent drop.

## Tools

- `govulncheck ./...` from `phase4-coordinator/`.
- `go test -race -count=1 ./internal/payout/...`.
- Static grep for any UPDATE / DELETE on ledger_payout_ready
  inside `internal/payout/orphans.go`.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_3-security-r1-audit.md`. Standard
structure (Risk Level, Critical / High / Medium / Low,
OWASP coverage, Verdict).

## Discipline

- Wall-clock target: 30 min.

=== END PROMPT ===
```
