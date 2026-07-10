# SPEC-019 v0.1.5 IMPL -- round-1 critic (blind-spot) audit

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 1/2/3/1/2

Scope: blind-spot pass for the 8 probe topics listed in the audit prompt's
Claude-critic lens, plus the StrictJSONParser introduction. Where the 4 codex
lanes will obviously land a finding (e.g. coordinator/provider regex parity,
catch-all wrap), I deliberately stayed off. Where I differ from the codex
lanes' likely coverage is in the **WS-end-frame envelope discipline**,
**StrictJSONParser asymmetry**, **`isWhitespace` parity drift on
Content-Encoding**, and **whitespace-only-output ambiguity** -- none of which
fall naturally inside architect/code/security/product-design lenses.

## Findings

### Finding 1: Provider->coordinator WS hop collapses SPEC-019 envelope to `error_internal`/`provider_error` -- buyer never sees `malformed_json_response` / `json_schema_validation_failed` / `retryable:false`

- Severity: **CRITICAL**
- Location: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529-548` (provider `errorEndFrame`); `phase4-coordinator/internal/buyer/server.go:5046-5057` (coordinator `writeWSEndError`); `phase4-coordinator/internal/buyer/server.go:5260-5282` (coordinator-side envelope construction).
- Issue: when `ModelRuntime.validateStructuredCompletion`
  (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:911-940`) throws
  the SPEC-019-shaped `APIError` (`malformed_json_response` or
  `json_schema_validation_failed`, `retryable:false`/`true`, `inferenceRan:
  true`, `settlementRan:true`), the WS path catches it at
  `InferenceRelay.swift:244` and routes through `errorEndFrame`. That helper
  only recognizes four codes (`model_not_loaded`, `model_not_found`,
  `context_length_exceeded`, `queue_full`); every other code -- including
  both new SPEC-019 detail codes -- collapses to `status:"error_internal"`
  with a plain string `error: error.message`. The original code, `param`,
  `retryable` override, `inference_ran`, and `settlement_ran` fields are
  **dropped from the end-frame**. The coordinator's `forwardWSNonStreaming`
  observes `end.Status != "complete"`, calls `writeWSEndError`, hits the
  default arm at `server.go:5054-5056`, and emits a 502 with
  `code:"provider_error"`, message `"Selected provider failed; buyer should
  retry"`, `retryable: spec018Retryable("provider_error") = false` (because
  `"provider_error"` is not in the map -> zero-value false), and
  `inference_ran:false` (`server.go:5278`). InferenceRelay.swift was **not
  touched by the IMPL** (`git diff origin/main --
  phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` returns
  empty), so the SPEC-019-envelope-shape contract reaches the buyer only on
  the direct-HTTPServer path the new tests exercise -- never on production
  traffic, which traverses provider->coordinator over WS. This breaks AC-18
  (empty-content envelope: `retryable:false` + actionable
  `temperature`/`seed` message MUST reach the buyer), AC-26 (SPEC-019
  detail codes propagate, money-path settles `FaultBreakerQualifying`
  using those codes), AC-30 (envelope discipline). The provider WILL
  internally mark the request as failed and settlement WILL be
  `FaultBreakerQualifying` (coordinator-side `zeroTokenFault` /
  `breakerFault` logic in this path is unchanged), so this is a buyer-UX
  + envelope-discipline violation rather than a billing leak -- but the
  buyer-actionable instructions (`temperature`/`seed`) and the very
  signal that this was a STRUCTURED-OUTPUT failure (vs. a generic provider
  failure they should retry) are silently destroyed in the WS hop.
- Recommendation: extend `errorEndFrame` in `InferenceRelay.swift` to
  carry the full SPEC-019 envelope across the WS hop. Either (a) add a
  new end-frame status (`error_spec019` or `error_postprocess`) that
  carries `code`, `param`, `retryable`, `inference_ran:true`,
  `settlement_ran:true`, `message`; OR (b) preserve the full
  `APIError.envelope` dict on the end frame for codes in a new
  `spec019PostprocessCodes` allow-list, and teach
  `coordinator/internal/buyer/server.go:writeWSEndError` to recognize
  those codes and pass them through verbatim (analogous to the gateway
  pass-through allow-list amendment for SPEC-006). Add a WS-path
  integration test that asserts the end-frame's `code` and `retryable`
  match the provider's `APIError` for both `malformed_json_response`
  (empty content) and `json_schema_validation_failed` (bad shape) cases.

