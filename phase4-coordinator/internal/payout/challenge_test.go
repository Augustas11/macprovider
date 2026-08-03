package payout

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
)

func newChallengeRouter(t *testing.T, svc *AddressesService) http.Handler {
	t.Helper()
	r := chi.NewRouter()
	r.Get("/providers/{provider_id}/payout-address/challenge", svc.ServePayoutChallenge)
	r.Post("/providers/{provider_id}/payout-address", svc.ServePayoutAddress)
	return r
}

func TestServePayoutChallenge_HappyPath(t *testing.T) {
	db := openTestDB(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	// Pin the clock so server_ts_utc is deterministic.
	fixed := time.Unix(1719234896, 0).UTC()
	svc.Now = func() time.Time { return fixed }
	logger, buf := quietLogger()
	svc.Log = logger

	r := newChallengeRouter(t, svc)
	req := httptest.NewRequest("GET", "/providers/test-pid/payout-address/challenge", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body=%s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("json: %v", err)
	}
	canonicalHot, _ := CanonicalizeEIP55(hotWallet)
	if body["verifying_contract"] != canonicalHot {
		t.Errorf("verifying_contract=%v want %s", body["verifying_contract"], canonicalHot)
	}
	if int(body["chain_id"].(float64)) != int(PayoutChainID) {
		t.Errorf("chain_id=%v want %d", body["chain_id"], PayoutChainID)
	}
	if body["domain_name"] != "macprovider-payout" {
		t.Errorf("domain_name=%v", body["domain_name"])
	}
	if body["domain_version"] != "1" {
		t.Errorf("domain_version=%v", body["domain_version"])
	}
	if body["chain"] != "base-mainnet" {
		t.Errorf("chain=%v", body["chain"])
	}
	if int64(body["server_ts_utc"].(float64)) != fixed.Unix() {
		t.Errorf("server_ts_utc=%v want %d", body["server_ts_utc"], fixed.Unix())
	}

	// Structured §7.1 log line.
	logOut := buf.String()
	if !strings.Contains(logOut, `"event":"provider_payout_address_challenge"`) {
		t.Errorf("expected challenge success event in log; got %q", logOut)
	}
	if !strings.Contains(logOut, `"provider_id":"test-pid"`) {
		t.Errorf("expected provider_id in log; got %q", logOut)
	}
}

func TestServePayoutChallenge_IncludesRegisteredAddress(t *testing.T) {
	db := openTestDB(t)
	priv, providerAddr := signerForTest(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newChallengeRouter(t, svc)

	// Register first.
	body := buildRequestBody(t, priv, "test-pid", providerAddr, hotWallet, uint64(time.Now().Unix()), [32]byte{9})
	post := httptest.NewRequest("POST", "/providers/test-pid/payout-address", strings.NewReader(body))
	post.Header.Set("Authorization", "Bearer tok")
	postRec := httptest.NewRecorder()
	r.ServeHTTP(postRec, post)
	if postRec.Code != http.StatusCreated {
		t.Fatalf("register status %d body=%s", postRec.Code, postRec.Body.String())
	}

	req := httptest.NewRequest("GET", "/providers/test-pid/payout-address/challenge", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body=%s", rec.Code, rec.Body.String())
	}
	var resp challengeResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json: %v", err)
	}
	if resp.RegisteredAddress == nil || *resp.RegisteredAddress != providerAddr {
		t.Errorf("registered_address=%v want %s", resp.RegisteredAddress, providerAddr)
	}
	if resp.PendingUntilUTC == nil || *resp.PendingUntilUTC == "" {
		t.Error("expected pending_until_utc after registration")
	}
	if resp.PayoutAllowed == nil || !*resp.PayoutAllowed {
		t.Error("expected payout_allowed=true after first registration")
	}
}

func TestServePayoutChallenge_UnauthorizedNoToken(t *testing.T) {
	db := openTestDB(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newChallengeRouter(t, svc)

	req := httptest.NewRequest("GET", "/providers/test-pid/payout-address/challenge", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "unauthorized") {
		t.Errorf("body=%q", rec.Body.String())
	}
}

func TestServePayoutChallenge_ForbiddenWrongProvider(t *testing.T) {
	db := openTestDB(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	r := newChallengeRouter(t, svc)

	req := httptest.NewRequest("GET", "/providers/other-pid/payout-address/challenge", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestServePayoutChallenge_PreAuthPauseIdenticalBody(t *testing.T) {
	db := openTestDB(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	pause := &fakePause{paused: true}
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", pause)
	_, _ = db.ExecContext(context.Background(),
		`UPDATE runtime_flags SET value=1 WHERE name='registration_paused'`)
	r := newChallengeRouter(t, svc)

	// Unauthed during pause.
	req1 := httptest.NewRequest("GET", "/providers/test-pid/payout-address/challenge", nil)
	rec1 := httptest.NewRecorder()
	r.ServeHTTP(rec1, req1)

	// Authed during pause.
	req2 := httptest.NewRequest("GET", "/providers/test-pid/payout-address/challenge", nil)
	req2.Header.Set("Authorization", "Bearer tok")
	rec2 := httptest.NewRecorder()
	r.ServeHTTP(rec2, req2)

	if rec1.Code != http.StatusServiceUnavailable || rec2.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503/503, got %d/%d", rec1.Code, rec2.Code)
	}
	if rec1.Body.String() != rec2.Body.String() {
		t.Fatalf("pause bodies must be identical; unauthed=%q authed=%q",
			rec1.Body.String(), rec2.Body.String())
	}
	if !strings.Contains(rec1.Body.String(), "rotation_in_progress") {
		t.Errorf("body=%q missing rotation_in_progress", rec1.Body.String())
	}
}

func TestServePayoutChallenge_StructuredLogOnReject(t *testing.T) {
	db := openTestDB(t)
	hotWallet := "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
	svc := newServiceForTest(t, db, hotWallet, "test-pid", "tok", &fakePause{})
	logger, buf := quietLogger()
	svc.Log = logger
	r := newChallengeRouter(t, svc)

	req := httptest.NewRequest("GET", "/providers/test-pid/payout-address/challenge", nil)
	// no auth
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
	logOut := buf.String()
	if !strings.Contains(logOut, `"event":"provider_payout_address_challenge_rejected"`) {
		t.Errorf("expected reject event; got %q", logOut)
	}
	if !strings.Contains(logOut, `"reason":"missing_token"`) {
		t.Errorf("expected missing_token reason; got %q", logOut)
	}
}

func TestMux_ChallengeEscapedURLsAreNotCollapsed(t *testing.T) {
	db := openTestDB(t)
	svc := newServiceForTest(t, db, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359", "pid", "tok", &fakePause{})
	fallback := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})
	mux, err := NewMux(svc, fallback)
	if err != nil {
		t.Fatalf("NewMux: %v", err)
	}
	// Exact match succeeds.
	okReq := httptest.NewRequest("GET", "/providers/pid/payout-address/challenge", nil)
	okReq.Header.Set("Authorization", "Bearer tok")
	okRec := httptest.NewRecorder()
	mux.ServeHTTP(okRec, okReq)
	if okRec.Code != http.StatusOK {
		t.Fatalf("exact challenge path: status %d body=%s", okRec.Code, okRec.Body.String())
	}

	// Escaped / dot-segment forms must NOT land on the challenge realm
	// as a successful 200 (SPEC-016 §3.3 exact-match discipline).
	escapedPaths := []string{
		"/admin/payout/../providers/pid/payout-address/challenge",
		"/providers/pid/../pid/payout-address/challenge",
		"/providers/pid%2Fpayout-address%2Fchallenge",
		"/providers/pid/payout-address/challenge/",
	}
	for _, p := range escapedPaths {
		req := httptest.NewRequest("GET", p, nil)
		req.Header.Set("Authorization", "Bearer tok")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code == http.StatusOK {
			t.Fatalf("escaped path %q reached challenge handler (code=%d body=%s)",
				p, rec.Code, rec.Body.String())
		}
	}
}
