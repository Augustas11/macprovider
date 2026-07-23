// Package canarycorr implements the pure SPEC-031 FR-CAN23 multi-provider
// correlation-epoch state machine for the coordinator canary path.
//
// Scope of this Partial (#584 remainder):
//   - staged results over a fixed pre-sweep snapshot
//   - shared challenge fingerprint + bank-generation fencing
//   - strict-majority (>N/2, ≥2) suspicion → ephemeral discard + operator alert
//   - non-correlated commit of staged results subject to a last-provider floor
//   - zero durable "containment" state from a correlated-majority verdict
//
// This package is intentionally free of pool.Registry / ws.Server coupling so
// the Sybil-safety properties can be hermetically proven. Wiring into the live
// canary dispatch loop is a follow-up Partial; production Pearl canary remains
// disabled under exc-canary-disabled-enable-gate until the full #584 re-enable
// bar (physical baselines, emergency-disable drill, go/no-go) is paid.
package canarycorr

import (
	"fmt"
	"strings"
	"time"
)

// FailureClass is the coarse canary failure taxonomy used for epoch decisions.
// Transport / status / soft-deadline classes never authorize a correlation
// suspicion by themselves (SPEC-031 FR-CAN23 / FR-CAN3 neutrality).
type FailureClass string

const (
	ClassPass          FailureClass = "pass"
	ClassNonceMismatch FailureClass = "nonce_mismatch"
	ClassIncomplete    FailureClass = "incomplete"
	// ClassRelayHard is a hard transport death that is committed per-provider
	// but never forms a shared-fingerprint correlation suspicion alone.
	ClassRelayHard FailureClass = "relay_error_hard"
	// ClassRelayStatus / ClassRelaySoft are neutral for correlation (do not
	// contribute to the strict-majority fingerprint failure count).
	ClassRelayStatus FailureClass = "relay_error_status"
	ClassRelaySoft   FailureClass = "relay_error_soft"
	// ClassNeutral covers coordinator-attributable / skip-neutral outcomes
	// (e.g. undersized max_tokens truncation once coordinator-verifiable).
	ClassNeutral FailureClass = "neutral"
)

// CorrectnessFailure reports whether class is a multi-provider correctness
// failure eligible for shared-fingerprint correlation (nonce_mismatch or
// incomplete). Other classes never open a correlation suspicion.
func CorrectnessFailure(class FailureClass) bool {
	switch class {
	case ClassNonceMismatch, ClassIncomplete:
		return true
	default:
		return false
	}
}

// StagedResult is one provider's outcome inside a correlation epoch. Results
// are unapplied until Resolve; suspicion discards them entirely.
type StagedResult struct {
	ProviderID  string
	AssignedID  string
	ModelID     string
	Fingerprint string
	// BankGeneration is the challenge-bank generation the probe was
	// dispatched under. A mismatch with the epoch's generation fences the
	// result as discarded (not committed, not suspicious).
	BankGeneration uint64
	Class          FailureClass
	// BuyerServing is the FR-CAN22/23 capacity predicate for this provider at
	// snapshot time (caller-supplied; request-aware or observed-serving when
	// available). The epoch never invents capacity.
	BuyerServing bool
	// ObservedServing is true when the coordinator has recent buyer-relay
	// success (or an equivalent request-aware eligibility proof) for this
	// peer. Peers that are BuyerServing but not ObservedServing MUST NOT lift
	// the last-provider floor when committing sanctions (FR-CAN23 residual).
	ObservedServing bool
}

// OperatorAlert is the FR-CAN29a fire-and-forget signal emitted on suspicion.
// It never itself mutates provider or config state.
type OperatorAlert struct {
	ModelID        string
	Fingerprint    string
	BankGeneration uint64
	SnapshotN      int
	FailingCount   int
	Discarded      bool
	Reason         string
}

