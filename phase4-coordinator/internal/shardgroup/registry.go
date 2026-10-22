package shardgroup

import (
	"context"
	"encoding/base64"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Availability reason codes (SPEC-051-R015), in evaluation order.
const (
	ReasonHeadSessionInvalid    = "head_session_invalid"
	ReasonGroupNotRegistered    = "group_not_registered"
	ReasonMemberNotJoined       = "member_not_joined"
	ReasonMemberSessionMissing  = "member_session_missing"
	ReasonMemberNotAdmissible   = "member_not_admissible"
	ReasonTrustLabelAboveMember = "trust_label_above_member"
	ReasonGroupHeartbeatStale   = "group_heartbeat_stale"
	ReasonMemberUnhealthy       = "member_unhealthy"
	ReasonLinkInterfaceInvalid  = "link_interface_invalid"
	ReasonLinkRTTExceeded       = "link_rtt_exceeded"
	ReasonMemberHealthStale     = "member_health_stale"
	ReasonMemberSelfUnhealthy   = "member_self_unhealthy"
)

// Member hello reason codes (SPEC-051-R029).
const (
	ReasonInvalidHello      = "invalid_hello"
	ReasonNotMemberSession  = "not_member_session"
	ReasonEpochSuperseded   = "epoch_superseded"
	ReasonRecordMismatch    = "record_mismatch"
	ReasonWeightsUnverified = "weights_unverified"
)

// ReasonRegistrationRateLimited refuses a new epoch beyond the per-group
// registration budget (SPEC-051-R005).
const ReasonRegistrationRateLimited = "registration_rate_limited"

const (
	// maxNewEpochsPerWindow new epochs of one group are accepted per
	// newEpochWindow. Takeovers and rebuilds start a new epoch once per member
	// loss; anything faster is refused before the store is written.
	maxNewEpochsPerWindow = 12
	newEpochWindow        = time.Hour
	// retainedEpochs bounds the epochs a group keeps in memory for
	// attestation verification: the latest and the ones before it that an
	// in-flight request or a takeover can still name.
	retainedEpochs = 8
)

// maxReportedRTTUS bounds a reported link RTT (10 s) so a malformed value is
// refused rather than compared.
const maxReportedRTTUS = 10_000_000

// HeadSession is the registering head session as the coordinator sees it.
type HeadSession struct {
	ProviderID         string
	AssignedID         string
	ModelID            string
	ModelHashAlgorithm string
	ModelHash          string
	MaxConcurrency     int
	ReceiptKey         []byte
	ShardGroupHeadV1   bool
	ShardMemberV1      bool
	WSTunneled         bool
}

// MemberSession is a member session sending `shard_member_hello`.
type MemberSession struct {
	ProviderID    string
	AssignedID    string
	ReceiptKey    []byte
	ShardMemberV1 bool
}

// Outbound is one coordinator-to-provider group message to send.
type Outbound struct {
	ProviderID string
	AssignedID string
	Message    any
}

type joinedMember struct {
	assignedID string
	key        string
}

type epochState struct {
	record    Record
	stageKeys map[int]string
	joined    map[string]joinedMember
}

type groupState struct {
	headAssignedID string
	latest         uint64
	epochs         map[uint64]*epochState
	// newEpochsAt holds when each new epoch inside newEpochWindow was accepted.
	newEpochsAt []time.Time
	heartbeat   *Heartbeat
	heartbeatAt time.Time
	// memberHealth holds each member's latest own report for the latest epoch.
	memberHealth map[string]memberHealthReport
	evaluated    bool
	available    bool
	reason       string
}

type memberClaim struct {
	hello      MemberHello
	assignedID string
	key        string
}

// Registry is the coordinator's live SPEC-051 group state. It is safe for
// concurrent use.
type Registry struct {
	mu          sync.Mutex
	cfg         Config
	store       *Store
	now         func() time.Time
	groups      map[string]*groupState
	memberGroup map[string]string
	claims      map[string]memberClaim
}

// NewRegistry returns an empty registry over store.
func NewRegistry(cfg Config, store *Store, now func() time.Time) *Registry {
	if now == nil {
		now = time.Now
	}
	return &Registry{
		cfg:         cfg,
		store:       store,
		now:         now,
		groups:      make(map[string]*groupState),
		memberGroup: make(map[string]string),
		claims:      make(map[string]memberClaim),
	}
}

// Config returns the registry configuration.
func (r *Registry) Config() Config {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cfg
}

// SetConfig replaces the coordinator shard_groups values (SPEC-051 §4) on a
// configuration reload. Accepted records stay accepted; the next availability
// evaluation and every later registration apply the new values.
func (r *Registry) SetConfig(cfg Config) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cfg = cfg
}

