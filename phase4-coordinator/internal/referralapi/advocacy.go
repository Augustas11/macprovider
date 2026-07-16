package referralapi

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

type AdvocacyStore interface {
	ProviderReferralStatus(context.Context, auth.ReferralPolicy, string) (auth.ProviderReferral, error)
	CreateSocialChallenge(context.Context, auth.ReferralPolicy, string, time.Time) (auth.SocialChallenge, error)
	PreflightSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, time.Time) (auth.ProviderReferral, bool, error)
	CompleteSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, time.Time) (auth.ProviderReferral, error)
	ConsumeSocialRateLimit(context.Context, auth.ReferralPolicy, string, string, time.Time, time.Duration, int) (bool, error)
	RecordSocialAudit(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, string, time.Time) error
}

type ProviderTokenValidator interface {
	ValidateTokenReadOnly(context.Context, string) (string, bool, error)
}

type PostVerifier interface {
	VerifyPost(context.Context, string, string) (string, error)
}

// AdvocacyHandler owns the provider-authenticated referral endpoints. It never
// consumes invite capacity; only provider registration creates redemptions.
type AdvocacyHandler struct {
	Store           AdvocacyStore
	Tokens          ProviderTokenValidator
	PostVerifier    PostVerifier
	Policy          auth.ReferralPolicy
	PublicLimiter   *BoundedLimiter
	ProviderLimiter *BoundedLimiter
	AuthSlots       chan struct{}
	VerifySlots     chan struct{}
	SourceIP        func(*http.Request) string
	Now             func() time.Time
	JoinBaseURL     string
	Metrics         ReferralMetrics
}

func (h *AdvocacyHandler) HandleStatus(w http.ResponseWriter, r *http.Request) {
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
		h.observe("status", "locked")
		h.writeStatus(w, status)
		return
	}
	if err != nil {
		h.observe("status", "error")
		writeError(w, http.StatusServiceUnavailable, "referral_state_unavailable", "provider referral state unavailable")
		return
	}
	if status.SocialState != "" {
		h.observe("status", status.SocialState)
	}
	h.writeStatus(w, status)
}

func (h *AdvocacyHandler) HandleChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	providerID, ok := h.authenticate(w, r)
	if !ok {
		return
	}
	if !h.Policy.EnableSocialBonus {
		h.observe("challenge", "disabled")
		writeError(w, http.StatusNotFound, "social_bonus_disabled", "social invite bonus is disabled")
		return
	}
	if h.ProviderLimiter == nil || !h.ProviderLimiter.Allow("challenge:"+providerID) {
		w.Header().Set("Retry-After", "60")
		h.observe("challenge", "rate_limited")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many social challenge requests")
		return
	}
	allowed, err := h.Store.ConsumeSocialRateLimit(r.Context(), h.Policy, providerID, "challenge", h.now(), time.Minute, 5)
	if err != nil {
		h.observe("challenge", "error")
		writeError(w, http.StatusServiceUnavailable, "rate_limit_unavailable", "social challenge is temporarily unavailable")
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		h.observe("challenge", "rate_limited")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many social challenge requests")
		return
	}
	challenge, err := h.Store.CreateSocialChallenge(r.Context(), h.Policy, providerID, h.now())
	if err != nil {
		if errors.Is(err, auth.ErrReferralLocked) {
			h.observe("challenge", "locked")
			writeError(w, http.StatusConflict, "first_serving_required", "complete one verified serving before sharing")
			return
		}
		if errors.Is(err, auth.ErrSocialChallenge) {
			h.observe("challenge", "conflict")
			writeError(w, http.StatusConflict, "challenge_unavailable", "social challenge unavailable")
			return
		}
		h.observe("challenge", "error")
		writeError(w, http.StatusServiceUnavailable, "challenge_unavailable", "social challenge temporarily unavailable")
		return
	}
	shareURL := strings.TrimRight(strings.TrimSpace(h.JoinBaseURL), "/") + "/" +
		url.PathEscape(challenge.Code) + "?c=" + url.QueryEscape(challenge.Cleartext)
	copy := "My Mac just joined Malibu's pre-beta compute network. If you have a Mac and want early access: " + shareURL
	h.observe("challenge", "created")
	writeJSON(w, http.StatusOK, map[string]any{
		"intent_url": "https://twitter.com/intent/tweet?text=" + url.QueryEscape(copy),
		"share_url":  shareURL,
		"expires_at": challenge.ExpiresAt.UTC().Format(time.RFC3339),
	})
}

