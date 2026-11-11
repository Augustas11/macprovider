package router

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
)

// BuyerHoldStartEnv, when "1" in the process environment, starts the gateway
// with the buyer hold on. The Pearl updater sets it in a runtime unit drop-in
// while a database restore is still possible, so a restart in that window also
// starts held, and removes it at commit, rollback or reconcile (SPEC-006-R027).
const BuyerHoldStartEnv = "MACPROVIDER_GATEWAY_START_BUYER_HOLD"

// buyerHoldState is the rollout buyer hold (SPEC-006-R027). While active the
// gateway refuses new requests on buyer routes with 503 and Retry-After;
// requests already in flight are untouched. A request whose bearer is the API
// key admitted by its sha256 (the rollout's buyer canary) still passes. The
// state is in memory only.
type buyerHoldState struct {
	mu       sync.RWMutex
	active   bool
	admit    [sha256.Size]byte
	hasAdmit bool
}

// WithBuyerHoldAtStart starts the server with the buyer hold on and no
// admitted key; the operator admits the canary key through /admin/buyer-hold.
func WithBuyerHoldAtStart(active bool) Option {
	return func(s *Server) {
		s.buyerHold.mu.Lock()
		s.buyerHold.active = active
		s.buyerHold.mu.Unlock()
	}
}

func (s *Server) buyerHoldActive() bool {
	s.buyerHold.mu.RLock()
	defer s.buyerHold.mu.RUnlock()
	return s.buyerHold.active
}

// buyerHeld reports whether the hold refuses this request. Operator, health,
// status and metrics routes are never held, exactly as for the all-public kill
// switch.
func (s *Server) buyerHeld(r *http.Request) bool {
	path := r.URL.Path
	if strings.HasPrefix(path, "/admin/") || path == "/v1/status" || path == "/healthz" || path == "/metrics" {
		return false
	}
	s.buyerHold.mu.RLock()
	active, admit, hasAdmit := s.buyerHold.active, s.buyerHold.admit, s.buyerHold.hasAdmit
	s.buyerHold.mu.RUnlock()
	if !active {
		return false
	}
	if !hasAdmit {
		return true
	}
	token, ok := strings.CutPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ")
	if !ok {
		return true
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return true
	}
	presented := sha256.Sum256([]byte(token))
	return !hmac.Equal(presented[:], admit[:])
}

func (s *Server) writeBuyerHeld(w http.ResponseWriter, r *http.Request) {
	const message = "The API is paused briefly for maintenance. Please retry shortly."
	if r.URL.Path == "/v1/messages" && s.cfg.Features.AnthropicMessagesEnabled {
		writeAnthropicMessagesError(w, http.StatusServiceUnavailable, "server_error", "public_api_paused", message)
		return
	}
	writeError(w, http.StatusServiceUnavailable, "server_error", "public_api_paused", message)
}

// handleBuyerHold reads (GET) or turns on or off (POST) the rollout buyer
// hold. Operator key only; the updater's GET proves the key before it stops
// anything. POST body: {"active": bool, "admit_api_key_sha256": "<64 hex>"};
// the admitted hash applies only while active and is cleared when the hold is
// turned off.
func (s *Server) handleBuyerHold(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	if r.Method == http.MethodGet {
		s.buyerHold.mu.RLock()
		active, hasAdmit := s.buyerHold.active, s.buyerHold.hasAdmit
		s.buyerHold.mu.RUnlock()
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":         true,
			"buyer_hold": map[string]any{"active": active, "canary_admitted": active && hasAdmit},
		})
		return
	}
	var req struct {
		Active            *bool  `json:"active"`
		AdmitAPIKeySHA256 string `json:"admit_api_key_sha256"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || req.Active == nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_buyer_hold", "Invalid buyer hold request")
		return
	}
	var admit [sha256.Size]byte
	hasAdmit := false
	if req.AdmitAPIKeySHA256 != "" {
		raw, err := hex.DecodeString(req.AdmitAPIKeySHA256)
		if err != nil || len(raw) != sha256.Size || !*req.Active {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_buyer_hold", "Invalid buyer hold request")
			return
		}
		copy(admit[:], raw)
		hasAdmit = true
	}
	s.buyerHold.mu.Lock()
	previous := s.buyerHold.active
	s.buyerHold.active = *req.Active
	s.buyerHold.admit = admit
	s.buyerHold.hasAdmit = hasAdmit
	s.buyerHold.mu.Unlock()
	slog.Info("buyer hold set", "request_id", requestID(r), "previous", previous, "active", *req.Active, "canary_admitted", hasAdmit)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"buyer_hold": map[string]any{"active": *req.Active, "canary_admitted": hasAdmit},
	})
}
