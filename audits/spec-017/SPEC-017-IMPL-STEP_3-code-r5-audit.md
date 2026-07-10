# SPEC-017 IMPL Step 3 — Code Audit Round 5

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `220181a` (`impl(017): Step 3 — round-4 audit fixes (ARCH 1M + SECURITY 1M + test coverage)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r4-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: PASS — overview still emits the locked 14-field network object plus 30 nullable timestamped points per axis; leaderboard keeps public and partner projections separated, keeps `meta.rewards_populated`, and gates `partial_history_since` to partial-backfill 30d/all responses; health derives seven component statuses at request time without selecting a `status` column.
B. Header correctness: PASS — code paths use the locked Cache-Control/Vary rows for overview, public leaderboard, partner leaderboard, and health; 304 strips to ETag/Cache-Control/Vary with an empty body; non-304 paths set `X-Stats-Generated-At`; ETags are `sha256(body)`.
C. Authn flow + crypto: PASS — keyed leaderboard requests hash `sha256([]byte(bearer))` before the `partner_keys` SELECT, no handler-side raw token or token-hash `==` / `bytes.Equal` comparison was found, origin rejection happens after hash+SELECT, and RFC 6454 normalization covers scheme/host case, IDN, default ports, and malformed slash/query Origins.
D. Rate-limit buckets: PASS — public and auth-failure buckets include `(client_ip, endpoint)`, partner buckets include `(partner_keys.id, endpoint)`, absent Authorization skips auth-failure, successful partner auth refunds the auth-failure reservation before later errors, and round-5 code now refunds success-bucket slots when a panic leaves the recorder status at zero.
E. Error envelope: PASS — runtime error bodies use only the six §5.9 codes, and 304 remains exempt with no JSON body.
F. Store correctness: PASS — the handler store is injected from the `stats_reader` pool, uses SELECT-only request-path methods, reads `stats_rewards_populated`, avoids forbidden request-path SELECTs against `provider_rewards_ledger`, `provider_tokens`, `provider_visibility_audit`, and `ledger_*`, and LEFT JOINs `provider_visibility` for leaderboard visibility defaults.
G. HEAD + 405: PASS — GET/HEAD/OPTIONS are explicitly allowed, HEAD suppresses success and error body bytes, and POST/PUT/DELETE/PATCH paths set `Allow: GET, HEAD, OPTIONS` with the §5.9 envelope.
H. Tests: FAIL — round 5 closes several prior gaps, but the Step 3 test suite still does not provide one clear pass/fail assertion for every locked AC/adversarial case required by the prompt.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:803`
   - Evidence: the AC-11 test explicitly says it cannot inject a real panic and substitutes 400-path refund coverage at lines 807-813, so it does not assert `500 internal`, `event=stats_handler_panic`, panic-log redaction, or `/healthz` survival. The AC-18 timing test uses `const N = 30` at line 906, below the required 100+ requests per row. The §5.7 CORS coverage at lines 980-1025 drives only one partner success row, not all seven rows. The HEAD test at lines 301-321 sends only public requests, so partner HEAD identical-headers coverage is missing. The partial-history test at lines 497-550 covers 30d include, 30d full-mode omit, and 24h omit, but not `window=all` include or `window=7d` omit. The AC-22 test at lines 443-466 counts 401/429 responses but does not assert the required SQL lookup counter `<=300`; no test covers the valid-partner-not-capped-at-300 reserve/refund case or trusted/untrusted `X-Forwarded-For` behavior.
   - Why: missing or under-strength tests are MEDIUM under the prompt. These gaps are the remaining lock blocker because they leave panic recovery, timing equivalence, full CORS decision rows, partner HEAD, partial-history window gating, auth-failure DB-load capping, valid-partner refunding, and trusted-proxy client-IP derivation unpinned.
   - Fix: add direct fixtures for the missing cases: an injected panic path that asserts the 500 envelope/log redaction/healthz survival, AC-18 with 100+ samples per row below the 300 rpm cap, full §5.4.3 and §5.7 row matrices, partner HEAD header comparison, 30d/all include plus 24h/7d omit for partial history, AC-22 SQL SELECT counting, valid partner 500-request refund proof, and trusted/untrusted XFF limiter tests.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 and AC matrix; prior CODE rounds r1, r2, r3, and r4.
- Round-5 diff reviewed against r4: `phase4-coordinator/internal/stats/mux.go` and `phase4-coordinator/internal/stats/handlers_integration_test.go` are the only runtime/test files changed since `9632386`.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS (`internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no test files).
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL on pre-existing trailing whitespace in Step 2 audit markdown files and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no Step 3 runtime Go file whitespace was reported.
- Required banned-call grep: FAIL by literal output because it matches the intentional build-tagged `phase4-coordinator/internal/stats/forbidigo_fixture.go`, comments, and lint tests asserting the ban; normal lint passes.
- Store wiring evidence: `phase4-coordinator/cmd/coordinator/main.go:493` mounts stats handlers with `statsstore.New(statsPools.Reader)`.
- Auth evidence: `phase4-coordinator/internal/stats/auth.go:164` computes `sha256.Sum256([]byte(bearer))`, matching `internal/auth/tokens.go`'s `sha256(token_utf8_bytes)` discipline.
- Round-4 SECURITY M1 closure evidence: `phase4-coordinator/internal/stats/mux.go:202` refunds the success bucket when `rec.status == 0`, so a panic before `WriteHeader` is not counted as a successful request.
- Newly added positive coverage evidence: AC-4 bucketed public `exact_earnings: null` at `handlers_integration_test.go:706`, AC-5 exact public `exact_earnings` at `handlers_integration_test.go:758`, stale-503-not-debited at `handlers_integration_test.go:841`, and method matrix coverage at `handlers_integration_test.go:1028`.

## Final Verdict
Counts: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 13 INFO
Verdict: NOT READY TO LOCK
