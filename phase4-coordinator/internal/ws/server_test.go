package ws_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/audit"
	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/rs/zerolog"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

type recordedIdlePrewarmEvent struct {
	providerID string
	event      string
	reason     string
}

type recordingIdlePrewarm struct {
	mu      sync.Mutex
	records []recordedIdlePrewarmEvent
}

func (r *recordingIdlePrewarm) RecordIdlePrewarmEvent(_ context.Context, providerID, event, reason string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.records = append(r.records, recordedIdlePrewarmEvent{
		providerID: providerID,
		event:      event,
		reason:     reason,
	})
	return nil
}

func (r *recordingIdlePrewarm) snapshot() []recordedIdlePrewarmEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]recordedIdlePrewarmEvent, len(r.records))
	copy(out, r.records)
	return out
}

func TestProviderHelloReceivesAck(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	assertHelloAck(t, conn)
}

func TestIdlePrewarmEventRecordsProviderBoundTelemetry(t *testing.T) {
	recorder := &recordingIdlePrewarm{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithIdlePrewarmRecorder(recorder),
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)
	if err := wsutil.WriteClientText(conn, []byte(`{"type":"idle_prewarm_event","event":"idle_prewarm_skipped","reason":"not_idle_yet"}`)); err != nil {
		t.Fatalf("write idle prewarm event: %v", err)
	}

	eventually(t, func() bool {
		records := recorder.snapshot()
		return len(records) == 1 &&
			records[0].providerID == "m4-anon" &&
			records[0].event == "idle_prewarm_skipped" &&
			records[0].reason == "not_idle_yet"
	})
}

func TestIdlePrewarmEventIncrementsAcceptedEventMetric(t *testing.T) {
	recorder := &recordingIdlePrewarm{}
	reg := prometheus.NewRegistry()
	metrics := statsmetrics.New(reg)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithIdlePrewarmRecorder(recorder),
		providerws.WithIdlePrewarmMetrics(metrics),
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)
	if err := wsutil.WriteClientText(conn, []byte(`{"type":"idle_prewarm_event","event":"idle_prewarm_skipped","reason":"not_idle_yet"}`)); err != nil {
		t.Fatalf("write idle prewarm event: %v", err)
	}

	eventually(t, func() bool {
		return idlePrewarmMetricValue(t, reg, "idle_prewarm_skipped", "not_idle_yet") == 1
	})
}

func TestIdlePrewarmEventWritesAreRateLimited(t *testing.T) {
	recorder := &recordingIdlePrewarm{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithIdlePrewarmRecorder(recorder),
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)
	for i := 0; i < 12; i++ {
		if err := wsutil.WriteClientText(conn, []byte(`{"type":"idle_prewarm_event","event":"idle_prewarm_fired"}`)); err != nil {
			t.Fatalf("write idle prewarm event %d: %v", i, err)
		}
	}
	eventually(t, func() bool {
		return len(recorder.snapshot()) == 10
	})
	time.Sleep(100 * time.Millisecond)
	if got := len(recorder.snapshot()); got != 10 {
		t.Fatalf("recorded idle prewarm events = %d, want burst cap 10", got)
	}
}

func TestIdlePrewarmRateLimitSurvivesImmediateReconnect(t *testing.T) {
	recorder := &recordingIdlePrewarm{}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithIdlePrewarmRecorder(recorder),
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial first connection: %v", err)
	}
	assertHelloAck(t, conn)
	for i := 0; i < 10; i++ {
		if err := wsutil.WriteClientText(conn, []byte(`{"type":"idle_prewarm_event","event":"idle_prewarm_fired"}`)); err != nil {
			t.Fatalf("write idle prewarm event %d: %v", i, err)
		}
	}
	eventually(t, func() bool {
		return len(recorder.snapshot()) == 10
	})
	_ = conn.Close()

	conn2, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial second connection: %v", err)
	}
	defer conn2.Close()
	assertHelloAck(t, conn2)
	if err := wsutil.WriteClientText(conn2, []byte(`{"type":"idle_prewarm_event","event":"idle_prewarm_fired"}`)); err != nil {
		t.Fatalf("write idle prewarm event after reconnect: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	if got := len(recorder.snapshot()); got != 10 {
		t.Fatalf("recorded idle prewarm events after reconnect = %d, want original burst cap 10", got)
	}
}

func idlePrewarmMetricValue(t *testing.T, reg *prometheus.Registry, event, reason string) float64 {
	t.Helper()
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather metrics: %v", err)
	}
	for _, family := range families {
		if family.GetName() != "stats_idle_prewarm_event_total" {
			continue
		}
		for _, metric := range family.GetMetric() {
			var gotEvent, gotReason string
			for _, label := range metric.GetLabel() {
				switch label.GetName() {
				case "event":
					gotEvent = label.GetValue()
				case "reason":
					gotReason = label.GetValue()
				}
			}
			if gotEvent == event && gotReason == reason {
				return metric.GetCounter().GetValue()
			}
		}
	}
	return 0
}

func TestProviderAuthV2RegistersEncryptedSession(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	providerPrivate, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["model_load_time_ms"] = int64(1234)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	if challenge.AssignedID == "" || challenge.AuthAttemptID == "" || challenge.SelectedAEADSuite != tier2.PillarBAEADA256GCM || challenge.KeyID == "" {
		t.Fatalf("bad auth_challenge: %+v", challenge)
	}
	coordinatorPublic, coordinatorPublicRaw, err := tier2.ParseX25519PublicKey(challenge.CoordinatorECDHPublicKey)
	if err != nil {
		t.Fatalf("coordinator public key: %v", err)
	}
	shared, err := providerPrivate.ECDH(coordinatorPublic)
	if err != nil {
		t.Fatalf("provider ECDH: %v", err)
	}
	derived, err := tier2.DerivePillarBKeysFromSharedSecret(shared, "m4-anon", challenge.AssignedID, providerPublicRaw, coordinatorPublicRaw, challenge.SelectedAEADSuite)
	if err != nil {
		t.Fatalf("derive provider-side keys: %v", err)
	}
	if derived.KeyID != challenge.KeyID {
		t.Fatalf("challenge key_id=%q want derived %q", challenge.KeyID, derived.KeyID)
	}

	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		t.Fatalf("auth_response = %+v", response)
	}
	if response.Tier2Session == nil || !response.Tier2Session.EncryptedLeg.Enabled || response.Tier2Session.EncryptedLeg.KID != challenge.KeyID || response.Tier2Session.Attestation.Status != string(pool.AttestationStatusNotRequired) {
		t.Fatalf("tier2 auth_response session = %+v", response.Tier2Session)
	}
	if !response.Tier2Session.EncryptedLeg.ResponseChunkPlaintextEnvelope {
		t.Fatal("auth_response did not select response_chunk_plaintext_envelope")
	}
	if !response.Tier2Session.EncryptedLeg.InBandAEADRekeyV1 {
		t.Fatal("auth_response did not select in_band_aead_rekey_v1")
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok &&
			provider.EncryptedLeg &&
			provider.AttestationStatus == pool.AttestationStatusNotRequired &&
			provider.ModelLoadTimeMs == 1234 &&
			provider.Tier2Session != nil &&
			provider.Tier2Session.ResponseChunkPlaintextEnvelope &&
			provider.Tier2Session.InBandAEADRekeyV1 &&
			provider.Tier2Session.KeyID == challenge.KeyID &&
			len(provider.Tier2Session.C2PKey) == 32 &&
			provider.InferencePath == pool.InferencePathWSTunneled
	})
}

func TestBuyerHTTPMaintainsOneProviderContinuityAcrossRequestThresholdRekey(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
		cfg.Tier2.EncryptedLegRekeyAfterRequests = 1
		cfg.Tier2.EncryptedLegRekeyAfterSeconds = 0
	})
	defer h.HTTP.Close()
	conn, assignedID, epoch := authenticateBuyerRekeyProvider(t, h)
	defer conn.Close()

	rekeyStarted := make(chan struct{})
	allowCommit := make(chan struct{})
	providerDone := make(chan error, 1)
	go func() {
		if err := serveBuyerInferenceOverEpoch(conn, "m4-anon", assignedID, epoch, 0); err != nil {
			providerDone <- err
			return
		}
		next, err := completeBuyerTestRekey(conn, "m4-anon", assignedID, rekeyStarted, allowCommit)
		if err != nil {
			providerDone <- err
			return
		}
		providerDone <- serveBuyerInferenceOverEpoch(conn, "m4-anon", assignedID, next, 1)
	}()

	relayEntered := make(chan struct{}, 2)
	buyerServer := buyer.NewServer(
		h.Registry,
		zerolog.Nop(),
		time.Now(),
		buyer.WithRelay(signalingBuyerRekeyRelay(h.Provider.DispatchInference, relayEntered), 3*time.Second),
	)
	first := postBuyerRekeyChat(buyerServer)
	assertBuyerRekeySuccess(t, first, assignedID)
	<-relayEntered
	select {
	case <-rekeyStarted:
	case err := <-providerDone:
		t.Fatalf("provider before request-threshold rekey: %v", err)
	case <-time.After(time.Second):
		t.Fatal("request-threshold rekey did not start")
	}
	assertProviderRemainsReadyDuringRekey(t, h.Registry, assignedID)

	secondResult := make(chan *httptest.ResponseRecorder, 1)
	go func() { secondResult <- postBuyerRekeyChat(buyerServer) }()
	select {
	case <-relayEntered:
	case <-time.After(time.Second):
		t.Fatal("second buyer request did not enter DispatchInference")
	}
	select {
	case early := <-secondResult:
		t.Fatalf("buyer request returned before rekey commit: status=%d body=%s", early.Code, early.Body.String())
	case <-time.After(50 * time.Millisecond):
	}
	close(allowCommit)
	select {
	case second := <-secondResult:
		assertBuyerRekeySuccess(t, second, assignedID)
	case <-time.After(2 * time.Second):
		t.Fatal("buyer request did not resume after request-threshold rekey")
	}
	if err := <-providerDone; err != nil {
		t.Fatal(err)
	}
	assertProviderRemainsReadyDuringRekey(t, h.Registry, assignedID)
	assertProviderEpochChanged(t, h.Registry, assignedID, epoch.KeyID)
}

func TestBuyerHTTPMaintainsOneProviderContinuityAcrossAgeThresholdRekey(t *testing.T) {
	clock := newLockedTime(time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC))
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithNow(clock.Now)}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
		cfg.Tier2.EncryptedLegRekeyAfterRequests = 0
		cfg.Tier2.EncryptedLegRekeyAfterSeconds = 1
	})
	defer h.HTTP.Close()
	conn, assignedID, epoch := authenticateBuyerRekeyProvider(t, h)
	defer conn.Close()
	clock.Set(clock.Now().Add(2 * time.Second))

	rekeyStarted := make(chan struct{})
	allowCommit := make(chan struct{})
	providerDone := make(chan error, 1)
	go func() {
		next, err := completeBuyerTestRekey(conn, "m4-anon", assignedID, rekeyStarted, allowCommit)
		if err != nil {
			providerDone <- err
			return
		}
		providerDone <- serveBuyerInferenceOverEpoch(conn, "m4-anon", assignedID, next, 1)
	}()

	relayEntered := make(chan struct{}, 1)
	buyerServer := buyer.NewServer(
		h.Registry,
		zerolog.Nop(),
		clock.Now(),
		buyer.WithRelay(signalingBuyerRekeyRelay(h.Provider.DispatchInference, relayEntered), 3*time.Second),
	)
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() { result <- postBuyerRekeyChat(buyerServer) }()
	select {
	case <-rekeyStarted:
	case err := <-providerDone:
		t.Fatalf("provider before age-threshold rekey: %v", err)
	case <-time.After(time.Second):
		t.Fatal("age-threshold rekey did not start")
	}
	select {
	case <-relayEntered:
	case <-time.After(time.Second):
		t.Fatal("age-threshold buyer request did not enter DispatchInference")
	}
	assertProviderRemainsReadyDuringRekey(t, h.Registry, assignedID)
	select {
	case early := <-result:
		t.Fatalf("buyer request returned before age rekey commit: status=%d body=%s", early.Code, early.Body.String())
	case <-time.After(50 * time.Millisecond):
	}
	close(allowCommit)
	select {
	case response := <-result:
		assertBuyerRekeySuccess(t, response, assignedID)
	case <-time.After(2 * time.Second):
		t.Fatal("buyer request did not resume after age-threshold rekey")
	}
	if err := <-providerDone; err != nil {
		t.Fatal(err)
	}
	assertProviderRemainsReadyDuringRekey(t, h.Registry, assignedID)
	assertProviderEpochChanged(t, h.Registry, assignedID, epoch.KeyID)
}

func TestProviderAuthV2AcceptsMockAttestationToken(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
		cfg.Tier2.RequireAttestation = true
		cfg.Tier2.AttestationRoots = []string{"mock-root"}
		cfg.Tier2.AllowMockAttestation = true
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	providerPublic := base64.RawURLEncoding.EncodeToString(providerPublicRaw)
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("m4-anon", providerPublic))); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	challengeBytes, err := base64.RawURLEncoding.DecodeString(challenge.AttestationChallenge)
	if err != nil {
		t.Fatalf("challenge decode: %v", err)
	}
	token := tier2.BuildMockAttestationToken(challenge.AttestationFormats[0], challengeBytes, "m4-anon", providerPublic, time.Now().Add(-time.Minute), time.Now().Add(time.Minute))

	writeAuthProof(t, conn, challenge, "m4-anon", token)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.Tier2Session == nil || response.Tier2Session.Attestation.Status != string(pool.AttestationStatusAttested) {
		t.Fatalf("auth_response = %+v", response)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok && provider.EncryptedLeg && provider.AttestationStatus == pool.AttestationStatusAttested
	})
}

func TestProviderAuthV2IdentitySignatureRequiredWithoutPolicyExemption(t *testing.T) {
	pub, _, providerID := testIdentityKey(t)
	store := &fakeIdentitySignatureStore{identityPubkey: pub, identityOK: true}
	h := newIdentitySignatureHarness(t, providerID, store)
	defer h.HTTP.Close()
	conn, challenge, _ := writeIdentityInitial(t, h.HTTP.URL, providerID)
	defer conn.Close()

	writeAuthProof(t, conn, challenge, providerID, nil)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("auth_response = %+v", response)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseIdentitySignatureRequired || reason != "identity_signature_required" {
		t.Fatalf("close = %d %q", code, reason)
	}
}

func TestProviderAuthV2IdentitySignatureRejectDoesNotConsumeProvisionalAdmission(t *testing.T) {
	pub, _, providerID := testIdentityKey(t)
	store := &fakeIdentitySignatureStore{identityPubkey: pub, identityOK: true}
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithIdentitySignatureStore(store)}, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Admission.ProvisionalAdmissionRatePerHour = 1
	})
	defer h.HTTP.Close()
	conn, challenge, _ := writeIdentityInitial(t, h.HTTP.URL, providerID)
	defer conn.Close()

	writeAuthProof(t, conn, challenge, providerID, nil)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("auth_response = %+v", response)
	}
	if records := h.Provider.Admission().Records(nil); len(records) != 0 {
		t.Fatalf("provisional records after rejected proof = %+v, want none", records)
	}
}

func TestProviderAuthV2IdentitySignaturePolicyExemptionAcceptsBearerOnly(t *testing.T) {
	_, _, providerID := testIdentityKey(t)
	exemptUntil := time.Now().Add(time.Hour)
	store := &fakeIdentitySignatureStore{policyOK: true, exemptUntil: &exemptUntil, grantedBy: "migration"}
	h := newIdentitySignatureHarness(t, providerID, store, func(cfg *config.Config) {
		cfg.AutotuneFeeds.EnforceProviderAdmission = false
		cfg.AutotuneFeeds.ProviderAdmissionBridgeDeadline = time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	})
	defer h.HTTP.Close()
	conn, challenge, _ := writeIdentityInitial(t, h.HTTP.URL, providerID)
	defer conn.Close()

	writeAuthProof(t, conn, challenge, providerID, nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		t.Fatalf("auth_response = %+v", response)
	}
	if response.IdentityAdmissionMode != "exemption" {
		t.Fatalf("identity_admission_mode=%q, want exemption", response.IdentityAdmissionMode)
	}
}

