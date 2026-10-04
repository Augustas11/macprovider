package router

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func privacyReservationFixture(t *testing.T, stream bool) relayblind.ReservationResponse {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, identity, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	notBefore := fixedNow().Add(-time.Minute)
	expires := notBefore.Add(time.Duration(relayblind.MaxPrivacyKeyLifetimeSeconds) * time.Second)
	record, err := relayblind.NewSignedKeyRecord(key.PublicKey().Bytes(), identity, []string{"test-model"}, 4096, notBefore, expires)
	if err != nil {
		t.Fatal(err)
	}
	random := func() string {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	res := relayblind.ReservationResponse{
		Version: relayblind.PrivacyReservationVersion, ProviderBinding: random(), BuyerBinding: random(),
		KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
		EndpointFamily: "chat_completions", Model: "test-model", ProviderModel: "test-model", Stream: stream,
		MaxEncryptedRequestBytes: 4096, MaxOutputTokens: 8, InputTokenUpperBound: 16, ReservationTokenCap: 24,
		ExpiresAtUnix: fixedNow().Add(30 * time.Second).Unix(), CachePolicy: "no-store", FailoverPolicy: "disabled",
		PrivacyClass: relayblind.PrivacyClassV1, PrivacyAssurance: relayblind.PrivacyAssurance,
		PrivacyKeyAttestation: &relayblind.PrivacyKeyAttestation{
			Version: relayblind.PrivacyKeyAttestationVersion, KeyRecordDigest: record.KeyRecordDigest,
			PrivacyClass: relayblind.PrivacyClassV1, Assurance: relayblind.PrivacyAssurance,
			BinaryVersion: "1.2.3", CodeCDHash: "0123456789abcdef0123456789abcdef01234567",
			NotBeforeUnix: record.NotBeforeUnix, ExpiresAtUnix: record.ExpiresAtUnix,
		},
		PrivacyKeyAttestationSignature: base64.RawURLEncoding.EncodeToString(make([]byte, ed25519.SignatureSize)),
		PrivacyPostureVerifiedAtUnix:   fixedNow().Add(-5 * time.Second).Unix(),
	}
	if err := res.Validate(); err != nil {
		t.Fatal(err)
	}
	return res
}

func privacyReservationBody(t *testing.T, res relayblind.ReservationResponse) []byte {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"endpoint_family": "chat_completions", "model": res.Model, "stream": res.Stream,
		"max_output_tokens": res.MaxOutputTokens, "input_token_upper_bound": res.InputTokenUpperBound,
		"encrypted_request_bytes": 128,
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func enablePrivacy(c *config.Config) {
	c.Features.RelayBlindRequests.Enabled = true
	c.Features.PrivacyClass.Enabled = true
}

const privacyCoordinatorVerifiedAt int64 = 1_700_000_001

func setPrivacyChatEcho(w http.ResponseWriter, verifiedAt int64) {
	w.Header().Set(privacyClassHeader, privacyClassV1)
	w.Header().Set(privacyPostureVerifiedAtHeader, strconv.FormatInt(verifiedAt, 10))
}

type privacyHop struct {
	path, account, exec, assurance, providerID, engine, posture string
	privacy                                                     []string
}

type privacyHopLog struct {
	mu   sync.Mutex
	hops []privacyHop
}

func (l *privacyHopLog) add(r *http.Request) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.hops = append(l.hops, privacyHop{
		path: r.URL.Path, account: r.Header.Get("X-MacProvider-Account"),
		exec: r.Header.Get(relayBlindExecutionHeader), assurance: r.Header.Get(privacyAssuranceHeader),
		providerID: r.Header.Get("X-Provider-Id"), engine: r.Header.Get("X-MacProvider-Internal-Engine"),
		posture: r.Header.Get(privacyPostureVerifiedAtHeader),
		privacy: append([]string(nil), r.Header.Values(privacyClassHeader)...),
	})
}

func (l *privacyHopLog) snapshot() []privacyHop {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]privacyHop, len(l.hops))
	copy(out, l.hops)
	return out
}

