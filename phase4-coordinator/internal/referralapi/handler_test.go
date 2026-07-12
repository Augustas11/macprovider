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

type staticTokens struct{ providerID string }

func (s staticTokens) ValidateAndMarkTokenUsed(_ context.Context, token string) (string, bool, error) {
	return s.providerID, token == "valid-token", nil
}

type staticServing struct {
	when     time.Time
	eligible bool
	err      error
}

func (s staticServing) FirstVerifiedServing(context.Context, string) (time.Time, bool, error) {
	return s.when, s.eligible, s.err
}

type recordingVerifier struct {
	postID      string
	expectedURL string
	authorID    string
	err         error
}

func (v *recordingVerifier) VerifyPost(_ context.Context, postID, expectedURL string) (string, error) {
	v.postID, v.expectedURL = postID, expectedURL
	return v.authorID, v.err
}

func apiPolicy() auth.ReferralPolicy {
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

func TestOptionalXShareUnlocksBonusWithoutChangingProviderAccess(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	verifier := &recordingVerifier{authorID: "author-1"}
	h := Handler{
		Store:           store,
		Tokens:          staticTokens{providerID: "provider-1"},
		ServingEvidence: staticServing{when: now.Add(-time.Minute), eligible: true},
		PostVerifier:    verifier,
		Policy:          apiPolicy(),
		Now:             func() time.Time { return now },
		JoinBaseURL:     "https://malibu.tech/j",
	}

	challengeRequest := httptest.NewRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", nil)
	challengeRequest.Header.Set("Authorization", "Bearer valid-token")
	challengeResponse := httptest.NewRecorder()
	h.HandleChallenge(challengeResponse, challengeRequest)
	if challengeResponse.Code != http.StatusOK {
		t.Fatalf("challenge status=%d body=%s", challengeResponse.Code, challengeResponse.Body.String())
	}
	var challengeBody struct {
		ShareURL string `json:"share_url"`
	}
	if err := json.Unmarshal(challengeResponse.Body.Bytes(), &challengeBody); err != nil {
		t.Fatal(err)
	}
	shareURL, err := url.Parse(challengeBody.ShareURL)
	if err != nil {
		t.Fatal(err)
	}
	challenge := shareURL.Query().Get("c")
	if len(challenge) != 64 {
		t.Fatalf("challenge length=%d", len(challenge))
	}

	verifyBody := `{"post_url":"https://x.com/malibu/status/123456789","challenge":"` + challenge + `"}`
	verifyRequest := httptest.NewRequest(http.MethodPost, "/v1/provider/referrals/x/verify", strings.NewReader(verifyBody))
	verifyRequest.Header.Set("Authorization", "Bearer valid-token")
	verifyResponse := httptest.NewRecorder()
	h.HandleVerify(verifyResponse, verifyRequest)
	if verifyResponse.Code != http.StatusOK {
		t.Fatalf("verify status=%d body=%s", verifyResponse.Code, verifyResponse.Body.String())
	}
	if verifier.postID != "123456789" || verifier.expectedURL != challengeBody.ShareURL {
		t.Fatalf("verifier post=%q expected=%q want=%q", verifier.postID, verifier.expectedURL, challengeBody.ShareURL)
	}
	// FIX-570 H3: the bonus is NOT granted at verify time; the verification is
	// pending and the bonus stays 0 until the dwell reconciler promotes it.
	var status auth.ProviderReferral
	status, err = store.ProviderReferralStatus(context.Background(), apiPolicy(), "provider-1")
	if err != nil {
		t.Fatal(err)
	}
	if status.SocialVerified || status.BonusUses != 0 || status.Remaining != 1 {
		t.Fatalf("expected pending (no bonus yet), status=%+v", status)
	}

	// A replay can neither re-consume the challenge nor create a second pending row.
	replayRequest := httptest.NewRequest(http.MethodPost, "/v1/provider/referrals/x/verify", strings.NewReader(verifyBody))
	replayRequest.Header.Set("Authorization", "Bearer valid-token")
	replayResponse := httptest.NewRecorder()
	h.HandleVerify(replayResponse, replayRequest)
	if replayResponse.Code != http.StatusConflict {
		t.Fatalf("replay status=%d body=%s", replayResponse.Code, replayResponse.Body.String())
	}

	// Promotion before the dwell window elapses grants nothing.
	recheck := func(_ context.Context, postID, boundAuthor string) error {
		if boundAuthor != "author-1" {
			return errors.New("author not bound")
		}
		return nil
	}
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), apiPolicy(), now.Add(time.Minute), recheck); err != nil || granted != 0 {
		t.Fatalf("premature promotion granted=%d err=%v", granted, err)
	}

	// After the dwell window, promotion grants the bonus exactly once.
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), apiPolicy(), now.Add(31*time.Minute), recheck); err != nil || granted != 1 {
		t.Fatalf("promotion granted=%d err=%v", granted, err)
	}
	status, err = store.ProviderReferralStatus(context.Background(), apiPolicy(), "provider-1")
	if err != nil || !status.SocialVerified || status.BonusUses != 2 || status.Remaining != 3 {
		t.Fatalf("post-promotion status=%+v err=%v", status, err)
	}

	// A second promotion pass must not double-grant.
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), apiPolicy(), now.Add(62*time.Minute), recheck); err != nil || granted != 0 {
		t.Fatalf("double promotion granted=%d err=%v", granted, err)
	}
}