func TestProviderAuthV2StrictAdmissionRefusesActivePolicyExemption(t *testing.T) {
	_, _, providerID := testIdentityKey(t)
	exemptUntil := time.Now().Add(time.Hour)
	store := &fakeIdentitySignatureStore{policyOK: true, exemptUntil: &exemptUntil, grantedBy: "migration"}
	h := newIdentitySignatureHarness(t, providerID, store)
	defer h.HTTP.Close()
	conn, challenge, _ := writeIdentityInitial(t, h.HTTP.URL, providerID)
	defer conn.Close()

	writeAuthProof(t, conn, challenge, providerID, nil)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("strict auth_response = %+v", response)
	}
}

func TestProviderAuthV2IdentitySignatureValidAppTrackProofAccepts(t *testing.T) {
	pub, priv, providerID := testIdentityKey(t)
	store := &fakeIdentitySignatureStore{identityPubkey: pub, identityOK: true}
	h := newIdentitySignatureHarness(t, providerID, store)
	defer h.HTTP.Close()
	conn, challenge, initial := writeIdentityInitial(t, h.HTTP.URL, providerID)
	defer conn.Close()

	fields := signedIdentityProofFields(t, priv, providerID, challenge.AuthAttemptID, initial)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil, fields)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		t.Fatalf("auth_response = %+v", response)
	}
	if response.IdentityAdmissionMode != "signature" || response.IdentityGeneration != 1 {
		t.Fatalf("identity admission=(%q, %d), want signature generation 1", response.IdentityAdmissionMode, response.IdentityGeneration)
	}
}

func TestProviderAuthV2IdentitySignatureValidCLIReceiptProofAccepts(t *testing.T) {
	receiptPub, receiptPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("receipt key: %v", err)
	}
	providerID := "m4-anon"
	store := &fakeIdentitySignatureStore{}
	h := newIdentitySignatureHarness(t, providerID, store)
	defer h.HTTP.Close()
	h.Registry.Register(&pool.Provider{
		ProviderID:    providerID,
		AssignedID:    "existing-cli",
		ReceiptPubkey: receiptPub,
		ReceiptPubkeyPrev: &pool.ReceiptPubkeyPrevious{
			Pubkey:    bytes.Repeat([]byte{0x77}, 32),
			RotatedAt: time.Now().Add(-time.Hour),
			ExpiresAt: time.Now().Add(time.Hour),
		},
	}, nil)
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPub)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	fields := signedIdentityProofFields(t, receiptPriv, providerID, challenge.AuthAttemptID, initial)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil, fields)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		t.Fatalf("auth_response = %+v", response)
	}
}

func TestProviderAuthV2IdentitySignatureRejectsSelfDeclaredCLIReceiptProof(t *testing.T) {
	storedReceiptPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("stored receipt key: %v", err)
	}
	attackerPub, attackerPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("attacker receipt key: %v", err)
	}
	providerID := "m4-anon"
	store := &fakeIdentitySignatureStore{}
	h := newIdentitySignatureHarness(t, providerID, store)
	defer h.HTTP.Close()
	h.Registry.Register(&pool.Provider{
		ProviderID:    providerID,
		AssignedID:    "existing-cli",
		ReceiptPubkey: storedReceiptPub,
	}, nil)
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(attackerPub)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	fields := signedIdentityProofFields(t, attackerPriv, providerID, challenge.AuthAttemptID, initial)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil, fields)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("auth_response = %+v", response)
	}
}

func TestProviderAuthV2IdentitySignatureRejectsCLIWithoutStoredReceiptKey(t *testing.T) {
	receiptPub, receiptPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("receipt key: %v", err)
	}
	providerID := "m4-anon"
	store := &fakeIdentitySignatureStore{}
	h := newIdentitySignatureHarness(t, providerID, store)
	defer h.HTTP.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPub)
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	fields := signedIdentityProofFields(t, receiptPriv, providerID, challenge.AuthAttemptID, initial)
	writeAuthProofWithFields(t, conn, challenge, providerID, nil, fields)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "identity_signature_required" {
		t.Fatalf("auth_response = %+v", response)
	}
}

func TestProviderAuthV2L1NoRetentionEntry(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw)))); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	if got := authAttemptCount(t, h.Provider); got != 0 {
		t.Fatalf("auth attempt count after initial = %d, want 0", got)
	}
	challenge := readAuthChallenge(t, conn)
	if got := authAttemptCount(t, h.Provider); got != 0 {
		t.Fatalf("auth attempt count after challenge = %d, want 0", got)
	}
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response = %+v", response)
	}
	if got := authAttemptCount(t, h.Provider); got != 0 {
		t.Fatalf("auth attempt count after proof = %d, want 0", got)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok &&
			len(provider.SupportedModels) == 1 &&
			provider.SupportedModels[0] == "mlx-community/Qwen2.5-7B-Instruct-4bit" &&
			!provider.PublishesSupportedModels
	})
}

func TestProviderAuthV2Spec010RetentionEntryCreatedAndReleased(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	models := []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["supported_models"] = models
	initial["publishes_supported_models"] = true
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	if got := authAttemptCount(t, h.Provider); got != 1 {
		t.Fatalf("auth attempt count after challenge = %d, want 1", got)
	}
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response = %+v", response)
	}
	eventually(t, func() bool {
		return authAttemptCount(t, h.Provider) == 0
	})
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok &&
			reflect.DeepEqual(provider.SupportedModels, models) &&
			provider.PublishesSupportedModels
	})
}

func TestProviderAuthV2RetentionReleasedOnDisconnectBeforeProof(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	initial["publishes_supported_models"] = true
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	_ = readAuthChallenge(t, conn)
	if got := authAttemptCount(t, h.Provider); got != 1 {
		t.Fatalf("auth attempt count after challenge = %d, want 1", got)
	}
	_ = conn.Close()
	eventually(t, func() bool {
		return authAttemptCount(t, h.Provider) == 0
	})
}

func TestProviderAuthV2Retention1024BoundRejection(t *testing.T) {
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithAuthAttemptRetentionBound(1)}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	firstConn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial first: %v", err)
	}
	_, firstProviderPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair first: %v", err)
	}
	firstInitial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(firstProviderPublicRaw))
	firstInitial["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	if err := wsutil.WriteClientText(firstConn, mustJSON(firstInitial)); err != nil {
		t.Fatalf("write first auth initial: %v", err)
	}
	_ = readAuthChallenge(t, firstConn)
	if got := authAttemptCount(t, h.Provider); got != 1 {
		t.Fatalf("auth attempt count = %d, want 1", got)
	}

	secondConn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial second: %v", err)
	}
	defer secondConn.Close()
	_, secondProviderPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair second: %v", err)
	}
	secondInitial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(secondProviderPublicRaw))
	secondInitial["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	if err := wsutil.WriteClientText(secondConn, mustJSON(secondInitial)); err != nil {
		t.Fatalf("write second auth initial: %v", err)
	}
	response := readAuthResponse(t, secondConn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "too_many_auth_attempts" {
		t.Fatalf("auth_response = %+v", response)
	}
	frame, err := gobwas.ReadFrame(secondConn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.ClosePoolFull || reason != "too_many_auth_attempts" {
		t.Fatalf("close = (%d, %q)", code, reason)
	}
	if got := authAttemptCount(t, h.Provider); got != 1 {
		t.Fatalf("auth attempt count after reject = %d, want 1", got)
	}

	_ = firstConn.Close()
	eventually(t, func() bool {
		return authAttemptCount(t, h.Provider) == 0
	})

	thirdConn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial third: %v", err)
	}
	defer thirdConn.Close()
	_, thirdProviderPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair third: %v", err)
	}
	thirdInitial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(thirdProviderPublicRaw))
	thirdInitial["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	if err := wsutil.WriteClientText(thirdConn, mustJSON(thirdInitial)); err != nil {
		t.Fatalf("write third auth initial: %v", err)
	}
	_ = readAuthChallenge(t, thirdConn)
	if got := authAttemptCount(t, h.Provider); got != 1 {
		t.Fatalf("auth attempt count after third challenge = %d, want 1", got)
	}
}

func TestProviderAuthV2InitialOverlongEntryRejectedWithLockedSubstring(t *testing.T) {
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["supported_models"] = []string{strings.Repeat("x", 257)}

	assertInitialCatalogRejectedWithLockedSubstring(t, initial, "supported_models entry exceeds 256 bytes")
}

func TestProviderAuthV2InitialOverlongCatalogRejectedWithLockedSubstring(t *testing.T) {
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	models := make([]string, 65)
	for i := range models {
		models[i] = "model-" + string(rune('A'+i))
	}
	models[0] = "mlx-community/Qwen2.5-7B-Instruct-4bit"
	initial["supported_models"] = models

	assertInitialCatalogRejectedWithLockedSubstring(t, initial, "supported_models exceeds 64 entries")
}

func TestProviderAuthV2InitialDuplicateCatalogRejectedWithLockedSubstring(t *testing.T) {
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["model_id"] = "Model-A"
	initial["supported_models"] = []string{"Model-A", "MODEL-A"}

	assertInitialCatalogRejectedWithLockedSubstring(t, initial, "supported_models contains duplicate entries")
}

func TestProviderAuthV2InitialMissingModelIDRejectedOnTheWire(t *testing.T) {
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["model_id"] = "X"
	initial["supported_models"] = []string{"Y"}

	assertInitialCatalogRejectedWithLockedSubstring(t, initial, "model_id not in supported_models")
}

// TestProviderAuthV2InitialSupportedModelsWrongTypeRejectedOnTheWire
// closes the pre-merge audit CRITICAL [code:1.1]: initial-stage
// JSON-type drift on supported_models MUST surface the SPEC-010 v1.5
// R-3.1.9 step-1 LOCKED substring "supported_models must be array of
// strings" via auth_response + WS close per AC-K.15. Pre-R3 the parser
// returned bare badField="supported_models" which was excluded from
// isSpec010CatalogBadField's exact-match allowlist and fell through to
// the generic envelope close path, violating the AC.
func TestProviderAuthV2InitialSupportedModelsWrongTypeRejectedOnTheWire(t *testing.T) {
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["supported_models"] = "not-an-array"

	assertInitialCatalogRejectedWithLockedSubstring(t, initial, "supported_models must be array of strings")
}

func TestProviderAuthV2InitialEmptyCatalogRejectedOnTheWire(t *testing.T) {
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["supported_models"] = []string{}

	assertInitialCatalogRejectedWithLockedSubstring(t, initial, "supported_models cannot be empty")
}

func TestProviderFirstAuthMissingVersionLogsBoundedMessageType(t *testing.T) {
	var logBuffer lockedBuffer
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, nil, zerolog.New(&logBuffer), func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	delete(initial, "version")

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, initial)
	if code != providerws.CloseUnrecognizedAuthMessage {
		t.Fatalf("close code = %d, want %d", code, providerws.CloseUnrecognizedAuthMessage)
	}
	if reason != "unrecognized auth message" {
		t.Fatalf("close reason = %q, want %q", reason, "unrecognized auth message")
	}

	logText := logBuffer.String()
	if !strings.Contains(logText, `"bad_field":"missing version"`) ||
		!strings.Contains(logText, `"message_type":"auth_request"`) {
		t.Fatalf("missing bounded first-auth rejection log fields: %s", logText)
	}
}

// TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath
// regression-pins the [r2:1.1] R2V closure: a first-frame
// auth_request with stage:"proof" whose supported_models field is a
// malformed JSON type (string instead of array) returns
// badField="supported_models" from parseAuthProof. The original R2
// gate prefix-matched on "supported_models" and misclassified this
// envelope-level failure as an AC-K.15 catalog rejection
// (bad_request + 4001 + locked substring). After the R3 exact-match
// switch in isSpec010CatalogBadField, this frame correctly takes the
// CloseUnrecognizedAuthMessage (4000) generic envelope path.
func TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()
	code, reason := sendHelloExpectClose(t, ts.URL, map[string]any{
		"type":             "auth_request",
		"version":          2,
		"stage":            "proof",
		"auth_attempt_id":  "auth-fake-attempt-id",
		"provider_id":      "m4-anon",
		"supported_models": "not-an-array",
	})
	if code != providerws.CloseUnrecognizedAuthMessage {
		t.Fatalf("close code = %d, want %d (envelope path, not AC-K.15 path)",
			code, providerws.CloseUnrecognizedAuthMessage)
	}
	if reason != "unrecognized auth message" {
		t.Fatalf("close reason = %q, want %q", reason, "unrecognized auth message")
	}
}

func TestProviderAuthV2ProofMismatchRejectedWithLockedSubstring(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["model_id"] = "model-a"
	initial["supported_models"] = []string{"model-a"}
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProofWithFields(t, conn, challenge, "m4-anon", nil, map[string]any{
		"supported_models": []string{"model-b"},
	})
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "bad_request" {
		t.Fatalf("auth_response = %+v", response)
	}
	if !strings.Contains(response.Error.Message, "supported_models mismatch between auth_request stages") {
		t.Fatalf("error message = %q", response.Error.Message)
	}
}

func TestProviderAuthV2ProofAbsentSpec010Accepted(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["supported_models"] = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
	initial["publishes_supported_models"] = true
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response = %+v", response)
	}
}

func TestProviderAuthV2InitialReceiptPublicKeyPublishesAfterStateUpdate(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	receiptPubkey := bytes.Repeat([]byte{0x42}, 32)
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPubkey)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response = %+v", response)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok && provider.ReceiptPubkey == nil && bytes.Equal(provider.PendingReceiptPubkey, receiptPubkey) && !provider.RoutingEligible()
	})
	writeStateUpdate(t, conn, "ready")
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok && bytes.Equal(provider.ReceiptPubkey, receiptPubkey) && provider.PendingReceiptPubkey == nil && provider.RoutingEligible()
	})
}

func TestPoolzReceiptPubkeyForV16Provider(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	receiptPubkey := bytes.Repeat([]byte{0x57}, 32)
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPubkey)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" {
		t.Fatalf("auth_response = %+v", response)
	}

	var got poolzResponse
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ProviderID == "m4-anon"
	})
	if got.Pool[0].ReceiptPubkey != nil {
		t.Fatalf("receipt_pubkey = %q before state_update, want nil", *got.Pool[0].ReceiptPubkey)
	}
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v, want nil", got.Pool[0].ReceiptPubkeyPrev)
	}

	writeStateUpdate(t, conn, "ready")
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil
	})
	want := base64.StdEncoding.EncodeToString(receiptPubkey)
	if *got.Pool[0].ReceiptPubkey != want {
		t.Fatalf("receipt_pubkey = %q, want %q", *got.Pool[0].ReceiptPubkey, want)
	}
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v, want nil", got.Pool[0].ReceiptPubkeyPrev)
	}
}

func TestProviderAuthV2RejectsMissingRequiredAttestation(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
		cfg.Tier2.RequireAttestation = true
		cfg.Tier2.AttestationRoots = []string{"mock-root"}
		cfg.Tier2.AllowMockAttestation = true
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw)))); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != string(pool.AttestationStatusFailed) {
		t.Fatalf("rejection auth_response = %+v", response)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseTier2AttestationFailed || reason != "tier2_attestation_failed" {
		t.Fatalf("close = (%d, %q)", code, reason)
	}
	if _, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID); ok {
		t.Fatal("rejected v2 provider was registered")
	}
}

func TestProviderAuthV2RejectsNoCommonAEADSuite(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	initial["tier2_capabilities"] = map[string]any{
		"encrypted_leg": true,
		"attestation":   true,
		"aead_suites":   []string{"CHACHA20-POLY1305"},
	}
	code, reason := sendHelloExpectClose(t, ts.URL, initial)
	if code != providerws.CloseInvalidHello || reason != "no_common_aead_suite" {
		t.Fatalf("close = (%d, %q)", code, reason)
	}
}

func TestProviderHelloRejectsWarmupProviderMissingRequiredEncryptedLeg(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 1
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = ""
		cfg.Tier2.RequireEncryptedLeg = true
	})
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("m4-anon"))
	if code != providerws.CloseTier2KeyExchangeFailed || reason != "tier2_encrypted_leg_required" {
		t.Fatalf("close = %d %q, want %d tier2_encrypted_leg_required", code, reason, providerws.CloseTier2KeyExchangeFailed)
	}
}

func TestProviderAuthFirstMessageDispatchRejectsUnknown(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()
	code, reason := sendHelloExpectClose(t, ts.URL, map[string]any{
		"type":    "capabilities",
		"version": 1,
	})
	if code != providerws.CloseUnrecognizedAuthMessage || reason != "unrecognized auth message" {
		t.Fatalf("close = (%d, %q)", code, reason)
	}
}

