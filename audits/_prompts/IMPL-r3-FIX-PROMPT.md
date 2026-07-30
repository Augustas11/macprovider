# IMPL r3 — Single fix: SSE comment instead of JSON data event

Apply this ONE fix. NO interpretation, NO commit, NO IMPL-NOTES update.
After: run `cd phase3-binary && swift test 2>&1 | tail -3` and
`cd phase4-coordinator && go test -count=1 ./internal/buyer 2>&1 | tail -3`.
Report. Done.

## The problem

The r2 H-1 fix introduced an SSE event with the line:
```
data: {"type":"macprovider_tool_call_open","unix_ms":1751140123456}

```

This data: line breaks `@ai-sdk/openai-compatible@2.0.38` chunk validation
(Cline's SDK). Per SSE spec, lines starting with `:` are COMMENTS that all
EventSource parsers (including Vercel AI SDK) discard silently.

## The fix

Change the emission to an SSE comment line:
```
: macprovider_tool_call_open unix_ms=1751140123456

```

Note: SSE comment is `: ` (colon + space) followed by free text, then
double-newline. NO `data:` prefix. NO JSON.

## File 1: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`

Find the SSE event emission in the `modelRuntime.stream(...)` closure body
where it fires on first `.toolCallDelta` (around lines 488-494). It currently
calls something like:

```swift
writer.writeSSEJSON([
    "type": "macprovider_tool_call_open",
    "unix_ms": Int64(Date().timeIntervalSince1970 * 1000)
])
```

Replace with:

```swift
let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
writer.write(": macprovider_tool_call_open unix_ms=\(unixMs)\n\n")
```

(If `writer.write` is not the correct method name, use whatever the
`ResponseWriter` type provides for raw-byte writes. Probably
`writer.writeRaw(...)` or similar — read the type if unsure.)

## File 2: `phase4-coordinator/internal/buyer/streaming_timing.go`

The current `toolCallOpenFromSSELine` function (around lines 110-130) parses
`data: {"type":"macprovider_tool_call_open","unix_ms":...}`. Change it to
parse the new comment form.

Find the line-matching logic; replace JSON extraction with a simple
parse-by-space:

```go
// New parser:
// Looks for: ": macprovider_tool_call_open unix_ms=12345"
func toolCallOpenFromSSELine(line string) (int64, bool) {
    const prefix = ": macprovider_tool_call_open unix_ms="
    if !strings.HasPrefix(line, prefix) {
        return 0, false
    }
    s := strings.TrimPrefix(line, prefix)
    s = strings.TrimSpace(s)
    if v, err := strconv.ParseInt(s, 10, 64); err == nil {
        return v, true
    }
    return 0, false
}
```

(Replace any existing logic.)

## File 3: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`

If `InferenceRelay` also emits a similar SSE event for tool-call-open (same
pattern as HTTPServer), apply the same comment-line transform. If it
doesn't, skip this file.

## File 4: Test fixtures

Find any tests/fixtures that assert the old `data:
{"type":"macprovider_tool_call_open"...}` format. Update them to the new
`: macprovider_tool_call_open unix_ms=12345` comment form. Likely in:
- `phase4-coordinator/internal/buyer/streaming_timing_test.go`
- Possibly Swift `HTTPServerSwapTests.swift` or `InferenceRelayTests.swift`

## Stop condition

```bash
cd /Users/augstar/macprovider-impl-spec-018-v0-2/phase3-binary && swift test 2>&1 | tail -3
cd ../phase4-coordinator && go test -count=1 ./internal/buyer 2>&1 | tail -3
```

Report pass/fail. Done.
