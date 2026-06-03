package ws

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

const (
	CloseUnrecognizedAuthMessage gobwas.StatusCode = 4000
	CloseInvalidHello            gobwas.StatusCode = 4001
	CloseUnknownProviderID       gobwas.StatusCode = 4002
	CloseTierUnsupported         gobwas.StatusCode = 4003
	CloseVersionUnsupported      gobwas.StatusCode = 4004
	CloseInvalidToken            gobwas.StatusCode = 4005
	CloseProvisionalPoolFull     gobwas.StatusCode = 4007
	CloseProvisionalRateLimited  gobwas.StatusCode = 4008
	CloseBanned                  gobwas.StatusCode = 4009
	CloseTier2AttestationFailed  gobwas.StatusCode = 4012
	CloseTier2KeyExchangeFailed  gobwas.StatusCode = 4013
	ClosePoolFull                gobwas.StatusCode = 4429
)

type Server struct {
	cfg       config.Config
	tier2Mu   sync.RWMutex
	tier2     config.Tier2Config
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
	explorer  http.Handler
	unauth    chan struct{}
}

type TokenValidator interface {
	ValidateToken(context.Context, string) (string, bool, error)
	MarkTokenUsed(context.Context, string) error
}

type providerAuth struct {
	validated  bool
	providerID string
	token      string
}

type Option func(*Server)

func WithTokenValidator(tokens TokenValidator) Option {
	return func(s *Server) {
		s.tokens = tokens
	}
}

func WithExplorerHandler(handler http.Handler) Option {
	return func(s *Server) {
		s.explorer = handler
	}
}

func WithAdmissionStore(store AdmissionStateStore) Option {
	return func(s *Server) {
		s.admission.SetPersistence(store, func(err error) {
			s.log.Warn().Err(err).Msg("admission state persistence failed")
		})
	}
}

type pendingPreflight struct {
	providerID string
	assignedID string
	ch         chan PreflightAck
}

