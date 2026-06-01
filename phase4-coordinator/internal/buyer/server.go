package buyer

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"math"
	mrand "math/rand"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

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
	tier2Mu                sync.RWMutex
	tier2                  config.Tier2Config
	reqLog                 requestLogInserter
	reqLogStore            *requestlog.Store
	provisionalWeight      float64
	maxChatBodyBytes       int64
	recovering             sync.Map
	poolCheckLast          sync.Map
	billingMu              sync.RWMutex
	billing                *billing.Store
	billingCfg             config.RewardsConfig
	billingSnapshotID      int64
	now                    func() time.Time
}

type stickyEntry struct {
	ConversationKey string
	ProviderID      string
	AccountID       string
	ModelScope      string
	CreatedAt       time.Time
	LastUsedAt      time.Time
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

const maxRequestLogUsageTokens = int64(10000000)

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

func WithBillingSnapshotID(snapshotID int64) Option {
	return func(s *Server) {
		s.billingMu.Lock()
		defer s.billingMu.Unlock()
		s.billingSnapshotID = snapshotID
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
		now:                    func() time.Time { return time.Now().UTC() },
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
	if !s.internalBearerAuthorized(r.Header) {
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
			if !baseRoutingEligible(p) {
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
	if !s.internalBearerAuthorized(r.Header) {
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
		Version:  "0.1.0",
	}
	for _, p := range providers {
		switch p.State {
		case pool.StateReady:
			resp.PoolReady++
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

func (s *Server) allowPoolCheck(r *http.Request) bool {
	ip := clientIP(r)
	now := time.Now()
	if prevAny, ok := s.poolCheckLast.Load(ip); ok {
		if now.Sub(prevAny.(time.Time)) < time.Second {
			return false
		}
	}
	s.poolCheckLast.Store(ip, now)
	return true
}

func clientIP(r *http.Request) string {
	if forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); forwarded != "" {
		if i := strings.IndexByte(forwarded, ','); i >= 0 {
			return strings.TrimSpace(forwarded[:i])
		}
		return forwarded
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		return r.RemoteAddr
	}
	return host
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
		if pillarAActive && !baseRoutingEligible(p) {
			continue
		}
		if !pillarAActive && p.State != pool.StateReady {
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
		if !baseRoutingEligible(p) || !modelIDEqual(p.ModelID, entry.ID) {
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
	requestID := requestIDForBuyerRequest(externalRequestID)
	routingRequestID := uuid.NewString()
	originalRequestID := requestID
	startedAt := s.now()
	routingDone := startedAt
	requestLogModel := ""
	requestLogStream := false
	explicitRetries := 0
	billingAttemptN := 0
	logRowWithBilling := func(
		providerAssignedID string,
		status int,
		promptTok, completionTok *int64,
		errMsg, errCode string,
		retried int,
		estimatedCompTokens *int64,
		faultFlag string,
	) {
		if s.reqLog == nil {
			return
		}
		attemptN := billingAttemptN
		if providerAssignedID != "" && status != http.StatusServiceUnavailable {
			defer func() {
				billingAttemptN++
			}()
		}
		row := requestlog.Row{
			TSUtc:              startedAt,
			RequestID:          originalRequestID,
			Model:              requestLogModel,
			ProviderAssignedID: providerAssignedID,
			PromptTokens:       promptTok,
			CompletionTokens:   completionTok,
			LatencyMs:          float64(time.Since(startedAt).Milliseconds()),
			RoutingMs:          float64(routingDone.Sub(startedAt).Milliseconds()),
			Status:             status,
			Stream:             requestLogStream,
			BuyerIP:            buyerIP(r.RemoteAddr),
			Error:              sanitizeRequestLogText(errMsg),
			ErrorCode:          errCode,
			PrefHeader:         sanitizeRequestLogText(r.Header.Get("X-MacProvider-Pref")),
			ProviderHeader:     sanitizeRequestLogText(r.Header.Get("X-MacProvider-Provider")),
			Retried:            retried,
		}
		ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		defer cancel()
		billingStore, billingCfg, billingSnapshotID := s.billingState()
		if billingStore != nil && s.reqLogStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable {
			stableProviderID := ""
			for _, p := range s.pool.Snapshot() {
				if p.AssignedID == providerAssignedID {
					stableProviderID = p.ProviderID
					break
				}
			}
			if stableProviderID != "" {
				if faultFlag == "" {
					faultFlag = billing.FaultNone
				}
				err := billingStore.WriteHotPath(ctx, s.reqLogStore, row, billing.HotPathInput{
					RequestID:           row.RequestID,
					AttemptN:            attemptN,
					ProviderAssignedID:  providerAssignedID,
					ProviderID:          stableProviderID,
					Model:               row.Model,
					Status:              status,
					Stream:              row.Stream,
					TSUtc:               row.TSUtc,
					PromptTokens:        promptTok,
					CompletionTokens:    completionTok,
					EstimatedCompTokens: estimatedCompTokens,
					ErrorCode:           errCode,
					FaultFlag:           faultFlag,
					ConfigSnapshotID:    billingSnapshotID,
					RateEntry:           billing.RateFor(billingCfg.RateCard, row.Model),
					MultiplierPPM:       billing.ParseMultiplierPPM(billingCfg.GlobalMultiplier),
					ProviderShareBps:    billing.ParseShareBps(billingCfg.ProviderShare),
				})
				if err != nil {
					s.log.Warn().Err(err).Str("request_id", originalRequestID).Msg("billing hot-path insert failed")
				} else {
					return
				}
			}
		}
		if err := s.reqLog.Insert(ctx, row); err != nil {
			s.log.Warn().Err(err).Str("request_id", originalRequestID).Msg("request_log insert failed")
		}
	}
	logRow := func(
		providerAssignedID string,
		status int,
		promptTok, completionTok *int64,
		errMsg, errCode string,
		retried int,
	) {
		logRowWithBilling(providerAssignedID, status, promptTok, completionTok, errMsg, errCode, retried, nil, billing.FaultNone)
	}
	logBuyerFailure := func(status int, msg string) {
		logRow("", status, nil, nil, msg, "", 0)
	}
	maxBodyBytes := s.maxChatBodyBytes
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	if err != nil {
		logBuyerFailure(http.StatusBadRequest, "Could not read request body")
		writeError(w, http.StatusBadRequest, "invalid_request", "Could not read request body")
		return
	}
	requestLogModel = modelForRequestLog(body)
	if int64(len(body)) > maxBodyBytes {
		logBuyerFailure(http.StatusRequestEntityTooLarge, "Request body too large")
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "Request body too large")
		return
	}
	req, status, code, msg := validateChatRequest(body)
	if status != 0 {
		logBuyerFailure(status, msg)
		writeError(w, status, code, msg)
		return
	}
	requestLogModel = req.Model
	requestLogStream = req.Stream
	if !s.pool.ModelKnown(req.Model) && s.resolveModelClass(req.Model) == nil {
		logBuyerFailure(http.StatusNotFound, "No provider has advertised model "+req.Model)
		writeError(w, http.StatusNotFound, "model_not_found", "No provider has advertised model "+req.Model)
		return
	}
	logAttempt := func(provider pool.Provider, fallbackStatus int, attempt requestLogAttempt) {
		status := attempt.Status
		if status == 0 {
			status = fallbackStatus
		}
		if attempt.PromptTokens == nil && attempt.ErrorCode == "" && (attempt.EstimatedCompTokens != nil || status == http.StatusBadGateway || status == http.StatusGatewayTimeout) {
			estimatedPrompt := int64(estimateTokens(req.raw))
			attempt.PromptTokens = &estimatedPrompt
		}
		logRowWithBilling(provider.AssignedID, status, attempt.PromptTokens, attempt.CompletionTokens, attempt.Error, attempt.ErrorCode, explicitRetries, attempt.EstimatedCompTokens, attempt.FaultFlag)
	}
	shouldLogAttempt := func(attempt requestLogAttempt) bool {
		return attempt.Status != 0 || attempt.PromptTokens != nil || attempt.CompletionTokens != nil || attempt.EstimatedCompTokens != nil || attempt.Error != "" || attempt.ErrorCode != ""
	}
	provider, routeErr := s.selectProvider(routingRequestID, req, r.Header)
	if routeErr != nil {
		routingDone = s.now()
		logRow("", routeErr.status, nil, nil, routeErr.message, "", 0)
		writeRouteError(w, routeErr)
		return
	}
	routingDone = s.now()
	faultedProviders := 0
	faultedRoutes := map[string]struct{}{}
	if req.Stream {
		failoverAttempted := false
		excluded := map[string]struct{}{}
		for {
			dispatchBody, err := dispatchBodyForProvider(req, provider)
			if err != nil {
				logRow(provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return
			}
			if provider.IsWSTunneled() {
				result, attempt := s.forwardWS(w, r, requestID, dispatchBody, provider, true, s.attemptTimeout(r))
				if result == wsForwardProviderDisconnectedCommitted {
					logAttempt(provider, http.StatusOK, attempt)
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, provider, "stream_terminal", "")
					return
				}
				if result == wsForwardComplete {
					logAttempt(provider, http.StatusOK, attempt)
					s.stickyStore(r.Header, provider, req.Model)
					return
				}
				excluded[routeKey(provider)] = struct{}{}
				faultedRoutes[routeKey(provider)] = struct{}{}
				if result == wsForwardCancelled {
					if shouldLogAttempt(attempt) {
						logAttempt(provider, http.StatusOK, attempt)
					}
					return
				}
				if result == wsForwardProviderDisconnected {
					if !failoverAttempted && !hasPinnedRoute(r.Header) {
						next, ok := s.failoverCandidate(uuid.NewString(), req, r.Header, provider, excluded)
						if ok {
							s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, provider, "failover", next.ProviderID)
							failoverAttempted = true
							provider = next
							continue
						}
					}
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, provider, "fast_fail", "")
				}
				if !s.shouldRetry(r, startedAt, explicitRetries, faultedProviders, statusForForwardResult(result), nil) {
					logAttempt(provider, statusForForwardResult(result), attempt)
					writeStreamForwardError(w, result)
					return
				}
				logAttempt(provider, statusForForwardResult(result), attempt)
				nextRouteID := uuid.NewString()
				next, routeErr := s.selectProviderExcluding(nextRouteID, req, r.Header, excluded)
				if routeErr != nil {
					routingDone = s.now()
					logRow("", routeErr.status, nil, nil, routeErr.message, "", explicitRetries)
					writeRouteError(w, routeErr)
					return
				}
				routingDone = s.now()
				explicitRetries++
				faultedProviders++
				provider = next
				excluded[routeKey(provider)] = struct{}{}
				s.logRoutingDecision(nextRouteID, []pool.Provider{provider}, "retry", 0, 0, "retry_"+itoa(explicitRetries), provider.ProviderID)
				continue
			}
			result, status, attempt := s.forwardStreaming(w, r, requestID, dispatchBody, provider, req.Model, s.attemptTimeout(r))
			if result == wsForwardComplete {
				logAttempt(provider, status, attempt)
				return
			}
			if result == wsForwardProviderDisconnectedCommitted || result == wsForwardCancelled {
				if shouldLogAttempt(attempt) {
					logAttempt(provider, http.StatusOK, attempt)
				}
				return
			}
			excluded[routeKey(provider)] = struct{}{}
			if !s.shouldRetry(r, startedAt, explicitRetries, faultedProviders, status, nil) {
				logAttempt(provider, status, attempt)
				writeStreamForwardError(w, result)
				return
			}
			logAttempt(provider, status, attempt)
			nextRouteID := uuid.NewString()
			next, routeErr := s.selectProviderExcluding(nextRouteID, req, r.Header, excluded)
			if routeErr != nil {
				routingDone = s.now()
				logRow("", routeErr.status, nil, nil, routeErr.message, "", explicitRetries)
				writeRouteError(w, routeErr)
				return
			}
			routingDone = s.now()
			explicitRetries++
			faultedProviders++
			provider = next
			excluded[routeKey(provider)] = struct{}{}
			s.logRoutingDecision(nextRouteID, []pool.Provider{provider}, "retry", 0, 0, "retry_"+itoa(explicitRetries), provider.ProviderID)
		}
	}
	if provider.IsWSTunneled() {
		excluded := map[string]struct{}{}
		failoverAttempted := false
		for {
			dispatchBody, err := dispatchBodyForProvider(req, provider)
			if err != nil {
				logRow(provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return
			}
			result, attempt := s.forwardWS(w, r, requestID, dispatchBody, provider, false, s.attemptTimeout(r))
			if result == wsForwardComplete {
				logAttempt(provider, http.StatusOK, attempt)
				s.stickyStore(r.Header, provider, req.Model)
				return
			}
			if result == wsForwardTimedOut {
				excluded[routeKey(provider)] = struct{}{}
				faultedRoutes[routeKey(provider)] = struct{}{}
				if !s.shouldRetry(r, startedAt, explicitRetries, faultedProviders, http.StatusGatewayTimeout, nil) {
					logAttempt(provider, http.StatusGatewayTimeout, attempt)
					writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
					return
				}
				logAttempt(provider, http.StatusGatewayTimeout, attempt)
				nextRouteID := uuid.NewString()
				next, routeErr := s.selectProviderExcluding(nextRouteID, req, r.Header, excluded)
				if routeErr != nil {
					routingDone = s.now()
					logRow("", routeErr.status, nil, nil, routeErr.message, "", explicitRetries)
					writeRouteError(w, routeErr)
					return
				}
				routingDone = s.now()
				explicitRetries++
				faultedProviders++
				provider = next
				excluded[routeKey(provider)] = struct{}{}
				if provider.IsWSTunneled() {
					continue
				}
				break
			}
			if result == wsForwardFailed || result == wsForwardUnavailable || result == wsForwardCancelled {
				if result != wsForwardCancelled || shouldLogAttempt(attempt) {
					logAttempt(provider, statusForForwardResult(result), attempt)
				}
				return
			}
			if result == wsForwardProviderDisconnected {
				excluded[routeKey(provider)] = struct{}{}
				faultedRoutes[routeKey(provider)] = struct{}{}
				if failoverAttempted || hasPinnedRoute(r.Header) {
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, provider, "fast_fail", "")
					logAttempt(provider, http.StatusBadGateway, attempt)
					writeError(w, http.StatusBadGateway, "provider_disconnected", "Selected provider disconnected; buyer should retry")
					return
				}
				next, ok := s.failoverCandidate(uuid.NewString(), req, r.Header, provider, excluded)
				if !ok {
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, provider, "fast_fail", "")
					logAttempt(provider, http.StatusBadGateway, attempt)
					writeError(w, http.StatusBadGateway, "provider_disconnected", "Selected provider disconnected; buyer should retry")
					return
				}
				s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, provider, "failover", next.ProviderID)
				logAttempt(provider, http.StatusBadGateway, attempt)
				failoverAttempted = true
				provider = next
				if provider.IsWSTunneled() {
					continue
				}
				break
			}
			if result == wsForwardQueueFull {
				s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateBusy)
				excluded[routeKey(provider)] = struct{}{}
				logAttempt(provider, http.StatusBadGateway, attempt)
			}
			provider, routeErr = s.selectProviderExcluding(uuid.NewString(), req, r.Header, excluded)
			if routeErr != nil {
				routingDone = s.now()
				logRow("", routeErr.status, nil, nil, routeErr.message, "", explicitRetries)
				writeRouteError(w, routeErr)
				return
			}
			routingDone = s.now()
			if !provider.IsWSTunneled() {
				break
			}
		}
	}
	excluded := map[string]struct{}{}
	for key := range faultedRoutes {
		excluded[key] = struct{}{}
	}
	excluded[routeKey(provider)] = struct{}{}
	for {
		dispatchBody, err := dispatchBodyForProvider(req, provider)
		if err != nil {
			logRow(provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			return
		}
		upstreamURL := provider.EndpointURL + "/v1/chat/completions"
		attemptCtx := r.Context()
		cancelAttempt := func() {}
		retryRequested := s.maxRetries > 0 && retryHeaderLimit(r.Header.Get("X-MacProvider-Retry")) > 0
		if retryRequested && s.retryPerAttemptTimeout > 0 {
			attemptCtx, cancelAttempt = context.WithTimeout(r.Context(), s.retryPerAttemptTimeout)
		}
		upReq, err := http.NewRequestWithContext(attemptCtx, http.MethodPost, upstreamURL, bytes.NewReader(dispatchBody))
		if err != nil {
			cancelAttempt()
			logRow(provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
			return
		}
		upReq.Header.Set("Content-Type", "application/json")
		upReq.Header.Set("X-Request-ID", originalRequestID)
		resp, err := providerhttp.Client.Do(upReq)
		if err == nil && resp.StatusCode == http.StatusOK {
			respBody, readErr := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			if readErr != nil {
				cancelAttempt()
				logRow(provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return
			}
			w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
			if w.Header().Get("Content-Type") == "" {
				w.Header().Set("Content-Type", "application/json")
			}
			w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
			w.Header().Set("X-MacProvider-Route", provider.AssignedID)
			w.WriteHeader(http.StatusOK)
			s.stickyStore(r.Header, provider, req.Model)
			_, _ = w.Write(respBody)
			cancelAttempt()
			promptTok, completionTok := tokenPointersFromChatResponse(respBody)
			logRow(provider.AssignedID, http.StatusOK, promptTok, completionTok, "", "", explicitRetries)
			return
		}
		status := 0
		attempt := requestLogAttempt{}
		if resp != nil {
			status = resp.StatusCode
			respBody, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			attempt.ErrorCode = spec001StatusFromBody(respBody)
		}
		cancelAttempt()
		s.log.Warn().Err(err).Int("status", status).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider request failed")
		if status != 0 {
			s.handleProviderFailure(provider, status)
		}
		if !s.shouldRetry(r, startedAt, explicitRetries, faultedProviders, status, err) {
			if retryRequested && status == http.StatusGatewayTimeout {
				logRow(provider.AssignedID, http.StatusGatewayTimeout, nil, nil, "Selected provider timed out; buyer should retry", attempt.ErrorCode, explicitRetries)
				writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
				return
			}
			logRow(provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", attempt.ErrorCode, explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
			return
		}
		failStatus := status
		if failStatus == 0 {
			failStatus = http.StatusBadGateway
		}
		errMsg := "Selected provider failed; buyer should retry"
		if err != nil {
			errMsg = err.Error()
		}
		logRow(provider.AssignedID, failStatus, nil, nil, errMsg, attempt.ErrorCode, explicitRetries)
		nextRouteID := uuid.NewString()
		next, routeErr := s.selectProviderExcluding(nextRouteID, req, r.Header, excluded)
		if routeErr != nil {
			routingDone = s.now()
			logRow("", routeErr.status, nil, nil, routeErr.message, "", explicitRetries)
			writeRouteError(w, routeErr)
			return
		}
		routingDone = s.now()
		explicitRetries++
		faultedProviders++
		provider = next
		excluded[routeKey(provider)] = struct{}{}
		s.logRoutingDecision(nextRouteID, []pool.Provider{provider}, "retry", 0, 0, "retry_"+itoa(explicitRetries), provider.ProviderID)
	}
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
		return estimatedCompletionTokensFromBytes(body.Len())
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
			checkedBody, err := guard.CheckNonStreamingBody(body.Bytes())
			if err != nil {
				writeError(w, http.StatusBadGateway, "tier2_output_encoding_invalid", "Provider returned invalid Tier2 output encoding")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider returned invalid Tier2 output encoding"}
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
			w.Header().Set("X-MacProvider-Route", provider.AssignedID)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(checkedBody)
			promptTok, completionTok := tokenPointersFromUsageObject(end.Usage)
			if promptTok == nil && completionTok == nil {
				promptTok, completionTok = tokenPointersFromChatResponse(checkedBody)
			}
			return wsForwardComplete, requestLogAttempt{Status: http.StatusOK, PromptTokens: promptTok, CompletionTokens: completionTok, FaultFlag: faultFlag}
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
		return requestLogAttempt{Status: http.StatusOK, Error: message, EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: faultFlag}
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
			attempt := requestLogAttempt{Status: http.StatusOK}
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
					attempt.EstimatedCompTokens = estimatedCompletionTokensFromBytes(bytesEmitted)
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
					return wsForwardProviderDisconnected, requestLogAttempt{Status: http.StatusBadGateway, Error: "Selected provider disconnected; buyer should retry", EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
				}
				writeSSEError(w, "Provider disconnected during streaming", "provider_disconnected")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardProviderDisconnectedCommitted, requestLogAttempt{Status: http.StatusOK, Error: "Provider disconnected during streaming", EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
			}
			if errors.Is(err, providerws.ErrRelayTimeout) {
				s.recordBreakerFault(provider, breakerFaultRelayTimeout, requestID)
				if !committed {
					return wsForwardTimedOut, requestLogAttempt{Status: http.StatusGatewayTimeout, Error: "Selected provider timed out; buyer should retry", EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
				}
				commit()
				writeSSEError(w, "Provider timed out during streaming", "provider_timeout")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardProviderDisconnectedCommitted, requestLogAttempt{Status: http.StatusOK, Error: "Provider timed out during streaming", EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
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
				return wsForwardFailed, requestLogAttempt{Status: http.StatusOK, Error: "Provider encrypted response failed authentication", EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
			}
			commit()
			writeSSEError(w, "Provider failed during streaming", "provider_error")
			if flusher != nil {
				flusher.Flush()
			}
			return wsForwardFailed, requestLogAttempt{Status: http.StatusOK, Error: "Provider failed during streaming", EstimatedCompTokens: estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: billing.FaultBreakerQualifying}
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
		return wsForwardFailed, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: err.Error()}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		s.log.Warn().Int("status", resp.StatusCode).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider returned non-200")
		s.handleProviderFailure(provider, resp.StatusCode)
		respBody, _ := io.ReadAll(resp.Body)
		attempt := requestLogAttempt{Status: resp.StatusCode, Error: http.StatusText(resp.StatusCode), ErrorCode: spec001StatusFromBody(respBody)}
		if resp.StatusCode == http.StatusGatewayTimeout {
			return wsForwardTimedOut, resp.StatusCode, attempt
		}
		return wsForwardFailed, resp.StatusCode, attempt
	}

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
	w.Header().Set("X-MacProvider-Route", provider.AssignedID)
	w.WriteHeader(http.StatusOK)
	// NOTE: HTTP-streaming sticky write is deferred to after io.EOF (clean
	// stream completion), per the SPEC-004 v0.2 audit. Storing affinity
	// upfront would pin the conversation to a provider that may disconnect
	// mid-stream, leaving the sticky entry pointing at a degraded route.
	// The store call now lives in the io.EOF branch below; the
	// wsForwardProviderDisconnectedCommitted branch intentionally does NOT
	// write sticky (the provider failed mid-flight).
	flusher, _ := w.(http.Flusher)

	reader := bufio.NewReader(resp.Body)
	var promptTok, completionTok *int64
	bytesEmitted := 0
	progressAttempt := func(message string, faultFlag string) requestLogAttempt {
		attempt := requestLogAttempt{Status: http.StatusOK, PromptTokens: promptTok, CompletionTokens: completionTok, Error: message, FaultFlag: faultFlag}
		if completionTok == nil {
			attempt.EstimatedCompTokens = estimatedCompletionTokensFromBytes(bytesEmitted)
		}
		return attempt
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
			return wsForwardComplete, http.StatusOK, requestLogAttempt{Status: http.StatusOK, PromptTokens: promptTok, CompletionTokens: completionTok}
		}
		s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("provider disconnected during streaming")
		writeSSEError(w, "Provider disconnected during streaming", "provider_disconnected")
		if flusher != nil {
			flusher.Flush()
		}
		return wsForwardProviderDisconnectedCommitted, http.StatusOK, progressAttempt("Provider disconnected during streaming", billing.FaultBreakerQualifying)
	}
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
		if !s.providerMatchesRequest(p, req.Model, class) || !baseRoutingEligible(p) {
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

func (s *Server) internalBearerAuthorized(headers http.Header) bool {
	expected := strings.TrimSpace(s.internalAuthKey)
	if expected == "" {
		return false
	}
	auth := strings.TrimSpace(headers.Get("Authorization"))
	token, ok := strings.CutPrefix(auth, "Bearer ")
	if !ok {
		return false
	}
	token = strings.TrimSpace(token)
	if len(token) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1
}

func (s *Server) validatePinnedProviderForRequest(p pool.Provider, model string, estimatedTokens int, unavailableMessage string, class *config.ModelClassConfig) (pool.Provider, *routeError) {
	if !s.providerMatchesRequest(p, model, class) {
		return pool.Provider{}, &routeError{status: http.StatusNotFound, code: "model_not_found", message: "Pinned provider serves different model"}
	}
	if p.MaxContextTokens < estimatedTokens {
		return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds pinned provider context capacity"}
	}
	if !baseRoutingEligible(p) {
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

func baseRoutingEligible(p pool.Provider) bool {
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

func estimatedCompletionTokensFromBytes(n int) *int64 {
	if n <= 0 {
		return nil
	}
	tokens := int64((n + 3) / 4)
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

func requestIDForBuyerRequest(headerValue string) string {
	if headerValue != "" {
		if parsed, err := uuid.Parse(headerValue); err == nil && parsed.Version() == 4 {
			return parsed.String()
		}
	}
	return uuid.NewString()
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
