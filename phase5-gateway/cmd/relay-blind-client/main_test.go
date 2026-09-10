package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

func TestRunAPIKeyAndWalletSession(t *testing.T) {
	for _, wallet := range []bool{false, true} {
		for _, stream := range []bool{false, true} {
			name := "api_key"
			if wallet {
				name = "wallet_session"
			}
			if stream {
				name += "_stream"
			}
			t.Run(name, func(t *testing.T) {
				now := time.Now().UTC()
				record, pin, providerPrivate := cliIdentity(t, now)
				pinPath := writePin(t, pin)
				inner := []byte(fmt.Sprintf("{\"model\":\"model-a\",\"messages\":[{\"role\":\"user\",\"content\":\"client secret prompt\"}],\"max_tokens\":32,\"stream\":%t}", stream))
				var calls atomic.Int32
				var walletPrivate ed25519.PrivateKey
				var walletPublic ed25519.PublicKey
				if wallet {
					seed := bytes.Repeat([]byte{0x77}, ed25519.SeedSize)
					walletPrivate = ed25519.NewKeyFromSeed(seed)
					walletPublic = walletPrivate.Public().(ed25519.PublicKey)
				}
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					if got := r.Header.Get("Authorization"); got != "Bearer test-bearer-secret" {
						t.Errorf("authorization=%q", got)
					}
					body, _ := io.ReadAll(r.Body)
					if wallet {
						verifyWalletRequest(t, r, body, "wallet-session-fixture", walletPublic)
					}
					switch r.URL.Path {
					case "/v1/relay-blind/route-reservations":
						request, err := relayblind.ParseReservationRequest(body)
						if err != nil {
							t.Errorf("reservation: %v", err)
							http.Error(w, "bad", 400)
							return
						}
						if request.EncryptedRequestBytes != int64(len(inner)) {
							t.Errorf("encrypted_request_bytes=%d want %d", request.EncryptedRequestBytes, len(inner))
						}
						response := relayblind.ReservationResponse{
							Version:         relayblind.ReservationVersion,
							ProviderBinding: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32)),
							BuyerBinding:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x44}, 32)),
							KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
							EndpointFamily: request.EndpointFamily, Model: request.Model, ProviderModel: request.Model,
							Stream: request.Stream, MaxEncryptedRequestBytes: record.MaxEncryptedRequestBytes,
							MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
							ReservationTokenCap: request.MaxOutputTokens + request.InputTokenUpperBound,
							ExpiresAtUnix:       now.Add(30 * time.Second).Unix(), CachePolicy: relayblind.CachePolicyNoStore,
							FailoverPolicy: relayblind.FailoverPolicyDisabled,
						}
						_ = json.NewEncoder(w).Encode(response)
					case "/v1/chat/completions":
						envelope, err := relayblind.ParseEnvelope(body)
						if err != nil {
							t.Errorf("envelope: %v", err)
							http.Error(w, "bad", 400)
							return
						}
						plaintext, err := envelope.Decrypt(providerPrivate.Bytes())
						if err != nil || !bytes.Equal(plaintext, inner) {
							t.Errorf("decrypt=%v match=%v", err, bytes.Equal(plaintext, inner))
							http.Error(w, "bad", 400)
							return
						}
						w.Header().Set("X-MacProvider-Requested-Privacy-Mode", "relay_blind_required")
						w.Header().Set("X-MacProvider-Effective-Privacy-Outcome", "relay_blind_satisfied")
						if stream {
							_, _ = io.WriteString(w, "data: "+successfulUsageJSON+"\n\ndata: [DONE]\n\n")
						} else {
							_, _ = io.WriteString(w, successfulUsageJSON)
						}
					default:
						http.NotFound(w, r)
					}
				}))
				defer server.Close()
				opts := options{
					baseURL: server.URL, identityPin: pinPath, model: "model-a", input: "-",
					maxOutputTokens: 32, inputTokenUpperBound: 96, stream: stream, apiKeyEnv: "TEST_API_KEY",
					walletSessionKeyEnv: "TEST_WALLET_KEY", timeout: time.Minute,
				}
				if wallet {
					opts.walletSessionID = "wallet-session-fixture"
				}
				getenv := func(name string) string {
					switch name {
					case "TEST_API_KEY":
						return "test-bearer-secret"
					case "TEST_WALLET_KEY":
						if wallet {
							return base64.RawURLEncoding.EncodeToString(walletPrivate)
						}
					}
					return ""
				}
				var stdout, stderr bytes.Buffer
				if err := run(context.Background(), opts, bytes.NewReader(inner), &stdout, &stderr, getenv); err != nil {
					t.Fatalf("run: %v", err)
				}
				wantOutput := successfulUsageJSON
				if stream {
					wantOutput = "data: " + successfulUsageJSON + "\n\ndata: [DONE]\n\n"
				}
				if stdout.String() != wantOutput {
					t.Fatalf("stdout=%q", stdout.String())
				}
				if strings.Contains(stderr.String(), "secret") || !strings.Contains(stderr.String(), requestScope) {
					t.Fatalf("unsafe/incomplete stderr=%q", stderr.String())
				}
				if calls.Load() != 2 {
					t.Fatalf("calls=%d want 2", calls.Load())
				}
			})
		}
	}
}