func TestProviderWebSocketDropsSilentPreAuthClientAfterHandshakeDeadline(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.WS.HandshakeTimeoutS = 1
	})
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	start := time.Now()
	frame, err := gobwas.ReadFrame(conn)
	if time.Since(start) > 2500*time.Millisecond {
		t.Fatal("silent pre-auth provider connection was not dropped by the handshake deadline")
	}
	if err == nil && frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close or closed connection", frame.Header.OpCode)
	}
}

func TestProviderWebSocketRejectsOversizeInitialFrame(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.WS.MaxFrameBytes = 32
	})
	defer ts.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, []byte(strings.Repeat("x", 64))); err != nil {
		t.Fatalf("write oversize frame: %v", err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, _ := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidHello {
		t.Fatalf("code = %d, want %d", code, providerws.CloseInvalidHello)
	}
}

// #1354 / SPEC-002 v1.6.0: the warm-up gate is now fail-open and observe-only.
// A fresh provider is admitted `ready` and immediately routable; the probe still
// runs (for a fitness verdict) but never withholds routing. This test replaces
// the old blocking-gate test (TestWarmupGateHoldsProviderUntilTokenProducingProbe).
func TestWarmupProbeAdmitsProviderReadyAndObservesOnly(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 2
		cfg.Pool.WarmupGateMaxTokens = 2
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	// Fail-open: the provider is routable the moment it is admitted, before the
	// probe is answered — it is NEVER parked in degraded by the warm-up gate.
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})

	// The observe-only probe is still dispatched over the WS.
	req := readInferenceRequest(t, conn)
	if !strings.HasPrefix(req.RequestID, "req-warmup-gate-"+assignedID+"-1") {
		t.Fatalf("request_id = %q, want warmup gate prefix for assigned_id %q", req.RequestID, assignedID)
	}
	if req.Stream {
		t.Fatal("warmup gate request stream = true, want false")
	}
	var body struct {
		Model     string `json:"model"`
		MaxTokens int    `json:"max_tokens"`
		Stream    bool   `json:"stream"`
	}
	if err := json.Unmarshal([]byte(req.Body), &body); err != nil {
		t.Fatalf("warmup body json: %v", err)
	}
	if body.Model != "mlx-community/Qwen2.5-7B-Instruct-4bit" {
		t.Fatalf("warmup model = %q", body.Model)
	}
	if body.MaxTokens != 2 {
		t.Fatalf("warmup max_tokens = %d, want 2", body.MaxTokens)
	}
	if body.Stream {
		t.Fatal("warmup body stream = true, want false")
	}

	// Answering the probe leaves the provider ready (it already was).
	writeWarmupCompletion(t, conn, req.RequestID, 1)
	consistently(t, 300*time.Millisecond, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
}

// #1354: a probe that times out with no token production must NOT mark the
// provider unavailable — fail-open leaves it routable (replaces the old
// TestWarmupGateTimeoutMarksProviderUnavailable).
func TestWarmupProbeTimeoutLeavesProviderRoutable(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 1
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)
	req := readInferenceRequest(t, conn)
	if req.RequestID == "" {
		t.Fatal("warmup request_id is empty")
	}

	// Never answer the probe. It exhausts and times out, but the provider stays
	// ready and routable throughout — it is never parked unavailable.
	eventuallyWithin(t, 4*time.Second, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
	hb := heartbeat()
	hb["status"] = "ready"
	hb["slots_free"] = 0
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write ready heartbeat after warmup timeout: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady && provider.SlotsFree == 0
	})
}

// #1354: a zero-token completion records a negative fitness verdict but must not
// change routing state (replaces TestWarmupGateRejectsZeroTokenCompletion).
func TestWarmupProbeZeroTokenLeavesProviderRoutable(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 2
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)
	// Provider is admitted ready before the probe is even answered.
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
	req := readInferenceRequest(t, conn)

	writeWarmupCompletion(t, conn, req.RequestID, 0)
	consistently(t, 300*time.Millisecond, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
}

// #1354: usage metadata without observed output records a negative verdict but
// must not change routing state (replaces
// TestWarmupGateRejectsUsageWithoutObservedOutput).
func TestWarmupProbeUsageWithoutOutputLeavesProviderRoutable(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 2
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
	req := readInferenceRequest(t, conn)

	if err := wsutil.WriteClientText(conn, mustJSON(providerws.InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  req.RequestID,
		Status:     "complete",
		ChunksSent: 0,
		Usage: json.RawMessage(mustJSON(map[string]any{
			"prompt_tokens":     4,
			"completion_tokens": 1,
			"total_tokens":      5,
		})),
	})); err != nil {
		t.Fatalf("write warmup end: %v", err)
	}
	consistently(t, 300*time.Millisecond, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
}

func TestWarmupGateUsesHTTPForHTTPForwardingProvider(t *testing.T) {
	requestSeen := make(chan struct{}, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("warmup request = %s %s, want POST /v1/chat/completions", r.Method, r.URL.Path)
		}
		var body struct {
			Model     string `json:"model"`
			MaxTokens int    `json:"max_tokens"`
			Stream    bool   `json:"stream"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("warmup body json: %v", err)
		}
		if body.Model != "mlx-community/Qwen2.5-7B-Instruct-4bit" || body.MaxTokens != 2 || body.Stream {
			t.Fatalf("warmup body = %#v", body)
		}
		select {
		case requestSeen <- struct{}{}:
		default:
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"warmup-http","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 2
		cfg.Pool.WarmupGateMaxTokens = 2
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = upstream.URL
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	select {
	case <-requestSeen:
	case <-time.After(2 * time.Second):
		t.Fatal("HTTP warmup request did not reach upstream")
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady && provider.InferencePath == pool.InferencePathHTTPForwarding
	})
}

// #1354 / SPEC-002 v1.6.0: the coordinator still MUST NOT follow HTTP-forwarding
// redirects during the warm-up probe (the security property is unchanged), but
// under fail-open the resulting negative verdict no longer parks the provider
// unavailable — it stays routable and a real buyer request would be governed by
// the circuit breaker. Replaces TestWarmupGateDoesNotFollowHTTPForwardingRedirects'
// unavailable assertion.
func TestWarmupProbeDoesNotFollowHTTPForwardingRedirectsAndStaysRoutable(t *testing.T) {
	var targetHits int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&targetHits, 1)
		_, _ = w.Write([]byte(`{"id":"redirected","choices":[{"message":{"content":"ok"}}],"usage":{"completion_tokens":1}}`))
	}))
	defer target.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/v1/chat/completions", http.StatusTemporaryRedirect)
	}))
	defer upstream.Close()

	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 2
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = upstream.URL
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	// The provider is admitted ready and stays ready across the probe window.
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
	consistently(t, 400*time.Millisecond, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
	// Security property preserved: the redirect target was never followed.
	if got := atomic.LoadInt32(&targetHits); got != 0 {
		t.Fatalf("redirect target hit %d times; coordinator must not follow provider redirects", got)
	}
}

// #1354 / SPEC-002 v1.6.0: under fail-open observe-only, heartbeat and
// state_update `ready` reports are NO LONGER clamped to degraded while the probe
// is in flight (that clamp was part of the blocking gate). Replaces
// TestWarmupGateSuppressesReadyProviderUpdates, which asserted the opposite.
func TestWarmupProbeDoesNotClampReadyProviderUpdates(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.WarmupGateEnabled = true
		cfg.Pool.WarmupGateTimeoutS = 2
		cfg.Pool.WarmupGateMaxTokens = 2
		cfg.Pool.DegradedMaxRetries = 1
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)
	req := readInferenceRequest(t, conn)

	// A ready heartbeat mid-probe is honored, not clamped to degraded.
	hb := heartbeat()
	hb["status"] = "ready"
	hb["slots_free"] = 0
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady && provider.SlotsFree == 0
	})

	// A ready state_update mid-probe is likewise honored.
	if err := wsutil.WriteClientText(conn, mustJSON(map[string]any{
		"type":   "state_update",
		"state":  "ready",
		"reason": "provider reports ready while the observe-only probe is in flight",
		"since":  "2026-05-30T00:00:00Z",
		"metrics_snapshot": map[string]any{
			"slots_free":  1,
			"slots_total": 1,
		},
	})); err != nil {
		t.Fatalf("write state_update: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady && provider.SlotsFree == 1
	})

	writeWarmupCompletion(t, conn, req.RequestID, 1)
	consistently(t, 300*time.Millisecond, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.State == pool.StateReady
	})
}

func TestProviderHelloAcceptsAuthorizationHeaderInStep2(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	dialer := gobwas.Dialer{
		Header: gobwas.HandshakeHeaderHTTP(http.Header{
			"Authorization": []string{"Bearer test-token"},
		}),
	}
	conn, _, _, err := dialer.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	assertHelloAck(t, conn)
}

func TestProviderTokenAuthFlow(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	record, token, err := store.IssueToken(context.Background(), "m4-anon", "M4 test provider")
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	h := newProviderHarnessWithTokenValidator(t, store)
	defer h.HTTP.Close()

	conn, _, _, err := bearerDialer(token).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial with issued token: %v", err)
	}
	assertHelloAck(t, conn)
	_ = conn.Close()
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens after valid auth: %v", err)
	}
	if len(records) != 1 || !records[0].LastUsedAt.Valid {
		t.Fatalf("records after valid auth = %#v, want last_used_at set", records)
	}

	if _, err := store.RevokeToken(context.Background(), record.TokenPrefix); err != nil {
		t.Fatalf("revoke token: %v", err)
	}
	revoked, br, _, err := bearerDialer(token).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial with revoked token: %v", err)
	}
	defer revoked.Close()
	// The server rejects an invalid token immediately after the WebSocket
	// handshake, so its close frame can race the client's handshake read: when
	// it arrives fast enough, gobwas slurps it into the bufio.Reader that Dial
	// returns rather than leaving it on the raw conn. Read from that reader
	// (which falls through to the conn once its buffer drains) instead of the
	// bare conn, otherwise ReadFrame misses the buffered frame and blocks until
	// the socket closes — surfacing as a flaky "unexpected EOF".
	var src io.Reader = revoked
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read invalid token close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
}

func TestProviderTokenMustMatchHelloProviderID(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	_, token, err := store.IssueToken(context.Background(), "other-provider", "Other provider")
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	h := newProviderHarnessWithTokenValidator(t, store)
	defer h.HTTP.Close()

	conn, br, _, err := bearerDialer(token).Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial with mismatched token: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	src := io.Reader(conn)
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read mismatched token close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
	// SPEC-003 v0.8.4 (fix-pass-5) — `last_used_at` is stamped
	// atomically by ValidateAndMarkTokenUsed at WS upgrade time, BEFORE
	// the hello parse + provider_id mismatch check. The pre-fix-pass-5
	// behavior was "stamp only on successful admission" but that left
	// a TOCTOU window where a concurrent self-heal could revoke the
	// row between ValidateToken and MarkTokenUsed. Under the atomic
	// op, the token holder is credited at the moment they present a
	// valid bearer; a subsequent provider_id mismatch closes the
	// connection but the credit stands (it correctly records that
	// the bearer was presented and validated by this coordinator).
	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens after mismatch: %v", err)
	}
	if len(records) != 1 || !records[0].LastUsedAt.Valid {
		t.Fatalf("records after mismatched auth = %#v, want last_used_at set by atomic ValidateAndMarkTokenUsed (fix-pass-5 F)", records)
	}
}

func TestPinnedProviderRequiresTokenWhenValidatorConfigured(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, store)
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("m4-anon"))
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
}

func TestProviderTokensRequiredFailsClosedWithoutValidator(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("m4-anon"))
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
}

// SPEC-003 v0.8 FR-C9.1 / FR-C9.5 — replaces the pre-v0.8 test
// `TestProvisionalProviderRequiresTokenWhenValidatorConfigured` which
// asserted the old contract "validator wired = tokenless rejected for
// everyone". v0.8 separates issuance from enforcement, so the gate
// here is `cfg.Auth.RequireProviderTokens`, not `s.tokens != nil`.
//
// When require_provider_tokens=true (the post-flag-flip posture), a
// tokenless connect is rejected at the WS upgrade with CloseInvalidToken
// regardless of pinned vs provisional. This locks in the strict gate
// the operator wants once the migration is complete.
func TestProvisionalProviderRejectedWhenRequireProviderTokensTrue(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	h := newProviderHarnessWithTokenValidator(t, store, func(cfg *config.Config) {
		cfg.Providers = nil
		cfg.Auth.RequireProviderTokens = true
	})
	defer h.HTTP.Close()

	code, reason := sendHelloExpectClose(t, h.HTTP.URL, validHello("m4-provisional"))
	if code != providerws.CloseInvalidToken || reason != "invalid_token" {
		t.Fatalf("close = %d %q, want %d invalid_token", code, reason, providerws.CloseInvalidToken)
	}
}

func TestHeartbeatUpdatesPoolz(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	hb := heartbeat()
	hb["slots_free"] = 0
	hb["status"] = "busy"
	hb["model_hash"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	hb["model_hash_algorithm"] = modelidentity.SnapshotManifestV1
	hb["safety_telemetry"] = map[string]any{
		"schema_version": 2, "provider_id": "m4-anon", "model_id": hb["model_id"], "model_loaded": true,
		"runtime_state": "busy", "hardware_tier": "16GB", "requests_in_flight": 1, "requests_queued": 0,
		"memory_rss_mb": 2048, "memory_capacity_mb": 16384, "memory_pressure": "normal",
		"thermal_state": "nominal", "thermally_throttled": false, "restart_count": 1, "uptime_s": 120,
		"coordinator_connected": true, "coordinator_session_id": assignedID,
		"cpu_utilization_pct": 12.5, "gpu_utilization_pct": 18.0, "gpu_utilization_scope": "host", "power_source": "external",
		"binary_version": "1.8.33", "compatibility_set_id": "set-a",
		"model_hash":           "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"model_hash_algorithm": modelidentity.SnapshotManifestV1,
		"observation_id":       "observation-a",
		"observed_at":          "2000-01-01T00:00:00Z", "valid_for_ms": 90000,
	}
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	var got struct {
		Pool []struct {
			ProviderID      string                        `json:"provider_id"`
			State           string                        `json:"state"`
			SlotsFree       int                           `json:"slots_free"`
			SlotsTotal      int                           `json:"slots_total"`
			Endpoint        string                        `json:"endpoint_url"`
			SafetyTelemetry *pool.ProviderSafetyTelemetry `json:"safety_telemetry"`
		} `json:"pool"`
		Summary struct {
			TotalProviders int `json:"total_providers"`
			Ready          int `json:"ready"`
			FreeSlots      int `json:"free_slots"`
		} `json:"summary"`
	}
	eventually(t, func() bool {
		req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer test-operator-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("poolz: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			t.Fatalf("poolz status=%d body=%s", resp.StatusCode, body)
		}
		got = struct {
			Pool []struct {
				ProviderID      string                        `json:"provider_id"`
				State           string                        `json:"state"`
				SlotsFree       int                           `json:"slots_free"`
				SlotsTotal      int                           `json:"slots_total"`
				Endpoint        string                        `json:"endpoint_url"`
				SafetyTelemetry *pool.ProviderSafetyTelemetry `json:"safety_telemetry"`
			} `json:"pool"`
			Summary struct {
				TotalProviders int `json:"total_providers"`
				Ready          int `json:"ready"`
				FreeSlots      int `json:"free_slots"`
			} `json:"summary"`
		}{}
		if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
			t.Fatalf("poolz json: %v", err)
		}
		return len(got.Pool) == 1 && got.Pool[0].State == "busy" && got.Pool[0].SlotsFree == 0
	})
	if got.Pool[0].ProviderID != "m4-anon" {
		t.Fatalf("provider_id = %q", got.Pool[0].ProviderID)
	}
	if got.Pool[0].Endpoint != "https://m4.malibu.tech" {
		t.Fatalf("endpoint = %q", got.Pool[0].Endpoint)
	}
	if telemetry := got.Pool[0].SafetyTelemetry; telemetry == nil || telemetry.ObservationID != "observation-a" || telemetry.ObservedAt == "2000-01-01T00:00:00Z" {
		t.Fatalf("safety_telemetry = %+v, want coordinator-stamped observation", telemetry)
	}
	if got.Summary.TotalProviders != 1 || got.Summary.Ready != 0 || got.Summary.FreeSlots != 0 {
		t.Fatalf("summary = %+v", got.Summary)
	}
}

func TestHeartbeatRejectsMismatchedSafetyTelemetrySession(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	hb := heartbeat()
	hb["slots_free"] = 0
	hb["status"] = "busy"
	hb["model_hash"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	hb["model_hash_algorithm"] = modelidentity.SnapshotManifestV1
	hb["safety_telemetry"] = map[string]any{
		"schema_version": 2, "provider_id": "m4-anon", "model_id": hb["model_id"], "model_loaded": true,
		"runtime_state": "busy", "hardware_tier": "16GB", "requests_in_flight": 1, "requests_queued": 0,
		"memory_rss_mb": 2048, "memory_capacity_mb": 16384, "memory_pressure": "normal",
		"thermal_state": "nominal", "thermally_throttled": false, "restart_count": 1, "uptime_s": 120,
		"coordinator_connected": true, "coordinator_session_id": assignedID + "-wrong",
		"cpu_utilization_pct": 12.5, "gpu_utilization_pct": nil, "gpu_utilization_scope": "host", "power_source": "external",
		"binary_version": "1.8.33", "compatibility_set_id": "set-a",
		"model_hash":           "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"model_hash_algorithm": modelidentity.SnapshotManifestV1,
		"observation_id":       "observation-a", "observed_at": "2000-01-01T00:00:00Z", "valid_for_ms": 90000,
	}
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	eventually(t, func() bool {
		req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer test-operator-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("poolz: %v", err)
		}
		defer resp.Body.Close()
		var got struct {
			Pool []struct {
				State           string                        `json:"state"`
				SlotsFree       int                           `json:"slots_free"`
				SafetyTelemetry *pool.ProviderSafetyTelemetry `json:"safety_telemetry"`
			} `json:"pool"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
			t.Fatalf("poolz json: %v", err)
		}
		return len(got.Pool) == 1 && got.Pool[0].State == "ready" && got.Pool[0].SlotsFree == 1 && got.Pool[0].SafetyTelemetry == nil
	})
}

