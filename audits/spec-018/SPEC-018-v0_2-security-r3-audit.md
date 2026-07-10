# SPEC-018 v0.2.2 -- SECURITY lane round-3 audit

Date: 2026-06-27
Lane: security
Scope: round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 after r2 absorption, limited to v0.2.2 additions and the two r2 security minors.

## Counts

CRITICAL: 0
HIGH: 0
MEDIUM: 0
minor: 0
Q: 0

## Verdict

READY TO LOCK reconfirmed from the security lane.

v0.2.2 closes both r2 security minors and does not regress the v0.2.1 READY TO LOCK posture. The new aggregate caps are request-validation gates before inference, not provider-fault settlement paths. AC-46's `null` unknown-hash sentinel remains observation-only and does not create parser, settlement, receipt, or SPEC-015 authority. Moving `prompt_echo_blocked` out of the buyer-visible code table is security-positive because the buyer sees plain-content fallback rather than a parser-failure reason.

## R2 security minor closure

### m-1 -- `invalid_tools` table inheritance note

Status: CLOSED.

Evidence:
- Section 10d.0 now states that `invalid_tools` is inherited from pre-existing SPEC-001 / SPEC-002 request validation and intentionally not duplicated in the v0.2.X-specific code table (`specs/SPEC-018-agentic-tool-calling.md:726`).
- Section 5 still uses `invalid_tools` for malformed assistant-history `tool_calls[]` request-side validation (`specs/SPEC-018-agentic-tool-calling.md:380`), and §10d.1 keeps the same behavior in the failure table (`specs/SPEC-018-agentic-tool-calling.md:765`).

Security conclusion: the table-domain ambiguity is closed without changing the security semantics. `invalid_tools` remains a stable request-validation error code owned by earlier specs.

### m-2 -- AC-46 vs §10d.0.1 unknown-hash inconsistency

Status: CLOSED by Option A (`null` sentinel).

Evidence:
- AC-46 now requires every v0.2 provider response to include `usage.macprovider_model_hash_observed`, with JSON type `null | "^[a-f0-9]{64}$"`; known hashes must be lowercase SHA-256 hex, and unknown provider hashes use `null` (`specs/SPEC-018-agentic-tool-calling.md:606`).
- §10d.0.1 now matches AC-46: every v0.2 provider response includes the field, the value is `null` when no known served hash exists, and the field is non-canonicalized, observation-only, and forbidden from affecting parser/profile selection, settlement, or SPEC-015 binding (`specs/SPEC-018-agentic-tool-calling.md:730`).
- AC-25a now captures `usage.macprovider_model_hash_observed` in release evidence and requires Cline success whether the value is known hex or `null`, with no Cline branching on the value (`specs/SPEC-018-agentic-tool-calling.md:560`).

Security conclusion: the release-gate fixture ambiguity is closed. The field is mandatory evidence, not v0.2 trust authority.

## Defensive r3 security sweep

### AC-50 through AC-54 -- aggregate caps and money-path posture

Status: CLEAN.

Evidence:
- AC-50 rejects raw request bodies greater than 4 MiB before inference with HTTP 413 `request_body_too_large`; it explicitly fails any path where an over-cap body reaches inference or returns a retryable/provider error (`specs/SPEC-018-agentic-tool-calling.md:614`).
- AC-51 and AC-52 reject aggregate request-side tool-result content and assistant-history argument bytes before inference with HTTP 413 request errors (`specs/SPEC-018-agentic-tool-calling.md:616`, `specs/SPEC-018-agentic-tool-calling.md:618`).
- AC-53 and AC-54 reject too many messages or assistant-history tool calls before prompt rendering or provider inference (`specs/SPEC-018-agentic-tool-calling.md:620`, `specs/SPEC-018-agentic-tool-calling.md:622`).
- The §10d.0 stable code table classifies all new aggregate-cap codes as `invalid_request_error` and `retryable: false`, not `upstream_provider_error` or fault-breaker provider faults (`specs/SPEC-018-agentic-tool-calling.md:713-719`).
- §10d.1 requires coordinator validation to mirror these failures before provider dispatch (`specs/SPEC-018-agentic-tool-calling.md:775`).

Security conclusion: no money-path regression. These failures are buyer/request validation gates. They do not run inference, do not create provider-positive credit, do not produce receipts, and should not be `FaultBreakerQualifying` provider faults.