// CommitAction is one per-provider effect after a non-suspicious resolve.
type CommitAction struct {
	ProviderID string
	AssignedID string
	// ApplyFailure is true when this staged failure should update the
	// ordinary FR-CAN11 counter / sanction path. Passes and neutral classes
	// have ApplyFailure=false (passes reset counters via ApplyPass).
	ApplyFailure bool
	ApplyPass    bool
	Class        FailureClass
	// FloorHeld is true when a would-be sanction was suppressed because the
	// provider is the sole observed-serving capacity for its model.
	FloorHeld bool
}

// Outcome is the atomic result of Resolve.
type Outcome struct {
	// Suspicious is true when a strict majority of the snapshot failed the
	// shared fingerprint. All staged results are discarded; no CommitActions.
	Suspicious bool
	// Discarded is true when the epoch's results must not be applied (suspicion
	// or generation fence). Always true when Suspicious is true.
	Discarded bool
	// Alert is non-nil only on suspicion (FR-CAN29a).
	Alert *OperatorAlert
	// Commits are the per-provider apply plan when the epoch is not discarded.
	// Empty when Discarded.
	Commits []CommitAction
	// Reason is a short machine-readable resolve reason.
	Reason string
}

// Epoch is one fixed pre-sweep correlation epoch for a single model.
// Construct via NewEpoch; Stage results; Resolve once.
type Epoch struct {
	ModelID        string
	Fingerprint    string
	BankGeneration uint64
	// Snapshot is the fixed pre-sweep provider ID set (denominator N).
	// Membership is frozen at construction; staging a provider outside the
	// snapshot is rejected.
	Snapshot map[string]struct{}
	// observedServing records which snapshot members offer FR-CAN23 residual
	// peer capacity (recent buyer-relay success). Populated from Stage;
	// missing providers default to not observed-serving.
	observedServing map[string]bool
	staged          map[string]StagedResult
	resolved        bool
}

// NewEpoch freezes a pre-sweep snapshot for modelID. snapshotProviderIDs must
// contain at least one provider; N≥2 is required for multi-provider correlation
// but N=1 is allowed so callers can stage sole-provider results without a
// separate code path (sole-provider epochs never go suspicious — strict
// majority requires ≥2 failures and >N/2).
func NewEpoch(modelID, fingerprint string, bankGeneration uint64, snapshotProviderIDs []string) (*Epoch, error) {
	modelID = strings.TrimSpace(modelID)
	fingerprint = strings.TrimSpace(fingerprint)
	if modelID == "" {
		return nil, fmt.Errorf("canarycorr: model_id is required")
	}
	if fingerprint == "" {
		return nil, fmt.Errorf("canarycorr: fingerprint is required")
	}
	if len(snapshotProviderIDs) == 0 {
		return nil, fmt.Errorf("canarycorr: snapshot must be non-empty")
	}
	snap := make(map[string]struct{}, len(snapshotProviderIDs))
	for _, id := range snapshotProviderIDs {
		id = strings.TrimSpace(id)
		if id == "" {
			return nil, fmt.Errorf("canarycorr: snapshot provider_id must be non-empty")
		}
		if _, dup := snap[id]; dup {
			return nil, fmt.Errorf("canarycorr: duplicate snapshot provider_id %q", id)
		}
		snap[id] = struct{}{}
	}
	return &Epoch{
		ModelID:         modelID,
		Fingerprint:     fingerprint,
		BankGeneration:  bankGeneration,
		Snapshot:        snap,
		observedServing: make(map[string]bool, len(snap)),
		staged:          make(map[string]StagedResult, len(snap)),
	}, nil
}

// N returns the frozen snapshot denominator.
func (e *Epoch) N() int {
	if e == nil {
		return 0
	}
	return len(e.Snapshot)
}

