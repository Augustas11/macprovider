package payout

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/rs/zerolog"
)

// ProviderTokenValidator mirrors the billing-package tokenValidator
// surface so the payouts handler can authenticate a provider
// bearer without taking a hard dependency on internal/billing.
// The auth.Store + the SPEC-003 token store both satisfy it.
type ProviderTokenValidator interface {
	ValidateToken(ctx context.Context, raw string) (providerID string, ok bool, err error)
}

// PayoutsHandler backs the §7.3 GET /providers/{provider_id}/payouts
// read endpoint. It is provider-token-auth (NOT operator). Returns
// the most recent N payouts joined from payout_attempts +
// ledger_payout_ready for the provider named in the path. Per-
// provider sliding-window rate-limit mirrors the billing/earnings
// surface algorithm.
type PayoutsHandler struct {
	db           *sql.DB
	tokens       ProviderTokenValidator
	rateLimitMin int
	defaultLimit int
	maxLimit     int
	log          zerolog.Logger
	nowFn        func() time.Time

	mu       sync.Mutex
	lastHits map[string][]time.Time
}

// PayoutsHandlerOptions bundles dependencies.
type PayoutsHandlerOptions struct {
	DB           *sql.DB
	Tokens       ProviderTokenValidator
	RateLimitMin int // 0 disables the limiter
	DefaultLimit int // default rows per response (SPEC §7.3 default 50)
	MaxLimit     int // ceiling for the ?limit= override
	Logger       zerolog.Logger
	NowFn        func() time.Time
}

// NewPayoutsHandler constructs the handler.
func NewPayoutsHandler(opts PayoutsHandlerOptions) (*PayoutsHandler, error) {
	if opts.DB == nil {
		return nil, errors.New("payout.NewPayoutsHandler: DB required")
	}
	if opts.Tokens == nil {
		return nil, errors.New("payout.NewPayoutsHandler: Tokens required")
	}
	if opts.DefaultLimit <= 0 {
		opts.DefaultLimit = 50
	}
	if opts.MaxLimit <= 0 {
		opts.MaxLimit = 200
	}
	nowFn := opts.NowFn
	if nowFn == nil {
		nowFn = time.Now
	}
	return &PayoutsHandler{
		db:           opts.DB,
		tokens:       opts.Tokens,
		rateLimitMin: opts.RateLimitMin,
		defaultLimit: opts.DefaultLimit,
		maxLimit:     opts.MaxLimit,
		log:          opts.Logger,
		nowFn:        nowFn,
		lastHits:     make(map[string][]time.Time),
	}, nil
}

// PayoutRow is one row of the §7.3 response. Sorted by
// confirmed_at_utc DESC, NULL last.
type PayoutRow struct {
	PayoutID        int64   `json:"payout_id"`
	AttemptSeq      int     `json:"attempt_seq"`
	ProviderCredits int64   `json:"provider_credits"`
	AmountBaseUnits int64   `json:"amount_base_units"`
	Chain           string  `json:"chain"`
	TxHash          *string `json:"tx_hash,omitempty"`
	BlockNumber     *int64  `json:"block_number,omitempty"`
	ConfirmedAtUTC  *string `json:"confirmed_at_utc,omitempty"`
	BroadcastAtUTC  *string `json:"broadcast_at_utc,omitempty"`
	AbandonedAtUTC  *string `json:"abandoned_at_utc,omitempty"`
	IsCancelSelfTrn bool    `json:"is_cancel_self_transfer"`
	WindowStartUTC  string  `json:"window_start_utc"`
	WindowEndUTC    string  `json:"window_end_utc"`
	IdempotencyKey  string  `json:"idempotency_key"`
}

// ServePayouts handles GET /providers/{provider_id}/payouts.
// Response: 200 with {payouts:[...]}; 401 missing/bad bearer;
// 403 token does not match path provider_id; 429 rate-limited;
// 500 DB error.
func (h *PayoutsHandler) ServePayouts(w http.ResponseWriter, r *http.Request) {
	pathProvider := chi.URLParam(r, "provider_id")
	if pathProvider == "" {
		writeError(w, http.StatusBadRequest, "missing_provider_id")
		return
	}
	bearer := bearerFromHeader(r.Header.Get("Authorization"))
	if bearer == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	tokenProvider, ok, err := h.tokens.ValidateToken(r.Context(), bearer)
	if err != nil {
		h.log.Warn().Err(err).Str("path", r.URL.Path).
			Str("event", "payouts_token_lookup_error").Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if tokenProvider != pathProvider {
		writeError(w, http.StatusForbidden, "provider_mismatch")
		return
	}
	if !h.allow(pathProvider) {
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}

	limit := h.parseLimit(r.URL.Query().Get("limit"))
	rows, err := h.queryPayouts(r.Context(), pathProvider, limit)
	if err != nil {
		h.log.Error().Err(err).Str("provider_id", pathProvider).
			Str("event", "payouts_query_failed").Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id": pathProvider,
		"count":       len(rows),
		"payouts":     rows,
	})
}

