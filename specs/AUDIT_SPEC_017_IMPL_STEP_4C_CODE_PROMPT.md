# AUDIT_SPEC_017_IMPL_STEP_4C — Code lane

Operator-paste prompt to audit the **Step 4.C IMPL diff**
(observability, runbook, changelog, end-of-impl AC sweep) under
PR `Augustas11/macprovider#173` from the code lens.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_4C-code-rM-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.C IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) from the CODE (implementation
correctness) lens.

Step 4.C scope: see ARCH-lane prompt.

Output: specs/SPEC-017-IMPL-STEP_4C-code-rM-audit.md.

Severity model:
- CRITICAL — wrong metric label value leaks secret-derived
  material; structured-log emit fails to pass through the
  Step 3 redaction-context middleware (raw Authorization
  bleeds into a `stats_handler_panic` event); a metric is
  declared with a label cardinality that would blow up the
  Prometheus scrape job (e.g. `endpoint` left unbounded).
- HIGH — emitted event field set drifts from SPEC: missing
  `latency_ms` on `stats_request_served`; `stats_rollup_drift_
  detected` missing one of the four §9.4 axes; metric
  registration uses wrong type (Histogram where Counter is
  required); a label is misspelled so dashboards break
  silently.
- MEDIUM — partial test coverage of a metric or event; the
  emit path is correct but the structured-log emit was added
  outside the request goroutine (so events miss request
  context).
- LOW — polish / quality / non-blocking.
- INFO — positive observations.

Required reading (same as ARCH lane).

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Event emitter wiring** — `stats_request_served` lives
   inside the access-log middleware (Step 3 already emits a
   `request_served` log line; Step 4.C MAY re-key it to the
   v0.1.8 SPEC name). `stats_rollup_tick_completed` /
   `stats_rollup_drift_detected` live in
   `internal/stats/rollup/` (Step 2 surface). `stats_handler_
   panic` lives in the recover middleware (Step 3 already
   emits an `error="panic"` line; Step 4.C MAY re-key).
   `stats_partner_key_issued` / `stats_partner_key_revoked`
   live in the CLI subcommand success paths.

B. **Prometheus metric type + labels** — `stats_request_total`
   is a Counter; `stats_partner_key_request_total` is a
   Counter labeled by `partner_keys.id` (BIGINT cast to
   string); `stats_rollup_lag_seconds` is a Gauge labeled by
   component; `stats_rollup_errors_total` is a Counter labeled
   by component; `stats_rate_limit_exceeded_total` is a
   Counter labeled by tier + endpoint.

C. **Field redaction** — events MUST NOT carry the raw token,
   43-char body, `token_hash`, raw Authorization header value,
   or any byte-substring of secret material. Only the
   operator-permitted `prefix` and `partner_keys.id` are
   surfaceable.

D. **OPS.md runbook entries** — exactly four entries land,
   each with: invocation command, expected outcome, recovery
   step if it fails. The verbatim sign-off template is the
   block at the end of the disclosure section, with all
   placeholder fields named (`<commit SHA>`, `<date>`).

E. **CHANGELOG.md format** — Markdown header + bullet list
   matching §8.5 patterns. PR numbers cite the four step
   commits (Step 1 / Step 2 / Step 3 / Step 4 PRs — there is
   one PR for all steps in this implementation, so cite that
   PR for each step's deliverables).

F. **AC-20 CI gate** — file location: integration test under
   the build-tag suite already wired into GitHub Actions.
   Test name: `TestAC20_NoOperatorExactRow_Final` or similar.
   Pure SQL count assertion.

G. **Metric-label hygiene test** — under `go test`, instantiate
   the metric registry, drive a real request through the Step
   3 mux, scrape via `prometheus.DefaultGatherer.Gather()`
   or equivalent, walk every labeled metric, assert no label
   value matches `regexp.MustCompile("[A-Za-z0-9_-]{43}")` or
   contains `mpk_` (other than the prefix-permitted contexts —
   and prefix MUST NOT be a metric label here).

H. **End-of-impl AC sweep** — convergence file lists all 22
   ACs with test paths. AC-1..AC-7, AC-11..AC-14, AC-18, AC-21
   are Step 3. AC-8 is Step 4.B. AC-9, AC-10, AC-16 are Step
   1. AC-15 distributed across steps. AC-17 is Step 4.A. AC-19
   distributed. AC-20 cross-step. AC-22 is Step 3.

I. **Test surface** — every new emitter (event or metric)
   gets a test that runs once + asserts the value lands. Tests
   compile and pass against the default `go test ./...`.

Validation steps:
- `go build ./...` from `phase4-coordinator/`.
- `go test ./...`.
- `go vet ./...`.
- `gofmt -l ./...`.
- `golangci-lint run ./...`.
- Manual scan of OPS.md changelog + sign-off template.

Output structure (one document per round, fresh file).

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
