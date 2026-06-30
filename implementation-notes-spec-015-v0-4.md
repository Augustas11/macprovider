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
