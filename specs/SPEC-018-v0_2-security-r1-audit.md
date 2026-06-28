# SPEC-018 v0.2.0 -- SECURITY lane round-1 audit

Date: 2026-06-27
Lane: security
Scope: v0.2 additions only: change-log entry, additive 3.7, 8.4.1/8.4.2/8.4.3, 10d, and AC-25 through AC-45. v0.1.5 locked prose was treated as context only.

## Counts

CRITICAL: 1
HIGH: 3
MEDIUM: 3
minor: 2
Q: 2

## Category sweep

| Lens | Result |
|---|---|
| Money-path end-to-end | Lock-blocking. The draft says only final-close gates settlement, and live billing confirms `FaultBreakerQualifying` zeroes credits, but final-close does not require a protocol-complete stream. A provider can emit a syntactically complete argument object and EOF before `finish_reason:"tool_calls"` / `[DONE]`; as written, that can be interpreted as final-close success. |
| 8.4 split race | Lock-blocking. Buyer-visible commit before settlement is the right split, but missing-finish/disconnect/timeout after commit must be named as final-close failure, not left to implementation interpretation. |
| Mid-stream withdrawal / partial acceptance | HIGH. SSE error + `[DONE]` is not enough unless clients/frameworks are proven not to dispatch partially accumulated calls. AC-43 is positive-only; AC-39 is cap-only. |
| Multi-turn trust boundary | MEDIUM. Accepting buyer-fabricated IDs is compatible with OpenAI replay, but v0.2 needs stronger provenance language so fabricated assistant/tool history cannot be confused with provider-minted prior work in receipts, logs, or UI. |
| DoS | MEDIUM. Caps exist, but v0.2 does not pin aggregate request/render caps, pre-parse validation order, or O(N) cross-message validation. Streaming accumulators are bounded per stream but not budgeted across concurrent streams. |
| Prompt injection residual | HIGH. Deferring the prompt-echo guard leaves a realistic Cline same-family echo path: untrusted repository/tool-result text can contain native tool-call markup that the model echoes verbatim and the parser promotes. |
| 10c forward-compat invariants | HIGH. v0.2 additions contradict the locked v0.2 model-hash fail-closed invariant by deferring the registry and keying the input renderer by self-declared modelID. |
| Operator kill switch | MEDIUM. It is intentionally not a public negotiation surface, but complete invisibility makes buyer-side diagnosis and downgrade accountability impossible. |

## Findings

### CRITICAL C-1 -- Final-close can pass without a protocol-complete terminal stream

Evidence:
- 8.4.2 says final-close verifies only accumulated argument semantics: JSON object, depth <= 32, per-call <= 1 MiB, aggregate <= 2 MiB (`SPEC-018-agentic-tool-calling.md:387-398`).
- 8.4.3 says final-close failure after emission returns SSE error + `[DONE]`, but it does not define missing `finish_reason:"tool_calls"`, missing `[DONE]`, provider EOF, disconnect, timeout, or AEAD failure after incremental-open as final-close failures (`SPEC-018-agentic-tool-calling.md:400-406`).
- 10d.4 repeats that final-close gates settlement but names "final-close failure", malformed deltas, and cap-cross. It does not name "no final-close happened" (`SPEC-018-agentic-tool-calling.md:616-620`).
- AC-42 tests "passes incremental-open but fails final-close", but not the more dangerous case "provider emits a complete JSON-object fragment and closes before the terminal finish/DONE sequence" (`SPEC-018-agentic-tool-calling.md:504`).
- Live code shows the security-critical distinction already exists: post-commit WS disconnect/timeout paths set `FaultBreakerQualifying` (`server.go:2239-2255`), and direct HTTP post-commit disconnect sets `FaultBreakerQualifying` (`server.go:2476-2487`). But direct HTTP clean EOF currently completes OK (`server.go:2469-2471`), so v0.2 final-close must explicitly define what makes EOF "clean" for tool-call streaming.

Attack:
1. Provider passes incremental-open and streams enough `function.arguments` fragments to form a valid JSON object under 1 MiB.
2. Provider closes the stream before `finish_reason:"tool_calls"` and before `data: [DONE]`.
3. A conforming implementer could run the current 8.4.2 checks over the accumulator, see a valid object under caps, and settle provider-positive credits even though the OpenAI stream was malformed/incomplete.

Why this is CRITICAL:
This is a money-path ambiguity that can permit non-zero settlement on bad provider behavior after buyer-visible commit. The existing billing primitive is safe only if the caller passes `FaultBreakerQualifying`; `formula.go:112-114` returns a zero-credit row for that flag, and `billing_recorder.go:176-190` carries it into the hot path. The SPEC must force every missing-terminal path to set that flag.

