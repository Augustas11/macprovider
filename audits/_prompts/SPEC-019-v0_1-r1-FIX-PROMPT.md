# SPEC-019 v0.1.1 — r1 absorption (TIGHT)

Edit `specs/SPEC-019-structured-output.md` to absorb r1 audit findings.
Target version: **v0.1.1**. Add a v0.1.1 change-log entry citing this
audit file: `specs/SPEC-019-v0_1-r1-audit.md`.

**No commits, no docs/runbook updates, no IMPL code. SPEC body edits only.**

Edit at low reasoning effort. The fixes below are specified with exact
file:line targets and exact wording where the call has been pre-decided.

## A. Cross-spec amendments (closes architect C-1, C-2)

### A.1 — SPEC-001 supersession note (architect C-1)

Add to §1 (after the "Quick orientation" preamble, before AC list):

> **Cross-spec amendment**: SPEC-019 v0.1.0 supersedes SPEC-001
> `response_format.type` allowed-values row. SPEC-001 currently allows
> only `text` and `json_object` and treats `json_object` as a hint;
> SPEC-019 adds `json_schema` and replaces the hint behavior with
> mandatory post-hoc enforcement. No other SPEC-001 request fields change.
> Cite `specs/SPEC-001-phase3-binary.md:934` (or current line — grep
> verify) as the superseded row.

### A.2 — SPEC-006 detail-code pass-through (architect C-2)

**Decision: detail-on-wire** (matches SPEC-018 tool-call posture).

Add to §7 (Coordinator / gateway behavior):

> **Gateway pass-through allow-list amendment**: SPEC-019 v0.1.0 amends
> SPEC-006's provider-5xx normalization (cite `specs/SPEC-006-buyer-api.md:2556`
> or current line — grep verify) to add `malformed_json_response` and
> `json_schema_validation_failed` to the gateway-pass-through detail-code
> allow-list. Other 502 codes from the provider continue to normalize to
> `api_error` / `upstream_provider_error` per SPEC-006.

Cite current gateway code paths that implement the existing
normalization: `phase5-gateway/internal/router/chat_proxy.go:317-327`
and `:601-607` (grep verify).

## B. Schema-shape parity (closes critic C-1 + critic M findings 8, 9)

### B.1 — Strict-mode `required` parity (critic C-1)

Add to §3 grammar rules:

> Under `strict:true`, an object schema's `required` array MUST contain
> **every** key in `properties`. The reverse direction (every entry in
> `required` MUST name a key in `properties`) is already required.
> Violation returns HTTP 400 `json_schema_strict_requires_all_properties_required`,
> `param` = JSON pointer of the offending object node.

Add AC immediately after AC-6:

> AC-6a. `strict:true` with any object schema where `properties` contains
> a key not listed in `required` returns HTTP 400
> `json_schema_strict_requires_all_properties_required`. Nested object
> schemas are checked recursively.

### B.2 — const/enum type-conformance error code (critic M-2 / Finding 8)

Add to §3:

> A schema where `const` or any `enum` element does not conform to `type`
> returns HTTP 400 `json_schema_invalid_const_or_enum_type`, `param` =
> JSON pointer of the offending node.

Add new AC (next free number):

> AC-N. Schemas with type-mismatched `const` or `enum` (e.g. `{"type":"string","const":42}`)
> return HTTP 400 `json_schema_invalid_const_or_enum_type` with JSON-pointer `param`.

### B.3 — NFC/NFD property name comparison (critic M-3 / Finding 9)

Add to §3:

> Property names are compared by raw UTF-8 byte sequence. No Unicode
> normalization is applied at validation. Two property names with
> different byte sequences are distinct keys even if they normalize to
> the same form.

Add AC:

> AC-N. NFC-vs-NFD property name fixture: a schema with NFC property name
> "café" and a model output with NFD property name "café" are byte-distinct;
> `additionalProperties:false` rejects the NFD key as
> `json_schema_validation_failed`.

