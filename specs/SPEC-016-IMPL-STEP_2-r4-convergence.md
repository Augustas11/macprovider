# SPEC-016 IMPL Step 2 — round 4 CONVERGED

Three-lane parallel codex audit fan-out converged at round 4
across all three lanes at **0 CRITICAL / 0 MAJOR / 0 MEDIUM / 0 LOW**.

## Final scoreboard

| Lane         | r1                | r2                  | r3                | r4                  | Final |
|--------------|-------------------|---------------------|-------------------|---------------------|-------|
| Code         | 0/2/2/1 BLOCK     | 0/0/1/1 FIX-THEN    | 0/0/1/0 FIX-THEN  | **0/0/0/0 CLEAN** ✅ | CONVERGED |
| Security     | 0/3 HIGH/0/0      | 0/0/1/1 MEDIUM      | **0/0/0/0 CLEAN** ✅ | (held at r3)        | CONVERGED |
| Architecture | 0/2/2/1 FIX-THEN  | 0/0/2/1 FIX-THEN    | **0/0/0/0 CLEAN** ✅ | (held at r3)        | CONVERGED |
| **Total r4** | — | — | — | **0 / 0 / 0 / 0**   | **CONVERGED** |

The audit-loop discipline at
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §3 is satisfied.
Step 2 IMPL is green to proceed to Step 3 on the same
`impl/spec-016` branch.

## Round-by-round narrative

### Round 1 (codex against `db5c9ba`)

Three lanes fired in parallel against the Step 2 IMPL surface.

**Code lane (BLOCK).** 2 MAJOR + 2 MEDIUM + 1 LOW.
- [code:1.1] MAJOR — persisted bytes never retried after crash
- [code:1.2] MAJOR — cancel pre-check halts forever
- [code:1.3] MEDIUM — chain-side verification trusts primary only
- [code:1.4] MEDIUM — DecodeSignedEIP1559 strict shape check missing
- [code:1.5] LOW — EOF blank line

**Security lane (HIGH risk).** 3 HIGH.
- [sec:2.1] HIGH — 24h gas cap ignores pending cancel gas
- [sec:2.2] HIGH — verifyChainSideTransfer primary-only logs
- [sec:2.3] HIGH — production uses dev plaintext env signer

