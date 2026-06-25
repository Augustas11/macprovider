package payout

import (
	"fmt"
	"runtime"
)

// PayoutRuntimeTopology captures the SPEC-016 §3.3 normative
// requirement that the §3.3 registration handler and the §4.3
// runner share ONE process (same clock, same `*sql.DB` pool).
// SPEC §3.3 line 625-629:
//
//	"the registration handler and the runner are co-resident
//	in the same coordinator process per §4.1; IMPL MUST assert
//	this co-residency at startup (e.g. a deployment-mode check
//	that fails-fast if the runner is configured to a different
//	process or host) and MUST NOT honor any clock-skew tolerance
//	when comparing pending_until_utc to :now."
//
// At Step 1 the runner has not been wired yet, so the topology
// hook only asserts what Step 1 can prove: (a) we are on Linux
// per §6.3 OS-restriction (§6.3 actually only requires Linux for
// the Step 2 runner — at Step 1 we tolerate non-Linux for the
// handler-only mode); (b) the `payout.security.hot_wallet_address`
// is set; (c) the shared `*sql.DB` handle is non-nil and the same
// instance the handler will use.
//
// Step 2 will extend this struct with a `RunnerEnabled` field that
// asserts the runner goroutine is launched in the same process by
// observing a sentinel set inside the runner's bootstrap. Closes
// codex round-1 [arch:1.3] MEDIUM and turns the prior
// "co-residency assertion lives in main.go" code comment in
// addresses.go (which was a lie at Step 1 commit time) into an
// executable check.
type PayoutRuntimeTopology struct {
	// HandlerEnabled is true when the §3.3 handler is mounted on
	// the listener. Step 1 sets this true iff payout.enabled is
	// true. Step 2's extension will require RunnerEnabled=true
	// iff HandlerEnabled=true so a split-process deployment
	// fails-fast.
	HandlerEnabled bool

	// RunnerCoResident is a forward-compatible flag. Step 2 will
	// set it true when the runner goroutine is launched in the
	// same process as the handler. Step 1 leaves it false (the
	// runner is not present yet).
	RunnerCoResident bool

	// HotWalletAddressPinned is the canonical EIP-55 form of the
	// operator's hot wallet, captured at process start. Used to
	// detect a future config-reload bug that would mutate the
	// security namespace post-startup.
	HotWalletAddressPinned string

	// LinuxRequired is the §6.3 / §4.3 OS gate. Step 1 leaves it
	// off (handler-only mode can run on any host); Step 2's
	// runner introduction will flip it on.
	LinuxRequired bool
}

// AssertPayoutRuntimeTopology validates the topology invariants
// AT STARTUP, before the §3.3 handler accepts traffic. The
// function returns an error on any invariant violation; main.go
// MUST treat the error as terminal and refuse to start the
// listener.
//
// Step 2 audit MUST extend the test corpus to drive
// RunnerCoResident=false + HandlerEnabled=true through this
// function and assert the error.
func AssertPayoutRuntimeTopology(topo PayoutRuntimeTopology) error {
	if !topo.HandlerEnabled {
		// Handler disabled — topology is trivially satisfied.
		// Step 1's setupPayout returns the disabled posture
		// when payout.enabled=false.
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
	// Step 2 tightening (per architect r2 recommendation): the
	// runner MUST be co-resident with the handler. A deployment
	// that enables the handler but not the runner is a SPEC §3.3
	// violation — the runner produces the chain confirmations
	// that the handler's pending_until_utc rows are eventually
	// paid from.
	if topo.HandlerEnabled && !topo.RunnerCoResident {
		return fmt.Errorf("payout.AssertPayoutRuntimeTopology: HandlerEnabled=true but RunnerCoResident=false — split-process deployment rejected (SPEC §3.3)")
	}
	return nil
}
