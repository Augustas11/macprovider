# SPEC-019 v0.2 IMPL — Round 2 audit prompt (per-lane)

You are auditing the SPEC-019 v0.2 IMPL after r1 absorption, at
worktree HEAD on branch `impl/spec-019-v0-2`. The audit anchor is
`68a86cd` (r1 absorption commit) plus the traceability commit on top.

r1 audit narrative: `specs/SPEC-019-v0_2-IMPL-r1-audit.md` (3C + 8H +
9M across 6 lanes). r1 absorption prompt:
`specs/ABSORB_SPEC_019_v0_2_IMPL_r1_PROMPT.md`.

## What changed in r1 absorption (commit 68a86cd)

Per the absorption commit message:

**Convergent (5 themes — must verify closure):**

- **T-1** 3-site 4-code allow-list. All three sites
  (`InferenceRelay.swift:529-554`, `server.go:5029-5037`,
  `chat_proxy.go:1076-1083`) now recognize the full 4-code SPEC-019
  set: `malformed_json_response`, `json_schema_validation_failed`,
  `response_byte_cap_exceeded`, `provider_timeout`. Per-site parity
  unit tests added. Tests in
  `phase3-binary/Tests/macprovider-cliTests/InferenceRelayStructuredOutputTests.swift`,
  `phase4-coordinator/internal/buyer/structured_output_ws_detail_test.go`,
  `phase5-gateway/internal/router/streaming_structured_output_test.go`.

- **T-2** Idle breach validates buffer-as-of-close. New file
  `phase3-binary/Tests/macprovider-cliTests/StreamingIdleTimeoutValidatesBufferTests.swift`.
  Idle-breach path in `ModelRuntime.swift` now reads
  `structuredAccumulator.content` and calls
  `validateStructuredStreamingCompletion` before throwing
  `provider_timeout` — if the buffer validates, returns success.

- **T-3** multipleOf scaled-integer + denormal pre-inference reject +
  saturation fail-closed. Validator in `JSONSchemaValidator.swift` +
  coord mirror in `server.go` `validateJSONSchemaNumericBounds` both
  reject sub-normal `multipleOf` at pre-inference. Runtime instance
  validation uses scaled-integer comparison when possible, falls back
  to FP with `quotient` saturation guard (`isFinite` + `|quotient| <=
  1e15`).

- **T-4** Gateway wall-clock zero-point moved to handler entry
  (`chat_proxy.go:70`, right after `start := s.now()`). Citation
  comment at line 66-69 cites AC-V2-9.

- **T-5** No-double-fire integration test added in
  `streaming_structured_output_test.go`. Asserts: provider terminal
  `provider_timeout` SSE → gateway forwards verbatim → no second
  terminal frame, no `outcome:"ok"` settle.

**Singular (7 items absorbed):**

- B-M-1: drainCancelled race — idle watcher does NOT call
  `token.fire()` on outer drain token; uses separate cancellation
  signal.
- D-M-1: AC-V2-14 fixture expanded with Qwen3 + Llama-3.3 + non-empty
  tool-history artifacts.
- D-M-2 + E-M-1: `pinned_versions.json` + `package-lock.json` added
  to both Cline + Vercel fixtures; `assert_fixture.py` asserts pinned
  versions. AC-V2-5 Cline assertion expanded to cover `required`,
  `additionalProperties`, numeric bounds.
- E-M-2: Inclusive-boundary cap test (`cap` exactly succeeds) +
  end-to-end wire coverage for `response_byte_cap_exceeded` and
  `provider_timeout` SSE pass-through.
- F-M-1: AC-V2-* citation comments at enforcement sites.
- F-M-2: SPEC citation comments at `2_097_152` cap + `60`s idle
  constants.
- F-M-3: `StreamingStructuredOutputTests.swift` renamed to
  `StrictJSONParserStreamingBufferTests.swift`.

**Smoke baseline after absorption:**
- phase3-binary swift: 638 tests / 7 skipped / 0 failures (+11 vs 627
  pre-absorption)
- phase4-coordinator: ok (391 tests counted)
- phase5-gateway: ok (206 tests counted)

## Anchors

- **IMPL under audit:** `git diff 521fe28..HEAD` from
  `/Users/augstar/macprovider-impl-spec-019-v0-2/` (or `git diff
  e5e9995..HEAD` for just the r1 absorption + traceability delta).
- **r1 narrative:** `specs/SPEC-019-v0_2-IMPL-r1-audit.md` — what r1
  found and how the absorption was scoped.
- **SPEC v0.2.4 LOCKED:** `specs/SPEC-019-structured-output.md`. AC-V2-*
  set is normative; do NOT propose SPEC edits.
- **IMPL prompt:** `specs/BUILD_SPEC_019_v0_2_IMPL_PROMPT.md` — what
  the IMPL was supposed to do.

## Lane charter

Each lane has a dual mandate:
1. **Verify r1 closures** — did each r1 finding actually close cleanly?
   Re-check the cited fix sites against the SPEC ACs they're supposed
   to satisfy.
