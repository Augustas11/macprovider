# SPEC-017 v0.1.8 — Final Whole-Implementation Architecture Audit

## Verdict

REQUEST CHANGES

Blocking count: 1 CRITICAL / 1 HIGH / 2 MEDIUM / 0 LOW / 4 INFO

## Required reading + commands run

Read:

- `CLAUDE.md`
- `specs/SPEC-017-network-stats-api.md`
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md`
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md`
- `specs/SPEC-017-IMPL-STEP_4-convergence.md`
- `specs/SPEC-017-IMPL-STEP_4C-r5-convergence.md`
- `OPS.md` §10
- `docs/network-stats-api/CHANGELOG.md`
- Changed SPEC-017 implementation files under `phase4-coordinator/internal/stats/`, `phase4-coordinator/cmd/coordinator/`, and `phase4-coordinator/dist/`

Commands run:

```bash
git status -sb
git rev-parse --short HEAD && git rev-parse HEAD && git branch --show-current && git merge-base HEAD main
git diff --name-only $(git merge-base HEAD main)..HEAD | wc -l
git diff --name-only $(git merge-base HEAD main)..HEAD
git log --oneline --decorate --max-count=8
rg -n "SPEC-017|v0\.1\.8|6\.6\.2|exact-USD|sign-off|rate|burst|metrics|partner" specs/SPEC-017-network-stats-api.md specs/BUILD_SPEC_017_IMPL_PROMPT.md specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md specs/SPEC-017-IMPL-STEP_4-convergence.md specs/SPEC-017-IMPL-STEP_4C-r5-convergence.md OPS.md docs/network-stats-api/CHANGELOG.md
rg -n "### 5\.6|Rate limits|burst|hard 60|rate-limit|req/min|auth-failure" specs/SPEC-017-network-stats-api.md
rg -n "sign-off|SPEC-014|6\.6\.2|production|PARTNER-KEY|issue|AdminDSN|admin.*dsn|STATS_ADMIN|PARTNER" phase4-coordinator/cmd/coordinator phase4-coordinator/internal OPS.md phase4-coordinator/dist -g '!**/*_test.go'
rg -n "partner-keys issue|PRODUCTION|sign-off|portal deploy|SPEC-014 v0\.9|COORDINATOR_PARTNER_KEYS_ADMIN_DSN|--admin-dsn" phase4-coordinator/cmd/coordinator/*.go phase4-coordinator/cmd/coordinator/*_test.go specs/SPEC-017-IMPL-STEP_4*.md OPS.md
rg -n "NewRegistry|DefaultRegisterer|prometheus|promhttp|/metrics|statsRegistry|StatsRegistry|Registerer" phase4-coordinator/cmd/coordinator phase4-coordinator/internal -g '*.go'
rg -n "INSERT|UPDATE|DELETE|COPY|TRUNCATE|CREATE|ALTER|DROP|ExecContext|QueryRowContext|QueryContext" phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/partnerkeys.go phase4-coordinator/cmd/coordinator/visibility.go -g '*.go'
rg -n "AC-10|provider_portal|provider_visibility|GRANT INSERT|SELECT, UPDATE|§7\.2\.3" specs/SPEC-017-network-stats-api.md specs/BUILD_SPEC_017_IMPL_PROMPT.md specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md phase4-coordinator/internal/stats/integration_test.go
rg -n "func TestAC17|TestIssueJournalStreamSuppresses|TestAC20|TestAC22|TestAC15_RedactionSweep|TestStep4C_WiredMux_MetricLabelHygiene|TestLabelHygiene|TestAC8|AC-8" phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go phase4-coordinator/internal/stats/handlers_integration_test.go phase4-coordinator/internal/stats/step4c_integration_test.go phase4-coordinator/internal/stats/metrics/metrics_test.go phase4-coordinator/internal/stats/integration_test.go phase4-coordinator/dist/test/check_nginx_stats_test.sh
rg -n -- "--config|COORDINATOR_PARTNER_KEYS_ADMIN_DSN|partner_keys_admin_dsn|visibility revert|partner-keys" OPS.md phase4-coordinator/dist/coordinator.yaml.example phase4-coordinator/dist/deploy-pearl-vps.sh
./dist/test/check_nginx_stats_test.sh
go test ./internal/stats/metrics ./internal/stats -run 'TestLabelHygiene|TestStep4C_WiredMux_MetricLabelHygiene|TestAC22_AuthFailureLimiter'
go test ./internal/stats/migrations -run Test
```