func TestPoolzDefaultOmitsTier2HashFieldsAfterWSAdmission(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	eventually(t, func() bool {
		req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer test-operator-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("poolz: %v", err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatalf("read poolz: %v", err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("poolz status=%d body=%s", resp.StatusCode, body)
		}
		if !bytes.Contains(body, []byte(`"provider_id":"m4-anon"`)) {
			return false
		}
		if bytes.Contains(body, []byte("hash_status")) || bytes.Contains(body, []byte("model_hash")) {
			t.Fatalf("default /poolz included Tier-2 hash fields: %s", body)
		}
		return true
	})
}

func TestHeartbeatLegacyPathPreservesV134Behavior(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2Provider(t, h)
	defer conn.Close()

	if err := wsutil.WriteClientText(conn, mustJSON(heartbeat())); err != nil {
		t.Fatalf("write legacy heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && !provider.LastLoadingState && provider.LoadingStartedAt.IsZero()
	})

	hb := heartbeat()
	hb["model_id"] = "mlx-community/Llama-3.1-8B-Instruct-4bit"
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write legacy model-change heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok &&
			provider.ModelID == "mlx-community/Llama-3.1-8B-Instruct-4bit" &&
			provider.ModelHash == "" &&
			provider.HashStatus == pool.HashStatusUncatalogued
	})
}

func TestHeartbeatSpecDecodeOptInFieldsPreserveStatePath(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2Provider(t, h)
	defer conn.Close()

	hb := heartbeat()
	hb["spec_decode_enabled"] = true
	hb["spec_decode_draft_model_id"] = "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
	hb["spec_decode_num_draft_tokens"] = 3
	hb["spec_decode_drafted_tokens_since_last"] = 30
	hb["spec_decode_accepted_tokens_since_last"] = 18
	hb["spec_decode_acceptance_rate"] = 0.6
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write spec decode heartbeat: %v", err)
	}

	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok &&
			provider.AssignedID == assignedID &&
			provider.InferencePath == pool.InferencePathWSTunneled &&
			provider.State == pool.StateReady &&
			provider.ModelID == hb["model_id"] &&
			provider.SlotsFree == 1 &&
			provider.SlotsTotal == 1 &&
			provider.ThroughputTPSEstimate == 19.8 &&
			!provider.LastLoadingState &&
			provider.LoadingStartedAt.IsZero()
	})
}

func TestHeartbeatSPEC011PathInvokesVerifier(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2Provider(t, h)
	defer conn.Close()
	hash := "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"

	hb := heartbeat()
	hb["model_hash"] = hash
	hb["loading"] = true
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write SPEC-011 heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok &&
			provider.ModelHash == hash &&
			provider.HashStatus == pool.HashStatusUncatalogued &&
			provider.LastLoadingState
	})
}

func TestHeartbeatUnknownModelHashAlgorithmFencesSession(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2Provider(t, h)
	defer conn.Close()

	hb := heartbeat()
	hb["model_hash"] = strings.Repeat("a", 64)
	hb["model_hash_algorithm"] = "sha256"
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write invalid identity heartbeat: %v", err)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidHello || reason != "invalid_model_hash_identity" {
		t.Fatalf("close = (%d, %q)", code, reason)
	}
	provider, ok := h.Registry.Resolve("m4-anon", assignedID)
	if ok && provider.HashStatus != pool.HashStatusInvalid {
		t.Fatalf("connected provider HashStatus=%q, want invalid", provider.HashStatus)
	}
}

func TestHeartbeatSwapCompletionFiresInjectedEmitter(t *testing.T) {
	var mu sync.Mutex
	var events []pool.SwapEvent
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithRegistryOptions(pool.WithSwapEmitter(func(event pool.SwapEvent) {
			mu.Lock()
			defer mu.Unlock()
			events = append(events, event)
		})),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2Provider(t, h)
	defer conn.Close()
	fromHash := "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
	toHash := "cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12ab12"

	hb := heartbeat()
	hb["model_hash"] = fromHash
	hb["loading"] = true
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write loading heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.LastLoadingState
	})

	hb = heartbeat()
	hb["model_id"] = "mlx-community/Llama-3.1-8B-Instruct-4bit"
	hb["model_hash"] = toHash
	hb["loading"] = false
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write completed heartbeat: %v", err)
	}
	eventually(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(events) == 1
	})
	mu.Lock()
	event := events[0]
	mu.Unlock()
	if event.ProviderID != "m4-anon" ||
		event.AssignedID != assignedID ||
		event.FromModelID != "mlx-community/Qwen2.5-7B-Instruct-4bit" ||
		event.FromModelHash != fromHash ||
		event.ToModelID != "mlx-community/Llama-3.1-8B-Instruct-4bit" ||
		event.ToModelHash != toHash ||
		event.HashVerificationResult != pool.HashStatusUncatalogued ||
		event.LoadingStartedAt.IsZero() ||
		event.CompletedAt.IsZero() {
		t.Fatalf("event = %+v", event)
	}
}

func TestHeartbeatSwapEmitterWritesAuditLogRow(t *testing.T) {
	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open audit store: %v", err)
	}
	defer auditStore.Close()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithRegistryOptions(pool.WithSwapEmitter(func(event pool.SwapEvent) {
			if err := auditStore.EmitSwap(context.Background(), event); err != nil {
				t.Errorf("emit swap: %v", err)
			}
		})),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2Provider(t, h)
	defer conn.Close()
	fromHash := "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12"
	toHash := "cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12ab12"

	hb := heartbeat()
	hb["model_hash"] = fromHash
	hb["loading"] = true
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write loading heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", assignedID)
		return ok && provider.LastLoadingState
	})

	hb = heartbeat()
	hb["model_id"] = "mlx-community/Llama-3.1-8B-Instruct-4bit"
	hb["model_hash"] = toHash
	hb["loading"] = false
	if err := wsutil.WriteClientText(conn, mustJSON(hb)); err != nil {
		t.Fatalf("write completed heartbeat: %v", err)
	}

	eventually(t, func() bool {
		var count int
		err := auditStore.DB().QueryRowContext(context.Background(), `
SELECT COUNT(*) FROM audit_log
WHERE event_type = 'operator_model_swap'`).Scan(&count)
		return err == nil && count == 1
	})
	var eventType, providerID, payloadJSON string
	if err := auditStore.DB().QueryRowContext(context.Background(), `
SELECT event_type, provider_id, payload_json
FROM audit_log`).Scan(&eventType, &providerID, &payloadJSON); err != nil {
		t.Fatalf("read audit row: %v", err)
	}
	if eventType != "operator_model_swap" || providerID != "m4-anon" {
		t.Fatalf("audit row event_type=%q provider_id=%q", eventType, providerID)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		t.Fatalf("payload json: %v", err)
	}
	if payload["event"] != "operator_model_swap" ||
		payload["provider_assigned_id"] != assignedID ||
		payload["from_model_id"] != "mlx-community/Qwen2.5-7B-Instruct-4bit" ||
		payload["from_model_hash"] != fromHash ||
		payload["to_model_id"] != "mlx-community/Llama-3.1-8B-Instruct-4bit" ||
		payload["to_model_hash"] != toHash ||
		payload["hash_verification_result"] != string(pool.HashStatusUncatalogued) {
		t.Fatalf("payload = %#v", payload)
	}
	loadingWindowMs, ok := payload["loading_window_ms"].(float64)
	if !ok {
		t.Fatalf("loading_window_ms type=%T payload=%#v", payload["loading_window_ms"], payload)
	}
	// SPEC-002 v1.3.5 §7.10.2 R-7.10.6 — loading_window_ms is the
	// wall-clock duration from prior LoadingStartedAt to the
	// completion heartbeat. Phase 2C stamps both on coordinator clock;
	// a positive value confirms the prior+completion heartbeats
	// actually flowed through ApplyHeartbeat. A zero would silently
	// pass the prior type-only assertion even if the loading-state
	// pipeline regressed.
	if loadingWindowMs <= 0 {
		t.Fatalf("loading_window_ms=%v, want > 0 (positive wall-clock duration)", loadingWindowMs)
	}
	if _, ok := payload["drain_inflight_count_estimate"]; ok {
		t.Fatalf("drain_inflight_count_estimate must be omitted: %#v", payload)
	}
}

func TestPoolzShapeUnchangedForL1Provider(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	eventually(t, func() bool {
		req, err := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer test-operator-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("poolz: %v", err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatalf("read poolz: %v", err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("poolz status=%d body=%s", resp.StatusCode, body)
		}

		var got struct {
			Pool []map[string]any `json:"pool"`
		}
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("poolz json: %v", err)
		}
		if len(got.Pool) == 0 || got.Pool[0]["provider_id"] != "m4-anon" {
			return false
		}
		if got.Pool[0]["canary_fail_count"] != float64(0) {
			t.Fatalf("canary_fail_count = %#v, want 0 in /poolz provider: %s", got.Pool[0]["canary_fail_count"], body)
		}
		for _, key := range []string{
			"supported_models",
			"publishes_supported_models",
			"last_loading_state",
			"loading_started_at",
			"canary_last_checked_at",
			"canary_last_failed_at",
		} {
			if _, ok := got.Pool[0][key]; ok {
				t.Fatalf("L-1 /poolz provider unexpectedly included %q: %s", key, body)
			}
		}
		return true
	})
}

func TestPoolzReceiptPubkeyNullForPreV16Provider(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	var body []byte
	var got poolzResponse
	eventually(t, func() bool {
		body, got = fetchPoolzRaw(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].ProviderID == "m4-anon"
	})
	if got.Pool[0].ReceiptPubkey != nil {
		t.Fatalf("receipt_pubkey = %q, want nil", *got.Pool[0].ReceiptPubkey)
	}
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v, want nil", got.Pool[0].ReceiptPubkeyPrev)
	}
	if !bytes.Contains(body, []byte(`"receipt_pubkey":null`)) {
		t.Fatalf("poolz omitted explicit receipt_pubkey null: %s", body)
	}
	if !bytes.Contains(body, []byte(`"receipt_pubkey_prev":null`)) {
		t.Fatalf("poolz omitted explicit receipt_pubkey_prev null: %s", body)
	}
}

func TestPoolzReceiptPubkeyPrevShape(t *testing.T) {
	h := newProviderHarness(t)
	defer h.HTTP.Close()

	current := bytes.Repeat([]byte{0x11}, 32)
	previous := bytes.Repeat([]byte{0x22}, 32)
	rotatedAt := time.Now().UTC()
	expiresAt := rotatedAt.Add(pool.ReceiptRotationGrace)
	_, registered := h.Registry.RegisterAt(&pool.Provider{
		ProviderID:      "m4-anon",
		AssignedID:      "assigned-receipt-prev",
		State:           pool.StateReady,
		ModelID:         "mlx-community/Qwen2.5-7B-Instruct-4bit",
		SlotsFree:       1,
		SlotsTotal:      1,
		EndpointURL:     "https://m4.malibu.tech",
		ConnectedAt:     rotatedAt,
		LastHeartbeatAt: rotatedAt,
		LastActivityAt:  rotatedAt,
		ReceiptPubkey:   current,
		ReceiptPubkeyPrev: &pool.ReceiptPubkeyPrevious{
			Pubkey:    previous,
			RotatedAt: rotatedAt,
			ExpiresAt: expiresAt,
		},
	}, nil, rotatedAt)
	if !registered {
		t.Fatalf("provider was not registered")
	}

	got := fetchPoolz(t, h.HTTP.URL)
	if len(got.Pool) != 1 {
		t.Fatalf("pool length = %d, want 1", len(got.Pool))
	}
	if got.Pool[0].ReceiptPubkey == nil {
		t.Fatalf("receipt_pubkey = nil, want populated")
	}
	if want := base64.StdEncoding.EncodeToString(current); *got.Pool[0].ReceiptPubkey != want {
		t.Fatalf("receipt_pubkey = %q, want %q", *got.Pool[0].ReceiptPubkey, want)
	}
	prev := got.Pool[0].ReceiptPubkeyPrev
	if prev == nil {
		t.Fatalf("receipt_pubkey_prev = nil, want object")
	}
	if want := base64.StdEncoding.EncodeToString(previous); prev.Pubkey != want {
		t.Fatalf("receipt_pubkey_prev.pubkey = %q, want %q", prev.Pubkey, want)
	}
	if prev.RotatedAt != rotatedAt.Unix() {
		t.Fatalf("receipt_pubkey_prev.rotated_at = %d, want %d", prev.RotatedAt, rotatedAt.Unix())
	}
	if prev.ExpiresAt != expiresAt.Unix() {
		t.Fatalf("receipt_pubkey_prev.expires_at = %d, want %d", prev.ExpiresAt, expiresAt.Unix())
	}
}

func TestProviderAuthV2ReceiptRotationMovesPriorPubkeyToPrevious(t *testing.T) {
	clock := newLockedTime(time.Now().UTC())
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(clock.Now),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	oldPubkey := bytes.Repeat([]byte{0x31}, 32)
	newPubkey := bytes.Repeat([]byte{0x32}, 32)
	oldConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer oldConn.Close()

	rotatedAt := clock.Now().Add(100 * time.Second)
	clock.Set(rotatedAt)
	newConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, newPubkey)
	defer newConn.Close()

	var got poolzResponse
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(newPubkey)
	})
	prev := got.Pool[0].ReceiptPubkeyPrev
	if prev == nil {
		t.Fatalf("receipt_pubkey_prev = nil, want previous key")
	}
	if want := base64.StdEncoding.EncodeToString(oldPubkey); prev.Pubkey != want {
		t.Fatalf("receipt_pubkey_prev.pubkey = %q, want %q", prev.Pubkey, want)
	}
	if prev.RotatedAt != rotatedAt.Unix() {
		t.Fatalf("receipt_pubkey_prev.rotated_at = %d, want %d", prev.RotatedAt, rotatedAt.Unix())
	}
	if want := rotatedAt.Add(pool.ReceiptRotationGrace).Unix(); prev.ExpiresAt != want {
		t.Fatalf("receipt_pubkey_prev.expires_at = %d, want %d", prev.ExpiresAt, want)
	}
}

