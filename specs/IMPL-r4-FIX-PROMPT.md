# IMPL r4 — Two-part fix: parser guard + table tests

Apply BOTH fixes. NO commit, NO docs update.

## Fix 1: Restore `unix_ms <= 0` rejection

File: `phase4-coordinator/internal/buyer/streaming_timing.go`
Function: `toolCallOpenFromSSELine` (around lines 108-118)

Current `strconv.ParseInt` accepts ANY int64 including 0 and negatives. The
old JSON-parsing version rejected non-positive values explicitly. Restore
that guard.

Change:
```go
if v, err := strconv.ParseInt(s, 10, 64); err == nil {
    return v, true
}
return 0, false
```

To:
```go
if v, err := strconv.ParseInt(s, 10, 64); err == nil && v > 0 {
    return v, true
}
return 0, false
```

(Or wherever the current parsing logic is — find the function and add the
`&& v > 0` guard on the success branch.)

## Fix 2: Add table tests for the parser

File: `phase4-coordinator/internal/buyer/streaming_timing_test.go`

Add a new test `TestToolCallOpenFromSSELine` covering:

```go
func TestToolCallOpenFromSSELine(t *testing.T) {
    cases := []struct {
        name     string
        line     string
        wantOK   bool
        wantTime int64  // only checked when wantOK is true
    }{
        {"valid", ": macprovider_tool_call_open unix_ms=1751140123456", true, 1751140123456},
        {"valid with trailing whitespace", ": macprovider_tool_call_open unix_ms=1751140123456 ", true, 1751140123456},
        {"old data: JSON form rejected", `data: {"type":"macprovider_tool_call_open","unix_ms":1751140123456}`, false, 0},
        {"missing prefix", "data: ", false, 0},
        {"missing unix_ms", ": macprovider_tool_call_open", false, 0},
        {"non-integer suffix", ": macprovider_tool_call_open unix_ms=abc", false, 0},
        {"empty suffix", ": macprovider_tool_call_open unix_ms=", false, 0},
        {"zero rejected", ": macprovider_tool_call_open unix_ms=0", false, 0},
        {"negative rejected", ": macprovider_tool_call_open unix_ms=-1", false, 0},
        {"unrelated comment", ": some-other-comment", false, 0},
        {"empty line", "", false, 0},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got, gotOK := toolCallOpenFromSSELine(tc.line)
            if gotOK != tc.wantOK {
                t.Fatalf("ok = %v, want %v", gotOK, tc.wantOK)
            }
            if tc.wantOK && got != tc.wantTime {
                t.Fatalf("time = %d, want %d", got, tc.wantTime)
            }
        })
    }
}
```

Note: if `toolCallOpenFromSSELine` returns `time.Time` instead of `int64`,
adjust the test signature to compare `.UnixMilli()` against the expected
int64. Read the actual function signature from `streaming_timing.go` and
match it.

## Stop condition

```bash
cd /Users/augstar/macprovider-impl-spec-018-v0-2/phase4-coordinator
go test -count=1 -run TestToolCallOpenFromSSELine ./internal/buyer
go test -count=1 ./internal/buyer
```

Report pass/fail. Done.