**Architecture lane (FIX-THEN-PROCEED).** 2 MAJOR + 2 MEDIUM + 1 LOW.
- [arch:3.1] MAJOR — lease/topology half-wired; runner never started
- [arch:3.2] MAJOR — /admin/payout/* unreachable via /providers/ mount
- [arch:3.3] MEDIUM — SPKI pinning declared but not installed
- [arch:3.4] MEDIUM — §7.1 event field sets incomplete
- [arch:3.5] LOW — §4.7 SPEC drift (deferred to v0.1.22)

### Round 1 fix-pass (commit `3653516`)

10 files modified + 1 new migration. All 7 MAJOR/HIGH + 4 MEDIUM
closed; [code:1.5] LOW closed inline; [arch:3.5] LOW deferred to
SPEC v0.1.22.

Key changes:
- Runner constructed with billing.Store as PayoutClaimer; Start
  + Stop + Release lifecycle in main.go.
- Step 2 mux mounted at BOTH `/providers/` and `/admin/payout/`.
- rebroadcastAndPoll branch for persisted-but-unbroadcast attempts.
- 3-branch cancel-pre-check state machine + pollCancelOnce.
- verifyChainSideTransfer on BOTH receipts.
- Migration 0010 + gas_reserved_native_wei + COALESCE(used,
  reserved) for the 24h cap.
- DecodeSignedEIP1559 strict (rlpKind + consumed-bytes).
- LoadLocalFileSigner with systemd KEK; dev path gated on
  cfg.Payout.Security.DevMode.
- SPKI pinning via tls.Config VerifyPeerCertificate.
- §7.1 event field-set additions (block_number/nonce/error_text/etc).

### Round 2 (codex against `3653516`)

All r1 closures VERIFIED. 4 new MEDIUMs + 1 LOW from the fix-pass
itself.

- [code:r2-2.1] MEDIUM — pollCancelOnce checks USDC log on primary only
- [code:r2-2.2] LOW — missing regression tests for new branches
- [arch:3.1-r2] MEDIUM — Stop returns on ctx.Done; Release races mid-cycle
- [arch:3.4-r2] MEDIUM — per-day payout_capped emit drops provider_id/ts_utc
- [sec:r2-2.1] MEDIUM — loadPayoutSigner KEK zeroize only on success path
- [sec:r2-2.2] LOW — operatorKeyMiddleware uses non-constant-time compare

### Round 2 fix-pass (commit `c761e55`)

4 files modified + 1 new test file. All 4 MEDIUMs + 1 LOW closed.

Key changes:
- pollCancelOnce checks both receipts' To AND USDC logs via new
  `hasUSDCTransferLog` helper.
- Runner.Stop returns bool; main.go Release only on cleanExit; emits
  payout_runner_lease_left_to_stale_out WARN on timeout.
- per-day payout_capped emit gets provider_id + ts_utc.
- KEK zeroize via defer for ALL paths (production + dev).
- subtle.ConstantTimeCompare with length pre-check for bearer.
- New runner_rebroadcast_test.go covers persisted-bytes-no-resign
  and cancel-pre-check-halt-fresh-allocation.

### Round 3 (codex against `c761e55`)

All r2 closures VERIFIED across all three lanes.

- Code lane: 1 new MEDIUM ([code:r3-3.1]) — pollCancelOnce
  rejects USDC logs but does NOT verify cancel tx body (value /
  input / from) on either RPC.
- Security lane: **CLEAN 0/0/0/0** ✅
- Architecture lane: **CLEAN 0/0/0/0** ✅

### Round 3 fix-pass (commit `6441dbf`)

Single file + test additions. The one MEDIUM closed:

- New `verifyCancelTxView(tx, hotWallet)` helper enforces SPEC
  §4.3 cancel-branch invariants: `tx.to == hot_wallet`,
  `tx.value == 1 wei`, `tx.input` empty, `tx.from == hot_wallet`.
- Called for both primary + secondary eth_getTransactionByHash
  before MarkConfirmedAtTx. Emits cancel_self_transfer_mismatch
  with side-discriminator (primary: / secondary:) on failure.
- Regression test TestVerifyCancelTxView covers happy path +
  case-fold tolerance (0X1 / 0x01 / 0x0001) + 4 rejection paths.

### Round 4 (codex code-only against `6441dbf`)

Security + architecture lanes already CLEAN at r3 — narrow
scope. Code lane verified the [code:r3-3.1] closure:

> r3 finding `[code:r3-3.1]` is closed: `pollCancelOnce` fetches
> both RPC transaction bodies and verifies both before
> confirmation. Ordering is correct: receipt agreement/depth/status
> checks happen first, then receipt log checks, then tx-body checks,
> then MarkConfirmedAtTx. `verifyCancelTxView` enforces to, from,
> empty input, and one-wei value as required. The normalization
> accepts `"0x000001"` and rejects `"0x10"`, `"0x"`, and `""`.

Verdict: APPROVE. **CLEAN 0/0/0/0** ✅.

## Step 2 → Step 3 readiness matrix

| Row | r4 verdict | Notes |
|-----|------------|-------|
| record-orphan endpoint | FRICTION | §4.7 SPEC drift still open as v0.1.22 candidate. Step 2's reorg.go works around it via `(payout_id, attempt_seq, tx_hash)` + ledger_payout_ready join; Step 3 endpoint will encode the same substitution. |
| record-funding endpoint | READY | Admin mux composition works; Step 3 just adds the new chi route + path-table entry. |
| pause/resume endpoints | FRICTION | Runtime-flag foundation exists from Step 1 (registration_paused row + audit + outbox). Step 3 adds the §6.4.1 endpoint pair with rate-limit + audit-trail outbox per SPEC §4.8a discipline. |
| chi mux composition | READY | `/providers/` AND `/admin/payout/` both mounted; path-table verifier enforces declared-route parity. |
| Step 4 SIGHUP tuning | NOT READY | Tuning values captured at startup; Step 4 will add an atomic PayoutTuningProvider with Runner.Stop+Restart semantics. |

## Forward-looking notes for Step 3 / Step 4

Architect r2 + r3 surfaced two cross-cutting concerns for later
steps. Both are deliberately deferred:

1. **§7.1 typed-event helpers** — Step 3 should add a small
   helper API (or table-driven log-field tests) so future
   endpoints can't drift on event field sets. The current
   inline zerolog .Send() calls work but invite drift.
2. **Step 4 PayoutTuningProvider** — `payout.tuning.*` values
   are value-captured in RunnerOptions + ReorgPoller. SIGHUP
   hot-reload requires an atomic provider snapshot + cycle
   reset semantics. Runner.Stop already returns bool which is
   the right primitive.

## Forward-looking notes for SPEC v0.1.22

Carrying forward from Step 1 [arch:1.1]:

- §4.7 reorg-poll query references `payout_attempts.id` and
  `payout_attempts.payout_external_id` — NEITHER exists in
  §4.5. Step 2 reorg.go documents the substitution + uses
  `(payout_id, attempt_seq, tx_hash)` + joins through
  `ledger_payout_ready.payout_external_id` instead.
- Operator-side SPEC amendment is the right resolution; Step 3
  endpoint design should encode the substitution explicitly so
  the §4.7 query shape becomes operationally pinned.

## Audit artifacts

Persisted findings (committed alongside this convergence file):

- specs/SPEC-016-IMPL-STEP_2-{code,security,arch}-r1-audit.md
- specs/SPEC-016-IMPL-STEP_2-r1-deferrals.md
- specs/SPEC-016-IMPL-STEP_2-{code,security,arch}-r2-audit.md
- specs/SPEC-016-IMPL-STEP_2-{code,security,arch}-r3-audit.md
- specs/SPEC-016-IMPL-STEP_2-code-r4-audit.md
- specs/SPEC-016-IMPL-STEP_2-r4-convergence.md (this file)

Source codex artifacts under `.omc/artifacts/ask/`:
- 3× r1 lanes (code/security/architecture)
- 3× r2 lanes
- 3× r3 lanes
- 1× r4 code

## Commit chain

```
HEAD  6441dbf impl(016): Step 2 r3 fix-pass — close [code:r3-3.1] cancel tx-body verify
      …      spec(016): Step 2 r4 code-only audit prompt
      …      spec(016): Step 2 audit r3 findings — security + arch CLEAN, code 1 MEDIUM
      c761e55 impl(016): Step 2 r2 fix-pass — close all 4 MEDIUMs + 1 LOW
      …      spec(016): Step 2 r3 audit prompts
      …      spec(016): Step 2 audit r2 findings — all r1 closures verified; 4 new MEDIUMs
      …      spec(016): Step 2 r2 audit prompts — 3 parallel codex lanes
      3653516 impl(016): Step 2 r1 fix-pass — close 7 MAJOR/HIGH + 4 MEDIUM
      …      spec(016): Step 2 audit r1 findings — 3 parallel codex lanes
      …      spec(016): Step 2 audit prompts — 3 parallel codex lanes (r1)
      db5c9ba impl(016): Step 2 wire signer/RPCs/lease into main.go; topology tightened
      cf313cf impl(016): Step 2 — §4.7 reorg poll + §4.6 abandon endpoint
      414d2fe impl(016): Step 2 — §4.3 runner cycle (9-step per-run algorithm)
      1809df8 impl(016): Step 2 — attempts CRUD + nonce cursor + §4.8b lease
      b3e1b7d impl(016): Step 2 — RPC client + two-RPC discipline helpers
      7970b6b impl(016): Step 2 — Signer interface + LocalFileSigner impl
      640a0d0 impl(016): Step 2 — EVM utilities (RLP, EIP-1559 tx, USDC calldata)
      5f7bfff impl(016): Step 2 — config keys for runner/RPC/caps/abandon
      a1fe3b1 spec(016): Step 1 audit CONVERGED — r2 across all 3 lanes 0/0/0/0
```

## Next action

Per `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §2: proceed to
Step 3 (§4.7 record-orphan + §4.9 record-funding + §6.4.1
pause/resume) on the same `impl/spec-016` branch.

**Do NOT push and do NOT open the PR yet.** The single PR opens
once after Step 4's audit converges per the consolidation plan
in commit `92c8672`.
