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
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/augstar/macprovider-coordinator/internal/routing/sticky"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

var errBodyTooLarge = errors.New("upstream response body too large")

const (
	maxToolCallArgumentsBytes         = 1_048_576
	maxToolCallArgumentsResponseBytes = 2_097_152
	maxToolCallArgumentsDepth         = 32
	maxJSONSchemaBytes                = 16_384
	maxJSONSchemaDepth                = 32
	maxToolResultBytes                = 256 * 1024
	maxToolResultsAggregateBytes      = 1_048_576
	maxChatMessages                   = 256
	maxAssistantToolCalls             = 128
)

var spec018RetryableByCode = map[string]bool{
	"byte_cap_exceeded":                                       false,
	"response_byte_cap_exceeded":                              false,
	"malformed_tool_call_final_json":                          true,
	"provider_stream_downgraded":                              true,
	"json_schema_missing_name":                                false,
	"json_schema_missing_schema":                              false,
	"json_schema_invalid_name":                                false,
	"json_schema_non_strict_unsupported":                      false,
	"streaming_json_schema_unsupported":                       false,
	"streaming_json_object_unsupported":                       false,
	"json_schema_unsupported_keyword":                         false,
	"json_schema_strict_requires_additional_properties_false": false,
	"json_schema_strict_requires_all_properties_required":     false,
	"json_schema_invalid_const_or_enum_type":                  false,
	"json_schema_too_deep":                                    false,
	"json_schema_too_large":                                   false,
	"request_content_encoding_unsupported":                    false,
	"provider_timeout":                                        false,
	"malformed_json_response":                                 true,
	"json_schema_validation_failed":                           true,
	"request_body_too_large":                                  false,
	"tool_result_too_large":                                   false,
	"tool_results_aggregate_too_large":                        false,
	"tool_call_arguments_too_large":                           false,
	"tool_call_arguments_aggregate_too_large":                 false,
	"messages_too_long":                                       false,
	"too_many_tool_calls":                                     false,
	"invalid_tool_call_id":                                    false,
	"tool_call_id_not_found":                                  false,
	"duplicate_tool_call_id":                                  false,
	"tool_call_result_out_of_order":                           false,
	"unsupported_modelID_for_multi_turn":                      false,
}

func spec018Retryable(code string) bool {
	return spec018RetryableByCode[code]
}

type Server struct {
	pool               *pool.Registry
	log                zerolog.Logger
	createdAt          int64
	preflight          PreflightFunc
	preflightThreshold int
	preflightTimeout   time.Duration
	recoveryBackoff    time.Duration
	recoveryMaxRetries int
	recoveryProbe      bool
	breakerThreshold   int
	breakerWindow      time.Duration
	relay              RelayFunc
	admission          *providerws.AdmissionManager
	requestTimeout     time.Duration
	failoverEnabled    bool
	failoverTimeout    time.Duration
	tiebreakRandomize  bool
	tiebreakEpsilon    float64
	// routingMu guards modelClasses, which is hot-swapped on SIGHUP
	// when routing.model_classes shape changes (issue #266 T1).
	// Pre-SIGHUP readers (handleModels iteration at modelEntry build;
	// resolveModelClass per-request hot path) MUST take a read lock
	// or use the snapshot accessors below — never read s.modelClasses
	// directly outside the routingMu critical section.
	routingMu              sync.RWMutex
	modelClasses           map[string]config.ModelClassConfig
	maxRetries             int
	retryPerAttemptTimeout time.Duration
	maxFaultedPerRequest   int
	stickyEnabled          bool
	stickyTTL              time.Duration
	stickyMaxEntries       int
	stickyMap              *sticky.Map
	// stickyMismatchLimiter throttles the sticky_account_mismatch
	// warn-log per conversation_key to defend against hostile-gateway
	// log flooding. Issue #266 T1 operational-hygiene item.
	stickyMismatchLimiter *stickyMismatchLimiter
	internalAuthKey       string
	gatewayServiceToken   string
	tier2Mu               sync.RWMutex
	tier2                 config.Tier2Config
	reqLog                requestLogInserter
	reqLogStore           *requestlog.Store
	provisionalWeight     float64
	maxChatBodyBytes      int64
	recovering            sync.Map
	poolCheckMu           sync.Mutex
	poolCheckLast         map[string]time.Time
	poolCheckMaxEntries   int
	poolCheckTTL          time.Duration
	receiptKeysMu         sync.Mutex
	receiptKeysLimiters   map[string]receiptKeysBucket
	receiptKeysMaxEntries int
	receiptKeysTTL        time.Duration
	streamingDowngrade    *streamingDowngradeStore
	streamingTiming       *streamingTimingCollector
	// trustedProxies is the parsed CIDR set whose X-Forwarded-For /
	// X-Real-IP headers the rate-limit keying honors. Pre-parsed at
	// construction (config.go TrustedProxyPrefixes) so the hot path
	// never re-parses. Default loopback-only — see WithTrustedProxies.
	// Issue #125.
	trustedProxies    []netip.Prefix
	billingMu         sync.RWMutex
	billing           *billing.Store
	billingCfg        config.RewardsConfig
	billingSnapshotID int64
	now               func() time.Time
	version           string
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
		s.routingMu.Lock()
		s.modelClasses = cloneModelClasses(cfg.ModelClasses)
		s.routingMu.Unlock()
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

// WithTrustedProxies sets the parsed trusted-proxy CIDR set the
// rate-limit keying honors. When r.RemoteAddr falls inside one of
// these prefixes, the coordinator parses X-Forwarded-For (rightmost
// untrusted hop) / X-Real-IP to derive the per-source key for
// /v1/pool/check, /v1/receipt-keys/*, and /catalog/* buckets;
// otherwise r.RemoteAddr is used unmodified so an attacker on the
// open internet cannot spoof their bucket key by sending those
// headers themselves. Issue #125.
//
// Pass the result of config.Config.TrustedProxyPrefixes(); Validate
// already rejected malformed CIDRs at Load time. A nil/empty list
// trusts NO proxy — only direct connections, matching the strictest
// possible production posture.
func WithTrustedProxies(prefixes []netip.Prefix) Option {
	return func(s *Server) {
		s.trustedProxies = append(s.trustedProxies[:0], prefixes...)
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
		modelClasses:           map[string]config.ModelClassConfig{},
		provisionalWeight:      0.3,
		maxChatBodyBytes:       config.Default().Limits.MaxChatRequestBodyBytes,
		poolCheckLast:          map[string]time.Time{},
		poolCheckMaxEntries:    4096,
		poolCheckTTL:           time.Minute,
		receiptKeysLimiters:    map[string]receiptKeysBucket{},
		receiptKeysMaxEntries:  4096,
		receiptKeysTTL:         5 * time.Minute,
		streamingDowngrade:     newStreamingDowngradeStore(),
		streamingTiming:        newStreamingTimingCollector(),
		// Default trusted-proxy set mirrors config.Default()'s
		// loopback-only posture so callers that construct via NewServer
		// without WithTrustedProxies keep the production nginx-on-
		// loopback behavior (X-Real-IP / X-Forwarded-For honored only
		// when r.RemoteAddr is 127.0.0.0/8 or ::1). WithTrustedProxies
		// replaces this set. Issue #125.
		trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("::1/128")},
		now:            func() time.Time { return time.Now().UTC() },
		version:        "dev",
	}
	for _, opt := range opts {
		opt(s)
	}
	// Initialize sticky.Map AFTER options have applied final
	// stickyTTL/stickyMaxEntries (WithBuyerConfig may override
	// defaults). Always construct it; sticky path callers gate
	// reads/writes on s.stickyEnabled, but Lookup/Update/Purge
	// on a constructed map are no-ops when keys never land.
	s.stickyMap = sticky.NewMap(sticky.Options{
		TTL:        s.stickyTTL,
		MaxEntries: s.stickyMaxEntries,
		Now:        s.now,
	})
	// stickyMismatchLimiter capacity mirrors stickyMap so a hostile
	// gateway cannot grow the limiter map beyond the affinity map's
	// own bound. 1-minute window matches the SPEC-004 §7 operational-
	// hygiene budget for cross-account refresh warns.
	s.stickyMismatchLimiter = newStickyMismatchLimiter(time.Minute, s.stickyMaxEntries)
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
	r.Get("/metrics/streaming", s.handleStreamingMetrics)
	r.Post("/v1/chat/completions", s.handleChatCompletions)
	return r
}

func (s *Server) handleStreamingMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(s.streamingTiming.prometheusText()))
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
	providerID := sanitizeRequestLogText(r.URL.Query().Get("provider_id"))
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
	key := s.poolCheckClientKey(r)
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
	key := s.poolCheckClientKey(r)
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
// When r.RemoteAddr falls inside the configured trusted-proxy CIDR
// set (`proxy.trusted_proxies`; default `["127.0.0.0/8", "::1/128"]`
// covers the production nginx-on-localhost topology) the helper
// honors the forwarded-for chain:
//
//  1. `X-Forwarded-For`: rightmost-untrusted hop — the closest IP in
//     the chain that is NOT itself in the trusted-proxy set. This is
//     the standard "rightmost untrusted" pattern (`MDN
//     X-Forwarded-For`); it survives chained trusted proxies (LB →
//     nginx → coordinator) without admitting a buyer-supplied
//     leftmost IP into the bucket key.
//  2. `X-Real-IP`: nginx's single-hop alias if the operator's nginx
//     site sets it (`proxy_set_header X-Real-IP $remote_addr`) but
//     does NOT set `X-Forwarded-For`.
//  3. Fallback to r.RemoteAddr (the trusted-proxy's IP) if neither
//     header is usable.
//
// When r.RemoteAddr is OUTSIDE the trusted set, the helper IGNORES
// both forwarded headers entirely and returns r.RemoteAddr's IP. An
// attacker on the open internet cannot spoof their bucket key by
// sending `X-Forwarded-For` / `X-Real-IP` themselves; only operators
// who explicitly trust a proxy CIDR opt their setup into header-
// based keying.
//
// Issue #125. Mirrors ws.remoteIPForUnauthSemaphore in shape (which
// still implements the narrower loopback-only X-Real-IP path; that
// path is deliberately not unified into this helper because the WS
// admission semaphore lives in a different package and its surface
// is intentionally minimal — a future PR may converge both onto a
// shared `httpip` helper).
func (s *Server) poolCheckClientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		host = r.RemoteAddr
	}
	hostAddr, parseErr := netip.ParseAddr(host)
	if parseErr != nil {
		// Unparseable r.RemoteAddr — never trust the forwarded headers
		// in this case; return whatever we have so the bucket key is
		// at least deterministic per malformed peer.
		if host == "" {
			return r.RemoteAddr
		}
		return host
	}
	if !isTrustedProxy(hostAddr, s.trustedProxies) {
		// Direct (untrusted) connection — IGNORE X-Forwarded-For /
		// X-Real-IP, key on the actual peer.
		return host
	}
	// Trusted proxy. Walk X-Forwarded-For right-to-left for the first
	// non-trusted hop; that is the buyer-visible IP we want to key on.
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if client := rightmostUntrustedXFF(xff, s.trustedProxies); client != "" {
			return client
		}
	}
	// X-Real-IP: parse via netip.ParseAddr to canonicalize and reject
	// junk (issue #125 security-lane L1). nginx's standard
	// `proxy_set_header X-Real-IP $remote_addr` produces a bare IP
	// without port, so a port-bearing value is treated as malformed
	// and falls through. An attacker who sneaks a non-IP value past a
	// trusted proxy cannot poison the bucket key — we use the canonical
	// addr.String() form instead.
	if realIP := strings.TrimSpace(r.Header.Get("X-Real-IP")); realIP != "" {
		if addr, err := netip.ParseAddr(realIP); err == nil {
			return addr.String()
		}
	}
	return host
}

// isLoopbackHost is retained for legacy callers that may still consult
// it directly. Issue #125 routes the rate-limit key derivation through
// the configured trusted-proxy CIDR set instead, but the helper stays
// for any non-rate-limit callsite that wants a quick loopback check.
func isLoopbackHost(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}

