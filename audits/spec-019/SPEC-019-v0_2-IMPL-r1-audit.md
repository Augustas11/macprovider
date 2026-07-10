# SPEC-019 v0.2 IMPL — Round 1 audit narrative

**Anchor:** `impl/spec-019-v0-2` @ `e5e9995`
**Audited IMPL:** `git diff 521fe28..HEAD` (3 commits: `21cd08e` codex IMPL + `edd6f48` prompt + `e5e9995` pre-audit gateway guard)
**Round:** r1
**Lanes:** 4 codex (architect, code, security, product-design) + 2 Claude blind-spot (critic, narrative)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect (codex) | NEEDS REVISION | 0 | 2 | 1 |
| B code (codex) | NEEDS REVISION | 0 | 1 | 1 |
| C security (codex) | NEEDS REVISION | 0 | 2 | 0 |
| D product-design (codex) | NEEDS REVISION | 0 | 0 | 2 |
| E critic (Claude, adversarial) | NEEDS REVISION | **3** | 2 | 2 |
| F narrative (Claude) | NEEDS REVISION | 0 | 1 | 3 |

**Totals: 3 CRITICAL, 8 HIGH, 9 MEDIUM.** No READY lanes.

## Convergent themes

### T-1: 3-site 2-code-vs-4-code allow-list asymmetry (3 CRITICAL — 5 lanes)

E-C-1 + E-C-3 + A-H-1 + A-H-2 + B-H-1 + C-H-1 + C-H-2 + F-H-1.

The IMPL recognizes 4 SPEC-019 terminal codes (`malformed_json_response`,
`json_schema_validation_failed`, `response_byte_cap_exceeded`,
`provider_timeout`) at SOME sites but only 2 at the WS hop + at the
gateway pass-through allow-list. Net result: provider-emitted
`provider_timeout` (idle breach) and `response_byte_cap_exceeded`
(cap breach) never reach the buyer with the SPEC-mandated code.

Three asymmetric sites:

1. **Provider WS frame** —
   `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529-554`.
   `errorEndFrame` switch only maps `malformed_json_response` and
   `json_schema_validation_failed`; everything else falls through to
   `status:"error_internal"`. `provider_timeout` thrown by
   `withStructuredStreamingIdleTimeout` (`ModelRuntime.swift:1147`) and
   `response_byte_cap_exceeded` thrown by
   `StructuredStreamingContentAccumulator.append`
   (`ModelRuntime.swift:80`) are both downgraded to `error_internal`.

2. **Coord WS detail-code allow-list** —
   `phase4-coordinator/internal/buyer/server.go:5029-5037`
   `isSpec019ProviderDetailCode`. Only handles 2 codes. Even if the
   provider WS frame carried the right status (after T-1.a fix),
   coord wouldn't recognize it as a SPEC-019 detail-code path.

3. **Gateway terminal-SSE allow-list** —
   `phase5-gateway/internal/router/chat_proxy.go:1076-1083`
   `isSpec019TerminalSSEErrorCode`. Only handles 2 codes. A coord-
   emitted terminal SSE with `code:"response_byte_cap_exceeded"` falls
   into `streamingCompletionDeltaBytes` (line 541), hits the
   `!hasChoices` branch at line 576-585, and is remapped to
   `stream_malformed` via `writeSSEError(...)`. Outcome
   `stream_malformed` is settled. AC-V2-3a violated.

**Resolution (Decision 1A — locked-in design call):**

Single canonical 4-code set, replicated at all 3 sites. Each site MUST
match SPEC-019 v0.2.4 §5 terminal-code table (4 codes). Add per-site
unit tests asserting the 4-code parity. Use comments at each site
citing AC-V2-3a + AC-V2-9 + AC-V2-9b as the normative source.

### T-2: AC-V2-9 idle breach discards buffer-as-of-close (1 CRITICAL — Lane E)

E-C-2.

SPEC §AC-V2-9 normative text: *"On idle breach: end-of-stream validation
runs on the buffer-as-of-close; the streaming SSE `provider_timeout`
emit path at `phase4-coordinator/internal/buyer/server.go:2386`
carries the terminal frame"*.