func TestRunDoesNotRetryEncryptedRequest(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream_%t", stream), func(t *testing.T) {
			now := time.Now().UTC()
			record, pin, _ := cliIdentity(t, now)
			pinPath := writePin(t, pin)
			inner := []byte(fmt.Sprintf("{\"model\":\"model-a\",\"messages\":[{\"role\":\"user\",\"content\":\"once\"}],\"max_tokens\":32,\"stream\":%t}", stream))
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				body, _ := io.ReadAll(r.Body)
				if r.URL.Path == "/v1/relay-blind/route-reservations" {
					request, _ := relayblind.ParseReservationRequest(body)
					response := relayblind.ReservationResponse{
						Version:         relayblind.ReservationVersion,
						ProviderBinding: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32)),
						BuyerBinding:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x44}, 32)),
						KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
						EndpointFamily: request.EndpointFamily, Model: request.Model, ProviderModel: request.Model,
						Stream: request.Stream, MaxEncryptedRequestBytes: record.MaxEncryptedRequestBytes,
						MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
						ReservationTokenCap: request.MaxOutputTokens + request.InputTokenUpperBound,
						ExpiresAtUnix:       now.Add(30 * time.Second).Unix(), CachePolicy: relayblind.CachePolicyNoStore,
						FailoverPolicy: relayblind.FailoverPolicyDisabled,
					}
					_ = json.NewEncoder(w).Encode(response)
					return
				}
				http.Error(w, "committed failure", http.StatusServiceUnavailable)
			}))
			defer server.Close()
			opts := options{baseURL: server.URL, identityPin: pinPath, model: "model-a", input: "-", maxOutputTokens: 32, inputTokenUpperBound: 96, stream: stream, apiKeyEnv: "KEY", walletSessionKeyEnv: "WALLET", timeout: time.Minute}
			var stdout, stderr bytes.Buffer
			err := run(context.Background(), opts, bytes.NewReader(inner), &stdout, &stderr, func(name string) string {
				if name == "KEY" {
					return "bearer"
				}
				return ""
			})
			if err == nil {
				t.Fatal("503 accepted")
			}
			if calls.Load() != 2 {
				t.Fatalf("calls=%d; encrypted request was retried", calls.Load())
			}
			if strings.Contains(stderr.String(), "bearer") {
				t.Fatal("credential leaked")
			}
		})
	}
}