func result(typ, groupID string, epoch uint64, reason string) Result {
	return Result{Type: typ, Version: WireVersion, GroupProviderID: groupID, GroupEpoch: epoch, Accepted: reason == "", Reason: reason}
}

// RecordIDs lists every identity a parsed record names (head first), for
// owner resolution before Register.
func RecordIDs(rec Record) []string {
	ids := make([]string, 0, len(rec.Stages)+len(rec.Spares))
	for _, st := range rec.Stages {
		ids = append(ids, st.MemberDeviceID)
	}
	for _, sp := range rec.Spares {
		ids = append(ids, sp.MemberDeviceID)
	}
	return ids
}

// Register applies `shard_group_register` from a head session. owners
// resolves each identity the record names to its SPEC-003 owner ("" when
// unclaimed); it is called only for a head session with a valid record and
// signature, so a refused registration never costs an owner lookup. It
// returns the register result for the head and any member hello results that
// the new record accepted.
func (r *Registry) Register(ctx context.Context, head HeadSession, payload []byte, resolveOwners func([]string) map[string]string) (Result, []Outbound) {
	msg, rec, err := ParseRegister(payload)
	if err != nil {
		return result(TypeRegisterResult, head.ProviderID, 0, ReasonInvalidRecord), nil
	}
	reject := func(reason string) (Result, []Outbound) {
		return result(TypeRegisterResult, rec.GroupProviderID, rec.GroupEpoch, reason), nil
	}
	if !head.ShardGroupHeadV1 || head.ShardMemberV1 || !head.WSTunneled {
		return reject(ReasonNotGroupHeadSession)
	}
	if reason := ValidateRecord(rec, r.Config(), HeadView{
		ProviderID:         head.ProviderID,
		ModelID:            head.ModelID,
		ModelHashAlgorithm: head.ModelHashAlgorithm,
		ModelHash:          head.ModelHash,
		MaxConcurrency:     head.MaxConcurrency,
	}); reason != "" {
		return reject(reason)
	}
	if !VerifyRecordSignature(msg.Record, msg.RecordSignature, head.ReceiptKey) {
		return reject(ReasonSignatureInvalid)
	}
	owners := resolveOwners(RecordIDs(rec))
	ownerID := owners[head.ProviderID]
	for _, id := range RecordIDs(rec) {
		if ownerID == "" || owners[id] != ownerID {
			return reject(ReasonOwnerMismatch)
		}
	}
	digest, err := RecordDigest(msg.Record)
	if err != nil {
		return reject(ReasonInvalidRecord)
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	for _, id := range RecordIDs(rec) {
		if g, ok := r.memberGroup[id]; ok && g != rec.GroupProviderID {
			return reject(ReasonMemberConflict)
		}
		if _, isGroup := r.groups[id]; isGroup && id != rec.GroupProviderID {
			return reject(ReasonMemberConflict)
		}
	}
	if g, ok := r.memberGroup[rec.GroupProviderID]; ok && g != rec.GroupProviderID {
		return reject(ReasonMemberConflict)
	}
	now := r.now()
	if g := r.groups[rec.GroupProviderID]; g != nil && rec.GroupEpoch != g.latest {
		recent := g.newEpochsAt[:0]
		for _, at := range g.newEpochsAt {
			if now.Sub(at) < newEpochWindow {
				recent = append(recent, at)
			}
		}
		g.newEpochsAt = recent
		if len(recent) >= maxNewEpochsPerWindow {
			return reject(ReasonRegistrationRateLimited)
		}
	}
	if _, err := r.store.AcceptRecord(ctx, StoredRecord{
		GroupProviderID: rec.GroupProviderID,
		GroupEpoch:      rec.GroupEpoch,
		RecordJSON:      string(msg.Record),
		RecordDigest:    digest,
		RecordSignature: msg.RecordSignature,
	}, r.now().UnixMilli()); err != nil {
		if errors.Is(err, ErrEpochNotIncreasing) {
			return reject(ReasonEpochNotIncreasing)
		}
		return reject(ReasonStoreUnavailable)
	}
	g := r.groups[rec.GroupProviderID]
	if g == nil {
		g = &groupState{epochs: make(map[uint64]*epochState)}
		r.groups[rec.GroupProviderID] = g
	}
	if previous, ok := g.epochs[g.latest]; ok && g.latest != rec.GroupEpoch {
		for _, id := range RecordIDs(previous.record) {
			if r.memberGroup[id] == rec.GroupProviderID {
				delete(r.memberGroup, id)
			}
		}
	}
	if g.latest != rec.GroupEpoch || g.headAssignedID != head.AssignedID {
		// A new epoch or a new head session needs a fresh group heartbeat.
		g.heartbeat, g.heartbeatAt = nil, time.Time{}
	}
	if g.latest != rec.GroupEpoch {
		// Member reports describe the previous epoch's chain.
		g.memberHealth = nil
		g.newEpochsAt = append(g.newEpochsAt, now)
	}
	g.headAssignedID = head.AssignedID
	g.latest = rec.GroupEpoch
	ep, ok := g.epochs[rec.GroupEpoch]
	if !ok {
		ep = &epochState{record: rec, joined: make(map[string]joinedMember)}
		g.epochs[rec.GroupEpoch] = ep
		evictOldEpochs(g)
	}
	ep.stageKeys = map[int]string{0: base64.StdEncoding.EncodeToString(head.ReceiptKey)}
	for id, joined := range ep.joined {
		if role, stage, ok := rec.role(id); ok && role == "stage" {
			ep.stageKeys[stage] = joined.key
		}
	}
	for _, id := range RecordIDs(rec) {
		r.memberGroup[id] = rec.GroupProviderID
	}
	var out []Outbound
	for _, id := range rec.MemberIDs() {
		claim, ok := r.claims[id]
		if !ok || claim.hello.GroupProviderID != rec.GroupProviderID || claim.hello.GroupEpoch != rec.GroupEpoch {
			continue
		}
		reason := r.bindClaimLocked(ctx, g, ep, claim)
		out = append(out, Outbound{ProviderID: id, AssignedID: claim.assignedID, Message: result(TypeMemberHelloResult, rec.GroupProviderID, rec.GroupEpoch, reason)})
	}
	return result(TypeRegisterResult, rec.GroupProviderID, rec.GroupEpoch, ""), out
}

// MemberHello applies `shard_member_hello` from a member session. A hello for
// an epoch not yet registered is kept and evaluated at registration.
func (r *Registry) MemberHello(ctx context.Context, member MemberSession, payload []byte) Result {
	hello, err := ParseMemberHello(payload)
	if err != nil {
		return result(TypeMemberHelloResult, "", 0, ReasonInvalidHello)
	}
	reject := func(reason string) Result {
		return result(TypeMemberHelloResult, hello.GroupProviderID, hello.GroupEpoch, reason)
	}
	if !member.ShardMemberV1 {
		return reject(ReasonNotMemberSession)
	}
	if hello.MemberDeviceID != member.ProviderID || hello.MemberDeviceID == hello.GroupProviderID ||
		(hello.Role != "stage" && hello.Role != "spare") || len(member.ReceiptKey) != 32 || hello.GroupEpoch < 1 || hello.GroupEpoch > maxJSONInteger {
		return reject(ReasonInvalidHello)
	}
	if !hello.WeightsVerified || !hello.StageFits {
		return reject(ReasonWeightsUnverified)
	}
	claim := memberClaim{hello: hello, assignedID: member.AssignedID, key: base64.StdEncoding.EncodeToString(member.ReceiptKey)}

	r.mu.Lock()
	defer r.mu.Unlock()
	if g, ok := r.memberGroup[hello.MemberDeviceID]; ok && g != hello.GroupProviderID {
		return reject(ReasonMemberConflict)
	}
	r.claims[hello.MemberDeviceID] = claim
	g := r.groups[hello.GroupProviderID]
	if g == nil || g.latest < hello.GroupEpoch {
		return reject(ReasonGroupNotRegistered)
	}
	if hello.GroupEpoch < g.latest {
		delete(r.claims, hello.MemberDeviceID)
		return reject(ReasonEpochSuperseded)
	}
	return reject(r.bindClaimLocked(ctx, g, g.epochs[g.latest], claim))
}

// bindClaimLocked checks a member claim against its epoch's record and, when
// it matches, binds the member's session and receipt key to that epoch.
func (r *Registry) bindClaimLocked(ctx context.Context, g *groupState, ep *epochState, claim memberClaim) string {
	hello, rec := claim.hello, ep.record
	role, stage, ok := rec.role(hello.MemberDeviceID)
	if !ok || role != hello.Role || stage != hello.StageIndex || stage == 0 {
		return ReasonRecordMismatch
	}
	st := rec.Stages[stage]
	if hello.LayerStart != st.LayerStart || hello.LayerEnd != st.LayerEnd || hello.TransportVersion != rec.TransportVersion ||
		hello.ArtifactHashAlgorithm != rec.Model.ArtifactHashAlgorithm || hello.ArtifactHash != rec.Model.ArtifactHash {
		return ReasonRecordMismatch
	}
	want := RequiredInterface(rec.InterconnectClass)
	reported := make(map[string]string, len(hello.Links))
	for _, link := range hello.Links {
		if _, dup := reported[link.PeerMemberDeviceID]; dup {
			return ReasonInvalidHello
		}
		reported[link.PeerMemberDeviceID] = link.InterfaceType
	}
	peers := rec.memberLinkPeers(hello.MemberDeviceID)
	if len(reported) != len(peers) {
		return ReasonRecordMismatch
	}
	for _, peer := range peers {
		iface, ok := reported[peer]
		if !ok {
			return ReasonRecordMismatch
		}
		if iface != want {
			return ReasonLinkInterfaceInvalid
		}
	}
	if err := r.store.BindMember(ctx, MemberBinding{
		GroupProviderID:  rec.GroupProviderID,
		GroupEpoch:       rec.GroupEpoch,
		MemberDeviceID:   hello.MemberDeviceID,
		Role:             role,
		StageIndex:       stage,
		ReceiptPublicKey: claim.key,
	}, r.now().UnixMilli()); err != nil {
		return ReasonStoreUnavailable
	}
	if previous, ok := ep.joined[hello.MemberDeviceID]; ok && (previous.assignedID != claim.assignedID || previous.key != claim.key) {
		// SPEC-051-R015 item 8: a report counts only from the session whose
		// hello is accepted; the replaced session's report is not its health.
		if g.latest == rec.GroupEpoch {
			delete(g.memberHealth, hello.MemberDeviceID)
		}
	}
	ep.joined[hello.MemberDeviceID] = joinedMember{assignedID: claim.assignedID, key: claim.key}
	if role == "stage" {
		ep.stageKeys[stage] = claim.key
	}
	return ""
}

// Heartbeat applies `shard_group_heartbeat` from the head session. It reports
// false when the heartbeat does not belong to the group's current head
// session and latest epoch or does not list exactly the record's members and
// required links; such a heartbeat is dropped.
func (r *Registry) Heartbeat(providerID, assignedID string, payload []byte) bool {
	hb, err := ParseHeartbeat(payload)
	if err != nil || hb.GroupProviderID != providerID {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	g := r.groups[providerID]
	if g == nil || g.headAssignedID != assignedID || hb.GroupEpoch != g.latest {
		return false
	}
	rec := g.epochs[g.latest].record
	wantMembers := RecordIDs(rec)
	if len(hb.Members) != len(wantMembers) {
		return false
	}
	seen := make(map[string]bool, len(hb.Members))
	for _, m := range hb.Members {
		if seen[m.MemberDeviceID] {
			return false
		}
		seen[m.MemberDeviceID] = true
	}
	for _, id := range wantMembers {
		if !seen[id] {
			return false
		}
	}
	links := rec.requiredLinks()
	if len(hb.Links) != len(links) {
		return false
	}
	have := make(map[[2]string]bool, len(hb.Links))
	for _, l := range hb.Links {
		key := [2]string{l.FromMemberDeviceID, l.ToMemberDeviceID}
		if have[key] || l.RTTP99US > maxReportedRTTUS {
			return false
		}
		have[key] = true
	}
	for _, key := range links {
		if !have[key] {
			return false
		}
	}
	g.heartbeat = &hb
	g.heartbeatAt = r.now()
	return true
}

type memberHealthReport struct {
	report MemberHealth
	at     time.Time
	// assignedID is the member session the report came from; it counts only
	// while that session is still the one the member's hello bound.
	assignedID string
}

// MemberHealth applies `shard_member_health` from a member session. It
// returns the member's group and whether the report was kept: only a member
// of the group's latest epoch, on the session its hello was accepted from,
// reporting exactly its stage links, is kept.
func (r *Registry) MemberHealth(member MemberSession, payload []byte) (string, bool) {
	report, err := ParseMemberHealth(payload)
	if err != nil || report.MemberDeviceID != member.ProviderID || !member.ShardMemberV1 {
		return "", false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	g := r.groups[report.GroupProviderID]
	if g == nil || report.GroupEpoch != g.latest {
		return "", false
	}
	ep := g.epochs[g.latest]
	joined, ok := ep.joined[report.MemberDeviceID]
	if !ok || joined.assignedID != member.AssignedID {
		return "", false
	}
	peers := ep.record.memberLinkPeers(report.MemberDeviceID)
	if len(report.Links) != len(peers) {
		return "", false
	}
	seen := make(map[string]bool, len(report.Links))
	for _, l := range report.Links {
		if seen[l.PeerMemberDeviceID] || l.RTTP99US > maxReportedRTTUS {
			return "", false
		}
		seen[l.PeerMemberDeviceID] = true
	}
	for _, p := range peers {
		if !seen[p] {
			return "", false
		}
	}
	if g.memberHealth == nil {
		g.memberHealth = make(map[string]memberHealthReport)
	}
	g.memberHealth[report.MemberDeviceID] = memberHealthReport{report: report, at: r.now(), assignedID: member.AssignedID}
	return report.GroupProviderID, true
}

// GroupFor returns the group an identity heads or belongs to.
func (r *Registry) GroupFor(providerID string) (string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.groups[providerID]; ok {
		return providerID, true
	}
	g, ok := r.memberGroup[providerID]
	return g, ok
}

// GroupIDs lists every known group, sorted.
func (r *Registry) GroupIDs() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.groups))
	for id := range r.groups {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// MemberIDs lists the identities of a group's latest record, head first.
func (r *Registry) MemberIDs(groupID string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	g := r.groups[groupID]
	if g == nil {
		return nil
	}
	return RecordIDs(g.epochs[g.latest].record)
}

// Epochs returns an accepted epoch of a group with its bound stage keys, for
// attestation verification.
func (r *Registry) Epochs(groupID string) func(uint64) (EpochKeys, bool) {
	return func(epoch uint64) (EpochKeys, bool) {
		r.mu.Lock()
		defer r.mu.Unlock()
		g := r.groups[groupID]
		if g == nil {
			return EpochKeys{}, false
		}
		ep, ok := g.epochs[epoch]
		if !ok {
			return EpochKeys{}, false
		}
		keys := make(map[int]string, len(ep.stageKeys))
		for k, v := range ep.stageKeys {
			keys[k] = v
		}
		return EpochKeys{Record: ep.record, StageKeys: keys}, true
	}
}

// Evaluation is one group's SPEC-051-R015 availability.
type Evaluation struct {
	GroupProviderID string
	HeadAssignedID  string
	GroupEpoch      uint64
	// PoolModelID is the pool model the latest accepted record names; the
	// head routes only for it (SPEC-051-R016).
	PoolModelID string
	Available   bool
	Reason      string
	Members     []pool.ShardGroupMemberView
	// Changed reports a change of availability or reason since the last
	// evaluation, when the head must be sent `shard_group_status`.
	Changed bool
}

// Evaluate computes a group's availability from the live provider sessions
// (providers), each identity's SPEC-003 owner (owners), and the coordinator
// heartbeat interval.
func (r *Registry) Evaluate(groupID string, providers func(string) (pool.Provider, bool), owners map[string]string, heartbeatInterval time.Duration) (Evaluation, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	g := r.groups[groupID]
	if g == nil {
		return Evaluation{}, false
	}
	ev := Evaluation{GroupProviderID: groupID, HeadAssignedID: g.headAssignedID, GroupEpoch: g.latest}
	if ep, ok := g.epochs[g.latest]; ok {
		ev.PoolModelID = ep.record.Model.PoolModelID
	}
	ev.Reason, ev.Members = r.evaluateLocked(groupID, g, providers, owners, heartbeatInterval)
	ev.Available = ev.Reason == ""
	if !ev.Available {
		ev.Members = nil
	}
	ev.Changed = !g.evaluated || g.available != ev.Available || g.reason != ev.Reason
	g.evaluated, g.available, g.reason = true, ev.Available, ev.Reason
	return ev, true
}

func (r *Registry) evaluateLocked(groupID string, g *groupState, providers func(string) (pool.Provider, bool), owners map[string]string, heartbeatInterval time.Duration) (string, []pool.ShardGroupMemberView) {
	ep, ok := g.epochs[g.latest]
	if !ok {
		return ReasonGroupNotRegistered, nil
	}
	rec := ep.record
	head, ok := providers(groupID)
	if !ok || head.AssignedID != g.headAssignedID || !head.ShardGroupHeadV1 || head.ShardMemberV1 || !head.IsWSTunneled() ||
		head.ModelHashAlgorithm != rec.Model.ArtifactHashAlgorithm || head.ModelHash != rec.Model.ArtifactHash ||
		base64.StdEncoding.EncodeToString(head.ReceiptPubkey) != ep.stageKeys[0] {
		return ReasonHeadSessionInvalid, nil
	}
	active := make([]pool.Provider, 0, len(rec.Stages)-1)
	for _, st := range rec.Stages[1:] {
		joined, ok := ep.joined[st.MemberDeviceID]
		if !ok {
			return ReasonMemberNotJoined, nil
		}
		p, ok := providers(st.MemberDeviceID)
		if !ok || p.AssignedID != joined.assignedID || !p.ShardMemberV1 || base64.StdEncoding.EncodeToString(p.ReceiptPubkey) != joined.key {
			return ReasonMemberSessionMissing, nil
		}
		active = append(active, p)
	}
	if !head.ShardMemberAdmissible() || len(head.ReceiptPubkey) == 0 {
		return ReasonMemberNotAdmissible, nil
	}
	for _, p := range active {
		if reason := memberReservable(head, p); reason != "" {
			return reason, nil
		}
	}
	// SPEC-051-R003/R004: a spare with a live member session passes the same
	// admission, artifact and minimum-label checks. A spare without one cannot
	// take over; that is replay readiness, not availability (R015).
	for _, sp := range rec.Spares {
		if p, ok := providers(sp.MemberDeviceID); ok && p.ShardMemberV1 {
			if reason := memberReservable(head, p); reason != "" {
				return reason, nil
			}
		}
	}
	ownerID := owners[groupID]
	for _, id := range RecordIDs(rec) {
		if ownerID == "" || owners[id] != ownerID {
			return ReasonOwnerMismatch, nil
		}
	}
	stale := time.Duration(r.cfg.GroupHeartbeatStaleMultiple) * heartbeatInterval
	if g.heartbeat == nil || r.now().Sub(g.heartbeatAt) > stale {
		return ReasonGroupHeartbeatStale, nil
	}
	healthy := make(map[string]bool, len(g.heartbeat.Members))
	for _, m := range g.heartbeat.Members {
		healthy[m.MemberDeviceID] = m.Healthy
	}
	for _, st := range rec.Stages {
		if !healthy[st.MemberDeviceID] {
			return ReasonMemberUnhealthy, nil
		}
	}
	want := RequiredInterface(rec.InterconnectClass)
	spares := make(map[string]bool, len(rec.Spares))
	for _, sp := range rec.Spares {
		spares[sp.MemberDeviceID] = true
	}
	for _, l := range g.heartbeat.Links {
		// SPEC-051-R015: a spare's health affects only whether replay is possible.
		// An unreachable spare's link has no interface to report; a reachable
		// spare's link must still be wired (SPEC-051-R007).
		if spares[l.ToMemberDeviceID] && !healthy[l.ToMemberDeviceID] {
			continue
		}
		if l.InterfaceType != want {
			return ReasonLinkInterfaceInvalid, nil
		}
	}
	for _, l := range g.heartbeat.Links {
		if !spares[l.ToMemberDeviceID] && l.RTTP99US > r.cfg.MaxLinkRTTP99US {
			return ReasonLinkRTTExceeded, nil
		}
	}
	// 8. Every active non-head member's own report for this epoch is current
	// and healthy, and its links meet SPEC-051-R007 as it measures them.
	for _, st := range rec.Stages[1:] {
		h, ok := g.memberHealth[st.MemberDeviceID]
		if !ok || h.report.GroupEpoch != g.latest || h.assignedID != ep.joined[st.MemberDeviceID].assignedID || r.now().Sub(h.at) > stale {
			return ReasonMemberHealthStale, nil
		}
		if !h.report.Healthy {
			return ReasonMemberSelfUnhealthy, nil
		}
	}
	for _, st := range rec.Stages[1:] {
		for _, l := range g.memberHealth[st.MemberDeviceID].report.Links {
			if l.InterfaceType != want {
				return ReasonLinkInterfaceInvalid, nil
			}
			if l.RTTP99US > r.cfg.MaxLinkRTTP99US {
				return ReasonLinkRTTExceeded, nil
			}
		}
	}
	views := make([]pool.ShardGroupMemberView, 0, len(active)+len(rec.Spares))
	for _, p := range active {
		views = append(views, pool.ShardGroupMemberView{ProviderID: p.ProviderID, AssignedID: p.AssignedID, BinaryVersion: p.BinaryVersion})
	}
	for _, sp := range rec.Spares {
		view := pool.ShardGroupMemberView{ProviderID: sp.MemberDeviceID, Spare: true}
		if p, ok := providers(sp.MemberDeviceID); ok {
			view.BinaryVersion = p.BinaryVersion
			if p.ShardMemberV1 {
				view.AssignedID = p.AssignedID
			}
		}
		views = append(views, view)
	}
	return "", views
}

// evictOldEpochs keeps the latest retainedEpochs epochs of a group in memory.
// Older records stay in the append-only store and keep the epoch floor there.
func evictOldEpochs(g *groupState) {
	if len(g.epochs) <= retainedEpochs {
		return
	}
	epochs := make([]uint64, 0, len(g.epochs))
	for epoch := range g.epochs {
		epochs = append(epochs, epoch)
	}
	sort.Slice(epochs, func(i, j int) bool { return epochs[i] < epochs[j] })
	for _, epoch := range epochs[:len(epochs)-retainedEpochs] {
		delete(g.epochs, epoch)
	}
}

// memberReservable applies the per-member gates of SPEC-051-R015 conditions
// 3 to 5 that can change between evaluations: the member passes every
// single-provider routing-state gate, publishes a receipt key, serves the
// head's model pair (SPEC-051-R003, R008) and holds at least the head's trust
// labels (SPEC-051-R004). It returns the failing reason code, or "".
func memberReservable(head, member pool.Provider) string {
	if !member.ShardMemberAdmissible() || len(member.ReceiptPubkey) == 0 ||
		member.ModelHashAlgorithm != head.ModelHashAlgorithm || !strings.EqualFold(strings.TrimSpace(member.ModelHash), strings.TrimSpace(head.ModelHash)) {
		return ReasonMemberNotAdmissible
	}
	if !labelsAtLeast(member, head) {
		return ReasonTrustLabelAboveMember
	}
	return ""
}

// MemberReservable re-checks one active member of an available group at
// reservation (SPEC-051-R003/R004/R015 "before the next reservation"): the
// member session the evaluation recorded is still live and still passes
// memberReservable against the head.
func MemberReservable(head pool.Provider, view pool.ShardGroupMemberView, resolve func(id string) (pool.Provider, bool)) bool {
	member, ok := resolve(view.ProviderID)
	if view.Spare {
		// A spare without a live member session only cannot take over; one
		// with a session must still pass admission and minimum labels.
		return !ok || !member.ShardMemberV1 || memberReservable(head, member) == ""
	}
	return ok && member.AssignedID == view.AssignedID && member.ShardMemberV1 && memberReservable(head, member) == ""
}

var tierRank = map[pool.Tier]int{pool.TierRejected: 0, pool.TierProvisional: 1, pool.TierTrusted: 2, pool.TierPinned: 3}

var attestationTierRank = map[string]int{"": 0, pool.AttestationTierSelfSigned: 1, pool.AttestationTierHardware: 2}

// labelsAtLeast reports whether member holds at least the head's value of
// every ordered trust label the routing path reads (SPEC-051-R004): provider
// tier, attestation tier, encrypted leg, and attested status.
func labelsAtLeast(member, head pool.Provider) bool {
	mt, okM := tierRank[member.Tier]
	ht, okH := tierRank[head.Tier]
	if !okM || !okH || mt < ht {
		return false
	}
	ma, okM := attestationTierRank[member.AttestationTier]
	ha, okH := attestationTierRank[head.AttestationTier]
	if !okM || !okH || ma < ha {
		return false
	}
	if head.EncryptedLeg && !member.EncryptedLeg {
		return false
	}
	if head.AttestationStatus == pool.AttestationStatusAttested && member.AttestationStatus != pool.AttestationStatusAttested {
		return false
	}
	return true
}

// Status builds the `shard_group_status` message of an evaluation.
func (ev Evaluation) Status() Status {
	return Status{Type: TypeStatus, Version: WireVersion, GroupProviderID: ev.GroupProviderID, GroupEpoch: ev.GroupEpoch, Available: ev.Available, Reason: ev.Reason}
}
