## Verdict

REQUEST CHANGES

Blocking count: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 2 LOW / 1 INFO

Audited branch `impl/spec-017-step-1` at HEAD `e2eb0112ce9a0bf65f8bbd25d9a74ce3fe8dafa8` against merge-base `e816dffb82cb08a9c8010a467498f9e6a1ac09f9`. The HEAD-vs-main changed-file count in this worktree is 203.

## Validation evidence

- `git status -sb`
  - Branch header: `## impl/spec-017-step-1...origin/impl/spec-017-step-1`.
  - Pre-existing untracked artifact observed: `specs/SPEC-017-FINAL-arch-r3-audit.md`.
- `git rev-parse HEAD`
  - `e2eb0112ce9a0bf65f8bbd25d9a74ce3fe8dafa8`.
- `git merge-base HEAD main`
  - `e816dffb82cb08a9c8010a467498f9e6a1ac09f9`.
- `git diff --name-only $(git merge-base HEAD main)..HEAD | wc -l`
  - Output: `203`.
- `gofmt -l $(git diff --name-only $(git merge-base HEAD main)..HEAD -- '*.go')`
  - Exit 0, no files listed.
- `go vet ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/`
  - Exit 0, no diagnostics.
- `golangci-lint run ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/`
  - Exit 0, `0 issues.`
- `go test -tags=integration -count=0 ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/`
  - Exit 0; integration-tag compile passed for `internal/stats/...` and `cmd/coordinator/...`.
- `go test ./internal/stats/... ./cmd/coordinator/...` from `phase4-coordinator/`
  - Exit 0; non-integration unit tests passed.
- `go test -race ./internal/stats/...` from `phase4-coordinator/`
  - Exit 0; no races reported.
- `go test -run 'TestEmitDriftIfExceeds|TestRedactErrMsg|TestClassifyPanic' ./internal/stats/rollup` from `phase4-coordinator/`
  - Exit 0; drift math and redaction tests passed.
- `go test -tags=integration -run TestProductionRequiresSignoff -count=1 ./cmd/coordinator` from `phase4-coordinator/`
  - Exit 0; current production-signoff test semantics passed.
- `go test -tags=integration -run 'TestAC17_IssueLockedSPECCommand|TestIssueTokenOutWritesFile|TestStep4C_StatsPartnerKeyIssuedEvent' -count=1 ./cmd/coordinator` from `phase4-coordinator/`
  - Exit 0; AC-17/token-out/event integration paths passed under current assertions.
- `git diff --check $(git merge-base HEAD main)..HEAD`
  - Exit 2; reports trailing whitespace / space-before-tab in historical audit markdown files such as `specs/SPEC-017-IMPL-STEP_2-arch-r1-audit.md` and `specs/SPEC-017-IMPL-STEP_4A-arch-r1-audit.md`. I did not classify this as a code blocker because `gofmt`, `go vet`, and `golangci-lint` are clean and the dirty paths are historical audit artifacts, not runtime code.

## Findings

### HIGH 1 - Production signoff gate is self-declared and bypassable by omitting `--production`

Evidence:
- `specs/SPEC-017-network-stats-api.md:1539` says `**Launch-sequencing precondition (v0.1.7, binding):** production`.
- `specs/SPEC-017-network-stats-api.md:1540-1543` scopes that precondition to any ``coordinator partner-keys issue`` invocation on a non-staging coordinator that produces a key delivered to a real partner and says it `MUST NOT begin`.
- `OPS.md:759` says `#### Cutover-runbook gate (BLOCKING for first PRODUCTION partner-key issuance)`.
- `OPS.md:761-762` says `The operator MUST NOT issue any partner key against the production coordinator`.
- `OPS.md:790` says `**Current status (2026-06-26): NOT YET SATISFIED.**`
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:189` defines `production := fs.Bool("production", false, ...)`, so production mode defaults to false.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:209` gates signoff validation only under `if *production {`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:230-234` rejects a signoff supplied without `--production`, but there is no reciprocal check that the resolved admin DSN/config is a production coordinator.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:256-324` resolves the admin DSN and inserts the `partner_keys` row after that opt-in check.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:420-421` prints the raw token and emits `stats_partner_key_issued` on the no-`--production` success path.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:554-560` locks the bypassable default as expected behavior: `staging default needs no signoff` succeeds with `--admin-dsn ... --label staging-key`.
- `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:227-241` defines `partner_keys` without environment, production marker, or persisted signoff column, so the database cannot distinguish staging from production rows.