Suggested fix:
- Extend 8.4.2 final-close with protocol-completeness requirements:
  - every opened `tool_calls[].index` has a terminal accumulated argument string;
  - the stream emitted `finish_reason:"tool_calls"` for the choice;
  - the stream reached the transport's normal completion marker (`data: [DONE]` for HTTP SSE, provider relay `complete` for WS-backed forwarding);
  - no provider disconnect, timeout, relay error, authentication failure, truncation, or missing terminal marker occurred after incremental-open.
- State explicitly: absence of final-close success is final-close failure; it is `FaultBreakerQualifying`, zero provider-positive credits, no receipt, and no sticky-route success write.
- Add AC coverage for both `forwardWSStreaming` and `forwardStreaming`: after incremental-open, provider EOF/disconnect/timeout/missing `[DONE]` must emit terminal SSE error if possible and settle zero credits.

### HIGH H-1 -- v0.2 additions violate the locked model-hash fail-closed invariant

Evidence:
- Locked 10c says v0.2 model-hash -> family registry MUST fail closed for unknown/unregistered `model_hash`; operator-only bypass without buyer consent is non-compliant (`SPEC-018-agentic-tool-calling.md:550`).
- The v0.2 change log says model-hash registry is deferred to v0.3 (`SPEC-018-agentic-tool-calling.md:16`, `:18`).
- New 3.7 keys the input renderer by modelID substring match in v0.2 and says verified `model_hash` moves to v0.3 (`SPEC-018-agentic-tool-calling.md:208-225`).
- 10d.8 again defers Deliverable #2 registry to v0.3 (`SPEC-018-agentic-tool-calling.md:733-739`).

Security impact:
The v0.2 renderer and streaming validator can select a native tool-call family from self-declared modelID even when the verified loaded model hash is unknown or unregistered. That is the exact class of provider-family confusion the locked invariant says v0.2 must close. It is not merely "additive"; it weakens a v0.1.5-locked v0.2 security guarantee.

Suggested fix:
Either include the minimal model-hash family/profile registry in v0.2, or make v0.2 tool-call synthesis/rendering fail closed unless the provider's verified `model_hash` maps to the selected family. If the product decision truly defers registry to v0.3, the draft must not claim SPEC-018 v0.2 compliance against the existing 10c invariant without reopening that locked invariant.

### HIGH H-2 -- Prompt-echo guard deferral leaves a realistic Cline prompt-injection path

Evidence:
- v0.2 change log and 10d.8 defer the prompt-echo guard to v0.3 (`SPEC-018-agentic-tool-calling.md:16`, `:733-739`).
- v0.1 text explicitly says the residual same-family echo case is to be closed by v0.2 via model-hash binding plus prompt-echo guard (`SPEC-018-agentic-tool-calling.md:170`), but v0.2.0 defers both pieces.
- Cline's normal threat model includes untrusted repository files, command output, and issue text entering `messages[]` and `role:"tool"` content. v0.2 now accepts and renders those tool results into native prompt templates (`SPEC-018-agentic-tool-calling.md:560-568`).

Attack:
A malicious repo file or tool output contains a full Qwen/Llama-native tool-call block such as a `write_to_file` or `execute_command` call. The model echoes it verbatim as quoted content or summary. Because the parser is same-family and no echo guard exists, macprovider can synthesize a real `tool_calls[]` response from text that originated in untrusted prompt history rather than model intent.

Why this is HIGH:
The buyer framework still has final policy authority, but Cline's job is to execute model-emitted tool calls. A parser-level echo false positive turns prompt data into an executable tool proposal. That is a realistic partial prompt-injection exploit in the v0.2 release-gate framework.

Suggested fix:
Add at least a minimal v0.2 echo guard: if the complete native sentinel+body+close sequence appears verbatim in request `messages[]` content or `role:"tool"` content, parser-side synthesis MUST fail closed to plain content or malformed-terminal behavior. Add a Cline-shaped AC fixture where a tool result contains a complete native tool-call block and the model echoes it; expected result: no executable `tool_calls[]`.

### HIGH H-3 -- Mid-stream SSE error is not proven safe against partial tool-call dispatch

