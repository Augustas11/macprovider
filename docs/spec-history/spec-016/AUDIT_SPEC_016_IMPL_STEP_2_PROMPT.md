# IMPL audit prompt — SPEC-016 Step 2 (runner cycle + abandon + reorg poll)

> **THIS FILE IS THE SHARED-CONTEXT INDEX, NOT A FIREABLE PROMPT.**
> Three parallel codex lanes consume the context preamble below.
> Do NOT fire this file solo — fire the three lane files in
> parallel instead:
>
> - `specs/AUDIT_SPEC_016_IMPL_STEP_2_CODE_PROMPT.md`     → `omc ask codex --agent-prompt code-reviewer`
> - `specs/AUDIT_SPEC_016_IMPL_STEP_2_SECURITY_PROMPT.md` → `omc ask codex --agent-prompt security-reviewer`
> - `specs/AUDIT_SPEC_016_IMPL_STEP_2_ARCH_PROMPT.md`     → `omc ask codex --agent-prompt architect`
>
> Each lane references this file for the shared context preamble.
> House practice — three lenses parallel, three findings files,
> three rounds at most, loop until ALL THREE lanes combined return
> 0 CRITICAL / 0 MAJOR / 0 MEDIUM before pushing or moving to Step 3.

## Context

This audit covers Step 2 of the SPEC-016 IMPL — the §4.3 runner
cycle, §4.4 RPC discipline, §4.6 nonce + abandon endpoint, §4.7
reorg detection (record-only; orphan recording is Step 3),
§4.8b lease, §6.3.1 Signer interface, and the §7.1 event surface
the runner emits. SPEC is LOCKED at v0.1.21 on commit `f0152c0`.

The branch under review is `impl/spec-016`. Step 2 IMPL commits:

```
db5c9ba impl(016): Step 2 — wire signer/RPCs/lease into main.go; topology tightened
cf313cf impl(016): Step 2 — §4.7 reorg poll + §4.6 abandon endpoint
414d2fe impl(016): Step 2 — §4.3 runner cycle (9-step per-run algorithm)
1809df8 impl(016): Step 2 — attempts CRUD + nonce cursor + §4.8b lease
b3e1b7d impl(016): Step 2 — RPC client + two-RPC discipline helpers
7970b6b impl(016): Step 2 — Signer interface + LocalFileSigner impl
640a0d0 impl(016): Step 2 — EVM utilities (RLP, EIP-1559 tx, USDC calldata)
5f7bfff impl(016): Step 2 — config keys for runner/RPC/caps/abandon
```

Step 1 converged at 0/0/0/0 across all three lanes (commit
`a1fe3b1`). The Step 1 [arch:1.1] deferral (SPEC v0.1.21 §4.7
references `payout_attempts.id` + `payout_external_id` columns
that don't exist in §4.5) is STILL open as a SPEC v0.1.22
candidate; Step 2's reorg.go works around it per architect's r2
recommendation. Audit Step 2's reorg-poll implementation against
the architect's recommended substitution (use `payout_attempts.tx_hash`
+ join via `ledger_payout_ready.payout_external_id`).

## Step 2 surface (files Step 2 added or substantially modified)

Production code (internal/payout/):
- `evm.go` (~580 LOC) — RLP, EIP-1559 encoding, USDC calldata,
  tx-hash, ecrecover-for-tx.
- `signer.go` (~330 LOC) — Signer interface + LocalFileSigner
  (AES-256-GCM file + KEK).
- `rpc.go` (~460 LOC) — RPCClient interface, HTTPRPCClient,
  TwoRPCs helpers (AssertChainID, ColdStartNonceSync,
  BroadcastBoth, ReceiptsAgree, IsNonceTooLow).
- `attempts.go` (~490 LOC) — payout_attempts CRUD, nonce cursor
  (UpsertNonceCursor, ReadNonceCursor, AllocateNextNonceTx,
  BumpNonceCursorTx). New migration
  `migrations/0009_wallet_nonce_cursor.sql`.
- `lease.go` (~320 LOC) — §4.8b Acquire / Heartbeat / SelfFenceTx
  / SelfFence / Release / IsLeaseActive.
- `runner.go` (~860 LOC) — §4.3 9-step algorithm; Runner +
  lifecycle (Start/Stop/RunOnce); per-row processRow +
  allocateBuildSignBroadcast + pollAndConfirm + claimAndLog;
  verifySignedTx (§4.3 step 6 NORMATIVE) + verifyChainSideTransfer
  (§4.3 step 7 a/b/c); §7.1 event emitters.
- `reorg.go` (~260 LOC) — §4.7 ReorgPoller. Provider-side
  observability + cancel-side LIVE-AGAIN UPDATE per v0.1.14.
- `abandon.go` (~480 LOC) — §4.6 admin endpoint + buildCancelTx
  + verifyCancelEnvelope + rate-limit + 24h-aggregate gas cap.
- `mux.go` — extended with `step2PathTable` + `NewMuxStep2` +
  `operatorKeyMiddleware`. step1PathTable unchanged.
- `topology.go` — tightened: HandlerEnabled=true +
  RunnerCoResident=false now FAILS-FAST.

