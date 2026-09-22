# Audit lane: security review — issue #1578 settlement receipt on unsettled legs

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
Security / money-path review. Specifically attack:
- Can this change be used to SUPPRESS a settlement receipt verdict that should have been recorded, i.e. can an attacker (a malicious provider, or a buyer shaping traffic) steer a leg that DID serve tokens into the no-op branch so no missing-receipt verdict lands and the leg escapes settlement accounting?
- Conversely, can it let a provider get CREDITED without a receipt verdict?
- Is `status != http.StatusServiceUnavailable` attacker-controllable? Trace where a 503 status on a provider leg can originate — can a provider force its own leg to be classified 503 after having served output?
- SPEC-015 / SPEC-022 conformance: does skipping the missing-receipt verdict on a non-billable leg violate any normative requirement? Check specs/SPEC-015-*.md and specs/SPEC-022-*.md for requirements about settlement receipt coverage per attempt, and whether a settlement-quarantine/verdict row is required for EVERY attempt or only every billable attempt.
- Does the change weaken any audit/evidence trail that a verifier or payout path depends on?
- Confirm no secret/token/PII exposure and no new log of untrusted provider data.
