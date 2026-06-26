package buyer

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"math"
	mrand "math/rand"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

var errBodyTooLarge = errors.New("upstream response body too large")

type Server struct {
	pool                   *pool.Registry
	log                    zerolog.Logger
	createdAt              int64
	preflight              PreflightFunc
	preflightThreshold     int
	preflightTimeout       time.Duration
	recoveryBackoff        time.Duration
	recoveryMaxRetries     int
	recoveryProbe          bool
	breakerThreshold       int
	breakerWindow          time.Duration
	relay                  RelayFunc
	admission              *providerws.AdmissionManager
	requestTimeout         time.Duration
	failoverEnabled        bool
	failoverTimeout        time.Duration
	tiebreakRandomize      bool
	tiebreakEpsilon        float64
	modelClasses           map[string]config.ModelClassConfig
	maxRetries             int
	retryPerAttemptTimeout time.Duration
	maxFaultedPerRequest   int
	stickyEnabled          bool
	stickyTTL              time.Duration
	stickyMaxEntries       int
	sticky                 map[string]stickyEntry
	stickyMu               sync.Mutex
	internalAuthKey        string
	gatewayServiceToken    string
	tier2Mu                sync.RWMutex
	tier2                  config.Tier2Config
	reqLog                 requestLogInserter
	reqLogStore            *requestlog.Store
	provisionalWeight      float64
	maxChatBodyBytes       int64
	recovering             sync.Map
	poolCheckMu            sync.Mutex
	poolCheckLast          map[string]time.Time
	poolCheckMaxEntries    int
	poolCheckTTL           time.Duration
	receiptKeysMu          sync.Mutex
	receiptKeysLimiters    map[string]receiptKeysBucket
	receiptKeysMaxEntries  int
	receiptKeysTTL         time.Duration
	billingMu              sync.RWMutex
	billing                *billing.Store
	billingCfg             config.RewardsConfig
	billingSnapshotID      int64
	now                    func() time.Time
	version                string
}

type stickyEntry struct {
	ConversationKey string
	ProviderID      string
	AccountID       string
	ModelScope      string
	CreatedAt       time.Time
	LastUsedAt      time.Time
}

type receiptKeysBucket struct {
	tokens float64
	last   time.Time
}

type PreflightResult struct {
	Accepted bool
	Reason   string
}

type PreflightFunc func(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (PreflightResult, bool, error)
type RelayFunc func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error)

type Option func(*Server)

type requestLogInserter interface {
	Insert(context.Context, requestlog.Row) error
}

type wsForwardResult string

type requestLogAttempt struct {
	PromptTokens        *int64
	CompletionTokens    *int64
	Status              int
	Error               string
	ErrorCode           string
	EstimatedCompTokens *int64
	FaultFlag           string
}

const (
	maxRequestLogUsageTokens     = int64(10000000)
	maxUpstreamResponseBodyBytes = int64(16 << 20)
	requestLogWriteTimeout       = 6 * time.Second
)

const (
	wsForwardComplete                      wsForwardResult = "complete"
	wsForwardFailed                        wsForwardResult = "failed"
	wsForwardQueueFull                     wsForwardResult = "queue_full"
	wsForwardTimedOut                      wsForwardResult = "timed_out"
	wsForwardCancelled                     wsForwardResult = "cancelled"
	wsForwardUnavailable                   wsForwardResult = "unavailable"
	wsForwardProviderDisconnected          wsForwardResult = "provider_disconnected"
	wsForwardProviderDisconnectedCommitted wsForwardResult = "provider_disconnected_committed"
)

type breakerFault string

const (
	breakerFaultDeadWS              breakerFault = "dead_ws_mid_inference"
	breakerFaultRelayTimeout        breakerFault = "relay_timeout_mid_inference"
	breakerFaultZeroTokenCompletion breakerFault = "zero_token_completion"
	breakerFaultHTTPStreamDead      breakerFault = "http_stream_disconnected_mid_inference"
	breakerFaultHTTPStreamTimeout   breakerFault = "http_stream_timed_out_mid_inference"
)

func WithPreflight(fn PreflightFunc) Option {
	return func(s *Server) {
		s.preflight = fn
	}
}

func WithPreflightConfig(thresholdTokens int, timeout time.Duration) Option {
	return func(s *Server) {
		if thresholdTokens > 0 {
			s.preflightThreshold = thresholdTokens
		}
		if timeout > 0 {
			s.preflightTimeout = timeout
		}
	}
}

func WithRecoveryConfig(backoff time.Duration, maxRetries int, enabled bool) Option {
	return func(s *Server) {
		if backoff > 0 {
			s.recoveryBackoff = backoff
		}
		if maxRetries > 0 {
			s.recoveryMaxRetries = maxRetries
		}
		s.recoveryProbe = enabled
	}
}

func WithBreakerConfig(threshold int, window time.Duration) Option {
	return func(s *Server) {
		if threshold > 0 {
			s.breakerThreshold = threshold
		}
		if window > 0 {
			s.breakerWindow = window
		}
	}
}

func WithFailoverConfig(enabled bool, timeout time.Duration) Option {
	return func(s *Server) {
		s.failoverEnabled = enabled
		if timeout > 0 {
			s.failoverTimeout = timeout
		}
	}
}

func WithRoutingConfig(cfg config.RoutingConfig) Option {
	return func(s *Server) {
		s.tiebreakRandomize = cfg.TiebreakRandomize
		s.tiebreakEpsilon = cfg.TiebreakEpsilon
		s.modelClasses = cloneModelClasses(cfg.ModelClasses)
		s.maxRetries = cfg.MaxRetries
		if cfg.RetryPerAttemptTimeoutS > 0 {
			s.retryPerAttemptTimeout = time.Duration(cfg.RetryPerAttemptTimeoutS) * time.Second
		}
		s.maxFaultedPerRequest = cfg.MaxProvidersFaultedPerRequest
		if s.maxFaultedPerRequest == 0 && cfg.MaxRetries > 0 {
			s.maxFaultedPerRequest = min(2, cfg.MaxRetries)
		}
		s.stickyEnabled = cfg.StickyEnabled
		if cfg.StickyTTLS > 0 {
			s.stickyTTL = time.Duration(cfg.StickyTTLS) * time.Second
		}
		if cfg.StickyMaxEntries > 0 {
			s.stickyMaxEntries = cfg.StickyMaxEntries
		}
	}
}

func WithTier2Config(cfg config.Tier2Config) Option {
	return func(s *Server) {
		s.SetTier2Config(cfg)
	}
}

func WithLimitsConfig(cfg config.LimitsConfig) Option {
	return func(s *Server) {
		if cfg.MaxChatRequestBodyBytes > 0 {
			s.maxChatBodyBytes = cfg.MaxChatRequestBodyBytes
		}
	}
}

func (s *Server) SetTier2Config(cfg config.Tier2Config) {
	s.tier2Mu.Lock()
	defer s.tier2Mu.Unlock()
	s.tier2 = cfg
}

func (s *Server) tier2Config() config.Tier2Config {
	s.tier2Mu.RLock()
	defer s.tier2Mu.RUnlock()
	return s.tier2
}

func WithInternalAuthKey(key string) Option {
	return func(s *Server) {
		s.internalAuthKey = strings.TrimSpace(key)
	}
}

// WithGatewayServiceToken sets the secondary credential accepted on
// `/internal/*` paths (M3-2 / SECU-4 / codex PR #73 HIGH-1). When
// non-empty, the gateway can call `/internal/routing` and
// `/internal/sticky` with either this token OR the operator key. The
// audit-log line emits `key=service_token|operator_key` so the operator
// can watch the cutover and rotate operator_key once gateway-origin
// calls stop reporting key=operator_key.
//
// IMPORTANT: this credential is intentionally NOT accepted on any
// `/admin/*` or `/poolz` endpoint. That class of route is human-admin
// only (per the codex audit), to ensure rotating operator_key does NOT
// silently leak admin power to a service token.
func WithGatewayServiceToken(token string) Option {
	return func(s *Server) {
		s.gatewayServiceToken = strings.TrimSpace(token)
	}
}

func WithRelay(fn RelayFunc, timeout time.Duration) Option {
	return func(s *Server) {
		s.relay = fn
		if timeout > 0 {
			s.requestTimeout = timeout
		}
	}
}

func WithAdmission(admission *providerws.AdmissionManager, provisionalWeight float64) Option {
	return func(s *Server) {
		s.admission = admission
		if provisionalWeight > 0 {
			s.provisionalWeight = provisionalWeight
		}
	}
}

func WithRequestLog(store requestLogInserter) Option {
	return func(s *Server) {
		s.reqLog = store
		if typed, ok := store.(*requestlog.Store); ok {
			s.reqLogStore = typed
		}
	}
}

func WithBilling(store *billing.Store, cfg config.RewardsConfig) Option {
	return func(s *Server) {
		s.billingMu.Lock()
		defer s.billingMu.Unlock()
		s.billing = store
		s.billingCfg = cfg
	}
}

func WithVersion(v string) Option {
	return func(s *Server) {
		if v != "" {
			s.version = v
		}
	}
}

func WithBillingSnapshotID(snapshotID int64) Option {
	return func(s *Server) {
		s.billingMu.Lock()
		defer s.billingMu.Unlock()
		s.billingSnapshotID = snapshotID
	}
}

func WithPoolCheckLimiter(maxEntries int, ttl time.Duration) Option {
	return func(s *Server) {
		if maxEntries > 0 {
			s.poolCheckMaxEntries = maxEntries
		}
		if ttl > 0 {
			s.poolCheckTTL = ttl
		}
	}
}

func (s *Server) SetBillingConfig(cfg config.RewardsConfig, snapshotID int64) {
	s.billingMu.Lock()
	defer s.billingMu.Unlock()
	s.billingCfg = cfg
	s.billingSnapshotID = snapshotID
}

func (s *Server) billingState() (*billing.Store, config.RewardsConfig, int64) {
	s.billingMu.RLock()
	defer s.billingMu.RUnlock()
	return s.billing, s.billingCfg, s.billingSnapshotID
}

func NewServer(registry *pool.Registry, logger zerolog.Logger, startedAt time.Time, opts ...Option) *Server {
	s := &Server{
		pool:                   registry,
		log:                    logger,
		createdAt:              startedAt.Unix(),
		preflightThreshold:     4096,
		preflightTimeout:       5 * time.Second,
		recoveryBackoff:        30 * time.Second,
		recoveryMaxRetries:     3,
		recoveryProbe:          true,
		breakerThreshold:       2,
		breakerWindow:          120 * time.Second,
		requestTimeout:         300 * time.Second,
		failoverEnabled:        true,
		failoverTimeout:        5 * time.Second,
		retryPerAttemptTimeout: 60 * time.Second,
		stickyTTL:              30 * time.Minute,
		stickyMaxEntries:       10000,
		sticky:                 map[string]stickyEntry{},
		modelClasses:           map[string]config.ModelClassConfig{},
		provisionalWeight:      0.3,
		maxChatBodyBytes:       config.Default().Limits.MaxChatRequestBodyBytes,
		poolCheckLast:          map[string]time.Time{},
		poolCheckMaxEntries:    4096,
		poolCheckTTL:           time.Minute,
		receiptKeysLimiters:    map[string]receiptKeysBucket{},
		receiptKeysMaxEntries:  4096,
		receiptKeysTTL:         5 * time.Minute,
		now:                    func() time.Time { return time.Now().UTC() },
		version:                "dev",
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Get("/healthz", s.handleHealthz)
	r.Get("/v1/models", s.handleModels)
	r.Get("/v1/pool/check", s.handlePoolCheck)
	r.Get("/v1/receipt-keys/{provider_id}", s.handleReceiptKeys)
	// SPEC-015 §M.4 — SPEC-002 v1.6 candidate annotations.
	// Public, unauthenticated, rate-limited; serve the literal
	// signed catalog file and the catalog signing pubkey so a buyer-
	// side verifier or public installer can run the §M.3.2 catalog-
	// check path against this coordinator without reading /poolz.
	r.Get("/catalog/current", s.handleCatalogCurrent)
	r.Get("/catalog/pubkey", s.handleCatalogPubkey)
	r.Get("/catalog/{catalog_id}", s.handleCatalogFile)
	r.Post("/v1/chat/completions", s.handleChatCompletions)
	return r
}

func (s *Server) InternalHandler() http.Handler {
	r := chi.NewRouter()
	r.Delete("/internal/sticky", s.handleInternalStickyDelete)
	r.Get("/internal/routing", s.handleInternalRouting)
	return r
}

func (s *Server) handleInternalRouting(w http.ResponseWriter, r *http.Request) {
	if !s.internalBearerAuthorizedFull(r.Header, r.RemoteAddr, r.URL.Path) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Internal routing metadata requires coordinator authorization")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"sticky": map[string]any{
			"enabled":     s.stickyEnabled,
			"ttl_seconds": int(s.stickyTTL.Seconds()),
		},
		"retry": map[string]any{
			"max_retries":                   s.maxRetries,
			"retry_per_attempt_timeout_s":   int(s.retryPerAttemptTimeout.Seconds()),
			"max_providers_faulted_request": s.maxFaultedPerRequest,
		},
		"tier2": s.internalTier2Metadata(),
	})
}

func (s *Server) internalTier2Metadata() map[string]any {
	cfg := s.tier2Config()
	active := s.pillarAActive()
	observedModelHash := s.observedModelHashEvidence()
	modelHashState := "none"
	if active {
		providers := s.pool.Snapshot()
		var verified, mismatched, uncatalogued int
		for _, p := range providers {
			if !hasAvailableSlot(p) {
				continue
			}
			switch s.effectiveHashStatus(p, cfg) {
			case pool.HashStatusVerified:
				verified++
			case pool.HashStatusMismatch, pool.HashStatusInvalid:
				mismatched++
			case pool.HashStatusUncatalogued, pool.HashStatusCatalogUnavailable:
				uncatalogued++
			}
		}
		total := verified + mismatched + uncatalogued
		switch {
		case total == 0:
			if cfg.RequireHashVerified {
				modelHashState = "required"
			}
		case verified == total:
			modelHashState = "all"
		case verified > 0:
			modelHashState = "partial"
		default:
			modelHashState = "none"
		}
	}
	providers := s.pool.Snapshot()
	encryptedLeg := encryptedLegStateForProviders(providers)
	attestation := attestationStateForProviders(providers)
	return map[string]any{
		"phase": tier2.PhaseForConfigWithModelHashEvidence(cfg, observedModelHash),
		"model_hash": map[string]any{
			"active":              active,
			"state":               modelHashState,
			"require_verified":    cfg.RequireHashVerified,
			"catalog_configured":  strings.TrimSpace(cfg.CatalogPath) != "",
			"catalog_available":   tier2.Active(),
			"catalog_load_failed": tier2.LoadFailed(),
		},
		"encrypted_leg": map[string]any{
			"state":                      encryptedLeg.state,
			"encrypted_provider_count":   encryptedLeg.positive,
			"unencrypted_provider_count": encryptedLeg.negative,
			"mixed":                      encryptedLeg.state == "partial",
			"scope":                      "coordinator_to_provider_only",
		},
		"attestation": map[string]any{
			"state":                      attestation.state,
			"attested_provider_count":    attestation.positive,
			"unsupported_provider_count": attestation.negative,
			"mixed":                      attestation.state == "partial",
		},
		"behavioral_safety": map[string]any{
			"state":                behavioralSafetyState(cfg),
			"size_cap":             cfg.BehavioralSafetyEnabled && cfg.OutputSizeCapBytes > 0,
			"encoding_validation":  cfg.BehavioralSafetyEnabled && cfg.EncodingValidationEnabled,
			"ttft_anomaly_logging": cfg.BehavioralSafetyEnabled && cfg.ResponseTimeAnomalyEnabled,
		},
	}
}

type tier2PredicateState struct {
	state    string
	positive int
	negative int
}

func encryptedLegStateForProviders(providers []pool.Provider) tier2PredicateState {
	var encrypted, unencrypted int
	for _, p := range providers {
		if p.State != pool.StateReady {
			continue
		}
		if p.EncryptedLeg {
			encrypted++
		} else {
			unencrypted++
		}
	}
	total := encrypted + unencrypted
	state := "none"
	switch {
	case total == 0:
		state = "none"
	case encrypted == total:
		state = "all"
	case encrypted > 0:
		state = "partial"
	default:
		state = "none"
	}
	return tier2PredicateState{state: state, positive: encrypted, negative: unencrypted}
}

func attestationStateForProviders(providers []pool.Provider) tier2PredicateState {
	var attested, unsupported, total int
	for _, p := range providers {
		if p.State != pool.StateReady {
			continue
		}
		total++
		if p.AttestationStatus == pool.AttestationStatusAttested {
			attested++
		} else {
			unsupported++
		}
	}
	state := "none"
	switch {
	case total == 0:
		state = "none"
	case attested == total:
		state = "all"
	case attested > 0:
		state = "partial"
	case unsupported == total:
		state = "unsupported"
	default:
		state = "none"
	}
	return tier2PredicateState{state: state, positive: attested, negative: unsupported}
}

func behavioralSafetyState(cfg config.Tier2Config) string {
	return tier2.BehavioralSafetyState(cfg)
}

func (s *Server) observedModelHashEvidence() bool {
	for _, p := range s.pool.Snapshot() {
		if strings.TrimSpace(p.ModelHash) != "" && p.HashStatus != "" {
			return true
		}
	}
	return false
}

func (s *Server) handleInternalStickyDelete(w http.ResponseWriter, r *http.Request) {
	if !s.internalBearerAuthorizedFull(r.Header, r.RemoteAddr, r.URL.Path) {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Internal sticky purge requires coordinator authorization")
		return
	}
	accountID := strings.TrimSpace(r.URL.Query().Get("account_id"))
	if accountID == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Missing account_id")
		return
	}
	entries := 0
	if s.stickyEnabled {
		entries = s.purgeStickyAccount(accountID)
	}
	s.log.Info().Str("event", "sticky_purged_account").Str("account_id", accountID).Int("entries", entries).Msg("sticky affinity purged")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"purged": true, "entries": entries})
}

