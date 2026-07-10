**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/2/1/0/0

## Findings

### Finding 1: Prompt-injection fixture omits `json_schema.name`
- Severity: MEDIUM
- Location: SPEC §1 (lines 82-86), SPEC §2 AC-23 (lines 230-233), SPEC §4 (lines 301-319)
- Issue: AC-23 covers hostile `json_schema.description`, property descriptions, enum values, and const values, and §4 adds descriptions, enum strings, const strings, and property names as untrusted prompt data. It does not cover `json_schema.name`, even though §4 requires the renderer to include the name in the injected system instruction. Because `name` is buyer-controlled and currently has no specified character set, max length, or JSON-string escaping rule, a hostile buyer can use the name field as the shortest prompt-injection escape path while still passing AC-23.
- Recommendation: Specify `json_schema.name` as untrusted prompt data, require it to be embedded only as JSON string data or constrain it with a strict regex/length such as OpenAI-compatible machine names, and add AC-23 fixtures with block terminators, system-role text, and tool-call sentinels in both `json_schema.name` and property names.

### Finding 2: Schema validator DoS is not bounded at schema parse time
- Severity: HIGH
- Location: SPEC §2 AC-5 (lines 129-132), SPEC §2 AC-17 (lines 195-200), SPEC §2 AC-25 (lines 240-244), SPEC §3 (lines 276-280), SPEC §6 (lines 389-390), SPEC §7 (lines 399-404)
- Issue: The 16 KiB cap bounds raw schema bytes, but the SPEC does not bound schema tree depth, schema node count, property count, or validator traversal work. AC-25 and §6 cap only decoded output JSON depth at 32; they do not require the provider parser or coordinator validator to reject a deeply nested schema before recursive schema validation. A valid-but-pathological 16 KiB schema can still drive stack exhaustion or high-cost validation, and coordinator/provider parity is untestable because §7 lists keyword and strict checks but no schema-depth or complexity checks.
- Recommendation: Add normative schema-complexity limits enforced at both provider parse and coordinator validation before inference: at minimum `json_schema_max_depth = 32` with depth-32 accept/depth-33 reject tests, plus either an explicit max schema-node/property budget or an iterative traversal requirement proving O(schema bytes + output bytes) behavior. AC-25 should cover both schema parse depth and output validation depth.

### Finding 3: Money-path protection does not cover validator exceptions
- Severity: HIGH
- Location: SPEC §2 AC-9/AC-10 (lines 149-160), SPEC §2 AC-19 (lines 207-213), SPEC §5 (lines 323-349), SPEC §8 (lines 417-427), `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:278`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:285`, `phase4-coordinator/internal/billing/formula.go:112`
- Issue: The SPEC requires normal parse and schema-validation failures to return `malformed_json_response` or `json_schema_validation_failed` with `settlement_ran:true` and `FaultBreakerQualifying`, but it does not require the structured-output validator to classify exceptional failure paths before success bookkeeping. Current provider success plumbing finishes the request and builds the receipt after `completeWithServedSnapshot` returns, while current `APIError.envelope` defaults `inference_ran:false` and `settlement_ran:false`; a thrown validator bug, recursion overflow, or resource abort can therefore fall into a generic internal-error path unless the implementation adds a distinct terminal structured-output error wrapper. That path is not covered by AC-19 and is exactly where money-path leakage or non-breaker fault classification can occur.
- Recommendation: Add a normative ordering and failure-mode AC: after inference starts and before any 200 response, success receipt, sticky-route success write, or provider-positive settlement, every structured-output postprocess failure, including parser/validator exceptions and resource-limit aborts, MUST be converted to a terminal 502 with a SPEC-019 code, `inference_ran:true`, `settlement_ran:true`, request-log `FaultBreakerQualifying`, and zero provider-positive credits. Add tests that inject validator exceptions/timeout-depth aborts and prove no success receipt, no sticky success, and no positive billing row.
