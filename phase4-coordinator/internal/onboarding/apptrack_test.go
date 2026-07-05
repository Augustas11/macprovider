package onboarding

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
)

func TestHandleAppTrackRegisterSuccess(t *testing.T) {
	body, providerID := signedRegisterBody(t, nil)
	stats := &fakeStatsDB{}
	authStore := &fakeAuthStore{token: "provider-token"}
	metrics := &fakeMetrics{}
	handler := testRegisterHandler(stats, authStore, metrics)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	waitHardwareCalls(t, stats, 1)
	hardwareProviderID, hardwareSummary := stats.hardwareSnapshot()
	if stats.nonceProviderID != providerID || stats.nonceSourceIP != "198.51.100.10" ||
		stats.upsertProviderID != providerID || hardwareProviderID != providerID {
		t.Fatalf("stats calls not wired: %+v", stats)
	}
	if hardwareSummary.Chip != "M4" || hardwareSummary.UnifiedMemoryGB != 24 {
		t.Fatalf("unexpected hardware summary: %+v", hardwareSummary)
	}
	if authStore.providerID != providerID {
		t.Fatalf("auth providerID=%q want %q", authStore.providerID, providerID)
	}
	if metrics.sourceApp != 1 {
		t.Fatalf("source metric=%d want 1", metrics.sourceApp)
	}
	var resp RegisterResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.ProviderID != providerID || resp.ProviderToken != "provider-token" || resp.TrustTier != "provisional" {
		t.Fatalf("unexpected response: %+v", resp)
	}
	if resp.CoordinatorWSURL != "wss://coordinator.streamvc.live/v2/provider" {
		t.Fatalf("coordinator_ws_url=%q", resp.CoordinatorWSURL)
	}
}

func TestHandleAppTrackRegisterAcceptsSwiftHardwareSummaryShape(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(m map[string]any) {
		m["hardware_summary"] = map[string]any{
			"chip":              "Apple Silicon",
			"unified_memory_gb": "64",
			"macos_version":     "15.5.0",
			"app_version":       "1.0.0",
		}
	})
	stats := &fakeStatsDB{}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	waitHardwareCalls(t, stats, 1)
	hardwareProviderID, hardwareSummary := stats.hardwareSnapshot()
	if hardwareProviderID != providerID {
		t.Fatalf("hardware provider_id=%q want %q", hardwareProviderID, providerID)
	}
	if hardwareSummary.Chip != "Apple Silicon" || hardwareSummary.UnifiedMemoryGB != 64 {
		t.Fatalf("unexpected hardware summary: %+v", hardwareSummary)
	}
}

func TestHandleAppTrackRegisterSkipsMissingOrEmptyHardwareSummary(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "missing",
			mutate: func(m map[string]any) {
				delete(m, "hardware_summary")
			},
		},
		{
			name: "empty chip",
			mutate: func(m map[string]any) {
				m["hardware_summary"] = map[string]any{
					"chip":              "",
					"unified_memory_gb": "64",
					"macos_version":     "15.5.0",
					"app_version":       "1.0.0",
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := signedRegisterBody(t, tc.mutate)
			stats := &fakeStatsDB{}
			handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, nil)

			req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
			req.RemoteAddr = "198.51.100.10:4444"
			rr := httptest.NewRecorder()
			handler.HandleAppTrackRegister(rr, req)

			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if calls := stats.hardwareCallsCount(); calls != 0 {
				t.Fatalf("hardware calls=%d, want 0", calls)
			}
		})
	}
}