func isLoopbackRequest(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
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
		UptimeS:  int64(time.Since(time.Unix(s.createdAt, 0)).Seconds()),
		PoolSize: len(providers),
		Version:  s.version,
	}
	for _, p := range providers {
		switch p.State {
		case pool.StateReady:
			if p.AuthState != pool.AuthBearerlessDuplicate && len(p.PendingReceiptPubkey) == 0 {
				resp.PoolReady++
			}
		case pool.StateDegraded, pool.StateBusy:
			resp.PoolDegraded++
		case pool.StateDraining:
			resp.PoolDraining++
		case pool.StateUnavailable:
			resp.PoolUnavailable++
		}
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		s.log.Warn().Err(err).Msg("write healthz response failed")
	}
}

type poolCheckResponse struct {
	ProviderID string     `json:"provider_id"`
	Tier       pool.Tier  `json:"tier"`
	State      pool.State `json:"state"`
}

type receiptKeysResponse struct {
	ProviderID        string                     `json:"provider_id"`
	ReceiptPubkey     *string                    `json:"receipt_pubkey"`
	ReceiptPubkeyPrev *receiptKeysPreviousPubkey `json:"receipt_pubkey_prev"`
	FetchedAt         string                     `json:"fetched_at"`
}

type receiptKeysPreviousPubkey struct {
	Pubkey    string `json:"pubkey"`
	RotatedAt string `json:"rotated_at"`
	ExpiresAt string `json:"expires_at"`
}

func (s *Server) handlePoolCheck(w http.ResponseWriter, r *http.Request) {
	if !s.allowPoolCheck(r) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Pool check rate limit exceeded")
		return
	}
	providerID := strings.TrimSpace(r.URL.Query().Get("provider_id"))
	if providerID == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Missing provider_id")
		return
	}
	for _, p := range s.pool.Snapshot() {
		if p.ProviderID != providerID {
			continue
		}
		state := p.State
		if state == pool.StateBusy {
			state = pool.StateDegraded
		}
		s.log.Info().Str("provider_id", providerID).Str("state", string(state)).Msg("pool check hit")
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(poolCheckResponse{ProviderID: p.ProviderID, Tier: p.Tier, State: state}); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("write pool check response failed")
		}
		return
	}
	s.log.Info().Str("provider_id", providerID).Msg("pool check miss")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error":       "provider_not_found",
		"provider_id": providerID,
	})
}

func (s *Server) handleReceiptKeys(w http.ResponseWriter, r *http.Request) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Receipt keys rate limit exceeded")
		return
	}
	providerID := strings.TrimSpace(chi.URLParam(r, "provider_id"))
	if providerID == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Missing provider_id")
		return
	}
	provider, ok := s.pool.Resolve(providerID, "")
	if !ok {
		writeError(w, http.StatusNotFound, "provider_not_found", "Provider not found")
		return
	}

	now := s.now().UTC()
	resp := receiptKeysResponse{
		ProviderID: provider.ProviderID,
		FetchedAt:  now.Format(time.RFC3339),
	}
	if len(provider.ReceiptPubkey) > 0 {
		pubkey := base64.StdEncoding.EncodeToString(provider.ReceiptPubkey)
		resp.ReceiptPubkey = &pubkey
	}
	if provider.ReceiptPubkeyPrev != nil && now.Before(provider.ReceiptPubkeyPrev.ExpiresAt) {
		resp.ReceiptPubkeyPrev = &receiptKeysPreviousPubkey{
			Pubkey:    base64.StdEncoding.EncodeToString(provider.ReceiptPubkeyPrev.Pubkey),
			RotatedAt: provider.ReceiptPubkeyPrev.RotatedAt.UTC().Format(time.RFC3339),
			ExpiresAt: provider.ReceiptPubkeyPrev.ExpiresAt.UTC().Format(time.RFC3339),
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("write receipt keys response failed")
	}
}

// SPEC-015 §M.4 — serve the verified signed catalog bytes under the
// effectively-active catalog's id. Public, unauthenticated, rate-
// limited (shares the receipt-keys bucket so a single attacker
// cannot starve the buyer surface). 404 when (a) no catalog
// configured, (b) catalog failed to load/verify, OR (c) the path
// segment does not match the active catalog_id.
func (s *Server) handleCatalogFile(w http.ResponseWriter, r *http.Request) {
	s.serveCatalogFile(w, r, strings.TrimSpace(chi.URLParam(r, "catalog_id")))
}

// handleCatalogCurrent serves the effectively-active catalog without requiring
// clients to discover catalog_id through operator-only /poolz.
func (s *Server) handleCatalogCurrent(w http.ResponseWriter, r *http.Request) {
	s.serveCatalogFile(w, r, "")
}

func (s *Server) serveCatalogFile(w http.ResponseWriter, r *http.Request, requested string) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Catalog endpoint rate limit exceeded")
		return
	}
	active, data, ok := tier2.CatalogSnapshot()
	if !ok {
		writeError(w, http.StatusNotFound, "catalog_not_found", "Catalog not found")
		return
	}
	if requested != "" && requested != active {
		writeError(w, http.StatusNotFound, "catalog_not_found", "Catalog not found")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	if _, err := w.Write(data); err != nil {
		s.log.Warn().Err(err).Str("catalog_id", active).Msg("write catalog file response failed")
	}
}

// SPEC-015 §M.4 — serve the catalog signing pubkey.
// `{"pubkey":"<43-char base64url-unpadded>","alg":"Ed25519"}`. The
// pubkey comes from Tier2Config.CatalogPublicKey, which the
// coordinator already uses to verify the loaded catalog — so the
// trust root is the same operator-configured key (§M.3.3 operator-
// mutable trust posture, inherited from §10.7).
func (s *Server) handleCatalogPubkey(w http.ResponseWriter, r *http.Request) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Catalog endpoint rate limit exceeded")
		return
	}
	cfg := s.tier2Config()
	pubkey := strings.TrimSpace(cfg.CatalogPublicKey)
	if !tier2.Active() || pubkey == "" {
		writeError(w, http.StatusNotFound, "catalog_not_found", "Catalog not found")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"pubkey": pubkey,
		"alg":    "Ed25519",
	}); err != nil {
		s.log.Warn().Err(err).Msg("write catalog pubkey response failed")
	}
}

func (s *Server) allowPoolCheck(r *http.Request) bool {
	key := poolCheckClientKey(r)
	now := s.now()
	s.poolCheckMu.Lock()
	defer s.poolCheckMu.Unlock()
	s.evictPoolCheckEntries(now)
	if prev, ok := s.poolCheckLast[key]; ok {
		if now.Sub(prev) < time.Second {
			return false
		}
	}
	s.poolCheckLast[key] = now
	s.evictPoolCheckEntries(now)
	return true
}

func (s *Server) allowReceiptKeys(r *http.Request) bool {
	const (
		receiptKeysRatePerSecond = 10.0
		receiptKeysBurst         = 10.0
	)
	key := poolCheckClientKey(r)
	now := s.now()
	s.receiptKeysMu.Lock()
	defer s.receiptKeysMu.Unlock()
	s.evictReceiptKeyEntries(now)

	bucket, ok := s.receiptKeysLimiters[key]
	if !ok {
		bucket = receiptKeysBucket{tokens: receiptKeysBurst, last: now}
	}
	if bucket.last.IsZero() {
		bucket.last = now
	}
	if elapsed := now.Sub(bucket.last).Seconds(); elapsed > 0 {
		bucket.tokens = math.Min(receiptKeysBurst, bucket.tokens+elapsed*receiptKeysRatePerSecond)
		bucket.last = now
	}
	if bucket.tokens < 1 {
		s.receiptKeysLimiters[key] = bucket
		return false
	}
	bucket.tokens--
	bucket.last = now
	s.receiptKeysLimiters[key] = bucket
	s.evictReceiptKeyEntries(now)
	return true
}

func (s *Server) evictPoolCheckEntries(now time.Time) {
	cutoff := now.Add(-s.poolCheckTTL)
	for key, seen := range s.poolCheckLast {
		if seen.Before(cutoff) {
			delete(s.poolCheckLast, key)
		}
	}
	for len(s.poolCheckLast) > s.poolCheckMaxEntries {
		var oldestKey string
		var oldest time.Time
		for key, seen := range s.poolCheckLast {
			if oldestKey == "" || seen.Before(oldest) {
				oldestKey = key
				oldest = seen
			}
		}
		if oldestKey == "" {
			return
		}
		delete(s.poolCheckLast, oldestKey)
	}
}

func (s *Server) evictReceiptKeyEntries(now time.Time) {
	cutoff := now.Add(-s.receiptKeysTTL)
	for key, bucket := range s.receiptKeysLimiters {
		if bucket.last.Before(cutoff) {
			delete(s.receiptKeysLimiters, key)
		}
	}
	for len(s.receiptKeysLimiters) > s.receiptKeysMaxEntries {
		var oldestKey string
		var oldest time.Time
		for key, bucket := range s.receiptKeysLimiters {
			if oldestKey == "" || bucket.last.Before(oldest) {
				oldestKey = key
				oldest = bucket.last
			}
		}
		if oldestKey == "" {
			return
		}
		delete(s.receiptKeysLimiters, oldestKey)
	}
}

// poolCheckClientKey returns the per-source key used for the
// /poolz, /v1/receipt-keys/*, and /catalog/* rate-limit buckets.
//
// Production sits behind nginx on loopback (see
// phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf) so
// every public buyer's r.RemoteAddr is 127.0.0.1 — keying on that
// alone collapses every public buyer into one shared bucket and lets
// any single caller starve the rate-limit pool for everyone else.
//
// Mirrors ws.remoteIPForUnauthSemaphore: when r.RemoteAddr is a
// loopback address, honor X-Real-IP (which the on-host nginx site
// sets). Direct, non-loopback hits (no proxy in front) use
// r.RemoteAddr unchanged so an attacker on the open internet cannot
// spoof their bucket key.
func poolCheckClientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		host = r.RemoteAddr
	}
	if isLoopbackHost(host) {
		if realIP := strings.TrimSpace(r.Header.Get("X-Real-IP")); realIP != "" {
			return realIP
		}
	}
	if host == "" {
		return r.RemoteAddr
	}
	return host
}

func isLoopbackHost(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}

type modelsResponse struct {
	Object string         `json:"object"`
	Data   []modelEntry   `json:"data"`
	Tier2  map[string]any `json:"tier2,omitempty"`
}

type modelEntry struct {
	ID               string            `json:"id"`
	Object           string            `json:"object"`
	Created          int64             `json:"created"`
	OwnedBy          string            `json:"owned_by"`
	ProviderCount    int               `json:"provider_count"`
	MaxContextTokens int               `json:"max_context_tokens"`
	TotalSlots       int               `json:"total_slots"`
	Objective        string            `json:"objective,omitempty"`
	Members          []string          `json:"members,omitempty"`
	HashVerified     interface{}       `json:"hash_verified,omitempty"`
	HashVerification *hashVerification `json:"hash_verification,omitempty"`
}

type hashVerification struct {
	Status                    string `json:"status"`
	VerifiedProviderCount     int    `json:"verified_provider_count"`
	UncataloguedProviderCount int    `json:"uncatalogued_provider_count"`
	MismatchProviderCount     int    `json:"mismatch_provider_count"`
	InvalidProviderCount      int    `json:"invalid_provider_count"`
	Catalogued                bool   `json:"catalogued"`
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	models := map[string]modelEntry{}
	providers := s.pool.Snapshot()
	cfg := s.tier2Config()
	pillarAActive := tier2.ModelHashActive(cfg)
	tier2Active := tier2.ConfigActive(cfg)
	for _, p := range providers {
		if pillarAActive && !p.RoutingEligible() {
			continue
		}
		if !pillarAActive && (p.State != pool.StateReady || p.AuthState == pool.AuthBearerlessDuplicate || len(p.PendingReceiptPubkey) > 0) {
			continue
		}
		excluded := tier2Active && s.tier2ProviderExcludedForConfig(p, cfg)
		entry := models[p.ModelID]
		if entry.ID == "" {
			entry = modelEntry{
				ID:      p.ModelID,
				Object:  "model",
				Created: s.createdAt,
				OwnedBy: "macprovider",
			}
		}
		if !excluded {
			entry.ProviderCount++
			if p.MaxContextTokens > entry.MaxContextTokens {
				entry.MaxContextTokens = p.MaxContextTokens
			}
			entry.TotalSlots += p.SlotsTotal
		}
		models[p.ModelID] = entry
	}

	data := make([]modelEntry, 0, len(models))
	for _, entry := range models {
		data = append(data, entry)
	}
	for name, class := range s.modelClasses {
		data = append(data, modelEntry{
			ID: name, Object: "model", Created: s.createdAt, OwnedBy: "macprovider",
			Objective: class.Objective, Members: append([]string(nil), modelClassMembers(&class)...),
		})
	}
	if pillarAActive {
		for i := range data {
			if data[i].Objective != "" {
				continue
			}
			s.applyHashVerification(&data[i], providers, cfg)
		}
	}
	sort.Slice(data, func(i, j int) bool {
		return data[i].ID < data[j].ID
	})

	w.Header().Set("Content-Type", "application/json")
	resp := modelsResponse{Object: "list", Data: data}
	if tier2Active {
		resp.Tier2 = s.internalTier2Metadata()
	}
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		s.log.Warn().Err(err).Msg("write models response failed")
	}
}

func (s *Server) pillarAActive() bool {
	return tier2.ModelHashActive(s.tier2Config())
}

func (s *Server) applyHashVerification(entry *modelEntry, providers []pool.Provider, cfg config.Tier2Config) {
	modelProviders := make([]pool.Provider, 0)
	catalogUnavailable := false
	for _, p := range providers {
		if !hasAvailableSlot(p) || !modelIDEqual(p.ModelID, entry.ID) {
			continue
		}
		status := s.effectiveHashStatus(p, cfg)
		if status == pool.HashStatusCatalogUnavailable {
			catalogUnavailable = true
		}
		p.HashStatus = status
		modelProviders = append(modelProviders, p)
	}
	counts := tier2.CountsForProviders(entry.ID, modelProviders)
	status := "all_uncatalogued"
	hashVerified := interface{}("uncatalogued")
	switch {
	case catalogUnavailable || tier2.CatalogUnavailable():
		status = "catalog_unavailable"
		hashVerified = false
	case counts.Mismatch > 0 || counts.Invalid > 0:
		status = "mismatch"
		hashVerified = false
	case counts.Verified > 0 && counts.Uncatalogued == 0:
		status = "all_verified"
		hashVerified = true
	case counts.Verified > 0:
		status = "partial"
		hashVerified = false
	default:
		status = "all_uncatalogued"
		hashVerified = "uncatalogued"
	}
	entry.HashVerified = hashVerified
	entry.HashVerification = &hashVerification{
		Status:                    status,
		VerifiedProviderCount:     counts.Verified,
		UncataloguedProviderCount: counts.Uncatalogued,
		MismatchProviderCount:     counts.Mismatch,
		InvalidProviderCount:      counts.Invalid,
		Catalogued:                tier2.Catalogued(entry.ID),
	}
}

type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
	raw      json.RawMessage
}

type chatMessage struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	ToolCallID string          `json:"tool_call_id"`
	ToolCalls  json.RawMessage `json:"tool_calls"`
}

