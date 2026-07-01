# AUDIT_SPEC_015_v0_4_IMPL_STEP_3_ADVERSARIAL_PROMPT

You are auditing Step 3 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 3.
- `specs/SPEC-015-receipts.md` §N.5 through §N.7 and AC-43 through AC-71.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 3 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Adversarially verify whether a buyer, provider, reconnect, timeout, malformed
SSE stream, retry/failover path, or provider usage claim could later let
SPEC-022 settle money against the wrong output, wrong terminal state, wrong
usage, or duplicate output range.

Required checks:

1. Try to find a streaming path that emits buyer-visible bytes but fails to
   persist matching `settlement_output_v1` evidence.
2. Try to find a path where a provider-only usage claim becomes
   settlement-capable without coordinator observation or cross-checking.
3. Try to find a retry/failover path where overlapping output prefixes are not
   marked non-creditable.
4. Try to find a terminal-error path that records `normal_done` or billable
   output incorrectly.
5. Try to find canonicalization drift for Unicode normalization, byte ranges,
   finish reasons, or tool-call argument fragments.
6. Try to find any loophole where this step effectively wires SPEC-022 money
   movement or treats legacy receipts as settlement-capable.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
