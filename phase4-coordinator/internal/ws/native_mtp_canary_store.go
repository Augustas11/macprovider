package ws

import (
	"strconv"
	"sync"
	"time"
)

type NativeMTPCanaryTupleStatus string

const (
	NativeMTPCanaryTupleUnknown  NativeMTPCanaryTupleStatus = "unknown"
	NativeMTPCanaryTupleFresh    NativeMTPCanaryTupleStatus = "fresh"
	NativeMTPCanaryTupleDisabled NativeMTPCanaryTupleStatus = "disabled"
)

type NativeMTPCanaryTupleState struct {
	Key                NativeMTPCanaryTupleKey
	Status             NativeMTPCanaryTupleStatus
	LastOutcome        NativeMTPCanaryOutcome
	LastReason         string
	LastCheckedAt      time.Time
	FreshUntil         time.Time
	NextDueAt          time.Time
	DisabledAt         time.Time
	DisabledReason     string
	InFlight           *NativeMTPCanaryCoreRequest
	InFlightDeadline   time.Time
	ReplayKeysRetained map[string]time.Time
}

type NativeMTPCanaryStateStore interface {
	BeginNativeMTPCanary(key NativeMTPCanaryTupleKey, req NativeMTPCanaryCoreRequest, now time.Time) error
	CompleteNativeMTPCanary(key NativeMTPCanaryTupleKey, req NativeMTPCanaryCoreRequest, result NativeMTPCanaryCoreResult, evaluation NativeMTPCanaryEvaluation, interval time.Duration, now time.Time) error
	ExpireNativeMTPCanary(key NativeMTPCanaryTupleKey, now time.Time) (bool, error)
	NativeMTPCanaryState(key NativeMTPCanaryTupleKey, now time.Time) (NativeMTPCanaryTupleState, bool)
}

type MemoryNativeMTPCanaryStateStore struct {
	mu     sync.Mutex
	states map[string]NativeMTPCanaryTupleState
}

func NewMemoryNativeMTPCanaryStateStore() *MemoryNativeMTPCanaryStateStore {
	return &MemoryNativeMTPCanaryStateStore{states: make(map[string]NativeMTPCanaryTupleState)}
}

