## Verdict

REQUEST CHANGES

Blocking count: 0 CRITICAL / 1 HIGH / 2 MEDIUM / 2 LOW / 1 INFO.

## Validation evidence

- `git rev-parse --short HEAD` -> `9ef3d92`.
- `git merge-base HEAD main` -> `e816dffb82cb08a9c8010a467498f9e6a1ac09f9`.
- `git diff --name-only $(git merge-base HEAD main)..HEAD | wc -l` -> `189`.
- `gofmt -l $(git diff --name-only $(git merge-base HEAD main)..HEAD -- '*.go')` -> exit 0, no files printed.
- `go vet ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/` -> exit 0, no diagnostics.
- `golangci-lint run ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/` -> exit 0, `0 issues.`
- `go test -tags=integration -count=0 ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/` -> exit 0; all target packages compiled, with `[no tests to run]` where expected.
- `go test -race -count=1 ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/` -> exit 0; all target packages passed under the race detector.
- `go test -tags=integration -count=1 -timeout 15m -v -run 'TestAC[0-9]+_|TestStep4C_|TestForbidigoOSExitRule|TestLabelHygiene|TestAC16ForbiddenImportFails|TestVisibilityExactVerbHardRejected' ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/` -> exit 0; AC and Step 4.C integration subset passed. Slowest observed test was `TestAC18_TimingEquivalenceRows5_6_7` at 69.42s.
- Manual code sweep covered dynamic SQL construction, request observation mutation, rollup cancellation paths, error sinks, nginx rate-limit directives, money/rebuild drift math, cited AC tests, production-visible `ForTest` seams, and partner-key event emission.

## Findings

### HIGH 1 - Production nginx config violates locked v0.1.8 no-burst rate-limit contract

Evidence:

- `specs/SPEC-017-network-stats-api.md:1116` says `v0.1.8 drops the burst column entirely`.
- `specs/SPEC-017-network-stats-api.md:1117` says `public tier is a hard 60 req/min per IP per endpoint with no burst absorption`.
- `specs/SPEC-017-network-stats-api.md:1120` requires ``limit_req zone=<name> nodelay;` (no `burst=` parameter)`.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md:569` says the location block `MUST use limit_req zone=<name> nodelay; with NO burst= parameter`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:110` uses `limit_req zone=stats_overview burst=59 nodelay;`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:138` uses `limit_req zone=stats_leaderboard burst=59 nodelay;`.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:161` uses `limit_req zone=stats_health burst=59 nodelay;`.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:213`, `:233`, and `:253` repeat the same `burst=59 nodelay` directives.
- `phase4-coordinator/dist/nginx-stats.streamvc.live.conf:20` through `:28` documents the intentional reinterpretation: `1 in-rate token + 59 burst capacity = 60`.

Risk:

The production edge config contradicts the locked controlling contract. Under nginx `limit_req`, `burst=59 nodelay` intentionally adds a 59-request excess queue admitted without delay. That likely makes the first-60/61st AC check pass, but it does so by reintroducing burst absorption that v0.1.8 explicitly removed. This is not just a comment mismatch: all six deployable stats locations carry the forbidden parameter.

Fix direction:

Either remove `burst=59` from every stats `limit_req` directive and update tests/docs to the strict nginx behavior, or reopen the SPEC and BUILD prompt before merge. Do not ship a production config that knowingly violates `NO burst=` in the locked contract.

### MEDIUM 1 - Rollup failure health updates ignore cancellation and can outlive shutdown

Evidence:

- `phase4-coordinator/internal/stats/rollup/runner.go:233` calls `fn(ctx)`, so the rollup tick receives the caller's cancellation context.
- `phase4-coordinator/internal/stats/rollup/runner.go:240` then records failures with `healthFail(context.Background(), r.db, c, time.Now().UTC(), err.Error())`.
- `phase4-coordinator/internal/stats/rollup/runner.go:226` does the same on panic recovery: `healthFail(context.Background(), ...)`.
- `phase4-coordinator/internal/stats/rollup/health.go:65` passes that context to `db.ExecContext`.

Risk:

On shutdown or context cancellation, the main rollup function can stop promptly, but the error/panic path can still block in `healthFail` under `context.Background()`. If the database is slow or partitioned, `Runner.Wait()` can be held by an uncancellable health update even though the tick's owning context was canceled.

Fix direction:

Use the tick context, or a short bounded context derived from it, for `healthFail`. If preserving best-effort error recording after cancellation is required, cap it with a small timeout and make shutdown behavior explicit in tests.

### MEDIUM 2 - Rollup error path persists unsanitized `err.Error()` into health state

Evidence:

- `phase4-coordinator/internal/stats/rollup/runner.go:235` logs the raw error with `.Err(err)`.
- `phase4-coordinator/internal/stats/rollup/runner.go:240` persists `err.Error()` into `healthFail`.
- `phase4-coordinator/internal/stats/rollup/health.go:51` accepts `errMsg string`.
- `phase4-coordinator/internal/stats/rollup/health.go:62` writes it to `last_error_message`.
- `phase4-coordinator/internal/stats/rollup/health.go:55` through `:58` truncates long messages, but does not redact DSNs, token-shaped strings, hashes, or other secret-shaped bytes.

Risk:

The panic path now classifies panics by type, but ordinary returned errors still cross directly into structured logs and `stats_components_health.last_error_message`. Current searched production rollup code does not obviously construct errors from raw partner keys or token hashes, but this sink has no redaction boundary and `runOne` accepts any `fn func(context.Context) error`. A lower-layer or future error containing a DSN, credential, token hash, or token-shaped string would be persisted.

Fix direction:

Apply the same discipline as `classifyPanic`: persist and label a bounded error class/category, not raw error text. If raw details are needed for operator diagnostics, route them only to a vetted sink with redaction and avoid storing them in `stats_components_health`.

### LOW 1 - `RunTickOnceForTest` and other `ForTest` seams are exported in production builds

Evidence:

- `phase4-coordinator/internal/stats/rollup/runner.go:145` defines exported `RunTickOnceForTest` in a normal production `.go` file.
- `phase4-coordinator/internal/stats/rollup/runner.go:160` exposes `func (r *Runner) RunTickOnceForTest(...)`.
- `phase4-coordinator/internal/stats/rollup/runner.go:153` through `:157` documents a required component invariant, then explicitly allows `comp=""` to drive the success-skip branch.
- `phase4-coordinator/internal/stats/rollup/runner.go:260` through `:261` skips success health/event handling when `c == ""`.
- A non-test-file sweep also found production-visible `ForTest` surfaces in `internal/stats/store/store.go`, `internal/stats/ratelimit.go`, `internal/stats/mux.go`, `internal/stats/middleware.go`, and `internal/stats/rollup/testseam.go`.

Risk:

The current non-test call graph does not call `RunTickOnceForTest`, and the integration tests use it intentionally. The problem is static containment: production packages can import and call these exported seams because they are not in `_test.go` files or otherwise build-constrained. In particular, the rollup seam can bypass the production scheduler and can pass `comp=""`, a path the production tick loop reserves for a special scalar check.

Fix direction:

Move test-only export seams behind test-only compilation where possible, or add an explicit static guard that fails if `RunTickOnceForTest` or related seams are referenced from non-test files. For the rollup seam, consider an `internal/.../rolluptest` helper used only by integration-tagged tests plus depguard/static analysis that forbids production imports.

### LOW 2 - Step 4 self-claim artifacts are stale relative to the audited HEAD

Evidence:

- Current audited HEAD is `9ef3d92`.
- `specs/SPEC-017-IMPL-STEP_4-convergence.md:6` says `HEAD: 9784ef5`.
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md:5` says `HEAD swept: 5ceb230`.

