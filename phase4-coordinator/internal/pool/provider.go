package pool

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

type State string
type Tier string
type InferencePath string
type RecoveryReason string
type HashStatus string
type AttestationStatus string

const (
	StateReady       State = "ready"
	StateBusy        State = "busy"
	StateDegraded    State = "degraded"
	StateDraining    State = "draining"
	StateUnavailable State = "unavailable"

	TierPinned      Tier = "pinned"
	TierProvisional Tier = "provisional"
	TierRejected    Tier = "rejected"

	InferencePathHTTPForwarding InferencePath = "http_forwarding"
	InferencePathWSTunneled     InferencePath = "ws_tunneled"

	RecoveryReasonBreaker         RecoveryReason = "breaker"
	RecoveryReasonProviderFailure RecoveryReason = "provider_failure"

	HashStatusVerified           HashStatus = "hash_verified"
	HashStatusMismatch           HashStatus = "hash_mismatch"
	HashStatusInvalid            HashStatus = "hash_invalid"
	HashStatusUncatalogued       HashStatus = "uncatalogued"
	HashStatusCatalogUnavailable HashStatus = "catalog_unavailable"

	AttestationStatusAttested    AttestationStatus = "attested"
	AttestationStatusFailed      AttestationStatus = "attestation_failed"
	AttestationStatusStale       AttestationStatus = "attestation_stale"
	AttestationStatusUnsupported AttestationStatus = "unsupported"
	AttestationStatusNotRequired AttestationStatus = "not_required"
)

type Provider struct {
	ProviderID            string        `json:"provider_id"`
	AssignedID            string        `json:"assigned_id"`
	Hostname              string        `json:"hostname"`
	ModelID               string        `json:"model_id"`
	ModelParamsB          float64       `json:"model_params_b"`
	RAMGB                 int           `json:"ram_gb"`
	MaxContextTokens      int           `json:"max_context_tokens"`
	MaxConcurrency        int           `json:"max_concurrency"`
	SlotsFree             int           `json:"slots_free"`
	SlotsTotal            int           `json:"slots_total"`
	ThroughputTPSEstimate float64       `json:"throughput_tps_estimate"`
	ModelLoadTimeMs       int64         `json:"model_load_time_ms,omitempty"`
	EndpointURL           string        `json:"endpoint_url"`
	Tier                  Tier          `json:"tier"`
	InferencePath         InferencePath `json:"inference_path"`
	AdmittedAt            time.Time     `json:"admitted_at"`
	HTTPForwardingOnly    bool          `json:"http_forwarding_only,omitempty"`
	State                 State         `json:"state"`
	LastHeartbeatAt       time.Time     `json:"last_heartbeat_at"`
	// LastActivityAt is the timestamp of the most recent inbound frame of any
	// kind (heartbeat OR in-flight inference response). The liveness monitor
	// uses this — not LastHeartbeatAt — so a provider actively streaming a
	// long generation is not closed for "missing" heartbeats it cannot send
	// while its single inference slot is busy.
	LastActivityAt time.Time  `json:"last_activity_at"`
	ConnectedAt    time.Time  `json:"connected_at"`
	BinaryVersion  string     `json:"binary_version"`
	ModelHash      string     `json:"model_hash,omitempty"`
	HashStatus     HashStatus `json:"hash_status,omitempty"`
	EncryptedLeg   bool       `json:"encrypted_leg,omitempty"`
	// AttestationStatus is informational unless tier2.require_attestation is
	// enabled. The zero value represents a legacy provider with no claim.
	AttestationStatus AttestationStatus `json:"attestation_status,omitempty"`

	// SPEC-002 v1.3.5 §3.X.1 — populated from v2 auth_request initial-stage
	// supported_models[] per SPEC-010 v1.5 R-3.3.1; nil for the L-1 baseline.
	SupportedModels []string `json:"supported_models,omitempty"`
	// SPEC-002 v1.3.5 §3.X.2 — populated from publishes_supported_models per
	// SPEC-010 v1.5 R-3.3.2; gates /v1/status echo per §7.4 R-7.4.1.
	PublishesSupportedModels bool `json:"publishes_supported_models,omitempty"`
	// SPEC-002 v1.3.5 §3.X.4 — sticky last-heartbeat loading flag for the
	// §7.1 R-7.1.6 / §7.10 R-7.10.8 exactly-once operator_model_swap gate.
	LastLoadingState bool `json:"-"`
	// SPEC-002 v1.3.5 §7.10.2 R-7.10.6 — coordinator clock at the first
	// observed loading:true heartbeat; loading_window_ms is computed at
	// swap-completion emission.
	LoadingStartedAt time.Time `json:"-"`

	Tier2Session *Tier2Session `json:"-"`

	conn net.Conn
}

