## Code Review Summary

**Files Reviewed:** 26 code/test files plus SPEC excerpts  
**Total Issues:** 5

### By Severity

- CRITICAL: 0
- MAJOR: 2
- MEDIUM: 2
- LOW: 1

### Issues

[code:1.1] [MAJOR] Persisted provider-payout bytes are never retried  
  File: `phase4-coordinator/internal/payout/runner.go:305`  
  Confidence: HIGH  
  What: `processRow` only handles existing non-cancel attempts when `confirmed_at_utc` or `broadcast_at_utc` is set. If Step 6 persisted `raw_signed_tx`/`tx_hash` but crashed or lost lease before broadcast, the next cycle falls through to fresh allocation and then hits the live-attempt unique index.  
  Why: SPEC §4.3 lines 1296-1309 require the next holder to rebroadcast existing persisted bytes bit-for-bit. This can strand payouts after the exact crash/retry path the CAS design is meant to recover.  
  Fix: Add an existing-attempt branch for `raw_signed_tx IS NOT NULL AND broadcast_at_utc IS NULL`: rebroadcast existing bytes, stamp `broadcast_at_utc`, then poll.

[code:1.2] [MAJOR] Cancel pre-check halts forever instead of polling/clearing cancel rows  
  File: `phase4-coordinator/internal/payout/runner.go:319`  
  Confidence: HIGH  
  What: The cancel loop returns `rowOutcomeSkipped` for every live cancel row. It rebroadcasts only unbroadcast cancels, never polls broadcast-unconfirmed cancels, and even already-confirmed cancel rows continue to block fresh provider-payout allocation.  
  Why: SPEC §4.3 lines 1065-1120 requires unbroadcast cancels to rebroadcast then poll, broadcast-unconfirmed cancels to poll with cancel-specific verification, and confirmed cancels to proceed to fresh non-cancel allocation without calling `ClaimPayoutReady`. Current behavior can permanently skip the payout after operator recovery.  
  Fix: Implement the cancel state machine: unbroadcast -> rebroadcast/stamp/poll; broadcast-unconfirmed -> cancel-specific poll/mark-confirmed; confirmed -> proceed to fresh allocation.

[code:1.3] [MEDIUM] Chain-side verification trusts primary-only sender/log evidence  
  File: `phase4-coordinator/internal/payout/runner.go:568`  
  Confidence: HIGH  
  What: `pollAndConfirm` passes only the primary receipt to `verifyChainSideTransfer`; that function checks `txA.From` only and counts Transfer logs only from the primary receipt. It fetches `txB` only for input equality.  
  Why: SPEC §4.3 lines 1332-1379 requires the chain-side value verification across both RPCs, with disagreements on sender/log evidence treated as mismatch. This weakens the two-RPC discipline.  
  Fix: Pass both receipts into verification, require `txA.From == txB.From == hot_wallet`, and run the exact-one Transfer-log check on both receipt log arrays.

[code:1.4] [MEDIUM] Signed EIP-1559 decoder accepts malformed RLP envelope shapes  
  File: `phase4-coordinator/internal/payout/evm.go:219`  
  Confidence: HIGH  
  What: `DecodeSignedEIP1559` ignores the consumed byte count from `rlpDecodeList`, so trailing bytes after the top-level list are accepted. It also collapses `0x80` empty string and `0xc0` empty list to the same `[]byte{}`, so an access-list field encoded as empty string passes as empty list.  
  Why: SPEC §4.3 step 6 requires strict pre-broadcast validation of Signer output; malformed signed envelopes should halt before persistence/broadcast.  
  Fix: Require `consumed == len(body)` and preserve RLP item kind so access-list must be exactly an empty list (`0xc0`), not an empty string.

[code:1.5] [LOW] Diff has trailing blank line at EOF  
  File: `phase4-coordinator/internal/payout/evm_test.go:204`  
  Confidence: HIGH  
  What: `git diff --check f0152c0..db5c9ba` reports `new blank line at EOF`.  
  Why: Low hygiene issue; it keeps diff-check from being a clean validation gate.  
  Fix: Remove the extra blank line at EOF.

### Open Questions

None.

### Positive Observations

- `go test ./...` and `go vet ./...` pass for `phase4-coordinator`.
- Config bounds match the v0.1.21 Step 2 requirements, including `confirmation_blocks [5,200]`, `reorg_poll_window [1h,168h]`, cap ordering, distinct RPC URLs, and SPKI pin shape.
- The nonce cursor migration is included in `payoutTables`, so `AssertSameDB` covers it.
- CAS persistence includes `raw_signed_tx IS NULL`, `confirmed_at_utc IS NULL`, and `abandoned_at_utc IS NULL`, closing the prior concurrent abandon/sign gap.

### Recommendation

REQUEST CHANGES

I did not write `specs/SPEC-016-IMPL-STEP_2-code-r1-audit.md` because this lane was explicitly read-only and prohibited file modification.
tokens used

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-code-review-lane-lane-1-of-2026-06-25T16-13-25-087Z.md._