### Finding 2: `StrictJSONParser` is used for model output only; request body and schema are parsed via `JSONSerialization` -> asymmetric duplicate-key + content-control semantics

- Severity: **HIGH**
- Location: `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:1-241` (NEW); `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:24` (`JSONSerialization.jsonObject(with: data)` for request body); `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:463` (`JSONValue.parse(rawSchema)` ultimately backed by `JSONSerialization`).
- Issue: SPEC section 5 step 3 says: "If `response_format.type == "json_object"`,
  parse final assistant content as JSON, **reject duplicate keys**, and
  require root object or array." Step 4 says the same for `json_schema`.
  The IMPL solves this with `StrictJSONParser`, which correctly rejects
  duplicate keys at line 62 (`throw ParseError.duplicateKey(key)`) and
  trailing data at line 9. **But** the same SPEC subsection's underlying
  invariant -- that duplicate keys are semantically forbidden -- is NOT
  enforced on the schema itself (parsed via `JSONSerialization`,
  silently last-wins) or on the request body envelope (same). The
  StrictJSONParser exists, the rest of the world disagrees. Concrete
  consequence: a buyer can send a schema `{"type":"object",
  "additionalProperties":true,"additionalProperties":false,
  "properties":{...},"required":[...]}`. Foundation's `JSONSerialization`
  silently keeps `additionalProperties:false` (last-wins), the validator
  accepts. That accident harms the buyer only, but the architectural
  asymmetry has two real consequences: (i) the StrictJSONParser is a
  240-line attack surface that exists for ONE caller -- if it has a bug
  (e.g. surrogate handling, number parsing, escape sequence handling),
  validation can fail for the wrong reason on legitimate model output;
  (ii) any future audit/maintenance work is harder because there are now
  TWO JSON parsers with subtly different semantics in the same package
  (e.g. control-character handling: `StrictJSONParser.parseString` line 135
  rejects `< 0x20`, but `JSONSerialization` is more permissive in some
  edge cases). The StrictJSONParser is also incomplete vs RFC 8259 in one
  observable way: it accepts a leading `0` followed by more digits via
  `consumeIf("0")` and then never checks that no extra digits follow
  before the dot/exponent (line 144-149) -- `"01"` would parse as `0` then
  trailing data at the `1` -> `trailingData` thrown. So the strict parser
  IS strict on numbers. But why does it exist at all? The SPEC says
  "reject duplicate keys"; that one constraint could have been bolted
  onto a `JSONSerialization.jsonObject(...)` walker much more cheaply.
  Module has zero file-level documentation explaining why it exists vs
  using `Foundation`.
- Recommendation: (a) add a module-level doc-comment to
  `StrictJSONParser.swift` explaining the rationale (which SPEC AC
  requires this strictness, and why `JSONSerialization` is not used);
  (b) decide whether the strict-parse contract should also apply to the
  inbound `response_format.json_schema.schema` (since `additionalProperties`
  last-wins is a buyer-confusion risk and an audit-traceability gap) and
  document the explicit decision either way in SPEC section 5; (c) add at least
  one test that asserts byte-level round-trip parity between
  `StrictJSONParser` and `JSONSerialization` for the cases where both
  could plausibly be used -- surrogate pairs, lone surrogates, embedded
  ` `, embedded ``, leading zero in number, and numbers near
  Int64 boundaries. None of these are currently in
  `JSONSchemaValidatorTests.swift`; the only StrictJSONParser test is
  `testDuplicateKeysAreRejectedByStrictParser` at line 82-84.

### Finding 3: Provider Content-Encoding gate uses `String.isWhitespace`; coordinator + gateway use ASCII-only whitespace -- `Content-Encoding: " identity<NBSP>"` is accepted by provider, rejected by coordinator/gateway

