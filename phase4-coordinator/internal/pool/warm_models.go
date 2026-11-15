package pool

import (
	"strings"

	"golang.org/x/text/unicode/norm"
)

// WarmModelState is a SPEC-001-R016 `warm_models[].state` value.
type WarmModelState string

const (
	WarmModelLoading  WarmModelState = "loading"
	WarmModelWarm     WarmModelState = "warm"
	WarmModelEvicting WarmModelState = "evicting"
)

// ValidWarmModelState reports whether s is one of the three R016 states.
func ValidWarmModelState(s WarmModelState) bool {
	switch s {
	case WarmModelLoading, WarmModelWarm, WarmModelEvicting:
		return true
	default:
		return false
	}
}

// WarmModel is one member of a provider's SPEC-001-R016 warm set as the
// provider reported it (SPEC-002-R011). The primary member repeats the
// session's top-level model fields, which stay authoritative for it.
type WarmModel struct {
	ModelID               string               `json:"model_id"`
	State                 WarmModelState       `json:"state"`
	Primary               bool                 `json:"primary"`
	Pinned                bool                 `json:"pinned"`
	SlotsTotal            int                  `json:"slots_total"`
	SlotsFree             int                  `json:"slots_free"`
	MaxContextTokens      int                  `json:"max_context_tokens,omitempty"`
	ThroughputTPSEstimate float64              `json:"throughput_tps_estimate,omitempty"`
	ModelParamsB          float64              `json:"model_params_b,omitempty"`
	ModelHash             string               `json:"model_hash,omitempty"`
	ModelHashAlgorithm    string               `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256 string               `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm  string               `json:"weights_manifest_algorithm,omitempty"`
	CBSelfCheck           *ProviderCBSelfCheck `json:"cb_self_check,omitempty"`
	EngineProfile         *EngineProfile       `json:"-"`
	// ExpectedModelHash and HashStatus are the coordinator's SPEC-008 §5.5
	// verdict for this (provider, model) pair; a failing member is excluded
	// on its own (SPEC-001-R016 Trust).
	ExpectedModelHash string     `json:"-"`
	HashStatus        HashStatus `json:"hash_status,omitempty"`
	// forwardedInFlight counts this member's accepted forwarded dispatches,
	// like Provider.forwardedInFlight does for the primary. It follows the
	// member by model id across heartbeats, promotion included.
	forwardedInFlight int
}

// warmModelKey is the SPEC-010 case-folded model id.
func warmModelKey(modelID string) string {
	return strings.ToLower(norm.NFC.String(modelID))
}

func cloneWarmModels(in []WarmModel) []WarmModel {
	if in == nil {
		return nil
	}
	out := make([]WarmModel, len(in))
	for i, m := range in {
		out[i] = m
		out[i].CBSelfCheck = cloneProviderCBSelfCheck(m.CBSelfCheck)
		out[i].EngineProfile = cloneEngineProfile(m.EngineProfile)
	}
	return out
}

const (
	warmMemberSession = -1
	warmMemberMissing = -2
)

// warmMemberIndexLocked names the slot owner for a dispatch: the session
// itself (warmMemberSession) for a provider without a warm set, an empty
// served model or the primary; the index of a further member; or
// warmMemberMissing when the served model is not in the warm set (evicted).
func warmMemberIndexLocked(p *Provider, servedModelID string) int {
	if p.WarmModels == nil || servedModelID == "" {
		return warmMemberSession
	}
	key := warmModelKey(servedModelID)
	for i := range p.WarmModels {
		if warmModelKey(p.WarmModels[i].ModelID) != key {
			continue
		}
		if p.WarmModels[i].Primary {
			return warmMemberSession
		}
		return i
	}
	return warmMemberMissing
}

// mutableWarmMemberLocked replaces the member list with a private copy before
// a member is mutated: copies handed out by Resolve/Snapshot share the old
// backing array and must never observe the write.
func mutableWarmMemberLocked(p *Provider, idx int) *WarmModel {
	p.WarmModels = cloneWarmModels(p.WarmModels)
	return &p.WarmModels[idx]
}