## C. Money-path & receipt ordering (closes security H-2, critic H-2 + H-3 + M-1)

### C.1 — Receipt-after-validation ordering (security H-2 + critic H-2)

Add to §5 (Validator behavior):

> **Normative ordering**: a success receipt MUST NOT be emitted, a sticky
> success route MUST NOT be written, and no provider-positive billing
> row MUST be created until post-hoc structured-output validation has
> completed and returned success. On `malformed_json_response` or
> `json_schema_validation_failed`, no success receipt is emitted; the
> request is settled as `FaultBreakerQualifying` per §8 with zero
> provider-positive credits.

Strengthen AC-19 (lines 207-213) to include the ordering claim:

> Add to AC-19: "Order-of-operations regression test: no success receipt
> row, no sticky success write, and no positive billing row exist when
> post-hoc validation fails. Validator exceptions, resource-limit aborts,
> and recursion overflow MUST be converted to terminal 502 with SPEC-019
> code, `inference_ran:true`, `settlement_ran:true`, `FaultBreakerQualifying`,
> zero provider-positive credits."

### C.2 — Empty completion content classification (critic H-3)

Add to §5:

> **Empty content under `json_schema` / `json_object`**: if final inference
> output (post stop-token filtering, cite `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:811-828`)
> is the empty string `""`, the response is classified as HTTP 502
> `malformed_json_response` with `inference_ran:true`, `settlement_ran:true`,
> `FaultBreakerQualifying`. Empty string is not a JSON value.

Add AC:

> AC-N. Empty-content fixture: when the model emits zero tokens after
> stop-token filtering and `json_schema` or `json_object` is requested,
> the response is HTTP 502 `malformed_json_response` (not 200 with empty
> content). Settlement is `FaultBreakerQualifying`.

### C.3 — Defaulted-`strict` idempotency cliff (critic M-1 / Finding 7)

Add to §9 (Forward-compatibility invariants):

> **Receipt canonical scope for `response_format`**: the receipt prompt
> hash is computed over the raw `response_format` JSON value as received
> in the request body. Defaulted-but-absent fields (notably `strict`
> defaulting to `true`) are NOT folded into the hash. Buyers seeking
> byte-stable receipts MUST send defaulted fields explicitly. This is the
> JCS-canonicalization contract of `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16`
> applied to v0.1.0; a future version MAY fold defaults in but MUST
> announce the migration.

## D. Caps & DoS surface (closes security H-1, critic H-4, H-5, security M-1)

### D.1 — Schema depth cap (security H-1 + critic H-4)

Add to §6 (Caps):

> **`json_schema_max_depth = 32`**. Schemas exceeding 32 nested levels at
> parse time return HTTP 400 `json_schema_too_deep` at both provider and
> coordinator before inference. Depth is counted at every level
> (`properties[*]`, `items`, nested `items`/`properties`). Same constant
> as the output-validation depth cap in AC-25, by design.

Add ACs:

> AC-N. Schema-depth fixture: a schema nested exactly 32 levels deep
> succeeds; 33 levels returns HTTP 400 `json_schema_too_deep` at both
> provider and coordinator.

### D.2 — Response cap pre-parse fail-closed (critic H-5)

Rewrite §6 response-cap paragraph to:

> **Response cap order**: the SPEC-018 v0.2.4 §9 `2_097_152`-byte response
> cap is enforced on the **raw UTF-8 bytes emitted by inference, before
> JSON parsing or schema validation runs**. Exceeding the cap returns
> HTTP 502 `response_byte_cap_exceeded` (existing SPEC-018 code),
> `inference_ran:true`, `settlement_ran:true`, `FaultBreakerQualifying`.
> Structured-output parsing and validation never run on over-cap output;
> this mirrors SPEC-018 §10d.7 fail-closed posture.

### D.3 — `json_schema.name` as untrusted prompt data (security M-1)

Add to §3:

> `json_schema.name` is untrusted prompt data when rendered into the
> chat-template system position. The renderer MUST embed it only as
> JSON string data (escaped, length-bounded). Recommended constraint:
> max 64 ASCII chars matching `[A-Za-z0-9_]+` (OpenAI machine-name
> convention); names outside this set return HTTP 400 `json_schema_invalid_name`.

Extend AC-23 explicitly:

> Amend AC-23: prompt-injection fixture covers hostile strings in
> `json_schema.description`, `json_schema.name`, property names, property
> descriptions, enum values, and const values. Hostile strings cannot
> terminate the schema instruction block, cannot inject system role text,
> and cannot inject tool-call sentinels.

## E. Renderer composition & state (closes architect H-1, code M-2, critic H-6)

### E.1 — Composite render ordering (architect H-1 + code M-2)

Add to §4 (Family rendering):

> **Composite render rule when both `tools` and `response_format:json_schema`
> are present**: the IMPL MUST first render multi-turn `tools` history per
> SPEC-018 §10d.1 (cite `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift`),
> then prepend the structured-output schema instruction immediately
> after, all in the system position. Order at each `ModelRuntime.swift`
> hook (cite `:400`, `:454`, `:540`):
> 1. Build structured-output-adjusted `ChatMessage` values (schema
>    instruction at system position).
> 2. Pass to `ToolPromptRenderer.renderMessages` (tool prompt template
>    rendering).
> 3. Create `UserInput` with unchanged `tools` array.

Add AC:

> AC-N. Composite-render fixture: a request with both `tools` (multi-turn
> history) and `response_format:json_schema` renders BOTH the tool prompt
> template AND the schema instruction in the system position, in
> deterministic order, byte-equivalent to the Qwen3 / Llama-3.3 fixture.

### E.2 — Stateless renderer in v0.1.0 (critic H-6)

Add to §4:

> **Stateless renderer**: the structured-output renderer MUST be stateless
> across requests in v0.1.0. No schema cache (in-process, per-connection,
> or per-family) is permitted. Schema warm-cache is deferred to v0.2 per §10.

Add AC:

> AC-N. Concurrent-request fixture: two simultaneous requests with
> different schemas render their own schemas into their own system
> prompts; no cross-render between requests.

## F. AC-15 / AC-16 fixture artifacts (closes code H-1, PD H-1)

### F.1 — Define concrete fixture artifacts (code H-1)

Rewrite AC-15 to specify:

> AC-15. Fixture: `test/integration/spec_019/openai_python_strict_json_schema/`
> contains a request body, a schema (`Person { name: str, age: int }`
> strict-mode), an expected `pydantic` parsed model, SDK version
> `openai==2.44.0`, and a target test file `test_strict_parity.py`.
> The macprovider response parses into the same `pydantic` model as the
> OpenAI `gpt-4o-2024-08-06` golden fixture committed alongside the test.

### F.2 — Vercel AC tests the right path (PD H-1)

Rewrite AC-16 to:

> AC-16. Fixture: `test/integration/spec_019/vercel_ai_sdk_strict_json_schema/`
> uses `createOpenAICompatible({ supportsStructuredOutputs: true, ... })`
> (NOT default — default emits `json_object` not `json_schema`). The
> outbound request body MUST contain `response_format.type ==
> "json_schema"` and `json_schema.strict == true`. A separate fixture
> AC-16b proves the default-path (`supportsStructuredOutputs:false`)
> emits `json_object` and is enforced by AC-7.

## G. Error code naming & buyer-facing UX (closes PD H-2, H-3, M-1, M-2)

### G.1 — Drop `_in_v0_1` suffixes (PD H-3)

**Decision: rename** — codes outlive their version names.

Replace these codes everywhere in the SPEC body (§1, AC-11, AC-22, §9):

| Old | New |
|---|---|
| `streaming_json_schema_unsupported_in_v0_1` | `streaming_json_schema_unsupported` |
| `streaming_json_object_unsupported_in_v0_1` | `streaming_json_object_unsupported` |
| `json_schema_non_strict_unsupported_in_v0_1` | `json_schema_non_strict_unsupported` |