- Severity: **HIGH**
- Location: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:436-449`; `phase4-coordinator/internal/buyer/server.go:5284-5296`; `phase5-gateway/internal/router/chat_proxy.go:628-640`.
- Issue: SPEC section 7 says Content-Encoding values "optionally surrounded by
  whitespace, which the parser MUST strip before comparison." All three
  layers must agree on what "whitespace" means or there's a 3-way parity
  gap. The provider's Swift gate uses
  `values.joined(separator: ",").filter { !$0.isWhitespace }.lowercased()`,
  where Swift `Character.isWhitespace` matches the full Unicode
  white-space property (NBSP `U+00A0`, NEXT LINE `U+0085`, en/em spaces,
  ZWJ, etc.). The coordinator/gateway gates use a literal `strings.Map`
  that strips ONLY ASCII `' '`, `'\t'`, `'\n'`, `'\r'`. Concrete
  divergence: header value `" identity\u00A0"` (literal NBSP after
  `identity`) normalizes on provider to `"identity"` (accepted) but
  normalizes on coordinator/gateway to `"identity\u00a0"` (rejected,
  HTTP 415). Buyer-facing impact is asymmetric (coordinator/gateway is
  the public path, so the buyer always sees 415; the provider-direct
  path is technically reachable on the local network, see audit-prompt
  blind-spot probe topic #5 about "tester bypass"). This is the
  parity-drift class the SPEC section 7 normative-equivalence clause forbids;
  the gateway test only covers ASCII whitespace (`HTTPServerStructuredOutputTests.swift:17`
  uses `" Identity "`).
- Recommendation: normalize all three sides to ASCII-only whitespace
  trim. Replace the Swift `.isWhitespace` filter with a literal
  `[" ", "\t", "\n", "\r"]` membership check (mirroring the Go
  `strings.Map` predicate). Add a parity fixture under
  `test/integration/spec_019/` that asserts NBSP / U+0085 / U+200B
  Content-Encoding values are treated identically by all three layers
  (either all reject, or all accept -- pick one). Add the same
  rejected-input matrix to `HTTPServerStructuredOutputTests.swift` and
  the Go-side `chat_proxy` and `server_test.go` so future drift is
  caught at unit-test time.

### Finding 4: Whitespace-only completion `"   \n"` is silently classified as `retryable:true` malformed-JSON, burning buyer retry budget the same way deterministic empty would

- Severity: **MEDIUM**
- Location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-987` (`parseStructuredJSONContent`).
- Issue: SPEC section 5 empty-content subcase override is **literally** "the
  offending output is the empty string `""` after stop-token filtering".
  The IMPL implements this literally: `guard !content.isEmpty` at
  line 943 -- any non-`""` content falls through to
  `StrictJSONParser.parse(content)`, which throws `unexpectedEnd` for
  whitespace-only input (because `skipWhitespace` advances past all
  whitespace then `parseValue` sees `isAtEnd`). The caught error becomes
  the **default** `malformed_json_response` envelope at line 959-967, with
  no `retryable: false` override (defaults to `retryable: true`). So a
  deterministic model emitting `"   \n"` causes the buyer's SDK to
  blindly retry the identical request (per SPEC section 5 "Retry semantics"
  rule), which will fail the same way, burning the buyer's budget.
  This is exactly the failure mode the empty-content override was
  designed to prevent -- but only for the literal-`""` case. SPEC section 5 is
  silent on whitespace-only output, so this is a defensible literal
  reading, but the user-impact behavior is identical to the empty case
  the SPEC explicitly protects against.
- Recommendation: either (a) extend the empty-content check at line 943
  to also match whitespace-only (e.g. `content.trimmingCharacters(in:
  .whitespacesAndNewlines).isEmpty`) and emit the same `retryable:false`
  envelope with the actionable `temperature`/`seed` message; OR (b) keep
  the literal SPEC behavior and file a SPEC clarification PR for section 5 so
  the decision is recorded. Whichever way: add a test in
  `ModelRuntimeStructuredOutputTests.swift` that pins the behavior so a
  future implementer can't silently flip the answer.

### Finding 5: Vercel fixture README is misleading -- buyer has no actionable instruction for handling `$schema` strip

