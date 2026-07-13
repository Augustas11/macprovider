package referralapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

type advocacyTokens struct {
	providerID string
	err        error
	calls      *int
}

func (s advocacyTokens) ValidateTokenReadOnly(_ context.Context, token string) (string, bool, error) {
	if s.calls != nil {
		(*s.calls)++
	}
	return s.providerID, token == "valid-token", s.err
}

type advocacyServing struct {
	when     time.Time
	eligible bool
	err      error
}

func (s advocacyServing) FirstVerifiedServing(context.Context, string) (time.Time, bool, error) {
	return s.when, s.eligible, s.err
}

type advocacyVerifier struct {
	postID      string
	expectedURL string
	authorID    string
	err         error
}

func (v *advocacyVerifier) VerifyPost(_ context.Context, postID, expectedURL string) (string, error) {
	v.postID = postID
	v.expectedURL = expectedURL
	return v.authorID, v.err
}

type advocacyMetrics struct {
	events []string
}

func (m *advocacyMetrics) IncReferralEvent(event, outcome string) {
	m.events = append(m.events, event+"/"+outcome)
}

func advocacyPolicy() auth.ReferralPolicy {
	return auth.ReferralPolicy{
		RequireForRegistration: true,
		EnableSocialBonus:      true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": strings.Repeat("s", 32)},
		ProviderBaseUses:       1,
		SocialBonusUses:        2,
		ChallengeTTL:           15 * time.Minute,
	}
}