func TestHandleAppTrackRegisterRejectsBadSignature(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	raw["signature"] = base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize))
	body, _ = json.Marshal(raw)
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401 body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleAppTrackRegisterMapsNonceReplay(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	handler := testRegisterHandler(&fakeStatsDB{nonceErr: ErrNonceReplay}, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusConflict || !strings.Contains(rr.Body.String(), "nonce_replay") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleAppTrackRegisterMapsRateLimitAndCooldown(t *testing.T) {
	for _, tc := range []struct {
		name       string
		handler    *Handler
		stats      *fakeStatsDB
		wantStatus int
		wantBody   string
	}{
		{
			name:       "ip rate limit",
			stats:      &fakeStatsDB{},
			wantStatus: http.StatusTooManyRequests,
			wantBody:   "rate_limited",
		},
		{
			name:       "reissue cooldown",
			stats:      &fakeStatsDB{},
			wantStatus: http.StatusTooManyRequests,
			wantBody:   "reissue_cooldown",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "ip rate limit" {
				tc.handler = testRegisterHandler(tc.stats, &fakeAuthStore{token: "provider-token"}, &fakeMetrics{}, denyLimiter{})
			} else {
				tc.handler = testRegisterHandler(tc.stats, &fakeAuthStore{err: auth.ErrAppTrackReissueCooldown}, nil)
			}
			body, _ := signedRegisterBody(t, nil)
			req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
			req.RemoteAddr = "198.51.100.10:4444"
			rr := httptest.NewRecorder()
			tc.handler.HandleAppTrackRegister(rr, req)
			if rr.Code != tc.wantStatus || !strings.Contains(rr.Body.String(), tc.wantBody) {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if calls := tc.stats.hardwareCallsCount(); calls != 0 {
				t.Fatalf("hardware calls=%d, want 0 for rejected request", calls)
			}
		})
	}
}

func TestHandleAppTrackRegisterRateLimitDoesNotWriteReplayNonce(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	stats := &fakeStatsDB{}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, &fakeMetrics{}, denyLimiter{})

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusTooManyRequests || !strings.Contains(rr.Body.String(), "rate_limited") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if stats.nonceCalls != 0 {
		t.Fatalf("nonce calls=%d, want 0 before rate-limit rejection", stats.nonceCalls)
	}
	if calls := stats.hardwareCallsCount(); calls != 0 {
		t.Fatalf("hardware calls=%d, want 0 before rate-limit rejection", calls)
	}
}

func TestHandleAppTrackRegisterHardwareFailureDoesNotStrandToken(t *testing.T) {
	body, providerID := signedRegisterBody(t, nil)
	stats := &fakeStatsDB{hardwareErr: errors.New("hardware store down")}
	authStore := &fakeAuthStore{token: "provider-token"}
	metrics := &fakeMetrics{}
	handler := testRegisterHandler(stats, authStore, metrics)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if authStore.providerID != providerID {
		t.Fatalf("auth providerID=%q want %q", authStore.providerID, providerID)
	}
	waitHardwareCalls(t, stats, 1)
	waitHardwareErrorMetric(t, metrics, 1)
}

func TestHandleAppTrackRegisterHardwarePersistenceCannotBlockTokenResponse(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	block := make(chan struct{})
	stats := &fakeStatsDB{hardwareBlock: block, hardwareStarted: make(chan struct{})}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	select {
	case <-stats.hardwareStarted:
	case <-time.After(time.Second):
		t.Fatal("hardware persistence did not start")
	}
	close(block)
}

func TestHandleAppTrackRegisterDropsHardwareWhenAsyncLaneFull(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	stats := &fakeStatsDB{}
	metrics := &fakeMetrics{}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, metrics)
	slots := make(chan struct{}, 1)
	slots <- struct{}{}
	handler.HardwareProfilePersistSlots = slots

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if calls := stats.hardwareCallsCount(); calls != 0 {
		t.Fatalf("hardware calls=%d, want 0 when async lane is full", calls)
	}
	if got := metrics.hardwareProfileErrorCount(); got != 1 {
		t.Fatalf("hardware profile error metric=%d want 1", got)
	}
}

func TestHandleAppTrackRegisterUsesServerTimeForNonceReplay(t *testing.T) {
	body, _ := signedRegisterBody(t, func(m map[string]any) {
		m["ts_utc"] = "2026-07-03T11:59:00Z"
	})
	stats := &fakeStatsDB{}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	want := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	if !stats.nonceObservedAt.Equal(want) {
		t.Fatalf("nonce observed_at=%s want server time %s", stats.nonceObservedAt, want)
	}
}

