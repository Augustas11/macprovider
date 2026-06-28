# AUDIT — Fix iss-190 R2 SECURITY re-audit

## Scope

Same four files as R1, `git diff origin/main..HEAD`.

## R1 SECURITY findings claimed fixed

R1 was `0C/2H/1M/0L/4N`. Fixes applied this round:

1. **R1 SECURITY HIGH #1 (DemoConcurrency=3 reintroduces M1-8/PERF-6
   regression).** **FIX:** `DemoConcurrency` default reverts to 2;
   only `AccountConcurrency` bumps to 3. Comment in config.go cites
   M1-8 as the reason demo stays at 2.

2. **R1 SECURITY HIGH #2 (per-tenant headers without no-store / Vary).**
   **FIX:** `handleChatCompletions` now calls the existing
   `setNoStoreHeaders(w.Header())` helper (sets `Cache-Control: no-store`,
   `Pragma: no-cache`, `Expires: 0`) and additionally sets
   `Vary: Authorization, X-Demo-Token`. This runs unconditionally
   at the entry of every chat-completion request so the headers are
   in place regardless of which response path the handler eventually
   takes (admit, 429, upstream error). New test
   `assertNoStoreCacheHeaders` confirms the headers on both the 200
   admitted path and the 429 reject path.

3. **R1 SECURITY MEDIUM (upstream X-RateLimit-* / Retry-After
   pollution via copyCleanHeadersWithReceipt).** **FIX:** new
   `isGatewayOwnedRateLimitHeader(key)` predicate; `copyCleanHeadersWithReceipt`
   drops any upstream value for the seven gateway-owned header
   names (`X-RateLimit-Limit`, `-Remaining`, `-Reset`, the
   `-Requests` triplet, and `Retry-After`).

## Your job (R2)

- Confirm each R1 SECURITY finding is genuinely resolved.
- Surface any NEW defect introduced by the fixes (e.g. does
  unconditional `setNoStoreHeaders` at handler entry break any
  legitimate caching of error responses; does the upstream-
  header strip drop something the buyer needed for token-quota
  rate-limiting; does the demo=2 split conflict with any other
  documented operator config).
- Sanity-check the test additions are tight enough to lock in the
  guarantees (cache-control / Vary / no upstream pollution).

Bar: **0 C/H/M** on R2 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
