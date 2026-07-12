package referralapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

type Store interface {
	ValidateReferral(context.Context, auth.ReferralPolicy, string, time.Time) (auth.ReferralValidation, error)
	ProviderReferralStatus(context.Context, auth.ReferralPolicy, string) (auth.ProviderReferral, error)
	EnsureProviderReferral(context.Context, auth.ReferralPolicy, string, time.Time) (auth.ProviderReferral, error)
	CreateSocialChallenge(context.Context, auth.ReferralPolicy, string, time.Time) (auth.SocialChallenge, error)
	ValidateSocialChallenge(context.Context, auth.ReferralPolicy, string, string, time.Time) error
	CompleteSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, string, time.Time) (auth.ProviderReferral, error)
}

type TokenValidator interface {
	ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error)
}

type ServingEvidence interface {
	FirstVerifiedServing(context.Context, string) (time.Time, bool, error)
}

type PostVerifier interface {
	VerifyPost(context.Context, string, string) error
}

type Metrics interface {
	IncReferralEvent(event, outcome string)
}

type Handler struct {
	Store           Store
	Tokens          TokenValidator
	ServingEvidence ServingEvidence
	PostVerifier    PostVerifier
	Policy          auth.ReferralPolicy
	PublicLimiter   *BoundedLimiter
	ProviderLimiter *BoundedLimiter
	VerifySlots     chan struct{}
	ValidateSlots   chan struct{}
	SourceIP        func(*http.Request) string
	Now             func() time.Time
	JoinBaseURL     string
	Metrics         Metrics
}

func (h *Handler) HandleValidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if !h.Policy.RequireForRegistration {
		h.observe("validate", "disabled")
		writeJSON(w, http.StatusOK, map[string]any{"valid": true, "required": false, "reason": "disabled"})
		return
	}
	key := r.RemoteAddr
	if h.SourceIP != nil {
		key = h.SourceIP(r)
	}
	if h.PublicLimiter == nil || !h.PublicLimiter.Allow(key) {
		h.observe("validate", "rate_limited")
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many referral checks")
		return
	}
	if h.ValidateSlots != nil {
		if !h.acquireValidationSlot(w, "validate") {
			return
		}
		defer func() { <-h.ValidateSlots }()
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := decodeBoundedJSON(r, &req, 1024); err != nil || len([]byte(req.Code)) > 256 {
		h.observe("validate", "bad_request")
		writeError(w, http.StatusBadRequest, "bad_request", "invalid request")
		return
	}
	validation, err := h.Store.ValidateReferral(r.Context(), h.Policy, req.Code, h.now())
	if err != nil {
		reason := referralReason(err)
		h.observe("validate", reason)
		writeJSON(w, http.StatusOK, map[string]any{"valid": false, "required": true, "reason": reason})
		return
	}
	h.observe("validate", "valid")
	writeJSON(w, http.StatusOK, map[string]any{"valid": validation.Valid, "required": true, "reason": validation.Reason})
}

var joinPage = template.Must(template.New("join").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>You're invited to Malibu</title>
<style>body{margin:0;background:#101116;color:#f7f3ee;font:17px system-ui,sans-serif}main{max-width:620px;margin:10vh auto;padding:32px}h1{font-size:42px;margin:.2em 0}.card{background:#1b1d25;border-radius:18px;padding:26px}code{display:block;overflow-wrap:anywhere;background:#0b0c10;padding:12px;border-radius:8px}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}a,button{border:0;border-radius:9px;padding:12px 16px;font:inherit;font-weight:650;cursor:pointer}a{background:#ff765f;color:#171717;text-decoration:none}button{background:#343744;color:#fff}</style></head>
<body><main><p>Malibu pre-beta</p><h1>Put your Mac to work.</h1><div class="card"><p>You've been invited to join Malibu's private pre-beta compute network.</p>
<p>Invite code</p><code id="invite">{{.Code}}</code><div class="actions"><a href="https://download.malibu.tech/latest.dmg">Download Malibu</a><button id="copy" type="button">Copy invite code</button></div>
<p id="copied" aria-live="polite"></p><p>You choose when to launch the provider after installing Malibu.</p></div></main>
<script>document.getElementById('copy').addEventListener('click',async()=>{await navigator.clipboard.writeText(document.getElementById('invite').textContent);document.getElementById('copied').textContent='Invite code copied.'})</script></body></html>`))

var joinFullPage = template.Must(template.New("join-full").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Malibu pre-beta invite</title>
<style>body{margin:0;background:#101116;color:#f7f3ee;font:17px system-ui,sans-serif}main{max-width:620px;margin:10vh auto;padding:32px}h1{font-size:42px}.card{background:#1b1d25;border-radius:18px;padding:26px}a{display:inline-block;border-radius:9px;padding:12px 16px;background:#ff765f;color:#171717;text-decoration:none;font-weight:650}</style></head>
<body><main><p>Malibu pre-beta</p><h1>This invite filled up.</h1><div class="card"><p>All early-access spots on this invite have been claimed. Malibu is building a network that lets Macs contribute useful compute.</p><a href="https://malibu.tech">Learn more about Malibu</a></div></main></body></html>`))