func privacyCoordinator(t *testing.T, res relayblind.ReservationResponse, raw []byte, onChat func(http.ResponseWriter, *http.Request)) (*httptest.Server, *privacyHopLog) {
	t.Helper()
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	log := &privacyHopLog{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.add(r)
		if r.Header.Get("Authorization") != "Bearer service-token" {
			t.Errorf("upstream auth %q", r.Header.Get("Authorization"))
		}
		switch r.URL.Path {
		case "/v1/relay-blind/route-reservations":
			json.NewEncoder(w).Encode(res)
		case "/v1/relay-blind/consume":
			json.NewEncoder(w).Encode(relayblind.ConsumeResponse{
				Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding,
				EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization",
				ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix,
			})
		case "/v1/chat/completions":
			onChat(w, r)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, log
}

func postPrivacy(h http.Handler, key, path string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+key)
	for name, value := range headers {
		r.Header.Set(name, value)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func privacyChatHeaders() map[string]string {
	return map[string]string{
		"X-Request-ID":                  "123e4567-e89b-42d3-a456-426614174088",
		privacyClassHeader:              privacyClassV1,
		privacyPostureVerifiedAtHeader:  "1",
		privacyAssuranceHeader:          "injected",
		"X-Provider-Id":                 "leaked",
		"X-MacProvider-Internal-Engine": "injected",
		"X-MacProvider-Account":         "spoof-account",
		relayBlindExecutionHeader:       "spoofed",
	}
}

func assertPrivacyError(t *testing.T, raw string, status int, code, retryAction, message string) {
	t.Helper()
	var body struct {
		Error struct {
			Code        string `json:"code"`
			Message     string `json:"message"`
			Type        string `json:"type"`
			Retryable   bool   `json:"retryable"`
			RetryAction string `json:"retry_action"`
			Macprovider struct {
				RetryAction string `json:"retry_action"`
			} `json:"macprovider"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		t.Fatalf("error json: %v body=%s", err, raw)
	}
	if body.Error.Code != code || body.Error.RetryAction != retryAction || body.Error.Macprovider.RetryAction != retryAction {
		t.Fatalf("code=%s retry=%s mac=%s want %s %s body=%s", body.Error.Code, body.Error.RetryAction, body.Error.Macprovider.RetryAction, code, retryAction, raw)
	}
	if message != "" && body.Error.Message != message {
		t.Fatalf("message=%q want %q", body.Error.Message, message)
	}
	wantType := "api_error"
	if status == http.StatusBadRequest {
		wantType = "invalid_request_error"
	}
	if body.Error.Type != wantType {
		t.Fatalf("type=%s want %s", body.Error.Type, wantType)
	}
	if body.Error.Retryable != (retryAction == "new_reservation_and_envelope") {
		t.Fatalf("retryable=%v action=%s", body.Error.Retryable, retryAction)
	}
}

func TestPrivacyClassConstantsMatchSharedPackage(t *testing.T) {
	if privacyClassV1 != relayblind.PrivacyClassV1 || privacyAssuranceV1 != relayblind.PrivacyAssurance || privacyResponseEncryptionV1 != relayblind.PrivacyResponseEncryption {
		t.Fatal("R020 short tokens drifted from relayblind")
	}
	if len(privacyProtects) != 9 || len(privacyDoesNotProtect) != 6 || len(privacyResidualRisks) != 11 {
		t.Fatalf("list lengths protects=%d does_not=%d residual=%d", len(privacyProtects), len(privacyDoesNotProtect), len(privacyResidualRisks))
	}
	copied := privacyUsageMetadata(7)
	copied.Protects[0] = "mutated"
	if privacyProtects[0] == "mutated" {
		t.Fatal("usage lists alias the package slices")
	}
}

func TestPrivacyDefaultOffOmitsDisclosure(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	key := createAccountAndKey(t, store, cfg, "privacy-default-off")
	r := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	r.Header.Set("Authorization", "Bearer "+key)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	if strings.Contains(w.Body.String(), "operator_constrained_privacy") || strings.Contains(w.Body.String(), "relay_blind_request_encryption") {
		t.Fatalf("default-off disclosure leaked: %s", w.Body.String())
	}

	t.Run("relay-blind on privacy off", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/v1/models":
				io.WriteString(w, `{"object":"list","data":[{"id":"test-model","object":"model"}]}`)
			case "/v1/relay-blind/capabilities":
				io.WriteString(w, `{"version":"relay-blind-capabilities-v1","models":{"test-model":{"capable_provider_count":2,"incapable_provider_count":1}},"privacy_class":{"enabled":true,"models":{"test-model":{"capable_provider_count":4,"incapable_provider_count":1},"hidden-model":{"capable_provider_count":9,"incapable_provider_count":0}}}}`)
			default:
				w.WriteHeader(http.StatusNotFound)
			}
		}))
		defer upstream.Close()
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			c.Features.RelayBlindRequests.Enabled = true
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-off-relay-on")
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+key)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != http.StatusOK {
			t.Fatalf("status %d body %s", resp.Code, resp.Body.String())
		}
		if strings.Contains(resp.Body.String(), "operator_constrained_privacy") || strings.Contains(resp.Body.String(), "hidden-model") {
			t.Fatalf("privacy disclosure leaked: %s", resp.Body.String())
		}
		var parsed struct {
			Data []struct {
				RelayBlind json.RawMessage `json:"relay_blind_request_encryption"`
			} `json:"data"`
			Tier1 struct {
				RelayBlind *relayBlindRequestEncryptionDisclosure `json:"relay_blind_request_encryption"`
			} `json:"tier1_disclosure"`
		}
		if err := json.Unmarshal(resp.Body.Bytes(), &parsed); err != nil {
			t.Fatal(err)
		}
		if parsed.Tier1.RelayBlind == nil || parsed.Tier1.RelayBlind.EndpointFamilies["chat_completions"].RequiredMode != "available" {
			t.Fatalf("relay-blind disclosure missing: %s", resp.Body.String())
		}
		if len(parsed.Data) != 1 || !bytes.Contains(parsed.Data[0].RelayBlind, []byte(`"capable_provider_count":2`)) {
			t.Fatalf("per-model relay-blind disclosure: %s", resp.Body.String())
		}
	})
}

func TestPrivacyModelsDisclosureCounts(t *testing.T) {
	payload := `{"version":"relay-blind-capabilities-v1","models":{"test-model":{"capable_provider_count":1,"incapable_provider_count":0}},"privacy_class":{"enabled":true,"models":{"test-model":{"capable_provider_count":3,"incapable_provider_count":2},"hidden-model":{"capable_provider_count":8,"incapable_provider_count":1},"bad-model":{"capable_provider_count":-1,"incapable_provider_count":0}}}}`
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/models":
			io.WriteString(w, `{"object":"list","data":[{"id":"test-model","object":"model"},{"id":"bad-model","object":"model"}]}`)
		case "/v1/relay-blind/capabilities":
			io.WriteString(w, payload)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-models")
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+key)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status %d %s", resp.Code, resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "hidden-model") {
		t.Fatalf("hidden model leaked: %s", resp.Body.String())
	}
	var parsed struct {
		Tier1 struct {
			Privacy *operatorConstrainedPrivacyDisclosure `json:"operator_constrained_privacy"`
		} `json:"tier1_disclosure"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &parsed); err != nil {
		t.Fatal(err)
	}
	got := parsed.Tier1.Privacy
	if got == nil {
		t.Fatalf("missing disclosure: %s", resp.Body.String())
	}
	if got.Version != privacyDisclosureVersion || got.Class != privacyClassV1 || got.Assurance != privacyAssuranceV1 || got.Scope != privacyScope {
		t.Fatalf("disclosure identity: %+v", got)
	}
	if !reflect.DeepEqual(got.Protects, privacyProtects) || !reflect.DeepEqual(got.DoesNotProtect, privacyDoesNotProtect) || !reflect.DeepEqual(got.ResidualRisks, privacyResidualRisks) {
		t.Fatal("disclosure lists drifted")
	}
	if len(got.Models) != 1 || got.Models["test-model"].CapableProviderCount != 3 || got.Models["test-model"].IncapableProviderCount != 2 {
		t.Fatalf("counts: %+v", got.Models)
	}
	if _, ok := got.Models["bad-model"]; ok {
		t.Fatal("invalid counts were published")
	}
}

func TestPrivacyHeaderWithPlaintextBodyRejected(t *testing.T) {
	var chats int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/chat/completions" {
			chats++
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-plaintext")
	body := []byte(`{"model":"test-model","messages":[{"role":"user","content":"hello"}]}`)
	resp := postPrivacy(h, key, "/v1/chat/completions", body, map[string]string{privacyClassHeader: privacyClassV1})
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status %d %s", resp.Code, resp.Body.String())
	}
	assertPrivacyError(t, resp.Body.String(), http.StatusBadRequest, privacyClassDowngrade, "none", privacyPlaintextDowngradeText)
	if chats != 0 {
		t.Fatalf("upstream chats=%d", chats)
	}
	assertNoDailyUsage(t, store, "privacy-plaintext")
}

func TestPrivacyHeaderForwardedToCoordinatorOnAllHops(t *testing.T) {
	res := privacyReservationFixture(t, false)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	upstream, log := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(settlementModeHeader, "observe")
		io.WriteString(w, `{"object":"macprovider.privacy_response","frames":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`)
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-hops")
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{privacyClassHeader: privacyClassV1})
	if reserve.Code != http.StatusOK {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
	if chat.Code != http.StatusOK {
		t.Fatalf("chat %d %s", chat.Code, chat.Body.String())
	}
	hops := log.snapshot()
	if len(hops) != 3 {
		t.Fatalf("hops %+v", hops)
	}
	for _, hop := range hops {
		if len(hop.privacy) != 1 || hop.privacy[0] != privacyClassV1 {
			t.Fatalf("hop %s privacy=%q", hop.path, hop.privacy)
		}
		if hop.account != "privacy-hops" || hop.assurance != "" || hop.providerID != "" || hop.engine != "" || hop.posture != "" {
			t.Fatalf("hop leaked %+v", hop)
		}
	}
	if hops[2].exec != "internal-execution-authorization" || hops[0].exec != "" || hops[1].exec != "" {
		t.Fatalf("execution headers %+v", hops)
	}
	if chat.Header().Get(privacyPostureVerifiedAtHeader) != "" {
		t.Fatalf("internal posture header reached the buyer: %q", chat.Header().Get(privacyPostureVerifiedAtHeader))
	}
}

func TestBuyerSuppliedInternalHeadersStillStripped(t *testing.T) {
	res := privacyReservationFixture(t, false)
	raw := pilotEnvelopeFixture(t, res)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	upstream, log := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(relayBlindValidatedHeader, digestText)
		setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
		w.Header().Set(settlementModeHeader, "observe")
		io.WriteString(w, `{"object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
	})
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-strip")
	headers := privacyChatHeaders()
	headers[privacyClassHeader] = privacyClassV1
	reserveHeaders := map[string]string{
		privacyClassHeader: privacyClassV1, privacyAssuranceHeader: "injected",
		privacyPostureVerifiedAtHeader: "1",
		"X-Provider-Id":                "leaked", "X-MacProvider-Internal-Engine": "injected",
		"X-MacProvider-Account": "spoof-account", relayBlindExecutionHeader: "spoofed",
	}
	injected := http.Header{}
	injected.Set(privacyPostureVerifiedAtHeader, "42")
	injected.Add(privacyPostureVerifiedAtHeader, "43")
	if stripped := stripInternalMacProviderHeaders(injected); len(stripped) != 1 || !strings.EqualFold(stripped[0], privacyPostureVerifiedAtHeader) || injected.Get(privacyPostureVerifiedAtHeader) != "" {
		t.Fatalf("ingress strip %v remaining %q", stripped, injected.Get(privacyPostureVerifiedAtHeader))
	}
	reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), reserveHeaders)
	if reserve.Code != http.StatusOK {
		t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
	}
	chat := postPrivacy(h, key, "/v1/chat/completions", raw, headers)
	if chat.Code != http.StatusOK {
		t.Fatalf("chat %d %s", chat.Code, chat.Body.String())
	}
	for _, hop := range log.snapshot() {
		if hop.account == "spoof-account" || hop.assurance != "" || hop.providerID != "" || hop.engine != "" || hop.exec == "spoofed" || hop.posture != "" {
			t.Fatalf("buyer header forwarded: %+v", hop)
		}
	}
}

func TestPrivacyUnconfirmedIsDoNotResubmit(t *testing.T) {
	for _, tc := range []struct {
		name, account string
		class         []string
		posture       []string
		stream        bool
	}{
		{name: "missing echo", account: "privacy-unconfirmed", posture: []string{"1700000001"}},
		{name: "missing posture", account: "privacy-unposted", class: []string{privacyClassV1}},
		{name: "duplicate posture", account: "privacy-duplicate-posture", class: []string{privacyClassV1}, posture: []string{"1700000001", "1700000002"}},
		{name: "zero posture", account: "privacy-zero-posture", class: []string{privacyClassV1}, posture: []string{"0"}},
		{name: "negative posture", account: "privacy-negative-posture", class: []string{privacyClassV1}, posture: []string{"-5"}},
		{name: "noncanonical posture", account: "privacy-padded-posture", class: []string{privacyClassV1}, posture: []string{"01"}},
		{name: "list posture", account: "privacy-list-posture", class: []string{privacyClassV1}, posture: []string{"1700000001,1700000002"}},
		{name: "missing echo stream", account: "privacy-unconfirmed-stream", posture: []string{"1700000001"}, stream: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := privacyReservationFixture(t, tc.stream)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set(relayBlindValidatedHeader, digestText)
				w.Header().Set(settlementModeHeader, "observe")
				for _, value := range tc.class {
					w.Header().Add(privacyClassHeader, value)
				}
				for _, value := range tc.posture {
					w.Header().Add(privacyPostureVerifiedAtHeader, value)
				}
				if tc.stream {
					io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"CANARY_PRIVACY_BODY\"}}]}\n\ndata: [DONE]\n\n")
					return
				}
				io.WriteString(w, `{"choices":[{"message":{"content":"CANARY_PRIVACY_BODY"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
			})
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, tc.account)
			chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
			if chat.Code != http.StatusInternalServerError {
				t.Fatalf("status %d %s", chat.Code, chat.Body.String())
			}
			assertPrivacyError(t, chat.Body.String(), http.StatusInternalServerError, privacyClassUnconfirmed, "do_not_resubmit", "Privacy class completion was not confirmed")
			if strings.Contains(chat.Body.String(), "CANARY_PRIVACY_BODY") {
				t.Fatalf("body forwarded: %s", chat.Body.String())
			}
			if chat.Header().Get(privacyClassHeader) != "" || chat.Header().Get(privacyAssuranceHeader) != "" || chat.Header().Get(privacyResponseEncryptionHeader) != "" || chat.Header().Get(privacyPostureVerifiedAtHeader) != "" {
				t.Fatalf("success headers on error: %v", chat.Header())
			}
			used, held, err := store.DailyUsage(context.Background(), tc.account, fixedNow().Format("2006-01-02"))
			if err != nil || used != 0 || held != 24 {
				t.Fatalf("used=%d held=%d err=%v", used, held, err)
			}
		})
	}
}

func TestPrivacyFramesPassThroughVerbatimStreamAndNonStream(t *testing.T) {
	cipherA := strings.Repeat("A", 40000)
	cipherB := strings.Repeat("B", 40000)
	frame := func(seq int, final bool, cipher string) string {
		raw, err := json.Marshal(map[string]any{
			"object": relayblind.PrivacyFrameObject, "version": "privacy-response-v1",
			"seq": seq, "final": final, "ciphertext": cipher,
		})
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	frame0 := frame(0, false, cipherA)
	frame1 := frame(1, true, cipherB)
	framesRaw := "[" + frame0 + "," + frame1 + "]"

	t.Run("stream", func(t *testing.T) {
		res := privacyReservationFixture(t, true)
		raw := pilotEnvelopeFixture(t, res)
		digest := sha256.Sum256(raw)
		digestText := base64.RawURLEncoding.EncodeToString(digest[:])
		upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set(relayBlindValidatedHeader, digestText)
			setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
			w.Header().Set(settlementModeHeader, "observe")
			w.Header().Set("Content-Type", "text/event-stream")
			io.WriteString(w, "data: "+frame0+"\n\ndata: "+frame1+"\n\ndata: {\"object\":\"chat.completion.chunk\",\"model\":\"test-model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6}}\n\ndata: [DONE]\n\n")
		})
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-frames-stream")
		reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{privacyClassHeader: privacyClassV1})
		if reserve.Code != http.StatusOK {
			t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
		}
		chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
		if chat.Code != http.StatusOK {
			t.Fatalf("status %d %s", chat.Code, chat.Body.String())
		}
		body := chat.Body.String()
		if strings.Count(body, frame0) != 1 || strings.Count(body, frame1) != 1 {
			t.Fatalf("frames not verbatim count0=%d count1=%d", strings.Count(body, frame0), strings.Count(body, frame1))
		}
		if chat.Header().Get(privacyPostureVerifiedAtHeader) != "" {
			t.Fatalf("internal posture header reached the buyer: %q", chat.Header().Get(privacyPostureVerifiedAtHeader))
		}
		if !strings.Contains(body, "data: "+frame0) || !strings.Contains(body, "data: "+frame1) {
			t.Fatal("sse prefix changed")
		}
		used, held, err := store.DailyUsage(context.Background(), "privacy-frames-stream", fixedNow().Format("2006-01-02"))
		if err != nil || used != 6 || held != 0 {
			t.Fatalf("used=%d held=%d err=%v", used, held, err)
		}
	})

	t.Run("nonstream", func(t *testing.T) {
		res := privacyReservationFixture(t, false)
		raw := pilotEnvelopeFixture(t, res)
		digest := sha256.Sum256(raw)
		digestText := base64.RawURLEncoding.EncodeToString(digest[:])
		upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set(relayBlindValidatedHeader, digestText)
			setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
			w.Header().Set(settlementModeHeader, "observe")
			io.WriteString(w, `{"object":"macprovider.privacy_response","version":"privacy-response-v1","frames":`+framesRaw+`,"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`)
		})
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-frames-json")
		reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{privacyClassHeader: privacyClassV1})
		if reserve.Code != http.StatusOK {
			t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
		}
		chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
		if chat.Code != http.StatusOK {
			t.Fatalf("status %d %s", chat.Code, chat.Body.String())
		}
		if strings.Count(chat.Body.String(), framesRaw) != 1 {
			t.Fatal("frames raw message was rewritten")
		}
		used, held, err := store.DailyUsage(context.Background(), "privacy-frames-json", fixedNow().Format("2006-01-02"))
		if err != nil || used != 6 || held != 0 {
			t.Fatalf("used=%d held=%d err=%v", used, held, err)
		}
	})
}