Validation evidence:

- HEAD is `9ef3d923c2d42026dd2ea50839a15bbd9eea4ad9` on `impl/spec-017-step-1`; changed-file count is 189.
- `./dist/test/check_nginx_stats_test.sh` passed, including nginx AC-8, keyed bypass, proxy no-cache, and access-log redaction.
- `go test ./internal/stats/metrics ./internal/stats -run 'TestLabelHygiene|TestStep4C_WiredMux_MetricLabelHygiene|TestAC22_AuthFailureLimiter'` passed.
- `go test ./internal/stats/migrations -run Test` passed.

## Findings

### CRITICAL

1. §6.6.2 production sign-off gate is bypassable by the documented CLI path

Evidence:

- `specs/SPEC-017-IMPL-STEP_4-convergence.md:26-30` says live production sign-off is `NOT YET SATISFIED`, but also claims "the gate is wired and non-bypassable" and only instructs the operator to record sign-off before running `coordinator partner-keys issue ...`.
- `OPS.md:735-747` states the operator "MUST NOT issue any partner key against the production coordinator" until the three disclosure/sign-off conditions are satisfied; `OPS.md:766-770` states current status is `NOT YET SATISFIED`.
- The actual issue path in `phase4-coordinator/cmd/coordinator/partnerkeys.go:165-177` defines flags for config/admin DSN, label, rpm, created-by, rotate-from, token-out, and allowed-origin. There is no sign-off artifact, production environment, SPEC-014 SHA, portal deployment date, or acknowledgement input.
- `phase4-coordinator/cmd/coordinator/partnerkeys.go:209-223` resolves and opens the admin DSN; `partnerkeys.go:259-277` then inserts directly into `partner_keys`; `partnerkeys.go:347-349` prints the raw token and emits the issued event.

Risk:

An operator with the production admin DSN can issue and deliver a production partner key while the documented §6.6.2 disclosure status is still `NOT YET SATISFIED`. That key unlocks exact USD earnings for every provider via the partner projection. Under the severity bar in this prompt, a §6.6.2 sign-off bypass by operator error is CRITICAL.

Fix direction:

Make the production issuance gate mechanical. For example, require a production sign-off record checked by the CLI before any `partner_keys` INSERT against a production DSN, or require an explicit immutable sign-off artifact/SPEC-014 SHA/date flag set that is persisted with the issuance audit. The CLI must fail closed when production status is unsigned, and tests should prove issue cannot insert without the sign-off on a production-marked config.

### HIGH

1. Production nginx config violates locked §5.6 "no burst" contract

Evidence:

- `specs/SPEC-017-network-stats-api.md:32-40` says v0.1.8 "drops the burst column entirely" and AC-8 is achievable with `limit_req zone=<name> nodelay;` and "no `burst=`."
- `specs/SPEC-017-network-stats-api.md:1116-1120` states "v0.1.8 drops the burst column entirely", "no burst absorption", and "`limit_req zone=<name> nodelay;` (no `burst=` parameter)."
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md:567-570` says the production location block "MUST use `limit_req zone=<name> nodelay;` with NO `burst=` parameter."
- The implementation uses `burst=59 nodelay` in all public stats locations: `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:109-110`, `137-138`, `160-161`; and the coordinator vhost mirrors it at `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf:212-214`, `232-234`, `252-254`.
- `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md:65-71` argues the change preserves sustained throughput, but the locked SPEC forbids burst absorption at the implementation level, not only long-term average throughput.

Risk:

The shipped edge behavior admits an immediate 60-request burst per endpoint, which is exactly the burst absorption §5.6 removed. AC-8 currently passes only because the implementation reintroduced a burst bucket after the locked SPEC/build prompt explicitly removed it. This leaves the public contract internally contradictory and creates a hostile-reading path where production is non-compliant on launch.

Fix direction:

Either remove `burst=59` and revise AC-8/test shape to make 60 requests over the allowed minute window without an implementation burst, or reopen the locked SPEC/build prompt/changelog and explicitly state that an initial `burst=59 nodelay` bucket is part of v0.1.8. Do not ship a config that contradicts the locked prose while claiming the prose is satisfied.

### MEDIUM

1. `provider_portal` grant set is widened beyond locked SPEC §7.2.3

Evidence:

- Locked SPEC §7.2.3 grants only `INSERT, UPDATE` on `provider_visibility` to `provider_portal` at `specs/SPEC-017-network-stats-api.md:1663-1671`, and states "No `stats_*` grants. No OLTP grants" at `specs/SPEC-017-network-stats-api.md:1674-1676`.
- The build prompt repeats the locked inventory at `specs/BUILD_SPEC_017_IMPL_PROMPT.md:166-169`: `provider_portal` gets `INSERT, UPDATE` on `provider_visibility`, `INSERT` on audit, and sequence privileges.
- The migration explicitly admits an implementation-authored deviation at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:86-118`, then grants `INSERT, SELECT, UPDATE ON provider_visibility TO provider_portal`.
- The privilege test at `phase4-coordinator/internal/stats/integration_test.go:720-749` only proves `provider_portal` cannot read `stats_overview_current` and can insert audit; it does not assert the exact locked grant set or deny `SELECT` on `provider_visibility`.