func TestRunRejectsRelaySubstitutedRecordBeforeEncryptedSend(t *testing.T) {
	now := time.Now().UTC()
	_, pin, _ := cliIdentity(t, now)
	pinPath := writePin(t, pin)

	otherIdentity := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x12}, ed25519.SeedSize))
	providerPrivate, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x13}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), otherIdentity, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/v1/relay-blind/route-reservations" {
			t.Errorf("encrypted request sent after key substitution: %s", r.URL.Path)
			http.Error(w, "unexpected", http.StatusBadRequest)
			return
		}
		body, _ := io.ReadAll(r.Body)
		request, parseErr := relayblind.ParseReservationRequest(body)
		if parseErr != nil {
			t.Errorf("reservation request: %v", parseErr)
			http.Error(w, "bad", http.StatusBadRequest)
			return
		}
		response := relayblind.ReservationResponse{
			Version:         relayblind.ReservationVersion,
			ProviderBinding: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32)),
			BuyerBinding:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x44}, 32)),
			KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
			EndpointFamily: request.EndpointFamily, Model: request.Model, ProviderModel: request.Model,
			Stream: request.Stream, MaxEncryptedRequestBytes: record.MaxEncryptedRequestBytes,
			MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
			ReservationTokenCap: request.MaxOutputTokens + request.InputTokenUpperBound,
			ExpiresAtUnix:       now.Add(30 * time.Second).Unix(), CachePolicy: relayblind.CachePolicyNoStore,
			FailoverPolicy: relayblind.FailoverPolicyDisabled,
		}
		_ = json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	inner := []byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}],"max_tokens":32,"stream":false}`)
	opts := options{baseURL: server.URL, identityPin: pinPath, model: "model-a", input: "-", maxOutputTokens: 32, inputTokenUpperBound: 96, apiKeyEnv: "KEY", walletSessionKeyEnv: "WALLET", timeout: time.Minute}
	var stdout, stderr bytes.Buffer
	err = run(context.Background(), opts, bytes.NewReader(inner), &stdout, &stderr, func(name string) string {
		if name == "KEY" {
			return "bearer-secret"
		}
		return ""
	})
	if err == nil {
		t.Fatal("relay-substituted provider record accepted")
	}
	if calls.Load() != 1 {
		t.Fatalf("calls=%d; encrypted request must not be sent", calls.Load())
	}
	if stdout.Len() != 0 || strings.Contains(stderr.String(), "bearer-secret") {
		t.Fatal("substitution failure exposed output or credential")
	}
}

func TestRunRequiresExplicitIdentityPinBeforeNetwork(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		calls.Add(1)
	}))
	defer server.Close()
	opts := options{baseURL: server.URL, model: "model-a", input: "-", maxOutputTokens: 32, inputTokenUpperBound: 96, apiKeyEnv: "KEY", walletSessionKeyEnv: "WALLET", timeout: time.Minute}
	var stdout, stderr bytes.Buffer
	err := run(context.Background(), opts, strings.NewReader(`{"model":"model-a","messages":[],"max_tokens":32}`), &stdout, &stderr, func(string) string { return "bearer-secret" })
	if err == nil {
		t.Fatal("missing identity pin accepted")
	}
	if calls.Load() != 0 {
		t.Fatalf("calls=%d; network used before identity pin validation", calls.Load())
	}
}

func TestValidateInnerRequestRejectsDuplicateFields(t *testing.T) {
	opts := options{model: "model-a", maxOutputTokens: 32}
	raw := []byte("{\"model\":\"model-a\",\"model\":\"model-b\",\"messages\":[],\"max_tokens\":32}")
	if err := validateInnerRequest(raw, opts); err == nil {
		t.Fatal("duplicate field accepted")
	}
}

func cliIdentity(t *testing.T, now time.Time) (relayblind.KeyRecord, relayblind.IdentityPin, *ecdh.PrivateKey) {
	t.Helper()
	identityPrivate := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x66}, ed25519.SeedSize))
	providerPrivate, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	public := identityPrivate.Public().(ed25519.PublicKey)
	fingerprint := sha256.Sum256(public)
	pin := relayblind.IdentityPin{
		Version: relayblind.PinVersion, IdentityPublicKey: base64.RawURLEncoding.EncodeToString(public),
		Fingerprint: base64.RawURLEncoding.EncodeToString(fingerprint[:]), Models: []string{"model-a"},
		EndpointFamilies: []string{relayblind.EndpointChatCompletions},
		NotBeforeUnix:    now.Add(-time.Hour).Unix(), ExpiresAtUnix: now.Add(time.Hour).Unix(),
	}
	return record, pin, providerPrivate
}

func writePin(t *testing.T, pin relayblind.IdentityPin) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	home = filepath.Clean(home)
	realHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	if realHome != home {
		t.Fatalf("test home contains a symlink: %q", home)
	}
	dir, err := os.MkdirTemp(home, ".macprovider-pin-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(dir); err != nil {
			t.Errorf("remove pin test directory: %v", err)
		}
	})
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "pin.json")
	raw, _ := json.Marshal(pin)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func verifyWalletRequest(t *testing.T, request *http.Request, body []byte, sessionID string, publicKey ed25519.PublicKey) {
	t.Helper()
	timestamp, err := strconv.ParseInt(request.Header.Get("X-MacProvider-Session-Timestamp"), 10, 64)
	if err != nil {
		t.Errorf("wallet timestamp: %v", err)
		return
	}
	object, err := auth.NewWalletRequestSignatureObject(sessionID, request.Method, request.URL.Path, request.Header.Get("X-Request-ID"), body, request.Header, timestamp)
	if err != nil {
		t.Errorf("wallet canonical: %v", err)
		return
	}
	if err := auth.VerifyWalletRequestSignature(object, request.Header.Get("X-MacProvider-Session-Signature"), publicKey, time.Unix(timestamp, 0), 0, 0); err != nil {
		t.Errorf("wallet signature: %v", err)
	}
}

const successfulUsageJSON = `{"usage":{"macprovider":{"requested_privacy_mode":"relay_blind_required","effective_privacy_outcome":"relay_blind_satisfied","scope":"request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays","settlement":{"verified_model_settlement":"unavailable_for_relay_blind_request","usage_settlement":"standard_usage_settlement_and_clear_cap_enforcement_still_apply"}}}}`

func TestResponseVerificationRequiresActualOutcomeAndCompletion(t *testing.T) {
	for _, tc := range []struct {
		name, body              string
		stream, header, success bool
	}{
		{"missing-header", successfulUsageJSON, false, false, false},
		{"missing-metadata", `{"choices":[]}`, false, true, false},
		{"invalid-json", `{`, false, true, false},
		{"json-error", `{"error":{"code":"failed"}}`, false, true, false},
		{"json-success", successfulUsageJSON, false, true, true},
		{"wrong-settlement", strings.ReplaceAll(successfulUsageJSON, "unavailable_for_relay_blind_request", "verified"), false, true, false},
		{"stream-missing-done", "data: " + successfulUsageJSON + "\n\n", true, true, false},
		{"stream-error", "data: " + successfulUsageJSON + "\n\ndata: {\"error\":{\"code\":\"failed\"}}\n\ndata: [DONE]\n\n", true, true, false},
		{"stream-no-metadata", "data: [DONE]\n\n", true, true, false},
		{"stream-success", "data: " + successfulUsageJSON + "\n\ndata: [DONE]\n\n", true, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(tc.body))}
			if tc.header {
				response.Header.Set("X-MacProvider-Requested-Privacy-Mode", "relay_blind_required")
				response.Header.Set("X-MacProvider-Effective-Privacy-Outcome", "relay_blind_satisfied")
			}
			var out bytes.Buffer
			err := copyVerifiedResponse(response, tc.stream, &out)
			if (err == nil) != tc.success {
				t.Fatalf("success=%v err=%v", tc.success, err)
			}
		})
	}
}