func NewServer(cfg config.Config, registry *pool.Registry, logger zerolog.Logger, opts ...Option) *Server {
	s := &Server{
		cfg:     cfg,
		tier2:   cfg.Tier2,
		pool:    registry,
		log:     logger,
		now:     func() time.Time { return time.Now().UTC() },
		newUUID: func() string { return uuid.NewString() },
		started: time.Now().UTC(),
		unauth:  make(chan struct{}, cfg.ProviderWSMaxUnauthenticatedConn()),
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

func (s *Server) SetTier2Config(cfg config.Tier2Config) {
	s.tier2Mu.Lock()
	defer s.tier2Mu.Unlock()
	s.tier2 = cfg
}

func (s *Server) RefreshTier2HashStatuses() int {
	cfg := s.tier2Config()
	if !tier2.ModelHashActive(cfg) {
		return s.pool.UpdateHashStatuses(func(pool.Provider) pool.HashStatus {
			return ""
		})
	}
	return s.pool.UpdateHashStatuses(func(provider pool.Provider) pool.HashStatus {
		next := tier2.VerifyProviderHash(provider.ModelID, provider.ModelHash)
		if next != provider.HashStatus {
			tier2.LogProviderHashStatus(s.log, provider.ProviderID, provider.AssignedID, provider.ModelID, provider.ModelHash, next)
		}
		if cfg.RequireHashVerified && (next == pool.HashStatusUncatalogued || next == pool.HashStatusCatalogUnavailable) {
			tier2.LogHashRequiredProviderExcluded(s.log, provider.ProviderID, provider.AssignedID, provider.ModelID, provider.ModelHash, next)
		}
		return next
	})
}

func (s *Server) tier2Config() config.Tier2Config {
	s.tier2Mu.RLock()
	defer s.tier2Mu.RUnlock()
	return s.tier2
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	if s.cfg.Explorer.Enabled && s.explorer != nil {
		bindPath := s.cfg.Explorer.BindPath
		mux.Handle(bindPath, s.explorer)
		mux.Handle(strings.TrimSuffix(bindPath, "/"), s.explorer)
	}
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
	if !s.reserveUnauthenticatedConn() {
		s.close(conn, ClosePoolFull, "too_many_unauthenticated_connections")
		time.AfterFunc(100*time.Millisecond, func() { _ = conn.Close() })
		return
	}
	s.setReadDeadline(conn, s.cfg.ProviderWSHandshakeTimeout())
	auth, ok := s.validateProviderToken(r)
	if !ok {
		s.close(conn, CloseInvalidToken, "invalid_token")
		s.releaseUnauthenticatedConn()
		time.AfterFunc(100*time.Millisecond, func() { _ = conn.Close() })
		return
	}
	go s.handleConn(conn, auth, s.releaseUnauthenticatedConn)
}

func (s *Server) validateProviderToken(r *http.Request) (providerAuth, bool) {
	authz := r.Header.Get("Authorization")
	if s.cfg.Auth.RequireProviderTokens && s.tokens == nil {
		s.log.Error().Msg("provider token validation is required but no token validator is configured")
		return providerAuth{}, false
	}
	if authz == "" && s.tokens != nil {
		return providerAuth{}, false
	}
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
	token := strings.TrimSpace(strings.TrimPrefix(authz, prefix))
	providerID, ok, err := s.tokens.ValidateToken(r.Context(), token)
	if err != nil {
		s.log.Warn().Err(err).Msg("provider token validation failed")
		return providerAuth{}, false
	}
	return providerAuth{validated: ok, providerID: providerID, token: token}, ok
}

func (s *Server) handleConn(conn net.Conn, auth providerAuth, releaseUnauthenticated func()) {
	defer conn.Close()
	var releaseOnce sync.Once
	releaseUnauth := func() {
		if releaseUnauthenticated != nil {
			releaseOnce.Do(releaseUnauthenticated)
		}
	}
	defer releaseUnauth()
	var providerID string
	var assignedID string
	defer func() {
		if providerID != "" && assignedID != "" {
			s.handleDisconnect(providerID, assignedID)
		}
	}()

	payload, op, err := s.readClientData(conn)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: read")
		return
	}
	if op != gobwas.OpText {
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
		return
	}

	typ, version, err := ParseFirstAuthMessage(payload)
	if err != nil {
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
		return
	}
	switch {
	case typ == "hello" && version == 1:
		providerID, assignedID = s.handleV1Conn(conn, auth, payload, releaseUnauth)
	case typ == "auth_request" && version == 2:
		providerID, assignedID = s.handleV2Conn(conn, auth, payload, releaseUnauth)
	default:
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
	}
}

func (s *Server) handleV1Conn(conn net.Conn, auth providerAuth, payload []byte, releaseUnauth func()) (string, string) {
	hello, badField, err := ParseHello(payload)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: "+badField)
		return "", ""
	}
	if hello.Version != 1 {
		s.close(conn, CloseVersionUnsupported, "version_unsupported: protocol version "+itoa(hello.Version))
		return "", ""
	}
	if hello.Tier != 1 {
		s.close(conn, CloseTierUnsupported, "tier_unsupported: tier "+itoa(hello.Tier)+" not supported")
		return "", ""
	}
	if s.tier2Config().RequireEncryptedLeg {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_encrypted_leg_required")
		return "", ""
	}
	entry, ok := s.prepareProviderAdmission(conn, auth, hello)
	if !ok {
		return "", ""
	}
	session := s.registerProviderSession(conn, entry)
	releaseUnauth()

	ack := HelloAck{
		Type:                     "hello_ack",
		CoordinatorVersion:       1,
		AssignedID:               entry.AssignedID,
		HeartbeatIntervalS:       int(s.cfg.HeartbeatInterval().Seconds()),
		Tier:                     string(entry.Tier),
		RecommendedBinaryVersion: s.cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion,
		RequiredBinaryVersion:    s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion,
	}
	b, err := json.Marshal(ack)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_hello: ack")
		return "", ""
	}
	if err := session.send(b); err != nil {
		s.log.Warn().Err(err).Str("provider_id", hello.ProviderID).Msg("hello_ack write failed")
		return "", ""
	}
	if s.cfg.Pool.WarmupGateEnabled {
		s.startWarmupGate(*entry)
	}
	s.readProviderLoop(conn, entry.ProviderID, entry.AssignedID)
	return entry.ProviderID, entry.AssignedID
}