// Stage records one provider result. Returns an error if the epoch is already
// resolved, the provider is outside the snapshot, the fingerprint/generation
// does not match, or the provider already staged.
//
// Staging never mutates provider counters or sanctions.
func (e *Epoch) Stage(r StagedResult) error {
	if e == nil {
		return fmt.Errorf("canarycorr: nil epoch")
	}
	if e.resolved {
		return fmt.Errorf("canarycorr: epoch already resolved")
	}
	r.ProviderID = strings.TrimSpace(r.ProviderID)
	r.AssignedID = strings.TrimSpace(r.AssignedID)
	r.ModelID = strings.TrimSpace(r.ModelID)
	r.Fingerprint = strings.TrimSpace(r.Fingerprint)
	if r.ProviderID == "" {
		return fmt.Errorf("canarycorr: staged provider_id is required")
	}
	if _, ok := e.Snapshot[r.ProviderID]; !ok {
		return fmt.Errorf("canarycorr: provider %q not in pre-sweep snapshot", r.ProviderID)
	}
	if _, dup := e.staged[r.ProviderID]; dup {
		return fmt.Errorf("canarycorr: provider %q already staged", r.ProviderID)
	}
	if r.ModelID != "" && !strings.EqualFold(r.ModelID, e.ModelID) {
		return fmt.Errorf("canarycorr: staged model_id %q mismatches epoch %q", r.ModelID, e.ModelID)
	}
	if r.Fingerprint != e.Fingerprint {
		return fmt.Errorf("canarycorr: staged fingerprint mismatches epoch")
	}
	if r.BankGeneration != e.BankGeneration {
		return fmt.Errorf("canarycorr: staged bank generation %d mismatches epoch %d", r.BankGeneration, e.BankGeneration)
	}
	if r.Class == "" {
		return fmt.Errorf("canarycorr: staged class is required")
	}
	e.staged[r.ProviderID] = r
	e.observedServing[r.ProviderID] = r.ObservedServing
	return nil
}

// StagedCount returns how many snapshot members have staged results.
func (e *Epoch) StagedCount() int {
	if e == nil {
		return 0
	}
	return len(e.staged)
}

// ResolveOptions controls incomplete-epoch behavior.
//
// Wiring Partial contract (SPEC-031 AC-F5 / FR-CAN12):
//   - Prefer RequireComplete=true so first responders are not committed before
//     the full snapshot stages (or the FR-CAN12 window elapses).
//   - AllowIncomplete is for hermetic unit tests and for the explicit
//     window-elapsed path once the caller has waited out the bound.
type ResolveOptions struct {
	// AllowIncomplete permits resolve when StagedCount < N. Default false
	// (fail closed). Set true only after the FR-CAN12 observation window
	// elapses or in tests that intentionally exercise partial snapshots.
	AllowIncomplete bool
}

