package buyer

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

const (
	privacyTestCDHash  = "0123456789abcdef0123456789abcdef01234567"
	privacyTestBinary  = "0.0.0-fixture"
	privacyTestTeamID  = "AB12CD34EF"
	privacyTestSigning = "live.malibu.provider.cli"
)

type privacyClock struct {
	mu sync.Mutex
	at time.Time
}

func (c *privacyClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *privacyClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.at = c.at.Add(d)
	c.mu.Unlock()
}

type privacyHarness struct {
	server         *Server
	store          *relayblind.Store
	clock          *privacyClock
	authority      *relayblind.PrivacyAuthority
	privacyKey     relayblind.KeyRecord
	relayKey       relayblind.KeyRecord
	privacyPrivate *ecdh.PrivateKey
	relayPrivate   *ecdh.PrivateKey
	provider       pool.Provider
	admission      *providerws.AdmissionManager
	requestLog     *requestlog.Store
}

type privacyHarnessConfig struct {
	privacyKey     bool
	privacyEnabled bool
	relayKey       bool
	maxAge         int
	ttl            int
	quota          int
	relay          RelayBlindRelayFunc
	requestLog     bool
}

func newPrivacyHarness(t *testing.T, cfg privacyHarnessConfig) *privacyHarness {
	t.Helper()
	if cfg.maxAge == 0 {
		cfg.maxAge = 150
	}
	if cfg.ttl == 0 {
		cfg.ttl = 600
	}
	now := time.Unix(1_800_000_000, 0).UTC()
	clock := &privacyClock{at: now}
	store, err := relayblind.OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	identityPublic, identityPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	seRaw := make([]byte, 64)
	seKey.X.FillBytes(seRaw[:32])
	seKey.Y.FillBytes(seRaw[32:])
	h := &privacyHarness{store: store, clock: clock}
	if cfg.privacyKey || cfg.privacyEnabled {
		if cfg.privacyKey {
			h.privacyPrivate, h.privacyKey = privacyTestKey(t, identityPrivate, now)
		}
		privacyCfg := config.PrivacyClassConfig{
			Enabled:              true,
			ProviderSEPublicKeys: map[string]string{"provider-a": base64.StdEncoding.EncodeToString(seRaw)},
			ApprovedCodeIdentities: []config.ApprovedCodeIdentity{{
				TeamID: privacyTestTeamID, SigningIdentifier: privacyTestSigning, CDHash: privacyTestCDHash,
				BinaryVersion: privacyTestBinary, ExpiresAt: now.Add(24 * time.Hour),
			}},
			AllowedSEKeyBackends:            []string{relayblind.PrivacySEBackendFile, relayblind.PrivacySEBackendKeychain},
			PostureChallengeIntervalSeconds: 60,
			PostureMaxAgeSeconds:            cfg.maxAge,
			PostureResponseTimeoutSeconds:   10,
			QuarantineSeconds:               86400,
		}
		h.authority, err = relayblind.NewPrivacyAuthority(store, privacyCfg, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8, 5*time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		if cfg.privacyKey {
			record := privacyTestRecord(t, identityPrivate, h.privacyKey)
			if err := h.authority.AcceptPrivacyKeys(context.Background(), "provider-a", "session-a", []relayblind.PrivacyKeyRecord{record}, now); err != nil {
				t.Fatal(err)
			}
			if err := privacyVerifyPosture(t, h.authority, identityPrivate, seKey, seRaw, h.privacyKey.KeyRecordDigest, now); err != nil {
				t.Fatal(err)
			}
		}
	}
	if cfg.relayKey {
		h.relayPrivate, err = ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		h.relayKey, err = relayblind.NewSignedKeyRecord(h.relayPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, relayblind.MaxEncryptedRequestBytes, now.Add(-time.Minute), now.Add(time.Hour))
		if err != nil {
			t.Fatal(err)
		}
		relayAuthority, err := relayblind.NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8)
		if err != nil {
			t.Fatal(err)
		}
		if err := relayAuthority.AcceptProviderKeys(context.Background(), "provider-a", "session-a", []relayblind.KeyRecord{h.relayKey}, now); err != nil {
			t.Fatal(err)
		}
	}
	registry := pool.NewRegistry(nil)
	h.provider = pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", ModelID: "model-a", MaxContextTokens: 4096,
		MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, State: pool.StateReady, AuthState: pool.AuthBearerValidated,
		InferencePath: pool.InferencePathWSTunneled,
	}
	if cfg.quota > 0 {
		h.provider.Tier = pool.TierProvisional
	}
	if _, registered := registry.RegisterAt(&h.provider, nil, now); !registered {
		t.Fatal("provider registration rejected")
	}
	if cfg.relay == nil {
		cfg.relay = func(context.Context, pool.Provider, string, []byte, bool, providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
			return nil, context.Canceled
		}
	}
	relayCfg := config.Default().RelayBlind
	relayCfg.Enabled = true
	relayCfg.ReservationTTLSeconds = cfg.ttl
	relayCfg.MaxClockSkewSeconds = 60
	relayCfg.MaxActiveReservations = 100
	relayCfg.MetadataRequestsPerMinute = 100
	opts := []Option{WithGatewayServiceToken("gateway-token"), WithRequireGatewayContext(true), WithRelayBlind(relayCfg, store, cfg.relay)}
	if h.authority != nil {
		opts = append(opts, WithPrivacyAuthority(h.authority))
	}
	if cfg.quota > 0 {
		h.admission = providerws.NewAdmissionManager(config.AdmissionConfig{ProvisionalQuotaPerHour: cfg.quota}, clock.Now)
		opts = append(opts, WithAdmission(h.admission, 0.3))
	}
	if cfg.requestLog {
		logStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = logStore.Close() })
		h.requestLog = logStore
		opts = append(opts, WithRequestLog(h.requestLog))
	}
	h.server = NewServer(registry, zerolog.Nop(), now, opts...)
	h.server.now = clock.Now
	return h
}

