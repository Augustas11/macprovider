# AUDIT_GATEWAY_RETRY_503_CODE — CODE lane

You are auditing the diff that implements the retry-with-backoff loop
described in `specs/BUILD_GATEWAY_RETRY_503_IMPL_PROMPT.md`. Read that
file for the behavioural contract, then read the diff.

## Your lane: CODE correctness

Focus exclusively on code-correctness bugs — not security, not
architecture. Assume the design in the BUILD prompt is fixed.

### Look for

1. **Retry loop control flow**
   - Off-by-one in attempt counting (default `MaxAttempts=3` means 1 +
     2 = 3 total attempts; verify the loop actually makes exactly 3
     attempts on a 3× 503 case).
   - Retry decision made against a value the response body has been
     read for (not a body that was consumed and not replayed).
   - Loop-exit conditions cover: 200, non-retryable 5xx, retryable 503
     exhausted, network error, context cancel.
   - Backoff calculation: `backoff_base_ms * 2^(attempt-1)` capped at
     `backoff_max_ms`, jitter ±25 %, never negative.

2. **Body drain / close discipline**
   - Response body drained (or bounded-read) BEFORE `Body.Close()` on
     every retry path.
   - No missed `defer resp.Body.Close()` on the retry loop path.
   - No file-descriptor / conn-pool leak on the failure path (`.Do()`
     returned an error before we got a response).

3. **Request replay integrity**
   - `bytes.NewReader(body)` (or equivalent) is re-instantiated per
     attempt so the reader position is at zero for each `Do(...)`.
   - `upReq.Header` state is reset per attempt if the code mutates it
     between attempts (e.g. adds a retry-attempt header — if this
     doesn't happen, verify headers are still stable).
   - `X-Request-ID` is byte-identical across attempts.
   - Same `upCtx` used across attempts (do NOT create a new context
     per attempt).

4. **Context / cancellation**
   - Sleep is cancellable via `select { case <-time.After: … ; case
     <-upCtx.Done(): … }` (or `time.NewTimer` with `Stop()` on the
     cancel branch to avoid timer leak).
   - Loop exits promptly on `upCtx.Err() != nil`.
   - No `time.Sleep(...)` used inside the loop (would ignore cancel).

5. **Response handoff to downstream**
   - After retry exhaustion or non-retryable 503, the response object
     handed to `forward{Streaming,NonStreaming}Chat` still has a
     readable body (i.e. if the body was drained during the retry
     check, it was replaced with `io.NopCloser(bytes.NewReader(...))`
     so downstream can still read it).
   - StatusCode, Header, and Body semantics preserved.

6. **Logging**
   - `slog.Info` / `slog.Warn` uses the exact message strings from R9
     of the BUILD prompt: `"gateway coord 503 retry"`, `"gateway coord
     503 retry recovered"`, `"gateway coord 503 retry exhausted"`.
   - `attempt` is the 1-indexed attempt-about-to-be-made (so first
     retry log is `attempt=2`).
   - No `slog.Info` fires on the initial (attempt=1) success path.
   - No log line duplicated / dropped on cancel path.

7. **Config validation**
   - New config-validation branches trigger correctly on
     `MaxAttempts=0`, `MaxAttempts=11`, `BackoffBaseMs=5`,
     `BackoffMaxMs=15000`, `BackoffMaxMs < BackoffBaseMs`.
   - Validation error messages match repo convention.
   - Defaults applied correctly when field is zero-value in unmarshal.

8. **Retryable-503 detection**
   - `isCoordNoProviderAvailable503(status, body)` returns:
     - `false` for `status != 503`
     - `true` for `status == 503 && len(body) == 0`
     - `false` when `isNullUsageProviderError(body)` returns true
     - `false` when `coordinatorTier2PolicyError(503, body)` returns
       true
     - `true` when parsed code is empty OR `no_provider_available`
     - `false` otherwise
   - Invoked with the FULL body (or a large-enough prefix) to make an
     accurate decision.

9. **Jitter random source**
   - Uses `math/rand/v2` (repo standard). Or if repo uses `math/rand`,
     the choice is consistent with existing code.
   - Not creating a new `*rand.Rand` per call (would be a perf smell).
   - No division-by-zero when computing jitter percentages.

10. **Test coverage matches AC3**
    - Each of the 9 AC3 test cases is present as a distinct test.
    - Retry-replay-integrity test actually inspects captured request
      bodies for byte-identity, not just count.
    - Fake clock (or sleep captor) used for backoff assertion, not
      real-wallclock sleep in tests.

### Do NOT flag

- Placement / architecture (that's the ARCHITECT lane).
- Auth-header leakage / credential exposure (that's the SECURITY
  lane).
- Naming taste, comment style, log-message wording (unless it violates
  R9 of the BUILD prompt verbatim).
- Anything outside the diff.

### Output format

Report findings ranked C (CRITICAL) / H (HIGH) / M (MEDIUM) / L (LOW) /
I (INFO). One paragraph per finding: file:line, defect description,
concrete failure scenario (inputs → wrong output), proposed fix in
plain English. No code patches.

Include a bottom-line status line:

```
STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

The diff is the current uncommitted change in this worktree. Read
`git diff` and the new file(s) to identify all changes.
