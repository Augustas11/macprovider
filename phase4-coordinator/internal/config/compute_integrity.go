package config

import "fmt"

// ComputeIntegrityConfig is the `compute_integrity` namespace.
type ComputeIntegrityConfig struct {
	Scoring ComputeIntegrityScoringConfig `yaml:"scoring"`
}

// ComputeIntegrityScoringConfig controls SPEC-036 §5A cross-provider
// scoring. It is on by default. Enabled=false is the kill switch: it stops
// scheduling new verification requests and leaves states and holds as they
// are (FR-19).
type ComputeIntegrityScoringConfig struct {
	Enabled                   bool `yaml:"enabled"`
	BaseIntervalSeconds       int  `yaml:"base_interval_seconds"`
	EscalationIntervalSeconds int  `yaml:"escalation_interval_seconds"`
	MaxInFlight               int  `yaml:"max_in_flight"`
	MaxPerHour                int  `yaml:"max_per_hour"`
	RecoveryCooldownSeconds   int  `yaml:"recovery_cooldown_seconds"`
	ScoreDeadlineSeconds      int  `yaml:"score_deadline_seconds"`
	SweepIntervalSeconds      int  `yaml:"sweep_interval_seconds"`
	// CorpusPath names a private, coordinator-only prompt corpus (SPEC-036
	// FR-20). Empty uses the checked-in public corpus, which is a fallback:
	// a provider can read it.
	CorpusPath string `yaml:"corpus_path"`
}

// DefaultComputeIntegrityConfig returns the SPEC-036 FR-20/FR-23 defaults.
func DefaultComputeIntegrityConfig() ComputeIntegrityConfig {
	return ComputeIntegrityConfig{Scoring: ComputeIntegrityScoringConfig{
		Enabled:                   true,
		BaseIntervalSeconds:       6 * 3600,
		EscalationIntervalSeconds: 600,
		MaxInFlight:               4,
		MaxPerHour:                240,
		RecoveryCooldownSeconds:   24 * 3600,
		ScoreDeadlineSeconds:      60,
		SweepIntervalSeconds:      30,
	}}
}

func (c ComputeIntegrityConfig) validate() error {
	s := c.Scoring
	bounds := []struct {
		name     string
		value    int
		min, max int
	}{
		{"base_interval_seconds", s.BaseIntervalSeconds, 1, 7 * 24 * 3600},
		{"escalation_interval_seconds", s.EscalationIntervalSeconds, 1, 24 * 3600},
		{"max_in_flight", s.MaxInFlight, 1, 256},
		{"max_per_hour", s.MaxPerHour, 1, 100_000},
		{"recovery_cooldown_seconds", s.RecoveryCooldownSeconds, 1, 30 * 24 * 3600},
		{"score_deadline_seconds", s.ScoreDeadlineSeconds, 5, 600},
		{"sweep_interval_seconds", s.SweepIntervalSeconds, 1, 3600},
	}
	for _, b := range bounds {
		if b.value < b.min || b.value > b.max {
			return fmt.Errorf("compute_integrity.scoring.%s must be in [%d, %d]", b.name, b.min, b.max)
		}
	}
	if s.EscalationIntervalSeconds > s.BaseIntervalSeconds {
		return fmt.Errorf("compute_integrity.scoring.escalation_interval_seconds must not exceed base_interval_seconds")
	}
	return nil
}
