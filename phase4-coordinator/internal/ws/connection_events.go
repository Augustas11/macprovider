package ws

import (
	"context"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	gobwas "github.com/gobwas/ws"
)

const (
	connectionEventQueueSize = 1024
	anonymousEventsPerMinute = 120
	lastKnownMinInterval     = time.Minute
)

// ConnectionEventStore is the durable Partial #535 journal seam.
type ConnectionEventStore interface {
	Record(ctx context.Context, event providerevents.Event) error
	UpsertLastKnown(ctx context.Context, snap providerevents.LastKnown) error
	GetLastKnown(ctx context.Context, providerID string) (providerevents.LastKnown, bool, error)
	ListLastKnown(ctx context.Context, limit int, afterProviderID string) ([]providerevents.LastKnown, error)
	ListEvents(ctx context.Context, providerID string, limit int) ([]providerevents.Event, error)
	LatestEventProvider(ctx context.Context, providerID string) (providerevents.Event, bool, error)
	ReconcileBounds(ctx context.Context) error
}

// ConnectionEventMetrics is the optional Prometheus seam for close-set outcomes.
type ConnectionEventMetrics interface {
	IncProviderConnectionEvent(kind, outcome, failureReason string)
}

type closeEventMeta struct {
	providerID       string
	sessionID        string
	attemptID        string
	authStage        string
	messageFamily    string
	binaryVersion    string
	diagnostic       string
	identityVerified bool
}

type connectionEventJob struct {
	event *providerevents.Event
	snap  *providerevents.LastKnown
}

func WithConnectionEventStore(store ConnectionEventStore) Option {
	return func(s *Server) {
		s.connectionEvents = store
		s.ensureConnectionEventWorker()
	}
}

func WithConnectionEventMetrics(metrics ConnectionEventMetrics) Option {
	return func(s *Server) {
		s.connectionEventMetrics = metrics
	}
}

func (s *Server) ensureConnectionEventWorker() {
	if s == nil {
		return
	}
	s.connectionEventWorkerOnce.Do(func() {
		s.connectionEventQueue = make(chan connectionEventJob, connectionEventQueueSize)
		s.connectionEventDone = make(chan struct{})
		s.lastKnownFlush = make(map[string]time.Time)
		go s.runConnectionEventWorker()
	})
}

func (s *Server) runConnectionEventWorker() {
	defer close(s.connectionEventDone)
	for job := range s.connectionEventQueue {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		if job.event != nil && s.connectionEvents != nil {
			if err := s.connectionEvents.Record(ctx, *job.event); err != nil {
				s.log.Warn().Err(err).
					Str("provider_id", job.event.ProviderID).
					Str("kind", job.event.Kind).
					Msg("provider connection event persistence failed")
			} else if s.connectionEventMetrics != nil {
				s.connectionEventMetrics.IncProviderConnectionEvent(job.event.Kind, job.event.Outcome, job.event.FailureReason)
			}
		}
		if job.snap != nil && s.connectionEvents != nil {
			if err := s.connectionEvents.UpsertLastKnown(ctx, *job.snap); err != nil {
				s.log.Warn().Err(err).
					Str("provider_id", job.snap.ProviderID).
					Msg("provider last-known snapshot persistence failed")
			}
		}
		cancel()
	}
}

// FlushConnectionEvents stops intake and waits briefly for queued journal
// writes before SQLite close during coordinator shutdown. The queue channel
// is closed only while holding connectionEventQueueMu so producers cannot
// race a send-on-closed-channel panic.
func (s *Server) FlushConnectionEvents(timeout time.Duration) {
	if s == nil {
		return
	}
	s.connectionEventStopOnce.Do(func() {
		s.ensureConnectionEventWorker()
		s.connectionEventQueueMu.Lock()
		s.connectionEventsStopped.Store(true)
		close(s.connectionEventQueue)
		s.connectionEventQueueMu.Unlock()
	})
	if s.connectionEventDone == nil {
		return
	}
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	select {
	case <-s.connectionEventDone:
	case <-time.After(timeout):
		s.log.Warn().Msg("provider connection event drain timed out at shutdown")
	}
}

func (s *Server) rememberCloseEvent(conn net.Conn, meta closeEventMeta) {
	if s == nil || conn == nil {
		return
	}
	for {
		existing, loaded := s.closeEventMeta.LoadOrStore(conn, meta)
		if !loaded {
			return
		}
		cur, ok := existing.(closeEventMeta)
		if !ok {
			s.closeEventMeta.Store(conn, meta)
			return
		}
		merged := mergeCloseEventMeta(cur, meta)
		if s.closeEventMeta.CompareAndSwap(conn, existing, merged) {
			return
		}
	}
}

