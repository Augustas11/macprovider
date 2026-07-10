# AUDIT_BUILD_SPEC_023_v0_1_IMPL_SECURITY_PROMPT

You are the SECURITY auditor for the SPEC-023 v0.1 implementation prompt.

Work read-only in the macprovider repo. Do not edit files.

## Required Reading

Read these files fully before auditing:

- `specs/SPEC-023-installer-autotune-recommend.md`
- `specs/SPEC-023-v0_1-r7-audit.md`
- `specs/BUILD_SPEC_023_v0_1_IMPL_PROMPT.md`
- Current repo security-relevant surfaces named by the build prompt, especially:
  - `phase3-binary/Sources/macprovider-cli/ReceiptKeyStore.swift`
  - `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
  - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
  - `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
  - `phase4-coordinator/internal/buyer/server.go`
  - `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`

## Scope

Audit only the implementation prompt. Do not audit implementation code, because no SPEC-023 implementation has been written yet.

## Security Checklist

Find prompt defects that would weaken SPEC-023 security/privacy guarantees:

- Static JSON signature/key/sidecar rules missing, ambiguous, or incorrectly scoped.
- Fallback rules that could accept tampered, stale, replayed, future-dated, or unsigned static JSON.
- Candidate catalog trust gaps that allow download/benchmark/recommend/donor commit without signed metadata.
- Mutable model artifact gaps: missing immutable revision, missing canonical hash verification, missing path-safety rejection, or tests that only check presence.
- Donor-mode bypass gaps, including arbitrary local model paths or paid network registration for non-recommendable rows.
- HMAC identity privacy gaps: missing CSPRNG local secret, unsafe storage, missing domain separation, raw fingerprint leakage, support bundle/log leakage.
- Benchmark gaming or cache poisoning gaps: stale cache identity, binary/catalog/model/hardware mismatch, swap/thermal omission.
- Rate-card public endpoint exposure or nginx route instructions that overexpose operator/provider/admin surfaces.
- Any instruction to inspect Darkbloom / d-inference source.

## Severity Guide

- CRITICAL: prompt would likely cause a bypass of signed catalog/static JSON trust, donor-mode paid-serving boundary, or raw secret/fingerprint leakage.
- HIGH: prompt omits a required security control or test for a locked SPEC-023 safety boundary.
- MEDIUM: prompt ambiguity could produce inconsistent or weaker security behavior.
- LOW: hygiene issue unlikely to weaken the shipped implementation.

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
