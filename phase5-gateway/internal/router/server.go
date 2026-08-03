package router

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"expvar"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

var unauthenticatedInternalProbes = expvar.NewInt("unauthenticated_internal_probes_total")

type Server struct {
	cfg     config.Config
	cfgPath string
	store   Store
	// readOnlyStore, when non-nil, backs GET-only handlers (explorer +
	// /v1/usage). M2-4 / PERF-4: the primary `store` is capped at
	// MaxOpenConns=1 to serialize BEGIN IMMEDIATE writes; a slow explorer
	// query on the same handle blocks ReserveQuota on the money path.
	// Routing reads through a second handle (opened by main.go via
	// sqlite.OpenReadOnly with conn cap 4) lets SQLite WAL's concurrent-
	// reader semantics absorb explorer load without touching the write
	// path. When nil, handlers fall back to `store`.
	//
	// Typed as ReadStore (the narrow read-only view), so a write method
	// invoked via readStore() is a COMPILE error, not a runtime mode=ro
	// driver error. The DSN-level mode=ro+query_only(1) guard in
	// internal/storage/sqlite stays as defense in depth.
	readOnlyStore    ReadStore
	keyMgr           auth.KeyManager
	demoMgr          auth.DemoManager
	oauth            auth.OAuthProvider
	now              func() time.Time
	client           *http.Client
	trustedProxyNets []*net.IPNet
	version          string
	mu               sync.RWMutex
	poolz            statusCache
	// routingMeta is a small TTL cache for /internal/routing probes. Without
	// it, every sticky-eligible chat-completion AND every /v1/models request
	// fires a coordinator roundtrip (the SPEC-004 audit's HIGH perf finding).
	// 5s TTL — coordinator config only changes on reload, so staleness is
	// harmless; cap on bursts.
	routingMeta     routingMetaCache
	retry503Metrics *retry503Metrics
	adminMetrics    *adminStateWriteMetrics
	chatStartLimits *requestRateLimiter
	// idlessDedupe backs the #762 id-less retry replay/coalesce cache. It is
	// per-process and non-authoritative; see idless_dedupe.go.
	idlessDedupe *idlessDedupeIndex
	// journal is the durable settlement journal (#763). Never nil — New
	// installs a discard implementation when cmd/gateway did not register a
	// real one — so the money path can call it unguarded.
	journal SettlementJournal
	// journalAttempts bounds conflicted re-drives before quarantine.
	journalAttempts *settlementJournalAttempts
}

// readStore returns the read-only view of the database. M2-4: this
// is the canonical invariant location for "GET-only handlers MUST NOT
// write" — it returns a ReadStore, so any attempt to call a write
// method through it is a compile error. When no separate handle is
// registered (tests, -check) we fall back to the primary Store, which
// trivially implements ReadStore because Store embeds every sub-
// interface ReadStore lists.
func (s *Server) readStore() ReadStore {
	if s.readOnlyStore != nil {
		return s.readOnlyStore
	}
	return s.store
}

type Store interface {
	storage.AuthStore
	storage.UsageStore
	storage.AuditStore
	storage.FeedbackStore
	storage.CapacityStore
	storage.HealthStore
	storage.ExplorerStore
}

// ReadStore is the narrow, write-free view of the gateway database used
// by GET-only handlers (explorer + /v1/usage). M2-4 / PERF-4: the
// router routes reads through ReadStore so a future handler can't
// accidentally call ReserveQuota / SettleReservation / SetCapacityTier
// through readStore() — that's a compile error. Bound by what
// router/explorer.go and the /v1/usage path actually call.
type ReadStore interface {
	storage.ExplorerStore
	DailyUsage(ctx context.Context, accountID, windowDate string) (int64, int64, error)
	ListAPIKeys(ctx context.Context, accountID string) ([]storage.APIKeySummary, error)
	GetCapacityTier(ctx context.Context) (storage.CapacityTier, error)
}

type Option func(*Server)

type statusCache struct {
	checkedAt time.Time
	body      statusResponse
}

func WithNow(fn func() time.Time) Option {
	return func(s *Server) {
		s.now = fn
	}
}

func WithHTTPClient(client *http.Client) Option {
	return func(s *Server) {
		if client != nil {
			s.client = client
		}
	}
}

func WithConfigPath(path string) Option {
	return func(s *Server) {
		s.cfgPath = path
	}
}

func WithVersion(v string) Option {
	return func(s *Server) {
		if v != "" {
			s.version = v
		}
	}
}

// WithReadStore registers a separate read-only handle for GET-only
// handlers. The argument is typed as ReadStore (the narrow,
// write-free interface) so callers can pass any read-only
// implementation; a *sqlite.Store opened via OpenReadOnly satisfies
// it. See Server.readOnlyStore doc for the why (M2-4 / PERF-4).
func WithReadStore(store ReadStore) Option {
	return func(s *Server) {
		if store != nil {
			s.readOnlyStore = store
		}
	}
}

func New(cfg config.Config, store Store, oauth auth.OAuthProvider, opts ...Option) *Server {
	trustedProxyNets, err := cfg.TrustedProxyNets()
	if err != nil {
		trustedProxyNets = nil
	}
	s := &Server{
		cfg:              cfg,
		store:            store,
		keyMgr:           auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret),
		demoMgr:          auth.NewDemoManager(cfg.Auth.Demo.SigningSecret),
		oauth:            oauth,
		now:              func() time.Time { return time.Now().UTC() },
		client:           http.DefaultClient,
		trustedProxyNets: trustedProxyNets,
		version:          "dev",
		retry503Metrics:  newRetry503Metrics(),
		adminMetrics:     newAdminStateWriteMetrics(),
		chatStartLimits:  newRequestRateLimiter(),
		idlessDedupe:     newIdlessDedupeIndex(),
		journal:          discardSettlementJournal{},
		journalAttempts:  newSettlementJournalAttempts(),
	}
	for _, opt := range opts {
		opt(s)
	}
	s.loadRuntimeKillSwitch(context.Background())
	return s
}

