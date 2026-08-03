# SPEC-016 IMPL Step 2 — codex round 1 findings deferred

The r1 fix-pass commit closes 7 MAJOR/HIGH + 4 MEDIUM:

- [code:1.1] MAJOR — persisted bytes not retried (rebroadcastAndPoll branch added)
- [code:1.2] MAJOR — cancel pre-check 3-branch state machine
- [code:1.3] MEDIUM — verifyChainSideTransfer trusts primary only (now both-RPC)
- [code:1.4] MEDIUM — DecodeSignedEIP1559 trailing bytes + 0x80/0xc0 collapse
- [arch:3.1] MAJOR — Runner now constructed + Start + Stop + Release lifecycle wired in main.go
- [arch:3.2] MAJOR — Step 2 mux mounted at /admin/payout/ + /providers/
- [arch:3.3] MEDIUM — SPKI pinning installed via tls.Config VerifyPeerCertificate
- [arch:3.4] MEDIUM — §7.1 events get missing fields (payout_paid, payout_failed,
  payout_signer_unavailable, payout_run_finished)
- [sec:2.1] HIGH — gas reservation column (migration 0010) + COALESCE(used, reserved)
- [sec:2.2] HIGH — verifyChainSideTransfer on BOTH receipts (same fix as [code:1.3])
- [sec:2.3] HIGH — production loader = LoadLocalFileSigner + systemd KEK; dev path
  gated behind explicit `payout.security.dev_mode=true` + env var

Remaining open from r1:

## [code:1.5] LOW — trailing blank line at EOF (evm_test.go)

**CLOSED IN-LINE** in this commit by stripping trailing
newlines via a Python one-liner on the file. `git diff --check
HEAD~..HEAD` should report clean after r1 fix-pass commit.

## [arch:3.5] LOW — SPEC v0.1.21 §4.7 column-name drift

**Destination:** SPEC v0.1.22 candidate (carried forward from
Step 1 [arch:1.1]).

**Why deferred:** the IMPL has correctly worked around the drift
by using `(payout_id, attempt_seq, tx_hash)` in reorg.go and by
joining `ledger_payout_ready.payout_external_id` through
ClaimPayoutReady. Step 3's record-orphan endpoint can do the
same join cleanly. The SPEC text still needs to be amended for
clarity before v0.2, but Step 2 does not encode the broken SQL.

**Action:** raise the urgency for SPEC author resolution before
Step 3 begins. Tracking issue should reference architect r1
[arch:3.5] + r2 [arch:1.1] for the chain of evidence.

---

_Persisted alongside Step 2 r1 fix-pass commit. Round 2 audit
fan-out fires after this lands._