func (h *AdvocacyHandler) HandleVerify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	providerID, ok := h.authenticate(w, r)
	if !ok {
		return
	}
	if !h.Policy.EnableSocialBonus || h.PostVerifier == nil {
		h.observe("x_verify", "disabled")
		writeError(w, http.StatusNotFound, "social_bonus_disabled", "social invite bonus is disabled")
		return
	}
	if h.ProviderLimiter == nil || !h.ProviderLimiter.Allow("verify:"+providerID) {
		w.Header().Set("Retry-After", "60")
		h.observe("x_verify", "rate_limited")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many social verification requests")
		return
	}
	allowed, err := h.Store.ConsumeSocialRateLimit(r.Context(), h.Policy, providerID, "submit", h.now(), time.Minute, 5)
	if err != nil {
		h.observe("x_verify", "error")
		writeError(w, http.StatusServiceUnavailable, "rate_limit_unavailable", "social verification is temporarily unavailable")
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		h.observe("x_verify", "rate_limited")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many social verification requests")
		return
	}
	var request struct {
		PostURL   string `json:"post_url"`
		Challenge string `json:"challenge"`
	}
	if err := decodeBoundedJSON(r, &request, 2048); err != nil || len(request.Challenge) != 64 {
		h.observe("x_verify", "bad_request")
		writeError(w, http.StatusBadRequest, "bad_request", "invalid verification request")
		return
	}
	postID, err := ParseXPostID(request.PostURL)
	if err != nil {
		h.observe("x_verify", "bad_request")
		writeError(w, http.StatusBadRequest, "invalid_post_url", "use a public x.com post URL")
		return
	}
	submittedAt := h.now()
	status, replayed, err := h.Store.PreflightSocialVerification(r.Context(), h.Policy, providerID, request.Challenge, postID, submittedAt)
	if err != nil {
		if errors.Is(err, auth.ErrSocialChallenge) {
			h.observe("x_verify", "conflict")
			writeError(w, http.StatusConflict, "challenge_invalid", "challenge expired, reused, or belongs to another provider")
			return
		}
		h.observe("x_verify", "error")
		writeError(w, http.StatusServiceUnavailable, "verification_state_unavailable", "social verification is temporarily unavailable")
		return
	}
	if replayed {
		h.observe("x_verify", "replayed")
		h.writeStatus(w, status)
		return
	}
	status, err = h.Store.ProviderReferralStatus(r.Context(), h.Policy, providerID)
	if err != nil || status.Code == "" {
		h.observe("x_verify", "conflict")
		writeError(w, http.StatusConflict, "referral_locked", "provider invite is not available")
		return
	}
	expectedURL := strings.TrimRight(strings.TrimSpace(h.JoinBaseURL), "/") + "/" +
		url.PathEscape(status.Code) + "?c=" + url.QueryEscape(request.Challenge)
	if h.VerifySlots != nil {
		select {
		case h.VerifySlots <- struct{}{}:
			defer func() { <-h.VerifySlots }()
		default:
			h.observe("x_verify", "busy")
			writeError(w, http.StatusServiceUnavailable, "verification_busy", "social verification is temporarily busy")
			return
		}
	}
	authorID, err := h.PostVerifier.VerifyPost(r.Context(), postID, expectedURL)
	if errors.Is(err, ErrXPostTransient) {
		if auditErr := h.Store.RecordSocialAudit(
			r.Context(), h.Policy, providerID, request.Challenge, postID, "",
			"external_verify", "transient", "x_unavailable", h.now(),
		); auditErr != nil {
			h.observe("x_verify", "error")
			writeError(w, http.StatusServiceUnavailable, "verification_audit_unavailable", "social verification is temporarily unavailable")
			return
		}
		w.Header().Set("Retry-After", "30")
		h.observe("x_verify", "unavailable")
		writeError(w, http.StatusServiceUnavailable, "verification_unavailable", "social verification is temporarily unavailable")
		return
	}
	if err != nil || strings.TrimSpace(authorID) == "" {
		reason := "post_not_verified"
		if err == nil {
			reason = "author_missing"
		}
		if auditErr := h.Store.RecordSocialAudit(
			r.Context(), h.Policy, providerID, request.Challenge, postID, authorID,
			"external_verify", "terminal", reason, h.now(),
		); auditErr != nil {
			h.observe("x_verify", "error")
			writeError(w, http.StatusServiceUnavailable, "verification_audit_unavailable", "social verification is temporarily unavailable")
			return
		}
		h.observe("x_verify", "failed")
		writeError(w, http.StatusUnprocessableEntity, "post_not_verified", "post is unavailable or does not contain the invite link")
		return
	}
	shareURLHash, err := ShareURLDigest(expectedURL, h.JoinBaseURL)
	if err != nil {
		h.observe("x_verify", "error")
		writeError(w, http.StatusInternalServerError, "verification_config_invalid", "social verification is unavailable")
		return
	}
	status, err = h.Store.CompleteSocialVerification(
		r.Context(), h.Policy, providerID, request.Challenge, postID, authorID, shareURLHash, "x_api", submittedAt,
	)
	if err != nil {
		if errors.Is(err, auth.ErrSocialChallenge) {
			h.observe("x_verify", "conflict")
			writeError(w, http.StatusConflict, "challenge_invalid", "challenge expired, reused, or belongs to another provider")
			return
		}
		h.observe("x_verify", "error")
		writeError(w, http.StatusServiceUnavailable, "verification_state_unavailable", "social verification is temporarily unavailable")
		return
	}
	h.observe("x_verify", "pending")
	h.writeStatus(w, status)
}