// isTrustedProxy reports whether addr falls inside any of the
// configured trusted-proxy prefixes. Pure function — both
// poolCheckClientKey and rightmostUntrustedXFF call it so the
// prefix-membership check is in exactly one place (architect-lane
// follow-up to issue #125). A nil/empty trusted slice returns false
// — strictest possible posture (no proxy is trusted; always key on
// r.RemoteAddr).
func isTrustedProxy(addr netip.Addr, trusted []netip.Prefix) bool {
	for _, p := range trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// rightmostUntrustedXFF walks X-Forwarded-For from RIGHT to LEFT
// (last hop nearest the coordinator → first hop nearest the buyer)
// and returns the first entry whose IP is NOT in the trusted-proxy
// set. That entry is the buyer-visible IP — survives chained trusted
// proxies (LB → nginx → coordinator) without admitting a buyer-
// supplied leftmost IP.
//
// Behavior:
//   - Returns "" on empty header / unparseable hops / all-hops-trusted
//     (the caller's fallback path then runs).
//   - Each hop is trimmed; brackets stripped if present
//     ([2001:db8::1]:443 → 2001:db8::1).
//   - Hops with attached :port are split via net.SplitHostPort before
//     the prefix check; bare IPs (no port) keep their literal value;
//     either way the final IP is parsed via netip.ParseAddr.
//
// MDN: "Take care when leftmost values are user-controlled. Use the
// rightmost-untrusted entry instead." We do exactly that.
func rightmostUntrustedXFF(header string, trusted []netip.Prefix) string {
	hops := strings.Split(header, ",")
	for i := len(hops) - 1; i >= 0; i-- {
		raw := strings.TrimSpace(hops[i])
		if raw == "" {
			continue
		}
		// Strip optional [v6]:port or v4:port suffix.
		host := raw
		if h, _, err := net.SplitHostPort(raw); err == nil {
			host = h
		}
		// Strip lone IPv6 brackets if no port was present.
		host = strings.Trim(host, "[]")
		addr, err := netip.ParseAddr(host)
		if err != nil {
			continue
		}
		if !isTrustedProxy(addr, trusted) {
			return addr.String()
		}
	}
	return ""
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
	for name, class := range s.snapshotModelClasses() {
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

type requestToolCall struct {
	ID        string
	Name      string
	Arguments string
	MsgIndex  int
}

func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	externalRequestID := sanitizeExternalRequestID(r.Header.Get("X-Request-ID"))
	// SPEC-002 v1.5.0 / issue #211: gateway-forwarded account id.
	// Persisted into request_log.account_id so reconciliation can use
	// the composite (account_id, external_request_id) key (composite-PK
	// addendum from #196). Empty for direct legacy buyer calls and for
	// pre-SPEC-006 v0.9.1 gateways that only emit this header on the
	// sticky path.
	accountID := sanitizeAccountID(r.Header.Get("X-MacProvider-Account"))
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
		// Snapshot the UTC daily-key bucket from startedAt (NOT a
		// second s.now() call) so the request-start timestamp and the
		// routing-seed bucket agree on the exact UTC-midnight boundary.
		// Without this, a long-running retry that crosses UTC midnight
		// produces a different seed than the first attempt, breaking
		// FR-SR-17 reproducibility for the request. Issue #266 T1,
		// R1 ARCHITECT audit LOW fix (atomic snapshot).
		dailyKey: startedAt.UTC().Format("2006-01-02"),
		// estimatedTokens is populated below once the body is read +
		// validated; retry-path PreflightResult derivation reads it.
	}
	// M3-10 (ARCH-6 close-out): the previously-inline logRowWithBilling
	// closure now lives as *billingRecorder. setModel / setStream /
	// setRequestID land before the first provider-bound recordRow call,
	// preserving the pre-refactor closure's "latest value at fire time"
	// semantics for what used to be captured outer-scope variables.
	rec := s.newBillingRecorder(r, state, startedAt, originalRequestID, externalRequestID, accountID)
	if !contentEncodingSupported(r.Header.Values("Content-Encoding")) {
		msg := "v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding` header; compressed request bodies are deferred to v0.2 per §10."
		rec.logBuyerFailure(http.StatusUnsupportedMediaType, msg)
		writeErrorWithParam(w, http.StatusUnsupportedMediaType, "request_content_encoding_unsupported", msg, "Content-Encoding")
		return
	}
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
		writeError(w, http.StatusRequestEntityTooLarge, "request_body_too_large", "Request body too large")
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
	// Snapshot prompt-token estimate so retry-path logRoutingDecisionRetry
	// can derive PreflightResult ("accepted" vs "not_applicable") without
	// re-tokenising req.raw on each advance. Issue #266 T1 R1 audit
	// MEDIUM fix.
	state.estimatedTokens = estimateTokens(req.raw)
	provider, routeErr := s.selectProvider(routingRequestID, req, r.Header, state.dailyKey)
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
	excluded[state.provider.SortKey()] = struct{}{}
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
	// M2-1e (issue #94): thin wrapper that builds streaming callbacks
	// and delegates the decision tree to forwardWithFailover. Audit-
	// flagged INTENTIONAL invariants preserved inside the callbacks:
	//   - Streaming `failoverEligible` carries `retryable=true` (per
	//     classifyStreamResult); onFailoverMiss returns handled=false
	//     so the core falls through to shouldRetry — the audit-cited
	//     intentional divergence vs WS-non-streaming's fast-fail.
	//   - committed early-exit (renderCommitted): post-first-chunk
	//     disconnect / cancelled get final-OK semantics with
	//     stream_terminal logging (WS-tunneled disconnect only).
	//   - logRoutingDecisionRetry fires after every successful advance
	//     across ALL three transports (streaming + HTTP + WS-non-
	//     streaming) per issue #266 T1 — the pre-#266 asymmetry where
	//     WS-non-streaming skipped the emission was the SPEC-004 §7
	//     audit-explainability gap closed in this PR.
	cbs := transportCallbacks{
		dispatch: func(w http.ResponseWriter, r *http.Request, req chatRequest, requestID, _ string, _ time.Time, state *forwardState, rec *billingRecorder) (dispatchedAttempt, bool) {
			dispatchBody, err := dispatchBodyForProvider(req, state.provider)
			if err != nil {
				rec.logRow(state.provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return dispatchedAttempt{}, false
			}
			wsTunneled := state.provider.IsWSTunneled()
			var tr transportResult
			var nativeResult wsForwardResult
			if wsTunneled {
				result, attempt := s.forwardWS(w, r, requestID, dispatchBody, state.provider, true, s.attemptTimeout(r))
				tr = classifyStreamResult(result, statusForForwardResult(result), attempt)
				nativeResult = result
			} else {
				result, status, attempt := s.forwardStreaming(w, r, requestID, dispatchBody, state.provider, req.Model, s.attemptTimeout(r))
				tr = classifyStreamResult(result, status, attempt)
				nativeResult = result
			}
			// Pre-refactor streaming gated the failoverCandidate
			// same-attempt re-route on `tr.failoverEligible && wsTunneled`
			// (server.go:1337). The classifier sets failoverEligible for
			// every pre-first-chunk disconnect regardless of transport,
			// but only the WS-tunneled streaming case actually invokes
			// failoverCandidate — HTTP-streaming pre-chunk disconnect
			// goes through normal shouldRetry+advance (which bumps
			// retried; pinned by forward_loop_test TestM92_RowSequence_*).
			// Clear the flag here so the core's failover branch fires
			// only for the WS-tunneled streaming case, matching pre-1e.
			if !wsTunneled {
				tr.failoverEligible = false
			}
			return dispatchedAttempt{
				tr:           tr,
				nativeResult: nativeResult,
				success:      nativeResult == wsForwardComplete,
			}, true
		},
		renderCommitted: func(_ http.ResponseWriter, _ *http.Request, dispatched dispatchedAttempt, state *forwardState) bool {
			tr := dispatched.tr
			if tr.cancelled {
				if shouldLogAttempt(tr.attempt) {
					logAttempt(state.provider, http.StatusOK, tr.attempt, state.explicitRetries)
				}
			} else {
				logAttempt(state.provider, http.StatusOK, tr.attempt, state.explicitRetries)
				if state.provider.IsWSTunneled() && dispatched.nativeResult == wsForwardProviderDisconnectedCommitted {
					s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "stream_terminal", "")
				}
			}
			return true
		},
		renderSuccess: func(_ http.ResponseWriter, r *http.Request, req chatRequest, dispatched dispatchedAttempt, state *forwardState) {
			logAttempt(state.provider, http.StatusOK, dispatched.tr.attempt, state.explicitRetries)
			if state.provider.IsWSTunneled() {
				s.stickyStore(r.Header, state.provider, req.Model)
			}
		},
		onFailoverHit: func(_, _ string, _ dispatchedAttempt, state *forwardState, next pool.Provider) {
			// Streaming gates failoverEligible on wsTunneled at the
			// dispatch callback (see the `if !wsTunneled {
			// tr.failoverEligible = false }` clear in this file's
			// streaming dispatch). The classifier itself sets
			// failoverEligible=true for every pre-first-chunk
			// disconnect regardless of transport (classifyStreamResult
			// at transport_result.go:154); the streaming dispatch
			// callback clears it for non-WS so the core's failover
			// branch — and therefore this hit hook — only fires for
			// WS-tunneled streaming, matching pre-refactor
			// `if tr.failoverEligible && wsTunneled` at server.go:1337.
			s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "failover", next.ProviderID)
		},
		onFailoverMiss: func(_ http.ResponseWriter, _ *http.Request, _ dispatchedAttempt, state *forwardState) bool {
			// Streaming intentional divergence: failoverEligible carries
			// retryable=true. A miss must fall THROUGH to shouldRetry —
			// return handled=false to let the core's retry-budget gate
			// evaluate. The fast_fail event is still logged here so the
			// downstream observability tracks the same shape as
			// pre-refactor server.go:1347.
			s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "fast_fail", "")
			return false
		},
		renderRetryExhausted: func(w http.ResponseWriter, dispatched dispatchedAttempt, state *forwardState) {
			// Curated attempt.Error: classifyStreamResult populated
			// dispatched.tr.attempt with the curated error string;
			// logAttempt reads from tr.attempt — never from a raw err
			// mirror. Carry-forward from PR #61 security audit.
			logAttempt(state.provider, dispatched.tr.status, dispatched.tr.attempt, state.explicitRetries)
			writeStreamForwardError(w, dispatched.nativeResult)
		},
		logRetryAttempt: func(dispatched dispatchedAttempt, state *forwardState) {
			logAttempt(state.provider, dispatched.tr.status, dispatched.tr.attempt, state.explicitRetries)
		},
		afterAdvance: func(state *forwardState, nextRouteID string) bool {
			s.logRoutingDecisionRetry(
				nextRouteID,
				[]pool.Provider{state.provider},
				"retry",
				state.provider.ProviderID,
				"retry_"+itoa(state.explicitRetries),
				retryDecisionAttrs{
					AttemptIndex:    state.explicitRetries + 1,
					RetryCount:      state.explicitRetries,
					Retried:         state.explicitRetries,
					RetryReason:     "streaming_advance",
					PreflightResult: s.preflightLabel(state.estimatedTokens),
				},
			)
			return false
		},
	}
	s.forwardWithFailover(w, r, req, requestID, originalRequestID, startedAt, state, excluded, rec, cbs)
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
	// M2-1e (issue #94): now a thin wrapper that builds per-transport
	// callbacks and delegates the decision tree to forwardWithFailover.
	// Audit-flagged INTENTIONAL invariants preserved inside the
	// callbacks:
	//   - failoverEligible carries retryable=false (per classifyWSResult);
	//     onFailoverMiss returns handled=true to fast-fail with 502 rather
	//     than fall through to shouldRetry — the audit-cited intentional
	//     divergence vs streaming.
	//   - Cancelled / Failed / Unavailable short-circuit via
	//     handleNonRetryableTerminal — no advance, no failover.
	//   - Queue-full (wsForwardQueueFull): markBusy fires in the shared
	//     core; the retry-budget gate is bypassed via skipRetryBudgetCheck
	//     to preserve the M2-1d "always advance on queue-full" behaviour
	//     pinned by forward_loop_test scenario
	//     TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance.
	//   - afterAdvance / afterFailoverHit return true when the new
	//     provider is not WS so the caller falls through to the HTTP loop
	//     on state.provider.
	cbs := transportCallbacks{
		dispatch: func(w http.ResponseWriter, r *http.Request, req chatRequest, requestID, _ string, _ time.Time, state *forwardState, rec *billingRecorder) (dispatchedAttempt, bool) {
			dispatchBody, err := dispatchBodyForProvider(req, state.provider)
			if err != nil {
				rec.logRow(state.provider.AssignedID, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return dispatchedAttempt{}, false
			}
			result, attempt := s.forwardWS(w, r, requestID, dispatchBody, state.provider, false, s.attemptTimeout(r))
			tr := classifyWSResult(result, attempt)
			return dispatchedAttempt{
				tr:           tr,
				nativeResult: result,
				success:      result == wsForwardComplete,
			}, true
		},
		handleNonRetryableTerminal: func(_ http.ResponseWriter, dispatched dispatchedAttempt, state *forwardState) bool {
			result := dispatched.nativeResult
			if result == wsForwardFailed || result == wsForwardUnavailable || result == wsForwardCancelled {
				if result != wsForwardCancelled || shouldLogAttempt(dispatched.tr.attempt) {
					logAttempt(state.provider, statusForForwardResult(result), dispatched.tr.attempt, state.explicitRetries)
				}
				return true
			}
			return false
		},
		renderSuccess: func(_ http.ResponseWriter, r *http.Request, req chatRequest, dispatched dispatchedAttempt, state *forwardState) {
			logAttempt(state.provider, http.StatusOK, dispatched.tr.attempt, state.explicitRetries)
			s.stickyStore(r.Header, state.provider, req.Model)
		},
		onFailoverHit: func(_, _ string, dispatched dispatchedAttempt, state *forwardState, next pool.Provider) {
			s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "failover", next.ProviderID)
			logAttempt(state.provider, http.StatusBadGateway, dispatched.tr.attempt, state.explicitRetries)
		},
		afterFailoverHit: func(state *forwardState) bool {
			return !state.provider.IsWSTunneled()
		},
		onFailoverMiss: func(w http.ResponseWriter, _ *http.Request, dispatched dispatchedAttempt, state *forwardState) bool {
			// Intentional divergence vs streaming: WS-non-streaming
			// failoverEligible carries retryable=false, so a miss MUST
			// fast-fail with 502 — NOT fall through to shouldRetry.
			s.logWSDeadMidRequest(originalRequestID, requestID, externalRequestID, state.provider, "fast_fail", "")
			logAttempt(state.provider, http.StatusBadGateway, dispatched.tr.attempt, state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_disconnected", "Selected provider disconnected; buyer should retry")
			return true
		},
		skipRetryBudgetCheck: func(dispatched dispatchedAttempt) bool {
			// Queue-full bypasses the retry-budget gate (always advances
			// when a candidate exists). M2-1d-preserved behaviour pinned
			// by forward_loop_test scenario
			// TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance.
			return dispatched.nativeResult == wsForwardQueueFull
		},
		renderRetryExhausted: func(w http.ResponseWriter, dispatched dispatchedAttempt, state *forwardState) {
			// Only the timeout branch reaches this in WS-non-streaming
			// today: failoverEligible's miss path renders + returns
			// inside onFailoverMiss; queue-full skips the gate above;
			// cancelled/failed/unavailable short-circuit before fault
			// mutation. The 504/provider_timeout envelope mirrors the
			// pre-refactor inline branch at server.go:1423-1424.
			logAttempt(state.provider, http.StatusGatewayTimeout, dispatched.tr.attempt, state.explicitRetries)
			writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
		},
		logRetryAttempt: func(dispatched dispatchedAttempt, state *forwardState) {
			// Timeout: classifier-mapped status (504). Queue-full: 502.
			// Matches pre-refactor pattern (timeout at server.go:1427,
			// queue-full at :1487).
			status := http.StatusGatewayTimeout
			if dispatched.nativeResult == wsForwardQueueFull {
				status = http.StatusBadGateway
			}
			logAttempt(state.provider, status, dispatched.tr.attempt, state.explicitRetries)
		},
		afterAdvance: func(state *forwardState, nextRouteID string) bool {
			// WS-non-streaming-only signal: if advance landed on a non-WS
			// provider, the caller (handleChatCompletions) drives the
			// HTTP loop on state.provider. WS targets continue the loop.
			//
			// Issue #266 T1: WS-non-streaming previously skipped the
			// per-retry routing-decision log emitted by the streaming /
			// HTTP afterAdvance callbacks; emit it here too for parity
			// (FR-SR-17 audit-explainability surface is per-attempt,
			// not per-transport).
			s.logRoutingDecisionRetry(
				nextRouteID,
				[]pool.Provider{state.provider},
				"retry",
				state.provider.ProviderID,
				"retry_"+itoa(state.explicitRetries),
				retryDecisionAttrs{
					AttemptIndex:    state.explicitRetries + 1,
					RetryCount:      state.explicitRetries,
					Retried:         state.explicitRetries,
					RetryReason:     "ws_advance",
					PreflightResult: s.preflightLabel(state.estimatedTokens),
				},
			)
			return !state.provider.IsWSTunneled()
		},
	}
	return s.forwardWithFailover(w, r, req, requestID, originalRequestID, startedAt, state, excluded, rec, cbs)
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
//
// httpDispatchExtra carries the HTTP dispatch's post-classification
// scratch state forward to the renderRetryExhausted / logRetryAttempt
// callbacks (status code, raw err, ErrorCode, retryRequested flag).
// The dispatch callback itself owns ALL the lifecycle plumbing
// (per-attempt context.WithTimeout setup, cancelAttempt cleanup on
// every exit path, 200-success render, receipt-bearing null-usage
// early-return); this struct only carries the post-dispatch
// observables the failure-render callbacks need.
type httpDispatchExtra struct {
	status         int
	err            error
	errorCode      string
	retryRequested bool
}

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
	// M2-1e (issue #94): thin wrapper that builds HTTP-transport
	// callbacks and delegates the decision tree to forwardWithFailover.
	// Audit-flagged INTENTIONAL invariants preserved inside the
	// callbacks:
	//   - HTTP per-attempt context.WithTimeout(...) — set up inside
	//     the dispatch callback when retryRequested && retryPerAttempt-
	//     Timeout > 0; cancelAttempt fires on EVERY exit path
	//     (200-success render, receipt-bearing early-return,
	//     fall-through-to-failure-classify). Never visible at the core
	//     level for other transports.
	//   - handleProviderFailure called on non-200 status — HTTP-only
	//     fault tracking, mirrored from pre-refactor server.go:1620;
	//     WS markBusy semantics live in their own classifier flag.
	//   - Receipt-bearing null-usage early-return (Round-1 audit H1):
	//     when shouldRetry would say stop AND the response has a
	//     null-usage error code AND the provider is receipt-eligible,
	//     render the response body + receipt headers verbatim before
	//     returning. Otherwise fall through to the normal failure
	//     path. Lives inside the dispatch callback so cancelAttempt
	//     lifetime stays correct.
	//   - Custom terminal disambiguation: shouldRetry-miss renders
	//     "provider_timeout" (504) vs "provider_error" (502) based on
	//     status+retryRequested. The renderRetryExhausted callback
	//     reads status/retryRequested from httpDispatchExtra.
	cbs := transportCallbacks{
		dispatch: func(w http.ResponseWriter, r *http.Request, req chatRequest, _, originalRequestID string, startedAt time.Time, state *forwardState, rec *billingRecorder) (dispatchedAttempt, bool) {
			dispatchBody, err := dispatchBodyForProvider(req, state.provider)
			if err != nil {
				rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return dispatchedAttempt{}, false
			}
			upstreamURL := state.provider.EndpointURL + "/v1/chat/completions"
			attemptCtx := r.Context()
			cancelAttempt := func() {}
			retryRequested := s.maxRetries > 0 && routing.RetryHeaderLimit(r.Header.Get("X-MacProvider-Retry")) > 0
			if retryRequested && s.retryPerAttemptTimeout > 0 {
				attemptCtx, cancelAttempt = context.WithTimeout(r.Context(), s.retryPerAttemptTimeout)
			}
			upReq, err := http.NewRequestWithContext(attemptCtx, http.MethodPost, upstreamURL, bytes.NewReader(dispatchBody))
			if err != nil {
				cancelAttempt()
				rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
				writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
				return dispatchedAttempt{}, false
			}
			upReq.Header.Set("Content-Type", "application/json")
			upReq.Header.Set("X-Request-ID", originalRequestID)
			resp, doErr := providerhttp.Client.Do(upReq)
			// 200 success path: render body + receipt headers, log row,
			// cancelAttempt on every exit.
			if doErr == nil && resp != nil && resp.StatusCode == http.StatusOK {
				respBody, readErr := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
				_ = resp.Body.Close()
				if readErr != nil {
					cancelAttempt()
					rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", "", state.explicitRetries)
					writeError(w, http.StatusBadGateway, "provider_failed", "Selected provider failed; buyer should retry")
					return dispatchedAttempt{}, false
				}
				promptTok, completionTok := tokenPointersFromChatResponse(respBody)
				estimatedCompletion := s.observedCompletionTokensFromBytes(len(respBody))
				if err := rec.logProviderRowWithEstimate(state.provider, http.StatusOK, promptTok, completionTok, "", "", state.explicitRetries, estimatedCompletion); err != nil {
					cancelAttempt()
					writeError(w, http.StatusInternalServerError, "request_log_failed", "Could not durably log request")
					return dispatchedAttempt{}, false
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
				// Signal to the core: this attempt was handled in
				// dispatch (we rendered the 200 + logged). Return
				// ok=false so the core just returns.
				return dispatchedAttempt{}, false
			}
			// Non-200 path.
			status := 0
			attempt := requestLogAttempt{}
			var respBody []byte
			if resp != nil {
				status = resp.StatusCode
				respBody, _ = readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
				_ = resp.Body.Close()
				attempt.ErrorCode = nullUsageProviderErrorCode(respBody)
				if isSpec019ProviderDetailCode(attempt.ErrorCode) {
					if err := rec.recordRow(state.provider.AssignedID, state.provider.ProviderID, status, nil, nil, http.StatusText(status), attempt.ErrorCode, state.explicitRetries, nil, billing.FaultBreakerQualifying); err != nil {
						cancelAttempt()
						writeError(w, http.StatusInternalServerError, "request_log_failed", "Could not durably log request")
						return dispatchedAttempt{}, false
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
					return dispatchedAttempt{}, false
				}
				// Receipt-bearing null-usage early-return (Round-1
				// audit H1). Only short-circuit when the retry budget
				// is genuinely exhausted; otherwise fall through so
				// the buyer's explicit retry budget is honored.
				if attempt.ErrorCode != "" && providerReceiptEligible(state.provider) {
					if !s.shouldRetry(r, startedAt, state.explicitRetries, state.faultedProviders, status, nil) {
						if err := rec.logProviderRow(state.provider, status, nil, nil, http.StatusText(status), attempt.ErrorCode, state.explicitRetries); err != nil {
							cancelAttempt()
							writeError(w, http.StatusInternalServerError, "request_log_failed", "Could not durably log request")
							return dispatchedAttempt{}, false
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
						return dispatchedAttempt{}, false
					}
				}
			}
			cancelAttempt()
			tr := classifyHTTPResult(resp, doErr, attempt)
			s.log.Warn().Err(doErr).Int("status", status).Str("request_id", requestID).Str("provider_id", state.provider.ProviderID).Msg("provider request failed")
			if status != 0 {
				s.handleProviderFailure(state.provider, status)
			}
			return dispatchedAttempt{
				tr:           tr,
				nativeResult: "",
				success:      false,
				extra: httpDispatchExtra{
					status:         status,
					err:            doErr,
					errorCode:      attempt.ErrorCode,
					retryRequested: retryRequested,
				},
			}, true
		},
		// HTTP never reaches the success branch via the core — the
		// dispatch callback handles 200 inline (writes body + returns
		// ok=false). The core's success branch is unused for HTTP, but
		// the callback is required by the struct shape, so we provide
		// a no-op (never invoked because dispatch returns success=false
		// for the non-200 path it falls through with).
		renderSuccess: func(http.ResponseWriter, *http.Request, chatRequest, dispatchedAttempt, *forwardState) {},
		renderRetryExhausted: func(w http.ResponseWriter, dispatched dispatchedAttempt, state *forwardState) {
			extra := dispatched.extra.(httpDispatchExtra)
			// HTTP-specific terminal disambiguation: provider_timeout
			// (504) when retryRequested and the upstream actually
			// returned 504, otherwise provider_error (502). Mirrors
			// pre-refactor server.go:1645-1652.
			if extra.retryRequested && extra.status == http.StatusGatewayTimeout {
				rec.logProviderRow(state.provider, http.StatusGatewayTimeout, nil, nil, "Selected provider timed out; buyer should retry", extra.errorCode, state.explicitRetries)
				writeError(w, http.StatusGatewayTimeout, "provider_timeout", "Selected provider timed out; buyer should retry")
				return
			}
			rec.logProviderRow(state.provider, http.StatusBadGateway, nil, nil, "Selected provider failed; buyer should retry", extra.errorCode, state.explicitRetries)
			writeError(w, http.StatusBadGateway, "provider_error", "Selected provider failed; buyer should retry")
		},
		logRetryAttempt: func(dispatched dispatchedAttempt, state *forwardState) {
			extra := dispatched.extra.(httpDispatchExtra)
			// failStatus = tr.status (already encodes the nil-response
			// → 502 normalisation per classifyHTTPResult). Mirrors
			// pre-refactor server.go:1659.
			errMsg := "Selected provider failed; buyer should retry"
			if extra.err != nil {
				errMsg = extra.err.Error()
			}
			rec.logProviderRow(state.provider, dispatched.tr.status, nil, nil, errMsg, extra.errorCode, state.explicitRetries)
		},
		afterAdvance: func(state *forwardState, nextRouteID string) bool {
			s.logRoutingDecisionRetry(
				nextRouteID,
				[]pool.Provider{state.provider},
				"retry",
				state.provider.ProviderID,
				"retry_"+itoa(state.explicitRetries),
				retryDecisionAttrs{
					AttemptIndex:    state.explicitRetries + 1,
					RetryCount:      state.explicitRetries,
					Retried:         state.explicitRetries,
					RetryReason:     "http_advance",
					PreflightResult: s.preflightLabel(state.estimatedTokens),
				},
			)
			return false
		},
	}
	s.forwardWithFailover(w, r, req, requestID, originalRequestID, startedAt, state, excluded, rec, cbs)
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
	picked, routeErr := s.selectProviderExcluding(nextRouteID, req, r.Header, excluded, state.dailyKey)
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
	if s.maxRetries > 0 && routing.RetryHeaderLimit(r.Header.Get("X-MacProvider-Retry")) > 0 && s.retryPerAttemptTimeout > 0 {
		return s.retryPerAttemptTimeout
	}
	return s.requestTimeout
}

func (s *Server) forwardWS(w http.ResponseWriter, r *http.Request, requestID string, body []byte, provider pool.Provider, stream bool, timeout time.Duration) (wsForwardResult, requestLogAttempt) {
	if s.relay == nil {
		writeError(w, http.StatusServiceUnavailable, "no_provider_available", "Selected provider is not reachable")
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
			writeError(w, http.StatusServiceUnavailable, "no_provider_available", "Selected provider is not reachable")
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
				attempt := requestLogAttempt{Status: status, Error: endErrorMessage(end), ErrorCode: spec001EndStatus(end.Status)}
				if isSpec019ProviderDetailCode(attempt.ErrorCode) {
					attempt.FaultFlag = billing.FaultBreakerQualifying
				}
				return wsForwardFailed, attempt
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
				writeError(w, http.StatusServiceUnavailable, "no_provider_available", "Selected provider is not reachable")
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
	toolFinal := newStreamToolCallFinalValidator()
	streamingMode := s.streamingMode(r, provider)
	streamingBuyer := s.streamingBuyerKey(r)
	progressAttempt := func(message string, faultFlag string) requestLogAttempt {
		return requestLogAttempt{Status: http.StatusOK, Error: message, EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(bytesEmitted), FaultFlag: faultFlag}
	}
	if streamingMode != streamingModeIncremental {
		return s.forwardWSStreamingBuffered(w, r, requestID, provider, relay, streamingMode, streamingBuyer)
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
		w.Header().Set(streamingModeHeader, streamingMode)
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
		if err := toolFinal.observeBlock(checked); err != nil {
			relay.Cancel("malformed_tool_call_stream")
			if s.streamingDowngrade != nil {
				s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
			}
			commit()
			writeSSEError(w, "Provider emitted malformed tool-call stream", "malformed_tool_call")
			if flusher != nil {
				flusher.Flush()
			}
			return true, wsForwardFailed
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
			if end.Status == "complete" && !toolFinal.finalCloseOK() {
				writeSSEError(w, "Provider closed before tool-call stream completed", "tool_call_final_close_failed")
				if s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				attempt.Error = "Provider closed before tool-call stream completed"
				attempt.ErrorCode = "tool_call_final_close_failed"
				attempt.FaultFlag = billing.FaultBreakerQualifying
				if attempt.CompletionTokens == nil {
					attempt.EstimatedCompTokens = s.estimatedCompletionTokensFromBytes(bytesEmitted)
				}
			}
			if end.Status != "complete" && end.Status != "cancelled" {
				if isSpec019ProviderDetailCode(end.Status) {
					writeSSEError(w, endErrorMessage(end), end.Status, requestID)
				} else {
					writeSSEError(w, "Provider failed during streaming", "provider_error")
				}
				if toolFinal.toolOpened && s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
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
			if end.Status == "complete" && attempt.FaultFlag == "" && s.streamingDowngrade != nil {
				s.streamingDowngrade.recordClean(streamingBuyer, provider.ProviderID, s.now())
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
				writeSSEError(w, "Provider timed out during streaming", "provider_timeout", requestID)
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

func (s *Server) forwardWSStreamingBuffered(w http.ResponseWriter, r *http.Request, requestID string, provider pool.Provider, relay *providerws.RelayStream, streamingMode, streamingBuyer string) (wsForwardResult, requestLogAttempt) {
	guard := tier2.NewPillarDGuard(s.tier2Config(), requestID, provider, s.log)
	var raw bytes.Buffer
	toolFinal := newStreamToolCallFinalValidator()
	for {
		select {
		case <-r.Context().Done():
			relay.Cancel("buyer_disconnected")
			return wsForwardCancelled, requestLogAttempt{Status: http.StatusOK, Error: "Buyer disconnected during buffered streaming", FaultFlag: billing.FaultNone}
		case chunk, ok := <-relay.Chunks:
			if !ok {
				continue
			}
			checked, stop, err := guard.CheckStreamingChunk(chunk.Data)
			if err != nil {
				relay.Cancel("tier2_encoding_invalid")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider returned invalid Tier2 output encoding", FaultFlag: billing.FaultBreakerQualifying}
			}
			if raw.Len() > int(maxUpstreamResponseBodyBytes)-len(checked) {
				relay.Cancel("buffered_stream_too_large")
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider buffered stream exceeded cap", FaultFlag: billing.FaultBreakerQualifying}
			}
			raw.WriteString(checked)
			if err := toolFinal.observeBlock(checked); err != nil {
				relay.Cancel("malformed_tool_call_stream")
				if s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider emitted malformed buffered tool-call stream", ErrorCode: "provider_stream_downgraded", FaultFlag: billing.FaultBreakerQualifying}
			}
			if stop {
				relay.Cancel("tier2_output_truncated")
				return wsForwardComplete, requestLogAttempt{Status: http.StatusOK, EstimatedCompTokens: s.estimatedCompletionTokensFromBytes(raw.Len())}
			}
		case end := <-relay.Done:
			if end.Status != "complete" {
				if toolFinal.toolOpened && s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				return wsForwardFailed, requestLogAttempt{Status: wsEndHTTPStatus(end.Status), Error: endErrorMessage(end), ErrorCode: spec001EndStatus(end.Status), FaultFlag: billing.FaultBreakerQualifying}
			}
			if !toolFinal.finalCloseOK() {
				if s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider closed before tool-call stream completed", ErrorCode: "tool_call_final_close_failed", FaultFlag: billing.FaultBreakerQualifying}
			}
			out, err := consolidatedToolCallSSE(raw.Bytes())
			if err != nil {
				if s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider emitted malformed buffered tool-call stream", ErrorCode: "provider_stream_downgraded", FaultFlag: billing.FaultBreakerQualifying}
			}
			w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
			w.Header().Set("X-Accel-Buffering", "no")
			w.Header().Set("Cache-Control", "no-cache")
			w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
			w.Header().Set("X-MacProvider-Route", provider.AssignedID)
			w.Header().Set(streamingModeHeader, streamingMode)
			w.WriteHeader(http.StatusOK)
			if _, err := w.Write(out); err != nil {
				relay.Cancel("buyer_disconnected")
				return wsForwardCancelled, requestLogAttempt{Status: http.StatusOK, Error: "Buyer disconnected during buffered streaming", FaultFlag: billing.FaultNone}
			}
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			if s.streamingDowngrade != nil {
				s.streamingDowngrade.recordClean(streamingBuyer, provider.ProviderID, s.now())
			}
			attempt := requestLogAttempt{Status: http.StatusOK, EstimatedCompTokens: s.observedCompletionTokensFromBytes(len(out))}
			attempt.PromptTokens, attempt.CompletionTokens = tokenPointersFromUsageObject(end.Usage)
			return wsForwardComplete, attempt
		case err := <-relay.Errors:
			s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("ws buffered streaming relay failed")
			if toolFinal.toolOpened && s.streamingDowngrade != nil {
				s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
			}
			return wsForwardFailed, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider failed during buffered streaming", FaultFlag: billing.FaultBreakerQualifying}
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
	streamingMode := s.streamingMode(r, provider)
	streamingBuyer := s.streamingBuyerKey(r)
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
	if streamingMode != streamingModeIncremental {
		return s.forwardStreamingBuffered(w, r, requestID, resp, provider, modelScope, streamingMode, streamingBuyer)
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
	toolFinal := newStreamToolCallFinalValidator()
	var preCommit bytes.Buffer
	var lineBuf bytes.Buffer
	sawCommitWorthyDataLine := false
	flusher, _ := w.(http.Flusher)
	var promptTok, completionTok *int64
	bytesEmitted := 0
	terminalSSEErrorCode := ""
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
		w.Header().Set(streamingModeHeader, streamingMode)
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
	var providerToolCallOpen time.Time
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
			if providerToolCallOpen.IsZero() {
				if openedAt, ok := toolCallOpenFromSSELine(line); ok {
					providerToolCallOpen = openedAt
				}
			}
			if code := terminalSSEErrorCodeFromLine(line); isSpec019TerminalSSEErrorCode(code) {
				terminalSSEErrorCode = code
				sawCommitWorthyDataLine = true
			}
			status := inspectCommitWorthyDataLine(line)
			if status == commitLineMalformedToolCalls {
				s.log.Warn().Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider emitted malformed pre-commit tool_calls delta")
				return errPreCommitMalformedToolCalls
			}
			if err := toolFinal.observeLine(line); err != nil {
				s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider emitted invalid pre-commit tool_calls stream")
				return errPreCommitMalformedToolCalls
			}
			preCommit.Write(line)
			lineBuf.Reset()
			if isSSEBlankLine(line) {
				if sawCommitWorthyDataLine {
					return nil // commit
				}
				continue
			}
			if status == commitLineWorthy {
				sawCommitWorthyDataLine = true
			}
		}
	}()
	if preCommitErr != nil {
		if errors.Is(preCommitErr, errPreCommitCapExceeded) {
			s.handleProviderFailure(provider, http.StatusBadGateway)
			return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider exceeded pre-commit buffer without commit-worthy event", FaultFlag: billing.FaultBreakerQualifying}
		}
		if errors.Is(preCommitErr, errPreCommitMalformedToolCalls) {
			s.handleProviderFailure(provider, http.StatusBadGateway)
			return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider emitted malformed pre-commit tool_calls delta", FaultFlag: billing.FaultBreakerQualifying}
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
	firstForwardedAt := s.now()
	if _, writeErr := w.Write(preCommit.Bytes()); writeErr != nil {
		s.log.Warn().Err(writeErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buyer pre-commit write failed")
		return wsForwardCancelled, 0, progressAttempt("Buyer disconnected during streaming", billing.FaultNone)
	}
	if s.streamingTiming != nil {
		timingHeaders := resp.Header.Clone()
		timingHeaders.Set(streamingTimingCoordinatorHeader, strconv.FormatInt(firstForwardedAt.UnixMilli(), 10))
		copyTimingHeader(timingHeaders, r.Header, streamingTimingGatewayByteHeader)
		copyTimingHeader(timingHeaders, r.Header, streamingTimingSkewHeader)
		s.streamingTiming.observeFromHeadersAndProviderOpen(requestID, provider.ProviderID, streamingMode, timingHeaders, firstForwardedAt, providerToolCallOpen)
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
			if code := terminalSSEErrorCodeFromLine(line); isSpec019TerminalSSEErrorCode(code) {
				terminalSSEErrorCode = code
			}
			if observeErr := toolFinal.observeLine(line); observeErr != nil {
				s.log.Warn().Err(observeErr).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider failed tool-call final-close validation")
				if s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				writeSSEError(w, "Provider emitted malformed tool-call stream", "malformed_tool_call")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardProviderDisconnectedCommitted, http.StatusOK, progressAttempt("Provider emitted malformed tool-call stream", billing.FaultBreakerQualifying)
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
			if terminalSSEErrorCode != "" {
				attempt := progressAttempt("Provider emitted terminal structured-output streaming error", billing.FaultBreakerQualifying)
				attempt.ErrorCode = terminalSSEErrorCode
				return wsForwardComplete, http.StatusOK, attempt
			}
			if !toolFinal.finalCloseOK() {
				s.log.Warn().Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("streaming provider closed before tool-call final-close conditions")
				if s.streamingDowngrade != nil {
					s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
				}
				writeSSEError(w, "Provider closed before tool-call stream completed", "tool_call_final_close_failed")
				if flusher != nil {
					flusher.Flush()
				}
				return wsForwardProviderDisconnectedCommitted, http.StatusOK, progressAttempt("Provider closed before tool-call stream completed", billing.FaultBreakerQualifying)
			}
			if s.streamingDowngrade != nil {
				s.streamingDowngrade.recordClean(streamingBuyer, provider.ProviderID, s.now())
			}
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

func (s *Server) forwardStreamingBuffered(w http.ResponseWriter, r *http.Request, requestID string, resp *http.Response, provider pool.Provider, modelScope, streamingMode, streamingBuyer string) (wsForwardResult, int, requestLogAttempt) {
	raw, err := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
	if err != nil {
		s.log.Warn().Err(err).Str("request_id", requestID).Str("provider_id", provider.ProviderID).Msg("buffered streaming provider body read failed")
		s.handleProviderFailure(provider, http.StatusBadGateway)
		return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider buffered stream failed", FaultFlag: billing.FaultBreakerQualifying}
	}
	validator := newStreamToolCallFinalValidator()
	if err := validator.observeBlock(string(raw)); err != nil || !validator.finalCloseOK() {
		if s.streamingDowngrade != nil {
			s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
		}
		return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider emitted malformed buffered tool-call stream", ErrorCode: "provider_stream_downgraded", FaultFlag: billing.FaultBreakerQualifying}
	}
	out, err := consolidatedToolCallSSE(raw)
	if err != nil {
		if s.streamingDowngrade != nil {
			s.streamingDowngrade.recordMalformed(streamingBuyer, provider.ProviderID, s.now())
		}
		return wsForwardProviderDisconnected, http.StatusBadGateway, requestLogAttempt{Status: http.StatusBadGateway, Error: "Provider emitted malformed buffered tool-call stream", ErrorCode: "provider_stream_downgraded", FaultFlag: billing.FaultBreakerQualifying}
	}
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-MacProvider-Provider", provider.ProviderID)
	w.Header().Set("X-MacProvider-Route", provider.AssignedID)
	w.Header().Set(streamingModeHeader, streamingMode)
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(out); err != nil {
		return wsForwardCancelled, 0, requestLogAttempt{Status: http.StatusOK, Error: "Buyer disconnected during buffered streaming", FaultFlag: billing.FaultNone}
	}
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
	if s.streamingDowngrade != nil {
		s.streamingDowngrade.recordClean(streamingBuyer, provider.ProviderID, s.now())
	}
	s.stickyStore(r.Header, provider, modelScope)
	return wsForwardComplete, http.StatusOK, requestLogAttempt{Status: http.StatusOK, EstimatedCompTokens: s.observedCompletionTokensFromBytes(len(out))}
}

type bufferedToolCall struct {
	Index     int
	ID        string
	Type      string
	Name      string
	Arguments string
}

func consolidatedToolCallSSE(raw []byte) ([]byte, error) {
	calls, err := collectStreamingToolCalls(raw)
	if err != nil {
		return nil, err
	}
	if len(calls) == 0 {
		return raw, nil
	}
	toolCalls := make([]map[string]any, 0, len(calls))
	for _, call := range calls {
		toolCalls = append(toolCalls, map[string]any{
			"index": call.Index,
			"id":    call.ID,
			"type":  call.Type,
			"function": map[string]any{
				"name":      call.Name,
				"arguments": call.Arguments,
			},
		})
	}
	chunk := map[string]any{"choices": []map[string]any{{
		"delta":         map[string]any{"tool_calls": toolCalls},
		"finish_reason": nil,
	}}}
	finish := map[string]any{"choices": []map[string]any{{
		"delta":         map[string]any{},
		"finish_reason": "tool_calls",
	}}}
	var out bytes.Buffer
	for _, event := range []map[string]any{chunk, finish} {
		data, err := json.Marshal(event)
		if err != nil {
			return nil, err
		}
		out.WriteString("data: ")
		out.Write(data)
		out.WriteString("\n\n")
	}
	out.WriteString("data: [DONE]\n\n")
	return out.Bytes(), nil
}

func collectStreamingToolCalls(raw []byte) ([]bufferedToolCall, error) {
	byIndex := map[int]*bufferedToolCall{}
	var order []int
	finished := false
	done := false
	for _, line := range bytes.Split(raw, []byte("\n")) {
		trimmed := bytes.TrimSpace(line)
		if !bytes.HasPrefix(trimmed, []byte("data:")) {
			continue
		}
		payload := bytes.TrimSpace(trimmed[len("data:"):])
		if len(payload) == 0 {
			continue
		}
		if bytes.Equal(payload, []byte("[DONE]")) {
			done = true
			continue
		}
		var event struct {
			Error   any `json:"error"`
			Choices []struct {
				Delta struct {
					ToolCalls []struct {
						Index    *int   `json:"index"`
						ID       string `json:"id"`
						Type     string `json:"type"`
						Function struct {
							Name      string  `json:"name"`
							Arguments *string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
				FinishReason *string `json:"finish_reason"`
			} `json:"choices"`
		}
		if err := json.Unmarshal(payload, &event); err != nil {
			return nil, err
		}
		if event.Error != nil {
			return nil, errors.New("terminal error in provider stream")
		}
		for _, choice := range event.Choices {
			if choice.FinishReason != nil && *choice.FinishReason == "tool_calls" {
				finished = true
			}
			for _, delta := range choice.Delta.ToolCalls {
				if delta.Index == nil {
					return nil, errors.New("tool call delta missing index")
				}
				call := byIndex[*delta.Index]
				if call == nil {
					call = &bufferedToolCall{Index: *delta.Index}
					byIndex[*delta.Index] = call
					order = append(order, *delta.Index)
				}
				if delta.ID != "" {
					call.ID = delta.ID
				}
				if delta.Type != "" {
					call.Type = delta.Type
				}
				if delta.Function.Name != "" {
					call.Name = delta.Function.Name
				}
				if delta.Function.Arguments != nil {
					call.Arguments += *delta.Function.Arguments
				}
			}
		}
	}
	if len(order) == 0 {
		return nil, nil
	}
	if !finished || !done {
		return nil, errors.New("tool call stream missing final close")
	}
	sort.Ints(order)
	out := make([]bufferedToolCall, 0, len(order))
	for _, index := range order {
		call := byIndex[index]
		if call.ID == "" || call.Type != "function" || call.Name == "" || !validToolCallArgumentsObject(call.Arguments) {
			return nil, errors.New("malformed consolidated tool call")
		}
		out = append(out, *call)
	}
	return out, nil
}

// errPreCommitCapExceeded is the sentinel returned by forwardStreaming's
// pre-commit phase when cumulative bytes hit maxPreCommitStreamingBytes
// before a commit-worthy event arrives. Distinguished from io.EOF /
// timeout / network errors so the caller can log a specific reason.
var errPreCommitCapExceeded = errors.New("pre-commit buffer cap exceeded")

// errPreCommitMalformedToolCalls is returned when a provider emits a
// malformed tool_calls delta before the stream commits. Commit-worthy gates
// billing settlement; rejection must NOT settle provider-positive usage.
var errPreCommitMalformedToolCalls = errors.New("malformed pre-commit tool_calls delta")

type commitLineStatus int

const (
	commitLineNoSignal commitLineStatus = iota
	commitLineWorthy
	commitLineMalformedToolCalls
)

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
//     non-empty array whose entries satisfy the SPEC-018 §8.4
//     minimal-shape validator, function_call non-empty object).
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
	return inspectCommitWorthyDataLine(line) == commitLineWorthy
}

func inspectCommitWorthyDataLine(line []byte) commitLineStatus {
	trimmed := bytes.TrimRight(line, "\r\n")
	trimmed = bytes.TrimPrefix(trimmed, []byte{0xEF, 0xBB, 0xBF})
	if !bytes.HasPrefix(trimmed, []byte("data:")) {
		return commitLineNoSignal
	}
	content := bytes.TrimSpace(trimmed[len("data:"):])
	if len(content) == 0 || bytes.Equal(content, []byte("[DONE]")) {
		return commitLineNoSignal
	}
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(content, &parsed); err != nil {
		return commitLineNoSignal
	}
	status := commitLineNoSignal
	if raw, ok := parsed["choices"]; ok {
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err == nil && len(arr) > 0 {
			for _, choice := range arr {
				var obj map[string]json.RawMessage
				if err := json.Unmarshal(choice, &obj); err != nil {
					continue
				}
				if raw, has := obj["delta"]; has {
					switch inspectOpenAIDeltaSignal(raw) {
					case deltaSignalMalformedToolCalls:
						return commitLineMalformedToolCalls
					case deltaSignalWorthy:
						status = commitLineWorthy
					}
				}
				if raw, has := obj["message"]; has {
					switch inspectOpenAIDeltaSignal(raw) {
					case deltaSignalMalformedToolCalls:
						return commitLineMalformedToolCalls
					case deltaSignalWorthy:
						status = commitLineWorthy
					}
				}
				if raw, has := obj["finish_reason"]; has && isNonEmptyJSONString(raw) {
					status = commitLineWorthy
				}
			}
		}
	}
	if status == commitLineWorthy {
		return status
	}
	if raw, ok := parsed["usage"]; ok {
		if isValidUsageObject(raw) {
			return commitLineWorthy
		}
	}
	return commitLineNoSignal
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

type deltaSignalStatus int

const (
	deltaSignalNoSignal deltaSignalStatus = iota
	deltaSignalWorthy
	deltaSignalMalformedToolCalls
)

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
//   - tool_calls: non-empty array whose entries satisfy the SPEC-018
//     §8.4 minimal-shape validator (function/tool calling)
//   - function_call: non-empty object (legacy function calling)
//   - reasoning: non-empty string (reasoning-model trace stream)
func hasOpenAIDeltaSignal(raw json.RawMessage) bool {
	return inspectOpenAIDeltaSignal(raw) == deltaSignalWorthy
}

func inspectOpenAIDeltaSignal(raw json.RawMessage) deltaSignalStatus {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return deltaSignalNoSignal
	}
	if raw, has := obj["tool_calls"]; has {
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err != nil || len(arr) == 0 {
			return deltaSignalMalformedToolCalls
		}
		for _, call := range arr {
			if !isCommitWorthyToolCallDelta(call) {
				return deltaSignalMalformedToolCalls
			}
		}
		return deltaSignalWorthy
	}
	if raw, has := obj["content"]; has && isNonEmptyJSONString(raw) {
		return deltaSignalWorthy
	}
	if raw, has := obj["role"]; has && isNonEmptyJSONString(raw) {
		return deltaSignalWorthy
	}
	if raw, has := obj["refusal"]; has && isNonEmptyJSONString(raw) {
		return deltaSignalWorthy
	}
	if raw, has := obj["reasoning"]; has && isNonEmptyJSONString(raw) {
		return deltaSignalWorthy
	}
	if raw, has := obj["function_call"]; has && isNonEmptyJSONObject(raw) {
		return deltaSignalWorthy
	}
	return deltaSignalNoSignal
}

// isCommitWorthyToolCallDelta validates the minimum OpenAI tool-call
// delta shape before the stream can cross the commit threshold.
// Commit-worthy gates billing settlement; rejection must NOT settle
// provider-positive usage.
func isCommitWorthyToolCallDelta(raw json.RawMessage) bool {
	var call struct {
		Index    *int            `json:"index"`
		ID       string          `json:"id"`
		Type     string          `json:"type"`
		Function json.RawMessage `json:"function"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	// Unknown fields remain allowed for SPEC-018 §10c forward compatibility.
	if err := dec.Decode(&call); err != nil {
		return false
	}
	if call.Index == nil || *call.Index < 0 || call.ID == "" || call.Type != "function" || len(call.Function) == 0 || bytes.Equal(call.Function, []byte("null")) {
		return false
	}
	var fn struct {
		Name      string  `json:"name"`
		Arguments *string `json:"arguments"`
	}
	dec = json.NewDecoder(bytes.NewReader(call.Function))
	// Unknown fields remain allowed for SPEC-018 §10c forward compatibility.
	if err := dec.Decode(&fn); err != nil {
		return false
	}
	if fn.Name == "" || fn.Arguments == nil {
		return false
	}
	if len([]byte(*fn.Arguments)) > maxToolCallArgumentsBytes {
		return false
	}
	return true
}

func validToolCallArgumentsObject(arguments string) bool {
	if len(arguments) > maxToolCallArgumentsBytes {
		return false
	}
	dec := json.NewDecoder(strings.NewReader(arguments))
	if !jsonArgumentsDepthWithinLimit(dec, maxToolCallArgumentsDepth) {
		return false
	}
	var obj map[string]json.RawMessage
	dec = json.NewDecoder(strings.NewReader(arguments))
	if err := dec.Decode(&obj); err != nil {
		return false
	}
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		return false
	}
	return obj != nil
}

type streamToolCallFinalValidator struct {
	opened       map[int]struct{}
	arguments    map[int]string
	totalBytes   int
	toolOpened   bool
	finishedTool bool
	done         bool
}

func newStreamToolCallFinalValidator() *streamToolCallFinalValidator {
	return &streamToolCallFinalValidator{
		opened:    map[int]struct{}{},
		arguments: map[int]string{},
	}
}

func (v *streamToolCallFinalValidator) observeLine(line []byte) error {
	trimmed := bytes.TrimRight(line, "\r\n")
	trimmed = bytes.TrimPrefix(trimmed, []byte{0xEF, 0xBB, 0xBF})
	if !bytes.HasPrefix(trimmed, []byte("data:")) {
		return nil
	}
	content := bytes.TrimSpace(trimmed[len("data:"):])
	if len(content) == 0 {
		return nil
	}
	if bytes.Equal(content, []byte("[DONE]")) {
		v.done = true
		return nil
	}
	var event struct {
		Choices []struct {
			Delta struct {
				Content   *string           `json:"content"`
				ToolCalls []json.RawMessage `json:"tool_calls"`
			} `json:"delta"`
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(content, &event); err != nil {
		return nil
	}
	for _, choice := range event.Choices {
		if choice.FinishReason != nil && *choice.FinishReason == "tool_calls" {
			v.finishedTool = true
		}
		if v.toolOpened && choice.Delta.Content != nil && *choice.Delta.Content != "" {
			return errors.New("tool-call stream fell back to content")
		}
		for _, rawCall := range choice.Delta.ToolCalls {
			if err := v.observeToolCall(rawCall); err != nil {
				return err
			}
		}
	}
	return nil
}

func (v *streamToolCallFinalValidator) observeBlock(block string) error {
	for _, line := range bytes.SplitAfter([]byte(block), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		if err := v.observeLine(line); err != nil {
			return err
		}
	}
	return nil
}

func (v *streamToolCallFinalValidator) observeToolCall(raw json.RawMessage) error {
	var call struct {
		Index    *int            `json:"index"`
		ID       string          `json:"id"`
		Type     string          `json:"type"`
		Function json.RawMessage `json:"function"`
	}
	if err := json.Unmarshal(raw, &call); err != nil {
		return errors.New("malformed tool_calls delta")
	}
	if call.Index == nil || *call.Index < 0 || len(call.Function) == 0 || bytes.Equal(call.Function, []byte("null")) {
		return errors.New("malformed tool_calls delta")
	}
	var fn struct {
		Name      string  `json:"name"`
		Arguments *string `json:"arguments"`
	}
	if err := json.Unmarshal(call.Function, &fn); err != nil {
		return errors.New("malformed tool_calls function delta")
	}
	index := *call.Index
	if _, ok := v.opened[index]; !ok {
		if call.ID == "" || call.Type != "function" || fn.Name == "" || fn.Arguments == nil {
			return errors.New("malformed tool-call opening delta")
		}
		v.opened[index] = struct{}{}
		v.toolOpened = true
	}
	if fn.Arguments == nil {
		return nil
	}
	next := v.arguments[index] + *fn.Arguments
	nextBytes := len([]byte(next))
	prevBytes := len([]byte(v.arguments[index]))
	if nextBytes > maxToolCallArgumentsBytes {
		return errors.New("byte_cap_exceeded")
	}
	if v.totalBytes-prevBytes+nextBytes > maxToolCallArgumentsResponseBytes {
		return errors.New("response_byte_cap_exceeded")
	}
	v.arguments[index] = next
	v.totalBytes = v.totalBytes - prevBytes + nextBytes
	return nil
}

func (v *streamToolCallFinalValidator) finalCloseOK() bool {
	if !v.toolOpened {
		return true
	}
	if !v.finishedTool || !v.done {
		return false
	}
	for index := range v.opened {
		arguments, ok := v.arguments[index]
		if !ok || !validToolCallArgumentsObject(arguments) {
			return false
		}
	}
	return true
}

func jsonArgumentsDepthWithinLimit(dec *json.Decoder, maxDepth int) bool {
	depth := 0
	sawToken := false
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return sawToken && depth == 0
		}
		if err != nil {
			return false
		}
		sawToken = true
		if delim, ok := tok.(json.Delim); ok {
			switch delim {
			case '{', '[':
				depth++
				if depth > maxDepth {
					return false
				}
			case '}', ']':
				depth--
				if depth < 0 {
					return false
				}
			}
		}
	}
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
		writeError(w, http.StatusServiceUnavailable, "no_provider_available", "Selected provider is not reachable")
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
	if v, ok := raw["stream"]; ok {
		if err := json.Unmarshal(v, &req.Stream); err != nil {
			return req, http.StatusBadRequest, "invalid_request", "Invalid stream"
		}
	}
	if status, code, msg := validateOptionalFields(raw, req.Stream); status != 0 {
		return req, status, code, msg
	}
	if status, code, msg := validateMessages(req.Messages); status != 0 {
		return req, status, code, msg
	}
	if status, code, msg := validateTools(raw, req.Messages); status != 0 {
		return req, status, code, msg
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

// dispatchBodyForProvider delegates to routing.RewriteModel. The
// pre-PR JSON-surgical model-field rewrite moved into the routing
// package as part of issue #266 T2; this wrapper preserves the
// chatRequest-typed call sites in forward*Sequence without leaking
// the buyer-internal chatRequest type past the package boundary.
func dispatchBodyForProvider(req chatRequest, provider pool.Provider) ([]byte, error) {
	return routing.RewriteModel(req.raw, req.Model, provider.ModelID)
}

func validateOptionalFields(raw map[string]json.RawMessage, stream bool) (int, string, string) {
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
		if status, code, msg := validateResponseFormatSchema(v, stream); status != 0 {
			return status, code, msg
		}
	}
	return 0, "", ""
}

func validateResponseFormatSchema(raw json.RawMessage, stream bool) (int, string, string) {
	var rf struct {
		Type       string          `json:"type"`
		JSONSchema json.RawMessage `json:"json_schema"`
	}
	if err := json.Unmarshal(raw, &rf); err != nil {
		return http.StatusBadRequest, "invalid_request", "Invalid response_format"
	}
	switch rf.Type {
	case "", "text":
		return 0, "", ""
	case "json_object":
		return 0, "", ""
	case "json_schema":
	default:
		return http.StatusBadRequest, "invalid_request", "Invalid response_format"
	}
	var spec map[string]json.RawMessage
	if len(rf.JSONSchema) == 0 || json.Unmarshal(rf.JSONSchema, &spec) != nil {
		return http.StatusBadRequest, "json_schema_missing_schema", "response_format.json_schema must be an object"
	}
	var name string
	if rawName, ok := spec["name"]; !ok || json.Unmarshal(rawName, &name) != nil {
		return http.StatusBadRequest, "json_schema_missing_name", "response_format.json_schema.name is required"
	}
	if !validJSONSchemaName(name) {
		return http.StatusBadRequest, "json_schema_invalid_name", "response_format.json_schema.name must match ^[A-Za-z0-9_-]{1,64}$"
	}
	if rawStrict, ok := spec["strict"]; ok {
		var strict bool
		if err := json.Unmarshal(rawStrict, &strict); err != nil {
			return http.StatusBadRequest, "invalid_request", "response_format.json_schema.strict must be boolean"
		}
		if !strict {
			return http.StatusBadRequest, "json_schema_non_strict_unsupported", "Non-strict structured output is unsupported in SPEC-019 v0.1.0"
		}
	}
	rawSchema, ok := spec["schema"]
	if !ok || len(bytes.TrimSpace(rawSchema)) == 0 || bytes.Equal(bytes.TrimSpace(rawSchema), []byte("null")) {
		return http.StatusBadRequest, "json_schema_missing_schema", "response_format.json_schema.schema is required"
	}
	if len(rawSchema) > maxJSONSchemaBytes {
		return http.StatusRequestEntityTooLarge, "json_schema_too_large", "response_format.json_schema.schema exceeds 16384 bytes"
	}
	if err := validateJSONSchemaRaw(rawSchema, "", 1); err != nil {
		return err.status, err.code, err.message
	}
	return 0, "", ""
}

type schemaValidationError struct {
	status  int
	code    string
	message string
}

func validateJSONSchemaRaw(raw json.RawMessage, pointer string, depth int) *schemaValidationError {
	if depth > maxJSONSchemaDepth {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_too_deep", "response_format.json_schema.schema exceeds maximum depth"}
	}
	var node map[string]json.RawMessage
	if err := json.Unmarshal(raw, &node); err != nil {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "Schema node must be an object"}
	}
	allowed := map[string]bool{"type": true, "properties": true, "required": true, "items": true, "enum": true, "const": true, "additionalProperties": true, "title": true, "description": true, "minimum": true, "maximum": true, "multipleOf": true}
	for key := range node {
		if !allowed[key] && !(pointer == "" && key == "$schema") {
			return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "Unsupported JSON Schema keyword " + key}
		}
	}
	var typ string
	if rawType, ok := node["type"]; !ok || json.Unmarshal(rawType, &typ) != nil || !allowedJSONSchemaType(typ) {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "Schema node must declare an allowed type"}
	}
	if rawConst, ok := node["const"]; ok && !jsonSchemaScalarConforms(rawConst, typ) {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_invalid_const_or_enum_type", "const value does not conform to schema type"}
	}
	if rawEnum, ok := node["enum"]; ok {
		var values []json.RawMessage
		if err := json.Unmarshal(rawEnum, &values); err != nil {
			return &schemaValidationError{http.StatusBadRequest, "json_schema_invalid_const_or_enum_type", "enum must be an array"}
		}
		for _, value := range values {
			if !jsonSchemaScalarConforms(value, typ) {
				return &schemaValidationError{http.StatusBadRequest, "json_schema_invalid_const_or_enum_type", "enum value does not conform to schema type"}
			}
		}
	}
	if err := validateJSONSchemaNumericBounds(node, typ); err != nil {
		return err
	}
	switch typ {
	case "object":
		var addl bool
		if rawAddl, ok := node["additionalProperties"]; !ok || json.Unmarshal(rawAddl, &addl) != nil || addl {
			return &schemaValidationError{http.StatusBadRequest, "json_schema_strict_requires_additional_properties_false", "Strict object schemas require additionalProperties:false"}
		}
		if _, ok := node["items"]; ok {
			return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "items is only allowed on array schemas"}
		}
		properties := map[string]json.RawMessage{}
		if rawProps, ok := node["properties"]; ok {
			if err := json.Unmarshal(rawProps, &properties); err != nil {
				return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "properties must be an object"}
			}
		}
		requiredSet := map[string]bool{}
		if rawRequired, ok := node["required"]; ok {
			var required []string
			if err := json.Unmarshal(rawRequired, &required); err != nil {
				return &schemaValidationError{http.StatusBadRequest, "json_schema_strict_requires_all_properties_required", "required must be an array of strings"}
			}
			for _, key := range required {
				if _, ok := properties[key]; !ok || requiredSet[key] {
					return &schemaValidationError{http.StatusBadRequest, "json_schema_strict_requires_all_properties_required", "required entries must uniquely name properties"}
				}
				requiredSet[key] = true
			}
		}
		for key, child := range properties {
			if !requiredSet[key] {
				return &schemaValidationError{http.StatusBadRequest, "json_schema_strict_requires_all_properties_required", "Strict object schemas require every property to be listed in required"}
			}
			if err := validateJSONSchemaRaw(child, pointer+"/"+key, depth+1); err != nil {
				return err
			}
		}
	case "array":
		child, ok := node["items"]
		if !ok {
			return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "Array schemas require items schema"}
		}
		for _, keyword := range []string{"properties", "required", "additionalProperties"} {
			if _, ok := node[keyword]; ok {
				return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "Object-only schema keyword used on array schema"}
			}
		}
		if err := validateJSONSchemaRaw(child, pointer+"/items", depth+1); err != nil {
			return err
		}
	default:
		for _, keyword := range []string{"properties", "required", "items", "additionalProperties"} {
			if _, ok := node[keyword]; ok {
				return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", keyword + " is not allowed on scalar schemas"}
			}
		}
	}
	return nil
}

func validJSONSchemaName(name string) bool {
	if len(name) == 0 || len(name) > 64 {
		return false
	}
	for i := 0; i < len(name); i++ {
		b := name[i]
		if (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_' || b == '-' {
			continue
		}
		return false
	}
	return true
}

func allowedJSONSchemaType(typ string) bool {
	switch typ {
	case "object", "array", "string", "number", "integer", "boolean", "null":
		return true
	default:
		return false
	}
}

func jsonSchemaScalarConforms(raw json.RawMessage, typ string) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] == '{' || trimmed[0] == '[' {
		return false
	}
	var value any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&value); err != nil {
		return false
	}
	switch typ {
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "null":
		return value == nil
	case "number":
		_, ok := value.(json.Number)
		return ok
	case "integer":
		n, ok := value.(json.Number)
		if !ok {
			return false
		}
		_, err := strconv.ParseInt(n.String(), 10, 64)
		return err == nil && !strings.ContainsAny(n.String(), ".eE")
	case "object", "array":
		return false
	default:
		return false
	}
}

func validateJSONSchemaNumericBounds(node map[string]json.RawMessage, typ string) *schemaValidationError {
	// AC-V2-10a/10b (SPEC-019 v0.2.4): numeric-bound operands must be
	// finite and safely enforceable before provider inference.
	keywords := []string{"minimum", "maximum", "multipleOf"}
	var present []string
	for _, keyword := range keywords {
		if _, ok := node[keyword]; ok {
			present = append(present, keyword)
		}
	}
	if len(present) == 0 {
		return nil
	}
	if typ != "number" && typ != "integer" {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", present[0] + " is only allowed on number or integer schemas"}
	}
	minimum, hasMinimum, errKeyword := jsonSchemaNumberOperand(node, "minimum")
	if errKeyword != "" {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", errKeyword + " must be a JSON number"}
	}
	maximum, hasMaximum, errKeyword := jsonSchemaNumberOperand(node, "maximum")
	if errKeyword != "" {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", errKeyword + " must be a JSON number"}
	}
	multipleOf, hasMultipleOf, errKeyword := jsonSchemaNumberOperand(node, "multipleOf")
	if errKeyword != "" {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", errKeyword + " must be a JSON number"}
	}
	const leastNormalFloat64 = 2.2250738585072014e-308
	const minimumSupportedMultipleOf = 1e-300
	if hasMultipleOf && (multipleOf <= 0 || math.IsInf(multipleOf, 0) || math.IsNaN(multipleOf) || multipleOf <= minimumSupportedMultipleOf || multipleOf < leastNormalFloat64) {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "multipleOf must be a normal positive number"}
	}
	if hasMinimum && hasMaximum && minimum > maximum {
		return &schemaValidationError{http.StatusBadRequest, "json_schema_unsupported_keyword", "minimum must be less than or equal to maximum"}
	}
	return nil
}

func jsonSchemaNumberOperand(node map[string]json.RawMessage, keyword string) (float64, bool, string) {
	raw, ok := node[keyword]
	if !ok {
		return 0, false, ""
	}
	var value any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&value); err != nil {
		return 0, true, keyword
	}
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		return 0, true, keyword
	}
	jsonNumber, ok := value.(json.Number)
	if !ok {
		return 0, true, keyword
	}
	number, err := jsonNumber.Float64()
	if err != nil || math.IsInf(number, 0) || math.IsNaN(number) {
		return 0, true, keyword
	}
	return number, true, ""
}

func validateMessages(messages []chatMessage) (int, string, string) {
	if len(messages) > maxChatMessages {
		return http.StatusBadRequest, "messages_too_long", "messages may contain at most 256 entries"
	}

	allIDs := map[string]int{}
	var parsedByMessage = make([][]requestToolCall, len(messages))
	totalToolCalls := 0
	totalArgumentBytes := 0
	duplicateAssistantID := false

	for i, m := range messages {
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
			if hasTools {
				calls, status, code, msg := parseRequestToolCalls(m.ToolCalls, i)
				if status != 0 {
					return status, code, msg
				}
				totalToolCalls += len(calls)
				if totalToolCalls > maxAssistantToolCalls {
					return http.StatusBadRequest, "too_many_tool_calls", "assistant tool_calls may contain at most 128 entries"
				}
				for _, call := range calls {
					if !validRequestToolCallID(call.ID) {
						return http.StatusBadRequest, "invalid_tool_call_id", "Invalid tool_call id"
					}
					if _, exists := allIDs[call.ID]; exists {
						duplicateAssistantID = true
					} else {
						allIDs[call.ID] = i
					}
					totalArgumentBytes += len([]byte(call.Arguments))
					if totalArgumentBytes > maxToolCallArgumentsResponseBytes {
						return http.StatusRequestEntityTooLarge, "tool_call_arguments_aggregate_too_large", "assistant-history tool_call arguments exceed aggregate cap"
					}
				}
				parsedByMessage[i] = calls
			}
		case "tool":
			if m.ToolCallID == "" || !validRequestToolCallID(m.ToolCallID) {
				return http.StatusBadRequest, "invalid_tool_call_id", "Invalid tool_call_id"
			}
			if string(m.Content) == "null" || !rawString(m.Content) {
				return http.StatusBadRequest, "invalid_request", "Invalid tool message content"
			}
		default:
			return http.StatusBadRequest, "invalid_request", "Invalid message role"
		}
	}
	if duplicateAssistantID {
		return http.StatusBadRequest, "duplicate_tool_call_id", "Duplicate assistant tool_call id"
	}

	seenAssistantIDs := map[string]struct{}{}
	fulfilledToolIDs := map[string]struct{}{}
	totalToolResultBytes := 0
	for i, m := range messages {
		for _, call := range parsedByMessage[i] {
			seenAssistantIDs[call.ID] = struct{}{}
		}
		if m.Role != "tool" {
			continue
		}
		if _, ok := allIDs[m.ToolCallID]; !ok {
			return http.StatusBadRequest, "tool_call_id_not_found", "tool_call_id does not reference an earlier assistant tool_call"
		}
		if _, ok := seenAssistantIDs[m.ToolCallID]; !ok {
			return http.StatusBadRequest, "tool_call_result_out_of_order", "tool result appears before matching assistant tool_call"
		}
		if _, exists := fulfilledToolIDs[m.ToolCallID]; exists {
			return http.StatusBadRequest, "duplicate_tool_call_id", "Duplicate tool result for tool_call_id"
		}
		fulfilledToolIDs[m.ToolCallID] = struct{}{}
		var content string
		_ = json.Unmarshal(m.Content, &content)
		contentBytes := len([]byte(content))
		if contentBytes > maxToolResultBytes {
			return http.StatusRequestEntityTooLarge, "tool_result_too_large", "tool message content exceeds 256 KiB"
		}
		totalToolResultBytes += contentBytes
		if totalToolResultBytes > maxToolResultsAggregateBytes {
			return http.StatusRequestEntityTooLarge, "tool_results_aggregate_too_large", "tool message content exceeds aggregate cap"
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

func parseRequestToolCalls(raw json.RawMessage, messageIndex int) ([]requestToolCall, int, string, string) {
	var wire []struct {
		ID       string `json:"id"`
		Type     string `json:"type"`
		Function struct {
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
		} `json:"function"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil || len(wire) == 0 {
		return nil, http.StatusBadRequest, "invalid_tools", "Invalid tool_calls"
	}
	out := make([]requestToolCall, 0, len(wire))
	for _, call := range wire {
		if call.ID == "" || call.Type != "function" || call.Function.Name == "" {
			return nil, http.StatusBadRequest, "invalid_tools", "Invalid tool_calls"
		}
		if len([]byte(call.Function.Arguments)) > maxToolCallArgumentsBytes {
			return nil, http.StatusRequestEntityTooLarge, "tool_call_arguments_too_large", "tool_call arguments exceed 1 MiB"
		}
		if !validToolCallArgumentsObject(call.Function.Arguments) {
			return nil, http.StatusBadRequest, "invalid_tools", "Invalid tool_call arguments"
		}
		out = append(out, requestToolCall{ID: call.ID, Name: call.Function.Name, Arguments: call.Function.Arguments, MsgIndex: messageIndex})
	}
	return out, 0, "", ""
}

func validRequestToolCallID(value string) bool {
	if !strings.HasPrefix(value, "call_") {
		return false
	}
	suffix := value[5:]
	if len(suffix) < 16 || len(suffix) > 64 {
		return false
	}
	for i := 0; i < len(suffix); i++ {
		c := suffix[i]
		if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			continue
		}
		return false
	}
	return true
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

func (s *Server) selectProvider(requestID string, req chatRequest, headers http.Header, dailyKey string) (pool.Provider, *routeError) {
	return s.selectProviderExcluding(requestID, req, headers, nil, dailyKey)
}

func (s *Server) failoverCandidate(requestID string, req chatRequest, headers http.Header, failed pool.Provider, excluded map[string]struct{}, dailyKey string) (pool.Provider, bool) {
	if !s.failoverEnabled || hasPinnedRoute(headers) {
		return pool.Provider{}, false
	}
	if excluded == nil {
		excluded = map[string]struct{}{}
	}
	excluded[failed.SortKey()] = struct{}{}
	failoverHeaders := headers.Clone()
	failoverHeaders.Del("X-MacProvider-Provider")
	failoverHeaders.Del("X-MacProvider-Session")
	next, routeErr := s.selectProviderExcluding(requestID, req, failoverHeaders, excluded, dailyKey)
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

func (s *Server) selectProviderExcluding(requestID string, req chatRequest, headers http.Header, excluded map[string]struct{}, dailyKey string) (pool.Provider, *routeError) {
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

	exSet := routing.NewExcluded(len(excluded))
	for k := range excluded {
		exSet.AddKey(k)
	}
	checker := &eligibilityCtx{
		s:               s,
		model:           req.Model,
		class:           class,
		estimatedTokens: estimatedTokens,
		tier2Cfg:        tier2Cfg,
	}
	result := routing.EligibleCandidates(providers, exSet, pool.Provider.SortKey, checker)
	candidates := result.Eligible
	if len(candidates) == 0 {
		// PreQuotaCount distinguishes "first loop dropped everything"
		// from "every first-loop survivor was quota-blocked". Quota
		// is checked first because SPEC-002 reserves 429 for the
		// every-otherwise-eligible-blocked case; once we know the
		// first loop did produce survivors but all of them got quota-
		// blocked, the envelope MUST be 429 not 503.
		if result.PreQuotaCount > 0 && result.Counts[routing.ReasonQuotaBlocked] == result.PreQuotaCount {
			return pool.Provider{}, &routeError{status: http.StatusTooManyRequests, code: "provisional_quota_exceeded", message: "All otherwise eligible provisional providers are over request quota"}
		}
		if result.Counts[routing.ReasonContextTooSmall] > 0 {
			return pool.Provider{}, &routeError{status: http.StatusRequestEntityTooLarge, code: "context_exceeds_capacity", message: "Request exceeds provider context capacity"}
		}
		if tier2Cfg.RequireHashVerified && (result.Counts[routing.ReasonTier2HashRequired] > 0 || len(result.HashMismatches) > 0) {
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_hash_verified_required", message: "No hash-verified provider available for model `" + req.Model + "`.", typ: "server_error"}
		}
		if len(result.HashMismatches) > 0 {
			providerID := result.HashMismatches[0].Provider.ProviderID
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_hash_mismatch", message: "Provider `" + providerID + "` hash verification failed; excluded from pool.", typ: "server_error"}
		}
		if result.Counts[routing.ReasonTier2EncryptedLeg] > 0 {
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_encrypted_leg_required", message: "No encrypted provider leg available for model `" + req.Model + "`.", typ: "server_error"}
		}
		if result.Counts[routing.ReasonTier2Attestation] > 0 {
			return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "tier2_attestation_required", message: "No attested provider available for model `" + req.Model + "`.", typ: "server_error"}
		}
		return pool.Provider{}, &routeError{status: http.StatusServiceUnavailable, code: "no_provider_available", message: "No provider available for model " + req.Model}
	}
	objective := s.objectiveForRequest(headers, class)
	// #266 T3c: sortCandidates surfaces the balanced-score cache so
	// applySticky / applyRandomTiebreak / logRoutingDecisionFull
	// reuse it instead of recomputing the FR-SR-8 normative formula
	// at every epsilon comparison + log emission.
	balancedCache := s.sortCandidates(candidates, objective)
	candidates = s.applySticky(requestID, headers, req.Model, class, candidates, balancedCache)
	candidates, seed, draw, reason := s.applyRandomTiebreak(requestID, candidates, objective, dailyKey, balancedCache)
	// Thread real pre-filter pool size + per-reason rejection counts
	// into the SPEC-004 §7 routing-decision log per the FULL-IMPL
	// audit CODE-M2 finding (previously both counts were the
	// post-filter slice length, and filtered_counts was always
	// omitted). routeKeyedFilterCounts converts routing.RejectionReason
	// enum keys to SPEC-004 §7 stringly names.
	s.logRoutingDecisionFullWithCache(requestID, len(providers), routeKeyedFilterCounts(result.Counts), candidates, objective, seed, draw, reason, "", balancedCache)
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
	s.routingMu.RLock()
	defer s.routingMu.RUnlock()
	for name, class := range s.modelClasses {
		if strings.EqualFold(name, model) {
			cp := config.ModelClassConfig{Objective: class.Objective, Members: append([]string(nil), class.Members...), Models: append([]string(nil), class.Models...)}
			return &cp
		}
	}
	return nil
}

// snapshotModelClasses returns a read-only clone of the current
// routing.model_classes config. Callers iterate the returned map
// without holding routingMu. Used by handleModels (catalog list)
// and by SetRoutingClasses for diff computation.
func (s *Server) snapshotModelClasses() map[string]config.ModelClassConfig {
	s.routingMu.RLock()
	defer s.routingMu.RUnlock()
	return cloneModelClasses(s.modelClasses)
}

// SetRoutingClasses atomically swaps the routing.model_classes config
// and calls sticky.Map.InvalidateClass for each class whose membership
// shape changed (added, removed, or members differ). Returns the list
// of changed class names + the total number of sticky entries
// invalidated. Empty / nil input is treated as "no classes" — a full
// reset of any prior classes counts as shape changes for those.
//
// Issue #266 T1 — wires the SIGHUP-trigger half of FR-SR-5 paragraph 2
// ("invalidate on class reconfig"). The InvalidateClass primitive
// shipped with PR #263; PR #170 deferred the trigger wiring.
//
// Safe to call concurrently with hot-path readers (resolveModelClass,
// snapshotModelClasses); they take routingMu.RLock while this method
// holds the write lock.
func (s *Server) SetRoutingClasses(next map[string]config.ModelClassConfig) (changedClasses []string, invalidated int) {
	cloned := cloneModelClasses(next)
	s.routingMu.Lock()
	prev := s.modelClasses
	changed := diffModelClasses(prev, cloned)
	s.modelClasses = cloned
	s.routingMu.Unlock()
	if len(changed) == 0 {
		return nil, 0
	}
	if s.stickyMap != nil {
		for _, name := range changed {
			invalidated += s.stickyMap.InvalidateClass(name)
		}
	}
	return changed, invalidated
}

// diffModelClasses returns the names of classes whose membership
// shape differs between prev and next. Includes: classes added in
// next, classes removed from prev, classes whose Objective changed,
// classes whose Models OR Members slices differ ELEMENT-WISE
// (ordered comparison — `[a,b]` and `[b,a]` are treated as DIFFERENT
// because the upstream cloneModelClasses preserves operator-config
// ordering and the BUILD prompt's class-membership semantics
// reference the YAML-declared order). The returned slice is sorted
// ascending so caller log output is deterministic.
func diffModelClasses(prev, next map[string]config.ModelClassConfig) []string {
	seen := make(map[string]struct{}, len(prev)+len(next))
	var changed []string
	for name, prevClass := range prev {
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		nextClass, ok := next[name]
		if !ok || !modelClassEqual(prevClass, nextClass) {
			changed = append(changed, name)
		}
	}
	for name := range next {
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		if _, ok := prev[name]; !ok {
			changed = append(changed, name)
		}
	}
	sort.Strings(changed)
	return changed
}

func modelClassEqual(a, b config.ModelClassConfig) bool {
	if a.Objective != b.Objective {
		return false
	}
	if !stringSliceEqual(a.Models, b.Models) {
		return false
	}
	if !stringSliceEqual(a.Members, b.Members) {
		return false
	}
	return true
}

func stringSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
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

// sortCandidates delegates to routing.SortCandidatesWithScores. The
// pre-T2 inline 4-branch comparator moved into routing in #266 T2;
// #266 T3c surfaces the balanced-score cache via the returned map so
// downstream consumers (applySticky / applyRandomTiebreak via
// inEpsilonCohort / logRoutingDecisionFull) can reuse it instead of
// recomputing the FR-SR-8 normative formula O(N) times per request.
//
// Returns nil for non-balanced objectives — the cache is meaningless
// outside the balanced score-map shape, and downstream consumers
// gate on nil to fall through to their own per-objective compute.
func (s *Server) sortCandidates(candidates []pool.Provider, objective string) map[string]float64 {
	return routing.SortCandidatesWithScores(candidates, routing.Objective(objective), routing.Weights{Pinned: 1.0, Provisional: s.provisionalWeight}, nil)
}

func (s *Server) applyRandomTiebreak(requestID string, candidates []pool.Provider, objective, dailyKey string, balancedCache map[string]float64) ([]pool.Provider, int64, float64, string) {
	if !s.tiebreakRandomize || len(candidates) < 2 {
		return candidates, 0, 0, "deterministic"
	}
	cohortEnd := 1
	for cohortEnd < len(candidates) {
		if !s.inEpsilonCohort(candidates[0], candidates[cohortEnd], objective, candidates, balancedCache) {
			break
		}
		cohortEnd++
	}
	if cohortEnd < 2 {
		return candidates, 0, 0, "deterministic"
	}
	// dailyKey is the per-request UTC bucket snapshotted in
	// forwardState.dailyKey at request entry; threaded here so retries
	// that span UTC midnight reproduce the first-attempt seed.
	// Empty string falls back to defaultDailyKey() — defensive guard
	// for callers (admin paths, future entry points) that don't yet
	// carry forwardState. Issue #266 T1.
	if dailyKey == "" {
		dailyKey = defaultDailyKey()
	}
	seed := seedForRequestWithKey(requestID, dailyKey)
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

func (s *Server) applySticky(requestID string, headers http.Header, model string, class *config.ModelClassConfig, candidates []pool.Provider, balancedCache map[string]float64) []pool.Provider {
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
		if !s.inEpsilonCohort(candidates[0], candidate, s.objectiveForRequest(headers, class), candidates, balancedCache) {
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

// stickyLookup delegates to routing/sticky.Map.Lookup. Returns the
// sticky.Entry, a hit boolean, and the FR-SR-3 miss reason
// ("not_found" / "expired") matching the pre-Phase-A inline path.
func (s *Server) stickyLookup(key string) (sticky.Entry, bool, string) {
	res := s.stickyMap.Lookup(key)
	return res.Entry, res.Hit, res.MissReason
}

// stickyStore delegates to routing/sticky.Map.Update. The Update
// implementation has the refresh-path-FIRST guard that the old
// inline code lacked (preventing eviction of unrelated entries
// when refreshing an existing key at MaxEntries — adversarial /
// FULL-IMPL SEC R1 HIGH finding fix). Update also rejects refreshes
// where the supplied accountID differs from the existing entry's
// AccountID (FULL-IMPL adversarial-M5 fix); we log a
// sticky_account_mismatch audit event for ops visibility.
func (s *Server) stickyStore(headers http.Header, provider pool.Provider, modelScope string) {
	if !s.stickyEnabled || hasPinnedRoute(headers) {
		return
	}
	key := strings.TrimSpace(headers.Get("X-MacProvider-Internal-Conv"))
	if !strings.HasPrefix(key, "conv:") {
		return
	}
	accountID := headers.Get("X-MacProvider-Account")
	mismatch := s.stickyMap.Update(key, accountID, provider.ProviderID, modelScope)
	if mismatch && s.stickyMismatchLimiter.allow(key) {
		// Rate-limited per-conversation_key (1 warn / minute / key,
		// bounded entry table). Suppressed warns are dropped, NOT
		// downgraded — under hostile-gateway pressure we don't want
		// even Info-level noise. The audit-event purpose is satisfied
		// by the throttled emission; cross-account refresh refusal
		// remains structurally rejected by sticky.Map.Update.
		s.log.Warn().
			Str("event", "sticky_account_mismatch").
			Str("provider_id", provider.ProviderID).
			Str("model_scope", modelScope).
			Msg("sticky.Map.Update refused refresh: account_id mismatch (existing entry attribution preserved)")
	}
}

// purgeStickyAccount delegates to routing/sticky.Map.PurgeAccount.
// Guards against accidental empty-accountID purge (which would
// wipe every entry with an unset AccountID) per the adversarial
// FULL-IMPL R1 finding.
func (s *Server) purgeStickyAccount(accountID string) int {
	if accountID == "" {
		return 0
	}
	return s.stickyMap.PurgeAccount(accountID)
}

// shouldRetry delegates to routing.ShouldRetry. The pure-policy
// gate moved out of buyer in #266 T2; this wrapper threads the
// Server's per-request inputs (headers, clock, operator-config caps)
// into the explicit ShouldRetryInput so the routing package can be
// unit-tested without spinning up a buyer.Server.
func (s *Server) shouldRetry(r *http.Request, startedAt time.Time, explicitRetries, faultedProviders, status int, err error) bool {
	return routing.ShouldRetry(routing.ShouldRetryInput{
		MaxRetries:             s.maxRetries,
		RequestedRetries:       routing.RetryHeaderLimit(r.Header.Get("X-MacProvider-Retry")),
		HasPinnedRoute:         hasPinnedRoute(r.Header),
		ContextErr:             r.Context().Err(),
		ExplicitRetries:        explicitRetries,
		FaultedProviders:       faultedProviders,
		MaxFaultedPerRequest:   s.maxFaultedPerRequest,
		Now:                    s.now(),
		StartedAt:              startedAt,
		RequestTimeout:         s.requestTimeout,
		RetryPerAttemptTimeout: s.retryPerAttemptTimeout,
		Status:                 status,
		Err:                    err,
	})
}

// routingScores delegates to routing.ObjectiveScores. Moved out of
// buyer in #266 T2; the result is keyed by ProviderID+/+AssignedID
// (matching buyer.routeKey) so callers that look up per-candidate
// scores via p.SortKey() continue to work unchanged.
func (s *Server) routingScores(candidates []pool.Provider, objective string) map[string]float64 {
	return routing.ObjectiveScores(candidates, routing.Objective(objective), routing.Weights{Pinned: 1.0, Provisional: s.provisionalWeight})
}

// inEpsilonCohort delegates to routing.InEpsilonCohort so the
// hot-path epsilon check picks up the fail-closed NaN/±Inf guard
// from routing.WithinRelativeEpsilon. Prior to the FULL-IMPL audit
// fix-pass, server.go had its own inline `withinRelativeEpsilon`
// WITHOUT the non-finite guard — a buggy heartbeat with +Inf
// throughput could bypass the cohort filter via +Inf == +Inf.
//
// `balancedCache` (issue #266 T3c) is the per-request balanced-score
// cache surfaced by sortCandidates; when balanced is the objective
// AND the cache is non-nil, the cohort check reads scores from the
// cache instead of recomputing KeyedBalancedScores at every call.
// Pre-T3c the function recomputed the FR-SR-8 normative formula on
// EVERY epsilon comparison — O(N) per applySticky/applyRandomTiebreak
// iteration. nil cache + balanced objective falls through to a
// freshly-computed map (legacy / test path).
func (s *Server) inEpsilonCohort(top, candidate pool.Provider, objective string, candidates []pool.Provider, balancedCache map[string]float64) bool {
	weights := routing.Weights{Pinned: 1.0, Provisional: s.provisionalWeight}
	var scoreFn func(pool.Provider) float64
	if objective == "balanced" {
		scores := balancedCache
		if scores == nil {
			scores = routing.KeyedBalancedScores(candidates)
		}
		scoreFn = func(p pool.Provider) float64 { return scores[p.SortKey()] }
	}
	return routing.InEpsilonCohort(top, candidate, routing.Objective(objective), s.tiebreakEpsilon, weights, scoreFn)
}

// seedForRequest derives the FR-SR-17 reproducibility seed from
// requestID + a daily key bucket per SPEC-004 §7 / BUILD prompt
// Phase D log-block contract:
//
//	"random_seed: per-request seed derivable from request_id +
//	 daily key, NEVER from time.Now() alone"
//
// The daily key bucket is the current UTC date (YYYY-MM-DD), which
// makes the seed:
//  1. Deterministically reproducible across the same UTC day for
//     the same requestID (audit replay possible within that
//     window), AND
//  2. Rotated daily so the seed space does not leak provider-
//     selection patterns across days.
//
// dailyKeyFn is injectable for tests; production callers go through
// the variadic-free seedForRequest wrapper which uses
// defaultDailyKey (UTC date).
func seedForRequest(requestID string) int64 {
	return seedForRequestWithKey(requestID, defaultDailyKey())
}

func defaultDailyKey() string {
	return time.Now().UTC().Format("2006-01-02")
}

func seedForRequestWithKey(requestID, dailyKey string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(dailyKey))
	_, _ = h.Write([]byte("|"))
	_, _ = h.Write([]byte(requestID))
	return int64(h.Sum64())
}

// routeKeyedFilterCounts maps routing.RejectionReason enum keys to
// the SPEC-004 §7 'filtered_counts' string keys (model_mismatch,
// context_too_small, breaker_held, busy, quota_blocked, etc.).
// Returns nil when the input is empty so LogRoutingDecision omits
// the field per its "empty optional" contract.
func routeKeyedFilterCounts(counts map[routing.RejectionReason]int) map[string]int {
	if len(counts) == 0 {
		return nil
	}
	out := make(map[string]int, len(counts))
	for k, v := range counts {
		var key string
		switch k {
		case routing.ReasonExcluded:
			key = "excluded_retry"
		case routing.ReasonModelMismatch:
			// ProviderMatchesRequest combines model/class + FR-P5
			// state. Pre-Phase-C the inline loop conflated both
			// rejections; SPEC-004 §7 names them separately
			// (model_mismatch / not_ready). The combined reason
			// maps to model_mismatch here since the spec does not
			// require splitting and the pre-Phase-C log did the
			// same.
			key = "model_mismatch"
		case routing.ReasonContextTooSmall:
			key = "context_too_small"
		case routing.ReasonTier2HashMismatch:
			key = "tier2_hash_mismatch"
		case routing.ReasonTier2HashRequired:
			key = "tier2_hash_required"
		case routing.ReasonTier2EncryptedLeg:
			key = "tier2_encrypted_leg"
		case routing.ReasonTier2Attestation:
			key = "tier2_attestation"
		case routing.ReasonQuotaBlocked:
			key = "quota_blocked"
		default:
			key = "other"
		}
		out[key] += v
	}
	return out
}

// logRoutingDecisionFull is the post-Phase-D / FULL-IMPL fix-pass
// surface: like logRoutingDecision but additionally threads the
// real pre-filter pool size and per-reason rejection counts into
// the SPEC-004 §7 routing-decision log. The sticky-path / retry-
// path callers that don't have a FilterResult continue to use
// logRoutingDecision (which delegates here with 0 / nil for the
// new fields, matching the pre-Phase-D shape).
func (s *Server) logRoutingDecisionFull(requestID string, preFilterCount int, filteredCounts map[string]int, candidates []pool.Provider, objective string, seed int64, draw float64, reason, chosen string) {
	s.logRoutingDecisionFullWithCache(requestID, preFilterCount, filteredCounts, candidates, objective, seed, draw, reason, chosen, nil)
}

// logRoutingDecisionFullWithCache is the cache-aware
// logRoutingDecisionFull. Issue #266 T3c: callers in the main-
// selection path pass the balanced-score cache surfaced from
// sortCandidates so the SPEC-004 §7 candidate_set values reuse the
// already-computed map instead of recomputing KeyedBalancedScores
// at log-emit time. nil cache falls through to ObjectiveScores
// (which recomputes — used by retry / sticky-miss log paths that
// don't share the cache).
func (s *Server) logRoutingDecisionFullWithCache(requestID string, preFilterCount int, filteredCounts map[string]int, candidates []pool.Provider, objective string, seed int64, draw float64, reason, chosen string, balancedCache map[string]float64) {
	if chosen == "" && len(candidates) > 0 {
		chosen = candidates[0].ProviderID
	}
	scores := routing.ObjectiveScoresWithCache(candidates, routing.Objective(objective), routing.Weights{Pinned: 1.0, Provisional: s.provisionalWeight}, balancedCache)
	weights := routing.Weights{Pinned: 1.0, Provisional: s.provisionalWeight}
	set := make([]routing.CandidateLogEntry, 0, len(candidates))
	var chosenAssignedID string
	for _, p := range candidates {
		set = append(set, routing.ProviderToCandidateLogEntry(p, scores[p.SortKey()], weights))
		if p.ProviderID == chosen && chosenAssignedID == "" {
			chosenAssignedID = p.AssignedID
		}
	}
	tiebreakMode := ""
	switch reason {
	case "deterministic":
		tiebreakMode = "deterministic"
	case "randomized":
		tiebreakMode = "random_epsilon"
	}
	beforeCount := preFilterCount
	if beforeCount == 0 {
		beforeCount = len(candidates)
	}
	routing.LogRoutingDecision(s.log, routing.Decision{
		RequestID:                   requestID,
		Objective:                   objective,
		CandidateCountBeforeFilters: beforeCount,
		CandidateCountAfterFilters:  len(candidates),
		FilteredCounts:              filteredCounts,
		CandidateSet:                set,
		TiebreakMode:                tiebreakMode,
		TiebreakEpsilon:             s.tiebreakEpsilon,
		RandomSeed:                  seed,
		RandomDraw:                  draw,
		ChosenProviderID:            chosen,
		ChosenAssignedID:            chosenAssignedID,
		LegacyReason:                reason,
	})
}

func (s *Server) logRoutingDecision(requestID string, candidates []pool.Provider, objective string, seed int64, draw float64, reason, chosen string) {
	s.logRoutingDecisionFull(requestID, 0, nil, candidates, objective, seed, draw, reason, chosen)
}

// retryDecisionAttrs carries the per-attempt FR-SR-17 / SPEC-004 §7
// retry/preflight metadata threaded into the routing-decision log
// when the request is on a retry attempt past the first. Each field
// corresponds to a `routing.Decision` field of the same name. Issue
// #266 T1 — closes the "FR-SR-17 reproducibility log half-empty on
// retries" gap noted in PR #263's deferred follow-ups.
type retryDecisionAttrs struct {
	AttemptIndex    int    // 1-indexed attempt number (1 = first attempt)
	RetryCount      int    // count of explicit retries (state.explicitRetries)
	Retried         int    // count of additional provider attempts beyond first
	RetryReason     string // why this retry fired (e.g. "stream_timeout", "queue_full")
	PreflightResult string // last preflight check result, if any
}

// preflightLabel returns the SPEC-004 §7 PreflightResult label for a
// retry-attempt's routing-decision log. At afterAdvance time the
// just-selected provider has already PASSED preflight inside
// selectProviderExcluding (else selectProviderExcluding would have
// returned a routeError and afterAdvance would not fire). So the
// label is deterministic from request-time preflight-applicability:
// "accepted" when preflight actually ran, "not_applicable" when it
// was skipped because the estimate was below the threshold OR no
// preflight function was wired. Issue #266 T1 R1 audit MEDIUM fix
// (PreflightResult was previously empty on retries).
func (s *Server) preflightLabel(estimatedTokens int) string {
	if s.preflight == nil || estimatedTokens <= s.preflightThreshold {
		return "not_applicable"
	}
	return "accepted"
}

// logRoutingDecisionRetry emits the SPEC-004 §7 routing-decision log
// for a retry-attempt's post-advance provider selection, populating
// the per-attempt FR-SR-17 fields. `chosen` is the newly-selected
// provider for this attempt; `candidates` is the single-provider
// slice the existing retry-log call sites pass to keep the schema
// consistent. legacyReason is the back-compat `reason` string the
// pre-issue-#266 retry log used (e.g. "retry_2"), so log consumers
// keying off the legacy field keep working.
func (s *Server) logRoutingDecisionRetry(requestID string, candidates []pool.Provider, objective string, chosen string, legacyReason string, attrs retryDecisionAttrs) {
	if chosen == "" && len(candidates) > 0 {
		chosen = candidates[0].ProviderID
	}
	scores := s.routingScores(candidates, objective)
	weights := routing.Weights{Pinned: 1.0, Provisional: s.provisionalWeight}
	set := make([]routing.CandidateLogEntry, 0, len(candidates))
	var chosenAssignedID string
	for _, p := range candidates {
		set = append(set, routing.ProviderToCandidateLogEntry(p, scores[p.SortKey()], weights))
		if p.ProviderID == chosen && chosenAssignedID == "" {
			chosenAssignedID = p.AssignedID
		}
	}
	routing.LogRoutingDecision(s.log, routing.Decision{
		RequestID:                   requestID,
		Objective:                   objective,
		CandidateCountBeforeFilters: len(candidates),
		CandidateCountAfterFilters:  len(candidates),
		CandidateSet:                set,
		TiebreakEpsilon:             s.tiebreakEpsilon,
		ChosenProviderID:            chosen,
		ChosenAssignedID:            chosenAssignedID,
		AttemptIndex:                attrs.AttemptIndex,
		RetryCount:                  attrs.RetryCount,
		Retried:                     attrs.Retried,
		RetryReason:                 attrs.RetryReason,
		PreflightResult:             attrs.PreflightResult,
		LegacyReason:                legacyReason,
	})
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

// eligibilityCtx adapts buyer.Server's per-request state to the
// routing.EligibilityChecker interface so routing.EligibleCandidates
// can apply SPEC-002 + SPEC-004 FR-SR-18 composition gates without
// importing buyer-internal types. Phase C step 2 wiring.
type eligibilityCtx struct {
	s               *Server
	model           string
	class           *config.ModelClassConfig
	estimatedTokens int
	tier2Cfg        config.Tier2Config
}

// ProviderMatchesRequest combines the model/class match and the
// SPEC-002 FR-P5 RoutingEligible() state check. The pre-Phase-C
// inline loop combined these two with `||` short-circuit
// (`!matches || !eligible → continue`), so the new helper reports
// either failure as ReasonModelMismatch to preserve byte identity.
func (c *eligibilityCtx) ProviderMatchesRequest(p pool.Provider) bool {
	return c.s.providerMatchesRequest(p, c.model, c.class) && p.RoutingEligible()
}

func (c *eligibilityCtx) ProviderContextSufficient(p pool.Provider) bool {
	return p.MaxContextTokens >= c.estimatedTokens
}

// Tier2Decision mirrors the inline tier2 branch in the pre-Phase-C
// loop: hash status first (mismatch / invalid vs required), then
// encrypted-leg requirement, then attestation requirement. Logging
// side effects (LogHashRequiredProviderExcluded /
// LogEncryptedLegRequiredMissing) are preserved verbatim so the
// audit trail does not regress.
func (c *eligibilityCtx) Tier2Decision(p pool.Provider) (routing.RejectionReason, pool.HashStatus) {
	hashStatus := c.s.effectiveHashStatus(p, c.tier2Cfg)
	if c.s.tier2ProviderExcludedStatus(hashStatus, c.tier2Cfg) {
		if hashStatus == pool.HashStatusMismatch || hashStatus == pool.HashStatusInvalid {
			return routing.ReasonTier2HashMismatch, hashStatus
		}
		if c.tier2Cfg.RequireHashVerified && (hashStatus == pool.HashStatusUncatalogued || hashStatus == pool.HashStatusCatalogUnavailable) {
			tier2.LogHashRequiredProviderExcluded(c.s.log, p.ProviderID, p.AssignedID, p.ModelID, p.ModelHash, hashStatus)
		}
		return routing.ReasonTier2HashRequired, hashStatus
	}
	if c.tier2Cfg.RequireEncryptedLeg && !p.EncryptedLeg {
		tier2.LogEncryptedLegRequiredMissing(c.s.log, p.ProviderID, p.AssignedID, p.ModelID)
		return routing.ReasonTier2EncryptedLeg, hashStatus
	}
	if c.tier2Cfg.RequireAttestation && p.AttestationStatus != pool.AttestationStatusAttested {
		return routing.ReasonTier2Attestation, hashStatus
	}
	return 0, hashStatus
}

func (c *eligibilityCtx) QuotaPermits(p pool.Provider) bool {
	return c.s.checkQuota(p)
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
	case "error_model_not_loaded", "error_context_exceeded", "error_queue_full", "error_internal", "malformed_json_response", "json_schema_validation_failed", "response_byte_cap_exceeded", "provider_timeout":
		return status
	default:
		return ""
	}
}

func isSpec019ProviderDetailCode(code string) bool {
	// AC-V2-3a + AC-V2-9 + AC-V2-9b (SPEC-019 v0.2.4 §5): these
	// four terminal structured-output codes are the canonical table.
	// Asymmetry across provider WS, coordinator SSE, and gateway SSE
	// allow-lists is a money-path violation.
	switch code {
	case "malformed_json_response", "json_schema_validation_failed", "response_byte_cap_exceeded", "provider_timeout":
		return true
	default:
		return false
	}
}

func isSpec019TerminalSSEErrorCode(code string) bool {
	switch code {
	case "malformed_json_response", "json_schema_validation_failed", "response_byte_cap_exceeded", "provider_timeout":
		return true
	default:
		return false
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

// sanitizeExternalRequestID normalizes the inbound X-Request-ID header
// for persistent storage in request_log.external_request_id. SPEC-002
// §11 requires the coordinator to "honor any inbound X-Request-ID";
// this honoring is bounded by defense-in-depth:
//
//   - Trim surrounding whitespace.
//   - Cap at 128 bytes (UUID v4 is 36; allowing for vendor-prefixed
//     ids like "req_<48hex>" gives reasonable headroom without
//     unbounded growth).
//   - Reject control characters byte-by-byte (< 0x20, 0x7f, and the
//     C1 range 0x80-0x9f) so raw control bytes cannot slip past as
//     `utf8.RuneError` under rune iteration. (See SPEC-002 v1.5.1 +
//     issue #197 R1 security: raw 0x9b CSI bytes were bypassing the
//     prior rune-based loop.)
//   - Reject invalid UTF-8 outright; the coordinator stores this in
//     structured logs and SQLite, both of which assume UTF-8.
//
// On failure, returns "" — the coordinator treats the value as if no
// header was present, which is allowed by §11 ("If absent, coordinator
// MAY generate its own UUID v4"). The malformed header is not
// surfaced to the buyer; logging it as-is would replay any
// log-injection payload.
func sanitizeExternalRequestID(value string) string {
	return sanitizeOpaqueHeader(value)
}

// sanitizeAccountID normalizes the inbound X-MacProvider-Account header
// for persistent storage in request_log.account_id (SPEC-002 v1.5.0,
// issue #211). Same defense-in-depth shape as sanitizeExternalRequestID:
// trim, cap at 128 bytes (gateway account ids are "acct_<...>" or
// "demo:<ip>" — both well under 128), reject C0/C1 control characters
// byte-by-byte, reject invalid UTF-8. On failure, returns "" — the
// coordinator treats the value as if no header was present, which is
// allowed by SPEC-002 v1.5.0 ("Absent header MUST be tolerated; the
// column carries NULL in that case").
func sanitizeAccountID(value string) string {
	return sanitizeOpaqueHeader(value)
}

// sanitizeOpaqueHeader is the shared byte-level defense-in-depth filter
// for opaque-sanitized-text headers (X-Request-ID, X-MacProvider-Account).
// SPEC-002 v1.5.1 R-2: 1-128 bytes, valid UTF-8, no control characters
// in C0 (0x00-0x1f), DEL (0x7f), or C1 (0x80-0x9f). Iterating runes is
// NOT sufficient — raw bytes in the C1 range decode to utf8.RuneError
// (U+FFFD) which would pass a rune-only check.
func sanitizeOpaqueHeader(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 128 {
		return ""
	}
	if !utf8.ValidString(value) {
		return ""
	}
	for i := 0; i < len(value); i++ {
		b := value[i]
		if b < 0x20 || b == 0x7f || (b >= 0x80 && b <= 0x9f) {
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
	// SPEC-002 v1.5.1 / issue #197 R2 security: text fields persisted in
	// request_log (error, pref_header, provider_header, model) carry the
	// same log-injection / terminal-CSI risk as the opaque header IDs.
	// Reject invalid UTF-8 outright so raw C1 bytes (e.g. 0x9b) cannot
	// slip through as `utf8.RuneError` (U+FFFD) during rune iteration;
	// after that gate, strip C0/DEL/C1 codepoints via the rune map.
	// (Multi-byte UTF-8 continuation bytes 0x80-0xbf are only "in range"
	// at byte level, but valid UTF-8 sequences resolve to a single
	// codepoint outside C1 — so the rune-level strip is safe AFTER the
	// utf8.ValidString gate.)
	if !utf8.ValidString(value) {
		return ""
	}
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
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

func terminalSSEErrorCodeFromLine(line []byte) string {
	text := strings.TrimSpace(string(line))
	if !strings.HasPrefix(text, "data:") {
		return ""
	}
	payload := strings.TrimSpace(strings.TrimPrefix(text, "data:"))
	if payload == "" || payload == "[DONE]" {
		return ""
	}
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(payload), &envelope); err != nil {
		return ""
	}
	return strings.TrimSpace(envelope.Error.Code)
}

func writeWSEndError(w http.ResponseWriter, end providerws.InferenceResponseEnd) {
	switch end.Status {
	case "error_context_exceeded":
		writeError(w, wsEndHTTPStatus(end.Status), "context_exceeds_capacity", "Request exceeds provider context capacity")
	case "error_model_not_loaded", "error_queue_full":
		writeError(w, wsEndHTTPStatus(end.Status), "no_provider_available", "Selected provider is not reachable")
	case "malformed_json_response", "json_schema_validation_failed":
		writeProviderStructuredOutputError(w, wsEndHTTPStatus(end.Status), end.Status, end.Error, end.Retryable)
	case "cancelled":
		return
	default:
		writeError(w, wsEndHTTPStatus(end.Status), "provider_error", "Selected provider failed; buyer should retry")
	}
}

func writeProviderStructuredOutputError(w http.ResponseWriter, status int, code, message string, retryable *bool) {
	if message == "" {
		message = http.StatusText(status)
	}
	retry := spec018Retryable(code)
	if retryable != nil {
		retry = *retryable
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"message":        message,
			"type":           spec018ErrorType(code, errorType(status)),
			"param":          nil,
			"code":           code,
			"retryable":      retry,
			"request_id":     nil,
			"inference_ran":  true,
			"settlement_ran": true,
		},
	})
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

func writeSSEError(w http.ResponseWriter, message, code string, requestID ...string) {
	id := any(nil)
	if len(requestID) > 0 && strings.TrimSpace(requestID[0]) != "" {
		id = requestID[0]
	}
	settlementRan := code == "malformed_json_response" ||
		code == "json_schema_validation_failed" ||
		code == "provider_timeout" ||
		code == "response_byte_cap_exceeded"
	payload, _ := json.Marshal(map[string]any{
		"error": map[string]any{
			"message":        message,
			"type":           spec018ErrorType(code, "server_error"),
			"param":          nil,
			"code":           code,
			"retryable":      spec018Retryable(code),
			"request_id":     id,
			"inference_ran":  true,
			"settlement_ran": settlementRan,
		},
	})
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(payload)
	_, _ = w.Write([]byte("\n\n"))
	_, _ = w.Write([]byte("data: [DONE]\n\n"))
}

func spec018ErrorType(code, fallback string) string {
	switch code {
	case "request_body_too_large", "tool_result_too_large", "tool_results_aggregate_too_large",
		"tool_call_arguments_too_large", "tool_call_arguments_aggregate_too_large",
		"messages_too_long", "too_many_tool_calls", "invalid_tool_call_id",
		"tool_call_id_not_found", "duplicate_tool_call_id",
		"tool_call_result_out_of_order", "unsupported_modelID_for_multi_turn":
		return "invalid_request_error"
	case "byte_cap_exceeded", "response_byte_cap_exceeded", "malformed_tool_call_final_json":
		return "upstream_provider_error"
	case "malformed_json_response", "json_schema_validation_failed":
		return "upstream_provider_error"
	case "provider_timeout":
		return "api_error"
	case "provider_stream_downgraded":
		return "api_error"
	default:
		return fallback
	}
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
	key := provider.SortKey()
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

func writeErrorWithParam(w http.ResponseWriter, status int, code, message, param string) {
	writeErrorTypedParam(w, status, errorType(status), code, message, param)
}

func writeRouteError(w http.ResponseWriter, err *routeError) {
	if err.typ != "" {
		writeErrorTyped(w, err.status, err.typ, err.code, err.message)
		return
	}
	writeError(w, err.status, err.code, err.message)
}

func writeErrorTyped(w http.ResponseWriter, status int, typ, code, message string) {
	writeErrorTypedParam(w, status, typ, code, message, "")
}

func writeErrorTypedParam(w http.ResponseWriter, status int, typ, code, message, param string) {
	w.Header().Set("Content-Type", "application/json")
	if status == http.StatusTooManyRequests && code == "provisional_quota_exceeded" {
		w.Header().Set("Retry-After", "3600")
	}
	var paramValue any
	if param != "" {
		paramValue = param
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"message":        message,
			"type":           typ,
			"param":          paramValue,
			"code":           code,
			"retryable":      spec018Retryable(code),
			"request_id":     nil,
			"inference_ran":  false,
			"settlement_ran": false,
		},
	})
}

func contentEncodingSupported(values []string) bool {
	if len(values) == 0 {
		return true
	}
	normalized := strings.ToLower(strings.Join(values, ","))
	normalized = strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, normalized)
	return normalized == "identity"
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