type Tier2Session struct {
	AEADSuite          string
	C2PKey             []byte
	P2CKey             []byte
	C2PNonceBase       []byte
	P2CNonceBase       []byte
	C2PCounter         uint64
	P2CCounter         uint64
	RequestsDispatched uint64
	KeyID              string
	StartedAt          time.Time
}

func (p Provider) RoutingEligible() bool {
	if p.HashStatus == HashStatusMismatch || p.HashStatus == HashStatusInvalid {
		return false
	}
	return p.State == StateReady && p.SlotsFree > 0
}

func (p Provider) IsWSTunneled() bool {
	return p.InferencePath == InferencePathWSTunneled && !p.HTTPForwardingOnly
}

type Registry struct {
	mu                    sync.RWMutex
	providers             map[string]*Provider
	sessions              map[string]*Provider
	endpoints             map[string]config.ProviderConfig
	seenModels            map[string]struct{}
	breakerFaults         map[string][]time.Time
	recoveryHolds         map[string]recoveryHold
	lastBreakerRecoveries map[string]time.Time
	maxProvider           int
	hashVerifier          HeartbeatHashVerifier
	swapEmitter           SwapEventEmitter
}

type recoveryHold struct {
	assignedID string
	reason     RecoveryReason
}

func NewRegistry(providers []config.ProviderConfig, opts ...RegistryOption) *Registry {
	endpoints := make(map[string]config.ProviderConfig, len(providers))
	for _, p := range providers {
		endpoints[p.ProviderID] = p
	}
	r := &Registry{
		providers:             map[string]*Provider{},
		sessions:              map[string]*Provider{},
		endpoints:             endpoints,
		seenModels:            map[string]struct{}{},
		breakerFaults:         map[string][]time.Time{},
		recoveryHolds:         map[string]recoveryHold{},
		lastBreakerRecoveries: map[string]time.Time{},
	}
	for _, opt := range opts {
		opt(r)
	}
	return r
}

func (r *Registry) Endpoint(providerID string) (config.ProviderConfig, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.endpoints[providerID]
	return p, ok
}

func (r *Registry) Register(p *Provider, conn net.Conn) (old net.Conn) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing := r.providers[p.ProviderID]; existing != nil {
		old = existing.conn
		delete(r.sessions, existing.AssignedID)
	}
	p.conn = conn
	if p.Tier == "" {
		p.Tier = TierPinned
	}
	if p.InferencePath == "" {
		if p.EndpointURL != "" {
			p.InferencePath = InferencePathHTTPForwarding
		} else {
			p.InferencePath = InferencePathWSTunneled
		}
	}
	r.providers[p.ProviderID] = p
	r.sessions[p.AssignedID] = p
	r.seenModels[p.ModelID] = struct{}{}
	delete(r.breakerFaults, p.ProviderID)
	delete(r.recoveryHolds, p.ProviderID)
	delete(r.lastBreakerRecoveries, p.ProviderID)
	return old
}

func (r *Registry) SetTier(providerID string, tier Tier) (Provider, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil {
		return Provider{}, false
	}
	p.Tier = tier
	cp := *p
	cp.conn = nil
	return cp, true
}

func (r *Registry) UpdateHashStatuses(statusFor func(Provider) HashStatus) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := 0
	for _, p := range r.providers {
		cp := *p
		cp.conn = nil
		next := statusFor(cp)
		if p.HashStatus != next {
			updated++
		}
		p.HashStatus = next
	}
	return updated
}

func (r *Registry) MarkHTTPForwardingOnly(providerID, assignedID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	p.HTTPForwardingOnly = true
	return true
}

func (r *Registry) MarkState(providerID, assignedID string, state State) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if !r.canSetCoordinatorStateLocked(p, state) {
		return false
	}
	r.setStateLocked(p, state)
	return true
}

func (r *Registry) MarkDegradedForRecovery(providerID, assignedID string, reason RecoveryReason) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	r.setStateLocked(p, StateDegraded)
	r.recoveryHolds[providerID] = recoveryHold{assignedID: assignedID, reason: reason}
	return true
}