func TestProviderAuthV2ReceiptRotationDetectedAuditEvent(t *testing.T) {
	clock := newLockedTime(time.Now().UTC())
	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open audit store: %v", err)
	}
	defer auditStore.Close()
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(clock.Now),
		providerws.WithRegistryOptions(pool.WithReceiptRotationEmitter(func(event pool.ReceiptRotationEvent) {
			if err := auditStore.EmitReceiptRotation(context.Background(), event); err != nil {
				t.Errorf("emit receipt rotation: %v", err)
			}
		})),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	oldPubkey := bytes.Repeat([]byte{0x71}, 32)
	newPubkey := bytes.Repeat([]byte{0x72}, 32)
	oldConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer oldConn.Close()

	rotatedAt := clock.Now().Add(100 * time.Second)
	clock.Set(rotatedAt)
	newConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, newPubkey)
	defer newConn.Close()

	var payloadJSON string
	eventually(t, func() bool {
		return auditStore.DB().QueryRowContext(context.Background(), `
SELECT payload_json
FROM audit_log
WHERE event_type = 'receipt_rotation_detected' AND provider_id = 'm4-anon'`).Scan(&payloadJSON) == nil
	})
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		t.Fatalf("payload json: %v", err)
	}
	if payload["event"] != "receipt_rotation_detected" {
		t.Fatalf("event = %#v", payload["event"])
	}
	if payload["old_pubkey"] != base64.StdEncoding.EncodeToString(oldPubkey) || payload["new_pubkey"] != base64.StdEncoding.EncodeToString(newPubkey) {
		t.Fatalf("rotation payload pubkeys = %#v", payload)
	}
	if payload["rotated_at"] != float64(rotatedAt.Unix()) {
		t.Fatalf("rotated_at = %#v, want %d", payload["rotated_at"], rotatedAt.Unix())
	}
}

func TestProviderAuthV2ReceiptRotationRejectsSecondChangeDuringPreviousGrace(t *testing.T) {
	clock := newLockedTime(time.Now().UTC())
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(clock.Now),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	oldPubkey := bytes.Repeat([]byte{0x61}, 32)
	firstRotationPubkey := bytes.Repeat([]byte{0x62}, 32)
	secondRotationPubkey := bytes.Repeat([]byte{0x63}, 32)
	oldConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer oldConn.Close()

	rotatedAt := clock.Now().Add(100 * time.Second)
	clock.Set(rotatedAt)
	firstRotationConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, firstRotationPubkey)
	defer firstRotationConn.Close()

	secondConn, response := authV2ProviderWithReceiptKeyExpectResponseAndMaybeStateUpdate(t, h.HTTP.URL, secondRotationPubkey, true)
	defer secondConn.Close()
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "receipt_rotation_grace_active" {
		t.Fatalf("second rotation auth_response = %+v", response)
	}

	var got poolzResponse
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(firstRotationPubkey)
	})
	prev := got.Pool[0].ReceiptPubkeyPrev
	if prev == nil {
		t.Fatalf("receipt_pubkey_prev = nil, want old key")
	}
	if want := base64.StdEncoding.EncodeToString(oldPubkey); prev.Pubkey != want {
		t.Fatalf("receipt_pubkey_prev.pubkey = %q, want %q", prev.Pubkey, want)
	}
}

func TestProviderAuthV2ReceiptKeyOmissionClearsLiveReceiptTrustState(t *testing.T) {
	clock := newLockedTime(time.Now().UTC())
	var logBuffer lockedBuffer
	h := newProviderHarnessWithServerOptionsAndLogger(t, nil, []providerws.Option{
		providerws.WithNow(clock.Now),
	}, zerolog.New(&logBuffer), func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	oldPubkey := bytes.Repeat([]byte{0x71}, 32)
	newPubkey := bytes.Repeat([]byte{0x72}, 32)
	oldConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer oldConn.Close()

	rotatedAt := clock.Now().Add(100 * time.Second)
	clock.Set(rotatedAt)
	newConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, newPubkey)
	defer newConn.Close()

	omitConn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial omit key: %v", err)
	}
	defer omitConn.Close()
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	if err := wsutil.WriteClientText(omitConn, mustJSON(initial)); err != nil {
		t.Fatalf("write omit-key auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, omitConn)
	writeAuthProof(t, omitConn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, omitConn)
	if response.Status != "accepted" {
		t.Fatalf("omit-key auth_response = %+v", response)
	}
	writeStateUpdate(t, omitConn, "ready")
	logText := logBuffer.String()
	if !strings.Contains(logText, `"receipt_omitted":true`) || !strings.Contains(logText, `"reason":"no_keypair"`) {
		t.Fatalf("missing receipt omission log fields: %s", logText)
	}

	got := fetchPoolz(t, h.HTTP.URL)
	if len(got.Pool) != 1 {
		t.Fatalf("poolz rows after omit reconnect: %+v", got.Pool)
	}
	if got.Pool[0].ReceiptPubkey != nil {
		t.Fatalf("receipt_pubkey = %q after omit reconnect, want nil", *got.Pool[0].ReceiptPubkey)
	}
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v after omit reconnect, want nil", got.Pool[0].ReceiptPubkeyPrev)
	}

	republishConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, newPubkey)
	defer republishConn.Close()
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(newPubkey) && got.Pool[0].ReceiptPubkeyPrev == nil
	})
}

func TestProviderAuthV2InitialReceiptCandidateWithoutStateUpdateDoesNotPublish(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	candidatePubkey := bytes.Repeat([]byte{0x53}, 32)
	candidateConn, response := authV2ProviderWithReceiptKeyExpectResponseAndMaybeStateUpdate(t, h.HTTP.URL, candidatePubkey, false)
	defer candidateConn.Close()
	if response.Status != "accepted" {
		t.Fatalf("candidate auth_response = %+v", response)
	}

	var got poolzResponse
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ProviderID == "m4-anon"
	})
	if got.Pool[0].ReceiptPubkey != nil {
		t.Fatalf("receipt_pubkey = %q before initial state_update, want nil", *got.Pool[0].ReceiptPubkey)
	}
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v before initial state_update, want nil", got.Pool[0].ReceiptPubkeyPrev)
	}
	if got.Summary.Ready != 0 || got.Summary.FreeSlots != 0 {
		t.Fatalf("pending initial candidate summary = %+v, want no buyer-usable ready/free capacity", got.Summary)
	}
	healthz := fetchProviderHealthz(t, h.HTTP.URL)
	if healthz.PoolSize != 1 || healthz.PoolReady != 0 || healthz.PoolPolicyReady != 0 {
		t.Fatalf("pending initial candidate healthz = %+v, want visible but not ready/policy-ready", healthz)
	}
	provider, ok := h.Registry.Resolve("m4-anon", response.AssignedID)
	if !ok || !bytes.Equal(provider.PendingReceiptPubkey, candidatePubkey) || provider.RoutingEligible() {
		t.Fatalf("pending initial provider = %+v, ok=%v; want pending and non-routable", provider, ok)
	}
}

func TestProviderAuthV2ReceiptRotationCandidateWithoutStateUpdateDoesNotPublish(t *testing.T) {
	clock := newLockedTime(time.Now().UTC())
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(clock.Now),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	oldPubkey := bytes.Repeat([]byte{0x51}, 32)
	candidatePubkey := bytes.Repeat([]byte{0x52}, 32)
	oldConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer oldConn.Close()

	rotatedAt := clock.Now().Add(100 * time.Second)
	clock.Set(rotatedAt)
	candidateConn, response := authV2ProviderWithReceiptKeyExpectResponseAndMaybeStateUpdate(t, h.HTTP.URL, candidatePubkey, false)
	defer candidateConn.Close()
	if response.Status != "accepted" {
		t.Fatalf("candidate auth_response = %+v", response)
	}

	var got poolzResponse
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(oldPubkey)
	})
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v, want nil before post-commit state_update", got.Pool[0].ReceiptPubkeyPrev)
	}
	if got.Summary.Ready != 0 || got.Summary.FreeSlots != 0 {
		t.Fatalf("pending rotation summary = %+v, want no buyer-usable ready/free capacity", got.Summary)
	}
	provider, ok := h.Registry.Resolve("m4-anon", response.AssignedID)
	if !ok || !bytes.Equal(provider.PendingReceiptPubkey, candidatePubkey) || provider.RoutingEligible() {
		t.Fatalf("pending rotation provider = %+v, ok=%v; want pending and non-routable", provider, ok)
	}

	oldRestoreConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer oldRestoreConn.Close()
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(oldPubkey) && got.Pool[0].ReceiptPubkeyPrev == nil
	})
}

func TestProviderAuthV2ReceiptRotationPurgesPreviousAfterGraceWindow(t *testing.T) {
	clock := newLockedTime(time.Now().UTC())
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithNow(clock.Now),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()

	oldPubkey := bytes.Repeat([]byte{0x41}, 32)
	newPubkey := bytes.Repeat([]byte{0x42}, 32)
	firstConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, oldPubkey)
	defer firstConn.Close()

	rotatedAt := clock.Now().Add(100 * time.Second)
	clock.Set(rotatedAt)
	rotatedConn := authV2ProviderWithReceiptKey(t, h.HTTP.URL, newPubkey)
	defer rotatedConn.Close()

	var got poolzResponse
	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(newPubkey) && got.Pool[0].ReceiptPubkeyPrev != nil
	})

	clock.Set(rotatedAt.Add(pool.ReceiptRotationGrace + time.Second))

	eventually(t, func() bool {
		got = fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].ReceiptPubkey != nil && *got.Pool[0].ReceiptPubkey == base64.StdEncoding.EncodeToString(newPubkey)
	})
	if got.Pool[0].ReceiptPubkeyPrev != nil {
		t.Fatalf("receipt_pubkey_prev = %+v, want nil after grace window", got.Pool[0].ReceiptPubkeyPrev)
	}
}

func TestStateUpdateCyclesProviderState(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	states := []string{"ready", "busy", "degraded", "draining", "unavailable"}
	for _, state := range states {
		msg := map[string]any{
			"type":   "state_update",
			"state":  state,
			"reason": "test transition",
			"since":  "2026-05-27T14:30:00Z",
			"metrics_snapshot": map[string]any{
				"slots_free":  0,
				"slots_total": 1,
			},
		}
		if state == "ready" {
			msg["metrics_snapshot"].(map[string]any)["slots_free"] = 1
		}
		if err := wsutil.WriteClientText(conn, mustJSON(msg)); err != nil {
			t.Fatalf("write state_update %s: %v", state, err)
		}
		eventually(t, func() bool {
			got := fetchPoolz(t, ts.URL)
			return len(got.Pool) == 1 && got.Pool[0].State == state
		})
	}
}

func TestWakeGapSendsWarmUpAndMarksDegraded(t *testing.T) {
	// The wake-gap detector fires when the interval between two
	// heartbeats exceeds wake_gap_threshold. Use a 25ms threshold so the
	// scenario can be reproduced with a 50ms sleep instead of >1s, which
	// shrinks the test under CI contention. The real flake risk is
	// server-side goroutine starvation between the resume heartbeat and
	// pool-state propagation — eventuallyWithin gives that wide latitude.
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Pool.WakeGapThresholdMs = 25
	})
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	if err := wsutil.WriteClientText(conn, mustJSON(heartbeat())); err != nil {
		t.Fatalf("write first heartbeat: %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := wsutil.WriteClientText(conn, mustJSON(heartbeat())); err != nil {
		t.Fatalf("write resume heartbeat: %v", err)
	}

	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read warm_up: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var msg map[string]string
	if err := json.Unmarshal(payload, &msg); err != nil {
		t.Fatalf("warm_up json: %v", err)
	}
	if msg["type"] != "warm_up" {
		t.Fatalf("message type = %q, want warm_up", msg["type"])
	}

	eventuallyWithin(t, 4*time.Second, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].State == "degraded"
	})
}

func TestPreflightRoundTrip(t *testing.T) {
	h := newProviderHarness(t)
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	resultCh := make(chan struct {
		ack providerws.PreflightAck
		ok  bool
		err error
	}, 1)
	go func() {
		ack, ok, err := h.Provider.Preflight(pool.Provider{ProviderID: "m4-anon", AssignedID: assignedID}, "req-1", 9000, time.Second)
		resultCh <- struct {
			ack providerws.PreflightAck
			ok  bool
			err error
		}{ack: ack, ok: ok, err: err}
	}()

	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read preflight: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var preflight map[string]any
	if err := json.Unmarshal(payload, &preflight); err != nil {
		t.Fatalf("preflight json: %v", err)
	}
	if preflight["type"] != "preflight" || preflight["request_id"] != "req-1" || int(preflight["estimated_tokens"].(float64)) != 9000 {
		t.Fatalf("preflight = %#v", preflight)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(map[string]any{
		"type":              "preflight_ack",
		"request_id":        "req-1",
		"accepted":          true,
		"estimated_wait_ms": 0,
	})); err != nil {
		t.Fatalf("write preflight_ack: %v", err)
	}

	select {
	case got := <-resultCh:
		if got.err != nil || !got.ok || !got.ack.Accepted {
			t.Fatalf("preflight result = ack:%#v ok:%v err:%v", got.ack, got.ok, got.err)
		}
	case <-time.After(time.Second):
		t.Fatal("preflight result timed out")
	}
}

func TestParsePreflightAckAcceptsAllSpecRejectionReasons(t *testing.T) {
	reasons := []string{
		"context_exceeds_capacity",
		"queue_full",
		"draining",
		"model_not_loaded",
		"unhealthy",
		"tier_mismatch",
	}
	for _, reason := range reasons {
		ack, field, err := providerws.ParsePreflightAck(mustJSON(map[string]any{
			"type":       "preflight_ack",
			"request_id": "req-" + reason,
			"accepted":   false,
			"reason":     reason,
		}))
		if err != nil {
			t.Fatalf("reason %s rejected at %s: %v", reason, field, err)
		}
		if ack.Reason != reason {
			t.Fatalf("reason = %q, want %q", ack.Reason, reason)
		}
	}
	_, field, err := providerws.ParsePreflightAck(mustJSON(map[string]any{
		"type":       "preflight_ack",
		"request_id": "req-bad",
		"accepted":   false,
		"reason":     "unknown",
	}))
	if err == nil || field != "reason" {
		t.Fatalf("invalid reason field=%q err=%v", field, err)
	}
}

func TestDisconnectMarksUnavailableThenRemovesAfterGrace(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Pool.DisconnectGracePeriodS = 1
	})
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	assertHelloAck(t, conn)
	if err := conn.Close(); err != nil {
		t.Fatalf("close provider conn: %v", err)
	}

	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].State == "unavailable"
	})
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 0
	})
}

func TestMissedHeartbeatClosesProviderWebSocketAndMarksUnavailable(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.HeartbeatIntervalS = 1
		cfg.Routing.FailoverTimeoutS = 1
		cfg.Pool.HeartbeatMissThresholdS = 1
		cfg.Pool.DisconnectGracePeriodS = 5
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" || ack.HeartbeatIntervalS != 1 {
		t.Fatalf("ack = %#v", ack)
	}

	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", "")
		return ok && provider.State == pool.StateUnavailable
	})
	if _, err := gobwas.ReadFrame(conn); err == nil {
		t.Fatal("expected stale heartbeat monitor to close provider websocket")
	}
}

func TestActiveProviderWithoutHeartbeatStaysConnected(t *testing.T) {
	// Regression (Phase 6 hotfix): a provider streaming inference response
	// chunks but NOT sending heartbeats — because its single inference slot
	// is busy generating — must not be closed by the liveness monitor. The
	// monitor keys off last inbound activity of any kind, not heartbeats.
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.HeartbeatIntervalS = 1
		cfg.Routing.FailoverTimeoutS = 1
		cfg.Pool.HeartbeatMissThresholdS = 1 // 1s — trivially exceeded if only heartbeats counted
		cfg.Pool.DisconnectGracePeriodS = 5
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("busy-provider"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(conn); err != nil {
		t.Fatalf("read ack: %v", err)
	}

	// Stream non-heartbeat activity for ~3x the miss threshold without ever
	// sending a heartbeat.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		chunk := map[string]any{
			"type":       "inference_response_chunk",
			"request_id": "no-such-request",
			"seq":        0,
			"data":       "tok",
		}
		if err := wsutil.WriteClientText(conn, mustJSON(chunk)); err != nil {
			t.Fatalf("write chunk: %v", err)
		}
		time.Sleep(200 * time.Millisecond)
	}

	provider, ok := h.Registry.Resolve("busy-provider", "")
	if !ok {
		t.Fatal("provider was removed despite continuous activity")
	}
	if provider.State == pool.StateUnavailable {
		t.Fatalf("provider marked unavailable despite continuous activity; state=%s", provider.State)
	}
}

