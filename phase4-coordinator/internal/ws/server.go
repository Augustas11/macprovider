package ws

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

const (
	CloseInvalidHello           gobwas.StatusCode = 4001
	CloseUnknownProviderID      gobwas.StatusCode = 4002
	CloseTierUnsupported        gobwas.StatusCode = 4003
	CloseVersionUnsupported     gobwas.StatusCode = 4004
	CloseInvalidToken           gobwas.StatusCode = 4005
	CloseProvisionalPoolFull    gobwas.StatusCode = 4007
	CloseProvisionalRateLimited gobwas.StatusCode = 4008
	CloseBanned                 gobwas.StatusCode = 4009
	ClosePoolFull               gobwas.StatusCode = 4429
)

type Server struct {
	cfg       config.Config
	pool      *pool.Registry
	log       zerolog.Logger
	now       func() time.Time
	newUUID   func() string
	timers    sync.Map
	pending   sync.Map
	warmups   sync.Map
	tokens    TokenValidator
	admission *AdmissionManager
	sessions  sync.Map
	started   time.Time
}

type TokenValidator interface {
	ValidateToken(context.Context, string) (bool, error)
}

type providerAuth struct {
	validated bool
}

type Option func(*Server)

func WithTokenValidator(tokens TokenValidator) Option {
	return func(s *Server) {
		s.tokens = tokens
	}
}

type pendingPreflight struct {
	providerID string
	ch         chan PreflightAck
}

func NewServer(cfg config.Config, registry *pool.Registry, logger zerolog.Logger, opts ...Option) *Server {
	s := &Server{
		cfg:     cfg,
		pool:    registry,
		log:     logger,
		now:     func() time.Time { return time.Now().UTC() },
		newUUID: func() string { return uuid.NewString() },
		started: time.Now().UTC(),
	}
	s.admission = NewAdmissionManager(cfg.Admission, s.now)
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *Server) Admission() *AdmissionManager {
	return s.admission
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/provider", s.handleProvider)
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/poolz", s.handlePoolz)
	mux.HandleFunc("/admin/blacklist", s.handleBlacklist)
	mux.HandleFunc("/admin/provisional", s.handleAdminProvisional)
	mux.HandleFunc("/admin/promote/", s.handleAdminPromote)
	mux.HandleFunc("/admin/reject/", s.handleAdminReject)
	return mux
}

func (s *Server) handleProvider(w http.ResponseWriter, r *http.Request) {
	conn, _, _, err := gobwas.UpgradeHTTP(r, w)
	if err != nil {
		s.log.Warn().Err(err).Msg("provider websocket upgrade failed")
		return
	}
	auth, ok := s.validateProviderToken(r)
	if !ok {
		s.close(conn, CloseInvalidToken, "invalid_token")
		time.AfterFunc(100*time.Millisecond, func() { _ = conn.Close() })
		return
	}
	go s.handleConn(conn, auth)
}

