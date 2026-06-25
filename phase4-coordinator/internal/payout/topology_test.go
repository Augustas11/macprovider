package payout

import (
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

func TestAssertPayoutRuntimeTopology_HappyPath_Step1Posture(t *testing.T) {
	// Step 1 posture: HandlerEnabled=true, RunnerCoResident=false,
	// LinuxRequired=false. This is the expected state at Step 1
	// commit; Step 2 will tighten it.
	if err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       false,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          false,
	}); err != nil {
		t.Fatalf("Step 1 happy-path posture should pass: %v", err)
	}
}