- Severity: **MEDIUM**
- Location: `test/integration/spec_019/vercel_ai_sdk_strict_json_schema/README.md:11`.
- Issue: README says: "The captured Vercel body may include a top-level
  `$schema`; v0.1.0 strips that key in the fixture normalization step
  because SPEC-019 v0.1.5 rejects `$schema`." The committed
  `fixture_request_body.json` does NOT contain `$schema`. So the fixture
  proves the post-strip body validates -- but a real buyer using
  `@ai-sdk/openai-compatible@2.0.38` will hit HTTP 400
  `json_schema_unsupported_keyword` if Vercel emits `$schema`. The
  README does not tell the buyer: (a) WHO strips it (Vercel SDK option?
  pre-flight middleware? client-side wrapper?); (b) the buyer config
  setting `supportsStructuredOutputs: true` mentioned in the
  audit-prompt product-design lens; (c) the literal JSON path to strip.
  This README is the only documentation a v0.1.0 buyer has for this
  integration, and it leaves them with "the fixture works, your
  request will fail and you won't know why."
- Recommendation: rewrite the README to document the buyer-side fix
  operationally. Either (a) a snippet showing the `supportsStructuredOutputs:
  true` Vercel option that suppresses `$schema` injection, OR (b) a
  pre-request hook that strips the key, OR (c) at minimum a clear note
  that the buyer MUST handle this on their side until v0.2 with the
  expected error code/message they'll see if they don't.

### Finding 6: Coordinator/provider `const`/`enum` integer conformance drift (`1.0` accepted as integer-schema literal in Swift, rejected in Go)

- Severity: **MEDIUM**
- Location: `phase3-binary/Sources/MacProviderCore/JSONValue.swift:33-37` (Swift `1.0` -> `.int(1)`); `phase4-coordinator/internal/buyer/server.go:3838-3844` (Go `n.String()` contains `.` -> reject).
- Issue: Swift's `JSONValue.parse` line 33-37 coerces any integer-valued
  Double (e.g. `1.0`) into `.int`, then `validateConstAndEnum` accepts
  it for `"type":"integer"` schemas. Go's `jsonSchemaScalarConforms` for
  `"integer"` explicitly rejects literals containing `.eE`. So a buyer
  schema `{"type":"integer","const":1.0}` is **accepted by the provider's
  parser, rejected by the coordinator's**. In production traffic
  (coordinator-fronted), the buyer always sees the coordinator's
  rejection -- but the existence of a provider parser that disagrees is a
  parity violation per SPEC section 7 "Provider and coordinator MUST use this
  identical algorithm." (The algorithm cited is for depth, but the section 7
  parity intent extends to the validator.)
- Recommendation: tighten Swift's integer conformance check to require
  the source token to lack a decimal/exponent character -- possibly by
  retaining the raw JSON literal alongside `.int`/`.double` in
  `JSONValue`. Simpler: parse schema literals via `StrictJSONParser`
  (which preserves the int/double distinction via the literal source) for
  the validator path, then match the Go semantics. Add a parity test
  fixture: `{"type":"integer","const":1.0}` MUST be rejected at both
  layers.

### Finding 7: `validateInstance` depth check runs on instance only; recursion in `validateInstanceNode` is unguarded

- Severity: **minor**
- Location: `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:23-28, 156-204`.
- Issue: `validateInstance` checks `jsonDepth(instance) <= maxDepth`
  upfront. Good. But `validateInstanceNode` then recurses with no
  depth tracking; it relies on the precondition. If a future caller
  invokes `validateInstanceNode` directly (e.g. a refactor splitting
  the validator), or if `jsonDepth` returns wrongly (Swift recursion in
  `jsonDepth` itself at line 209-211 has the same depth-32 stack frame
  cost), the contract holds today but is brittle. The instance walker
  also doesn't enforce a per-node child-count bound -- a 16 KiB schema
  with `properties` of 1 entry and an instance with thousands of
  unrelated keys would walk the unsupported-property check for each
  one before throwing on the first. Linear time, fine at v0.1.0 caps.
