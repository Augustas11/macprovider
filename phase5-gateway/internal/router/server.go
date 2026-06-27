package router

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

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
	routingMeta routingMetaCache
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
	mux.HandleFunc("/auth/github/start", s.handleGitHubStart)
	mux.HandleFunc("/auth/github/callback", s.handleGitHubCallback)
	mux.Handle("/auth/demo-session", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleDemoSession)))
	mux.HandleFunc("/auth/api-keys", s.handleAPIKeys)
	mux.HandleFunc("/auth/api-keys/", s.handleAPIKeyAction)
	mux.HandleFunc("/account", s.handleAccount)
	mux.HandleFunc("/docs", s.handleDocs)
	mux.Handle("/v1/models", s.withCORS(http.MethodGet, http.HandlerFunc(s.handleModels)))
	mux.HandleFunc("/v1/usage", s.handleUsage)
	mux.Handle("/v1/chat/completions", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleChatCompletions)))
	mux.Handle("/v1/sticky", s.withCORS(http.MethodDelete, http.HandlerFunc(s.handleStickyDelete)))
	mux.Handle("/v1/status", s.withCORS(http.MethodGet, http.HandlerFunc(s.handleStatus)))
	mux.HandleFunc("/v1/feedback", s.handleFeedback)
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/admin/feedback-summary", s.handleFeedbackSummary)
	mux.HandleFunc("/admin/kill-switch", s.handleKillSwitch)
	mux.HandleFunc("/admin/capacity-signal", s.handleCapacitySignal)
	mux.HandleFunc("/admin/capacity-tier/evaluate", s.handleCapacityEvaluate)
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

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.Header.Get("X-Request-ID")
		if !isUUIDLike(requestID) {
			requestID = newUUID()
		}
		if stripped := stripInternalMacProviderHeaders(r.Header); len(stripped) > 0 {
			slog.Warn("internal header injection stripped", "request_id", requestID, "headers", stripped)
			if s.shouldPersistInternalHeaderAudit(r) {
				_ = s.store.InsertAuditEvent(context.Background(), storage.AuditEvent{
					EventID: mustID("audit"), RequestID: requestID, Actor: "public_ingress", Type: "internal_header_injection_stripped",
					Payload: fmt.Sprintf(`{"headers":%q}`, strings.Join(stripped, ",")), CreatedAt: s.now(),
				})
			}
		}
		w.Header().Set("X-Request-ID", requestID)
		if s.publicPaused(r.URL.Path) {
			writeError(w, http.StatusServiceUnavailable, "server_error", "public_api_paused", "Mac Provider beta is paused while capacity catches up. Please retry later.")
			return
		}
		ctx := context.WithValue(r.Context(), requestIDKey{}, requestID)
		defer func() {
			if recovered := recover(); recovered != nil {
				slog.Error("panic recovered", "panic", recovered, "request_id", requestID, "path", r.URL.Path, "stack", string(debug.Stack()))
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
	if r.Method != http.MethodGet {
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
		"capacity": map[string]any{"tier": tier.Tier},
		"keys":     keys,
		"models":   []any{},
		"rating":   nil,
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
	// M3-2 / SECU-4: prefer ServiceToken when set; falls back to
	// OperatorKey so a not-yet-upgraded coordinator keeps accepting us.
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
	var req struct {
		Rating    int    `json:"rating"`
		Comment   string `json:"comment"`
		RequestID string `json:"request_id"`
		Scope     string `json:"scope"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, int64(s.cfg.Limits.MaxFeedbackCommentBytes)+4096)).Decode(&req); err != nil {
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
	now := s.now()
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

type poolzResponse struct {
	Pool []struct {
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
		// SPEC-003 v0.8.3 FR-C9.4 auth_state — empty / bearer_validated /
		// self_minted are routable; bearerless_duplicate is non-routable
		// (admitted for /poolz visibility, excluded from buyer traffic +
		// billing). The gateway mirrors pool.Provider.RoutingEligible() by
		// dropping bearerless_duplicate entries from /v1/status capacity
		// aggregation so the buyer-visible status doesn't promise capacity
		// the coordinator will refuse to route.
		AuthState string `json:"auth_state,omitempty"`
	} `json:"pool"`
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
		// SPEC-003 v0.8.3 FR-C9.4 — bearerless duplicates are admitted to
		// /poolz for operator visibility but are non-routable (excluded by
		// pool.Provider.RoutingEligible). They MUST NOT contribute to the
		// gateway's buyer-facing capacity counts: counting them would
		// over-promise capacity that the coordinator will refuse to route,
		// and would taint per-model availability (a model whose only
		// "ready" entry is a bearerless duplicate would appear available).
		if p.AuthState == authStateBearerlessDuplicate {
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
	// been excluded by the bearerless-duplicate gate above; otherwise the
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

func writeError(w http.ResponseWriter, status int, typ, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": message, "type": typ, "param": nil, "code": code}})
}

func copyCleanHeaders(dst, src http.Header) {
	copyCleanHeadersWithReceipt(dst, src, false)
}

func copyReceiptEligibleHeaders(dst, src http.Header) {
	copyCleanHeadersWithReceipt(dst, src, true)
}

func copyCleanHeadersWithReceipt(dst, src http.Header, allowReceipt bool) {
	for key, values := range src {
		if strings.EqualFold(key, "Content-Length") {
			continue
		}
		if isMacProviderHeader(key) && !(allowReceipt && isReceiptResponseHeader(key)) {
			continue
		}
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

func isReceiptResponseHeader(key string) bool {
	return strings.EqualFold(key, "X-MacProvider-Receipt")
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