func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	externalRequestID := strings.TrimSpace(r.Header.Get("X-Request-ID"))
	requestID := requestIDForBuyerRequest()
	routingRequestID := uuid.NewString()
	originalRequestID := requestID
	startedAt := s.now()
	// state is allocated up-front so the billingRecorder captures the
	// pointer — pre-1c the inline logRowWithBilling closure read
	// mutable locals (routingDone, explicitRetries); post-1c those
	// locals migrated into forwardState; M3-10 hoists the closure
	// itself into *billingRecorder. The recorder still needs the live
	// state values at log-write time, so it holds *forwardState.
	state := &forwardState{
		routingDone:   startedAt,
		faultedRoutes: map[string]struct{}{},
	}
	// M3-10 (ARCH-6 close-out): the previously-inline logRowWithBilling
	// closure now lives as *billingRecorder. setModel / setStream /
	// setRequestID land before the first provider-bound recordRow call,
	// preserving the pre-refactor closure's "latest value at fire time"
	// semantics for what used to be captured outer-scope variables.
	rec := s.newBillingRecorder(r, state, startedAt, originalRequestID)
	maxBodyBytes := s.maxChatBodyBytes
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	if err != nil {
		rec.logBuyerFailure(http.StatusBadRequest, "Could not read request body")
		writeError(w, http.StatusBadRequest, "invalid_request", "Could not read request body")
		return
	}
	rec.setModel(modelForRequestLog(body))
	if int64(len(body)) > maxBodyBytes {
		rec.logBuyerFailure(http.StatusRequestEntityTooLarge, "Request body too large")
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "Request body too large")
		return
	}
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		rec.logBuyerFailure(status, msg)
		writeError(w, status, code, msg)
		return
	}
	rec.setModel(req.Model)
	rec.setStream(req.Stream)
	if idempotencyKey := normalizeIdempotencyKey(r.Header.Get("Idempotency-Key")); idempotencyKey != "" {
		if s.reqLogStore == nil {
			rec.logBuyerFailure(http.StatusServiceUnavailable, "Idempotency-Key requires durable request logging")
			writeError(w, http.StatusServiceUnavailable, "idempotency_unavailable", "Idempotency-Key requires durable request logging")
			return
		}
		bodyHash := sha256.Sum256(body)
		reservedRequestID, replay, err := s.reqLogStore.ReserveIdempotencyKey(r.Context(), idempotencyKey, hex.EncodeToString(bodyHash[:]), originalRequestID, startedAt)
		if err != nil {
			if errors.Is(err, requestlog.ErrIdempotencyConflict) {
				rec.logBuyerFailure(http.StatusConflict, "Idempotency-Key was already used with a different request body")
				writeError(w, http.StatusConflict, "idempotency_key_body_mismatch", "Idempotency-Key was already used with a different request body")
				return
			}
			s.log.Warn().Err(err).Msg("idempotency reservation failed")
			rec.logBuyerFailure(http.StatusInternalServerError, "Could not reserve idempotency key")
			writeError(w, http.StatusInternalServerError, "idempotency_reservation_failed", "Could not reserve idempotency key")
			return
		}
		originalRequestID = reservedRequestID
		requestID = reservedRequestID
		routingRequestID = reservedRequestID
		rec.setRequestID(reservedRequestID)
		if replay {
			w.Header().Set("X-Request-ID", reservedRequestID)
			rec.logBuyerFailure(http.StatusConflict, "Idempotency-Key request is already recorded")
			writeError(w, http.StatusConflict, "idempotency_key_replayed", "Idempotency-Key request is already recorded")
			return
		}
	}
	if !s.pool.ModelKnown(req.Model) && s.resolveModelClass(req.Model) == nil {
		rec.logBuyerFailure(http.StatusNotFound, "No provider has advertised model "+req.Model)
		writeError(w, http.StatusNotFound, "model_not_found", "No provider has advertised model "+req.Model)
		return
	}
	// logAttempt's retried argument is supplied by the caller — M2-1c
	// inlines state.explicitRetries at each call site instead of having
	// the closure capture the outer-scope `explicitRetries`. Pre-1c the
	// closure read from the captured variable; post-1c the three
	// unified-loop helpers (forwardStreamSequence, forwardWSNonStream-
	// Sequence, forwardHTTPSequence) bump state.explicitRetries and
	// pass it in, which keeps every log row consistent with the
	// transport's view of "what retry am I on" without relying on
	// closure-by-reference semantics that wouldn't survive the helper
	// boundary.
	//
	// M3-10: logAttempt stays as a local closure because the
	// estimated-prompt-token computation reads req.raw (the chat
	// request body), which is local to handleChatCompletions. The
	// closure delegates the actual row write to rec.recordRow, so the
	// billing/request-log orchestration that ARCH-6 flagged still
	// lives in *billingRecorder — only the per-attempt token-estimate
	// adapter remains here.
	logAttempt := func(provider pool.Provider, fallbackStatus int, attempt requestLogAttempt, retried int) {
		status := attempt.Status
		if status == 0 {
			status = fallbackStatus
		}
		if attempt.PromptTokens == nil && attempt.ErrorCode == "" && (attempt.EstimatedCompTokens != nil || status == http.StatusBadGateway || status == http.StatusGatewayTimeout) {
			estimatedPrompt := int64(estimateTokens(req.raw))
			attempt.PromptTokens = &estimatedPrompt
		}
		rec.recordRow(provider.AssignedID, provider.ProviderID, status, attempt.PromptTokens, attempt.CompletionTokens, attempt.Error, attempt.ErrorCode, retried, attempt.EstimatedCompTokens, attempt.FaultFlag)
	}
	shouldLogAttempt := func(attempt requestLogAttempt) bool {
		return attempt.Status != 0 || attempt.PromptTokens != nil || attempt.CompletionTokens != nil || attempt.EstimatedCompTokens != nil || attempt.Error != "" || attempt.ErrorCode != ""
	}
	provider, routeErr := s.selectProvider(routingRequestID, req, r.Header)
	if routeErr != nil {
		state.routingDone = s.now()
		rec.logRow("", routeErr.status, nil, nil, routeErr.message, "", 0)
		writeRouteError(w, routeErr)
		return
	}
	state.routingDone = s.now()
	state.provider = provider
	// M2-1c: the three transport loops (streaming, WS-non-streaming, HTTP)
	// previously duplicated the retry/failover/busy-marking decision tree.
	// They now share three thin helpers (forwardStreamSequence,
	// forwardWSNonStreamSequence, forwardHTTPSequence) that drive all
	// transition decisions off transportResult flags + *forwardState.
	// Per-loop scratch (excluded, failoverAttempted) lives here in
	// handleChatCompletions' local scope per audits/2026-06-10/
	// M2-1B_DESIGN.md §forwardState — not on the state struct, because
	// each call into the helpers is one transport sequence and scratch
	// does not survive transport boundaries.
	if req.Stream {
		excluded := map[string]struct{}{}
		s.forwardStreamSequence(w, r, req, requestID, originalRequestID, externalRequestID, startedAt, state, excluded, rec, logAttempt, shouldLogAttempt)
		return
	}
	if state.provider.IsWSTunneled() {
		excluded := map[string]struct{}{}
		shouldFallThroughToHTTP := s.forwardWSNonStreamSequence(w, r, req, requestID, originalRequestID, externalRequestID, startedAt, state, excluded, rec, logAttempt, shouldLogAttempt)
		if !shouldFallThroughToHTTP {
			return
		}
	}
	excluded := map[string]struct{}{}
	for key := range state.faultedRoutes {
		excluded[key] = struct{}{}
	}
	excluded[routeKey(state.provider)] = struct{}{}
	s.forwardHTTPSequence(w, r, req, requestID, originalRequestID, startedAt, state, excluded, rec)
}

// forwardStreamSequence is the unified loop body for streaming requests
// (req.Stream=true). It dispatches per-attempt to either forwardWS
// (WS-tunneled streaming) or forwardStreaming (HTTP streaming), pipes
// the native result through the appropriate classifier, and then drives
// retry / failover / busy-marking / committed-early-exit decisions off
// the resulting transportResult flags — the M2-1c unification of the
// three previously-duplicated transport loops at server.go:1085-1170.
//
// Audit-flagged invariants preserved:
//   - attempt_n numbering: identical across all transport types (logAttempt
//     consults explicitRetries which is bumped exclusively by
//     advanceToNextProvider, never by failoverCandidate).
//   - logAttempt row sequence: emitted once per non-cancelled attempt
//     before any branch decision, matching pre-refactor behaviour.
//   - HTTP-only per-attempt context timeout: STAYS inside forwardStreaming,
//     not in the unified loop (the loop never knows about it).
//   - WS-streaming pre-first-chunk failoverEligible + retryable=true is
//     branched on the classifier flags, not on transport kind — the
//     classifier already encoded this divergence in M2-1b.
func (s *Server) forwardStreamSequence(
	w http.ResponseWriter,
	r *http.Request,
	req chatRequest,
	requestID, originalRequestID, externalRequestID string,
	startedAt time.Time,
	state *forwardState,
	excluded map[string]struct{},
	rec *billingRecorder,
	logAttempt func(pool.Provider, int, requestLogAttempt, int),
	shouldLogAttempt func(requestLogAttempt) bool,
) {
	failoverAttempted := false
	for {
		dispatchBody, err := dispatchBodyForProvider(req, state.provider)
		if err != nil {
			rec.logRow(state.provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			return
		}
		wsTunneled := state.provider.IsWSTunneled()
		var tr transportResult
		var nativeResult wsForwardResult
		if wsTunneled {
			result, attempt := s.forwardWS(w, r, requestID, dispatchBody, state.provider, true, s.attemptTimeout(r))
			// Per pre-refactor server.go:1130/1131 — WS-streaming status
			// for shouldRetry + logAttempt is statusForForwardResult(result).
			tr = classifyStreamResult(result, statusForForwardResult(result), attempt)
			nativeResult = result
		} else {
			result, status, attempt := s.forwardStreaming(w, r, requestID, dispatchBody, state.provider, req.Model, s.attemptTimeout(r))
			tr = classifyStreamResult(result, status, attempt)
			nativeResult = result
		}
		// Committed-early-exit: the streaming first-chunk-received path
		// (wsForwardProviderDisconnectedCommitted, wsForwardCancelled).
		// Encoded as committed=true by classifyStreamResult.
		if tr.committed {
			if tr.cancelled {
				if shouldLogAttempt(tr.attempt) {
					logAttempt(state.provider, http.StatusOK, tr.attempt, state.explicitRetries)
				}
			} else {
				logAttempt(state.provider, http.StatusOK, tr.attempt, state.explicitRetries)
				if wsTunneled && nativeResult == wsForwardProviderDisconnectedCommitted {
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "stream_terminal", "")
				}
			}
			return
		}
		// Success: classifyStreamResult sets status=200, no behaviour flags.
		if nativeResult == wsForwardComplete {
			logAttempt(state.provider, http.StatusOK, tr.attempt, state.explicitRetries)
			if wsTunneled {
				s.stickyStore(r.Header, state.provider, req.Model)
			}
			return
		}
		excluded[routeKey(state.provider)] = struct{}{}
		state.faultedRoutes[routeKey(state.provider)] = struct{}{}
		if tr.markBusy {
			s.pool.MarkState(state.provider.ProviderID, state.provider.AssignedID, pool.StateBusy)
		}
		// failoverEligible: WS-streaming pre-first-chunk disconnect path.
		// Only set by classifyStreamResult on wsForwardProviderDisconnected
		// in the WS-tunneled branch. Streaming-pre-chunk falls through to
		// shouldRetry if failover misses (retryable=true).
		if tr.failoverEligible && wsTunneled {
			if !failoverAttempted && !hasPinnedRoute(r.Header) {
				next, ok := s.failoverCandidate(uuid.NewString(), req, r.Header, state.provider, excluded)
				if ok {
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "failover", next.ProviderID)
					failoverAttempted = true
					state.provider = next
					continue
				}
			}
			s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "fast_fail", "")
		}
		// Curated attempt.Error: classify*Result already populated
		// tr.attempt with the curated error string. logAttempt reads
		// from tr.attempt — never from a raw tr.err mirror. Carry-forward
		// from PR #61 security audit.
		if !s.shouldRetry(r, startedAt, state.explicitRetries, state.faultedProviders, tr.status, nil) {
			logAttempt(state.provider, tr.status, tr.attempt, state.explicitRetries)
			writeStreamForwardError(w, nativeResult)
			return
		}
		logAttempt(state.provider, tr.status, tr.attempt, state.explicitRetries)
		nextRouteID, ok := s.advanceToNextProvider(w, r, req, state, excluded, rec)
		if !ok {
			return
		}
		excluded[routeKey(state.provider)] = struct{}{}
		s.logRoutingDecision(nextRouteID, []pool.Provider{state.provider}, "retry", 0, 0, "retry_"+itoa(state.explicitRetries), state.provider.ProviderID)
	}
}

// forwardWSNonStreamSequence is the unified loop body for non-streaming
// WS-tunneled requests — collapses server.go:1172-1257 pre-refactor.
// Returns shouldFallThroughToHTTP=true when the loop's "advance picked
// a non-WS provider" break-condition fires, signalling the caller to
// run the HTTP non-streaming loop on state.provider.
//
// Audit-flagged invariants preserved:
//   - WS-non-streaming failoverEligible carries retryable=false in the
//     classifier; the loop branches on the flag pair to fast-fail with
//     502 when failover misses, NOT falling through to shouldRetry.
//     This is the audit-cited intentional divergence vs streaming.
//   - Cancelled / Failed / Unavailable short-circuit return without
//     advance, matching pre-refactor behaviour at server.go:1208-1213.
func (s *Server) forwardWSNonStreamSequence(
	w http.ResponseWriter,
	r *http.Request,
	req chatRequest,
	requestID, originalRequestID, externalRequestID string,
	startedAt time.Time,
	state *forwardState,
	excluded map[string]struct{},
	rec *billingRecorder,
	logAttempt func(pool.Provider, int, requestLogAttempt, int),
	shouldLogAttempt func(requestLogAttempt) bool,
) (shouldFallThroughToHTTP bool) {
	failoverAttempted := false
	for {
		dispatchBody, err := dispatchBodyForProvider(req, state.provider)
		if err != nil {
			rec.logRow(state.provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			return false
		}
		result, attempt := s.forwardWS(w, r, requestID, dispatchBody, state.provider, false, s.attemptTimeout(r))
		tr := classifyWSResult(result, attempt)
		if result == wsForwardComplete {
			logAttempt(state.provider, http.StatusOK, tr.attempt, state.explicitRetries)
			s.stickyStore(r.Header, state.provider, req.Model)
			return false
		}
		// Cancelled / Failed / Unavailable: short-circuit return.
		if result == wsForwardFailed || result == wsForwardUnavailable || result == wsForwardCancelled {
			if result != wsForwardCancelled || shouldLogAttempt(tr.attempt) {
				logAttempt(state.provider, statusForForwardResult(result), tr.attempt, state.explicitRetries)
			}
			return false
		}
		// Timeout: classifier marks retryable=true, no failoverEligible.
		// Runs through shouldRetry + advanceToNextProvider; on advance
		// the loop continues if the next provider is WS, or breaks to
		// HTTP fallback otherwise.
		if result == wsForwardTimedOut {
			excluded[routeKey(state.provider)] = struct{}{}
			state.faultedRoutes[routeKey(state.provider)] = struct{}{}
			if !s.shouldRetry(r, startedAt, state.explicitRetries, state.faultedProviders, http.StatusGatewayTimeout, nil) {
				logAttempt(state.provider, http.StatusGatewayTimeout, tr.attempt, state.explicitRetries)
				writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
				return false
			}
			logAttempt(state.provider, http.StatusGatewayTimeout, tr.attempt, state.explicitRetries)
			_, ok := s.advanceToNextProvider(w, r, req, state, excluded, rec)
			if !ok {
				return false
			}
			excluded[routeKey(state.provider)] = struct{}{}
			if state.provider.IsWSTunneled() {
				continue
			}
			return true
		}
		// Provider disconnected (pre-commit): failoverEligible + retryable=false.
		// The non-streaming WS loop fast-fails with 502 when failover misses
		// (audit-flagged intentional divergence vs streaming).
		if tr.failoverEligible {
			excluded[routeKey(state.provider)] = struct{}{}
			state.faultedRoutes[routeKey(state.provider)] = struct{}{}
			if failoverAttempted || hasPinnedRoute(r.Header) {
				s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "fast_fail", "")
				logAttempt(state.provider, http.StatusBadGateway, tr.attempt, state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_disconnected", "Selected provider disconnected; buyer should retry")
				return false
			}
			next, ok := s.failoverCandidate(uuid.NewString(), req, r.Header, state.provider, excluded)
			if !ok {
				s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "fast_fail", "")
				logAttempt(state.provider, http.StatusBadGateway, tr.attempt, state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_disconnected", "Selected provider disconnected; buyer should retry")
				return false
			}
			s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "failover", next.ProviderID)
			logAttempt(state.provider, http.StatusBadGateway, tr.attempt, state.explicitRetries)
			failoverAttempted = true
			state.provider = next
			if state.provider.IsWSTunneled() {
				continue
			}
			return true
		}
		// Queue full: markBusy + retryable=true. The audit (post-merge
		// verification of PR #91 — Q3 BLOCKING) called out the prior
		// inline state mutation here as the concrete shared-state
		// bypass that kept ARCH-1 / CODE-1 at PARTIAL_RESOLVED_DIFFERENTLY.
		// M2-1d routes this path through advanceToNextProvider so the
		// "pick next provider + bump explicitRetries/faultedProviders"
		// tail lives in exactly one place — same as the timeout branch
		// above and the two siblings (forwardStreamSequence,
		// forwardHTTPSequence).
		//
		// Byte-identical to PR #91 baseline: classifier sets markBusy=true
		// only on wsForwardQueueFull (the only case that falls through to
		// this point), so the unconditional MarkState + excluded-add +
		// logAttempt block here matches the pre-1d guarded behaviour.
		// advanceToNextProvider performs the identical mutation order
		// (selectProviderExcluding → routingDone → explicitRetries++ →
		// faultedProviders++ → state.provider = next) as the prior inline
		// block, preserving the request_log row sequence the billing
		// ledger keys off (verified by forward_loop_test.go scenario 5).
		s.pool.MarkState(state.provider.ProviderID, state.provider.AssignedID, pool.StateBusy)
		excluded[routeKey(state.provider)] = struct{}{}
		logAttempt(state.provider, http.StatusBadGateway, tr.attempt, state.explicitRetries)
		if _, ok := s.advanceToNextProvider(w, r, req, state, excluded, rec); !ok {
			return false
		}
		if !state.provider.IsWSTunneled() {
			return true
		}
	}
}

