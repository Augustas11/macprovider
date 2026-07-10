# AUDIT_SPEC_015_v0_4_IMPL_STEP_1

Step: SPEC-015 v0.4 implementation Step 1 - canonical contract and fixtures.

Date: 2026-06-30

Verdict: READY.

Final counts:

| Lane | Tool | Critical | High | Medium | Status |
|---|---|---:|---:|---:|---|
| Code | Codex subagent | 0 | 0 | 0 | READY |
| Security | Codex subagent | 0 | 0 | 0 | READY |
| Architect | Codex subagent | 0 | 0 | 0 | READY |
| Adversarial verification | Claude subscription CLI | 0 | 0 | 0 | READY |
| Product design critic | Claude subscription CLI | 0 | 0 | 0 | READY |

Scope audited:

- `implementation-notes-spec-015-v0-4.md`
- `testdata/spec015/v04_settlement_receipts.json`
- `phase7-verify/testdata/generator/v04/main.go`
- `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`
- `phase4-coordinator/internal/spec015contract/`
- `phase5-gateway/internal/spec015contract/`
- `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`
- `specs/SPEC-015-receipts.md` Section N
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 1

Final audit evidence:

- Code lane verified exact failover-chain assertions in Swift, phase4, phase5,
  and phase7: tuple IDs, output IDs, attempts, `[0,13)` / `[13,30)` ranges,
  and terminal states.
- Security lane verified deterministic Ed25519 fixture signing, provider key ID
  derivation, signed receipt integrity, route/output/usage binding, negative
  receipt coverage, and no SPEC-022 money movement.
- Architect lane verified scenario-based route IDs, zero-based contiguous
  `attempt_n` per request, explicit negative range scenarios, cross-language
  enforcement, module boundaries, and no runtime settlement behavior.
- Claude adversarial lane verified streaming and terminal-state coverage,
  strict-shape coverage, signature/key/output-hash binding, cross-module parity,
  and no SPEC-022 money movement.
- Claude product lane verified the slice is framed as full-product trust-floor
  infrastructure, not a launch shortcut; does not imply enforce-mode money
  settlement is live; preserves streaming as first-class agentic tooling; and
  does not overclaim local model-measurement integrity.

Findings fixed during audit:

- HIGH: the shared request chain originally used non-zero-based attempts
  (`1`, `10`). Fixed by making `attempt_n` zero-based per request, moving
  scenario identity into fixture IDs, and adding cross-language per-request
  attempt sequence assertions.
- MEDIUM: range-integrity negatives were absent. Fixed with
  `negative_range_scenarios` for overlap, duplicate, and out-of-order ranges.
- MEDIUM: usage-integrity negatives were incomplete. Fixed with signed
  negatives for mismatched `delivered_output_bytes`, negative usage, `usage:
  null`, missing usage field, and extra usage field.
- MEDIUM: strict-shape top-level extra-field coverage was incomplete. Fixed
  with `negative_receipt_extra_top_level_field`.
- MEDIUM: failover chain modeled two `normal_done` attempts for one request.
  Fixed by making the chain `upstream_transport_disconnect [0,13)` followed by
  streaming `normal_done [13,30)`, while keeping standalone nonzero
  `normal_done` outside the chain.
- MEDIUM: failover-chain tests were not exact enough. Fixed by asserting exact
  tuple IDs, output IDs, attempts, ranges, and terminal states in all four
  conformance suites.
- MEDIUM: model-hash and terminal-state mismatch negatives were absent. Fixed
  with signed `model_hash_mismatch`, `terminal_state_mismatch`, and
  `terminal_state_out_of_enum` vectors across Swift, phase4, phase5, and
  phase7.

Low/info items deferred to later verifier/runtime steps:

- Timestamp skew and replay-axis negatives require verifier/ledger state and
  remain later-step audit surface.
- Pure streaming `[DONE]` object is canonical/hash-checked but not signed as a
  standalone tuple; signed streaming coverage uses the tool-call tuple.
- `negative_range_scenarios` are detector fixtures, not signed receipt vectors.
- Nested `tool_calls` shape is hash-bound but not separately strict-key-checked.
- Product/operator copy must continue to preserve SPEC-015 Section N / SPEC-022
  caveats that v0.4 binds provider-reported model hash to catalog expectation
  but does not prove malicious local model measurement.

Validation at closure:

- `cd phase3-binary && swift test --filter SPEC015V04SettlementFixtureTests`
  PASS, 8 tests.
- `cd phase4-coordinator && go test ./...` PASS.
- `cd phase5-gateway && go test ./...` PASS.
- `cd phase7-verify && go test ./...` PASS.
- `cd phase7-verify && go run ./testdata/generator/v04 -out ../testdata/spec015
  && git diff --exit-code -- ../testdata/spec015/v04_settlement_receipts.json`
  PASS, no diff.
- `git diff --check` PASS.
- `rg -n "phase7-verify/internal|github.com/augstar/macprovider/phase7-verify/internal" phase4-coordinator phase5-gateway`
  returned no matches.

Known baseline retained:

- Full `cd phase3-binary && swift test` still has the pre-existing
  `ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  failure from Step 0; Step 1 only adds the focused
  `SPEC015V04SettlementFixtureTests` suite.