func (h *Handler) HandleJoin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	key := r.RemoteAddr
	if h.SourceIP != nil {
		key = h.SourceIP(r)
	}
	if h.PublicLimiter == nil || !h.PublicLimiter.Allow("join:"+key) {
		h.observe("join", "rate_limited")
		http.Error(w, "too many invite checks", http.StatusTooManyRequests)
		return
	}
	if h.ValidateSlots != nil {
		if !h.acquireValidationSlot(w, "join") {
			return
		}
		defer func() { <-h.ValidateSlots }()
	}
	code := strings.TrimPrefix(r.URL.Path, "/j/")
	if code == "" || strings.Contains(code, "/") || len(code) > 256 {
		h.observe("join", "not_found")
		http.NotFound(w, r)
		return
	}
	if _, err := h.Store.ValidateReferral(r.Context(), h.Policy, code, h.now()); errors.Is(err, auth.ErrReferralExhausted) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		h.observe("join", "full")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = joinFullPage.Execute(w, nil)
		return
	} else if err != nil {
		h.observe("join", "not_found")
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	h.observe("join", "served")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if err := joinPage.Execute(w, struct{ Code string }{Code: code}); err != nil {
		return
	}
}

func (h *Handler) acquireValidationSlot(w http.ResponseWriter, event string) bool {
	if h.ValidateSlots == nil {
		return true
	}
	select {
	case h.ValidateSlots <- struct{}{}:
		return true
	default:
		h.observe(event, "busy")
		w.Header().Set("Retry-After", "5")
		http.Error(w, "invite validation is temporarily busy", http.StatusServiceUnavailable)
		return false
	}
}

func (h *Handler) HandleProviderStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET required")
		return
	}
	providerID, ok := h.authenticate(w, r)
	if !ok {
		return
	}
	status, err := h.Store.ProviderReferralStatus(r.Context(), h.Policy, providerID)
	if errors.Is(err, auth.ErrReferralLocked) {
		if h.ServingEvidence == nil {
			h.observe("status", "locked")
			h.writeProviderStatus(w, status)
			return
		}
		first, eligible, evidenceErr := h.ServingEvidence.FirstVerifiedServing(r.Context(), providerID)
		if evidenceErr != nil {
			h.observe("status", "error")
			writeError(w, http.StatusServiceUnavailable, "serving_evidence_unavailable", "serving evidence unavailable")
			return
		}
		if !eligible {
			h.observe("status", "locked")
			h.writeProviderStatus(w, status)
			return
		}
		status, err = h.Store.EnsureProviderReferral(r.Context(), h.Policy, providerID, first)
	}
	if err != nil {
		h.observe("status", "error")
		writeError(w, http.StatusInternalServerError, "internal_error", "provider referral state unavailable")
		return
	}
	h.observe("status", statusOutcome(status))
	h.writeProviderStatus(w, status)
}

