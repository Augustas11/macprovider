package pool

import (
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
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
	// ToolSelectionCapabilities and VisionRuntimeCapabilities are this
	// member's own declarations, with the schema of the session's top-level
	// lists; buyer routing reads them for the member's model exactly as it
	// reads the top-level lists for the primary.
	ToolSelectionCapabilities []ToolSelectionCapability `json:"-"`
	VisionRuntimeCapabilities []VisionRuntimeCapability `json:"-"`
	// ArtifactIdentity is the artifact-feed binding of this member's own
	// identity verdict (SPEC-010-R007), as Provider.ArtifactIdentity is the
	// session's.
	ArtifactIdentity *artifactidentity.Binding `json:"-"`
	// ExpectedModelHash and HashStatus are the coordinator's SPEC-008 §5.5
	// verdict for this (provider, model) pair; a failing member is excluded
	// on its own (SPEC-001-R016 Trust).
	ExpectedModelHash string     `json:"-"`
	HashStatus        HashStatus `json:"hash_status,omitempty"`
	// forwardedInFlight counts this member's accepted forwarded dispatches,
	// like Provider.forwardedInFlight does for the primary. It follows the
	// member by model id across heartbeats, promotion included.
	forwardedInFlight int
	// notLoaded records a model_not_loaded answer for this member; its entry
	// is unavailable until the next heartbeat replaces the member list.
	notLoaded bool
	// computeIntegritySuspended is the SPEC-036 FR-25 suspension of this
	// (provider, model) key; the entry view of a further member takes it in
	// place of the session's (the primary's) flag.
	computeIntegritySuspended bool
	// computeIntegrityPassing is the passing SPEC-036 verification of this
	// (provider, model) key; the entry view takes it as the suspension.
	computeIntegrityPassing bool
	// identityPin is this further member's SPEC-010-R007(b)(c) authority:
	// the identity it first verified while a further member. It follows the
	// member by model id across heartbeats (Provider.warmPins, also while the
	// session is not multi-model) and is reset when the member leaves the
	// declared warm set or becomes primary (the session's pin is then its
	// authority, reset on a model change as for any session).
	identityPin *IdentityPin
	// refusalHold mirrors the session's queueFullHold for this member: a
	// refusal (MarkForwardedSlotFullFor) closes its seats while SlotsFree
	// keeps the coordinator's own count; a ready heartbeat reporting free
	// seats lifts it, taking the lower of the two counts.
	refusalHold bool
}

// ModelKey is the SPEC-010 canonical model id (surrounding whitespace
// trimmed, NFC, then lowercase): the one form the pool, buyer entry routing
// and the routing perf store key a model on. Per-model sanctions
// (compute-integrity suspension and scoring, not-loaded strikes, identity
// pins) key on Registry.SanctionKey, which maps every name of one catalog
// row to one identity and falls back to ModelKey.
func ModelKey(modelID string) string {
	return strings.ToLower(norm.NFC.String(strings.TrimSpace(modelID)))
}

func warmModelKey(modelID string) string {
	return ModelKey(modelID)
}

