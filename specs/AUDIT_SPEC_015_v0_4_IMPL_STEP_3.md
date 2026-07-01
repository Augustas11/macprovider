# AUDIT_SPEC_015_v0_4_IMPL_STEP_3

Step: SPEC-015 v0.4 implementation Step 3 - terminal-state, output, and usage
canonicalization.

Date: 2026-07-01

Verdict: READY for Step 3 Codex-gated closure.

Current counts:

| Lane | Tool | Critical | High | Medium | Status |
|---|---|---:|---:|---:|---|
| Code | Codex subagent | 0 | 0 | 0 | READY |
| Security | Codex subagent | 0 | 0 | 0 | READY |
| Architect | Codex subagent | 0 | 0 | 0 | READY |
| Adversarial verification | Claude subscription CLI | deferred | deferred | deferred | DEFERRED |
| Product design critic | Claude subscription CLI | deferred | deferred | deferred | DEFERRED |

Note: On 2026-07-01 the audit gate was narrowed for per-step work to the three
Codex lanes only. Claude subscription CLI adversarial/product lanes are
deferred until the full implementation across all steps has landed.

Scope to audit:

- `implementation-notes-spec-015-v0-4.md` Step 3.
- `specs/SPEC-015-receipts.md` §N.5 through §N.7 and AC-43 through AC-71.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement_output_test.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 3 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Implementation validation before audit:

- `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer` PASS.
- `cd phase4-coordinator && go test ./...` PASS.
- `git diff --check` PASS.

Closure evidence:

- Codex code lane: READY, 0 critical / 0 high / 0 medium.
- Codex security lane: READY, 0 critical / 0 high / 0 medium.
- Codex architect lane: READY, 0 critical / 0 high / 0 medium.
- Fixed audit-loop findings before closure:
  - unavailable output evidence now persists as `output_available=0` with
    nullable output hash/canonical JSON;
  - incomplete/malformed streaming tool-call and settlement evidence persists
    unavailable provider-error evidence;
  - streaming `normal_done` timestamps latch on first `data: [DONE]` and reject
    post-terminal data;
  - WS non-streaming and buffered streaming validate/log settlement evidence
    before receipt-bearing 200 responses;
  - settlement output `attempt_n` uses the route-snapshot provider-dispatch
    ordinal;
  - unavailable rows keep an empty `[0,0)` range even after prior prefixes.
