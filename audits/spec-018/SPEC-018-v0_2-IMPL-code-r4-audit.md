**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/0/0

## Closure verified

PARTIAL.

The provider emission is byte-exact for the intended SSE comment shape: `HTTPServer.swift` now emits `writer.writeRawSSE(": macprovider_tool_call_open unix_ms=\(unixMs)\n\n")`, so the first bytes are `: ` and the frame terminator is exactly blank-line SSE framing (`\n\n`) at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:489-492`. The new `writeRawSSE` path forwards the payload unchanged through `writeRawSSEPayload`, while ordinary JSON chunks still route through `writeRawSSEData` and receive the `data: ` prefix at `HTTPServer.swift:1055-1104`. This closes the r3 code-lane wire-shape blocker: the old buyer-visible JSON `data: {"type":"macprovider_tool_call_open",...}` chunk is gone from the source path changed by `a27d129`.

The coordinator parser recognizes the legitimate new line form. `toolCallOpenFromSSELine` trims line whitespace, requires the exact prefix `: macprovider_tool_call_open unix_ms=`, parses the suffix with `strconv.ParseInt`, and returns `time.UnixMilli(v).UTC()` at `phase4-coordinator/internal/buyer/streaming_timing.go:108-118`. `forwardStreaming` still observes that line before pre-commit forwarding at `phase4-coordinator/internal/buyer/server.go:2563-2581`, so AC-44 internal timing observability is preserved.

Fresh validation run:

- `cd phase3-binary && swift test` passed: 578 tests, 0 failures, 7 skipped.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` passed: `ok .../internal/buyer 1.913s`.

## Fresh findings

### MEDIUM - `toolCallOpenFromSSELine` accepts semantically malformed non-positive timestamps and has no direct fixture coverage

The old JSON parser rejected `unix_ms <= 0` before returning a timestamp (`git show a27d129^:phase4-coordinator/internal/buyer/streaming_timing.go`, old lines 126-129). The new parser removed that semantic guard: any syntactically valid signed integer parsed by `strconv.ParseInt` returns `ok=true` at `phase4-coordinator/internal/buyer/streaming_timing.go:114-117`. That means these malformed provider lines are currently accepted:

```text
: macprovider_tool_call_open unix_ms=0
: macprovider_tool_call_open unix_ms=-1
```

This is not a buyer-visible SSE compatibility regression, and it does not reopen the r3 `data:`-chunk problem. It is still a code-lane merge blocker under this round's explicit check because the parser was asked to parse legitimate input and reject malformed inputs. A non-positive Unix-millisecond value is malformed for this timestamp and was explicitly rejected by the immediately previous implementation. If accepted, it can poison `/metrics/streaming` lag calculations with 1970-era or pre-epoch provider-open times.

There is also no direct test fixture for `toolCallOpenFromSSELine` in the current buyer tests. `phase4-coordinator/internal/buyer/streaming_timing_test.go:11-37` covers header fallback/skew metrics only; `rg` finds no `_test.go` references to `toolCallOpenFromSSELine` or `macprovider_tool_call_open`. The passing buyer package test therefore does not prove the new comment-form parser accepts the legitimate line or rejects malformed variants.

Required fix: restore the `v <= 0` rejection after `strconv.ParseInt`, and add table tests covering at least: valid comment line, valid line with trailing newline/whitespace, old `data:` JSON marker rejection, missing `unix_ms`, non-integer suffix, empty suffix, zero, and negative values.

## Verdict justification

The r3 wire-shape problem is closed at the source emission point: the marker is now an SSE comment, byte-exact as `: macprovider_tool_call_open unix_ms=<N>\n\n`, and no longer a `data:` JSON event that SDK parsers treat as a chat chunk. However, the r4 code-lane bar also required malformed parser inputs to be rejected. The new parser fails that bar for non-positive timestamps and lacks a direct fixture to lock the new comment format. With one MEDIUM outstanding, code lane is not READY TO MERGE.