Risk:
An operator or wrapper on Pearl can run the old documented command against the production admin DSN without `--production`:

```bash
coordinator partner-keys issue --config /opt/macprovider/coordinator.yaml --label "real partner"
```

That path can insert a valid production `partner_keys` row and deliver a raw `mpk_` token while the §6.6.2 production disclosure signoff is still unsatisfied. The resulting key unlocks the partner projection with exact earnings for all providers, which is the exact exposure the launch gate is supposed to prevent under operator error.

Fix direction:
Make production/staging a trusted, non-optional input instead of a self-declared skip flag. Reasonable fixes include requiring an explicit `--environment production|staging` with no default, deriving production from a trusted config field on the loaded coordinator YAML, or persisting signoff/environment evidence with issued keys. Add a regression test proving a production-marked config/admin DSN rejects `partner-keys issue --label X` without signoff and inserts no row.

### LOW 1 - `assertStdoutIsTokenOnly` accepts extra trailing blank lines

Evidence:
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:272` defines `func assertStdoutIsTokenOnly`.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:274` uses `s := strings.TrimRight(stdout, "\n")`.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:275-280` validates the trimmed value and internal newlines only.

Risk:
`mpk_<43 chars>\n\n` passes the helper even though AC-17 says stdout is exactly one raw-token line. This does not prove the current production code emits extra newlines; it weakens the test seam intended to prevent the exact stdout-contract regression found in round 2.

Fix direction:
Match raw stdout directly with `^mpk_[A-Za-z0-9_-]{43}\n?$` or equivalent byte-level checks, and reject any additional trailing newline or byte.

### LOW 2 - Subprocess AC-17 test still validates only the last stdout line

Evidence:
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:299` defines `TestAC17_IssueLockedSPECCommand_Subprocess`.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:316` calls `raw := extractRawTokenLine(stdout.String())`.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:317-320` validates only that extracted last line matches the token regex.

Risk:
The compiled-binary path would pass if metadata or another line appeared before the token, which was the original AC-17 failure class. The in-process test is stricter, but the subprocess test is the one that proves dispatcher/argv/main wiring for the locked command surface.

Fix direction:
Call `assertStdoutIsTokenOnly(t, stdout.String())` in `TestAC17_IssueLockedSPECCommand_Subprocess` before extracting the token.

### INFO 1 - Historical audit markdown has whitespace dirt

Evidence:
- `git diff --check $(git merge-base HEAD main)..HEAD` reports trailing whitespace in historical audit files, including `specs/SPEC-017-IMPL-STEP_2-arch-r1-audit.md:3` and space-before-tab in `specs/SPEC-017-IMPL-STEP_4A-arch-r1-audit.md:59`.

Risk:
This is branch hygiene noise, not a runtime code issue. It can still confuse a final pre-merge check if the repo starts gating `git diff --check`.

Fix direction:
Clean historical audit markdown whitespace in a separate mechanical pass if branch hygiene is required.

## Category sweep

A. SQL injection / parameter mis-binding: PASS. Runtime SQL values are parameter-bound. Dynamic table/order fragments I inspected come from internal whitelists such as `leaderboardTable` and `leaderboardOrder` in `phase4-coordinator/internal/stats/store/leaderboard.go:160-184`; value arguments still use `$1` binding, e.g. `LIMIT $1` at `phase4-coordinator/internal/stats/store/leaderboard.go:67-69`.

