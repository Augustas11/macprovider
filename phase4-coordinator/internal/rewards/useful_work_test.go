package rewards

import "testing"

func TestUsefulWorkRewardFormulaAndExternalRef(t *testing.T) {
	runner := &Runner{cfg: Config{UsefulWorkMALIBUPer1KCredits: 2.5}.DefaultsApplied()}
	if got := runner.usefulWorkMALIBU(2400); got != 6 {
		t.Fatalf("usefulWorkMALIBU(2400) = %v, want 6", got)
	}
	if got := runner.usefulWorkMALIBU(0); got != 0 {
		t.Fatalf("usefulWorkMALIBU(0) = %v, want 0", got)
	}

	ref := usefulWorkExternalRef(usefulWorkRewardRow{
		RequestID:  "req-1",
		AttemptN:   2,
		ProviderID: "provider-a",
	})
	if ref != "spec022:req-1:2:provider-a" {
		t.Fatalf("external ref = %q", ref)
	}
}
