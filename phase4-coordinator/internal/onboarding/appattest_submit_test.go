package onboarding

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
)

type fakeAppAttestRecorder struct {
	fakeStatsDB
	mu         sync.Mutex
	configured bool
	byProvider map[string][]byte
	recordErr  error
}

func (f *fakeAppAttestRecorder) AppAttestRecorderConfigured() bool { return f.configured }

func (f *fakeAppAttestRecorder) AppAttestVerificationRecorded(_ context.Context, providerID string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	_, ok := f.byProvider[providerID]
	return ok, nil
}

func (f *fakeAppAttestRecorder) RecordAppAttestVerification(_ context.Context, providerID string, keyID []byte) (AppAttestRecordOutcome, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.recordErr != nil {
		return 0, f.recordErr
	}
	if _, ok := f.byProvider[providerID]; ok {
		return AppAttestAlreadyRecorded, nil
	}
	for _, k := range f.byProvider {
		if bytes.Equal(k, keyID) {
			return AppAttestKeyReused, nil
		}
	}
	f.byProvider[providerID] = append([]byte(nil), keyID...)
	return AppAttestRecorded, nil
}

// tokenAuthStore maps bearer tokens to provider ids.
type tokenAuthStore struct {
	fakeAuthStore
	tokens map[string]string
}

func (s *tokenAuthStore) ValidateToken(_ context.Context, token string) (string, bool, error) {
	id, ok := s.tokens[token]
	return id, ok, nil
}

type appAttestHarness struct {
	t        *testing.T
	handler  *Handler
	recorder *fakeAppAttestRecorder
	fixture  *appattesttest.Fixture
	now      time.Time
}

const testAppAttestTeam = "TEAM123456"

func newAppAttestHarness(t *testing.T) *appAttestHarness {
	t.Helper()
	h := &appAttestHarness{t: t, now: time.Now().UTC()}
	fixture, err := appattesttest.NewFixtureAt(h.now)
	if err != nil {
		t.Fatal(err)
	}
	h.fixture = fixture
	h.recorder = &fakeAppAttestRecorder{configured: true, byProvider: map[string][]byte{}}
	cfg := AppAttestConfig{TeamID: testAppAttestTeam, BundleID: "tech.malibu.app", CoordinatorDomain: "Coordinator.Malibu.Tech/"}
	h.handler = &Handler{
		StatsDB:             h.recorder,
		AuthTokenStore:      &tokenAuthStore{tokens: map[string]string{"tok-a": "mp-aaaa", "tok-b": "mp-bbbb"}},
		AppAttestConfig:     cfg,
		AppAttestChallenges: NewAppAttestChallengeStore(0),
		AppAttestVerifier: AppleAppAttestVerifier{
			Config: cfg,
			Root:   fixture.Root,
			Now:    func() time.Time { return h.now },
		},
		Now: func() time.Time { return h.now },
	}
	return h
}

func (h *appAttestHarness) post(path, token, body string) *httptest.ResponseRecorder {
	h.t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rr := httptest.NewRecorder()
	switch path {
	case "/v1/providers/app-attest/challenge":
		h.handler.HandleAppAttestChallenge(rr, req)
	default:
		h.handler.HandleAppAttestSubmit(rr, req)
	}
	return rr
}

func (h *appAttestHarness) challenge(token string) appAttestChallengeResponse {
	h.t.Helper()
	rr := h.post("/v1/providers/app-attest/challenge", token, `{"provider_id":"mp-ignored"}`)
	if rr.Code != http.StatusOK {
		h.t.Fatalf("challenge status=%d body=%s", rr.Code, rr.Body.String())
	}
	var out appAttestChallengeResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
		h.t.Fatal(err)
	}
	return out
}

// attest builds an attestation whose nonce binds clientData.
func (h *appAttestHarness) attest(clientData string, opts appattesttest.AttestOptions) appattesttest.Attestation {
	h.t.Helper()
	hash := sha256.Sum256([]byte(clientData))
	opts.AppID = testAppAttestTeam + ".tech.malibu.app"
	opts.ClientDataHash = hash[:]
	att, err := h.fixture.Attest(opts)
	if err != nil {
		h.t.Fatal(err)
	}
	return att
}

func submitBody(challenge string, att appattesttest.Attestation) string {
	body, _ := json.Marshal(map[string]string{
		"challenge":   challenge,
		"key_id":      base64.StdEncoding.EncodeToString(att.KeyID),
		"attestation": base64.StdEncoding.EncodeToString(att.Object),
	})
	return string(body)
}