Risk:

This is a least-privilege drift in the role that will be used by the SPEC-014 portal. It may be functionally necessary for the chosen PostgreSQL UPSERT shape, but the implementation shipped a broader grant than the locked contract and left the test suite green by not checking that exact boundary. The widened read currently includes `blocked_from_partner_projection`, a v0.2-sensitive column stub.

Fix direction:

Either update SPEC-017/build prompt before lock to enumerate the required `SELECT` grant, preferably column-scoped to the minimum needed columns, or change the implementation shape to preserve the locked grant inventory. Add a regression test that checks `provider_portal` privileges exactly, including whether `SELECT` is intentionally allowed or denied.

2. OPS.md §10 partner-key and visibility commands are not executable from a fresh Pearl operator shell

Evidence:

- `OPS.md:629-636`, `OPS.md:654-655`, and `OPS.md:698-700` invoke `/opt/macprovider/coordinator` without `--config /opt/macprovider/coordinator.yaml`.
- The CLI default config path is the relative string `coordinator.yaml` at `phase4-coordinator/cmd/coordinator/partnerkeys.go:168`; the same pattern is used for visibility at `phase4-coordinator/cmd/coordinator/visibility.go:73`.
- The production systemd unit uses `WorkingDirectory=/opt/macprovider` and `ExecStart=/opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml` at `phase4-coordinator/dist/macprovider-coordinator.service:11-19`. A manual `sudo -u macprovider /opt/macprovider/coordinator ...` does not inherit that service working directory or `/etc/macprovider/coordinator.env`.
- Existing OPS commands outside §10 already include explicit config paths, e.g. `OPS.md:273`, `OPS.md:409`, and `OPS.md:435`.

Risk:

A fresh operator following §10 from their normal shell can fail to load the production config/admin DSN, or fail to resolve any `env:`-indirected DSN because the service env file is not loaded. For rotation/revoke this delays incident response; for issue it encourages ad hoc `--admin-dsn` use and makes the sign-off/DSN hygiene story weaker.

Fix direction:

Update every §10 coordinator CLI command to pass `--config /opt/macprovider/coordinator.yaml` and document how `COORDINATOR_PARTNER_KEYS_ADMIN_DSN`/env-indirected secrets are loaded for one-off CLI invocations, or provide a wrapper that runs with the same working directory and env file as the service.

### LOW

None.

### INFO

1. Metrics registry isolation held under inspection

Evidence:

- Production creates `statsRegistry := prom.NewRegistry()` and passes it to `statsmetrics.New(statsRegistry)` at `phase4-coordinator/cmd/coordinator/main.go:543-544`.
- `/metrics` is mounted with `promhttp.HandlerFor(statsRegistry, ...)` at `phase4-coordinator/cmd/coordinator/main.go:558`.
- `rg` found no package registering non-stats collectors into that registry. The only default-registerer wording is a stale/loose comment in `phase4-coordinator/internal/stats/metrics/metrics.go:41-44`; production wiring uses the isolated registry.

Risk:

No blocker found. The wording in `metrics.go` could be tightened later, but the code path is isolated.

Fix direction:

Optional: update the comment to say production uses a coordinator-owned registry.

