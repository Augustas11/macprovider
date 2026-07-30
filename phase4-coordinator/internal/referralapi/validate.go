package referralapi

import (
	"bytes"
	"container/list"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

type ValidationStore interface {
	ValidateReferral(context.Context, auth.ReferralPolicy, string, time.Time) (auth.ReferralValidation, error)
}

// ReferralMetrics accepts only the closed event/outcome vocabulary enforced
// by the coordinator metrics implementation.
type ReferralMetrics interface {
	IncReferralEvent(event, outcome string)
}

// ValidationHandler is intentionally read-only. It exposes invite state for
// onboarding UX but does not reserve capacity; registration remains the sole
// authority that consumes a referral.
type ValidationHandler struct {
	Store         ValidationStore
	Policy        auth.ReferralPolicy
	PublicLimiter *BoundedLimiter
	ValidateSlots chan struct{}
	SourceIP      func(*http.Request) string
	Now           func() time.Time
	Metrics       ReferralMetrics
	// RequestAccessURL is optional operator configuration shared with the
	// public /j page. It is informational only and never grants admission.
	RequestAccessURL string
}

type validationResponse struct {
	Valid            bool   `json:"valid"`
	Required         bool   `json:"required"`
	Reason           string `json:"reason"`
	RequestAccessURL string `json:"request_access_url,omitempty"`
}

const validationBrowserOrigin = "https://malibu.tech"

func (h *ValidationHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Add("Vary", "Origin")
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin != "" {
		if origin != validationBrowserOrigin {
			writeError(w, http.StatusForbidden, "origin_forbidden", "browser origin is not allowed")
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", validationBrowserOrigin)
		w.Header().Set("Access-Control-Allow-Methods", http.MethodPost)
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Max-Age", "300")
	}
	if r.Method == http.MethodOptions {
		if origin == "" ||
			r.Header.Get("Access-Control-Request-Method") != http.MethodPost ||
			!onlyContentTypeRequested(r.Header.Values("Access-Control-Request-Headers")) {
			writeError(w, http.StatusForbidden, "preflight_forbidden", "browser preflight is not allowed")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	mediaType, parameters, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" ||
		(len(parameters) != 0 && !(len(parameters) == 1 && strings.EqualFold(parameters["charset"], "utf-8"))) {
		h.observe("bad_request")
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "application/json required")
		return
	}
	key := r.RemoteAddr
	if h.SourceIP != nil {
		key = h.SourceIP(r)
	}
	if h.ValidateSlots != nil {
		select {
		case h.ValidateSlots <- struct{}{}:
			defer func() { <-h.ValidateSlots }()
		default:
			h.observe("busy")
			w.Header().Set("Retry-After", "5")
			writeError(w, http.StatusServiceUnavailable, "busy", "invite validation is temporarily busy")
			return
		}
	}
	if h.PublicLimiter == nil || !h.PublicLimiter.Allow(key) {
		h.observe("rate_limited")
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many referral checks")
		return
	}
	// Decode and bound the request before consulting policy or authority so a
	// temporarily disabled public route retains the same abuse posture.
	var request struct {
		Code string `json:"code"`
	}
	if err := decodeBoundedJSON(r, &request, 1024); err != nil || len([]byte(request.Code)) > 256 {
		h.observe("bad_request")
		writeError(w, http.StatusBadRequest, "bad_request", "invalid request")
		return
	}
	if !h.Policy.RequireForRegistration {
		h.observe("disabled")
		h.writeValidation(w, true, false, "disabled")
		return
	}
	if h.Store == nil {
		h.observe("unavailable")
		writeError(w, http.StatusServiceUnavailable, "unavailable", "referral authority unavailable")
		return
	}
	validation, err := h.Store.ValidateReferral(r.Context(), h.Policy, request.Code, h.now())
	if err != nil {
		reason := referralReason(err)
		if reason == "invalid" && !errors.Is(err, auth.ErrReferralInvalid) {
			h.observe("unavailable")
			writeError(w, http.StatusServiceUnavailable, "unavailable", "referral authority unavailable")
			return
		}
		h.observe(reason)
		h.writeValidation(w, false, true, reason)
		return
	}
	h.observe("valid")
	h.writeValidation(w, validation.Valid, true, validation.Reason)
}

func onlyContentTypeRequested(values []string) bool {
	if len(values) == 0 {
		return true
	}
	var requested []string
	for _, value := range values {
		for _, header := range strings.Split(value, ",") {
			if trimmed := strings.TrimSpace(header); trimmed != "" {
				requested = append(requested, trimmed)
			}
		}
	}
	return len(requested) == 1 && strings.EqualFold(requested[0], "content-type")
}

func (h *ValidationHandler) observe(outcome string) {
	if h.Metrics != nil {
		h.Metrics.IncReferralEvent("validate", outcome)
	}
}

func (h *ValidationHandler) writeValidation(w http.ResponseWriter, valid, required bool, reason string) {
	writeJSON(w, http.StatusOK, validationResponse{
		Valid:            valid,
		Required:         required,
		Reason:           reason,
		RequestAccessURL: strings.TrimSpace(h.RequestAccessURL),
	})
}

func (h *ValidationHandler) now() time.Time {
	if h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}

func referralReason(err error) string {
	switch {
	case errors.Is(err, auth.ErrReferralRequired):
		return "missing"
	case errors.Is(err, auth.ErrReferralExpired):
		return "expired"
	case errors.Is(err, auth.ErrReferralRevoked):
		return "revoked"
	case errors.Is(err, auth.ErrReferralExhausted):
		return "exhausted"
	case errors.Is(err, auth.ErrReferralConflict):
		return "conflict"
	default:
		return "invalid"
	}
}

func decodeBoundedJSON(r *http.Request, dst any, max int64) error {
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, max+1))
	if err != nil || int64(len(body)) > max {
		return fmt.Errorf("body too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("request must contain exactly one JSON value")
	}
	return nil
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

type limiterEntry struct {
	windowStart time.Time
	count       int
	element     *list.Element
}

type BoundedLimiter struct {
	mu         sync.Mutex
	limit      int
	window     time.Duration
	maxEntries int
	now        func() time.Time
	entries    map[string]limiterEntry
	oldest     *list.List
}

func NewBoundedLimiter(limit int, window time.Duration, maxEntries int) *BoundedLimiter {
	return &BoundedLimiter{
		limit: limit, window: window, maxEntries: maxEntries,
		now: time.Now, entries: map[string]limiterEntry{}, oldest: list.New(),
	}
}

func (l *BoundedLimiter) Allow(key string) bool {
	if l == nil || l.limit <= 0 || l.window <= 0 || l.maxEntries <= 0 {
		return false
	}
	now := l.now().UTC()
	l.mu.Lock()
	defer l.mu.Unlock()
	// Expiration is ordered by window start and bounded per call. This keeps a
	// distributed-key flood from turning every request into a full-map scan.
	for removed := 0; removed < 16; removed++ {
		front := l.oldest.Front()
		if front == nil {
			break
		}
		key := front.Value.(string)
		entry, ok := l.entries[key]
		if !ok || entry.element != front {
			l.oldest.Remove(front)
			continue
		}
		if now.Sub(entry.windowStart) < l.window {
			break
		}
		delete(l.entries, key)
		l.oldest.Remove(front)
	}
	entry, ok := l.entries[key]
	if !ok {
		if len(l.entries) >= l.maxEntries {
			// Never reset an active caller's budget merely to admit a new key.
			return false
		}
		element := l.oldest.PushBack(key)
		l.entries[key] = limiterEntry{windowStart: now, count: 1, element: element}
		return true
	}
	if now.Sub(entry.windowStart) >= l.window {
		l.oldest.Remove(entry.element)
		entry.windowStart = now
		entry.count = 1
		entry.element = l.oldest.PushBack(key)
		l.entries[key] = entry
		return true
	}
	if entry.count >= l.limit {
		return false
	}
	entry.count++
	l.entries[key] = entry
	return true
}
