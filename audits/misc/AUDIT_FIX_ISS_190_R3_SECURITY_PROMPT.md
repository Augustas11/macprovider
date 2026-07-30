# AUDIT — Fix iss-190 R3 SECURITY re-audit

## Scope

`/Users/augstar/macprovider-fix-190`, four files in the diff plus
the new streaming-test addition:

- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/integration_test.go`
- `phase5-gateway/internal/router/server_test.go` (new asserts on
  TestStreamingReceiptHeaderStripped)

Read `git diff origin/main..HEAD`.

## R2 SECURITY HIGH now claimed FIXED

R2 SECURITY was `0/1H/0/0/0`. The one HIGH:

- The streaming success path at `chat_proxy.go:384` previously
  did `w.Header().Set("Cache-Control", "no-cache, no-transform")`,
  silently clobbering the `no-store` set at handler entry on
  responses that still carry per-tenant
  `X-RateLimit-*-Requests` headers.

**FIX:** the streaming Cache-Control value is now
`"no-store, no-cache, no-transform"` — preserving no-store for
tenant-state safety, plus the original SSE-required no-cache /
no-transform. The existing `TestStreamingReceiptHeaderStripped`
test was extended to assert `no-store` is present and that
`X-RateLimit-Limit-Requests` is emitted on the streaming path.

Additionally addressed from R2 advisory ("avoid clobbering
existing Vary: Origin from CORS"): `handleChatCompletions` now
uses `w.Header().Add("Vary", "Authorization")` +
`Add("Vary", "X-Demo-Token")` instead of a single `Set`, so any
prior CORS-supplied `Vary: Origin` is preserved as a separate
header value. The `assertNoStoreCacheHeaders` test helper was
updated to inspect `Header().Values("Vary")` so it tolerates both
the Add (multi-value) and Set (comma-joined) representations.

## Your job (R3)

- Confirm the R2 streaming-path HIGH is genuinely resolved.
- Confirm the Vary-Add change preserves CORS Vary semantics and
  no new defect was introduced.
- Surface any remaining streaming-specific tenant-state caching
  risk (e.g., chunked-transfer paths that bypass the header
  rewrite).

Bar: **0 C/H/M** on the R3 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