- Recommendation: pass `depth` through `validateInstanceNode`
  recursion and reject if exceeded. Document the precondition in a
  doc-comment so future refactors don't accidentally drop it.

### Finding 8: AC-25 receipt regression test exists; but it only varies `properties.age.type`, not the more brittle whitespace-equivalent schema case

- Severity: **Q**
- Location: `phase3-binary/Tests/macprovider-cliTests/HTTPServerStructuredOutputTests.swift:25-38`.
- Issue: the audit-prompt's blind-spot probe topic #4 asks whether
  whitespace-only-different schemas produce the same hash. The current
  AC-25 test changes a property type (`number` -> `integer`), which
  changes both bytes and semantics. It does NOT test the case where
  the buyer reformats the schema JSON (e.g. pretty-printed vs
  compact). The `PromptCanonicalizer` JCS-canonicalizes its inputs
  (which is the right thing -- JCS strips insignificant whitespace
  before hashing) but the SPEC section 9 "raw `response_format` JSON value
  as received" wording is ambiguous: does "raw" mean the bytes as sent
  over the wire, or the canonical-decoded value? The current IMPL
  implies the latter, which means a pretty-printed-vs-compact schema
  yields the **same** hash. That's defensible but not stated.
- Recommendation: (Q) -- clarify in SPEC section 9 / SPEC-015 section 1191-1204
  whether the prompt hash is over canonical bytes or raw bytes.
  Once clarified, add a positive test (equivalent compact vs pretty
  schemas -> same hash) or a negative test (different bytes -> different
  hash, including whitespace differences). No code change required if
  the SPEC author confirms canonical-bytes semantics.

### Finding 9: `parseStructuredJSONContent` only catches `let error as APIError` in the json_object depth subcase; but the bare-catch parity vs `validateStructuredCompletion` is missing

- Severity: **Q**
- Location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:955-987`.
- Issue: the `do { parsed = try StrictJSONParser.parse(content) } catch
  { throw APIError(...) }` block at line 956-968 maps any parser error
  (StrictJSONParser.ParseError) to a SPEC-019 envelope correctly. The
  subsequent `do { try JSONSchemaValidator.validateJSONObjectOrArray
  (parsed) } catch let error as APIError where error.code == ...`
  block has TYPED catches but no bare fallback `catch`. If
  `validateJSONObjectOrArray` ever started throwing a non-APIError
  (it currently does not), the bare error would propagate and HTTPServer's
  generic catch at `HTTPServer.swift:338` would emit a 503
  `model_not_loaded` -- wrong shape. This is a latent fragility, not a
  current bug. Today the validator only throws `APIError`.
- Recommendation: (Q for the implementer) -- would the team prefer a
  defensive bare `catch { throw <SPEC-019-shaped APIError> }` after the
  typed catches at line 971-984? It's belt-and-suspenders for the
  catch-all clause in SPEC section 5. Same applies at line 925-937 in
  `validateStructuredCompletion`. The current bare `catch` at 927-937
  does the right thing; the json_object subcase doesn't have an
  equivalent. Parity-fix.

### Finding 10: `parseStructuredJSONContent` for `json_object` depth-overflow rewrites the message but the `param` rebuild is dead code

- Severity: **minor**
- Location: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:974-984`.
- Issue: the catch at line 974 rebuilds the APIError with
  `param: error.param ?? ""`. But `validateJSONObjectOrArray` at
  `JSONSchemaValidator.swift:30-56` throws with `param: ""` already, so
  the `?? ""` fallback is dead code. Not a bug, just a hint that the
  IMPL author was hedging against a future change. Leave or simplify.
- Recommendation: simplify to `param: error.param` or remove the
  rebuild entirely and pass through `error`.

## Open questions (Q)

- Finding 8 -- SPEC section 9 wording: "raw `response_format` JSON value as
  received" vs canonical-bytes. Confirm with SPEC author.
- Finding 9 -- defensive bare catch on the json_object validation
  block. Style call.

## Notes for other lanes (so they don't redundant-file these)

- The `json_object` branch DOES accept both top-level object and array
  (`JSONSchemaValidator.swift:42-45`); the audit-prompt blind-spot
  probe topic #6 will report "no finding" if read carefully.