func privacyTestKey(t *testing.T, identity ed25519.PrivateKey, now time.Time) (*ecdh.PrivateKey, relayblind.KeyRecord) {
	t.Helper()
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(private.PublicKey().Bytes(), identity, []string{"model-a"}, relayblind.MaxEncryptedRequestBytes, now, now.Add(time.Duration(relayblind.MaxPrivacyKeyLifetimeSeconds)*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	return private, record
}

func privacyTestRecord(t *testing.T, identity ed25519.PrivateKey, key relayblind.KeyRecord) relayblind.PrivacyKeyRecord {
	t.Helper()
	attestation := relayblind.PrivacyKeyAttestation{
		Version: relayblind.PrivacyKeyAttestationVersion, KeyRecordDigest: key.KeyRecordDigest,
		PrivacyClass: relayblind.PrivacyClassV1, Assurance: relayblind.PrivacyAssurance, BinaryVersion: privacyTestBinary,
		CodeCDHash: privacyTestCDHash, NotBeforeUnix: key.NotBeforeUnix, ExpiresAtUnix: key.ExpiresAtUnix,
	}
	framed, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	return relayblind.PrivacyKeyRecord{KeyRecord: key, Attestation: attestation, Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(identity, framed))}
}

func privacyVerifyPosture(t *testing.T, authority *relayblind.PrivacyAuthority, identity ed25519.PrivateKey, se *ecdsa.PrivateKey, seRaw []byte, digest string, now time.Time) error {
	t.Helper()
	nonce, issued, err := authority.BeginChallenge("provider-a", "session-a", now)
	if err != nil {
		return err
	}
	statement := relayblind.PostureStatement{
		Version: relayblind.PrivacyPostureVersion, PrivacyClass: relayblind.PrivacyClassV1, ProviderID: "provider-a",
		AssignedSession: "session-a", Nonce: nonce, Sequence: 1, IssuedAtUnix: issued, BinaryVersion: privacyTestBinary,
		CodeCDHash: privacyTestCDHash, TeamID: privacyTestTeamID, SigningIdentifier: privacyTestSigning,
		HardenedRuntime: true, LibraryValidation: true, GetTaskAllow: false, CSDebugged: false, PTraced: false,
		PTDenyAttachApplied: true, CoreDumpsDisabled: true, SIPEnabled: true, RuntimeSource: relayblind.PrivacyRuntimeSource,
		DiagnosticEnvClear: true, KVDiskTierDisabled: true, SEKeyBackend: relayblind.PrivacySEBackendFile,
		PrivacyKeyRecordDigests: []string{digest},
	}
	rawStatement, err := json.Marshal(statement)
	if err != nil {
		return err
	}
	framing, err := statement.Framing()
	if err != nil {
		return err
	}
	sum := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, se, sum[:])
	if err != nil {
		return err
	}
	wire, err := json.Marshal(struct {
		Type              string          `json:"type"`
		Version           int             `json:"version"`
		Statement         json.RawMessage `json:"statement"`
		SESignature       string          `json:"se_signature"`
		IdentitySignature string          `json:"identity_signature"`
	}{
		Type: "privacy_posture_response", Version: 1, Statement: rawStatement,
		SESignature:       base64.RawURLEncoding.EncodeToString(seSig),
		IdentitySignature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(identity, framing)),
	})
	if err != nil {
		return err
	}
	return authority.VerifyPosture(context.Background(), "provider-a", "session-a", nonce, wire, seRaw, now)
}

