# IMPL audit prompt — SPEC-016 Step 2, **CODE REVIEW lane**

Lane 1 of 3 parallel codex audit lanes for SPEC-016 Step 2 IMPL
on branch `impl/spec-016`. Master shared-context preamble lives
in `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md` — read it before
starting; it lists all Step 2 commits, surface, and v0.1.21 delta
verification list.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Expected wall-clock: 40–60 min (Step 2 is ~5,000 net production
LOC across 9 files + 8 test files; SPEC §§4.3 + 4.4 + 4.6 + 4.7
+ 4.8b + 6.3.1 + 7.1 all in scope).

This is **read-only** — codex MUST NOT modify any file, commit,
push, or change git state.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 2
IMPL. Two sibling lanes (security-reviewer + architect) fire in
parallel; your scope is CODE REVIEW ONLY — do not report
security/architecture findings.

## Shared context

Read `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md` for the FULL
shared-context preamble (commits, file surface, v0.1.21 delta
verification list, threat models, output format).

SPEC v0.1.21 LOCKED at `f0152c0`. Step 2 IMPL HEAD at `db5c9ba`.

## Lane scope: code review

Focus areas:

### Migration + schema (0009 + same-DB pin)

- `migrations/0009_wallet_nonce_cursor.sql` — schema correctness
  vs §4.6 nonce-cursor prose. Single-row per from_address; PK
  on from_address; columns next_nonce, last_synced_at_utc, rpc
  values.
- `migrations.go` payoutTables list now includes
  `wallet_nonce_cursor` — confirm presence + AssertSameDB walk
  catches a misplaced cursor.

### EVM utilities (evm.go)

- RLP encoder correctness vs Ethereum yellow paper Appendix B.
  Probe: empty string → 0x80; single byte < 0x80 → identity;
  1–55 bytes → 0x80+len prefix; > 55 bytes → 0xb7+len-of-len.
  Lists: empty 0xc0; 1–55 bytes 0xc0+len; > 55 bytes 0xf7+len-of-len.
- EIP-1559 unsigned envelope shape: 0x02 || rlp([chainId, nonce,
  maxPrio, maxFee, gasLimit, to, value, data, accessList, yParity=0,
  r=0, s=0]). Empty access-list is 0xc0 (single byte).
- USDCTransferCalldata: selector 0xa9059cbb (keccak256 prefix of
  "transfer(address,uint256)") + 32-byte left-padded address +
  32-byte big-endian uint256 — total exactly 68 bytes.
- DecodeSignedEIP1559: rejects type != 0x02; rejects 12-field
  list other shapes; rejects non-empty access list; rejects
  malformed r/s (size 0 or > 32); rejects yParity > 1.
- TxHash: keccak256 of signed bytes — what basescan shows.
- RecoverTxSender: routes the y_parity → 27+y for decred
  RecoverCompact. Verify the conversion is correct (decred wants
  recovery byte 27+y for uncompressed).
- PadAddressTopic: left-pad to 32 bytes; first 12 bytes zero.

### Signer (signer.go)

- LocalFileSigner.SignTx:
  - Rejects unsigned[0] != 0x02 → ErrSignerUnavailable.
  - Rejects chain_id != BaseMainnetChainID → ErrSignerUnavailable.
  - 100ms self-deadline enforcement.
  - ctx.Err() propagation as transient.
- LoadLocalFileSigner: AES-256-GCM decrypt; KEK len enforced =32;
  decrypt failure does NOT echo key material in error.
- Zero-on-decrypt pattern: plaintext slice cleared after PrivKeyFromBytes.
- deriveEthereumAddress: uncompressed pubkey marker 0x04, then
  keccak256(X||Y)[12:] = address bytes; canonicalised to EIP-55.

### RPC client (rpc.go)

- HTTPRPCClient.call: JSON-RPC 2.0 envelope; HTTP non-2xx →
  error; RPC error → typed RPCError.
- IsNonceTooLow: 3 canonical messages caught; false on plain errors.
- ColdStartNonceSync: returns chosen = max(a, b); withinTolerance
  = (|a - b| > 0); halt on diff > 1.
- ReceiptsAgree: min-set (tx_hash + block_hash + block_number +
  status + to); nil-safe.
- TransactionReceipt: nil result returns (nil, nil).

### Attempts CRUD (attempts.go)

- SelectReadyPayouts: hot-wallet filter +
  registered_against_hot_wallet equality; cooling-off /
  rotated_from rules; effective_address CASE.
- InsertAttempt: ErrDuplicateLiveAttempt on the
  idx_pa_one_live_non_cancel_per_payout UNIQUE.
- CASPersistSignedTx: predicate AND raw_signed_tx IS NULL AND
  confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL —
  v0.1.11 round-12 MAJOR-1 closure. Disambiguation via follow-up
  read into ErrAttemptRowMissing / ErrAttemptStateChangedDuringSign
  / ErrRawSignedTxAlreadyPresent.
- MarkConfirmedAtTx: clears cancel_reconfirm_stale_paged_at_utc
  per v0.1.16/v0.1.17.
- SumAmountWindow: reservation-aware — counts ALL live reserved
  attempts (broadcast NULL, confirmed NULL, abandoned NULL)
  regardless of age, AND broadcasts in the 24h window per §5.3.
- CountStaleUnbroadcastTx: §4.3 step 4 stale halt (updated_at_utc
  < now-24h, broadcast NULL).

### Lease (lease.go)

- Acquire: fresh INSERT (no row) → no takeover.
  Conflict on heartbeat ≥ now - 3*runInterval.
  Takeover on heartbeat < now - 3*runInterval; takeover_count++;
  emit payout_runner_lease_taken_over.