// forwardHTTPSequence is the unified loop body for HTTP non-streaming
// requests — collapses server.go:1264-1356 pre-refactor.
//
// Audit-flagged invariants preserved:
//   - HTTP per-attempt context timeout stays HTTP-only — set up
//     inside this function via context.WithTimeout(r.Context(), ...)
//     when retryRequested && retryPerAttemptTimeout > 0; the timeout
//     is never visible at the unified-loop level for other transports.
//   - handleProviderFailure called on non-200 status (HTTP-only fault
//     tracking — WS path has its own MarkState semantics via classifier
//     markBusy flag).
func (s *Server) forwardHTTPSequence(
	w http.ResponseWriter,
	r *http.Request,
	req chatRequest,
	requestID, originalRequestID string,
	startedAt time.Time,
	state *forwardState,
	excluded map[string]struct{},
	rec *billingRecorder,
) {
	for {
		dispatchBody, err := dispatchBodyForProvider(req, state.provider)
		if err != nil {
			rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			return
		}
		upstreamURL := state.provider.EndpointURL + "/v1/chat/completions"
		attemptCtx := r.Context()
		cancelAttempt := func() {}
		retryRequested := s.maxRetries > 0 && retryHeaderLimit(r.Header.Get("X-MacProvider-Retry")) > 0
		if retryRequested && s.retryPerAttemptTimeout > 0 {
			attemptCtx, cancelAttempt = context.WithTimeout(r.Context(), s.retryPerAttemptTimeout)
		}
		upReq, err := http.NewRequestWithContext(attemptCtx, http.MethodPost, upstreamURL, bytes.NewReader(dispatchBody))
		if err != nil {
			cancelAttempt()
			rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			return
		}
		upReq.Header.Set("Content-Type", "application/json")
		upReq.Header.Set("X-Request-ID", originalRequestID)
		resp, err := providerhttp.Client.Do(upReq)
		if err == nil && resp != nil && resp.StatusCode == http.StatusOK {
			respBody, readErr := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
			_ = resp.Body.Close()
			if readErr != nil {
				cancelAttempt()
				rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return
			}
			promptTok, completionTok := tokenPointersFromChatResponse(respBody)
			estimatedCompletion := s.observedCompletionTokensFromBytes(len(respBody))
			if err := rec.logProviderRowWithEstimate(state.provider, http.StatusOK, promptTok, completionTok, "", "", state.explicitRetries, estimatedCompletion); err != nil {
				cancelAttempt()
				writeError(w, http.StatusInternalServerError, "request_log_failed", "Could not durably log request")
				return
			}
			copyReceiptHeaderForProvider(w.Header(), resp.Header, state.provider)
			w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
			if w.Header().Get("Content-Type") == "" {
				w.Header().Set("Content-Type", "application/json")
			}
			w.Header().Set("X-MacProvider-Provider", state.provider.ProviderID)
			w.Header().Set("X-MacProvider-Route", state.provider.AssignedID)
			w.WriteHeader(http.StatusOK)
			s.stickyStore(r.Header, state.provider, req.Model)
			_, _ = w.Write(respBody)
			cancelAttempt()
			return
		}
		status := 0
		attempt := requestLogAttempt{}
		if resp != nil {
			status = resp.StatusCode
			respBody, _ := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
			_ = resp.Body.Close()
			attempt.ErrorCode = nullUsageProviderErrorCode(respBody)
			if attempt.ErrorCode != "" && providerReceiptEligible(state.provider) {
				// Round-1 audit H1: receipt-bearing null-usage errors used to
				// return immediately to the buyer, bypassing the
				// `X-MacProvider-Retries: N` budget. Only short-circuit when
				// the retry budget is genuinely exhausted; otherwise fall
				// through to the failover path so the buyer's explicit retry
				// budget is honored. The receipt is preserved on the final
				// attempt.
				if !s.shouldRetry(r, startedAt, state.explicitRetries, state.faultedProviders, status, nil) {
					if err := rec.logProviderRow(state.provider, status, nil, nil, http.StatusText(status), attempt.ErrorCode, state.explicitRetries); err != nil {
						cancelAttempt()
						writeError(w, http.StatusInternalServerError, "request_log_failed", "Could not durably log request")
						return
					}
					copyReceiptHeaderForProvider(w.Header(), resp.Header, state.provider)
					w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
					if w.Header().Get("Content-Type") == "" {
						w.Header().Set("Content-Type", "application/json")
					}
					w.Header().Set("X-MacProvider-Provider", state.provider.ProviderID)
					w.Header().Set("X-MacProvider-Route", state.provider.AssignedID)
					w.WriteHeader(status)
					_, _ = w.Write(respBody)
					cancelAttempt()
					return
				}
			}
		}
		cancelAttempt()
		// classifyHTTPResult is the canonical translation of the
		// (resp, err) pair into transportResult.status (with the
		// nil-response → 502 normalisation) and tr.retryable. The HTTP
		// failure path keeps its inline shouldRetry + logProviderRow
		// shape because logProviderRow vs logAttempt differ in
		// caller-supplied message wording (the HTTP-specific
		// "provider_timeout" / "provider_error" disambiguation lives
		// here, not in the classifier). Using tr.status downstream
		// pulls the status-derivation contract into one place across
		// HTTP/streaming/WS.
		tr := classifyHTTPResult(resp, err, attempt)
		s.log.Warn().Err(err).Int("status", status).Str("request_id", requestID).Str("provider_id", state.provider.ProviderID).Msg("provider request failed")
		if status != 0 {
			s.handleProviderFailure(state.provider, status)
		}
		if !s.shouldRetry(r, startedAt, state.explicitRetries, state.faultedProviders, status, err) {
			if retryRequested && status == http.StatusGatewayTimeout {
				rec.logProviderRow(state.provider, http.StatusGatewayTimeout, nil, nil, "Selected provider timed out; buyer should retry", attempt.ErrorCode, state.explicitRetries)
				writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
				return
			}
			rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", attempt.ErrorCode, state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
			return
		}
		// tr.status already encodes the nil-response → 502 normalisation
		// the pre-refactor code did inline (failStatus := status; if
		// failStatus == 0 { failStatus = http.StatusBadGateway }). Read
		// it from the classifier so HTTP and streaming/WS paths share
		// the same status-derivation contract.
		failStatus := tr.status
		errMsg := "Selected provider failed; buyer should retry"
		if err != nil {
			errMsg = err.Error()
		}
		rec.logProviderRow(state.provider, failStatus, nil, nil, errMsg, attempt.ErrorCode, state.explicitRetries)
		nextRouteID, ok := s.advanceToNextProvider(w, r, req, state, excluded, rec)
		if !ok {
			return
		}
		excluded[routeKey(state.provider)] = struct{}{}
		s.logRoutingDecision(nextRouteID, []pool.Provider{state.provider}, "retry", 0, 0, "retry_"+itoa(state.explicitRetries), state.provider.ProviderID)
	}
}

// advanceToNextProvider performs the per-retry "pick a fresh provider,
// dispatch the route-error response on no-candidate, bump explicitRetries
// and faultedProviders" tail that the 2026-06-10 audit (ARCH-1 / CODE-1)
// flagged as a 5×-duplicated block inside handleChatCompletions. This
// sub-PR (M2-1a) is a pure mechanical extraction with zero behaviour
// diff — the caller is still responsible for the per-site suffix
// (updating excluded, emitting logRoutingDecision, and any loop-control
// continue/break) because those vary across callsites. Sub-PRs 1b and 1c
// unify the three transport loops into a single failover skeleton.
//
// M3-10 (ARCH-6 close-out): the route-error logRow that this helper
// emits on no-candidate now routes through *billingRecorder, matching
// the rest of the request-log/billing orchestration that the audit
// hoisted out of inline closures.
//
// Returns (next provider, nextRouteID used for routing-decision logging,
// ok). ok=false means a route error has already been written to w and
// the caller MUST return from handleChatCompletions immediately.
func (s *Server) advanceToNextProvider(
	w http.ResponseWriter,
	r *http.Request,
	req chatRequest,
	state *forwardState,
	excluded map[string]struct{},
	rec *billingRecorder,
) (nextRouteID string, ok bool) {
	nextRouteID = uuid.NewString()
	picked, routeErr := s.selectProviderExcluding(nextRouteID, req, r.Header, excluded)
	if routeErr != nil {
		state.routingDone = s.now()
		rec.logRow("", routeErr.status, nil, nil, routeErr.message, "", state.explicitRetries)
		writeRouteError(w, routeErr)
		return "", false
	}
	state.routingDone = s.now()
	state.explicitRetries++
	state.faultedProviders++
	state.provider = picked
	return nextRouteID, true
}

func (s *Server) attemptTimeout(r *http.Request) time.Duration {
	if s.maxRetries > 0 && retryHeaderLimit(r.Header.Get("X-MacProvider-Retry")) > 0 && s.retryPerAttemptTimeout > 0 {
		return s.retryPerAttemptTimeout
	}
	return s.requestTimeout
}

