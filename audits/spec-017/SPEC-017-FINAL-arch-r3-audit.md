# SPEC-017 v0.1.8 — Final whole-implementation ARCH r3 audit

Date: 2026-06-26
Branch: `impl/spec-017-step-1`
Audited HEAD: `e2eb0112ce9a0bf65f8bbd25d9a74ce3fe8dafa8`
Diff base: `e816dffb82cb08a9c8010a467498f9e6a1ac09f9`

## Verdict

REQUEST CHANGES

Blocking count: 1 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 1 INFO

## Required reading + commands run

Required reading:

- `CLAUDE.md`
- `specs/SPEC-017-network-stats-api.md`
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md`
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md`
- `specs/SPEC-017-IMPL-STEP_4-convergence.md`
- `specs/SPEC-017-IMPL-STEP_4C-r5-convergence.md`
- `OPS.md`
- `docs/network-stats-api/CHANGELOG.md`
- `phase4-coordinator/cmd/coordinator/partnerkeys.go`
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go`
- `phase4-coordinator/internal/stats/migrations/*.up.sql`
- `phase4-coordinator/internal/stats/{auth.go,middleware.go,mux.go,handlers.go,store/*.go,metrics/metrics.go,step4c_integration_test.go}`
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/dist/{deploy-pearl-vps.sh,nginx-coordinator.malibu.tech.conf,nginx-stats.malibu.tech.conf,nginx-snippets/*.conf,test/check_nginx_stats_test.sh}`

Commands run:

```bash
git status -sb
git rev-parse HEAD
git branch --show-current
git merge-base HEAD main
git diff --name-only $(git merge-base HEAD main)..HEAD | wc -l
git diff --name-only $(git merge-base HEAD main)..HEAD
rg -n "v0\.1\.8|6\.6\.2|5\.6|5\.7|5\.9|7\.2\.3|rate|burst|sign-off|signoff|partner|exact-USD|metrics|304" specs/SPEC-017-network-stats-api.md specs/BUILD_SPEC_017_IMPL_PROMPT.md specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md specs/SPEC-017-IMPL-STEP_4-convergence.md specs/SPEC-017-IMPL-STEP_4C-r5-convergence.md OPS.md docs/network-stats-api/CHANGELOG.md
rg -n "signoff|sign-off|spec-6-6-2|production|token-out|stdout|stderr|partner key|partner_keys|stats_partner_key|mpk_|issue|revoke|list" phase4-coordinator/cmd/coordinator phase4-coordinator/internal/stats specs/SPEC-017-IMPL-STEP_4A-* specs/SPEC-017-FINAL-arch-r2-audit.md specs/SPEC-017-FINAL-security-r2-audit.md
rg -n "limit_req|burst=|nodelay|60|429|stats_ratelimit|rate=|zone=|Cache-Control|proxy_cache|access_log|log_format|metrics|promhttp|DefaultRegisterer|statsRegistry|partner" phase4-coordinator/dist phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator specs/SPEC-017-IMPL-STEP_4B-* specs/SPEC-017-IMPL-STEP_4C-*
rg -n "stats_api|stats_rollup|stats_handler|GRANT|REVOKE|CREATE ROLE|ALTER DEFAULT|SECURITY DEFINER|INSERT|UPDATE|DELETE|SELECT|ON CONFLICT|provider_portal|bootstrap|uuid|partner_keys" phase4-coordinator/internal/stats/migrations phase4-coordinator/internal/stats/rollup phase4-coordinator/internal/stats/store phase4-coordinator/cmd/coordinator
rg -n "production|signoff-spec-6-6-2|signoff|Test.*Production|without --production|supplied without --production|requires --signoff|issue --label" phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go phase4-coordinator/cmd/coordinator/dispatch_test.go specs/SPEC-017-FINAL-security-r2-audit.md specs/SPEC-017-FINAL-arch-r2-audit.md specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md
rg -n "DefaultRegisterer|prometheus\.NewRegistry|promauto|Register\(|MustRegister|statsmetrics.New|statsRegistry|/metrics|partner_key_id|PartnerKeyRequestTotal|RateLimitExceededTotal|RequestTotal|WithLabelValues" phase4-coordinator/internal phase4-coordinator/cmd/coordinator
rg -n "macprovider-coordinator|/opt/macprovider/coordinator|coordinator.yaml|partner_keys_admin_dsn|stats-shared|stats-security|nginx-stats|stats.streamvc|nginx -t|systemctl|journalctl" phase4-coordinator/dist/deploy-pearl-vps.sh OPS.md phase4-coordinator/dist/*.conf phase4-coordinator/dist/nginx-snippets/*.conf
printf '%s\n' AC-{1..22} | awk 'BEGIN{srand(170)} {print rand(), $0}' | sort -n | head -5
rg -n "AC-6\.|AC-13\.|AC-21\.|func TestAC6_|func TestAC13_|func TestAC21_" specs/SPEC-017-network-stats-api.md phase4-coordinator/internal/stats/handlers_integration_test.go specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md
go test ./internal/stats/metrics ./internal/config
bash phase4-coordinator/dist/test/check_nginx_stats_test.sh
go test -tags=integration ./cmd/coordinator -run 'TestProductionRequiresSignoff|TestAC17_IssueLockedSPECCommand' -count=1
```

Validation evidence:

- `go test ./internal/stats/metrics ./internal/config` passed.
- `bash phase4-coordinator/dist/test/check_nginx_stats_test.sh` passed, including nginx `AC-8`, keyed bypass, per-endpoint isolation, cache write-suppression, and access-log redaction.
- `go test -tags=integration ./cmd/coordinator -run 'TestProductionRequiresSignoff|TestAC17_IssueLockedSPECCommand' -count=1` passed, confirming the current sign-off semantics encoded by the tests.

## Findings

### CRITICAL

1. Production partner-key sign-off gate is opt-in and bypassable by omitting `--production`

Evidence:

- `specs/SPEC-017-network-stats-api.md:1539` defines the binding launch-sequencing precondition. Lines 1540-1544 scope it to any `coordinator partner-keys issue` invocation on a non-staging coordinator that produces a key delivered to a real partner and say it `MUST NOT begin` until the live Pearl conditions are satisfied.
- `OPS.md:759-771` repeats the production gate: the operator `MUST NOT issue any partner key against the production coordinator` until SPEC-014 v0.9 is deployed, disclosures are live, and the runbook contains the signed-off entry. `OPS.md:790-794` says current status is `NOT YET SATISFIED`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:189-190` makes the gate opt-in: `--production` defaults to false and `--signoff-spec-6-6-2` is only interpreted as production evidence when that flag is set.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:209-235` enforces sign-off only inside `if *production`; the `else` branch rejects a sign-off value without `--production`, but does not detect that the admin DSN/config is production.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:256-324` then resolves the admin DSN, opens Postgres, and inserts the `partner_keys` row. There is no production/staging discriminator between validation and `INSERT`.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:420-421` prints the raw token and emits `stats_partner_key_issued` after that insert on the no-`--production` path.
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go:546-560` explicitly locks the bypass shape as acceptable: "Staging issuance (the default) has no preconditions", and the test asserts `coordinator partner-keys issue --admin-dsn <dsn> --label staging-key` succeeds with no sign-off.
- `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:227-241` defines `partner_keys` without any environment, production marker, or sign-off evidence column. The database cannot distinguish production-issued rows from staging-issued rows, and direct admin-DSN SQL has no mechanical sign-off gate either.

Risk:

An operator or wrapper on Pearl with the production `stats.partner_keys_admin_dsn` can run the documented CLI with one missing flag:

```bash
sudo -u macprovider /opt/macprovider/coordinator partner-keys issue \
  --config /opt/macprovider/coordinator.yaml \
  --label "real partner"
```

That command can insert a valid production `partner_keys` row and deliver a raw `mpk_` token while `OPS.md` still says the §6.6.2 production sign-off is not satisfied. The issued key exposes exact `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd` for all providers through the partner projection, so this is a security/regulatory gate that does not gate under ordinary operator error. It also fails the prompt's explicit non-bypassability question: an operator with admin DSN access can issue without recording sign-off, either through the no-`--production` CLI path or direct SQL.

Fix direction:

Make production/staging an input the CLI cannot silently omit on a production host. Acceptable shapes include:

- Add a required environment field in `coordinator.yaml` or the DSN config, fail closed when it says production and the recorded sign-off artifact is absent.
- Require an explicit `--environment production|staging` flag and reject production admin DSNs/configs unless the sign-off evidence is supplied and persisted.
- Persist immutable sign-off evidence with the key row or an issuance audit table so the DB can reject or audit production keys independently of stderr log capture.
- Add a regression test that uses a production-marked config/admin DSN and proves `partner-keys issue --label X` without sign-off does not insert any row.

### HIGH

None.

### MEDIUM

None.

### LOW

None.

### INFO

1. Convergence metadata is stale relative to Round 3 HEAD

Evidence:

- `specs/SPEC-017-IMPL-STEP_4-convergence.md:5-7` still names HEAD `9784ef5` and marks that record converged before the Round 3 target `e2eb011`.
- The current branch diff is 203 changed paths against `main`, while the prompt's inherited scope says 189 files. The command was `git diff --name-only $(git merge-base HEAD main)..HEAD | wc -l`.
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md:5` names swept HEAD `5ceb230`, also older than this audit target.

Risk:

This is not a standalone production blocker because this report supersedes those records for the Round 3 gate. It is still easy for a future reader to cite stale "all locked" metadata rather than this final blocker.

Fix direction:

After fixing the CRITICAL sign-off bypass, regenerate or append the convergence/sweep records with the actual locking HEAD and explicitly mark the older records superseded.

## Category sweep

A. Cross-step interaction bugs: FAIL. Runtime role separation mostly holds, but Step 4.A's admin-DSN CLI can create production-capable keys without a non-optional production sign-off discriminator.

B. Step 4.B contract reconciliation: PASS. The locked SPEC now explicitly requires `burst=59 nodelay` at `specs/SPEC-017-network-stats-api.md:1136-1153`, all six nginx locations use it, and the nginx smoke proved 60 successes plus 61st 429.

C. Money-path drift: FAIL. The redaction/caching/metrics layers held in this pass, but the sign-off bypass can expose exact partner projection values before the §6.6.2 disclosure gate is satisfied.

D. Test surface honesty: PASS with caveat. The seeded sample command returned AC-6, AC-8, AC-13, AC-21, and AC-17; their cited tests exercise real partner projection, nginx rate limiting, OPTIONS, method rejection, and CLI token-only stdout paths. The production sign-off problem is outside the 22 AC matrix, and the added `TestProductionRequiresSignoff` encodes the flawed opt-in assumption.

E. `/metrics` endpoint surface: PASS. `main.go:543-558` uses `prometheus.NewRegistry()` and `promhttp.HandlerFor(statsRegistry, ...)`, not the default registerer; config validation rejects non-loopback bind when stats are enabled; metric labels are closed and the wired test now emits all five families including a real partner-key request.

F. Migration safety: PASS. Migration ordering is lexicographic by version, each migration is transactional and recorded under an advisory lock, bootstrap uses `ON CONFLICT DO NOTHING`, and role grants deny the expected cross-role surfaces. The partner-key table still lacks sign-off/environment state, captured under the CRITICAL finding.

G. CHANGELOG honesty: PASS. The v0.1.8 changelog states the exact partner projection and points to the OPS.md sign-off template without claiming live sign-off completion.

H. OPS.md runbook executability: PASS with caveat. Paths, service names, `--config`, nginx snippets, and Pearl service names line up with deploy scripts and local smoke coverage; the runbook tells operators to pass `--production`, but that procedural instruction is not a non-bypassable gate.

I. §6.6.2 sign-off gate non-bypassability: FAIL. The CLI gate is opt-in and database rows have no sign-off/environment invariant, so production issuance can occur without a recorded sign-off.

J. Anything else: PASS. I did not find a stronger blocker in nginx caching, metrics registry isolation, role grants, 304/CORS handling, or AC-17 stdout token-only behavior after Round 3 fixes.

## Final recommendation

Do not lock PR #173 at `e2eb011`. The implementation is materially stronger than Round 2 on nginx behavior, metrics label hygiene, and CLI stdout redaction, but the §6.6.2 production issuance gate is still bypassable through the ordinary CLI by omitting an opt-in flag on a production host. Because a valid partner key exposes exact USD figures for every provider, this remains a CRITICAL pre-merge blocker under the stated severity bar.
