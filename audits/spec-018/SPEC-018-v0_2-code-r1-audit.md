# SPEC-018 v0.2.0 — Code Lane r1 Audit

**Date:** 2026-06-27
**Reviewer:** codex code lane
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=4 HIGH / M=2 MEDIUM / m=0 minor / Q=1 question

## Findings

### H-1 — Tool prompt-template profile is not byte-specifiable enough to implement or test
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:208`, `:216-225`; AC-26, AC-27
- Code location: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:194-209`; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:374`, `:428`, `:513`
- What the SPEC claims: §3.7 requires assistant-history `tool_calls[]` and `role:"tool"` results to be rendered into "family-native" chat-template markup before inference, and AC-26/AC-27 require tests to prove that rendering happened.
- What the code does: The live code validates those structured fields, then drops them into `ChatMessage(role, content)` and feeds only `request.messages.map { $0.mlxMessage }` to MLX. The SPEC correctly identifies this loss, but it does not define the byte-level Qwen/Llama prompt-template output that should replace it.
- Drift summary: An implementer cannot write `ToolPromptRenderer.swift` or executable golden tests from §3.7 because the required native markup bytes, ordering around `id`, escaping/canonicalization rules, and tool-result block shapes are unspecified.
- Recommended fix to SPEC body: Add family-specific prompt-rendering fixtures for each §3.1 family: input OpenAI `messages[]` JSON, exact rendered prompt/template text or exact structured `UserInput` shape, and expected rejection when no profile matches. Tie AC-26/AC-27 to those golden fixtures.

### H-2 — Missing `tool_call_id` has two normative error codes
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:578`, `:698-703`; AC-31, AC-32
- Code location: current analogous provider validation is `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:202-205`; current coordinator validation is `phase4-coordinator/internal/buyer/server.go:3105-3108`
- What the SPEC claims: §10d.1's failure table says a `role:"tool"` missing `tool_call_id` returns HTTP 400 code `invalid_request`; §10d.6 says `invalid_tool_call_id` covers "ID missing or format invalid"; AC-32 includes missing `tool_call_id` among failures whose code set includes `invalid_tool_call_id`.
- What the code does: Current pre-v0.2 code uses generic `invalid_request` for missing `tool_call_id`, but v0.2 is defining a new exact wire contract.
- Drift summary: A test author cannot write one byte-exact fixture that satisfies both §10d.1 and §10d.6/AC-32. This is the DRAFT-NOTES flagged mismatch and should be resolved before lock.
- Recommended fix to SPEC body: Canonicalize missing `tool_call_id` to `invalid_tool_call_id` everywhere, or explicitly split "missing field" from "present but malformed" in §10d.6 and AC-32. The four-code enum currently points toward `invalid_tool_call_id`.

### H-3 — Several v0.2 code citations are stale or point at function starts, not the claimed lines
- SPEC location: change log line 18; §3.7 line 225; §8.4.1 line 385; §10d.1 line 586; §10d.4 line 620
- Code location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:353`, `:403`; `phase4-coordinator/internal/buyer/server.go:2103`, `:2149`, `:1241-1245`
- What the SPEC claims: `ModelRuntime.swift:344` and `:395` are "call sites"; `server.go:2119` is `forwardWSStreaming`; `server.go:1234` is where coordinator structs preserve `tool_call_id` and `tool_calls`.
- What the code does: The actual `validateToolCallingV1Scope` calls are at `ModelRuntime.swift:353` and `:403` (the cited lines are function starts). `forwardWSStreaming` starts at `server.go:2103`, and the actual WS byte write is `:2149` (the cited `:2119` sets a response header). The preserved fields are `chatMessage.ToolCallID` / `ToolCalls` at `server.go:1241-1245`, not `:1234`.
- Drift summary: The cited files are right, but multiple v0.2 line citations are shifted by more than five lines or identify a nearby scope instead of the specific behavior. The severity bar marks N>5 citation drift as HIGH.
- Recommended fix to SPEC body: Replace `ModelRuntime.swift:344`/`:395` with `:353`/`:403` for call sites; cite `server.go:2103` for function start and `:2149` for WS streaming bytes; cite `server.go:1241-1245` for `tool_call_id`/`tool_calls` preservation.

### H-4 — Cline and streaming-ops ACs are not yet mechanically reproducible fixtures
- SPEC location: AC-25, AC-44, AC-45 at `specs/SPEC-018-agentic-tool-calling.md:470`, `:508`, `:510`
- Code location: no fixed harness or artifact path is named
- What the SPEC claims: AC-25 passes when a recorded Cline session "completes"; AC-44 measures first argument delta within 1500 ms of "provider recognizing the tool-call opening"; AC-45 validates a kill switch and per-provider downgrade.
- What the code does: No fixture task, recording format, log schema, timestamp source, provider-recognition event, config key, downgrade state key, or artifact path is specified in the AC text.
- Drift summary: These ACs are directionally measurable, but not executable by an independent test author from the SPEC alone. The missing fixture/observable definitions are large enough to block deterministic pass/fail implementation.
- Recommended fix to SPEC body: Define a release-smoke artifact contract: fixed Cline task repo/prompt, required raw request/response or SSE transcript, provider/coordinator log fields, clock source for the 1500 ms measurement, config key for kill switch, downgrade state record, and JSON summary schema consumed by CI/release gating.

### M-1 — The §10d.4 SSE example is JSON-valid but not byte-exact regex-valid
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:600-613`
- Code location: provider-emitted ID source remains `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:59-75`, with v0.2 regex at §10d.6
- What the SPEC claims: The example is the OpenAI wire format for streaming tool calls; §10d.6/AC-30 require provider-emitted IDs to match `^call_[a-f0-9]{32}$`.
- What the code does: The example uses `"id":"call_<32hex>"`, which parses as JSON but fails the provider-emitted ID regex because `<` and `>` are not allowed.
- Drift summary: The pinned `openai==2.44.0` streaming reader accepts the same chunk sequence when the ID is replaced with a real `call_0123456789abcdef0123456789abcdef`, and it accumulates arguments correctly. As written, the example is not a byte-exact valid fixture.
- Recommended fix to SPEC body: Replace the placeholder with a concrete regex-valid ID, e.g. `call_0123456789abcdef0123456789abcdef`, and keep placeholders only in surrounding prose.