func TestProviderClosedAfterActivityStops(t *testing.T) {
	// Regression boundary: a provider that WAS active (streaming chunks) and
	// then goes silent must be closed ~heartbeat_miss_threshold_s after its
	// LAST inbound frame — proving liveness is keyed off activity staleness,
	// not merely total absence of frames. Guards against a future revert to
	// LastHeartbeatAt-only checking.
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Pool.HeartbeatIntervalS = 1
		cfg.Routing.FailoverTimeoutS = 1
		cfg.Pool.HeartbeatMissThresholdS = 1
		cfg.Pool.DisconnectGracePeriodS = 5
	})
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("then-silent"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(conn); err != nil {
		t.Fatalf("read ack: %v", err)
	}

	// A burst of activity, then go silent.
	for i := 0; i < 3; i++ {
		chunk := map[string]any{"type": "inference_response_chunk", "request_id": "no-such-request", "seq": i, "data": "tok"}
		if err := wsutil.WriteClientText(conn, mustJSON(chunk)); err != nil {
			t.Fatalf("write chunk: %v", err)
		}
		time.Sleep(150 * time.Millisecond)
	}

	// After silence exceeds the 1s threshold, the monitor must close + reap.
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("then-silent", "")
		return ok && provider.State == pool.StateUnavailable
	})
}

// Regression: M1-4 follow-up. When nginx fronts the coordinator on
// loopback, r.RemoteAddr is 127.0.0.1 for every public client and the
// pre-fix per-IP bucket collapsed to a single shared 127.0.0.1 slot
// (codex security audit 2026-06-11). Fix: honor X-Real-IP when the
// immediate remote is loopback. This pins the bucket per real-client
// IP behind a loopback proxy.
func TestRemoteIPForUnauthSemaphoreHonorsXRealIPBehindLoopback(t *testing.T) {
	cases := []struct {
		name       string
		remoteAddr string
		xRealIP    string
		want       string
	}{
		{name: "loopback_ipv4_with_real_ip", remoteAddr: "127.0.0.1:54321", xRealIP: "203.0.113.5", want: "203.0.113.5"},
		{name: "loopback_ipv6_with_real_ip", remoteAddr: "[::1]:54321", xRealIP: "2001:db8::1", want: "2001:db8::1"},
		{name: "loopback_no_real_ip_falls_back", remoteAddr: "127.0.0.1:54321", xRealIP: "", want: "127.0.0.1"},
		{name: "non_loopback_ignores_real_ip", remoteAddr: "198.51.100.7:443", xRealIP: "203.0.113.5", want: "198.51.100.7"},
		{name: "non_loopback_no_real_ip", remoteAddr: "198.51.100.7:443", xRealIP: "", want: "198.51.100.7"},
		{name: "x_real_ip_whitespace_trimmed", remoteAddr: "127.0.0.1:54321", xRealIP: "  203.0.113.5  ", want: "203.0.113.5"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			header := http.Header{}
			if tc.xRealIP != "" {
				header.Set("X-Real-IP", tc.xRealIP)
			}
			got := providerws.RemoteIPForUnauthSemaphoreExport(tc.remoteAddr, header)
			if got != tc.want {
				t.Fatalf("remoteIPForUnauthSemaphore(%q, X-Real-IP=%q) = %q, want %q", tc.remoteAddr, tc.xRealIP, got, tc.want)
			}
		})
	}
}

// Regression: M1-4 / SECU-1. Per-IP cap on concurrent unauthenticated WS
// handshakes refuses the (cap+1)-th attempt from a single source even
// when the global semaphore still has room. Pre-fix the only backstop
// was a single global 64-slot semaphore with no per-IP dimension — one
// host could starve all provider readmissions (full inference outage at
// N=3). Test sets the cap to 4, opens 4 dialed-but-silent connections,
// asserts the 5th gets ClosePoolFull with the per-IP reason.
func TestProviderUnauthenticatedConnPerIPCapDeniesFifth(t *testing.T) {
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.WS.MaxUnauthenticatedConnPerIP = 4
		cfg.WS.MaxUnauthenticatedConn = 64 // global cap leaves room — per-IP must fire
	})
	defer h.HTTP.Close()

	conns := make([]net.Conn, 0, 4)
	defer func() {
		for _, c := range conns {
			_ = c.Close()
		}
	}()
	for i := 0; i < 4; i++ {
		c, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		conns = append(conns, c)
	}
	// Dial returning means the HTTP upgrade completed; the server's
	// reserveUnauthenticatedConnForIP call runs in the handler goroutine
	// after gobwas.UpgradeHTTP returns. Wait for the counter to reach 4
	// before opening the 5th conn, otherwise the 5th can win the race and
	// reserve a slot before earlier conns get accounted (test flakiness).
	eventually(t, func() bool {
		return h.Provider.UnauthenticatedPerIPSnapshot() >= 4
	})

	fifth, fifthBR, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial fifth: %v", err)
	}
	defer fifth.Close()
	// The server writes the close frame immediately after HTTP upgrade.
	// gobwas.Dial's bufio.Reader may have already buffered those bytes off
	// the socket as part of the same TCP read that delivered the upgrade
	// response. Read from the bufio.Reader, not from the raw conn (which
	// would EOF if the close frame was already pulled into the buffer).
	_ = fifth.SetReadDeadline(time.Now().Add(2 * time.Second))
	var reader io.Reader = fifth
	if fifthBR != nil && fifthBR.Buffered() > 0 {
		reader = fifthBR
	}
	frame, err := gobwas.ReadFrame(reader)
	if err != nil {
		t.Fatalf("read fifth close: %v", err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.ClosePoolFull || reason != "too_many_unauthenticated_connections_per_ip" {
		t.Fatalf("fifth close = (%d, %q), want (%d, %q)", code, reason, providerws.ClosePoolFull, "too_many_unauthenticated_connections_per_ip")
	}
}

func TestPoolzRequiresOperatorKey(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/poolz")
	if err != nil {
		t.Fatalf("poolz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}

// Regression: M1-5 / SECU-5. authorizedOperator must DENY when the configured
// operator key is empty (fail closed). Previously the predicate short-circuited
// to allow on empty expected key, relying on config.Validate() in main.go to
// refuse to start. That defense-in-depth coupling meant any future entry point
// that bypassed Validate would silently fail open. This test constructs a
// server with an empty OperatorKey directly (bypassing Validate) and asserts
// /poolz returns 401 even without a Bearer token in the request.
func TestPoolzDeniesWhenOperatorKeyEmpty(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Auth.OperatorKey = ""
	})
	defer ts.Close()

	// No Authorization header — pre-fix this returned 200 because the
	// short-circuit treated empty expected key as "no auth required."
	resp, err := http.Get(ts.URL + "/poolz")
	if err != nil {
		t.Fatalf("poolz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 (empty operator key must deny)", resp.StatusCode)
	}

	// Even a Bearer token that happens to be the empty string must deny.
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/poolz", nil)
	req.Header.Set("Authorization", "Bearer ")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("poolz: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 with empty-bearer header", resp2.StatusCode)
	}
}

func TestProviderHealthzReportsInjectedVersion(t *testing.T) {
	harness := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithVersion("v1.3.0-7-gabcdef0"),
	}, func(cfg *config.Config) {
		cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.26"
	})
	defer harness.HTTP.Close()

	resp, err := http.Get(harness.HTTP.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz status = %d", resp.StatusCode)
	}
	var body struct {
		Status                   string `json:"status"`
		Version                  string `json:"version"`
		RecommendedBinaryVersion string `json:"recommended_binary_version"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Status != "ok" {
		t.Fatalf("status = %q", body.Status)
	}
	if body.Version != "v1.3.0-7-gabcdef0" {
		t.Fatalf("version = %q, want %q", body.Version, "v1.3.0-7-gabcdef0")
	}
	if body.RecommendedBinaryVersion != "1.8.26" {
		t.Fatalf("recommended_binary_version = %q, want %q", body.RecommendedBinaryVersion, "1.8.26")
	}
}

func TestProviderHealthzAcceptsHEAD(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	req, err := http.NewRequest(http.MethodHead, ts.URL+"/healthz", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("healthz HEAD: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("HEAD /healthz status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if len(body) != 0 {
		t.Fatalf("HEAD /healthz must return no body; got %q", body)
	}
}

func TestProviderHealthzDefaultVersion(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Version != "dev" {
		t.Fatalf("default version = %q, want \"dev\"", body.Version)
	}
}

func TestProviderHealthzAndPoolzExcludeSelfMintedFromPublishedCapacity(t *testing.T) {
	harness := newProviderHarness(t)
	defer harness.HTTP.Close()
	now := time.Now().UTC()
	harness.Registry.Register(&pool.Provider{
		ProviderID:       "m4-anon",
		AssignedID:       "self-minted-session",
		Hostname:         "self-minted.local",
		ModelID:          "model-a",
		MaxContextTokens: 20000,
		SlotsFree:        1,
		SlotsTotal:       1,
		EndpointURL:      "https://m4.malibu.tech",
		Tier:             pool.TierPinned,
		State:            pool.StateReady,
		LastHeartbeatAt:  now,
		LastActivityAt:   now,
		ConnectedAt:      now,
		BinaryVersion:    "0.1.0",
		AuthState:        pool.AuthSelfMinted,
	}, nil)

	healthz := fetchProviderHealthz(t, harness.HTTP.URL)
	if healthz.PoolSize != 1 || healthz.PoolReady != 0 || healthz.PoolPolicyReady != 0 {
		t.Fatalf("self-minted healthz = %+v, want visible but not ready/policy-ready", healthz)
	}
	poolz := fetchPoolz(t, harness.HTTP.URL)
	if poolz.Summary.TotalProviders != 1 || poolz.Summary.Ready != 0 || poolz.Summary.FreeSlots != 0 {
		t.Fatalf("self-minted poolz summary = %+v, want visible but not ready/free capacity", poolz.Summary)
	}
}

func TestOperatorEndpointsBlacklistTwoPhaseDrain(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assignedID := assertHelloAck(t, conn)

	healthResp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer healthResp.Body.Close()
	if healthResp.StatusCode != http.StatusOK {
		t.Fatalf("healthz status = %d", healthResp.StatusCode)
	}
	var health struct {
		Status   string `json:"status"`
		PoolSize int    `json:"pool_size"`
	}
	if err := json.NewDecoder(healthResp.Body).Decode(&health); err != nil {
		t.Fatalf("health json: %v", err)
	}
	if health.Status != "ok" || health.PoolSize != 1 {
		t.Fatalf("health = %#v", health)
	}

	reqBody := bytes.NewReader(mustJSON(map[string]string{
		"provider_id": "m4-anon",
		"reason":      "test blacklist",
	}))
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/admin/blacklist", reqBody)
	if err != nil {
		t.Fatalf("blacklist request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("blacklist: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("blacklist status=%d body=%s", resp.StatusCode, body)
	}
	var blacklist struct {
		Status     string `json:"status"`
		ProviderID string `json:"provider_id"`
		AssignedID string `json:"assigned_id"`
		DrainSent  bool   `json:"drain_sent"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&blacklist); err != nil {
		t.Fatalf("blacklist json: %v", err)
	}
	if blacklist.Status != "draining" || blacklist.ProviderID != "m4-anon" || blacklist.AssignedID != assignedID || !blacklist.DrainSent {
		t.Fatalf("blacklist response = %#v", blacklist)
	}

	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read drain: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var drain map[string]string
	if err := json.Unmarshal(payload, &drain); err != nil {
		t.Fatalf("drain json: %v", err)
	}
	if drain["type"] != "drain" {
		t.Fatalf("drain = %#v", drain)
	}
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].State == "draining"
	})

	if err := wsutil.WriteClientText(conn, mustJSON(map[string]any{
		"type":                    "drain_status",
		"phase":                   "complete",
		"inflight_requests":       0,
		"estimated_drain_seconds": 0,
	})); err != nil {
		t.Fatalf("write drain_status complete: %v", err)
	}
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 0
	})

	missingBody := bytes.NewReader(mustJSON(map[string]string{"provider_id": "missing"}))
	missing, err := http.NewRequest(http.MethodPost, ts.URL+"/admin/blacklist", missingBody)
	if err != nil {
		t.Fatalf("missing request: %v", err)
	}
	missing.Header.Set("Authorization", "Bearer test-operator-key")
	missingResp, err := http.DefaultClient.Do(missing)
	if err != nil {
		t.Fatalf("missing blacklist: %v", err)
	}
	defer missingResp.Body.Close()
	if missingResp.StatusCode != http.StatusNotFound {
		body, _ := io.ReadAll(missingResp.Body)
		t.Fatalf("missing status=%d body=%s", missingResp.StatusCode, body)
	}
}

func TestOperatorRejectClosesProviderWithBannedCode(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	req, err := http.NewRequest(http.MethodPost, ts.URL+"/admin/reject/m4-anon", bytes.NewReader(mustJSON(map[string]string{"reason": "test reject"})))
	if err != nil {
		t.Fatalf("reject request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("reject: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("reject status=%d body=%s", resp.StatusCode, body)
	}

	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read drain: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text drain", op)
	}
	var drain map[string]string
	if err := json.Unmarshal(payload, &drain); err != nil {
		t.Fatalf("drain json: %v", err)
	}
	if drain["type"] != "drain" {
		t.Fatalf("drain = %#v", drain)
	}

	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseBanned || !strings.Contains(reason, "has been rejected by operator") {
		t.Fatalf("close = %d %q", code, reason)
	}
}

func TestDrainAllSendsDrainAndMarksDraining(t *testing.T) {
	h := newProviderHarness(t)
	defer h.HTTP.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	assertHelloAck(t, conn)

	h.Provider.DrainAll("test shutdown")
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read drain: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var drain map[string]string
	if err := json.Unmarshal(payload, &drain); err != nil {
		t.Fatalf("drain json: %v", err)
	}
	if drain["type"] != "drain" {
		t.Fatalf("drain = %#v", drain)
	}
	eventually(t, func() bool {
		got := fetchPoolz(t, h.HTTP.URL)
		return len(got.Pool) == 1 && got.Pool[0].State == "draining"
	})
}

func assertHelloAck(t *testing.T, conn net.Conn) string {
	t.Helper()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("m4-anon"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}

	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack type = %q", ack.Type)
	}
	if ack.CoordinatorVersion != 1 {
		t.Fatalf("coordinator_version = %d", ack.CoordinatorVersion)
	}
	if ack.AssignedID == "" {
		t.Fatal("assigned_id is empty")
	}
	if ack.HeartbeatIntervalS != 30 {
		t.Fatalf("heartbeat_interval_s = %d", ack.HeartbeatIntervalS)
	}
	return ack.AssignedID
}

func readInferenceRequest(t *testing.T, conn net.Conn) providerws.InferenceRequest {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	defer conn.SetReadDeadline(time.Time{})
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var req providerws.InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("inference_request json: %v", err)
	}
	if req.Type != "inference_request" {
		t.Fatalf("message type = %q, want inference_request", req.Type)
	}
	return req
}

func writeWarmupCompletion(t *testing.T, conn net.Conn, requestID string, completionTokens int) {
	t.Helper()
	if err := wsutil.WriteClientText(conn, mustJSON(providerws.InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Seq:       0,
		Data:      `{"id":"warmup","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}`,
	})); err != nil {
		t.Fatalf("write warmup chunk: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(providerws.InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  requestID,
		Status:     "complete",
		ChunksSent: 1,
		Usage: json.RawMessage(mustJSON(map[string]any{
			"prompt_tokens":     4,
			"completion_tokens": completionTokens,
			"total_tokens":      4 + completionTokens,
		})),
	})); err != nil {
		t.Fatalf("write warmup end: %v", err)
	}
}

func TestProviderHelloAdmitsUnknownProviderAsProvisional(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(validHello("unknown"))); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Tier != "provisional" {
		t.Fatalf("tier = %q, want provisional", ack.Tier)
	}
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].ProviderID == "unknown" && got.Pool[0].Tier == "provisional" && got.Pool[0].InferencePath == "ws_tunneled"
	})
}

func TestProviderHelloPinnedStaticEndpointIgnoresHelloOverride(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	h := validHello("m4-anon")
	h["endpoint_url"] = "https://evil.example"
	if err := wsutil.WriteClientText(conn, mustJSON(h)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack = %#v", ack)
	}
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].Endpoint == "https://m4.malibu.tech"
	})
}