func (s *Server) forwardWS(w http.ResponseWriter, r *http.Request, requestID string, body []byte, provider pool.Provider, stream bool, timeout time.Duration) (wsForwardResult, requestLogAttempt) {
	if s.relay == nil {
		writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
		return wsForwardUnavailable, requestLogAttempt{Status: http.StatusServiceUnavailable, Error: "Selected provider is not reachable"}
	}
	reserved := false
	if s.admission != nil {
		if !s.admission.TryReserveRequest(provider) {
			writeError(w, http.StatusTooManyRequests, "provisional_quota_exceeded", "Selected provisional provider is over request quota")
			return wsForwardFailed, requestLogAttempt{Status: http.StatusTooManyRequests, Error: "Selected provisional provider is over request quota"}
		}
		reserved = provider.Tier == pool.TierProvisional
	}
	if timeout <= 0 {
		timeout = s.requestTimeout
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()
	relay, err := s.relay(ctx, provider, requestID, body, stream)
	if err != nil {
		if reserved {
			s.admission.RefundRequest(provider)
		}
		if errors.Is(err, providerws.ErrRelayClosed) {
			return wsForwardProviderDisconnected, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider disconnected; buyer should retry"}
		}
		if errors.Is(err, providerws.ErrRelayBackpressure) || errors.Is(err, providerws.ErrRelayNAKFallback) {
			if stream {
				return wsForwardUnavailable, requestLogAttempt{Status: http.StatusServiceUnavailable, Error: "Selected provider is not reachable"}
			}
			writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
			return wsForwardUnavailable, requestLogAttempt{Status: http.StatusServiceUnavailable, Error: "Selected provider is not reachable"}
		}
		if errors.Is(err, providerws.ErrRelayAEADFailed) {
			if stream {
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider encrypted response failed authentication"}
			}
			writeError(w, http.StatusBadGateway, "tier2_aead_decrypt_failed", "Provider encrypted response failed authentication")
			return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider encrypted response failed authentication"}
		}
		if stream {
			return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider failed; buyer should retry"}
		}
		writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
		return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider failed; buyer should retry"}
	}
	if stream {
		result, attempt := s.forwardWSStreaming(w, r, requestID, provider, relay)
		if reserved && result == wsForwardProviderDisconnected {
			s.admission.RefundRequest(provider)
		}
		return result, attempt
	}
	result, attempt := s.forwardWSNonStreaming(w, r, requestID, provider, relay)
	if reserved && (result == wsForwardQueueFull || result == wsForwardProviderDisconnected) {
		s.admission.RefundRequest(provider)
	}
	return result, attempt
}

func (s *Server) forwardWSNonStreaming(w http.ResponseWriter, r *http.Request, requestID string, provider pool.Provider, relay *providerws.RelayStream) (wsForwardResult, requestLogAttempt) {
	var body bytes.Buffer
	guard := tier2.NewPillarDGuard(s.tier2Config(), requestID, provider, s.log)
	started := time.Now()
	ttftLogged := false
	faultFlag := billing.FaultNone
	estimatedCompletion := func() *int64 {
		return s.estimatedCompletionTokensFromBytes(body.Len())
	}
	observeTTFT := func() {
		if ttftLogged {
			return
		}
		ttftLogged = true
		guard.LogTTFT(time.Since(started))
	}
	chunks := relay.Chunks
	for {
		select {
		case chunk, ok := <-chunks:
			if ok {
				observeTTFT()
				if body.Len() > int(maxUpstreamResponseBodyBytes)-len(chunk.Data) {
					relay.Cancel("response_body_too_large")
					writeError(w, http.StatusBadGateway, "provider_response_too_large", "Provider response exceeded coordinator limit")
					return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider response exceeded coordinator limit"}
				}
				body.WriteString(chunk.Data)
			} else {
				chunks = nil
			}
		case end := <-relay.Done:
			for chunks != nil {
				select {
				case chunk, ok := <-chunks:
					if !ok {
						chunks = nil
						continue
					}
					observeTTFT()
					if body.Len() > int(maxUpstreamResponseBodyBytes)-len(chunk.Data) {
						relay.Cancel("response_body_too_large")
						writeError(w, http.StatusBadGateway, "provider_response_too_large", "Provider response exceeded coordinator limit")
						return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider response exceeded coordinator limit"}
					}
					body.WriteString(chunk.Data)
				default:
					chunks = nil
				}
			}
			if end.Status != "complete" {
				status := wsEndHTTPStatus(end.Status)
				if end.Status == "error_queue_full" {
					return wsForwardQueueFull, requestLogAttempt{Status: status, Error: endErrorMessage(end), ErrorCode: end.Status}
				}
				writeWSEndError(w, end)
				return wsForwardFailed, requestLogAttempt{Status: status, Error: endErrorMessage(end), ErrorCode: spec001EndStatus(end.Status)}
			}
			if s.zeroTokenFault(end, finishReasonFromChatResponse(body.Bytes())) {
				s.recordBreakerFault(provider, breakerFaultZeroTokenCompletion, requestID)
				faultFlag = billing.FaultBreakerQualifying
			}
			originalBody := body.Bytes()
			checkedBody, err := guard.CheckNonStreamingBody(originalBody)
			if err != nil {
				writeError(w, http.StatusBadGateway, "tier2_output_encoding_invalid", "Provider returned invalid Tier2 output encoding")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider returned invalid Tier2 output encoding"}
			}
			// Round-2 audit HIGH: PillarD enforceOutputCap may truncate the
			// completion. The provider signed end.Receipt over the original
			// bytes; if we forward the truncated body alongside the receipt,
			// the buyer-side verifier will recompute a different output_hash
			// and reject. Drop the receipt header in that case — the buyer
			// still gets the truncated 200 OK body, just without an
			// integrity attestation that no longer applies.
			receiptValue := end.Receipt
			if !bytes.Equal(checkedBody, originalBody) {
				receiptValue = ""
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
			w.Header().Set("X-MacProvider-Route", provider.AssignedID)
			setReceiptHeaderForProvider(w.Header(), receiptValue, provider)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(checkedBody)
			promptTok, completionTok := tokenPointersFromUsageObject(end.Usage)
			if promptTok == nil && completionTok == nil {
				promptTok, completionTok = tokenPointersFromChatResponse(checkedBody)
			}
			return wsForwardComplete, requestLogAttempt{Status: http.StatusOK, PromptTokens: promptTok, CompletionTokens: completionTok, EstimatedCompTokens: s.observedCompletionTokensFromBytes(body.Len()), FaultFlag: faultFlag}
		case err := <-relay.Errors:
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("ws relay failed")
			if errors.Is(err, providerws.ErrRelayTimeout) {
				s.recordBreakerFault(provider, breakerFaultRelayTimeout, requestID)
				return wsForwardTimedOut, requestLogAttempt{Status: http.StatusGatewayTimeout, Error: "Selected provider timed out; buyer should retry", EstimatedCompTokens: estimatedCompletion(), FaultFlag: billing.FaultBreakerQualifying}
			} else if errors.Is(err, providerws.ErrRelayClosed) {
				if r.Context().Err() != nil {
					return wsForwardCancelled, requestLogAttempt{Status: http.StatusOK, Error: "Buyer disconnected during request", EstimatedCompTokens: estimatedCompletion()}
				}
				s.recordBreakerFault(provider, breakerFaultDeadWS, requestID)
				return wsForwardProviderDisconnected, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider disconnected; buyer should retry", EstimatedCompTokens: estimatedCompletion(), FaultFlag: billing.FaultBreakerQualifying}
			} else if errors.Is(err, providerws.ErrRelayAEADFailed) {
				writeError(w, http.StatusBadGateway, "tier2_aead_decrypt_failed", "Provider encrypted response failed authentication")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider encrypted response failed authentication"}
			} else if errors.Is(err, providerws.ErrRelayNAKFallback) {
				writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusServiceUnavailable, Error: "Selected provider is not reachable"}
			} else {
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider failed; buyer should retry"}
			}
		}
	}
}

func (s *Server) forwardWSStreaming(w http.ResponseWriter, r *http.Request, requestID string, provider pool.Provider, relay *providerws.RelayStream) (wsForwardResult, requestLogAttempt) {
	flusher, _ := w.(http.Flusher)
	guard := tier2.NewPillarDGuard(s.tier2Config(), requestID, provider, s.log)
	started := time.Now()
	ttftLogged := false
	chunks := relay.Chunks
	committed := false
	finishReason := ""
	bytesEmitted := 0
	progressAttempt := func(message string, faultFlag string) requestLogAttempt {
		return requestLogAttempt{Status: http.StatusOK, Error: message, EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: faultFlag}
	}
	commit := func() {
		if committed {
			return
		}
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.Header().Set("X-Accel-Buffering", "no")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
		w.Header().Set("X-MacProvider-Route", provider.AssignedID)
		w.WriteHeader(http.StatusOK)
		committed = true
	}
	writeChunk := func(data string) (bool, wsForwardResult) {
		if !ttftLogged {
			ttftLogged = true
			guard.LogTTFT(time.Since(started))
		}
		checked, stop, err := guard.CheckStreamingChunk(data)
		if err != nil {
			relay.Cancel("tier2_encoding_invalid")
			if !committed {
				writeError(w, http.StatusBadGateway, "tier2_output_encoding_invalid", "Provider returned invalid Tier2 output encoding")
				return true, wsForwardFailed
			}
			writeSSEError(w, "Provider returned invalid Tier2 output encoding", "tier2_output_encoding_invalid")
			if flusher != nil {
				flusher.Flush()
			}
			return true, wsForwardFailed
		}
		if reason := finishReasonFromSSE(checked); reason != "" {
			finishReason = reason
		}
		commit()
		if _, err := w.Write([]byte(checked)); err != nil {
			relay.Cancel("buyer_disconnected")
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buyer ws stream write failed")
			return true, wsForwardCancelled
		}
		bytesEmitted += len(checked)
		if flusher != nil {
			flusher.Flush()
		}
		if stop {
			relay.Cancel("tier2_output_truncated")
			return true, wsForwardComplete
		}
		return false, ""
	}
	for {
		select {
		case <-r.Context().Done():
			relay.Cancel("buyer_disconnected")
			return wsForwardCancelled, progressAttempt("Buyer disconnected during streaming", billing.FaultNone)
		case chunk, ok := <-chunks:
			if !ok {
				chunks = nil
				continue
			}
			if done, result := writeChunk(chunk.Data); done {
				faultFlag := billing.FaultNone
				if result == wsForwardFailed {
					faultFlag = billing.FaultBreakerQualifying
				}
				return result, progressAttempt("", faultFlag)
			}
		case end := <-relay.Done:
			for chunks != nil {
				select {
				case chunk, ok := <-chunks:
					if !ok {
						chunks = nil
						continue
					}
					if done, result := writeChunk(chunk.Data); done {
						faultFlag := billing.FaultNone
						if result == wsForwardFailed {
							faultFlag = billing.FaultBreakerQualifying
						}
						return result, progressAttempt("", faultFlag)
					}
				default:
					chunks = nil
				}
			}
			if !committed && end.Status != "complete" && end.Status != "cancelled" {
				status := wsEndHTTPStatus(end.Status)
				if end.Status == "error_queue_full" {
					return wsForwardQueueFull, requestLogAttempt{Status: status, Error: endErrorMessage(end), ErrorCode: end.Status}
				}
				return wsForwardFailed, requestLogAttempt{Status: status, Error: endErrorMessage(end), ErrorCode: spec001EndStatus(end.Status)}
			}
			commit()
			if end.Status == "complete" && s.zeroTokenFault(end, finishReason) {
				s.recordBreakerFault(provider, breakerFaultZeroTokenCompletion, requestID)
			}
			attempt := requestLogAttempt{Status: http.StatusOK, EstimatedCompTokens: s.observedCompletionTokensFromBytes(bytesEmitted)}
			attempt.PromptTokens, attempt.CompletionTokens = tokenPointersFromUsageObject(end.Usage)
			if end.Status == "complete" && s.zeroTokenFault(end, finishReason) {
				attempt.FaultFlag = billing.FaultBreakerQualifying
			}
			if end.Status != "complete" && end.Status != "cancelled" {
				writeSSEError(w, "Provider failed during streaming", "provider_error")
				attempt.Error = endErrorMessage(end)
				attempt.ErrorCode = spec001EndStatus(end.Status)
				attempt.FaultFlag = billing.FaultBreakerQualifying
				if attempt.CompletionTokens == nil {
					attempt.EstimatedCompTokens = s.estimatedCompletionTokensFromBytes(bytesEmitted)
				}
			}
			if flusher != nil {
				flusher.Flush()
			}
			return wsForwardComplete, attempt
		case err := <-relay.Errors:
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("ws streaming relay failed")
			if errors.Is(err, providerws.ErrRelayClosed) {
				if r.Context().Err() != nil {
					return wsForwardCancelled, progressAttempt("Buyer disconnected during streaming", billing.FaultNone)
				}
				s.recordBreakerFault(provider, breakerFaultDeadWS, requestID)
				if !committed {
					return wsForwardProviderDisconnected, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider disconnected; buyer should retry", EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
				}
				writeSSEError(w, "Provider disconnected during streaming", "provider_disconnected")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardProviderDisconnectedCommitted, requestLogAttempt{Status: http.StatusOK, Error: "Provider disconnected during streaming", EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
			}
			if errors.Is(err, providerws.ErrRelayTimeout) {
				s.recordBreakerFault(provider, breakerFaultRelayTimeout, requestID)
				if !committed {
					return wsForwardTimedOut, requestLogAttempt{Status: http.StatusGatewayTimeout, Error: "Selected provider timed out; buyer should retry", EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
				}
				commit()
				writeSSEError(w, "Provider timed out during streaming", "provider_timeout")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardProviderDisconnectedCommitted, requestLogAttempt{Status: http.StatusOK, Error: "Provider timed out during streaming", EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
			}
			if errors.Is(err, providerws.ErrRelayAEADFailed) {
				if !committed {
					writeError(w, http.StatusBadGateway, "tier2_aead_decrypt_failed", "Provider encrypted response failed authentication")
					return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider encrypted response failed authentication"}
				}
				writeSSEError(w, "Provider encrypted response failed authentication", "tier2_aead_decrypt_failed")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardFailed, requestLogAttempt{Status: http.StatusOK, Error: "Provider encrypted response failed authentication", EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
			}
			commit()
			writeSSEError(w, "Provider failed during streaming", "provider_error")
			if flusher != nil {
				flusher.Flush()
			}
			return wsForwardFailed, requestLogAttempt{Status: http.StatusOK, Error: "Provider failed during streaming", EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
		}
	}
}

func (s *Server) forwardStreaming(w http.ResponseWriter, r *http.Request, requestID string, body []byte, provider pool.Provider, modelScope string, timeout time.Duration) (wsForwardResult, int, requestLogAttempt) {
	upstreamURL := provider.EndpointURL + "/v1/chat/completions"
	attemptCtx := r.Context()
	cancelAttempt := func() {}
	if timeout > 0 {
		attemptCtx, cancelAttempt = context.WithTimeout(r.Context(), timeout)
	}
	defer cancelAttempt()
	upReq, err := http.NewRequestWithContext(attemptCtx, http.MethodPost, upstreamURL, bytes.NewReader(body))
	if err != nil {
		return wsForwardFailed, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider failed; buyer should retry"}
	}
	upReq.Header.Set("Content-Type", "application/json")
	upReq.Header.Set("X-Request-ID", requestID)
	resp, err := providerhttp.Client.Do(upReq)
	if err != nil {
		s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider request failed")
		if r.Context().Err() != nil {
			return wsForwardCancelled, 0, requestLogAttempt{}
		}
		// Issue #92 r2 fix: when providerhttp.Client.Timeout fires before
		// response headers arrive, classify as wsForwardTimedOut (504) so
		// the unified loop's TimedOut accounting fires and the breaker
		// counts a timeout (not a generic failure).
		if isStreamingTimeoutErr(err, attemptCtx) {
			s.handleProviderFailure(provider, http.StatusGatewayTimeout)
			return wsForwardTimedOut, http.StatusGatewayTimeout, requestLogAttempt{Status: http.StatusGatewayTimeout, Error: "Provider timed out before response headers", FaultFlag: billing.FaultBreakerQualifying}
		}
		return wsForwardFailed, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: err.Error()}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		s.log.Warn().Int("status", resp.StatusCode).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider returned non-200")
		s.handleProviderFailure(provider, resp.StatusCode)
		respBody, _ := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
		attempt := requestLogAttempt{Status: resp.StatusCode, Error: http.StatusText(resp.StatusCode), ErrorCode: spec001StatusFromBody(respBody)}
		if resp.StatusCode == http.StatusGatewayTimeout {
			return wsForwardTimedOut, resp.StatusCode, attempt
		}
		return wsForwardFailed, resp.StatusCode, attempt
	}

	// Issue #92: do NOT WriteHeader until the provider has streamed at
	// least one COMPLETE valid SSE event — a `data:` line carrying a
	// non-empty, non-`[DONE]`, JSON-parseable OpenAI-shaped chunk,
	// terminated by a blank line. The codex audit found that a weaker
	// threshold (1 byte, then "any non-blank line + blank line") still
	// let an adversarial provider commit 200 OK + sticky storage by
	// sending a few bytes of SSE-shaped garbage (`x\n\n`, `:\n\n`,
	// `data: [DONE]\n\n`) and EOFing. The protocol-aware threshold
	// raises the bar to "produced one well-formed chat-completion chunk".
	//
	// Memory bound: pre-commit reads byte-by-byte and aborts as soon as
	// cumulative pre-commit bytes exceed maxPreCommitStreamingBytes. A
	// malicious provider streaming a giant unterminated line cannot
	// force unbounded buffering into bufio.Reader.
	//
	// The audit-flagged INTENTIONAL semantic of "first valid chunk
	// received then disconnected = committed" is preserved: this guard
	// only fires before the first commit-worthy event arrives. Once
	// committed, EOF/error are committed-terminal exactly as before.
	reader := bufio.NewReader(resp.Body)
	var preCommit bytes.Buffer
	var lineBuf bytes.Buffer
	sawCommitWorthyDataLine := false
	flusher, _ := w.(http.Flusher)
	var promptTok, completionTok *int64
	bytesEmitted := 0
	progressAttempt := func(message string, faultFlag string) requestLogAttempt {
		attempt := requestLogAttempt{Status: http.StatusOK, PromptTokens: promptTok, CompletionTokens: completionTok, Error: message, FaultFlag: faultFlag}
		if completionTok == nil {
			attempt.EstimatedCompTokens = s.estimatedCompletionTokensFromBytes(bytesEmitted)
		}
		return attempt
	}
	writeBuyerHeaders := func() {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		w.Header().Set("X-Accel-Buffering", "no")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
		w.Header().Set("X-MacProvider-Route", provider.AssignedID)
		w.WriteHeader(http.StatusOK)
	}
	// NOTE: HTTP-streaming sticky write is deferred to after io.EOF (clean
	// stream completion), per the SPEC-004 v0.2 audit. Storing affinity
	// upfront would pin the conversation to a provider that may disconnect
	// mid-stream, leaving the sticky entry pointing at a degraded route.
	// The store call now lives in the io.EOF branch below; the
	// wsForwardProviderDisconnectedCommitted branch intentionally does NOT
	// write sticky (the provider failed mid-flight).

	// Pre-commit phase: byte-by-byte read so the cap is honored even
	// against a single unterminated line larger than the cap. On every
	// '\n' the accumulated line is processed: tokens extracted, appended
	// to preCommit, and the commit predicate (a commit-worthy data line
	// followed by a blank-line terminator) is evaluated.
	preCommitErr := func() error {
		for {
			b, err := reader.ReadByte()
			if err != nil {
				return err
			}
			if preCommit.Len()+lineBuf.Len() >= maxPreCommitStreamingBytes {
				s.log.Warn().Int("bytes", preCommit.Len()+lineBuf.Len()).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider exceeded pre-commit buffer cap")
				return errPreCommitCapExceeded
			}
			lineBuf.WriteByte(b)
			if b != '\n' {
				continue
			}
			line := lineBuf.Bytes()
			if p, c := tokenPointersFromSSE(line); p != nil || c != nil {
				promptTok, completionTok = p, c
			}
			preCommit.Write(line)
			lineBuf.Reset()
			if isSSEBlankLine(line) {
				if sawCommitWorthyDataLine {
					return nil // commit
				}
				continue
			}
			if isCommitWorthyDataLine(line) {
				sawCommitWorthyDataLine = true
			}
		}
	}()
	if preCommitErr != nil {
		if errors.Is(preCommitErr, errPreCommitCapExceeded) {
			s.handleProviderFailure(provider, http.StatusBadGateway)
			return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider exceeded pre-commit buffer without commit-worthy event", FaultFlag: billing.FaultBreakerQualifying}
		}
		if r.Context().Err() != nil {
			return wsForwardCancelled, 0, requestLogAttempt{}
		}
		if isStreamingTimeoutErr(preCommitErr, attemptCtx) {
			s.log.Warn().Err(preCommitErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider timed out before first commit-worthy event")
			s.handleProviderFailure(provider, http.StatusGatewayTimeout)
			return wsForwardTimedOut, http.StatusGatewayTimeout, requestLogAttempt{Status: http.StatusGatewayTimeout, Error: "Provider timed out before first commit-worthy event", FaultFlag: billing.FaultBreakerQualifying}
		}
		if preCommitErr == io.EOF {
			s.log.Warn().Int("pre_commit_bytes", preCommit.Len()).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider closed before first commit-worthy event")
		} else {
			s.log.Warn().Err(preCommitErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider disconnected before first commit-worthy event")
		}
		s.handleProviderFailure(provider, http.StatusBadGateway)
		return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider disconnected before first commit-worthy event", FaultFlag: billing.FaultBreakerQualifying}
	}

	// Commit transition: write SSE headers, flush the buffered first
	// event(s) to the buyer in one shot, then drop into the original
	// line-by-line forwarding loop for the remainder of the stream.
	// From this point on, errors are committed-terminal — wsForwardCancelled
	// / wsForwardProviderDisconnectedCommitted / wsForwardComplete only.
	writeBuyerHeaders()
	if _, writeErr := w.Write(preCommit.Bytes()); writeErr != nil {
		s.log.Warn().Err(writeErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buyer pre-commit write failed")
		return wsForwardCancelled, 0, progressAttempt("Buyer disconnected during streaming", billing.FaultNone)
	}
	bytesEmitted = preCommit.Len()
	preCommit.Reset()
	if flusher != nil {
		flusher.Flush()
	}
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			if p, c := tokenPointersFromSSE(line); p != nil || c != nil {
				promptTok, completionTok = p, c
			}
			if _, writeErr := w.Write(line); writeErr != nil {
				s.log.Warn().Err(writeErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buyer streaming write failed")
				return wsForwardCancelled, 0, progressAttempt("Buyer disconnected during streaming", billing.FaultNone)
			}
			bytesEmitted += len(line)
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err == nil {
			continue
		}
		if err == io.EOF {
			s.stickyStore(r.Header, provider, modelScope)
			return wsForwardComplete, http.StatusOK, requestLogAttempt{Status: http.StatusOK, PromptTokens: promptTok, CompletionTokens: completionTok, EstimatedCompTokens: s.observedCompletionTokensFromBytes(bytesEmitted)}
		}
		if r.Context().Err() != nil {
			return wsForwardCancelled, 0, progressAttempt("Buyer disconnected during streaming", billing.FaultNone)
		}
		if isStreamingTimeoutErr(err, attemptCtx) {
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider timed out during streaming")
			s.recordBreakerFault(provider, breakerFaultHTTPStreamTimeout, requestID)
		} else {
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider disconnected during streaming")
			s.recordBreakerFault(provider, breakerFaultHTTPStreamDead, requestID)
		}
		writeSSEError(w, "Provider disconnected during streaming", "provider_disconnected")
		if flusher != nil {
			flusher.Flush()
		}
		return wsForwardProviderDisconnectedCommitted, http.StatusOK, progressAttempt("Provider disconnected during streaming", billing.FaultBreakerQualifying)
	}
}

// errPreCommitCapExceeded is the sentinel returned by forwardStreaming's
// pre-commit phase when cumulative bytes hit maxPreCommitStreamingBytes
// before a commit-worthy event arrives. Distinguished from io.EOF /
// timeout / network errors so the caller can log a specific reason.
var errPreCommitCapExceeded = errors.New("pre-commit buffer cap exceeded")

// isCommitWorthyDataLine reports whether the given SSE line counts as
// real provider work for the purposes of forwardStreaming's commit
// threshold. Codex r5 audit tightened the predicate from "field present"
// to "field value-typed and bounded":
//
//   - `choices` must be a non-empty JSON array where AT LEAST ONE
//     element (not necessarily the first) is an object carrying one of:
//
//   - `delta`: an object carrying at least one KNOWN OpenAI field
//     (content/role/refusal/reasoning non-empty string, tool_calls
//     non-empty array, function_call non-empty object).
//     Arbitrary-key objects like `{"":0}` or `{"x":"y"}` reject.
//
//   - `message`: same allowlist as `delta` (matches non-streaming
//     message-shape variants)
//
//   - `finish_reason`: a STRING of length >= 1 (matches `"stop"`,
//     `"length"`, `"tool_calls"`, etc.; numeric or empty/null
//     finish_reason rejects)
//
//   - `usage` must decode to non-negative INTEGER `completion_tokens`
//     in [0, maxRequestLogUsageTokens] AND at least one of
//     `prompt_tokens` / `total_tokens` also non-negative integer within
//     the same range. Floats, negatives, overflow, and string-typed
//     token counts reject.
//
// A leading UTF-8 BOM (0xEF 0xBB 0xBF) on the line is tolerated for
// SSE-source compatibility; some HTTP libraries emit one on stream init.
func isCommitWorthyDataLine(line []byte) bool {
	trimmed := bytes.TrimRight(line, "\r\n")
	trimmed = bytes.TrimPrefix(trimmed, []byte{0xEF, 0xBB, 0xBF})
	if !bytes.HasPrefix(trimmed, []byte("data:")) {
		return false
	}
	content := bytes.TrimSpace(trimmed[len("data:"):])
	if len(content) == 0 || bytes.Equal(content, []byte("[DONE]")) {
		return false
	}
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(content, &parsed); err != nil {
		return false
	}
	if raw, ok := parsed["choices"]; ok {
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err == nil && len(arr) > 0 {
			for _, choice := range arr {
				var obj map[string]json.RawMessage
				if err := json.Unmarshal(choice, &obj); err != nil {
					continue
				}
				if raw, has := obj["delta"]; has && hasOpenAIDeltaSignal(raw) {
					return true
				}
				if raw, has := obj["message"]; has && hasOpenAIDeltaSignal(raw) {
					return true
				}
				if raw, has := obj["finish_reason"]; has && isNonEmptyJSONString(raw) {
					return true
				}
			}
		}
	}
	if raw, ok := parsed["usage"]; ok {
		if isValidUsageObject(raw) {
			return true
		}
	}
	return false
}

// isNonEmptyJSONObject reports whether raw decodes to a JSON object
// (map) with at least one key. Retained for general-purpose checks;
// the commit predicate uses hasOpenAIDeltaSignal instead since
// post-PR-167 security review showed `{"":0}` would otherwise pass.
func isNonEmptyJSONObject(raw json.RawMessage) bool {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return false
	}
	return len(obj) > 0
}

// hasOpenAIDeltaSignal reports whether raw decodes to a JSON object
// carrying at least one KNOWN OpenAI delta/message field with a value
// that signals real provider work. The fresh security-review lane on
// PR #167 caught that `isNonEmptyJSONObject` accepted `{"":0}` /
// `{"x":"y"}` — a 37-byte payload that gamed the commit threshold
// while delivering nothing. This allowlist closes that gap.
//
// Accepted shapes:
//   - content: non-empty string (the streaming token delta)
//   - role: non-empty string (the role-assignment first chunk)
//   - refusal: non-empty string (safety-refusal stream)
//   - tool_calls: non-empty array (function/tool calling)
//   - function_call: non-empty object (legacy function calling)
//   - reasoning: non-empty string (reasoning-model trace stream)
func hasOpenAIDeltaSignal(raw json.RawMessage) bool {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return false
	}
	if raw, has := obj["content"]; has && isNonEmptyJSONString(raw) {
		return true
	}
	if raw, has := obj["role"]; has && isNonEmptyJSONString(raw) {
		return true
	}
	if raw, has := obj["refusal"]; has && isNonEmptyJSONString(raw) {
		return true
	}
	if raw, has := obj["reasoning"]; has && isNonEmptyJSONString(raw) {
		return true
	}
	if raw, has := obj["tool_calls"]; has {
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err == nil && len(arr) > 0 {
			return true
		}
	}
	if raw, has := obj["function_call"]; has && isNonEmptyJSONObject(raw) {
		return true
	}
	return false
}

// isNonEmptyJSONString reports whether raw decodes to a JSON string
// of length >= 1. Used by isCommitWorthyDataLine to require
// finish_reason to be a real string ("stop", "length", etc.) — null
// / numeric / empty-string finish_reason rejects.
func isNonEmptyJSONString(raw json.RawMessage) bool {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return false
	}
	return len(s) > 0
}

// isValidUsageObject reports whether raw decodes to an OpenAI usage
// object with non-negative integer completion_tokens AND at least one
// other non-negative integer token field, all within
// maxRequestLogUsageTokens. Floats, negatives, overflow, and
// non-numeric token counts reject.
func isValidUsageObject(raw json.RawMessage) bool {
	var usage struct {
		PromptTokens     *json.Number `json:"prompt_tokens"`
		CompletionTokens *json.Number `json:"completion_tokens"`
		TotalTokens      *json.Number `json:"total_tokens"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&usage); err != nil {
		return false
	}
	completion, ok := validatedTokenCount(usage.CompletionTokens)
	if !ok {
		return false
	}
	if _, ok := validatedTokenCount(usage.PromptTokens); ok {
		_ = completion
		return true
	}
	if _, ok := validatedTokenCount(usage.TotalTokens); ok {
		return true
	}
	return false
}

// validatedTokenCount checks that n is a non-negative integer in the
// range [0, maxRequestLogUsageTokens]. Returns (value, true) on
// success, (0, false) on failure or nil input.
func validatedTokenCount(n *json.Number) (int64, bool) {
	if n == nil {
		return 0, false
	}
	v, err := n.Int64()
	if err != nil {
		return 0, false
	}
	if v < 0 || v > maxRequestLogUsageTokens {
		return 0, false
	}
	return v, true
}

// maxPreCommitStreamingBytes caps how much pre-commit body forwardStreaming
// will buffer before declaring the provider malformed/adversarial. 16 KiB
// covers any reasonable first SSE event from current OpenAI-compatible
// providers (typical first chunk is < 1 KiB).
const maxPreCommitStreamingBytes = 16 * 1024

// isSSEBlankLine reports whether the given bufio.Reader.ReadBytes('\n')
// result is the blank-line event terminator used by SSE — either "\n"
// or "\r\n".
func isSSEBlankLine(line []byte) bool {
	if len(line) == 1 && line[0] == '\n' {
		return true
	}
	if len(line) == 2 && line[0] == '\r' && line[1] == '\n' {
		return true
	}
	return false
}

// isStreamingTimeoutErr reports whether a body-read error or context state
// should be classified as a provider timeout. Covers three timeout sources
// the forwardStreaming pre-commit path can hit:
//  1. attemptCtx deadline (the per-attempt timeout in forwardStreaming).
//  2. providerhttp.Client.Timeout, which surfaces as a wrapped
//     net.OpError carrying *url.Error / os.ErrDeadlineExceeded — these
//     do not match errors.Is(ctx.Err(), context.DeadlineExceeded) yet.
//  3. Direct context.DeadlineExceeded wrapped in the read error itself.
func isStreamingTimeoutErr(err error, attemptCtx context.Context) bool {
	if errors.Is(attemptCtx.Err(), context.DeadlineExceeded) {
		return true
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return true
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	return false
}

func statusForForwardResult(result wsForwardResult) int {
	switch result {
	case wsForwardTimedOut:
		return http.StatusGatewayTimeout
	case wsForwardUnavailable:
		return http.StatusServiceUnavailable
	default:
		return http.StatusBadGateway
	}
}

func writeStreamForwardError(w http.ResponseWriter, result wsForwardResult) {
	switch result {
	case wsForwardTimedOut:
		writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
	case wsForwardUnavailable:
		writeError(w, http.StatusServiceUnavailable, "provider_unavailable", "Selected provider is not reachable")
	case wsForwardProviderDisconnected:
		writeError(w, http.StatusBadGateway, "provider_disconnected", "Selected provider disconnected; buyer should retry")
	case wsForwardCancelled, wsForwardProviderDisconnectedCommitted:
		return
	default:
		writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
	}
}

func validateChatRequest(body []byte) (chatRequest, int, string, string) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return chatRequest{}, http.StatusBadRequest, "invalid_json", "Invalid JSON in request body"
	}
	modelCount, nonCanonicalModel, err := countTopLevelField(body, "model")
	if err != nil {
		return chatRequest{}, http.StatusBadRequest, "invalid_json", "Invalid JSON in request body"
	}
	if nonCanonicalModel || modelCount > 1 {
		return chatRequest{}, http.StatusBadRequest, "invalid_request", "Duplicate model field"
	}
	var req chatRequest
	req.raw = append(req.raw, body...)
	modelRaw, ok := raw["model"]
	if !ok {
		return req, http.StatusBadRequest, "invalid_request", "Missing required field: model"
	}
	if err := json.Unmarshal(modelRaw, &req.Model); err != nil || req.Model == "" {
		return req, http.StatusBadRequest, "invalid_request", "Invalid model"
	}
	messagesRaw, ok := raw["messages"]
	if !ok {
		return req, http.StatusBadRequest, "invalid_request", "Missing required field: messages"
	}
	if err := json.Unmarshal(messagesRaw, &req.Messages); err != nil || len(req.Messages) == 0 {
		return req, http.StatusBadRequest, "invalid_request", "Invalid messages"
	}
	if status, code, msg := validateOptionalFields(raw); status != 0 {
		return req, status, code, msg
	}
	if status, code, msg := validateMessages(req.Messages); status != 0 {
		return req, status, code, msg
	}
	if status, code, msg := validateTools(raw, req.Messages); status != 0 {
		return req, status, code, msg
	}
	if v, ok := raw["stream"]; ok {
		if err := json.Unmarshal(v, &req.Stream); err != nil {
			return req, http.StatusBadRequest, "invalid_request", "Invalid stream"
		}
	}
	return req, 0, "", ""
}

func countTopLevelField(body []byte, field string) (int, bool, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	token, err := dec.Token()
	if err != nil {
		return 0, false, err
	}
	if delim, ok := token.(json.Delim); !ok || delim != '{' {
		return 0, false, errors.New("request body is not a JSON object")
	}
	count := 0
	nonCanonical := false
	for dec.More() {
		keyToken, err := dec.Token()
		if err != nil {
			return 0, false, err
		}
		key, ok := keyToken.(string)
		if !ok {
			return 0, false, errors.New("request body contains a non-string object key")
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return 0, false, err
		}
		if key == field {
			count++
		} else if strings.EqualFold(key, field) {
			nonCanonical = true
		}
	}
	if _, err := dec.Token(); err != nil {
		return 0, false, err
	}
	return count, nonCanonical, nil
}

func dispatchBodyForProvider(req chatRequest, provider pool.Provider) ([]byte, error) {
	if modelIDEqual(req.Model, provider.ModelID) {
		return append([]byte(nil), req.raw...), nil
	}

	dec := json.NewDecoder(bytes.NewReader(req.raw))
	token, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := token.(json.Delim); !ok || delim != '{' {
		return nil, errors.New("chat request body is not a JSON object")
	}
	type replacement struct {
		start int
		end   int
	}
	var replacements []replacement
	for dec.More() {
		keyToken, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, errors.New("chat request body contains a non-string object key")
		}
		keyEnd := int(dec.InputOffset())
		valueStart, err := jsonValueStart(req.raw, keyEnd)
		if err != nil {
			return nil, err
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil, err
		}
		if key == "model" {
			replacements = append(replacements, replacement{start: valueStart, end: int(dec.InputOffset())})
		} else if strings.EqualFold(key, "model") {
			return nil, errors.New("chat request body contains non-canonical model field")
		}
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	if len(replacements) == 0 {
		return nil, errors.New("chat request body missing model field")
	}
	if len(replacements) > 1 {
		return nil, errors.New("chat request body contains duplicate model fields")
	}
	model, err := json.Marshal(provider.ModelID)
	if err != nil {
		return nil, err
	}
	out := append([]byte(nil), req.raw...)
	r := replacements[0]
	next := make([]byte, 0, len(out)-(r.end-r.start)+len(model))
	next = append(next, out[:r.start]...)
	next = append(next, model...)
	next = append(next, out[r.end:]...)
	return next, nil
}

func jsonValueStart(raw []byte, keyEnd int) (int, error) {
	i := keyEnd
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\n' || raw[i] == '\r' || raw[i] == '\t') {
		i++
	}
	if i >= len(raw) || raw[i] != ':' {
		return 0, errors.New("chat request body object key missing colon")
	}
	i++
	for i < len(raw) && (raw[i] == ' ' || raw[i] == '\n' || raw[i] == '\r' || raw[i] == '\t') {
		i++
	}
	if i >= len(raw) {
		return 0, errors.New("chat request body object key missing value")
	}
	return i, nil
}

func validateOptionalFields(raw map[string]json.RawMessage) (int, string, string) {
	if v, ok := raw["max_tokens"]; ok {
		var n int
		if err := json.Unmarshal(v, &n); err != nil || n <= 0 {
			return http.StatusBadRequest, "invalid_request", "max_tokens must be > 0"
		}
	}
	for _, field := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty"} {
		if v, ok := raw[field]; ok {
			var f float64
			if err := json.Unmarshal(v, &f); err != nil {
				return http.StatusBadRequest, "invalid_request", "Invalid " + field
			}
			if field == "temperature" && (f < 0 || f > 2) {
				return http.StatusBadRequest, "invalid_request", "temperature out of range"
			}
			if field == "top_p" && (f < 0 || f > 1) {
				return http.StatusBadRequest, "invalid_request", "top_p out of range"
			}
			if (field == "presence_penalty" || field == "frequency_penalty") && (f < -2 || f > 2) {
				return http.StatusBadRequest, "invalid_request", field + " out of range"
			}
		}
	}
	if v, ok := raw["n"]; ok {
		var n int
		if err := json.Unmarshal(v, &n); err != nil || n != 1 {
			return http.StatusBadRequest, "invalid_request", "n must be 1"
		}
	}
	if v, ok := raw["response_format"]; ok {
		var rf struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(v, &rf); err != nil || (rf.Type != "" && rf.Type != "text" && rf.Type != "json_object") {
			return http.StatusBadRequest, "invalid_request", "Invalid response_format"
		}
	}
	return 0, "", ""
}

func validateMessages(messages []chatMessage) (int, string, string) {
	for _, m := range messages {
		switch m.Role {
		case "system", "user":
			if !rawStringNonEmpty(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid message content"
			}
		case "assistant":
			hasContent := string(m.Content) != "" && string(m.Content) != "null"
			hasTools := len(m.ToolCalls) > 0 && string(m.ToolCalls) != "null"
			if hasContent && !rawString(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid assistant content"
			}
			if !hasContent && !hasTools {
				return http.StatusBadRequest, "invalid_request", "Assistant message requires content or tool_calls"
			}
		case "tool":
			if m.ToolCallID == "" || !rawString(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid tool message"
			}
		default:
			return http.StatusBadRequest, "invalid_request", "Invalid message role"
		}
	}
	return 0, "", ""
}

func validateTools(raw map[string]json.RawMessage, messages []chatMessage) (int, string, string) {
	if v, ok := raw["tools"]; ok && string(v) != "null" {
		var tools []struct {
			Type     string `json:"type"`
			Function struct {
				Name       string          `json:"name"`
				Parameters json.RawMessage `json:"parameters"`
			} `json:"function"`
		}
		if err := json.Unmarshal(v, &tools); err != nil {
			return http.StatusBadRequest, "invalid_tools", "Invalid tools"
		}
		for i, tool := range tools {
			if tool.Type != "function" || tool.Function.Name == "" || !json.Valid(tool.Function.Parameters) || string(tool.Function.Parameters) == "null" || len(tool.Function.Parameters) == 0 {
				return http.StatusBadRequest, "invalid_tools", "Invalid tools[" + itoa(i) + "]"
			}
		}
	}
	for _, msg := range messages {
		if len(msg.ToolCalls) == 0 || string(msg.ToolCalls) == "null" {
			continue
		}
		var calls []struct {
			ID       string `json:"id"`
			Type     string `json:"type"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		}
		if err := json.Unmarshal(msg.ToolCalls, &calls); err != nil {
			return http.StatusBadRequest, "invalid_tools", "Invalid tool_calls"
		}
		for _, call := range calls {
			if call.ID == "" || call.Type != "function" || call.Function.Name == "" || !json.Valid([]byte(call.Function.Arguments)) {
				return http.StatusBadRequest, "invalid_tools", "Invalid tool_calls"
			}
		}
	}
	return 0, "", ""
}

func rawString(raw json.RawMessage) bool {
	var s string
	return json.Unmarshal(raw, &s) == nil
}

func rawStringNonEmpty(raw json.RawMessage) bool {
	var s string
	return json.Unmarshal(raw, &s) == nil && s != ""
}

type routeError struct {
	status  int
	code    string
	message string
	typ     string
}

func (s *Server) selectProvider(requestID string, req chatRequest, headers http.Header) (pool.Provider, *routeError) {
	return s.selectProviderExcluding(requestID, req, headers, nil)
}

func (s *Server) failoverCandidate(requestID string, req chatRequest, headers http.Header, failed pool.Provider, excluded map[string]struct{}) (pool.Provider, bool) {
	if !s.failoverEnabled || hasPinnedRoute(headers) {
		return pool.Provider{}, false
	}
	if excluded == nil {
		excluded = map[string]struct{}{}
	}
	excluded[routeKey(failed)] = struct{}{}
	failoverHeaders := headers.Clone()
	failoverHeaders.Del("X-MacProvider-Provider")
	failoverHeaders.Del("X-MacProvider-Session")
	next, routeErr := s.selectProviderExcluding(requestID, req, failoverHeaders, excluded)
	if routeErr != nil {
		return pool.Provider{}, false
	}
	return next, true
}

func hasPinnedRoute(headers http.Header) bool {
	return headers.Get("X-MacProvider-Provider") != "" || headers.Get("X-MacProvider-Session") != ""
}

func (s *Server) logWSDeadMidRequest(originalRequestID, requestID, externalRequestID string, provider pool.Provider, action, targetProviderID string) {
	s.log.Warn().
		Str("event", "ws_dead_mid_request").
		Str("original_request_id", originalRequestID).
		Str("request_id", requestID).
		Str("external_request_id", externalRequestID).
		Str("provider_id", provider.ProviderID).
		Str("action", action).
		Str("target_provider_id", targetProviderID).
		Dur("failover_timeout", s.failoverTimeout).
		Msg("provider websocket died during in-flight request")
}

func (s *Server) recordBreakerFault(provider pool.Provider, fault breakerFault, requestID string) {
	result := s.pool.RecordBreakerFault(provider.ProviderID, provider.AssignedID, s.now(), s.breakerThreshold, s.breakerWindow)
	event := s.log.Warn().
		Str("event", "provider_breaker_fault").
		Str("provider_id", provider.ProviderID).
		Str("assigned_id", provider.AssignedID).
		Str("request_id", requestID).
		Str("fault", string(fault)).
		Int("count", result.Count).
		Int("threshold", result.Threshold)
	switch result.Tripped {
	case pool.BreakerTripDegraded:
		event.Str("reason", "breaker_tripped").Msg("provider circuit breaker tripped")
		s.startRecoveryProbe(provider)
	case pool.BreakerTripUnavailable:
		event.Str("reason", "breaker_retrip").Msg("provider marked unavailable after breaker re-trip")
	default:
		event.Msg("provider circuit breaker fault recorded")
	}
}

func (s *Server) selectProviderExcluding(requestID string, req chatRequest, headers http.Header, excluded map[string]struct{}) (pool.Provider, *routeError) {
	providers := s.pool.Snapshot()
	estimatedTokens := estimateTokens(req.raw)
	class := s.classForRequest(req.Model, providers)
	tier2Cfg := s.tier2Config()
	if hasInternalRoutingHeader(headers) && !s.internalBearerAuthorized(headers) {
		return pool.Provider{}, &routeError{status: http.StatusBadRequest, code: "invalid_request", message: "Internal routing header is not accepted on the buyer port"}
	}
	if session := headers.Get("X-MacProvider-Session"); session != "" {
		for _, p := range providers {
			if p.AssignedID == session {
				provider, routeErr := s.validatePinnedProviderForRequest(p, req.Model, estimatedTokens, "Pinned session not available", class)
				if routeErr != nil {
					return provider, routeErr
				}
				if !s.checkQuota(provider) {
					return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "Pinned provisional provider is over request quota"}
				}
				return s.preflightCandidate(provider, requestID, estimatedTokens)
			}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "session_ended", message: "Pinned session has ended"}
	}
	if providerID := headers.Get("X-MacProvider-Provider"); providerID != "" {
		for _, p := range providers {
			if p.ProviderID == providerID {
				provider, routeErr := s.validatePinnedProviderForRequest(p, req.Model, estimatedTokens, "Pinned provider not available", class)
				if routeErr != nil {
					return provider, routeErr
				}
				if !s.checkQuota(provider) {
					return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "Pinned provisional provider is over request quota"}
				}
				return s.preflightCandidate(provider, requestID, estimatedTokens)
			}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "Pinned provider not in pool"}
	}

	candidates := make([]pool.Provider, 0, len(providers))
	hasRoutableContextMiss := false
	tier2HashRequiredExcluded := 0
	tier2HashMismatchExcluded := []pool.Provider{}
	tier2EncryptedLegExcluded := 0
	tier2AttestationExcluded := 0
	for _, p := range providers {
		if _, skip := excluded[routeKey(p)]; skip {
			continue
		}
		if !s.providerMatchesRequest(p, req.Model, class) || !p.RoutingEligible() {
			continue
		}
		if p.MaxContextTokens < estimatedTokens {
			hasRoutableContextMiss = true
			continue
		}
		hashStatus := s.effectiveHashStatus(p, tier2Cfg)
		if s.tier2ProviderExcludedStatus(hashStatus, tier2Cfg) {
			if hashStatus == pool.HashStatusMismatch || hashStatus == pool.HashStatusInvalid {
				p.HashStatus = hashStatus
				tier2HashMismatchExcluded = append(tier2HashMismatchExcluded, p)
			} else {
				if tier2Cfg.RequireHashVerified && (hashStatus == pool.HashStatusUncatalogued || hashStatus == pool.HashStatusCatalogUnavailable) {
					tier2.LogHashRequiredProviderExcluded(s.log, p.ProviderID, p.AssignedID, p.ModelID, p.ModelHash, hashStatus)
				}
				tier2HashRequiredExcluded++
			}
			continue
		}
		if tier2Cfg.RequireEncryptedLeg && !p.EncryptedLeg {
			tier2.LogEncryptedLegRequiredMissing(s.log, p.ProviderID, p.AssignedID, p.ModelID)
			tier2EncryptedLegExcluded++
			continue
		}
		if tier2Cfg.RequireAttestation && p.AttestationStatus != pool.AttestationStatusAttested {
			tier2AttestationExcluded++
			continue
		}
		candidates = append(candidates, p)
	}
	if len(candidates) == 0 {
		if hasRoutableContextMiss {
			return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds provider context capacity"}
		}
		if tier2Cfg.RequireHashVerified && (tier2HashRequiredExcluded > 0 || len(tier2HashMismatchExcluded) > 0) {
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_hash_verified_required", message: "No hash-verified provider available for model `" + req.Model + "`.", typ: "server_error"}
		}
		if len(tier2HashMismatchExcluded) > 0 {
			providerID := tier2HashMismatchExcluded[0].ProviderID
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_hash_mismatch", message: "Provider `" + providerID + "` hash verification failed; excluded from pool.", typ: "server_error"}
		}
		if tier2EncryptedLegExcluded > 0 {
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_encrypted_leg_required", message: "No encrypted provider leg available for model `" + req.Model + "`.", typ: "server_error"}
		}
		if tier2AttestationExcluded > 0 {
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_attestation_required", message: "No attested provider available for model `" + req.Model + "`.", typ: "server_error"}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "No provider available for model " + req.Model}
	}
	preQuotaCandidates := candidates
	candidates = candidates[:0]
	quotaBlocked := 0
	for _, candidate := range preQuotaCandidates {
		if s.checkQuota(candidate) {
			candidates = append(candidates, candidate)
		} else {
			quotaBlocked++
		}
	}
	if len(candidates) == 0 && quotaBlocked > 0 && quotaBlocked == len(preQuotaCandidates) {
		return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "All otherwise eligible provisional providers are over request quota"}
	}
	objective := s.objectiveForRequest(headers, class)
	s.sortCandidates(candidates, objective)
	candidates = s.applySticky(requestID, headers, req.Model, class, candidates)
	candidates, seed, draw, reason := s.applyRandomTiebreak(requestID, candidates, objective)
	s.logRoutingDecision(requestID, candidates, objective, seed, draw, reason, "")
	for _, candidate := range candidates {
		provider, routeErr := s.preflightCandidate(candidate, requestID, estimatedTokens)
		if routeErr == nil {
			return provider, nil
		}
	}
	return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "preflight_rejected", message: "All providers rejected the request"}
}

func cloneModelClasses(in map[string]config.ModelClassConfig) map[string]config.ModelClassConfig {
	out := make(map[string]config.ModelClassConfig, len(in))
	for name, class := range in {
		out[name] = config.ModelClassConfig{Objective: class.Objective, Members: append([]string(nil), class.Members...), Models: append([]string(nil), class.Models...)}
	}
	return out
}

func (s *Server) resolveModelClass(model string) *config.ModelClassConfig {
	for name, class := range s.modelClasses {
		if strings.EqualFold(name, model) {
			cp := config.ModelClassConfig{Objective: class.Objective, Members: append([]string(nil), class.Members...), Models: append([]string(nil), class.Models...)}
			return &cp
		}
	}
	return nil
}

func (s *Server) classForRequest(model string, providers []pool.Provider) *config.ModelClassConfig {
	for _, p := range providers {
		if modelIDEqual(p.ModelID, model) {
			return nil
		}
	}
	return s.resolveModelClass(model)
}

func (s *Server) providerMatchesRequest(provider pool.Provider, model string, class *config.ModelClassConfig) bool {
	if class == nil {
		return modelIDEqual(provider.ModelID, model)
	}
	for _, member := range modelClassMembers(class) {
		if modelIDEqual(provider.ModelID, member) {
			return true
		}
	}
	return false
}

func (s *Server) objectiveForRequest(headers http.Header, class *config.ModelClassConfig) string {
	if class != nil {
		return class.Objective
	}
	switch headers.Get("X-MacProvider-Pref") {
	case "fast", "accurate":
		return headers.Get("X-MacProvider-Pref")
	default:
		return "default"
	}
}

func (s *Server) sortCandidates(candidates []pool.Provider, objective string) {
	switch objective {
	case "fast":
		sort.SliceStable(candidates, func(i, j int) bool {
			ti := s.effectiveThroughput(candidates[i])
			tj := s.effectiveThroughput(candidates[j])
			if ti == tj {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return ti > tj
		})
	case "accurate":
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].ModelParamsB == candidates[j].ModelParamsB {
				ti := s.effectiveThroughput(candidates[i])
				tj := s.effectiveThroughput(candidates[j])
				if ti != tj {
					return ti > tj
				}
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return candidates[i].ModelParamsB > candidates[j].ModelParamsB
		})
	case "balanced":
		scores := balancedScores(candidates)
		sort.SliceStable(candidates, func(i, j int) bool {
			if scores[routeKey(candidates[i])] == scores[routeKey(candidates[j])] {
				return candidates[i].SlotsFree < candidates[j].SlotsFree
			}
			return scores[routeKey(candidates[i])] > scores[routeKey(candidates[j])]
		})
	default:
		sort.SliceStable(candidates, func(i, j int) bool {
			if candidates[i].SlotsFree == candidates[j].SlotsFree {
				return s.effectiveThroughput(candidates[i]) > s.effectiveThroughput(candidates[j])
			}
			return candidates[i].SlotsFree < candidates[j].SlotsFree
		})
	}
}

