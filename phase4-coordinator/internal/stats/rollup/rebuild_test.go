package rollup

import (
	"bytes"
	"strings"
	"testing"

	"github.com/rs/zerolog"
)

// TestEmitDriftIfExceeds — round-2 CODE r2 MEDIUM 1 fix:
// verifies the SPEC §9.4 v0.1 pinned formula
// `(rebuild - incremental) / max(rebuild, 1) > threshold`,
// including divide-by-zero (rebuild=0) and sub-unit (rebuild<1)
// edge cases where the `max(rebuild, 1)` denominator suppresses
// noise.
func TestEmitDriftIfExceeds(t *testing.T) {
	cases := []struct {
		name        string
		incremental float64
		rebuild     float64
		threshold   float64
		wantFire    bool
	}{
		// Equal values — no drift.
		{"equal_zero", 0, 0, 0.005, false},
		{"equal_thousand", 1000, 1000, 0.005, false},

		// Divide-by-zero guard: rebuild=0, incremental=5;
		// denom clamps to max(0, 1) = 1; delta=5; ratio=5;
		// fires for any reasonable threshold.
		{"zero_rebuild_nonzero_incremental", 5, 0, 0.005, true},

		// Sub-unit rebuild: incremental=$0.49, rebuild=$0.50.
		// Old formula: (0.50-0.49)/0.50 = 2% — over threshold.
		// New formula: delta=0.01, denom=max(0.5, 1)=1, ratio=0.01.
		// Above 0.005 → still fires (0.01 > 0.005), but below 1%.
		{"subunit_above_threshold", 0.49, 0.50, 0.005, true},
		// Sub-cent delta below threshold.
		{"subcent_below_threshold", 0.495, 0.500, 0.01, false},

		// Dollar magnitude examples (the leaderboard's usual range).
		// $100 rebuild, $99 incremental → delta=1, denom=100, ratio=0.01 → fires at 0.005.
		{"dollar_above_threshold", 99, 100, 0.005, true},
		// $100 rebuild, $99.50 incremental → delta=0.5, denom=100, ratio=0.005 → NOT > threshold.
		{"dollar_at_threshold_exclusive", 99.5, 100, 0.005, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			logger := zerolog.New(&buf)
			emitDriftIfExceeds("all", "earnings", "p_test", tc.incremental, tc.rebuild, tc.threshold, logger)
			fired := strings.Contains(buf.String(), "stats_rollup_drift_detected")
			if fired != tc.wantFire {
				t.Errorf("incremental=%v rebuild=%v threshold=%v: fired=%v want=%v\nlog=%s",
					tc.incremental, tc.rebuild, tc.threshold, fired, tc.wantFire, buf.String())
			}
		})
	}
}

// TestEmitDriftPayloadRedaction — the drift log MUST include
// numerical drift values and a provider_id sample, but MUST NOT
// include raw token-like or DSN-like strings. The provider_id
// itself is a pseudonymizable identifier per [[provider-auth-...]]
// and is fine; this test pins the shape.
func TestEmitDriftPayloadRedaction(t *testing.T) {
	var buf bytes.Buffer
	logger := zerolog.New(&buf)
	emitDriftIfExceeds("30d", "tokens", "provider-abc-123", 100, 200, 0.005, logger)
	s := buf.String()
	if !strings.Contains(s, "stats_rollup_drift_detected") {
		t.Fatalf("event not emitted: %s", s)
	}
	if !strings.Contains(s, "provider-abc-123") {
		t.Errorf("provider_id_sample missing: %s", s)
	}
	if !strings.Contains(s, "delta_ratio") {
		t.Errorf("delta_ratio missing: %s", s)
	}
	// Should NOT contain any DSN-shaped substring.
	for _, leak := range []string{"postgres://", "password", "host=", "token_hash"} {
		if strings.Contains(s, leak) {
			t.Errorf("drift log leaked %q: %s", leak, s)
		}
	}
}

// TestClassifyPanic — round-2 SECURITY r2 MED-2 fix: panic
// classification is TYPE-NAME ONLY; no payload, even when the
// panic value is an error with a message containing
// secret-shaped strings.
func TestClassifyPanic(t *testing.T) {
	cases := []struct {
		name  string
		panic any
	}{
		{"plain_string", "kaboom"},
		{"int", 42},
		{"error_with_dsn_substring", driverError("postgres://user:hunter2@host/db panicked")},
		{"error_with_token_substring", driverError("token_hash=abcdef1234 went bad")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := classifyPanic(tc.panic)
			for _, leak := range []string{"postgres://", "hunter2", "token_hash", "abcdef1234"} {
				if strings.Contains(s, leak) {
					t.Errorf("classifyPanic leaked %q in %q (test panic: %v)", leak, s, tc.panic)
				}
			}
		})
	}
}

// driverError is a tiny error type used in TestClassifyPanic to
// simulate a panic whose payload's Error() string contains
// secret-shaped text. The package's classifyPanic MUST NOT
// surface that text.
type driverError string

func (d driverError) Error() string { return string(d) }