func TestPrivacyUsageMetadataExactStrings(t *testing.T) {
	for _, tc := range []struct {
		name, account string
		reserve       bool
	}{
		{name: "after reservation", account: "privacy-usage", reserve: true},
		{name: "other gateway instance", account: "privacy-usage-stateless"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := privacyReservationFixture(t, false)
			if res.PrivacyPostureVerifiedAtUnix == privacyCoordinatorVerifiedAt {
				t.Fatal("fixture stamp collided with the coordinator header")
			}
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			upstream, log := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set(relayBlindValidatedHeader, digestText)
				setPrivacyChatEcho(w, privacyCoordinatorVerifiedAt)
				w.Header().Set(settlementModeHeader, "observe")
				io.WriteString(w, `{"object":"macprovider.privacy_response","frames":[{"object":"macprovider.privacy_frame","ciphertext":"abc"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`)
			})
			h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				enablePrivacy(c)
				c.Coordinator.BuyerURL = upstream.URL
			})
			key := createAccountAndKey(t, store, cfg, tc.account)
			if tc.reserve {
				reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{
					privacyClassHeader: privacyClassV1, privacyPostureVerifiedAtHeader: "1",
				})
				if reserve.Code != http.StatusOK {
					t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
				}
			}
			chat := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
			if chat.Code != http.StatusOK {
				t.Fatalf("chat %d %s", chat.Code, chat.Body.String())
			}
			if chat.Header().Get(privacyClassHeader) != privacyClassV1 || chat.Header().Get(privacyAssuranceHeader) != privacyAssuranceV1 || chat.Header().Get(privacyResponseEncryptionHeader) != privacyResponseEncryptionV1 || chat.Header().Get(privacyPostureVerifiedAtHeader) != "" {
				t.Fatalf("success headers class=%q assurance=%q encryption=%q posture=%q", chat.Header().Get(privacyClassHeader), chat.Header().Get(privacyAssuranceHeader), chat.Header().Get(privacyResponseEncryptionHeader), chat.Header().Get(privacyPostureVerifiedAtHeader))
			}
			for _, hop := range log.snapshot() {
				if hop.posture != "" {
					t.Fatalf("buyer posture header reached the coordinator: %+v", hop)
				}
			}
			var parsed struct {
				Usage struct {
					Macprovider struct {
						Scope   string             `json:"scope"`
						Privacy privacyUsageObject `json:"privacy"`
					} `json:"macprovider"`
				} `json:"usage"`
			}
			if err := json.Unmarshal(chat.Body.Bytes(), &parsed); err != nil {
				t.Fatal(err)
			}
			if parsed.Usage.Macprovider.Scope != relayBlindScope {
				t.Fatalf("outer scope replaced: %s", parsed.Usage.Macprovider.Scope)
			}
			want := privacyUsageMetadata(privacyCoordinatorVerifiedAt)
			if !reflect.DeepEqual(parsed.Usage.Macprovider.Privacy, want) || parsed.Usage.Macprovider.Privacy.PostureVerifiedAtUnix == res.PrivacyPostureVerifiedAtUnix {
				t.Fatalf("privacy usage %+v want %+v reservation %d", parsed.Usage.Macprovider.Privacy, want, res.PrivacyPostureVerifiedAtUnix)
			}
			if parsed.Usage.Macprovider.Privacy.Scope != "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound" {
				t.Fatal("scope string drifted")
			}
			encoded, err := json.Marshal(parsed.Usage.Macprovider.Privacy)
			if err != nil {
				t.Fatal(err)
			}
			last := -1
			for _, key := range []string{`"class"`, `"assurance"`, `"scope"`, `"protects"`, `"does_not_protect"`, `"residual_risks"`, `"posture_verified_at_unix"`} {
				idx := strings.Index(string(encoded), key)
				if idx <= last {
					t.Fatalf("key %s out of order in %s", key, encoded)
				}
				last = idx
			}
		})
	}
}

