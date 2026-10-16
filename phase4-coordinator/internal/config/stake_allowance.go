package config

import "fmt"

// StakeAllowanceConfig is the SPEC-050 MALIBU stake allowance. The feature is
// always on; DailyBudgetCredits sets its size, and 0 grants nothing. Credits
// are SPEC-005 credits (1 credit = 1 micro-USD). Values apply at coordinator
// start.
type StakeAllowanceConfig struct {
	DailyBudgetCredits          int64 `yaml:"daily_budget_credits"`
	CreditsPerMALIBU            int64 `yaml:"credits_per_malibu"`
	PerAccountDailyCapCredits   int64 `yaml:"per_account_daily_cap_credits"`
	MinStakeAgeHours            int   `yaml:"min_stake_age_hours"`
	UnlockCooldownHours         int   `yaml:"unlock_cooldown_hours"`
	RefreshCheckIntervalSeconds int   `yaml:"refresh_check_interval_seconds"`
}

// DefaultStakeAllowanceConfig is the SPEC-050 §4 default: on, zero budget.
func DefaultStakeAllowanceConfig() StakeAllowanceConfig {
	return StakeAllowanceConfig{
		MinStakeAgeHours:            24,
		UnlockCooldownHours:         168,
		RefreshCheckIntervalSeconds: 60,
	}
}

func (c Config) validateStakeAllowance() error {
	s := c.StakeAllowance
	if s.DailyBudgetCredits < 0 || s.CreditsPerMALIBU < 0 || s.PerAccountDailyCapCredits < 0 {
		return fmt.Errorf("stake_allowance: daily_budget_credits, credits_per_malibu and per_account_daily_cap_credits must be >= 0")
	}
	if s.DailyBudgetCredits > 0 && (s.CreditsPerMALIBU <= 0 || s.PerAccountDailyCapCredits <= 0) {
		return fmt.Errorf("stake_allowance: daily_budget_credits > 0 requires positive credits_per_malibu and per_account_daily_cap_credits")
	}
	if s.MinStakeAgeHours < 1 || s.MinStakeAgeHours > 720 {
		return fmt.Errorf("stake_allowance.min_stake_age_hours must be in [1, 720]")
	}
	if s.UnlockCooldownHours < 24 || s.UnlockCooldownHours > 2160 {
		return fmt.Errorf("stake_allowance.unlock_cooldown_hours must be in [24, 2160]")
	}
	if s.RefreshCheckIntervalSeconds < 10 || s.RefreshCheckIntervalSeconds > 3600 {
		return fmt.Errorf("stake_allowance.refresh_check_interval_seconds must be in [10, 3600]")
	}
	return nil
}