- Heartbeat: UPDATE WHERE holder_token = ours; 0 rows →
  ErrLeaseLost + emit payout_runner_lease_lost; enriches event
  with observed_token / host / pid.
- SelfFenceTx / SelfFence: SELECT holder_token; mismatch →
  ErrLeaseLost.
- IsLeaseActive: heartbeat within 3*runInterval window.

### Runner (runner.go)

- Step 1 SELECT result handling: NULL effective_address →
  invariant_violation `null_effective_address` (impossible per
  WHERE; SPEC §4.3 step 1 hard error).
- Step 2 unit identity: amount = provider_credits exactly.
- Step 4 stale-reservation halt + reservation-aware cap re-check
  inside BEGIN IMMEDIATE.
- Step 5 C3 NORMATIVE invariant: re-read lpr.provider_credits
  inside the same txn; mismatch → invariant_violation
  `amount_credit_mismatch`.
- Step 5 cancel pre-check: LookupLiveCancels HALT (not invariant)
  on live unconfirmed cancel; rebroadcast unbroadcast.
- Step 6 verifySignedTx: full set (nonce, chain, to, value=0,
  calldata byte-equal, tx_hash recompute, ecrecover = hot_wallet).
- Step 6 CAS persist: in-txn lease re-read; CASPersistSignedTx;
  BumpNonceCursorTx; COMMIT.
- Step 6 post-COMMIT lease re-read BEFORE broadcast.
- Step 6 nonce-collision handling: IsNonceTooLow → NOT invariant
  violation (chain-serialized race per M4).
- Step 7 receipt poll: ConfirmationBlocks depth check; ReceiptsAgree;
  status=1; verifyChainSideTransfer.
- Step 7 (a) input byte-equality on BOTH RPCs.
- Step 7 (c) exactly-one matching Transfer log.
- Step 8 ClaimPayoutReady: payoutCurrency="USDC-BASE" literal;
  expectedGrossCredits = lpr.gross_credits (NOT provider_credits).
- Side-channel discipline: emitInvariantViolation does NOT
  include raw_signed_tx / tx_hash on discard paths.

### Reorg poller (reorg.go)

- BOTH RPCs not-found → reorg; ONE RPC error → WARN
  `payout_reorg_poll_rpc_error`; ONE RPC found / other not →
  transient log.
- Cancel-side LIVE-AGAIN: BEGIN IMMEDIATE; clears confirmed +
  block + gas + cancel_reconfirm_stale_paged_at_utc per v0.1.16;
  ROLLBACK rebroadcast guard against operator abandoning in the gap.
- Provider-side: emits payout_reorg_revert PAGE without mutating
  ledger_payout_ready (Step 3 handles that).
- NOTE on [arch:1.1] deferral: reorg.go uses payout_attempts.tx_hash
  + (payout_id, attempt_seq) per architect's r2 substitution; verify
  this is consistent (do NOT flag as a defect — flag if Step 2 deviates).

### Abandon endpoint (abandon.go)

- Read 400 paths: missing field, missing Idempotency-Key,
  bad JSON.
- 429 rate-limit per actor.
- Tip-multiplier silent floor + cap_applied flag.
- Gas-estimate per-request cap (422).
- BEGIN IMMEDIATE: runner-active gate (IsLeaseActive) → 409;
  24h-aggregate gas check (422); abandon-marker UPDATE gated on
  confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL (v0.1.12);
  row-count=0 disambiguation (404 / 409 already_confirmed /
  409 already_abandoned).
- Cancel-row INSERT: same txn; nonce reused from original row;
  is_cancel_self_transfer=1; broadcast_at_utc persisted as NULL
  (v0.1.14 round-15 MAJOR-1).
- Cancel-broadcast preflight: verifyCancelEnvelope BEFORE COMMIT.
- Post-COMMIT BroadcastBoth + StampBroadcastAt CAS on accept.

### Mux + topology

- step2PathTable extends step1; operatorKeyMiddleware bearer
  match.
- topology: HandlerEnabled + !RunnerCoResident → fail-fast.

### Config (config/config.go)

- Step 2 keys + parse-time bounds:
  ConfirmationBlocks [5, 200] (NOT [2, 50]); RunInterval [5m,
  24h]; RunNowMinInterval [10s, 1h]; MaxRowsPerRun [1, 500];
  ReorgPollWindow [1h, 168h]; LowBalanceThreshold ≤
  2*PerDayCap; LowNativeThreshold ≤ 1e18.
- PerDayCap ≥ PerPayoutCap.
- CancelMaxGasNativeWeiPer24h ≥ CancelMaxGasNativeWei.
- Two RPC URLs required + must differ when payout.enabled.
- SPKI pin = empty or 64 hex chars (lower/upper accepted).

### Coordinator wiring (cmd/coordinator/main.go)

- setupPayout signature change; caller updated.
- loadPayoutSigner: dev env path warns; refuses if env var
  unset. Production LoadCredential= path is a follow-up — flag
  if the dev path could escape into prod by silent default.

Findings format:

```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <one-paragraph description>
  Why: <impact>
  Fix: <suggested remediation; cite the binding SPEC rule>
```

Severity scale:
- CRITICAL — money-loss vector, signature-verification bypass,
  silent migration corruption.
- MAJOR — confirmed-reproduction bug not on the immediate money
  path.
- MEDIUM — SPEC deviation surviving to production without
  immediate exploit.
- LOW — style / idiom / comment.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-code-r1-audit.md`
following the same structure as the Step 1 r1 audit file.

## Discipline

- Specific cites for every finding.
- Reference the SPEC §-rule for violations.
- BLOCK only on new CRITICAL or where r1 surface is wrong.
- You may run `go test`, `go vet`, `git show`, `grep`. You MUST NOT
  modify any file.

You may take up to 50 min wall-clock.

=== END PROMPT ===
```
