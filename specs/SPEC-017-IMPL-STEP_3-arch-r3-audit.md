# SPEC-017 IMPL Step 3 - Architecture Audit Round 3

Branch: `impl/spec-017-step-1`
HEAD audited: `78466816141d9c3b773f2bc43c927374e6d83432` (`impl(017): Step 3 - round-2 audit fixes (1C + 6H + 3M)`)
Diff base: Step 2 converged tip `bd68a0a`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_3-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_3-arch-r2-audit.md`

Verdict: NOT READY TO LOCK -
1 CRITICAL + 1 HIGH + 1 MEDIUM + 0 LOW + 10 INFO

## Validation evidence
- `git diff --name-only bd68a0a..HEAD -- phase4-coordinator/` - scoped Step 3 delta to `cmd/coordinator/main.go`, `.golangci.yml`, `go.mod`, `internal/stats/{auth,cors,envelope,etag,handlers,health_status,middleware,mux,origin,ratelimit}.go`, `internal/stats/store/*`, migrations, rollup, and Step 3 tests.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/...` - PASS: `internal/stats`, migrations, rollup; store has no tests.
- `go test -tags=integration -c ./internal/stats` - PASS compile smoke.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` - FAIL against this audit prompt's explicit handler-package allowlist because `golang.org/x/net/idna` is still imported; no forbidden internal imports (`internal/ws`, `internal/explorer`, `internal/billing`, `internal/buyer`, `internal/session`) were present.
- `gofmt -l ./internal/stats` - PASS, no output.
- `git diff --check origin/main...HEAD` - FAIL on pre-existing audit markdown trailing whitespace under `specs/SPEC-017-IMPL-STEP_2-*` and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no inspected phase4 Step 3 code whitespace errors were reported.
- `git diff --check bd68a0a..HEAD -- phase4-coordinator/` - PASS, no output.

## Category Verdicts
A. Endpoint + projection scope vs Step 4 boundary: FAIL - Step 3 stays in handler/store scope, but the auth dispatcher is applied to `/overview` and `/health` even though those endpoints are locked as unauthenticated public surfaces.
B. Middleware stack ordering: FAIL - the stack order is structurally present, but auth-failure reservation plus auth dispatch runs for all endpoints, so public endpoints can be rejected or partner-key metered before their handlers.
C. §5.4.3 partner-key authn flow: PASS for `/leaderboard` - keyed leaderboard requests still hash+SELECT before Origin branching and do not touch `last_used_at`.
D. CORS per §5.7: FAIL - partner success responses avoid `ACAO: *`, but preflight only checks static config and does not collect the active `partner_keys.allowed_origins` union required by the global allowlist rule.
E. Header surface: PASS - the round-2 ETag snapshot-anchor issue is closed, 304 omits `X-Stats-Generated-At`, and response Cache-Control/Vary rows are present for the returned projection.
F. Endpoint contract: FAIL - `/overview` and `/health` no-auth contracts are broken by global partner-key auth dispatch; the empty-leaderboard snapshot metadata issue is closed.
G. 503 + rate-limit semantics: PASS with caveat - stale 503s are refunded/skipped, absent Authorization skips the auth-failure tier, and AC-22-style invalid bearer floods cap before repeated DB work; endpoint auth-scope is raised under A/B/F.
H. Failure modes + main.go integration: FAIL - main uses the `stats_reader` store and same binary mount, but the handler package import graph still exceeds the prompt allowlist.

## Findings
### CRITICAL
1. `phase4-coordinator/internal/stats/mux.go:98`
   - Evidence: `dispatch` runs the auth-failure limiter and `dispatchAuth` for every endpoint after `endpoint := trimEndpointFromPath(...)`, not only for `leaderboard` (`mux.go:78-130`). A request like `GET /v1/stats/overview` or `/v1/stats/health` with `Authorization: Bearer mpk_invalid` enters the auth-failure bucket (`mux.go:98-107`), hashes/selects in the auth dispatcher, and returns 401 before the public handler (`mux.go:109-130`). A valid partner key on those endpoints also flows through the partner tier (`mux.go:169-181`) and passes `ar.projection == "partner"` into `writeJSON`, which makes the otherwise-public response use partner CORS (`handlers.go:187-190`, `handlers.go:665-666`, `handlers.go:697-702`).
   - Why: SPEC §4.3 locks `/v1/stats/overview` and `/v1/stats/health` as `Auth: None`, while only `/v1/stats/leaderboard` has optional `Bearer <partner_key>`. SPEC §5.1 further locks overview `Vary: Accept-Encoding, Origin` with no `Authorization` because overview ignores it, and §5.3 says health has no auth and must return 200 for rollup degradation. Applying the §5.4.3 partner-key decision table to all endpoints breaks the public endpoint contract and lets an irrelevant Authorization header change status, rate-limit tier, and CORS.
   - Fix: scope layers 4-5 partner-key auth to `endpoint == "leaderboard"` only. For `overview` and `health`, synthesize a public `authResult` with normalized Origin for public CORS, skip the auth-failure reservation entirely, and use the public `(client_ip, endpoint)` success bucket. Add regression tests that `GET` and `HEAD` for `/overview` and `/health` with malformed, invalid, and valid partner Authorization return the same status/body/header class as anonymous requests.

### HIGH
1. `phase4-coordinator/internal/stats/cors.go:55`
   - Evidence: `servePreflight` decides whether to echo Origin by checking only `cors.PartnerOriginAllowlist` (`cors.go:55-60`). `cmd/coordinator/main.go` wires that from `cfg.Stats.CORS.PartnerOriginAllowlist` (`main.go:496-498`), and there is no store method that reads active `partner_keys.allowed_origins` for preflight. SPEC §5.7 says the global partner-origin allowlist is collected as the union of every active `partner_keys.allowed_origins` array plus the well-known console/portal origins.
   - Why: Step 4.A will issue partner keys by inserting `allowed_origins` into `partner_keys`. With the current Step 3 design, a browser partner origin stored only in that key row gets preflight `Access-Control-Allow-Origin: *` and no `Access-Control-Allow-Credentials`, even though the subsequent keyed GET would accept the same normalized Origin. That structurally misaligns Step 3 preflight behavior with the Step 4 partner-key CLI surface and can make conforming browser partner integrations fail unless operators duplicate every key origin into YAML.
   - Fix: add a request-path store method such as `ActivePartnerOrigins(ctx)` that SELECTs `allowed_origins` from non-revoked partner keys, normalizes/filters the entries, and unions them with the configured well-known/static origins for OPTIONS. Cache the union for at most the 60s preflight max-age if needed, but keep revocation/update behavior bounded. Add a test that seeds a key with `allowed_origins = ARRAY['https://acme.example']` and verifies preflight from that Origin echoes it without requiring a YAML duplicate.

### MEDIUM
1. `phase4-coordinator/internal/stats/origin.go:7`
   - Evidence: `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats` still reports `golang.org/x/net/idna`, and `origin.go:7` imports it. Round-2 added a `.golangci.yml` comment documenting local approval (`.golangci.yml:42-57`), but this round's audit prompt still defines the handler-package validation allowlist as standard library, `internal/auth` for shared hash helpers only, `internal/config`, `internal/stats/store`, optional `internal/pool`, and `github.com/rs/zerolog`.
   - Why: this is the same prior ARCH MEDIUM import-boundary issue. The IDNA dependency is justified by the RFC 6454 IDN-to-Punycode requirement, but the controlling audit validation still fails; two conforming Step 3 sessions can still disagree between accepting the dependency via local lint comment and requiring a controlling prompt/spec boundary update.
   - Fix: either amend the controlling Step 3 dependency boundary to explicitly allow `golang.org/x/net/idna`, or move the normalization behind an approved local helper/package and update the allowlist/tests accordingly.

### LOW
- None.

### INFO
- `phase4-coordinator/internal/stats/handlers.go:170-182` now aligns overview `rpm_30m` and `tpm_30m` points to `ov.GeneratedAt`, closing the round-2 ETag snapshot-anchor finding.
- `phase4-coordinator/internal/stats/store/health.go:22-40` and `handlers.go:375-385` now read `stats_components_health.generated_at` for empty leaderboard pages, closing the round-2 empty-snapshot metadata finding.
- `phase4-coordinator/internal/stats/handlers.go:397-401` still reads `stats_rewards_populated` rather than querying `provider_rewards_ledger` synchronously.
- `phase4-coordinator/internal/stats/handlers.go:495-499` and `handlers.go:541-567` gate `partial_history_since` on `BackfillMode == "partial"`, non-empty config, and 30d/all windows.
- `phase4-coordinator/internal/stats/mux.go:73-75` keeps preflight key-agnostic and returns through `servePreflight` before auth dispatch.
- `phase4-coordinator/internal/stats/mux.go:84-89` explicitly allows GET/HEAD and returns 405 with `Allow: GET, HEAD, OPTIONS` for other methods.
- `phase4-coordinator/internal/stats/mux.go:139-155` refunds successful auth-failure reservations before freshness/error paths and emits overview stale 503 before success-bucket debit.
- `phase4-coordinator/internal/stats/mux.go:177-189` refunds public/partner success buckets on non-2xx handler responses, preserving stale-503 quota isolation.
- `phase4-coordinator/internal/stats/cors.go:77-87` prevents partner projection responses from emitting `Access-Control-Allow-Origin: *`.
- `phase4-coordinator/cmd/coordinator/main.go:493-505` mounts the same stats handler subtree through the coordinator binary with `statsstore.New(statsPools.Reader)`, preserving request-path DB role isolation.

## Round-(M-1) Closure Checks
- r2 CRITICAL 1 (overview ETag computed off request-time anchor): closed. Evidence: `handlers.go:170-182` calls `alignRpmPoints(rpm, ov.GeneratedAt)` and `alignTpmPoints(tpm, ov.GeneratedAt)`; `writeJSON` hashes that snapshot-anchored body at `handlers.go:679-687`.
- r2 HIGH 1 (empty leaderboard emits year-1 generated_at instead of snapshot time): closed. Evidence: `handlers.go:375-385` uses `Store.ComponentGeneratedAt(ctx, "leaderboard_"+window)` for empty tables, and `store/health.go:22-40` reads `stats_components_health.generated_at`.
- r2 MEDIUM 1 (IDNA import outside prompt allowlist): still open; re-raised as MEDIUM 1. The new `.golangci.yml` comment documents an intended approval, but the required `go list` validation still exceeds the operator-paste allowlist for this audit round.

## Final Verdict
READY TO LOCK: NO
Blocking count: 1 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW / 10 INFO
