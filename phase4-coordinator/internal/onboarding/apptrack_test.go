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
	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
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

func TestHandleAppTrackRegisterBogusBearerDoesNotBypassReferralGate(t *testing.T) {
	body, _ := signedRegisterBody(t, nil)
	stats := &fakeStatsDB{}
	authStore := &fakeAuthStore{referralMintErr: auth.ErrReferralRequired}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer bogus")
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, req)

	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "referral_required") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.referralMintCalls != 1 || stats.prepareCalls != 0 || stats.upsertProviderID != "" {
		t.Fatalf("mintCalls=%d prepareCalls=%d upsert=%q", authStore.referralMintCalls, stats.prepareCalls, stats.upsertProviderID)
	}
}

func TestHandleAppTrackRegisterValidBearerBypassesReferralConsumption(t *testing.T) {
	body, providerID := signedRegisterBody(t, nil)
	stats := &fakeStatsDB{}
	authStore := &fakeAuthStore{
		token:              "replacement-token",
		validateOK:         true,
		validateProviderID: providerID,
		referralMintErr:    auth.ErrReferralRequired,
	}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer current-token")
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, req)

	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.referralMintCalls != 0 || stats.nonceCalls != 1 || stats.upsertProviderID != providerID {
		t.Fatalf("referralMints=%d nonceCalls=%d upsert=%q", authStore.referralMintCalls, stats.nonceCalls, stats.upsertProviderID)
	}
}

func TestHandleAppTrackRegisterFreshGateUsesSagaThenDiscloses(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{}
	authStore := &fakeAuthStore{
		referralToken:      "fresh-token",
		validateOK:         true,
		validateProviderID: providerID,
	}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, req)

	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "fresh-token") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.referralMintCalls != 1 || stats.prepareCalls != 1 || authStore.ackCalls != 1 || authStore.rollbackCalls != 0 {
		t.Fatalf("mint=%d prepare=%d ack=%d rollback=%d", authStore.referralMintCalls, stats.prepareCalls, authStore.ackCalls, authStore.rollbackCalls)
	}
	if stats.nonceCalls != 0 || stats.upsertProviderID != "" {
		t.Fatalf("fresh gate used non-atomic legacy PG path: nonce=%d upsert=%q", stats.nonceCalls, stats.upsertProviderID)
	}
}

func TestHandleAppTrackRegisterCommittedRetryNeverRotatesCredential(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{
		referralToken:      "must-not-mint",
		validateOK:         true,
		validateProviderID: providerID,
	}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, req)

	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), strings.Repeat("c", 64)) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.referralMintCalls != 0 || stats.prepareCalls != 0 {
		t.Fatalf("committed retry mutated state: mint=%d prepare=%d", authStore.referralMintCalls, stats.prepareCalls)
	}
}

func TestHandleAppTrackRegisterCommittedRetrySurvivesRollbackSkewAndRateLimit(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{
		validateOK:         true,
		validateProviderID: providerID,
	}
	metrics := &fakeMetrics{}
	handler := testRegisterHandler(stats, authStore, metrics, denyLimiter{})
	handler.ReferralStore = authStore
	handler.Now = func() time.Time {
		return time.Date(2026, 7, 3, 12, 2, 0, 0, time.UTC)
	}
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))

	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), strings.Repeat("c", 64)) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.referralMintCalls != 0 || stats.prepareCalls != 0 || stats.nonceCalls != 0 {
		t.Fatalf("committed retry mutated state: mint=%d prepare=%d nonce=%d", authStore.referralMintCalls, stats.prepareCalls, stats.nonceCalls)
	}
	if metrics.limitIP != 0 {
		t.Fatalf("committed retry reached IP limiter: hits=%d", metrics.limitIP)
	}
}

