package ws

import (
	"encoding/json"
	"net"
	"net/http"
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
	CloseInvalidHello       gobwas.StatusCode = 4001
	CloseUnknownProviderID  gobwas.StatusCode = 4002
	CloseTierUnsupported    gobwas.StatusCode = 4003
	CloseVersionUnsupported gobwas.StatusCode = 4004
	CloseInvalidToken       gobwas.StatusCode = 4005
	ClosePoolFull           gobwas.StatusCode = 4429
)

type Server struct {
	cfg     config.Config
	pool    *pool.Registry
	log     zerolog.Logger
	now     func() time.Time
	newUUID func() string
	timers  sync.Map
	pending sync.Map
}

type pendingPreflight struct {
	providerID string
	ch         chan PreflightAck
}

func NewServer(cfg config.Config, registry *pool.Registry, logger zerolog.Logger) *Server {
	return &Server{
		cfg:     cfg,
		pool:    registry,
		log:     logger,
		now:     func() time.Time { return time.Now().UTC() },
		newUUID: func() string { return uuid.NewString() },
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/provider", s.handleProvider)
	mux.HandleFunc("/poolz", s.handlePoolz)
	return mux
}

func (s *Server) handleProvider(w http.ResponseWriter, r *http.Request) {
	conn, _, _, err := gobwas.UpgradeHTTP(r, w)
	if err != nil {
		s.log.Warn().Err(err).Msg("provider websocket upgrade failed")
		return
	}
	go s.handleConn(conn)
}

func (s *Server) handleConn(conn net.Conn) {
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
	providerCfg, ok := s.pool.Endpoint(hello.ProviderID)
	if !ok {
		s.close(conn, CloseUnknownProviderID, "unknown_provider_id: "+hello.ProviderID)
		return
	}

	assignedID = s.newUUID()
	providerID = hello.ProviderID
	now := s.now()
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
		EndpointURL:           providerCfg.EndpointURL,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         hello.BinaryVersion,
	}
	if old := s.pool.Register(entry, conn); old != nil {
		_ = old.Close()
	}

	ack := HelloAck{
		Type:               "hello_ack",
		CoordinatorVersion: 1,
		AssignedID:         assignedID,
		HeartbeatIntervalS: int(s.cfg.HeartbeatInterval().Seconds()),
	}
	b, err := json.Marshal(ack)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: ack")
		return
	}
	if err := wsutil.WriteServerText(conn, b); err != nil {
		s.log.Warn().Err(err).Str("provider_id", hello.ProviderID).Msg("hello_ack write failed")
		return
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
	_ = wsutil.WriteServerMessage(conn, gobwas.OpClose, gobwas.NewCloseFrameBody(code, reason))
}

func (s *Server) handleMessage(conn net.Conn, providerID, assignedID string, payload []byte) {
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid provider message json")
		return
	}
	switch envelope.Type {
	case "heartbeat":
		s.handleHeartbeat(conn, providerID, assignedID, payload)
	case "state_update":
		s.handleStateUpdate(providerID, payload)
	case "preflight_ack":
		s.handlePreflightAck(providerID, payload)
	default:
		s.log.Warn().Str("provider_id", providerID).Str("type", envelope.Type).Msg("unknown provider message type")
	}
}

func (s *Server) Preflight(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (PreflightAck, bool, error) {
	conn, err := s.pool.Conn(provider.ProviderID, provider.AssignedID)
	if err != nil {
		return PreflightAck{}, false, err
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
	if err := wsutil.WriteServerText(conn, payload); err != nil {
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
	if gap > s.wakeGapThreshold() {
		s.log.Info().Str("provider_id", providerID).Dur("gap", gap).Msg("provider wake detected")
		s.markDegradedForWarmup(providerID, assignedID)
		if err := wsutil.WriteServerText(conn, []byte(`{"type":"warm_up"}`)); err != nil {
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
		if s.pool.MarkState(providerID, assignedID, pool.StateReady) {
			s.log.Warn().Str("provider_id", providerID).Dur("timeout", s.warmupFallback()).Msg("warm_up timed out; allowing routing")
		}
		s.timers.Delete(providerID)
	})
	s.timers.Store(providerID, timer)
}

func (s *Server) handleDisconnect(providerID, assignedID string) {
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
	return 60 * time.Second
}

func (s *Server) disconnectGracePeriod() time.Duration {
	seconds := s.cfg.Pool.DisconnectGracePeriodS
	if seconds <= 0 {
		seconds = config.Default().Pool.DisconnectGracePeriodS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) handlePoolz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.cfg.Auth.OperatorKey != "" && r.Header.Get("Authorization") != "Bearer "+s.cfg.Auth.OperatorKey {
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
