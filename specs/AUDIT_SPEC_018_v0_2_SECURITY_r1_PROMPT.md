# AUDIT_SPEC_018_v0_2_SECURITY_r1

## Task

Audit `specs/SPEC-018-agentic-tool-calling.md` v0.2.0 from the **security lens**: settlement protection (money-path), DoS attack surface, prompt-injection residual risk, multi-turn trust boundary, validator-split race conditions, mid-stream withdrawal vulnerabilities.

This is round 1 of a codex 4-lane audit per [[feedback-three-lane-codex-audits]]. Your peer lanes audit independently.

## Scope

**Only review v0.2 additions** (new change-log, §3.7, §8.4.1/.2/.3, §10d, AC-25 through AC-45). v0.1.5 LOCKED.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — drafted v0.2.0.
2. `specs/SPEC-018-v0_2-design-synthesis.md` — design source.
3. `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md` — self-acknowledged issues.
4. `specs/BUILD_SPEC_018_v0_2_PROMPT.md` — BUILD obligations.

Live repo for settlement-path tracing:
- `phase4-coordinator/internal/buyer/billing_recorder.go:176`
- `phase4-coordinator/internal/billing/formula.go:112`
- `phase4-coordinator/internal/buyer/server.go` (FaultBreakerQualifying flag uses)

## Your security lens

Focus on:
- **Money-path end-to-end**: trace each v0.2 failure mode to its settlement outcome. Does every malformed/oversized/cap-violation path arrive at `FaultBreakerQualifying` + zero provider credits? Are there ANY new failure modes that could permit non-zero settlement on bad provider behavior?
- **§8.4 split race condition**: incremental-open allows buyer-visible commit; final-close gates settlement. What happens if provider streams partial bytes (buyer-visible commit happens), then crashes / disconnects / coordinator times out before final-close? Money-path posture for this case must be unambiguous.
- **Mid-stream withdrawal prohibition**: §10d.4 says no "treat as content" fallback after any `tool_calls[]` delta emitted. Is the terminating SSE error frame + `[DONE]` mechanism safe against partial-acceptance attacks (buyer thinks it got a complete tool call, dispatches the partial-args result)? Is the AC-43 streaming forward-compat test sufficient to verify this?
- **Multi-turn trust boundary**: deliverable #1 accepts buyer-supplied assistant-history `tool_calls[]` and `role:"tool"` results. Buyer-fabricated IDs MUST be accepted (#6 says so). What's the attack surface? Could a malicious buyer manipulate the model into emitting tool calls it wouldn't otherwise emit by fabricating tool results? Does the model's "trust" in prior tool results create any new vulnerability?
- **DoS surfaces**:
  - 1 MiB per-call + 2 MiB per-response cap — is the per-response cap accumulator memory-bound? Could N concurrent streams each consuming 2 MiB exhaust gateway memory?
  - 256 KiB per-tool-result-content cap — is this enforced before or after JSON parsing of `messages[]`? Pre-parse means cap is on raw bytes; post-parse means an attacker could send compressed/escape-heavy content.
  - Cross-message consistency rules (#6) — is the validation O(N²) on `messages[]` length? Can a buyer DoS the provider with a large but format-valid `messages[]` array?
- **Prompt-injection residual**: v0.3 defers the prompt-echo guard. v0.2.0 §3.2 modelID-match-required closes cross-family bypass, but same-family prompt-echo (model echoes attacker's tool-call markup verbatim) is unmitigated. Is this acceptable for Cline's threat model? Should v0.2 add ANY mitigation, or is the deferral safe?
- **§10c forward-compat invariants**: v0.2 adds new locked invariants (1 MiB cap baseline, streaming wire shape). Does any v0.2 normative claim weaken a v0.1.5 §10c invariant? (codex must verify; not just claim "additive.")
- **Operator kill switch**: §10d.4 says operator can disable streaming. Is this an attack vector? A malicious operator could downgrade Cline to buffered-only, causing UX degradation. Does the SPEC require operator-kill-switch state to be observable to buyers?

## Output format

Write findings to `specs/SPEC-018-v0_2-security-r1-audit.md` with the standard structure.

## Severity bar

- **CRITICAL** — settlement can leak non-zero credits to bad provider behavior, money-path bypass, multi-turn trust boundary admits attack vector, DoS that brings down coordinator/gateway with single buyer.
- **HIGH** — partial-acceptance attack surface, prompt-injection residual that's exploitable in Cline's realistic threat model, DoS that degrades but doesn't down.
- **MEDIUM** — observability gap (operator-kill-switch invisible to buyers), trust-boundary edge case requiring clarification.
- **minor** — security narrative gap, defense-in-depth recommendation.
- **Q** — security trade-off needing explicit closure.

Be aggressive. Money-path bugs and trust-boundary holes are the worst possible outcome. False positives are cheap; missed CRITICAL is unrecoverable.