func TestProviderHelloIgnoresPinnedHelloEndpointWithoutConfiguredEndpoint(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer ts.Close()

	h := validHello("m4-anon")
	h["endpoint_url"] = "http://169.254.169.254/latest/meta-data"
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(ts.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(h)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil {
		t.Fatalf("ack json: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("ack = %#v", ack)
	}
	eventually(t, func() bool {
		got := fetchPoolz(t, ts.URL)
		return len(got.Pool) == 1 && got.Pool[0].Endpoint == "" && got.Pool[0].InferencePath == "ws_tunneled"
	})
}

func TestProviderHelloRejectsMalformedHello(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	h := validHello("m4-anon")
	delete(h, "model_id")
	code, reason := sendHelloExpectClose(t, ts.URL, h)
	if code != providerws.CloseInvalidHello {
		t.Fatalf("code = %d, want %d", code, providerws.CloseInvalidHello)
	}
	if reason != "invalid_hello: missing model_id" {
		t.Fatalf("reason = %q", reason)
	}
}

func TestProviderHelloRejectsUnsupportedVersionAndTier(t *testing.T) {
	ts := newProviderServer(t)
	defer ts.Close()

	versionHello := validHello("m4-anon")
	versionHello["version"] = 2
	code, reason := sendHelloExpectClose(t, ts.URL, versionHello)
	if code != providerws.CloseUnrecognizedAuthMessage {
		t.Fatalf("version code = %d, want %d", code, providerws.CloseUnrecognizedAuthMessage)
	}
	if reason != "unrecognized auth message" {
		t.Fatalf("version reason = %q", reason)
	}

	tierHello := validHello("m4-anon")
	tierHello["tier"] = 2
	code, reason = sendHelloExpectClose(t, ts.URL, tierHello)
	if code != providerws.CloseTierUnsupported {
		t.Fatalf("tier code = %d, want %d", code, providerws.CloseTierUnsupported)
	}
	if reason != "tier_unsupported: tier 2 not supported" {
		t.Fatalf("tier reason = %q", reason)
	}
}

func TestProviderHelloRejectsBelowRequiredBinaryVersion(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.2.6"
	})
	defer ts.Close()

	hello := validHello("m4-anon")
	hello["binary_version"] = "1.2.5"
	code, reason := sendHelloExpectClose(t, ts.URL, hello)
	if code != providerws.CloseVersionUnsupported {
		t.Fatalf("code = %d, want %d", code, providerws.CloseVersionUnsupported)
	}
	if !strings.Contains(reason, "below required 1.2.6") {
		t.Fatalf("reason = %q", reason)
	}
}

func TestProviderHelloRejectsSuffixedRequiredBinaryVersion(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion = "1.2.6"
	})
	defer ts.Close()

	hello := validHello("m4-anon")
	hello["binary_version"] = "1.2.6-dev"
	code, reason := sendHelloExpectClose(t, ts.URL, hello)
	if code != providerws.CloseVersionUnsupported {
		t.Fatalf("code = %d, want %d", code, providerws.CloseVersionUnsupported)
	}
	if !strings.Contains(reason, "below required 1.2.6") {
		t.Fatalf("reason = %q", reason)
	}
}

func TestProviderHelloRejectsV1WhenEncryptedLegRequired(t *testing.T) {
	ts := newProviderServer(t, func(cfg *config.Config) {
		cfg.Tier2.RequireEncryptedLeg = true
	})
	defer ts.Close()

	code, reason := sendHelloExpectClose(t, ts.URL, validHello("m4-anon"))
	if code != providerws.CloseTier2KeyExchangeFailed || reason != "tier2_encrypted_leg_required" {
		t.Fatalf("close = %d %q, want %d tier2_encrypted_leg_required", code, reason, providerws.CloseTier2KeyExchangeFailed)
	}
}

type poolzResponse struct {
	Pool []struct {
		ProviderID        string                  `json:"provider_id"`
		State             string                  `json:"state"`
		SlotsFree         int                     `json:"slots_free"`
		SlotsTotal        int                     `json:"slots_total"`
		Endpoint          string                  `json:"endpoint_url"`
		Tier              string                  `json:"tier"`
		InferencePath     string                  `json:"inference_path"`
		ReceiptPubkey     *string                 `json:"receipt_pubkey"`
		ReceiptPubkeyPrev *poolzReceiptPubkeyPrev `json:"receipt_pubkey_prev"`
	} `json:"pool"`
	Summary struct {
		TotalProviders int `json:"total_providers"`
		Ready          int `json:"ready"`
		FreeSlots      int `json:"free_slots"`
	} `json:"summary"`
}

type poolzReceiptPubkeyPrev struct {
	Pubkey    string `json:"pubkey"`
	RotatedAt int64  `json:"rotated_at"`
	ExpiresAt int64  `json:"expires_at"`
}

type providerHealthzResponse struct {
	PoolSize        int `json:"pool_size"`
	PoolReady       int `json:"pool_ready"`
	PoolPolicyReady int `json:"pool_policy_ready"`
}

func fetchProviderHealthz(t *testing.T, serverURL string) providerHealthzResponse {
	t.Helper()
	resp, err := http.Get(serverURL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("healthz status=%d body=%s", resp.StatusCode, body)
	}
	var got providerHealthzResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("healthz json: %v", err)
	}
	return got
}

func fetchPoolz(t *testing.T, serverURL string) poolzResponse {
	t.Helper()
	_, got := fetchPoolzRaw(t, serverURL)
	return got
}

func fetchPoolzRaw(t *testing.T, serverURL string) ([]byte, poolzResponse) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, serverURL+"/poolz", nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("poolz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("poolz status=%d body=%s", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read poolz: %v", err)
	}
	var got poolzResponse
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("poolz json: %v", err)
	}
	return body, got
}

type providerHarness struct {
	HTTP     *httptest.Server
	Provider *providerws.Server
	Registry *pool.Registry
}

func newProviderServer(t *testing.T, opts ...func(*config.Config)) *httptest.Server {
	t.Helper()
	return newProviderHarness(t, opts...).HTTP
}

func newProviderHarnessWithTokenValidator(t *testing.T, validator providerws.TokenValidator, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	return newProviderHarnessWithOptions(t, validator, nil, opts...)
}

func newProviderHarness(t *testing.T, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	return newProviderHarnessWithOptions(t, nil, nil, opts...)
}

func newProviderHarnessWithServerOptions(t *testing.T, validator providerws.TokenValidator, serverOpts []providerws.Option, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	return newProviderHarnessWithOptions(t, validator, serverOpts, opts...)
}

func newProviderHarnessWithServerOptionsAndLogger(t *testing.T, validator providerws.TokenValidator, serverOpts []providerws.Option, logger zerolog.Logger, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	return newProviderHarnessWithOptionsAndLogger(t, validator, serverOpts, logger, opts...)
}

func newProviderHarnessWithOptions(t *testing.T, validator providerws.TokenValidator, serverOpts []providerws.Option, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	return newProviderHarnessWithOptionsAndLogger(t, validator, serverOpts, zerolog.Nop(), opts...)
}

func newProviderHarnessWithOptionsAndLogger(t *testing.T, validator providerws.TokenValidator, serverOpts []providerws.Option, logger zerolog.Logger, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	if validator == nil {
		cfg.Auth.RequireProviderTokens = false
	}
	cfg.Pool.WarmupGateEnabled = false
	cfg.Providers = []config.ProviderConfig{
		{
			ProviderID:  "m4-anon",
			EndpointURL: "https://m4.malibu.tech",
			DisplayName: "M4 test provider",
		},
	}
	for _, opt := range opts {
		opt(&cfg)
	}
	registry := pool.NewRegistry(cfg.Providers)
	allServerOpts := append([]providerws.Option(nil), serverOpts...)
	if validator != nil {
		allServerOpts = append(allServerOpts, providerws.WithTokenValidator(validator))
		// SPEC-003 v0.8 FR-C9.1 — when the harness ships a TokenValidator
		// that also satisfies TokenIssuer (i.e. *auth.Store or
		// mintFailingStore), wire it as the issuer too so the self-serve
		// path is exercised. Validator-only mocks skip this branch.
		if issuer, ok := validator.(providerws.TokenIssuer); ok {
			allServerOpts = append(allServerOpts, providerws.WithTokenIssuer(issuer))
		}
		if bootstrapStore, ok := validator.(providerws.BootstrapTokenStore); ok {
			allServerOpts = append(allServerOpts, providerws.WithBootstrapTokenStore(bootstrapStore))
		}
	}
	server := providerws.NewServer(cfg, registry, logger, allServerOpts...)
	return providerHarness{
		HTTP:     httptest.NewServer(server.Handler()),
		Provider: server,
		Registry: registry,
	}
}

func bearerDialer(token string) gobwas.Dialer {
	return gobwas.Dialer{
		Header: gobwas.HandshakeHeaderHTTP(http.Header{
			"Authorization": []string{"Bearer " + token},
		}),
	}
}

func sendHelloExpectClose(t *testing.T, serverURL string, hello map[string]any) (gobwas.StatusCode, string) {
	t.Helper()
	conn, br, _, err := gobwas.Dial(context.Background(), wsURL(serverURL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	var src io.Reader = conn
	if br != nil {
		src = br
	}
	frame, err := gobwas.ReadFrame(src)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	if frame.Header.OpCode != gobwas.OpClose {
		t.Fatalf("op = %v, want close", frame.Header.OpCode)
	}
	return gobwas.ParseCloseFrameData(frame.Payload)
}

func validHello(providerID string) map[string]any {
	return map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             providerID,
		"hostname":                "provider.local",
		"model_id":                "mlx-community/Qwen2.5-7B-Instruct-4bit",
		"model_params_b":          7.0,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "0.1.0",
		"attestation":             nil,
	}
}

func validAuthInitial(providerID, providerPublic string) map[string]any {
	h := validHello(providerID)
	h["type"] = "auth_request"
	h["version"] = 2
	h["stage"] = "initial"
	delete(h, "tier")
	delete(h, "attestation")
	h["provider_ecdh_public_key"] = providerPublic
	h["tier2_capabilities"] = map[string]any{
		"encrypted_leg":                     true,
		"attestation":                       true,
		"aead_suites":                       []string{tier2.PillarBAEADA256GCM},
		"response_chunk_plaintext_envelope": true,
		"in_band_aead_rekey_v1":             true,
	}
	return h
}

func validAuthInitialWithFreshKey(t *testing.T, providerID string) map[string]any {
	t.Helper()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	return validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
}

func testIdentityKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("identity key: %v", err)
	}
	return pub, priv, onboarding.ProviderIDForIdentityPubkey(pub)
}

func newIdentitySignatureHarness(t *testing.T, providerID string, store providerws.IdentitySignatureStore, opts ...func(*config.Config)) providerHarness {
	t.Helper()
	return newProviderHarnessWithServerOptions(t, nil, []providerws.Option{providerws.WithIdentitySignatureStore(store)}, func(cfg *config.Config) {
		cfg.Providers[0].ProviderID = providerID
		cfg.Providers[0].EndpointURL = ""
		for _, opt := range opts {
			opt(cfg)
		}
	})
}

func writeIdentityInitial(t *testing.T, serverURL, providerID string) (net.Conn, providerws.AuthChallenge, map[string]any) {
	t.Helper()
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial(providerID, base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(serverURL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		conn.Close()
		t.Fatalf("write auth initial: %v", err)
	}
	return conn, readAuthChallenge(t, conn), initial
}

func signedIdentityProofFields(t *testing.T, priv ed25519.PrivateKey, providerID, authAttemptID string, initial map[string]any) map[string]any {
	t.Helper()
	normalizedInitial := normalizeForJCS(t, initial)
	canonicalInitial, err := billing.CanonicalJSON(normalizedInitial)
	if err != nil {
		t.Fatalf("canonical initial: %v", err)
	}
	transcriptHash := sha256.Sum256(canonicalInitial)
	transcriptB64 := base64.StdEncoding.EncodeToString(transcriptHash[:])
	tuple := map[string]any{
		"auth_attempt_id":          authAttemptID,
		"provider_id":              providerID,
		"binary_version":           normalizedInitial["binary_version"],
		"provider_ecdh_public_key": normalizedInitial["provider_ecdh_public_key"],
		"transcript_sha256":        transcriptB64,
	}
	canonicalTuple, err := billing.CanonicalJSON(tuple)
	if err != nil {
		t.Fatalf("canonical tuple: %v", err)
	}
	return map[string]any{
		"identity_signature":                   base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonicalTuple)),
		"identity_signature_transcript_sha256": transcriptB64,
	}
}

func signedCredentialBootstrapProofFields(
	t *testing.T,
	priv ed25519.PrivateKey,
	providerID string,
	challenge providerws.AuthChallenge,
	initial map[string]any,
) map[string]any {
	t.Helper()
	normalizedInitial := normalizeForJCS(t, initial)
	canonicalInitial, err := billing.CanonicalJSON(normalizedInitial)
	if err != nil {
		t.Fatalf("canonical bootstrap initial: %v", err)
	}
	transcriptHash := sha256.Sum256(canonicalInitial)
	transcriptB64 := base64.StdEncoding.EncodeToString(transcriptHash[:])
	challengeRaw, err := json.Marshal(challenge)
	if err != nil {
		t.Fatalf("marshal bootstrap challenge: %v", err)
	}
	var challengeWire map[string]any
	dec := json.NewDecoder(bytes.NewReader(challengeRaw))
	dec.UseNumber()
	if err := dec.Decode(&challengeWire); err != nil {
		t.Fatalf("normalize bootstrap challenge: %v", err)
	}
	tuple := map[string]any{
		"challenge":                challengeWire,
		"auth_attempt_id":          challenge.AuthAttemptID,
		"provider_id":              providerID,
		"binary_version":           normalizedInitial["binary_version"],
		"provider_ecdh_public_key": normalizedInitial["provider_ecdh_public_key"],
		"transcript_sha256":        transcriptB64,
		"credential_bootstrap":     true,
	}
	canonicalTuple, err := billing.CanonicalJSON(tuple)
	if err != nil {
		t.Fatalf("canonical bootstrap tuple: %v", err)
	}
	return map[string]any{
		"credential_bootstrap":                 true,
		"identity_signature":                   base64.StdEncoding.EncodeToString(ed25519.Sign(priv, canonicalTuple)),
		"identity_signature_transcript_sha256": transcriptB64,
	}
}

func normalizeForJCS(t *testing.T, in map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal normalize: %v", err)
	}
	var out map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&out); err != nil {
		t.Fatalf("decode normalize: %v", err)
	}
	return out
}

type fakeIdentitySignatureStore struct {
	policyOK       bool
	exemptUntil    *time.Time
	grantedBy      string
	identityPubkey []byte
	identityOK     bool
}

func (f *fakeIdentitySignatureStore) LookupProviderAuthPolicy(ctx context.Context, providerID string) (*time.Time, string, bool, error) {
	return f.exemptUntil, f.grantedBy, f.policyOK, nil
}

func (f *fakeIdentitySignatureStore) LookupProviderIdentityPubkey(ctx context.Context, providerID string) ([]byte, bool, error) {
	return append([]byte(nil), f.identityPubkey...), f.identityOK, nil
}

