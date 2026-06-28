# SPEC-018 v0.2.2 - Product-design-lane round-3 audit

## Counts

CRITICAL: 0
HIGH: 0
MEDIUM: 0
MINOR: 0
QUESTIONS: 0

## Inputs Reviewed

- `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 working copy.
- `specs/SPEC-018-v0_2-product-design-r2-audit.md`.
- `specs/SPEC-018-v0_2-r2-audit.md`.
- `specs/SPEC-018-v0_2-r2-absorption-prompt.md`.
- `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md`.

## Prior PD r2 Closure Matrix

### MEDIUM-1 - AC-46 is mandatory but absent from the Cline evidence schema

Status: CLOSED.

v0.2.2 adds `usage.macprovider_model_hash_observed` to the AC-25a machine-readable Cline transcript schema and makes the intended UX explicit: the Cline session must succeed whether the observed value is a known lowercase hex hash or `null`, and Cline must not branch on the value. AC-46 now requires the field on every v0.2 provider response with JSON type `null | "^[a-f0-9]{64}$"` and fixtures for both known-hash and unknown-hash cases. §10d.0.1 says the field is non-canonicalized, observation-only, and not a v0.2 parser/profile, settlement, or SPEC-015 binding input; Cline and other OpenAI clients need not act on it. Citations: `specs/SPEC-018-agentic-tool-calling.md:560`, `specs/SPEC-018-agentic-tool-calling.md:606`, `specs/SPEC-018-agentic-tool-calling.md:728-730`.

## Fresh r3 Product-Design Sweep

### AC-50 through AC-55 aggregate caps - Cline UX impact

No finding.

The v0.2.2 cap envelope is generous enough for the intended Cline coding-session UX:

- Raw request body cap: 4 MiB at the coordinator/provider boundary, rejected pre-inference with HTTP 413 `request_body_too_large`.
- Aggregate `role:"tool".content`: 1 MiB across all tool results, with the pre-existing 256 KiB per-message cap still independently enforced.
- Aggregate assistant-history `tool_calls[].function.arguments`: 2 MiB across the request, with the pre-existing 1 MiB per-call cap still independently enforced.
- Shape caps: 256 messages and 128 assistant-history tool calls.
- Validation complexity: linear `O(messages[] + tool_calls[])`, with a 256-message / 128-tool-call fixture and duplicate-ID adversarial fixture.

These values are above the normal operating range implied by the AC-25a Cline release gate: at least 20 provider turns, at least 30 tool calls/results, at least three file edits, at least two shell runs, and one large-write streaming case of at least 64 KiB. A legitimate Cline session could hit these caps only by carrying unusually large accumulated tool outputs or many historical assistant tool calls in one replay. In that case the spec requires explicit pre-inference HTTP 400/413 failures rather than truncation, provider 5xx, or post-inference failure, which is the correct UX for the boundary case. Citations: `specs/SPEC-018-agentic-tool-calling.md:560`, `specs/SPEC-018-agentic-tool-calling.md:602`, `specs/SPEC-018-agentic-tool-calling.md:614-624`, `specs/SPEC-018-agentic-tool-calling.md:744-756`, `specs/SPEC-018-agentic-tool-calling.md:758-771`.

Residual implementation note, not a PD finding: §10d.1 notes that some gateway deployments using SPEC-006 defaults may be stricter than the 4 MiB coordinator/provider cap. The AC-25a gate traverses gateway -> coordinator -> provider, so any public v0.2 endpoint used for the Cline release gate must be configured so normal Cline traffic reaches the v0.2 validation path.

### AC-46 `null` sentinel - Cline UX impact

No finding.

The `null` sentinel is correctly scoped as macprovider diagnostic evidence, not a Cline behavior branch. AC-25a requires success in both known-hash and unknown-hash cases and fails if Cline behavior differs based on the field. AC-46 and §10d.0.1 prohibit v0.2 enforcement based on the value and keep it outside canonical output binding and settlement. From Cline's perspective this is an additive OpenAI-compatible `usage` field that can be ignored. Citations: `specs/SPEC-018-agentic-tool-calling.md:560`, `specs/SPEC-018-agentic-tool-calling.md:606`, `specs/SPEC-018-agentic-tool-calling.md:728-730`.

### `prompt_echo_blocked` internal-only fallback - Cline UX impact

No finding.

v0.2.2 clearly moves `prompt_echo_blocked` out of the buyer-visible error-envelope code space. When the exact-verbatim prompt-echo guard fires, Cline sees normal plain assistant content with no synthesized `tool_calls[]` and no HTTP/SSE error envelope. That is acceptable for v0.2 because the guard is a narrow fail-closed safety fallback: it prevents execution of echoed prompt/tool-result text, preserves a valid assistant response shape, and does not make Cline handle a macprovider-specific error branch. The richer structured signal remains a v0.3 candidate, which matches the prior PD tradeoff acceptance. Citations: `specs/SPEC-018-agentic-tool-calling.md:299-305`, `specs/SPEC-018-agentic-tool-calling.md:612`, `specs/SPEC-018-agentic-tool-calling.md:703`, `specs/SPEC-018-agentic-tool-calling.md:773`, `specs/SPEC-018-agentic-tool-calling.md:933-936`.

UX caveat accepted for v0.2: if the guard fires during a Cline session, the user may see a plain assistant answer instead of an explicit diagnostic. That is less transparent than a structured signal, but it is preferable to dispatching a false tool call and avoids requiring Cline-specific handling before v0.3.

## Final Lock-Readiness Assessment

READY TO LOCK from the product-design lane.

Round 2 PD MEDIUM-1 is closed. The v0.2.2 additions do not introduce any new CRITICAL, HIGH, or MEDIUM product-design issues. The aggregate caps are high enough for legitimate Cline coding sessions under the specified release gate, the AC-46 `null` sentinel is observation-only and ignored by Cline, and the internal-only `prompt_echo_blocked` fallback is an acceptable v0.2 UX compromise with structured signaling deferred to v0.3.
