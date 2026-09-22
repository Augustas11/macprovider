# Audit lane R2: code review — issue #1578, final diff

Repo: /Users/augstar/macprovider-1578 (branch fix/settlement-receipt-unsettled-leg off origin/main).
Final diff: audits/2026-09-22/fix-1578.diff

R1 of this lane returned 0 findings / APPROVE. Since then the ONLY change is the architecture lane's LOW/WATCH item: the settlement-subject predicate was extracted into a local variable in recordRow and reused by BOTH billing branches, and the latch field was renamed settlementSubject -> lastRecordedSettlementSubject.

Do NOT re-review the whole design. Review exactly one thing, adversarially:

**Is the extraction semantically IDENTICAL to what it replaced?**

Before:
  b.settlementSubject = billingStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable
  if billingStore != nil && s.reqLogStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable {   // hot path
  ...
  if billingStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable {                            // fallback branch

After:
  settlementSubject := billingStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable
  b.lastRecordedSettlementSubject = settlementSubject
  if settlementSubject && s.reqLogStore != nil {   // hot path
  ...
  if settlementSubject {                            // fallback branch

Check specifically:
- Short-circuit / evaluation-order differences. Is billingStore or status mutated anywhere between the new assignment point and either branch, such that the hoisted value could differ from a re-evaluation at the branch? Read the whole body of recordRow between those points.
- Is `status` reassigned after the hoist? Is `providerAssignedID`? Is `billingStore`?
- Does the fallback branch still only run when the hot path did NOT (i.e. did hoisting change which branch executes for any input)?
- Any other reader of those variables whose behaviour shifts.
- Confirm the rename has no missed reference (production or test).

Report findings with severity. If it is a faithful extraction, say so plainly and APPROVE.
