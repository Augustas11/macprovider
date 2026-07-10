# BUILD SPEC-019 v0.1 — Structured Output (`response_format: json_schema`)

Draft `specs/SPEC-019-structured-output.md` v0.1.0 as a **narrow product slice**
that lets buyers send OpenAI-style `response_format: {"type":"json_schema", ...}`
to macprovider and get back a JSON message that conforms to their schema (or a
structured error). Same shape and discipline as SPEC-018 v0.2.4.

This is the BUILD-direction prompt — write the **first draft of the SPEC body**.
A 4-round 6-lane codex audit loop will follow.

## Context (background, not normative)

SPEC-018 v0.2.4 LOCKED + IMPL shipped today (commit `c77313a35f` on
`origin/main`, PR #209). The Cline drop-in product slice is live. The
recommendation from a sibling session: "structured-output slice is the same gap
pattern pre-cf2f135 had for tool calling — provider accepts the wire field but
returns 400 / no-ops it. Now with SPEC-018 plumbing proven, even faster lift."

Already-known facts about the current codebase (verified pre-prompt):

- **Provider**: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:239-241`
  has `ResponseFormat` enum with only `.text` and `.jsonObject`. Line 376
  returns HTTP 400 `invalid_request` for `json_schema`. `ResponseFormat` is
  parsed but **never consulted during inference** — even `json_object` is a
  silent no-op (model generates freely).
- **MLX-Swift**: `mlx-swift-examples@2.29.1` (per
  `phase3-binary/Package.swift`) exposes no constrained-decoding / grammar /
  logits-processor API. **Tool calling was solved by post-hoc text parsing
  (`ToolCallParser.swift`), not constrained generation.** This SPEC MUST use
  the same approach.
- **Receipts**: `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:16`
  already JCS-canonicalizes `response_format` into the receipt hash. **Receipt
  binding for `json_schema` works for free** the moment the provider accepts
  the field — no schema change to SPEC-015 needed.
- **Coordinator/gateway**: pure pass-through today. `phase4-coordinator/internal/buyer/server.go:3608-3615`
  validates `response_format.type ∈ {text, json_object}` syntactically and
  preserves the field through dispatch. Gateway (`phase5-gateway/internal/router/chat_proxy.go`)
  forwards raw body unchanged. Both layers will need their type-allowlist
  extended to `json_schema`.
- **Family rendering**: SPEC-018 v0.2 introduced `ToolPromptRenderer.swift`
  (Qwen3 / Llama-3.3). Same family-key mechanism (modelID-match per SPEC-018
  §3.2) MUST be used for system-prompt injection of the JSON-schema
  instruction.
- **Money-path**: SPEC-018 v0.2.4 §10d.4 + `billing_recorder.go:181` +
  `formula.go:112` set `FaultBreakerQualifying` (zero credits) on
  parse/cap failures. Same posture MUST apply to schema-validation failures.

## Resolved design decisions (DO NOT re-litigate)

These are upstream calls. Write the SPEC consistent with them; don't argue.

1. **Bundle `json_object` enforcement fix.** v0.1.0 fixes the existing silent
   no-op so `response_format: {"type":"json_object"}` actually constrains
   output to valid top-level JSON (object or array). Same enforcement
   mechanism as `json_schema` minus the schema validation step.

2. **Schema subset = OpenAI strict-mode subset.** Define a normative subset:
   `type` (object / array / string / number / integer / boolean / null), `properties`,
   `required`, `items`, `enum`, `const`, `additionalProperties: false` (REQUIRED at
   object scope when `strict: true`), nested objects/arrays. Reject (HTTP 400)
   schemas using `oneOf` / `anyOf` / `allOf` / `not` / `$ref` / `$defs` /
   `pattern` / `format` / numeric constraints (`minimum` / `maximum` / `multipleOf`)
   / array length constraints (`minItems` / `maxItems` / `uniqueItems`) in
   v0.1.0. Promote a wider subset to v0.2 once Cline / Vercel AI SDK
   compatibility is verified against the subset.

3. **Streaming = DEFERRED to v0.2.** v0.1.0 is non-streaming only. Buffered
   inference, validate at end, emit single message. Streaming with
   partial-JSON-prefix validation is a separate slice (analog: SPEC-018
   shipped non-streaming tool calling in v0.1, incremental streaming in v0.2).

4. **Retry policy = FAIL-FAST.** On JSON parse failure or schema validation
   failure, return a structured error envelope. Buyer retries at their layer.
   No internal retry. This matches the SPEC-018 v0.1.5
   `malformed_tool_call_final_json` posture (retryable=true on the wire, no
   server-side retry).

5. **SPEC home = NEW SPEC-019** (not SPEC-018 v0.3). Structured output is a
   distinct buyer surface from agentic tool calling; clean separation. Cite
   SPEC-018 v0.2.4 §10b as the precondition release-gate ("promoted when the
   wire contract for §10a #4 streaming-incremental stabilizes").

6. **Schema-size cap = 16 KiB UTF-8.** Hard reject (HTTP 413
   `json_schema_too_large`) at parser + coordinator. Identical at both layers.

7. **Response-size cap.** Reuse the v0.2.4 `2_097_152` bytes per response cap
   from SPEC-018 §9 — structured output is just JSON in the assistant content,
   so the same response envelope cap applies. NO new constant.

8. **Money-path = FaultBreakerQualifying on validation failure.** Schema
   validation failure after inference completes is `FaultBreakerQualifying`
   with zero provider-positive credits, same posture as SPEC-018
   `malformed_tool_call_final_json`. Cite `billing_recorder.go:181` +
   `formula.go:112`.

9. **Receipts = no schema change.** `PromptCanonicalizer.swift:16` already
   JCS-canonicalizes `response_format`. v0.1.0 only requires regression tests
   proving `prompt_hash` changes when `json_schema` changes (analog of
   SPEC-018 v0.2's `tool_call_id` / `tool_calls` receipt regression
   requirement).

10. **Out-of-scope for v0.1.0**: streaming structured output, schema reuse
    via `$ref`, `oneOf`/`anyOf` polymorphism, partial validation,
    auto-retry, schema warm-cache between requests, multi-language
    error messages.

## SPEC required structure

Mirror SPEC-018 v0.2.4's outline. The drafter MUST include at minimum:

### §1 — Buyer-visible contract
- OpenAI `response_format` shape — three values: `text` (default), `json_object`,
  `json_schema`.
- For `json_schema`: required `name`, optional `description`, optional `strict`
  (default `true` in v0.1.0 — non-strict deferred), required `schema`.
- Buyer-side validation obligations (analog of SPEC-018 §1).
- v0.1.0 is non-streaming only — `response_format: {"type":"json_schema"}`
  with `stream: true` MUST return HTTP 400
  `streaming_json_schema_unsupported_in_v0_1`.

### §2 — Acceptance criteria (numbered AC list)
- AC-1: `response_format.type == "json_schema"` is accepted by request parser.
- AC-2: Missing `json_schema.name` → HTTP 400 `json_schema_missing_name`.
- AC-3: Missing `json_schema.schema` → HTTP 400 `json_schema_missing_schema`.
- AC-4: Schema using disallowed keyword (`oneOf` / `anyOf` / `$ref` / etc.)
  → HTTP 400 `json_schema_unsupported_keyword`.
- AC-5: Schema byte size > 16 KiB → HTTP 413 `json_schema_too_large`.
- AC-6: `strict: true` + object schema without `additionalProperties: false`
  → HTTP 400 `json_schema_strict_requires_additional_properties_false`.
- AC-7: `response_format: {"type":"json_object"}` constrains output to valid
  JSON (object or array). Currently a silent no-op.
- AC-8: `response_format: {"type":"json_schema", ...}` — assistant content is
  a JSON-parseable string conforming to the schema.
- AC-9: Inference output that is not JSON-parseable when `json_schema`/`json_object`
  is requested → terminal structured error `malformed_json_response`,
  `FaultBreakerQualifying`, zero provider-positive credits.
- AC-10: Inference output that parses as JSON but fails schema validation
  → terminal structured error `json_schema_validation_failed`, includes
  the offending JSON pointer (e.g. `/path/to/field`), `FaultBreakerQualifying`.
- AC-11: `response_format: {"type":"json_schema", ...}` + `stream: true` →
  HTTP 400 (per §1).
- AC-12: Provider receipt `prompt_hash` changes when any byte of
  `response_format.json_schema.schema` changes.
- AC-13: Family-prompt rendering — Qwen3 and Llama-3.3 fixtures show the
  schema is injected into the chat-template system position byte-equivalently
  per family.
- AC-14: Tools + json_schema interaction — if BOTH `tools` and
  `response_format: json_schema` are sent, behavior is: tool calls take
  precedence (model decides whether to call a tool or emit structured
  content); if a tool is called, the schema does NOT apply to the
  tool-call arguments (those use the tool's own JSON Schema). Define
  explicitly so the audit can catch ambiguity.
- AC-15: Forward-compat — `openai==2.44.0` regression: sending
  `response_format=json_schema(...)` against macprovider produces the same
  parsed `pydantic` model as against OpenAI's `gpt-4o-2024-08-06`.
- AC-16: Vercel AI SDK regression — `@ai-sdk/openai-compatible@2.0.38` with
  Zod schema → call → parsed object matches against canonical fixture.
- AC-17–AC-N: cover cap edges, error-envelope shape, money-path zero-credit
  proof, coordinator validation parity.

### §3 — Schema-subset grammar (normative)
Allowed keywords table + REJECT-list. Cite OpenAI's strict-mode docs as
reference, not as normative source.

### §4 — Family rendering
How the schema is rendered into the chat-template system prompt per family.
Qwen3 and Llama-3.3 fixtures (analog of SPEC-018 §3.8). Reuse
`ToolPromptRenderer.swift` patterns.

### §5 — Validator behavior
Post-inference: JSON parse → schema validate. On failure, what error code,
what envelope, what billing posture. JSON pointer extraction for the
validation-failure error message.

### §6 — Caps (normative constants)
- `json_schema_max_bytes` = `16_384`
- response cap inherited from SPEC-018 §9 `2_097_152` — explicit cite, not
  redefinition.

### §7 — Coordinator / gateway behavior
Both layers extend allowlist to `json_schema`. Coordinator validates the
schema-size cap at the coordinator boundary (defense in depth). Pass-through
otherwise.

### §8 — Money path
FaultBreakerQualifying for both `malformed_json_response` and
`json_schema_validation_failed`. Citations: `billing_recorder.go:181`,
`formula.go:112`.

### §9 — Forward-compat invariants (analog of SPEC-018 §10c)
- Schema-subset MAY widen across v0.1.x; MUST NOT narrow.
- Error codes MAY add new ones; MUST NOT rename or repurpose.
- Caps MAY raise; MUST NOT lower.
- `json_schema` request shape: future versions MAY add new optional fields
  inside `json_schema.*` but MUST NOT require new fields without a major
  version bump.
- `strict: true` semantics in v0.1.0 is the conformant baseline; `strict: false`
  semantics, if ever added, MUST be additive.

### §10 — Deferred to v0.2 / v0.3
- Streaming structured output (partial-JSON-prefix validation per chunk).
- `oneOf` / `anyOf` polymorphism.
- `$ref` / `$defs` for schema reuse.
- Non-strict mode (`strict: false`) — observability without enforcement.
- Auto-retry with tightened prompt on validation failure.
- Schema warm-cache between requests on same connection (perf).

### §11 — Open questions (audit hooks)
Explicitly list what the audit lanes should adversarially probe — e.g. JSON
canonicalization edge cases (NaN, ±Infinity, lone surrogates in strings,
duplicate keys, deeply nested arrays); prompt-injection risk if schema
description text is attacker-controlled; model-quality regression (does the
prompt-injection of the schema hurt quality on non-structured requests
elsewhere — measure?).

### §12 — Document metadata
- Status: DRAFT (will become LOCKED after audit loop converges 0/0/0)
- Version: 0.1.0
- Precondition: SPEC-018 v0.2.4 LOCKED (cite PR #202 + IMPL PR #209).
- Successor: TBD (v0.1.1 or v0.2.0 depending on audit-round absorption shape)

## Citations to wire in

Every claim about file:line in the SPEC body MUST cite the actual current
file:line on `origin/main` at the time of drafting (commit `98336d9` or later).
The drafter MUST grep-verify before citing.

Key paths to cite:

- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:239-241`
  (existing enum)
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:376`
  (current 400)
- `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:16`
  (existing canon)
- `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift` (family
  renderer to mimic)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (where the
  rendering hooks live — verify with grep)
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift` (parser
  analog)
- `phase4-coordinator/internal/buyer/server.go:3608-3615` (existing
  type-allowlist)
- `phase4-coordinator/internal/buyer/billing_recorder.go:181` (money-path)
- `phase4-coordinator/internal/billing/formula.go:112` (money-path)
- `phase5-gateway/internal/router/chat_proxy.go` (pass-through)
- `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED (precondition)
- `specs/SPEC-015-receipts.md` (no schema change required, but cite)
- `specs/SPEC-006-buyer-api.md` line 1044 (response_format is buyer-API
  allow-listed)

## Out-of-scope for the drafter

- DO NOT modify any file other than `specs/SPEC-019-structured-output.md`.
- DO NOT write IMPL code. This is the SPEC draft only; IMPL is a separate
  PR after the SPEC locks.
- DO NOT touch SPEC-018. SPEC-019 cites SPEC-018 as precondition; it does
  not amend it.
- DO NOT change any existing receipts schema or canonicalizer code paths.
- DO NOT add new HTTP endpoints; structured output rides on the existing
  `/v1/chat/completions` endpoint.

## Style requirements

- Match SPEC-018 v0.2.4's tone: terse, numbered AC list, file:line citations,
  explicit forward-compat invariants, money-path posture spelled out, no
  marketing language.
- No emoji.
- No "we" / "you" — use "the provider", "the coordinator", "the buyer".
- Numbered ACs starting at AC-1.
- Bare HTTP codes + error code identifiers in `code_block_form`.
- All caps acronyms: HTTP, JSON, SSE, SDK, UTF-8, JCS.

## Stop condition

Write `specs/SPEC-019-structured-output.md` v0.1.0 covering §1 through §12 as
outlined. Verify every cited file:line by reading the actual file. Report:

1. Path of the written SPEC file.
2. Wordcount or line count.
3. List of citations actually verified vs cited-without-verification (should
   be zero in the latter bucket).
4. Any resolved-decision-list ambiguities you noticed and resolved
   in-spec (don't ask — make the call, document it in the SPEC body).

After your draft lands, the audit loop fires: 4 codex lanes (architect, code,
security, product-design) + Claude critic + Claude narrative. Bar: 0
CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes before SPEC PR opens.