Move "unsupported in SPEC-019 v0.1.0" context into `error.message`, not
`error.code`.

### G.2 — `json_object` enforcement = breaking change (PD H-2)

Add to §1 (Buyer-visible contract):

> **Breaking change for `json_object` buyers**: before SPEC-019, buyers
> who sent `response_format: {"type":"json_object"}` received
> unconstrained text (silent no-op). v0.1.0 enforces top-level JSON
> object/array; malformed output is HTTP 502 `malformed_json_response`,
> `retryable:true`. Buyers relying on best-effort text fallback under
> `json_object` MUST migrate to omitted or `{"type":"text"}` before
> upgrade. v0.1.0 release notes MUST surface this change.

Add to §10 (Deferred):

> A buyer-facing migration note in the public release notes is a v0.1.0
> release acceptance criterion.

### G.3 — Streaming-reject envelope (PD M-2)

Rewrite AC-11 to:

> AC-11. `response_format: {"type":"json_schema", ...}` with `stream:true`
> returns HTTP 400 `streaming_json_schema_unsupported` with envelope
> `type:"invalid_request_error"`, `param:"stream"`, `retryable:false`,
> `inference_ran:false`, `settlement_ran:false`, message recommending
> `stream:false` retry. Same envelope shape for
> `streaming_json_object_unsupported`.

### G.4 — Cline v0.1 boundary statement (PD M-1)

Add to §10 (Deferred):

> **v0.1.0 is NOT a Cline drop-in structured-output release.** Cline
> source as of `commit-sha-from-grep` does not send `response_format` /
> `json_schema` / `generateObject` / `streamObject` on its active
> streaming code path. Cline structured-output enablement is a v0.2
> streaming-validation deliverable. v0.1.0 unlocks structured output for
> non-streaming SDK consumers (openai-python, Vercel AI SDK non-stream).

Add AC:

> AC-N. Cline negative regression: a Cline-style `streamText` request
> WITHOUT `response_format` is unaffected by SPEC-019. No new
> validation, no new error envelope, no behavior change.

## H. Code-lane M findings (closes code M-1, M-2 covered in E.1)

### H.1 — RFC 6901 root pointer (code M-1)

Find every `"/"` reference in the SPEC that's claimed as a JSON pointer.
Replace with `""` (the empty string is the RFC 6901 root pointer).
Update §5 wording: "for root-level failures, the JSON pointer is the
empty string `""`, per RFC 6901 §5."

## I. Document quality (closes narrative H-1, H-2 + minor wording)

### I.1 — Quick orientation: promote the lead (narrative H-1)

Restructure §0 "Quick orientation" so the first 4-5 lines are PLAIN
ENGLISH about what v0.1.0 does, before any file:line citation. Move
file:line evidence into a "## Current code state" subsection that comes
AFTER the orientation lead.

