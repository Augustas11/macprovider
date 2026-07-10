**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 2/1/0/0/0

## Findings

### Finding 1: SPEC-019 extends `response_format` without superseding SPEC-001
- Severity: CRITICAL
- Location: SPEC-019 §1 (lines 54-61), AC-1 (lines 112-115), AC-7 (lines 139-142); SPEC-001 `specs/SPEC-001-phase3-binary.md:934`
- Issue: SPEC-019 requires the provider to accept `response_format.type == "json_schema"` and to enforce `json_object`, but SPEC-001 still normatively defines `response_format.type` as only `"text"` or `"json_object"`, says `"json_object"` engages an MLX structured-decoding hint if available, and says any other value is rejected with 400. That is a direct cross-spec contradiction unless SPEC-019 explicitly amends or supersedes the SPEC-001 row for this field.
- Recommendation: Add an explicit cross-spec amendment note near SPEC-019 §1/metadata: "For `/v1/chat/completions`, SPEC-019 v0.1.0 supersedes SPEC-001's `response_format` row by adding `json_schema` and replacing the optional MLX-hint `json_object` behavior with mandatory post-hoc JSON enforcement." Include the SPEC-001 citation and make clear no other SPEC-001 request fields are changed.

### Finding 2: Buyer-visible 502 codes conflict with SPEC-006 gateway normalization
- Severity: CRITICAL
- Location: SPEC-019 AC-9/AC-10 (lines 149-160), §5 (lines 338-348); SPEC-006 `specs/SPEC-006-buyer-api.md:2556`; current gateway `phase5-gateway/internal/router/chat_proxy.go:317-327` and `phase5-gateway/internal/router/chat_proxy.go:601-607`
- Issue: SPEC-019 makes `malformed_json_response` and `json_schema_validation_failed` buyer-visible HTTP 502 error codes with `type:"upstream_provider_error"`. SPEC-006, however, says selected-provider failures reaching the gateway are exposed as `type:"api_error"` and `code:"upstream_provider_error"`. The current gateway also collapses non-OK coordinator/provider responses to `api_error/upstream_provider_error` except a narrow allow-list that does not include the SPEC-019 codes. As written, implementers cannot satisfy both SPEC-019's stable structured-output error codes and SPEC-006's gateway normalization contract.
- Recommendation: Decide and document ownership of these detailed 502 codes. If buyers must see `malformed_json_response` / `json_schema_validation_failed`, SPEC-019 should explicitly amend SPEC-006's 502 normalization for receipt-eligible provider-output validation failures and add gateway pass-through requirements. If the detailed codes are provider/coordinator-internal only, revise AC-9/AC-10/§5 to state the buyer-visible gateway envelope remains SPEC-006 `api_error/upstream_provider_error` and move detailed reason fields to logs/request-log/receipt-specific metadata.

### Finding 3: Tools plus `json_schema` precedence omits composite prompt-rendering rules
- Severity: HIGH
- Location: SPEC-019 §1 tools interaction (lines 101-108), AC-14 (lines 179-184), §4 (lines 296-319); SPEC-018 §10d.1 `specs/SPEC-018-agentic-tool-calling.md:784-832`
- Issue: SPEC-019 crisply defines post-inference precedence: valid tool calls win, otherwise assistant content must validate against the response schema. It does not define the corresponding pre-inference rendering when both `tools` and `response_format.type == "json_schema"` are present. §4 defines schema instruction placement and fixtures that explicitly expect no tool-call sentinel injection, while SPEC-018 §10d.1 requires tool prompt-template rendering for multi-turn tool use. An implementer could reasonably render only the schema instruction, only the tool template, or both in either order, producing different Cline behavior for the same request.
- Recommendation: Add a normative composite-rendering rule and fixture: when both tools and `json_schema` are supplied, render the SPEC-018 tool prompt-template exactly as before, add the structured-output instruction in a deterministic system-position order, and verify both a tool-call response path and a no-tool final-content validation path. If the intended behavior is mutual exclusion instead, state that explicitly and reject the combination before inference.