// warmInFlightLocked is the coordinator's open dispatch count per member,
// keyed by model id; the primary's is the session's own count.
func warmInFlightLocked(p *Provider) map[string]int {
	out := map[string]int{}
	if p.WarmModels == nil {
		out[warmModelKey(p.ModelID)] = p.forwardedInFlight
		return out
	}
	for _, m := range p.WarmModels {
		if m.Primary {
			out[warmModelKey(m.ModelID)] = p.forwardedInFlight
		} else {
			out[warmModelKey(m.ModelID)] = m.forwardedInFlight
		}
	}
	return out
}

// promoteWarmPrimaryLocked moves the session-level in-flight count to the
// member a heartbeat names primary (SPEC-011 R-3.10.3 promotion), so each
// member keeps its own open dispatches. Coordinator occupancy guards that
// described the previous primary's seats no longer apply.
func promoteWarmPrimaryLocked(p *Provider, incoming []WarmModel, inFlight map[string]int) {
	if incoming == nil {
		return
	}
	priorPrimary := warmModelKey(p.ModelID)
	for _, m := range p.WarmModels {
		if m.Primary {
			priorPrimary = warmModelKey(m.ModelID)
		}
	}
	nextPrimary := warmModelKey(incoming[0].ModelID)
	if nextPrimary == priorPrimary {
		return
	}
	p.forwardedInFlight = inFlight[nextPrimary]
	p.awaitingReadyOccupancy = false
	p.ignoredLowerReadyReport = false
	if p.queueFullHold {
		p.capacitySafetyHold = false
		p.queueFullHold = false
	}
}

// applyWarmModelsLocked replaces the session's member list with the reported
// one (SPEC-002-R011): a member missing from the report is gone, and every
// remaining member keeps its in-flight count. The primary's slots, hash and
// verdict are the session's own; a further member's hash is verified for its
// own model. verify is false at registration while the session itself has
// no verdict (model-hash verification inactive).
func (r *Registry) applyWarmModelsLocked(p *Provider, incoming []WarmModel, inFlight map[string]int, verify bool) {
	if incoming == nil {
		p.WarmModels = nil
		return
	}
	prior := map[string]WarmModel{}
	for _, m := range p.WarmModels {
		if !m.Primary {
			prior[warmModelKey(m.ModelID)] = m
		}
	}
	entries := cloneWarmModels(incoming)
	for i := range entries {
		m := &entries[i]
		key := warmModelKey(m.ModelID)
		if m.Primary {
			m.forwardedInFlight = p.forwardedInFlight
			m.ExpectedModelHash = p.ExpectedModelHash
			m.HashStatus = p.HashStatus
			continue
		}
		m.forwardedInFlight = inFlight[key]
		if m.State != WarmModelWarm {
			m.SlotsFree = 0
		} else if old, ok := prior[key]; ok && m.forwardedInFlight > 0 && old.SlotsFree < m.SlotsFree {
			// While the coordinator has dispatches open on this member its
			// own count is at least as fresh as the provider's report.
			m.SlotsFree = old.SlotsFree
		}
		if !verify {
			m.HashStatus = ""
			continue
		}
		m.HashStatus = r.warmModelHashStatusLocked(p, *m)
	}
	p.WarmModels = entries
}

// warmModelHashStatusLocked is the SPEC-008 §5.5 verdict for one further
// member, computed by the same verifier chain as the session's model. The
// primary-only catalog model binding is not this member's, so it is not used.
func (r *Registry) warmModelHashStatusLocked(p *Provider, m WarmModel) HashStatus {
	if m.ModelHash == "" {
		return HashStatusUncatalogued
	}
	switch {
	case r.modelIdentityResolver != nil:
		return r.modelIdentityResolver(ModelIdentityRequest{
			ModelID:                m.ModelID,
			ExpectedHash:           m.ExpectedModelHash,
			ReportedHash:           m.ModelHash,
			ReportedAlgorithm:      m.ModelHashAlgorithm,
			CandidateCatalogSHA256: p.CandidateCatalogSHA256,
			CatalogAdmissionMode:   p.CatalogAdmissionMode,
		}).Status
	case r.modelIdentityVerifier != nil:
		return r.modelIdentityVerifier(m.ModelID, m.ExpectedModelHash, m.ModelHash, m.ModelHashAlgorithm)
	case r.hashVerifier != nil:
		return r.hashVerifier(m.ModelID, m.ModelHash)
	default:
		return HashStatusUncatalogued
	}
}

