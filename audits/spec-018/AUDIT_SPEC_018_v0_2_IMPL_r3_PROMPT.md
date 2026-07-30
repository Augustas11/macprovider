# IMPL r3 — Defensive lock-confirmation (TIGHT)

Round 3 audit of SPEC-018 v0.2.4 IMPL at commit `125aacc` on
`impl/spec-018-v0-2`. This is after r2 absorption (5 mechanical fixes).

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO MERGE.

## What changed in `125aacc` (only this commit)

Verify these 5 fixes mechanically by reading the cited code:

1. **AC-25a runtime crash**: `test/integration/cline_session/run_fixture.py:224`
   — `max()` now has `key=` argument. Run `python3 run_fixture.py --self-test`
   or equivalent to verify no `TypeError`.

2. **AC-44 timestamp placement**: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   — `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` removed from `writer.startSSE(...)`.
   Tool-call-open timestamp now emitted as SSE event
   `{"type":"macprovider_tool_call_open","unix_ms":...}` inside the
   `modelRuntime.stream(...)` closure, gated by `toolCallOpenEmitted` flag,
   fired on first `.toolCallDelta`. `streaming_timing.go` parses the new
   SSE event.

3. **NTP skew honesty**: `phase5-gateway/internal/router/chat_proxy.go:211, 361`
   — hardcoded `X-MacProvider-NTP-Skew-Ms: "0"` removed. Deploy doc
   `docs/operations/spec-018-v0.2-deploy.md` X-MacProvider-NTP-Skew-Ms
   section now says DEFERRED TO v0.3.

4. **AC-46 mismatch logging**: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   `validObservedModelHash` now logs error on non-empty input that fails the
   hex regex. New test in `ToolCallParserTests.swift` (or `MultiTurnTests.swift`)
   covers the known-but-malformed path.

5. **Sendable warnings**: `streamedAnyToolCallDelta` in HTTPServer.swift +
   InferenceRelay.swift replaced with NSLock-protected wrapper class. No
   Swift Sendable warnings remain.

## Authoritative inputs

1. **The r2 absorption diff**: `git show 125aacc --stat`
2. r2 audit verdicts (your prior round): all 6 files at
   `specs/SPEC-018-v0_2-IMPL-{lane}-r2-audit.md`
3. SPEC: `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED

## Smoke evidence

- `cd phase3-binary && swift test` — 578 tests / 0 failures / 7 skipped (37.2s)
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` — ok 1.9s

## Per-lane lens (TIGHT — close-only verification)

**Architect lane**: Are the 5 fixes structurally consistent? Specifically: does
the new SSE event `macprovider_tool_call_open` belong in the SSE stream
shape, or does it break v0.1.5 wire-shape (§10c forward-compat invariant)?

**Code lane**: Each fix mechanically verified at the cited line. Does the new
SSE event parse correctly via the openai-python streaming reader (would it
appear as an unknown chunk type to be skipped, or break parsing)? Are the
NSLock changes thread-safe?

**Security lane**: Money-path posture unchanged (re-verify `FaultBreakerQualifying`
paths are still set on the same failure modes). Does the new SSE event
`macprovider_tool_call_open` leak settlement-relevant timing info to buyers
that they could use to game?

**Product-design lane**: Cline UX impact of the new SSE event — does Cline's
Vercel AI SDK parser skip unknown event types cleanly, or does it warn /
break? Does the deploy-doc DEFERRED-TO-v0.3 note for NTP skew read honest
to ops?

**Claude critic**: Verify each closure mechanically. Especially:
- Is the AC-25a fixture actually CALLED in CI, or does the `--self-test` flag
  exist? If not, the fixture might still be broken in practice.
- Does the new SSE event ACTUALLY get emitted at first `.toolCallDelta`, or
  does it fire at SSE-start (still wrong place)? Read HTTPServer.swift inside
  the closure body.
- Does `validObservedModelHash` ACTUALLY log on the mismatch path, or is the
  log buried behind an `if` that never fires?
- Are the NSLock wrappers correctly capturing the FLAG STATE, not just the
  lock itself? Check the closure capture semantics.

**Claude narrative**: Reader test — does an IMPL reviewer reading the commit
message + IMPL-NOTES (if updated) understand what's in `125aacc` vs `42476b7`
vs `23266e7`?

## Output format

Write findings to `specs/SPEC-018-v0_2-IMPL-{lane}-r3-audit.md`:

```
# SPEC-018 v0.2.4 IMPL — {Lane} r3 Audit

**Verdict:** {READY TO MERGE | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closures verified
{Fix N status with citation}

## Fresh findings
{If any}

## Verdict justification
```

Bar: 0/0/0 across all 6 = READY TO MERGE → IMPL PR opens.