func (s *Server) loadRuntimeKillSwitch(ctx context.Context) {
	state, err := s.store.GetKillSwitch(ctx)
	if err != nil {
		slog.Warn("runtime kill switch load failed", "error", err)
		return
	}
	if state.UpdatedAt.IsZero() {
		return
	}
	s.cfg.KillSwitch.DemoOnly = state.DemoOnly
	s.cfg.KillSwitch.AllPublicAPI = state.AllPublicAPI
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	if s.cfg.Auth.GitHubOAuthEnabled {
		mux.HandleFunc("/auth/github/start", s.handleGitHubStart)
		mux.HandleFunc("/auth/github/callback", s.handleGitHubCallback)
	}
	mux.Handle("/auth/handoff/exchange", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleHandoffExchange)))
	mux.Handle("/auth/demo-session", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleDemoSession)))
	mux.HandleFunc("/auth/api-keys", s.handleAPIKeys)
	mux.HandleFunc("/auth/api-keys/", s.handleAPIKeyAction)
	mux.HandleFunc("/account", s.handleAccount)
	mux.HandleFunc("/docs", s.handleDocs)
	mux.Handle("/v1/models", s.withCORS(http.MethodGet, http.HandlerFunc(s.handleModels)))
	mux.HandleFunc("/v1/usage", s.handleUsage)
	mux.Handle("/v1/chat/completions", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleChatCompletions)))
	if s.cfg.Features.ResponsesAPIEnabled {
		mux.Handle("/v1/responses", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleResponses)))
	}
	if s.cfg.Features.AnthropicMessagesEnabled {
		mux.Handle("/v1/messages", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleAnthropicMessages)))
	}
	mux.Handle("/v1/sticky", s.withCORS(http.MethodDelete, http.HandlerFunc(s.handleStickyDelete)))
	mux.Handle("/v1/status", s.withCORS(http.MethodGet, http.HandlerFunc(s.handleStatus)))
	mux.HandleFunc("/v1/feedback", s.handleFeedback)
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/admin/feedback-summary", s.handleFeedbackSummary)
	mux.HandleFunc("/admin/kill-switch", s.handleKillSwitch)
	mux.HandleFunc("/admin/capacity-signal", s.handleCapacitySignal)
	mux.HandleFunc("/admin/capacity-tier/evaluate", s.handleCapacityEvaluate)
	mux.HandleFunc("/admin/settlement/reconcile", s.handleSettlementReconcile)
	if s.cfg.Explorer.Enabled {
		mux.HandleFunc("/admin/explorer/buyers", s.handleExplorerBuyers)
		mux.HandleFunc("/admin/explorer/buyers/", s.handleExplorerBuyerDetail)
		mux.HandleFunc("/admin/explorer/sessions", s.handleExplorerSessions)
		mux.HandleFunc("/admin/explorer/sessions/", s.handleExplorerSessionDetail)
		mux.HandleFunc("/admin/explorer/activity", s.handleExplorerActivity)
		mux.HandleFunc("/admin/explorer/health", s.handleExplorerHealth)
	}
	mux.HandleFunc("/", s.handleNotFound)
	return s.middleware(mux)
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(s.retry503Metrics.prometheus()))
	_, _ = w.Write([]byte(s.adminMetrics.prometheus()))
	_, _ = w.Write([]byte(s.idlessDedupe.prometheus()))
	_, _ = w.Write([]byte(s.journal.MetricsSnapshot().Prometheus()))
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.Header.Get("X-Request-ID")
		requestIDClass := retry503RequestIDClassClientSupplied
		if !isUUIDLike(requestID) {
			requestID = newUUID()
			requestIDClass = retry503RequestIDClassGatewayGenerated
		}
		if stripped := stripInternalMacProviderHeaders(r.Header); len(stripped) > 0 {
			slog.Warn("internal header injection stripped", "request_id", requestID, "headers", stripped)
			if s.shouldPersistInternalHeaderAudit(r) {
				_ = s.store.InsertAuditEvent(context.Background(), storage.AuditEvent{
					EventID: mustID("audit"), RequestID: requestID, Actor: "public_ingress", Type: "internal_header_injection_stripped",
					Payload: fmt.Sprintf(`{"headers":%q}`, strings.Join(stripped, ",")), CreatedAt: s.now(),
				})
			} else {
				unauthenticatedInternalProbes.Add(1)
			}
		}
		w.Header().Set("X-Request-ID", requestID)
		if s.publicPaused(r.URL.Path) {
			if r.URL.Path == "/v1/messages" && s.cfg.Features.AnthropicMessagesEnabled {
				writeAnthropicMessagesError(w, http.StatusServiceUnavailable, "server_error", "public_api_paused", "Mac Provider beta is paused while capacity catches up. Please retry later.")
				return
			}
			writeError(w, http.StatusServiceUnavailable, "server_error", "public_api_paused", "Mac Provider beta is paused while capacity catches up. Please retry later.")
			return
		}
		ctx := context.WithValue(r.Context(), requestIDKey{}, requestID)
		ctx = context.WithValue(ctx, requestIDClassKey{}, requestIDClass)
		defer func() {
			if recovered := recover(); recovered != nil {
				slog.Error("panic recovered", "panic", recovered, "request_id", requestID, "path", r.URL.Path, "stack", string(debug.Stack()))
				if r.URL.Path == "/v1/messages" && s.cfg.Features.AnthropicMessagesEnabled {
					writeAnthropicMessagesError(w, http.StatusInternalServerError, "server_error", "internal_error", "Internal server error")
					return
				}
				writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Internal server error")
			}
		}()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if _, ok := s.authenticateAny(w, r); !ok {
		return
	}
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodGet, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/models", nil)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	// SPEC-006 v0.X R-G3 / SPEC-002 v1.4.2 R-2: gateway forwards the
	// buyer-visible request id verbatim so the coordinator's
	// request_log.external_request_id matches the gateway's
	// usage_events.request_id on a per-request basis.
	upReq.Header.Set("X-Request-ID", requestID(r))
	resp, err := s.client.Do(upReq)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_models_error", "Coordinator models error")
		return
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_models_error", "Coordinator models error")
		return
	}
	disclosure, ok := s.tier1DisclosureForModels(body, r.Context())
	if !ok {
		writeError(w, http.StatusBadGateway, "api_error", "tier2_metadata_unavailable", "Coordinator Tier-2 metadata unavailable")
		return
	}
	body["tier1_disclosure"] = disclosure
	copyCleanHeaders(w.Header(), resp.Header)
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// HEAD returns the same status/headers as GET with no body (Go's server
	// discards the body for HEAD), so probes using curl -I / k8s / UptimeRobot
	// are not rejected with 405.
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "unavailable", "version": s.version})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "version": s.version})
}

