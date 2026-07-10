# SPEC-017 IMPL Step 4.C - Security Audit Round 2

Date: 2026-06-26
PR: `Augustas11/macprovider#173`
Branch: `impl/spec-017-step-1`
HEAD audited: `ed86d8bb1dbe02b5c4e39d5a7991de79965b246d`
Diff base checked: `022cd55` (Step 4.B lock tip)
Lens: SECURITY - label leak / disclosure gate / metric cardinality

## Verdict

READY TO LOCK.

Blocking count: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW / 9 INFO.

Round 1's two security blockers are closed:

- SECURITY r1 CRITICAL: the Step 4.C convergence file now exists and quotes the
  Section 6.6.2 sign-off template while recording live SPEC-014 v0.9 disclosure
  as `NOT YET SATISFIED`.
- SECURITY r1 HIGH: `stats_partner_key_issued` no longer emits `prefix` or any
  raw-token substring.

## Required Reading And Validation

Required reading completed:

- `CLAUDE.md`.
- Step 4.C ARCH/CODE/SECURITY prompts.
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 6.6.2, 7.4, 8.5, 9.4,
  9.5, 9.6, and AC-15/AC-20/AC-22.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C, the v0.1.7-tightened Section
  6.6.2 cutover gate, v11 ARCH r10 H1, and the AC ownership matrix.
- Step 3 convergence record and Step 4.A / Step 4.B security lock audits.
- Step 4.C ARCH/CODE/SECURITY r1 audits and Step 4.C r1 convergence record.

Commands run:

- `git fetch origin` - PASS.
- `git diff --name-only 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - scoped the Step 4.C diff.
- Required structured-event `rg` sweep - all six names present.
- Required metric-name `rg` sweep - all five names present.
- `git grep -n -E 'mpk_[A-Za-z0-9_-]{12,}' -- OPS.md specs docs phase4-coordinator | head -100`
  - no real-looking `mpk_` token in `OPS.md`; hits are tests/prompts only.
- `go build ./...` from `phase4-coordinator/` - PASS.
- `go test ./...` from `phase4-coordinator/` - PASS.
- `go vet ./...` from `phase4-coordinator/` - PASS.
- `golangci-lint run ./...` from `phase4-coordinator/` - PASS, `0 issues`.
- `go test ./internal/stats/metrics` and `go test ./internal/stats/...` - PASS.
- `make test-coordinator-integration` - NOT RUN TO COMPLETION locally; testcontainers
  panicked with `rootless Docker not found` before AC-20 / wired hygiene tests.
- `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
  - FAIL only on trailing whitespace in the prior
  `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md` artifact.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

1. `/metrics` remains unauthenticated and relies on the checked-in loopback bind
   posture plus nginx route absence.

   Evidence: Step 4.C mounts `/metrics` on the provider mux at
   `phase4-coordinator/cmd/coordinator/main.go:535-558`. The production example
   and defaults bind the coordinator to `127.0.0.1`
   (`dist/coordinator.yaml.example:7-10`, `internal/config/config.go:381-387`),
   and checked-in nginx stats/coordinator vhosts proxy only
   `/v1/stats/{overview,leaderboard,health}`, not `/metrics`.

   Risk: Low defense-in-depth residual. The committed deployment posture is
   loopback-only, so I do not find a public scrape endpoint. A future operator
   config that changes `listen.bind_address` to a non-loopback address would
   expose unauthenticated metrics unless an external firewall compensates.

   Fix: make the assumption executable by failing startup when stats metrics are
   enabled and the provider bind address is not loopback, or move metrics to a
   separate loopback-only / bearer-gated listener.

2. The scoped diff's hygiene check is dirtied by r1 audit whitespace, not by
   executable Step 4.C code.

   Evidence: `git diff --check 022cd55..HEAD -- phase4-coordinator/ OPS.md docs/ specs/`
   reports trailing whitespace on lines 3-5 of
   `specs/SPEC-017-IMPL-STEP_4C-security-r1-audit.md`.

   Risk: Non-runtime polish. This does not affect label leak, disclosure gate,
   or metric cardinality behavior, but it keeps the broad diff check from going
   green.

   Fix: strip trailing spaces from the r1 audit artifact if the PR requires
   `git diff --check` to pass over specs.

