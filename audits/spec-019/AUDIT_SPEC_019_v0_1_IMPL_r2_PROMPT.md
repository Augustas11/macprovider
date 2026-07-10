# SPEC-019 v0.1.5 IMPL — round-2 defensive audit (TIGHT)

Audit SPEC-019 v0.1.5 IMPL at HEAD `1bad28c` on branch
`impl/spec-019-v0-1` (worktree
`/Users/augstar/macprovider-impl-spec-019-v0-1`).

**Defensive round** after r1 absorbed 2 CRITICAL + 7 HIGH + 8 MEDIUM +
4 minor across 8 themed blocks. r1 narrative at
`specs/SPEC-019-v0_1-IMPL-r1-audit.md`; r1 per-lane findings at
`specs/SPEC-019-v0_1-IMPL-{lane}-r1-audit.md`; absorption directive
at `specs/SPEC-019-v0_1-IMPL-r1-FIX-PROMPT.md`.

Smoke baseline: 617 swift tests / 0 failures (was 609 pre-r1, +8 new),
Go coordinator + gateway green.

Two tasks:

1. **Closure verification** of your r1 findings.
2. **Regression probing**: r1 absorption modified 15 files and added 3
   new test files. Look for blind spots introduced by the absorption
   itself — depth-bound parser regression on valid deep input,
   Content-Encoding empty-trim breaking legitimate omitted-header
   request, allow-list extension allowing unintended code class to
   pass through, etc.

Bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM** across all 6 lanes = READY TO
MERGE → IMPL PR opens.

## What changed in `1bad28c` (only this commit's delta)

8 themed blocks per `specs/SPEC-019-v0_1-IMPL-r1-FIX-PROMPT.md`:

- A. WS hop allow-list extension: `InferenceRelay.swift:529` (provider
  side); messages.go updated for serialization.
- B. Coordinator HTTP allow-list + classification: `server.go:4915` +
  `:1857-1928` extended to recognize SPEC-019 codes and mark
  `FaultBreakerQualifying`.
- C. New end-to-end test files:
  - `phase3-binary/Tests/macprovider-cliTests/InferenceRelayStructuredOutputTests.swift`
  - `phase4-coordinator/internal/buyer/structured_output_provider_error_test.go`
- D. Depth-bound parser: `StrictJSONParser.swift` `parseValue` /
  `parseObject` / `parseArray` thread `depth: Int`; throws
  `json_schema_validation_failed` 502 if depth > 32. Module-level
  comment added.
  - New tests: `StrictJSONParserDepthTests.swift`
  - End-to-end test in `ModelRuntimeStructuredOutputTests.swift` for
    33-deep model output.
- E. Empty-trim `Content-Encoding` reject at all 3 layers; gateway test
  inverted.
- F. Whitespace-strip parity: ASCII-only at Swift + Go (NBSP not
  stripped).
- G. Gateway preserves AC-20 streaming-reject envelope.
- H. MEDIUMs:
  - `1.0` rejected for integer schema (Swift now matches Go).
  - `json_object` breaking-change error message extended with
    migration path.
  - Full 14-keyword reject enumeration at both Swift + Go.
  - Go name-regex test parity matrix added.
  - Vercel/OpenAI fixture READMEs polished.
  - Whitespace-only completion → `retryable:false`.
  - StructuredOutputRenderer.swift module comment added.

## Authoritative inputs

1. `specs/SPEC-019-structured-output.md` — v0.1.5 LOCKED.
2. Current code state at `1bad28c`.
3. r1 per-lane audit files + r1 narrative + r1 absorption directive.

## Per-lane lens

### Architect

**Closure check**: Architect r1 had 1 CRITICAL (C-1):
- Coordinator HTTP path drops SPEC-019 codes before money-path
  classification. CLOSED in v0.1.3 by extending `spec001EndStatus` at
  `server.go:4915` AND adding FaultBreakerQualifying classification at
  `server.go:1857-1928`. Verify both edits land cleanly.

**Regression probe**:
- The HTTP path now treats SPEC-019 codes as terminal (no retry/failover).
  Verify this doesn't accidentally apply to other 502s that SHOULD
  retry — i.e., the classification only matches `malformed_json_response`
  and `json_schema_validation_failed`, not e.g. `error_internal`.
