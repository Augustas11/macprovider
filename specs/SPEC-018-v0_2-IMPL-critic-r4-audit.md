# SPEC-018 v0.2.4 IMPL — Claude critic r4 audit

**Verdict:** READY TO MERGE
**Tally:** C/H/M/m/Q = 0/0/0/0/2

Round 4 defensive lock-confirmation. r3 audit closed 1C (SSE wire-shape
§10c break) via commit `a27d129` switching from `data: {JSON}` to an SSE
comment line `: macprovider_tool_call_open unix_ms=<N>\n\n`. r4 verifies
the fix against BOTH pinned downstream SDKs and the upstream Go parser.

## Closure verified

### 1C closure — SSE wire-shape §10c forward-compat invariant

**Fix bytes (exact):**
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:491` emits
  `writer.writeRawSSE(": macprovider_tool_call_open unix_ms=\(unixMs)\n\n")`.
- `HTTPServer.swift:1100-1105` defines `writeRawSSEPayload` that writes
  the buffer byte-exact (no `data:` prefix injection).
- `phase4-coordinator/internal/buyer/streaming_timing.go:108-118`
  re-parses with `const prefix = ": macprovider_tool_call_open unix_ms="`
  + `strconv.ParseInt`.

**Single emission site, single parser site:**
```
$ grep -rn "macprovider_tool_call_open" --include="*.swift" --include="*.go"
phase3-binary/.../HTTPServer.swift:491   ← emit
phase4-coordinator/.../streaming_timing.go:109 ← parse
phase4-coordinator/.../streaming_timing.go:25  ← doc comment
```
No drift. No alternate emission path (InferenceRelay confirmed clean by r3 commit body).

### SDK #1 — `@ai-sdk/openai-compatible@2.0.38` (Cline anchor per AC-48b)

Pin verified: `test/integration/streaming_terminal_error/node_modules/@ai-sdk/openai-compatible/package.json` → `"version": "2.0.38"`.

Critic ran `parseJsonEventStream({stream, schema: choices-required})` —
the EXACT code path the SDK uses to consume upstream SSE responses
(`@ai-sdk/openai-compatible/dist/index.mjs:626` →
`@ai-sdk/provider-utils/dist/index.mjs:2577` →
`@ai-sdk/provider-utils/dist/index.mjs:2284` →
`new EventSourceParserStream()` from `eventsource-parser`).

The schema deliberately required `choices: array` (no `.nullish()`) so
that ANY leak of the comment-line bytes into `safeParseJSON` would be
caught. Test injected the comment line in 4 placements:

| Placement | Result | Items past schema | Errored |
|---|---|---|---|
| `: ... \n\n` then valid data | PASS | 1 | no |
| valid data then `: ... \n\n` | PASS | 1 | no |
| `: ... \n\n: ... \n\n` then valid data | PASS | 1 | no |
| valid data then `: ... \n\n` then valid data | PASS | 2 | no |

EventSource parser routes `:`-prefix lines to `onComment` (which the
SDK does not subscribe to), so comment bytes never reach the schema
validator. This is HTML5 EventSource §9.2 conformant behavior.
**r3 fix verified against the actual pinned SDK.**

### SDK #2 — `openai==2.44.0` (AC-23 / AC-43 forward-compat baseline)

Pin verified: `.venv-ac48a/lib/python3.13/site-packages/openai/_version.py`
via `python -c "import openai; print(openai.__version__)"` → `2.44.0`.

Critic ran a local SSE server emitting the same 4 placement variants
into `OpenAI(...).chat.completions.create(stream=True)` iterator. All
4 placements: 2 chunks yielded (the two valid `data:` events), tool_call
delta reconstructed, no exception raised. openai-python's SSE reader
silently drops comment lines for the same EventSource-spec reason.
**AC-23 forward-compat preserved.**

### Go upstream parser — `toolCallOpenFromSSELine`

Critic ran 13 ephemeral parser cases against the new form:
- happy path with/without trailing `\n`/`\n\n`: PASS, returns UnixMilli UTC time
- leading whitespace tolerated (TrimSpace): accepted (consistent with `tokenPointersFromSSE`)
- old `data: {"type":...}` JSON form: REJECTED (regression guard intact)
- missing/non-numeric/typo'd key: REJECTED
- trailing-garbage form: REJECTED
- empty / `:` only / wrong-event comment: REJECTED

Parser is byte-exact strict on prefix + strconv-strict on payload.
Old form cannot mistakenly match.

### Consumer pipeline — server.go SSE byte reader

Critic traced `internal/buyer/server.go:2550-2592`:
1. Byte-by-byte read into `lineBuf` until `\n`.
2. `tokenPointersFromSSE(line)` → no-ops on non-`data:` prefix.
3. `toolCallOpenFromSSELine(line)` → matches comment line, records timing.
4. `inspectCommitWorthyDataLine(line)` → returns `commitLineNoSignal`
   on non-`data:` prefix.
5. `toolFinal.observeLine(line)` → no-ops on non-`data:` prefix.
6. `preCommit.Write(line)` → forwards bytes downstream to buyer SDK.
7. `isSSEBlankLine(line)` matches the second `\n` of `\n\n` —
   `sawCommitWorthyDataLine` is still false at the comment's blank line
   (HTTPServer.swift:489 emits comment BEFORE the writeSSEJSON for the
   tool_call_delta on line 494), so the blank harmlessly `continue`s.

End-to-end: comment line bytes are observed by Go parser for timing,
forwarded transparently to the buyer SDK, dropped by the SDK at the
EventSourceParser layer. Settlement and commit-worthiness logic
correctly untouched.

### Smoke baselines re-run by critic

- `swift test`: 578 passed / 0 failures / 7 skipped (37.7s).
- `go test -count=1 ./internal/buyer`: ok (1.9s).

### Money-path posture (unchanged)

- Comment line carries no settlement data (a buyer-public unix_ms timestamp,
  observed independently by the buyer's clock anyway).
- Comment line silently dropped by buyer SDK → cannot be used by malicious
  buyer to game settlement.
- AC-44 timing observability preserved on coordinator side via
  `/metrics/streaming` (operator-internal).

### Narrative — 4-commit chain reads coherently

```
23266e7 narrow Cline drop-in (#1 multi-turn + #4 streaming + #6 tool_call_id + #7 byte cap)
42476b7 r1 absorption (2C + 10H + 13M closed)
125aacc r2 absorption (2C + 7H + 6M closed)
a27d129 r3 absorption (1C closed: SSE wire-shape §10c fix)
```

Each commit names the round, finding tally, and root cause. Reviewer
can follow the convergence curve (2C → 2C → 1C → 0). The r3 commit body
explains the problem (chunkBaseSchema vs `choices`), the fix (EventSource
comment line), and money-path impact (unchanged). Clear PR-review chain.

## Fresh findings

None.

## Open questions (unscored)

**Q-1.** The Go parser accepts `unix_ms=0` and `unix_ms=-1` (any int64
that `strconv.ParseInt` returns without error). Phase3 always emits
`Int64(Date().timeIntervalSince1970 * 1000)` which is bounded positive
on real clocks. A clock-skewed phase3 (NTP catastrophe) could emit a
near-zero or negative value; downstream metrics would then attribute
negative latency. Not a v0.2 blocker — phase3 clock skew is already a
known operational concern handled by the streaming-timing skew-skip
logic in `observeFromHeaders`. Flagging for v0.3 hardening review.

**Q-2.** Critic noted while verifying that the existing
`ac48b_openai_compatible_terminal_error.test.ts` integration test
passes structurally regardless of the SSE wire shape because `ai@5.0.87`
rejects the `@ai-sdk/openai-compatible@2.0.38` model as
`specificationVersion: "v3"` before any SSE bytes are read, satisfying
the `threw=true` assertion arm. The test's expectation
(`threw || (!sawToolCallPart && !sawSuccessfulText)`) is technically
correct but currently exercises the wrong code path. This was not the
r3 regression mechanism (which the r4 verification confirmed at the
parser layer directly), but the AC-48b harness deserves a follow-up to
align `ai` and `@ai-sdk/openai-compatible` major versions so the SSE
parser is actually exercised. Flagging for tracking issue, not a v0.2.4
blocker — the AC-48b protection exists in the fix-side parser code, not
in this specific JS test.

## Verdict justification

**Pre-commitment predictions** (made before investigation):
1. r3 fix might emit comment without correct CRLF / final `\n\n` →
   verified byte-exact via HTTPServer.swift:491 (uses `\n\n` literal,
   no CRLF). PASS.
2. Go parser might over-accept old `data:`-form → verified rejects old
   form. PASS.
3. SDK schema might reject the comment line because of an upstream
   parser bug → verified `EventSourceParserStream` drops `:`-lines via
   `onComment` callback that's never subscribed. PASS.
4. openai-python might handle SSE differently from JS → verified
   identical behavior (silent drop). PASS.
5. End-to-end consumer in server.go might mis-treat the comment-line
   blank as commit signal → verified emission order makes
   `sawCommitWorthyDataLine` false at the comment's blank line. PASS.

All 5 predictions probed; 0 surfaced new findings.

**Multi-perspective notes:**
- Architect: SSE comment is EventSource §9.2 compliant; cannot break a
  conformant parser. v0.1 invariants intact. AC-23 / AC-43 baseline
  byte-equivalence test still passes (comment line never reaches the
  reader's accumulator).
- Code: prefix + strconv parse is robust against malformed input; old
  form cannot accidentally match. No off-by-one in CRLF / blank-line
  handling.
- Security: comment line is purely observational (unix_ms timestamp the
  buyer can read off its own clock). No settlement-relevant data. No
  new attack surface.
- Product-design: timing observability moves from "data: JSON" (which
  was always buyer-invisible — they'd never parse it) to "comment
  line" (also buyer-invisible). Net UX delta = 0; AC-44 operator
  observability preserved on coordinator side.

**Escalation:** stayed in THOROUGH mode — no CRITICAL or MAJOR findings,
no systemic pattern to escalate against. Critic actively hunted for
edge cases (byte-cap interaction, blank-line commit-trigger ordering,
old-form regression) and all came back clean.

**Realist check:** N/A — no findings to recalibrate.

Bar (0C + 0H + 0M across all 6 lanes) met by Claude critic lane.
→ READY TO MERGE → IMPL PR opens.