func balancedScores(candidates []pool.Provider) map[string]float64 {
	tps := make([]float64, len(candidates))
	params := make([]float64, len(candidates))
	ctx := make([]float64, len(candidates))
	slots := make([]float64, len(candidates))
	for i, p := range candidates {
		tps[i] = p.ThroughputTPSEstimate
		params[i] = p.ModelParamsB
		ctx[i] = float64(p.MaxContextTokens)
		if p.SlotsTotal > 0 {
			slots[i] = float64(p.SlotsFree) / float64(p.SlotsTotal)
		}
	}
	out := map[string]float64{}
	for i, p := range candidates {
		out[routeKey(p)] = 0.4*norm(tps, i) + 0.3*norm(params, i) + 0.2*norm(ctx, i) + 0.1*norm(slots, i)
	}
	return out
}

func norm(values []float64, idx int) float64 {
	if len(values) == 0 {
		return 1
	}
	minV, maxV := values[0], values[0]
	for _, v := range values[1:] {
		if v < minV {
			minV = v
		}
		if v > maxV {
			maxV = v
		}
	}
	if maxV == minV {
		return 1
	}
	return (values[idx] - minV) / (maxV - minV)
}

func (s *Server) applyRandomTiebreak(requestID string, candidates []pool.Provider, objective string) ([]pool.Provider, int64, float64, string) {
	if !s.tiebreakRandomize || len(candidates) < 2 {
		return candidates, 0, 0, "deterministic"
	}
	cohortEnd := 1
	for cohortEnd < len(candidates) {
		if !s.inEpsilonCohort(candidates[0], candidates[cohortEnd], objective, candidates) {
			break
		}
		cohortEnd++
	}
	if cohortEnd < 2 {
		return candidates, 0, 0, "deterministic"
	}
	seed := seedForRequest(requestID)
	rng := mrand.New(mrand.NewSource(seed))
	draw := rng.Float64()
	pick := int(draw * float64(cohortEnd))
	if pick >= cohortEnd {
		pick = cohortEnd - 1
	}
	if pick != 0 {
		candidates[0], candidates[pick] = candidates[pick], candidates[0]
	}
	return candidates, seed, draw, "randomized"
}