Evidence:
- 8.4.3 specifies terminal SSE error + `[DONE]` after any emitted tool-call delta fails final-close (`SPEC-018-agentic-tool-calling.md:400-406`).
- AC-39 covers cap-cross bytes not being forwarded and zero credits, but it does not assert that the client/framework refuses to execute the already accumulated partial call (`SPEC-018-agentic-tool-calling.md:498`).
- AC-43 is a positive streaming forward-compat test only; it proves a valid stream accumulates with openai-python, not that malformed terminal error invalidates the partial call (`SPEC-018-agentic-tool-calling.md:506`).
- AC-25/AC-44 exercise happy-path Cline streaming, not hostile final-close failure after buyer-visible commit (`SPEC-018-agentic-tool-calling.md:470`, `:508`).

Attack:
A provider emits a plausible `tool_calls[0]` opening and argument fragments that are syntactically useful to a streaming client, then triggers final-close failure. If Cline or another OpenAI-wire client dispatches as soon as it sees parseable arguments, or treats the final SSE error as a normal `[DONE]` after preserving the partial accumulated call, the buyer can execute a call that the coordinator correctly refused to settle.

Suggested fix:
- Define the terminal error event shape precisely enough that OpenAI clients surface an exception or failed stream state, not a successful assistant message.
- Forbid emitting `finish_reason:"tool_calls"` on any final-close failure.
- Add negative AC coverage using the pinned `openai==2.44.0` reader and Cline: after a final-close error, no assistant message with dispatchable `tool_calls[]` is delivered to the framework's tool-execution boundary.

### MEDIUM M-1 -- Request-side DoS bounds are per-field, not aggregate or validation-order bounded

Evidence:
- v0.2 caps individual `role:"tool"` content at 256 KiB and individual assistant-history arguments at 1 MiB (`SPEC-018-agentic-tool-calling.md:568-570`).
- 10d.6 requires cross-message graph validation before inference but does not require O(N) validation or cap `messages[]` count / total tool-result bytes / total rendered prompt bytes (`SPEC-018-agentic-tool-calling.md:642-650`).
- Existing gateway/coordinator/body limits partially mitigate raw request size (`SPEC-006-buyer-api.md` has a 1 MiB default request-body limit; coordinator has configurable max chat body bytes), but v0.2 does not state how these interact with the new 1 MiB assistant-history cap and 256 KiB per-tool-result cap.

Risk:
A buyer can submit a large but format-valid `messages[]` array with many near-cap tool results or many duplicate/cross-reference IDs. A naive implementation can allocate the whole parsed JSON, then perform repeated scans for each `tool_call_id`, creating memory/CPU amplification before request rejection. If the coordinator accepts a larger body than the gateway, direct coordinator or test deployments are exposed more than the public path.

Suggested fix:
- Add v0.2 request-side aggregate caps: total raw request body, total decoded `role:"tool"` content bytes, total assistant-history `function.arguments` bytes, max messages, and max tool calls per request.
- Require validation to be linear in `messages[] + tool_calls[]`, using maps/sets for IDs, and to fail before prompt rendering.
- State whether caps are checked on raw JSON bytes before parsing, decoded UTF-8 string bytes after JSON unescape, or both. For DoS, enforce a raw-body cap before parse and decoded per-field caps during parse/validation.

### MEDIUM M-2 -- Buyer-fabricated history needs a stronger provenance boundary

Evidence:
- 10d.6 requires accepting buyer-fabricated but internally consistent IDs and says the model may believe the context, with no retroactive money-path implication (`SPEC-018-agentic-tool-calling.md:707-709`).
- AC-34 asserts request acceptance and no retroactive settlement/receipt state for fabricated prior events (`SPEC-018-agentic-tool-calling.md:488`).

Risk:
This is compatible with OpenAI replay, but the draft should explicitly classify assistant-history `tool_calls[]` and `role:"tool"` results as buyer-supplied prompt data, not provider provenance. Without that language, downstream receipts, logs, support tooling, or buyer UI could accidentally display accepted fabricated prior tool calls as if macprovider had emitted or settled them in an earlier turn.

Suggested fix:
Add normative prose: request-side assistant-history tool calls and tool results MUST NOT create provider provenance, settlement entries, receipt output objects, or "provider emitted" audit claims for prior turns. Receipts for the current turn may bind the prompt hash that includes fabricated history, but must not attest that prior history was true or provider-minted.

### MEDIUM M-3 -- Operator streaming kill-switch state is invisible to buyers

Evidence:
- 10d.4 requires an operator kill switch and says configurability is operational only, not exposed as a public wire negotiation surface (`SPEC-018-agentic-tool-calling.md:592-594`).
- AC-45 verifies the kill switch does not change schema and that downgrade is per-provider, but does not require buyer-visible observability (`SPEC-018-agentic-tool-calling.md:510`).