func (h *Handler) HandleChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	providerID, ok := h.authenticate(w, r)
	if !ok {
		return
	}
	if h.ProviderLimiter != nil && !h.ProviderLimiter.Allow("challenge:"+providerID) {
		w.Header().Set("Retry-After", "60")
		h.observe("challenge", "error")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many social challenge requests")
		return
	}
	if !h.Policy.EnableSocialBonus {
		h.observe("challenge", "disabled")
		writeError(w, http.StatusNotFound, "social_bonus_disabled", "social invite bonus is disabled")
		return
	}
	if h.ServingEvidence == nil {
		h.observe("challenge", "error")
		writeError(w, http.StatusServiceUnavailable, "serving_evidence_unavailable", "serving evidence unavailable")
		return
	}
	first, eligible, err := h.ServingEvidence.FirstVerifiedServing(r.Context(), providerID)
	if err != nil {
		h.observe("challenge", "error")
		writeError(w, http.StatusServiceUnavailable, "serving_evidence_unavailable", "serving evidence unavailable")
		return
	}
	if !eligible {
		h.observe("challenge", "locked")
		writeError(w, http.StatusConflict, "first_serving_required", "complete one verified serving before sharing")
		return
	}
	if _, err := h.Store.EnsureProviderReferral(r.Context(), h.Policy, providerID, first); err != nil {
		h.observe("challenge", "error")
		writeError(w, http.StatusInternalServerError, "internal_error", "provider referral state unavailable")
		return
	}
	challenge, err := h.Store.CreateSocialChallenge(r.Context(), h.Policy, providerID, h.now())
	if err != nil {
		h.observe("challenge", "error")
		writeError(w, http.StatusConflict, "challenge_unavailable", "social challenge unavailable")
		return
	}
	joinBase := strings.TrimRight(strings.TrimSpace(h.JoinBaseURL), "/")
	if joinBase == "" {
		joinBase = "https://coordinator.streamvc.live/j"
	}
	shareURL := joinBase + "/" + url.PathEscape(challenge.Code) + "?c=" + url.QueryEscape(challenge.Cleartext)
	copy := "My Mac just joined Malibu's pre-beta compute network. If you have a Mac and want early access: " + shareURL
	intentURL := "https://twitter.com/intent/tweet?text=" + url.QueryEscape(copy)
	h.observe("challenge", "created")
	writeJSON(w, http.StatusOK, map[string]any{
		"intent_url": intentURL,
		"share_url":  shareURL,
		"expires_at": challenge.ExpiresAt.UTC().Format(time.RFC3339),
	})
}

func (h *Handler) HandleVerify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	providerID, ok := h.authenticate(w, r)
	if !ok {
		return
	}
	if h.ProviderLimiter != nil && !h.ProviderLimiter.Allow("verify:"+providerID) {
		w.Header().Set("Retry-After", "60")
		h.observe("x_verify", "failed")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many social verification requests")
		return
	}
	if !h.Policy.EnableSocialBonus || h.PostVerifier == nil {
		h.observe("x_verify", "disabled")
		writeError(w, http.StatusNotFound, "social_bonus_disabled", "social invite bonus is disabled")
		return
	}
	var req struct {
		PostURL   string `json:"post_url"`
		Challenge string `json:"challenge"`
	}
	if err := decodeBoundedJSON(r, &req, 2048); err != nil || len(req.Challenge) != 64 {
		h.observe("x_verify", "bad_request")
		writeError(w, http.StatusBadRequest, "bad_request", "invalid verification request")
		return
	}
	postID, err := ParseXPostID(req.PostURL)
	if err != nil {
		h.observe("x_verify", "bad_request")
		writeError(w, http.StatusBadRequest, "invalid_post_url", "use a public x.com post URL")
		return
	}
	status, err := h.Store.ProviderReferralStatus(r.Context(), h.Policy, providerID)
	if err != nil {
		h.observe("x_verify", "conflict")
		writeError(w, http.StatusConflict, "referral_locked", "provider invite is not available")
		return
	}
	joinBase := strings.TrimRight(strings.TrimSpace(h.JoinBaseURL), "/")
	if joinBase == "" {
		joinBase = "https://coordinator.streamvc.live/j"
	}
	expectedURL := joinBase + "/" + status.Code + "?c=" + req.Challenge
	if err := h.Store.ValidateSocialChallenge(r.Context(), h.Policy, providerID, req.Challenge, h.now()); err != nil {
		h.observe("x_verify", "conflict")
		writeError(w, http.StatusConflict, "challenge_invalid", "social challenge is invalid or expired")
		return
	}
	if h.VerifySlots != nil {
		select {
		case h.VerifySlots <- struct{}{}:
			defer func() { <-h.VerifySlots }()
		default:
			h.observe("x_verify", "failed")
			writeError(w, http.StatusServiceUnavailable, "verification_busy", "social verification is temporarily busy")
			return
		}
	}
	if err := h.PostVerifier.VerifyPost(r.Context(), postID, expectedURL); err != nil {
		h.observe("x_verify", "failed")
		writeError(w, http.StatusUnprocessableEntity, "post_not_verified", "post is unavailable or does not contain the invite link")
		return
	}
	status, err = h.Store.CompleteSocialVerification(r.Context(), h.Policy, providerID, req.Challenge, postID, "x_api", h.now())
	if err != nil {
		h.observe("x_verify", "conflict")
		writeError(w, http.StatusConflict, "challenge_invalid", "challenge expired, reused, or belongs to another provider")
		return
	}
	h.observe("x_verify", "verified")
	h.writeProviderStatus(w, status)
}

