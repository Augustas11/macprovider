// Package stakeallowance is the coordinator's internal SPEC-050 surface: the
// gateway, authenticated by the service token, forwards an API-key account's
// stake and allowance calls here. The gateway holds no stake or allowance
// state (SPEC-050-R013); every principal field comes from headers the gateway
// sets on a new request, never from the client.
package stakeallowance

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
	"github.com/rs/zerolog"
)

const (
	// Prefix is the coordinator mount for the gateway's stake calls.
	Prefix = "/internal/stake-allowance/"

	AccountIDHeader    = "X-MacProvider-Stake-Account-ID"
	GitHubUserIDHeader = "X-MacProvider-Stake-GitHub-User-ID"

	maxBodyBytes = 4 << 10
)

// Disclosure is the SPEC-050-R012 text every stake and allowance surface
// carries unchanged.
const Disclosure = "Staked MALIBU stays locked while staked and during the unlock cooldown. The daily allowance is inference credit on this network only. It cannot be withdrawn, transferred, or sold, and unused allowance expires at 00:00 UTC. Its size depends on the operator's daily network budget and can change."

var accountIDPattern = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)

// StakeLedger is the stake source surface the handler needs (SPEC-050-R001).
type StakeLedger interface {
	Lock(ctx context.Context, req rewards.StakeRequest) (rewards.StakeResult, error)
	Unlock(ctx context.Context, req rewards.StakeRequest) (rewards.StakeResult, error)
	Position(ctx context.Context, accountID string, ownedProviderIDs []string) (rewards.StakePosition, error)
}

// AllowanceStore is the billing surface for the overage setting and the
// account view (SPEC-050-R007/R008/R011).
type AllowanceStore interface {
	SetAllowanceOverage(ctx context.Context, accountID string, enabled bool, now time.Time) error
	AllowanceStatusFor(ctx context.Context, accountID string, now time.Time) (billing.AllowanceStatus, error)
}

// Deps wires the handler. A nil Ledger answers stake calls with
// 503 stake_source_unavailable (no rewards database configured). A nil
// Allowance answers allowance calls with 503.
type Deps struct {
	GatewayServiceToken string
	Ledger              StakeLedger
	OwnedProviderIDs    func(ctx context.Context, githubUserID int64) ([]string, error)
	Allowance           AllowanceStore
	// PayoutAddresses lists the payout addresses of the given providers
	// (the account's linked wallets).
	PayoutAddresses func(ctx context.Context, providerIDs []string) ([]string, error)
	Now             func() time.Time
	Logger          zerolog.Logger
}

type handler struct {
	deps Deps
}

// NewHandler returns the internal stake/allowance handler mounted at Prefix.
func NewHandler(deps Deps) http.Handler {
	return &handler{deps: deps}
}

type principal struct {
	AccountID    string
	GitHubUserID int64
}

func singleHeader(h http.Header, name string) (string, bool) {
	values := h.Values(name)
	if len(values) != 1 {
		return "", false
	}
	v := strings.TrimSpace(values[0])
	return v, v != "" && v == values[0]
}

// authenticate requires the gateway service token and a well-formed account
// principal. The GitHub user id is optional; operations that need ownership
// fail closed without it.
func (h *handler) authenticate(r *http.Request) (principal, bool) {
	if strings.TrimSpace(h.deps.GatewayServiceToken) == "" {
		return principal{}, false
	}
	if auth.GatewayInternalBearerMatches(r.Header, h.deps.GatewayServiceToken) == auth.BearerKindNone {
		return principal{}, false
	}
	accountID, ok := singleHeader(r.Header, AccountIDHeader)
	if !ok || !accountIDPattern.MatchString(accountID) {
		return principal{}, false
	}
	p := principal{AccountID: accountID}
	if len(r.Header.Values(GitHubUserIDHeader)) > 0 {
		raw, ok := singleHeader(r.Header, GitHubUserIDHeader)
		if !ok {
			return principal{}, false
		}
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 || strconv.FormatInt(id, 10) != raw {
			return principal{}, false
		}
		p.GitHubUserID = id
	}
	return p, true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, typ, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"type": typ, "code": code, "message": message}})
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p, ok := h.authenticate(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "authentication_error", "unauthorized", "Gateway service authentication is required")
		return
	}
	route := strings.TrimPrefix(r.URL.Path, Prefix)
	switch {
	case route == "lock" && r.Method == http.MethodPost:
		h.handleStake(w, r, p, true)
	case route == "unlock" && r.Method == http.MethodPost:
		h.handleStake(w, r, p, false)
	case route == "overage" && r.Method == http.MethodPost:
		h.handleOverage(w, r, p)
	case route == "account" && r.Method == http.MethodGet:
		h.handleAccount(w, r, p)
	case route == "account":
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
	case route == "lock" || route == "unlock" || route == "overage":
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
	default:
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
	}
}

type stakeBody struct {
	AmountMALIBU string `json:"amount_malibu"`
}