// Resolve freezes the epoch under opts.
//
// Fingerprint / bank-generation mismatches are rejected at Stage (not as a
// Resolve discard outcome). Callers MUST NOT apply a result that failed Stage;
// no commit plan is produced for that provider.
//
// FloorHeld wiring contract (FR-CAN22 parity):
//   - FloorHeld=true means "suppress the tier sanction branch".
//   - ApplyFailure remains true so the ordinary failure counter still accrues
//     (matches RecordCanaryResult: increment CanaryFailCount, then return
//     CanaryTripFloorHeld without degrading/banning).
//   - Callers map FloorHeld commits to CanaryTripFloorHeld telemetry and MUST
//     still record the failure (counter accrual), never skip the fail path.
//
// Resolve is not concurrency-safe; the wiring Partial must serialize
// Stage/Resolve per epoch. A second call returns an error.
func (e *Epoch) Resolve(now time.Time, opts ResolveOptions) (Outcome, error) {
	if e == nil {
		return Outcome{}, fmt.Errorf("canarycorr: nil epoch")
	}
	if e.resolved {
		return Outcome{}, fmt.Errorf("canarycorr: epoch already resolved")
	}
	_ = now // reserved for window/age fencing helpers at the call site
	if !opts.AllowIncomplete && e.StagedCount() < e.N() {
		return Outcome{}, fmt.Errorf("canarycorr: incomplete epoch (%d/%d staged); wait for full snapshot or FR-CAN12 window then AllowIncomplete", e.StagedCount(), e.N())
	}
	e.resolved = true

	n := e.N()
	failing := 0
	for _, r := range e.staged {
		if CorrectnessFailure(r.Class) {
			failing++
		}
	}

	// Strict majority of the snapshot denominator, and at least two failures.
	// A single failure at N=2 is not a majority; two failures at N=2 is.
	// Exact half (e.g. N=4, failing=2) is NOT suspicion (needs failing*2 > N).
	// One malicious provider alone can never open suspicion.
	if failing >= 2 && failing*2 > n {
		alert := &OperatorAlert{
			ModelID:        e.ModelID,
			Fingerprint:    e.Fingerprint,
			BankGeneration: e.BankGeneration,
			SnapshotN:      n,
			FailingCount:   failing,
			Discarded:      true,
			Reason:         "correlated_majority_shared_fingerprint",
		}
		return Outcome{
			Suspicious: true,
			Discarded:  true,
			Alert:      alert,
			Reason:     "discard_on_suspicion",
		}, nil
	}

	// Non-suspicious: commit staged results atomically under the last-provider
	// floor. Peer capacity that may lift the floor requires ObservedServing so
	// a peer that never actually serves cannot authorize removing the target
	// (FR-CAN23 residual). Target eligibility for the floor remains
	// BuyerServing (FR-CAN22): a cold sole buyer-serving provider with no
	// recent relay stamp must still be spared.
	commits := make([]CommitAction, 0, len(e.staged))
	type pending struct {
		r            StagedResult
		applyFailure bool
		applyPass    bool
	}
	pendings := make([]pending, 0, len(e.staged))
	for _, r := range e.staged {
		switch {
		case r.Class == ClassPass:
			pendings = append(pendings, pending{r: r, applyPass: true})
		case CorrectnessFailure(r.Class) || r.Class == ClassRelayHard:
			pendings = append(pendings, pending{r: r, applyFailure: true})
		default:
			// Neutral / soft / status: no counter update.
			pendings = append(pendings, pending{r: r})
		}
	}

	// Peer capacity that may lift the floor: ObservedServing only, excluding
	// peers that are themselves committing a failure in this epoch. Floor-held
	// targets stay in the pool, so they do not need a second capacity pass.
	failingIDs := make(map[string]bool)
	for _, p := range pendings {
		if p.applyFailure {
			failingIDs[p.r.ProviderID] = true
		}
	}

	for _, p := range pendings {
		action := CommitAction{
			ProviderID:   p.r.ProviderID,
			AssignedID:   p.r.AssignedID,
			ApplyFailure: p.applyFailure,
			ApplyPass:    p.applyPass,
			Class:        p.r.Class,
		}
		if p.applyFailure && p.r.BuyerServing && observedPeerCapacity(e, p.r.ProviderID, failingIDs) == 0 {
			// Sole buyer-serving target with no remaining observed-serving peers.
			// ApplyFailure stays true (counter accrual); FloorHeld suppresses sanction.
			action.FloorHeld = true
		}
		commits = append(commits, action)
	}

	return Outcome{
		Suspicious: false,
		Discarded:  false,
		Commits:    commits,
		Reason:     "commit_staged",
	}, nil
}

// observedPeerCapacity counts snapshot peers other than exclude that still
// offer ObservedServing evidence and are not committing a failure this epoch.
// Unstaged peers never invent capacity.
func observedPeerCapacity(e *Epoch, exclude string, failingIDs map[string]bool) int {
	count := 0
	for id := range e.Snapshot {
		if id == exclude {
			continue
		}
		if failingIDs[id] {
			continue
		}
		if e.observedServing[id] {
			count++
		}
	}
	return count
}

// ObservedServingWindow is the recommended default age for
// coordinator-observed buyer-relay success evidence used by floor residual
// peers. Callers may choose a tighter bound; this constant documents the
// Partial's design default (one canary interval class, 90s).
const ObservedServingWindow = 90 * time.Second

// HasRecentObservedServing reports whether lastSuccess is non-zero and within
// window of now. A zero lastSuccess never counts.
func HasRecentObservedServing(lastSuccess, now time.Time, window time.Duration) bool {
	if lastSuccess.IsZero() || window <= 0 {
		return false
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	delta := now.Sub(lastSuccess)
	return delta >= 0 && delta <= window
}