### M-2 — Streaming terminal error shape is OpenAI-reader-compatible as an error, but AC wording should distinguish success accumulation from terminal error
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:404`, `:498`, `:618`; AC-39, AC-43
- Code location: current analogous helper is `phase4-coordinator/internal/buyer/server.go:4157-4159`
- What the SPEC claims: Final-close/cap failure emits `data: {"error": ...}` followed by `data: [DONE]`; AC-43 separately requires the pinned streaming reader to accumulate v0.2 streams without parse error.
- What the code does: `openai==2.44.0` accepts normal incremental tool-call chunks and accumulates them by `index`. For an SSE `data: {"error": ...}` frame, it raises `APIError` before yielding a normal chunk, even if `[DONE]` follows.
- Drift summary: This is acceptable for the error path, but the SPEC should prevent readers from interpreting AC-43's "without parse error" as applying to the intentional AC-39 terminal error fixture.
- Recommended fix to SPEC body: Add one sentence to AC-39 or §8.4.3: "OpenAI SDKs may surface the terminal error frame as an exception; AC-43's no-parse-error requirement applies only to successful streams."

### Q-1 — Should final-close validation require `finish_reason:"tool_calls"` before settlement?
- SPEC location: §8.4.2 at `specs/SPEC-018-agentic-tool-calling.md:387-398`; §10d.4 at `:616-620`
- Code location: current coordinator can read finish reasons through `phase4-coordinator/internal/buyer/server.go:4116-4128`
- What the SPEC claims: Final-close validates accumulated JSON object/depth/byte caps before settlement, but does not explicitly require that the stream ended with `finish_reason:"tool_calls"` for tool-call responses.
- What the code does: The current coordinator already has finish-reason extraction helpers, but v0.2 final-close inputs/outputs do not name finish reason as part of the settlement predicate.
- Drift summary: A stream could emit valid-looking fragments and then end with `finish_reason:"stop"` or disconnect after valid JSON; the SPEC is not explicit whether that is settlement-worthy, terminal-error-worthy, or fallback content.
- Recommended fix to SPEC body: Clarify final-close inputs and required terminal state: accumulated tool-call state, completion of every open call, and expected finish reason (`tool_calls`) before provider-positive settlement.

## Verified Citations And Checks

- Verified accurate or behavior-locatable citations: `ModelRuntime.swift:909`, `:924`, `:931`, `:374`, `:428`, `:513`; `ChatCompletionRequest.swift:194`, `:202`, `:175`; `PromptCanonicalizer.swift:5`, `:31`; `server.go:2279`, `:2674`, `:3089`; `billing_recorder.go:176`; `formula.go:112`.
- Verified current `server.go:2674` claim: `isCommitWorthyToolCallDelta` requires `id`, `type:"function"`, non-empty `function.name`, and `function.arguments` that passes `validToolCallArgumentsObject`, so it is incompatible with OpenAI incremental fragments that omit metadata or carry partial JSON-object strings.
- Verified regexes: `^call_[a-f0-9]{32}$` and `^call_[A-Za-z0-9]{16,64}$` are syntactically valid and match/reject the AC-31 character classes as intended.
- Verified byte-cap arithmetic: `1_048_576` is 1 MiB, `2_097_152` is 2 MiB, and AC-36/AC-37 use inclusive exact-cap / cap-plus-one boundaries consistently.
- Verified JSON examples: §10d.6 valid/invalid examples parse as JSON; §10d.4 SSE `data:` payloads parse as JSON after replacing no fields.
- Verified openai-python behavior with temporary `openai==2.44.0`: normal incremental chunks with first metadata delta and subsequent arguments-only deltas accumulate to `{"content":"abc","path":"/tmp/demo.txt"}` with `finish_reason == "tool_calls"`.

## Verdict
FIX REQUIRED

## Verdict Justification

Lock bar is 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 1 finds 4 HIGH and 2 MEDIUM code-lens issues, so v0.2.0 is not mechanically lockable yet.