func decodeBody(r *http.Request, w http.ResponseWriter, dst any) error {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		return err
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	// Exactly one JSON value: anything after it is refused.
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("trailing data")
	}
	return nil
}

type stakeEventView struct {
	ProviderID   string `json:"provider_id"`
	EventType    string `json:"event_type"`
	AmountMALIBU string `json:"amount_malibu"`
	CreatedAt    string `json:"created_at"`
	ReleaseAt    string `json:"release_at,omitempty"`
}

func (h *handler) handleStake(w http.ResponseWriter, r *http.Request, p principal, lock bool) {
	if h.deps.Ledger == nil {
		writeError(w, http.StatusServiceUnavailable, "api_error", "stake_source_unavailable", "Staking is not available right now")
		return
	}
	key, ok := singleHeader(r.Header, "Idempotency-Key")
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "idempotency_key_required", "Idempotency-Key header is required")
		return
	}
	var body stakeBody
	if err := decodeBody(r, w, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_body", "Body must be {\"amount_malibu\": \"<decimal>\"}")
		return
	}
	units, err := rewards.ParseMALIBUUnits(body.AmountMALIBU)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_amount", "amount_malibu must be a positive decimal with at most 8 fractional digits")
		return
	}
	req := rewards.StakeRequest{AccountID: p.AccountID, GitHubUserID: p.GitHubUserID, AmountUnits: units, IdempotencyKey: key}
	var result rewards.StakeResult
	if lock {
		// Locking needs the GitHub identity that owns the providers; an
		// unlock is authorized by the account alone.
		if p.GitHubUserID <= 0 {
			writeError(w, http.StatusForbidden, "permission_error", "github_identity_required", "Staking needs an account signed in with GitHub")
			return
		}
		if h.deps.OwnedProviderIDs == nil {
			writeError(w, http.StatusServiceUnavailable, "api_error", "stake_source_unavailable", "Staking is not available right now")
			return
		}
		owned, err := h.deps.OwnedProviderIDs(r.Context(), p.GitHubUserID)
		if err != nil {
			h.deps.Logger.Warn().Err(err).Msg("stake: owned provider lookup failed")
			writeError(w, http.StatusServiceUnavailable, "api_error", "stake_source_unavailable", "Staking is not available right now")
			return
		}
		req.OwnedProviderIDs = owned
		result, err = h.deps.Ledger.Lock(r.Context(), req)
		if h.writeStakeError(w, err) {
			return
		}
	} else {
		result, err = h.deps.Ledger.Unlock(r.Context(), req)
		if h.writeStakeError(w, err) {
			return
		}
	}
	events := make([]stakeEventView, 0, len(result.Events))
	for _, ev := range result.Events {
		view := stakeEventView{
			ProviderID:   ev.ProviderID,
			EventType:    ev.EventType,
			AmountMALIBU: rewards.FormatMALIBUUnits(ev.AmountUnits),
			CreatedAt:    ev.CreatedAt.UTC().Format(time.RFC3339),
		}
		if ev.ReleaseAt != nil {
			view.ReleaseAt = ev.ReleaseAt.UTC().Format(time.RFC3339)
		}
		events = append(events, view)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"object":     "stake_events",
		"replayed":   result.Replayed,
		"events":     events,
		"disclosure": Disclosure,
	})
}

func (h *handler) writeStakeError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, rewards.ErrStakeInvalidAmount):
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_amount", "amount_malibu must be a positive decimal with at most 8 fractional digits")
	case errors.Is(err, rewards.ErrStakeInvalidIdempotency):
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_idempotency_key", "Idempotency-Key must be 1-128 characters of [A-Za-z0-9._:-]")
	case errors.Is(err, rewards.ErrStakeNoGitHubIdentity):
		writeError(w, http.StatusForbidden, "permission_error", "github_identity_required", "Staking needs an account signed in with GitHub")
	case errors.Is(err, rewards.ErrStakeNoOwnedProviders):
		writeError(w, http.StatusConflict, "invalid_request_error", "no_owned_provider", "This account owns no provider with MALIBU")
	case errors.Is(err, rewards.ErrStakeInsufficient):
		writeError(w, http.StatusConflict, "invalid_request_error", "insufficient_malibu", "Not enough MALIBU for this request")
	case errors.Is(err, rewards.ErrStakeIdentityChanged):
		writeError(w, http.StatusConflict, "invalid_request_error", "stake_identity_changed", "This account already staked under a different GitHub identity")
	case errors.Is(err, rewards.ErrStakeAccountBound):
		writeError(w, http.StatusBadRequest, "invalid_request_error", "stake_bound_exceeded", "This lock would take the account's stake past its bound")
	case errors.Is(err, rewards.ErrStakeRateLimited):
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "stake_rate_limited", "Too many stake changes in the last 24 hours")
	case errors.Is(err, rewards.ErrStakeIdempotencyReused):
		writeError(w, http.StatusConflict, "invalid_request_error", "idempotency_key_reused", "Idempotency-Key was already used for a different request")
	default:
		h.deps.Logger.Warn().Err(err).Msg("stake: ledger write failed")
		writeError(w, http.StatusServiceUnavailable, "api_error", "stake_source_unavailable", "Staking is not available right now")
	}
	return true
}

