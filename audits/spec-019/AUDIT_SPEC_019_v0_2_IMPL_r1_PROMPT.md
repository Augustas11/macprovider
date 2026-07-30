# SPEC-019 v0.2 IMPL — Round 1 audit prompt (per-lane)

You are auditing the **SPEC-019 v0.2 IMPL diff** at worktree HEAD
`e5e9995` on branch `impl/spec-019-v0-2`. The IMPL implements
SPEC-019 v0.2.4 LOCKED — gateway-owned wall-clock + provider-owned
idle authority + streaming structured output + numeric bounds +
`$schema` + dual envelope (`invalid_json` for NaN/Infinity,
`json_schema_unsupported_keyword` for non-numeric operand types).

## Diff anchors

Three IMPL commits since v0.2.4 SPEC (`521fe28`):

- **`21cd08e` "Enable SPEC-019 streaming structured output"** — codex
  IMPL diff (+1325/-116, 45 files). Provider ModelRuntime/JSONSchema
  Validator/HTTPServer; coordinator server.go mirror + WS streaming +
  Spec-019 SSE pass-through; gateway chat_proxy.go wall-clock
  authority + terminal-frame pass-through + Spec-019 timeout SSE; 7
  fixture dirs; 5 new test files.
- **`edd6f48`** — IMPL prompt for audit traceability.
- **`e5e9995` "refund-only on upstream read error after SPEC-019
  terminal SSE error frame"** — pre-audit manual fix. 5-line guard
  at the top of `chat_proxy.go` read-error block + 68-line regression
  test in `streaming_structured_output_test.go`. Closes the money-
  path wire-shape violation where a SPEC-019 terminal SSE error
  followed by upstream read failure would double-write a second
  terminal frame.

Run `git diff 521fe28..HEAD` to see the full IMPL surface.

## SPEC anchors (already LOCKED — do NOT propose SPEC edits)

- `specs/SPEC-019-structured-output.md` v0.2.4 LOCKED — 14 v0.2 ACs
  (AC-V2-1..14 + sub-items 3a, 9b, 10a, 10b). v0.1.5 body immutable.
- `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — §10d.4
  SSE error frame envelope (parent contract).
- `specs/SPEC-006-buyer-api.md` — §17.5 / `:2605` defines
  `provider_timeout`.
- `specs/SPEC-019-v0_2-r4-audit.md` — the SPEC r4 LOCK narrative
  describing what the IMPL is implementing.

## IMPL anchors

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — +222
  lines; idle watcher (`StructuredStreamingIdleState`), content
  buffer (`StructuredStreamingContentAccumulator`),
  `withStructuredStreamingIdleTimeout` TaskGroup wrapper,
  `validateStructuredStreamingCompletion`.
- `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift`
  — +67 lines; numeric-bound validation, type-conditional gate,
  `$schema` allow-list.
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` — -24
  lines (streaming-reject deleted).
- `phase4-coordinator/internal/buyer/server.go` — +133 lines; mirror
  validator widened, WS streaming terminal-status mapping, SSE
  pass-through for the 4 SPEC-019 codes, EOF + terminal code →
  FaultBreakerQualifying classification, `writeSSEError` sets
  `settlement_ran:true` for the 4 SPEC-019 codes.
- `phase5-gateway/internal/router/chat_proxy.go` — +145 lines (+ the
  e5e9995 fix adds 12 more); structuredStreaming flag, wall-clock
  authority on initial-connect + during-stream timeout, terminal-
  frame verbatim pass-through, refund-only post-terminal-error
  guard, `writeStructuredOutputTimeoutSSE` shape.

## Lane charters

Each lane returns 0/0/0 OR finds CRITICAL/HIGH/MEDIUM. Bar to return
READY TO LOCK: 0 CRITICAL + 0 HIGH + 0 MEDIUM.

### Lane A — Codex architect
- Cross-module invariant consistency: does IMPL match SPEC ACs at
  every layer? Spot-check 5 random AC-V2-* against IMPL surface.
- Wall-clock authority: gateway emits `provider_timeout` for SPEC-
  019 streaming timeouts (initial connect, during-stream, post-
  terminal). Both watchers (gateway wall-clock + provider idle)
  don't fire twice.
- 3-layer money-path bridge per AC-V2-3a: provider WS end-frame
  status + coord SSE writer settlement_ran:true + gateway pass-
  through verbatim. Each layer enforced independently.

