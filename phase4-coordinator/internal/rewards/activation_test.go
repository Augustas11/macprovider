package rewards

import (
	"context"
	"errors"
	"testing"
)

func TestRunEmissionTickRequiresBootstrapFlag(t *testing.T) {
	runner := &Runner{cfg: Config{
		Enabled:              true,
		BootstrapTickEnabled: false,
	}.DefaultsApplied()}
	if err := runner.runEmissionTick(context.Background()); err != nil {
		t.Fatalf("runEmissionTick with bootstrap disabled: %v", err)
	}
}

func TestRunEmissionTickRejectsEpochBootstrapCoexistence(t *testing.T) {
	runner := &Runner{cfg: Config{
		Enabled:              true,
		BootstrapTickEnabled: true,
		EpochEnabled:         true,
	}.DefaultsApplied()}
	err := runner.runEmissionTick(context.Background())
	if !errors.Is(err, ErrEpochPolicyEngineUnavailable) {
		t.Fatalf("runEmissionTick error = %v, want %v", err, ErrEpochPolicyEngineUnavailable)
	}
}
