# SPEC-015 Prompt and Output Canonicalization Notes

## Fixture provenance

`phase7-verify/testdata/canon_fixtures.json` is generated from the Swift
canonicalizers in:

- `phase3-binary/Sources/malibu-cli/PromptCanonicalizer.swift`
- `phase3-binary/Sources/malibu-cli/OutputCanonicalizer.swift`

The generator is guarded by `REGENERATE_CANON_FIXTURES=1` in
`phase3-binary/Tests/malibu-cliTests/PromptOutputCanonicalizerParityTests.swift`.
The same test also reads the shared fixture corpus without regeneration and
asserts Swift still emits every expected canonical byte string and hash.

## Raw tool-call arguments

`tool_call.function.arguments` is encoded with `jcs.KindRawString`, matching
Swift's `.rawString(...)`. This is intentionally different from normal
`jcs.KindString`: normal strings are NFC-normalized by the JCS layer, while raw
strings are escaped without NFC normalization.

This distinction is load-bearing. The receipt commits to the exact serialized
argument string emitted by the model, including whitespace and decomposed
Unicode. Parsing, reformatting, or NFC-normalizing the argument blob would
change the signed hash.

## Line-ending normalization scope

SPEC-015 line-ending normalization (`CRLF -> LF`, bare `CR -> LF`) is applied
only to:

- prompt message `content` when it is a string
- prompt multimodal `text` content part `text`
- output `choices[0].message.content`

It is not applied to `tool_call.function.arguments`, tool schemas, image URLs,
audio payload strings, names, tool call ids, or arbitrary optional request
objects.

## Buyer flexibility

The prompt canonical object always includes the exact sixteen SPEC-015 §4.2
keys. Optional fields absent from the buyer's raw OpenAI request map become JSON
`null`; present fields are JCS-wrapped as supplied. Fields outside the committed
set, such as `stream`, `user`, and `metadata`, are ignored. This preserves the
v0.1 buyer-flexibility contract for raw captures while still binding the fields
that affect output distribution and response shape.

## Cross-validation reference

`test/integration/spec015/tuple_canonicalizer.go` remains in a separate
integration module and is not imported by `phase7-verify`. That canonicalizer
has been used in the existing integration harness to validate real v0.1 receipt
tuple bytes. The `phase7-verify/internal/canon` package independently ports the
same Swift prompt/output contract, then cross-validates through the shared
Swift-generated fixture corpus and an end-to-end receipt parser test modeled on
the integration harness request/response shape.