func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
}

func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	window := s.now().UTC().Format("2006-01-02")
	// M2-4 / PERF-4: /v1/usage is a GET-only handler — read through
	// the separate read-only handle so a hot explorer query can't
	// stall a buyer-facing usage lookup.
	used, reserved, err := s.readStore().DailyUsage(r.Context(), validation.AccountID, window)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "usage_load_failed", "Could not load usage")
		return
	}
	keys, err := s.readStore().ListAPIKeys(r.Context(), validation.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "keys_load_failed", "Could not load API keys")
		return
	}
	limit := s.effectiveAccountDailyQuota(r.Context())
	remaining := limit - used - reserved
	if remaining < 0 {
		remaining = 0
	}
	setRateLimitHeaders(w, limit, remaining, resetUnix(window))
	tier, _ := s.readStore().GetCapacityTier(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"account_id": validation.AccountID,
		"quota": map[string]any{
			"window_date": window, "daily_tokens_used": used, "daily_tokens_reserved": reserved,
			"daily_tokens_remaining": remaining, "daily_tokens_limit": limit,
		},
		"settlement_disclosure": makeVerifiedModelSettlementDisclosure(s.cfg.Features.ResponsesAPIEnabled, s.cfg.Features.AnthropicMessagesEnabled),
		"capacity":              map[string]any{"tier": tier.Tier},
		"keys":                  keys,
		"models":                []any{},
		"rating":                nil,
	})
}

