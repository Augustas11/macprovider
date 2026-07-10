# BUILD SPEC-019 v0.1.5 IMPL — structured output (`response_format: json_schema`)

Implement SPEC-019 v0.1.5 LOCKED on branch `impl/spec-019-v0-1` in
worktree `/Users/augstar/macprovider-impl-spec-019-v0-1` (base
`608ab22` on `origin/main`).

This is the IMPL companion to SPEC PR [#218](https://github.com/Augustas11/macprovider/pull/218)
(SPEC-019 v0.1.5 LOCKED). After this IMPL diff lands and passes
smoke tests, a 4+ round 6-lane codex+Claude audit loop fires.

## Context (background, not normative)

SPEC-018 v0.2.4 LOCKED + IMPL shipped today (commit `c77313a` on
`origin/main`, PRs [#202](https://github.com/Augustas11/macprovider/pull/202)
+ [#209](https://github.com/Augustas11/macprovider/pull/209)). The
SPEC-019 SPEC PR landed as commit `608ab22` (PR #218).

SPEC-019 reuses much of the SPEC-018 v0.2 IMPL plumbing:

- **Family rendering**: `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift`
  is the model — SPEC-019 needs the same pattern for the structured-
  output schema instruction. Per SPEC-019 §4, composite render is
  ordered: schema-adjusted ChatMessage first → ToolPromptRenderer
  .renderMessages → UserInput.
- **Receipts**: NO SPEC-015 schema change. `phase3-binary/Sources/
  macprovider-cli/PromptCanonicalizer.swift:5-16` already canonicalizes
  `response_format` into the prompt hash. AC-25 regression test just
  proves hash changes when schema bytes change.
- **Money-path posture**: `phase4-coordinator/internal/buyer/
  billing_recorder.go:181-183` + `phase4-coordinator/internal/billing/
  formula.go:112-114`. Same FaultBreakerQualifying pattern as SPEC-018
  tool-call failures.
- **Coordinator allowlist**: `phase4-coordinator/internal/buyer/
  server.go:3608-3615` currently rejects `response_format.type !=
  text|json_object` — needs `json_schema` added.

## Authoritative inputs

- `specs/SPEC-019-structured-output.md` — v0.1.5 LOCKED. 1050 lines,
  34 ACs across 12 categories, ~24 error codes. **Read entire SPEC
  before starting.** Every IMPL claim must trace to an AC.
- `specs/SPEC-018-agentic-tool-calling.md` — v0.2.4 LOCKED, the
  precondition. SPEC-019 §1 amends SPEC-001 row + SPEC-006 normalization
  inline.
- `specs/SPEC-015-receipts.md` — canonical-prompt JCS scope. No change
  needed; verify §1191-1204 lists `response_format`.
- Current code at `608ab22`.

## Scope — what to build (mechanical mapping from SPEC §-numbers)

### A. Provider request parser (SPEC §1, §2 AC-1..AC-9, AC-22, §3)

File: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`

1. Extend `ResponseFormat` enum (lines 239-241):
   ```swift
   public enum ResponseFormat: Sendable {
       case text
       case jsonObject
       case jsonSchema(JSONSchemaSpec)
   }
   ```
   Add `JSONSchemaSpec` struct: `name: String`, `description: String?`,
   `strict: Bool` (default `true`), `schema: JSONValue`.

2. Replace `parseResponseFormat` (lines 371-379):
   - Accept `text | json_object | json_schema` (other types → HTTP 400
     `invalid_request`).
   - `json_schema`: validate `name` + `schema` required; reject
     `strict:false` → HTTP 400 `json_schema_non_strict_unsupported`;
     reject `name` not matching `^[A-Za-z0-9_-]{1,64}$` (anchored,
     case-sensitive on chars, 1-64 bytes) → HTTP 400
     `json_schema_invalid_name`; reject `name` missing → HTTP 400
     `json_schema_missing_name`; reject `schema` missing → HTTP 400
     `json_schema_missing_schema`.

3. New file `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift`:
   - `validateSchemaShape(schema: JSONValue) throws` — enforces §3
     subset grammar at parse time:
     - Allowed: `type` (object/array/string/number/integer/boolean/null),
       `properties`, `required`, `items`, `enum`, `const`,
       `additionalProperties: false` (REQUIRED at object scope under
       `strict:true`), `title`, `description`.
     - Reject (HTTP 400 `json_schema_unsupported_keyword`):
       `oneOf`, `anyOf`, `allOf`, `not`, `$ref`, `$defs`, `pattern`,
       `format`, `minimum`, `maximum`, `multipleOf`, `minItems`,
       `maxItems`, `uniqueItems`, `$schema`. Include offending keyword
       + JSON pointer in `param`.
     - `strict:true` object schemas: enforce `required` ⊇ `properties`
       (every property key must appear in required) recursively → HTTP
       400 `json_schema_strict_requires_all_properties_required`.
     - `strict:true` object schemas: enforce `additionalProperties:false`
       at every object level → HTTP 400
       `json_schema_strict_requires_additional_properties_false`.
     - `const` / `enum` values must conform to `type` → HTTP 400
       `json_schema_invalid_const_or_enum_type`.
     - Property name comparison: raw UTF-8 byte sequence; NO Unicode
       normalization. NFC ≠ NFD.
     - Schema byte size > 16384 → HTTP 413 `json_schema_too_large`.
     - Schema depth > 32 → HTTP 400 `json_schema_too_deep` (depth
       counted per §6 algorithm: root = 1; each nested
       `properties[*]` / `items` / `additionalProperties` subtree +1;
       siblings same level do NOT increment).

### B. Provider streaming + Content-Encoding rejects (§1, §2 AC-20)

File: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`

1. After request body read, before `parseChatRequest`: if
   `request.headers["Content-Encoding"]` normalized (case-insensitive,
   whitespace-stripped) is anything other than empty or `identity` →
   HTTP 415 `request_content_encoding_unsupported`,
   `param:"Content-Encoding"`, `retryable:false`, `inference_ran:false`,
   `settlement_ran:false`. Multi-value (`identity, gzip`) rejected.

2. After `parseChatRequest`: if `response_format == .jsonSchema(_)` +
   `stream:true` → HTTP 400 `streaming_json_schema_unsupported`,
   `param:"stream"`, `retryable:false`, `inference_ran:false`,
   `settlement_ran:false`, message: "v0.1.0 does not stream
   structured `json_schema` output; resend with `stream:false`."

3. Same for `response_format == .jsonObject` + `stream:true` →
   `streaming_json_object_unsupported`.

### C. Family rendering — structured-output schema injection (SPEC §4)

New file: `phase3-binary/Sources/macprovider-cli/StructuredOutputRenderer.swift`

- Family detection: same pattern as `ToolPromptRenderer.detect(modelID:)`
  — Qwen3 / Llama-3.3 keyed on modelID substring.
- `renderSchemaInstruction(schema: JSONValue, family: Family, name:
  String, description: String?) -> String` — produces the family-
  specific system-prompt prefix per §4 fixtures.
- `prependSchemaInstruction(to: [ChatMessage], schema: JSONValue,
  modelID: String, name: String, description: String?) ->
  [ChatMessage]` — prepends/appends the schema instruction to the
  system-position message (or creates a system message if none exists).
- **Stateless renderer**: no caching, no shared state. v0.1.0 explicit
  per SPEC §4 "Stateless renderer rule".

Family-rendering fixtures (per SPEC §4 normative): commit the byte-
exact rendered output for Qwen3 + Llama-3.3 under
`phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC019/`.

### D. ModelRuntime composite render + post-hoc validation (SPEC §4, §5)

File: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`

At each of the three hook sites (`:400`, `:454`, `:540` — preflight,
non-streaming, streaming), per SPEC §4 composite-render rule:

1. If `request.responseFormat` is `.jsonSchema(_)` or `.jsonObject`,
   adjust `ChatMessage` array first: prepend schema instruction
   (or `json_object` instruction for that case) via
   `StructuredOutputRenderer`.
2. Pass adjusted messages to `ToolPromptRenderer.renderMessages(...)`
   (no change; existing behavior; short-circuits when no multi-turn
   tool data).
3. Create `UserInput(chat: rendered, tools: request.tools)` with
   `request.tools` unchanged.

After inference completes (non-streaming only; streaming was rejected
in §B), per SPEC §5:

4. Apply stop-token filter as before (`applyOutputFilters` at
   `:811-828`).
5. If `responseFormat` is `.jsonSchema(_)` or `.jsonObject`, run
   post-hoc validation:
   - Empty content `""` → HTTP 502 `malformed_json_response`,
     `retryable:false` (override per SPEC §5 empty-content), actionable
     message ("Model emitted zero tokens for the requested schema;
     adjust `temperature` / `seed` (for stochastic models), or modify
     the prompt or schema before retrying — automatic same-request
     retry will not succeed.").
   - JSON parse fail → HTTP 502 `malformed_json_response`,
     `retryable:true`, `FaultBreakerQualifying`, `inference_ran:true`,
     `settlement_ran:true`.
   - For `.jsonSchema`: validate parsed JSON against schema. Fail →
     HTTP 502 `json_schema_validation_failed`, include offending
     RFC 6901 JSON pointer in `error.param` (root = `""`), `retryable:
     true`, `FaultBreakerQualifying`.
   - Validator panic / fatal error: catch + emit terminal 502 with
     `error.param: ""` and generic message ("Schema validation
     aborted before completion"); discard partial state.
6. If valid: return assistant content as the JSON string (NOT parsed
   object).

### E. Error envelope updates (SPEC §5 error-codes table)

File: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
(APIError envelope at lines 244+).

Add envelope `retryableByCode` entries (verify exact line; field is
the existing private static dict). New codes per SPEC §5 table —
roughly 17 new codes total:

| Code | retryable | HTTP |
|---|---|---|
| `json_schema_missing_name` | false | 400 |
| `json_schema_missing_schema` | false | 400 |
| `json_schema_invalid_name` | false | 400 |
| `json_schema_non_strict_unsupported` | false | 400 |
| `streaming_json_schema_unsupported` | false | 400 |
| `streaming_json_object_unsupported` | false | 400 |
| `json_schema_unsupported_keyword` | false | 400 |
| `json_schema_strict_requires_additional_properties_false` | false | 400 |
| `json_schema_strict_requires_all_properties_required` | false | 400 |
| `json_schema_invalid_const_or_enum_type` | false | 400 |
| `json_schema_too_deep` | false | 400 |
| `json_schema_too_large` | false | 413 |
| `request_content_encoding_unsupported` | false | 415 |
| `malformed_json_response` | true (false for empty-content) | 502 |
| `json_schema_validation_failed` | true | 502 |
| `response_byte_cap_exceeded` | false | 502 (existing — reuse) |

### F. Coordinator parity (SPEC §7, §2 AC-26..AC-28a)

File: `phase4-coordinator/internal/buyer/server.go`

1. At line 3608-3615 (existing response_format type allowlist): extend
   from `{text, json_object}` to `{text, json_object, json_schema}`.

2. New helper `validateResponseFormatSchema` (or extend existing
   dispatch validator) at coordinator boundary — mirrors §A/§C
   validation: schema byte cap 16384 (HTTP 413), depth cap 32 (HTTP
   400), name regex check, subset grammar reject-list, strict-mode
   parity rules. Identical semantics to provider parser.

3. New `Content-Encoding` rejection at request entry (before any body
   parse): non-`identity` non-empty value → HTTP 415
   `request_content_encoding_unsupported` (same envelope shape as
   provider).

4. Gateway pass-through allowlist amendment (SPEC §7): the coordinator
   already produces structured 502 envelopes for the new
   `malformed_json_response` and `json_schema_validation_failed` codes
   — verify these pass through `dispatchBodyForProvider` and bubble
   to the gateway with envelope intact. Existing
   `nullUsageProviderError` / pass-through helpers in
   `phase5-gateway/internal/router/chat_proxy.go:593-607` need to
   include these two codes in the receipt-eligible allow-list (so they
   are NOT collapsed to generic `api_error/upstream_provider_error`).

### G. Gateway parity (SPEC §7, §2 AC-27)

File: `phase5-gateway/internal/router/chat_proxy.go`

1. Content-Encoding rejection at line ~102-117 (before
   `parseChatRequest`): same as provider/coordinator. HTTP 415
   `request_content_encoding_unsupported`. Multi-value rejected.
   Case-insensitive identity, whitespace-stripped accepted.

2. Extend `passThroughReceiptEligibleProviderError` (currently at
   `chat_proxy.go:593-599`) allow-list to include
   `malformed_json_response` + `json_schema_validation_failed`.

3. Double-settlement prevention (SPEC §7): on these two codes, do NOT
   call `settleBeforeResponse` — coordinator already settled with
   FaultBreakerQualifying. (Verify current `chat_proxy.go` flow; the
   helper choice determines whether re-settling can happen.)

### H. Tests

#### Unit tests (Swift) — `phase3-binary/Tests/macprovider-cliTests/`

- New `JSONSchemaValidatorTests.swift`: covers §3 subset (allow-list +
  reject-list), depth-32 boundary, byte-16384 boundary, NFC/NFD byte
  comparison (AC-9), const/enum type mismatch (AC-6), required ⊇
  properties (AC-6a), additionalProperties:false at each object level.
- New `StructuredOutputRendererTests.swift`: family-keyed render
  fixtures for Qwen3 + Llama-3.3 (byte-equivalent assertions per AC-22a).
- Extend `HTTPServerSwapTests.swift` or new file:
  - AC-1 through AC-8a (request parsing, validation, name regex)
  - AC-18 (empty-content `retryable:false` + actionable message)
  - AC-19 (streaming + json_schema → 400)
  - AC-20 (streaming + json_object → 400)
  - AC-22a/22b (composite render with/without tools)
  - AC-28 (Content-Encoding 415 — `gzip`, `deflate`, `br`,
    `Identity` case-variant accepted, `identity, gzip` rejected,
    whitespace-surround accepted)
- Extend `HTTPServerReceiptTests.swift`: AC-25 (prompt hash changes
  when schema bytes change).

#### Unit tests (Go) — `phase4-coordinator/internal/buyer/`

- Extend `server_test.go` `TestModelClassAliasRewrittenToConcreteModelOnDispatch`
  (line 1839+) to also test `json_schema` preservation through dispatch.
- New test file `structured_output_validation_test.go`:
  - Coordinator allow-list extension (json_schema accepted)
  - Schema byte cap 16384 (HTTP 413)
  - Schema depth cap 32 (HTTP 400)
  - Name regex enforcement (HTTP 400)
  - Subset grammar reject-list (HTTP 400)
  - Strict-mode parity (HTTP 400)
- Extend `chat_proxy.go` test (gateway): Content-Encoding 415,
  `identity` accepted, pass-through allow-list extension.

#### Integration fixtures — `test/integration/spec_019/`

- `openai_python_strict_json_schema/`: AC-30 paired Pydantic fixture
  (`Person { name: str, age: float }`).
- `vercel_ai_sdk_strict_json_schema/`: AC-31 paired Zod fixture
  (`z.object({ name: z.string(), age: z.number() })`). Captured
  outbound HTTP body. `$schema` strip step documented inline.
- `nfc_nfd_adversarial/`: AC-9 NFC schema "café" vs NFD output —
  rejected.

### I. Out-of-scope (defer to v0.2 / v0.3, per SPEC §10)

- **Streaming structured output**: §B above already rejects
  `stream:true` + json_schema/json_object with HTTP 400. Do NOT
  implement token-incremental schema validation.
- **Transparent `Content-Encoding` decompression**: §B/§F/§G above
  reject with HTTP 415. Do NOT implement gzip/deflate/br decompression.
- **Schema warm-cache**: stateless renderer is normative per §4. Do
  NOT add per-connection or per-family cache.
- **Numeric bounds** (`minimum`/`maximum`/`multipleOf`): rejected per
  §3. Do NOT implement.
- **`$ref` / `$defs` schema reuse**: rejected per §3. Do NOT
  implement.
- **Nested-Pydantic fixtures**: deferred to v0.3. Use flat Pydantic
  for AC-30 (matches SPEC §10 note).
- **`strict:false`**: rejected per §1. Do NOT accept.

## Money-path invariant (SPEC §8 — DO NOT REGRESS)

Every post-inference failure path (`malformed_json_response`,
`json_schema_validation_failed`, validator panic) MUST set
`FaultBreakerQualifying` at:
- `phase4-coordinator/internal/buyer/billing_recorder.go:181-183`
  (where billing rows are written)
- `phase4-coordinator/internal/billing/formula.go:112-114` (early
  return before positive-credit calculation)

Pre-inference failure paths (request parse, schema validation, caps)
have `inference_ran:false` + `settlement_ran:false` — no
FaultBreakerQualifying needed (no billing row written).

## Stop conditions

After IMPL diff complete, verify:

1. `cd phase3-binary && swift test` — all tests pass. Report count
   (was 578 before SPEC-018 IMPL; should grow with SPEC-019 unit tests).
2. `cd phase4-coordinator && go vet ./...` — clean.
3. `cd phase4-coordinator && go test -count=1 ./internal/buyer` —
   all pass.
4. `cd phase5-gateway && go build ./...` — clean.
5. `cd phase5-gateway && go test -count=1 ./internal/router` — all
   pass.
6. Receipt regression: prompt hash differs between
   `{"type":"json_schema","json_schema":{"name":"X","schema":{...}}}`
   and same with one byte changed in schema. AC-25.

Report:
- Files created (new) and files modified.
- Test count growth (before / after).
- Any AC you could not implement — explain why (likely "tests
  pending in next round" — defer judiciously).
- Money-path verification: list the FaultBreakerQualifying call sites
  exercised by SPEC-019 tests.

## Out of scope for the implementer

- DO NOT modify SPEC-019 SPEC body. The SPEC is locked.
- DO NOT modify any other SPEC.
- DO NOT change SPEC-018 IMPL behavior beyond the composite-render
  hook integration (which is additive — schema instruction prepended
  before ToolPromptRenderer).
- DO NOT add new HTTP endpoints. Structured output rides on the
  existing `/v1/chat/completions` endpoint.
- DO NOT add IMPL-NOTES markdown files. Commit messages tell the
  story.

## Commit / push protocol

- Commit incrementally as logical units (parser, renderer, validator,
  coordinator, gateway, tests). Each commit must compile.
- DO NOT commit secrets / .env / golden fixture API keys.
- DO NOT push the branch from this codex session — that happens after
  the audit loop converges 0/0/0.
- Sign commits with the standard footer:
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