func (s *Server) validateProviderToken(r *http.Request) (providerAuth, bool) {
	authz := r.Header.Get("Authorization")
	if authz == "" {
		return providerAuth{}, true
	}
	if s.tokens == nil {
		return providerAuth{}, true
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(authz, prefix) {
		return providerAuth{}, false
	}
	ok, err := s.tokens.ValidateToken(r.Context(), strings.TrimSpace(strings.TrimPrefix(authz, prefix)))
	if err != nil {
		s.log.Warn().Err(err).Msg("provider token validation failed")
		return providerAuth{}, false
	}
	return providerAuth{validated: ok}, ok
}

func (s *Server) handleConn(conn net.Conn, auth providerAuth) {
	defer conn.Close()
	var providerID string
	var assignedID string
	defer func() {
		if providerID != "" && assignedID != "" {
			s.handleDisconnect(providerID, assignedID)
		}
	}()

	payload, op, err := wsutil.ReadClientData(conn)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: read")
		return
	}
	if op != gobwas.OpText {
		s.close(conn, CloseInvalidHello, "invalid_hello: type")
		return
	}

	hello, badField, err := ParseHello(payload)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: "+badField)
		return
	}
	if hello.Version != 1 {
		s.close(conn, CloseVersionUnsupported, "version_unsupported: protocol version "+itoa(hello.Version))
		return
	}
	if hello.Tier != 1 {
		s.close(conn, CloseTierUnsupported, "tier_unsupported: tier "+itoa(hello.Tier)+" not supported")
		return
	}
	providerCfg, pinned := s.pool.Endpoint(hello.ProviderID)
	if pinned && s.tokens != nil && !auth.validated {
		s.close(conn, CloseInvalidToken, "invalid_token")
		return
	}
	tier, closeCode, closeReason := s.admission.Admit(hello, pinned, s.connectedProvisional())
	if closeCode != 0 {
		s.close(conn, closeCode, closeReason)
		return
	}
	endpointURL := ""
	inferencePath := pool.InferencePathWSTunneled
	if pinned {
		if providerCfg.EndpointURL != "" {
			endpointURL = providerCfg.EndpointURL
			if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" && strings.TrimSpace(*hello.EndpointURL) != providerCfg.EndpointURL {
				s.log.Warn().
					Str("provider_id", hello.ProviderID).
					Str("configured_endpoint_url", providerCfg.EndpointURL).
					Str("hello_endpoint_url", strings.TrimSpace(*hello.EndpointURL)).
					Msg("pinned provider endpoint_url override ignored")
			}
		} else if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" {
			endpointURL = strings.TrimSpace(*hello.EndpointURL)
			if err := config.ValidateEndpointURL(endpointURL); err != nil {
				s.close(conn, CloseInvalidHello, "invalid_hello: endpoint_url")
				return
			}
		}
		if endpointURL != "" {
			inferencePath = pool.InferencePathHTTPForwarding
		}
	} else if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" {
		s.log.Warn().Str("provider_id", hello.ProviderID).Str("endpoint_url", *hello.EndpointURL).Msg("provisional provider sent endpoint_url; ignoring and forcing ws-tunneled mode")
	}

	assignedID = s.newUUID()
	providerID = hello.ProviderID
	now := s.now()
	initialState := pool.StateReady
	if s.cfg.Pool.WarmupGateEnabled {
		initialState = pool.StateDegraded
	}
	entry := &pool.Provider{
		ProviderID:            hello.ProviderID,
		AssignedID:            assignedID,
		Hostname:              hello.Hostname,
		ModelID:               hello.ModelID,
		ModelParamsB:          hello.ModelParamsB,
		RAMGB:                 hello.RAMGB,
		MaxContextTokens:      hello.MaxContextTokens,
		MaxConcurrency:        hello.MaxConcurrency,
		SlotsFree:             hello.MaxConcurrency,
		SlotsTotal:            hello.MaxConcurrency,
		ThroughputTPSEstimate: hello.ThroughputTPSEstimate,
		EndpointURL:           endpointURL,
		Tier:                  tier,
		InferencePath:         inferencePath,
		AdmittedAt:            now,
		State:                 initialState,
		LastHeartbeatAt:       now,
		LastActivityAt:        now,
		ConnectedAt:           now,
		BinaryVersion:         hello.BinaryVersion,
	}
	if old := s.pool.Register(entry, conn); old != nil {
		_ = old.Close()
	}
	session := newProviderSession(providerID, assignedID, conn, s.cfg.WS.WriteBufferSize)
	s.sessions.Store(sessionKey(providerID, assignedID), session)
	go session.runWriter()
	go s.monitorHeartbeat(providerID, assignedID, conn)

	ack := HelloAck{
		Type:                     "hello_ack",
		CoordinatorVersion:       1,
		AssignedID:               assignedID,
		HeartbeatIntervalS:       int(s.cfg.HeartbeatInterval().Seconds()),
		Tier:                     string(tier),
		RecommendedBinaryVersion: s.cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion,
	}
	b, err := json.Marshal(ack)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: ack")
		return
	}
	if err := session.send(b); err != nil {
		s.log.Warn().Err(err).Str("provider_id", hello.ProviderID).Msg("hello_ack write failed")
		return
	}
	if s.cfg.Pool.WarmupGateEnabled {
		s.startWarmupGate(*entry)
	}

	for {
		payload, op, err := wsutil.ReadClientData(conn)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", hello.ProviderID).Msg("provider websocket read failed")
			return
		}
		if op != gobwas.OpText {
			s.log.Warn().Str("provider_id", hello.ProviderID).Uint8("op", uint8(op)).Msg("ignoring non-text provider frame")
			continue
		}
		s.handleMessage(conn, hello.ProviderID, assignedID, payload)
	}
}