func openAdvocacyStore(t *testing.T) *auth.Store {
	t.Helper()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func bearerRequest(method, target, body string) *http.Request {
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer valid-token")
	return request
}

func TestAdvocacyStatusLocksThenIssuesAfterVerifiedServing(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	metrics := &advocacyMetrics{}
	handler := AdvocacyHandler{
		Store:           store,
		Tokens:          advocacyTokens{providerID: "provider-status"},
		ServingEvidence: advocacyServing{eligible: false},
		Policy:          advocacyPolicy(),
		PublicLimiter:   NewBoundedLimiter(100, time.Minute, 32),
		AuthSlots:       make(chan struct{}, 1),
		JoinBaseURL:     "https://malibu.tech/j",
		Metrics:         metrics,
	}

	locked := httptest.NewRecorder()
	handler.HandleStatus(locked, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if locked.Code != http.StatusOK || !strings.Contains(locked.Body.String(), `"social_state":"locked_until_first_serving"`) ||
		strings.Contains(locked.Body.String(), "invite_code") || strings.Contains(locked.Body.String(), "invite_url") {
		t.Fatalf("locked status=%d body=%s", locked.Code, locked.Body.String())
	}

	handler.ServingEvidence = advocacyServing{when: now.Add(-time.Minute), eligible: true}
	issued := httptest.NewRecorder()
	handler.HandleStatus(issued, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if issued.Code != http.StatusOK || !strings.Contains(issued.Body.String(), `"social_state":"eligible"`) ||
		!strings.Contains(issued.Body.String(), `"base_capacity":1`) ||
		!strings.Contains(issued.Body.String(), `"configured_bonus_capacity":2`) ||
		!strings.Contains(issued.Body.String(), `"redemptions":0`) ||
		!strings.Contains(issued.Body.String(), `"invite_url":"https://malibu.tech/j/MAL1-P-`) {
		t.Fatalf("issued status=%d body=%s", issued.Code, issued.Body.String())
	}
	if !containsEvent(metrics.events, "status/locked") || !containsEvent(metrics.events, "status/issued") {
		t.Fatalf("metrics=%v", metrics.events)
	}
}

func TestAdvocacyXFlowBindsAuthorAndReturnsPendingState(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	verifier := &advocacyVerifier{authorID: "987654321"}
	metrics := &advocacyMetrics{}
	handler := AdvocacyHandler{
		Store:           store,
		Tokens:          advocacyTokens{providerID: "provider-x"},
		ServingEvidence: advocacyServing{when: now.Add(-time.Minute), eligible: true},
		PostVerifier:    verifier,
		Policy:          advocacyPolicy(),
		PublicLimiter:   NewBoundedLimiter(100, time.Minute, 32),
		ProviderLimiter: NewBoundedLimiter(10, time.Minute, 32),
		AuthSlots:       make(chan struct{}, 1),
		VerifySlots:     make(chan struct{}, 1),
		Now:             func() time.Time { return now },
		JoinBaseURL:     "https://malibu.tech/j",
		Metrics:         metrics,
	}

	challengeResponse := httptest.NewRecorder()
	handler.HandleChallenge(challengeResponse, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	if challengeResponse.Code != http.StatusOK {
		t.Fatalf("challenge status=%d body=%s", challengeResponse.Code, challengeResponse.Body.String())
	}
	var challengeBody struct {
		ShareURL string `json:"share_url"`
		Intent   string `json:"intent_url"`
	}
	if err := json.Unmarshal(challengeResponse.Body.Bytes(), &challengeBody); err != nil {
		t.Fatal(err)
	}
	shareURL, err := url.Parse(challengeBody.ShareURL)
	if err != nil {
		t.Fatal(err)
	}
	challenge := shareURL.Query().Get("c")
	if len(challenge) != 64 || !strings.HasPrefix(challengeBody.Intent, "https://twitter.com/intent/tweet?") {
		t.Fatalf("challenge body=%+v", challengeBody)
	}

	verifyBody := `{"post_url":"https://x.com/malibu/status/123456789","challenge":"` + challenge + `"}`
	verifyResponse := httptest.NewRecorder()
	handler.HandleVerify(verifyResponse, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", verifyBody))
	if verifyResponse.Code != http.StatusOK || !strings.Contains(verifyResponse.Body.String(), `"social_state":"pending"`) ||
		!strings.Contains(verifyResponse.Body.String(), `"bonus_capacity":0`) ||
		strings.Contains(verifyResponse.Body.String(), `"review_due_at"`) {
		t.Fatalf("verify status=%d body=%s", verifyResponse.Code, verifyResponse.Body.String())
	}
	if verifier.postID != "123456789" || verifier.expectedURL != challengeBody.ShareURL {
		t.Fatalf("verifier post=%q url=%q want=%q", verifier.postID, verifier.expectedURL, challengeBody.ShareURL)
	}
	wantDigest, err := ShareURLDigest(challengeBody.ShareURL, handler.JoinBaseURL)
	if err != nil {
		t.Fatal(err)
	}
	var storedDigest string
	if err := store.DB().QueryRow(`SELECT share_url_hash FROM referral_social_verifications WHERE provider_id = ?`, "provider-x").Scan(&storedDigest); err != nil {
		t.Fatal(err)
	}
	if storedDigest != wantDigest {
		t.Fatalf("stored digest=%q want=%q", storedDigest, wantDigest)
	}
	if !containsEvent(metrics.events, "challenge/created") || !containsEvent(metrics.events, "x_verify/pending") {
		t.Fatalf("metrics=%v", metrics.events)
	}

	replay := httptest.NewRecorder()
	handler.HandleVerify(replay, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", verifyBody))
	if replay.Code != http.StatusConflict {
		t.Fatalf("replay status=%d body=%s", replay.Code, replay.Body.String())
	}
}

func TestAdvocacyRejectsUnboundXAuthor(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	verifier := &advocacyVerifier{}
	handler := AdvocacyHandler{
		Store: store, Tokens: advocacyTokens{providerID: "provider-unbound"},
		ServingEvidence: advocacyServing{when: now.Add(-time.Minute), eligible: true},
		PostVerifier:    verifier, Policy: advocacyPolicy(),
		PublicLimiter:   NewBoundedLimiter(100, time.Minute, 32),
		ProviderLimiter: NewBoundedLimiter(10, time.Minute, 32),
		AuthSlots:       make(chan struct{}, 1),
		Now:             func() time.Time { return now }, JoinBaseURL: "https://malibu.tech/j",
	}
	challengeResponse := httptest.NewRecorder()
	handler.HandleChallenge(challengeResponse, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	var challengeBody struct {
		ShareURL string `json:"share_url"`
	}
	if err := json.Unmarshal(challengeResponse.Body.Bytes(), &challengeBody); err != nil {
		t.Fatal(err)
	}
	shareURL, _ := url.Parse(challengeBody.ShareURL)
	verifyBody := `{"post_url":"https://x.com/malibu/status/123","challenge":"` + shareURL.Query().Get("c") + `"}`
	response := httptest.NewRecorder()
	handler.HandleVerify(response, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", verifyBody))
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAdvocacyTransientXFailureIsRetryableWithSameChallenge(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	verifier := &advocacyVerifier{err: ErrXPostTransient}
	handler := AdvocacyHandler{
		Store: store, Tokens: advocacyTokens{providerID: "provider-retry"},
		ServingEvidence: advocacyServing{when: now.Add(-time.Minute), eligible: true},
		PostVerifier:    verifier, Policy: advocacyPolicy(),
		PublicLimiter:   NewBoundedLimiter(100, time.Minute, 32),
		ProviderLimiter: NewBoundedLimiter(10, time.Minute, 32),
		AuthSlots:       make(chan struct{}, 1),
		Now:             func() time.Time { return now }, JoinBaseURL: "https://malibu.tech/j",
	}
	challengeResponse := httptest.NewRecorder()
	handler.HandleChallenge(challengeResponse, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	var challengeBody struct {
		ShareURL string `json:"share_url"`
	}
	if err := json.Unmarshal(challengeResponse.Body.Bytes(), &challengeBody); err != nil {
		t.Fatal(err)
	}
	shareURL, _ := url.Parse(challengeBody.ShareURL)
	verifyBody := `{"post_url":"https://x.com/malibu/status/123","challenge":"` + shareURL.Query().Get("c") + `"}`
	first := httptest.NewRecorder()
	handler.HandleVerify(first, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", verifyBody))
	if first.Code != http.StatusServiceUnavailable || first.Header().Get("Retry-After") == "" {
		t.Fatalf("transient status=%d headers=%v body=%s", first.Code, first.Header(), first.Body.String())
	}

	verifier.err = nil
	verifier.authorID = "456"
	retry := httptest.NewRecorder()
	handler.HandleVerify(retry, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", verifyBody))
	if retry.Code != http.StatusOK || !strings.Contains(retry.Body.String(), `"social_state":"pending"`) {
		t.Fatalf("retry status=%d body=%s", retry.Code, retry.Body.String())
	}
}

func TestAdvocacyAuthenticationFailsClosed(t *testing.T) {
	handler := AdvocacyHandler{
		Store: openAdvocacyStore(t), Tokens: advocacyTokens{providerID: "provider-auth", err: errors.New("db unavailable")},
		Policy: advocacyPolicy(), PublicLimiter: NewBoundedLimiter(100, time.Minute, 32), AuthSlots: make(chan struct{}, 1),
	}
	response := httptest.NewRecorder()
	handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAdvocacyPublicLimitRunsBeforeTokenValidation(t *testing.T) {
	store := openAdvocacyStore(t)
	limiter := NewBoundedLimiter(1, time.Minute, 32)
	if !limiter.Allow("advocacy:203.0.113.8") {
		t.Fatal("failed to prime public limiter")
	}
	calls := 0
	handler := AdvocacyHandler{
		Store: store, Tokens: advocacyTokens{providerID: "provider-limited", calls: &calls},
		Policy: advocacyPolicy(), PublicLimiter: limiter, AuthSlots: make(chan struct{}, 1),
		SourceIP: func(*http.Request) string { return "203.0.113.8" },
	}
	response := httptest.NewRecorder()
	handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if response.Code != http.StatusTooManyRequests || calls != 0 {
		t.Fatalf("status=%d token calls=%d body=%s", response.Code, calls, response.Body.String())
	}
}

func TestAdvocacyAuthConcurrencyRunsBeforeTokenValidation(t *testing.T) {
	store := openAdvocacyStore(t)
	authSlots := make(chan struct{}, 1)
	authSlots <- struct{}{}
	calls := 0
	handler := AdvocacyHandler{
		Store: store, Tokens: advocacyTokens{providerID: "provider-busy", calls: &calls},
		Policy: advocacyPolicy(), PublicLimiter: NewBoundedLimiter(100, time.Minute, 32), AuthSlots: authSlots,
	}
	response := httptest.NewRecorder()
	handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if response.Code != http.StatusServiceUnavailable || calls != 0 {
		t.Fatalf("status=%d token calls=%d body=%s", response.Code, calls, response.Body.String())
	}
}

func containsEvent(events []string, want string) bool {
	for _, event := range events {
		if event == want {
			return true
		}
	}
	return false
}
