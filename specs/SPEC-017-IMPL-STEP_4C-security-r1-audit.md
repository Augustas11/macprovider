# SPEC-017 IMPL Step 4.C - Security Audit Round 1

PR: Augustas11/macprovider#173  
Branch: `impl/spec-017-step-1`  
Lens: SECURITY - label leak / disclosure gate / metric cardinality  
Verdict: NOT CONVERGED - 1 CRITICAL / 1 HIGH / 0 MEDIUM / 2 LOW / 8 INFO

Required reading completed: `CLAUDE.md`; `specs/AUDIT_SPEC_017_IMPL_STEP_4C_ARCH_PROMPT.md`; `specs/AUDIT_SPEC_017_IMPL_STEP_4C_CODE_PROMPT.md`; `specs/AUDIT_SPEC_017_IMPL_STEP_4C_SECURITY_PROMPT.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.C and AC matrix; locked `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 5.4.6, 6.6.2, 7.4, 8.5, 9.4, 9.5, 9.6, and AC-15/AC-20/AC-22; Step 3 convergence file. Step 4.A and Step 4.B convergence records were not present in the worktree.

## Findings

### CRITICAL

1. `specs/SPEC-017-IMPL-STEP_4C-r*-convergence.md` is absent, so the disclosure gate has no auditable production-status statement.

   Evidence: `find specs -maxdepth 1 -name 'SPEC-017-IMPL-STEP_4C*convergence*.md' -print` returns no files; no Step 4.C convergence file exists. `OPS.md:725` through `OPS.md:742` correctly contains the sign-off template and states current status is `NOT YET SATISFIED`, but the Step 4.C security prompt explicitly requires the convergence file to state whether live SPEC-014 v0.9 disclosure is in production or remains an operator-side cutover prerequisite.

   Risk: the privacy boundary for partner-key exact-dollar disclosure is process-owned. Without the convergence artifact, later reviewers cannot tell whether production key issuance is still blocked by SPEC-014 v0.9 disclosure deployment or has been signed off.

   Fix: add `specs/SPEC-017-IMPL-STEP_4C-r1-convergence.md` or the final round equivalent. Quote the OPS.md sign-off template verbatim and state: `SPEC-014 v0.9 commit SHA + date both disclosure surfaces went live = NOT YET; remains a cutover prerequisite before first production partner-key issuance`, unless the live portal deployment has actually happened.

### HIGH

1. `stats_partner_key_issued` emits `prefix`, a substring of the raw token, in the structured event.

   Evidence: `phase4-coordinator/cmd/coordinator/partnerkeys.go:293` through `phase4-coordinator/cmd/coordinator/partnerkeys.go:300` emits `stats_partner_key_issued` with `id`, `label`, `prefix`, `created_by`, `rotated_from_id`, and `created_at`. The Step 4.C BUILD field set for this event is `partner_keys.id`, `label`, `created_by`, and `rotated_from_id_or_null`; the security prompt rates a `stats_partner_key_issued` event containing a raw-token substring as HIGH. The prefix is derived from `rawToken[:8]` at `partnerkeys.go:266`.

   Risk: SPEC 5.4.6 permits prefix in general operator logs, but the Step 4.C event taxonomy is a narrower disclosure surface. Emitting secret-derived prefix in the issuance event creates avoidable event-field drift and increases correlation value in downstream log aggregation.

   Fix: remove `prefix` from the `stats_partner_key_issued` structured event. Keep correlation on `partner_keys.id`; leave prefix only in the existing operator metadata paths already covered by Step 4.A.

### MEDIUM

None.

### LOW

1. `/metrics` exposure relies on the existing loopback bind posture, not an explicit stats-metrics guard.

   Evidence: `phase4-coordinator/cmd/coordinator/main.go:535` through `main.go:558` mounts unauthenticated `/metrics` on the provider mux. Checked-in coordinator examples bind to `127.0.0.1`, and the public nginx stats vhost only proxies the three `/v1/stats/{overview,leaderboard,health}` paths (`phase4-coordinator/dist/nginx-stats.streamvc.live.conf:99`, `:127`, `:150`), so I did not find a public nginx route to `/metrics`.

   Risk: non-blocking defense-in-depth gap. If an operator changes `listen.bind_address` away from loopback, the scrape endpoint becomes unauthenticated on that interface.

   Fix: when `stats.enabled` is true and `/metrics` is mounted, fail startup unless the bind address is loopback, or move metrics to a separate loopback-only listener / bearer-auth-gated endpoint.

