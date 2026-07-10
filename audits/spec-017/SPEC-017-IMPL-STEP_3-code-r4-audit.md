# SPEC-017 IMPL Step 3 — Code Audit Round 4

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `9632386` (`impl(017): Step 3 — round-3 audit fixes (ARCH 1C+1H + CODE 2H)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r3-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: PASS — overview emits the 14-field network object and 30 timestamped nullable points per axis; leaderboard keeps public/partner projection fields separated, emits `meta.rewards_populated`, gates `partial_history_since` to partial 30d/all windows, and health derives a seven-key component map without selecting a `status` column.
B. Header correctness: PASS — success paths use the locked Cache-Control/Vary rows, 304 carries only ETag/Cache-Control/Vary with an empty body, non-304 responses get `X-Stats-Generated-At`, and round-3 partner error context now selects the private partner header row after successful auth.
C. Authn flow + crypto: PASS — keyed requests hash `sha256([]byte(bearer))` before SELECT, no handler-side token `==` / `bytes.Equal` comparison was found, origin-rejection rows run after hash+SELECT, and request Origin normalization follows the locked RFC 6454 rules. Stored allowlist values are treated as normalized per §5.4.3 CLI issuance contract.
D. Rate-limit buckets: PASS — bucket keys include endpoint dimensions, public/auth-failure use `(client_ip, endpoint)`, partner uses `(partner_keys.id, endpoint)`, absent Authorization skips auth-failure, valid auth reservations are refunded before later error paths, and success-bucket refunds now only run after an actual reservation.
E. Error envelope: PASS — runtime response bodies use only the six §5.9 codes, and 304 remains exempt with no JSON body.
F. Store correctness: PASS — handler store is injected from `stats_reader`, uses SELECT-only request-path methods, reads `stats_rewards_populated`, avoids forbidden OLTP tables, and LEFT JOINs `provider_visibility` for leaderboard visibility defaults.
G. HEAD + 405: PASS — GET/HEAD/OPTIONS are explicitly allowed, HEAD suppresses success and error body bytes, and 405 sets `Allow: GET, HEAD, OPTIONS` plus the §5.9 envelope.
H. Tests: FAIL — round-4 added some coverage, but multiple Step 3-owned ACs and adversarial assertions from the locked prompt remain unpinned.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
1. `phase4-coordinator/internal/stats/handlers_integration_test.go:130`
   - Evidence: the Step 3 handler test file now covers AC-1, AC-2, AC-3, AC-6, AC-7, AC-12, AC-13, AC-14, AC-15 header redaction, AC-21, AC-22 invalid/absent auth-failure behavior, public earnings-total absence, public HEAD, and partial/full `partial_history_since` gating. It still has no explicit tests for AC-4 bucketed public `exact_earnings: null`, AC-5 exact public `exact_earnings`, AC-11 panic recovery, AC-18 rows 5/6/7 timing below the auth-failure threshold, the full §5.4.3 seven-row decision table, the §5.7 seven-row CORS behavior, RFC 6454 GET cases (`HTTPS://Acme.Example`, default port, malformed slash/query), partner HEAD identical headers, all four Cache-Control/Vary cells, partner post-auth error headers, valid-partner-not-capped-at-300, or the required 100 stale + 60 fresh 503-not-debited sequence. The `rg` sweep over `handlers_integration_test.go` only finds tests through `TestAC6_PartnerProjection` and no `TestAC4`, `TestAC5`, `TestAC11`, `TestAC18`, or CORS/503-not-debited coverage.
   - Why: missing tests are MEDIUM under the audit prompt. The remaining gaps are exactly the adversarial assertions that would prevent regressions in projection privacy, timing equivalence, CORS semantics, partner header semantics, and rate-limit refund behavior.
   - Fix: add one clear pass/fail assertion per missing Step 3-owned AC and prompt-specific adversarial case, especially AC-18 timing, AC-11 panic recovery, §5.4.3/§5.7 decision rows, partner HEAD, partner error headers, and stale-503-not-debited.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 and AC matrix; prior CODE rounds r1, r2, and r3.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS (`internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no test files).
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL on pre-existing trailing whitespace in Step 2 audit markdown files and `specs/SPEC-017-IMPL-STEP_3-security-r1-audit.md`; no Step 3 runtime Go file whitespace was reported.
- Required banned-call grep: FAIL by literal output because it matches the intentional build-tagged `phase4-coordinator/internal/stats/forbidigo_fixture.go`, comments, and the lint test asserting the ban; normal lint passes.
- Store wiring evidence: `phase4-coordinator/cmd/coordinator/main.go:493` mounts stats handlers with `statsstore.New(statsPools.Reader)`.
- Auth evidence: `phase4-coordinator/internal/stats/auth.go:164` computes `sha256.Sum256([]byte(bearer))`, matching `internal/auth/tokens.go`'s `sha256(token_utf8_bytes)` discipline.
- Round-3 CODE H1 closure evidence: `phase4-coordinator/internal/stats/mux.go:176` and `phase4-coordinator/internal/stats/mux.go:183` set refund state only after `allow` succeeds.
- Round-3 CODE H2 closure evidence: `phase4-coordinator/internal/stats/mux.go:130` tags successful partner requests and `phase4-coordinator/internal/stats/envelope.go:106` selects the private partner Cache-Control/Vary row for post-auth errors.

## Final Verdict
Counts: 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 12 INFO
Verdict: NOT READY TO LOCK