IMPL `withStructuredStreamingIdleTimeout`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1105-1145`)
instead `token.fire()`s and throws `structuredStreamingProviderTimeoutError()`
directly. The accumulated `StructuredStreamingContentAccumulator.contentValue`
buffer is discarded without being passed to
`validateStructuredStreamingCompletion`.

Failure mode: buyer whose model momentarily stalls but whose
buffer-as-of-close IS schema-valid sees spurious `provider_timeout`
failure instead of the success `[DONE]` SPEC requires.

**Resolution (Decision 2α — locked-in design call):**

Modify the idle-timeout TaskGroup so that on idle breach, it:
1. Marks `idleState.markTimedOut()`.
2. Cancels the inference task via `token.fire()`.
3. Reads `structuredAccumulator.content` (buffer-as-of-close).
4. Calls `validateStructuredStreamingCompletion(...)` with that
   buffer.
5. If validation succeeds, returns the synthesized `CompletionResult`
   as success (buyer sees `[DONE]`).
6. If validation fails, throws `provider_timeout` APIError (current
   behavior).

This requires either (a) restructuring the TaskGroup to return a
`CompletionResult` from the watcher arm, or (b) deferring the
validation to the call site after the operation returns. Pick (a)
because it keeps the idle-breach semantics co-located with the
watcher and the buffer.

### T-3: multipleOf validator bypass on denormal / sub-1e-300 operands (1 HIGH — Lane E)

E-H-1.

`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:250-256`:

```swift
let quotient = numeric / multipleOf
let nearest = quotient.rounded()
let tolerance = max(1e-12, abs(quotient) * 1e-12)
if abs(quotient - nearest) > tolerance { throw ... }
```

With `multipleOf: 1e-300`, quotient grows to ~1e300 and tolerance
saturates such that every numeric instance passes. With
`multipleOf: 5e-324` (smallest positive subnormal), quotient overflows
to `+Infinity`, `nearest = .infinity`, `abs(quotient - nearest) = NaN`,
the comparison `NaN > tolerance` is false → silent accept.

Schema cap is 16384 bytes; the offending schema fits trivially.

**Resolution (Decision 3δ — locked-in design call):**

Scaled-integer comparison when both operands are integer-representable,
with explicit denormal / overflow guard:

1. If `multipleOf` is sub-normal or `<= 0` after parse, reject pre-
   inference with `json_schema_unsupported_keyword` (this is already
   covered by `multipleOf > 0` rule but extend to also reject
   denormals; concretely require `multipleOf >= Double.leastNormalMagnitude`).
2. If both operands are integer-representable (i.e., `numeric.truncatingRemainder(dividingBy: 1) == 0`
   AND `multipleOf.truncatingRemainder(dividingBy: 1) == 0`), use
   `Int(numeric) % Int(multipleOf) == 0` for exact comparison.
3. Otherwise compute `quotient` and detect saturation: if `quotient`
   is non-finite, or `abs(quotient) > 1e15` (precision-loss threshold),
   reject as invalid output (i.e., treat unverifiable as fail-closed).
4. Otherwise use the existing relative-tolerance comparison.

Pre-inference rejection of denormals also closes the input side.

### T-4: Gateway wall-clock zero-point misplaced (1 MEDIUM — Lane A)

A-M-1.

SPEC AC-V2-9: "wall-clock duration since gateway-side
first-byte-of-request". IMPL uses `context.WithTimeout(r.Context(),
s.cfg.CoordinatorTimeout())` at `chat_proxy.go:225-239`, which is
created AFTER body read, quota reservation, and concurrency
reservation. Pre-upstream gateway time excluded from the 300s budget.

**Resolution:** Move `context.WithTimeout` to immediately after
`handleChatCompletions` enters (before body read). The `start` timestamp
at `chat_proxy.go:65` is the right zero-point. Restructure so the
context with the 300s timeout is created at entry; downstream code
re-uses that same context.

### T-5: No-double-fire invariant unverified + currently broken (1 HIGH — Lane E)

E-H-2.

SPEC AC-V2-9: "Either timeout authority may fire first; whichever
fires first produces the buyer-visible terminal frame; the other
authority MUST observe the closed stream and not fire a second time".

No test exercises a real race between the gateway 300s wall-clock
watcher and the provider 60s idle watcher. AND per T-1, when provider
idle fires (T=60s), the WS frame becomes `error_internal`, coord
emits generic `"provider_error"` SSE, gateway doesn't recognize that
as a SPEC-019 terminal frame → falls into `streamingCompletionDeltaBytes`
malformed branch → emits a second terminal frame.

**Resolution:** T-1 fix resolves the actual no-double-fire bug
(provider idle → 4-code WS frame → coord → SPEC-019 terminal SSE →
gateway recognizes, sets `terminalStructuredErrorCode` → e5e9995
guard fires on subsequent upstream events). Add a test asserting
that scenario: provider emits idle-timeout WS frame, coord emits
`provider_timeout` SSE, gateway forwards verbatim, no second
terminal frame, refund-only outcome.

## Singular findings (7)

- **B-M-1:** Idle watcher fires `drainCancelled` token before throwing
  `provider_timeout`. Outer `withDrainCancellation` can race and
  convert the fired token to `DrainCancelledError`, which
  `HTTPServer.swift:572` maps to swap-drain envelope. **Fix:** in the
  catch-clause of `withStructuredStreamingIdleTimeout`, distinguish
  `DrainCancelledError where idleState.timedOut` (already handled) but
  also ensure the outer wrapper sees the `provider_timeout` APIError
  first. May require not firing the drain token at all and instead
  using a dedicated cancel signal for idle.

- **D-M-1:** AC-V2-14 fixture expansion — add Qwen3 and Llama-3.3
  family-specific artifacts, add non-empty tool-history case. Use the
  existing v0.1.5 family-rendering fixtures as templates.

- **D-M-2 + E-M-1:** Fixture version pinning: assert pinned versions
  in CI, not just README. Cline `assert_fixture.py` MUST assert exact
  Cline commit + `ai@<pin>` + `@ai-sdk/openai-compatible@<pin>` +
  `bun@<pin>`. AC-V2-5 also requires asserting `required`,
  `additionalProperties`, and numeric bounds in the captured body
  (lane D-M-2 specific).

- **E-M-2:** Add an inclusive-boundary cap test (`cap` exactly).
  Add end-to-end wire coverage for `response_byte_cap_exceeded` and
  provider-idle `provider_timeout` (after T-1 fix enables it):
  provider emits → coord SSE → gateway forwards → buyer sees right
  code.

- **F-M-1:** Add AC-V2-* citation comments at every IMPL enforcement
  site (matching house style elsewhere in the repo). Targets:
  - `ModelRuntime.swift:80` (cap accumulator → AC-V2-9b)
  - `ModelRuntime.swift:195` (cap constant → AC-V2-9b)
  - `ModelRuntime.swift:196` (idle constant → AC-V2-9 + §10)
  - `ModelRuntime.swift:1105` (idle watcher → AC-V2-9)
  - `JSONSchemaValidator.swift:14-16` (numeric bounds → AC-V2-10/10a/10b)
  - `JSONSchemaValidator.swift:160-186` (numeric bounds validator → AC-V2-10a/10b)
  - `server.go:5030-5037` (terminal-code allow-list → AC-V2-3a)
  - `chat_proxy.go:1076-1083` (terminal-code allow-list → AC-V2-3a)
  - `chat_proxy.go:225-239` (wall-clock authority → AC-V2-9)
  - `chat_proxy.go:1147-1166` (writeStructuredOutputTimeoutSSE → AC-V2-9)

- **F-M-2:** Magic constants need SPEC-citation comments:
  - `structuredStreamingValidationBufferByteCap = 2_097_152` →
    `// AC-V2-9b (LOCKED): SPEC-019 v0.2.4 §6 2 MiB streaming content cap`
  - `structuredStreamingIdleTimeoutSeconds: TimeInterval = 60` →
    `// AC-V2-9 N placeholder: SPEC-019 v0.2.4 §10 defers concrete value to v0.2.x`