func (h *AdvocacyHandler) authenticate(w http.ResponseWriter, r *http.Request) (string, bool) {
	key := r.RemoteAddr
	if h.SourceIP != nil {
		key = h.SourceIP(r)
	}
	if h.PublicLimiter == nil || !h.PublicLimiter.Allow("advocacy:"+key) {
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "too many provider referral requests")
		return "", false
	}
	if h.AuthSlots != nil {
		select {
		case h.AuthSlots <- struct{}{}:
			defer func() { <-h.AuthSlots }()
		default:
			w.Header().Set("Retry-After", "5")
			writeError(w, http.StatusServiceUnavailable, "auth_busy", "provider authentication is temporarily busy")
			return "", false
		}
	}
	raw := strings.TrimSpace(r.Header.Get("Authorization"))
	token, ok := strings.CutPrefix(raw, "Bearer ")
	if !ok || strings.TrimSpace(token) == "" || h.Tokens == nil || h.Store == nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return "", false
	}
	providerID, valid, err := h.Tokens.ValidateTokenReadOnly(r.Context(), strings.TrimSpace(token))
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

func (h *AdvocacyHandler) writeStatus(w http.ResponseWriter, status auth.ProviderReferral) {
	configuredBonusCapacity := 0
	if h.Policy.EnableSocialBonus {
		configuredBonusCapacity = h.Policy.SocialBonusUses
	}
	body := map[string]any{
		"campaign":                  status.Campaign,
		"social_state":              status.SocialState,
		"base_capacity":             status.BaseCapacity,
		"configured_bonus_capacity": configuredBonusCapacity,
		"bonus_capacity":            status.BonusCapacity,
		"redemptions":               status.Redemptions,
		"remaining":                 status.Remaining,
		"first_serving_seen":        status.FirstServingSeen,
		"social_bonus_enabled":      h.Policy.EnableSocialBonus,
	}
	if status.Code != "" {
		body["invite_code"] = status.Code
		body["invite_url"] = strings.TrimRight(strings.TrimSpace(h.JoinBaseURL), "/") + "/" + url.PathEscape(status.Code)
	}
	writeJSON(w, http.StatusOK, body)
}

func (h *AdvocacyHandler) now() time.Time {
	if h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}

func (h *AdvocacyHandler) observe(event, outcome string) {
	if h.Metrics != nil {
		h.Metrics.IncReferralEvent(event, outcome)
	}
}