- WS hop allow-list extension: does the new allow-list at
  `InferenceRelay.swift:529` + `messages.go` correctly serialize the
  `retryable` flag from the SPEC-019 envelope across the WS frame?
  Or does the frame use a fixed retryable value per code?
- Gateway preserves the new streaming-reject codes — are these on the
  pass-through allow-list at `chat_proxy.go`, separate from the
  post-inference detail codes?

### Code

**Closure check**: Code r1 had 1 HIGH (H-1) + 1 MEDIUM (M-1) + 2 LOW (L1/L2):
- H-1 (depth-bound parser): CLOSED — verify `parseValue` / `parseObject`
  / `parseArray` all carry the `depth: Int` parameter and bail BEFORE
  recursing past 32.
- M-1 (empty-trim Content-Encoding): CLOSED at all 3 layers.
- L1 (rejected-keyword enumeration): CLOSED — verify the test file
  enumerates all 14 keywords explicitly (`oneOf, anyOf, allOf, not,
  $ref, $defs, pattern, format, minimum, maximum, multipleOf,
  minItems, maxItems, uniqueItems`).
- L2 (Go name-regex parity): CLOSED — verify table cases include
  `person-v1` accepted + `person.v1` / `Café` / 65-byte / `name\nINJECT`
  rejected.

**Regression probe**:
- New depth-counter signature: every recursive caller of
  `parseValue` / `parseObject` / `parseArray` must pass the correct
  depth. Grep for ALL call sites and verify none is missing a
  `depth + 1` increment or pass-through.
- 14-keyword enumeration: does the test for `format` actually trip
  because v0.1.0 explicitly rejects it, or does it pass because the
  validator silently treats `format` as an unknown allow-list miss?
- Whitespace-only completion classification — is the trim function
  ASCII-only or does it accidentally strip Unicode whitespace? Verify
  parity with §F's Content-Encoding normalization decision.
- Did the absorption touch `JSONSchemaValidator.swift` in a way that
  affects schema-side validation (which was already PASS in r1)?
  Spot-check.

### Security

**Closure check**: Security r1 had 2 HIGHs (SEC-1, SEC-2):
- SEC-1 (StrictJSONParser depth): CLOSED — verify the depth bound is
  THROWN before recursion (not after).
- SEC-2 (coordinator HTTP drops codes): CLOSED — verify the new
  classification path actually emits `FaultBreakerQualifying`.

**Regression probe**:
- `FaultBreakerQualifying` is a billing-side flag. Verify the new
  classification at `server.go:1857-1928` writes the flag to the
  request log AND that the billing formula at `formula.go:112` honors
  it.
- Allow-list at `spec001EndStatus`: does adding SPEC-019 codes to the
  same list as legacy codes accidentally cause them to be treated as
  legacy in any other code path? Grep for all consumers of
  `spec001EndStatus`.
- Depth-bound parser: is the cap 32 the same constant used everywhere
  (`JSONSchemaValidator.maxDepth`)? Or did someone hardcode `32`
  somewhere that could drift?