func (s *Server) handleV2Conn(conn net.Conn, auth providerAuth, payload []byte, releaseUnauth func()) (string, string) {
	initial, badField, err := ParseAuthRequest(payload)
	if err != nil || initial.Stage != "initial" {
		if badField == "" {
			badField = "stage"
		}
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
		return "", ""
	}
	tier2Cfg := s.tier2Config()
	selectedAEAD, ok := negotiateAEAD(initial.Tier2Capabilities.AEADSuites, tier2Cfg)
	if !ok || !initial.Tier2Capabilities.EncryptedLeg {
		s.close(conn, CloseInvalidHello, "no_common_aead_suite")
		return "", ""
	}
	providerPublic, _, err := tier2.ParseX25519PublicKey(initial.ProviderECDHPublicKey)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	entry, ok := s.prepareProviderAdmission(conn, auth, initial.Hello())
	if !ok {
		return "", ""
	}
	coordinatorPrivate, coordinatorPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	keys, err := tier2.DerivePillarBKeys(coordinatorPrivate, providerPublic, initial.ProviderID, entry.AssignedID, selectedAEAD)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	challengeBytes, err := randomBytes(32)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	authAttemptID := "auth-" + s.newUUID()
	challengeExpiresAt := s.now().Add(10 * time.Minute).UTC()
	challenge := AuthChallenge{
		Type:                     "auth_challenge",
		Version:                  2,
		AuthAttemptID:            authAttemptID,
		AssignedID:               entry.AssignedID,
		AttestationChallenge:     base64.RawURLEncoding.EncodeToString(challengeBytes),
		AttestationFormats:       append([]string(nil), tier2Cfg.AttestationFormats...),
		CoordinatorECDHPublicKey: base64.RawURLEncoding.EncodeToString(coordinatorPublicRaw),
		SelectedAEADSuite:        selectedAEAD,
		SelectedAEAD:             selectedAEAD,
		KeyID:                    keys.KeyID,
		ExpiresAt:                challengeExpiresAt.Format(time.RFC3339),
	}
	rawChallenge, err := json.Marshal(challenge)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	if err := s.writeServerText(conn, rawChallenge); err != nil {
		s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("auth_challenge write failed")
		return "", ""
	}

	s.setReadDeadline(conn, s.cfg.ProviderWSHandshakeTimeout())
	proofPayload, op, err := s.readClientData(conn)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_auth_request: read")
		return "", ""
	}
	if op != gobwas.OpText {
		s.close(conn, CloseInvalidHello, "invalid_auth_request: type")
		return "", ""
	}
	proof, badField, err := ParseAuthRequest(proofPayload)
	if err != nil || proof.Stage != "proof" {
		if badField == "" {
			badField = "stage"
		}
		s.sendAuthRejection(conn, "invalid_auth_request", "invalid auth_request")
		s.close(conn, CloseInvalidHello, "invalid_auth_request: "+badField)
		return "", ""
	}
	if proof.AuthAttemptID != authAttemptID || proof.ProviderID != initial.ProviderID || s.now().After(challengeExpiresAt) {
		s.sendAuthRejection(conn, "attestation_failed", "attestation failed")
		s.close(conn, CloseTier2AttestationFailed, "tier2_attestation_failed")
		return "", ""
	}
	attestationStatus := tier2.VerifyAttestationToken(proof.AttestationToken, tier2Cfg, challengeBytes, authAttemptID, initial.ProviderID, initial.ProviderECDHPublicKey, s.now(), s.log)
	if tier2Cfg.RequireAttestation && attestationStatus != pool.AttestationStatusAttested {
		s.sendAuthRejection(conn, string(attestationStatus), string(attestationStatus))
		s.close(conn, CloseTier2AttestationFailed, "tier2_attestation_failed")
		return "", ""
	}

	entry.EncryptedLeg = true
	entry.AttestationStatus = attestationStatus
	entry.Tier2Session = &pool.Tier2Session{
		AEADSuite:    selectedAEAD,
		C2PKey:       keys.C2PKey,
		P2CKey:       keys.P2CKey,
		C2PNonceBase: keys.C2PNonceBase,
		P2CNonceBase: keys.P2CNonceBase,
		KeyID:        keys.KeyID,
		StartedAt:    s.now(),
	}
	session := s.registerProviderSession(conn, entry)
	releaseUnauth()
	response := AuthResponse{
		Type:                     "auth_response",
		Version:                  2,
		Status:                   "accepted",
		AssignedID:               entry.AssignedID,
		HeartbeatIntervalS:       int(s.cfg.HeartbeatInterval().Seconds()),
		Tier:                     string(entry.Tier),
		RecommendedBinaryVersion: s.cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion,
		RequiredBinaryVersion:    s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion,
		Tier2Session: &AuthTier2Session{
			EncryptedLeg: AuthEncryptedLegSession{
				Enabled:            true,
				Alg:                selectedAEAD,
				KID:                keys.KeyID,
				RekeyAfterRequests: tier2Cfg.EncryptedLegRekeyAfterRequests,
				RekeyAfterSeconds:  tier2Cfg.EncryptedLegRekeyAfterSeconds,
			},
			Attestation: AuthAttestationSession{
				Status:          string(attestationStatus),
				RAMTierAttested: false,
			},
			ModelHash: AuthModelHashSession{Status: string(entry.HashStatus)},
		},
	}
	rawResponse, err := json.Marshal(response)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_auth_response")
		return "", ""
	}
	if err := session.send(rawResponse); err != nil {
		s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("auth_response write failed")
		return "", ""
	}
	if s.cfg.Pool.WarmupGateEnabled {
		s.startWarmupGate(*entry)
	}
	s.readProviderLoop(conn, entry.ProviderID, entry.AssignedID)
	return entry.ProviderID, entry.AssignedID
}