func (s *Server) close(conn net.Conn, code gobwas.StatusCode, reason string) {
	// Log every WS close at warn level so silent failures (like the v1.1.2
	// deploy's invalid_token rejection of M4/M1) are visible in the journal.
	s.log.Warn().Int("close_code", int(code)).Str("reason", reason).Msg("provider websocket closing")
	_ = wsutil.WriteServerMessage(conn, gobwas.OpClose, gobwas.NewCloseFrameBody(code, reason))
}

func sessionKey(providerID, assignedID string) string {
	return providerID + "/" + assignedID
}

func (s *Server) sessionFor(providerID, assignedID string) (*providerSession, bool) {
	v, ok := s.sessions.Load(sessionKey(providerID, assignedID))
	if !ok {
		return nil, false
	}
	session, ok := v.(*providerSession)
	return session, ok
}

func (s *Server) sessionByProvider(providerID string) (*providerSession, bool) {
	for _, p := range s.pool.Snapshot() {
		if p.ProviderID != providerID {
			continue
		}
		return s.sessionFor(p.ProviderID, p.AssignedID)
	}
	return nil, false
}

func (s *Server) connectedProvisional() int {
	n := 0
	for _, p := range s.pool.Snapshot() {
		if p.Tier == pool.TierProvisional {
			n++
		}
	}
	return n
}

func (s *Server) handleMessage(conn net.Conn, providerID, assignedID string, payload []byte) {
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid provider message json")
		return
	}
	// Any well-formed inbound frame (heartbeat OR in-flight inference response)
	// proves the provider is alive and following protocol — record activity so
	// the liveness monitor does not close a provider that cannot heartbeat
	// while its single slot is busy streaming a long generation. Unparseable
	// or non-text frames deliberately do NOT count, so a malfunctioning
	// provider emitting garbage is still reaped after the threshold.
	s.pool.Touch(providerID, assignedID, s.now())
	switch envelope.Type {
	case "heartbeat":
		s.handleHeartbeat(conn, providerID, assignedID, payload)
	case "state_update":
		s.handleStateUpdate(providerID, payload)
	case "preflight_ack":
		s.handlePreflightAck(providerID, payload)
	case "inference_response_chunk":
		s.handleInferenceChunk(providerID, payload)
	case "inference_response_end":
		s.handleInferenceEnd(providerID, payload)
	case "nak":
		s.handleNAK(providerID, assignedID, payload)
	case "drain_status":
		s.handleDrainStatus(conn, providerID, assignedID, payload)
	default:
		s.log.Warn().Str("provider_id", providerID).Str("type", envelope.Type).Msg("unknown provider message type")
	}
}