func assertInitialCatalogRejectedWithLockedSubstring(t *testing.T, initial map[string]any, substring string) {
	t.Helper()
	h := newProviderHarness(t, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	response := readAuthResponse(t, conn)
	if response.Status != "rejected" || response.Error == nil || response.Error.Code != "bad_request" {
		t.Fatalf("auth_response = %+v", response)
	}
	if !strings.Contains(response.Error.Message, substring) {
		t.Fatalf("error message = %q, want substring %q", response.Error.Message, substring)
	}
	frame, err := gobwas.ReadFrame(conn)
	if err != nil {
		t.Fatalf("read close: %v", err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if code != providerws.CloseInvalidHello {
		t.Fatalf("close code = %d, want %d", code, providerws.CloseInvalidHello)
	}
	if !strings.Contains(reason, substring) {
		t.Fatalf("close reason = %q, want substring %q", reason, substring)
	}
}

func dialAndAuthV2Provider(t *testing.T, h providerHarness) (net.Conn, string) {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	_, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		conn.Close()
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		conn.Close()
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		conn.Close()
		t.Fatalf("auth_response = %+v", response)
	}
	return conn, challenge.AssignedID
}

func writeStateUpdate(t *testing.T, conn net.Conn, state string) {
	t.Helper()
	msg := map[string]any{
		"type":   "state_update",
		"state":  state,
		"reason": "test state update",
		"since":  "2026-06-22T00:00:00Z",
		"metrics_snapshot": map[string]any{
			"slots_free":  1,
			"slots_total": 1,
		},
	}
	if err := wsutil.WriteClientText(conn, mustJSON(msg)); err != nil {
		t.Fatalf("write state_update: %v", err)
	}
}

func authV2ProviderWithReceiptKey(t *testing.T, serverURL string, receiptPubkey []byte) net.Conn {
	t.Helper()
	conn, response := authV2ProviderWithReceiptKeyExpectResponse(t, serverURL, receiptPubkey)
	if response.Status != "accepted" {
		conn.Close()
		t.Fatalf("auth_response = %+v", response)
	}
	return conn
}

func authV2ProviderWithReceiptKeyExpectResponse(t *testing.T, serverURL string, receiptPubkey []byte) (net.Conn, providerws.AuthResponse) {
	t.Helper()
	return authV2ProviderWithReceiptKeyExpectResponseAndMaybeStateUpdate(t, serverURL, receiptPubkey, true)
}

func authV2ProviderWithReceiptKeyExpectResponseAndMaybeStateUpdate(t *testing.T, serverURL string, receiptPubkey []byte, sendStateUpdate bool) (net.Conn, providerws.AuthResponse) {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(serverURL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["provider_receipt_public_key"] = base64.StdEncoding.EncodeToString(receiptPubkey)
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		conn.Close()
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status == "accepted" && response.AssignedID != challenge.AssignedID {
		conn.Close()
		t.Fatalf("auth_response assigned_id = %q, want %q", response.AssignedID, challenge.AssignedID)
	}
	if response.Status == "accepted" && sendStateUpdate {
		writeStateUpdate(t, conn, "ready")
	}
	return conn, response
}

type buyerRekeyEncryptedCarrier struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id"`
	Stream    bool                   `json:"stream"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

func authenticateBuyerRekeyProvider(t *testing.T, h providerHarness) (net.Conn, string, tier2.PillarBKeyMaterial) {
	t.Helper()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial provider: %v", err)
	}
	providerPrivate, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		conn.Close()
		t.Fatalf("provider keypair: %v", err)
	}
	initial := validAuthInitial("m4-anon", base64.RawURLEncoding.EncodeToString(providerPublicRaw))
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		conn.Close()
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	coordinatorPublic, coordinatorPublicRaw, err := tier2.ParseX25519PublicKey(challenge.CoordinatorECDHPublicKey)
	if err != nil {
		conn.Close()
		t.Fatalf("parse coordinator public key: %v", err)
	}
	shared, err := providerPrivate.ECDH(coordinatorPublic)
	if err != nil {
		conn.Close()
		t.Fatalf("provider ECDH: %v", err)
	}
	epoch, err := tier2.DerivePillarBKeysFromSharedSecret(shared, "m4-anon", challenge.AssignedID, providerPublicRaw, coordinatorPublicRaw, challenge.SelectedAEADSuite)
	if err != nil {
		conn.Close()
		t.Fatalf("derive provider epoch: %v", err)
	}
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	response := readAuthResponse(t, conn)
	if response.Status != "accepted" || response.AssignedID != challenge.AssignedID {
		conn.Close()
		t.Fatalf("auth response = %+v", response)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(heartbeat())); err != nil {
		conn.Close()
		t.Fatalf("write ready heartbeat: %v", err)
	}
	eventually(t, func() bool {
		provider, ok := h.Registry.Resolve("m4-anon", challenge.AssignedID)
		return ok && provider.State == pool.StateReady && provider.SlotsFree == 1 && provider.Tier2Session != nil
	})
	return conn, challenge.AssignedID, epoch
}

func serveBuyerInferenceOverEpoch(conn net.Conn, providerID, assignedID string, epoch tier2.PillarBKeyMaterial, expectedC2PSeq uint64) error {
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		return fmt.Errorf("read inference request: %w", err)
	}
	if op != gobwas.OpText {
		return fmt.Errorf("inference request opcode = %v", op)
	}
	var request buyerRekeyEncryptedCarrier
	if err := json.Unmarshal(payload, &request); err != nil {
		return fmt.Errorf("decode inference request: %w", err)
	}
	if request.Type != "inference_request" || request.RequestID == "" || !request.Encrypted || request.Stream {
		return fmt.Errorf("invalid inference request carrier: %+v", request)
	}
	aad, _, err := tier2.DecodeAEADAAD(request.Enc.AAD)
	if err != nil {
		return fmt.Errorf("decode inference request aad: %w", err)
	}
	if aad.Seq != expectedC2PSeq || aad.RequestID != request.RequestID || aad.AssignedID != assignedID {
		return fmt.Errorf("inference request aad = %+v, want seq=%d assigned=%s", aad, expectedC2PSeq, assignedID)
	}
	if _, err := tier2.OpenPillarBFrame(epoch.C2PKey, epoch.C2PNonceBase, epoch.KeyID, expectedC2PSeq, aad, tier2.AEADEnvelope{Encrypted: true, Enc: request.Enc}); err != nil {
		return fmt.Errorf("open inference request: %w", err)
	}

	completion := `{"id":"chatcmpl-rekey","object":"chat.completion","created":1,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`
	chunkPlaintext, err := json.Marshal(map[string]any{
		"type": "inference_response_chunk_plaintext",
		"seq":  0,
		"data": completion,
	})
	if err != nil {
		return err
	}
	chunkAAD := tier2.AEADFrameAAD{
		Type: "inference_response_chunk", Direction: "p2c", RequestID: request.RequestID,
		ProviderID: providerID, AssignedID: assignedID, Seq: expectedC2PSeq,
	}
	chunkEnvelope, err := tier2.SealPillarBFrame(epoch.P2CKey, epoch.P2CNonceBase, epoch.KeyID, expectedC2PSeq, chunkAAD, chunkPlaintext)
	if err != nil {
		return fmt.Errorf("seal inference chunk: %w", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(map[string]any{
		"type": "inference_response_chunk", "request_id": request.RequestID,
		"encrypted": true, "enc": chunkEnvelope.Enc,
	})); err != nil {
		return fmt.Errorf("write inference chunk: %w", err)
	}

	endSeq := expectedC2PSeq + 1
	end := providerws.InferenceResponseEnd{
		Type: "inference_response_end", RequestID: request.RequestID, Status: "complete", ChunksSent: 1,
		Usage: json.RawMessage(`{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}`),
	}
	endAAD := tier2.AEADFrameAAD{
		Type: "inference_response_end", Direction: "p2c", RequestID: request.RequestID,
		ProviderID: providerID, AssignedID: assignedID, Seq: endSeq,
	}
	endEnvelope, err := tier2.SealPillarBFrame(epoch.P2CKey, epoch.P2CNonceBase, epoch.KeyID, endSeq, endAAD, mustJSON(end))
	if err != nil {
		return fmt.Errorf("seal inference end: %w", err)
	}
	if err := wsutil.WriteClientText(conn, mustJSON(map[string]any{
		"type": "inference_response_end", "request_id": request.RequestID,
		"encrypted": true, "enc": endEnvelope.Enc,
	})); err != nil {
		return fmt.Errorf("write inference end: %w", err)
	}
	return nil
}

func completeBuyerTestRekey(conn net.Conn, providerID, assignedID string, started chan<- struct{}, allow <-chan struct{}) (tier2.PillarBKeyMaterial, error) {
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("read rekey request: %w", err)
	}
	if op != gobwas.OpText {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("rekey request opcode = %v", op)
	}
	var request providerws.AEADRekeyRequest
	if err := json.Unmarshal(payload, &request); err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("decode rekey request: %w", err)
	}
	if request.Type != "aead_rekey_request" || request.AssignedID != assignedID || request.OldKID == "" {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("invalid rekey request: %+v", request)
	}
	close(started)
	<-allow
	coordinatorPublic, coordinatorPublicRaw, err := tier2.ParseX25519PublicKey(request.CoordinatorECDHPublicKey)
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("parse rekey coordinator key: %w", err)
	}
	providerPrivate, providerPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("generate rekey provider key: %w", err)
	}
	shared, err := providerPrivate.ECDH(coordinatorPublic)
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("derive rekey shared secret: %w", err)
	}
	next, err := tier2.DerivePillarBKeysFromSharedSecret(shared, providerID, assignedID, providerPublicRaw, coordinatorPublicRaw, request.SelectedAEAD)
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("derive rekey epoch: %w", err)
	}
	response := providerws.AEADRekeyResponse{
		Type: "aead_rekey_response", Version: 1, RekeyID: request.RekeyID,
		AssignedID: assignedID, OldKID: request.OldKID, NewKID: next.KeyID,
		ProviderECDHPublicKey: base64.RawURLEncoding.EncodeToString(providerPublicRaw),
	}
	if err := wsutil.WriteClientText(conn, mustJSON(response)); err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("write rekey response: %w", err)
	}
	commitPayload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("read rekey commit: %w", err)
	}
	var commit providerws.AEADRekeyConfirmation
	if err := json.Unmarshal(commitPayload, &commit); err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("decode rekey commit: %w", err)
	}
	commitAAD := tier2.AEADFrameAAD{
		Type: "aead_rekey_commit", Direction: "c2p", RequestID: request.RekeyID,
		ProviderID: providerID, AssignedID: assignedID, Seq: 0,
	}
	proof, err := tier2.OpenPillarBFrame(next.C2PKey, next.C2PNonceBase, next.KeyID, 0, commitAAD, tier2.AEADEnvelope{Encrypted: true, Enc: commit.Enc})
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("open rekey commit: %w", err)
	}
	committedAAD := tier2.AEADFrameAAD{
		Type: "aead_rekey_committed", Direction: "p2c", RequestID: request.RekeyID,
		ProviderID: providerID, AssignedID: assignedID, Seq: 0,
	}
	committedEnvelope, err := tier2.SealPillarBFrame(next.P2CKey, next.P2CNonceBase, next.KeyID, 0, committedAAD, proof)
	if err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("seal rekey committed: %w", err)
	}
	committed := providerws.AEADRekeyConfirmation{
		Type: "aead_rekey_committed", Version: 1, RekeyID: request.RekeyID,
		AssignedID: assignedID, OldKID: request.OldKID, NewKID: next.KeyID,
		Encrypted: true, Enc: committedEnvelope.Enc,
	}
	if err := wsutil.WriteClientText(conn, mustJSON(committed)); err != nil {
		return tier2.PillarBKeyMaterial{}, fmt.Errorf("write rekey committed: %w", err)
	}
	return next, nil
}

func postBuyerRekeyChat(server *buyer.Server) *httptest.ResponseRecorder {
	body := `{"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","messages":[{"role":"user","content":"hello"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func signalingBuyerRekeyRelay(relay buyer.RelayFunc, entered chan<- struct{}) buyer.RelayFunc {
	return func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
		entered <- struct{}{}
		return relay(ctx, provider, requestID, body, stream)
	}
}

func assertBuyerRekeySuccess(t *testing.T, response *httptest.ResponseRecorder, assignedID string) {
	t.Helper()
	if response.Code != http.StatusOK || !bytes.Contains(response.Body.Bytes(), []byte(`"content":"ok"`)) {
		t.Fatalf("buyer response status=%d body=%s, want successful completion", response.Code, response.Body.String())
	}
	if got := response.Header().Get("X-MacProvider-Provider"); got != "m4-anon" {
		t.Fatalf("buyer provider header = %q, want m4-anon", got)
	}
	if got := response.Header().Get("X-MacProvider-Route"); got != assignedID {
		t.Fatalf("buyer route header = %q, want %q", got, assignedID)
	}
	if bytes.Contains(response.Body.Bytes(), []byte("no_provider_available")) {
		t.Fatalf("buyer response crossed a no-provider gap: %s", response.Body.String())
	}
}

func assertProviderEpochChanged(t *testing.T, registry *pool.Registry, assignedID, oldKID string) {
	t.Helper()
	provider, ok := registry.Resolve("m4-anon", assignedID)
	if !ok || provider.Tier2Session == nil || provider.Tier2Session.KeyID == "" || provider.Tier2Session.KeyID == oldKID {
		t.Fatalf("provider epoch after rekey = %#v ok=%v, want a new KID", provider.Tier2Session, ok)
	}
}

func assertProviderRemainsReadyDuringRekey(t *testing.T, registry *pool.Registry, assignedID string) {
	t.Helper()
	provider, ok := registry.Resolve("m4-anon", assignedID)
	if !ok || provider.AssignedID != assignedID || provider.State != pool.StateReady {
		t.Fatalf("sole provider during rekey = %#v ok=%v, want same assigned ready provider", provider, ok)
	}
}

type lockedTime struct {
	mu  sync.Mutex
	now time.Time
}

func newLockedTime(now time.Time) *lockedTime {
	return &lockedTime{now: now}
}

func (l *lockedTime) Now() time.Time {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.now
}

func (l *lockedTime) Set(now time.Time) {
	l.mu.Lock()
	l.now = now
	l.mu.Unlock()
}

func readAuthChallenge(t *testing.T, conn net.Conn) providerws.AuthChallenge {
	t.Helper()
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read auth_challenge: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("auth_challenge op = %v, want text", op)
	}
	var challenge providerws.AuthChallenge
	if err := json.Unmarshal(payload, &challenge); err != nil {
		t.Fatalf("auth_challenge json: %v", err)
	}
	if challenge.Type != "auth_challenge" || challenge.Version != 2 {
		t.Fatalf("auth_challenge envelope = %+v", challenge)
	}
	return challenge
}

func writeAuthProof(t *testing.T, conn net.Conn, challenge providerws.AuthChallenge, providerID string, token json.RawMessage) {
	t.Helper()
	writeAuthProofWithFields(t, conn, challenge, providerID, token, nil)
}

func writeAuthProofWithFields(t *testing.T, conn net.Conn, challenge providerws.AuthChallenge, providerID string, token json.RawMessage, fields map[string]any) {
	t.Helper()
	proof := map[string]any{
		"type":              "auth_request",
		"version":           2,
		"stage":             "proof",
		"auth_attempt_id":   challenge.AuthAttemptID,
		"provider_id":       providerID,
		"attestation_token": token,
	}
	for key, value := range fields {
		proof[key] = value
	}
	if err := wsutil.WriteClientText(conn, mustJSON(proof)); err != nil {
		t.Fatalf("write auth proof: %v", err)
	}
}

func readAuthResponse(t *testing.T, conn net.Conn) providerws.AuthResponse {
	t.Helper()
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read auth_response: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("auth_response op = %v, want text", op)
	}
	var response providerws.AuthResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		t.Fatalf("auth_response json: %v", err)
	}
	if response.Type != "auth_response" || response.Version != 2 {
		t.Fatalf("auth_response envelope = %+v", response)
	}
	return response
}

func heartbeat() map[string]any {
	return map[string]any{
		"type":                       "heartbeat",
		"status":                     "ready",
		"model_id":                   "mlx-community/Qwen2.5-7B-Instruct-4bit",
		"model_params_b":             7.0,
		"ram_gb":                     16,
		"max_context_tokens":         50000,
		"max_concurrency":            1,
		"slots_free":                 1,
		"slots_total":                1,
		"throughput_tps_estimate":    19.8,
		"requests_served_since_last": 1,
		"avg_latency_ms_since_last":  450.0,
		"throughput_tps_since_last":  18.5,
	}
}

func eventually(t *testing.T, f func() bool) {
	t.Helper()
	eventuallyWithin(t, 2*time.Second, f)
}

func eventuallyWithin(t *testing.T, timeout time.Duration, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		if f() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("condition did not become true before deadline")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// consistently asserts f() holds true continuously across the window. Used to
// prove the observe-only warm-up probe (#1354) never transitions a routable
// provider out of ready as a delayed side effect.
func consistently(t *testing.T, window time.Duration, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(window)
	for {
		if !f() {
			t.Fatal("condition did not hold for the full window")
		}
		if time.Now().After(deadline) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func authAttemptCount(t *testing.T, server *providerws.Server) int {
	t.Helper()
	return server.AuthAttemptCount()
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func wsURL(httpURL string) string {
	return "ws" + strings.TrimPrefix(httpURL, "http") + "/ws/provider"
}