func (h *privacyHarness) privacyRequest(t *testing.T, method, path string, body []byte, authorization string, mutate func(*http.Request)) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, bytes.NewReader(body))
	request.RemoteAddr = "127.0.0.1:43210"
	request.Header.Set("Authorization", "Bearer gateway-token")
	request.Header.Set("X-MacProvider-Account", "account-a")
	request.Header.Set("X-MacProvider-Wallet-Session", "wallet-a")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(privacyClassHeader, relayblind.PrivacyClassV1)
	if authorization != "" {
		request.Header.Set(relayBlindExecutionAuthorizationHeader, authorization)
	}
	if mutate != nil {
		mutate(request)
	}
	response := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(response, request)
	return response
}

func (h *privacyHarness) reserve(t *testing.T, privacy bool) relayblind.ReservationResponse {
	t.Helper()
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	var response *httptest.ResponseRecorder
	if privacy {
		response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
	} else {
		response = relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	}
	if response.Code != http.StatusOK {
		t.Fatalf("reservation status=%d body=%s", response.Code, response.Body.String())
	}
	parsed, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil {
		t.Fatalf("parse reservation: %v body=%s", err, response.Body.String())
	}
	return parsed
}

func (h *privacyHarness) seal(t *testing.T, reservation relayblind.ReservationResponse, requestID string, private *ecdh.PrivateKey) []byte {
	t.Helper()
	envelope, err := reservation.NewEnvelope(requestID, h.clock.Now(), bytes.Repeat([]byte{0x33}, 32))
	if err != nil {
		t.Fatal(err)
	}
	buyer, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err = envelope.Encrypt([]byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`), private.PublicKey().Bytes(), buyer.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func privacySuccessRelay(body string, gotClass *atomic.Value, dispatches *atomic.Int32) RelayBlindRelayFunc {
	return func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		if dispatches != nil {
			dispatches.Add(1)
		}
		if gotClass != nil {
			gotClass.Store(relayContext.PrivacyClass)
		}
		chunks := make(chan providerws.InferenceResponseChunk)
		done := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		validations := make(chan providerws.RelayBlindValidation, 1)
		validated := relayBlindValidationForContext(relayContext, "validated", 11)
		terminal := relayBlindValidationForContext(relayContext, "terminal", 11)
		validations <- validated
		go func() {
			chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: body}
			close(chunks)
			done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete", Usage: json.RawMessage(`{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}`), RelayBlindValidation: &terminal}
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs, Validations: validations}, nil
	}
}

func privacyCountingRelay(dispatches *atomic.Int32) RelayBlindRelayFunc {
	return func(context.Context, pool.Provider, string, []byte, bool, providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		dispatches.Add(1)
		return nil, context.Canceled
	}
}

func TestPrivacyReservationRequiresEligibleProvider(t *testing.T) {
	body := `{"id":"privacy-body","choices":[{"message":{"content":"CANARY-PRIVACY-BODY"}}]}`
	var gotClass atomic.Value
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacySuccessRelay(body, &gotClass, &dispatches)})
	reservation := h.reserve(t, true)
	if reservation.Version != relayblind.PrivacyReservationVersion || reservation.KeyRecordDigest != h.privacyKey.KeyRecordDigest || reservation.PrivacyClass != relayblind.PrivacyClassV1 || reservation.PrivacyAssurance != relayblind.PrivacyAssurance || reservation.PrivacyKeyAttestation == nil || reservation.PrivacyKeyAttestationSignature == "" || reservation.PrivacyPostureVerifiedAtUnix <= 0 {
		t.Fatalf("reservation=%+v", reservation)
	}
	if reservation.KeyRecordDigest == h.relayKey.KeyRecordDigest {
		t.Fatal("privacy reservation selected the relay-blind key")
	}
	plain := h.reserve(t, false)
	if plain.Version != relayblind.ReservationVersion || plain.KeyRecordDigest != h.relayKey.KeyRecordDigest || plain.PrivacyClass != "" {
		t.Fatalf("relay reservation=%+v", plain)
	}
	raw := h.seal(t, reservation, "privacy-request-a", h.privacyPrivate)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	if response.Code != http.StatusOK || response.Body.String() != body || response.Header().Get(privacyClassHeader) != relayblind.PrivacyClassV1 {
		t.Fatalf("chat status=%d header=%q body=%s", response.Code, response.Header().Get(privacyClassHeader), response.Body.String())
	}
	if gotClass.Load() != relayblind.PrivacyClassV1 || dispatches.Load() != 1 {
		t.Fatalf("class=%v dispatches=%d", gotClass.Load(), dispatches.Load())
	}
	caps := httptest.NewRequest(http.MethodGet, "/v1/relay-blind/capabilities", nil)
	caps.RemoteAddr = "127.0.0.1:43210"
	caps.Header.Set("Authorization", "Bearer gateway-token")
	recorded := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(recorded, caps)
	if recorded.Code != http.StatusOK || !strings.Contains(recorded.Body.String(), `"privacy_class":{"enabled":true,"models":{"model-a":{"capable_provider_count":1,"incapable_provider_count":0}}}`) {
		t.Fatalf("capabilities status=%d body=%s", recorded.Code, recorded.Body.String())
	}
}

func TestPrivacyReservationNeverSelectsRelayBlindKey(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyEnabled: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_unavailable"`) || strings.Contains(response.Body.String(), h.relayKey.KeyRecordDigest) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

func TestRelayBlindReservationNeverSelectsPrivacyKey(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: false, relay: privacyCountingRelay(&dispatches)})
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response := relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"relay_blind_provider_unsupported"`) || strings.Contains(response.Body.String(), h.privacyKey.KeyRecordDigest) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

func TestPrivacyHeaderStrippedAtConsumeIsDowngrade(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
	reservation := h.reserve(t, true)
	raw := h.seal(t, reservation, "privacy-strip", h.privacyPrivate)
	response := relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/consume", raw, "")
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) {
		t.Fatalf("strip status=%d body=%s", response.Code, response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	retry := relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/consume", raw, "")
	if retry.Code == http.StatusOK {
		t.Fatalf("retry consumed a rejected privacy reservation: %s", retry.Body.String())
	}
	t.Run("invalid", func(t *testing.T) {
		next := h.reserve(t, true)
		again := h.seal(t, next, "privacy-invalid", h.privacyPrivate)
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", again, "", func(r *http.Request) {
			r.Header.Set(privacyClassHeader, "not-the-class")
		})
		if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) {
			t.Fatalf("invalid status=%d body=%s", response.Code, response.Body.String())
		}
		row, err := h.store.LookupReservation(context.Background(), next.ProviderBinding)
		if err != nil || row.State != relayblind.ReservationStateRejected {
			t.Fatalf("row=%#v err=%v", row, err)
		}
	})
	t.Run("repeated", func(t *testing.T) {
		next := h.reserve(t, true)
		again := h.seal(t, next, "privacy-repeated", h.privacyPrivate)
		response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", again, "", func(r *http.Request) {
			r.Header.Add(privacyClassHeader, relayblind.PrivacyClassV1)
		})
		if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) {
			t.Fatalf("repeated status=%d body=%s", response.Code, response.Body.String())
		}
	})
}

func TestPrivacyHeaderInjectedOnRelayBlindIsDowngrade(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
	reservation := h.reserve(t, false)
	raw := h.seal(t, reservation, "relay-inject", h.relayPrivate)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected || row.PrivacyClass {
		t.Fatalf("row=%#v err=%v", row, err)
	}
}

func TestPlaintextChatWithPrivacyHeaderRejected(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	h.server.relayBlind.cfg.Enabled = false
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"PROMPT-CANARY-7f3a"}]}`)
	response := h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", body, "", nil)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) || strings.Contains(response.Body.String(), "PROMPT-CANARY-7f3a") {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