func (s *Server) prepareProviderAdmission(conn net.Conn, auth providerAuth, hello Hello) (*pool.Provider, bool) {
	if required := strings.TrimSpace(s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion); required != "" {
		cmp, ok := compareSemver(hello.BinaryVersion, required)
		if !ok || cmp < 0 {
			s.close(conn, CloseVersionUnsupported, "version_unsupported: binary_version "+hello.BinaryVersion+" below required "+required)
			return nil, false
		}
	}
	providerCfg, pinned := s.pool.Endpoint(hello.ProviderID)
	if s.tokens != nil {
		if auth.validated && auth.providerID != hello.ProviderID {
			s.close(conn, CloseInvalidToken, "invalid_token")
			return nil, false
		}
		if pinned && !auth.validated {
			s.close(conn, CloseInvalidToken, "invalid_token")
			return nil, false
		}
		if auth.validated {
			if err := s.tokens.MarkTokenUsed(context.Background(), auth.token); err != nil {
				s.log.Warn().Err(err).Str("provider_id", hello.ProviderID).Msg("provider token usage update failed")
				s.close(conn, CloseInvalidToken, "invalid_token")
				return nil, false
			}
		}
	}
	tier, closeCode, closeReason := s.admission.Admit(hello, pinned, s.connectedProvisional())
	if closeCode != 0 {
		s.close(conn, closeCode, closeReason)
		return nil, false
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
			s.log.Warn().
				Str("provider_id", hello.ProviderID).
				Str("hello_endpoint_url", strings.TrimSpace(*hello.EndpointURL)).
				Msg("pinned provider endpoint_url ignored because no configured endpoint_url exists")
		}
		if endpointURL != "" {
			inferencePath = pool.InferencePathHTTPForwarding
		}
	} else if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" {
		s.log.Warn().Str("provider_id", hello.ProviderID).Str("endpoint_url", *hello.EndpointURL).Msg("provisional provider sent endpoint_url; ignoring and forcing ws-tunneled mode")
	}

	assignedID := s.newUUID()
	now := s.now()
	hashStatus := pool.HashStatus("")
	tier2Cfg := s.tier2Config()
	if tier2.ModelHashActive(tier2Cfg) {
		hashStatus = tier2.VerifyProviderHash(hello.ModelID, hello.ModelHash)
		tier2.LogProviderHashStatus(s.log, hello.ProviderID, assignedID, hello.ModelID, hello.ModelHash, hashStatus)
		if tier2Cfg.RequireHashVerified && (hashStatus == pool.HashStatusUncatalogued || hashStatus == pool.HashStatusCatalogUnavailable) {
			tier2.LogHashRequiredProviderExcluded(s.log, hello.ProviderID, assignedID, hello.ModelID, hello.ModelHash, hashStatus)
		}
	}
	initialState := pool.StateReady
	if s.cfg.Pool.WarmupGateEnabled {
		initialState = pool.StateDegraded
	}
	return &pool.Provider{
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
		ModelLoadTimeMs:       hello.ModelLoadTimeMs,
		EndpointURL:           endpointURL,
		Tier:                  tier,
		InferencePath:         inferencePath,
		AdmittedAt:            now,
		State:                 initialState,
		LastHeartbeatAt:       now,
		LastActivityAt:        now,
		ConnectedAt:           now,
		BinaryVersion:         hello.BinaryVersion,
		ModelHash:             hello.ModelHash,
		HashStatus:            hashStatus,
	}, true
}