Risk:

The final validation commands in this audit passed on `9ef3d92`, so this is not a runtime correctness failure by itself. It does mean the cited convergence and 22-AC sweep documents are not evidence for the exact code under final review, and they also helped normalize the forbidden `burst=59` interpretation.

Fix direction:

Refresh or supersede the Step 4 convergence and AC sweep records for `9ef3d92`, and make them explicitly subordinate to the locked SPEC where they disagree.

### INFO 1 - `emitPartnerKeyEvent` relies on caller discipline for secret-free JSON fields

Evidence:

- `phase4-coordinator/cmd/coordinator/partnerkeys.go:313` through `:318` calls `emitPartnerKeyEvent` with `id`, `label`, `created_by`, and `rotated_from_id`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:449` through `:453` calls it with `id`, `reason`, and `actor`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:466` through `:468` says the field set must never contain raw token, token body, or token hash bytes.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:469` accepts `fields map[string]any`, and `:474` JSON-encodes the map.

Risk:

Current callers pass only expected int/string fields and do not include token material. The helper itself is not statically closed, so a future caller could pass secret-shaped bytes and the encoder would write them to stderr without redaction.

Fix direction:

Prefer typed event structs or event-specific emitters over `map[string]any`, or add a static test that enumerates allowed field names and value types for each partner-key event.

## Category sweep

- A. SQL injection / parameter mis-binding: PASS. Dynamic table/order SQL is constrained by closed switch helpers (`leaderboardTable`, `leaderboardOrder`, `leaderboardTableForWindow`) and user values are parameter-bound. I did not find user- or config-derived strings interpolated into SQL.
- B. Concurrent-write hazards: PASS. The request observation pointer is created per request, written synchronously before the handler returns, and read by access logging after `next.ServeHTTP` returns. The targeted race run passed.
- C. Context cancellation correctness: FAIL. Rollup `fn(ctx)` is cancellable, but failure/panic health updates use `context.Background()` and can outlive shutdown.
- D. Error-path label leaks: FAIL. Panic classification is type-only, but ordinary rollup errors still persist raw `err.Error()` into `last_error_message`.
- E. Off-by-one / boundary bugs: FAIL. I did not find a 60-vs-61 arithmetic off-by-one in the `burst=59 nodelay` explanation; the blocking issue is stronger: the locked SPEC and BUILD prompt require no `burst=` at all.
- F. Money math: PASS. The rebuild path uses exact numeric handling for row construction, and the float conversion is confined to drift telemetry with a zero-safe denominator. I did not find a divide-by-zero, sign-flip, or ranking monotonicity bug.
- G. Test claims vs test behavior: PASS with caveat. The AC tests I opened generally inspect response bodies and database state, not just status codes. The caveat is that the cited sweep documents are stale relative to `9ef3d92`.
- H. `Runner.RunTickOnceForTest`: FAIL. It is exported from a production build file and callable by production code even though current non-test call sites do not use it.
- I. `emitPartnerKeyEvent map[string]any`: PASS with INFO. Current callers are secret-free, but the helper has no static closed field type.
- J. Gofmt / vet / lint clean: PASS. `gofmt`, `go vet`, and `golangci-lint` were clean.
- K. Test compile coverage: PASS. `go test -tags=integration -count=0` compiled the requested packages.
- L. Anything else: FAIL. The stale Step 4 evidence files are not evidence for the audited HEAD and conflict with the locked contract on the rate-limit interpretation.

## Final recommendation

Do not lock PR #173 at `9ef3d92`. The Go test/lint surface is clean, and I did not find SQL injection, request-observation data races, or money-math drift defects, but the production nginx config violates the locked no-burst SPEC, and the rollup failure path still has uncancellable DB writes plus raw error persistence into health state. Fix those blockers, refresh the stale Step 4 evidence for the actual HEAD, then rerun the same validation commands before the final lock.
