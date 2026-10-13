package router

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// SPEC-050 MALIBU stake allowance, gateway side. The gateway holds no stake or
// allowance state (SPEC-050-R013). For an API-key plaintext or relay-blind
// request it sends the request's credit-bound inputs to the coordinator on
// the chat hop; the coordinator admits the request against the account's
// allowance before dispatch and answers with the funding (SPEC-050-R007). An
// allowance-funded request's quota reservation is then marked so it never
// counts against the paid daily quota. The gateway also proxies the
// account's /v1/stake calls (SPEC-050-R011).

const (
	stakeProxyPrefix    = "/v1/stake"
	stakeUpstreamPrefix = "/internal/stake-allowance/"
	stakeAccountHeader  = "X-MacProvider-Stake-Account-ID"
	stakeGitHubHeader   = "X-MacProvider-Stake-GitHub-User-ID"
	stakeProxyMaxBody   = 4 << 10
	stakeProxyMaxResult = 64 << 10

	// Chat-hop allowance headers. All are X-MacProvider-Internal-*, so a
	// buyer-supplied copy is stripped at ingress.
	allowanceModelHeader        = "X-MacProvider-Internal-Allowance-Model"
	allowanceInputTokensHeader  = "X-MacProvider-Internal-Allowance-Input-Tokens"
	allowanceOutputTokensHeader = "X-MacProvider-Internal-Allowance-Output-Tokens"
	allowanceRequiredHeader     = "X-MacProvider-Internal-Allowance-Required"
	allowanceDayHeader          = "X-MacProvider-Internal-Allowance-Day"
	allowanceFundingHeader      = "X-MacProvider-Internal-Allowance-Funding"
	allowanceActiveHeader       = "X-MacProvider-Internal-Allowance-Active"

	allowanceCacheMaxEntries = 100_000
)

// allowanceCache remembers, per account, the UTC day the coordinator last
// reported an allowance for. Only such an account may be forwarded once its
// paid quota is exhausted, so the coordinator can fund it from the allowance
// alone. Only positive answers are cached in memory; the
// allowance_active_days table is the shared source across restarts and
// gateway instances, so a miss always consults it.
type allowanceCache struct {
	mu      sync.Mutex
	entries map[string]string // account -> UTC day with an allowance
}

func (c *allowanceCache) has(account, day string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.entries[account] == day
}

func (c *allowanceCache) set(account, day string, active bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !active {
		if c.entries[account] == day {
			delete(c.entries, account)
		}
		return
	}
	if c.entries == nil || len(c.entries) >= allowanceCacheMaxEntries {
		c.entries = map[string]string{}
	}
	c.entries[account] = day
}

// allowanceStore is implemented by the SQLite store.
type allowanceStore interface {
	MarkReservationFundingSource(ctx context.Context, accountID, requestID, source string) error
	NoteAllowanceDay(ctx context.Context, accountID, day string, active bool, now time.Time) error
	AllowanceDayActive(ctx context.Context, accountID, day string) (bool, error)
}

func (s *Server) allowanceActive(ctx context.Context, account, day string) bool {
	if s.allowance.has(account, day) {
		return true
	}
	store, ok := s.store.(allowanceStore)
	if !ok {
		return false
	}
	active, err := store.AllowanceDayActive(ctx, account, day)
	if err != nil {
		slog.Warn("allowance day lookup failed", "account_id", account, "error", err)
		return false
	}
	s.allowance.set(account, day, active)
	return active
}

// noteAllowanceDay records the coordinator's answer. A positive answer is
// cached in memory only after the shared table holds it, so a failed write is
// retried on the next answer instead of living in one process only.
func (s *Server) noteAllowanceDay(account, day string, active bool) {
	if active && s.allowance.has(account, day) {
		return
	}
	if store, ok := s.store.(allowanceStore); ok {
		if err := store.NoteAllowanceDay(context.Background(), account, day, active, s.now()); err != nil {
			slog.Warn("allowance day record failed", "account_id", account, "error", err)
			if active {
				return
			}
		}
	}
	s.allowance.set(account, day, active)
}

