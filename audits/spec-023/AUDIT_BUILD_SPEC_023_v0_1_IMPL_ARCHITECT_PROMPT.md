# AUDIT_BUILD_SPEC_023_v0_1_IMPL_ARCHITECT_PROMPT

You are the ARCHITECT auditor for the SPEC-023 v0.1 implementation prompt.

Work read-only in the macprovider repo. Do not edit files.

## Required Reading

Read these files fully before auditing:

- `specs/SPEC-023-installer-autotune-recommend.md`
- `specs/SPEC-023-v0_1-r7-audit.md`
- `specs/BUILD_SPEC_023_v0_1_IMPL_PROMPT.md`
- Relevant current repo architecture surfaces named by the build prompt:
  - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
  - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
  - `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
  - `phase4-coordinator/internal/buyer/server.go`
  - `phase4-coordinator/cmd/coordinator/main.go`
  - `phase5-gateway/README.md`

## Scope

Audit only the implementation prompt. Do not audit implementation code, because no SPEC-023 implementation has been written yet.

## Architecture Checklist

Find prompt defects that would make the implementation structurally wrong:

- Prompt reopens or contradicts SPEC-023 non-goals.
- Prompt crosses coordinator/gateway/provider boundaries incorrectly.
- Prompt under-specifies the `/v1/rate-card` buyer-mux/nginx route or accidentally changes gateway buyer API behavior.
- Prompt creates a hidden new control plane beyond static JSON + rate-card endpoint.
- Prompt does not preserve the existing autotune benchmark path while adding `--recommend`.
- Prompt omits retune/status lifecycle, stored state, or deterministic stale detection.
- Prompt creates a local donor mode that requires coordinator/gateway donor routing in v0.1.
- Prompt decomposes implementation in an order that makes tests or integration unworkable.
- Prompt lacks a credible acceptance-criteria ownership matrix or final verification contract.
- Prompt implies SPEC text edits, PR opening, or implementation work before prompt-audit convergence.

## Severity Guide

- CRITICAL: prompt requires an architecture that violates locked non-goals or money-path/gateway boundaries.
- HIGH: prompt misses a required subsystem or orders work so the implementation cannot converge safely.
- MEDIUM: prompt ambiguity could create incompatible subsystem boundaries or lifecycle behavior.
- LOW: citation, wording, or process issue unlikely to change architecture.

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
