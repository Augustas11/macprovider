# SPEC-017 IMPL Step 3 — Code Audit Round 8

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `2b27256` (`impl(017): Step 3 — round-7 test coverage (CODE M + SECURITY M)`)
Prior round: `specs/SPEC-017-IMPL-STEP_3-code-r7-audit.md`
Lens: CODE — SQL/JSON correctness, header semantics, auth-flow crypto, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts
A. JSON shape: PASS — `handlers.go:60-190` still emits the locked overview shape with 14 `network` fields and 30 nullable timeseries points; `handlers.go:325-501` still separates public/partner leaderboard fields, reads `meta.rewards_populated`, and gates `partial_history_since` to Path A 30d/all; `handlers.go:620-666` derives health status at request time over the locked seven-key component set.
B. Header correctness: PASS — success responses use the locked Cache-Control/Vary rows at `handlers.go:187-190`, `handlers.go:476-501`, and `handlers.go:665-666`; 304 is stripped to ETag/Cache-Control/Vary at `handlers.go:686-694`; non-304 responses set `X-Stats-Generated-At` at `handlers.go:697-702`; ETag remains `sha256(body)` via `etag.go:21`.
C. Authn flow + crypto: PASS — stats auth computes `sha256.Sum256([]byte(bearer))` before the `partner_keys` lookup at `auth.go:162-165`, matching `internal/auth/tokens.go`'s UTF-8 byte hash discipline; rows 3/5/6/7 all share hash+SELECT before origin/revocation branching at `auth.go:178-211`; RFC 6454 normalization remains in `origin.go:25-64`; no `==`/`bytes.Equal` token-secret comparison was found in the stats request path.
D. Rate-limit buckets: PASS — auth-failure reserves `(client_ip, endpoint)` before lookup and refunds on valid partner auth at `mux.go:94-125`; success buckets use `(client_ip, endpoint)` for public and `(partner_keys.id, endpoint)` for partner at `mux.go:168-182`; stale overview 503 is checked before success debit at `mux.go:150-157`; non-success refunds remain at `mux.go:193-205`; client-IP derivation honors trusted proxies in `ratelimit.go:96-127`.
E. Error envelope: PASS — `envelope.go:10-16` keeps the closed six-code vocabulary; HEAD drops error bodies at `envelope.go:49-55`; 304 bypasses the envelope and body entirely at `handlers.go:686-694`.
F. Store correctness: PASS — request-path store methods are SELECT-only; leaderboard reads `stats_leaderboard_*` with `LEFT JOIN provider_visibility` at `store/leaderboard.go:56-68`; rewards are read from `stats_rewards_populated` at `store/leaderboard.go:143-145`; health reads `stats_components_health` columns without a status column at `store/health.go:43-48`; no handler/store SELECT against `provider_rewards_ledger`, `provider_tokens`, `provider_visibility_audit`, or `ledger_*` was found.
G. HEAD + 405: PASS — mux accepts GET/HEAD and sets `Allow: GET, HEAD, OPTIONS` on unsupported verbs at `mux.go:76-80`; `writeJSON` suppresses HEAD bodies at `handlers.go:704-706`; tests pin GET/HEAD parity and empty body at `handlers_integration_test.go:302-321` and `handlers_integration_test.go:1181-1229`.
H. Tests: PASS — r7's remaining MEDIUM is closed: AC-22 now asserts `partner_keys` lookup count `<=300` at `handlers_integration_test.go:444-486`; the valid-partner 500-request refund path asserts final auth-failure count `0` at `handlers_integration_test.go:1499-1552`; §5.7 row 4 server-to-server CORS omission is pinned at `handlers_integration_test.go:1583-1631`.

## Findings
### CRITICAL
None.

### HIGH
None.

### MEDIUM
None.

### LOW
None.

### INFO
- Required reading completed: locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections §1.5, §4.3, §5.1, §5.2, §5.3, §5.4, §5.6, §5.7, §5.8, §5.9, §9.1, §9.5, §9.7; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 3 block and AC-to-step matrix; prior CODE audit `specs/SPEC-017-IMPL-STEP_3-code-r7-audit.md`.
- Round-8 diff reviewed against r7: runtime additions are test seams only (`Store.LookupHashCountForTest`, `limiter.CountForTest`, `Mux.AuthFailureCountForTest`) plus integration tests; handler wire behavior is unchanged.
- AC-22 closure evidence: 350 invalid bearer requests assert 300 `401`, 50 `429`, and `LookupHashCountForTest() <= 300` at `handlers_integration_test.go:466-486`.
- Auth-failure refund closure evidence: 500 valid partner requests assert 500 `200`, zero `429`, and `AuthFailureCountForTest("192.0.2.1", "leaderboard") == 0` at `handlers_integration_test.go:1530-1552`.
- §5.7 row 4 closure evidence: empty-allowlist partner key with absent Origin asserts 200 partner projection, omitted `Access-Control-Allow-Origin`, omitted `Access-Control-Allow-Credentials`, and partner `Vary` containing `Authorization` at `handlers_integration_test.go:1611-1631`.
- AC coverage evidence remains present for overview shape (`handlers_integration_test.go:131-181`), invalid window and bad_request (`handlers_integration_test.go:187-205`), invalid bearer unauthorized (`handlers_integration_test.go:212-223`), OPTIONS preflight (`handlers_integration_test.go:241-255`), stale 503 (`handlers_integration_test.go:261-279`), 405 envelope (`handlers_integration_test.go:286-298`), 304 stripping (`handlers_integration_test.go:345-365`), health degraded/down (`handlers_integration_test.go:370-380`), partial history windows (`handlers_integration_test.go:1234-1274`), timing equivalence with 100 samples below cap (`handlers_integration_test.go:926-941`), and no trace imports (`handlers_integration_test.go:1642-1668`).
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./internal/stats/... -count=1`: PASS (`internal/stats`, `internal/stats/migrations`, `internal/stats/rollup`; store has no test files).
- `go test -tags=integration -c ./internal/stats -o /tmp/stats-integ.test`: PASS.
- `gofmt -l phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go`: PASS, no output.
- `golangci-lint run --config=.golangci.yml ./...`: PASS, `0 issues`.
- `git diff --check origin/main...HEAD`: FAIL only on pre-existing trailing whitespace in earlier Step 2 audit markdown and Step 3 security r1 audit markdown; no Step 3 Go file or r8 audit artifact whitespace issue was reported.
- Required banned-call grep: literal grep returns matches for the intentional `forbidigo_fixture.go` build-tagged `os.Exit(1)` fixture and lint-test comments/assertions; `golangci-lint` passes and production stats code has no banned call.

## Final Verdict
Counts: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 13 INFO
Verdict: READY TO LOCK