### Lane B — Codex code
- Citation correctness: every IMPL file:line cited in test names /
  comments resolves accurately against the working tree.
- v0.1.5 IMPL invariants preserved: streaming-reject deletion didn't
  break non-streaming path; mirror validator widening didn't
  regress v0.1.5 schema rejects.
- Race / concurrency surfaces: idle watcher TaskGroup, content
  accumulator NSLock, gateway forwardLine return-true vs
  return-false control flow under edge cases.

### Lane C — Codex security
- Money-path posture per the table in the IMPL prompt:
  - HTTP streaming validation failure → terminal SSE error +
    FaultBreakerQualifying
  - WS streaming validation failure → end-frame status set +
    receipt omitted + FaultBreakerQualifying
  - Gateway SSE pass-through → no `stream_malformed` remap, no
    `outcome:"ok"` settle
  - Provider idle timeout → terminal `provider_timeout` +
    FaultBreakerQualifying
  - Gateway wall-clock 300s breach → terminal `provider_timeout` +
    FaultBreakerQualifying; NOT `provider_disconnected`/
    `stream_truncated`
  - Cap exceeded (2 MiB content) → terminal
    `response_byte_cap_exceeded` + FaultBreakerQualifying
  - NaN/Infinity in numeric-bound positions → HTTP 400
    `invalid_json` from parse layer
- DoS surfaces opened by streaming acceptance: validation buffer
  growth, idle watcher resource leak, content accumulator overflow,
  schema parsing depth.
- Double-settlement / double-write surfaces: can the gateway emit
  more than one terminal frame, ever? Can the coordinator?

### Lane D — Codex product-design
- Fixture buildability: each of the 7 fixture dirs under
  `test/integration/spec_019/` actually constructs a real assertable
  artifact (captured POST body, SSE samples, package.json with
  pinned versions). No stub `pass` placeholders.
- AC-V2-5 Cline live fixture: pins Cline commit AND `ai` SDK
  package version. Captures outbound POST body. Asserts
  `stream:true` + exact `response_format.json_schema` fields BEFORE
  asserting parsed output.
- AC-V2-12 Vercel `z.number().int()` fixture: captured body matches
  actual Vercel/Zod emission (integer + safe-integer min/max + top-
  level `$schema`).
- AC-V2-13 partial-content negative streaming: includes BOTH Cline
  AND Vercel fixtures (conjunctive per r1 SPEC absorption).
- AC-V2-14 composite-render streaming invariant: byte-equivalent vs
  non-streaming.

### Lane E — Claude critic (blind-spot adversarial)
- Hostile read of the IMPL diff. What does the IMPL claim to do
  that an attacker (or a buggy upstream) could bypass?
- Look for new MUST / SHALL semantics in the IMPL that have no test
  asserting them.
- Numeric-bound floating-point edge cases: `multipleOf: 1e-300`,
  large operands, denormal numbers, signed-zero edge cases.
- Idle timeout placeholder value of 60s in
  `ModelRuntime.swift:195` — verify against SPEC §10 / AC-V2-9
  deferred-to-v0.2.x text (the SPEC says N is deferred; 60s is
  IMPL choice).
- Cline / Vercel fixture commit pinning — is the version pin
  visible in the test assertions, or only in a README that nobody
  reads?

### Lane F — Claude narrative (blind-spot continuity)
- Test naming consistency across phase3 / phase4 / phase5: do test
  names follow a discoverable pattern? Easy to grep for an AC and
  find the test?
- Comments in IMPL diff: do they cite the right AC / spec section?
  Especially the pre-audit fix in `e5e9995`.
- Commit message accuracy: does `21cd08e` "Enable SPEC-019
  streaming structured output" accurately describe the +1325-line
  change?
- IMPL prompt vs IMPL diff: any deliverable the prompt requested
  that the IMPL skipped, or vice versa?

## Output format (per-lane)

Return EXACTLY this, no preamble:

```
# SPEC-019 v0.2 IMPL r1 audit — lane <X>

## Verdict
<READY TO LOCK | NEEDS REVISION>

## CRITICAL (N)
- **[C-1]** ...

## HIGH (N)
- **[H-1]** ...

## MEDIUM (N)
- **[M-1]** ...

## Notes (N) [optional]
- ...
```

**Bar:** 0C + 0H + 0M. Do NOT edit files. Do NOT propose SPEC
edits. Constrain to IMPL surface only.