func TestPrivacyReservationVersionMismatch(t *testing.T) {
	t.Run("privacy request relay-blind reservation", func(t *testing.T) {
		res, _ := pilotReservationFixture(t, false)
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			json.NewEncoder(w).Encode(res)
		}))
		defer upstream.Close()
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-version-down")
		body := privacyReservationBody(t, relayblind.ReservationResponse{Model: res.Model, Stream: res.Stream, MaxOutputTokens: res.MaxOutputTokens, InputTokenUpperBound: res.InputTokenUpperBound})
		resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", body, map[string]string{privacyClassHeader: privacyClassV1})
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), http.StatusServiceUnavailable, privacyClassUnavailable, "none", "Privacy class is unavailable")
	})
	t.Run("plain request privacy reservation", func(t *testing.T) {
		res := privacyReservationFixture(t, false)
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get(privacyClassHeader) != "" {
				t.Error("privacy header on non-privacy reservation")
			}
			json.NewEncoder(w).Encode(res)
		}))
		defer upstream.Close()
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-version-up")
		resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), nil)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), http.StatusServiceUnavailable, privacyClassUnavailable, "none", "")
	})
}

func TestPrivacyPoolAndDemoDowngradeRejected(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("upstream called")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-pool")
	resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", []byte(`{`), map[string]string{
		privacyClassHeader: privacyClassV1, poolSelectHeader: "pool",
	})
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("pool status %d %s", resp.Code, resp.Body.String())
	}
	assertPrivacyError(t, resp.Body.String(), http.StatusBadRequest, privacyClassDowngrade, "none", privacyPoolDowngradeText)

	demo := issueDemoToken(t, h, "192.0.2.20")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"test-model","messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("X-Demo-Token", demo)
	req.Header.Set("X-Real-IP", "192.0.2.20")
	req.Header.Set(privacyClassHeader, "not-the-class")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("demo status %d %s", w.Code, w.Body.String())
	}
	assertPrivacyError(t, w.Body.String(), http.StatusBadRequest, privacyClassDowngrade, "none", privacyDemoDowngradeText)
}

