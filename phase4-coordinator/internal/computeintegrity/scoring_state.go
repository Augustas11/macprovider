package computeintegrity

// SPEC-036 FR-23 verification decision state machine. Pure: it takes scored
// outcomes and clock ticks and returns the transition, including the SPEC-022
// R-16 hold action the caller must apply.

import (
	"time"
)

// VerificationState is the FR-23 state of a (provider_id, model_id) key.
type VerificationState string

const (
	VerificationUnverified VerificationState = "unverified"
	VerificationPassing    VerificationState = "passing"
	VerificationSuspect    VerificationState = "suspect"
	VerificationFailed     VerificationState = "failed"
	VerificationRecovering VerificationState = "recovering"
)

// Known reports membership of the closed FR-23 state set.
func (s VerificationState) Known() bool {
	switch s {
	case VerificationUnverified, VerificationPassing, VerificationSuspect, VerificationFailed, VerificationRecovering:
		return true
	}
	return false
}

// RoutingSuspended reports whether the state removes the key from routing.
func (s VerificationState) RoutingSuspended() bool { return s == VerificationFailed }

// Escalating reports whether the key is probed at the escalation cadence and
// double scored.
func (s VerificationState) Escalating() bool {
	return s == VerificationSuspect || s == VerificationRecovering
}

// AcceptsHonestSamples reports whether in-band measurements of this key may
// enter the FR-22 honest-pair window.
func (s VerificationState) AcceptsHonestSamples() bool {
	return s == VerificationUnverified || s == VerificationPassing
}

// StateReason is the closed FR-25 reason set.
type StateReason string

const (
	ReasonNone                   StateReason = ""
	ReasonInBandStreak           StateReason = "in_band_streak"
	ReasonOutOfBandTop1          StateReason = "out_of_band_top1"
	ReasonOutOfBandLogprob       StateReason = "out_of_band_logprob"
	ReasonConfirmedFailure       StateReason = "confirmed_failure"
	ReasonRecoveryPassed         StateReason = "recovery_passed"
	ReasonEscalationPassed       StateReason = "escalation_passed"
	ReasonEscalationInconclusive StateReason = "escalation_inconclusive"
	ReasonOperatorClear          StateReason = "operator_clear"
	ReasonCooldownElapsed        StateReason = "cooldown_elapsed"
)

// FR-23 thresholds.
const (
	passStreakToVerify       = 3
	escalationWindow         = 5
	escalationOutsToFail     = 3
	escalationInsToPass      = 3
	escalationMaxMeasured    = 15
	recoveryStreakToPass     = 5
	minDistinctScorerOps     = 2
	DefaultRecoveryCooldown  = 24 * time.Hour
	escalationHistoryRetains = escalationMaxMeasured
)

// HoldKind distinguishes SPEC-022 R-16 holds.
type HoldKind string

const (
	HoldKindFailure  HoldKind = "failure"
	HoldKindRecovery HoldKind = "recovery"
)

// HoldActionKind is what the caller must do to the SPEC-022 R-16 holds.
type HoldActionKind string

const (
	HoldActionNone HoldActionKind = ""
	// HoldActionOpenFailure opens a held failure hold for [Start, End].
	HoldActionOpenFailure HoldActionKind = "open_failure"
	// HoldActionOpenRecovery opens a held recovery hold from Start, end open.
	HoldActionOpenRecovery HoldActionKind = "open_recovery"
	// HoldActionReleaseRecovery closes the open recovery hold at End and
	// releases it.
	HoldActionReleaseRecovery HoldActionKind = "release_recovery"
	// HoldActionCloseRecovery closes the open recovery hold at End and keeps
	// it held.
	HoldActionCloseRecovery HoldActionKind = "close_recovery"
)

// HoldAction is a SPEC-022 R-16 change produced by a transition.
type HoldAction struct {
	Kind  HoldActionKind
	Start time.Time
	End   time.Time
}

// Transition is one FR-23 state change.
type Transition struct {
	From   VerificationState
	To     VerificationState
	Reason StateReason
	At     time.Time
	Hold   HoldAction
}

// Outcome is one scored verification request: every scorer that answered
// was in band (InBand), every one was out (OutOfBand), or they split.
type Outcome struct {
	InBand          bool
	OutOfBand       bool
	OutReason       OutReason
	ScorerOperators []string
	At              time.Time
}

