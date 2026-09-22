# Audit lane: code review — issue #1578 settlement receipt on unsettled legs

Repo: /Users/augstar/macprovider-1578 (worktree, branch fix/settlement-receipt-unsettled-leg off origin/main).
Full fix diff as it will land: audits/2026-09-22/fix-1578.diff

## Background (verified, not hypothesis)
Coordinator log on prod 2026-09-18 during the #1570 probe:
  warn "missing settlement receipt recording failed" error="settlement attempt output missing"
40 occurrences, every one paired 1:1 with a request_log row of status 503 / error_code error_queue_full, on attempt_n=0, where a LATER attempt on a different provider served 200 and got a full settlement_attempt_outputs row + valid/verified/verified_settlement verdict + ledger credit. 0 of 54 such 503 legs on that day had a settlement attempt output; 0 of 455 successful probe-window requests lacked a ledger credit.

Cause: phase4-coordinator/internal/buyer/billing_recorder.go recordRow gates both billing branches on
  billingStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable
so a 503 leg never gets a settlement_attempt_outputs row (documented as intentional at billing_recorder.go:84-98 — a queue-full leg served zero bytes and is owed nothing). The retry paths then still called ingestSettlementReceipt(provider, "") for that leg, which asks RecordMissingSettlementReceipt to load evidence, which can only return sql.ErrNoRows -> "settlement attempt output missing" (internal/billing/settlement_receipts.go:915).

On the streaming retry-exhausted path this error is propagated to the BUYER as HTTP 500 "request_log_failed" (server.go renderRetryExhausted at ~:2742) instead of the real stream-forward terminal.

## The fix under review
Latch, inside recordRow, whether the leg just recorded was a settlement subject (same expression as the billing gate), and make the header=="" (missing-receipt) branch of ingestSettlementReceipt a silent no-op when it was not. Deliberately NOT keyed on "the attempt-output write succeeded", because a BILLABLE leg whose attempt output failed to persist (SQLite contention / route-snapshot store pressure) is a real SPEC-022 payability gap that must stay loud.

## Your lane
Correctness review. Specifically attack:
- Is the latch read only after a recordRow that corresponds to the SAME leg, at all 7 ingestSettlementReceipt call sites in internal/buyer/server.go and internal/buyer/route_snapshot.go? Enumerate them and prove each is immediately preceded by a recordRow (directly or via a logProviderRow*/logRow wrapper) for that provider+attempt. Any path that reads a stale latch is a finding.
- Is the reset placement (top of recordRow, before the s.reqLog == nil early return) sufficient? Any path that calls ingestSettlementReceipt without any recordRow at all?
- Does the latch expression correctly cover BOTH billing branches (the hot path additionally requires s.reqLogStore; the fallback branch at the bottom does not)? Could a leg be a settlement subject per the latch but take neither branch, or vice versa?
- Behaviour change on the non-empty-header (real receipt) path: prove there is none.
- Return-value contract change: ingestSettlementReceipt now returns (zero, false, nil) where it previously returned (zero, false, err). Walk every caller's handling of err and hasReceiptState and state whether the buyer-visible status, the settlement outcome headers, and the no-prior-dispatch marker change — and whether each change is correct.
- Concurrency: is billingRecorder ever used from more than one goroutine such that the latch races?
- Test adequacy: do the three new tests in settlement_unsettled_leg_test.go actually fail without the fix, and do they pin the right invariants?