func (h *Handler) authenticate(w http.ResponseWriter, r *http.Request) (string, bool) {
	raw := strings.TrimSpace(r.Header.Get("Authorization"))
	token, ok := strings.CutPrefix(raw, "Bearer ")
	if !ok || strings.TrimSpace(token) == "" || h.Tokens == nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return "", false
	}
	providerID, valid, err := h.Tokens.ValidateAndMarkTokenUsed(r.Context(), strings.TrimSpace(token))
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "auth_unavailable", "provider authentication unavailable")
		return "", false
	}
	if !valid {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token invalid")
		return "", false
	}
	return providerID, true
}

func (h *Handler) now() time.Time {
	if h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}

func (h *Handler) observe(event, outcome string) {
	if h.Metrics != nil {
		h.Metrics.IncReferralEvent(event, outcome)
	}
}

func statusOutcome(status auth.ProviderReferral) string {
	if status.SocialVerified {
		return "verified"
	}
	if status.FirstServingSeen {
		return "eligible"
	}
	return "locked"
}

func (h *Handler) writeProviderStatus(w http.ResponseWriter, status auth.ProviderReferral) {
	joinBase := strings.TrimRight(strings.TrimSpace(h.JoinBaseURL), "/")
	writeJSON(w, http.StatusOK, map[string]any{
		"campaign":             status.Campaign,
		"advocacy_status":      status.AdvocacyStatus,
		"invite_code":          status.Code,
		"base_uses":            status.BaseUses,
		"bonus_uses":           status.BonusUses,
		"used":                 status.Used,
		"remaining":            status.Remaining,
		"social_verified":      status.SocialVerified,
		"first_serving_seen":   status.FirstServingSeen,
		"social_bonus_enabled": h.Policy.EnableSocialBonus,
		"invite_url":           joinBase + "/" + url.PathEscape(status.Code),
	})
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
}

type BoundedLimiter struct {
	mu         sync.Mutex
	limit      int
	window     time.Duration
	maxEntries int
	now        func() time.Time
	entries    map[string]limiterEntry
}

func NewBoundedLimiter(limit int, window time.Duration, maxEntries int) *BoundedLimiter {
	return &BoundedLimiter{limit: limit, window: window, maxEntries: maxEntries, now: time.Now, entries: map[string]limiterEntry{}}
}

func (l *BoundedLimiter) Allow(key string) bool {
	if l == nil || l.limit <= 0 || l.window <= 0 || l.maxEntries <= 0 {
		return false
	}
	now := l.now().UTC()
	l.mu.Lock()
	defer l.mu.Unlock()
	for k, entry := range l.entries {
		if now.Sub(entry.windowStart) >= l.window {
			delete(l.entries, k)
		}
	}
	entry, ok := l.entries[key]
	if !ok {
		if len(l.entries) >= l.maxEntries {
			var oldestKey string
			var oldest time.Time
			for k, candidate := range l.entries {
				if oldestKey == "" || candidate.windowStart.Before(oldest) {
					oldestKey, oldest = k, candidate.windowStart
				}
			}
			delete(l.entries, oldestKey)
		}
		l.entries[key] = limiterEntry{windowStart: now, count: 1}
		return true
	}
	if entry.count >= l.limit {
		return false
	}
	entry.count++
	l.entries[key] = entry
	return true
}