func (s *Server) handleDrainStatus(conn net.Conn, providerID, assignedID string, payload []byte) {
	status, field, err := ParseDrainStatus(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid drain_status")
		return
	}
	if status.Phase == "starting" {
		s.pool.MarkState(providerID, assignedID, pool.StateDraining)
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("phase", status.Phase).
		Int("inflight_requests", status.InflightRequests).
		Int("estimated_drain_seconds", status.EstimatedDrainSeconds).
		Msg("provider drain progress")
	if status.Phase == "complete" {
		_ = conn.Close()
	}
}

func (s *Server) Preflight(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (PreflightAck, bool, error) {
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return PreflightAck{}, false, ErrRelayClosed
	}
	ch := make(chan PreflightAck, 1)
	s.pending.Store(requestID, pendingPreflight{providerID: provider.ProviderID, ch: ch})
	defer s.pending.Delete(requestID)
	msg := map[string]any{
		"type":             "preflight",
		"request_id":       requestID,
		"estimated_tokens": estimatedTokens,
	}
	payload, err := json.Marshal(msg)
	if err != nil {
		return PreflightAck{}, false, err
	}
	if err := session.send(payload); err != nil {
		return PreflightAck{}, false, err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case ack := <-ch:
		return ack, true, nil
	case <-timer.C:
		return PreflightAck{}, false, nil
	}
}

func (s *Server) startWarmupGate(provider pool.Provider) {
	s.warmups.Store(provider.ProviderID, provider.AssignedID)
	go s.runWarmupGate(provider)
}

func (s *Server) runWarmupGate(provider pool.Provider) {
	defer s.clearWarmupGate(provider.ProviderID, provider.AssignedID)
	attempts := s.cfg.Pool.DegradedMaxRetries
	if attempts <= 0 {
		attempts = config.Default().Pool.DegradedMaxRetries
	}
	delay := s.degradedBackoff()
	for attempt := 1; attempt <= attempts; attempt++ {
		if attempt > 1 {
			time.Sleep(delay)
			delay *= 2
		}
		if !s.warmupGateCurrent(provider.ProviderID, provider.AssignedID) {
			return
		}
		if s.runWarmupGateAttempt(provider, attempt) {
			s.clearWarmupGate(provider.ProviderID, provider.AssignedID)
			if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateReady) {
				s.log.Info().Str("provider_id", provider.ProviderID).Int("attempt", attempt).Msg("warmup gate passed")
			}
			return
		}
		s.log.Warn().Str("provider_id", provider.ProviderID).Int("attempt", attempt).Str("reason", "warmup_failed").Msg("warmup gate attempt failed")
	}
	if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
		s.log.Warn().Str("provider_id", provider.ProviderID).Str("reason", "warmup_failed").Msg("provider marked unavailable after warmup gate failures")
	}
}

func (s *Server) runWarmupGateAttempt(provider pool.Provider, attempt int) bool {
	body, err := json.Marshal(map[string]any{
		"model": provider.ModelID,
		"messages": []map[string]string{{
			"role":    "user",
			"content": "Reply with ok.",
		}},
		"max_tokens": s.warmupGateMaxTokens(),
		"stream":     false,
	})
	if err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.warmupGateTimeout())
	defer cancel()
	requestID := "warmup-gate-" + provider.AssignedID + "-" + itoa(attempt)
	relay, err := s.DispatchInference(ctx, provider, requestID, body, false)
	if err != nil {
		return false
	}
	chunks := relay.Chunks
	for {
		select {
		case _, ok := <-chunks:
			if !ok {
				chunks = nil
			}
		case end := <-relay.Done:
			return warmupGatePassed(end)
		case <-relay.Errors:
			return false
		case <-ctx.Done():
			return false
		}
	}
}

func warmupGatePassed(end InferenceResponseEnd) bool {
	if end.Status != "complete" {
		return false
	}
	if len(end.Usage) == 0 {
		return false
	}
	var usage struct {
		CompletionTokens int `json:"completion_tokens"`
	}
	if err := json.Unmarshal(end.Usage, &usage); err != nil {
		return false
	}
	return usage.CompletionTokens > 0
}

func (s *Server) warmupGateCurrent(providerID, assignedID string) bool {
	value, ok := s.warmups.Load(providerID)
	return ok && value.(string) == assignedID
}

func (s *Server) warmupGatePending(providerID string) bool {
	_, ok := s.warmups.Load(providerID)
	return ok
}

func (s *Server) clearWarmupGate(providerID, assignedID string) {
	value, ok := s.warmups.Load(providerID)
	if ok && value.(string) == assignedID {
		s.warmups.Delete(providerID)
	}
}

