# AUDIT — Fix iss-190 (concurrency rate-limit headers + N=3) — R1 CODE lane

## Scope

Branch `fix/iss-190-ratelimit-headers` (worktree
`/Users/augstar/macprovider-fix-190`). Diff scope:

- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/integration_test.go`

Read `git diff origin/main..HEAD`. The issue body is at GitHub
issue #190.

## Context

`phase5-gateway` emits HTTP 429 on per-account concurrency overflow
but does NOT include OpenAI-compatible rate-limit headers, so client
SDKs fire blindly until 429 and retry without backoff signal.

This PR:

1. Bumps default `AccountConcurrency` / `DemoConcurrency` from 2 to 3
   (issue's recommended N; matches phase-A network capacity of 3
   providers × 1 slot).
2. Adds a new `setConcurrencyRateLimitHeaders(w, limit, remaining,
   retryAfterSeconds, now)` helper in `server.go` that emits
   `X-RateLimit-Limit-Requests`, `X-RateLimit-Remaining-Requests`,
   `X-RateLimit-Reset-Requests`, and `Retry-After` (the last only
   when `retryAfterSeconds > 0`). Names are deliberately suffixed
   `-Requests` to disambiguate from the existing `X-RateLimit-*`
   headers which describe the daily-token budget.
3. Wires the helper into two paths in `chat_proxy.go`:
   - On admit (post-AcquireConcurrency): emit
     limit / (limit - active) / no Retry-After.
   - On `ErrQuotaExceeded`: emit limit / 0 / Retry-After=1.
4. Constant `concurrencyRetryAfterSeconds = 1` — deterministic,
   short hint; documented as conservative pending completion-time
   telemetry.
5. Tests assert the headers on both 200 and 429 paths.

## You are the CODE auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M** on
diff-introduced surface.

Specifically check:

1. **`concurrencyDecision.Active` semantics.** `setConcurrencyRateLimitHeaders`
   is called with `remaining = concurrencyLimit - concurrencyDecision.Active`.
   Looking at `AcquireConcurrency` in `phase5-gateway/internal/storage/sqlite/store.go`:
   `decision.Active = active + 1` on admit. So remaining = limit -
   (active + 1). Is the off-by-one correct relative to OpenAI's
   semantics ("how many you can still send")?
2. **Header-set before WriteHeader.** `setConcurrencyRateLimitHeaders`
   is called on the admit path BEFORE the upstream-proxy code that
   eventually writes the response. Are there any code paths where
   we `setConcurrencyRateLimitHeaders` and then fall through to a
   path that calls `WriteHeader` from a different `w` (e.g.,
   `forwardStreamingChat` may create a new response writer or
   flusher)? Confirm the headers are not silently dropped on the
   streaming path.
3. **Retry-After constant.** Hardcoded `1` second. Is this defensible
   per OpenAI SDK behavior (most clients respect Retry-After
   exactly; some cap it)? Could a buyer-side SDK retry-loop with
   1s sleep actually hammer? Should it scale with concurrency
   pressure?
4. **Variable rename `_, err` → `concurrencyDecision, concurrencyErr`.**
   The shadowing change is non-trivial; the `err` was a fresh
   binding inside `if`. Now `concurrencyErr` is the outer
   binding. Confirm no later code in the same function refers
   to `err` expecting the old binding.
5. **N=3 bump regressions.** Did any tests rely on
   `AccountConcurrency = 2` as the default? Confirm
   `cfg.Quotas.AccountConcurrency = 2` overrides in tests still
   work; check `TestAccountConcurrencyCap` does not regress.
6. **Header naming choice.** `X-RateLimit-Limit-Requests` vs OpenAI
   spec's `x-ratelimit-limit-requests` (lowercase). HTTP headers
   are case-insensitive by spec but some SDKs are picky. Go's
   `http.Header.Set` canonicalizes — confirm the canonicalization
   matches what SDKs expect.
7. **Edge cases.** What happens when `concurrencyLimit` is 0 (an
   operator misconfig the validator already rejects)? When
   `decision.Active` exceeds `concurrencyLimit` (impossible by
   invariant)? Are negative `remaining` values guarded?

Out of scope: anything outside the four files in the diff.

## Output format

For each finding:

- **SEVERITY** (CRITICAL/HIGH/MEDIUM/LOW/NOTE)
- **Location** (file:line)
- **What** (one sentence)
- **Why it matters** (one sentence)
- **Suggested fix** (one or two lines)

End with `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