func TestHandleAppTrackRegisterCommittedRetryIsBoundedBeforeCredentialLookup(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{validateOK: true, validateProviderID: providerID}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralStore = authStore
	limiter := newPerKeyLimiter(1)
	handler.CommittedRetryRateLimiter = limiter
	handler.Now = func() time.Time {
		return time.Date(2026, 7, 3, 12, 2, 0, 0, time.UTC)
	}

	first := httptest.NewRecorder()
	firstRequest := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	firstRequest.RemoteAddr = "198.51.100.10:4444"
	handler.HandleAppTrackRegister(first, firstRequest)
	if first.Code != http.StatusOK {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}

	second := httptest.NewRecorder()
	secondRequest := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	secondRequest.RemoteAddr = "198.51.100.10:4444"
	handler.HandleAppTrackRegister(second, secondRequest)
	if second.Code != http.StatusTooManyRequests || !strings.Contains(second.Body.String(), "rate_limited") {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	if authStore.validateCalls != 1 || stats.preparedChecks != 1 {
		t.Fatalf("bounded retry authority calls: validates=%d prepared=%d", authStore.validateCalls, stats.preparedChecks)
	}
	if len(limiter.keys) != 3 ||
		limiter.keys[0] != "provider|"+providerID ||
		limiter.keys[1] != "ip|198.51.100.10" {
		t.Fatalf("recovery limiter keys=%q", limiter.keys)
	}
}

func TestHandleAppTrackRegisterAbsentCommittedRetryIsBounded(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: false}
	authStore := &fakeAuthStore{validateOK: true, validateProviderID: providerID}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralStore = authStore
	limiter := newPerKeyLimiter(1)
	handler.CommittedRetryRateLimiter = limiter
	handler.Now = func() time.Time {
		return time.Date(2026, 7, 3, 12, 2, 0, 0, time.UTC)
	}

	first := httptest.NewRecorder()
	handler.HandleAppTrackRegister(first, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))
	if first.Code != http.StatusBadRequest || !strings.Contains(first.Body.String(), "timestamp_skew") {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	second := httptest.NewRecorder()
	handler.HandleAppTrackRegister(second, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))
	if second.Code != http.StatusTooManyRequests || !strings.Contains(second.Body.String(), "rate_limited") {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	if authStore.validateCalls != 1 || stats.preparedChecks != 1 {
		t.Fatalf("bounded absent retry authority calls: validates=%d prepared=%d", authStore.validateCalls, stats.preparedChecks)
	}
}

func TestHandleAppTrackRegisterCommittedRetryGlobalCapacityPrecedesAuthorities(t *testing.T) {
	body, _ := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{validateOK: true}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralStore = authStore
	handler.CommittedRetrySlots = make(chan struct{}, 1)
	handler.CommittedRetrySlots <- struct{}{}
	handler.Now = func() time.Time {
		return time.Date(2026, 7, 3, 12, 2, 0, 0, time.UTC)
	}
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))

	if response.Code != http.StatusTooManyRequests || !strings.Contains(response.Body.String(), "rate_limited") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.validateCalls != 0 || stats.preparedChecks != 0 {
		t.Fatalf("capacity-bound retry reached authorities: validates=%d prepared=%d", authStore.validateCalls, stats.preparedChecks)
	}
}

func TestHandleAppTrackRegisterCommittedRetryGlobalRatePrecedesPerKeyState(t *testing.T) {
	body, _ := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{validateOK: true}
	perKey := newPerKeyLimiter(1)
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralStore = authStore
	handler.CommittedRetryGlobalRateLimiter = denyLimiter{}
	handler.CommittedRetryRateLimiter = perKey
	handler.Now = func() time.Time {
		return time.Date(2026, 7, 3, 12, 2, 0, 0, time.UTC)
	}
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))

	if response.Code != http.StatusTooManyRequests || !strings.Contains(response.Body.String(), "rate_limited") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if len(perKey.keys) != 0 || authStore.validateCalls != 0 || stats.preparedChecks != 0 {
		t.Fatalf("global-bound retry reached lower authorities: keys=%q validates=%d prepared=%d", perKey.keys, authStore.validateCalls, stats.preparedChecks)
	}
}

func TestHandleAppTrackRegisterCommittedRetryRejectsDifferentCandidate(t *testing.T) {
	body, _ := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))

	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "committed_credential_mismatch") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if authStore.referralMintCalls != 0 || stats.prepareCalls != 0 {
		t.Fatalf("committed retry mutated state: mint=%d prepare=%d", authStore.referralMintCalls, stats.prepareCalls)
	}
}