func (s *Server) DrainAll(reason string) {
	for _, provider := range s.pool.Snapshot() {
		session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
		if !ok {
			continue
		}
		if err := session.send([]byte(`{"type":"drain"}`)); err != nil {
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Str("reason", reason).Msg("drain write failed")
			continue
		}
		s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
		s.log.Info().Str("provider_id", provider.ProviderID).Str("reason", reason).Msg("provider drain sent")
	}
}

func (s *Server) handlePreflightAck(providerID string, payload []byte) {
	ack, field, err := ParsePreflightAck(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid preflight_ack")
		return
	}
	if pending, ok := s.pending.Load(ack.RequestID); ok {
		pf := pending.(pendingPreflight)
		if pf.providerID != providerID {
			s.log.Warn().Str("provider_id", providerID).Str("expected_provider_id", pf.providerID).Str("request_id", ack.RequestID).Msg("preflight_ack from wrong provider")
			return
		}
		select {
		case pf.ch <- ack:
		default:
		}
		return
	}
	s.log.Warn().Str("provider_id", providerID).Str("request_id", ack.RequestID).Msg("unexpected preflight_ack")
}

func (s *Server) handleHeartbeat(conn net.Conn, providerID, assignedID string, payload []byte) {
	hb, field, err := ParseHeartbeat(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid heartbeat")
		return
	}
	state := pool.State(hb.Status)
	if !validState(state) {
		s.log.Warn().Str("state", hb.Status).Str("provider_id", providerID).Msg("invalid heartbeat state")
		return
	}
	if state == pool.StateReady && s.warmupGatePending(providerID) {
		state = pool.StateDegraded
	}
	entry, gap, ok := s.pool.ApplyHeartbeat(providerID, pool.HeartbeatUpdate{
		Status:                state,
		ModelID:               hb.ModelID,
		ModelParamsB:          hb.ModelParamsB,
		RAMGB:                 hb.RAMGB,
		MaxContextTokens:      hb.MaxContextTokens,
		MaxConcurrency:        hb.MaxConcurrency,
		SlotsFree:             hb.SlotsFree,
		SlotsTotal:            hb.SlotsTotal,
		ThroughputTPSEstimate: hb.ThroughputTPSEstimate,
		At:                    s.now(),
	})
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("heartbeat for unknown provider")
		return
	}
	threshold := s.cfg.HeartbeatInterval() + s.cfg.HeartbeatInterval()/2
	if gap > threshold {
		s.log.Warn().Str("provider_id", providerID).Dur("gap", gap).Dur("threshold", threshold).Msg("provider heartbeat stale")
	}
	if gap > s.wakeGapThreshold() && !s.warmupGatePending(providerID) {
		s.log.Info().Str("provider_id", providerID).Dur("gap", gap).Msg("provider wake detected")
		s.markDegradedForWarmup(providerID, assignedID)
		session, ok := s.sessionFor(providerID, assignedID)
		if !ok {
			return
		}
		if err := session.send([]byte(`{"type":"warm_up"}`)); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("warm_up write failed")
		}
	} else {
		s.log.Debug().
			Str("provider_id", providerID).
			Str("state", string(entry.State)).
			Int("slots_free", entry.SlotsFree).
			Int("slots_total", entry.SlotsTotal).
			Msg("provider heartbeat")
	}
}

func (s *Server) handleStateUpdate(providerID string, payload []byte) {
	update, field, err := ParseStateUpdate(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid state_update")
		return
	}
	state := pool.State(update.State)
	if !validState(state) {
		s.log.Warn().Str("state", update.State).Str("provider_id", providerID).Msg("invalid provider state")
		return
	}
	if state == pool.StateReady && s.warmupGatePending(providerID) {
		state = pool.StateDegraded
	}
	entry, ok := s.pool.ApplyStateUpdate(providerID, pool.StateUpdate{
		State:      state,
		SlotsFree:  update.MetricsSnapshot.SlotsFree,
		SlotsTotal: update.MetricsSnapshot.SlotsTotal,
	})
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("state_update for unknown provider")
		return
	}
	if state == pool.StateReady {
		if timer, ok := s.timers.LoadAndDelete(providerID); ok {
			timer.(*time.Timer).Stop()
		}
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("state", string(entry.State)).
		Str("reason", update.Reason).
		Str("since", update.Since).
		Msg("provider state transition")
}

