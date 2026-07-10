# AUDIT_SPEC_015_v0_2_IMPL_STEP_4_PROMPT

You are auditing Step 4 of `BUILD_SPEC_015_v0_2_VERIFY_IMPL_PROMPT.md`:
prompt and output canonicalization for `phase7-verify/internal/canon`.

## Scope

Review only the Step 4 implementation and tests:

- `phase7-verify/internal/canon/canon.go`
- `phase7-verify/internal/canon/canon_test.go`
- `phase7-verify/internal/canon/parity_test.go`
- `phase7-verify/internal/canon/integration_test.go`
- `phase7-verify/internal/canon/implementation-notes.md`
- `phase7-verify/testdata/canon_fixtures.json`
- `phase3-binary/Tests/macprovider-cliTests/PromptOutputCanonicalizerParityTests.swift`

Do not modify source of truth canonicalizers:

- `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift`
- `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift`

Do not inspect or modify `d-inference`.

## Audit Questions

1. Swift<->Go bit identity:
   - Does the shared fixture corpus prove byte-for-byte canonical identity for
     prompt and output paths?
   - Are both canonical bytes and SHA-256 hashes asserted on both sides?
   - Is fixture regeneration guarded so accidental rewrites are explicit?

2. SPEC-015 §4.2 prompt fields:
   - Are exactly the sixteen committed prompt keys included?
   - Do absent optional fields canonicalize as JSON `null`?
   - Are present optional values JCS-wrapped without shortcutting object,
     array, string, int, float, bool, and null behavior?
   - Are fields outside the committed set ignored?

3. SPEC-015 §4.3 / §4.4 prompt subobjects:
   - Are messages canonicalized to exactly `role`, `content`, `name`,
     `tool_call_id`, and `tool_calls`?
   - Are string, null, and multimodal content arrays handled per spec?
   - Are canonical tools reduced to `type:"function"` and the canonical
     function object with `name`, `description`, and `parameters`?

4. SPEC-015 §5.1 output fields:
   - Is `choices[0]` the only output source?
   - Does missing or null output content become `""`?
   - Are `content`, `tool_calls`, and `finish_reason` the only committed output
     keys?

5. Line-ending and Unicode normalization scope:
   - Are CRLF and bare CR normalized only for prompt content strings, prompt
     text content parts, and output content?
   - Are normal strings left to the JCS layer for NFC normalization?
   - Are tool-call arguments excluded from both line-ending normalization and
     NFC normalization?

6. Raw string distinction:
   - Does `tool_call.function.arguments` use `jcs.KindRawString` or equivalent?
   - Do tests prove whitespace and decomposed Unicode in arguments change the
     hash?

7. Finish reason enum:
   - Are all five v0.1 values accepted: `stop`, `length`, `tool_calls`,
     `content_filter`, and `error`?
   - Are unknown values such as `stop_streaming` rejected with the typed error?

8. End-to-end receipt integration:
   - Does the test combine `CanonicalPrompt`, `CanonicalOutput`, and the Step 3
     receipt parser/verifier?
   - Is the request/response shape aligned with the existing SPEC-015
     integration harness v0.1 receipt path?
   - Do parsed `prompt_hash` and `output_hash` match the canonicalizer output?

## Required Output

Return findings first, ordered by severity, with concrete file and line
references. If no issues are found, state that clearly and list residual risks
or test gaps. Keep the review focused on canonical bit identity and receipt
verification safety.