func TestHandleAppTrackRegisterGateRequiresClientHeldCandidate(t *testing.T) {
	body, _ := signedRegisterBody(t, func(body map[string]any) {
		body["referral_code"] = "invite"
		delete(body, "provider_token_candidate")
	})
	stats := &fakeStatsDB{}
	authStore := &fakeAuthStore{}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body)))

	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "provider_token_candidate_required") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestHandleAppTrackRegisterCompensatesOnlyProvenAbsentPrepare(t *testing.T) {
	body, providerID := signedRegisterBody(t, func(body map[string]any) { body["referral_code"] = "invite" })
	stats := &fakeStatsDB{prepareErr: ErrTOFUConflict, prepared: false}
	authStore := &fakeAuthStore{
		referralToken:      "undisclosed-token",
		validateOK:         true,
		validateProviderID: providerID,
	}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralPolicy = auth.ReferralPolicy{RequireForRegistration: true}
	handler.ReferralStore = authStore
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	response := httptest.NewRecorder()

	handler.HandleAppTrackRegister(response, req)

	if response.Code != http.StatusConflict || authStore.rollbackCalls != 1 || authStore.ackCalls != 0 {
		t.Fatalf("status=%d rollback=%d ack=%d body=%s", response.Code, authStore.rollbackCalls, authStore.ackCalls, response.Body.String())
	}
}

func TestReconcilePendingAppTrackReferralMintUsesExactSignedAttemptWithEnforcementOff(t *testing.T) {
	attemptTS := time.Date(2026, 7, 3, 11, 59, 30, 0, time.UTC)
	pending := auth.PendingAppTrackReferralMint{
		ProviderID: "provider-a",
		TokenHash:  strings.Repeat("a", 64),
		Attempt: auth.AppTrackRegistrationAttempt{
			SourceIP: "203.0.113.10", Nonce: strings.Repeat("b", 64), AttemptTS: attemptTS,
		},
	}
	stats := &fakeStatsDB{prepared: true}
	authStore := &fakeAuthStore{pendingMints: []auth.PendingAppTrackReferralMint{pending}}
	handler := testRegisterHandler(stats, authStore, nil)
	handler.ReferralStore = authStore

	if err := handler.ReconcilePendingAppTrackReferralMints(context.Background()); err != nil {
		t.Fatal(err)
	}
	if stats.preparedProviderID != pending.ProviderID || stats.preparedNonce != pending.Attempt.Nonce || !stats.preparedAttemptTS.Equal(attemptTS) {
		t.Fatalf("prepared lookup provider=%q nonce=%q ts=%s", stats.preparedProviderID, stats.preparedNonce, stats.preparedAttemptTS)
	}
	if len(authStore.resolvedMints) != 1 || !authStore.resolvedPrepared[0] {
		t.Fatalf("resolved=%+v prepared=%+v", authStore.resolvedMints, authStore.resolvedPrepared)
	}
}

func TestReconcilePendingAppTrackReferralMintReportsMissingPostgresAuthority(t *testing.T) {
	authStore := &fakeAuthStore{pendingMints: []auth.PendingAppTrackReferralMint{{
		ProviderID: "provider-a",
		Attempt: auth.AppTrackRegistrationAttempt{
			Nonce:     strings.Repeat("b", 64),
			AttemptTS: time.Date(2026, 7, 3, 11, 59, 30, 0, time.UTC),
		},
	}}}
	handler := &Handler{
		ReferralStore: authStore,
		Now: func() time.Time {
			return time.Date(2026, 7, 3, 12, 2, 0, 0, time.UTC)
		},
	}

	err := handler.ReconcilePendingAppTrackReferralMints(context.Background())
	if err == nil || !strings.Contains(err.Error(), "registration prepare store unavailable") {
		t.Fatalf("error=%v, want missing registration prepare authority", err)
	}
	if len(authStore.resolvedMints) != 0 {
		t.Fatalf("resolved without PostgreSQL authority: %+v", authStore.resolvedMints)
	}
}

