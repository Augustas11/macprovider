# IMPL r4 — Defensive lock-confirmation (TIGHT)

Round 4 audit of SPEC-018 v0.2.4 IMPL at commit `a27d129` on
`impl/spec-018-v0-2`. After r3 absorption (1C fix: SSE wire-shape §10c).

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO MERGE → IMPL PR.

## What changed in `a27d129` (only this commit)

Verify ONE fix:

1. **SSE wire-shape**: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   no longer calls `writer.writeSSEJSON({...macprovider_tool_call_open...})`.
   Instead emits a raw SSE comment line:
   `: macprovider_tool_call_open unix_ms=<N>\n\n`. Cline's Vercel AI SDK +
   openai-python both ignore comment lines per EventSource spec.

2. **Parser updated**: `phase4-coordinator/internal/buyer/streaming_timing.go`
   `toolCallOpenFromSSELine` now parses the `:` prefix + `key=value` form.

## Authoritative inputs

1. `git show a27d129 --stat` — 2 files / +19 / −21
2. r3 audit verdicts: `specs/SPEC-018-v0_2-IMPL-{lane}-r3-audit.md`
3. SPEC: `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED (§10c
   forward-compat invariant)

## Smoke evidence

- `cd phase3-binary && swift test` — 578 tests / 0 failures / 7 skipped (37.8s)
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` — ok 1.9s

## Per-lane lens (TIGHT)

**Architect**: SSE comment is wire-spec-compliant per HTML5 EventSource §9.2.
Does emitting it inside a regular SSE response break any v0.1 invariant?
Specifically: does AC-23 (openai-python forward-compat regression) still pass
through openai==2.44.0 reader without raising on the comment line?

**Code**: Verify the SSE comment line format is byte-exact (`: ` then text,
then `\n\n`). Verify `toolCallOpenFromSSELine` parses the new form correctly
on legitimate input AND rejects malformed inputs. Test fixtures updated to
the new format.

**Security**: Does the comment line leak any settlement-relevant timing that
a malicious buyer could use to game? (Answer should be: no, because the
buyer's SDK silently drops the comment; the timing is only observed by
internal coordinator metrics.) Money-path posture unchanged.

**Product-design**: Cline UX — buyer's SDK now silently drops the comment.
That's the right outcome (timing observability is operator-internal via
`/metrics/streaming`, not buyer-facing). Does this regress any narrative or
UX claim?

**Claude critic**: Verify against the actual pinned `@ai-sdk/openai-compatible@2.0.38`
in `test/integration/streaming_terminal_error/node_modules/` that the comment
line is now dropped without `AI_TypeValidationError`. AND verify against
`openai==2.44.0` (AC-23 forward-compat baseline) that the comment line
doesn't break streaming accumulation.

**Claude narrative**: Reader test — does the 4-commit chain
(23266e7 → 42476b7 → 125aacc → a27d129) read coherently for an IMPL
reviewer doing PR review? Are commit messages clear about what each
absorption round addressed?

## Output format

Write findings to `specs/SPEC-018-v0_2-IMPL-{lane}-r4-audit.md`:

```
**Verdict:** {READY TO MERGE | FIX REQUIRED}
**Tally:** C/H/M/m/Q = N/N/N/N/N

## Closure verified
{Status with citation}

## Fresh findings
{If any}

## Verdict justification
```

Bar: 0/0/0 across all 6 = READY TO MERGE → IMPL PR opens.