func TestStalePostureBetweenConsumeAndDispatchRejectsAndRefunds(t *testing.T) {
	var dispatches atomic.Int32
	// Posture max-age is 150s and relay-blind envelope skew is 60s. A single
	// jump past max-age also fails envelope validation, so the chat never
	// reaches the posture gate. Seal while the posture is still inside
	// max-age, then advance only to the skew boundary.
	const (
		postureMaxAge = 150 * time.Second
		envelopeSkew  = 60 * time.Second
	)
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, quota: 1, maxAge: int(postureMaxAge / time.Second), ttl: 600, relay: privacyCountingRelay(&dispatches)})
	h.clock.Advance(postureMaxAge - envelopeSkew + time.Second)
	if _, ok := h.authority.Eligible(h.provider.ProviderID, h.provider.AssignedID, h.privacyKey.KeyRecordDigest, h.clock.Now()); !ok {
		t.Fatal("posture expired before the envelope was sealed")
	}
	reservation := h.reserve(t, true)
	raw := h.seal(t, reservation, "privacy-stale", h.privacyPrivate)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(envelopeSkew)
	if _, ok := h.authority.Eligible(h.provider.ProviderID, h.provider.AssignedID, h.privacyKey.KeyRecordDigest, h.clock.Now()); ok {
		t.Fatal("posture still eligible at dispatch")
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) || !strings.Contains(response.Body.String(), `"retryable":true`) {
		t.Fatalf("chat status=%d body=%s", response.Code, response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
	if !h.admission.CheckQuota(h.provider) || !h.admission.TryReserveRequest(h.provider) {
		t.Fatal("quota was not refunded")
	}
	if h.admission.TryReserveRequest(h.provider) {
		t.Fatal("refund left more than the hourly quota")
	}
	h.admission.RefundRequest(h.provider)
}

func TestQuarantinedProviderUnavailable(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	if err := h.store.Quarantine(context.Background(), "provider-a", "review", h.clock.Now(), time.Hour); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_unavailable"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}
}

func TestKillSwitchBlocksAllPhases(t *testing.T) {
	var dispatches atomic.Int32
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, relay: privacyCountingRelay(&dispatches)})
	first := h.reserve(t, true)
	firstRaw := h.seal(t, first, "privacy-kill-a", h.privacyPrivate)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", firstRaw, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("consume A status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	second := h.reserve(t, true)
	if err := h.store.SetPrivacyDisabled(context.Background(), true, "maintenance", h.clock.Now()); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_disabled"`) {
		t.Fatalf("reservation status=%d body=%s", response.Code, response.Body.String())
	}
	secondRaw := h.seal(t, second, "privacy-kill-b", h.privacyPrivate)
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", secondRaw, "", nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_disabled"`) {
		t.Fatalf("consume B status=%d body=%s", response.Code, response.Body.String())
	}
	secondRow, err := h.store.LookupReservation(context.Background(), second.ProviderBinding)
	if err != nil || secondRow.State != relayblind.ReservationStateRejected {
		t.Fatalf("B row=%#v err=%v", secondRow, err)
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", firstRaw, consume.ExecutionAuthorization, nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_disabled"`) {
		t.Fatalf("chat A status=%d body=%s", response.Code, response.Body.String())
	}
	firstRow, err := h.store.LookupReservation(context.Background(), first.ProviderBinding)
	if err != nil || firstRow.State != relayblind.ReservationStateRejected {
		t.Fatalf("A row=%#v err=%v", firstRow, err)
	}
	plain := relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	if plain.Code != http.StatusOK || !strings.Contains(plain.Body.String(), `"version":"relay-blind-reservation-v1"`) {
		t.Fatalf("relay reservation status=%d body=%s", plain.Code, plain.Body.String())
	}
	if dispatches.Load() != 0 {
		t.Fatalf("dispatches=%d", dispatches.Load())
	}

	t.Run("store error", func(t *testing.T) {
		closed := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
		if err := closed.store.Close(); err != nil {
			t.Fatal(err)
		}
		response := closed.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
		if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_disabled"`) {
			t.Fatalf("closed store status=%d body=%s", response.Code, response.Body.String())
		}
	})
}