func TestSocialVerificationDoesNotGrantWhenPostDeletedBeforeDwell(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	verifier := &recordingVerifier{authorID: "author-1"}
	h := Handler{
		Store:           store,
		Tokens:          staticTokens{providerID: "provider-2"},
		ServingEvidence: staticServing{when: now.Add(-time.Minute), eligible: true},
		PostVerifier:    verifier,
		Policy:          apiPolicy(),
		Now:             func() time.Time { return now },
		JoinBaseURL:     "https://malibu.tech/j",
	}
	challengeReq := httptest.NewRequest(http.MethodPost, "/v1/provider/referrals/x/challenge", nil)
	challengeReq.Header.Set("Authorization", "Bearer valid-token")
	challengeResp := httptest.NewRecorder()
	h.HandleChallenge(challengeResp, challengeReq)
	if challengeResp.Code != http.StatusOK {
		t.Fatalf("challenge status=%d", challengeResp.Code)
	}
	var challengeBody struct {
		ShareURL string `json:"share_url"`
	}
	if err := json.Unmarshal(challengeResp.Body.Bytes(), &challengeBody); err != nil {
		t.Fatal(err)
	}
	shareURL, _ := url.Parse(challengeBody.ShareURL)
	challenge := shareURL.Query().Get("c")
	verifyBody := `{"post_url":"https://x.com/malibu/status/987654321","challenge":"` + challenge + `"}`
	verifyReq := httptest.NewRequest(http.MethodPost, "/v1/provider/referrals/x/verify", strings.NewReader(verifyBody))
	verifyReq.Header.Set("Authorization", "Bearer valid-token")
	verifyResp := httptest.NewRecorder()
	h.HandleVerify(verifyResp, verifyReq)
	if verifyResp.Code != http.StatusOK {
		t.Fatalf("verify status=%d body=%s", verifyResp.Code, verifyResp.Body.String())
	}
	// The post is deleted before the dwell elapses: re-check errors, so the bonus
	// is never granted and the verification is marked failed.
	recheckFails := func(_ context.Context, _, _ string) error { return errors.New("post gone") }
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), apiPolicy(), now.Add(31*time.Minute), recheckFails); err != nil || granted != 0 {
		t.Fatalf("failed promotion granted=%d err=%v", granted, err)
	}
	status, err := store.ProviderReferralStatus(context.Background(), apiPolicy(), "provider-2")
	if err != nil {
		t.Fatal(err)
	}
	if status.SocialVerified || status.BonusUses != 0 {
		t.Fatalf("deleted post must not grant bonus, status=%+v", status)
	}
	// A subsequent successful re-check must not resurrect the failed verification.
	recheckOK := func(_ context.Context, _, _ string) error { return nil }
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), apiPolicy(), now.Add(62*time.Minute), recheckOK); err != nil || granted != 0 {
		t.Fatalf("failed verification resurrected granted=%d err=%v", granted, err)
	}
}

func TestJoinLandingValidatesCodeAndOffersDownloadAndCopy(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	code, err := store.CreateSeedReferral(context.Background(), apiPolicy(), "landing", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	h := Handler{Store: store, Policy: apiPolicy(), Now: time.Now, PublicLimiter: NewBoundedLimiter(10, time.Minute, 10)}
	request := httptest.NewRequest(http.MethodGet, "/j/"+code, nil)
	response := httptest.NewRecorder()

	h.HandleJoin(response, request)

	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), code) ||
		!strings.Contains(response.Body.String(), "https://download.malibu.tech/latest.dmg") ||
		!strings.Contains(response.Body.String(), "Copy invite code") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	invalid := httptest.NewRecorder()
	h.HandleJoin(invalid, httptest.NewRequest(http.MethodGet, "/j/not-a-code", nil))
	if invalid.Code != http.StatusNotFound {
		t.Fatalf("invalid status=%d", invalid.Code)
	}
	if _, _, err := store.IssueTokenWithReferral(context.Background(), "landing-provider", "landing", code, apiPolicy()); err != nil {
		t.Fatal(err)
	}
	full := httptest.NewRecorder()
	h.HandleJoin(full, httptest.NewRequest(http.MethodGet, "/j/"+code, nil))
	if full.Code != http.StatusOK || !strings.Contains(full.Body.String(), "This invite filled up") ||
		!strings.Contains(full.Body.String(), "https://malibu.tech") ||
		strings.Contains(full.Body.String(), "download.malibu.tech") {
		t.Fatalf("full status=%d body=%s", full.Code, full.Body.String())
	}
}

