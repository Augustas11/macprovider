# SPEC-017 IMPL Step 3 — Security Audit Round 1

Branch: `impl/spec-017-step-1` / PR #173  
HEAD audited: `9c2976571c3d76a6849f5f965b5320d5b3eb9e27` (`impl(017): Step 3 — handlers + middleware + store (initial drop for audit loop)`)  
Prior round: none  
Lens: SECURITY — role isolation, token handling, timing equivalence, CORS, rate-limit security, recover/redaction, surface attacks, cross-step boundary.

Required reading completed:
- `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4, §5.6, §5.7, §6.1, §6.4, §6.6, §7.2.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3, including redaction invariants, 7-row decision table, CORS rules, middleware stack order, and rate-limit reserve-then-refund.
- `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
- Step 3 SECURITY prior rounds: none found for round 1.
- Memory notes from `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/`: `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, `c1-control-chars-terminal-sanitizer-bypass`, `audit-loop-catches-billing-ledger-drift`.

## Validation Run
- `git show --name-only --format=fuller HEAD` — PASS; HEAD is `9c2976571c3d76a6849f5f965b5320d5b3eb9e27`, Step 3 handler/middleware/store drop.
- `git diff --name-only bd68a0a..HEAD` — PASS; changed files are Step 3 stats handlers/middleware/store, coordinator mux wiring, `go.mod`, and Step 3 audit prompts.
- `rg "partner_keys\.token_hash|raw_token|bearer_token" phase4-coordinator/internal/stats/` — PASS; no matches.
- `rg "log\.|fmt\.Print|trace\." phase4-coordinator/internal/stats/` — PASS with caveat; handler package log calls are in recover middleware only, and no raw `Authorization` call site was found. Rollup logs are outside this Step 3 handler lens.
- `rg "subtle\.ConstantTimeCompare" phase4-coordinator/internal/stats/` — PASS; one match in `auth.go` revoked-key branch.
- `go test ./internal/stats/... -count=1` from `phase4-coordinator/` — PASS.
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test` from `phase4-coordinator/` — PASS compile smoke.
- `gofmt -l phase4-coordinator/internal/stats` — PASS; no output.

## Category Verdicts
A. Role + pool isolation: PASS — `cmd/coordinator/main.go` injects `statsstore.New(statsPools.Reader)` into `stats.NewMux`, and request-path store code uses SELECT-only methods. No request-path imports of `internal/stats/migrations`, billing, explorer, ws, or auth were found. Handler/store SQL does not select ledger tables, `provider_tokens`, `provider_rewards_ledger`, `provider_visibility_audit`, or a rollup pool.

B. Token handling: FAIL — raw token handling is mostly contained: redaction stashes the bearer under unexported `authKey`, hashes with `sha256.Sum256([]byte(bearer))`, and store lookup is by `token_hash`. Error envelopes use closed generic details. However, the redaction middleware strips only `Authorization`; it does not strip `Cookie` or `X-Api-Key` as required defense in depth for this audit.

C. Timing equivalence: PASS — `dispatchAuth` performs `sha256 + LookupPartnerKeyByHash` before row presence, revocation, and Origin allowlist checks for keyed requests. Row 3 and rows 5/6/7 share the hash+SELECT path. `subtle.ConstantTimeCompare` is present. The timing test itself is not exercised by the unit run; integration compile succeeded.

D. CORS + Origin: FAIL — preflight is key-agnostic with Max-Age capped to 300 and default 60; Origin normalization lowercases scheme/host, Punycode-encodes IDNs, strips default ports, and treats path/query/fragment as absent. Partner success projection never emits `ACAO: *`. However, auth-failed keyed 401s are explicitly sent through the public CORS branch and emit `Access-Control-Allow-Origin: *`, contrary to §5.7 rows 6/7 which require omit on rejected keyed requests.

E. Rate-limit security: FAIL — auth-failure reserve-then-refund is implemented and untrusted XFF is ignored unless the immediate peer is trusted. But the post-auth “success” limiter is debited before the handler returns, so stale 503, handler 500, and bad-request 400 paths can consume the success bucket. This violates the Step 3 security invariant that only successful 2xx traffic is charged and stale rollup outages must not exhaust quotas.

F. Recover + redaction: FAIL — recover wraps the full subtree and strips `Authorization` again before logging. Panic public log avoids panic string and stack at error level, and the stack is debug-level only. The same Cookie / X-Api-Key redaction gap from category B applies here.

