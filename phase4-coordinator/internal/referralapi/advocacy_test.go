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

type advocacyVerifier struct {
	postID      string
	expectedURL string
	authorID    string
	err         error
	calls       int
}

func (v *advocacyVerifier) VerifyPost(_ context.Context, postID, expectedURL string) (string, error) {
	v.calls++
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
		RequireForRegistration:  true,
		EnableSocialBonus:       true,
		Campaign:                "prebeta_test",
		PolicyVersion:           "v1",
		CurrentKeyID:            "k1",
		HMACKeys:                map[string]string{"k1": strings.Repeat("s", 32)},
		ProviderBaseUses:        1,
		SocialBonusUses:         2,
		SocialBonusMaxGrants:    5,
		ChallengeTTL:            15 * time.Minute,
		SocialVerificationDwell: 30 * time.Minute,
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

func qualifyAdvocacyProvider(t *testing.T, store *auth.Store, policy auth.ReferralPolicy, providerID string, now time.Time) auth.ProviderReferral {
	t.Helper()
	status, created, err := store.QualifyProviderReferral(
		context.Background(), policy, providerID, "settlement-verdict:"+providerID,
		now.Add(-time.Minute), now,
	)
	if err != nil || !created {
		t.Fatalf("qualify provider status=%+v created=%v err=%v", status, created, err)
	}
	return status
}

func newAdvocacyHandler(store *auth.Store, providerID string, now time.Time) AdvocacyHandler {
	return AdvocacyHandler{
		Store:            store,
		Tokens:           advocacyTokens{providerID: providerID},
		Policy:           advocacyPolicy(),
		PublicLimiter:    NewBoundedLimiter(1000, time.Minute, 128),
		ProviderLimiter:  NewBoundedLimiter(1000, time.Minute, 128),
		AuthSlots:        make(chan struct{}, 1),
		VerifySlots:      make(chan struct{}, 1),
		Now:              func() time.Time { return now },
		JoinBaseURL:      "https://malibu.tech/j",
		JoinLinksEnabled: true,
	}
}

func bearerRequest(method, target, body string) *http.Request {
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer valid-token")
	return request
}

func referralMutationCount(t *testing.T, store *auth.Store) int64 {
	t.Helper()
	var changes int64
	if err := store.DB().QueryRow(`SELECT total_changes()`).Scan(&changes); err != nil {
		t.Fatal(err)
	}
	return changes
}

func TestAdvocacyStatusIsReadOnlyAndCannotQualifyProvider(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	metrics := &advocacyMetrics{}
	handler := newAdvocacyHandler(store, "provider-status", now)
	handler.Metrics = metrics

	before := referralMutationCount(t, store)
	for range 2 {
		response := httptest.NewRecorder()
		handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"social_state":"locked_until_first_serving"`) ||
			strings.Contains(response.Body.String(), "invite_code") || strings.Contains(response.Body.String(), "invite_url") {
			t.Fatalf("locked status=%d body=%s", response.Code, response.Body.String())
		}
	}
	if after := referralMutationCount(t, store); after != before {
		t.Fatalf("status GET mutated coordinator DB: before=%d after=%d", before, after)
	}
	for _, table := range []string{"referral_serving_qualifications", "referral_issuers", "referral_social_audit"} {
		var rows int
		if err := store.DB().QueryRow(`SELECT COUNT(1) FROM ` + table).Scan(&rows); err != nil {
			t.Fatal(err)
		}
		if rows != 0 {
			t.Fatalf("status GET created %d rows in %s", rows, table)
		}
	}

	qualified := qualifyAdvocacyProvider(t, store, handler.Policy, "provider-status", now)
	before = referralMutationCount(t, store)
	response := httptest.NewRecorder()
	handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"social_state":"eligible"`) ||
		!strings.Contains(response.Body.String(), `"base_capacity":1`) ||
		!strings.Contains(response.Body.String(), `"join_base_url":"https://malibu.tech/j"`) ||
		!strings.Contains(response.Body.String(), `"invite_url":"https://malibu.tech/j#/`+qualified.Code+`"`) {
		t.Fatalf("qualified status=%d body=%s", response.Code, response.Body.String())
	}
	if after := referralMutationCount(t, store); after != before {
		t.Fatalf("qualified status GET mutated coordinator DB: before=%d after=%d", before, after)
	}
	if !containsEvent(metrics.events, "status/locked") || !containsEvent(metrics.events, "status/eligible") {
		t.Fatalf("metrics=%v", metrics.events)
	}
}

func createAdvocacyChallenge(t *testing.T, handler *AdvocacyHandler) (shareURL, challenge string) {
	t.Helper()
	response := httptest.NewRecorder()
	handler.HandleChallenge(response, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	if response.Code != http.StatusOK {
		t.Fatalf("challenge status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		ShareURL string `json:"share_url"`
		Intent   string `json:"intent_url"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(body.ShareURL)
	if err != nil {
		t.Fatal(err)
	}
	codeFragment, challengeValue, ok := strings.Cut(parsed.Fragment, "?c=")
	if !ok || !strings.HasPrefix(codeFragment, "/MAL1-") {
		t.Fatalf("share URL fragment=%q", parsed.Fragment)
	}
	challenge = challengeValue
	if len(challenge) != 64 || !strings.HasPrefix(body.Intent, "https://twitter.com/intent/tweet?") {
		t.Fatalf("challenge body=%+v", body)
	}
	return body.ShareURL, challenge
}

func TestAdvocacyChallengeIntentUsesTaggedMalibuHandle(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 18, 9, 0, 0, 0, time.UTC)
	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-copy", now)
	handler := newAdvocacyHandler(store, "provider-copy", now)

	response := httptest.NewRecorder()
	handler.HandleChallenge(response, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	if response.Code != http.StatusOK {
		t.Fatalf("challenge status=%d body=%s", response.Code, response.Body.String())
	}

	var body struct {
		ShareURL string `json:"share_url"`
		Intent   string `json:"intent_url"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	parsedIntent, err := url.Parse(body.Intent)
	if err != nil {
		t.Fatal(err)
	}
	decodedText := parsedIntent.Query().Get("text")
	want := "My Mac just joined @malibuonbase’s pre-beta compute network. If you have a Mac and want early access: " + body.ShareURL
	if decodedText != want {
		t.Fatalf("decoded intent text mismatch\nwant: %q\n got: %q", want, decodedText)
	}
	if strings.Contains(decodedText, "joined Malibu's") {
		t.Fatalf("decoded intent text retained untagged legacy copy: %q", decodedText)
	}
}

func TestAdvocacyXSubmissionIsExactReplaySafeAfterResponseLoss(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-x", now)
	verifier := &advocacyVerifier{authorID: "987654321"}
	metrics := &advocacyMetrics{}
	handler := newAdvocacyHandler(store, "provider-x", now)
	handler.PostVerifier = verifier
	handler.Metrics = metrics
	shareURL, challenge := createAdvocacyChallenge(t, &handler)
	verifyBody := `{"post_url":"https://x.com/malibu/status/123456789","challenge":"` + challenge + `"}`

	for attempt := 1; attempt <= 2; attempt++ {
		response := httptest.NewRecorder()
		handler.HandleVerify(response, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", verifyBody))
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"social_state":"pending"`) ||
			!strings.Contains(response.Body.String(), `"bonus_capacity":0`) {
			t.Fatalf("attempt=%d status=%d body=%s", attempt, response.Code, response.Body.String())
		}
	}
	if verifier.postID != "123456789" || verifier.expectedURL != shareURL {
		t.Fatalf("verifier post=%q url=%q want=%q", verifier.postID, verifier.expectedURL, shareURL)
	}
	if verifier.calls != 1 {
		t.Fatalf("external verifier calls=%d want=1", verifier.calls)
	}
	var verifications, accepted, replayed int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_verifications WHERE provider_id = ?`, "provider-x").Scan(&verifications); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'submission' AND outcome = 'accepted'`, "provider-x").Scan(&accepted); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'submission' AND outcome = 'replayed'`, "provider-x").Scan(&replayed); err != nil {
		t.Fatal(err)
	}
	if verifications != 1 || accepted != 1 || replayed != 1 {
		t.Fatalf("verifications=%d accepted=%d replayed=%d", verifications, accepted, replayed)
	}
	if !containsEvent(metrics.events, "challenge/created") || !containsEvent(metrics.events, "x_verify/pending") {
		t.Fatalf("metrics=%v", metrics.events)
	}
}

func TestAdvocacyRejectsInvalidChallengeBeforeExternalVerification(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-preflight", now)
	verifier := &advocacyVerifier{authorID: "987654321"}
	handler := newAdvocacyHandler(store, "provider-preflight", now)
	handler.PostVerifier = verifier

	response := httptest.NewRecorder()
	body := `{"post_url":"https://x.com/malibu/status/123456789","challenge":"` + strings.Repeat("f", 64) + `"}`
	handler.HandleVerify(response, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", body))
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), `"code":"challenge_invalid"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if verifier.calls != 0 {
		t.Fatalf("external verifier called %d times for invalid challenge", verifier.calls)
	}
}

func TestAdvocacyExternalDecisionsAreAuditedAndTransientRetryUsesSameChallenge(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-retry", now)
	verifier := &advocacyVerifier{err: ErrXPostTransient}
	handler := newAdvocacyHandler(store, "provider-retry", now)
	handler.PostVerifier = verifier
	_, challenge := createAdvocacyChallenge(t, &handler)
	body := `{"post_url":"https://x.com/malibu/status/123","challenge":"` + challenge + `"}`

	transient := httptest.NewRecorder()
	handler.HandleVerify(transient, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", body))
	if transient.Code != http.StatusServiceUnavailable || transient.Header().Get("Retry-After") == "" {
		t.Fatalf("transient status=%d headers=%v body=%s", transient.Code, transient.Header(), transient.Body.String())
	}
	var transientAudit int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'external_verify' AND outcome = 'transient' AND reason = 'x_unavailable'`, "provider-retry").Scan(&transientAudit); err != nil {
		t.Fatal(err)
	}
	if transientAudit != 1 {
		t.Fatalf("transient audit rows=%d", transientAudit)
	}

	verifier.err = nil
	verifier.authorID = "456"
	retry := httptest.NewRecorder()
	handler.HandleVerify(retry, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", body))
	if retry.Code != http.StatusOK || !strings.Contains(retry.Body.String(), `"social_state":"pending"`) {
		t.Fatalf("retry status=%d body=%s", retry.Code, retry.Body.String())
	}
	var verifiedAudit int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'external_verify' AND outcome = 'verified'`, "provider-retry").Scan(&verifiedAudit); err != nil {
		t.Fatal(err)
	}
	if verifiedAudit != 1 {
		t.Fatalf("verified audit rows=%d", verifiedAudit)
	}

	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-terminal", now)
	terminalVerifier := &advocacyVerifier{err: ErrXPostTerminal}
	terminalHandler := newAdvocacyHandler(store, "provider-terminal", now)
	terminalHandler.PostVerifier = terminalVerifier
	_, terminalChallenge := createAdvocacyChallenge(t, &terminalHandler)
	terminalBody := `{"post_url":"https://x.com/malibu/status/456","challenge":"` + terminalChallenge + `"}`
	terminal := httptest.NewRecorder()
	terminalHandler.HandleVerify(terminal, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", terminalBody))
	if terminal.Code != http.StatusUnprocessableEntity {
		t.Fatalf("terminal status=%d body=%s", terminal.Code, terminal.Body.String())
	}
	if !strings.Contains(terminal.Body.String(), `"social_state":"failed"`) {
		t.Fatalf("terminal body=%s", terminal.Body.String())
	}
	var terminalAudit int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'external_verify' AND outcome = 'terminal' AND reason = 'post_not_verified'`, "provider-terminal").Scan(&terminalAudit); err != nil {
		t.Fatal(err)
	}
	if terminalAudit != 1 {
		t.Fatalf("terminal audit rows=%d", terminalAudit)
	}
	replayed := httptest.NewRecorder()
	terminalHandler.HandleVerify(replayed, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", terminalBody))
	if replayed.Code != http.StatusOK || !strings.Contains(replayed.Body.String(), `"social_state":"failed"`) {
		t.Fatalf("terminal replay status=%d body=%s", replayed.Code, replayed.Body.String())
	}
	if terminalVerifier.calls != 1 {
		t.Fatalf("terminal replay external calls=%d", terminalVerifier.calls)
	}
	var failedRows, attackerVerificationRows int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_failures WHERE provider_id = ? AND post_id = ?`, "provider-terminal", "456").Scan(&failedRows); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_verifications WHERE provider_id = ?`, "provider-terminal").Scan(&attackerVerificationRows); err != nil {
		t.Fatal(err)
	}
	if failedRows != 1 || attackerVerificationRows != 0 {
		t.Fatalf("terminal failure rows=%d verification rows=%d", failedRows, attackerVerificationRows)
	}

	// A terminally rejected post was never positively bound to the first
	// provider, so it must not reserve the global replay key and deny a later
	// legitimate verification.
	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-legitimate", now)
	legitimateVerifier := &advocacyVerifier{authorID: "789"}
	legitimateHandler := newAdvocacyHandler(store, "provider-legitimate", now)
	legitimateHandler.PostVerifier = legitimateVerifier
	_, legitimateChallenge := createAdvocacyChallenge(t, &legitimateHandler)
	legitimateBody := `{"post_url":"https://x.com/malibu/status/456","challenge":"` + legitimateChallenge + `"}`
	legitimate := httptest.NewRecorder()
	legitimateHandler.HandleVerify(legitimate, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/verify", legitimateBody))
	if legitimate.Code != http.StatusOK || !strings.Contains(legitimate.Body.String(), `"social_state":"pending"`) {
		t.Fatalf("legitimate reuse status=%d body=%s", legitimate.Code, legitimate.Body.String())
	}
}

func TestAdvocacyStatusDoesNotAdvertiseDisabledJoinLink(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	qualified := qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-link-disabled", now)
	handler := newAdvocacyHandler(store, "provider-link-disabled", now)
	handler.JoinLinksEnabled = false

	response := httptest.NewRecorder()
	handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
	if response.Code != http.StatusOK ||
		!strings.Contains(response.Body.String(), `"join_links_enabled":false`) ||
		!strings.Contains(response.Body.String(), `"invite_code":"`+qualified.Code+`"`) ||
		strings.Contains(response.Body.String(), `"invite_url"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAdvocacyDurableProviderLimitsSurviveHandlerReplacement(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	qualifyAdvocacyProvider(t, store, advocacyPolicy(), "provider-limited", now)

	for attempt := 1; attempt <= 5; attempt++ {
		handler := newAdvocacyHandler(store, "provider-limited", now)
		response := httptest.NewRecorder()
		handler.HandleChallenge(response, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
		if response.Code != http.StatusOK {
			t.Fatalf("attempt=%d status=%d body=%s", attempt, response.Code, response.Body.String())
		}
	}
	restarted := newAdvocacyHandler(store, "provider-limited", now)
	denied := httptest.NewRecorder()
	restarted.HandleChallenge(denied, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	if denied.Code != http.StatusTooManyRequests || denied.Header().Get("Retry-After") == "" {
		t.Fatalf("denied status=%d headers=%v body=%s", denied.Code, denied.Header(), denied.Body.String())
	}
	var count, deniedAudit int
	if err := store.DB().QueryRow(`SELECT request_count FROM referral_social_rate_windows WHERE campaign = ? AND provider_id = ? AND action = 'challenge'`, advocacyPolicy().Campaign, "provider-limited").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'rate_limit' AND outcome = 'denied'`, "provider-limited").Scan(&deniedAudit); err != nil {
		t.Fatal(err)
	}
	if count != 5 || deniedAudit != 1 {
		t.Fatalf("durable count=%d denied audits=%d", count, deniedAudit)
	}
}

func TestAdvocacyAuthenticationAndAdmissionLimitsFailClosed(t *testing.T) {
	t.Run("auth storage unavailable", func(t *testing.T) {
		handler := newAdvocacyHandler(openAdvocacyStore(t), "provider-auth", time.Now())
		handler.Tokens = advocacyTokens{providerID: "provider-auth", err: errors.New("db unavailable")}
		response := httptest.NewRecorder()
		handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
		if response.Code != http.StatusServiceUnavailable {
			t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
		}
	})

	t.Run("public limit precedes token validation", func(t *testing.T) {
		limiter := NewBoundedLimiter(1, time.Minute, 32)
		if !limiter.Allow("advocacy:203.0.113.8") {
			t.Fatal("failed to prime public limiter")
		}
		calls := 0
		handler := newAdvocacyHandler(openAdvocacyStore(t), "provider-limited", time.Now())
		handler.PublicLimiter = limiter
		handler.Tokens = advocacyTokens{providerID: "provider-limited", calls: &calls}
		handler.SourceIP = func(*http.Request) string { return "203.0.113.8" }
		response := httptest.NewRecorder()
		handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
		if response.Code != http.StatusTooManyRequests || calls != 0 {
			t.Fatalf("status=%d token calls=%d body=%s", response.Code, calls, response.Body.String())
		}
	})

	t.Run("auth concurrency precedes token validation", func(t *testing.T) {
		authSlots := make(chan struct{}, 1)
		authSlots <- struct{}{}
		calls := 0
		handler := newAdvocacyHandler(openAdvocacyStore(t), "provider-busy", time.Now())
		handler.AuthSlots = authSlots
		handler.Tokens = advocacyTokens{providerID: "provider-busy", calls: &calls}
		response := httptest.NewRecorder()
		handler.HandleStatus(response, bearerRequest(http.MethodGet, "/v1/provider/referrals", ""))
		if response.Code != http.StatusServiceUnavailable || calls != 0 {
			t.Fatalf("status=%d token calls=%d body=%s", response.Code, calls, response.Body.String())
		}
	})
}

func TestAdvocacyRejectsDisabledSocialAndUnqualifiedChallenges(t *testing.T) {
	store := openAdvocacyStore(t)
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	handler := newAdvocacyHandler(store, "provider-locked", now)

	locked := httptest.NewRecorder()
	handler.HandleChallenge(locked, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	if locked.Code != http.StatusConflict || !strings.Contains(locked.Body.String(), "first_serving_required") {
		t.Fatalf("locked status=%d body=%s", locked.Code, locked.Body.String())
	}

	handler.Policy.EnableSocialBonus = false
	disabled := httptest.NewRecorder()
	handler.HandleChallenge(disabled, bearerRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", ""))
	if disabled.Code != http.StatusNotFound {
		t.Fatalf("disabled status=%d body=%s", disabled.Code, disabled.Body.String())
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
