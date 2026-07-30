# AUDIT_SPEC_015_v0_4_IMPL_STEP_4

Step: SPEC-015 v0.4 implementation Step 4 - verifier support and settlement
mapping.

Date: 2026-07-01

Verdict: READY for Step 4 Codex-gated closure.

Final counts:

| Lane | Tool | Critical | High | Medium | Status |
|---|---|---:|---:|---:|---|
| Code | Codex subagent | 0 | 0 | 0 | READY |
| Security | Codex subagent | 0 | 0 | 0 | READY |
| Architect | Codex subagent | 0 | 0 | 0 | READY |
| Adversarial verification | Claude subscription CLI | deferred | deferred | deferred | DEFERRED |
| Product design critic | Claude subscription CLI | deferred | deferred | deferred | DEFERRED |

Note: On 2026-07-01 the operator narrowed per-step work to the three Codex
lanes only. Claude subscription CLI adversarial/product lanes are deferred
until the full implementation across all steps has landed.

Scope audited:

- `implementation-notes-spec-015-v0-4.md` Step 4.
- `specs/SPEC-015-receipts.md` §N.8 through §N.9 and AC-43 through AC-71.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase7-verify/internal/verify/settlement.go`
- `phase7-verify/internal/verify/settlement_test.go`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase4-coordinator/internal/billing/settlement_verifier_test.go`
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/store_test.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/forward_loop_test.go`
- Step 4 tests in `phase4-coordinator/internal/billing/`,
  `phase4-coordinator/internal/buyer/`, and `phase7-verify/internal/verify/`.

Implementation validation:

- `cd phase7-verify && go test ./internal/verify -run Settlement -count=1 -v`
  PASS.
- `cd phase7-verify && go test ./...` PASS.
- `cd phase4-coordinator && go test ./internal/billing -run 'Settlement|RouteSnapshot' -count=1 -v`
  PASS.
- `cd phase4-coordinator && go test ./internal/buyer -run 'RouteSnapshot|Settlement' -count=1 -v`
  PASS.
- `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer`
  PASS.
- `cd phase4-coordinator && go test ./...` PASS.
- `git diff --check` PASS.

Closure evidence:

- Codex architect lane final rerun: READY, 0 critical / 0 high / 0 medium.
- Codex security lane final rerun: READY, 0 critical / 0 high / 0 medium.
- Codex code lane final rerun after the phase7 route snapshot validation fix:
  READY, 0 critical / 0 high / 0 medium.

Critical/high/medium findings fixed during Step 4 audit loop:

- CRITICAL/HIGH: provider-signed usage could previously drive `verified`
  without coordinator/gateway usage authority. Fixed by adding expected usage,
  usage source, and cross-check inputs to both verifier implementations, and by
  quarantining missing, byte-estimated, or mismatched usage evidence.
- HIGH/MEDIUM: overlap/duplicate output ranges and already-terminal rows were
  not part of the Step 4 verifier API. Fixed with explicit ledger-state inputs
  and non-payable reasons.
- HIGH: Step 5 would have needed to reparse raw receipts to persist verifier
  safe fields. Fixed by adding sanitized parsed facts and check booleans to the
  verifier result.
- MEDIUM: replay coverage only covered one or two dimensions. Fixed with
  table-driven trust-boundary mutations in both module-local test suites.
- HIGH: settlement output persistence retained raw canonical output JSON.
  Fixed by computing `output_hash` transiently and persisting `NULL` for raw
  output JSON.
- HIGH/MEDIUM: route/output digest database checks did not fully enforce
  lowercase 64-hex shape, and sanitized facts lacked the receipt usage digest.
  Fixed with stricter `CHECK` constraints, `usage_digest`, and progressive
  verifier checks on invalid/quarantined results.
- HIGH: coordinator attempt rows never became settlement-capable because usage
  evidence was only byte-estimated. Fixed by recording token-present upstream
  responses as `coordinator_observed` while keeping byte-estimated rows
  non-capable.
- HIGH: settlement attempt output rows were not account-scoped. Fixed by
  adding `account_scope` to persistence, uniqueness, immutable conflict checks,
  and overlap queries.
- MEDIUM: zero-byte tool-call outputs could bypass overlap/duplicate marking.
  Fixed by treating duplicate `output_hash` as duplicate evidence even when
  byte ranges are empty.
- MEDIUM: negative fixture public reason semantics were not fully locked, and
  terminal out-of-enum vectors could return a broader ledger mismatch reason.
  Fixed with `expected_failure` assertions and terminal enum validation before
  ledger-state terminal mismatch.
- MEDIUM: the tuple canonical digest fact initially hashed raw receipt input
  instead of canonical tuple bytes. Fixed by hashing `tuple.CanonicalBytes`.
- MEDIUM: partial-prefix non-normal terminals incorrectly required positive
  billable tokens. Fixed by allowing zero billable tokens within observed usage
  bounds.
- MEDIUM: phase7 route snapshot digesting accepted invalid snapshot structures.
  Fixed by adding local route snapshot validation before digest computation.

Residual risk and deferrals:

- This step still does not add receipt ingestion/storage state transitions,
  buyer final debit, provider-positive settlement, payout readiness, or
  SPEC-022 enforce activation.
- Claude subscription CLI adversarial verification and product design critic
  lanes are deferred until the full SPEC-015 v0.4 implementation lands, per
  operator instruction.
- Provider-side v0.4 receipt emission remains a later implementation step; Step
  4 closes verifier semantics and settlement mapping inputs.