func (s *Server) applySticky(requestID string, headers http.Header, model string, class *config.ModelClassConfig, candidates []pool.Provider) []pool.Provider {
	if !s.stickyEnabled || hasPinnedRoute(headers) || len(candidates) < 2 {
		return candidates
	}
	key := strings.TrimSpace(headers.Get("X-MacProvider-Internal-Conv"))
	if !strings.HasPrefix(key, "conv:") {
		return candidates
	}
	entry, ok, reason := s.stickyLookup(key)
	if !ok {
		s.logRoutingDecision(requestID, candidates, s.objectiveForRequest(headers, class), 0, 0, "sticky_miss_"+reason, "")
		return candidates
	}
	for i, candidate := range candidates {
		if candidate.ProviderID != entry.ProviderID {
			continue
		}
		if i == 0 {
			return candidates
		}
		if !s.inEpsilonCohort(candidates[0], candidate, s.objectiveForRequest(headers, class), candidates) {
			s.logRoutingDecision(requestID, candidates, s.objectiveForRequest(headers, class), 0, 0, "sticky_outside_epsilon", candidate.ProviderID)
			return candidates
		}
		candidates[0], candidates[i] = candidates[i], candidates[0]
		s.logRoutingDecision(requestID, candidates, s.objectiveForRequest(headers, class), 0, 0, "sticky_hit", candidate.ProviderID)
		return candidates
	}
	s.logRoutingDecision(requestID, candidates, s.objectiveForRequest(headers, class), 0, 0, "sticky_miss_provider_not_candidate", "")
	return candidates
}

func (s *Server) stickyLookup(key string) (stickyEntry, bool, string) {
	s.stickyMu.Lock()
	defer s.stickyMu.Unlock()
	entry, ok := s.sticky[key]
	if !ok {
		return stickyEntry{}, false, "not_found"
	}
	now := s.now()
	if now.Sub(entry.LastUsedAt) > s.stickyTTL {
		delete(s.sticky, key)
		return stickyEntry{}, false, "expired"
	}
	entry.LastUsedAt = now
	s.sticky[key] = entry
	return entry, true, ""
}

func (s *Server) stickyStore(headers http.Header, provider pool.Provider, modelScope string) {
	if !s.stickyEnabled || hasPinnedRoute(headers) {
		return
	}
	key := strings.TrimSpace(headers.Get("X-MacProvider-Internal-Conv"))
	if !strings.HasPrefix(key, "conv:") {
		return
	}
	now := s.now()
	s.stickyMu.Lock()
	defer s.stickyMu.Unlock()
	if len(s.sticky) >= s.stickyMaxEntries {
		var oldestKey string
		var oldest time.Time
		for k, entry := range s.sticky {
			if now.Sub(entry.LastUsedAt) > s.stickyTTL {
				delete(s.sticky, k)
				continue
			}
			if oldestKey == "" || entry.LastUsedAt.Before(oldest) {
				oldestKey = k
				oldest = entry.LastUsedAt
			}
		}
		if len(s.sticky) >= s.stickyMaxEntries && oldestKey != "" {
			delete(s.sticky, oldestKey)
		}
	}
	created := now
	if existing, ok := s.sticky[key]; ok {
		created = existing.CreatedAt
	}
	s.sticky[key] = stickyEntry{ConversationKey: key, ProviderID: provider.ProviderID, AccountID: headers.Get("X-MacProvider-Account"), ModelScope: modelScope, CreatedAt: created, LastUsedAt: now}
}

func (s *Server) purgeStickyAccount(accountID string) int {
	s.stickyMu.Lock()
	defer s.stickyMu.Unlock()
	removed := 0
	for key, entry := range s.sticky {
		if entry.AccountID == accountID {
			delete(s.sticky, key)
			removed++
		}
	}
	return removed
}

func (s *Server) shouldRetry(r *http.Request, startedAt time.Time, explicitRetries, faultedProviders, status int, err error) bool {
	requestedRetries := retryHeaderLimit(r.Header.Get("X-MacProvider-Retry"))
	if s.maxRetries <= 0 || requestedRetries <= 0 || hasPinnedRoute(r.Header) {
		return false
	}
	if r.Context().Err() != nil {
		return false
	}
	if explicitRetries >= min(s.maxRetries, requestedRetries) {
		return false
	}
	if s.maxFaultedPerRequest > 0 && faultedProviders >= s.maxFaultedPerRequest {
		return false
	}
	if s.requestTimeout > 0 && s.now().Sub(startedAt)+s.retryPerAttemptTimeout > s.requestTimeout {
		return false
	}
	if err != nil {
		return true
	}
	return status == http.StatusBadGateway || status == http.StatusGatewayTimeout
}

func (s *Server) routingScores(candidates []pool.Provider, objective string) map[string]float64 {
	if objective == "balanced" {
		return balancedScores(candidates)
	}
	out := map[string]float64{}
	for _, p := range candidates {
		switch objective {
		case "fast":
			out[routeKey(p)] = s.effectiveThroughput(p)
		case "accurate":
			out[routeKey(p)] = p.ModelParamsB
		default:
			out[routeKey(p)] = s.effectiveThroughput(p)
		}
	}
	return out
}

func retryHeaderLimit(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if strings.EqualFold(value, "true") {
		return int(^uint(0) >> 1)
	}
	var n int
	if _, err := fmt.Sscanf(value, "%d", &n); err != nil || n <= 0 {
		return 0
	}
	return n
}

func (s *Server) inEpsilonCohort(top, candidate pool.Provider, objective string, candidates []pool.Provider) bool {
	switch objective {
	case "accurate":
		return withinRelativeEpsilon(top.ModelParamsB, candidate.ModelParamsB, s.tiebreakEpsilon)
	case "balanced":
		scores := balancedScores(candidates)
		return withinRelativeEpsilon(scores[routeKey(top)], scores[routeKey(candidate)], s.tiebreakEpsilon)
	default:
		if objective == "default" && top.SlotsFree != candidate.SlotsFree {
			return false
		}
		return withinRelativeEpsilon(s.effectiveThroughput(top), s.effectiveThroughput(candidate), s.tiebreakEpsilon)
	}
}

func withinRelativeEpsilon(top, candidate, epsilon float64) bool {
	if top == candidate {
		return true
	}
	if epsilon <= 0 {
		return false
	}
	denom := math.Abs(top)
	if denom == 0 {
		return math.Abs(candidate) <= epsilon
	}
	return math.Abs(top-candidate) <= denom*epsilon
}

func seedForRequest(requestID string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(requestID))
	return int64(h.Sum64())
}

func (s *Server) logRoutingDecision(requestID string, candidates []pool.Provider, objective string, seed int64, draw float64, reason, chosen string) {
	if chosen == "" && len(candidates) > 0 {
		chosen = candidates[0].ProviderID
	}
	scores := s.routingScores(candidates, objective)
	set := make([]map[string]any, 0, len(candidates))
	for _, p := range candidates {
		set = append(set, map[string]any{
			"provider_id":    p.ProviderID,
			"assigned_id":    p.AssignedID,
			"state":          string(p.State),
			"slots_free":     p.SlotsFree,
			"slots_total":    p.SlotsTotal,
			"throughput_tps": s.effectiveThroughput(p),
			"metric":         scores[routeKey(p)],
		})
	}
	s.log.Info().
		Str("event", "routing_decision").
		Str("request_id", requestID).
		Str("objective", objective).
		Interface("candidate_set", set).
		Int("candidate_count", len(candidates)).
		Float64("epsilon", s.tiebreakEpsilon).
		Int64("seed", seed).
		Float64("draw", draw).
		Str("chosen_provider_id", chosen).
		Str("reason", reason).
		Msg("routing decision")
}

func modelClassMembers(class *config.ModelClassConfig) []string {
	if class == nil {
		return nil
	}
	if len(class.Models) > 0 {
		return class.Models
	}
	return class.Members
}

func hasInternalRoutingHeader(headers http.Header) bool {
	for key, values := range headers {
		lowerKey := strings.ToLower(key)
		if lowerKey != "x-macprovider-account" && !strings.HasPrefix(lowerKey, "x-macprovider-internal-") {
			continue
		}
		for _, value := range values {
			if strings.TrimSpace(value) != "" {
				return true
			}
		}
	}
	return false
}