- **F-M-3:** `StreamingStructuredOutputTests.swift` filename mismatch.
  Two resolutions:
  - **(option A)** Rename the file to
    `StrictJSONParserStreamingBufferTests.swift` (reflects its actual
    content — 1 panic-safety test).
  - **(option B)** Move broader coverage from the three sibling files
    under `macprovider-cliTests/` into the MacProviderCore-side file,
    or add re-export tests there.
  Pick (A) — smaller surface change, keeps the swift-test discoverability
  intact.

## r1 absorption plan

**r1 IMPL absorption target:** commits on top of `e5e9995`.

**Convergent absorption (5 themes — must close all 5):**
- T-1: 4-code allow-list at 3 sites + per-site unit tests
- T-2: Idle breach validates buffer-as-of-close before throwing
- T-3: multipleOf scaled-integer + denormal pre-inference reject + saturation fail-closed
- T-4: Gateway wall-clock zero-point at entry
- T-5: No-double-fire invariant test (the bug is closed by T-1; only
  test gap remains)

**Singular absorption (7 items — must close all):**
- B-M-1, D-M-1, D-M-2+E-M-1, E-M-2, F-M-1, F-M-2, F-M-3

**Lock convention:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6
lanes.

## Per-lane round files

- Lane A codex artifact: `codex-spec-019-v0-2-impl-...2026-06-29T09-34-19-500Z.md`
- Lane B codex artifact: `codex-spec-019-v0-2-impl-...2026-06-29T09-34-05-518Z.md`
- Lane C codex artifact: `codex-spec-019-v0-2-impl-...2026-06-29T09-33-58-189Z.md`
- Lane D codex artifact: `codex-spec-019-v0-2-impl-...2026-06-29T09-33-05-750Z.md`
- Lane E Claude agent: `tasks/a011d46dafa17b50b.output`
- Lane F Claude agent: `tasks/ab011f33f4fb9560e.output`
