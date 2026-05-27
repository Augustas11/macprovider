package ws

import (
	"encoding/json"
	"net"
	"net/http"
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

	assignedID := s.newUUID()
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

	// Step 2 stops after handshake. Later steps keep this goroutine alive for
	// heartbeat, state_update, preflight_ack, drain_status, and nak handling.
}

func (s *Server) close(conn net.Conn, code gobwas.StatusCode, reason string) {
	_ = wsutil.WriteServerMessage(conn, gobwas.OpClose, gobwas.NewCloseFrameBody(code, reason))
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