2. The metric hygiene test is synthetic rather than a real mux scrape.

   Evidence: `phase4-coordinator/internal/stats/metrics/metrics_test.go:37` through `metrics_test.go:53` instantiates the registry and manually increments all five metric vectors. It does walk labels and blocks `mpk_`, `token_hash`, `Authorization`, 43-character token-body shapes, non-integer `partner_key_id`, and unbounded tier/endpoint/component values.

   Risk: low security residual. The code path appears safe by inspection, but this test would not catch a future mux-level regression that passes a request-derived value into a label.

   Fix: add a companion test that creates `NewMuxWithMetrics`, drives public, partner, rate-limit, and health requests, scrapes the registry, and runs the same denylist over emitted labels.

## Category Sweep

A. Metric-label leak sweep: PASS for leak. The five declared metrics are `stats_request_total{endpoint,status,tier}`, `stats_partner_key_request_total{partner_key_id}`, `stats_rollup_lag_seconds{component}`, `stats_rollup_errors_total{component}`, and `stats_rate_limit_exceeded_total{tier,endpoint}` (`metrics.go:58` through `metrics.go:92`). Values are endpoint/status/tier/id/component only; no raw token, body, `token_hash`, prefix, label text, Authorization, or Origin-derived value is used as a label. One bounded non-secret drift remains: tests allow `endpoint=""` and `tier="auth_failure"` although the prompt's narrow allowlist names endpoint values and `public`/`partner` only.

B. Event field redaction: FAIL HIGH for `stats_partner_key_issued` carrying `prefix`. Other events are clean by inspection: `stats_handler_panic` strips Authorization/Cookie/X-Api-Key and omits panic payload (`middleware.go:95` through `middleware.go:118`); `stats_request_served` emits endpoint/method/status/timing/partner key id only (`middleware.go:176` through `middleware.go:184`); rollup tick/drift emit bounded component/axis/numeric fields (`runner.go:234` through `runner.go:239`, `rebuild.go:231` through `rebuild.go:242`); revoke emits id/reason/actor only (`partnerkeys.go:431` through `partnerkeys.go:438`).

C. Operator-runbook redaction defaults: PASS. The only Step 4.C `partner-keys issue` runbook command is `OPS.md:625` through `OPS.md:631`; it does not show a real-looking `mpk_<base64url>` token. No `mpk_` literal was found in OPS.md.

D. Section 6.6.2 sign-off template: FAIL CRITICAL for the missing convergence record. OPS.md itself contains the disclosure copy, the blocking cutover gate, the sign-off template, and the explicit `NOT YET SATISFIED` status (`OPS.md:693` through `OPS.md:742`).

E. AC-20 CI assertion strength: PASS. The assertion is SQL, not CLI introspection: `phase4-coordinator/internal/stats/integration_test.go:466` through `integration_test.go:475` runs `SELECT COUNT(*) FROM provider_visibility_audit WHERE new_mode = 'exact' AND actor_kind = 'operator'` and requires zero. `.github/workflows/ci.yml:167` through `.github/workflows/ci.yml:187` wires `make test-coordinator-integration` on every PR.

F. Metric scrape endpoint posture: PASS with LOW caveat. `/metrics` is not publicly proxied by checked-in nginx and checked-in coordinator examples bind loopback. The endpoint itself is unauthenticated, so the loopback assumption should be made executable.

G. Cross-step disclosure surface: PASS. Step 4.C composes through the existing stats middleware stack (`mux.go:64` through `mux.go:70`) and does not replace Step 3 redaction. Panic and access-log tests still target the existing redaction middleware (`handlers_integration_test.go:1075` through `handlers_integration_test.go:1135`).

H. AC-15 Step 4.C share: PASS by implementation inspection and synthetic test; LOW test-shape caveat above. Metric labels are scanned by `TestLabelHygiene`, and all live metric emitters derive values from endpoint/status/tier/id/component sources, not request headers or token material.

## Validation

- `git diff --name-only origin/main...HEAD -- phase4-coordinator/ OPS.md docs/ specs/` scoped the implementation surface.
- `rg` sweeps found all six structured event names and all five metric names.
- `go build ./...` from `phase4-coordinator/`: PASS.
- `go test ./...` from `phase4-coordinator/`: PASS.
- `go vet ./...` from `phase4-coordinator/`: PASS.
- `golangci-lint run ./...` from `phase4-coordinator/`: PASS, `0 issues`.
- `find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l`: reported `./internal/buyer/transport_result_test.go` and `./internal/tier2/catalog_di_test.go`, both outside the Step 4.C stats surface and not changed by this PR diff subset.
- `make test-coordinator-integration`: NOT RUN TO COMPLETION locally. It failed before AC-20 execution because testcontainers could not find rootless Docker (`panic: rootless Docker not found`). CI wiring for the same target is present.

## Lock Status

Lock target is not met. Step 4.C SECURITY remains blocked on:

- CRITICAL: add the required Step 4.C convergence artifact with the Section 6.6.2 production disclosure status.
- HIGH: remove `prefix` from the `stats_partner_key_issued` structured event.
