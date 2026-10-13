package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestStakeAllowanceDefaultsAreOnWithZeroBudget(t *testing.T) {
	cfg := Default()
	if err := cfg.validateStakeAllowance(); err != nil {
		t.Fatalf("default stake_allowance invalid: %v", err)
	}
	if cfg.StakeAllowance.DailyBudgetCredits != 0 || cfg.StakeAllowance.UnlockCooldownHours != 168 || cfg.StakeAllowance.MinStakeAgeHours != 24 {
		t.Fatalf("defaults %+v", cfg.StakeAllowance)
	}
}

func TestStakeAllowanceValidation(t *testing.T) {
	for name, mutate := range map[string]func(*StakeAllowanceConfig){
		"negative budget":             func(s *StakeAllowanceConfig) { s.DailyBudgetCredits = -1 },
		"budget without rate":         func(s *StakeAllowanceConfig) { s.DailyBudgetCredits = 10; s.PerAccountDailyCapCredits = 5 },
		"budget without cap":          func(s *StakeAllowanceConfig) { s.DailyBudgetCredits = 10; s.CreditsPerMALIBU = 5 },
		"cooldown too short":          func(s *StakeAllowanceConfig) { s.UnlockCooldownHours = 23 },
		"min age zero":                func(s *StakeAllowanceConfig) { s.MinStakeAgeHours = 0 },
		"reservation max age too big": func(s *StakeAllowanceConfig) { s.ReservationMaxAgeSeconds = 86401 },
		"refresh interval too short":  func(s *StakeAllowanceConfig) { s.RefreshCheckIntervalSeconds = 1 },
	} {
		t.Run(name, func(t *testing.T) {
			cfg := Default()
			mutate(&cfg.StakeAllowance)
			if err := cfg.validateStakeAllowance(); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestCoordinatorYAMLExamplesCarryConservativeStakeAllowance(t *testing.T) {
	for _, rel := range []string{"../../coordinator.yaml.example", "../../dist/coordinator.yaml.example"} {
		b, err := os.ReadFile(filepath.Clean(rel))
		if err != nil {
			t.Fatal(err)
		}
		var doc struct {
			StakeAllowance StakeAllowanceConfig `yaml:"stake_allowance"`
		}
		if err := yaml.Unmarshal(b, &doc); err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		cfg := Default()
		cfg.StakeAllowance = doc.StakeAllowance
		if err := cfg.validateStakeAllowance(); err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		s := doc.StakeAllowance
		if s.DailyBudgetCredits != 5_000_000 || s.CreditsPerMALIBU != 1000 || s.PerAccountDailyCapCredits != 250_000 {
			t.Fatalf("%s: stake_allowance example %+v", rel, s)
		}
		text := string(b)
		start := strings.Index(text, "# SPEC-050 MALIBU stake allowance")
		end := strings.Index(text, "reservation_max_age_seconds")
		if start < 0 || end < start {
			t.Fatalf("%s: stake_allowance block not found", rel)
		}
		block := strings.ToLower(text[start:end])
		for _, banned := range []string{"apy", "apr", "yield", "interest", "dividend"} {
			if strings.Contains(block, banned) {
				t.Fatalf("%s: stake_allowance block uses %q", rel, banned)
			}
		}
	}
}