func TestJoinServesOpenBetaLandingWhenGateDisabled(t *testing.T) {
	policy := apiPolicy()
	policy.RequireForRegistration = false
	// Store is intentionally nil: when the gate is off HandleJoin must not
	// validate a code, so it must not touch the store.
	h := Handler{Policy: policy, Now: time.Now, PublicLimiter: NewBoundedLimiter(10, time.Minute, 10)}
	req := httptest.NewRequest(http.MethodGet, "/j/MAL1-S-k1-anything-AAAAAAAAAAAAAAAAAAAAAAAAAA", nil)
	w := httptest.NewRecorder()
	h.HandleJoin(w, req)
	if w.Code != http.StatusOK ||
		!strings.Contains(w.Body.String(), "Malibu is now open") ||
		!strings.Contains(w.Body.String(), "https://download.malibu.tech/latest.dmg") {
		t.Fatalf("open-beta join status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestValidateIsRateLimitedAndDoesNotExposeIssuer(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := apiPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "seed", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	limiter := NewBoundedLimiter(1, time.Minute, 8)
	h := Handler{Store: store, Policy: policy, PublicLimiter: limiter}
	request := func() *http.Request {
		return httptest.NewRequest(http.MethodPost, "/v1/referrals/validate", strings.NewReader(`{"code":"`+code+`"}`))
	}
	first := httptest.NewRecorder()
	h.HandleValidate(first, request())
	if first.Code != http.StatusOK || strings.Contains(first.Body.String(), "seed") || strings.Contains(first.Body.String(), code) {
		t.Fatalf("unexpected public response status=%d body=%s", first.Code, first.Body.String())
	}
	second := httptest.NewRecorder()
	h.HandleValidate(second, request())
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
}

func TestReserveClaimsCapacityIdempotentlyAndReportsExhaustion(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := apiPolicy()
	code, err := store.CreateSeedReferral(context.Background(), policy, "reserveseed", 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	h := Handler{Store: store, Policy: policy, PublicLimiter: NewBoundedLimiter(50, time.Minute, 64), Now: func() time.Time { return now }}
	reserve := func(code, providerID string) *httptest.ResponseRecorder {
		body := `{"code":"` + code + `","provider_id":"` + providerID + `"}`
		req := httptest.NewRequest(http.MethodPost, "/v1/referrals/reserve", strings.NewReader(body))
		w := httptest.NewRecorder()
		h.HandleReserve(w, req)
		return w
	}

	first := reserve(code, "prov-a")
	var firstBody struct {
		Reserved      bool   `json:"reserved"`
		ReservationID string `json:"reservation_id"`
		Reason        string `json:"reason"`
	}
	if first.Code != http.StatusOK {
		t.Fatalf("first reserve status=%d body=%s", first.Code, first.Body.String())
	}
	if err := json.Unmarshal(first.Body.Bytes(), &firstBody); err != nil {
		t.Fatal(err)
	}
	if !firstBody.Reserved || firstBody.ReservationID == "" {
		t.Fatalf("first reserve body=%s", first.Body.String())
	}

	// Same provider + code -> same reservation id (idempotent extension).
	second := reserve(code, "prov-a")
	var secondBody struct {
		Reserved      bool   `json:"reserved"`
		ReservationID string `json:"reservation_id"`
	}
	if err := json.Unmarshal(second.Body.Bytes(), &secondBody); err != nil {
		t.Fatal(err)
	}
	if !secondBody.Reserved || secondBody.ReservationID != firstBody.ReservationID {
		t.Fatalf("expected same reservation id, got %q vs %q", secondBody.ReservationID, firstBody.ReservationID)
	}

	// A different provider against a cap-1 code that is already reserved is exhausted.
	third := reserve(code, "prov-b")
	var thirdBody struct {
		Reserved bool   `json:"reserved"`
		Reason   string `json:"reason"`
	}
	if err := json.Unmarshal(third.Body.Bytes(), &thirdBody); err != nil {
		t.Fatal(err)
	}
	if thirdBody.Reserved || thirdBody.Reason != "exhausted" {
		t.Fatalf("expected exhausted for second provider, body=%s", third.Body.String())
	}
}

func TestReserveDisabledReturnsNotRequired(t *testing.T) {
	policy := apiPolicy()
	policy.RequireForRegistration = false
	h := Handler{Policy: policy, PublicLimiter: NewBoundedLimiter(10, time.Minute, 10)}
	req := httptest.NewRequest(http.MethodPost, "/v1/referrals/reserve", strings.NewReader(`{"code":"x","provider_id":"prov-a"}`))
	w := httptest.NewRecorder()
	h.HandleReserve(w, req)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"required":false`) || strings.Contains(w.Body.String(), `"reserved":true`) {
		t.Fatalf("disabled reserve status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestProviderStatusRemainsLockedBeforeVerifiedServing(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	h := Handler{
		Store:           store,
		Tokens:          staticTokens{providerID: "provider-locked"},
		ServingEvidence: staticServing{eligible: false},
		Policy:          apiPolicy(),
	}
	r := httptest.NewRequest(http.MethodGet, "/v1/provider/referrals", nil)
	r.Header.Set("Authorization", "Bearer valid-token")
	w := httptest.NewRecorder()
	h.HandleProviderStatus(w, r)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"advocacy_status":"locked_until_first_serving"`) || strings.Contains(w.Body.String(), "MAL1-") {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}
