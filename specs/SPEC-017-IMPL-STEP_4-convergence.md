# SPEC-017 v0.1.8 — Step 4 convergence record (4.A + 4.B + 4.C)

Date: 2026-06-26
PR: [Augustas11/macprovider#173](https://github.com/Augustas11/macprovider/pull/173)
Branch: `impl/spec-017-step-1`
HEAD: `9784ef5`
Status: **CONVERGED.** All 9 audit lanes locked
(4.A ARCH/CODE/SECURITY + 4.B ARCH/CODE/SECURITY + 4.C ARCH/CODE/SECURITY).
22 of 22 ACs PASS.

## §6.6.2 sign-off template (quoted verbatim from `OPS.md` §10.5)

> Production partner-key issuance is blocked until the following
> sign-off is recorded in the SPEC-017 v0.1.8 commit message OR
> the convergence record:
>
>     §6.6.2 disclosure sign-off (SPEC-017 v0.1.8):
>     I, <operator name>, on <date>, on behalf of <Augustas's
>     name / organization>, confirm that we have disclosed to
>     <partner counterparty name> in writing the exact USD
>     amounts each partner key holder will have access to via
>     the `/v1/stats/leaderboard` partner projection, per
>     SPEC §6.6.2. Disclosure artifact:
>     <URL OR file path to the signed acknowledgment>.

Live production sign-off status: **NOT YET SATISFIED.**
PR #173 ships the *capability*; the gate is wired and
non-bypassable. Operator must record the sign-off before
running `coordinator partner-keys issue ...` against
production.

## Audit-lane lock matrix

| Sub-step | Lane     | Locking round | Verdict             | Counts                       |
|----------|----------|---------------|---------------------|------------------------------|
| 4.A      | ARCH     | r2            | READY TO LOCK       | 0C / 0H / 0M                 |
| 4.A      | CODE     | r4            | READY TO LOCK       | 0C / 0H / 0M                 |
| 4.A      | SECURITY | r2            | READY TO LOCK       | 0C / 0H / 0M / 2L / 10 INFO  |
| 4.B      | ARCH     | r3            | READY TO LOCK       | 0C / 0H / 0M                 |
| 4.B      | CODE     | r4            | READY TO LOCK       | 0C / 0H / 0M                 |
| 4.B      | SECURITY | r4            | READY TO LOCK       | 0C / 0H / 0M                 |
| 4.C      | ARCH     | r5            | READY TO LOCK       | 0C / 0H / 0M / 0L / 15 INFO  |
| 4.C      | CODE     | r5            | READY TO LOCK       | 0C / 0H / 0M / 0L / 12 INFO  |
| 4.C      | SECURITY | r2            | READY TO LOCK       | 0C / 0H / 0M / 2L /  9 INFO  |

Every lane converged to 0 CRITICAL / 0 HIGH / 0 MEDIUM. The
LOW + INFO entries that remain are non-blocking and documented
in their respective lane files; the worst case is one LOW per
SECURITY lane carrying a doc / comment polish suggestion.

The full lane-by-lane round trajectories live in the sub-step
convergence record: [`SPEC-017-IMPL-STEP_4C-r5-convergence.md`](SPEC-017-IMPL-STEP_4C-r5-convergence.md).
That file covers 4.C; the round-by-round details for 4.A and 4.B
live in their individual audit files.

## 22-AC sweep (post-reconciliation)

The end-of-implementation 22-AC sweep ran natively against locked
HEAD `9784ef5`. Full details + sources live in
[`SPEC-017-IMPL-STEP_4-22AC-sweep.md`](SPEC-017-IMPL-STEP_4-22AC-sweep.md);
the summary table is reproduced here so the convergence record is
self-contained.

| AC    | Lane (sub-step) | Verdict |
|-------|-----------------|---------|
| AC-1  | Step 3          | PASS    |
| AC-2  | Step 3          | PASS    |
| AC-3  | Step 3 + 4.B    | PASS (Go + nginx) |
| AC-4  | Step 3          | PASS    |
| AC-5  | Step 3          | PASS    |
| AC-6  | Step 3          | PASS    |
| AC-7  | Step 3          | PASS    |
| AC-8  | Step 4.B        | PASS (nginx 60-burst + 61st 429 confirmed locally) |
| AC-9  | Step 1          | PASS    |
| AC-10 | Step 1          | PASS    |
| AC-11 | Step 3          | PASS    |
| AC-12 | Step 3          | PASS    |
| AC-13 | Step 3          | PASS    |
| AC-14 | Step 3          | PASS    |
| AC-15 | Step 3 + 4.A + 4.B + 4.C | PASS (Go ×7 redundant + nginx access-log) |
| AC-16 | Step 1          | PASS    |
| AC-17 | Step 4.A        | PASS    |
| AC-18 | Step 3          | PASS (100-sample timing equivalence) |
| AC-19 | Step 1 + 3      | PASS    |
| AC-20 | Step 1 + 4.C    | PASS    |
| AC-21 | Step 3          | PASS    |
| AC-22 | Step 3          | PASS    |

**Final score: 22 of 22 PASS, no caveat.**

## Step 4 deliverables (cumulative)

### Step 4.A — partner-keys CLI + emergency visibility revert

- `coordinator partner-keys issue` — generates a 47-char `mpk_*`
  token (43-char base64url body), sha256-hashes it into
  `partner_keys.token_hash`, INSERTs the row with locked column
  set (label, prefix, allowed_origins, rate_limit_rpm,
  created_by, rotated_from_id; v0.1.8 dropped
  `rate_limit_burst`), and delivers the raw token EXACTLY ONCE
  via stdout OR `--token-out FILE` (mode 0600, O_EXCL).
- `coordinator partner-keys revoke --id N --reason TEXT` —
  idempotent UPDATE; refuses to clobber an already-revoked row;
  clean stderr diagnostic on missing-id.
- `coordinator partner-keys list` — operator-visible audit
  table; raw token never re-emitted.
- `coordinator visibility revert` — emergency operator-side
  setter that hardcodes bucketed mode; `coordinator visibility
  exact ...` is **hard-rejected** at parse time per SPEC §6.6.2.
- SECURITY r1 H1 fix: `JOURNAL_STREAM` env detection refuses
  stdout token print when systemd-journal would persist it.

Files:
[`cmd/coordinator/partnerkeys.go`](../phase4-coordinator/cmd/coordinator/partnerkeys.go),
[`cmd/coordinator/visibility.go`](../phase4-coordinator/cmd/coordinator/visibility.go),
[`cmd/coordinator/dispatch.go`](../phase4-coordinator/cmd/coordinator/dispatch.go).

### Step 4.B — nginx edge

- `nginx-stats.streamvc.live.conf` — shape-(a) standalone vhost
  on `stats.streamvc.live`; TLS + HSTS + security headers via
  shared snippet; per-endpoint rate-limit zones; `proxy_cache`
  for public projection only with `proxy_cache_bypass` +
  `proxy_no_cache` paired on `$http_authorization`
  (SECURITY r5 C1).
- `nginx-coordinator.streamvc.live.conf` — shape-(b) embedded
  `/v1/stats/*` block in the existing coordinator vhost; same
  zones / cache / security headers.
- `nginx-snippets/stats-shared.conf` — `$public_rl_key` map
  (Authorization-aware: empty key for keyed traffic →
  keyed-bypass), three per-endpoint `limit_req_zone` declarations
  at `rate=60r/m`, the shared `stats_public` cache, and the
  redacted access-log format.
- `nginx-snippets/stats-security-headers.conf` — shared
  `add_header` block (HSTS, X-Frame-Options, X-Content-Type-
  Options, Referrer-Policy, Permissions-Policy) included by both
  vhosts. Mitigates the nginx-header-shadowing trap
  ([[nginx-add-header-inheritance-trap]]).
- All 6 `limit_req` directives carry `burst=59 nodelay` per the
  22-AC sweep reconciliation: admits 60 immediate, 61st 429s,
  sustained 60/min (the §5.6 contract).

Files:
[`dist/nginx-stats.streamvc.live.conf`](../phase4-coordinator/dist/nginx-stats.streamvc.live.conf),
[`dist/nginx-coordinator.streamvc.live.conf`](../phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf),
[`dist/nginx-snippets/`](../phase4-coordinator/dist/nginx-snippets/),
[`dist/test/check_nginx_stats_test.sh`](../phase4-coordinator/dist/test/check_nginx_stats_test.sh).

### Step 4.C — observability + runbook

Structured-log events on the locked §8.5 taxonomy
(`internal/stats/...`):

- `stats_request_served` — access-log middleware
  (`middleware.go::accessLogMiddleware`); fields: endpoint,
  status, latency_ms, generated_at_age_ms, partner_key_id.
- `stats_rollup_tick_completed` — rollup runner success path
  (`rollup/runner.go::runOne`); fields: component, generated_at,
  duration_ms. Skipped on the `rewards_populated` tick
  (round-1 CODE H3).
- `stats_rollup_drift_detected` — rebuild path
  (`rollup/rebuild.go::emitDriftIfExceeds`); fields: component,
  axis, divergence_pct, rebuild_value, incremental_value
  (round-2 ARCH M2 narrowed; debug-only triage line carries
  delta_ratio + provider_id_sample).
- `stats_handler_panic` — recover middleware
  (`middleware.go::recoverMiddleware`); fields: route,
  request_id (round-2 ARCH M2 / CODE H2 narrowed; debug-only
  untagged stack line carries panic_type).
- `stats_partner_key_issued` — CLI issue success boundary
  (`cmd/coordinator/partnerkeys.go`); fields: id, label,
  created_by, rotated_from_id. Emits only AFTER raw-token
  delivery (round-3 CODE M1).
- `stats_partner_key_revoked` — CLI revoke
  (`cmd/coordinator/partnerkeys.go`); fields: id, reason, actor.

Prometheus metrics (`internal/stats/metrics/metrics.go`):

- `stats_request_total{endpoint, status, tier}` — Counter
- `stats_partner_key_request_total{partner_key_id}` — Counter
- `stats_rollup_lag_seconds{component}` — Gauge
- `stats_rollup_errors_total{component}` — Counter
- `stats_rate_limit_exceeded_total{tier, endpoint}` — Counter

Closed label vocabularies: `tier ∈ {public, partner}`,
`endpoint ∈ {overview, leaderboard, health}`, `component ∈`
the §9.5 seven-component set. Unknown stats paths skip metric
emit (no `endpoint=""`).

Production wiring (`cmd/coordinator/main.go`):
coordinator-owned `prometheus.NewRegistry()` + `/metrics`
endpoint on the provider port 8444 (loopback-only per Pearl
posture); 15-s `observeRollupLag` ticker delegates to
`statsrollup.ObserveRollupLagOnce` (round-3 ARCH M1 / CODE M2
extraction).

Runbook (`OPS.md` §10):

- §10.1 Rotating a partner key (+ "If this fails")
- §10.2 Revoking a partner key in incident (+ "If this fails")
- §10.3 Restarting the rollup scheduler (+ "If this fails")
- §10.4 Emergency provider-visibility revert (+ "If this fails")
- §10.5 §6.6.2 disclosure obligation + sign-off template +
  NOT YET annotation.

Public changelog: [`docs/network-stats-api/CHANGELOG.md`](../docs/network-stats-api/CHANGELOG.md)
v0.1.8 entry with per-step PR table (single PR #173 for this
implementation).

## CI coverage gate

`make test-coordinator-integration` now runs against BOTH
`./internal/stats/...` AND `./cmd/coordinator/...` (round-4
CODE M2 expansion). The CI workflow at
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
invokes this target on every PR and adds a new dedicated job
for the nginx behavior smoke:

- `coordinator-stats-integration` — `make test-coordinator-
  integration` → Go-side ACs + Step 4.C event landings.
- `coordinator-nginx-integration` — `bash check_nginx_stats_test.sh`
  → AC-8 + AC-3-nginx + AC-15-nginx + keyed-bypass + per-endpoint
  isolation + proxy_no_cache write-suppression.

Both jobs are aggregated into the `ci-required` merge gate so
the behavior smokes block merges that would regress AC-8 or any
Step 4.B contract.

## Headline closures from each audit lane

The exhaustive round-by-round narrative lives in the individual
audit files + the 4.C r5 sub-step convergence. The top-of-mind
closures are:

### 4.A

- SECURITY r1 H1 — `JOURNAL_STREAM` env detection prevents
  systemd-journal from persisting the raw token. Closed in
  round 2 with explicit operator-facing diagnostic + `--token-out`
  remediation pointer.
- CODE r3 M1 — subprocess + handler test surface for the locked
  SPEC command (AC-17_IssueLockedSPECCommand_Subprocess proves
  the binary's argv parsing + CSPRNG + sha256 + base64url
  assembly works end-to-end through `exec.Command`).

### 4.B

- ARCH r1 H1 — `proxy_cache_bypass $http_authorization` alone
  only blocks cache READS; SECURITY r5 C1 added the paired
  `proxy_no_cache $http_authorization` write-suppression so
  partner projections cannot land on disk.
- CODE r3 C1 — three shared declarations (the `$public_rl_key`
  map, three `limit_req_zone`s, the `stats_public` cache) moved
  from the standalone vhost to `nginx-snippets/stats-shared.conf`
  so a deploy that installs only the coordinator vhost still
  passes `nginx -t`.
- 22-AC sweep reconciliation (this commit) — `burst=59 nodelay`
  on all 6 `limit_req` directives closes the deferred SPEC §5.6
  ↔ AC-8 contradiction noted in earlier r6 / r7 / r9 audits.

### 4.C

- ARCH r1 H1 / CODE r2 H2 — `stats_handler_panic` narrowed to
  the locked `{route, request_id}` field set after r1 r2
  reshaping; triage detail (panic_type, stack) lives on an
  untagged debug log line.
- CODE r2 H1 — mutable `requestObs` pointer-in-context pattern
  closes the immutable `r.WithContext` propagation bug;
  PartnerKeyID and GeneratedAtAgeMs both reach the outer
  access-log middleware reliably.
- CODE r3 M1 — `stats_partner_key_issued` emit moved past the
  success boundary so the JOURNAL_STREAM-suppressed exit-1 +
  file-write-failed exit-1 paths emit no event.
- ARCH r4 M1 / CODE r4 M1 — wired metric-label hygiene test
  hardened with SPEC-shaped 47-char token, expanded denylist
  (bearer + prefix + generic `mpk_`), and explicit
  family-presence assertion across all five metrics.

## Local verification on locked HEAD `9784ef5`

    cd phase4-coordinator
    go build ./...                                    # PASS
    go vet ./... && go vet -tags=integration ./...    # PASS
    go test -count=1 ./...                            # PASS (default)
    golangci-lint run ./...                           # PASS (0 issues)

    go test -tags=integration -count=1 -timeout 15m -v \
      -run 'TestAC[0-9]+_|TestStep4C_|TestForbidigoOSExitRule|TestLabelHygiene|TestAC16ForbiddenImportFails' \
      ./internal/stats/... ./cmd/coordinator/...
    # → every TestACN_* PASS (21 native ACs + 6 Step 4.C event
    #   landings); transcript at /tmp/ac-sweep-v.out

    bash phase4-coordinator/dist/test/check_nginx_stats_test.sh
    # → ok: nginx -t passes
    # → ok: AC-8: 60 anonymous /overview pass, 61st returns 429 + Retry-After + §5.9 envelope
    # → ok: keyed-bypass: 100 valid-keyed /leaderboard pass without edge 429
    # → ok: per-endpoint isolation: 50 /overview + 50 /leaderboard share no quota
    # → ok: AC-3 (nginx-tier): Bearer garbage → 401 envelope through nginx
    # → ok: proxy_no_cache write-suppression: keyed request added 0 cache entries
    # → ok: AC-15: keyed request log contains no raw token / body / token_hash
    # → PASS: SPEC-017 Step 4.B nginx behavior smoke

## Disposition

PR #173 ships. The capability is complete; the only remaining
operational gate is the §6.6.2 disclosure sign-off, which is
explicitly outside this PR's scope and is recorded as
NOT YET SATISFIED in `OPS.md` §10.5. An operator must run that
gate before issuing any production partner key.

## Cross-references

- [SPEC-017-network-stats-api.md (v0.1.8 LOCKED)](SPEC-017-network-stats-api.md)
- [BUILD_SPEC_017_IMPL_PROMPT.md](BUILD_SPEC_017_IMPL_PROMPT.md)
- [SPEC-017-IMPL-STEP_4C-r5-convergence.md](SPEC-017-IMPL-STEP_4C-r5-convergence.md)
- [SPEC-017-IMPL-STEP_4-22AC-sweep.md](SPEC-017-IMPL-STEP_4-22AC-sweep.md)
- [SPEC-017-IMPL-STEP_3-r8-convergence.md](SPEC-017-IMPL-STEP_3-r8-convergence.md)
- [SPEC-017-IMPL-STEP_2-r10-convergence.md](SPEC-017-IMPL-STEP_2-r10-convergence.md) (if present)
- [`docs/network-stats-api/CHANGELOG.md`](../docs/network-stats-api/CHANGELOG.md)
- [`OPS.md` §10](../OPS.md)
- All per-lane audit files at `specs/SPEC-017-IMPL-STEP_4{A,B,C}-{arch,code,security}-rN-audit.md`.
