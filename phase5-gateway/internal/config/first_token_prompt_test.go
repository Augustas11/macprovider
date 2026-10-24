package config

import (
	"testing"
	"time"
)

func TestFirstTokenTimeoutForPrompt(t *testing.T) {
	cfg := Default()
	cfg.Timeouts.FirstTokenSeconds = 300
	cfg.Timeouts.StreamCeilingMaxSeconds = 3600
	if cfg.Timeouts.FirstTokenPrefillTokensPerSecond != 100 {
		t.Fatalf("default prefill rate=%d want 100", cfg.Timeouts.FirstTokenPrefillTokensPerSecond)
	}
	for _, tc := range []struct {
		prompt int64
		want   time.Duration
	}{
		{0, 300 * time.Second},
		{-5, 300 * time.Second},
		{1, 301 * time.Second},
		{80_000, 1100 * time.Second},
		{131_072, 1611 * time.Second},
		{1 << 40, 3600 * time.Second},
	} {
		if got := cfg.FirstTokenTimeoutForPrompt(tc.prompt); got != tc.want {
			t.Fatalf("prompt=%d budget=%s want %s", tc.prompt, got, tc.want)
		}
	}
	cfg.Timeouts.FirstTokenPrefillTokensPerSecond = 0
	if got := cfg.FirstTokenTimeoutForPrompt(131_072); got != 300*time.Second {
		t.Fatalf("disabled scaling budget=%s want the floor", got)
	}
	cfg.Timeouts.FirstTokenPrefillTokensPerSecond = -1
	if err := cfg.Validate(); err == nil {
		t.Fatal("negative prefill rate validated")
	}
}
