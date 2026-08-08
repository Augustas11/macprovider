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

func TestAssertPayoutRuntimeTopology_HappyPath_FullExecution(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		ExecutionEnabled:       true,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          true,
	})
	if runtime.GOOS != "linux" {
		if err == nil {
			t.Fatalf("full execution posture must reject on %s", runtime.GOOS)
		}
		return
	}
	if err != nil {
		t.Fatalf("full execution posture should pass on linux: %v", err)
	}
}

func TestAssertPayoutRuntimeTopology_ExecutionWithoutRunnerRejected(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       false,
		ExecutionEnabled:       true,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          true,
	})
	if err == nil {
		t.Fatal("expected error when ExecutionEnabled but RunnerCoResident=false")
	}
}

func TestAssertPayoutRuntimeTopology_ExecutionWithoutLinuxRequiredRejected(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		ExecutionEnabled:       true,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          false,
	})
	if err == nil || !strings.Contains(err.Error(), "LinuxRequired") {
		t.Fatalf("expected LinuxRequired cross-check error, got %v", err)
	}
}

func TestAssertPayoutRuntimeTopology_RunnerWithoutExecutionRejected(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		ExecutionEnabled:       false,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          false,
	})
	if err == nil || !strings.Contains(err.Error(), "registration-only") {
		t.Fatalf("expected runner-in-registration-only error, got %v", err)
	}
}

func TestAssertPayoutRuntimeTopology_RegistrationOnlyOK(t *testing.T) {
	if err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       false,
		ExecutionEnabled:       false,
		HotWalletAddressPinned: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		LinuxRequired:          false,
	}); err != nil {
		t.Fatalf("registration-only posture should pass: %v", err)
	}
}

func TestAssertPayoutRuntimeTopology_LinuxRequiredGate(t *testing.T) {
	err := AssertPayoutRuntimeTopology(PayoutRuntimeTopology{
		HandlerEnabled:         true,
		RunnerCoResident:       true,
		ExecutionEnabled:       true,
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