func (s *Server) markDegradedForWarmup(providerID, assignedID string) {
	s.pool.MarkState(providerID, assignedID, pool.StateDegraded)
	if timer, ok := s.timers.LoadAndDelete(providerID); ok {
		timer.(*time.Timer).Stop()
	}
	timer := time.AfterFunc(s.warmupFallback(), func() {
		if s.warmupGatePending(providerID) {
			s.timers.Delete(providerID)
			return
		}
		if s.pool.MarkState(providerID, assignedID, pool.StateReady) {
			s.log.Warn().Str("provider_id", providerID).Dur("timeout", s.warmupFallback()).Msg("warm_up timed out; allowing routing")
		}
		s.timers.Delete(providerID)
	})
	s.timers.Store(providerID, timer)
}

func (s *Server) handleDisconnect(providerID, assignedID string) {
	s.clearWarmupGate(providerID, assignedID)
	if session, ok := s.sessionFor(providerID, assignedID); ok {
		session.close()
		s.sessions.Delete(sessionKey(providerID, assignedID))
	}
	if s.pool.RemoveIfSessionState(providerID, assignedID, pool.StateDraining) {
		s.log.Info().Str("provider_id", providerID).Msg("draining provider removed after websocket close")
		return
	}
	if !s.pool.MarkState(providerID, assignedID, pool.StateUnavailable) {
		return
	}
	grace := s.disconnectGracePeriod()
	s.log.Warn().Str("provider_id", providerID).Dur("grace", grace).Msg("provider websocket disconnected")
	time.AfterFunc(grace, func() {
		if s.pool.RemoveIfSession(providerID, assignedID) {
			s.log.Warn().Str("provider_id", providerID).Msg("provider removed after disconnect grace period")
		}
	})
}

func (s *Server) monitorHeartbeat(providerID, assignedID string, conn net.Conn) {
	tick := s.cfg.FailoverTimeout() / 2
	if tick <= 0 {
		tick = time.Second
	}
	if tick > time.Second {
		tick = time.Second
	}
	ticker := time.NewTicker(tick)
	defer ticker.Stop()
	threshold := s.cfg.HeartbeatMissThreshold()
	for range ticker.C {
		provider, ok := s.pool.Resolve(providerID, assignedID)
		if !ok {
			return
		}
		// Liveness is measured from the last inbound frame of ANY type, not
		// just heartbeats: a provider streaming a long inference response is
		// demonstrably alive even though it cannot emit heartbeats while its
		// single slot is busy. Fall back to LastHeartbeatAt for safety if a
		// provider predates activity tracking.
		last := provider.LastActivityAt
		if last.IsZero() {
			last = provider.LastHeartbeatAt
		}
		if s.now().Sub(last) <= threshold {
			continue
		}
		s.log.Warn().
			Str("provider_id", providerID).
			Dur("gap", s.now().Sub(last)).
			Dur("threshold", threshold).
			Msg("provider inactive past threshold; closing websocket")
		_ = conn.Close()
		return
	}
}

func validState(state pool.State) bool {
	switch state {
	case pool.StateReady, pool.StateBusy, pool.StateDegraded, pool.StateDraining, pool.StateUnavailable:
		return true
	default:
		return false
	}
}

