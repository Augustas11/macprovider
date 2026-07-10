# SPEC-018 v0.2.1 -- SECURITY lane round-2 audit

Date: 2026-06-27
Lane: security
Scope: round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.1 after r1 absorption, focused on prior security findings plus fresh review of v0.2.1 security additions.

## Counts

CRITICAL: 0
HIGH: 0
MEDIUM: 0
minor: 2
Q: 0

## Verdict

READY TO LOCK from the security lane.

The r1 money-path blocker is closed normatively. The remaining notes below are minor consistency fixes that do not reopen settlement, provider provenance, model-family trust, prompt-echo, or streaming-dispatch safety.

## Category sweep

| Lens | Result |
|---|---|
| Money-path final-close | CLOSED. Section 8.4.2 now requires terminal accumulated arguments, `finish_reason:"tool_calls"`, normal transport completion, and no post-open provider/relay/auth/truncation failure before settlement. Any missing condition is `FaultBreakerQualifying`, zero provider-positive credits, no receipt, and no sticky-route success write. |
| WS and direct HTTP streaming paths | CLOSED at SPEC level. AC-47 names both `forwardWSStreaming` and `forwardStreaming`. Live code already has the right billing primitive; the direct-HTTP clean EOF path still needs the v0.2 implementation patch called out by the SPEC. |
| Section 10c model-hash invariant | CLOSED by explicit Path B amendment. The change log and section 10c state the amendment, rationale, and precedent; AC-46 is observation-only and does not claim v0.2 registry security. |
| Prompt-echo guard | CLOSED for the v0.2 exact-echo attack. A complete native block echoed verbatim from request/tool content must fail closed to plain content. Transformed/canonicalized echoes remain the explicitly deferred v0.3 problem. |
| Mid-stream SSE error safety | CLOSED. Section 8.4.3 forbids `finish_reason:"tool_calls"` on terminal error, and AC-48 requires openai-python plus Cline not to receive dispatchable tool calls after final-close failure. |
| Aggregate request and streaming DoS bounds | CLOSED. v0.2.1 adds raw/decoded aggregate caps, max messages/tool calls, O(N) validation, per-stream response caps, and coordinator accumulator budget language. |
| Buyer-fabricated history provenance | CLOSED. v0.2.1 classifies request-side assistant/tool history as prompt data, not provider provenance, and forbids retroactive settlement/receipt/audit claims. |
| Kill-switch visibility and info disclosure | CLOSED. `X-MacProvider-Streaming-Mode` reveals operational streaming mode but not credentials, secrets, settlement state, or provider identity. The values are already behaviorally inferable from latency/streaming shape and are useful for buyer diagnosis. |
| v0.2 error envelope semantics | ACCEPTABLE. `request_id` is an opaque log correlation handle; `inference_ran` and `settlement_ran` expose coarse phase state useful for retry/support and are not settlement authority. |

## Closure verification

### C-1 -- Final-close settlement leak

Status: CLOSED.

Evidence:
- Section 8.4.2 now requires all terminal conditions before settlement: no partial-open call, JSON-object arguments, depth and byte caps, `finish_reason:"tool_calls"`, normal transport completion marker, and no provider/relay/auth/truncation failure after incremental-open (`specs/SPEC-018-agentic-tool-calling.md:458-475`).
- The same paragraph says absence of any required condition is final-close failure and explicitly maps missing finish reason, missing normal marker, provider disconnect, timeout, relay error, auth failure, truncation, and missing terminal marker to `FaultBreakerQualifying`, zero provider-positive credits, no receipt, and no sticky-route success write (`specs/SPEC-018-agentic-tool-calling.md:473-475`).
- Section 10d.4 repeats the money-path rule for v0.2 streaming and names both coordinator paths (`specs/SPEC-018-agentic-tool-calling.md:771-773`).
- AC-47 requires coverage for both `forwardWSStreaming` and `forwardStreaming` after incremental-open (`specs/SPEC-018-agentic-tool-calling.md:597`).
- Live billing confirms the named flag is the right carrier: `billing_recorder.go` passes `FaultFlag` into `HotPathInput` (`phase4-coordinator/internal/buyer/billing_recorder.go:176-190`), and `formula.go` returns the row before provider-positive credit calculation when `FaultBreakerQualifying` is present (`phase4-coordinator/internal/billing/formula.go:112-114`).