2. **Fresh-surface audit** — does the r1 absorption introduce NEW
   findings? Each edit is a fresh audit surface; the wall-clock
   zero-point move, idle-breach buffer validation, and scaled-integer
   multipleOf math are all new risk surfaces.

### Lane A — Codex architect
- Verify T-1 4-code parity: each of the 3 sites carries all 4 codes,
  no asymmetry remains.
- Verify T-2 idle-breach buffer validation: the new control flow
  preserves AC-V2-9 (idle is one of two authorities, fire-once
  semantics).
- Verify T-4 wall-clock zero-point: gateway timeout context created at
  handler entry, threaded through downstream calls without
  double-creation.
- New surface: does the T-2 restructure of `withStructuredStreamingIdleTimeout`
  alter the relationship to the outer `withDrainCancellation` (B-M-1
  area)?

### Lane B — Codex code
- Citation accuracy: each AC-V2-* comment cites the right file:line,
  the right AC.
- Constant pinning: `2_097_152` cap and `60` idle still satisfy SPEC
  requirements; constants are not silently widened.
- Test discoverability: file-rename + new test files (singular S-*
  + convergent T-2/T-5) — do they live where a maintainer would expect?
- T-3 multipleOf math: review the scaled-integer path for edge cases
  not yet tested (negative integers, very-large integer values,
  integer overflow if `Int(numeric)` casting silently truncates).

### Lane C — Codex security
- Money-path table re-verification: every entry from the lane C
  charter in r1 must hold. Specifically — does the 4-code allow-list
  parity actually produce buyer-visible terminal codes for
  `response_byte_cap_exceeded` and `provider_timeout` end-to-end? Trace
  one of those codes from provider → coord SSE → gateway → buyer.
- T-4 wall-clock relocation: does moving the timeout context to
  request entry open any new race (e.g., the timeout fires before
  quota reservation completes, leaving an orphaned reservation)?
- T-2 idle-breach buffer validation: can a buyer craft a schema that
  ALWAYS validates against any partial buffer (e.g., `additionalProperties:true`
  + no `required`) and use that to mask an idle timeout as success?
- Fixture version assertions in CI: can a buyer / attacker influence
  what gets asserted? (Unlikely, but worth checking.)

### Lane D — Codex product-design
- AC-V2-5 Cline fixture: now asserts pinned versions + `required` +
  `additionalProperties` + numeric bounds. Does the captured body
  reflect a REAL live Cline invocation, or is it still hand-crafted
  to satisfy the AC?
- AC-V2-12 Vercel fixture: `pinned_versions.json` + assertions —
  buildable end-to-end against a live `ai@<pin>` install?
- AC-V2-13 partial-content negative streaming: does the fixture set
  cover BOTH Cline AND Vercel (conjunctive per r1 SPEC absorption +
  D-r1-M-1)?
- AC-V2-14 composite-render: Qwen3 + Llama-3.3 + tool-history
  artifacts present. Are byte-equivalent assertions enforced for ALL
  family x tool-history combinations?

### Lane E — Claude critic (blind-spot adversarial)
- Hostile read of the r1 absorption diff (`git diff e5e9995..HEAD`).
  Each new test file, each new helper — is it actually testing what
  the SPEC requires, or just the IMPL's current behavior?
- T-1 4-code parity: are the tests asserting WIRE-LEVEL byte
  equivalence (the SSE frame the buyer would actually see), or just
  internal function output? End-to-end coverage gap if internal-only.
- T-2 idle-breach buffer validation: what's the wall-clock cost of
  the validation pass after idle breach? If validation takes >N
  seconds itself, can it trip the gateway's 300s wall-clock and emit
  a second terminal frame anyway?
- Schema-validation determinism: is `validateStructuredStreamingCompletion`
  pure / idempotent enough that calling it once during normal streaming
  end + once during idle breach won't double-charge or double-emit?
- New citation comments — do they actually point at the right SPEC
  section, or are they decorative?

### Lane F — Claude narrative (blind-spot continuity)
- Commit message accuracy: `68a86cd` claims 638 tests / 7 skipped /
  0 failures, 391 + 206 go tests. Verify those counts hold against
  current HEAD.
- r1 audit narrative ↔ r1 absorption commit message ↔ IMPL diff:
  every item claimed in the absorption commit message has a
  corresponding IMPL artifact and a corresponding test artifact?
- Test naming consistency: do the new tests follow the pattern from
  the existing test files (e.g.,
  `TestStreaming<Feature><Expectation>` for Go,
  `test<Component><Behavior>` for Swift)?
- Citation traceability: grep `AC-V2` across the IMPL diff. Is
  coverage now adequate for a future maintainer to navigate from
  SPEC → IMPL?

## Output format

Same per-lane format as r1:

```
# SPEC-019 v0.2 IMPL r2 audit — lane <X>

## Verdict
<READY TO LOCK | NEEDS REVISION>

## CRITICAL (N)
## HIGH (N)
## MEDIUM (N)
## Notes (N) [optional]
```

**Bar:** 0 CRITICAL + 0 HIGH + 0 MEDIUM. Do NOT edit files. Do NOT
propose SPEC edits. Constrain to IMPL surface only.