func TestHandleHardwareEvidenceQueuesAuthenticatedAutotuneEvidence(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	stats := &fakeStatsDB{}
	handler := testRegisterHandler(stats, &fakeAuthStore{
		validateOK:         true,
		validateProviderID: "mac",
	}, nil)
	body := validHardwareEvidenceBody(now)
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer provider-token")
	rr := httptest.NewRecorder()

	handler.HandleHardwareEvidence(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if stats.evidenceProviderID != "mac" {
		t.Fatalf("evidenceProviderID=%q want mac", stats.evidenceProviderID)
	}
	if stats.evidenceRequest.Hardware.Chip != "Apple M5" || stats.evidenceRequest.Hardware.MemoryGB != 32 {
		t.Fatalf("unexpected evidence request: %+v", stats.evidenceRequest)
	}
	if !stats.evidenceGeneratedAt.Equal(now) {
		t.Fatalf("generatedAt=%s want %s", stats.evidenceGeneratedAt, now)
	}
}

func TestCanonicalHardwareEvidenceSHAMatchesSwiftJCS(t *testing.T) {
	evidence := HardwareEvidenceRequest{
		SchemaVersion:          hardwareEvidenceSchemaVersion,
		ProviderID:             "mac",
		GeneratedAt:            "2026-08-29T10:40:00Z",
		CandidateCatalogSHA256: strings.Repeat("a", 64),
		RecommendedModel:       "model-a",
		ProbeProtocol:          hardwareEvidenceProbeProtocol,
		Hardware: HardwareEvidenceHardware{
			Chip:                 "Apple M5",
			MemoryGB:             32,
			BandwidthTier:        "C",
			Detected:             true,
			OSVersion:            "15.5",
			BinaryVersion:        "1.7.9",
			HardwareIdentityHash: "hash",
			ExecutableSHA256:     strings.Repeat("d", 64),
		},
		Benchmarks: []HardwareEvidenceBenchmark{{
			ModelKey:                "model-a",
			ModelID:                 "mlx-community/model-a",
			ModelArtifactPath:       "/tmp/model",
			SustainedTPS:            42.5,
			TTFTMS:                  1200,
			SwapDetected:            false,
			ThermalThrottleDetected: false,
			ArtifactSHA256:          strings.Repeat("b", 64),
			CandidateCatalogSHA256:  strings.Repeat("a", 64),
			CandidateRowIdentity:    strings.Repeat("c", 64),
			BenchmarkID:             "bench-1",
			GeneratedAt:             "2026-08-29T10:40:00Z",
			BinaryVersion:           "1.7.9",
			HardwareIdentityHash:    "hash",
		}},
	}

	sha, _, err := canonicalEvidenceSHA(evidence)
	if err != nil {
		t.Fatal(err)
	}
	// Golden updated for #745: benchmarks now include model_artifact_path.
	const want = "1c477957d51a8064a311f55b8ae86c963d83737c7d276a6a44e87e0a0fb350b7"
	if sha != want {
		t.Fatalf("evidence SHA=%q want Swift JCS SHA %q", sha, want)
	}
}

func TestHandleHardwareEvidenceRejectsProviderMismatch(t *testing.T) {
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{
		validateOK:         true,
		validateProviderID: "mac",
	}, nil)
	body := []byte(`{"schema_version":"hardware_evidence.autotune.v1","provider_id":"other","generated_at":"2026-07-03T12:00:00Z","hardware":{"chip":"Apple M5","memory_gb":32,"bandwidth_tier":"C","detected":true,"os_version":"15.5","binary_version":"1.7.9","hardware_identity_hash":"abc"},"benchmarks":[]}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer provider-token")
	rr := httptest.NewRecorder()

	handler.HandleHardwareEvidence(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleHardwareEvidenceEnforcesPostgresTimestampPrecision(t *testing.T) {
	now := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.UTC)
	for _, tc := range []struct {
		name       string
		generated  string
		wantStatus int
	}{
		{name: "microsecond", generated: "2026-07-10T12:00:00.123456Z", wantStatus: http.StatusOK},
		{name: "zero padded nanoseconds", generated: "2026-07-10T12:00:00.123456000Z", wantStatus: http.StatusOK},
		{name: "precision loss", generated: "2026-07-10T12:00:00.123456789Z", wantStatus: http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stats := &fakeStatsDB{}
			handler := testRegisterHandler(stats, &fakeAuthStore{
				validateOK: true, validateProviderID: "mac",
			}, nil)
			handler.Now = func() time.Time { return now }
			body := validHardwareEvidenceBody(now)
			body["generated_at"] = tc.generated
			raw, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(raw))
			req.Header.Set("Authorization", "Bearer token")
			rr := httptest.NewRecorder()
			handler.HandleHardwareEvidence(rr, req)
			if rr.Code != tc.wantStatus {
				t.Fatalf("status=%d body=%s want=%d", rr.Code, rr.Body.String(), tc.wantStatus)
			}
		})
	}
}

func TestHandleHardwareEvidenceRequiresBearer(t *testing.T) {
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{}, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", strings.NewReader(`{}`))
	rr := httptest.NewRecorder()

	handler.HandleHardwareEvidence(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleHardwareEvidenceMapsRateLimitBeforeBodyRead(t *testing.T) {
	handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{
		validateOK:         true,
		validateProviderID: "mac",
	}, nil)
	handler.HardwareEvidenceIPRateLimiter = denyLimiter{}
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", strings.NewReader(`not-json`))
	req.Header.Set("Authorization", "Bearer provider-token")
	rr := httptest.NewRecorder()

	handler.HandleHardwareEvidence(rr, req)

	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleHardwareEvidenceMapsDBAdmissionCap(t *testing.T) {
	stats := &fakeStatsDB{evidenceErr: ErrHardwareEvidenceRateLimited}
	handler := testRegisterHandler(stats, &fakeAuthStore{
		validateOK:         true,
		validateProviderID: "mac",
	}, nil)
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	body, err := json.Marshal(validHardwareEvidenceBody(now))
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer provider-token")
	rr := httptest.NewRecorder()

	handler.HandleHardwareEvidence(rr, req)

	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHandleHardwareEvidenceReturnsExistingReplayBeforeProviderRateLimit(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	body, err := json.Marshal(validHardwareEvidenceBody(now))
	if err != nil {
		t.Fatal(err)
	}
	var evidence HardwareEvidenceRequest
	if err := json.Unmarshal(body, &evidence); err != nil {
		t.Fatal(err)
	}
	evidenceSHA, _, err := canonicalEvidenceSHA(evidence)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name           string
		status         string
		decisionReason string
		wantHTTP       int
		wantStatus     string
	}{
		{name: "pending", status: hardwareEvidenceJobPending, wantHTTP: http.StatusOK, wantStatus: hardwareEvidenceResponseExisting},
		{name: "waiting trust", status: hardwareEvidenceJobWaitingTrust, decisionReason: "hardware-verifier.v2:trust_missing", wantHTTP: http.StatusOK, wantStatus: hardwareEvidenceResponseExisting},
		{name: "current verified trusted", status: hardwareEvidenceJobVerified, decisionReason: hardwareverify.VerifiedDecisionReason, wantHTTP: http.StatusOK, wantStatus: hardwareEvidenceResponseVerified},
		{name: "rejected", status: "rejected", decisionReason: "hardware-verifier.v2:benchmark_invalid", wantHTTP: http.StatusConflict},
		{name: "failed", status: "failed", decisionReason: "worker_failed", wantHTTP: http.StatusConflict},
		{name: "legacy verified", status: hardwareEvidenceJobVerified, decisionReason: "hardware-verifier.v1:verified", wantHTTP: http.StatusConflict},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			stats := &fakeStatsDB{
				existingEvidenceFound: true,
				existingEvidenceRecord: HardwareEvidenceJobRecord{
					JobID:          41,
					EvidenceSHA:    evidenceSHA,
					Status:         tc.status,
					DecisionReason: tc.decisionReason,
				},
			}
			handler := testRegisterHandler(stats, &fakeAuthStore{
				validateOK:         true,
				validateProviderID: "mac",
			}, nil)
			handler.HardwareEvidenceProviderRateLimiter = denyLimiter{}
			req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer provider-token")
			rr := httptest.NewRecorder()

			handler.HandleHardwareEvidence(rr, req)

			if rr.Code != tc.wantHTTP {
				t.Fatalf("status=%d want=%d body=%s", rr.Code, tc.wantHTTP, rr.Body.String())
			}
			if tc.wantStatus != "" && !strings.Contains(rr.Body.String(), `"status":"`+tc.wantStatus+`"`) {
				t.Fatalf("body=%s want response status %q", rr.Body.String(), tc.wantStatus)
			}
			if stats.evidenceProviderID != "" {
				t.Fatal("duplicate replay inserted a new verification job")
			}
			if stats.existingEvidenceProviderID != "mac" || stats.existingEvidenceSHA != evidenceSHA {
				t.Fatalf("unexpected duplicate lookup provider=%q sha=%q", stats.existingEvidenceProviderID, stats.existingEvidenceSHA)
			}
		})
	}
}

func TestHandleHardwareEvidenceDoesNotReplayDifferentPayloadByHardwareIdentity(t *testing.T) {
	now := time.Date(2026, 7, 31, 13, 0, 0, 0, time.UTC)
	body, err := json.Marshal(validHardwareEvidenceBody(now))
	if err != nil {
		t.Fatal(err)
	}
	var evidence HardwareEvidenceRequest
	if err := json.Unmarshal(body, &evidence); err != nil {
		t.Fatal(err)
	}
	evidenceSHA, _, err := canonicalEvidenceSHA(evidence)
	if err != nil {
		t.Fatal(err)
	}
	stats := &fakeStatsDB{
		identityReplayFound: true,
		identityReplayRecord: HardwareEvidenceJobRecord{
			JobID:       43,
			Status:      hardwareEvidenceJobPending,
			EvidenceSHA: evidenceSHA,
			Replay:      true,
		},
	}
	handler := testRegisterHandler(stats, &fakeAuthStore{
		validateOK:         true,
		validateProviderID: "mac",
	}, nil)
	handler.Now = func() time.Time { return now }
	handler.HardwareEvidenceProviderRateLimiter = denyLimiter{}
	req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer provider-token")
	rr := httptest.NewRecorder()

	handler.HandleHardwareEvidence(rr, req)

	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if stats.evidenceProviderID != "" || stats.identityReplayProviderID != "" {
		t.Fatal("same-identity payload reached the queue or an identity replay lookup")
	}
}

func TestHardwareEvidenceResponseStatusMarksStoreReplayExisting(t *testing.T) {
	evidenceSHA := strings.Repeat("e", 64)
	status, accepted := hardwareEvidenceResponseStatus(HardwareEvidenceJobRecord{
		JobID:       42,
		EvidenceSHA: evidenceSHA,
		Status:      hardwareEvidenceJobPending,
		Replay:      true,
	}, false, evidenceSHA)
	if !accepted || status != hardwareEvidenceResponseExisting {
		t.Fatalf("status=%q accepted=%v, want existing accepted replay", status, accepted)
	}
}

func TestHandleHardwareEvidenceRejectsReboundOrStaleBenchmarkBindings(t *testing.T) {
	now := time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "catalog rebound",
			mutate: func(body map[string]any) {
				body["benchmarks"].([]map[string]any)[0]["candidate_catalog_sha256"] = strings.Repeat("a", 64)
			},
		},
		{
			name: "binary rebound",
			mutate: func(body map[string]any) {
				body["benchmarks"].([]map[string]any)[0]["binary_version"] = "1.8.0"
			},
		},
		{
			name: "hardware rebound",
			mutate: func(body map[string]any) {
				body["benchmarks"].([]map[string]any)[0]["hardware_identity_hash"] = strings.Repeat("a", 64)
			},
		},
		{
			name: "stale benchmark",
			mutate: func(body map[string]any) {
				body["benchmarks"].([]map[string]any)[0]["generated_at"] = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339)
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			body := validHardwareEvidenceBody(now)
			tc.mutate(body)
			raw, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			handler := testRegisterHandler(&fakeStatsDB{}, &fakeAuthStore{
				validateOK:         true,
				validateProviderID: "mac",
			}, nil)
			req := httptest.NewRequest(http.MethodPost, "/v1/providers/hardware-evidence", bytes.NewReader(raw))
			req.Header.Set("Authorization", "Bearer provider-token")
			rr := httptest.NewRecorder()
			handler.HandleHardwareEvidence(rr, req)
			if rr.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
		})
	}
}

func validHardwareEvidenceBody(now time.Time) map[string]any {
	return map[string]any{
		"schema_version":           "hardware_evidence.autotune.v2",
		"probe_protocol":           "spec-023-harmony-stream.v2",
		"provider_id":              "mac",
		"generated_at":             now.Format(time.RFC3339),
		"candidate_catalog_sha256": strings.Repeat("b", 64),
		"recommended_model":        "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
		"hardware": map[string]any{
			"chip":                   "Apple M5",
			"memory_gb":              32,
			"bandwidth_tier":         "C",
			"detected":               true,
			"os_version":             "15.5",
			"binary_version":         "1.7.9",
			"hardware_identity_hash": strings.Repeat("c", 64),
			"executable_sha256":      strings.Repeat("d", 64),
		},
		"benchmarks": []map[string]any{{
			"model_key":                 "qwen-7b",
			"model_id":                  "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
			"sustained_tps":             42.5,
			"ttft_ms":                   1200,
			"swap_detected":             false,
			"thermal_throttle_detected": false,
			"artifact_sha256":           strings.Repeat("d", 64),
			"candidate_catalog_sha256":  strings.Repeat("b", 64),
			"benchmark_id":              "bench-1",
			"generated_at":              now.Format(time.RFC3339),
			"binary_version":            "1.7.9",
			"hardware_identity_hash":    strings.Repeat("c", 64),
			"candidate_row_identity":    strings.Repeat("e", 64),
		}},
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
	authStore := &fakeAuthStore{token: "provider-token", validateOK: true}
	handler := testRegisterHandler(stats, authStore, &fakeMetrics{}, denyLimiter{})

	req := httptest.NewRequest(http.MethodPost, "/v1/providers/register", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.10:4444"
	req.Header.Set("Authorization", "Bearer existing-token")
	rr := httptest.NewRecorder()
	handler.HandleAppTrackRegister(rr, req)

	if rr.Code != http.StatusTooManyRequests || !strings.Contains(rr.Body.String(), "rate_limited") {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if stats.nonceCalls != 0 {
		t.Fatalf("nonce calls=%d, want 0 before rate-limit rejection", stats.nonceCalls)
	}
	if stats.preparedChecks != 0 {
		t.Fatalf("prepared checks=%d, want 0 before rate-limit rejection", stats.preparedChecks)
	}
	if authStore.validateCalls != 0 {
		t.Fatalf("credential validations=%d, want 0 before rate-limit rejection", authStore.validateCalls)
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
		"nonce":                    strings.Repeat("a", 64),
		"ts_utc":                   "2026-07-03T12:00:00Z",
		"provider_token_candidate": strings.Repeat("c", 64),
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
		StatsDB:                         stats,
		AuthTokenStore:                  authStore,
		CoordinatorDomain:               "coordinator.streamvc.live",
		CoordinatorWSURL:                "wss://coordinator.streamvc.live/v2/provider",
		IPRateLimiter:                   limiter,
		CommittedRetryRateLimiter:       allowLimiter{},
		CommittedRetryGlobalRateLimiter: allowLimiter{},
		ASNRateLimiter:                  allowLimiter{},
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
	mu                         sync.Mutex
	nonceErr                   error
	upsertErr                  error
	checkKeyErr                error
	nonceProviderID            string
	nonceSourceIP              string
	nonceObservedAt            time.Time
	nonceCalls                 int
	upsertProviderID           string
	upsertAttested             bool
	upsertAppAttestKeyID       []byte
	hardwareProviderID         string
	hardwareSummary            HardwareSummary
	hardwareObservedAt         time.Time
	hardwareCalls              int
	hardwareErr                error
	hardwareBlock              <-chan struct{}
	hardwareStarted            chan struct{}
	hardwareStartedOnce        sync.Once
	evidenceProviderID         string
	evidenceRequest            HardwareEvidenceRequest
	evidenceGeneratedAt        time.Time
	evidenceRecord             HardwareEvidenceJobRecord
	evidenceErr                error
	existingEvidenceProviderID string
	existingEvidenceSHA        string
	existingEvidenceRecord     HardwareEvidenceJobRecord
	existingEvidenceFound      bool
	existingEvidenceErr        error
	identityReplayProviderID   string
	identityReplayHash         string
	identityReplaySHA          string
	identityReplayRecord       HardwareEvidenceJobRecord
	identityReplayFound        bool
	identityReplayErr          error
	prepareErr                 error
	prepared                   bool
	preparedErr                error
	prepareCalls               int
	preparedChecks             int
	preparedProviderID         string
	preparedNonce              string
	preparedAttemptTS          time.Time
}

func (f *fakeStatsDB) PrepareProviderRegistration(_ context.Context, providerID, sourceIP, nonce string, observedAt, attemptTS time.Time, identityPubkey []byte, attested bool, appAttestKeyID []byte) error {
	f.prepareCalls++
	f.preparedProviderID = providerID
	f.preparedNonce = nonce
	f.preparedAttemptTS = attemptTS
	return f.prepareErr
}

func (f *fakeStatsDB) ProviderRegistrationPrepared(_ context.Context, providerID, nonce string, attemptTS time.Time) (bool, error) {
	f.preparedChecks++
	f.preparedProviderID = providerID
	f.preparedNonce = nonce
	f.preparedAttemptTS = attemptTS
	return f.prepared, f.preparedErr
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

func (f *fakeStatsDB) InsertHardwareVerificationJob(ctx context.Context, providerID string, evidence HardwareEvidenceRequest, generatedAt time.Time) (HardwareEvidenceJobRecord, error) {
	f.evidenceProviderID = providerID
	f.evidenceRequest = evidence
	f.evidenceGeneratedAt = generatedAt
	if f.evidenceErr != nil {
		return HardwareEvidenceJobRecord{}, f.evidenceErr
	}
	if f.evidenceRecord.JobID == 0 {
		evidenceSHA, _, err := canonicalEvidenceSHA(evidence)
		if err != nil {
			return HardwareEvidenceJobRecord{}, err
		}
		f.evidenceRecord = HardwareEvidenceJobRecord{
			JobID:       7,
			EvidenceSHA: evidenceSHA,
			Status:      hardwareEvidenceJobPending,
		}
	}
	return f.evidenceRecord, nil
}

func (f *fakeStatsDB) ExistingHardwareVerificationJob(ctx context.Context, providerID, evidenceSHA string) (HardwareEvidenceJobRecord, bool, error) {
	f.existingEvidenceProviderID = providerID
	f.existingEvidenceSHA = evidenceSHA
	return f.existingEvidenceRecord, f.existingEvidenceFound, f.existingEvidenceErr
}

func (f *fakeStatsDB) ExistingActiveHardwareVerificationJobForHardwareIdentity(ctx context.Context, providerID, hardwareIdentityHash, responseEvidenceSHA string) (HardwareEvidenceJobRecord, bool, error) {
	f.identityReplayProviderID = providerID
	f.identityReplayHash = hardwareIdentityHash
	f.identityReplaySHA = responseEvidenceSHA
	return f.identityReplayRecord, f.identityReplayFound, f.identityReplayErr
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
	token              string
	err                error
	providerID         string
	bearer             *string
	validateProviderID string
	validateOK         bool
	validateErr        error
	validateCalls      int
	referralToken      string
	referralMintErr    error
	referralMintCalls  int
	ackErr             error
	ackCalls           int
	rollbackErr        error
	rollbackCalls      int
	pendingMints       []auth.PendingAppTrackReferralMint
	resolvedMints      []auth.PendingAppTrackReferralMint
	resolvedPrepared   []bool
}

func (f *fakeAuthStore) MintProviderTokenAppTrack(ctx context.Context, providerID string, currentBearer, freshTokenCandidate *string) (string, error) {
	f.providerID = providerID
	f.bearer = currentBearer
	if f.err != nil {
		return "", f.err
	}
	if currentBearer == nil && freshTokenCandidate != nil && f.token == "" {
		return *freshTokenCandidate, nil
	}
	return f.token, nil
}

func (f *fakeAuthStore) ValidateToken(ctx context.Context, token string) (string, bool, error) {
	f.validateCalls++
	if f.validateErr != nil {
		return "", false, f.validateErr
	}
	if !f.validateOK {
		return "", false, nil
	}
	if f.validateProviderID != "" {
		return f.validateProviderID, true, nil
	}
	return f.providerID, true, nil
}

func (f *fakeAuthStore) MintProviderTokenAppTrackWithReferralAttempt(_ context.Context, providerID, referralCode, tokenCandidate string, policy auth.ReferralPolicy, attempt auth.AppTrackRegistrationAttempt) (string, error) {
	f.referralMintCalls++
	f.providerID = providerID
	if f.referralMintErr != nil {
		return "", f.referralMintErr
	}
	if f.referralToken != "" {
		return f.referralToken, nil
	}
	return tokenCandidate, nil
}

func (f *fakeAuthStore) AcknowledgeAppTrackReferralMint(context.Context, string, string) error {
	f.ackCalls++
	return f.ackErr
}

func (f *fakeAuthStore) RollbackAppTrackReferralMint(context.Context, string, string) error {
	f.rollbackCalls++
	return f.rollbackErr
}

func (f *fakeAuthStore) ListPendingAppTrackReferralMints(context.Context, time.Time) ([]auth.PendingAppTrackReferralMint, error) {
	return append([]auth.PendingAppTrackReferralMint(nil), f.pendingMints...), nil
}

func (f *fakeAuthStore) ResolvePendingAppTrackReferralMint(_ context.Context, pending auth.PendingAppTrackReferralMint, prepared bool) error {
	f.resolvedMints = append(f.resolvedMints, pending)
	f.resolvedPrepared = append(f.resolvedPrepared, prepared)
	return nil
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

type perKeyLimiter struct {
	limit int
	hits  map[string]int
	keys  []string
}

func newPerKeyLimiter(limit int) *perKeyLimiter {
	return &perKeyLimiter{limit: limit, hits: make(map[string]int)}
}

func (l *perKeyLimiter) Allow(key string) bool {
	l.keys = append(l.keys, key)
	if l.hits[key] >= l.limit {
		return false
	}
	l.hits[key]++
	return true
}

func stringPtr(s string) *string {
	return &s
}
