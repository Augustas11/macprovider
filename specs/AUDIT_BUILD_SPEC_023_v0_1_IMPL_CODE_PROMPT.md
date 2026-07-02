# AUDIT_BUILD_SPEC_023_v0_1_IMPL_CODE_PROMPT

You are the CODE auditor for the SPEC-023 v0.1 implementation prompt.

Work read-only in the macprovider repo. Do not edit files.

## Required Reading

Read these files fully before auditing:

- `specs/SPEC-023-installer-autotune-recommend.md`
- `specs/SPEC-023-v0_1-r7-audit.md`
- `specs/BUILD_SPEC_023_v0_1_IMPL_PROMPT.md`
- Current repo code surfaces named by the build prompt, especially:
  - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
  - `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
  - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
  - `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
  - `phase4-coordinator/internal/buyer/server.go`
  - `phase4-coordinator/cmd/coordinator/main.go`
  - `phase4-coordinator/internal/billing/formula.go`
  - `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`

## Scope

Audit only the implementation prompt. Do not audit implementation code, because no SPEC-023 implementation has been written yet.

## Code-Mechanics Checklist

Find prompt defects that would make a conforming implementer write the wrong code:

- Wrong file paths, command names, branch/worktree instructions, or repo surfaces.
- Missing implementation slice for any locked SPEC-023 requirement or AC.
- Incorrect mapping from AC-1 through AC-39 to implementation/test slices.
- Prompt instructions that contradict current Swift or Go package patterns.
- Prompt instructions that accidentally require changing money-path schemas, `RateCardEntry`, billing formula, ledger, settlement, request logs, or gateway routing.
- Unclear `--recommend` integration with the existing `autotune` command and existing benchmark behavior.
- Missing deterministic algorithms needed for tests: field order, hash derivation, stable selection, rate-card version, catalog hash, artifact hash, bandwidth tier order.
- Test plan gaps where a SPEC AC can be tested but the prompt leaves it to prose.
- Any stale command name such as `macprovider` instead of `macprovider-cli`.

## Severity Guide

- CRITICAL: prompt would drive implementation that violates money-path boundaries, omits a mandatory safety gate, or cannot be implemented without major redesign.
- HIGH: prompt would likely produce code that fails a locked SPEC-023 AC or uses the wrong repo surface.
- MEDIUM: prompt is ambiguous enough that two competent implementers could produce incompatible behavior for a required v0.1 contract.
- LOW: citation, wording, or hygiene issue unlikely to change implementation behavior.

## Output Contract

Return:

- Verdict: `READY TO BUILD` or `NEEDS FIX PASS`.
- Counts: Critical / High / Medium / Low.
- Findings ordered by severity. Each finding must include:
  - ID
  - severity
  - file:line
  - evidence from prompt and/or locked SPEC/current repo
  - impact
  - required prompt fix
- If no Critical/High/Medium findings remain, state that explicitly.