func (r *Registry) MarkRecovered(providerID, assignedID string, at time.Time) bool {
	if at.IsZero() {
		at = time.Now().UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	hold, held := r.recoveryHolds[providerID]
	if !held || hold.assignedID != assignedID {
		return false
	}
	r.setStateLocked(p, StateReady)
	delete(r.breakerFaults, providerID)
	delete(r.recoveryHolds, providerID)
	if hold.reason == RecoveryReasonBreaker {
		r.lastBreakerRecoveries[providerID] = at
	}
	return true
}

type BreakerTripState string

const (
	BreakerTripNone        BreakerTripState = ""
	BreakerTripDegraded    BreakerTripState = "degraded"
	BreakerTripUnavailable BreakerTripState = "unavailable"
)

type BreakerFaultResult struct {
	Count     int
	Threshold int
	Tripped   BreakerTripState
}

func (r *Registry) RecordBreakerFault(providerID, assignedID string, at time.Time, threshold int, window time.Duration) BreakerFaultResult {
	if threshold <= 0 {
		threshold = 2
	}
	if window <= 0 {
		window = 120 * time.Second
	}
	if at.IsZero() {
		at = time.Now().UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return BreakerFaultResult{Threshold: threshold}
	}
	if p.State != StateReady && p.State != StateBusy {
		return BreakerFaultResult{Threshold: threshold}
	}
	cutoff := at.Add(-window)
	faults := r.breakerFaults[providerID]
	kept := faults[:0]
	for _, faultAt := range faults {
		if !faultAt.Before(cutoff) {
			kept = append(kept, faultAt)
		}
	}
	kept = append(kept, at)
	r.breakerFaults[providerID] = kept
	result := BreakerFaultResult{Count: len(kept), Threshold: threshold}
	if result.Count < threshold {
		return result
	}
	if recoveredAt := r.lastBreakerRecoveries[providerID]; !recoveredAt.IsZero() && at.Sub(recoveredAt) <= window {
		r.setStateLocked(p, StateUnavailable)
		result.Tripped = BreakerTripUnavailable
		return result
	}
	r.setStateLocked(p, StateDegraded)
	r.recoveryHolds[providerID] = recoveryHold{assignedID: assignedID, reason: RecoveryReasonBreaker}
	result.Tripped = BreakerTripDegraded
	return result
}

// canSetCoordinatorStateLocked guards COORDINATOR-initiated state changes
// (admin drain/blacklist, warm-up, recovery). It is deliberately more
// permissive than canApplyProviderStateLocked: the coordinator is trusted to
// drain a held provider (the provider is then leaving the pool), so only the
// `ready` promotion is gated by an active hold. Keep these two guards separate
// — the provider-path one must stay strict (see canApplyProviderStateLocked).
func (r *Registry) canSetCoordinatorStateLocked(p *Provider, next State) bool {
	if next != StateReady {
		return true
	}
	if hold, ok := r.recoveryHolds[p.ProviderID]; ok && hold.assignedID == p.AssignedID {
		return false
	}
	return p.State != StateUnavailable
}

// canApplyProviderStateLocked guards PROVIDER-originated state changes
// (heartbeat status + state_update). It is intentionally STRICTER than the
// coordinator-path guard (canSetCoordinatorStateLocked): while a
// coordinator-owned recovery/breaker hold is live for this session, the
// provider's own telemetry may ONLY re-affirm `degraded`. It must not be able
// to launder itself back to routable by self-reporting an intermediate state.
// Specifically, without this a faulting, breaker-held provider could escape
// degradation by reporting `draining` and then `ready`. A hold is cleared only
// by a fresh session (Register), a coordinator recovery (MarkRecovered), or the
// provider becoming terminally `unavailable` / removed — never by a reversible
// provider-reported transition such as `draining`. (drain_status routes through
// the coordinator MarkState path; applyStateCleanupLocked no longer clears a
// hold on `draining`, so that vector is closed at the cleanup boundary too.)
func (r *Registry) canApplyProviderStateLocked(p *Provider, next State) bool {
	if hold, ok := r.recoveryHolds[p.ProviderID]; ok && hold.assignedID == p.AssignedID {
		return next == StateDegraded
	}
	if next != StateReady {
		return true
	}
	return p.State != StateUnavailable
}

func (r *Registry) setStateLocked(p *Provider, next State) {
	p.State = next
	r.applyStateCleanupLocked(p.ProviderID, next)
}

func (r *Registry) applyStateCleanupLocked(providerID string, next State) {
	// Only a TERMINAL transition clears a coordinator-owned breaker/recovery
	// hold. `draining` is deliberately NOT included: it is reversible and
	// reachable from provider-controlled messages (state_update, heartbeat, and
	// — via the coordinator path — drain_status), so clearing a hold on
	// `draining` would let a faulting, held provider launder itself back to
	// routable (draining clears the hold, then `ready`). A held provider that
	// genuinely shuts down does so by disconnecting, which removes it (and its
	// hold) via RemoveIfSession / RemoveIfSessionState below.
	if next == StateUnavailable {
		r.clearBreakerStateLocked(providerID)
	}
}

func (r *Registry) clearBreakerStateLocked(providerID string) {
	delete(r.breakerFaults, providerID)
	delete(r.recoveryHolds, providerID)
	delete(r.lastBreakerRecoveries, providerID)
}

func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

// HeartbeatHashVerifier verifies a (model_id, reported_hash) pair against
// the SPEC-008 v0.3 §5.5 five-state enum. Injected into Registry via
// WithHeartbeatHashVerifier so the pool package stays decoupled from the tier2
// catalog package; the production wiring at internal/ws/server.go passes
// tier2.VerifyProviderHash.
type HeartbeatHashVerifier func(modelID, reportedHash string) HashStatus

// SwapEvent carries the per-swap data needed for the operator_model_swap audit
// event per SPEC-002 v1.3.5 §7.10. Phase 2C only populates and emits this
// event; Phase 2E adds the SQLite write + payload schema + F-1.5 invariants.
type SwapEvent struct {
	ProviderID             string
	AssignedID             string
	FromModelID            string
	FromModelHash          string
	ToModelID              string
	ToModelHash            string
	HashVerificationResult HashStatus
	LoadingStartedAt       time.Time
	CompletedAt            time.Time
}

// SwapEventEmitter is called from ApplyHeartbeat when a SPEC-011 PATH
// heartbeat completes a swap (prior heartbeat had loading:true; current
// heartbeat has loading:false AND carries model_hash). Default nil = no-op.
// Phase 2E registers the SQLite emitter via WithSwapEmitter.
type SwapEventEmitter func(event SwapEvent)

type HeartbeatUpdate struct {
	Status                State
	ModelID               string
	ModelParamsB          float64
	RAMGB                 int
	MaxContextTokens      int
	MaxConcurrency        int
	SlotsFree             int
	SlotsTotal            int
	ThroughputTPSEstimate float64
	// ModelHash is the raw lowercase hex hash from the heartbeat when
	// ModelHashPresent is true; ignored otherwise. Populated from the SPEC-011
	// v0.5 optional heartbeat field per SPEC-002 v1.3.5 §7.1 R-7.1.4.
	ModelHash        string
	ModelHashPresent bool
	// Loading is the value of the heartbeat's optional `loading` field; absent
	// on the wire (= LoadingPresent false) is equivalent to false per SPEC-011
	// v0.5 R-3.3.4.
	Loading        bool
	LoadingPresent bool
	At             time.Time
}

func (r *Registry) ApplyHeartbeat(providerID, assignedID string, hb HeartbeatUpdate) (*Provider, time.Duration, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return nil, 0, false
	}
	prev := p.LastHeartbeatAt
	priorModelID := p.ModelID
	priorModelHash := p.ModelHash
	priorLoadingState := p.LastLoadingState
	priorLoadingStartedAt := p.LoadingStartedAt
	p.LastHeartbeatAt = hb.At

	modelIDChanged := !strings.EqualFold(priorModelID, hb.ModelID)
	if !hb.ModelHashPresent {
		if modelIDChanged {
			p.ModelHash = ""
			p.HashStatus = HashStatusUncatalogued
		}
	} else if modelIDChanged || !strings.EqualFold(priorModelHash, hb.ModelHash) {
		p.ModelHash = hb.ModelHash
		if r.hashVerifier != nil {
			p.HashStatus = r.hashVerifier(hb.ModelID, hb.ModelHash)
		} else {
			p.HashStatus = HashStatusUncatalogued
		}
	}

	p.ModelID = hb.ModelID
	p.ModelParamsB = hb.ModelParamsB
	p.RAMGB = hb.RAMGB
	p.MaxContextTokens = hb.MaxContextTokens
	p.MaxConcurrency = hb.MaxConcurrency
	p.SlotsFree = hb.SlotsFree
	p.SlotsTotal = hb.SlotsTotal
	p.ThroughputTPSEstimate = hb.ThroughputTPSEstimate
	r.seenModels[hb.ModelID] = struct{}{}
	if hb.Status != "" && hb.Status != p.State {
		if r.canApplyProviderStateLocked(p, hb.Status) {
			r.setStateLocked(p, hb.Status)
		}
	}
	if hb.LoadingPresent {
		if !priorLoadingState && hb.Loading {
			p.LoadingStartedAt = hb.At
		}
		p.LastLoadingState = hb.Loading
	}
	swapCompleted := hb.ModelHashPresent &&
		priorLoadingState &&
		hb.LoadingPresent && !hb.Loading
	if swapCompleted && r.swapEmitter != nil {
		r.swapEmitter(SwapEvent{
			ProviderID:             p.ProviderID,
			AssignedID:             p.AssignedID,
			FromModelID:            priorModelID,
			FromModelHash:          priorModelHash,
			ToModelID:              p.ModelID,
			ToModelHash:            p.ModelHash,
			HashVerificationResult: p.HashStatus,
			LoadingStartedAt:       priorLoadingStartedAt,
			CompletedAt:            hb.At,
		})
	}
	cp := *p
	var gap time.Duration
	if !prev.IsZero() {
		gap = hb.At.Sub(prev)
	}
	return &cp, gap, true
}