// warmMultiModel is the SPEC-002-R011 multi-model predicate: the session
// keeps at least two members that are warm and whose identity verdict is
// hash_verified (the primary's verdict is the session's own), each further
// member with at least one seat (a zero-seat member is never routed or
// probed). Only then does
// the session have entry views, a served_model_id, a route snapshot flag of
// 1 and per-model compute-integrity holds; otherwise it is a legacy session
// exactly as with a warm set of one member.
func warmMultiModel(p *Provider, members []WarmModel) bool {
	n := 0
	for _, m := range members {
		status := m.HashStatus
		if m.Primary {
			status = p.HashStatus
		}
		if m.State == WarmModelWarm && status == HashStatusVerified && (m.Primary || m.SlotsTotal >= 1) {
			n++
		}
	}
	return n >= 2
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
// itself (warmMemberSession) for an empty served model, the primary, or the
// session's own model on a session without a warm set; the index of a further
// member; or warmMemberMissing when the served model is neither (a member
// that left the warm set, also when the session became a legacy session).
func warmMemberIndexLocked(p *Provider, servedModelID string) int {
	if servedModelID == "" {
		return warmMemberSession
	}
	key := warmModelKey(servedModelID)
	if p.WarmModels == nil {
		if key == warmModelKey(p.ModelID) {
			return warmMemberSession
		}
		return warmMemberMissing
	}
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
// described the previous primary's seats no longer apply. It runs only when
// the incoming primary was a further member of the previous warm set; a
// legacy session whose model the heartbeat keeps as a further member under
// another primary hands its count and holds to that member
// (demoteLegacyModelLocked). Any other primary change (a legacy or one-member
// session's warm swap) keeps the session's own swap handling.
func promoteWarmPrimaryLocked(p *Provider, incoming []WarmModel, inFlight map[string]int) *WarmModel {
	if len(incoming) == 0 {
		return nil
	}
	if p.WarmModels == nil {
		return demoteLegacyModelLocked(p, incoming)
	}
	nextPrimary := warmModelKey(incoming[0].ModelID)
	wasFurther := false
	for _, m := range p.WarmModels {
		if !m.Primary && warmModelKey(m.ModelID) == nextPrimary {
			wasFurther = true
		}
	}
	if !wasFurther {
		return nil
	}
	drainEmptyServedLocked(p)
	p.forwardedInFlight = inFlight[nextPrimary]
	p.awaitingReadyOccupancy = false
	p.ignoredLowerReadyReport = false
	if p.queueFullHold {
		p.capacitySafetyHold = false
		p.queueFullHold = false
	}
	return nil
}

// demoteLegacyModelLocked handles a legacy session (no warm set) whose
// heartbeat names another primary and lists the session's model as a further
// member: the session's open dispatches, seat count and refusal hold belong
// to that member, so they leave the session (now the new primary) and the
// returned prior entry carries them to the member. The legacy dispatches
// that name no served model are drained to the member
// (drainEmptyServedLocked).
func demoteLegacyModelLocked(p *Provider, incoming []WarmModel) *WarmModel {
	old := warmModelKey(p.ModelID)
	if warmModelKey(incoming[0].ModelID) == old {
		return nil
	}
	for _, m := range incoming[1:] {
		if m.Primary || warmModelKey(m.ModelID) != old {
			continue
		}
		prior := &WarmModel{ModelID: m.ModelID, SlotsFree: p.SlotsFree, refusalHold: p.queueFullHold}
		drainEmptyServedLocked(p)
		p.forwardedInFlight = 0
		p.awaitingReadyOccupancy = false
		p.ignoredLowerReadyReport = false
		if p.queueFullHold {
			p.capacitySafetyHold = false
			p.queueFullHold = false
		}
		return prior
	}
	return nil
}

// drainEmptyServedLocked runs when the session's model stops being its
// primary (a legacy model demoted under another primary, or a primary
// promoted away): the open dispatches that name no served model
// (emptyServedOpen) are that model's, so they become the drain record and
// every later empty-served ending is attributed to that model until as many
// as were open have ended. While the record is open, a dispatch that names
// no served model is booked under the session's model
// (ConsumeForwardedSlotBooked), so the two never mix.
func drainEmptyServedLocked(p *Provider) {
	if p.emptyServedOpen == 0 {
		return
	}
	p.legacyDispatchModel = p.ModelID
	p.legacyDispatchOpen = p.emptyServedOpen
	p.emptyServedOpen = 0
}

// endedDispatchModelLocked is the served model a dispatch that ends
// (restore, drop, refusal of a consumed seat) was booked for: an empty
// served model names the drained model while its record is open, whatever
// the session's warm set is now (a model that left the warm set resolves as
// missing, never as a live model), and otherwise the session.
func endedDispatchModelLocked(p *Provider, servedModelID string) string {
	if servedModelID != "" {
		return servedModelID
	}
	if p.legacyDispatchOpen == 0 {
		if p.emptyServedOpen > 0 {
			p.emptyServedOpen--
		}
		return ""
	}
	model := p.legacyDispatchModel
	p.legacyDispatchOpen--
	if p.legacyDispatchOpen == 0 {
		p.legacyDispatchModel = ""
	}
	return model
}

// applyWarmModelsLocked replaces the session's member list with the reported
// one (SPEC-002-R011): a member missing from the report is gone, and every
// remaining member keeps its in-flight count. The primary's slots, hash and
// verdict are the session's own; a further member's hash is verified for its
// own model. verify is false at registration while the session itself has
// no verdict (model-hash verification inactive).
//
// A warm set that is not multi-model (warmMultiModel: fewer than two warm,
// hash-verified members, e.g. one member, or a second member still loading
// or unverified) is stored as no warm set: the session is a legacy session
// everywhere (entry views, served model, route snapshot flag, sort and sticky
// keys, model_not_loaded and swap handling). A later heartbeat that makes it
// multi-model is a legacy-to-multi flip (demoteLegacyModelLocked when the
// primary changes); one that makes it legacy again drops the member entries,
// so their dispatches resolve as missing.
//
// demoted is the prior entry demoteLegacyModelLocked made for the legacy
// session's own model, or nil.
func (r *Registry) applyWarmModelsLocked(p *Provider, incoming []WarmModel, inFlight map[string]int, demoted *WarmModel, verify, serving bool) {
	if len(incoming) <= 1 {
		p.WarmModels = nil
		p.warmPins = nil
		return
	}
	prior := map[string]WarmModel{}
	for _, m := range p.WarmModels {
		if !m.Primary {
			prior[warmModelKey(m.ModelID)] = m
		}
	}
	if demoted != nil {
		prior[warmModelKey(demoted.ModelID)] = *demoted
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
		m.identityPin = p.warmPins[r.SanctionKey(m.ModelID)]
		old, known := prior[key]
		switch {
		case m.State != WarmModelWarm:
			m.SlotsFree = 0
		case known && old.refusalHold && serving && m.SlotsFree > 0:
			// The refusal and this report share the provider's ordered
			// stream, so a free seat this member reports opened after the
			// refusal. The session's status describes the primary's seats,
			// so a busy primary does not keep the member closed. The lower
			// of the two counts applies.
			if old.SlotsFree < m.SlotsFree {
				m.SlotsFree = old.SlotsFree
			}
		case known && old.refusalHold:
			m.refusalHold = true
			m.SlotsFree = old.SlotsFree
		case known && m.forwardedInFlight > 0 && old.SlotsFree < m.SlotsFree:
			// While the coordinator has dispatches open on this member its
			// own count is at least as fresh as the provider's report.
			m.SlotsFree = old.SlotsFree
		}
		if !verify {
			m.HashStatus = ""
			m.ArtifactIdentity = nil
			continue
		}
		verdict := pinArtifactSession(m.identityPin, r.warmModelIdentityLocked(p, *m))
		m.identityPin = pinIdentity(m.identityPin, verdict)
		m.HashStatus, m.ArtifactIdentity = verdict.Status, verdict.Artifact
	}
	p.warmPins = r.warmPinsOf(entries)
	if !warmMultiModel(p, entries) {
		p.WarmModels = nil
		return
	}
	p.WarmModels = entries
	r.applyComputeIntegritySuspensionLocked(p)
}

// warmPinsOf is the identity pin of each further member, by SanctionKey, so
// a member declared under another name of its catalog row keeps its pin.
func (r *Registry) warmPinsOf(members []WarmModel) map[string]*IdentityPin {
	pins := map[string]*IdentityPin{}
	for _, m := range members {
		if !m.Primary && m.identityPin != nil {
			pins[r.SanctionKey(m.ModelID)] = m.identityPin
		}
	}
	return pins
}

// maxRejectedWarmModels is how many consecutive heartbeats with a rejected
// warm_models keep the previous member list before it is dropped as stale.
const maxRejectedWarmModels = 3

// keepWarmModelsLocked keeps the previous member list for a heartbeat whose
// warm_models was rejected. A list whose primary is no longer the session's
// model describes another configuration and is dropped, and so is a list kept
// over maxRejectedWarmModels consecutive rejections (fail closed: the session
// serves its top-level model only until a valid warm set arrives).
func (r *Registry) keepWarmModelsLocked(p *Provider) {
	p.warmModelsRejected++
	if p.WarmModels != nil && (warmModelKey(p.WarmModels[0].ModelID) != warmModelKey(p.ModelID) || p.warmModelsRejected >= maxRejectedWarmModels) {
		p.WarmModels = nil
		p.warmPins = nil
	}
	if p.WarmModels != nil && !warmMultiModel(p, p.WarmModels) {
		p.WarmModels = nil
	}
	r.applyComputeIntegritySuspensionLocked(p)
}

// warmModelIdentityLocked is the SPEC-008 §5.5 / SPEC-010 verdict for one
// further member, computed by the same verifier chain as the session's model.
// The primary-only catalog model binding is not this member's, so it is not used.
func (r *Registry) warmModelIdentityLocked(p *Provider, m WarmModel) ModelIdentityVerdict {
	if m.ModelHash == "" {
		return ModelIdentityVerdict{Status: HashStatusUncatalogued}
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
		})
	case r.modelIdentityVerifier != nil:
		return ModelIdentityVerdict{Status: r.modelIdentityVerifier(m.ModelID, m.ExpectedModelHash, m.ModelHash, m.ModelHashAlgorithm)}
	case r.hashVerifier != nil:
		return ModelIdentityVerdict{Status: r.hashVerifier(m.ModelID, m.ModelHash)}
	default:
		return ModelIdentityVerdict{Status: HashStatusUncatalogued}
	}
}