func compareSemver(lhs, rhs string) (int, bool) {
	left, okLeft := semverParts(lhs)
	right, okRight := semverParts(rhs)
	if !okLeft || !okRight {
		return 0, false
	}
	n := len(left)
	if len(right) > n {
		n = len(right)
	}
	for i := 0; i < n; i++ {
		var l, r int
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			r = right[i]
		}
		switch {
		case l < r:
			return -1, true
		case l > r:
			return 1, true
		}
	}
	return 0, true
}

func semverParts(value string) ([]int, bool) {
	value = strings.TrimLeft(strings.TrimSpace(value), "vV")
	if value == "" {
		return nil, false
	}
	parts := strings.Split(value, ".")
	if len(parts) > 3 {
		return nil, false
	}
	out := make([]int, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, false
		}
		for _, r := range part {
			if r < '0' || r > '9' {
				return nil, false
			}
		}
		n, err := strconv.Atoi(part)
		if err != nil {
			return nil, false
		}
		out = append(out, n)
	}
	for len(out) < 3 {
		out = append(out, 0)
	}
	return out, true
}

func (s *Server) registerProviderSession(conn net.Conn, entry *pool.Provider) *providerSession {
	if old := s.pool.Register(entry, conn); old != nil {
		_ = old.Close()
	}
	session := newProviderSession(entry.ProviderID, entry.AssignedID, conn, s.cfg.WS.WriteBufferSize, s.cfg.ProviderWSWriteTimeout())
	session.useTier2Session(entry.Tier2Session)
	s.sessions.Store(sessionKey(entry.ProviderID, entry.AssignedID), session)
	go session.runWriter()
	go s.monitorHeartbeat(entry.ProviderID, entry.AssignedID, conn)
	return session
}

