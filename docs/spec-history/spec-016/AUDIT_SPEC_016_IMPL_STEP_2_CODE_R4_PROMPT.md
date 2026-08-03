# IMPL audit prompt — SPEC-016 Step 2, **CODE REVIEW lane, round 4**

Round 4 against fix-pass commit `6441dbf` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

**Note:** Security + Architecture lanes converged at r3 (both
returned CLEAN 0/0/0/0). This r4 fan-out is **code lane only**;
the other two lanes need no further verification unless the
fix-pass touches files outside `runner.go` (it does not).

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 2
IMPL — round 4. Round 3 returned 0/0/1 MEDIUM/0. The fix-pass
`6441dbf` addresses the one MEDIUM. Your r4 job: verify the
closure holds.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`. HEAD: `6441dbf`.

## r3 finding to verify CLOSED

### [code:r3-3.1] MEDIUM — pollCancelOnce cancel tx-body verification

Per SPEC §4.3 step 7 (cancel branch), the runner MUST verify on
BOTH RPCs' eth_getTransactionByHash responses:
- tx.to == hot_wallet
- tx.value == 1 wei (raw hex 0x1)
- tx.input empty
- tx.from == hot_wallet

The fix at `runner.go:493-516`:

- Calls `r.opts.RPCs.Primary.TransactionByHash(ctx, txHash)`
- Calls `r.opts.RPCs.Secondary.TransactionByHash(ctx, txHash)`
- Bails on nil tx OR error from either
- Calls new `verifyCancelTxView(txA, hotWallet)` and emits
  `payout_chain_value_mismatch` with `"primary: " + err.Error()`
  detail on fail
- Same for txB with `"secondary: "` prefix

Helper `verifyCancelTxView` (runner.go:1024-1056):
- to == hot_wallet (addressEqualFold)
- from == hot_wallet (addressEqualFold)
- input empty
- value parses to "1" after `ToLower` + `TrimPrefix("0x")` +
  `TrimLeft("0")`

Regression test `TestVerifyCancelTxView` (runner_rebroadcast_test.go:84):
- happy path + 0X1/0x01/0x0001 tolerance + 4 rejection cases

Probe:
1. Verify the helper is invoked BEFORE MarkConfirmedAtTx (i.e.
   no race where the row gets marked confirmed before tx-body
   checks).
2. Verify the ordering: receipt checks → log checks → tx-body
   checks. Any reordering opportunity?
3. The case-fold + leading-zero strip is unusual — does it
   correctly accept "0x000001" (4 leading zeros), and reject
   "0x10" (= 16 wei)?
4. The TransactionByHash call doesn't time out independently —
   it inherits the parent ctx. Is that adequate for the cancel
   path or should there be a tighter deadline?

## Regression sweep

Probe the small fix-pass diff for new defects:

1. `verifyCancelTxView` doesn't validate `tx.ChainID`. SPEC
   §4.3 cancel branch implicitly assumes Base mainnet 8453;
   the receipt-level checks happen before this. Is the absence
   load-bearing?
2. `tx.Value` is a raw hex string from JSON-RPC. Does the
   parser tolerate "0x" with no digits? "" (empty)? Probe.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-code-r4-audit.md`.

## Discipline

CLEAN requires r3 [code:r3-3.1] CLOSED + zero new findings.
BLOCK only on new CRITICAL.

You may take up to 20 min wall-clock.

=== END PROMPT ===
```
