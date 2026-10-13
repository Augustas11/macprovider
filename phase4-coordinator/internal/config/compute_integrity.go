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
	BaseIntervalMinutes       int  `yaml:"base_interval_minutes"`
	EscalationIntervalMinutes int  `yaml:"escalation_interval_minutes"`
	MaxInFlight               int  `yaml:"max_in_flight"`
	MaxPerHour                int  `yaml:"max_per_hour"`
	RecoveryCooldownMinutes   int  `yaml:"recovery_cooldown_minutes"`
	ScoreDeadlineSeconds      int  `yaml:"score_deadline_seconds"`
	SweepIntervalSeconds      int  `yaml:"sweep_interval_seconds"`
}

// DefaultComputeIntegrityConfig returns the SPEC-036 FR-20/FR-23 defaults.
func DefaultComputeIntegrityConfig() ComputeIntegrityConfig {
	return ComputeIntegrityConfig{Scoring: ComputeIntegrityScoringConfig{
		Enabled:                   true,
		BaseIntervalMinutes:       360,
		EscalationIntervalMinutes: 10,
		MaxInFlight:               4,
		MaxPerHour:                240,
		RecoveryCooldownMinutes:   1440,
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
		{"base_interval_minutes", s.BaseIntervalMinutes, 1, 7 * 24 * 60},
		{"escalation_interval_minutes", s.EscalationIntervalMinutes, 1, 24 * 60},
		{"max_in_flight", s.MaxInFlight, 1, 256},
		{"max_per_hour", s.MaxPerHour, 1, 100_000},
		{"recovery_cooldown_minutes", s.RecoveryCooldownMinutes, 1, 30 * 24 * 60},
		{"score_deadline_seconds", s.ScoreDeadlineSeconds, 5, 600},
		{"sweep_interval_seconds", s.SweepIntervalSeconds, 1, 3600},
	}
	for _, b := range bounds {
		if b.value < b.min || b.value > b.max {
			return fmt.Errorf("compute_integrity.scoring.%s must be in [%d, %d]", b.name, b.min, b.max)
		}
	}
	if s.EscalationIntervalMinutes > s.BaseIntervalMinutes {
		return fmt.Errorf("compute_integrity.scoring.escalation_interval_minutes must not exceed base_interval_minutes")
	}
	return nil
}