func (s *Server) readProviderLoop(conn net.Conn, providerID, assignedID string) {
	for {
		s.setReadDeadline(conn, s.cfg.HeartbeatMissThreshold())
		payload, op, err := s.readClientData(conn)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("provider websocket read failed")
			return
		}
		if op != gobwas.OpText {
			s.log.Warn().Str("provider_id", providerID).Uint8("op", uint8(op)).Msg("ignoring non-text provider frame")
			continue
		}
		s.handleMessage(conn, providerID, assignedID, payload)
	}
}

func negotiateAEAD(suites []string, cfg config.Tier2Config) (string, bool) {
	supported := strings.TrimSpace(cfg.EncryptedLegAEAD)
	if supported == "" {
		supported = tier2.PillarBAEADA256GCM
	}
	if supported != tier2.PillarBAEADA256GCM {
		return "", false
	}
	for _, suite := range suites {
		if suite == tier2.PillarBAEADA256GCM {
			return tier2.PillarBAEADA256GCM, true
		}
	}
	return "", false
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return nil, err
	}
	return b, nil
}

func (s *Server) sendAuthRejection(conn net.Conn, code, message string) {
	raw, err := json.Marshal(AuthResponse{
		Type:    "auth_response",
		Version: 2,
		Status:  "rejected",
		Error:   &AuthResponseError{Code: code, Message: message},
	})
	if err != nil {
		return
	}
	_ = s.writeServerText(conn, raw)
}

func (s *Server) close(conn net.Conn, code gobwas.StatusCode, reason string) {
	// Log every WS close at warn level so silent failures (like the v1.1.2
	// deploy's invalid_token rejection of M4/M1) are visible in the journal.
	s.log.Warn().Int("close_code", int(code)).Str("reason", reason).Msg("provider websocket closing")
	_ = s.writeServerMessage(conn, gobwas.OpClose, gobwas.NewCloseFrameBody(code, reason))
}