func wantStatus(t *testing.T, rr *httptest.ResponseRecorder, code int, fragment string) {
	t.Helper()
	if rr.Code != code || !strings.Contains(rr.Body.String(), fragment) {
		t.Fatalf("status=%d body=%s, want %d containing %q", rr.Code, rr.Body.String(), code, fragment)
	}
}

func TestAppAttestSubmitRecordsTokenBoundProvider(t *testing.T) {
	h := newAppAttestHarness(t)
	ch := h.challenge("tok-a")
	if ch.Status != "challenge" || ch.ProviderID != "mp-aaaa" {
		t.Fatalf("challenge = %+v", ch)
	}
	// The client data is the coordinator's own JCS tuple; the body's
	// provider_id was ignored.
	wantClientData := `{"bundle_id":"tech.malibu.app","challenge":"` + ch.Challenge +
		`","coordinator_domain":"coordinator.malibu.tech","provider_id":"mp-aaaa","purpose":"malibu.app_attest.hardware_trust.v1","team_id":"TEAM123456"}`
	if ch.ClientData != wantClientData {
		t.Fatalf("client_data = %s\nwant          %s", ch.ClientData, wantClientData)
	}
	att := h.attest(ch.ClientData, appattesttest.AttestOptions{})

	// A body that names a provider is not the closed shape.
	withProvider := strings.TrimSuffix(submitBody(ch.Challenge, att), "}") + `,"provider_id":"mp-bbbb"}`
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", withProvider), http.StatusBadRequest, "invalid_request")
	// The rejected submit spent the challenge.
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(ch.Challenge, att)), http.StatusConflict, "challenge_invalid")

	ch = h.challenge("tok-a")
	att = h.attest(ch.ClientData, appattesttest.AttestOptions{})
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(ch.Challenge, att)), http.StatusOK, `"status":"recorded"`)
	if got := h.recorder.byProvider["mp-aaaa"]; !bytes.Equal(got, att.KeyID) || len(h.recorder.byProvider) != 1 {
		t.Fatalf("recorded %v", h.recorder.byProvider)
	}
	// Once recorded, the challenge endpoint issues nothing.
	if again := h.challenge("tok-a"); again.Status != "already_recorded" || again.Challenge != "" {
		t.Fatalf("after record: %+v", again)
	}

	// The same key cannot vouch for a second provider.
	chB := h.challenge("tok-b")
	reuse := h.attest(chB.ClientData, appattesttest.AttestOptions{Key: att.Key})
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chB.Challenge, reuse)), http.StatusConflict, "app_attest_key_reused")
	if _, ok := h.recorder.byProvider["mp-bbbb"]; ok {
		t.Fatal("reused key recorded for a second provider")
	}
}

func TestAppAttestChallengeIsSingleUseAndProviderBound(t *testing.T) {
	h := newAppAttestHarness(t)
	chA := h.challenge("tok-a")
	attA := h.attest(chA.ClientData, appattesttest.AttestOptions{})

	// Provider B cannot spend A's challenge, and B's attempt leaves A's alone.
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chA.Challenge, attA)), http.StatusConflict, "challenge_invalid")
	// An attestation over A's client data does not verify for B's challenge:
	// the coordinator recomputes the client data with B's id.
	chB := h.challenge("tok-b")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chB.Challenge, attA)), http.StatusUnprocessableEntity, "app_attest_rejected")

	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(chA.Challenge, attA)), http.StatusOK, `"status":"recorded"`)
	// Replaying the spent challenge fails.
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(chA.Challenge, attA)), http.StatusConflict, "challenge_invalid")

	// A failed submit still spends the challenge.
	chB = h.challenge("tok-b")
	dev := appattesttest.DevelopmentAAGUID
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chB.Challenge, h.attest(chB.ClientData, appattesttest.AttestOptions{AAGUID: &dev}))), http.StatusUnprocessableEntity, "app_attest_rejected")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chB.Challenge, h.attest(chB.ClientData, appattesttest.AttestOptions{}))), http.StatusConflict, "challenge_invalid")

	// SIP/Full Security policy mismatch is rejected and not recorded.
	chB = h.challenge("tok-b")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chB.Challenge, h.attest(chB.ClientData, appattesttest.AttestOptions{ACLInner: []byte{0x30, 0x00}}))), http.StatusUnprocessableEntity, "app_attest_rejected")

	// A newer challenge replaces the older one.
	old := h.challenge("tok-b")
	h.challenge("tok-b")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(old.Challenge, h.attest(old.ClientData, appattesttest.AttestOptions{}))), http.StatusConflict, "challenge_invalid")

	// Challenges expire after 5 minutes.
	chB = h.challenge("tok-b")
	attB := h.attest(chB.ClientData, appattesttest.AttestOptions{})
	h.now = h.now.Add(appAttestChallengeTTL)
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-b", submitBody(chB.Challenge, attB)), http.StatusConflict, "challenge_invalid")
	if _, ok := h.recorder.byProvider["mp-bbbb"]; ok {
		t.Fatal("provider B recorded without a valid attestation")
	}
}

