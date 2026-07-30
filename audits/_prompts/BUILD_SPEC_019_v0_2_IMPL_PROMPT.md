# SPEC-019 v0.2.4 IMPL — Build prompt

You are implementing **SPEC-019 v0.2.4 LOCKED** — the streaming
structured-output v0.2 amendment to the v0.1.5 LOCKED contract. This is
an incremental IMPL on top of PR #225 (SPEC-019 v0.1.5 IMPL @
`47dc2724`).

## Constraints — DO NOT VIOLATE

- v0.2.4 SPEC text is LOCKED. Do NOT modify
  `specs/SPEC-019-structured-output.md` body. If you find a SPEC bug, stop
  and report it as a finding — do not fix SPEC inline.
- No SPEC-015 schema change.
- No SPEC-018 edits.
- No SPEC-006 edits.
- No new HTTP endpoint.
- No new error codes (reuse existing only — `provider_timeout`,
  `malformed_json_response`, `json_schema_validation_failed`,
  `invalid_json`, `json_schema_unsupported_keyword`,
  `response_byte_cap_exceeded` are the only relevant codes).
- v0.1.5 IMPL (StrictJSONParser, JSONSchemaValidator non-streaming,
  StructuredOutputRenderer, money-path 3-layer for non-streaming) is the
  base. Extend, don't rewrite.

## Worktree base

The SPEC v0.2.4 text lives on branch `spec/019-v0-2-streaming` (PR #233,
not yet merged to main). Create the IMPL worktree based on that branch
so the SPEC is readable during IMPL:

```
git fetch origin
git worktree add ../macprovider-impl-spec-019-v0-2 -b impl/spec-019-v0-2 \
  origin/spec/019-v0-2-streaming
cd ../macprovider-impl-spec-019-v0-2
```

After merging PR #233 to main, rebase `impl/spec-019-v0-2` onto
`origin/main` before opening the IMPL PR (same pattern as v0.1.5 IMPL).

## Spec anchors (read first)

- `specs/SPEC-019-structured-output.md` v0.2.4 LOCKED — read §§1–12. The
  14 v0.2 ACs are `AC-V2-1..14` plus sub-items 3a, 9b, 10a, 10b.