func (s *Server) reserveUnauthenticatedConn() bool {
	select {
	case s.unauth <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *Server) releaseUnauthenticatedConn() {
	select {
	case <-s.unauth:
	default:
	}
}

func (s *Server) setReadDeadline(conn net.Conn, timeout time.Duration) {
	_ = conn.SetReadDeadline(s.now().Add(timeout))
}

func (s *Server) setWriteDeadline(conn net.Conn) {
	_ = conn.SetWriteDeadline(s.now().Add(s.cfg.ProviderWSWriteTimeout()))
}

func (s *Server) writeServerText(conn net.Conn, payload []byte) error {
	s.setWriteDeadline(conn)
	return wsutil.WriteServerText(conn, payload)
}

func (s *Server) writeServerMessage(conn net.Conn, op gobwas.OpCode, payload []byte) error {
	s.setWriteDeadline(conn)
	return wsutil.WriteServerMessage(conn, op, payload)
}

func (s *Server) readClientData(conn net.Conn) ([]byte, gobwas.OpCode, error) {
	controlHandler := wsutil.ControlFrameHandler(conn, gobwas.StateServerSide)
	rd := wsutil.Reader{
		Source:          conn,
		State:           gobwas.StateServerSide,
		CheckUTF8:       true,
		SkipHeaderCheck: false,
		MaxFrameSize:    s.cfg.ProviderWSMaxFrameBytes(),
		OnIntermediate:  controlHandler,
	}
	for {
		hdr, err := rd.NextFrame()
		if err != nil {
			return nil, 0, err
		}
		if hdr.OpCode.IsControl() {
			if err := controlHandler(hdr, &rd); err != nil {
				return nil, 0, err
			}
			continue
		}
		if hdr.OpCode&(gobwas.OpText|gobwas.OpBinary) == 0 {
			if err := rd.Discard(); err != nil {
				return nil, 0, err
			}
			continue
		}
		payload, err := io.ReadAll(&rd)
		return payload, hdr.OpCode, err
	}
}

func sessionKey(providerID, assignedID string) string {
	return providerID + "/" + assignedID
}

func (s *Server) storedSessionFor(providerID, assignedID string) (*providerSession, bool) {
	v, ok := s.sessions.Load(sessionKey(providerID, assignedID))
	if !ok {
		return nil, false
	}
	session, ok := v.(*providerSession)
	return session, ok
}

func (s *Server) sessionFor(providerID, assignedID string) (*providerSession, bool) {
	if _, ok := s.pool.Resolve(providerID, assignedID); !ok {
		return nil, false
	}
	return s.storedSessionFor(providerID, assignedID)
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
		s.handleStateUpdate(providerID, assignedID, payload)
	case "preflight_ack":
		s.handlePreflightAck(providerID, assignedID, payload)
	case "inference_response_chunk":
		s.handleInferenceChunk(providerID, assignedID, payload)
	case "inference_response_end":
		s.handleInferenceEnd(providerID, assignedID, payload)
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
	s.pending.Store(requestID, pendingPreflight{providerID: provider.ProviderID, assignedID: provider.AssignedID, ch: ch})
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
	if !provider.IsWSTunneled() {
		return s.runHTTPWarmupGateAttempt(ctx, provider, body)
	}
	return s.runWSWarmupGateAttempt(ctx, provider, attempt, body)
}

func (s *Server) runWSWarmupGateAttempt(ctx context.Context, provider pool.Provider, attempt int, body []byte) bool {
	if s.tier2WarmupExcluded(provider) {
		return false
	}
	requestID := "warmup-gate-" + provider.AssignedID + "-" + itoa(attempt)
	relay, err := s.DispatchInference(ctx, provider, requestID, body, false)
	if err != nil {
		return false
	}
	chunks := relay.Chunks
	observedOutput := false
	for {
		select {
		case chunk, ok := <-chunks:
			if !ok {
				chunks = nil
				continue
			}
			if warmupChunkHasOutput(chunk.Data) {
				observedOutput = true
			}
		case end := <-relay.Done:
			return warmupGatePassed(end, observedOutput)
		case <-relay.Errors:
			return false
		case <-ctx.Done():
			return false
		}
	}
}

func (s *Server) tier2WarmupExcluded(provider pool.Provider) bool {
	cfg := s.tier2Config()
	if tier2.ModelHashActive(cfg) {
		status := provider.HashStatus
		if status == "" {
			status = tier2.VerifyProviderHash(provider.ModelID, provider.ModelHash)
		}
		if tier2.IsHashPredicateFailure(status, cfg.RequireHashVerified) {
			return true
		}
	}
	if cfg.RequireEncryptedLeg && !provider.EncryptedLeg {
		return true
	}
	if cfg.RequireAttestation && provider.AttestationStatus != pool.AttestationStatusAttested {
		return true
	}
	return false
}

func (s *Server) runHTTPWarmupGateAttempt(ctx context.Context, provider pool.Provider, body []byte) bool {
	endpoint := strings.TrimRight(strings.TrimSpace(provider.EndpointURL), "/")
	if endpoint == "" {
		return false
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := providerhttp.Client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return false
	}
	return warmupPayloadHasOutput(raw) && warmupCompletionUsagePassed(raw)
}

func warmupGatePassed(end InferenceResponseEnd, observedOutput bool) bool {
	if end.Status != "complete" {
		return false
	}
	if !observedOutput {
		return false
	}
	return warmupUsagePassed(end.Usage)
}

func warmupUsagePassed(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	var usage struct {
		CompletionTokens int `json:"completion_tokens"`
	}
	if err := json.Unmarshal(raw, &usage); err != nil {
		return false
	}
	return usage.CompletionTokens > 0
}

func warmupCompletionUsagePassed(raw []byte) bool {
	var resp struct {
		Usage json.RawMessage `json:"usage"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return false
	}
	return warmupUsagePassed(resp.Usage)
}

func warmupChunkHasOutput(data string) bool {
	hasDataLines := false
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		hasDataLines = true
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		if warmupPayloadHasOutput([]byte(payload)) {
			return true
		}
	}
	if hasDataLines {
		return false
	}
	return warmupPayloadHasOutput([]byte(data))
}

func warmupPayloadHasOutput(raw []byte) bool {
	var resp struct {
		Choices []struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
			Delta struct {
				Content json.RawMessage `json:"content"`
			} `json:"delta"`
			Text json.RawMessage `json:"text"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return false
	}
	for _, choice := range resp.Choices {
		if rawJSONHasText(choice.Message.Content) || rawJSONHasText(choice.Delta.Content) || rawJSONHasText(choice.Text) {
			return true
		}
	}
	return false
}

func rawJSONHasText(raw json.RawMessage) bool {
	if len(raw) == 0 || string(raw) == "null" {
		return false
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return false
	}
	return valueHasText(value)
}

func valueHasText(value any) bool {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v) != ""
	case []any:
		for _, item := range v {
			if valueHasText(item) {
				return true
			}
		}
	case map[string]any:
		for _, key := range []string{"text", "content"} {
			if valueHasText(v[key]) {
				return true
			}
		}
	}
	return false
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