// refreshWarmModelIdentitiesLocked re-evaluates every further member's
// verdict with the session's own refresh (UpdateModelIdentities), on the
// member's entry view, so a release publication re-verifies each member
// against its own model id and hash exactly as it does the primary.
func (r *Registry) refreshWarmModelIdentitiesLocked(p *Provider, verdictFor func(Provider) ModelIdentityVerdict) {
	if p.WarmModels == nil {
		return
	}
	session := *p
	session.conn = nil
	entries := cloneWarmModels(p.WarmModels)
	for i := range entries {
		m := &entries[i]
		if m.Primary {
			m.HashStatus = p.HashStatus
			continue
		}
		if m.ModelHash == "" {
			continue
		}
		next := pinArtifactSession(m.identityPin, verdictFor(warmEntryView(session, *m)))
		m.identityPin = pinIdentity(m.identityPin, next)
		m.HashStatus, m.ArtifactIdentity = next.Status, next.Artifact
	}
	p.warmPins = r.warmPinsOf(entries)
	if !warmMultiModel(p, entries) {
		// A refresh that leaves fewer than two verified warm members makes
		// the session legacy until a heartbeat makes it multi-model again.
		p.WarmModels = nil
		return
	}
	p.WarmModels = entries
}

// warmEntryView projects one member onto a copy of its session. The primary
// is the session as it is. A further member takes its own model, slots,
// throughput, identity, verdict, identity pin, artifact binding, SPEC-036
// FR-25 suspension and tool and vision declarations; the session-level gates
// (connection, trust, admission tier, breaker, pause,
// draining/degraded/unavailable, thermal hold) stay. Bindings that belong to
// the primary's tuple alone (the SPEC-047 session-to-candidate model
// admission binding, the native-MTP canary, pool model and shard group) are
// cleared so every consumer fails closed on them.
func warmEntryView(session Provider, m WarmModel) Provider {
	v := session
	v.ServedModelID = m.ModelID
	if m.Primary {
		if m.notLoaded && (session.State == StateReady || session.State == StateBusy) {
			v.State = StateUnavailable
		}
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
	v.ArtifactIdentity = m.ArtifactIdentity
	v.IdentityPin = m.identityPin
	clearModelAdmissionBinding(&v)
	v.ModelAdmissionBindingGeneration = 0
	v.NativeMTPCanary = nil
	v.ShardGroupAvailable = false
	v.ShardGroupPoolModelID = ""
	v.ShardGroupMembers = nil
	v.CandidateRowIdentity = ""
	v.ToolSelectionCapabilities = m.ToolSelectionCapabilities
	v.VisionRuntimeCapabilities = m.VisionRuntimeCapabilities
	v.ComputeIntegritySuspended = m.computeIntegritySuspended
	v.ComputeIntegrityPassing = m.computeIntegrityPassing
	thermal := session.capacitySafetyHold && !session.queueFullHold
	v.forwardedInFlight = m.forwardedInFlight
	v.awaitingReadyOccupancy = false
	v.ignoredLowerReadyReport = false
	v.queueFullHold = false
	v.capacitySafetyHold = thermal
	if m.State != WarmModelWarm || m.notLoaded || m.refusalHold {
		v.SlotsFree = 0
	}
	if session.State != StateReady && session.State != StateBusy {
		return v
	}
	switch {
	case m.State != WarmModelWarm || m.notLoaded:
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

// EntryMember is the warm-set member an entry view (ServedModelID set)
// projects; false for a provider without a warm set.
func (p Provider) EntryMember() (WarmModel, bool) {
	if p.ServedModelID == "" {
		return WarmModel{}, false
	}
	key := warmModelKey(p.ServedModelID)
	for _, m := range p.WarmModels {
		if warmModelKey(m.ModelID) == key {
			return m, true
		}
	}
	return WarmModel{}, false
}

// EntryViews projects one Snapshot value onto its SPEC-002-R011 entries, in
// WarmModels order: a provider without a warm set (a one-member warm set is
// stored as none) yields exactly itself.
func EntryViews(session Provider) []Provider {
	if session.WarmModels == nil {
		return []Provider{session}
	}
	out := make([]Provider, 0, len(session.WarmModels))
	for _, m := range session.WarmModels {
		out = append(out, warmEntryView(session, m))
	}
	return out
}

// EntrySnapshot is Snapshot with one Provider value per SPEC-002-R011 entry:
// a provider without a warm set yields exactly its Snapshot value, and a
// provider with one of more than one member yields a view per member
// (ServedModelID set).
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
// resolves as Resolve does for an empty model or its own model (case-folded)
// and fails for any other; a provider with one resolves the member named by
// model (case-folded; empty is the primary) and fails when that model is not
// in its warm set.
func (r *Registry) ResolveEntry(providerID, assignedID, model string) (Provider, bool) {
	session, ok := r.Resolve(providerID, assignedID)
	if !ok {
		return session, ok
	}
	key := warmModelKey(model)
	if session.WarmModels == nil {
		if model != "" && key != warmModelKey(session.ModelID) {
			return Provider{}, false
		}
		return session, true
	}
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
	return r.consumeForwardedSlotForLocked(p, servedModelID)
}

// ConsumeForwardedSlotBooked is ConsumeForwardedSlotFor that also returns the
// served model every ending of the dispatch (RestoreForwardedSlotFor,
// DropForwardedInFlightFor, MarkForwardedSlotFullFor) must name. A dispatch
// without a served model is booked under the session's model when the
// session has a warm set (a session view, e.g. relay-blind or privacy class,
// reaches the primary and is counted there) or a drain record is open;
// otherwise, as on every legacy session, it stays empty.
func (r *Registry) ConsumeForwardedSlotBooked(providerID, assignedID, servedModelID string) (ok, unconfirmed bool, booked string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false, false, ""
	}
	booked = servedModelID
	if booked == "" && (p.WarmModels != nil || p.legacyDispatchOpen > 0) {
		booked = p.ModelID
	}
	ok, unconfirmed = r.consumeForwardedSlotForLocked(p, booked)
	return ok, unconfirmed, booked
}

func (r *Registry) consumeForwardedSlotForLocked(p *Provider, servedModelID string) (ok, unconfirmed bool) {
	switch idx := warmMemberIndexLocked(p, servedModelID); idx {
	case warmMemberSession:
		ok, unconfirmed = r.consumeForwardedSlotLocked(p)
		if ok && servedModelID == "" {
			p.emptyServedOpen++
		}
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
	switch idx := warmMemberIndexLocked(p, endedDispatchModelLocked(p, servedModelID)); idx {
	case warmMemberSession:
		return r.restoreForwardedSlotLocked(p)
	case warmMemberMissing:
		return false
	default:
		m := mutableWarmMemberLocked(p, idx)
		if m.forwardedInFlight == 0 {
			// A dispatch the member does not count (opened before the
			// member last joined a multi-model warm set) reopens no seat.
			return true
		}
		m.forwardedInFlight--
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
	switch idx := warmMemberIndexLocked(p, endedDispatchModelLocked(p, servedModelID)); idx {
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
// seats until a ready heartbeat reports a free seat for it; the primary and
// the session are untouched.
func (r *Registry) MarkForwardedSlotFullFor(providerID, assignedID, servedModelID string, refusedSeatConsumed bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	model := servedModelID
	if refusedSeatConsumed {
		model = endedDispatchModelLocked(p, servedModelID)
	}
	switch idx := warmMemberIndexLocked(p, model); idx {
	case warmMemberSession:
		return r.markForwardedSlotFullLocked(p, refusedSeatConsumed)
	case warmMemberMissing:
		return false
	default:
		m := mutableWarmMemberLocked(p, idx)
		if refusedSeatConsumed {
			if m.forwardedInFlight > 0 {
				m.forwardedInFlight--
			}
			if m.SlotsFree < m.SlotsTotal {
				m.SlotsFree++
			}
		}
		m.refusalHold = true
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
		if thermal || m.State != WarmModelWarm || m.notLoaded || m.refusalHold || m.SlotsFree < 0 {
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

// maxNotLoadedStrikes bounds one model's strike history.
const maxNotLoadedStrikes = 16

// MarkEntryNotLoaded records a provider's model_not_loaded answer for the
// entry serving servedModelID (SPEC-002-R011): that entry is unavailable
// until the next heartbeat replaces the warm set. The session, its other
// entries and Snapshot are untouched. A provider without a warm set, or a
// model no longer in it, is a no-op.
func (r *Registry) MarkEntryNotLoaded(providerID, assignedID, servedModelID string) bool {
	_, ok := r.RecordEntryNotLoaded(providerID, assignedID, servedModelID, time.Now(), 0)
	return ok
}

// RecordEntryNotLoaded is MarkEntryNotLoaded that also counts strikes: the
// first answer after a heartbeat advertised the entry warm is a strike at
// `at`; further answers before the next heartbeat (concurrent dispatches in
// the same race) are not. It returns the strikes within window (all kept
// strikes when window is 0).
//
// Strikes are the session's, per SanctionKey: only window ages them, and a
// member declared under another name of its catalog row keeps them.
// A member reporting another state, leaving and rejoining the warm set, or
// the session becoming a legacy session and a multi-model one again keeps
// them, so a provider cannot clear its strikes by cycling a member's state.
// A model gets an entry only when a member of the warm set serving it
// answers; every entry older than window is pruned at each answer.
func (r *Registry) RecordEntryNotLoaded(providerID, assignedID, servedModelID string, at time.Time, window time.Duration) (int, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || p.WarmModels == nil || servedModelID == "" {
		return 0, false
	}
	key := warmModelKey(servedModelID)
	for i := range p.WarmModels {
		if warmModelKey(p.WarmModels[i].ModelID) != key {
			continue
		}
		m := mutableWarmMemberLocked(p, i)
		strikes := make(map[string][]time.Time, len(p.notLoadedStrikes)+1)
		for model, times := range p.notLoadedStrikes {
			kept := make([]time.Time, 0, len(times)+1)
			for _, t := range times {
				if window <= 0 || t.After(at.Add(-window)) {
					kept = append(kept, t)
				}
			}
			if len(kept) > 0 {
				strikes[model] = kept
			}
		}
		strikeKey := r.SanctionKey(servedModelID)
		kept := strikes[strikeKey]
		if !m.notLoaded {
			kept = append(kept, at)
		}
		if len(kept) > maxNotLoadedStrikes {
			kept = kept[len(kept)-maxNotLoadedStrikes:]
		}
		if len(kept) > 0 {
			strikes[strikeKey] = kept
		}
		p.notLoadedStrikes = strikes
		m.notLoaded = true
		return len(kept), true
	}
	return 0, false
}