// internalBearerAuthorized guards the `/internal/routing` and
// `/internal/sticky` paths the gateway calls upstream. It accepts
// EITHER the operator key OR the gateway service token (M3-2 / SECU-4
// dual-credential bridge per the codex PR #73 fix). BOTH candidates are
// evaluated before branching to close the short-circuit timing oracle
// the audit flagged as MEDIUM. The audit-log line carries which class
// matched so the operator can watch the cutover.
//
// TODO(m3-2-cleanup): remove the operator-key fallback in a dedicated
// PR once live audit logs show zero gateway-origin
// `key=operator_key` for 30 days post-OperatorKey-rotation. Tracked in
// audits/2026-06-10/M3-2_LEGACY_FALLBACK_REMOVAL.md.
func (s *Server) internalBearerAuthorized(headers http.Header) bool {
	return s.internalBearerAuthorizedRemote(headers, "")
}

// internalBearerAuthorizedRemote is the variant called from request
// handlers that have a *http.Request available, so the audit-log line
// can carry the originating address. The non-remote variant calls this
// with an empty string for legacy in-band call sites that only have
// headers (e.g., the buyer routing-eligibility check).
func (s *Server) internalBearerAuthorizedRemote(headers http.Header, remoteAddr string) bool {
	return s.internalBearerAuthorizedFull(headers, remoteAddr, "")
}

func (s *Server) internalBearerAuthorizedFull(headers http.Header, remoteAddr, path string) bool {
	kind := auth.GatewayInternalBearerMatches(headers, s.internalAuthKey, s.gatewayServiceToken)
	if kind == auth.BearerKindNone {
		return false
	}
	s.log.Info().
		Str("event", "internal_bearer_accepted").
		Str("key", kind.String()).
		Str("path", path).
		Str("remote_addr", remoteAddr).
		Msg("internal bearer accepted")
	return true
}

func (s *Server) validatePinnedProviderForRequest(p pool.Provider, model string, estimatedTokens int, unavailableMessage string, class *config.ModelClassConfig) (pool.Provider, *routeError) {
	if !s.providerMatchesRequest(p, model, class) {
		return pool.Provider{}, &routeError{status: http.StatusNotFound, code: "model_not_found", message: "Pinned provider serves different model"}
	}
	if p.MaxContextTokens < estimatedTokens {
		return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds pinned provider context capacity"}
	}
	if !p.RoutingEligible() {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: unavailableMessage}
	}
	if s.tier2ProviderExcluded(p) {
		return pool.Provider{}, &routeError{
			status:  http.StatusBadRequest,
			code:    "tier2_hard_pin_predicate_failed",
			message: "Hard-pinned provider `" + p.ProviderID + "` does not satisfy enabled Tier-2 predicates.",
			typ:     "invalid_request",
		}
	}
	return p, nil
}

func routeKey(provider pool.Provider) string {
	return provider.ProviderID + "/" + provider.AssignedID
}

func (s *Server) preflightCandidate(provider pool.Provider, requestID string, estimatedTokens int) (pool.Provider, *routeError) {
	if estimatedTokens <= s.preflightThreshold || s.preflight == nil {
		return provider, nil
	}
	result, ok, err := s.preflight(provider, requestID, estimatedTokens, s.preflightTimeout)
	if err != nil || !ok {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "preflight_rejected", message: "Provider preflight timed out"}
	}
	if !result.Accepted {
		msg := "Provider rejected preflight"
		if result.Reason != "" {
			msg += ": " + result.Reason
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "preflight_rejected", message: msg}
	}
	return provider, nil
}

func validatePinnedProvider(p pool.Provider, model string, estimatedTokens int, unavailableMessage string) (pool.Provider, *routeError) {
	if !modelIDEqual(p.ModelID, model) {
		return pool.Provider{}, &routeError{status: http.StatusNotFound, code: "model_not_found", message: "Pinned provider serves different model"}
	}
	if p.MaxContextTokens < estimatedTokens {
		return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds pinned provider context capacity"}
	}
	if !p.RoutingEligible() {
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: unavailableMessage}
	}
	return p, nil
}

// hasAvailableSlot reports providers occupying a routable slot. Used by
// observability sites that branch on HashStatus and need to count
// mismatched/uncatalogued providers (which RoutingEligible excludes from
// routing entirely). Bearer-less duplicates are excluded here too —
// they hold a slot but are never legitimate.
//
// For routing decisions, use pool.Provider.RoutingEligible() — that is the
// single authority on whether a provider may receive traffic.
func hasAvailableSlot(p pool.Provider) bool {
	if p.AuthState == pool.AuthBearerlessDuplicate {
		return false
	}
	return p.State == pool.StateReady && p.SlotsFree > 0
}

func (s *Server) tier2ProviderExcluded(p pool.Provider) bool {
	cfg := s.tier2Config()
	return s.tier2ProviderExcludedForConfig(p, cfg)
}

func (s *Server) tier2ProviderExcludedForConfig(p pool.Provider, cfg config.Tier2Config) bool {
	if s.tier2ProviderExcludedStatus(s.effectiveHashStatus(p, cfg), cfg) {
		return true
	}
	if cfg.RequireEncryptedLeg && !p.EncryptedLeg {
		return true
	}
	if cfg.RequireAttestation && p.AttestationStatus != pool.AttestationStatusAttested {
		return true
	}
	return false
}

func (s *Server) tier2ProviderExcludedStatus(status pool.HashStatus, cfg config.Tier2Config) bool {
	if !tier2.ModelHashActive(cfg) {
		return false
	}
	return tier2.IsHashPredicateFailure(status, cfg.RequireHashVerified)
}

func (s *Server) effectiveHashStatus(p pool.Provider, cfg config.Tier2Config) pool.HashStatus {
	if !tier2.ModelHashActive(cfg) {
		return p.HashStatus
	}
	// Prefer pool-stored status: it is set at connect time and refreshed on
	// SIGHUP by RefreshTier2HashStatuses. Only fall back to live verification
	// for providers that connected before tier2 was activated.
	if p.HashStatus != "" {
		return p.HashStatus
	}
	// TODO(m3-8d-followup): legacy fallback uses the package-singleton shim
	// (tier2.VerifyProviderHash → tier2.Default()) because buyer.Server is
	// not yet threaded with an explicit *tier2.Catalog via DI. Migration is
	// tracked separately (see beta/DECISION_CRITERIA.md); switching it here
	// also unblocks t.Parallel() in internal/buyer/server_test.go.
	return tier2.VerifyProviderHash(p.ModelID, p.ModelHash)
}

func (s *Server) checkQuota(provider pool.Provider) bool {
	return s.admission == nil || s.admission.CheckQuota(provider)
}

func (s *Server) effectiveThroughput(provider pool.Provider) float64 {
	weight := 1.0
	if provider.Tier == pool.TierProvisional {
		weight = s.provisionalWeight
	}
	return provider.ThroughputTPSEstimate * weight
}

func modelIDEqual(a, b string) bool {
	return strings.EqualFold(a, b)
}

func (s *Server) zeroTokenFault(end providerws.InferenceResponseEnd, finishReason string) bool {
	completionTokens, ok := completionTokens(end.Usage)
	if !ok || completionTokens != 0 {
		return false
	}
	switch finishReason {
	case "stop", "length":
		return false
	default:
		return true
	}
}

func completionTokens(raw json.RawMessage) (int, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	var usage struct {
		CompletionTokens *int `json:"completion_tokens"`
	}
	if err := json.Unmarshal(raw, &usage); err != nil || usage.CompletionTokens == nil {
		return 0, false
	}
	return *usage.CompletionTokens, true
}

func tokenPointersFromChatResponse(body []byte) (*int64, *int64) {
	var resp struct {
		Usage json.RawMessage `json:"usage"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, nil
	}
	return tokenPointersFromUsageObject(resp.Usage)
}

func tokenPointersFromUsageObject(raw json.RawMessage) (*int64, *int64) {
	if len(raw) == 0 {
		return nil, nil
	}
	var usage struct {
		PromptTokens     *int64 `json:"prompt_tokens"`
		CompletionTokens *int64 `json:"completion_tokens"`
	}
	if err := json.Unmarshal(raw, &usage); err != nil {
		return nil, nil
	}
	return usage.PromptTokens, usage.CompletionTokens
}

func (s *Server) estimatedCompletionTokensFromBytes(n int) *int64 {
	return estimatedCompletionTokensFromBytes(n, s.tier2Config().OutputBytesPerTokenCeiling)
}

func (s *Server) observedCompletionTokensFromBytes(n int) *int64 {
	if n <= 0 {
		zero := int64(0)
		return &zero
	}
	return s.estimatedCompletionTokensFromBytes(n)
}

func estimatedCompletionTokensFromBytes(n, bytesPerToken int) *int64 {
	if n <= 0 {
		return nil
	}
	if bytesPerToken <= 0 {
		bytesPerToken = 4
	}
	tokens := int64((n + bytesPerToken - 1) / bytesPerToken)
	if tokens < 1 {
		tokens = 1
	}
	if tokens > maxRequestLogUsageTokens {
		tokens = maxRequestLogUsageTokens
	}
	return &tokens
}

func tokenPointersFromSSE(line []byte) (*int64, *int64) {
	text := strings.TrimSpace(string(line))
	if !strings.HasPrefix(text, "data:") {
		return nil, nil
	}
	payload := strings.TrimSpace(strings.TrimPrefix(text, "data:"))
	if payload == "" || payload == "[DONE]" {
		return nil, nil
	}
	return tokenPointersFromChatResponse([]byte(payload))
}

func spec001StatusFromBody(body []byte) string {
	var msg struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(body, &msg); err != nil {
		return ""
	}
	return spec001EndStatus(msg.Status)
}

func spec001EndStatus(status string) string {
	switch status {
	case "error_model_not_loaded", "error_context_exceeded", "error_queue_full", "error_internal":
		return status
	default:
		return ""
	}
}

func endErrorMessage(end providerws.InferenceResponseEnd) string {
	if spec001EndStatus(end.Status) != "" {
		return end.Status
	}
	return "Provider failed during inference"
}

func requestIDForBuyerRequest() string {
	return uuid.NewString()
}

func normalizeIdempotencyKey(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 256 {
		return ""
	}
	for _, r := range value {
		if r < 0x21 || r > 0x7e {
			return ""
		}
	}
	return value
}

func modelForRequestLog(body []byte) string {
	var raw struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return ""
	}
	return raw.Model
}

func buyerIP(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

func sanitizeRequestLogText(value string) string {
	const maxRunes = 256
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	runes := []rune(strings.TrimSpace(value))
	if len(runes) > maxRunes {
		runes = runes[:maxRunes]
	}
	return string(runes)
}

func finishReasonFromChatResponse(body []byte) string {
	var resp struct {
		Choices []struct {
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return ""
	}
	for _, choice := range resp.Choices {
		if choice.FinishReason != nil {
			return *choice.FinishReason
		}
	}
	return ""
}

func finishReasonFromSSE(data string) string {
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		if reason := finishReasonFromChatResponse([]byte(payload)); reason != "" {
			return reason
		}
	}
	return ""
}

func writeWSEndError(w http.ResponseWriter, end providerws.InferenceResponseEnd) {
	switch end.Status {
	case "error_context_exceeded":
		writeError(w, wsEndHTTPStatus(end.Status), "context_exceeds_capacity", "Request exceeds provider context capacity")
	case "error_model_not_loaded", "error_queue_full":
		writeError(w, wsEndHTTPStatus(end.Status), "provider_unavailable", "Selected provider is not reachable")
	case "cancelled":
		return
	default:
		writeError(w, wsEndHTTPStatus(end.Status), "provider_error", "Selected provider failed; buyer should retry")
	}
}

func wsEndHTTPStatus(status string) int {
	switch status {
	case "error_context_exceeded":
		return http.StatusRequestEntityTooLarge
	case "error_model_not_loaded", "error_queue_full":
		return http.StatusServiceUnavailable
	default:
		return http.StatusBadGateway
	}
}

func writeSSEError(w http.ResponseWriter, message, code string) {
	_, _ = fmt.Fprintf(w, "data: {\"error\":{\"message\":%q,\"type\":\"server_error\",\"code\":%q}}\n\n", message, code)
	_, _ = w.Write([]byte("data: [DONE]\n\n"))
}

func (s *Server) handleProviderFailure(provider pool.Provider, status int) {
	switch status {
	case http.StatusBadGateway, http.StatusGatewayTimeout:
		if s.pool.MarkDegradedForRecovery(provider.ProviderID, provider.AssignedID, pool.RecoveryReasonProviderFailure) {
			s.log.Warn().Str("provider_id", provider.ProviderID).Int("status", status).Msg("provider marked degraded after upstream failure")
			s.startRecoveryProbe(provider)
		}
	case 530:
		if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
			s.log.Warn().Str("provider_id", provider.ProviderID).Int("status", status).Str("reason", "http_530_observed").Msg("provider marked unavailable after HTTP 530")
		}
		s.closeProviderConn(provider, "http_530_observed")
	default:
		if status >= 300 && status < 400 {
			if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
				s.log.Warn().Str("provider_id", provider.ProviderID).Int("status", status).Str("reason", "provider_redirect_observed").Msg("provider marked unavailable after HTTP redirect")
			}
			s.closeProviderConn(provider, "provider_redirect_observed")
		}
	}
}

func (s *Server) closeProviderConn(provider pool.Provider, reason string) {
	conn, err := s.pool.Conn(provider.ProviderID, provider.AssignedID)
	if err != nil {
		return
	}
	if err := conn.Close(); err != nil {
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Str("reason", reason).Msg("provider websocket close after terminal HTTP failure failed")
	}
}

func (s *Server) startRecoveryProbe(provider pool.Provider) {
	if !s.recoveryProbe || s.preflight == nil || s.recoveryMaxRetries <= 0 {
		return
	}
	key := provider.ProviderID + "/" + provider.AssignedID
	if _, loaded := s.recovering.LoadOrStore(key, struct{}{}); loaded {
		return
	}
	go func() {
		defer s.recovering.Delete(key)
		delay := s.recoveryBackoff
		for attempt := 1; attempt <= s.recoveryMaxRetries; attempt++ {
			time.Sleep(delay)
			requestID := fmt.Sprintf("recovery-probe-%s-%d", provider.AssignedID, attempt)
			result, ok, err := s.preflight(provider, requestID, 128, s.preflightTimeout)
			if err == nil && ok && result.Accepted {
				if s.pool.MarkRecovered(provider.ProviderID, provider.AssignedID, s.now()) {
					s.log.Info().Str("provider_id", provider.ProviderID).Str("request_id", requestID).Msg("provider recovery preflight accepted")
				}
				return
			}
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Str("request_id", requestID).Msg("provider recovery preflight failed")
			delay = s.recoveryBackoff * 2
		}
		if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
			s.log.Warn().Str("provider_id", provider.ProviderID).Msg("provider marked unavailable after recovery preflight failures")
		}
	}()
}

func estimateTokens(raw json.RawMessage) int {
	n := len(raw) / 4
	if n < 1 {
		return 1
	}
	return n
}

func copyReceiptHeaderForProvider(dst, src http.Header, provider pool.Provider) {
	if !providerReceiptEligible(provider) {
		return
	}
	if receipt := normalizeReceiptHeaderValue(src.Get("X-MacProvider-Receipt")); receipt != "" {
		dst.Set("X-MacProvider-Receipt", receipt)
	}
}

func setReceiptHeaderForProvider(dst http.Header, value string, provider pool.Provider) {
	if !providerReceiptEligible(provider) {
		return
	}
	if receipt := normalizeReceiptHeaderValue(value); receipt != "" {
		dst.Set("X-MacProvider-Receipt", receipt)
	}
}

// normalizeReceiptHeaderValue enforces SPEC-015 AC-15: the receipt header
// is at most 4096 ASCII bytes and contains no CR/LF/NUL. Returns "" when
// the candidate value fails either constraint so the caller drops the
// header rather than poisoning the response (nginx upstream defaults are
// 8 KiB and a malicious provider header would otherwise convert into a
// 502 at the gateway hop).
func normalizeReceiptHeaderValue(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	if len(value) > 4096 {
		return ""
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if c < 0x20 || c > 0x7E {
			return ""
		}
	}
	return value
}

func providerReceiptEligible(provider pool.Provider) bool {
	return len(provider.ReceiptPubkey) > 0
}

func nullUsageProviderErrorCode(body []byte) string {
	if code := spec001StatusFromBody(body); code != "" {
		return code
	}
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return ""
	}
	return spec001EndStatus(envelope.Error.Code)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeErrorTyped(w, status, errorType(status), code, message)
}

func writeRouteError(w http.ResponseWriter, err *routeError) {
	if err.typ != "" {
		writeErrorTyped(w, err.status, err.typ, err.code, err.message)
		return
	}
	writeError(w, err.status, err.code, err.message)
}

func writeErrorTyped(w http.ResponseWriter, status int, typ, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	if status == http.StatusTooManyRequests && code == "provisional_quota_exceeded" {
		w.Header().Set("Retry-After", "3600")
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"message": message,
			"type":    typ,
			"param":   nil,
			"code":    code,
		},
	})
}

func readLimitedBody(r io.Reader, maxBytes int64) ([]byte, error) {
	if maxBytes < 0 {
		maxBytes = 0
	}
	lr := &io.LimitedReader{R: r, N: maxBytes + 1}
	body, err := io.ReadAll(lr)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > maxBytes {
		return nil, errBodyTooLarge
	}
	return body, nil
}

func errorType(status int) string {
	switch status {
	case http.StatusBadRequest:
		return "invalid_request_error"
	case http.StatusNotFound:
		return "invalid_request_error"
	case http.StatusRequestEntityTooLarge:
		return "invalid_request_error"
	case http.StatusTooManyRequests:
		return "rate_limit_error"
	case http.StatusServiceUnavailable:
		return "service_unavailable"
	default:
		return "upstream_error"
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