func (s *Server) handlePreflightAck(providerID, assignedID string, payload []byte) {
	ack, field, err := ParsePreflightAck(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid preflight_ack")
		return
	}
	if pending, ok := s.pending.Load(ack.RequestID); ok {
		pf := pending.(pendingPreflight)
		if pf.providerID != providerID || pf.assignedID != assignedID {
			s.log.Warn().Str("provider_id", providerID).Str("expected_provider_id", pf.providerID).Str("request_id", ack.RequestID).Msg("preflight_ack from wrong provider")
			return
		}
		if _, ok := s.sessionFor(providerID, assignedID); !ok {
			s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Str("request_id", ack.RequestID).Msg("preflight_ack from stale provider session")
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
	entry, gap, ok := s.pool.ApplyHeartbeat(providerID, assignedID, pool.HeartbeatUpdate{
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

func (s *Server) handleStateUpdate(providerID, assignedID string, payload []byte) {
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
	entry, ok := s.pool.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{
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
	if session, ok := s.storedSessionFor(providerID, assignedID); ok {
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
		PoolPolicyReady int    `json:"pool_policy_ready"`
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
			if s.providerTier2PolicyEligible(p, s.tier2Config()) {
				resp.PoolPolicyReady++
			}
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
	if !tier2.ModelHashActive(s.tier2Config()) {
		for i := range providers {
			providers[i].ModelHash = ""
			providers[i].HashStatus = ""
		}
	} else {
		for i := range providers {
			providers[i].HashStatus = tier2.VerifyProviderHash(providers[i].ModelID, providers[i].ModelHash)
		}
	}
	modelSet := map[string]struct{}{}
	summary := struct {
		TotalProviders int      `json:"total_providers"`
		Ready          int      `json:"ready"`
		PolicyReady    int      `json:"policy_ready"`
		TotalSlots     int      `json:"total_slots"`
		FreeSlots      int      `json:"free_slots"`
		Models         []string `json:"models"`
	}{TotalProviders: len(providers)}
	cfg := s.tier2Config()
	for _, p := range providers {
		if p.State == pool.StateReady {
			summary.Ready++
			if s.providerTier2PolicyEligible(p, cfg) {
				summary.PolicyReady++
			}
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

func (s *Server) providerTier2PolicyEligible(p pool.Provider, cfg config.Tier2Config) bool {
	if p.State != pool.StateReady {
		return false
	}
	if !tier2.ConfigActive(cfg) {
		return true
	}
	if tier2.ModelHashActive(cfg) && tier2.IsHashPredicateFailure(tier2.VerifyProviderHash(p.ModelID, p.ModelHash), cfg.RequireHashVerified) {
		return false
	}
	if cfg.RequireEncryptedLeg && !p.EncryptedLeg {
		return false
	}
	if cfg.RequireAttestation && p.AttestationStatus != pool.AttestationStatusAttested {
		return false
	}
	return true
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