Conceptual trace:
- `forwardWSStreaming`: the live post-commit disconnect/timeout branches already emit SSE error and return `FaultBreakerQualifying` (`phase4-coordinator/internal/buyer/server.go:2239-2255`). Under v0.2.1, missing relay `complete`, missing finish reason, AEAD/auth failure, timeout, or truncation after incremental-open must take the same fault-settlement posture.
- `forwardStreaming`: live post-commit timeout/disconnect returns `FaultBreakerQualifying` (`phase4-coordinator/internal/buyer/server.go:2476-2487`). The live clean EOF success path (`server.go:2469-2471`) is safe for v0.2 tool-call streaming only after the final-close validator proves `finish_reason:"tool_calls"` plus `[DONE]` and the other terminal conditions. The SPEC now forces that distinction.

Security conclusion: the money-path leak is closed in v0.2.1. A provider cannot earn positive credits merely by emitting a syntactically complete argument object and closing early.

### H-1 -- Section 10c model-hash invariant

Status: CLOSED by explicit amendment.

Evidence:
- The v0.2.1 change log names the section 10c amendment, says registry curation is deferred to v0.3, gives the rationale, and records the precedent that locked invariants require explicit named amendment rather than silent scope cuts (`specs/SPEC-018-agentic-tool-calling.md:9-18`).
- Section 10c keeps the original locked text visible, then immediately marks it `AMENDED v0.2.0/v0.2.1` and names the mitigating v0.2 controls: section 3.9 prompt-echo guard, section 8.4.2 final-close tightening, and AC-46 model-hash observation (`specs/SPEC-018-agentic-tool-calling.md:641-643`).
- AC-46 and section 10d.0.1 make `usage.macprovider_model_hash_observed` observation-only, non-canonicalized, and explicitly not a v0.2 parser-selection, settlement, or SPEC-015 output-binding authority (`specs/SPEC-018-agentic-tool-calling.md:595`, `specs/SPEC-018-agentic-tool-calling.md:695-697`).

Security conclusion: this is an honest Path B amendment. It prepares v0.3 registry work with passive evidence without claiming false v0.2 model-hash enforcement.

### H-2 -- Prompt-echo guard deferral

Status: CLOSED for v0.2 exact-verbatim echo.

Evidence:
- Section 3.9 says parser-side synthesis must fail closed to plain assistant content when a complete native tool-call block in model output appears verbatim in request `messages[].content` or `role:"tool".content` (`specs/SPEC-018-agentic-tool-calling.md:290-294`).
- The byte-match domain is specific enough for the minimal guard: opening sentinel, body bytes, and closing sentinel; case-sensitive; no normalization; no partial/body-only matches (`specs/SPEC-018-agentic-tool-calling.md:294`).
- AC-49 tests the Cline-shaped attack where a tool result contains a complete native Qwen or Llama block and the model echoes that exact sequence (`specs/SPEC-018-agentic-tool-calling.md:601`).

Bypass analysis:
- If an attacker inserts whitespace or other bytes inside the prompt block and the model echoes those same bytes, the emitted complete block still appears verbatim in the request and the guard triggers.
- If inserted bytes make the native sentinel/body/close invalid and the model echoes exactly, the parser should not synthesize a native tool call.
- If the model rewrites, normalizes, repairs, or canonicalizes the attacker-provided block before emitting it, the v0.2 guard does not trigger. That is the documented v0.3 full-guard scope, not a v0.2 closure failure for the exact-echo attack (`specs/SPEC-018-agentic-tool-calling.md:895`).

Security conclusion: the realistic r1 exact-echo Cline attack is closed. Transformed echo remains residual risk, but it is explicitly bounded and deferred.

### H-3 -- Mid-stream SSE error safety

Status: CLOSED.

Evidence:
- Section 8.4.3 now requires a terminal OpenAI-style error event plus `[DONE]` when possible, forbids `finish_reason:"tool_calls"` on the terminal-error event, and says buyer SDKs must surface a failed stream rather than a successful assistant message with dispatchable tool calls (`specs/SPEC-018-agentic-tool-calling.md:477-483`).
- AC-39 accepts SDK exceptions as intended for cap-cross terminal errors (`specs/SPEC-018-agentic-tool-calling.md:581`).
- AC-43 scopes the successful-stream no-parse-error requirement away from terminal-error streams (`specs/SPEC-018-agentic-tool-calling.md:589`).
- AC-48 is the required negative fixture with `openai-python` v2.44.0+ and Cline integration (`specs/SPEC-018-agentic-tool-calling.md:599`).

Security conclusion: the negative AC is sufficient. The release gate is framed around the actual risk: no dispatchable `tool_calls[]` may reach the framework after final-close failure.

## Medium closure checks

### M-1 -- Aggregate request caps

Status: CLOSED.