func (s *Server) wakeGapThreshold() time.Duration {
	seconds := s.cfg.Pool.WakeGapThresholdS
	if seconds <= 0 {
		seconds = config.Default().Pool.WakeGapThresholdS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) warmupFallback() time.Duration {
	seconds := s.cfg.Pool.WarmupFallbackS
	if seconds <= 0 {
		seconds = config.Default().Pool.WarmupFallbackS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) disconnectGracePeriod() time.Duration {
	seconds := s.cfg.Pool.DisconnectGracePeriodS
	if seconds <= 0 {
		seconds = config.Default().Pool.DisconnectGracePeriodS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) warmupGateTimeout() time.Duration {
	seconds := s.cfg.Pool.WarmupGateTimeoutS
	if seconds <= 0 {
		seconds = config.Default().Pool.WarmupGateTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) warmupGateMaxTokens() int {
	tokens := s.cfg.Pool.WarmupGateMaxTokens
	if tokens <= 0 {
		tokens = config.Default().Pool.WarmupGateMaxTokens
	}
	return tokens
}

func (s *Server) degradedBackoff() time.Duration {
	seconds := s.cfg.Pool.DegradedBackoffS
	if seconds <= 0 {
		seconds = config.Default().Pool.DegradedBackoffS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providers := s.pool.Snapshot()
	resp := struct {
		Status          string `json:"status"`
		UptimeS         int64  `json:"uptime_s"`
		PoolSize        int    `json:"pool_size"`
		PoolReady       int    `json:"pool_ready"`
		PoolDegraded    int    `json:"pool_degraded"`
		PoolDraining    int    `json:"pool_draining"`
		PoolUnavailable int    `json:"pool_unavailable"`
		RequestsTotal   int    `json:"requests_total"`
		RequestsActive  int    `json:"requests_active"`
		Version         string `json:"version"`
	}{
		Status:   "ok",
		UptimeS:  int64(s.now().Sub(s.started).Seconds()),
		PoolSize: len(providers),
		Version:  "0.1.0",
	}
	for _, p := range providers {
		switch p.State {
		case pool.StateReady:
			resp.PoolReady++
		case pool.StateDegraded:
			resp.PoolDegraded++
		case pool.StateDraining:
			resp.PoolDraining++
		case pool.StateUnavailable:
			resp.PoolUnavailable++
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *Server) handlePoolz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"unauthorized","code":"invalid_operator_token"}}`))
		return
	}

	providers := s.pool.Snapshot()
	modelSet := map[string]struct{}{}
	summary := struct {
		TotalProviders int      `json:"total_providers"`
		Ready          int      `json:"ready"`
		TotalSlots     int      `json:"total_slots"`
		FreeSlots      int      `json:"free_slots"`
		Models         []string `json:"models"`
	}{TotalProviders: len(providers)}
	for _, p := range providers {
		if p.State == pool.StateReady {
			summary.Ready++
		}
		summary.TotalSlots += p.SlotsTotal
		summary.FreeSlots += p.SlotsFree
		if _, ok := modelSet[p.ModelID]; !ok {
			modelSet[p.ModelID] = struct{}{}
			summary.Models = append(summary.Models, p.ModelID)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Pool    []pool.Provider `json:"pool"`
		Summary any             `json:"summary"`
	}{
		Pool:    providers,
		Summary: summary,
	})
}

func (s *Server) handleBlacklist(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	var req struct {
		ProviderID string `json:"provider_id"`
		AssignedID string `json:"assigned_id"`
		Reason     string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	provider, ok := s.pool.Resolve(req.ProviderID, req.AssignedID)
	if !ok {
		id := req.ProviderID
		if id == "" {
			id = req.AssignedID
		}
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider " + id + " not in pool", "code": "provider_not_found"}})
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider " + provider.ProviderID + " not in pool", "code": "provider_not_found"}})
		return
	}
	drainSent := true
	if err := session.send([]byte(`{"type":"drain"}`)); err != nil {
		drainSent = false
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("drain write failed during blacklist")
	}
	s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
	time.AfterFunc(time.Minute, func() {
		_ = session.conn.Close()
	})
	s.log.Warn().Str("provider_id", provider.ProviderID).Str("assigned_id", provider.AssignedID).Str("reason", req.Reason).Msg("provider blacklisted")
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "draining",
		"provider_id": provider.ProviderID,
		"assigned_id": provider.AssignedID,
		"drain_sent":  drainSent,
	})
}

func (s *Server) authorizedOperator(r *http.Request) bool {
	return s.cfg.Auth.OperatorKey == "" || r.Header.Get("Authorization") == "Bearer "+s.cfg.Auth.OperatorKey
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