// persistFundingSource writes a confirmed funding onto the reservation
// outside the normal settlement transaction (settlement fallback, journal
// recovery). Empty does nothing; a missing reservation is not an error.
func (s *Server) persistFundingSource(account, reqID, source string) error {
	if source == "" || account == "" {
		return nil
	}
	store, ok := s.store.(allowanceStore)
	if !ok {
		return nil
	}
	if err := store.MarkReservationFundingSource(context.Background(), account, reqID, source); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
		slog.Error("allowance funding persist failed", "request_id", reqID, "account_id", account, "source", source, "error", err)
		return err
	}
	return nil
}

// setAllowanceRequestHeaders asks the coordinator to admit this request
// against the account's allowance for day, the UTC day of the gateway's
// quota reservation, so both sides account the request to the same day.
// required marks a request whose paid quota is exhausted: only the allowance
// may fund it.
func setAllowanceRequestHeaders(h http.Header, model, day string, inputUpperBound, maxOutputTokens int64, required bool) {
	h.Set(allowanceModelHeader, model)
	h.Set(allowanceDayHeader, day)
	h.Set(allowanceInputTokensHeader, strconv.FormatInt(inputUpperBound, 10))
	h.Set(allowanceOutputTokensHeader, strconv.FormatInt(maxOutputTokens, 10))
	if required {
		h.Set(allowanceRequiredHeader, "1")
	}
}

// reserveAllowanceOnly is the paid-quota-exhausted path: when the account
// had an allowance today, reserve past the paid quota's limit and require the
// coordinator to fund the request from the allowance (SPEC-050-R007). The
// reservation stays on the paid quota until the coordinator confirms the
// allowance funding, so a lost answer, a crash, or a coordinator without
// SPEC-050 leaves it charged to the paid quota (SPEC-050-R014).
func (s *Server) reserveAllowanceOnly(ctx context.Context, subject *usageSubject, req storage.ReservationRequest) (storage.QuotaDecision, error, bool) {
	if !s.allowanceActive(ctx, subject.AccountID, req.WindowDate) {
		return storage.QuotaDecision{}, nil, false
	}
	req.AllowanceOnly = true
	decision, err := s.store.ReserveQuota(ctx, req)
	if err == nil {
		subject.AllowanceRequired = true
	}
	return decision, err, true
}

// noteAllowanceResponse reads the coordinator's funding answer and strips
// the internal headers before anything reaches the buyer. An allowance answer
// takes the reservation off the paid quota; the settlement repeats the
// funding atomically, so a failed early update cannot charge both. An
// allowance-only request the coordinator did not fund (a coordinator without
// SPEC-050, or one rolled back) is put back on the paid quota and charged
// there, even past its limit, so it is never served unfunded (SPEC-050-R014).
func (s *Server) noteAllowanceResponse(r *http.Request, subject *usageSubject, h http.Header) {
	if h == nil {
		return
	}
	funding := strings.TrimSpace(h.Get(allowanceFundingHeader))
	active := strings.TrimSpace(h.Get(allowanceActiveHeader))
	h.Del(allowanceFundingHeader)
	h.Del(allowanceActiveHeader)
	if subject.AccountID == "" || subject.DemoIdentity != "" || subject.WalletSessionID != "" {
		return
	}
	day := subject.ReservationCreatedAt.UTC().Format("2006-01-02")
	if active == "1" || active == "0" {
		s.noteAllowanceDay(subject.AccountID, day, active == "1")
	}
	store, _ := s.store.(allowanceStore)
	if subject.AllowanceRequired && funding != allowanceFundingAllowance {
		s.noteAllowanceDay(subject.AccountID, day, false)
		subject.AllowanceFunded = false
		if store != nil {
			if err := store.MarkReservationFundingSource(context.Background(), subject.AccountID, requestID(r), storage.FundingSourceQuota); err != nil {
				slog.Error("allowance-only request not funded by the coordinator; settlement charges the paid quota",
					"request_id", requestID(r), "account_id", subject.AccountID, "error", err)
			}
		}
		return
	}
	if funding != allowanceFundingAllowance || subject.AllowanceFunded {
		return
	}
	subject.AllowanceFunded = true
	if store != nil {
		if err := store.MarkReservationFundingSource(context.Background(), subject.AccountID, requestID(r), storage.FundingSourceAllowance); err != nil {
			slog.Warn("allowance funding mark failed; the settlement records it",
				"request_id", requestID(r), "account_id", subject.AccountID, "error", err)
		}
	}
}