// warmEntryView projects one member onto a copy of its session. The primary
// is the session as it is. A further member takes its own model, slots,
// throughput, identity and verdict; the session-level gates (connection,
// trust, admission tier, breaker, pause, draining/degraded/unavailable,
// thermal hold) stay. Bindings that belong to the primary's tuple alone
// (model admission, artifact identity, native MTP, pool model, tool and vision
// guarantees) are cleared so every consumer fails closed on them.
func warmEntryView(session Provider, m WarmModel) Provider {
	v := session
	v.ServedModelID = m.ModelID
	if m.Primary {
		return v
	}
	v.ModelID = m.ModelID
	v.MaxContextTokens = m.MaxContextTokens
	v.MaxConcurrency = m.SlotsTotal
	v.SlotsTotal = m.SlotsTotal
	v.SlotsFree = m.SlotsFree
	v.ThroughputTPSEstimate = m.ThroughputTPSEstimate
	v.ModelParamsB = m.ModelParamsB
	v.RequestsServedSinceLast = 0
	v.ThroughputTPSSinceLast = 0
	v.ModelHash = m.ModelHash
	v.ModelHashAlgorithm = m.ModelHashAlgorithm
	v.WeightsManifestSHA256 = m.WeightsManifestSHA256
	v.WeightsHashAlgorithm = m.WeightsHashAlgorithm
	v.ExpectedModelHash = m.ExpectedModelHash
	v.HashStatus = m.HashStatus
	v.CBSelfCheck = cloneProviderCBSelfCheck(m.CBSelfCheck)
	v.EngineProfile = cloneEngineProfile(m.EngineProfile)
	v.ArtifactIdentity = nil
	v.IdentityPin = nil
	clearModelAdmissionBinding(&v)
	v.ModelAdmissionBindingGeneration = 0
	v.NativeMTPCanary = nil
	v.ShardGroupAvailable = false
	v.ShardGroupPoolModelID = ""
	v.ShardGroupMembers = nil
	v.CandidateRowIdentity = ""
	v.ToolSelectionCapabilities = nil
	v.VisionRuntimeCapabilities = nil
	thermal := session.capacitySafetyHold && !session.queueFullHold
	v.forwardedInFlight = m.forwardedInFlight
	v.awaitingReadyOccupancy = false
	v.ignoredLowerReadyReport = false
	v.queueFullHold = false
	v.capacitySafetyHold = thermal
	if m.State != WarmModelWarm {
		v.SlotsFree = 0
	}
	if session.State != StateReady && session.State != StateBusy {
		return v
	}
	switch {
	case m.State != WarmModelWarm:
		v.State = StateUnavailable
	case thermal || v.SlotsFree <= 0:
		v.State = StateBusy
	default:
		v.State = StateReady
	}
	return v
}

func (r *Registry) entryViewsLocked(p *Provider, out []Provider) []Provider {
	if p.WarmModels == nil {
		return append(out, snapshotProviderLocked(p))
	}
	for _, m := range p.WarmModels {
		out = append(out, warmEntryView(snapshotProviderLocked(p), m))
	}
	return out
}

// EntrySnapshot is Snapshot with one Provider value per SPEC-002-R011 entry:
// a provider without a warm set yields exactly its Snapshot value, and a
// provider with one yields a view per member (ServedModelID set).
func (r *Registry) EntrySnapshot() []Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Provider, 0, len(r.providers))
	for _, p := range r.providers {
		out = r.entryViewsLocked(p, out)
	}
	return out
}

// ResolveEntry is Resolve for one entry. A provider without a warm set
// resolves as Resolve does whatever model is named; a provider with one
// resolves the member named by model (case-folded; empty is the primary) and
// fails when that model is not in its warm set.
func (r *Registry) ResolveEntry(providerID, assignedID, model string) (Provider, bool) {
	session, ok := r.Resolve(providerID, assignedID)
	if !ok || session.WarmModels == nil {
		return session, ok
	}
	key := warmModelKey(model)
	for _, m := range session.WarmModels {
		if (model == "" && m.Primary) || (model != "" && warmModelKey(m.ModelID) == key) {
			return warmEntryView(session, m), true
		}
	}
	return Provider{}, false
}