func TestPrivacyPoolIntentRejected(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", func(r *http.Request) {
		r.Header.Set("X-MacProvider-Pool", "pool-a")
	})
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	count, err := h.store.CountReservations(context.Background())
	if err != nil || count != 0 {
		t.Fatalf("reservations=%d err=%v", count, err)
	}
	pooled := h.serverRequest(t, raw, func(r *http.Request) { r.Header.Set("X-MacProvider-Pool", "pool-a") })
	if pooled.Code != http.StatusBadRequest || !strings.Contains(pooled.Body.String(), `"code":"relay_blind_downgrade_rejected"`) {
		t.Fatalf("pool without privacy status=%d body=%s", pooled.Code, pooled.Body.String())
	}
}

func (h *privacyHarness) serverRequest(t *testing.T, body []byte, mutate func(*http.Request)) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/v1/relay-blind/route-reservations", bytes.NewReader(body))
	request.RemoteAddr = "127.0.0.1:43210"
	request.Header.Set("Authorization", "Bearer gateway-token")
	request.Header.Set("X-MacProvider-Account", "account-a")
	request.Header.Set("X-MacProvider-Wallet-Session", "wallet-a")
	request.Header.Set("Content-Type", "application/json")
	if mutate != nil {
		mutate(request)
	}
	response := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(response, request)
	return response
}