Target lead (paraphrase, don't copy verbatim):

> SPEC-019 v0.1 is the provider-side structured-output contract:
> buyers send `response_format: {"type":"json_schema", ...}` and
> receive assistant content that conforms to their schema, or a
> structured 502 with `FaultBreakerQualifying` settlement.
> Slice scope: non-streaming only; post-hoc parse+validate (no
> constrained decoding); OpenAI strict-mode subset; bundled
> `json_object` enforcement fix; no SPEC-015 schema change.

### I.2 — Reorder ACs into categories (narrative H-2)

Resort ACs into these categories, renumbering AC-1..AC-N sequentially:

1. **Request parsing** (currently AC-1, AC-2, AC-3, AC-22)
2. **Request validation** (currently AC-4, AC-5, AC-6, AC-6a NEW from §B.1,
   plus AC for const/enum NEW from §B.2)
3. **Schema-shape parity** (NEW for B.3 NFC/NFD)
4. **Caps** (currently AC-5 byte cap, AC-17 boundary, NEW schema depth
   from §D.1, AC-25 output depth)
5. **Output validation** (currently AC-8, AC-9, AC-10, NEW for §C.2 empty
   content, NEW for §D.2 response cap order)
6. **Streaming reject** (currently AC-11, rewritten per §G.3)
7. **Family rendering** (currently AC-13, NEW for §E.1 composite render,
   NEW for §E.2 stateless renderer)
8. **Tool × schema interaction** (currently AC-14)
9. **Money path & receipt ordering** (currently AC-12 receipt, AC-19
   money-path, strengthened per §C.1)
10. **Coordinator / gateway parity** (currently AC-20, AC-21)
11. **Buyer-facing UX** (currently AC-22 strict:false — moved to category
    1, NEW for Cline negative regression from §G.4)
12. **Forward-compat regression fixtures** (currently AC-15, AC-16,
    AC-23, AC-24)

### I.3 — Minor wording fixes (narrative M-1..M-4)

- AC-1 "Fail condition" convention: state up front in §2 preamble that
  every AC includes a "Fail condition" naming the current behavior that
  would falsely pass the AC. AC-1's "Fail condition: current HTTP 400
  remains" is correct — clarify in preamble.
- Cross-spec citations (SPEC-001, SPEC-006, SPEC-015, SPEC-018): add a
  half-line summary after each `file:line` citation explaining what the
  cited range contains, not just where it is.
- §3 reject-list: state the count of rejected keywords explicitly
  ("v0.1.0 rejects 11 JSON Schema keywords: oneOf, anyOf, allOf, not,
  $ref, $defs, pattern, format, minimum, maximum, multipleOf, minItems,
  maxItems, uniqueItems — count = 14"; verify and update).
- §6 caps: cite SPEC-018 §9 inheritance once, not three times.

## J. Change log entry & metadata

Update §12 (Document metadata):

- Version: **0.1.1** (2026-06-28, round-1 audit absorption)
- Status: DRAFT (r2 defensive audit pending)
- Append to change log:

```
- **v0.1.1 (2026-06-28, round-1 audit absorption):** Absorbed 3 CRITICAL
  + 14 HIGH + 14 MEDIUM findings across 6 audit lanes. Cross-spec
  amendments to SPEC-001 (§A.1) and SPEC-006 (§A.2). New strict-mode
  parity rule (§B.1) and new error codes. Schema-depth cap added (§D.1).
  Money-path receipt-ordering normative (§C.1). Empty-content
  classification (§C.2). Composite tool×schema render order (§E.1).
  Stateless renderer required (§E.2). Concrete AC-15/AC-16 fixtures
  (§F). Versioned error-code suffixes dropped (§G.1). Quick orientation
  + AC categories restructured (§I.1, §I.2). Round narrative:
  `specs/SPEC-019-v0_1-r1-audit.md`; per-lane findings:
  `specs/SPEC-019-v0_1-{architect,code,security,product-design,critic,
  narrative}-r1-audit.md`.
```

## Stop condition

Verify after editing:

1. Every old `_in_v0_1` suffix is gone from §1, AC-11, AC-22, §9.
2. New error codes added: `json_schema_strict_requires_all_properties_required`,
   `json_schema_invalid_const_or_enum_type`, `json_schema_too_deep`,
   `json_schema_invalid_name`. List all SPEC-019 error codes in a
   table in §5 (or §13 new).
3. AC count: original 25 + new ACs from §B (3), §C (2), §D (1), §E (2),
   §G (1) = roughly 34. Renumber per §I.2 ordering.
4. Receipt-ordering invariant is present in both §5 and AC-19.
5. Schema-depth cap is 32, same as output-depth cap.
6. Response-cap order is pre-parse fail-closed.
7. Quick orientation §0 reads as plain-English summary, not file:line wall.

Report:
- Resulting `wc -l specs/SPEC-019-structured-output.md`.
- Total AC count after renumber.
- List of new error codes added.
- Any §B/C/D/E/G AC additions you could not place — explain why.

Done. No commit. No re-audit. The audit loop fires r2 next.
