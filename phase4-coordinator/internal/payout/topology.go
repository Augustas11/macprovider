package payout

import (
	"fmt"
	"runtime"
)

// PayoutRuntimeTopology captures the SPEC-016 §3.3 normative
// requirement that, when the execution pipeline is enabled, the
// §3.3 registration handler and the §4.3 runner share ONE process
// (same clock, same `*sql.DB` pool). SPEC §3.3 (v0.1.26+):
//
//	"When payout.enabled = true, the registration handler and the
//	runner MUST be co-resident in the same coordinator process…
//	When payout.enabled = false (registration-only), no runner
//	exists; the co-residency assertion is vacuously satisfied."
//
// Registration-only mode (#954) mounts the §3.3 handlers with
// ExecutionEnabled=false so providers can register wallets while
// the runner/signer/RPC/lease stay idle.
type PayoutRuntimeTopology struct {
	// HandlerEnabled is true when the §3.3 handler is mounted on
	// the listener (full pipeline OR registration-only).
	HandlerEnabled bool

	// RunnerCoResident is true when the runner goroutine is
	// launched in the same process as the handler. Required only
	// when ExecutionEnabled is true.
	RunnerCoResident bool

	// ExecutionEnabled is true when payout.enabled=true — the
	// full pipeline (runner, signer, RPC, lease, admin routes).
	// False for registration-only and fully-disabled postures.
	ExecutionEnabled bool

	// HotWalletAddressPinned is the canonical EIP-55 form of the
	// operator's hot wallet, captured at process start. Used to
	// detect a future config-reload bug that would mutate the
	// security namespace post-startup.
	HotWalletAddressPinned string

	// LinuxRequired is the §6.3 / §4.3 OS gate. Required when the
	// execution pipeline is enabled; registration-only leaves it
	// false so macOS dev hosts can serve §3.3.
	LinuxRequired bool
}

// AssertPayoutRuntimeTopology validates the topology invariants
// AT STARTUP, before the §3.3 handler accepts traffic. The
// function returns an error on any invariant violation; main.go
// MUST treat the error as terminal and refuse to start the
// listener.
func AssertPayoutRuntimeTopology(topo PayoutRuntimeTopology) error {
	if !topo.HandlerEnabled {
		// Handler disabled — topology is trivially satisfied.
		return nil
	}
	if topo.HotWalletAddressPinned == "" {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: handler enabled but hot_wallet_address pin is empty — SPEC §3.3 / §6.5 invariant violated")
	}
	if _, err := CanonicalizeEIP55(topo.HotWalletAddressPinned); err != nil {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: hot_wallet_address pin is not a valid EIP-55 address: %w", err)
	}
	if topo.LinuxRequired && runtime.GOOS != "linux" {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: SPEC §6.3 requires runtime.GOOS=linux (got %q)", runtime.GOOS)
	}
	// Cross-constrain flags so a future caller cannot silently
	// drop §6.3 Linux or §3.3 co-residency by omitting a field.
	if topo.ExecutionEnabled && !topo.RunnerCoResident {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: ExecutionEnabled=true but RunnerCoResident=false — split-process deployment rejected (SPEC §3.3)")
	}
	if topo.ExecutionEnabled && !topo.LinuxRequired {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: ExecutionEnabled=true requires LinuxRequired=true (SPEC §6.3)")
	}
	if topo.RunnerCoResident && !topo.ExecutionEnabled {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: RunnerCoResident=true but ExecutionEnabled=false — runner present in a registration-only posture")
	}
	return nil
}
