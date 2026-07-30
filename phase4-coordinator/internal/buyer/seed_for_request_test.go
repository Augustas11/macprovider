package buyer

import "testing"

// Pins SPEC-004 §7 / BUILD prompt Phase D log contract:
// random_seed MUST be derivable from request_id + daily key, and
// MUST rotate when the daily key changes. Audit replay within the
// same UTC day reproduces the same seed; the next day's seed is
// different so cross-day selection patterns are not leaked.

func TestSeedForRequest_SameKeyAndRequestIsStable(t *testing.T) {
	t.Parallel()
	a := seedForRequestWithKey("req-abc", "2026-06-30")
	b := seedForRequestWithKey("req-abc", "2026-06-30")
	if a != b {
		t.Fatalf("same request+key MUST be stable: a=%d b=%d", a, b)
	}
}

func TestSeedForRequest_DifferentDailyKeyChangesSeed(t *testing.T) {
	t.Parallel()
	monday := seedForRequestWithKey("req-abc", "2026-06-30")
	tuesday := seedForRequestWithKey("req-abc", "2026-07-01")
	if monday == tuesday {
		t.Fatalf("daily-key rotation MUST change seed for same request_id: %d == %d", monday, tuesday)
	}
}

func TestSeedForRequest_DifferentRequestIdChangesSeed(t *testing.T) {
	t.Parallel()
	a := seedForRequestWithKey("req-A", "2026-06-30")
	b := seedForRequestWithKey("req-B", "2026-06-30")
	if a == b {
		t.Fatalf("different request_id MUST change seed: %d == %d", a, b)
	}
}

func TestSeedForRequest_DailyKeyDelimiterPreventsCollisions(t *testing.T) {
	// Without the "|" delimiter between dailyKey and requestID,
	// (key="2026-06-30", req="req") would hash identically to
	// (key="2026-06-3", req="0req"). The delimiter guards against
	// that collision class.
	t.Parallel()
	a := seedForRequestWithKey("req", "2026-06-30")
	b := seedForRequestWithKey("0req", "2026-06-3")
	if a == b {
		t.Fatalf("delimiter should prevent (key+req) concat collision: %d == %d", a, b)
	}
}