// EscalationEntry is one escalation (or recovery) measurement.
type EscalationEntry struct {
	Out             bool     `json:"out"`
	In              bool     `json:"in"`
	ScorerOperators []string `json:"scorer_operators,omitempty"`
}

// KeyState is the persisted FR-23 state of one verification key.
type KeyState struct {
	ProviderID       string            `json:"provider_id"`
	ModelID          string            `json:"model_id"`
	State            VerificationState `json:"state"`
	Reason           StateReason       `json:"reason,omitempty"`
	Since            time.Time         `json:"since"`
	FirstMeasuredAt  time.Time         `json:"first_measured_at,omitempty"`
	LastInBandAt     time.Time         `json:"last_in_band_at,omitempty"`
	WindowStart      time.Time         `json:"window_start,omitempty"`
	InStreak         int               `json:"in_streak"`
	StreakScorerOps  []string          `json:"streak_scorer_ops,omitempty"`
	Escalations      []EscalationEntry `json:"escalations,omitempty"`
	EscalationCount  int               `json:"escalation_count"`
	FailedAt         time.Time         `json:"failed_at,omitempty"`
	CooldownUntil    time.Time         `json:"cooldown_until,omitempty"`
	InBandTotal      int               `json:"in_band_total"`
	OutOfBandTotal   int               `json:"out_of_band_total"`
	RecoveryCooldown time.Duration     `json:"-"`
}

// NewKeyState returns an unverified key.
func NewKeyState(providerID, modelID string, now time.Time) *KeyState {
	return &KeyState{ProviderID: providerID, ModelID: modelID, State: VerificationUnverified, Since: now}
}

func (k *KeyState) cooldown() time.Duration {
	if k.RecoveryCooldown > 0 {
		return k.RecoveryCooldown
	}
	return DefaultRecoveryCooldown
}

func (k *KeyState) transition(to VerificationState, reason StateReason, at time.Time, hold HoldAction) *Transition {
	t := &Transition{From: k.State, To: to, Reason: reason, At: at, Hold: hold}
	k.State = to
	k.Reason = reason
	k.Since = at
	return t
}

func (k *KeyState) resetEscalation() {
	k.Escalations = nil
	k.EscalationCount = 0
	k.InStreak = 0
	k.StreakScorerOps = nil
}

// Apply records one outcome. Outcomes for a failed key are ignored: it is not
// routed and not probed until its cooldown elapses (Tick).
func (k *KeyState) Apply(o Outcome) *Transition {
	if k.FirstMeasuredAt.IsZero() {
		k.FirstMeasuredAt = o.At
	}
	if o.InBand {
		k.InBandTotal++
	}
	if o.OutOfBand {
		k.OutOfBandTotal++
	}
	switch k.State {
	case VerificationUnverified, VerificationPassing:
		return k.applyBase(o)
	case VerificationSuspect:
		return k.applySuspect(o)
	case VerificationRecovering:
		return k.applyRecovering(o)
	}
	return nil
}

func (k *KeyState) applyBase(o Outcome) *Transition {
	switch {
	case o.InBand:
		k.InStreak++
		k.LastInBandAt = o.At
		if k.State == VerificationUnverified && k.InStreak >= passStreakToVerify {
			return k.transition(VerificationPassing, ReasonInBandStreak, o.At, HoldAction{})
		}
	case o.OutOfBand:
		start := k.LastInBandAt
		if start.IsZero() {
			start = k.FirstMeasuredAt
		}
		k.WindowStart = start
		k.resetEscalation()
		return k.transition(VerificationSuspect, StateReason(o.OutReason), o.At, HoldAction{})
	}
	return nil
}

func (k *KeyState) recordEscalation(o Outcome) {
	k.Escalations = append(k.Escalations, EscalationEntry{Out: o.OutOfBand, In: o.InBand, ScorerOperators: append([]string(nil), o.ScorerOperators...)})
	if len(k.Escalations) > escalationHistoryRetains {
		k.Escalations = k.Escalations[len(k.Escalations)-escalationHistoryRetains:]
	}
	k.EscalationCount++
}

// confirmedFailure applies the FR-23 rule: at least 3 of the last 5 escalation
// measurements out, scored by at least 2 distinct scorer operators.
func (k *KeyState) confirmedFailure() bool {
	recent := k.Escalations
	if len(recent) > escalationWindow {
		recent = recent[len(recent)-escalationWindow:]
	}
	outs := 0
	ops := map[string]struct{}{}
	for _, e := range recent {
		if !e.Out {
			continue
		}
		outs++
		for _, op := range e.ScorerOperators {
			ops[op] = struct{}{}
		}
	}
	return outs >= escalationOutsToFail && len(ops) >= minDistinctScorerOps
}