// ConsumeForwardedSlotFor is ConsumeForwardedSlotDetailed for the entry
// serving servedModelID. A further member's dispatch takes that member's
// seat only: it never consumes the primary's seats or marks the session busy.
func (r *Registry) ConsumeForwardedSlotFor(providerID, assignedID, servedModelID string) (ok, unconfirmed bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false, false
	}
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		ok, unconfirmed = r.consumeForwardedSlotLocked(p)
		return ok, unconfirmed
	case warmMemberMissing:
		return false, false
	default:
		m := mutableWarmMemberLocked(p, idx)
		unconfirmed = m.forwardedInFlight > 0
		m.forwardedInFlight++
		if m.SlotsFree > 0 {
			m.SlotsFree--
		}
		return true, unconfirmed
	}
}

// RestoreForwardedSlotFor is RestoreForwardedSlot for the entry serving
// servedModelID. A restore for a member that has left the warm set is a
// no-op.
func (r *Registry) RestoreForwardedSlotFor(providerID, assignedID, servedModelID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		return r.restoreForwardedSlotLocked(p)
	case warmMemberMissing:
		return false
	default:
		m := mutableWarmMemberLocked(p, idx)
		if m.forwardedInFlight > 0 {
			m.forwardedInFlight--
		}
		if m.State == WarmModelWarm && m.SlotsFree < m.SlotsTotal {
			m.SlotsFree++
		}
		return true
	}
}

// DropForwardedInFlightFor is DropForwardedInFlight for the entry serving
// servedModelID.
func (r *Registry) DropForwardedInFlightFor(providerID, assignedID, servedModelID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		if p.forwardedInFlight > 0 {
			p.forwardedInFlight--
		}
		return true
	case warmMemberMissing:
		return false
	default:
		m := mutableWarmMemberLocked(p, idx)
		if m.forwardedInFlight > 0 {
			m.forwardedInFlight--
		}
		return true
	}
}

// MarkForwardedSlotFullFor is MarkForwardedSlotFull for the entry serving
// servedModelID. A further member's refusal (the shared memory budget
// admitted fewer rows than advertised, SPEC-001-R017) closes that member's
// seats until its next heartbeat; the primary and the session are untouched.
func (r *Registry) MarkForwardedSlotFullFor(providerID, assignedID, servedModelID string, refusedSeatConsumed bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		return r.markForwardedSlotFullLocked(p, refusedSeatConsumed)
	case warmMemberMissing:
		return false
	default:
		m := mutableWarmMemberLocked(p, idx)
		if refusedSeatConsumed && m.forwardedInFlight > 0 {
			m.forwardedInFlight--
		}
		m.SlotsFree = 0
		return true
	}
}

// RoutableSlotsFreeFor is RoutableSlotsFree for the entry serving
// servedModelID.
func (r *Registry) RoutableSlotsFreeFor(providerID, assignedID, servedModelID string) (int, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil || (assignedID != "" && p.AssignedID != assignedID) {
		return 0, false
	}
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		if p.capacitySafetyHold || p.SlotsFree < 0 {
			return 0, true
		}
		return p.SlotsFree, true
	case warmMemberMissing:
		return 0, false
	default:
		m := p.WarmModels[idx]
		thermal := p.capacitySafetyHold && !p.queueFullHold
		if thermal || m.State != WarmModelWarm || m.SlotsFree < 0 {
			return 0, true
		}
		return m.SlotsFree, true
	}
}

// ForwardedInFlightFor is ForwardedInFlight for the entry serving
// servedModelID.
func (r *Registry) ForwardedInFlightFor(providerID, assignedID, servedModelID string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil || (assignedID != "" && p.AssignedID != assignedID) {
		return 0
	}
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		return p.forwardedInFlight
	case warmMemberMissing:
		return 0
	default:
		return p.WarmModels[idx].forwardedInFlight
	}
}