func TestAppAttestEndpointsRefuseWithoutCredentialOrRecorder(t *testing.T) {
	h := newAppAttestHarness(t)
	wantStatus(t, h.post("/v1/providers/app-attest/challenge", "", ""), http.StatusUnauthorized, "unauthorized")
	wantStatus(t, h.post("/v1/providers/app-attest/challenge", "tok-x", ""), http.StatusUnauthorized, "unauthorized")
	wantStatus(t, h.post("/v1/providers/app-attest", "", "{}"), http.StatusUnauthorized, "unauthorized")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", `{"challenge":"","key_id":"","attestation":""}`), http.StatusBadRequest, "invalid_request")

	h.recorder.configured = false
	wantStatus(t, h.post("/v1/providers/app-attest/challenge", "tok-a", ""), http.StatusServiceUnavailable, "app_attest_unavailable")
	h.recorder.configured = true
	h.handler.AppAttestConfig.TeamID = ""
	wantStatus(t, h.post("/v1/providers/app-attest/challenge", "tok-a", ""), http.StatusServiceUnavailable, "app_attest_unavailable")
	h.handler.AppAttestConfig.TeamID = testAppAttestTeam

	// A recorder failure answers 503 and the provider can retry.
	ch := h.challenge("tok-a")
	h.recorder.recordErr = errors.New("db down")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(ch.Challenge, h.attest(ch.ClientData, appattesttest.AttestOptions{}))), http.StatusServiceUnavailable, "app_attest_unavailable")
	h.recorder.recordErr = nil
	ch = h.challenge("tok-a")
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(ch.Challenge, h.attest(ch.ClientData, appattesttest.AttestOptions{}))), http.StatusOK, `"status":"recorded"`)

	req := httptest.NewRequest(http.MethodGet, "/v1/providers/app-attest", nil)
	rr := httptest.NewRecorder()
	h.handler.HandleAppAttestSubmit(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET status=%d", rr.Code)
	}
}

func TestAppAttestChallengeStoreIsBounded(t *testing.T) {
	store := NewAppAttestChallengeStore(2)
	now := time.Now()
	if _, _, err := store.Issue("mp-1", now); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Issue("mp-2", now); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Issue("mp-3", now); !errors.Is(err, errAppAttestChallengeStoreFull) {
		t.Fatalf("third outstanding challenge: err=%v", err)
	}
	// Replacing an existing provider's challenge is always allowed, and
	// expired entries are swept to make room.
	if _, _, err := store.Issue("mp-1", now); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Issue("mp-3", now.Add(appAttestChallengeTTL)); err != nil {
		t.Fatalf("after expiry: %v", err)
	}
}

// TestAppAttestRecorderPolicyCopiesAreIdentical keeps the deploy preflight
// and the provisioner on the same least-privilege policy as the startup smoke.
func TestAppAttestRecorderPolicyCopiesAreIdentical(t *testing.T) {
	for _, path := range []string{"../../dist/deploy-pearl-vps.sh", "../../dist/provision-app-attest-recorder.py"} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(raw), AppAttestRecorderPolicySQL+";\n") {
			t.Fatalf("%s does not carry AppAttestRecorderPolicySQL verbatim", path)
		}
	}
}

// TestAppAttestChallengeExpiryIsJudgedAfterTheBody: a submit that starts
// before expiry but whose body completes after it is refused.
func TestAppAttestChallengeExpiryIsJudgedAfterTheBody(t *testing.T) {
	h := newAppAttestHarness(t)
	ch := h.challenge("tok-a")
	att := h.attest(ch.ClientData, appattesttest.AttestOptions{})
	start := h.now
	calls := 0
	h.handler.Now = func() time.Time {
		calls++
		if calls == 1 {
			return start
		}
		return start.Add(appAttestChallengeTTL)
	}
	wantStatus(t, h.post("/v1/providers/app-attest", "tok-a", submitBody(ch.Challenge, att)), http.StatusConflict, "challenge_invalid")
	if len(h.recorder.byProvider) != 0 {
		t.Fatal("recorded after expiry")
	}
}
