# Audit lane: architecture review — issue #1578 settlement receipt on unsettled legs

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
Architecture review. Specifically attack:
- Is a mutable per-recorder latch the right mechanism, versus passing the leg status/settlement-subject explicitly into ingestSettlementReceipt at its call sites? Argue the trade-off and say whether the latch creates a temporal-coupling hazard that will break under future refactors of the forward loop.
- Does the latch duplicate the billing gate in a way that can DRIFT (two places encoding "is this leg billable")? Would extracting one predicate used by both the gate and the latch be materially better, and is that worth the churn?
- Is the boundary right — should this live in internal/billing (RecordMissingSettlementReceipt knowing that an unsettled leg is a no-op) rather than in the buyer caller? Note the stated constraint that a billable leg with an absent attempt output MUST stay loud, and judge whether the chosen layer honours it best.
- Naming and comment accuracy of the new field and comments.
- Does this leave the codebase in a state where the REAL remaining defect (billable legs whose settlement_attempt_outputs write fails under store pressure — 442/6610 successful requests on 2026-09-18, ~79% of that cohort non-payable under SPEC-022) is now easier or harder to see and fix?