// settlementFundingSource is the funding a settlement writes onto the
// reservation: the coordinator-confirmed allowance, the paid quota for an
// allowance-only request it did not fund, or "" to keep the reservation's.
func settlementFundingSource(subject usageSubject) string {
	switch {
	case subject.AllowanceFunded:
		return storage.FundingSourceAllowance
	case subject.AllowanceRequired:
		return storage.FundingSourceQuota
	}
	return ""
}

const allowanceFundingAllowance = "allowance"

// newStakeUpstreamRequest builds a request to the coordinator's internal
// stake/allowance mount from an empty header set. Like the creator proxy it
// is assembled from a parsed URL so the target can be pinned to the mount,
// never a chat route.
func newStakeUpstreamRequest(ctx context.Context, method, target string, body []byte) (*http.Request, error) {
	u, err := url.Parse(target)
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(u.Path, stakeUpstreamPrefix) {
		return nil, errors.New("stake proxy: upstream target outside the stake mount")
	}
	req := (&http.Request{
		Method:     method,
		URL:        u,
		Proto:      "HTTP/1.1",
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     make(http.Header),
		Host:       u.Host,
	}).WithContext(ctx)
	if len(body) > 0 {
		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		req.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(body)), nil }
	}
	return req, nil
}

func (s *Server) stakeUpstreamTarget(route string) string {
	return strings.TrimRight(s.coordinatorBuyerURL(), "/") + stakeUpstreamPrefix + route
}

// handleStakeProxy serves GET /v1/stake and POST /v1/stake/{lock,unlock,
// overage} for API-key accounts (SPEC-050-R011). The coordinator receives a
// new request that carries only the verified principal.
func (s *Server) handleStakeProxy(w http.ResponseWriter, r *http.Request) {
	route := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, stakeProxyPrefix), "/")
	method := http.MethodPost
	switch route {
	case "":
		route, method = "account", http.MethodGet
	case "lock", "unlock", "overage":
	default:
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
		return
	}
	if r.Method != method {
		w.Header().Set("Allow", method)
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		writeError(w, http.StatusForbidden, "permission_error", "demo_stake_forbidden", "Demo tokens cannot stake")
		return
	}
	if bearer := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")); strings.HasPrefix(bearer, walletSessionBearerPrefix) {
		writeError(w, http.StatusForbidden, "permission_error", "wallet_session_stake_forbidden", "Wallet sessions cannot stake")
		return
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	githubUserID := ""
	if lookup, ok := s.store.(accountIdentityLookup); ok {
		identity, err := lookup.LookupAccountIdentityByProvider(r.Context(), validation.AccountID, "github")
		switch {
		case err == nil:
			githubUserID = strings.TrimSpace(identity.ProviderUserID)
		case errors.Is(err, storage.ErrNotFound):
		default:
			writeError(w, http.StatusInternalServerError, "server_error", "stake_identity_lookup_failed", "Could not load account identity")
			return
		}
	}
	var body []byte
	if method == http.MethodPost {
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, stakeProxyMaxBody))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
			return
		}
		body = raw
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.CoordinatorTimeout())
	defer cancel()
	upReq, err := newStakeUpstreamRequest(ctx, method, s.stakeUpstreamTarget(route), body)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "stake_upstream_error", "Could not reach the stake service")
		return
	}
	upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	upReq.Header.Set(stakeAccountHeader, validation.AccountID)
	if githubUserID != "" {
		upReq.Header.Set(stakeGitHubHeader, githubUserID)
	}
	if method == http.MethodPost {
		upReq.Header.Set("Content-Type", "application/json")
	}
	if key := strings.TrimSpace(r.Header.Get("Idempotency-Key")); key != "" {
		upReq.Header.Set("Idempotency-Key", key)
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	resp, err := s.client.Do(upReq)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "stake_upstream_error", "Could not reach the stake service")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		writeError(w, http.StatusBadGateway, "api_error", "stake_upstream_error", "Could not reach the stake service")
		return
	}
	payload, err := io.ReadAll(io.LimitReader(resp.Body, stakeProxyMaxResult+1))
	if err != nil || len(payload) > stakeProxyMaxResult {
		writeError(w, http.StatusBadGateway, "api_error", "stake_upstream_error", "Could not reach the stake service")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	setNoStoreHeaders(w.Header())
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(payload)
}