2. Partner projection redaction guards are layered and passed targeted checks

Evidence:

- Handler partner-only fields are added only when `partnerProj` is true at `phase4-coordinator/internal/stats/handlers.go:415-456`, with partner cache headers at `handlers.go:488-493`.
- Redaction strips `Authorization`, `Cookie`, and `X-Api-Key` before downstream logging at `phase4-coordinator/internal/stats/middleware.go:52-72`; panic path strips again at `middleware.go:87-137`.
- Metrics labels use endpoint/status/tier or integer `partner_key_id` only at `middleware.go:211-222` and `metrics/metrics.go:62-96`.
- Targeted tests for label hygiene and nginx redaction passed.

Risk:

No leak found in the audited handler/middleware/nginx/metrics paths.

Fix direction:

None required for v0.1.8 beyond the blockers above.

3. Migration ordering and bootstrap idempotency held in static and targeted test review

Evidence:

- `001_stats_tables.up.sql` creates tables; `002_bootstrap_health_and_rewards.up.sql:10-27` seeds component/reward rows with `ON CONFLICT DO NOTHING`; `003_roles.up.sql` creates roles; `004_grants.up.sql` grants after tables exist; `005_oltp_source_grants.up.sql` conditionally grants source reads only when tables exist.
- `go test ./internal/stats/migrations -run Test` passed.

Risk:

No stock-checkout migration-order blocker found.

Fix direction:

None required for v0.1.8.

4. CHANGELOG is directionally accurate but inherits the burst/sign-off ambiguities

Evidence:

- `docs/network-stats-api/CHANGELOG.md:20-31` lists v0.1.8 behavior including three-tier rate limiting and §6.6.2 sign-off template.
- It does not disclose the implementation-level `burst=59` edge behavior or that live sign-off is currently not satisfied.

Risk:

This is not a separate blocker once the HIGH/CRITICAL findings are fixed, but the changelog should be rechecked after those fixes so it does not publish an oversimplified partner-facing contract.

Fix direction:

Align the changelog with the final resolved §5.6 and §6.6.2 posture.

## Category sweep

A. Cross-step interaction bugs — FAIL. Runtime pool isolation is mostly sound, but the admin DSN can issue partner keys without a mechanical sign-off gate, and `provider_portal` receives broader `provider_visibility` read privilege than the locked role inventory.

B. Step 4.B contract reconciliation — FAIL. `burst=59 nodelay` satisfies the current 60+1 smoke but contradicts the locked "no `burst=`" and "no burst absorption" text.

C. Money-path drift — FAIL. I found no raw-token/log/metric leak in the inspected layers, but the §6.6.2 exact-USD disclosure gate is process-only and bypassable by the production issue CLI.

D. Test surface honesty — FAIL. Sampled AC-8, AC-10, AC-15, AC-17, and AC-22; AC-8 proves behavior by violating the locked no-burst contract, and AC-10 does not assert the exact `provider_portal` grant boundary.

E. `/metrics` endpoint surface — PASS. Production uses a fresh `prometheus.NewRegistry()` and `promhttp.HandlerFor(statsRegistry, ...)`; metric labels are closed vocabularies or integer `partner_key_id`.

F. Migration safety — PASS. Ordering is coherent, bootstrap seeds are idempotent, and targeted migration tests pass.

G. CHANGELOG honesty — FAIL. The changelog is broadly correct but underspecifies the current burst behavior and live sign-off status, which matters if the implementation is shipped as-is.

H. OPS.md runbook executability — FAIL. §10 one-off CLI commands omit the production config path/env-file handling that the service unit uses, unlike earlier OPS commands.

I. §6.6.2 sign-off gate non-bypassability — FAIL. An operator with the admin DSN can issue a production key without any code-level sign-off check.

J. Anything else — PASS. I did not find an additional independent blocker in metrics registry isolation, redaction labels, migration bootstrap, or stats handler store write boundaries.

## Final recommendation

Do not ship PR #173 as ready to lock. The two release blockers are architectural, not cosmetic: production partner-key issuance is not mechanically gated on §6.6.2 sign-off, and the nginx edge config contradicts the locked no-burst rate-limit contract. Fix those first, then reconcile the `provider_portal` grant drift and OPS.md command executability before re-running the final 22-AC sweep.