func mergeCloseEventMeta(cur, next closeEventMeta) closeEventMeta {
	if next.providerID != "" {
		cur.providerID = next.providerID
	}
	if next.sessionID != "" {
		cur.sessionID = next.sessionID
	}
	if next.attemptID != "" {
		cur.attemptID = next.attemptID
	}
	if next.authStage != "" {
		cur.authStage = next.authStage
	}
	if next.messageFamily != "" {
		cur.messageFamily = next.messageFamily
	}
	if next.binaryVersion != "" {
		cur.binaryVersion = next.binaryVersion
	}
	if next.diagnostic != "" {
		cur.diagnostic = next.diagnostic
	}
	if next.identityVerified {
		cur.identityVerified = true
	}
	return cur
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

func (s *Server) allowAnonymousEvent() bool {
	if s == nil {
		return false
	}
	now := time.Now().UTC()
	s.anonymousEventMu.Lock()
	defer s.anonymousEventMu.Unlock()
	if s.anonymousEventWindow.IsZero() || now.Sub(s.anonymousEventWindow) >= time.Minute {
		s.anonymousEventWindow = now
		s.anonymousEventCount = 0
	}
	if s.anonymousEventCount >= anonymousEventsPerMinute {
		return false
	}
	s.anonymousEventCount++
	return true
}

func (s *Server) recordConnectionEvent(event providerevents.Event) {
	if s == nil || s.connectionEvents == nil {
		return
	}
	if s.connectionEventsStopped.Load() {
		return
	}
	s.ensureConnectionEventWorker()
	if event.OccurredAt.IsZero() {
		event.OccurredAt = s.now().UTC()
	}
	if strings.TrimSpace(event.ProviderID) == "" {
		event.ProviderID = providerevents.AnonymousProviderID
	}
	if event.ProviderID == providerevents.AnonymousProviderID && !s.allowAnonymousEvent() {
		return
	}
	if event.FailureReason != "" {
		event.FailureReason = providerevents.NormalizeFailureReason(event.FailureReason)
	}
	job := connectionEventJob{event: &event}
	s.connectionEventQueueMu.Lock()
	if s.connectionEventsStopped.Load() {
		s.connectionEventQueueMu.Unlock()
		return
	}
	select {
	case s.connectionEventQueue <- job:
		s.connectionEventQueueMu.Unlock()
	default:
		s.connectionEventQueueMu.Unlock()
		// Identity-bound events fall back to synchronous persist so overflow
		// cannot silently drop operator-visible failures (SPEC-035-R001).
		if event.ProviderID != providerevents.AnonymousProviderID && s.connectionEvents != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if err := s.connectionEvents.Record(ctx, event); err != nil {
				s.log.Warn().Err(err).
					Str("provider_id", event.ProviderID).
					Str("kind", event.Kind).
					Msg("provider connection event sync fallback failed")
			} else if s.connectionEventMetrics != nil {
				s.connectionEventMetrics.IncProviderConnectionEvent(event.Kind, event.Outcome, event.FailureReason)
			}
			return
		}
		s.log.Warn().
			Str("provider_id", event.ProviderID).
			Str("kind", event.Kind).
			Msg("provider connection event queue full; dropping anonymous")
	}
}

func (s *Server) recordCloseEvent(conn net.Conn, code gobwas.StatusCode, reason string) {
	meta := s.takeCloseEvent(conn)
	s.recordCloseEventFromMeta(meta, code, reason)
}

func (s *Server) recordCloseEventFromMeta(meta closeEventMeta, code gobwas.StatusCode, reason string) {
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
	providerID := strings.TrimSpace(meta.providerID)
	sessionID := meta.sessionID
	attemptID := meta.attemptID
	// Unverified claimed identities must not bypass the anonymous bucket or
	// create last-known rows (reconnect-storm / disk exhaustion).
	if !meta.identityVerified || providerID == "" {
		providerID = providerevents.AnonymousProviderID
		sessionID = ""
		attemptID = ""
	}
	s.recordConnectionEvent(providerevents.Event{
		ProviderID:    providerID,
		SessionID:     sessionID,
		AttemptID:     attemptID,
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
	// Last-known snapshots are updated only from admitted sessions
	// (register/disconnect/heartbeat), never from pre-admission closes.
}

func (s *Server) rememberProviderSnapshot(provider pool.Provider) {
	s.enqueueLastKnown(lastKnownFromProvider(provider, s.now().UTC()), true)
}

func (s *Server) rememberProviderSnapshotCoalesced(provider pool.Provider) {
	s.enqueueLastKnown(lastKnownFromProvider(provider, s.now().UTC()), false)
}

func (s *Server) enqueueLastKnown(snap providerevents.LastKnown, force bool) {
	if s == nil || s.connectionEvents == nil || strings.TrimSpace(snap.ProviderID) == "" {
		return
	}
	if s.connectionEventsStopped.Load() {
		return
	}
	s.ensureConnectionEventWorker()
	if !force {
		s.lastKnownFlushMu.Lock()
		last := s.lastKnownFlush[snap.ProviderID]
		now := s.now().UTC()
		if !last.IsZero() && now.Sub(last) < lastKnownMinInterval {
			s.lastKnownFlushMu.Unlock()
			return
		}
		s.lastKnownFlush[snap.ProviderID] = now
		s.lastKnownFlushMu.Unlock()
	}
	job := connectionEventJob{snap: &snap}
	s.connectionEventQueueMu.Lock()
	if s.connectionEventsStopped.Load() {
		s.connectionEventQueueMu.Unlock()
		return
	}
	select {
	case s.connectionEventQueue <- job:
		s.connectionEventQueueMu.Unlock()
	default:
		s.connectionEventQueueMu.Unlock()
		if s.connectionEvents != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if err := s.connectionEvents.UpsertLastKnown(ctx, snap); err != nil {
				s.log.Warn().Err(err).
					Str("provider_id", snap.ProviderID).
					Msg("provider last-known sync fallback failed")
			}
			return
		}
		s.log.Warn().
			Str("provider_id", snap.ProviderID).
			Msg("provider last-known queue full; dropping")
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

// Keep sync visible for Server fields declared elsewhere.
var _ = sync.Once{}
