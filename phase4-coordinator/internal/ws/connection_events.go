package ws

import (
	"context"
	"net"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	gobwas "github.com/gobwas/ws"
)

// ConnectionEventStore is the durable Partial #535 journal seam.
type ConnectionEventStore interface {
	Record(ctx context.Context, event providerevents.Event) error
	UpsertLastKnown(ctx context.Context, snap providerevents.LastKnown) error
	GetLastKnown(ctx context.Context, providerID string) (providerevents.LastKnown, bool, error)
	ListLastKnown(ctx context.Context) ([]providerevents.LastKnown, error)
	ListEvents(ctx context.Context, providerID string, limit int) ([]providerevents.Event, error)
}

// ConnectionEventMetrics is the optional Prometheus seam for close-set outcomes.
type ConnectionEventMetrics interface {
	IncProviderConnectionEvent(kind, outcome, failureReason string)
}

type closeEventMeta struct {
	providerID    string
	sessionID     string
	attemptID     string
	authStage     string
	messageFamily string
	binaryVersion string
	diagnostic    string
}

func WithConnectionEventStore(store ConnectionEventStore) Option {
	return func(s *Server) {
		s.connectionEvents = store
	}
}

func WithConnectionEventMetrics(metrics ConnectionEventMetrics) Option {
	return func(s *Server) {
		s.connectionEventMetrics = metrics
	}
}

func (s *Server) rememberCloseEvent(conn net.Conn, meta closeEventMeta) {
	if s == nil || conn == nil {
		return
	}
	s.closeEventMeta.Store(conn, meta)
}

func (s *Server) takeCloseEvent(conn net.Conn) closeEventMeta {
	if s == nil || conn == nil {
		return closeEventMeta{}
	}
	if raw, ok := s.closeEventMeta.LoadAndDelete(conn); ok {
		if meta, ok := raw.(closeEventMeta); ok {
			return meta
		}
	}
	return closeEventMeta{}
}

func (s *Server) recordConnectionEvent(event providerevents.Event) {
	if s == nil || s.connectionEvents == nil {
		return
	}
	if event.OccurredAt.IsZero() {
		event.OccurredAt = s.now().UTC()
	}
	if event.FailureReason != "" {
		event.FailureReason = providerevents.NormalizeFailureReason(event.FailureReason)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.connectionEvents.Record(ctx, event); err != nil {
		s.log.Warn().Err(err).
			Str("provider_id", event.ProviderID).
			Str("kind", event.Kind).
			Msg("provider connection event persistence failed")
	}
	if s.connectionEventMetrics != nil {
		s.connectionEventMetrics.IncProviderConnectionEvent(event.Kind, event.Outcome, event.FailureReason)
	}
}

func (s *Server) recordCloseEvent(conn net.Conn, code gobwas.StatusCode, reason string) {
	meta := s.takeCloseEvent(conn)
	failure := providerevents.NormalizeFailureReason(reason)
	kind := providerevents.KindAuthRejected
	stage := meta.authStage
	if stage == "" {
		stage = providerevents.AuthStageFirstMessage
	}
	switch failure {
	case providerevents.ReasonUpgradeFailed:
		kind = providerevents.KindUpgradeFailed
		stage = providerevents.AuthStageUpgrade
	case providerevents.ReasonProviderWebsocketDisconnected:
		kind = providerevents.KindDisconnect
		stage = providerevents.AuthStagePostAuth
	case providerevents.ReasonHeartbeatStale:
		kind = providerevents.KindHeartbeatStale
		stage = providerevents.AuthStageLiveness
	case providerevents.ReasonWarmupFailed:
		kind = providerevents.KindWarmupFailed
		stage = providerevents.AuthStageWarmup
	}
	family := meta.messageFamily
	if family == "" {
		family = providerevents.MessageFamilyNone
	}
	s.recordConnectionEvent(providerevents.Event{
		ProviderID:    meta.providerID,
		SessionID:     meta.sessionID,
		AttemptID:     meta.attemptID,
		Kind:          kind,
		Outcome:       providerevents.OutcomeFailure,
		FailureReason: failure,
		AuthStage:     stage,
		MessageFamily: family,
		BinaryVersion: meta.binaryVersion,
		CloseCode:     int(code),
		CloseReason:   reason,
		Diagnostic:    meta.diagnostic,
	})
}

func (s *Server) rememberProviderSnapshot(provider pool.Provider) {
	if s == nil || s.connectionEvents == nil || strings.TrimSpace(provider.ProviderID) == "" {
		return
	}
	snap := lastKnownFromProvider(provider, s.now().UTC())
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.connectionEvents.UpsertLastKnown(ctx, snap); err != nil {
		s.log.Warn().Err(err).
			Str("provider_id", provider.ProviderID).
			Msg("provider last-known snapshot persistence failed")
	}
}

func lastKnownFromProvider(provider pool.Provider, now time.Time) providerevents.LastKnown {
	snap := providerevents.LastKnown{
		ProviderID:      provider.ProviderID,
		AssignedID:      provider.AssignedID,
		BinaryVersion:   provider.BinaryVersion,
		ModelID:         provider.ModelID,
		State:           string(provider.State),
		AuthState:       string(provider.AuthState),
		LastSeenAt:      now,
		RoutingEligible: provider.RoutingEligible(),
		Presence:        "connected",
	}
	if !provider.ConnectedAt.IsZero() {
		t := provider.ConnectedAt.UTC()
		snap.ConnectedAt = &t
	}
	if !provider.LastHeartbeatAt.IsZero() {
		t := provider.LastHeartbeatAt.UTC()
		snap.LastHeartbeatAt = &t
	}
	if !provider.LastActivityAt.IsZero() {
		t := provider.LastActivityAt.UTC()
		snap.LastActivityAt = &t
		snap.LastSeenAt = t
	} else if !provider.LastHeartbeatAt.IsZero() {
		snap.LastSeenAt = provider.LastHeartbeatAt.UTC()
	} else if !provider.ConnectedAt.IsZero() {
		snap.LastSeenAt = provider.ConnectedAt.UTC()
	}
	return snap
}