- WS frame serialization: does the new `messages.go` change permit a
  malicious provider to send back ANY error code in the new allow-list
  format (including future codes the coordinator doesn't recognize)?
  Should the coordinator have an explicit "only accept known codes"
  validation step, or is allow-list sufficient?

### Product-design

**Closure check**: PD r1 had 1 HIGH (PD-H1) + 1 MEDIUM (PD-M1):
- PD-H1 (gateway preserves AC-20 envelope): CLOSED — verify the
  gateway's pass-through allow-list now includes streaming-reject
  codes and the envelope shape is preserved verbatim.
- PD-M1 (json_object migration message): CLOSED — verify both empty-
  content and malformed-JSON messages include the migration hint.

**Regression probe**:
- The new json_object error message is longer. Does it still fit
  within any HTTP error envelope size constraint? Sanity check.
- Whitespace-only completion `retryable:false`: this is now the
  fail-fast posture. Is there a legitimate buyer use case for
  expecting whitespace-only output? (e.g., a buyer might WANT to
  retry because the model temporarily emitted whitespace.) The SPEC
  says `retryable:false` for `""` empty content per §5 override.
  Does treating whitespace-only the same break any AC?

### Critic (Claude blind-spot)

**Closure check**: Critic r1 had 1 CRITICAL + 2 HIGH + 3 MEDIUM:
- C-1 (WS hop): CLOSED — verify InferenceRelay r1 fix.
- H-1 (depth-bound parser): CLOSED.
- H-2 (Content-Encoding whitespace parity): CLOSED.
- M-1 to M-4: should all be addressed by H.5–H.7 in fix prompt.

**Fresh blind-spot probe**:

- The depth-bound `parseValue(depth:)` signature — what if internal
  helpers like `parseString` or `parseNumber` recurse internally
  (e.g., for nested escape sequences)? Those wouldn't increment
  depth. Read the parser source carefully.
- WS frame allow-list extension: are SPEC-019 codes serialized as a
  buyer-visible code (preserving the original `malformed_json_response`
  string) OR are they translated to a legacy code on the wire and
  reconstituted on the other side? If translated, debugging is
  harder.
- `FaultBreakerQualifying` is set at coordinator. But the WS hop
  passes codes through `InferenceRelay`. Does the provider also
  record a request-log entry with the right fault flag, or only the
  coordinator? If only coordinator, that's correct (per architecture)
  but verify.
- Empty-content vs whitespace-only: both are now `retryable:false`.
  But what about content that is JSON-parseable as `null` (the JSON
  null literal)? Per SPEC §5 + AC, `null` is a valid JSON value but
  doesn't satisfy any object schema. Is this `malformed_json_response`
  (parse-fail) or `json_schema_validation_failed` (parse-OK, validate-
  fail)? It should be the latter. Verify.
- Receipt regression: did the absorption touch
  `PromptCanonicalizer.swift` even accidentally? AC-25 receipt-hash
  regression must still hold. Grep diff.
- Coordinator allow-list at `spec001EndStatus`: is the constant
  `error_internal` still treated as a fallback if a non-SPEC-019
  unknown code arrives? Could a malicious provider send an
  `error_too_bad_to_classify` and bypass the allow-list?

### Narrative (Claude blind-spot)

**Closure check**: Narrative r1 had 1 HIGH + 3 MEDIUM + 1 minor:
- H-1 (StrictJSONParser missing rationale): CLOSED — verify the
  module-level comment exists and is informative.
- M-1 (Vercel README): CLOSED — verify
  `supportsStructuredOutputs:true` instruction and `$schema` strip
  steps are documented.
- M-2 (commit `7b2a272` AC anchors): NOT FIXED — the commit is
  already shipped; absorption commit message should anchor ACs
  retroactively.
- M-3 (StructuredOutputRenderer module comment): CLOSED — verify.

**Fresh narrative probe**:
- Absorption commit message at `1bad28c` — is it coherent? Does it
  thread the story from CRITICAL fixes through MEDIUMs?
- New test files have clear names? `InferenceRelayStructuredOutputTests.swift`
  is clear; `StrictJSONParserDepthTests.swift` is clear; the new Go
  file `structured_output_provider_error_test.go` is clear.
- Does the IMPL diff chain now read as: provider boundary → coordinator
  boundary → gateway boundary → absorption? Or has it become tangled?
- Are there any TODO / FIXME comments left in the absorption that
  should be addressed before PR?

## Output format

Write findings to `specs/SPEC-019-v0_1-IMPL-{lane}-r2-audit.md`:

```
**Verdict:** {READY TO MERGE | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified
- r1 C-1: CLOSED (cite file:line) | PARTIAL | REGRESSED
- r1 H-1: ...

## Fresh findings
{if any, under None. if 0/0/0}

## Verdict justification
```

Bar: 0/0/0 across all 6 = READY TO MERGE → IMPL PR opens. If 0/0/0
across all 6, no r3 IMPL needed (matches SPEC-018 IMPL pattern where
r3 surfaced a convergent CRITICAL; if r2 returns clean here, we're
done).