- Composite render order at the three hook sites
  (`ModelRuntime.swift:400`, `:454`, `:540`) is identical and correct:
  all three call `Self.userInput(for: request)` which is the single
  composition path through `StructuredOutputRenderer.prependResponseFormatInstruction`
  then `ToolPromptRenderer.renderMessages` at lines 899-909. The
  architect lane will land this -- no critic-side gap.
- AC-25 receipt-hash regression test exists at
  `HTTPServerStructuredOutputTests.swift:25-38`. Not a finding; the
  open question is the whitespace-equivalence semantics (Finding 8).
- NFC/NFD test exists at `JSONSchemaValidatorTests.swift:68-80` and
  uses raw UTF-8 byte sequences. The validator's `rawKey(in:matching:)`
  byte comparison at line 237-240 correctly handles this. The security
  lane will confirm; no critic-side gap.
- The validator has no force-unwrap `!` that could panic; the only `!`
  at line 134 is guarded at line 128. No panic catch-all gap found
  in the validator entry point itself; what IS missing is the WS-hop
  envelope discipline (Finding 1) which is a different failure mode
  than "validator panics."

## Verdict justification

CRITICAL Finding 1 alone blocks merge. The IMPL adds direct-HTTP-path
provider tests (`HTTPServerStructuredOutputTests.swift`,
`ModelRuntimeStructuredOutputTests.swift`) that prove the envelope is
correctly constructed at the throw site. The IMPL adds gateway
pass-through allow-list entries that prove the envelope survives the
**gateway->coordinator** hop on the response path. But the IMPL never
touched `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`,
which is the file that decides how validator errors crossing the
**provider->coordinator** WS hop are framed. Production traffic always
traverses that hop. So the envelope discipline the rest of the IMPL
painstakingly constructs is destroyed at the only hop that matters in
production. AC-18 / AC-26 / AC-30 are not actually met for
production traffic.

HIGH Findings 2 and 3 are coverage/parity gaps that don't block on
their own but compound the production reliability risk. The codex
lanes will likely catch the regex-parity drift on `Content-Encoding`
case-insensitive parsing; whether they catch the `isWhitespace`
parity drift (Finding 3) depends on whether the security or code
lane drills into the `strings.Map` predicate vs Swift's `Character`
property. Finding 2 (StrictJSONParser asymmetry) is exactly the kind
of "240-line attack surface with one caller" the audit prompt's
blind-spot probe topic #2 was steering toward; no other lane has
this exact lens.

MEDIUM Findings 4, 5, 6 are buyer-UX and parity gaps that should
land in absorption but wouldn't individually block.

To upgrade to READY TO MERGE: at minimum, resolve Finding 1
(WS-hop envelope) -- either fix `errorEndFrame` + `writeWSEndError`,
or add SPEC text explicitly grandfathering the WS-path envelope
collapse and document the buyer-facing impact. Finding 3 (`isWhitespace`
parity) and Finding 6 (`const` integer parity) are cheap one-line
fixes and should land in the same round.

I operated in THOROUGH mode throughout. No escalation to ADVERSARIAL
was needed -- the critical finding surfaced cleanly during the
WS-path trace probe (audit-prompt blind-spot topic #5, generalized
beyond "tester bypass" to "production WS hop"). Realist Check on
Finding 1: realistic worst case is buyers see generic 502
`provider_error` for what should be `malformed_json_response` /
`json_schema_validation_failed`, with `retryable` defaulting to
false (coordinator zero-value behavior at server.go:5276) and
`inference_ran:false` (server.go:5278). Buyer's SDK won't blindly
retry (good -- money-path-safe direction) but will report a
generic provider failure to the developer instead of the
actionable empty-content/schema-mismatch error. The billing /
breaker path is preserved (the FaultBreakerQualifying signal
still flows through the provider-side detection, just not via
the SPEC-019 code), so **this is NOT a money-path leak** -- it's
an envelope-discipline + buyer-UX gap. Confirmed CRITICAL because
multiple ACs explicitly assert the wire shape that this gap
destroys, not because of dollars. No downgrade.