func (s *Server) handleStickyDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	authn, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	accountID := authn.AccountID
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodDelete, strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")+"/internal/sticky?account_id="+url.QueryEscape(accountID), nil)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	// SPEC-006 v0.X R-G3: gateway forwards the buyer-visible request id
	// on every forwarded buyer-facing coordinator call. /v1/sticky is
	// request-scoped audit-diagnostic surface, not a usage-event path,
	// so the join target here is gateway audit_events.request_id ↔
	// coordinator audit_events / request_log diagnostics — NOT the
	// gateway usage_events join used by /v1/chat/completions.
	upReq.Header.Set("X-Request-ID", requestID(r))
	// M3-2 / SECU-4 post-cutover: /internal/sticky uses the
	// service-token-only upstream bearer.
	upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	resp, err := s.client.Do(upReq)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_sticky_error", "Coordinator sticky purge error")
		return
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_sticky_error", "Coordinator sticky purge error")
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	resp, err := s.statusFromPoolz(r.Context())
	if err != nil {
		writeJSON(w, http.StatusOK, statusResponse{
			Status: "down", Degraded: false,
			Coordinator: coordinatorStatus{Status: "down", CheckedAt: s.now().Format(time.RFC3339)},
		})
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleFeedback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !validFeedbackSource(r.Header.Get("X-Feedback-Source")) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_feedback_source", "feedback source is required")
		return
	}
	ip := s.clientIP(r)
	now := s.now()
	var req struct {
		Rating    int    `json:"rating"`
		Comment   string `json:"comment"`
		RequestID string `json:"request_id"`
		Scope     string `json:"scope"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, s.cfg.Limits.MaxFeedbackBodyBytes)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_feedback", "Invalid feedback")
		return
	}
	if req.Rating < 1 || req.Rating > 4 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_rating", "rating must be 1 through 4")
		return
	}
	if len([]byte(req.Comment)) > s.cfg.Limits.MaxFeedbackCommentBytes {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "comment_too_long", "comment too long")
		return
	}
	if req.RequestID != "" && !safeID(req.RequestID) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_id", "request_id is invalid")
		return
	}
	if req.Scope == "" {
		if req.RequestID != "" {
			req.Scope = "request"
		} else {
			req.Scope = "account"
		}
	}
	if !validFeedbackScope(req.Scope) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_feedback_scope", "scope is invalid")
		return
	}
	accountID := ""
	if req.Scope == "playground" {
		if s.demoPaused() {
			writeError(w, http.StatusServiceUnavailable, "server_error", "demo_paused", "Demo is temporarily paused")
			return
		}
		token := r.Header.Get("X-Demo-Token")
		payload, err := s.demoMgr.Validate(token, s.clientIP(r), s.now())
		if err != nil {
			writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_demo_token", "Invalid demo token")
			return
		}
		accountID = "demo:" + payload.IP
	} else {
		validation, ok := s.requireBearer(w, r)
		if !ok {
			return
		}
		accountID = validation.AccountID
	}
	if err := s.store.ReservePublicIssuance(r.Context(), storage.PublicIssuanceReservation{
		Surface: "feedback", ClientIP: ip, WindowStart: now.Add(-time.Hour), Limit: s.cfg.Limits.FeedbackRequestsPerIPPerHour, CreatedAt: now,
	}); err != nil {
		if errors.Is(err, storage.ErrRateLimit) {
			writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "feedback_rate_limited", "Feedback rate limit exceeded")
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "feedback_limit_check_failed", "Could not check feedback limit")
		return
	}
	event := storage.FeedbackEvent{
		EventID: mustID("fb"), RequestID: req.RequestID, AccountID: accountID, Scope: req.Scope,
		Rating: req.Rating, Comment: req.Comment, CreatedAt: now,
	}
	if err := s.store.InsertFeedbackEvent(r.Context(), event); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "feedback_store_failed", "Could not store feedback")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "feedback_id": event.EventID, "received_at": now.Format(time.RFC3339)})
}

type statusResponse struct {
	Status      string            `json:"status"`
	Degraded    bool              `json:"degraded"`
	Coordinator coordinatorStatus `json:"coordinator"`
	Pool        statusPool        `json:"pool"`
	Models      []statusModel     `json:"models"`
}

type coordinatorStatus struct {
	Status    string `json:"status"`
	CheckedAt string `json:"checked_at"`
}

type statusPool struct {
	TotalProviders int `json:"total_providers"`
	Ready          int `json:"ready"`
	Degraded       int `json:"degraded"`
	Draining       int `json:"draining"`
	Unavailable    int `json:"unavailable"`
}

type statusModel struct {
	ID                 string `json:"id"`
	ProviderCount      int    `json:"provider_count"`
	ReadyProviderCount int    `json:"ready_provider_count"`
	TotalSlots         int    `json:"total_slots"`
	SlotsFree          int    `json:"slots_free"`
	MaxContextTokens   int    `json:"max_context_tokens"`
	Degraded           bool   `json:"degraded"`
	Available          bool   `json:"available"`
	Availability       string `json:"availability"`
	// SPEC-002 v1.3.5 §7.4 R-7.4.1 / SPEC-010 v1.5 R-3.3.3 — per
	// SPEC-006 v0.8.1 §5.6 anonymization, the buyer-facing
	// /v1/status surfaces supported_models as a per-model UNION
	// across providers serving this model_id whose
	// PublishesSupportedModels == true (NOT per-provider entries,
	// which would leak provider count fingerprints). The field is
	// OMITTED when the union is empty.
	SupportedModels []string `json:"supported_models,omitempty"`
}

// authStateBearerlessDuplicate is the wire value the coordinator emits for
// SPEC-003 v0.8.3 FR-C9.4 bearer-less duplicate sessions on /poolz. The
// authoritative const lives at phase4-coordinator/internal/pool/provider.go
// `AuthBearerlessDuplicate`; the gateway cannot import that package, so the
// value is mirrored here as a string literal. SPEC-002 v1.4.1 is the
// normative contract — if these ever drift, fix SPEC-002 first.
const authStateBearerlessDuplicate = "bearerless_duplicate"

// Non-routable auth_state values mirrored from pool.Provider.RoutingEligible().
// Used when /poolz rows omit routing_eligible (pre-upgrade coordinators).
const (
	authStateSelfMinted = "self_minted"
	authStateMintFailed = "mint_failed"
)

type poolzProviderRow struct {
	ProviderID               string   `json:"provider_id"`
	AssignedID               string   `json:"assigned_id"`
	EndpointURL              string   `json:"endpoint_url"`
	Hostname                 string   `json:"hostname"`
	ModelID                  string   `json:"model_id"`
	State                    string   `json:"state"`
	SlotsFree                int      `json:"slots_free"`
	SlotsTotal               int      `json:"slots_total"`
	MaxContextTokens         int      `json:"max_context_tokens"`
	MemoryBytes              int64    `json:"memory_bytes"`
	CPUCount                 int      `json:"cpu_count"`
	OperatorIdentity         string   `json:"operator_identity"`
	SupportedModels          []string `json:"supported_models,omitempty"`
	PublishesSupportedModels bool     `json:"publishes_supported_models,omitempty"`
	// routing_eligible is coordinator-computed from pool.Provider.RoutingEligible().
	// Omitted on legacy coordinators — gateway falls back to auth_state exclusion.
	RoutingEligible *bool  `json:"routing_eligible,omitempty"`
	AuthState       string `json:"auth_state,omitempty"`
}

type poolzResponse struct {
	Pool    []poolzProviderRow `json:"pool"`
	Summary struct {
		TotalProviders int `json:"total_providers"`
		Ready          int `json:"ready"`
		TotalSlots     int `json:"total_slots"`
		FreeSlots      int `json:"free_slots"`
	} `json:"summary"`
}

func (s *Server) statusFromPoolz(ctx context.Context) (statusResponse, error) {
	s.mu.RLock()
	if !s.poolz.checkedAt.IsZero() && s.now().Sub(s.poolz.checkedAt) < 10*time.Second {
		cached := s.poolz.body
		s.mu.RUnlock()
		return cached, nil
	}
	s.mu.RUnlock()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")+"/poolz", nil)
	if err != nil {
		return statusResponse{}, err
	}
	// /poolz is OPERATOR-ONLY on the coordinator (OperatorOnlyBearerMatches):
	// it rejects the service_token. Unlike the /internal/* upstream calls,
	// this poll must send OperatorKey directly, NOT UpstreamCoordinatorBearer()
	// (which prefers ServiceToken once the M3-2 cutover sets it). Validate
	// guarantees OperatorKey is non-empty.
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.OperatorKey)
	resp, err := s.client.Do(req)
	if err != nil {
		s.flushStatusCache()
		return statusResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		s.flushStatusCache()
		return statusResponse{}, fmt.Errorf("poolz status %d", resp.StatusCode)
	}
	var poolz poolzResponse
	if err := json.NewDecoder(resp.Body).Decode(&poolz); err != nil {
		s.flushStatusCache()
		return statusResponse{}, err
	}
	out := aggregateStatus(poolz, s.cfg.Capacity.ReadyProviderDegradedThreshold, s.now())
	s.mu.Lock()
	s.poolz = statusCache{checkedAt: s.now(), body: out}
	s.mu.Unlock()
	return out, nil
}

func (s *Server) coordinatorBuyerURL() string {
	return s.cfg.Coordinator.BuyerURL
}

func (s *Server) flushStatusCache() {
	s.mu.Lock()
	s.poolz = statusCache{}
	s.mu.Unlock()
}

func aggregateStatus(poolz poolzResponse, readyThreshold int, now time.Time) statusResponse {
	models := map[string]statusModel{}
	stats := map[string]poolzModelStats{}
	supportedSets := map[string]map[string]struct{}{}
	out := statusResponse{
		Status:      "up",
		Coordinator: coordinatorStatus{Status: "up", CheckedAt: now.Format(time.RFC3339)},
	}
	for _, p := range poolz.Pool {
		// SPEC-003 v0.8.3 FR-C9.4 + pool.Provider.RoutingEligible() — sessions
		// admitted to /poolz for operator visibility but excluded from buyer
		// routing (self_minted, bearerless_duplicate, pending receipt rotation,
		// etc.) MUST NOT contribute to buyer-facing capacity counts.
		if !poolzProviderCountsTowardBuyerCapacity(p) {
			continue
		}
		out.Pool.TotalProviders++
		switch p.State {
		case "ready":
			out.Pool.Ready++
		case "degraded", "busy":
			out.Pool.Degraded++
		case "draining":
			out.Pool.Draining++
		default:
			out.Pool.Unavailable++
		}
		if p.ModelID == "" {
			continue
		}
		m := models[p.ModelID]
		m.ID = p.ModelID
		m.ProviderCount++
		m.TotalSlots += p.SlotsTotal
		m.SlotsFree += p.SlotsFree
		if p.State == "ready" {
			m.ReadyProviderCount++
		}
		if p.MaxContextTokens > m.MaxContextTokens {
			m.MaxContextTokens = p.MaxContextTokens
		}
		models[p.ModelID] = m
		if p.PublishesSupportedModels && len(p.SupportedModels) > 0 {
			if supportedSets[p.ModelID] == nil {
				supportedSets[p.ModelID] = map[string]struct{}{}
			}
			for _, s := range p.SupportedModels {
				supportedSets[p.ModelID][s] = struct{}{}
			}
		}
		st := stats[p.ModelID]
		st.TotalProviders++
		st.SlotsFreeTotal += p.SlotsFree
		if p.State == "ready" {
			st.Ready++
			st.ReadySlotsFree += p.SlotsFree
		}
		if p.State == "unavailable" || p.State == "draining" {
			st.UnavailableOrDraining++
		}
		stats[p.ModelID] = st
	}
	// SPEC-002 v1.4.1 — the summary fallback only fires when the coordinator
	// omitted the detailed `pool` array entirely (e.g. a redacted/summary-only
	// response). It MUST NOT fire when `pool` rows ARE present but all have
	// been excluded by the non-routable aggregation gate above; otherwise the
	// coordinator's summary (which includes bearerless rows in
	// `total_providers`) would reintroduce excluded capacity on the buyer-
	// facing surface. The condition is on `len(poolz.Pool)`, not on
	// `out.Pool.TotalProviders`, so an all-bearerless pool collapses to no-
	// capacity instead of falling through to the summary.
	if len(poolz.Pool) == 0 && poolz.Summary.TotalProviders > 0 {
		out.Pool.TotalProviders = poolz.Summary.TotalProviders
		out.Pool.Ready = poolz.Summary.Ready
	}
	if out.Pool.Ready == 0 {
		out.Status = "idle"
		out.Degraded = false
	} else if out.Pool.Ready < readyThreshold {
		out.Status = "degraded"
		out.Degraded = true
	}
	for modelID, set := range supportedSets {
		if len(set) == 0 {
			continue
		}
		m := models[modelID]
		m.SupportedModels = sortedKeys(set)
		models[modelID] = m
	}
	for _, model := range models {
		model.Degraded = computeDegraded(stats[model.ID])
		model.Available, model.Availability = computeAvailability(stats[model.ID])
		out.Models = append(out.Models, model)
	}
	sort.Slice(out.Models, func(i, j int) bool { return out.Models[i].ID < out.Models[j].ID })
	return out
}

// poolzProviderCountsTowardBuyerCapacity mirrors pool.Provider.RoutingEligible()
// for buyer-facing /v1/status aggregation.
func poolzProviderCountsTowardBuyerCapacity(p poolzProviderRow) bool {
	if p.RoutingEligible != nil {
		return *p.RoutingEligible
	}
	switch p.AuthState {
	case authStateBearerlessDuplicate, authStateSelfMinted, authStateMintFailed:
		return false
	default:
		return true
	}
}

type poolzModelStats struct {
	TotalProviders        int
	UnavailableOrDraining int
	Ready                 int
	SlotsFreeTotal        int
	ReadySlotsFree        int
}

func computeDegraded(modelStats poolzModelStats) bool {
	if modelStats.TotalProviders == 0 {
		return true
	}
	if modelStats.UnavailableOrDraining == modelStats.TotalProviders {
		return true
	}
	if (2 * modelStats.Ready) < modelStats.TotalProviders {
		return true
	}
	if modelStats.SlotsFreeTotal == 0 {
		return true
	}
	return false
}

func computeAvailability(modelStats poolzModelStats) (bool, string) {
	if modelStats.Ready == 0 {
		return false, "no_awake_provider"
	}
	if modelStats.ReadySlotsFree == 0 {
		return false, "no_free_slots"
	}
	return true, "available"
}

func sortedKeys(set map[string]struct{}) []string {
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func validFeedbackScope(scope string) bool {
	return scope == "request" || scope == "session" || scope == "account" || scope == "playground"
}

func validFeedbackSource(source string) bool {
	source = strings.TrimSpace(source)
	if source == "" || len(source) > 64 {
		return false
	}
	for _, r := range source {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' || r == '.' {
			continue
		}
		return false
	}
	return true
}

func safeID(v string) bool {
	if len(v) > 128 {
		return false
	}
	for _, ch := range v {
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' {
			continue
		}
		return false
	}
	return true
}

type requestIDKey struct{}

func requestID(r *http.Request) string {
	if v, ok := r.Context().Value(requestIDKey{}).(string); ok {
		return v
	}
	return newUUID()
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// gatewayRetryableByCode mirrors phase4-coordinator/internal/buyer/server.go's
// spec018RetryableByCode (SPEC-006 §5.2). The coordinator and gateway are
// separate Go modules with no shared package, so this table is intentionally
// duplicated rather than imported — keep both in sync when a new buyer-
// visible transient/availability code is introduced on either service. A
// code absent from this table defaults to Go's zero value (false) via
// gatewayRetryable, which is the correct default for the gateway's many
// permanent/client codes (auth, validation, admin, oauth, quota-shape).
//
// Round-2 3-lane re-audit rule (H-R2/M-R2-2/M-R2-3): retryable, any
// Retry-After/reset header the same path sets, and the human message
// wording must all agree for every code — a positive Retry-After or
// "retry later"/"temporarily" wording means the code MUST be true.
// TestGatewayErrorCodeCompleteness enforces every code literal the error
// writers can emit is accounted for here or in gatewayPermanentCodes, so a
// future unclassified code fails a test instead of shipping a silent
// false-default contradiction (closes L-R2-2).
//
// The coordinator-owned codes below (no_provider_available through
// rate_limited) are included even though the gateway only ever reaches them
// via coordinatorErrorRetryable's fallback (openAIErrorRetryable already
// preserves the coordinator's own verdict when the forwarded body carries
// one) — that fallback only fires on a malformed/legacy body, and it must
// not silently reintroduce finding H2 by defaulting a transient code to
// false just because it took the fallback path.
var gatewayRetryableByCode = map[string]bool{
	// Transient availability/timeout — the buyer should retry (SPEC-006 §5.2).
	"no_provider_available":      true,
	"provider_error":             true,
	"provider_timeout":           true,
	"provider_disconnected":      true,
	"provider_failed":            true,
	"provisional_quota_exceeded": true,
	"preflight_rejected":         true,
	"idempotency_unavailable":    true,
	"rate_limited":               true,
	// Gateway-generated transient/availability codes (no coordinator-body
	// equivalent — the gateway itself constructs these envelopes).
	"coordinator_unavailable":   true,
	"upstream_provider_error":   true,
	"invalid_provider_usage":    true,
	"invalid_provider_response": true,
	// rate_limit_exceeded-typed 429s that actually ship a backoff signal
	// (Retry-After via setConcurrencyRateLimitHeaders, or X-RateLimit-Reset
	// via setRateLimitHeaders) — H-R2. (signup_rate_limited was the one
	// rate_limit_exceeded code left true only because the round-3 revert
	// didn't name it; runbook item 20 reverted it to false alongside its
	// three siblings — see gatewayPermanentCodes.)
	"account_request_rate_exceeded": true,
	"account_concurrency_exceeded":  true,
	"demo_concurrency_exceeded":     true,
	"quota_exhausted":               true,
	// Operator-controlled capacity pauses (M-R2-3 + sweep): the wording on
	// all three ("paused"/"closed ... while capacity catches up") already
	// promises the buyer this resolves with time; the code must agree.
	"public_api_paused":      true,
	"demo_paused":            true,
	"capacity_signup_closed": true,
}

// gatewayPermanentCodes is the explicit "yes, false is correct" allow-list
// for TestGatewayErrorCodeCompleteness: every other code literal the error
// writers can emit (auth, validation, admin, oauth signup/account flows,
// resource-not-found, cap/shape violations) that is genuinely not
// retryable — retrying the identical request cannot succeed. Codes absent
// from BOTH this set and gatewayRetryableByCode fail that test, so a new
// code must be explicitly triaged into one set or the other rather than
// silently defaulting to false.
var gatewayPermanentCodes = map[string]bool{
	"method_not_allowed": true, "invalid_window": true, "invalid_kill_switch": true,
	"invalid_kill_switch_version": true, "invalid_capacity_signal": true,
	"invalid_operator_token": true, "invalid_demo_token": true, "missing_bearer_token": true,
	"invalid_api_key": true, "api_key_revoked": true, "account_blocked": true,
	"not_found": true, "session_id_untyped": true, "query_timeout": true,
	"oauth_callback_not_allowed": true, "oauth_action_unknown": true,
	"oauth_return_to_not_allowed": true, "oauth_state_invalid": true,
	"oauth_scope_forbidden": true, "invalid_handoff": true, "api_key_not_found": true,
	"invalid_request_body": true, "request_too_large": true, "invalid_request": true,
	"n_must_be_1": true, "max_tokens_exceeded": true, "token_limit_overflow": true,
	"duplicate_request_id": true, "invalid_conversation_tag": true,
	"invalid_feedback_source": true, "invalid_feedback": true, "invalid_rating": true,
	"comment_too_long": true, "invalid_request_id": true, "invalid_feedback_scope": true,
	"invalid_limit": true, "api_key_lookup_failed": true,
	"request_content_encoding_unsupported": true,
	"unsupported_content_shape":            true,
	// Round-3 SECURITY MEDIUM revert: round-2 classified these three true
	// as part of the rate_limit_exceeded family, but unlike
	// account_request_rate_exceeded/account_concurrency_exceeded/
	// demo_concurrency_exceeded/quota_exhausted, none of these three ships
	// a Retry-After or reset header, AND none sits behind the 30-RPS
	// account-level rate clamp (chatStartLimits) the way /v1/chat/completions
	// does — so retryable:true here would tell a conforming SDK to
	// auto-retry a 429 with zero backoff against an endpoint with no other
	// throttle, a DoS-amplification risk. Reverted to false.
	"feedback_rate_limited": true, "oauth_state_rate_limited": true,
	"demo_session_rate_limited": true,
	// Runbook item 20 (deferred from #548 r4 audit): signup_rate_limited is
	// the same shape — a per-IP-per-day signup cap (oauth.go
	// createSignupAccount, SignupAccountsPerIPPerDay over a 24h window)
	// emitted with no Retry-After header and outside the chat-path rate
	// clamp. #548 left it true only because the round-3 revert didn't name
	// it. Retrying the identical signup within the 24h window cannot
	// succeed, so zero-backoff SDK auto-retry is pure DoS amplification.
	"signup_rate_limited": true,
	// Internal-fault codes: absent Retry-After/reset header and no
	// "retry later" wording, so the sweep's rule doesn't require true —
	// these are ambiguous store/settlement faults, not availability
	// signals, and reclassifying them is out of this sweep's scope.
	"settlement_failed": true, "admin_state_write_failed": true,
	"feedback_summary_failed": true, "capacity_signal_store_failed": true,
	"capacity_tier_load_failed": true, "capacity_signal_load_failed": true,
	"state_generation_failed": true, "session_generation_failed": true,
	"oauth_state_store_failed": true, "oauth_exchange_failed": true,
	"api_key_issuance_failed": true, "account_lookup_failed": true,
	"signup_limit_check_failed": true, "account_create_failed": true,
	"identity_create_failed": true, "signup_event_failed": true,
	"demo_session_check_failed": true, "demo_token_issuance_failed": true,
	"demo_session_record_failed": true, "api_key_rotation_failed": true,
	"api_key_revoke_failed": true, "internal_error": true,
	"coordinator_models_error": true, "tier2_metadata_unavailable": true,
	"usage_load_failed": true, "keys_load_failed": true,
	"coordinator_sticky_error": true, "feedback_limit_check_failed": true,
	"feedback_store_failed": true, "settlement_reconcile_load_failed": true,
	"nonce_unavailable": true, "docs_missing": true, "docs_render_failed": true,
	"quota_reservation_failed": true, "concurrency_reservation_failed": true,
	// Gateway-side stream/cap-shape codes (mirrors the coordinator's own
	// byte/schema cap family, all false): retrying the same request/prompt
	// deterministically re-triggers the same cap, so these are permanent
	// from the buyer's perspective even though the underlying cause is a
	// provider response.
	"stream_malformed": true, "stream_output_exceeded": true, "stream_truncated": true,
}

func gatewayRetryable(code string) bool {
	return gatewayRetryableByCode[code]
}

// gatewayRetryAfterByCode holds a fixed Retry-After value (seconds, as a
// header string) for specific codes whose backoff window is a known
// constant that must be preserved or set explicitly, distinct from the
// generic 1s fast-availability default:
//   - provisional_quota_exceeded mirrors the coordinator's own fixed 3600s
//     window (phase4-coordinator/internal/buyer/server.go's
//     writeErrorTypedParam). copyCleanHeaders strips the coordinator's own
//     Retry-After as gateway-owned (issue #190) before this runs, so
//     without this table the buyer would see retryable:true with zero
//     backoff hint (M-R2-2) even though the coordinator already computed
//     the right value.
//   - the capacity-pause codes use a longer, human-pause-appropriate
//     window (M-R2-3) — 1s is right for a fast transient blip, wrong for
//     an operator-toggled pause that won't resolve for many seconds.
var gatewayRetryAfterByCode = map[string]string{
	"provisional_quota_exceeded": "3600",
	"public_api_paused":          "30",
	"demo_paused":                "30",
	"capacity_signup_closed":     "30",
}

// gatewayTransientRetryAfterSeconds is a modest, bounded backoff hint the
// gateway attaches to its own retryable 503/504 responses so conforming
// buyer SDKs back off instead of hot-looping a degraded coordinator (see
// the 2026-07-10 single-provider-pool empty-pool outage). This mirrors the
// "Retry-After: 1" convention the coordinator already uses on its own
// rate-limited Tier-2 disclosure endpoints. copyCleanHeadersWithReceipt
// already strips any upstream Retry-After as gateway-owned (issue #190);
// this supplies the gateway's own value rather than leaving it absent.
const gatewayTransientRetryAfterSeconds = "1"

// setGatewayRetryAfter sets Retry-After when retryable, preferring a
// code-specific fixed value (gatewayRetryAfterByCode) over the generic
// 503/504 fast-availability default. Codes with their own request-specific
// Retry-After (the concurrency/rate-limit family — setConcurrencyRateLimitHeaders/
// setRateLimitHeaders, called by the handler before writeError) are 429s,
// which this generic 503/504 gate never touches, so their existing header
// is left alone either way.
func setGatewayRetryAfter(w http.ResponseWriter, status int, code string, retryable bool) {
	if !retryable {
		return
	}
	if v, ok := gatewayRetryAfterByCode[code]; ok {
		w.Header().Set("Retry-After", v)
		return
	}
	if status == http.StatusServiceUnavailable || status == http.StatusGatewayTimeout {
		w.Header().Set("Retry-After", gatewayTransientRetryAfterSeconds)
	}
}

func writeError(w http.ResponseWriter, status int, typ, code, message string) {
	retryable := gatewayRetryable(code)
	setGatewayRetryAfter(w, status, code, retryable)
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": message, "type": typ, "param": nil, "code": code, "retryable": retryable}})
}

func writeSpec019PreflightError(w http.ResponseWriter, status int, code, message, param string) {
	// Retryable is derived from the same classifier writeError/writeSSEError
	// use, rather than hardcoded, so a future call site can't silently
	// disagree with gatewayRetryableByCode (the exact shape of this sweep's
	// finding, applied preemptively here).
	writeJSON(w, status, map[string]any{
		"error": map[string]any{
			"message":        message,
			"type":           "invalid_request_error",
			"param":          param,
			"code":           code,
			"retryable":      gatewayRetryable(code),
			"request_id":     nil,
			"inference_ran":  false,
			"settlement_ran": false,
		},
	})
}

func copyCleanHeaders(dst, src http.Header) {
	copyCleanHeadersWithReceipt(dst, src, false)
}

func copyReceiptEligibleHeaders(dst, src http.Header) {
	copyCleanHeadersWithReceipt(dst, src, true)
}

func copyCleanHeadersWithReceipt(dst, src http.Header, allowReceipt bool) {
	for key, values := range src {
		if strings.EqualFold(key, "Content-Length") || strings.EqualFold(key, "Trailer") {
			continue
		}
		if allowReceipt && isReceiptResponseHeader(key) {
			for _, value := range values {
				if receipt := buyerVisibleReceiptHeader(value); receipt != "" {
					dst.Add(key, receipt)
				}
			}
			continue
		}
		// SPEC-018 AC-45 / SPEC-006 §5.4 response-pass-through allowlist:
		// the coordinator's buyer-visible X-MacProvider-Streaming-Mode
		// diagnostic must survive the blanket X-MacProvider-* strip below.
		// The value is validated against AC-45's closed enum so a
		// compromised or misconfigured upstream cannot smuggle arbitrary
		// header content past the strip (defense-in-depth — the value is
		// coordinator-set). Unconditional (both receipt-eligible and
		// non-receipt paths) because the coordinator emits it on the
		// streaming 200 path that flows through copyCleanHeaders.
		if isStreamingModeResponseHeader(key) {
			for _, value := range values {
				if mode := buyerVisibleStreamingModeHeader(value); mode != "" {
					dst.Set(streamingModeResponseHeader, mode)
					break
				}
			}
			continue
		}
		if isMacProviderHeader(key) {
			continue
		}
		// Issue #190: the gateway is authoritative for rate-limit
		// and Retry-After headers on chat responses. Dropping any
		// upstream values prevents duplicate / contradictory
		// headers that SDKs may parse inconsistently (comma-joined
		// repeats in some HTTP libraries).
		if isGatewayOwnedRateLimitHeader(key) {
			continue
		}
		if isGatewayOwnedCorrelationHeader(key) {
			continue
		}
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

// Issue #190: header names the gateway emits and treats as
// authoritative on /v1/chat/completions responses. Upstream
// (coordinator / provider) variants of the same name are dropped
// in copyCleanHeadersWithReceipt so the gateway-set values are
// the only ones the buyer sees.
func isGatewayOwnedRateLimitHeader(key string) bool {
	switch strings.ToLower(key) {
	case "x-ratelimit-limit",
		"x-ratelimit-remaining",
		"x-ratelimit-reset",
		"x-ratelimit-limit-requests",
		"x-ratelimit-remaining-requests",
		"x-ratelimit-reset-requests",
		"retry-after":
		return true
	}
	return false
}

func isGatewayOwnedCorrelationHeader(key string) bool {
	return strings.EqualFold(key, "X-Request-ID")
}

func isReceiptResponseHeader(key string) bool {
	return strings.EqualFold(key, "X-MacProvider-Receipt")
}

// streamingModeResponseHeader is the SPEC-018 AC-45 buyer-visible
// diagnostic. The coordinator sets it on streaming 200 responses; the
// gateway allowlists it through the X-MacProvider-* strip per the
// SPEC-006 §5.4 response-pass-through allowlist.
const streamingModeResponseHeader = "X-MacProvider-Streaming-Mode"

func isStreamingModeResponseHeader(key string) bool {
	return strings.EqualFold(key, streamingModeResponseHeader)
}

// buyerVisibleStreamingModeHeader returns the value only if it is byte-exactly
// one of AC-45's three canonical streaming-mode values, else "" (drop). The
// match is strict — no trimming or case-folding — because SPEC-006 §5.4
// mandates dropping any value outside the closed enum rather than normalizing
// it, and the coordinator emits the bare constants verbatim, so a value with
// surrounding whitespace or altered case is not something the trusted upstream
// produces. The header is observation-only (SPEC-018 §10d.4) — buyers MUST NOT
// negotiate on it — so the strict enum guard is safe and prevents header
// injection should the upstream ever be compromised.
func buyerVisibleStreamingModeHeader(raw string) string {
	switch raw {
	case "incremental", "buffered_kill_switch", "buffered_provider_downgrade":
		return raw
	}
	return ""
}

func buyerVisibleReceiptHeader(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" || len(value) > 4096 {
		return ""
	}
	for i := 0; i < len(value); i++ {
		if value[i] < 0x20 || value[i] > 0x7E {
			return ""
		}
	}
	if receiptHeaderVersion(value) == "4" {
		return ""
	}
	return value
}

func receiptHeaderVersion(header string) string {
	tupleB64, _, ok := strings.Cut(header, ".")
	if !ok || tupleB64 == "" {
		return ""
	}
	raw, err := base64.StdEncoding.DecodeString(tupleB64)
	if err != nil {
		return ""
	}
	var payload struct {
		ReceiptVersion string `json:"receipt_version"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return ""
	}
	return payload.ReceiptVersion
}

