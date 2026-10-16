package ws

import (
	"context"
	"encoding/json"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/fleetcache"
)

type conversationCachePurge struct {
	Type            string `json:"type"`
	PurgeID         string `json:"purge_id"`
	ConversationKey string `json:"conversation_key"`
	Generation      int64  `json:"generation"`
}

type conversationCachePurgeAck struct {
	Type            string `json:"type"`
	PurgeID         string `json:"purge_id"`
	ConversationKey string `json:"conversation_key"`
	Generation      int64  `json:"generation"`
	Purged          bool   `json:"purged"`
}

const fleetCachePurgeRetryInterval = 30 * time.Second

func (s *Server) runFleetCachePurgeLoop() {
	ticker := time.NewTicker(fleetCachePurgeRetryInterval)
	defer ticker.Stop()
	for range ticker.C {
		for _, provider := range s.pool.Snapshot() {
			if provider.FleetCacheProtocol >= 1 {
				s.replayConversationCachePurges(provider.ProviderID, provider.AssignedID)
			}
		}
	}
}

// DispatchConversationCachePurge attempts immediate delivery. Durable state is
// authoritative: an offline/backpressured provider gets the same command after
// reconnect, and the obligation remains until a matching session ACK lands.
func (s *Server) DispatchConversationCachePurge(purge fleetcache.Purge) {
	provider, ok := s.pool.Resolve(purge.ProviderID, "")
	if !ok || provider.FleetCacheProtocol < 1 {
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}
	raw, err := json.Marshal(conversationCachePurge{
		Type: "conversation_cache_purge", PurgeID: purge.PurgeID,
		ConversationKey: purge.ConversationKey, Generation: purge.Generation,
	})
	if err != nil {
		return
	}
	if err := session.send(raw); err != nil {
		s.log.Warn().Err(err).Str("provider_id", purge.ProviderID).Str("purge_id", purge.PurgeID).Msg("conversation cache purge delivery deferred")
	}
}

func (s *Server) replayConversationCachePurges(providerID, assignedID string) {
	if s.fleetCache == nil {
		return
	}
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok || provider.FleetCacheProtocol < 1 {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pending, err := s.fleetCache.PendingForProvider(ctx, providerID)
	if err != nil {
		s.log.Error().Err(err).Str("provider_id", providerID).Msg("conversation cache purge replay unavailable")
		return
	}
	for _, purge := range pending {
		s.DispatchConversationCachePurge(purge)
	}
}

func (s *Server) handleConversationCachePurgeAck(providerID, assignedID string, payload []byte) {
	if s.fleetCache == nil {
		return
	}
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok || provider.FleetCacheProtocol < 1 {
		return
	}
	var ack conversationCachePurgeAck
	if err := json.Unmarshal(payload, &ack); err != nil || ack.Type != "conversation_cache_purge_ack" || ack.PurgeID == "" || ack.ConversationKey == "" || ack.Generation < 1 {
		s.log.Warn().Str("provider_id", providerID).Msg("invalid conversation cache purge acknowledgement")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	matched, err := s.fleetCache.Ack(ctx, providerID, fleetcache.Purge{
		PurgeID: ack.PurgeID, ProviderID: providerID,
		ConversationKey: ack.ConversationKey, Generation: ack.Generation,
	}, ack.Purged)
	if err != nil {
		s.log.Error().Err(err).Str("provider_id", providerID).Str("purge_id", ack.PurgeID).Msg("conversation cache purge acknowledgement persistence failed")
		return
	}
	if !matched {
		s.log.Warn().Str("provider_id", providerID).Str("purge_id", ack.PurgeID).Bool("purged", ack.Purged).Msg("conversation cache purge acknowledgement did not match pending command")
	}
}