B. Concurrent-write hazards: PASS. The `requestObs` pointer is per-request, created before `next.ServeHTTP` in `phase4-coordinator/internal/stats/middleware.go:176`, written synchronously in `phase4-coordinator/internal/stats/mux.go:160-162` and `phase4-coordinator/internal/stats/handlers.go:144-145` / `:405-406`, then read after `next.ServeHTTP` returns at `phase4-coordinator/internal/stats/middleware.go:188-189`. `go test -race ./internal/stats/...` passed.

C. Context cancellation correctness: PASS. Rollup ticks pass the runner context into `runOne` and tick functions (`phase4-coordinator/internal/stats/rollup/runner.go:198`, `:204`, `:253`). `observeRollupLag` exits on `ctx.Done()` at `phase4-coordinator/cmd/coordinator/main.go:947-951`. The remaining health-failure background context is bounded to 5s at `phase4-coordinator/internal/stats/rollup/runner.go:324-325`.

D. Error-path label leaks: PASS. Rollup health failure stores `redactErrMsg(err.Error())` at `phase4-coordinator/internal/stats/rollup/runner.go:260-262`; the redactor strips DSNs, `mpk_*`, `token_hash=...`, and long hex runs at `phase4-coordinator/internal/stats/rollup/runner.go:342-362`. Panic classification is type-only at `phase4-coordinator/internal/stats/rollup/runner.go:307-309`.

E. Off-by-one / boundary bugs: PASS. The shipped nginx stats locations use `burst=59 nodelay` on all six public-tier directives: `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:110`, `:138`, `:161` and `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:213`, `:233`, `:253`. Under nginx semantics, `burst=59` plus one in-rate request admits exactly 60 immediate requests and rejects the 61st.

F. Money math: PASS. Drift detection uses absolute delta over `max(rebuild, 1)` at `phase4-coordinator/internal/stats/rollup/rebuild.go:224-235`, avoiding divide-by-zero and sign-flip misses. Targeted tests for zero, sub-unit, threshold-exclusive, and dollar values passed.

G. Test claims vs test behavior: FAIL. Most AC tests inspect body/header content, but the AC-17 subprocess test still only checks the last stdout line (`phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:316-320`), so it would not catch metadata before the token on the compiled command surface.

H. `Runner.RunTickOnceForTest`: PASS. The seam is a narrow wrapper over production `runOne` at `phase4-coordinator/internal/stats/rollup/runner.go:161-162`. Search found no production caller; integration tests use it to drive the real tick/error metric path.

I. `emitPartnerKeyEvent` `map[string]any`: PASS. The function is unexported at `phase4-coordinator/cmd/coordinator/partnerkeys.go:542`. Current call sites pass closed maps only: issue fields at `phase4-coordinator/cmd/coordinator/partnerkeys.go:366-381` and revoke fields at `phase4-coordinator/cmd/coordinator/partnerkeys.go:522-526`. No current caller passes raw token, token body, prefix, or token hash.

J. Gofmt / vet / lint clean: PASS. `gofmt -l` over changed Go files produced no output. `go vet ./internal/stats/... ./cmd/coordinator/...` passed. `golangci-lint run ./internal/stats/... ./cmd/coordinator/...` passed with `0 issues.`

K. Test compile coverage: PASS. `go test -tags=integration -count=0 ./internal/stats/... ./cmd/coordinator/...` passed for the requested package sets.

L. Anything else: FAIL. The round-3 production signoff validator is fail-closed only after `--production` is supplied, but a production admin DSN can still be used on the no-`--production` path. This is HIGH 1.

## Final recommendation

Do not lock this code round. The round-3 regex and stdout fixes are mostly sound, but the production signoff gate is still opt-in rather than tied to the actual production coordinator/config/DSN, so the old issuance command can bypass the disclosure gate. Fix HIGH 1 before merge; the two LOW AC-17 test issues should be closed in the same pass because they protect the exact round-2 stdout regression class.
