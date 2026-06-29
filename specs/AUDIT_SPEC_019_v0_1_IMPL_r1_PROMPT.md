# SPEC-019 v0.1.5 IMPL — round-1 audit (TIGHT)

Audit the SPEC-019 v0.1.5 IMPL at HEAD `1a6e00f` on branch
`impl/spec-019-v0-1` (worktree `/Users/augstar/macprovider-impl-spec-019-v0-1`).

This is the first audit round of a freshly-shipped IMPL. Bar:
**0 CRITICAL + 0 HIGH + 0 MEDIUM** before the IMPL PR opens. Findings
get absorbed and another round fires.

## What you are auditing

3 commits on top of SPEC-019 v0.1.5 LOCKED (`608ab22` = PR #218 merge):

```
1a6e00f  Validate SPEC-019 Content-Encoding at gateway boundary (+459)
eaa907d  Validate SPEC-019 response formats at coordinator boundary (+419)
7b2a272  Support SPEC-019 structured output at provider boundary (+1882)
608ab22  spec(019): v0.1.5 LOCKED (#218)
```

Smoke baseline:
- `cd phase3-binary && swift test` → **609 tests, 0 failures, 7 skipped, 44.4s** (was 578 pre-IMPL).
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` → ok 1.97s.
- `cd phase5-gateway && go test -count=1 ./internal/router` → ok 3.00s.

Files of interest (new + modified):

Provider:
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift` (modified, +ResponseFormat.jsonSchema enum + parser)
- `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift` (NEW, 307 lines)
- `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift` (NEW, 241 lines)
- `phase3-binary/Sources/MacProviderCore/JSONValue.swift` (modified)
- `phase3-binary/Sources/macprovider-cli/StructuredOutputRenderer.swift` (NEW, 122 lines)
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` (Content-Encoding 415 + streaming reject)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (composite render + post-hoc validation)
- 5 new test files under `phase3-binary/Tests/macprovider-cliTests/`
- `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC019/{qwen3,llama33}_schema_instruction.txt`

Coordinator:
- `phase4-coordinator/internal/buyer/server.go` (modified, +allowlist + mirror validation)
- `phase4-coordinator/internal/buyer/structured_output_validation_test.go` (NEW)

Gateway:
- `phase5-gateway/internal/router/chat_proxy.go` (Content-Encoding gate + pass-through allow-list)
- `phase5-gateway/internal/router/server.go` (modified)
- `phase5-gateway/internal/router/structured_output_test.go` (NEW)

Integration fixtures (under `test/integration/spec_019/`):
- `openai_python_strict_json_schema/`
- `vercel_ai_sdk_strict_json_schema/`
- `nfc_nfd_adversarial/`

## Authoritative inputs

1. `specs/SPEC-019-structured-output.md` — v0.1.5 LOCKED. Every IMPL claim
   must trace to an AC.
2. `specs/BUILD_SPEC_019_v0_1_IMPL_PROMPT.md` — drafter's directive.
3. `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — the precondition.
4. `specs/SPEC-015-receipts.md` — canonical-prompt JCS scope (no IMPL
   change, but AC-25 prompt-hash regression must hold).
5. Current code state at `1a6e00f`.

## Per-lane lens

You are ONE of these lanes. Stay in your lens.

### Architect

- Cross-spec consistency: does the IMPL match SPEC-019 v0.1.5 §1 cross-spec
  amendments (SPEC-001 supersession, SPEC-006 normalization carve-out)?
  Cite both directions.
- Money-path posture: trace every post-inference failure path
  (`malformed_json_response`, `json_schema_validation_failed`, validator
  panic catch-all). Does each reach `FaultBreakerQualifying` at
  `phase4-coordinator/internal/buyer/billing_recorder.go:181-183` +
  `phase4-coordinator/internal/billing/formula.go:112-114`? Or do any
  fall through to a generic 500 / partial-settle path?
- Composite render order: SPEC §4 normative order is
  schema-adjusted ChatMessage → ToolPromptRenderer.renderMessages →
  UserInput. Verify `ModelRuntime.swift` at the three hook sites
  (`:400`, `:454`, `:540`) follows this exact order. Verify renderer
  is stateless (no in-process cache).
- Receipt binding: AC-25 requires prompt-hash to change when any byte
  of `response_format.json_schema.schema` changes. SPEC-015 §1191-1204
  already covers `response_format` in canonical prompt. Verify the IMPL
  did NOT change `PromptCanonicalizer.swift` and that there's a
  regression test proving the hash changes.
- Gateway double-settlement prevention: gateway must NOT call
  `settleBeforeResponse` for `malformed_json_response` /
  `json_schema_validation_failed` (already settled by coordinator).

### Code

- Citations: every code path the IMPL claims (per the per-commit message
  or the SPEC AC) must exist at the cited file:line in current HEAD.
  Spot-check at minimum: provider parser at
  `ChatCompletionRequest.swift`, validator at
  `JSONSchemaValidator.swift`, renderer at
  `StructuredOutputRenderer.swift`, hook integration at
  `ModelRuntime.swift`, coordinator at `server.go`, gateway at
  `chat_proxy.go`.
- Schema-subset grammar (SPEC §3): verify the validator's reject list
  matches SPEC §3 exactly. Allowed: `type`, `properties`, `required`,
  `items`, `enum`, `const`, `additionalProperties:false`, `title`,
  `description`. Reject: `oneOf`, `anyOf`, `allOf`, `not`, `$ref`,
  `$defs`, `pattern`, `format`, `minimum`, `maximum`, `multipleOf`,
  `minItems`, `maxItems`, `uniqueItems`, `$schema`. Anything missing
  from the IMPL reject list is a buyer-visible footgun.
- Depth-counting algorithm: SPEC §6 specifies the recursive walk
  (root=1; each nested `properties[*]`/`items`/`additionalProperties`
  +1; siblings same level do not increment). Verify the IMPL's depth
  walker matches.
- Byte-cap algorithm: SPEC AC-7 + §6 — schema bytes counted over the
  raw request-body bytes (including insignificant whitespace inside
  that value), NOT a compacted post-parse serialization. Verify.
- Name regex: anchored `^[A-Za-z0-9_-]{1,64}$`. Verify Swift regex AND
  Go regex both use the anchored, case-sensitive byte-count form.
  Verify `person-v1` accepted; `person.v1` / `Café` / 65-byte /
  `name\nINJECT` rejected.
- Error envelope: SPEC §5 error-codes table lists ~24 codes. Spot-check
  10 of them are wired into `APIError.retryableByCode` and have the
  right HTTP status mapping. Flag any missing.
- Empty-content classification: SPEC §5 says empty `""` after
  stop-token filtering is `malformed_json_response` with
  `retryable:false` override + actionable message. Verify the IMPL's
  empty-content branch uses `retryable:false` (NOT the default
  `retryable:true` for the same code).
- Validator panic catch-all (SPEC §5): every postprocess failure mode
  MUST be caught. Look at the validator entry point and trace what
  happens on a synthetic panic / OOM / recursion overflow. If there's
  no `do { try ... } catch { /* terminal 502 */ }` wrapper, that's a
  HIGH.
- Content-Encoding gate (SPEC §7, AC-28a): three layers — provider
  HTTPServer, coordinator server, gateway chat_proxy. Verify all three
  reject non-`identity` with HTTP 415 + identical envelope shape.
  Verify case-insensitive `identity`, whitespace-tolerant. Multi-value
  `identity, gzip` MUST reject (not exactly `identity`).
- Test adequacy: 31 net new Swift tests. Spot-check: do the new tests
  cover SPEC ACs 1-34? Any AC without a test is a coverage gap.

### Security

- Prompt-injection surface (SPEC §3, AC-23, AC-33 / §4 untrusted-data
  list): hostile strings in `json_schema.name`, `description`, property
  descriptions, enum values, const values — verify the renderer escapes
  them so they cannot terminate the schema instruction block or inject
  system role text. Look at `StructuredOutputRenderer.swift` rendering
  logic; if it does string concatenation without escape, that's a
  HIGH.
- Name regex DoS: anchored `[A-Za-z0-9_-]{1,64}$` — verify the regex
  is not vulnerable to ReDoS (it shouldn't be — alternation-free,
  bounded length, no backtracking). Confirm both Swift `NSRegularExpression`
  and Go `regexp` compile and run in linear time.
- Schema-validator DoS: at 16 KiB schema cap + 32-depth cap, can a
  valid-but-pathological schema (e.g. 16 KiB of nested object schemas
  at depth 32 with thousands of `properties` keys at one level) drive
  the validator superlinear? Read the validator's walk function and
  trace complexity.
- Money-path leak through validator panic: SPEC §5 catch-all is
  normative. Verify the IMPL's validator runs inside a panic-safe
  boundary (Swift: `do/try/catch`; or for `JSONSerialization` errors
  caught explicitly; for runtime aborts there's no recover, so the
  question is whether an aborted handler still produces a structured
  error or an empty 500). If empty 500, that's CRITICAL.
- NFC/NFD: AC-9 requires byte-distinct key comparison (no Unicode
  normalization). Swift `String ==` does NFC-normalized comparison
  silently. The validator MUST compare by raw UTF-8 byte sequence.
  Verify `JSONSchemaValidator.swift` uses `.utf8` byte comparison
  (or an equivalent) for property names. If it uses `String ==`,
  HIGH.
- Coordinator parity: SPEC §7 requires coordinator AND provider
  enforce identical name regex / subset grammar / depth cap / byte
  cap. Verify the Go `server.go` regex is byte-identical to the
  Swift one. A drift = bypass via coordinator-direct path.
- Settlement double-attribution: SPEC §7 says gateway MUST NOT
  `settleBeforeResponse` on the two new detail codes. Trace
  `chat_proxy.go` and verify the new codes are excluded from any
  re-settle path.
- Content-Encoding case-folding: `Content-Encoding: Identity`,
  `IDENTITY`, `iDeNtItY` MUST accept; `gzip`, `Gzip`, `identity,
  gzip`, ` identity ` (after trim) — verify each layer treats them
  consistently.

### Product-design

- AC-30/AC-31 paired fixture: verify the openai-python fixture +
  Vercel Zod fixture both use `Person { name: str, age: float }` and
  the captured request bodies actually JCS-match modulo
  `title`/`description`/`$schema`. The fixtures are committed under
  `test/integration/spec_019/`; verify both are present and the README
  files explain the `$schema` strip step for Vercel.
- Buyer-facing error codes: SPEC §5 lists 17 new codes. Are the
  error messages actionable for a buyer reading them in their SDK
  exception? Sample 5 codes and assess message clarity.
- `json_object` breaking-change migration: SPEC §1 labels this as a
  breaking change for buyers currently using `json_object` as a silent
  no-op. Does the IMPL produce a buyer-visible error message that
  points them to omitted or `{"type":"text"}` for prose? Read the
  empty-content + malformed-JSON message text.
- Cline negative regression: AC-N (per SPEC §10 "v0.1.0 NOT Cline drop-in")
  — verify Cline-style `streamText` request WITHOUT `response_format`
  is unaffected. The IMPL should NOT have changed any code path that
  fires when `response_format == .text`.
- Empty-content `retryable:false` + actionable message: verify the
  literal message says `temperature` / `seed` (not `max_tokens`). The
  SPEC §5 wording was specifically corrected at r3 absorption from
  `max_tokens` to `temperature`/`seed`.
- Streaming reject envelope: SPEC AC-19/AC-20 says
  `type:"invalid_request_error"`, `param:"stream"`, `retryable:false`,
  `inference_ran:false`, `settlement_ran:false`. Verify the IMPL's
  streaming-reject envelope matches.

### Claude critic (blind-spot)

The 4 codex lanes are covering architecture, code correctness,
security, and product-design. Look for what they MISS.

Reasonable probe topics:

- Concurrency: the stateless renderer is normative. But Swift's
  static dispatch may share state via class-level singletons or actor
  isolation. Read `StructuredOutputRenderer.swift` — is it actually
  stateless, or does it carry a per-call cache that crosses requests?
- StrictJSONParser (NEW, 241 lines): why does this exist? The IMPL
  drafter chose to write a strict parser rather than use Swift's
  `JSONSerialization`. What does "strict" mean here — duplicate-key
  rejection? Trailing-comma rejection? Number canonicalization? If
  it's parsing both schema validation input AND model output, are the
  semantics consistent across both?
- Composite render with empty tool history: SPEC §4 short-circuit
  semantics says `ToolPromptRenderer.renderMessages` is a no-op when
  `containsMultiTurnToolData == false`. The IMPL composite must
  preserve the schema instruction in both branches. Read fixtures —
  is there a test for the empty-tool-history path that doesn't trip
  up the schema-injection logic?
- Receipt regression: AC-25 says prompt-hash changes when schema
  bytes change. But it doesn't say the hash MUST be identical for
  semantically-equivalent schemas with different whitespace. The
  current PromptCanonicalizer JCS-canonicalizes — does it strip
  whitespace? If yes, AC-25 might pass for byte-level changes but
  fail for whitespace-only changes (which arguably should produce
  the same hash). What did the IMPL actually do?
- Provider Content-Encoding gate: provider HTTP server adds the gate,
  but the provider is reachable on the local network. If a buyer
  bypasses the gateway entirely (which Cline can't do, but a tester
  can), the provider gate is the only defense. Verify the gate is
  enforced regardless of how the request arrived.
- Empty completion vs only-whitespace completion: SPEC §5 says empty
  `""` after stop-token filtering. What if the model emits `"   \n"`
  (only whitespace)? Is that "empty" for the override? Or does it
  parse as malformed JSON and get `retryable:true`?
- `json_object` enforcement: SPEC §1 says `json_object` accepts
  top-level object OR array. The IMPL needs to parse and check both
  branches. Verify the IMPL's `json_object` enforcement accepts both
  shapes, not just object.

### Claude narrative (blind-spot)

Document-quality lens for the IMPL. Read the 3 commit messages and
ask:

- Does the chain (provider → coordinator → gateway) tell the IMPL
  story coherently for a PR reviewer? Commit messages should make
  the surface clear.
- Are the new test files named for the AC they cover, or are they
  named arbitrarily? `JSONSchemaValidatorTests.swift` is clear;
  `ModelRuntimeStructuredOutputTests.swift` is clear; but check the
  others.
- Are the integration fixture READMEs clear about what they prove?
  Especially the `vercel_ai_sdk_strict_json_schema` README — does it
  explain the `$schema` strip step and why Vercel needs the
  `supportsStructuredOutputs:true` setting?
- The new `StrictJSONParser.swift` is 241 lines — does it have a
  module-level comment explaining why it exists, or is the rationale
  buried in the implementer's head?

## Output format

Write findings to `specs/SPEC-019-v0_1-IMPL-{lane}-r1-audit.md` where
`{lane}` is your lane name verbatim: `architect`, `code`, `security`,
`product-design`, `critic`, `narrative`.

```
**Verdict:** {READY TO MERGE | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Findings

### Finding 1: <title>
- Severity: {CRITICAL | HIGH | MEDIUM | minor | Q}
- Location: file:line in current HEAD, or SPEC §X
- Issue: one paragraph
- Recommendation: what to change
```

If 0/0/0, write "No findings." under Findings header.

Severity scale:

- CRITICAL: money-path regression, cross-spec contradiction, panic
  catch-all gap that leaks empty 500, breaks an AC in a way that
  bypasses settlement.
- HIGH: AC not implemented or implemented wrong; coordinator/provider
  parity drift; envelope discipline gap; test missing for a money-path
  AC.
- MEDIUM: edge case not covered by test; wording in error message
  unclear; minor coverage gap.
- minor: typos, formatting.
- Q: question for the implementer, not a defect.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes = READY TO
MERGE → IMPL PR opens.