### INFO

- The five metric declarations use only the required labels:
  `stats_request_total{endpoint,status,tier}`,
  `stats_partner_key_request_total{partner_key_id}`,
  `stats_rollup_lag_seconds{component}`,
  `stats_rollup_errors_total{component}`, and
  `stats_rate_limit_exceeded_total{tier,endpoint}`.
- `partner_key_id` is sourced only from the matched `partner_keys.id` integer
  and emitted with `strconv.FormatInt`, not label text, prefix, token hash, raw
  token, Authorization, or Origin.
- Endpoint values are closed by exact path matching to `overview`,
  `leaderboard`, `health`, or `""` for non-stats paths before metrics emit.
- `stats_partner_key_issued` emits only `id`, `label`, `created_by`, and
  `rotated_from_id`; the previous `prefix` leak is gone.
- `stats_handler_panic` is emitted inside the existing redaction middleware
  stack and records route/request_id/type only; the stack log is debug-only and
  no longer tagged as a `stats_*` event.
- `OPS.md` partner-key issue examples show commands only; no real-looking
  `mpk_<base64url>` token appears in the runbook.
- The OPS.md sign-off template and convergence-file quote match, and both state
  SPEC-014 v0.9 live disclosure remains a cutover prerequisite before first
  production partner-key issuance.
- AC-20 is the required SQL count assertion and is wired into the PR integration
  job through `make test-coordinator-integration`.
- The metric hygiene tests now include both a package-level all-metric scan and
  an integration-tag wired-mux scan for request-derived labels.

## Category Sweep

A. Metric-label leak sweep: PASS. Every labeled metric was enumerated. Request
metrics take `endpoint` from exact route tokens, `status` from the HTTP status
integer, and `tier` from the closed request classification (`public`,
`partner`, or `auth_failure`). Partner-key request metrics take only
`partner_keys.id` as a decimal integer. Rollup metrics take fixed component
names. No metric label carries raw token, 43-character body, `token_hash`,
prefix, partner key label text, Authorization fragment, or Origin fragment.

B. Event field redaction: PASS. Events emit operator-permitted fields only for
the security lens. Panic events defensively re-redact Authorization/Cookie/
X-Api-Key before logging and avoid panic payload strings. Partner-key issuance
no longer emits prefix or `created_at`; revoke emits id/reason/actor only.

C. Operator-runbook redaction defaults: PASS. The `coordinator partner-keys
issue` recipe in `OPS.md:625-631` contains no token placeholder and no real
`mpk_*` value; it instructs operators to use `--token-out` when stdout is
journal-captured.

D. Section 6.6.2 sign-off template: PASS. `OPS.md:753-766` contains the
template; `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md:18-33` quotes it and
states live production sign-off is `NOT YET SATISFIED`, remaining an operator
cutover prerequisite.

E. AC-20 CI assertion strength: PASS. The test uses the required SQL count:
`SELECT COUNT(*) FROM provider_visibility_audit WHERE new_mode = 'exact' AND
actor_kind = 'operator'`, and `.github/workflows/ci.yml` runs the integration
target on PRs.

F. Metric scrape endpoint posture: PASS with LOW caveat above. `/metrics` is
not publicly proxied by checked-in nginx and the committed/default coordinator
bind address is loopback. The endpoint itself is not bearer-auth gated.

G. Cross-step disclosure surface: PASS. Step 4.C composes through the existing
Step 3 middleware stack (`redactionContextMiddleware -> recover -> access log`)
and does not replace the Step 3 redaction surface.

H. AC-15 Step 4.C share: PASS. `TestLabelHygiene` scans all five metric
families for `mpk_`, `token_hash`, `Authorization`, 43-character body shape,
and Origin fragment. `TestStep4C_WiredMux_MetricLabelHygiene` drives real
requests through `stats.NewMuxWithMetrics`, gathers the registry, and scans
label values for request-derived Authorization/Origin material. Local
Docker-backed execution was blocked, but CI wiring exists.

## Lock Status

SECURITY lock target is met: 0 CRITICAL + 0 HIGH + 0 MEDIUM.
