# SPEC-017 IMPL Step 3 — Code Audit Round 7

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `5fbf18e` (`impl(017): Step 3 — round-6 test coverage closure (final test batch)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r6-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: PASS — runtime handlers were unchanged from round 6 and still emit the locked overview 14-field network object plus 30 nullable timeseries points, separated leaderboard public/partner projections with `meta.rewards_populated`, 30d/all-only `partial_history_since`, and a seven-key health components map with request-time status derivation.
B. Header correctness: PASS — success, error, HEAD, and 304 paths still use the locked Cache-Control/Vary rows; 304 is stripped to ETag/Cache-Control/Vary and empty body; non-304 paths set `X-Stats-Generated-At`; ETags are `sha256(body)`.
C. Authn flow + crypto: PASS — keyed leaderboard requests hash `sha256([]byte(bearer))` before `partner_keys` lookup, match `internal/auth/tokens.go`'s token byte discipline, perform Origin rejection after lookup, and use RFC 6454 normalization for allowlist comparison.
D. Rate-limit buckets: PASS — code keys public/auth-failure buckets by `(client_ip, endpoint)`, partner buckets by `(partner_keys.id, endpoint)`, skips auth-failure when Authorization is absent, reserves auth-failure before auth lookup, refunds it on valid partner auth, and refunds success buckets for non-success paths including stale 503 and panic-before-status.
E. Error envelope: PASS — runtime responses use only the six §5.9 codes; 304 remains exempt with no JSON envelope.
F. Store correctness: PASS — handler/store request path is injected with `stats_reader`, uses SELECT-only DAO methods, reads `stats_rewards_populated`, avoids forbidden handler SELECTs against `provider_rewards_ledger`, `provider_tokens`, `provider_visibility_audit`, and `ledger_*`, and LEFT JOINs `provider_visibility`.
G. HEAD + 405: PASS — GET/HEAD/OPTIONS are explicitly allowed; HEAD suppresses body bytes; 405 sets `Allow: GET, HEAD, OPTIONS` with the §5.9 envelope.
H. Tests: FAIL — round 7 closes many prior test gaps, but the Step 3 suite still lacks the prompt-required AC-22 SQL lookup counter assertion and does not pin the complete literal §5.7 CORS matrix.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:443`
   - Evidence: `TestAC22_AuthFailureLimiter` still asserts only response counts: 300 `401` and 50 `429` for 350 invalid-bearer requests at lines 443-466. It does not instrument or assert the required `partner_keys` SELECT/SQL lookup counter `<=300`. `TestValidPartnerKey500ReqNoAuthFailureCap` at lines 1476-1522 proves 500 valid partner requests are not capped at 300, but it also asserts only status counts, not the final auth-failure bucket counter promised in its comment. `TestSection_5_7_CORSMatrix` at lines 1328-1424 covers several auth/CORS branches, but it does not include the locked §5.7 row 4 case: valid partner key with `allowed_origins = '{}'` and absent Origin must return 200 while omitting both `Access-Control-Allow-Origin` and `Access-Control-Allow-Credentials`. `TestPartnerHEADParity` at lines 1160-1205 sends that server-to-server shape, but it only compares GET/HEAD parity and does not assert the required omission semantics.
   - Why: missing or under-strength tests are MEDIUM under the prompt. The inspected runtime code appears to enforce the AC-22 pre-SELECT limiter and the §5.7 server-to-server branch correctly, but the lock target asks the Step 3 test suite to pin those exact adversarial observations.
   - Fix: add a counting `stats_reader`/store seam or query-hook wrapper around `LookupPartnerKeyByHash` and assert invalid-bearer lookup count `<=300` after 350 requests; expose/inspect the auth-failure bucket count or equivalent counter for the 500 valid-key refund test; add a literal §5.7 row 4 fixture asserting status 200, `Access-Control-Allow-Origin == ""`, and `Access-Control-Allow-Credentials == ""`.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 block and AC-to-step matrix; prior CODE rounds r1 through r6.
- Round-7 diff reviewed against r6: runtime code is unchanged; only `phase4-coordinator/internal/stats/handlers_integration_test.go` plus audit markdown changed in Step 3 scope.
- New round-7 coverage evidence: AC-18 now uses 100 samples per row at `handlers_integration_test.go:905`; panic recovery redaction sweep is broadened at `handlers_integration_test.go:1054`; §5.7 matrix was added at `handlers_integration_test.go:1328`; active-key preflight union at `handlers_integration_test.go:1432`; valid partner 500-request no-cap at `handlers_integration_test.go:1476`; sibling subdomain reject at `handlers_integration_test.go:1529`.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS (`internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no test files).
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL on pre-existing trailing whitespace in Step 2 audit markdown and early Step 3 security audit markdown; no Step 3 Go file whitespace was reported.
- Required banned-call grep: FAIL by literal output because it matches the intentional build-tagged `phase4-coordinator/internal/stats/forbidigo_fixture.go` plus lint tests/comments asserting the ban; normal lint passes.
- Store wiring evidence: `phase4-coordinator/cmd/coordinator/main.go:493` mounts stats handlers with `statsstore.New(statsPools.Reader)`.
- Auth/rate-limit evidence: `phase4-coordinator/internal/stats/mux.go:96` reserves `authfail|ip|endpoint` before auth lookup; `mux.go:124` refunds on auth success; `mux.go:174` keys partner success by `partner|id|endpoint`; `phase4-coordinator/internal/stats/auth.go:164` computes `sha256.Sum256([]byte(bearer))`.

## Final Verdict
Counts: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 12 INFO
Verdict: NOT READY TO LOCK
