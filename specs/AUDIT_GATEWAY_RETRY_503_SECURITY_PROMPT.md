# AUDIT_GATEWAY_RETRY_503_SECURITY — SECURITY lane

You are auditing the diff that implements the retry-with-backoff loop
described in `specs/BUILD_GATEWAY_RETRY_503_IMPL_PROMPT.md`.

## Your lane: SECURITY

Focus exclusively on security-class defects. Not correctness, not
architecture. Assume the design is fixed by the BUILD prompt.

### Look for

1. **Credential / secret handling across retries**
   - `Authorization` header (buyer token or internal service token)
     replayed byte-identical on retries — no token mutation, no logging
     of the token in retry log lines.
   - `X-Demo-Token` and any other auth-shaped header treated
     identically.
   - `X-MacProvider-Account` (internal-only) not exposed to buyer via
     any error path added by this PR.

2. **Amplification / DoS surface**
   - Retry loop bounded so a buyer cannot amplify one inbound request
     into many upstream requests beyond `MaxAttempts`.
   - No path where a hostile buyer can drive coord to sustained 503
     and cause the gateway to CPU-spin (the sleep must be enforced).
   - Concurrency reservation is held across all retries — a buyer
     cannot dodge concurrency limits by triggering retries.

3. **Log injection / PII leakage**
   - `body_code` field in retry log lines uses the parsed
     `openAIErrorCode(body)` return value which strips whitespace but
     may contain untrusted content. Verify the code sanitises for
     control characters / newlines before slog, OR verify slog handles
     this safely.
   - `request_id` — is any user-supplied `X-Request-ID` sanitised
     before reaching slog? Same for `attempt`, `backoff_ms` — those
     should be numeric so no injection risk, but confirm.
   - No buyer-supplied prompt content ends up in a log line.
   - No secret (buyer key, service token, etc.) inadvertently logged
     in an error path.

4. **Timing side-channel**
   - Retry decision is content-based (`openAIErrorCode`) not
     content-length-based. A buyer cannot infer coord state by
     measuring retry timing.
   - Backoff jitter — is the random source appropriate for the use
     case? (Non-cryptographic is fine here since it's for backoff
     staggering, but confirm no security-relevant randomness reuses
     this source.)

5. **Buyer-disconnect handling**
   - If buyer TCP disconnects mid-retry-sleep, `upCtx.Done()` fires,
     loop aborts, reservation released via existing defer. Verify no
     path where a buyer-abandon leaves a coord dispatch in flight
     charging concurrency indefinitely.

6. **Concurrency reservation safety**
   - `store.ReleaseConcurrency` (deferred in the outer handler) fires
     regardless of retry outcome.
   - No path where a retry loop bails without triggering the deferred
     release.
   - No path where a retry-recovered success releases concurrency
     twice.

7. **Response body integrity**
   - After retry-exhaustion, the response body handed to downstream
     (with `io.NopCloser(bytes.NewReader(drainedBody))`) is exactly
     the bytes the FINAL coord response sent — not the FIRST
     response's body.
   - No cross-attempt body contamination (e.g. a scratch buffer reused
     between attempts).

8. **Config values as attack surface**
   - `MaxAttempts` validation prevents `MaxAttempts=1000` (which could
     be used as an amplification attack via a malicious config
     deploy). Validated in `[1, 10]` per BUILD spec.
   - `BackoffMaxMs` validation prevents `BackoffMaxMs=999999` (which
     would stall requests). Validated in `[10, 10000]`.
   - Config values reloaded / applied atomically — no torn read of a
     partially-updated config during a live retry loop.

9. **HTTPS / plaintext**
   - `s.coordinatorBuyerURL()` — is it always HTTPS in production
     configs? Retry loop must not fall back to HTTP even under network
     duress.
   - No hardcoded coord URL added by the retry code.

10. **Panic recovery**
    - Existing `httptest.HandlerFunc` / stdlib handlers panic-recover;
      confirm the retry loop does not introduce a new panic surface
      (e.g. nil-deref on `resp.Body` after error, index-out-of-range
      on jitter arithmetic).

### Do NOT flag

- Non-security correctness bugs (that's the CODE lane).
- Naming / placement (that's ARCHITECT).
- Anything not touched by the diff.
- Findings already present in the untouched pre-diff code (this is a
  new-code audit, not a repo audit).

### Output format

Report findings ranked C / H / M / L / I. Each finding lists:
file:line, threat model (who benefits from exploiting it), concrete
scenario (attacker action → security impact), proposed mitigation.

Bottom-line status:

```
STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

Read `git diff` in the worktree. The relevant files are named in the
BUILD prompt.