// allow is the per-provider sliding-window limiter. Same algorithm
// as billing/endpoints.go::allowEarnings — kept package-local
// instead of exported across the boundary so the §4.1 import
// direction stays one-way (payout→billing for ClaimPayoutReady
// only; no reverse dependency).
func (h *PayoutsHandler) allow(providerID string) bool {
	if h.rateLimitMin <= 0 {
		return true
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	cutoff := h.nowFn().Add(-time.Minute)
	kept := h.lastHits[providerID][:0]
	for _, t := range h.lastHits[providerID] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= h.rateLimitMin {
		h.lastHits[providerID] = kept
		return false
	}
	h.lastHits[providerID] = append(kept, h.nowFn())
	return true
}

func (h *PayoutsHandler) parseLimit(q string) int {
	if q == "" {
		return h.defaultLimit
	}
	q = strings.TrimSpace(q)
	// We accept only integer 1..MaxLimit; non-integers fall back
	// to the default (forgiving to the client). Caller can pass
	// 0 explicitly to get the default.
	n := 0
	for _, c := range q {
		if c < '0' || c > '9' {
			return h.defaultLimit
		}
		n = n*10 + int(c-'0')
		if n > h.maxLimit {
			return h.maxLimit
		}
	}
	if n <= 0 {
		return h.defaultLimit
	}
	return n
}

// queryPayouts returns the most recent N payouts for providerID.
// Join through ledger_payout_ready so cancel rows (which do NOT
// consume lpr) are FILTERED OUT — providers should never see the
// operator's own cancel self-transfers (they're an operational
// signal, not a payment).
func (h *PayoutsHandler) queryPayouts(ctx context.Context, providerID string, limit int) ([]PayoutRow, error) {
	rows, err := h.db.QueryContext(ctx, `
SELECT pa.payout_id, pa.attempt_seq, lpr.provider_credits,
       pa.amount_base_units, pa.chain, pa.tx_hash, pa.block_number,
       pa.confirmed_at_utc, pa.broadcast_at_utc, pa.abandoned_at_utc,
       pa.is_cancel_self_transfer,
       lpr.window_start_utc, lpr.window_end_utc, lpr.idempotency_key
  FROM payout_attempts pa
 INNER JOIN ledger_payout_ready lpr ON lpr.id = pa.payout_id
 WHERE lpr.provider_id = ?
   AND pa.is_cancel_self_transfer = 0
 ORDER BY COALESCE(pa.confirmed_at_utc, pa.broadcast_at_utc, pa.updated_at_utc) DESC
 LIMIT ?`, providerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]PayoutRow, 0, limit)
	for rows.Next() {
		var r PayoutRow
		var txHash sql.NullString
		var blockNumber sql.NullInt64
		var confirmedAt, broadcastAt, abandonedAt sql.NullString
		var isCancel int
		if err := rows.Scan(
			&r.PayoutID, &r.AttemptSeq, &r.ProviderCredits,
			&r.AmountBaseUnits, &r.Chain, &txHash, &blockNumber,
			&confirmedAt, &broadcastAt, &abandonedAt,
			&isCancel,
			&r.WindowStartUTC, &r.WindowEndUTC, &r.IdempotencyKey,
		); err != nil {
			return nil, err
		}
		if txHash.Valid {
			s := txHash.String
			r.TxHash = &s
		}
		if blockNumber.Valid {
			n := blockNumber.Int64
			r.BlockNumber = &n
		}
		if confirmedAt.Valid {
			s := confirmedAt.String
			r.ConfirmedAtUTC = &s
		}
		if broadcastAt.Valid {
			s := broadcastAt.String
			r.BroadcastAtUTC = &s
		}
		if abandonedAt.Valid {
			s := abandonedAt.String
			r.AbandonedAtUTC = &s
		}
		r.IsCancelSelfTrn = isCancel == 1
		out = append(out, r)
	}
	return out, rows.Err()
}

// Ensure encoding/json is used (silences unused-import vet on a
// minimal-test path) — writeJSON depends on json indirectly.
var _ = json.Marshal
