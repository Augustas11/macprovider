// Package metrics declares the SPEC-017 v0.1.8 §8 Prometheus
// metric surface plus SPEC-026 register counters. Wired by Step 4.C
// per BUILD §2:
//
//	stats_request_total{endpoint,status,tier}                — Counter
//	stats_partner_key_request_total{partner_key_id}           — Counter
//	stats_rollup_lag_seconds{component}                        — Gauge
//	stats_rollup_errors_total{component}                       — Counter
//	stats_rate_limit_exceeded_total{tier,endpoint}             — Counter
//
// Label hygiene (SECURITY M5 — Step 4.C SECURITY lane category A):
//
//   - `partner_key_id` is the INTEGER row id from `partner_keys.id`
//     ONLY. Never the prefix, label_text, raw token, or token_hash
//     bytes. Cardinality is bounded by the operator-issued key set
//     (typically tens, not thousands).
//
//   - `tier` is a closed set: "public" or "partner". The
//     locked Step 4.C contract per BUILD §2 pins this to two
//     values; there is no `auth_failure` tier. Auth-failure
//     limiter 429s are emitted as `tier="public"` (the request
//     never reached a partner-key match).
//
//   - `endpoint` is a closed set: "overview" / "leaderboard" /
//     "health" (mirrors the Step 3 mux verbs).
//
//   - `component` is a closed set from §9.5: "overview",
//     "timeseries_rpm", "timeseries_tpm", "leaderboard_24h",
//     "leaderboard_7d", "leaderboard_30d", "leaderboard_all".
//
//   - `status` is the HTTP status code as a decimal string.
//
//   - `provider_register_rate_limit_hits_total{scope}` uses closed
//     scope values "ip" / "asn".
//
//   - `provider_register_source_total{track}` uses closed track values
//     "app" / "cli" / "portal".
//
// No label takes an operator- or attacker-controllable string directly.
// A `Reset` method exists for test isolation.
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics holds the five SPEC-017 v0.1.8 metrics. New() takes a
// prometheus.Registerer so tests can use a fresh registry per
// case; production code passes prometheus.DefaultRegisterer (or
// a coordinator-owned named registry).
type Metrics struct {
	RequestTotal           *prometheus.CounterVec
	PartnerKeyRequestTotal *prometheus.CounterVec
	RollupLagSeconds       *prometheus.GaugeVec
	RollupErrorsTotal      *prometheus.CounterVec
	RateLimitExceededTotal *prometheus.CounterVec
	RegisterRateLimitHits  *prometheus.CounterVec
	RegisterSource         *prometheus.CounterVec
}

// New registers all five metrics against reg and returns the
// Metrics handle. promauto.With(reg) panics on double-register;
// production callers MUST construct this once at coordinator
// boot (BUILD §C.3 fail-closed contract — duplicate registration
// of the same metric name is a deploy-time bug, not a runtime
// branch).
func New(reg prometheus.Registerer) *Metrics {
	f := promauto.With(reg)
	return &Metrics{
		RequestTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "stats_request_total",
				Help: "Count of /v1/stats/* requests served by the in-process handler stack, labeled by endpoint, status code, and tier.",
			},
			[]string{"endpoint", "status", "tier"},
		),
		PartnerKeyRequestTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "stats_partner_key_request_total",
				Help: "Count of partner-projection requests served, labeled by the integer partner_keys.id only.",
			},
			[]string{"partner_key_id"},
		),
		RollupLagSeconds: f.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "stats_rollup_lag_seconds",
				Help: "Per-component rollup lag in seconds (now - stats_components_health.generated_at).",
			},
			[]string{"component"},
		),
		RollupErrorsTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "stats_rollup_errors_total",
				Help: "Count of rollup-tick errors per component (panics + returned errors).",
			},
			[]string{"component"},
		),
		RateLimitExceededTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "stats_rate_limit_exceeded_total",
				Help: "Count of requests rejected by the in-process rate limiter, labeled by tier (public/partner) and endpoint.",
			},
			[]string{"tier", "endpoint"},
		),
		RegisterRateLimitHits: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "provider_register_rate_limit_hits_total",
				Help: "Count of SPEC-026 /v1/providers/register requests rejected by register rate limit scope.",
			},
			[]string{"scope"},
		),
		RegisterSource: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "provider_register_source_total",
				Help: "Count of provider register attempts by onboarding track.",
			},
			[]string{"track"},
		),
	}
}

func (m *Metrics) IncRegisterRateLimitHit(scope string) {
	if m == nil || m.RegisterRateLimitHits == nil {
		return
	}
	switch scope {
	case "ip", "asn":
	default:
		return
	}
	m.RegisterRateLimitHits.WithLabelValues(scope).Inc()
}

func (m *Metrics) IncRegisterSource(track string) {
	if m == nil || m.RegisterSource == nil {
		return
	}
	switch track {
	case "app", "cli", "portal":
	default:
		return
	}
	m.RegisterSource.WithLabelValues(track).Inc()
}
