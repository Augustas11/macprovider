package buyer

import "testing"

func TestRequestLogCacheRecoveryFieldsPreservesExplicitStickyHitZero(t *testing.T) {
	prompt, cached := int64(10), int64(0)
	got, reason := requestLogCacheRecoveryFields(&cached, &prompt, &forwardState{stickyResult: "hit"}, 0)
	if reason != "" {
		t.Fatalf("reason=%q want empty", reason)
	}
	if got == nil || *got != 0 {
		t.Fatalf("cached=%v want explicit zero", got)
	}
}

func TestRequestLogCacheRecoveryFieldsDropsNonHitZero(t *testing.T) {
	prompt, cached := int64(10), int64(0)
	got, reason := requestLogCacheRecoveryFields(&cached, &prompt, &forwardState{stickyResult: "miss"}, 0)
	if reason != "" {
		t.Fatalf("reason=%q want empty", reason)
	}
	if got != nil {
		t.Fatalf("cached=%v want nil", got)
	}
}