// Touch records that an inbound frame was received from the provider,
// resetting its liveness clock. Called for every frame (any type) so that
// in-flight inference response chunks keep an otherwise-heartbeat-silent
// provider alive. Safe to call for an unregistered provider (no-op).
func (r *Registry) Touch(providerID, assignedID string, at time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var p *Provider
	if providerID != "" {
		p = r.providers[providerID]
	} else if assignedID != "" {
		p = r.sessions[assignedID]
	}
	if p != nil && (assignedID == "" || p.AssignedID == assignedID) {
		p.LastActivityAt = at
	}
}

func (r *Registry) ModelKnown(modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		if strings.EqualFold(p.ModelID, modelID) {
			return true
		}
	}
	for seen := range r.seenModels {
		if strings.EqualFold(seen, modelID) {
			return true
		}
	}
	return false
}

type StateUpdate struct {
	State      State
	SlotsFree  *int
	SlotsTotal *int
}

func (r *Registry) ApplyStateUpdate(providerID, assignedID string, update StateUpdate) (*Provider, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return nil, false
	}
	if r.canApplyProviderStateLocked(p, update.State) {
		r.setStateLocked(p, update.State)
	}
	if update.SlotsFree != nil {
		p.SlotsFree = *update.SlotsFree
	}
	if update.SlotsTotal != nil {
		p.SlotsTotal = *update.SlotsTotal
	}
	cp := *p
	return &cp, true
}

