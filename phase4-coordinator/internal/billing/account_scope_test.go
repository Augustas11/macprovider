package billing

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestVerifiedModelSettlementModeDefaultsObserve(t *testing.T) {
	cases := []struct {
		name string
		mode string
		want string
	}{
		{name: "blank", want: RouteSnapshotModeObserve},
		{name: "observe", mode: RouteSnapshotModeObserve, want: RouteSnapshotModeObserve},
		{name: "enforce", mode: RouteSnapshotModeEnforce, want: RouteSnapshotModeEnforce},
		{name: "unknown", mode: "shadow", want: RouteSnapshotModeObserve},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := VerifiedModelSettlementMode(config.SettlementConfig{VerifiedModelSettlementMode: tc.mode})
			if got != tc.want {
				t.Fatalf("VerifiedModelSettlementMode(%q)=%q want %q", tc.mode, got, tc.want)
			}
		})
	}
}