Risk:
A malicious or misconfigured operator can force buffered-to-end behavior while still advertising v0.2 compatibility. This is primarily UX/observability, not settlement, but it matters because streaming is a v0.2 Cline release-gate property. Buyers need a way to distinguish "model slow" from "operator disabled streaming" from "provider downgraded for malformed streams."

Suggested fix:
Keep it out of request negotiation, but expose read-only state in a non-negotiating surface: status endpoint, response header, or documented diagnostic event. At minimum, AC-45 should require an operator/buyer diagnostic artifact showing whether streaming was enabled, kill-switched globally, or downgraded per provider.

### minor m-1 -- Request-side error-code split is internally inconsistent

Evidence:
- 10d.1 says missing `tool_call_id` returns `invalid_request` (`SPEC-018-agentic-tool-calling.md:577-579`).
- 10d.6 says `invalid_tool_call_id` covers ID missing or format invalid (`SPEC-018-agentic-tool-calling.md:698-703`).
- Draft notes already flag this loose interpretation (`SPEC-018-v0_2_0-DRAFT-NOTES.md:23`).

Security relevance:
This is not a bypass by itself, but inconsistent errors make validator tests and client failure handling weaker around the trust boundary.

Suggested fix:
Pick one normative code for missing `tool_call_id`; I recommend `invalid_tool_call_id` for all missing/format-invalid ID failures, with `param` preserving the exact field path.

### minor m-2 -- Streaming-side pass-through AC is implied but not directly named

Evidence:
- 10d.4 requires byte-identical pass-through for split streaming arguments on both coordinator paths (`SPEC-018-agentic-tool-calling.md:620`).
- Draft notes say this was treated as AC-43 rather than a separate AC (`SPEC-018-v0_2_0-DRAFT-NOTES.md:24`).
- AC-43 verifies SDK accumulation against a mocked endpoint, not both coordinator relay paths byte-identically.

Security relevance:
Byte-equivalent pass-through matters because any coordinator rewrite can affect cap accounting, prompt-injection diagnostics, or partial-acceptance behavior. This is test coverage polish, not a new threat.

Suggested fix:
Add explicit AC text or split AC-43/AC-46: WS-backed and direct HTTP coordinator streaming preserve split `function.arguments` bytes exactly while still enforcing incremental-open/final-close.

## Questions

### Q-1 -- What is the intended total memory budget for streaming accumulators?

v0.2 bounds one response to 2 MiB of decoded argument fragments, but N concurrent streams imply O(N * 2 MiB) accumulator memory, plus raw SSE buffers and parser overhead. Is the intended safety argument "provider/gateway concurrency limits cap N", and if so which SPEC pins the maximum active streams per coordinator process? If not, v0.2 should add a process-level or per-buyer streaming-accumulator budget.

### Q-2 -- Is v0.2 allowed to ship while 10a still says #2/#3/#5 are v0.2 targets?

The draft notes explain that 10a was left locked even though 10d narrows v0.2.0 and defers #2/#3/#5. From a security reader's perspective, this creates a real contradiction for model-hash registry and prompt-echo guard. Does the audit loop intend to reopen 10a/10c for a deliberate lock-breaking version-policy edit, or must v0.2.0 absorb the minimum security pieces of #2/#3 to satisfy the locked target?

## Net residual threat model

If C-1 and the HIGH findings are fixed, the remaining v0.2 security posture is acceptable for the narrow Cline drop-in goal: malformed provider output can be buyer-visible only until terminal failure, never provider-credit-positive; buyer-fabricated multi-turn history is prompt data, not provenance; and DoS exposure is bounded by explicit request/response/concurrency budgets. Without those fixes, v0.2 has two lock blockers: a possible settlement leak on incomplete streaming terminal state, and a direct contradiction of the locked v0.2 model-hash family-selection invariant.

## Verdict

FIX REQUIRED.

Lock bar is 0 CRITICAL + 0 HIGH + 0 MEDIUM. Current result is 1 CRITICAL + 3 HIGH + 3 MEDIUM.

## Self-verification

- Reviewed authoritative v0.2 inputs: SPEC draft, design synthesis, draft notes, build prompt.
- Traced live settlement path: `billing_recorder.go:176-190` passes `FaultFlag`; `formula.go:112-114` zeroes credits for `FaultBreakerQualifying`.
- Checked live coordinator streaming failure posture for WS and HTTP paths around post-commit disconnect/timeout.
- Stayed within v0.2 additions for findings; v0.1.5 locked text is cited only when a v0.2 addition contradicts or depends on it.