### AC-55 -- linear validation and DoS posture

Status: CLEAN.

Evidence:
- AC-55 requires cross-message `tool_call_id` validation to be O(messages[] + tool_calls[]) using a linear profile such as one pass with maps/sets, with pass and adversarial fixtures at the v0.2 maximum sizes (`specs/SPEC-018-agentic-tool-calling.md:624`).
- §10d.1 repeats that validation must use maps/sets and that O(N^2) repeated scans are non-compliant (`specs/SPEC-018-agentic-tool-calling.md:752`).
- The caps bound the maximum validation surface to 256 messages and 128 assistant-history tool calls (`specs/SPEC-018-agentic-tool-calling.md:749-750`).

Security conclusion: no new DoS surface. The new AC makes an existing validation risk testable and bounded rather than opening a higher-cost validation path.

### AC-46 -- unknown-hash `null` information disclosure

Status: CLEAN.

Evidence:
- AC-46 allows `null` only when the provider has no known hash and fails `null` when a provider hash is known (`specs/SPEC-018-agentic-tool-calling.md:606`).
- §10d.0.1 says Cline and other OpenAI clients need not act on the value; macprovider release evidence and logs may capture it for diagnostics and v0.3 registry preparation (`specs/SPEC-018-agentic-tool-calling.md:730`).
- The field is explicitly non-canonicalized and must not affect parser/profile selection, settlement, or SPEC-015 output binding (`specs/SPEC-018-agentic-tool-calling.md:730`).

Information-disclosure analysis: `null` reveals that the serving path lacks a known recorded model hash. That is coarse operational state, not a secret, credential, settlement fact, or routing authority. It is less ambiguous than an absent field, supports deterministic release evidence, and is not attacker-useful for v0.2 parser or money-path manipulation because buyers and implementations are forbidden from branching security decisions on it.

Security conclusion: acceptable. The `null` sentinel is a diagnostic disclosure with bounded value and better auditability than field absence.

### `prompt_echo_blocked` internal-only move

Status: CLEAN, security-positive.

Evidence:
- §3.9 now says prompt-echo guard firing produces no buyer-visible HTTP/SSE error envelope; the buyer-visible behavior is normal plain assistant content with no synthesized `tool_calls[]`, while implementations may log internal code `prompt_echo_blocked` (`specs/SPEC-018-agentic-tool-calling.md:305`).
- AC-49 fails any implementation that emits buyer-visible error code `prompt_echo_blocked` (`specs/SPEC-018-agentic-tool-calling.md:612`).
- §10d.0 states the stable table contains buyer-visible HTTP/SSE error-envelope codes only, and internal fallback reasons are not buyer-visible v0.2 codes (`specs/SPEC-018-agentic-tool-calling.md:703`).
- §10d.1 maps the echoed native block case to plain-content fallback with no buyer-visible error, retaining only the internal log code (`specs/SPEC-018-agentic-tool-calling.md:773`).

Security conclusion: the change reduces parser-oracle leakage. A buyer can observe that no executable `tool_calls[]` were synthesized, but does not receive a specific reason explaining that a prompt-echo defense fired.

## Final lock-readiness reconfirmation

Security lane remains READY TO LOCK for v0.2.2:

- r2 security minors are closed.
- The v0.2.2 aggregate caps strengthen request-bound DoS controls and are correctly classified as non-retryable request-validation errors.
- AC-55 hardens validation complexity with a release-gated linear-time requirement.
- AC-46 `null` sentinel is observation-only and does not become trust, parser-selection, settlement, or receipt authority.
- `prompt_echo_blocked` moved from public code space to internal logging only, reducing buyer-visible parser-failure detail.
- No money-path, trust-boundary, prompt-echo, streaming-dispatch, or model-hash regression found in the v0.2.2 delta.

## Self-verification

- Read the v0.2.2 SPEC body and checked the changed areas for AC-46, AC-50 through AC-55, §3.9, §10d.0, §10d.0.1, and §10d.1.
- Read the r2 security audit, r2 narrative, r2 absorption prompt, and v0.2.2 draft notes.
- Checked that this audit is scoped only to v0.2.2 additions and does not reopen locked v0.1.5 content.