func TestHandleAppTrackRegisterAppAttestPresentRequiresVerifier(t *testing.T) {
	body, _ := signedRegisterBody(t, func(m map[string]any) {
		m["app_attest_object"] = base64.StdEncoding.EncodeToString([]byte{0xa0})
		m["app_attest_key_id"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	})
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusBadRequest || !strings.Contains(rr.Body.String(), "app_attest_unverified") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleAppTrackRegisterAppAttestRequiresPinnedTeamAndBundle(t *testing.T) {
	body, _ := signedRegisterBody(t, func(m map[string]any) {
		m["app_attest_object"] = base64.StdEncoding.EncodeToString([]byte{0xa0})
		m["app_attest_key_id"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	})
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{token: "provider-token"}, nil)
	handler.AppAttestVerifier = &fakeAppAttestVerifier{ok: true}
	handler.AppAttestConfig = AppAttestConfig{}

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusServiceUnavailable || !strings.Contains(rr.Body.String(), "app_attest_pin_unconfigured") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleAppTrackRegisterAcceptsVerifiedAppAttest(t *testing.T) {
	keyID := bytes.Repeat([]byte{1}, 32)
	body, _ := signedRegisterBody(t, func(m map[string]any) {
		m["app_attest_object"] = base64.StdEncoding.EncodeToString([]byte{0xa0})
		m["app_attest_key_id"] = base64.StdEncoding.EncodeToString(keyID)
	})
	stats := &fakeStatsDB{}
	verifier := &fakeAppAttestVerifier{ok: true}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, nil)
	handler.AppAttestVerifier = verifier

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if !verifier.seen || !bytes.Equal(verifier.evidence.KeyID, keyID) {
		t.Fatalf("verifier evidence not wired: seen=%v key=%x", verifier.seen, verifier.evidence.KeyID)
	}
	if !stats.upsertAttested || !bytes.Equal(stats.upsertAppAttestKeyID, keyID) {
		t.Fatalf("attested identity not persisted: attested=%v key=%x", stats.upsertAttested, stats.upsertAppAttestKeyID)
	}
}

func TestHandleAppTrackRegisterMapsAppAttestFailures(t *testing.T) {
	for _, tc := range []struct {
		name       string
		stats      *fakeStatsDB
		verifier   AppAttestVerifier
		wantStatus int
		wantBody   string
	}{
		{
			name:       "key reused",
			stats:      &fakeStatsDB{checkKeyErr: ErrAttestKeyReused},
			verifier:   &fakeAppAttestVerifier{ok: true},
			wantStatus: http.StatusConflict,
			wantBody:   "app_attest_key_reused",
		},
		{
			name:       "binding failure",
			stats:      &fakeStatsDB{},
			verifier:   &fakeAppAttestVerifier{err: ErrAppAttestBinding},
			wantStatus: http.StatusBadRequest,
			wantBody:   "app_attest_binding_failed",
		},
		{
			name:       "transient fallback",
			stats:      &fakeStatsDB{},
			verifier:   &fakeAppAttestVerifier{err: ErrAppAttestTransient},
			wantStatus: http.StatusOK,
			wantBody:   "provider-token",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := signedRegisterBody(t, func(m map[string]any) {
				m["app_attest_object"] = base64.StdEncoding.EncodeToString([]byte{0xa0})
				m["app_attest_key_id"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
			})
			handler := testRegisterHandler(tc.stats, &fakeAuthStore{token: "provider-token"}, nil)
			handler.AppAttestVerifier = tc.verifier
			req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
			req.RemoteAddr = "198.51.100.10:4444"
			rr := httptest.NewRecorder()
			handler.HandleAppTrackRegister(rr, req)
			if rr.Code != tc.wantStatus || !strings.Contains(rr.Body.String(), tc.wantBody) {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
		})
	}
}

func TestHandleAppTrackRegisterAppAttestTimeoutFallsBackTransient(t *testing.T) {
	body, _ := signedRegisterBody(t, func(m map[string]any) {
		m["app_attest_object"] = base64.StdEncoding.EncodeToString([]byte{0xa0})
		m["app_attest_key_id"] = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	})
	stats := &fakeStatsDB{}
	handler := testRegisterHandler(stats, &fakeAuthStore{token: "provider-token"}, nil)
	handler.AppAttestVerifier = waitForCancelAppAttestVerifier{}

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	start := time.Now()
	handler.HandleAppTrackRegister(rr, req)
	elapsed := time.Since(start)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if stats.upsertAttested {
		t.Fatal("timeout fallback persisted attested=true")
	}
	if elapsed < 2*time.Second || elapsed > 3*time.Second {
		t.Fatalf("verification timeout elapsed=%s, want about 2s", elapsed)
	}
}

func TestHandleAppTrackRegisterMapsTOFUConflict(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	handler := testRegisterHandler(&fakeStatsDB{upsertErr: ErrTOFUConflict}, &fakeAuthStore{token: "provider-token"}, nil)

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusConflict || !strings.Contains(rr.Body.String(), "provider_id_pubkey_mismatch") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleAppTrackRegisterDuplicateBearerProofPaths(t *testing.T) {
	current := "current-token"
	for _, tc := range []struct {
		name       string
		header     string
		bodyToken  *string
		authErr    error
		wantStatus int
		wantBearer *string
		wantBody   string
	}{
		{
			name:       "missing proof",
			authErr:    auth.ErrAppTrackExistingTokenNoProof,
			wantStatus: http.StatusConflict,
			wantBody:   "existing_active_token_no_proof",
		},
		{
			name:       "body proof rejected",
			bodyToken:  &current,
			wantStatus: http.StatusBadRequest,
			wantBody:   "bearer_proof_in_body",
		},
		{
			name:       "authorization header proof",
			header:     "Bearer header-token",
			wantStatus: http.StatusOK,
			wantBearer: stringPtr("header-token"),
			wantBody:   "provider-token",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, _ := signedRegisterBody(t, func(m map[string]any) {
				if tc.bodyToken != nil {
					m["current_provider_token"] = *tc.bodyToken
				}
			})
			stats := &fakeStatsDB{}
			authStore := &fakeAuthStore{token: "provider-token", err: tc.authErr}
			handler := testRegisterHandler(stats, authStore, nil)
			req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
			req.RemoteAddr = "198.51.100.10:4444"
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rr := httptest.NewRecorder()
			handler.HandleAppTrackRegister(rr, req)
			if rr.Code != tc.wantStatus || !strings.Contains(rr.Body.String(), tc.wantBody) {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if tc.wantBearer != nil {
				if authStore.bearer == nil || *authStore.bearer != *tc.wantBearer {
					t.Fatalf("bearer=%v want %q", authStore.bearer, *tc.wantBearer)
				}
				waitHardwareCalls(t, stats, 1)
				if calls := stats.hardwareCallsCount(); calls != 1 {
					t.Fatalf("hardware calls=%d, want 1 for accepted duplicate proof", calls)
				}
			} else if calls := stats.hardwareCallsCount(); calls != 0 {
				t.Fatalf("hardware calls=%d, want 0 for rejected duplicate path", calls)
			}
		})
	}
}

func TestHandleAppTrackRegisterDoesNotApplyASNLimiterWithoutResolver(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{token: "provider-token"}, nil)
	handler.ASNResolver = nil
	handler.ASNRateLimiter = denyLimiter{}

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleAppTrackRegisterAppliesASNLimiterWithResolver(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{token: "provider-token"}, &fakeMetrics{})
	handler.ASNResolver = fakeASNResolver{asn: "AS64500", ok: true}
	handler.ASNRateLimiter = denyLimiter{}

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusTooManyRequests || !strings.Contains(rr.Body.String(), "rate_limited") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestClientIPUsesRightmostUntrustedAndCanonicalRealIP(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("10.0.0.0/8")}
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.RemoteAddr = "127.0.0.1:5000"
	req.Header.Set("X-Forwarded-For", "malformed, 203.0.113.9, 10.1.2.3")
	if got := clientIP(req, trusted); got != "203.0.113.9" {
		t.Fatalf("clientIP XFF=%q", got)
	}

	req = httptest.NewRequest(http.MethodPost, "/", nil)
	req.RemoteAddr = "127.0.0.1:5000"
	req.Header.Set("X-Real-IP", "2001:db8::1")
	if got := clientIP(req, trusted); got != "2001:db8::1" {
		t.Fatalf("clientIP X-Real-IP=%q", got)
	}

	req = httptest.NewRequest(http.MethodPost, "/", nil)
	req.RemoteAddr = "198.51.100.44:5000"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")
	if got := clientIP(req, trusted); got != "198.51.100.44" {
		t.Fatalf("direct client spoofed XFF got %q", got)
	}
}

func signedRegisterBody(t *testing.T, mutate func(map[string]any)) ([]byte, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	providerID := ProviderIDForIdentityPubkey(pub)
	body := map[string]any{
		"provider_id":     providerID,
		"identity_pubkey": base64.StdEncoding.EncodeToString(pub),
		"hardware_summary": map[string]any{
			"chip":              "M4",
			"unified_memory_gb": float64(24),
			"macos_version":     "15.5",
			"app_version":       "1.0.0",
		},
		"nonce":  strings.Repeat("a", 64),
		"ts_utc": "2026-07-03T12:00:00Z",
	}
	normalized, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal unsigned body: %v", err)
	}
	body = map[string]any{}
	if err := json.Unmarshal(normalized, &body); err != nil {
		t.Fatalf("normalize unsigned body: %v", err)
	}
	if mutate != nil {
		mutate(body)
	}
	canonical, err := billing.CanonicalJSON(body)
	if err != nil {
		t.Fatalf("canonical body: %v", err)
	}
	body["signature"] = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	out, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal signed body: %v", err)
	}
	return out, providerID
}

func testRegisterHandler(stats *fakeStatsDB, authStore *fakeAuthStore, metrics *fakeMetrics, limiters ...IPRateLimiter) *Handler {
	var limiter IPRateLimiter = allowLimiter{}
	if len(limiters) > 0 {
		limiter = limiters[0]
	}
	return &Handler{
		StatsDB:           stats,
		AuthTokenStore:    authStore,
		CoordinatorDomain: "coordinator.streamvc.live",
		CoordinatorWSURL:  "wss://coordinator.streamvc.live/v2/provider",
		IPRateLimiter:     limiter,
		ASNRateLimiter:    allowLimiter{},
		AppAttestConfig: AppAttestConfig{
			BundleID: "live.streamvc.Malibu",
			TeamID:   "MALIBU1234",
		},
		Metrics: metrics,
		Now: func() time.Time {
			return time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
		},
	}
}

type fakeStatsDB struct {
	mu                   sync.Mutex
	nonceErr             error
	upsertErr            error
	checkKeyErr          error
	nonceProviderID      string
	nonceSourceIP        string
	nonceObservedAt      time.Time
	nonceCalls           int
	upsertProviderID     string
	upsertAttested       bool
	upsertAppAttestKeyID []byte
	hardwareProviderID   string
	hardwareSummary      HardwareSummary
	hardwareObservedAt   time.Time
	hardwareCalls        int
	hardwareErr          error
	hardwareBlock        <-chan struct{}
	hardwareStarted      chan struct{}
	hardwareStartedOnce  sync.Once
}

func (f *fakeStatsDB) UpsertProviderIdentity(ctx context.Context, providerID string, identityPubkey []byte, attested bool, appAttestKeyID []byte) error {
	f.upsertProviderID = providerID
	f.upsertAttested = attested
	f.upsertAppAttestKeyID = append([]byte(nil), appAttestKeyID...)
	return f.upsertErr
}

func (f *fakeStatsDB) UpsertProviderHardwareProfile(ctx context.Context, providerID string, summary HardwareSummary, observedAt time.Time) error {
	f.mu.Lock()
	f.hardwareCalls++
	f.hardwareProviderID = providerID
	f.hardwareSummary = summary
	f.hardwareObservedAt = observedAt
	started := f.hardwareStarted
	block := f.hardwareBlock
	err := f.hardwareErr
	f.mu.Unlock()
	if started != nil {
		f.hardwareStartedOnce.Do(func() { close(started) })
	}
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return err
}

func (f *fakeStatsDB) InsertRegisterNonce(ctx context.Context, providerID, sourceIP, nonce string, tsUtc time.Time) error {
	f.nonceCalls++
	f.nonceProviderID = providerID
	f.nonceSourceIP = sourceIP
	f.nonceObservedAt = tsUtc
	return f.nonceErr
}

func (f *fakeStatsDB) CheckAppAttestKeyIDUnique(ctx context.Context, keyID []byte, providerID string) error {
	return f.checkKeyErr
}

type fakeAppAttestVerifier struct {
	ok       bool
	err      error
	seen     bool
	evidence AppAttestEvidence
}

func (f *fakeAppAttestVerifier) Verify(ctx context.Context, evidence AppAttestEvidence) (bool, error) {
	f.seen = true
	f.evidence = evidence
	return f.ok, f.err
}

type waitForCancelAppAttestVerifier struct{}

func (waitForCancelAppAttestVerifier) Verify(ctx context.Context, evidence AppAttestEvidence) (bool, error) {
	<-ctx.Done()
	return false, ctx.Err()
}

type fakeAuthStore struct {
	token      string
	err        error
	providerID string
	bearer     *string
}

func (f *fakeAuthStore) MintProviderTokenAppTrack(ctx context.Context, providerID string, currentBearer *string) (string, error) {
	f.providerID = providerID
	f.bearer = currentBearer
	if f.err != nil {
		return "", f.err
	}
	return f.token, nil
}

type fakeMetrics struct {
	mu                    sync.Mutex
	sourceApp             int
	limitIP               int
	limitASN              int
	hardwareProfileErrors int
}

type fakeASNResolver struct {
	asn string
	ok  bool
	err error
}

func (f fakeASNResolver) ResolveASN(ctx context.Context, ip netip.Addr) (string, bool, error) {
	return f.asn, f.ok, f.err
}

func (f *fakeMetrics) IncRegisterRateLimitHit(scope string) {
	if f == nil {
		return
	}
	switch scope {
	case "ip":
		f.limitIP++
	case "asn":
		f.limitASN++
	default:
		panic(errors.New("unexpected scope"))
	}
}

func (f *fakeMetrics) IncRegisterSource(track string) {
	if f == nil {
		return
	}
	if track == "app" {
		f.sourceApp++
	}
}

func (f *fakeMetrics) IncRegisterHardwareProfileError() {
	if f == nil {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hardwareProfileErrors++
}

func (f *fakeStatsDB) hardwareCallsCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hardwareCalls
}

func (f *fakeStatsDB) hardwareSnapshot() (string, HardwareSummary) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hardwareProviderID, f.hardwareSummary
}

func (f *fakeMetrics) hardwareProfileErrorCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hardwareProfileErrors
}

func waitHardwareCalls(t *testing.T, stats *fakeStatsDB, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if stats.hardwareCallsCount() == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("hardware calls=%d want %d", stats.hardwareCallsCount(), want)
}

func waitHardwareErrorMetric(t *testing.T, metrics *fakeMetrics, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if metrics.hardwareProfileErrorCount() == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("hardware profile error metric=%d want %d", metrics.hardwareProfileErrorCount(), want)
}

type allowLimiter struct{}

func (allowLimiter) Allow(string) bool { return true }

type denyLimiter struct{}

func (denyLimiter) Allow(string) bool { return false }

func stringPtr(s string) *string {
	return &s
}