Wire-up (cmd/coordinator/main.go):
- `setupPayout` signature now returns
  `(*AddressesService, http.Handler, *payoutStep2, error)`.
- New helpers: `loadPayoutSigner` (dev env loader;
  `MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY` env var; production
  LoadCredential= path is a follow-up).
- AssertChainID + ColdStartNonceSync + UpsertNonceCursor +
  Acquire are wired at startup.
- Step 2 mux swap (NewMux → NewMuxStep2) is a follow-up commit
  per the C10 commit body. Runner.Start invocation also pending.

Tests (internal/payout/):
- evm_test.go — calldata vector, sign/decode/ecrecover round-trip,
  empty access-list 0xc0 marker, type-0x02 rejection.
- signer_test.go — derivation, round-trip, wrong chain id rejected,
  ctx cancel, AES-GCM decrypt happy + wrong-KEK rejected without
  key-material leak in the error.
- rpc_test.go — TwoRPCs.AssertChainID + ColdStartNonceSync paths,
  IsNonceTooLow classifier, ReceiptsAgree, HTTPRPCClient via
  httptest.
- attempts_test.go — SelectReadyPayouts filtering,
  ErrDuplicateLiveAttempt, CASPersistSignedTx happy +
  ErrRawSignedTxAlreadyPresent + ErrAttemptStateChangedDuringSign,
  nonce cursor round-trip, NextAttemptSeq monotonic.
- lease_test.go — fresh acquire, conflict, takeover, heartbeat
  refresh + lease-lost detection, release-then-reacquire,
  IsLeaseActive fresh vs stale.
- runner_test.go — happy-path single payout end-to-end with mock
  RPCs + mock claimer; C3 amount_credit_mismatch halt;
  ErrLeaseLost abort; ConfirmationBlocks bound rejection.
- reorg_test.go — provider-side reorg observability (no row
  mutation), cancel-side LIVE-AGAIN UPDATE, RPC error does NOT
  count as reorg.
- abandon_test.go — 404 / 409 runner_active / 200 OK no-cancel /
  400 missing fields / 400 missing Idempotency-Key / 429
  rate-limit.

## SPEC v0.1.21 deltas to verify Step 2 honors

- **C3 (§4.3 step 5, v0.1.20 round-20):** `amount_base_units ==
  lpr.provider_credits` invariant asserted INSIDE BEGIN IMMEDIATE
  with `lpr.provider_credits` re-read inside the SAME txn. Step
  2 implements this in `runner.go::allocateBuildSignBroadcast`.
- **M1 (§4.7, v0.1.20 round-20):** reorg-poll cadence with
  `payout.tuning.reorg_poll_window` default 24h, bounds
  `[1h, 168h]`. Both-RPC discipline; one-RPC error → WARN
  `payout_reorg_poll_rpc_error`; both-RPC not-found → reorg.
- **M2 (§4.3 step 7 + §6.5):** `confirmation_blocks` bounds
  widened `[2, 50]` → `[5, 200]`. NewRunner rejects out-of-bounds.
- **M4 (§4.8b):** post-CAS broadcast race window — chain-nonce
  uniqueness is the load-bearing guard. Runner exposes a test
  hook `SleepAfterPostCommitLeaseReread` for the §4.8b test (4).
- **M5 (§7.4):** conservation invariant query (E hot-wallet
  self-funding detector) + (F money-conservation) lives in Step
  4's reconcile.sql; Step 2 just must NOT BREAK the invariant —
  the C3 check is the load-bearing guard.

## Threat models (apply to security lane only)

- **Adversary A — stolen `provider_token`.** Covered by Step 1
  EIP-712 PoP; Step 2 does NOT add a new path here. Re-verify
  the §3.3 surface still holds after Step 2's mux extension.
- **Adversary B — malicious portal / on-path attacker.**
  Replayed signed-bytes / mempool collision. Verify M4
  chain-nonce serialization.
- **Adversary C — operator-key compromise.** Step 2 introduces
  the abandon endpoint. SPEC §4.6 caps + runner-active gate +
  rate-limit + 24h-aggregate gas cap defang this. Verify each
  cap is enforced in-txn (not just at parse time).
- **Adversary D — compromised Signer (KMS policy bypass or
  rogue wallet swap).** SPEC §4.3 step 6 NORMATIVE pre-broadcast
  verification + §4.3 step 7 chain-side verification together
  catch this. Probe both code paths.
- **Adversary E — lying RPC.** SPEC §4.4 two-RPC discipline
  with explicit disagreement events. Probe each path:
  - Cold-start: ±1 agreement, halt on diff > 1
  - Receipt: ReceiptsAgree min-set, payout_rpc_disagreement
  - Reorg poll: one-RPC error vs both-not-found

## Output

Each lane writes to `specs/SPEC-016-IMPL-STEP_2-{code,security,arch}-r1-audit.md`.

## Discipline

- Specific cites with `<file>:<line>` for every finding.
- Conservative on CRITICAL — concrete failure mode in one sentence.
- Reference the SPEC §-rule for every violation claim.
- Loop until 0 / 0 / 0 / 0 across all three lanes combined.