func (s *MemoryNativeMTPCanaryStateStore) BeginNativeMTPCanary(key NativeMTPCanaryTupleKey, req NativeMTPCanaryCoreRequest, now time.Time) error {
	if !key.valid() {
		return errNativeMTPCanaryInvalidTuple
	}
	if req.ProviderID != key.ProviderID ||
		req.AssignedID != key.AssignedID ||
		req.TargetGeneration != key.TargetGeneration ||
		req.RuntimeTupleSHA256 != key.RuntimeTupleSHA256 ||
		req.RuntimeTuple != key.RuntimeTuple ||
		req.ChallengeBankSHA256 != key.ChallengeBankSHA256 {
		return errNativeMTPCanaryInvalidTuple
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	storeKey := key.storeKey()
	state := s.states[storeKey]
	state.Key = key
	pruneNativeMTPReplayKeys(&state, now)
	if state.InFlight != nil && now.Before(state.InFlightDeadline) {
		return errNativeMTPCanaryInFlight
	}
	replayKey := nativeMTPReplayKey(req)
	if expires, ok := state.ReplayKeysRetained[replayKey]; ok && now.Before(expires) {
		return errNativeMTPCanaryReplay
	}
	reqCopy := req
	state.InFlight = &reqCopy
	state.InFlightDeadline = req.ExpiresAt
	if state.ReplayKeysRetained == nil {
		state.ReplayKeysRetained = make(map[string]time.Time)
	}
	state.ReplayKeysRetained[replayKey] = req.ExpiresAt
	state.Status = NativeMTPCanaryTupleUnknown
	s.states[storeKey] = state
	return nil
}

func (s *MemoryNativeMTPCanaryStateStore) CompleteNativeMTPCanary(key NativeMTPCanaryTupleKey, req NativeMTPCanaryCoreRequest, result NativeMTPCanaryCoreResult, evaluation NativeMTPCanaryEvaluation, interval time.Duration, now time.Time) error {
	if !key.valid() {
		return errNativeMTPCanaryInvalidTuple
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	storeKey := key.storeKey()
	state := s.states[storeKey]
	state.Key = key
	pruneNativeMTPReplayKeys(&state, now)
	if state.InFlight == nil || state.InFlight.RequestDigestSHA256 != req.RequestDigestSHA256 {
		return errNativeMTPCanaryReplay
	}
	state.InFlight = nil
	state.InFlightDeadline = time.Time{}
	state.LastOutcome = evaluation.Outcome
	state.LastReason = evaluation.Reason
	state.LastCheckedAt = now.UTC()
	switch evaluation.Outcome {
	case NativeMTPCanaryPass:
		interval = NativeMTPCanaryInterval(interval)
		state.Status = NativeMTPCanaryTupleFresh
		state.FreshUntil = now.UTC().Add(2 * interval)
		state.NextDueAt = now.UTC().Add(interval)
		state.DisabledAt = time.Time{}
		state.DisabledReason = ""
	case NativeMTPCanaryReschedule:
		interval = NativeMTPCanaryInterval(interval)
		state.Status = NativeMTPCanaryTupleUnknown
		state.NextDueAt = now.UTC().Add(interval)
	case NativeMTPCanaryFail:
		state.Status = NativeMTPCanaryTupleDisabled
		state.DisabledAt = now.UTC()
		state.DisabledReason = evaluation.Reason
		state.FreshUntil = time.Time{}
	default:
		state.Status = NativeMTPCanaryTupleUnknown
	}
	_ = result
	s.states[storeKey] = state
	return nil
}

func (s *MemoryNativeMTPCanaryStateStore) ExpireNativeMTPCanary(key NativeMTPCanaryTupleKey, now time.Time) (bool, error) {
	if !key.valid() {
		return false, errNativeMTPCanaryInvalidTuple
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	storeKey := key.storeKey()
	state := s.states[storeKey]
	state.Key = key
	pruneNativeMTPReplayKeys(&state, now)
	expired := false
	if state.InFlight != nil && !now.Before(state.InFlightDeadline) {
		state.LastOutcome = NativeMTPCanaryFail
		state.LastReason = "timeout"
		state.LastCheckedAt = now.UTC()
		state.Status = NativeMTPCanaryTupleDisabled
		state.DisabledAt = now.UTC()
		state.DisabledReason = "timeout"
		state.InFlight = nil
		state.InFlightDeadline = time.Time{}
		state.FreshUntil = time.Time{}
		expired = true
	}
	if state.Status == NativeMTPCanaryTupleFresh && !state.FreshUntil.IsZero() && !now.Before(state.FreshUntil) {
		state.Status = NativeMTPCanaryTupleDisabled
		state.DisabledAt = now.UTC()
		state.DisabledReason = "expired_result"
		expired = true
	}
	s.states[storeKey] = state
	return expired, nil
}

func (s *MemoryNativeMTPCanaryStateStore) NativeMTPCanaryState(key NativeMTPCanaryTupleKey, now time.Time) (NativeMTPCanaryTupleState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.states[key.storeKey()]
	if !ok {
		return NativeMTPCanaryTupleState{}, false
	}
	pruneNativeMTPReplayKeys(&state, now)
	s.states[key.storeKey()] = state
	return cloneNativeMTPCanaryState(state), true
}

func nativeMTPReplayKey(req NativeMTPCanaryCoreRequest) string {
	return req.ProviderID + "\x00" +
		req.AssignedID + "\x00" +
		strconvFormatUint(req.TargetGeneration) + "\x00" +
		req.RuntimeTupleSHA256 + "\x00" +
		req.ChallengeBankSHA256 + "\x00" +
		req.ChallengeID + "\x00" +
		req.Nonce
}

func pruneNativeMTPReplayKeys(state *NativeMTPCanaryTupleState, now time.Time) {
	for key, expires := range state.ReplayKeysRetained {
		if !now.Before(expires) {
			delete(state.ReplayKeysRetained, key)
		}
	}
}

func cloneNativeMTPCanaryState(state NativeMTPCanaryTupleState) NativeMTPCanaryTupleState {
	if state.InFlight != nil {
		req := *state.InFlight
		state.InFlight = &req
	}
	if state.ReplayKeysRetained != nil {
		copied := make(map[string]time.Time, len(state.ReplayKeysRetained))
		for key, value := range state.ReplayKeysRetained {
			copied[key] = value
		}
		state.ReplayKeysRetained = copied
	}
	return state
}

func strconvFormatUint(v uint64) string {
	return strconv.FormatUint(v, 10)
}
