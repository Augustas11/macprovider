# AUDIT_GATEWAY_RETRY_503_CODE — CODE lane, ROUND 2

Round 1 CODE audit returned 1 MEDIUM finding:

> M — phase5-gateway/internal/router/chat_proxy.go:405: body read
> errors during the retry classification pass are swallowed. Scenario:
> coordinator returns 503 with a body reader that yields partial bytes
> plus an error; `readCoordRetryBody` returns `readErr`, but lines
> 405-410 replace `resp.Body` with the partial buffer and hand it
> downstream as a clean readable body. Existing downstream code would
> observe the body read error and take its upstream-error path; this
> can instead produce a terminal 503 no_provider_available or pass
> through a partial coordinator body. Preserve body read-error
> semantics.

The fix in this round wraps the buffered body in a new
`coord503PrefixErrBody` type that replays the captured prefix bytes
and then surfaces the deferred read error on the next `Read` call, so
downstream `forwardNonStreamingChat` sees the same read error and
takes its existing 502 `upstream_provider_error` branch.

Round 1 LOW finding (real sleeps in retry-loop tests) is deliberately
NOT fixed — per repo convention, LOW/INFO findings ship with PR-body
documentation and are not gating.

## Your lane: CODE, ROUND 2

Audit ONLY the ROUND 1 → ROUND 2 delta. Everything else in the diff
was already accepted in Round 1. Focus on:

1. **The fix at `chat_proxy.go:405-419` (the branch that assigns
   resp.Body).**
   - `coord503PrefixErrBody` correctly emits the prefix bytes across
     multi-Read invocations (partial reads by the caller).
   - The deferred read error surfaces ONLY after the prefix is fully
     replayed — never before.
   - No infinite loop / stall if a caller reads after the error has
     been returned once.
   - Position tracking is correct across concurrent reads-of-one-body
     (net/http uses one goroutine per response body — verify no
     assumption of goroutine-safety is required, but the type MUST be
     safe for the single-consumer pattern net/http uses).

2. **The `coord503PrefixErrBody` type definition.**
   - `Read` semantics conform to `io.Reader` contract: return `(n,
     nil)` while data is available, return `(0, err)` on error,
     `(0, io.EOF)` on clean end.
   - `Close` returns `nil` and is safe to call more than once.
   - `pos` field never exceeds `len(prefix)`.

3. **Downstream interaction.**
   - `forwardNonStreamingChat` at chat_proxy.go:489 uses
     `readLimitedBody`; verify by inspection that the read-error
     branch (line ~493) is actually reached when the wrapped body
     surfaces `coord503PrefixErrBody.err`.
   - `forwardStreamingChat` at chat_proxy.go:604 or similar path
     receives a 503 status with the same body wrapper — verify the
     downstream 503 branch doesn't ALSO try to read the body and get
     the deferred error at the wrong moment.

4. **Regression: existing behaviour on non-error retry paths.**
   - When `readErr == nil`, the code takes the `io.NopCloser(
     bytes.NewReader(body))` branch unchanged — the Round 1 test
     assertions still pass.
   - `resp.ContentLength = int64(len(body))` still runs on both
     branches (so downstream can still trust the header).

## Do NOT flag

- Anything already accepted in Round 1 (config, retry loop control
  flow, logging, jitter, config validation, existing test coverage).
- The Round 1 LOW finding about real sleeps in tests — deferred by
  design.
- Anything outside the R1 → R2 delta.

## Output format

Findings ranked C / H / M / L / I. Each finding lists: file:line,
defect, concrete failure scenario, proposed fix.

Bottom-line status:

```
STATUS: CODE lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

`git diff` in the worktree shows the full accumulated change. The
delta between R1 and R2 is the addition of the
`coord503PrefixErrBody` type and the split at chat_proxy.go:405-419.
