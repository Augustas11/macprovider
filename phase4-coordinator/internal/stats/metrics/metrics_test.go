package metrics

// SPEC-017 v0.1.8 Step 4.C label-hygiene test (SECURITY M5 +
// Step 4.C SECURITY lane category A).
//
// Drives a synthetic load against the 5 metrics, then walks the
// Prometheus gathered MetricFamily set and asserts:
//   - no label VALUE matches the 43-char base64url body shape
//   - no label VALUE contains the literal `mpk_`, `token_hash`,
//     or `Authorization`
//   - the partner_key_id label only takes positive-integer
//     decimal strings (no prefix, no label-text)
//   - tier ∈ {public, partner}
//   - endpoint ∈ {overview, leaderboard, provider, health, routability, models, providers}
//   - component ∈ the locked §9.5 component set

import (
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	bodyShape = regexp.MustCompile(`[A-Za-z0-9_-]{43}`)
	allowTier = map[string]bool{"public": true, "partner": true}
	allowEP   = map[string]bool{"overview": true, "leaderboard": true, "provider": true, "health": true, "routability": true, "models": true, "providers": true}
	allowComp = map[string]bool{
		"overview": true, "timeseries_rpm": true, "timeseries_tpm": true,
		"leaderboard_24h": true, "leaderboard_7d": true,
		"leaderboard_30d": true, "leaderboard_all": true,
		"routability": true,
	}
	allowIdlePrewarmEvent = map[string]bool{
		"idle_prewarm_fired":                     true,
		"idle_prewarm_completed":                 true,
		"idle_prewarm_skipped":                   true,
		"idle_prewarm_cancelled_by_real_request": true,
		"idle_prewarm_failed":                    true,
	}
	allowIdlePrewarmReason = map[string]bool{
		"none": true, "disabled": true, "busy": true, "not_idle_yet": true,
		"thermal_pressure": true, "on_battery": true, "model_not_loaded": true,
	}
	allowCredentialBootstrapOutcome = map[string]bool{
		"minted": true, "recovered": true, "rejected_v1": true,
		"rejected_identity": true, "rejected_used": true, "rejected_expired": true,
		"rejected_rate": true, "rejected_outstanding": true, "store_error": true,
	}
	allowMoneySQLiteComponentLabel = map[string]bool{
		"billing_hot_path": true, "request_log_identity": true,
		"billing_reload_config": true, "route_snapshot": true,
		"wal_checkpoint": true,
	}
	allowMoneySQLiteOutcomeLabel   = map[string]bool{"success": true, "error": true}
	allowMoneySQLiteOperationLabel = map[string]bool{
		"route_snapshot_insert": true,
	}
	allowMoneySQLitePageClassLabel = map[string]bool{
		"busy": true, "log": true, "checkpointed": true,
	}
	allowReferralOutcome = map[string]bool{
		"disabled": true, "busy": true, "rate_limited": true,
		"unavailable": true, "bad_request": true, "missing": true,
		"expired": true, "revoked": true, "exhausted": true,
		"conflict": true, "invalid": true, "valid": true,
	}
	// Round-1 ARCH M1 / CODE M1 fix: also scan for an
	// Origin-fragment to prove no attacker-controlled string
	// from the request `Origin` header lands in a label value.
	denyTokens = []string{"mpk_", "token_hash", "Authorization", "evil.malibu.tech"}
)

