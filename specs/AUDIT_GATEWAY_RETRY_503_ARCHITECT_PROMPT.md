# AUDIT_GATEWAY_RETRY_503_ARCHITECT — ARCHITECT lane

You are auditing the diff that implements the retry-with-backoff loop
described in `specs/BUILD_GATEWAY_RETRY_503_IMPL_PROMPT.md`.

## Your lane: ARCHITECT

Focus on design-level concerns: placement, layering, consistency with
existing patterns, and future-extensibility. Not code correctness, not
security.

### Look for

1. **Placement of the retry loop**
   - The retry loop wraps the coord dispatch BEFORE the split into
     `forwardStreamingChat` / `forwardNonStreamingChat`. Verify this
     placement in the diff. If the retry is inside one of the forward
     functions instead, that's a HIGH finding (the streaming path
     could return partial data before the retry decision).
   - The retry is a handler-level concern (per BUILD "Prohibited
     implementation choices" R2). Verify it is NOT implemented as
     `http.RoundTripper` middleware on `s.client`.

2. **Config placement**
   - New `Retry503Config` struct is on the correct parent (`Config`
     top-level vs a nested block like `CoordinatorConfig` or a new
     `RetryConfig` block).
   - The yaml key naming (`retry_503`) is consistent with the naming
     style of existing keys (`coordinator_request_seconds`,
     `warmup_gate_enabled`, etc.). Consider whether a more
     general-purpose name (e.g. `coord_retry`) would age better.
   - Config defaults registered in the same place as other config
     defaults (avoid drift where some knobs default via unmarshal
     tags and others via `applyDefaults` / normaliser).

3. **Observability naming stability**
   - Log message strings (`"gateway coord 503 retry"`, `"… retry
     recovered"`, `"… retry exhausted"`) should be greppable and
     stable enough that ops dashboards can rely on them.
   - Field names (`attempt`, `backoff_ms`, `body_code`,
     `total_backoff_ms`, `attempts`) should follow the same
     snake_case convention as existing gateway log fields.
   - When metrics wiring is added later (out-of-scope for this PR),
     the current log structure should map cleanly to a
     Prometheus/StatsD schema.

4. **Consistency with existing retry / backoff patterns in the
   codebase**
   - Search the coord + gateway for other retry loops. Does this new
     one match their style (helper function name, backoff formula,
     jitter approach)?
   - If a shared `backoffMs(attempt, base, max)` helper exists, does
     the new code reuse it or duplicate the logic?

5. **Test-file naming**
   - `chat_proxy_retry_test.go` — consistent with existing per-topic
     test file naming (e.g. `chat_proxy_streaming_test.go`,
     `chat_proxy_settle_test.go` if they exist)?

6. **Helper placement**
   - `isCoordNoProviderAvailable503` placed adjacent to
     `coordinatorTier2PolicyError` and `isNullUsageProviderError` for
     review-locality. Verify.
   - Helper exported vs package-private matches the convention set by
     its neighbours.

7. **Interaction with SPEC-006 / SPEC-024 settlement paths**
   - Retry loop MUST NOT touch settlement / reservation code — this
     is a BUILD-prompt R7 requirement. Verify no accidental coupling
     was introduced (e.g. the retry loop passes an extra argument to
     `forwardStreamingChat` that leaks retry state into settlement).
   - `promptEstimate`, `maxUsageTokens`, `maxTokens` are computed
     once before the loop — verify they're NOT recomputed per attempt
     (would waste work and could produce inconsistent values under
     race).

8. **Streaming safety**
   - A streaming request that would have failed on attempt 1 (503),
     and succeeds on attempt 2 — the buyer sees a clean 200 stream,
     not a "first 503-body-then-200-stream" concatenation. Verify by
     tracing the response-write path.
   - `w http.ResponseWriter` — no bytes written to `w` on any
     interim-attempt failure. First byte to `w` happens only after
     the terminal attempt.

9. **Scope discipline**
   - No changes outside `chat_proxy.go`, `config.go`, and the new
     test file (per BUILD "Scope of change"). Except:
     - `gateway.yaml.example` may be extended with a commented-out
       block IF such a file exists in the repo. If it doesn't exist,
       verify one was NOT created (scope creep).
   - No new dependencies added to `go.mod`.
   - No changes to coord / provider code.

10. **Future-extensibility signals**
    - Is the retry helper structured such that adding "retry on 504"
      or "retry on network error" would be a small change? A design
      that hardcodes 503 everywhere makes future ops changes painful.
    - Would this design generalise to other outbound-call sites in
      gateway (auth, account lookup) if they later need similar
      retry? If so, is the helper reusable, or is it tangled with
      `chat_proxy.go`-specific state?

### Do NOT flag

- Code correctness bugs (CODE lane).
- Security concerns (SECURITY lane).
- Findings that are matters of pure aesthetic preference with no
  operational consequence.
- Suggestions to refactor pre-existing code untouched by the diff.

### Output format

Report findings ranked C / H / M / L / I. Each finding lists:
file:line, the design concern, why it will bite (concrete future
scenario), proposed change in plain English.

Bottom-line status:

```
STATUS: ARCHITECT lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

Read `git diff` in the worktree.