func TestPrivacyErrorCodesMatchCoordinatorInventory(t *testing.T) {
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
		t.Fatalf("inventory %+v", inventory)
	}
	seen := map[string]bool{}
	for _, row := range inventory.Codes {
		seen[row.Code] = true
		status, _ := privacyClassHTTP(row.Code)
		if status != row.HTTPStatus || gatewayRetryable(row.Code) != row.Retryable {
			t.Fatalf("shape %s status=%d retryable=%v", row.Code, status, gatewayRetryable(row.Code))
		}
		if relayBlindRetryAction(http.Header{}, row.Code) != row.RetryAction {
			t.Fatalf("retry action %s", row.Code)
		}
		_, retryable := gatewayRetryableByCode[row.Code]
		_, permanent := gatewayPermanentCodes[row.Code]
		if retryable == permanent {
			t.Fatalf("%s classification retryable=%v permanent=%v", row.Code, retryable, permanent)
		}
		found := false
		for _, code := range gatewayEmittedErrorCodes {
			if code == row.Code {
				found = true
			}
		}
		if !found {
			t.Fatalf("%s missing from gatewayEmittedErrorCodes", row.Code)
		}
	}
	for _, table := range []map[string]bool{gatewayRetryableByCode, gatewayPermanentCodes} {
		for code := range table {
			if strings.HasPrefix(code, "privacy_class_") && !seen[code] {
				t.Fatalf("map code %s missing from inventory", code)
			}
		}
	}
	sticky := http.Header{}
	sticky.Set("X-MacProvider-Relay-Blind-Retry-Action", "new_reservation_and_envelope")
	if relayBlindRetryAction(sticky, privacyClassDisabled) != "none" || relayBlindRetryAction(sticky, privacyClassUnconfirmed) != "do_not_resubmit" {
		t.Fatal("privacy retry action followed the predispatch header")
	}

	t.Run("disabled", func(t *testing.T) {
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			c.Features.RelayBlindRequests.Enabled = true
		})
		key := createAccountAndKey(t, store, cfg, "privacy-disabled")
		resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", []byte(`{`), map[string]string{privacyClassHeader: privacyClassV1})
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), resp.Code, privacyClassDisabled, "none", "Privacy class is disabled")
		if resp.Header().Get("Retry-After") != "" {
			t.Fatalf("Retry-After %q", resp.Header().Get("Retry-After"))
		}
	})
	t.Run("downgrade", func(t *testing.T) {
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) { enablePrivacy(c) })
		key := createAccountAndKey(t, store, cfg, "privacy-bad-header")
		resp := postPrivacy(h, key, "/v1/chat/completions", []byte(`{"model":"test-model","messages":[{"role":"user","content":"x"}]}`), map[string]string{privacyClassHeader: "not-the-class"})
		if resp.Code != http.StatusBadRequest {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), resp.Code, privacyClassDowngrade, "none", "")
	})
	t.Run("unavailable", func(t *testing.T) {
		res, _ := pilotReservationFixture(t, false)
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			json.NewEncoder(w).Encode(res)
		}))
		defer upstream.Close()
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-unavailable")
		body := privacyReservationBody(t, relayblind.ReservationResponse{Model: res.Model, Stream: res.Stream, MaxOutputTokens: res.MaxOutputTokens, InputTokenUpperBound: res.InputTokenUpperBound})
		resp := postPrivacy(h, key, "/v1/relay-blind/route-reservations", body, map[string]string{privacyClassHeader: privacyClassV1})
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), resp.Code, privacyClassUnavailable, "none", "")
		if strings.Contains(resp.Body.String(), "relay_blind_required_unavailable") {
			t.Fatal("privacy code remapped")
		}
	})
	t.Run("posture_stale", func(t *testing.T) {
		res := privacyReservationFixture(t, false)
		raw := pilotEnvelopeFixture(t, res)
		var chats int
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/v1/chat/completions" {
				chats++
			}
			w.WriteHeader(http.StatusBadRequest)
			io.WriteString(w, `{"error":{"code":"privacy_class_posture_stale","message":"CANARY_STALE"}}`)
		}))
		defer upstream.Close()
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-stale")
		resp := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), resp.Code, privacyClassStale, "new_reservation_and_envelope", "Privacy class posture is stale")
		if strings.Contains(resp.Body.String(), "CANARY_STALE") || strings.Contains(resp.Body.String(), "relay_blind_required_unavailable") {
			t.Fatalf("remapped or leaked: %s", resp.Body.String())
		}
		if resp.Header().Get("Retry-After") != "1" {
			t.Fatalf("Retry-After %q", resp.Header().Get("Retry-After"))
		}
		if chats != 0 {
			t.Fatalf("chat dispatched %d", chats)
		}
	})
	t.Run("unconfirmed", func(t *testing.T) {
		res := privacyReservationFixture(t, false)
		raw := pilotEnvelopeFixture(t, res)
		digest := sha256.Sum256(raw)
		digestText := base64.RawURLEncoding.EncodeToString(digest[:])
		upstream, _ := privacyCoordinator(t, res, raw, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set(relayBlindValidatedHeader, digestText)
			w.Header().Set(settlementModeHeader, "observe")
			io.WriteString(w, `{"choices":[{"message":{"content":"CANARY_PRIVACY_BODY"}}]}`)
		})
		h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
			enablePrivacy(c)
			c.Coordinator.BuyerURL = upstream.URL
		})
		key := createAccountAndKey(t, store, cfg, "privacy-inventory-unconfirmed")
		reserve := postPrivacy(h, key, "/v1/relay-blind/route-reservations", privacyReservationBody(t, res), map[string]string{privacyClassHeader: privacyClassV1})
		if reserve.Code != http.StatusOK {
			t.Fatalf("reserve %d %s", reserve.Code, reserve.Body.String())
		}
		resp := postPrivacy(h, key, "/v1/chat/completions", raw, privacyChatHeaders())
		if resp.Code != http.StatusInternalServerError {
			t.Fatalf("status %d %s", resp.Code, resp.Body.String())
		}
		assertPrivacyError(t, resp.Body.String(), resp.Code, privacyClassUnconfirmed, "do_not_resubmit", "")
		if strings.Contains(resp.Body.String(), "CANARY_PRIVACY_BODY") {
			t.Fatal("unconfirmed body streamed")
		}
	})
}
