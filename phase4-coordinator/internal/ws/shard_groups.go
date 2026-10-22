package ws

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/shardgroup"
)

// SPEC-051 multi-Mac shard groups: the coordinator half of the group wire
// messages (SPEC-051-R029), group availability (SPEC-051-R015) and group
// attestation verification (SPEC-051-R019).

const (
	// shardGroupSweepInterval is the SPEC-051-R015 "at least once per
	// second" availability re-evaluation.
	shardGroupSweepInterval = time.Second
	// shardGroupOwnerTTL bounds how long a resolved SPEC-003 owner is reused
	// before it is read again (SPEC-051-R001 ownership changes).
	shardGroupOwnerTTL = 30 * time.Second
)

// ShardGroupOwnerLookup resolves a provider's SPEC-003 owner key. A claimed
// provider resolves to "github:<id>"; any other value means unclaimed.
type ShardGroupOwnerLookup interface {
	ProviderOperatorKey(ctx context.Context, providerID string) (string, error)
}

type shardGroupWiring struct {
	registry *shardgroup.Registry
	store    *shardgroup.Store
	owners   ShardGroupOwnerLookup

	ownerMu    sync.Mutex
	ownerCache map[string]shardGroupOwnerEntry

	// evalMu serializes evaluate-then-publish so an older evaluation can
	// never overwrite a newer one on the head session.
	evalMu sync.Mutex
}

type shardGroupOwnerEntry struct {
	owner   string
	fetched time.Time
}

// WithShardGroups wires the SPEC-051 group registry, its store, and the
// SPEC-003 owner lookup. Without it the coordinator ignores group messages,
// so a head session never becomes available and stays unroutable
// (SPEC-051-R027), and member sessions stay unroutable.
func WithShardGroups(registry *shardgroup.Registry, store *shardgroup.Store, owners ShardGroupOwnerLookup) Option {
	return func(s *Server) {
		if registry == nil || store == nil || owners == nil {
			return
		}
		s.shardGroups = &shardGroupWiring{registry: registry, store: store, owners: owners, ownerCache: make(map[string]shardGroupOwnerEntry)}
	}
}

// shardGroupOwners resolves each identity's owner through a short-lived cache.
// An unclaimed identity or a failed read resolves to "", which fails the
// owner-equality checks closed.
func (s *Server) shardGroupOwners(ctx context.Context, ids []string) map[string]string {
	w := s.shardGroups
	out := make(map[string]string, len(ids))
	now := s.now()
	for _, id := range ids {
		w.ownerMu.Lock()
		entry, ok := w.ownerCache[id]
		w.ownerMu.Unlock()
		if !ok || now.Sub(entry.fetched) > shardGroupOwnerTTL {
			key, err := w.owners.ProviderOperatorKey(ctx, id)
			owner := ""
			if err == nil && strings.HasPrefix(key, "github:") {
				owner = key
			}
			entry = shardGroupOwnerEntry{owner: owner, fetched: now}
			if err == nil {
				w.ownerMu.Lock()
				w.ownerCache[id] = entry
				w.ownerMu.Unlock()
			}
		}
		out[id] = entry.owner
	}
	return out
}

// sendShardGroupMessage marshals and sends one group message to a session.
func (s *Server) sendShardGroupMessage(providerID, assignedID string, message any) {
	raw, err := json.Marshal(message)
	if err != nil {
		return
	}
	session, ok := s.storedSessionFor(providerID, assignedID)
	if !ok {
		return
	}
	if err := session.send(raw); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("shard group message send failed")
	}
}

func (s *Server) handleShardGroupRegister(providerID, assignedID string, payload []byte) {
	w := s.shardGroups
	if w == nil {
		return
	}
	live, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var owners map[string]string
	if _, rec, err := shardgroup.ParseRegister(payload); err == nil {
		owners = s.shardGroupOwners(ctx, shardgroup.RecordIDs(rec))
	}
	res, memberResults := w.registry.Register(ctx, shardgroup.HeadSession{
		ProviderID:         providerID,
		AssignedID:         assignedID,
		ModelID:            live.ModelID,
		ModelHashAlgorithm: live.ModelHashAlgorithm,
		ModelHash:          strings.ToLower(strings.TrimSpace(live.ModelHash)),
		MaxConcurrency:     live.MaxConcurrency,
		ReceiptKey:         live.ReceiptPubkey,
		ShardGroupHeadV1:   live.ShardGroupHeadV1,
		ShardMemberV1:      live.ShardMemberV1,
		WSTunneled:         live.IsWSTunneled(),
	}, payload, owners)
	s.log.Info().
		Str("event", "shard_group_register").
		Str("provider_id", providerID).
		Uint64("group_epoch", res.GroupEpoch).
		Bool("accepted", res.Accepted).
		Str("reason", res.Reason).
		Msg("shard group registration")
	s.sendShardGroupMessage(providerID, assignedID, res)
	for _, out := range memberResults {
		s.sendShardGroupMessage(out.ProviderID, out.AssignedID, out.Message)
	}
	if res.Accepted {
		s.reevaluateShardGroup(ctx, providerID)
	}
}

