**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/0/0/0

## Closure verified

- r1 C-1: CLOSED. SPEC-019 §1 now explicitly supersedes the SPEC-001
  `response_format.type` allowed-values row, adds `json_schema`, replaces
  `json_object` hint behavior with mandatory post-hoc enforcement, and states no
  other SPEC-001 request fields change (`specs/SPEC-019-structured-output.md:60`;
  `specs/SPEC-019-structured-output.md:64`). The cited SPEC-001 row does define
  only `text` / `json_object`, hint behavior, and unknown-value rejection
  (`specs/SPEC-001-phase3-binary.md:934`), so the supersession is clean.
- r1 C-2: CLOSED. SPEC-019 §7 now amends SPEC-006's provider-5xx normalization
  and adds only `malformed_json_response` and
  `json_schema_validation_failed` to the gateway pass-through detail-code
  allow-list (`specs/SPEC-019-structured-output.md:625`). The cited SPEC-006 line
  is the conflicting normalized 502 contract (`specs/SPEC-006-buyer-api.md:2556`).
- r1 H-1: PARTIAL. SPEC-019 §4 now requires a composite tool-schema render path,
  but the prose and numbered sequence disagree on the operative order. The prose
  says the IMPL MUST first render multi-turn tools, then prepend the structured
  schema instruction (`specs/SPEC-019-structured-output.md:452`), while the
  numbered hook sequence says first build schema-adjusted `ChatMessage` values,
  then pass them to `ToolPromptRenderer.renderMessages`
  (`specs/SPEC-019-structured-output.md:461`). This leaves the original
  system-position ordering ambiguity unresolved at the `ModelRuntime.swift`
  hook sites (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`,
  `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`,
  `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`).

## Fresh findings

### Finding 1: Composite render rule still has two normative orders
- Severity: HIGH
- Location: SPEC §4 (`specs/SPEC-019-structured-output.md:452`)
- Issue: The new composite rule is internally contradictory. "MUST first render
  multi-turn `tools` history ... then prepend the structured-output schema
  instruction" describes tool rendering before schema insertion, but the ordered
  hook steps prescribe schema insertion before calling
  `ToolPromptRenderer.renderMessages`. Since `ToolPromptRenderer.renderMessages`
  is the existing hook used immediately before MLX preparation, both readings are
  implementable and produce different ownership of the final system-position
  text.
- Recommendation: Pick one order and make both the prose and numbered hook
  sequence say the same thing. The least invasive order appears to be: build
  schema-adjusted `ChatMessage` values with the schema instruction in the system
  message, pass those messages through `ToolPromptRenderer.renderMessages`, then
  create `UserInput` with unchanged tools. If the intended order is instead
  tool-render first, specify the concrete post-render insertion API and fixture
  bytes.

## Verdict justification

The SPEC-001 supersession is clean: SPEC-019 cites and explicitly replaces the
old `response_format` row without widening unrelated SPEC-001 fields. SPEC-006
also has a clean, narrow amendment: the previous blanket gateway normalization
remains for other provider 502s, while only the two structured-output
post-inference detail codes pass through.

Regression probes found no architect-level contradiction with SPEC-006's
`response_format` treatment, because SPEC-006 only lists the field as supported
and does not constrain its inner values (`specs/SPEC-006-buyer-api.md:1029`).
The v0.1.1 metadata bump does not affect receipt hashes: SPEC-015 hashes the
canonical prompt object including `response_format`
(`specs/SPEC-015-receipts.md:1191`), and current code hashes the prompt-source
`responseFormat` field, not SPEC metadata
(`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5`).

The §5 error-code table covers the SPEC-019 codes used by §2 ACs:
`json_schema_missing_name`, `json_schema_missing_schema`,
`json_schema_non_strict_unsupported`, `json_schema_unsupported_keyword`,
`json_schema_strict_requires_additional_properties_false`,
`json_schema_strict_requires_all_properties_required`,
`json_schema_invalid_const_or_enum_type`, `json_schema_too_large`,
`json_schema_too_deep`, `malformed_json_response`,
`json_schema_validation_failed`, `response_byte_cap_exceeded`,
`streaming_json_schema_unsupported`, and `streaming_json_object_unsupported`
all appear in the table (`specs/SPEC-019-structured-output.md:533`).

The remaining HIGH is enough to block lock: §4 must be made internally
single-order before SPEC-019 can be considered ready.
