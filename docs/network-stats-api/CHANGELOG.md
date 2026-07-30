# Network Stats API — Changelog

Per SPEC-017 §8.5. Each entry cites the PR(s) that landed the
delta, the SPEC version delivered, and a one-line summary suitable
for a partner-facing announcement.

## v0.1.9 — 2026-07-29

Adds `network.capacity_estimate_sources` to
`GET /v1/stats/overview` so synthetic capacity totals are labeled as
estimates from hardware profiles or provider-reported summaries, not
as hardware attestation. Existing numeric metrics are unchanged.

Delivered in PR [Augustas11/macprovider#805][pr805].

## v0.1.8 — 2026-06-26

First public release. Surface frozen to:

- `GET /v1/stats/overview` — 14 network fields + nested 30-minute
  rpm/tpm timeseries.
- `GET /v1/stats/leaderboard` — paginated leaderboard with
  public projection (bucketed earnings, public providers) +
  partner-key projection (exact earnings, every provider per
  §6.6.2).
- `GET /v1/stats/health` — 7-component health map per §9.5
  budgets.

Other locked v0.1.8 behavior:

- §5.6 three-tier rate limiting: public 60/IP/endpoint, partner
  600/key/endpoint (key-overridable), auth-failure 300/IP/endpoint
  with reserve-then-refund.
- §5.7 CORS: partner projection never `ACAO: *`, sibling-subdomain
  rejected, RFC 6454 ASCII normalization on all Origin compares.
- §5.8 staleness: overview 120s, leaderboard 24h 300s / 7d 1800s
  / 30d 14400s / all 86400s.
- §5.9 closed error vocabulary + JSON envelope.
- §6.6.2 partner-key exact-$ disclosure obligation; OPS.md
  §10.5 sign-off template.

Delivered in PR [Augustas11/macprovider#173][pr173] across six
audit-converged steps (all six landed on a single PR so each row
cites #173; future v0.2 releases will split per-step PRs and the
table will carry distinct numbers):

| Step | PR | Scope | Audit-loop rounds |
|------|-----|-------|-------------------|
| 1    | [#173][pr173] | Postgres pools + 4-role grants + lint surface       | 1 round |
| 2    | [#173][pr173] | Rollup runner (7 components) + drift detection + retention | 10 rounds |
| 3    | [#173][pr173] | HTTP handlers + 7-layer middleware + §5.4.3 dispatcher | 8 rounds |
| 4.A  | [#173][pr173] | `coordinator partner-keys` + `coordinator visibility revert` CLI | 4 rounds |
| 4.B  | [#173][pr173] | Nginx vhost + cache + rate-limit + Pearl deploy pipeline | 4 rounds |
| 4.C  | [#173][pr173] | Structured-log events + Prometheus metrics + OPS.md + this changelog | (this PR) |

Step 4.C metrics surface (per `internal/stats/metrics/metrics.go`):

- `stats_request_total{endpoint,status,tier}`
- `stats_partner_key_request_total{partner_key_id}` (integer id only)
- `stats_rollup_lag_seconds{component}`
- `stats_rollup_errors_total{component}`
- `stats_rate_limit_exceeded_total{tier,endpoint}`

Structured log event taxonomy: `stats_request_served`,
`stats_rollup_tick_completed`, `stats_rollup_drift_detected`,
`stats_handler_panic`, `stats_partner_key_issued`,
`stats_partner_key_revoked`.

[pr173]: https://github.com/Augustas11/macprovider/pull/173
[pr805]: https://github.com/Augustas11/macprovider/pull/805