func (k *KeyState) trailingIns() int {
	n := 0
	for i := len(k.Escalations) - 1; i >= 0 && k.Escalations[i].In; i-- {
		n++
	}
	return n
}

func (k *KeyState) applySuspect(o Outcome) *Transition {
	if !o.InBand && !o.OutOfBand && len(o.ScorerOperators) == 0 {
		return nil
	}
	k.recordEscalation(o)
	if o.InBand {
		k.LastInBandAt = o.At
	}
	switch {
	case k.confirmedFailure():
		k.FailedAt = o.At
		k.CooldownUntil = o.At.Add(k.cooldown())
		start := k.WindowStart
		k.resetEscalation()
		return k.transition(VerificationFailed, ReasonConfirmedFailure, o.At, HoldAction{Kind: HoldActionOpenFailure, Start: start, End: o.At})
	case k.trailingIns() >= escalationInsToPass:
		k.resetEscalation()
		k.WindowStart = time.Time{}
		return k.transition(VerificationPassing, ReasonEscalationPassed, o.At, HoldAction{})
	case k.EscalationCount >= escalationMaxMeasured:
		k.resetEscalation()
		k.WindowStart = time.Time{}
		return k.transition(VerificationPassing, ReasonEscalationInconclusive, o.At, HoldAction{})
	}
	return nil
}

func (k *KeyState) applyRecovering(o Outcome) *Transition {
	if !o.InBand && !o.OutOfBand && len(o.ScorerOperators) == 0 {
		return nil
	}
	k.recordEscalation(o)
	switch {
	case o.InBand:
		k.InStreak++
		k.LastInBandAt = o.At
		k.StreakScorerOps = mergeOperators(k.StreakScorerOps, o.ScorerOperators)
	default:
		k.InStreak = 0
		k.StreakScorerOps = nil
	}
	if k.confirmedFailure() {
		k.FailedAt = o.At
		k.CooldownUntil = o.At.Add(k.cooldown())
		k.resetEscalation()
		return k.transition(VerificationFailed, ReasonConfirmedFailure, o.At, HoldAction{Kind: HoldActionCloseRecovery, End: o.At})
	}
	if k.InStreak >= recoveryStreakToPass && len(k.StreakScorerOps) >= minDistinctScorerOps {
		k.resetEscalation()
		k.WindowStart = time.Time{}
		return k.transition(VerificationPassing, ReasonRecoveryPassed, o.At, HoldAction{Kind: HoldActionReleaseRecovery, End: o.At})
	}
	return nil
}

// Tick moves a failed key into recovering once its cooldown has elapsed.
func (k *KeyState) Tick(now time.Time) *Transition {
	if k.State != VerificationFailed || k.CooldownUntil.IsZero() || now.Before(k.CooldownUntil) {
		return nil
	}
	k.resetEscalation()
	return k.transition(VerificationRecovering, ReasonCooldownElapsed, now, HoldAction{Kind: HoldActionOpenRecovery, Start: now})
}

// OperatorClear resets the key to unverified. Holds are untouched: an
// operator releases them separately (SPEC-022 R-16.4).
func (k *KeyState) OperatorClear(now time.Time) *Transition {
	k.resetEscalation()
	k.WindowStart = time.Time{}
	k.LastInBandAt = time.Time{}
	k.FirstMeasuredAt = time.Time{}
	k.FailedAt = time.Time{}
	k.CooldownUntil = time.Time{}
	return k.transition(VerificationUnverified, ReasonOperatorClear, now, HoldAction{})
}

// NextStep is the closed FR-25 next_step value.
func (k *KeyState) NextStep() string {
	switch k.State {
	case VerificationSuspect:
		return "escalation_running"
	case VerificationFailed:
		return "cooldown_until:" + k.CooldownUntil.UTC().Format(time.RFC3339)
	case VerificationRecovering:
		return "requalification_running"
	}
	return "none"
}

func mergeOperators(have, add []string) []string {
	seen := map[string]struct{}{}
	for _, op := range have {
		seen[op] = struct{}{}
	}
	out := append([]string(nil), have...)
	for _, op := range add {
		if _, ok := seen[op]; ok || op == "" {
			continue
		}
		seen[op] = struct{}{}
		out = append(out, op)
	}
	return out
}
