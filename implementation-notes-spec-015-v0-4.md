# SPEC-015 v0.4 implementation notes

## Step 0 - Preflight and baseline

Date: 2026-06-30

Worktree:

- Path: `/Users/augstar/macprovider-impl-spec-015-v0-4`
- Branch: `impl/spec-015-v0-4-settlement-receipts`
- Base: SPEC branch commit `d70eb16` (`Lock settlement receipt trust floor`)
- Dirty state before product edits: clean (`git status -sb` showed only the
  branch name)

Locked-spec evidence:

- `specs/SPEC-015-receipts.md` line 3 is locked at `0.4.2`.
- `specs/SPEC-015-v0-4-audit.md` final status is 0 critical / 0 high /
  0 medium across Codex code, Codex security, Codex architect, Claude
  adversarial verification, and Claude product design critic lanes.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT_AUDIT.md`
  final status is 0 critical / 0 high / 0 medium across the same five lanes.

SPEC-022 boundary:

- SPEC-022 D-022-1 frames this as a product-wide trust floor, not a beta-only
  shortcut or temporary launch exception.
- `specs/SPEC-022-verified-model-settlement.md` still treats SPEC-015 v0.3 or
  earlier receipts as not settlement-capable. SPEC-015 v0.4 work must not wire
  enforce-mode buyer final debit, provider-positive settlement, payout
  readiness, or gateway money movement.
- Step 1 remains a contract/fixture slice before any product behavior lands.

Baseline commands:

| Command | Result | Evidence |
|---|---|---|
| `cd phase4-coordinator && go test ./...` | PASS | completed before implementation edits |
| `cd phase5-gateway && go test ./...` | PASS | completed before implementation edits |
| `cd phase7-verify && go test ./...` | PASS | completed before implementation edits |
| `cd phase3-binary && swift test` | FAIL, known baseline | 672 tests, 7 skipped, 1 failure |

Swift baseline failure:

- Full suite log: `/tmp/spec015-v04-swift-test.log`.
- Failing test:
  `ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  at `phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift:64`.
- Targeted rerun:
  `swift test --filter ModelsSubcommandTests/testModelsListDisabledModePrintsIdleTableAndExitsZero`
  also failed with the same assertion.
- This branch had no product code edits when the failure was observed, so later
  SPEC-015 verification should use targeted tests for changed receipt behavior
  and keep this failure visible as a pre-existing baseline issue until fixed in
  a separate slice.

Stop condition:

- Step 0 is complete when the five Step 0 audit lanes report 0 critical /
  0 high / 0 medium on this preflight evidence.

## Step 1 - v0.4 canonical contract and fixtures

Date: 2026-06-30

What landed:

- Deterministic v0.4 settlement fixture generator:
  `phase7-verify/testdata/generator/v04/main.go`.
- Shared fixture corpus:
  `testdata/spec015/v04_settlement_receipts.json`.
- Swift fixture/parity tests:
  `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`.
- Go module-local conformance tests:
  `phase4-coordinator/internal/spec015contract/`,
  `phase5-gateway/internal/spec015contract/`, and
  `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`.

Fixture coverage:

- `receipt_version: "4"` signed tuples with deterministic Ed25519 signatures
  and strict v0.4 tuple keys.
- `route_snapshot_v1` strict object and digest.
- `settlement_output_v1` strict objects for non-streaming `normal_done`,
  streaming `[DONE]`/`normal_done`, `provider_error`, `buyer_cancel`,
  `gateway_timeout`, and `upstream_transport_disconnect`, including empty and
  non-empty prefix cases.
- A signed streaming/tool-call tuple with a non-zero output prefix and
  adversarial canonicalization content (`<`, `>`, `&`, and decomposed Unicode)
  so the streaming path is represented end-to-end, not only as a standalone
  output object.
- Strict `usage` objects for normal billable, zero-settled empty prefix, and
  partial-prefix billable cases.
- Per-request attempt sequencing fixtures use `attempt_n` as a zero-based
  contiguous retry/failover counter; scenario identity lives in fixture IDs,
  not in attempt numbers.
- Negative receipt vectors cover output-hash mismatch, route digest mismatch,
  model-hash mismatch, terminal-state mismatch, out-of-enum terminal state,
  attempt mismatch, wrong-key signature, legacy receipt version, missing
  `output_hash`, extra top-level tuple field, mismatched
  `delivered_output_bytes`, negative usage values, missing/extra usage fields,
  and `usage: null`.
- `negative_range_scenarios` cover overlapping, duplicate, and out-of-order
  output prefix ranges outside the positive receipt corpus, while the positive
  shared chain keeps adjacent half-open ranges `[0,13)` and `[13,30)` with
  `upstream_transport_disconnect` as the non-final prefix and streaming
  `normal_done` as the final tuple.
- Cross-language canonical byte/hash parity between Swift and Go for the
  receipt tuple, route snapshot, usage, and `settlement_output_v1` fixtures.
- Cross-object assertions bind each signed tuple to its route snapshot digest,
  output hash, output byte range, usage delivered-byte count, Ed25519
  signature, and `provider_receipt_key_id`.

Import boundary:

- `phase4-coordinator` and `phase5-gateway` do not import
  `phase7-verify/internal/*`. Their Step 1 tests use module-local test
  canonicalizers locked by the same golden fixture corpus.
- `phase5-gateway` now uses the same `golang.org/x/text v0.37.0` module
  version already used by phase4 and phase7 so its test-only canonicalizer can
  normalize string values to NFC.

Validation:

| Command | Result |
|---|---|
| `cd phase3-binary && swift test --filter SPEC015V04SettlementFixtureTests` | PASS, 8 tests |
| `cd phase4-coordinator && go test ./...` | PASS |
| `cd phase5-gateway && go test ./...` | PASS |
| `cd phase7-verify && go test ./...` | PASS |
| `rg -n "phase7-verify/internal\|github.com/augstar/macprovider/phase7-verify/internal" phase4-coordinator phase5-gateway` | no matches |
| deterministic regeneration diff for `testdata/spec015/v04_settlement_receipts.json` | PASS, no diff |

Known baseline retained:

- Full `cd phase3-binary && swift test` is still expected to fail on the
  pre-existing `ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  issue recorded in Step 0. The new Step 1 Swift fixture tests pass.

Stop condition:

- Step 1 is complete when the five Step 1 audit lanes report 0 critical /
  0 high / 0 medium on this fixture/contract slice.