func stripInternalMacProviderHeaders(header http.Header) []string {
	var stripped []string
	for key := range header {
		if isInternalMacProviderHeader(key) {
			stripped = append(stripped, key)
			header.Del(key)
		}
	}
	sort.Strings(stripped)
	return stripped
}

func isMacProviderHeader(key string) bool {
	return strings.HasPrefix(strings.ToLower(key), "x-macprovider-")
}

func isInternalMacProviderHeader(key string) bool {
	lower := strings.ToLower(key)
	return lower == "x-macprovider-internal-conv" || strings.HasPrefix(lower, "x-macprovider-internal-")
}

func setRateLimitHeaders(w http.ResponseWriter, limit, remaining, reset int64) {
	w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", limit))
	w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", remaining))
	w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", reset))
}

// Issue #190: per-account concurrency rate-limit headers, distinct
// from the daily-token quota headers above. OpenAI-compatible
// clients honor the *-Requests variants for self-pacing the
// in-flight request count, whereas the unsuffixed variants (still
// emitted on the daily-quota path) describe the token budget.
//
// We emit these on EVERY admitted request so SDKs can pre-emptively
// throttle, and again on the 429 reject path with Remaining=0 and
// a Retry-After hint. retryAfterSeconds = 0 suppresses the
// Retry-After header (used on the admitted-path call).
func setConcurrencyRateLimitHeaders(w http.ResponseWriter, limit, remaining int, retryAfterSeconds int, now time.Time) {
	w.Header().Set("X-RateLimit-Limit-Requests", strconv.Itoa(limit))
	if remaining < 0 {
		remaining = 0
	}
	w.Header().Set("X-RateLimit-Remaining-Requests", strconv.Itoa(remaining))
	if retryAfterSeconds > 0 {
		// X-RateLimit-Reset-Requests communicates the wall-clock
		// instant (unix seconds) at which the buyer can retry; it
		// must be consistent with Retry-After. We anchor both to
		// the same `now` to remove TOCTOU drift between header
		// values within a single response.
		w.Header().Set("X-RateLimit-Reset-Requests", strconv.FormatInt(now.Unix()+int64(retryAfterSeconds), 10))
		w.Header().Set("Retry-After", strconv.Itoa(retryAfterSeconds))
	}
}

// Issue #190: Retry-After hint for concurrency 429. Conservative
// constant — 1 second — so OpenAI-compatible SDKs back off briefly
// without hammering, while still being short enough to recover
// quickly once an in-flight request completes. Bounded so future
// changes can not accidentally produce huge values.
const concurrencyRetryAfterSeconds = 1

func resetUnix(windowDate string) int64 {
	t, err := time.Parse("2006-01-02", windowDate)
	if err != nil {
		return 0
	}
	return t.Add(24 * time.Hour).Unix()
}

func mustID(prefix string) string {
	id, err := auth.RandomID(prefix)
	if err != nil {
		panic(err)
	}
	return id
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func isUUIDLike(v string) bool {
	if len(v) != 36 {
		return false
	}
	for i, ch := range v {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if ch != '-' {
				return false
			}
			continue
		}
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') && (ch < 'A' || ch > 'F') {
			return false
		}
	}
	if v[14] != '4' {
		return false
	}
	variant := v[19]
	return variant == '8' || variant == '9' || variant == 'a' || variant == 'b' || variant == 'A' || variant == 'B'
}
