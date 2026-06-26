package payout

import (
	"runtime"
	"strings"
	"testing"
)

func TestAssertPayoutRuntimeTopology_HandlerDisabledIsTriviallyOK(t *testing.T) {
	if err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled: false,
	}); err != nil {
		t.Fatalf("disabled handler should pass: %v", err)
	}
}

func TestAssertPayoutRuntimeTopology_EmptyHotWalletPinRejected(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		HotWalletAddressPinned: "",
	})
	if err == nil {
		t.Fatal("expected error when HotWalletAddressPinned is empty")
	}
	if !strings.Contains(err.Error(), "hot_wallet_address pin is empty") {
		t.Errorf("error %q does not mention empty pin", err.Error())
	}
}

func TestAssertPayoutRuntimeTopology_InvalidHotWalletPinRejected(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		HotWalletAddressPinned: "not-an-address",
	})
	if err == nil {
		t.Fatal("expected error when HotWalletAddressPinned is malformed")
	}
}

func TestAssertPayoutRuntimeTopology_HappyPath_Step2Posture(t *testing.T) {
	// Step 2 posture (post-tightening): HandlerEnabled=true,
	// RunnerCoResident=true, LinuxRequired toggleable.
	if err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          false,
	}); err != nil {
		t.Fatalf("Step 2 happy-path posture should pass: %v", err)
	}
}

func TestAssertPayoutRuntimeTopology_HandlerWithoutRunnerRejected(t *testing.T) {
	// Step 2 tightening: handler enabled but runner missing is
	// rejected.
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       false,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
	})
	if err == nil {
		t.Fatal("expected error when HandlerEnabled but RunnerCoResident=false")
	}
}

// FULL-r1 [full-arch:r1-1] MEDIUM closure: setupPayout now passes
// LinuxRequired=true when payout.enabled=true. Verify the gate:
// on non-linux the topology MUST reject; on linux it MUST accept.
// Same test body covers both — the assertion branches on runtime.GOOS.
func TestAssertPayoutRuntimeTopology_LinuxRequiredGate(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          true,
	})
	if runtime.GOOS == "linux" {
		if err != nil {
			t.Fatalf("LinuxRequired=true on linux should pass: %v", err)
		}
		return
	}
	if err == nil {
		t.Fatalf("LinuxRequired=true on %s should reject (SPEC §6.3)", runtime.GOOS)
	}
	if !strings.Contains(err.Error(), "SPEC §6.3") || !strings.Contains(err.Error(), runtime.GOOS) {
		t.Errorf("error %q must cite SPEC §6.3 and runtime.GOOS=%s", err.Error(), runtime.GOOS)
	}
}