func TestPrivacyUnknownPostdispatchBillsInputOnly(t *testing.T) {
	canary := `{"choices":[{"message":{"content":"` + strings.Repeat("CANARY", 80) + `"}}]}`
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, requestLog: true, relay: func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
		chunks := make(chan providerws.InferenceResponseChunk)
		done := make(chan providerws.InferenceResponseEnd, 1)
		errs := make(chan error, 1)
		validations := make(chan providerws.RelayBlindValidation, 1)
		validations <- relayBlindValidationForContext(relayContext, "validated", 11)
		go func() {
			chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: canary}
			close(chunks)
			done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete"}
		}()
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs, Validations: validations}, nil
	}})
	reservation := h.reserve(t, true)
	raw := h.seal(t, reservation, "privacy-unknown", h.privacyPrivate)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("consume status=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	if response.Code != http.StatusInternalServerError || strings.Contains(response.Body.String(), "CANARY") {
		t.Fatalf("chat status=%d body=%s", response.Code, response.Body.String())
	}
	row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding)
	if err != nil || row.State != relayblind.ReservationStateUnknownPostdispatch {
		t.Fatalf("row=%#v err=%v", row, err)
	}
	var prompt, completion, estimate sql.NullInt64
	if err := h.requestLog.DB().QueryRow(`SELECT prompt_tokens, completion_tokens, estimated_completion_tokens FROM request_log`).Scan(&prompt, &completion, &estimate); err != nil {
		t.Fatal(err)
	}
	if !prompt.Valid || prompt.Int64 != 11 || completion.Valid || !estimate.Valid || estimate.Int64 != 0 {
		t.Fatalf("prompt=%v completion=%v estimate=%v", prompt, completion, estimate)
	}
}

func TestPrivacyErrorInventoryComplete(t *testing.T) {
	raw, err := os.ReadFile("../../../test/fixtures/relay-blind/privacy-error-inventory.json")
	if err != nil {
		t.Fatal(err)
	}
	var inventory struct {
		Version string `json:"version"`
		Codes   []struct {
			Code        string `json:"code"`
			HTTPStatus  int    `json:"http_status"`
			Retryable   bool   `json:"retryable"`
			RetryAction string `json:"retry_action"`
		} `json:"codes"`
	}
	if err := json.Unmarshal(raw, &inventory); err != nil {
		t.Fatal(err)
	}
	if inventory.Version != "privacy-error-inventory-v1" || len(inventory.Codes) != 5 {
		t.Fatalf("inventory=%+v", inventory)
	}
	seen := map[string]struct{}{}
	for _, item := range inventory.Codes {
		shape, ok := relayBlindErrors[item.Code]
		if !ok || shape.Status != item.HTTPStatus || shape.Retryable != item.Retryable || shape.RetryAction != item.RetryAction {
			t.Fatalf("code %s shape=%+v fixture=%+v", item.Code, shape, item)
		}
		seen[item.Code] = struct{}{}
	}
	for code := range relayBlindErrors {
		if strings.HasPrefix(code, "privacy_class_") {
			if _, ok := seen[code]; !ok {
				t.Fatalf("coordinator code %s missing from fixture", code)
			}
		}
	}
	now := time.Unix(1_800_100_110, 0).UTC()
	server, _, _, closeStore := relayBlindTestServer(t, now, nil)
	defer closeStore()
	request := httptest.NewRequest(http.MethodGet, "/v1/relay-blind/capabilities", nil)
	request.RemoteAddr = "127.0.0.1:43210"
	request.Header.Set("Authorization", "Bearer gateway-token")
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"privacy_class":{"enabled":false,"models":{"model-a":{"capable_provider_count":0,"incapable_provider_count":1}}}`) {
		t.Fatalf("disabled capabilities status=%d body=%s", response.Code, response.Body.String())
	}
}
