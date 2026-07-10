# BUILD SPEC-015 v0.4 settlement receipts IMPL prompt audit

Scope: `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`.

Required bar: 0 critical / 0 high / 0 medium across Codex code, Codex
security, Codex architect, Claude subscription-CLI adversarial verification,
and Claude subscription-CLI product design critic lanes.

## Final status

The BUILD IMPL prompt is ready for implementation.

Final counts:

| Lane | Final round | Result | Critical | High | Medium |
|---|---:|---|---:|---:|---:|
| Codex code | R3 | READY | 0 | 0 | 0 |
| Codex security | R1 | READY | 0 | 0 | 0 |
| Codex architect | R2 | READY | 0 | 0 | 0 |
| Claude adversarial verification | R1 | READY | 0 | 0 | 0 |
| Claude product design critic | R1 | READY | 0 | 0 | 0 |

Clean lanes were not refired after reaching 0/0/0.

## Codex code lane

### Round 1

Artifact:
`.omc/artifacts/ask/codex-audit-build-spec-015-v0-4-impl-code-prompt-you-are-auditing--2026-06-30T17-24-58-887Z.md`

Verdict: NEEDS REVISION, 0 critical / 1 high / 2 medium.

Findings:

- `CODE-H-1`: provider issuance was ordered before hard dependencies:
  terminal/output/usage canonicalization and receipt ingestion/storage.
- `CODE-M-1`: prompt referenced non-existent
  `phase4-coordinator/internal/buyer/forward_loop.go`.
- `CODE-M-2`: SPEC-022 money-movement boundary needed tighter wording around
  buyer debit, provider credit, payout-ready rows, and enforce-mode startup.

Resolution:

- Reordered steps so terminal/output/usage canonicalization precedes provider
  issuance.
- Removed `forward_loop.go`; current prompt names `server.go`,
  `forward_with_failover.go`, `forward_state.go`, `streaming_timing.go`, and
  `transport_result.go`.
- Tightened text so SPEC-015 v0.4 exposes receipt-verifier outcomes and
  capability evidence only; SPEC-022 owns buyer debit, provider credit,
  payout-ready rows, and enforce-mode startup gating.

### Round 2

Artifact:
`.omc/artifacts/ask/codex-audit-build-spec-015-v0-4-impl-code-r2-prompt-you-are-re-aud-2026-06-30T17-29-15-593Z.md`

Verdict: NEEDS REVISION, 0 critical / 1 high / 0 medium.

Finding:

- `CODE-H-1`: provider issuance still depended on streaming receipt submission
  through a coordinator-ingested channel before the coordinator ingestion
  API/channel existed.

Resolution:

- Reordered implementation steps so coordinator receipt ingestion/storage/
  verdict state is Step 5 and provider v0.4 issuance is Step 6. Step 6 now
  explicitly uses the internal coordinator-ingested channel from Step 5.

### Round 3

Artifact:
`.omc/artifacts/ask/codex-audit-build-spec-015-v0-4-impl-code-r3-prompt-you-are-re-aud-2026-06-30T17-31-32-397Z.md`

Verdict: READY, 0 critical / 0 high / 0 medium.

Closure evidence:

- Coordinator route snapshot, terminal/output/usage canonicalization, verifier
  mapping, and coordinator receipt ingestion/storage/verdict state all land
  before provider issuance.
- No stale `forward_loop.go` reference remains.
- SPEC-022 money movement remains downstream/deferred.
- Strict `settlement_output_v1`, route snapshots, usage, timestamp authority,
  receipt-key identity, streaming/non-streaming coverage, and redaction remain
  implementable.

## Codex security lane

Artifact:
`.omc/artifacts/ask/codex-audit-build-spec-015-v0-4-impl-security-prompt-you-are-audit-2026-06-30T17-23-10-698Z.md`

Verdict: READY, 0 critical / 0 high / 0 medium.

## Codex architect lane

### Round 1

Artifact:
`.omc/artifacts/ask/codex-audit-build-spec-015-v0-4-impl-architect-prompt-you-are-audi-2026-06-30T17-24-47-004Z.md`

Verdict: NEEDS REVISION, 0 critical / 2 high / 1 medium.

Findings:

- `ARCH-H-1`: coordinator receipt verdict state depended on verifier behavior
  that landed in a later step.
- `ARCH-H-2`: shared Go canonicalization was not architected early enough for
  coordinator/gateway use; phase4/phase5 cannot import
  `phase7-verify/internal/*`.
- `ARCH-M-1`: prompt referenced non-existent
  `phase4-coordinator/internal/buyer/forward_loop.go`.

Resolution:

- Verifier support and settlement mapping moved before coordinator verdict
  storage.
- Step 1 now requires fixture-locked Go canonicalization/conformance tests in
  phase4, phase5, and phase7, and explicitly forbids coordinator/gateway
  imports from `phase7-verify/internal/*`.
- Stale file reference removed.

### Round 2

Artifact:
`.omc/artifacts/ask/codex-audit-build-spec-015-v0-4-impl-architect-r2-prompt-you-are-r-2026-06-30T17-28-50-861Z.md`

Verdict: READY, 0 critical / 0 high / 0 medium.

## Claude adversarial verification lane

Execution: Claude subscription CLI, not API, using
`claude --setting-sources project,local --disallowedTools Bash,Edit,Write,Task --permission-mode dontAsk --output-format text --print ...`.

Verdict: READY, 0 critical / 0 high / 0 medium.

Low advisories, accepted as non-blocking:

- Define "covered attempt" consistently with SPEC-015 §N.2 wording.
- Surface the paid-entrypoint canonical-hash exclusion requirement directly in
  step text.
- Make strict `settlement_output_v1` field exactness explicit.
- Avoid folding `provider_receipt_key_id` into the storage dedup key.

The prompt was updated for the relevant low-advisory text while Code/Architect
fixes were applied; the lane had no critical/high/medium findings and was not
refired.

## Claude product design critic lane

Execution: Claude subscription CLI, not API, same subscription CLI mode as the
adversarial lane.

Verdict: READY, 0 critical / 0 high / 0 medium.

Low advisories, accepted as non-blocking:

- Provider-facing reason-code wording could distinguish submission failures
  from later settlement-quarantine causes in a future SPEC-022 surface.
- The exact buyer disclosure surface remains controlled by AC-68 and the
  implementation step, not hard-coded in the prompt.

The product lane confirmed the prompt frames v0.4 as full-product receipt trust
floor work, not beta-only work.