func (s *Server) handleShardMemberHello(providerID, assignedID string, payload []byte) {
	w := s.shardGroups
	if w == nil {
		return
	}
	live, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res := w.registry.MemberHello(ctx, shardgroup.MemberSession{
		ProviderID:    providerID,
		AssignedID:    assignedID,
		ReceiptKey:    live.ReceiptPubkey,
		ShardMemberV1: live.ShardMemberV1,
	}, payload)
	s.log.Info().
		Str("event", "shard_member_hello").
		Str("provider_id", providerID).
		Uint64("group_epoch", res.GroupEpoch).
		Bool("accepted", res.Accepted).
		Str("reason", res.Reason).
		Msg("shard group member hello")
	s.sendShardGroupMessage(providerID, assignedID, res)
	if res.Accepted {
		s.reevaluateShardGroup(ctx, res.GroupProviderID)
	}
}

func (s *Server) handleShardGroupHeartbeat(providerID, assignedID string, payload []byte) {
	w := s.shardGroups
	if w == nil {
		return
	}
	if !w.registry.Heartbeat(providerID, assignedID, payload) {
		s.log.Warn().Str("provider_id", providerID).Msg("shard group heartbeat dropped")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s.reevaluateShardGroup(ctx, providerID)
}

// shardGroupSessionChanged re-evaluates the group an identity heads or
// belongs to after one of its sessions changed (disconnect).
func (s *Server) shardGroupSessionChanged(providerID string) {
	w := s.shardGroups
	if w == nil {
		return
	}
	groupID, ok := w.registry.GroupFor(providerID)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s.reevaluateShardGroup(ctx, groupID)
}

// reevaluateShardGroup applies SPEC-051-R015 to one group, records the result
// on the head session for routing, and sends `shard_group_status` on change.
func (s *Server) reevaluateShardGroup(ctx context.Context, groupID string) {
	w := s.shardGroups
	owners := s.shardGroupOwners(ctx, w.registry.MemberIDs(groupID))
	w.evalMu.Lock()
	defer w.evalMu.Unlock()
	ev, ok := w.registry.Evaluate(groupID, func(id string) (pool.Provider, bool) {
		return s.pool.Resolve(id, "")
	}, owners, s.cfg.HeartbeatInterval())
	if !ok {
		return
	}
	s.pool.SetShardGroupState(groupID, ev.HeadAssignedID, ev.Available, ev.GroupEpoch, ev.Members)
	if ev.Changed {
		s.log.Info().
			Str("event", "shard_group_status").
			Str("provider_id", groupID).
			Uint64("group_epoch", ev.GroupEpoch).
			Bool("available", ev.Available).
			Str("reason", ev.Reason).
			Msg("shard group availability changed")
		s.sendShardGroupMessage(groupID, ev.HeadAssignedID, ev.Status())
	}
}

// RunShardGroupSweep re-evaluates every group at least once per second
// (SPEC-051-R015), so a stale group heartbeat or a member state change makes
// the group unavailable before the next reservation even without a message.
func (s *Server) RunShardGroupSweep(ctx context.Context) {
	if s.shardGroups == nil {
		return
	}
	ticker := time.NewTicker(shardGroupSweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			for _, groupID := range s.shardGroups.registry.GroupIDs() {
				s.reevaluateShardGroup(ctx, groupID)
			}
		}
	}
}

// applyShardGroupAttestation enforces SPEC-051-R019 on a head session's
// terminal frame. A frame without a receipt is returned unchanged. With a
// receipt, the attestation is verified and stored; on any failure the
// verdict names the faulty member and the receipt is dropped, so the attempt
// settles as a SPEC-022 attempt without a receipt.
func (s *Server) applyShardGroupAttestation(providerID, assignedID string, end InferenceResponseEnd) InferenceResponseEnd {
	if end.Receipt == "" {
		end.GroupAttestation = nil
		return end
	}
	live, ok := s.pool.Resolve(providerID, assignedID)
	if !ok || !live.ShardGroupHeadV1 {
		return end
	}
	w := s.shardGroups
	if w == nil {
		end.Receipt, end.GroupAttestation = "", nil
		return end
	}
	verdict := shardgroup.VerifyAttestation(end.GroupAttestation, end.Receipt, providerID, live.ReceiptPubkey, w.registry.Epochs(providerID))
	requestID := verdict.RequestID
	if requestID == "" {
		requestID = end.RequestID
	}
	record := shardgroup.AttestationRecord{
		RequestID:           requestID,
		AttemptN:            verdict.AttemptN,
		GroupProviderID:     providerID,
		ReceiptTupleSHA256:  verdict.ReceiptTupleSHA256,
		Verified:            verdict.Verified(),
		FaultKind:           verdict.FaultKind,
		FaultMemberDeviceID: verdict.FaultMemberDeviceID,
		AttestationJSON:     string(end.GroupAttestation),
		TakeoverFromEpoch:   verdict.TakeoverFromEpoch,
		TakeoverReason:      verdict.TakeoverReason,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := w.store.RecordAttestation(ctx, record, s.now().UnixMilli()); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Str("request_id", end.RequestID).Msg("shard group attestation store failed")
		end.Receipt = ""
	}
	if !verdict.Verified() {
		s.log.Warn().
			Str("event", "shard_group_attestation_failed").
			Str("provider_id", providerID).
			Str("request_id", end.RequestID).
			Str("fault_kind", verdict.FaultKind).
			Str("fault_member_device_id", verdict.FaultMemberDeviceID).
			Msg("shard group attestation failed; receipt dropped")
		end.Receipt = ""
	}
	end.GroupAttestation = nil
	return end
}