func TestLabelHygiene(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)

	// Drive a representative cross-section of label combinations.
	m.RequestTotal.WithLabelValues("overview", "200", "public").Inc()
	m.RequestTotal.WithLabelValues("leaderboard", "200", "partner").Inc()
	m.RequestTotal.WithLabelValues("provider", "200", "partner").Inc()
	m.RequestTotal.WithLabelValues("leaderboard", "429", "public").Inc()
	m.RequestTotal.WithLabelValues("health", "503", "public").Inc()
	m.PartnerKeyRequestTotal.WithLabelValues("17").Inc()
	m.PartnerKeyRequestTotal.WithLabelValues("9001").Inc()
	m.RollupLagSeconds.WithLabelValues("overview").Set(1.5)
	m.RollupLagSeconds.WithLabelValues("leaderboard_24h").Set(0)
	m.RollupErrorsTotal.WithLabelValues("timeseries_rpm").Inc()
	m.RollupPanicTotal.WithLabelValues("leaderboard_30d").Inc()
	m.RateLimitExceededTotal.WithLabelValues("public", "overview").Inc()
	m.RateLimitExceededTotal.WithLabelValues("partner", "leaderboard").Inc()
	m.IncRegisterRateLimitHit("ip")
	m.IncRegisterRateLimitHit("asn")
	m.IncRegisterRateLimitHit("raw-attacker-value")
	m.IncRegisterSource("app")
	m.IncRegisterSource("cli")
	m.IncRegisterSource("portal")
	m.IncRegisterSource("raw-attacker-value")
	m.IncRegisterHardwareProfileError()
	m.IncIdlePrewarmEvent("idle_prewarm_fired", "")
	m.IncIdlePrewarmEvent("idle_prewarm_skipped", "not_idle_yet")
	m.IncIdlePrewarmEvent("raw-attacker-value", "not_idle_yet")
	m.IncIdlePrewarmEvent("idle_prewarm_skipped", "raw-attacker-value")
	for outcome := range allowCredentialBootstrapOutcome {
		m.IncCredentialBootstrap(outcome)
	}
	m.IncCredentialBootstrap("raw-attacker-value")
	for outcome := range allowReferralOutcome {
		m.IncReferralEvent("validate", outcome)
	}
	m.IncReferralEvent("validate", "raw-attacker-value")
	m.IncReferralEvent("raw-attacker-value", "valid")
	m.ObserveSQLiteConnectionWait("billing_hot_path", "success", time.Millisecond)
	m.ObserveSQLiteConnectionWait("raw-attacker-value", "success", time.Millisecond)
	m.ObserveSQLiteConnectionWait("billing_hot_path", "raw-attacker-value", time.Millisecond)
	m.ObserveSQLiteTransactionDuration("request_log_identity", "error", time.Millisecond)
	m.ObserveSQLiteWriteDuration("route_snapshot", "route_snapshot_insert", "success", time.Millisecond)
	m.ObserveSQLiteWriteDuration("route_snapshot", "raw-attacker-value", "success", time.Millisecond)
	m.ObserveSQLiteWALCheckpoint("wal_checkpoint", "log", "success", 7)
	m.ObserveSQLiteWALCheckpoint("wal_checkpoint", "raw-attacker-value", "success", 7)

	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}

	for _, mf := range families {
		for _, mt := range mf.GetMetric() {
			for _, lp := range mt.GetLabel() {
				name := lp.GetName()
				val := lp.GetValue()

				if bodyShape.MatchString(val) {
					t.Errorf("metric %s label %s value %q matches 43-char body shape (potential token leak)",
						mf.GetName(), name, val)
				}
				for _, deny := range denyTokens {
					if containsCaseFold(val, deny) {
						t.Errorf("metric %s label %s value %q contains forbidden substring %q",
							mf.GetName(), name, val, deny)
					}
				}
				switch name {
				case "tier":
					if !allowTier[val] {
						t.Errorf("metric %s tier=%q not in allowed set", mf.GetName(), val)
					}
				case "endpoint":
					if !allowEP[val] {
						t.Errorf("metric %s endpoint=%q not in allowed set", mf.GetName(), val)
					}
				case "component":
					if !allowComp[val] && !allowMoneySQLiteComponentLabel[val] {
						t.Errorf("metric %s component=%q not in allowed set", mf.GetName(), val)
					}
				case "partner_key_id":
					// Must parse as a non-negative integer.
					n, err := strconv.ParseInt(val, 10, 64)
					if err != nil || n < 0 {
						t.Errorf("metric %s partner_key_id=%q is not a non-negative integer", mf.GetName(), val)
					}
				case "status":
					// Decimal HTTP status code.
					n, err := strconv.Atoi(val)
					if err != nil || n < 100 || n > 599 {
						t.Errorf("metric %s status=%q is not a valid HTTP status code", mf.GetName(), val)
					}
				case "scope":
					if val != "ip" && val != "asn" {
						t.Errorf("metric %s scope=%q not in allowed set", mf.GetName(), val)
					}
				case "track":
					if val != "app" && val != "cli" && val != "portal" {
						t.Errorf("metric %s track=%q not in allowed set", mf.GetName(), val)
					}
				case "event":
					if mf.GetName() == "referral_event_total" {
						if val != "validate" {
							t.Errorf("metric %s event=%q not in referral allowed set", mf.GetName(), val)
						}
					} else if !allowIdlePrewarmEvent[val] {
						t.Errorf("metric %s event=%q not in allowed set", mf.GetName(), val)
					}
				case "reason":
					if !allowIdlePrewarmReason[val] {
						t.Errorf("metric %s reason=%q not in allowed set", mf.GetName(), val)
					}
				case "outcome":
					if mf.GetName() == "referral_event_total" {
						if !allowReferralOutcome[val] {
							t.Errorf("metric %s outcome=%q not in referral allowed set", mf.GetName(), val)
						}
					} else if strings.HasPrefix(mf.GetName(), "money_sqlite_") {
						if !allowMoneySQLiteOutcomeLabel[val] {
							t.Errorf("metric %s outcome=%q not in money SQLite allowed set", mf.GetName(), val)
						}
					} else if !allowCredentialBootstrapOutcome[val] {
						t.Errorf("metric %s outcome=%q not in allowed set", mf.GetName(), val)
					}
				case "operation":
					if !allowMoneySQLiteOperationLabel[val] {
						t.Errorf("metric %s operation=%q not in allowed set", mf.GetName(), val)
					}
				case "page_class":
					if !allowMoneySQLitePageClassLabel[val] {
						t.Errorf("metric %s page_class=%q not in allowed set", mf.GetName(), val)
					}
				}
			}
		}
	}
}

func containsCaseFold(haystack, needle string) bool {
	// Cheap case-insensitive substring; the hygiene check doesn't
	// need the full Unicode `strings.EqualFold` machinery.
	if len(needle) == 0 {
		return false
	}
	h, n := []byte(haystack), []byte(needle)
	for i := 0; i+len(n) <= len(h); i++ {
		match := true
		for j := 0; j < len(n); j++ {
			a, b := h[i+j], n[j]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			if a != b {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