func (r *Registry) RemoveIfSession(providerID, assignedID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	delete(r.providers, providerID)
	delete(r.sessions, assignedID)
	r.clearBreakerStateLocked(providerID)
	return true
}

func (r *Registry) RemoveIfSessionState(providerID, assignedID string, state State) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || p.State != state {
		return false
	}
	delete(r.providers, providerID)
	delete(r.sessions, assignedID)
	r.clearBreakerStateLocked(providerID)
	return true
}

func (r *Registry) Resolve(providerID, assignedID string) (Provider, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var p *Provider
	if providerID != "" {
		p = r.providers[providerID]
	} else if assignedID != "" {
		p = r.sessions[assignedID]
	}
	if p == nil || (assignedID != "" && p.AssignedID != assignedID) {
		return Provider{}, false
	}
	cp := *p
	cp.conn = nil
	return cp, true
}

func (r *Registry) Conn(providerID, assignedID string) (net.Conn, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || p.conn == nil {
		return nil, fmt.Errorf("provider session not connected")
	}
	return p.conn, nil
}

func (r *Registry) Snapshot() []Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Provider, 0, len(r.providers))
	for _, p := range r.providers {
		cp := *p
		cp.conn = nil
		out = append(out, cp)
	}
	return out
}

type RegistryOption func(*Registry)

// WithHeartbeatHashVerifier injects the SPEC-008 v0.3 Pillar A verifier used
// by the SPEC-011 PATH of ApplyHeartbeat per SPEC-002 v1.3.5 §7.1 R-7.1.5.
// If never set, the SPEC-011 PATH defaults to HashStatusUncatalogued (the
// conservative fallback for an un-injected Registry — tests typically either
// inject a stub or never exercise the SPEC-011 PATH).
func WithHeartbeatHashVerifier(fn HeartbeatHashVerifier) RegistryOption {
	return func(r *Registry) { r.hashVerifier = fn }
}

// WithSwapEmitter injects the operator_model_swap callback per SPEC-002
// v1.3.5 §7.10. Default nil = no-op (Phase 2C ships the detection logic; Phase
// 2E ships the SQLite writer).
func WithSwapEmitter(fn SwapEventEmitter) RegistryOption {
	return func(r *Registry) { r.swapEmitter = fn }
}
