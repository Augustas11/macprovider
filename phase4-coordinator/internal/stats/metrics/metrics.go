// Package metrics declares the SPEC-017 v0.1.8 §8 Prometheus
// metric surface plus SPEC-026 register counters. Wired by Step 4.C
// per BUILD §2:
//
//	stats_request_total{endpoint,status,tier}                — Counter
//	stats_partner_key_request_total{partner_key_id}           — Counter
//	stats_rollup_lag_seconds{component}                        — Gauge
//	stats_rollup_errors_total{component}                       — Counter
//	stats_rate_limit_exceeded_total{tier,endpoint}             — Counter
//	stats_idle_prewarm_event_total{event,reason}                — Counter
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
//     "provider" / "health" (mirrors the Step 3 mux verbs).
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
//   - `provider_register_hardware_profile_errors_total` has no labels.
//
//   - `stats_idle_prewarm_event_total{event,reason}` uses the
//     idle-prewarm protocol allowlist. Non-skip events use
//     reason="none" so the label set stays closed and low-cardinality.
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
	RequestTotal                 *prometheus.CounterVec
	PartnerKeyRequestTotal       *prometheus.CounterVec
	RollupLagSeconds             *prometheus.GaugeVec
	RollupErrorsTotal            *prometheus.CounterVec
	RollupPanicTotal             *prometheus.CounterVec
	RateLimitExceededTotal       *prometheus.CounterVec
	RegisterRateLimitHits        *prometheus.CounterVec
	RegisterSource               *prometheus.CounterVec
	RegisterHardwareErrors       prometheus.Counter
	IdlePrewarmEventTotal        *prometheus.CounterVec
	ModelHashMismatchTotal       prometheus.Counter
	CredentialBootstrapTotal     *prometheus.CounterVec
	ReferralEventTotal           *prometheus.CounterVec
	ProviderConnectionEventTotal *prometheus.CounterVec
	// CapacityOverClaimTotal is the issue-#764 over-claim tripwire. It is
	// PERMANENT by construction: a prometheus counter never decreases and is
	// never reset for the process lifetime, and the coordinator increments it
	// on every offending frame rather than once per provider.
	CapacityOverClaimTotal *prometheus.CounterVec
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
		RollupPanicTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "stats_rollup_panic_total",
				Help: "Count of recovered rollup panics per component.",
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
		RegisterHardwareErrors: f.NewCounter(
			prometheus.CounterOpts{
				Name: "provider_register_hardware_profile_errors_total",
				Help: "Count of accepted provider register requests whose best-effort hardware profile persistence failed.",
			},
		),
		IdlePrewarmEventTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "stats_idle_prewarm_event_total",
				Help: "Count of accepted provider idle-prewarm telemetry events by protocol event and closed-set reason.",
			},
			[]string{"event", "reason"},
		),
		ModelHashMismatchTotal: f.NewCounter(
			prometheus.CounterOpts{
				Name: "model_hash_mismatch_total",
				Help: "Count of provider hash status transitions to hash_mismatch (Proof of Weights W1 observability).",
			},
		),
		CapacityOverClaimTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "provider_capacity_over_claim_total",
				Help: "Permanent count of provider-reported capacity claims above pool.max_concurrency_ceiling, by ingest phase.",
			},
			[]string{"phase"},
		),
		CredentialBootstrapTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "credential_bootstrap_total",
				Help: "Count of v2 receipt-key credential bootstrap outcomes using a closed-set outcome label.",
			},
			[]string{"outcome"},
		),
		ReferralEventTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "referral_event_total",
				Help: "Count of public referral validation outcomes using closed-set event and outcome labels.",
			},
			[]string{"event", "outcome"},
		),
		ProviderConnectionEventTotal: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "provider_connection_event_total",
				Help: "Count of durable provider connection lifecycle events by closed-set kind, outcome, and failure_reason.",
			},
			[]string{"kind", "outcome", "failure_reason"},
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

func (m *Metrics) IncRegisterHardwareProfileError() {
	if m == nil || m.RegisterHardwareErrors == nil {
		return
	}
	m.RegisterHardwareErrors.Inc()
}

func (m *Metrics) IncIdlePrewarmEvent(event, reason string) {
	if m == nil || m.IdlePrewarmEventTotal == nil {
		return
	}
	switch event {
	case "idle_prewarm_fired",
		"idle_prewarm_completed",
		"idle_prewarm_cancelled_by_real_request",
		"idle_prewarm_failed":
		if reason != "" {
			return
		}
		reason = "none"
	case "idle_prewarm_skipped":
		switch reason {
		case "disabled", "busy", "not_idle_yet", "thermal_pressure", "on_battery", "model_not_loaded":
		default:
			return
		}
	default:
		return
	}
	m.IdlePrewarmEventTotal.WithLabelValues(event, reason).Inc()
}

func (m *Metrics) IncModelHashMismatch() {
	if m == nil || m.ModelHashMismatchTotal == nil {
		return
	}
	m.ModelHashMismatchTotal.Inc()
}

// IncCapacityOverClaim records one provider capacity claim above the operator
// ceiling. phase is a closed set ("hello" | "heartbeat"); no
// provider-controlled string is ever used as a label.
func (m *Metrics) IncCapacityOverClaim(phase string) {
	if m == nil || m.CapacityOverClaimTotal == nil {
		return
	}
	m.CapacityOverClaimTotal.WithLabelValues(phase).Inc()
}

func (m *Metrics) IncCredentialBootstrap(outcome string) {
	if m == nil || m.CredentialBootstrapTotal == nil {
		return
	}
	switch outcome {
	case "minted", "recovered", "rejected_v1", "rejected_identity", "rejected_used",
		"rejected_expired", "rejected_rate", "rejected_outstanding", "store_error":
	default:
		return
	}
	m.CredentialBootstrapTotal.WithLabelValues(outcome).Inc()
}

func (m *Metrics) IncReferralEvent(event, outcome string) {
	if m == nil || m.ReferralEventTotal == nil || event != "validate" {
		return
	}
	switch outcome {
	case "disabled", "busy", "rate_limited", "unavailable", "bad_request",
		"missing", "expired", "revoked", "exhausted", "conflict", "invalid", "valid":
	default:
		return
	}
	m.ReferralEventTotal.WithLabelValues(event, outcome).Inc()
}

func (m *Metrics) IncProviderConnectionEvent(kind, outcome, failureReason string) {
	if m == nil || m.ProviderConnectionEventTotal == nil {
		return
	}
	switch kind {
	case "upgrade_failed", "auth_rejected", "auth_accepted", "disconnect", "warmup_failed", "heartbeat_stale":
	default:
		return
	}
	switch outcome {
	case "success", "failure":
	default:
		return
	}
	switch failureReason {
	case "", "none":
		failureReason = "none"
	case "invalid_token", "invalid_auth_request", "no_common_aead_suite", "tier2_attestation_failed",
		"version_unsupported", "warmup_failed", "heartbeat_stale", "provider_websocket_disconnected",
		"upgrade_failed", "unrecognized_auth_message", "pool_full", "other":
	default:
		failureReason = "other"
	}
	m.ProviderConnectionEventTotal.WithLabelValues(kind, outcome, failureReason).Inc()
}
