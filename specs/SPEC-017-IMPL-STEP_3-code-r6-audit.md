# SPEC-017 IMPL Step 3 — Code Audit Round 6

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `f54b3d1` (`impl(017): Step 3 — round-5 test coverage (CODE M + SECURITY M)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r5-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: PASS — overview emits the locked 14-field `network` object and 30 nullable timestamped points per axis; leaderboard keeps public/partner projections separated, always emits `meta.rewards_populated`, gates `partial_history_since` to partial-backfill 30d/all responses, and health derives seven component statuses at request time without selecting a `status` column.
B. Header correctness: PASS — success and error paths use the locked Cache-Control/Vary rows for overview, public leaderboard, partner leaderboard, and health; 304 strips to ETag/Cache-Control/Vary with an empty body; non-304 paths set `X-Stats-Generated-At`; ETags are `sha256(body)` and overview timeseries are snapshot-anchored.
C. Authn flow + crypto: PASS — keyed leaderboard requests hash `sha256([]byte(bearer))` before the `partner_keys` SELECT, matching `internal/auth/tokens.go`; no handler-side raw-token or token-hash `==` / `bytes.Equal` comparison was found; Origin rejection happens after hash+SELECT; RFC 6454 normalization covers scheme/host case, IDN, default ports, and malformed slash/query Origins.
D. Rate-limit buckets: PASS — public and auth-failure buckets include `(client_ip, endpoint)`, partner buckets include `(partner_keys.id, endpoint)`, absent Authorization skips auth-failure, successful partner auth refunds the auth-failure reservation, stale/non-2xx/panic paths refund success buckets, and client-IP derivation ignores untrusted XFF while honoring trusted-proxy CIDRs.
E. Error envelope: PASS — runtime response bodies use only the six §5.9 codes, and 304 remains exempt with no JSON body.
F. Store correctness: PASS — the handler store is injected from the `stats_reader` pool, uses SELECT-only request-path methods, reads `stats_rewards_populated`, avoids forbidden handler SELECTs against `provider_rewards_ledger`, `provider_tokens`, `provider_visibility_audit`, and `ledger_*`, and LEFT JOINs `provider_visibility` for leaderboard visibility defaults.
G. HEAD + 405: PASS — GET/HEAD/OPTIONS are explicitly allowed, HEAD suppresses success and error body bytes, partner HEAD parity is now covered, and POST/PUT/DELETE/PATCH paths set `Allow: GET, HEAD, OPTIONS` with the §5.9 envelope.
H. Tests: FAIL — round 6 adds useful coverage, but the Step 3 test suite still does not provide one clear pass/fail assertion for every locked AC/adversarial case required by the prompt.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:906`
   - Evidence: AC-18 still uses `const N = 30` samples per row at lines 905-922, while the locked Step 3 prompt requires 100+ requests for each of rows 5, 6, and 7. The AC-22 test at lines 443-466 proves 300 401s + 50 429s but still does not assert the required SQL lookup counter `<=300`, and no test drives the required valid-partner-not-capped-at-300 reserve/refund scenario. The §5.7 CORS coverage is still distributed rather than a full seven-row matrix: the new row fixture at lines 1107-1130 covers rows 1 and 6, and partner success at lines 983-1025 covers one matched-Origin partner case, but there is no single row-by-row assertion for all locked §5.7 branches, including absent-Origin with non-empty allowlist and server-to-server empty allowlist.
   - Why: missing or under-strength tests are MEDIUM under the prompt. The runtime code inspected in this round appears conformant, but the lock target requires the test suite to pin timing sample size, pre-SELECT DB-load capping, valid-key auth-failure refunding under load, and the full CORS decision table.
   - Fix: raise AC-18 to 100+ samples per row while staying below the auth-failure threshold; add an auth-store/SQL lookup counter assertion for AC-22; add a 500-request valid-partner fixture proving the auth-failure bucket refunds to zero and partner tier is the only cap; add an explicit §5.7 seven-row CORS table test covering every public, partner, absent-Origin, matched-Origin, rejected-Origin, and empty-allowlist server-to-server branch.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 and AC matrix; prior CODE rounds r1, r2, r3, r4, and r5.
- Round-6 diff reviewed against r5: only `phase4-coordinator/internal/stats/middleware.go` and `phase4-coordinator/internal/stats/handlers_integration_test.go` changed in Step 3 code/test scope.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS (`internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no test files).
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL on pre-existing trailing whitespace in Step 2 audit markdown files and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no Step 3 runtime Go file whitespace was reported.
- Required banned-call grep: FAIL by literal output because it matches the intentional build-tagged `phase4-coordinator/internal/stats/forbidigo_fixture.go`, comments, and lint tests asserting the ban; normal lint passes.
- Store wiring evidence: `phase4-coordinator/cmd/coordinator/main.go:493` mounts stats handlers with `statsstore.New(statsPools.Reader)`.
- Auth evidence: `phase4-coordinator/internal/stats/auth.go:164` computes `sha256.Sum256([]byte(bearer))`, matching `internal/auth/tokens.go:128`'s `sha256(token_utf8_bytes)` discipline.
- Header evidence: `phase4-coordinator/internal/stats/handlers.go:687` returns 304 with only ETag/Cache-Control/Vary, and `phase4-coordinator/internal/stats/envelope.go:96` picks endpoint/projection Cache-Control and Vary for non-304 errors.
- Rate-limit evidence: `phase4-coordinator/internal/stats/mux.go:96` keys auth-failure as `authfail|ip|endpoint`, `mux.go:174` keys partner as `partner|id|endpoint`, and `ratelimit.go:99` derives client IP using trusted-proxy CIDRs.
- Round-5 coverage additions verified: real panic seam `RecoverForTest` at `phase4-coordinator/internal/stats/middleware.go:134`, real panic test at `handlers_integration_test.go:1051`, partner HEAD parity at `handlers_integration_test.go:1135`, all-window partial-history coverage at `handlers_integration_test.go:1186`, and trusted/untrusted XFF coverage at `handlers_integration_test.go:1232`.

## Final Verdict
Counts: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 13 INFO
Verdict: NOT READY TO LOCK