v0.2.1 adds a 4 MiB coordinator/provider raw request cap, 1 MiB aggregate decoded `role:"tool"` content cap, 2 MiB aggregate assistant-history arguments cap, 256-message max, 128 total assistant tool-call max, pre-render validation, and O(messages + tool_calls) graph validation (`specs/SPEC-018-agentic-tool-calling.md:711-719`). Streaming accumulator budget is also bounded by max concurrent streams and per-buyer limits (`specs/SPEC-018-agentic-tool-calling.md:775`).

### M-2 -- Buyer-fabricated history provenance

Status: CLOSED.

The new provenance language is direct: buyer-supplied assistant-history `tool_calls[]` and `role:"tool"` results are prompt data, not provider provenance; they must not create prior-turn provider provenance, settlement entries, receipt outputs, or "provider emitted" audit claims (`specs/SPEC-018-agentic-tool-calling.md:866`).

### M-3 -- Kill-switch buyer visibility

Status: CLOSED.

v0.2.1 adds `X-MacProvider-Streaming-Mode` on every v0.2 response, constrains it to `incremental`, `buffered_kill_switch`, or `buffered_provider_downgrade`, and says it is diagnostic/observation-only, not negotiation (`specs/SPEC-018-agentic-tool-calling.md:747`, `specs/SPEC-018-agentic-tool-calling.md:593`).

Information-disclosure analysis: the header exposes operational streaming posture, but not secrets, auth state, settlement state, provider identity, or model hash. A buyer can already infer most of the same state from stream chunking and latency. The header improves accountability more than it helps an attacker.

## Fresh findings

### minor m-1 -- `invalid_tools` is used but omitted from the stable v0.2 error-code table

Evidence:
- Section 10d.0 says v0.2-introduced errors use a minimum envelope and enumerates stable v0.2 error codes (`specs/SPEC-018-agentic-tool-calling.md:660-693`).
- Section 10d.1 uses HTTP 400 `invalid_tools` for malformed assistant `tool_calls[]` request shape (`specs/SPEC-018-agentic-tool-calling.md:731`).
- Section 5 also says coordinator malformed assistant-history `tool_calls[]` validation uses `invalid_tools` (`specs/SPEC-018-agentic-tool-calling.md:369`).

Impact:
This is not a bypass, and existing SPEC-001/SPEC-002 request validation can still own the code. But v0.2.1's new stable-envelope table should either include `invalid_tools` or explicitly state that `invalid_tools` is inherited from pre-existing request validation and therefore not duplicated in the v0.2 table.

Suggested fix:
Add `invalid_tools | invalid_request_error | false` to the stable-code table, or add a note that `invalid_tools` is inherited and remains stable outside the v0.2-specific enum list.

### minor m-2 -- AC-46 and section 10d.0.1 differ on always-present vs known-hash-only observation

Evidence:
- AC-46 says every provider response includes `usage.macprovider_model_hash_observed: "<hex>"` and makes a missing field a fail condition (`specs/SPEC-018-agentic-tool-calling.md:595`).
- Section 10d.0.1 says every v0.2 provider response must include the field "when the served model hash is known" (`specs/SPEC-018-agentic-tool-calling.md:697`).

Impact:
This does not create false v0.2 security because the field is explicitly observation-only and cannot drive parser selection, settlement, or SPEC-015 binding. It can, however, produce inconsistent release-gate fixtures for unknown-hash providers.

Suggested fix:
Choose one shape:
- Always include the field, with a separate explicit unknown sentinel such as `null` or `"unknown"` and update AC-46's hex rule accordingly; or
- Require the field only when the served hash is known, and change AC-46's missing-field fail condition to "missing when known."

## Net residual threat model

v0.2.1 is acceptable for the narrow Cline drop-in security scope:

- malformed or incomplete provider streaming output can become buyer-visible only before terminal failure, but it cannot earn provider-positive credits after final-close failure;
- a terminal streaming error must not deliver dispatchable tool calls to Cline or the pinned OpenAI SDK;
- buyer-fabricated replay history remains prompt data, not provider provenance;
- request and streaming memory exposure is bounded by explicit aggregate caps and linear validation;
- the model-hash registry is honestly deferred to v0.3, with passive observation but no false enforcement claim;
- exact-verbatim prompt-echo of native tool-call blocks from Cline tool output is blocked in v0.2.1.

## Self-verification

- Re-read authoritative inputs: v0.2.1 SPEC body, security r1 audit, r1 narrative, r1 absorption prompt, and v0.2.1 draft notes.
- Traced live money-path files named by the prompt: `billing_recorder.go`, `formula.go`, and both WS/direct HTTP streaming failure areas in `server.go`.
- Checked fresh v0.2.1 additions for request caps, error envelope fields, model-hash observation, streaming-mode header, prompt-echo byte-match semantics, and new AC-46 through AC-49.