G. Surface attack tests: FAIL — HEAD success responses are bodyless through `writeJSON`, 304 suppresses `X-Stats-Generated-At`, and 405 carries `Allow`. Error envelopes are generic. One low-severity route-surface oddity remains: `trimEndpointFromPath` accepts extra path segments after a known endpoint, so `/v1/stats/overview/anything` is routed as `overview` instead of unknown.

H. Step 4 boundary: PASS — no partner-key CLI surface, nginx config, or Prometheus metric label authoring landed in Step 3. Step 4-only references remain comments/spec prompts.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/mux.go:145`
   - Evidence: `dispatch` debits `m.publicLimit` / `m.partnerLimit` at lines 145-163 before calling `handleOverview`, `handleLeaderboard`, or `handleHealth`. The stale overview branch is inside `handleOverview` at `phase4-coordinator/internal/stats/handlers.go:83`, after the limiter has already incremented.
   - Why: BUILD Step 3 requires post-auth success accounting to track successful 2xx only, and stale 503 responses MUST NOT debit the success bucket. A rollup outage can currently burn the public or partner quota, so healthy clients may receive 429 after recovery or during repeated stale polling.
   - Fix: Wrap the handler with a status-recording response writer or split the flow so freshness/validation happens before success debit. Only commit the public/partner success bucket after a 2xx response; do not charge 400/500/503.

2. `phase4-coordinator/internal/stats/middleware.go:39`
   - Evidence: `redactionContextMiddleware` reads and replaces only `Authorization` at lines 41-46. The recover middleware’s defense-in-depth strip also replaces only `Authorization` at line 73. There is no corresponding `Cookie` or `X-Api-Key` strip.
   - Why: The audit severity model calls this a MEDIUM defense-in-depth gap. Future access-log, trace, or panic-context refactors could capture session cookies or alternate API-key headers even if SPEC-017 currently names only `Authorization`.
   - Fix: In both redaction and recover middleware, delete or replace `Cookie` and `X-Api-Key` alongside `Authorization`; add AC-15 fixtures that panic/log with all three headers and assert no raw values survive.

### LOW
1. `phase4-coordinator/internal/stats/mux.go:137`
   - Evidence: auth-failed keyed requests set public Vary and call `writeCORSHeaders(w, false, ...)`; `writeCORSHeaders` sets `Access-Control-Allow-Origin: *` for public responses at `phase4-coordinator/internal/stats/cors.go:86`.
   - Why: §5.7 rows 6/7 say rejected keyed requests omit ACAO. The response body is generic and not key-derived, so this is not a partner-data leak, but it diverges from the locked CORS table and makes rejected keyed responses browser-readable cross-origin.
   - Fix: For `ar.statusCode == 401`, omit ACAO/credentials instead of using the public CORS branch.

2. `phase4-coordinator/internal/stats/handlers.go:492`
   - Evidence: `trimEndpointFromPath` truncates at the first slash after `/v1/stats/`, so `/v1/stats/overview/extra` routes to `overview`.
   - Why: The public surface is only `/v1/stats/{overview,leaderboard,health}`. Accepting suffix paths broadens cache/routing surface and weakens the requested “no path traversal / prefix oddity” check.
   - Fix: Require the remaining path segment to exactly equal one endpoint and reject any additional slash or suffix.

### INFO
- `dispatchAuth` hashes raw bearer bytes with SHA-256 and performs the partner-key SELECT before Origin allowlist evaluation, preserving row 3/5/6/7 work ordering.
- Store dynamic SQL for leaderboard table/order is allowlisted by validated `window` and `sort`, not user-interpolated directly.
- `cmd/coordinator/main.go` mounts `/v1/stats/` only when stats pools exist and injects the reader pool into the handler.
- `normalizeOrigin` implements lowercase scheme/host, IDN-to-ASCII, default-port stripping, and malformed path/query/fragment handling.
- Step 3 stays inside its boundary: no CLI, nginx, or metric-label implementation was added.

## Positive Security Observations
- Request-path store methods are read-only and do not touch ledger, provider token, rewards ledger, or audit tables.
- Raw bearer material is stored only in request context under an unexported typed key and consumed by the auth dispatcher; no long-lived package global or cache was found.
- Partner-key success CORS never emits `Access-Control-Allow-Origin: *`; server-to-server partner responses omit ACAO when Origin is absent.
- Auth-failure limiter keys by trusted-proxy-aware client IP and ignores spoofed XFF when the trusted proxy list is empty.
- Error details are generic and do not include SQL errors, DSNs, hostnames, internal IPs, token hashes, or raw tokens.

## Final Verdict
CRITICAL: 0  
HIGH: 0  
MEDIUM: 2  
LOW: 2  
INFO: 5

NOT READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