func (h *handler) now() time.Time {
	if h.deps.Now != nil {
		return h.deps.Now().UTC()
	}
	return time.Now().UTC()
}

type overageBody struct {
	Enabled *bool `json:"enabled"`
}

// handleOverage sets whether a request the allowance cannot cover may use
// the paid quota (SPEC-050-R007).
func (h *handler) handleOverage(w http.ResponseWriter, r *http.Request, p principal) {
	if h.deps.Allowance == nil {
		writeError(w, http.StatusServiceUnavailable, "api_error", "allowance_unavailable", "Allowance is not available right now")
		return
	}
	var body overageBody
	if err := decodeBody(r, w, &body); err != nil || body.Enabled == nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_body", "Body must be {\"enabled\": true|false}")
		return
	}
	if err := h.deps.Allowance.SetAllowanceOverage(r.Context(), p.AccountID, *body.Enabled, h.now()); err != nil {
		if errors.Is(err, billing.ErrAllowanceOverageRateLimited) {
			writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "overage_rate_limited", "Too many overage changes in the last 24 hours")
			return
		}
		writeError(w, http.StatusServiceUnavailable, "api_error", "allowance_unavailable", "Allowance is not available right now")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"object": "allowance_overage", "overage_enabled": *body.Enabled, "disclosure": Disclosure})
}

// handleAccount is the SPEC-050-R011 account view: stake, today's allowance,
// the next refresh, the overage setting, and the linked wallets.
func (h *handler) handleAccount(w http.ResponseWriter, r *http.Request, p principal) {
	if h.deps.Allowance == nil {
		writeError(w, http.StatusServiceUnavailable, "api_error", "allowance_unavailable", "Allowance is not available right now")
		return
	}
	now := h.now()
	status, err := h.deps.Allowance.AllowanceStatusFor(r.Context(), p.AccountID, now)
	if err != nil {
		h.deps.Logger.Warn().Err(err).Msg("allowance status failed")
		writeError(w, http.StatusServiceUnavailable, "api_error", "allowance_unavailable", "Allowance is not available right now")
		return
	}
	view := map[string]any{
		"object":                      "stake_allowance",
		"github_linked":               p.GitHubUserID > 0,
		"stake_source":                "unavailable",
		"staked_malibu":               nil,
		"unlocking_malibu":            nil,
		"next_unlock_release_at":      nil,
		"available_to_stake_malibu":   nil,
		"allowance_day":               status.Day,
		"allowance_credits":           status.GrantedCredits,
		"allowance_spent_credits":     status.SpentCredits,
		"allowance_held_credits":      status.HeldCredits,
		"allowance_remaining_credits": status.RemainingCredits,
		"next_refresh_at":             status.NextRefreshAt.UTC().Format(time.RFC3339),
		"overage_enabled":             status.OverageEnabled,
		"linked_wallets":              []string{},
		"disclosure":                  Disclosure,
	}
	var owned []string
	if p.GitHubUserID > 0 && h.deps.OwnedProviderIDs != nil {
		owned, err = h.deps.OwnedProviderIDs(r.Context(), p.GitHubUserID)
		if err != nil {
			h.deps.Logger.Warn().Err(err).Msg("stake: owned provider lookup failed")
			writeError(w, http.StatusServiceUnavailable, "api_error", "stake_source_unavailable", "Staking is not available right now")
			return
		}
	}
	if len(owned) > 0 && h.deps.PayoutAddresses != nil {
		wallets, err := h.deps.PayoutAddresses(r.Context(), owned)
		if err != nil {
			h.deps.Logger.Warn().Err(err).Msg("stake: payout address lookup failed")
		} else if wallets != nil {
			view["linked_wallets"] = wallets
		}
	}
	if h.deps.Ledger != nil {
		pos, err := h.deps.Ledger.Position(r.Context(), p.AccountID, owned)
		if err != nil {
			h.deps.Logger.Warn().Err(err).Msg("stake: position failed")
		} else {
			view["stake_source"] = "ledger_malibu_v1"
			view["staked_malibu"] = rewards.FormatMALIBUUnits(pos.StakedUnits)
			view["unlocking_malibu"] = rewards.FormatMALIBUUnits(pos.UnlockingUnits)
			view["available_to_stake_malibu"] = rewards.FormatMALIBUUnits(pos.AvailableUnits)
			if pos.NextReleaseAt != nil {
				view["next_unlock_release_at"] = pos.NextReleaseAt.UTC().Format(time.RFC3339)
			}
		}
	}
	writeJSON(w, http.StatusOK, view)
}