- `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — §10d.4 SSE
  error frame envelope (parent contract for AC-V2-3 reuse).
- `specs/SPEC-006-buyer-api.md` — §17.5 / `:2605` defines
  `provider_timeout` (HTTP 504).
- `specs/SPEC-019-v0_2-r4-audit.md` — lock narrative, summarizes
  closures.

## IMPL surface — 4 deliverables × 3 modules

### Deliverable 1 — Streaming structured output

**Provider (phase3-binary):**

- `Sources/macprovider-cli/HTTPServer.swift`:
  - Remove the streaming-reject 400 for `response_format:
    {"type":"json_schema"|"json_object"}` + `stream:true`. v0.2 accepts.
  - The v0.1 code path returned `streaming_json_schema_unsupported` /
    `streaming_json_object_unsupported` at HTTPServer.swift:455-474
    (per v0.1.5 IMPL). Delete the streaming-reject branch entirely.
  - On `stream:true` + structured output: enter streaming path with
    end-of-stream validation hook.

- `Sources/macprovider-cli/ModelRuntime.swift`:
  - Composite render path (schema-adjusted `ChatMessage` →
    `ToolPromptRenderer.renderMessages` → `UserInput`) MUST run for
    `stream:true` exactly as for `stream:false`. v0.1.5 IMPL has 3 hook
    sites for the composite render — verify `stream:true` reaches all
    three.
  - End-of-stream validation: after the final SSE chunk and before
    emitting `data: [DONE]`, validate the concatenated `content`
    buffer against the schema. On validation failure, emit a terminal
    SSE error frame (SPEC-018 §10d.4 envelope shape, see Deliverable 2)
    and skip `[DONE]`.
  - Buffer the post-stop-token-filter buyer-visible delta concatenation
    (AC-V2-7 byte-equivalence requirement).
  - Cap the validation buffer at `2_097_152` bytes (AC-V2-9b). On cap
    exceeded: provider closes upstream generation, emits terminal SSE
    error frame using existing `response_byte_cap_exceeded` code.
  - Provider-side idle timeout watcher: emit terminal SSE
    `provider_timeout` if no buyer-visible content delta is emitted for
    N seconds (N deferred to v0.2.x — pick a placeholder default of
    `60s` and document via constant; SPEC text defers the exact
    normative N).
  - On terminal validation failure, settle `FaultBreakerQualifying`
    with zero provider-positive credits.

- `Sources/MacProviderCore/StrictJSONParser.swift`: already exists from
  v0.1.5. Verify panic-safe boundary still holds for streaming buffer
  parse.

- Add Swift test files:
  - `phase3-binary/Tests/MacProviderCoreTests/StreamingStructuredOutputTests.swift`
  - `phase3-binary/Tests/macprovider-cliTests/StreamingValidationFailureTests.swift`
  - `phase3-binary/Tests/macprovider-cliTests/StreamingIdleTimeoutTests.swift`
  - `phase3-binary/Tests/macprovider-cliTests/StreamingByteCapTests.swift`

**Coordinator (phase4-coordinator):**

- `internal/buyer/server.go`:
  - Remove the streaming-reject branch at `:3676-3687` for the two
    v0.1 streaming-reject codes (v0.2 accepts streaming).
  - Mirror validator (subset, depth, byte cap, name regex, strict-mode
    parity) MUST run on `stream:true` requests exactly as on
    `stream:false`.
  - WS-tunneled streaming: terminal validation failures MUST close the
    end frame with `inference_response_end.status ∈
    {malformed_json_response, json_schema_validation_failed}`,
    retryable preserved, receipt omitted. v0.1.5 already widened the
    WS frame allow-list — verify streaming path reaches it.
  - Streaming SSE writer for terminal validation failures MUST populate
    `request_id` and `settlement_ran:true`. v0.1.5 cited
    `phase4-coordinator/internal/buyer/server.go:5150-5170` as the
    writer site; extend to also cover the streaming path.
  - `provider_timeout` for streaming idle: the streaming SSE
    `writeSSEError(... "provider_timeout")` site is at `server.go:2386`.
    Verify it fires on provider idle timeout for SPEC-019 streaming
    structured-output flows.
  - For streaming structured-output requests, classify HTTP non-200
    paths and WS-tunneled non-streaming-equivalent paths as
    `FaultBreakerQualifying` (3-layer money-path rule already
    established in v0.1.5; extend to streaming).

- Add Go test file:
  - `phase4-coordinator/internal/buyer/streaming_structured_output_test.go`
    covering: mirror validator on stream:true, WS end-frame status
    propagation, settlement_ran:true on terminal SSE error.

**Gateway (phase5-gateway):**

- `internal/router/chat_proxy.go`:
  - **Wall-clock authority (AC-V2-9)**: gateway owns the 300s
    wall-clock watcher. The existing
    `upCtx, cancelUpstream := context.WithTimeout(r.Context(),
    s.cfg.CoordinatorTimeout())` at `chat_proxy.go:225` is the timeout
    source. On wall-clock breach for SPEC-019 streaming structured-
    output: emit terminal SSE error frame with `error.code =
    provider_timeout`, settle `FaultBreakerQualifying`, skip
    ok/positive settlement. Do NOT route through the
    `provider_disconnected` / `stream_truncated` path at
    `chat_proxy.go:592-614` — that path is for non-SPEC-019 timeouts.
  - **SSE pass-through (AC-V2-3a)**: gateway MUST recognize terminal
    SSE error frames carrying `error.code ∈
    {malformed_json_response, json_schema_validation_failed}` as final
    structured-output failures. Forward verbatim through `[DONE]`. Do
    NOT remap to `stream_malformed` (the `!hasChoices` remap at
    `chat_proxy.go:533` MUST be bypassed for SPEC-019 codes). Do NOT
    emit `usage_events` with `outcome:"ok"` (positive-settle path at
    `chat_proxy.go:625-629` MUST be skipped).
  - The full `forwardLine` closure body is `chat_proxy.go:482-557` —
    the SPEC-019 carve-out lives inside that closure.

- Add Go test file:
  - `phase5-gateway/internal/router/streaming_structured_output_test.go`
    covering: terminal SSE error frame pass-through (no remap, no
    `outcome:"ok"`), gateway wall-clock breach emits `provider_timeout`
    + `FaultBreakerQualifying`, double-settle prevention.

### Deliverable 2 — Terminal streaming validation failures (SPEC-018 §10d.4 reuse)

Already covered above via the streaming hook. Key points:

- Terminal SSE error frame matches SPEC-018 v0.2.4 §10d.4 minimum
  envelope: `error.type`, `error.code`, `error.message`, optional
  `error.param`, plus the SPEC-019-specific `error.settlement_ran`
  field.
- Settlement is `FaultBreakerQualifying` for both
  `malformed_json_response` and `json_schema_validation_failed`.
- For `provider_timeout` (idle or wall-clock):
  `FaultBreakerQualifying` is the v0.2 contract per §8 amendment.
- For `response_byte_cap_exceeded` (streaming cap breach): retryable
  inherits v0.1.5 LOCKED IMPL semantics (`false` per
  `phase4-coordinator/internal/buyer/server.go:56` —
  `spec018RetryableByCode["response_byte_cap_exceeded"] = false`).

### Deliverable 3 — §3 schema-subset widening

**Provider:** `Sources/MacProviderCore/JSONSchemaValidator.swift`:

- Lift the pre-inference reject for `minimum`, `maximum`, `multipleOf`
  on schema nodes whose `type` is `number` or `integer`. Reject the
  same keywords on any other `type` (`string`, `boolean`, `null`,
  `array`, `object`) with `json_schema_unsupported_keyword` and
  `error.param` pointing at the offending node path.
- Pre-inference value-validity:
  - `multipleOf` MUST be a JSON number `> 0`. Reject `0`, negative,
    non-number with `json_schema_unsupported_keyword`.
  - `minimum`/`maximum` MUST be JSON numbers. Reject string, null,
    bool, array, object operands.
  - When both `minimum` and `maximum` present, require `minimum ≤
    maximum`. Reject inverted bounds.
- Accept top-level `$schema` in `response_format.json_schema.schema`
  with any JSON value. Ignored for validation-time meta-schema
  selection, but `$schema` bytes count toward the 16 KiB cap and are
  JCS-canonicalized into receipt `prompt_hash`.
- Runtime value enforcement: after end-of-stream parse, enforce
  `multipleOf` / `minimum` / `maximum` on integer/number instances. On
  failure: `json_schema_validation_failed` terminal SSE error frame.
- NaN/Infinity literals: already excluded by JSON parser (these are
  not valid JSON tokens per RFC 8259 §6). The buyer-visible envelope
  is HTTP 400 `invalid_json` from the parse layer — verify the parse
  layer at `ChatCompletionRequest.swift:22-27` actually rejects.

**Coordinator:** `internal/buyer/server.go` mirror validator — lift the
same rejects from the v0.1.5 reject-list and apply the same value-
validity and type-conditional gating. Coordinator parse layer at
`server.go:3467-3471` already rejects NaN/Infinity via `json.Unmarshal`
failure → `invalid_json`; verify.

### Deliverable 4 — SDK fixture expansion

**Cline live fixture (AC-V2-5):**

- Path: `test/integration/spec_019/cline_streaming_structured_output/`
- Pin the exact Cline upstream commit AND the `ai` SDK package version
  Cline pins on that commit. Document in fixture README.
- Invoke the streaming primitive Cline uses on its active call path
  (verify whether `streamObject` or `streamText` + output per Cline's
  current source).
- Capture the outbound POST body bytes.
- Fixture assertions:
  - Body contains `"stream": true`
  - Body contains exact `response_format.json_schema` fields
    (`name`, `schema`, `strict:true`)
  - Body matches `@ai-sdk/openai-compatible@2.0.38`
    `supportsStructuredOutputs:true` emission
  - Parsed assistant output validates against the schema
  - Receipt `prompt_hash` deterministic across replay

**Vercel z.number().int() captured-body fixture (AC-V2-12):**

- Path: `test/integration/spec_019/vercel_zod_int_streaming/`
- Pin Vercel AI SDK + zod + `@ai-sdk/openai-compatible` versions in
  package.json.
- Capture and commit the actual outbound request body. Expected shape:
  `age` field with `{"type":"integer", "minimum":-9007199254740991,
  "maximum":9007199254740991}` plus top-level `$schema`. If actual
  capture differs, commit what the SDK emits and update fixture
  assertions to match reality.
- NO SDK-side rewrite/normalization step permitted.

**openai-python streaming fixture (AC-V2-6):**

- Path: `test/integration/spec_019/openai_python_streaming/`
- Mirror v0.1 AC-15 (non-streaming) but with `stream=True`.
- Accumulate `chunk.choices[0].delta.content` into final content
  string, parse, validate.

**Partial-content negative streaming fixture set (AC-V2-13):**

- Path: `test/integration/spec_019/partial_content_negative/`
- MUST include BOTH:
  - `cline_partial_then_error/` — Cline emits partial content then
    terminal `malformed_json_response` or
    `json_schema_validation_failed` SSE error frame.
  - `vercel_partial_then_error/` — Vercel AI SDK same shape.
- Both fixtures assert: final object parsing fails (no
  partial-success path). Document partial deltas pre-validation are
  provisional.

**Composite-render streaming invariant fixture (AC-V2-14):**

- For `stream:true + tools + json_schema`: byte-equivalent
  system-position composition vs the non-streaming equivalent.

## Smoke obligations before submitting for audit

After the implementation lands, run:

```
cd phase3-binary && swift build && swift test
cd ../phase4-coordinator && go test ./internal/buyer/...
cd ../phase5-gateway && go test ./internal/router/...
```

Each MUST be green. Document the result counts.

Compare against v0.1.5 IMPL baseline (PR #225): provider was 618 tests /
7 skipped / 0 failures. v0.2 IMPL should be **strictly** ≥ 618 tests
with no new failures.

## Money-path posture — DO NOT REGRESS

| Path | Required behavior |
|---|---|
| HTTP streaming validation failure | terminal SSE error frame + `FaultBreakerQualifying` |
| WS streaming validation failure | inference_response_end.status set + receipt omitted + FaultBreakerQualifying |
| Gateway SSE pass-through | terminal frames forwarded verbatim; no `stream_malformed` remap; no `outcome:"ok"` settle |
| Provider idle timeout | terminal `provider_timeout` + FaultBreakerQualifying |
| Gateway wall-clock 300s breach | terminal `provider_timeout` + FaultBreakerQualifying; NOT `provider_disconnected`/`stream_truncated` |
| Cap exceeded (2 MiB content) | terminal `response_byte_cap_exceeded` + FaultBreakerQualifying |
| NaN/Infinity in numeric-bound positions | HTTP 400 `invalid_json` from parse layer (NOT schema-keyword reject) |

## Output requirements

- Commit the IMPL diff in logical commits (separate provider /
  coordinator / gateway commits is fine, or one bundled commit).
- DO NOT open the PR yet — leave for audit-loop.
- Reasoning effort: **high** (cross-module changes; money-path
  surface).

## Next steps (orchestrator, NOT codex)

After this IMPL diff lands:
1. Smoke check the 3 module test suites.
2. r1..rN IMPL audit loop with the same 6-lane convention used for the
   SPEC (4 codex + 2 Claude blind-spot).
3. Lock at 0/0/0 across all 6 lanes.
4. Rebase onto `origin/main` after SPEC PR #233 merges.
5. Open IMPL PR.
6. Pearl smoke after merge.
