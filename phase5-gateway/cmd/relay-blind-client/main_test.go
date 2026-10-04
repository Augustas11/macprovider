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
					if r.Header.Get("X-MacProvider-Privacy-Class") != "" {
						t.Errorf("default request set privacy class header")
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
				if strings.Contains(stderr.String(), "secret") || !strings.Contains(stderr.String(), requestScope) || strings.Contains(stderr.String(), relayblind.PrivacyAssurance) {
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

func TestPrivacyClientDecryptsStreamAndNonStream(t *testing.T) {
	if privacyScope != "request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound" {
		t.Fatal("privacy scope drifted from SPEC-049-R020")
	}
	if len(privacyProtects) != 9 || len(privacyDoesNotProtect) != 6 || len(privacyResidualRisks) != 11 {
		t.Fatal("disclosure list length drifted")
	}
	for _, tc := range []struct {
		name                         string
		stream, wallet               bool
		finalPrompt, finalCompletion int64
		clearPrompt, clearCompletion int64
	}{
		{name: "stream", stream: true, finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2},
		{name: "nonstream", finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2},
		{name: "nonstream_bounded", finalPrompt: 120, finalCompletion: 40, clearPrompt: 96, clearCompletion: 32},
		{name: "wallet_stream", stream: true, wallet: true, finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			content := privacyContent(tc.stream)
			stdout, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{
				stream: tc.stream, wallet: tc.wallet, content: content,
				finalPrompt: tc.finalPrompt, finalCompletion: tc.finalCompletion,
				clearPrompt: tc.clearPrompt, clearCompletion: tc.clearCompletion,
				verifiedAt: time.Now().Unix() + 10,
			})
			if err != nil {
				t.Fatalf("run: %v", err)
			}
			if stdout != string(content) {
				t.Fatalf("stdout=%q", stdout)
			}
			if strings.Contains(stdout, "ciphertext") {
				t.Fatal("stdout contained ciphertext metadata")
			}
			assertPrivacyStderr(t, stderr)
			if calls != 2 {
				t.Fatalf("calls=%d", calls)
			}
		})
	}
}

func TestPrivacyClientRejectsTruncatedMissingFinal(t *testing.T) {
	for _, tc := range []struct {
		name, mode string
		stream     bool
	}{
		{name: "stream_truncated", mode: "truncated", stream: true},
		{name: "stream_missing_final", mode: "missing_final", stream: true},
		{name: "nonstream_truncated", mode: "truncated", stream: false},
		{name: "nonstream_missing_final", mode: "missing_final", stream: false},
		{name: "nonstream_cancelled_final", mode: "cancelled", stream: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{stream: tc.stream, mode: tc.mode, content: privacyContent(tc.stream)})
			assertPrivacyFailure(t, err, stderr, calls, 2)
		})
	}
}

func TestPrivacyClientRejectsSeqGapReorderTamperAfterFinal(t *testing.T) {
	for _, stream := range []bool{false, true} {
		for _, mode := range []string{"gap", "reorder", "tamper", "after_final"} {
			t.Run(fmt.Sprintf("stream_%t_%s", stream, mode), func(t *testing.T) {
				_, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{stream: stream, mode: mode, content: privacyContent(stream)})
				assertPrivacyFailure(t, err, stderr, calls, 2)
			})
		}
	}
}

func TestPrivacyClientRejectsUsageMismatch(t *testing.T) {
	for _, tc := range []struct {
		name                         string
		stream                       bool
		finalPrompt, finalCompletion int64
		clearPrompt, clearCompletion int64
		totalOverride                *int64
		alter                        func(map[string]any) map[string]any
	}{
		{name: "token_mismatch", finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 3},
		{name: "total_mismatch", finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2, totalOverride: int64Ptr(9)},
		{name: "unbounded_over_cap", finalPrompt: 120, finalCompletion: 40, clearPrompt: 120, clearCompletion: 40},
		{name: "stream_token_mismatch", stream: true, finalPrompt: 4, finalCompletion: 2, clearPrompt: 5, clearCompletion: 2},
		{name: "swapped_protects", finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2, alter: swapPrivacyProtects},
		{name: "zero_posture_time", finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2, alter: func(usage map[string]any) map[string]any {
			privacyObject(usage)["posture_verified_at_unix"] = int64(0)
			return usage
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			spec := privacyClientSpec{
				stream: tc.stream, content: privacyContent(tc.stream),
				finalPrompt: tc.finalPrompt, finalCompletion: tc.finalCompletion,
				clearPrompt: tc.clearPrompt, clearCompletion: tc.clearCompletion,
				totalOverride: tc.totalOverride, alterUsage: tc.alter,
				verifiedAt: time.Now().Unix() + 10,
			}
			_, stderr, calls, err := runPrivacyClient(t, spec)
			assertPrivacyFailure(t, err, stderr, calls, 2)
		})
	}
}

func TestPrivacyClientRejectsNonPrivacyReservation(t *testing.T) {
	_, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{
		content: privacyContent(false),
		reservation: func(res relayblind.ReservationResponse) relayblind.ReservationResponse {
			res.Version = relayblind.ReservationVersion
			res.PrivacyClass = ""
			res.PrivacyAssurance = ""
			res.PrivacyKeyAttestation = nil
			res.PrivacyKeyAttestationSignature = ""
			res.PrivacyPostureVerifiedAtUnix = 0
			return res
		},
	})
	if err == nil {
		t.Fatal("non-privacy reservation accepted")
	}
	if calls != 1 {
		t.Fatalf("calls=%d; chat was sent", calls)
	}
	if stderr != "" || strings.Contains(err.Error(), "do not resubmit") {
		t.Fatalf("pre-send failure err=%v stderr=%q", err, stderr)
	}
}

func TestPrivacyClientRejectsBadAttestationSignature(t *testing.T) {
	_, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{
		content: privacyContent(false),
		reservation: func(res relayblind.ReservationResponse) relayblind.ReservationResponse {
			raw, decErr := base64.RawURLEncoding.DecodeString(res.PrivacyKeyAttestationSignature)
			if decErr != nil || len(raw) == 0 {
				t.Fatalf("signature: %v len=%d", decErr, len(raw))
			}
			raw[0] ^= 0x01
			res.PrivacyKeyAttestationSignature = base64.RawURLEncoding.EncodeToString(raw)
			return res
		},
	})
	if err == nil || !strings.Contains(err.Error(), "privacy key attestation rejected") {
		t.Fatalf("err=%v", err)
	}
	if calls != 1 {
		t.Fatalf("calls=%d; chat was sent", calls)
	}
	if stderr != "" || strings.Contains(err.Error(), "do not resubmit") {
		t.Fatalf("pre-send failure err=%v stderr=%q", err, stderr)
	}
}

func TestPrivacyClientRejectsMissingR020Headers(t *testing.T) {
	for _, tc := range []struct {
		name string
		hook func(http.Header)
	}{
		{name: "missing_class", hook: func(h http.Header) { h.Del(privacyClassHeader) }},
		{name: "missing_assurance", hook: func(h http.Header) { h.Del(privacyAssuranceHeader) }},
		{name: "missing_encryption", hook: func(h http.Header) { h.Del(privacyResponseEncryptionHeader) }},
		{name: "wrong_class", hook: func(h http.Header) { h.Set(privacyClassHeader, "confidential_compute") }},
		{name: "duplicate_class", hook: func(h http.Header) { h.Add(privacyClassHeader, relayblind.PrivacyClassV1) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{
				stream: true, content: privacyContent(true), headerHook: tc.hook,
				finalPrompt: 4, finalCompletion: 2, clearPrompt: 4, clearCompletion: 2,
				verifiedAt: time.Now().Unix() + 10,
			})
			assertPrivacyFailure(t, err, stderr, calls, 2)
			if err == nil || !strings.Contains(err.Error(), "privacy response headers rejected") {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

type privacyClientSpec struct {
	stream, wallet               bool
	mode                         string
	content                      []byte
	finalPrompt, finalCompletion int64
	clearPrompt, clearCompletion int64
	verifiedAt                   int64
	totalOverride                *int64
	alterUsage                   func(map[string]any) map[string]any
	headerHook                   func(http.Header)
	reservation                  func(relayblind.ReservationResponse) relayblind.ReservationResponse
}

func runPrivacyClient(t *testing.T, spec privacyClientSpec) (string, string, int32, error) {
	t.Helper()
	if spec.finalPrompt == 0 && spec.finalCompletion == 0 && spec.mode == "" && spec.reservation == nil {
		spec.finalPrompt, spec.finalCompletion = 4, 2
		spec.clearPrompt, spec.clearCompletion = 4, 2
	}
	if spec.verifiedAt == 0 {
		spec.verifiedAt = time.Now().Unix() + 10
	}
	now := time.Now().UTC()
	record, pin, identity, provider := cliPrivacyMaterial(t, now)
	pinPath := writePin(t, pin)
	inner := []byte(fmt.Sprintf("{\"model\":\"model-a\",\"messages\":[{\"role\":\"user\",\"content\":\"PRIVACY-CANARY-7f3a\"}],\"max_tokens\":32,\"stream\":%t}", spec.stream))
	var calls atomic.Int32
	var walletPrivate ed25519.PrivateKey
	var walletPublic ed25519.PublicKey
	if spec.wallet {
		walletPrivate = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x77}, ed25519.SeedSize))
		walletPublic = walletPrivate.Public().(ed25519.PublicKey)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		body, _ := io.ReadAll(r.Body)
		if got := r.Header.Values("X-MacProvider-Privacy-Class"); len(got) != 1 || got[0] != relayblind.PrivacyClassV1 {
			t.Errorf("privacy header=%v path=%s", got, r.URL.Path)
		}
		if spec.wallet {
			verifyWalletRequest(t, r, body, "wallet-session-fixture", walletPublic)
		}
		switch r.URL.Path {
		case "/v1/relay-blind/route-reservations":
			request, err := relayblind.ParseReservationRequest(body)
			if err != nil {
				t.Errorf("reservation: %v", err)
				http.Error(w, "bad", http.StatusBadRequest)
				return
			}
			response := privacyReservationResponse(t, record, identity, request, now)
			if spec.reservation != nil {
				response = spec.reservation(response)
			}
			_ = json.NewEncoder(w).Encode(response)
		case "/v1/chat/completions":
			writePrivacyChat(t, w, body, inner, provider, spec)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	opts := options{
		baseURL: server.URL, identityPin: pinPath, model: "model-a", input: "-",
		maxOutputTokens: 32, inputTokenUpperBound: 96, stream: spec.stream, privacyClass: true,
		apiKeyEnv: "TEST_API_KEY", walletSessionKeyEnv: "TEST_WALLET_KEY", timeout: time.Minute,
	}
	if spec.wallet {
		opts.walletSessionID = "wallet-session-fixture"
	}
	getenv := func(name string) string {
		switch name {
		case "TEST_API_KEY":
			return "test-bearer-secret"
		case "TEST_WALLET_KEY":
			if spec.wallet {
				return base64.RawURLEncoding.EncodeToString(walletPrivate)
			}
		}
		return ""
	}
	var stdout, stderr bytes.Buffer
	err := run(context.Background(), opts, bytes.NewReader(inner), &stdout, &stderr, getenv)
	return stdout.String(), stderr.String(), calls.Load(), err
}

func writePrivacyChat(t *testing.T, w http.ResponseWriter, body, inner []byte, provider *ecdh.PrivateKey, spec privacyClientSpec) {
	t.Helper()
	setPrivacyBuyerHeaders(w.Header())
	if spec.headerHook != nil {
		spec.headerHook(w.Header())
	}
	if spec.mode == "truncated" && !spec.stream {
		_, _ = io.WriteString(w, "{")
		return
	}
	keys, env, digest, plaintext := providerResponseKeys(t, body, provider)
	if !bytes.Equal(plaintext, inner) {
		t.Errorf("request decrypt mismatch")
	}
	status := relayblind.PrivacyFinalStatusComplete
	frames := sealPrivacyParts(t, keys, env, digest, spec.content, spec.finalPrompt, spec.finalCompletion, status)
	switch spec.mode {
	case "gap":
		frames[1].Seq = 2
	case "reorder":
		frames[0], frames[1] = frames[1], frames[0]
	case "tamper":
		frames[0].Ciphertext = tamperCiphertext(t, frames[0].Ciphertext)
	case "after_final":
		extra := frames[0]
		extra.Seq = 2
		extra.Final = false
		frames = append(frames, extra)
	case "missing_final":
		frames = frames[:1]
	case "cancelled":
		frames = sealPrivacyParts(t, keys, env, digest, spec.content, spec.finalPrompt, spec.finalCompletion, relayblind.PrivacyFinalStatusCancelled)
	}
	if spec.mode == "truncated" && spec.stream {
		var b strings.Builder
		for _, frame := range frames {
			raw, err := json.Marshal(frame)
			if err != nil {
				t.Fatal(err)
			}
			b.WriteString("data: ")
			b.Write(raw)
			b.WriteString("\n\n")
		}
		_, _ = io.WriteString(w, b.String())
		return
	}
	usage := privacyClearUsage(spec.clearPrompt, spec.clearCompletion, spec.verifiedAt)
	if spec.totalOverride != nil {
		usage["total_tokens"] = *spec.totalOverride
	}
	if spec.alterUsage != nil {
		usage = spec.alterUsage(usage)
	}
	if spec.mode == "missing_final" && spec.clearPrompt == 0 && spec.clearCompletion == 0 {
		usage = privacyClearUsage(4, 2, spec.verifiedAt)
	}
	if env.Stream {
		var b strings.Builder
		for _, frame := range frames {
			raw, err := json.Marshal(frame)
			if err != nil {
				t.Fatal(err)
			}
			b.WriteString("data: ")
			b.Write(raw)
			b.WriteString("\n\n")
		}
		event, err := json.Marshal(map[string]any{
			"object": "chat.completion.chunk", "model": env.Model, "choices": []any{}, "usage": usage,
		})
		if err != nil {
			t.Fatal(err)
		}
		b.WriteString("data: ")
		b.Write(event)
		b.WriteString("\n\ndata: [DONE]\n\n")
		_, _ = io.WriteString(w, b.String())
		return
	}
	raw, err := json.Marshal(struct {
		Object  string                    `json:"object"`
		Version string                    `json:"version"`
		Frames  []relayblind.PrivacyFrame `json:"frames"`
		Usage   any                       `json:"usage"`
	}{
		Object: relayblind.PrivacyResponseObject, Version: relayblind.PrivacyResponseVersion,
		Frames: frames, Usage: usage,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write(raw)
}

func sealPrivacyParts(t *testing.T, keys relayblind.ResponseKeys, env relayblind.Envelope, digest string, content []byte, prompt, completion int64, status string) []relayblind.PrivacyFrame {
	t.Helper()
	if prompt == 0 && completion == 0 {
		prompt, completion = 4, 2
	}
	finalRaw, err := (relayblind.PrivacyFinal{
		Version: relayblind.PrivacyFinalVersion, Status: status,
		PromptTokens: prompt, CompletionTokens: completion,
	}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	parts := [][]byte{content, finalRaw}
	frames := make([]relayblind.PrivacyFrame, len(parts))
	for i, part := range parts {
		frame, sealErr := relayblind.SealFrame(keys, digest, env.KID, env.RequestID, env.Stream, uint64(i), i == len(parts)-1, part)
		if sealErr != nil {
			t.Fatal(sealErr)
		}
		frames[i] = frame
	}
	return frames
}

func providerResponseKeys(t *testing.T, body []byte, provider *ecdh.PrivateKey) (relayblind.ResponseKeys, relayblind.Envelope, string, []byte) {
	t.Helper()
	envelope, err := relayblind.ParseEnvelope(body)
	if err != nil {
		t.Fatal(err)
	}
	digest, err := relayblind.DigestEnvelopeBytes(body)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := envelope.Decrypt(provider.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := ecdh.X25519().NewPrivateKey(provider.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	buyerPub, err := base64.RawURLEncoding.Strict().DecodeString(envelope.BuyerEphemeralPublicKey)
	if err != nil {
		t.Fatal(err)
	}
	peer, err := ecdh.X25519().NewPublicKey(buyerPub)
	if err != nil {
		t.Fatal(err)
	}
	shared, err := privateKey.ECDH(peer)
	if err != nil {
		t.Fatal(err)
	}
	aad, err := envelope.AAD()
	if err != nil {
		t.Fatal(err)
	}
	keys, err := relayblind.DeriveResponseKeys(shared, aad)
	if err != nil {
		t.Fatal(err)
	}
	return keys, envelope, digest, plaintext
}

func privacyReservationResponse(t *testing.T, record relayblind.KeyRecord, identity ed25519.PrivateKey, request relayblind.ReservationRequest, now time.Time) relayblind.ReservationResponse {
	t.Helper()
	attestation := relayblind.PrivacyKeyAttestation{
		Version: relayblind.PrivacyKeyAttestationVersion, KeyRecordDigest: record.KeyRecordDigest,
		PrivacyClass: relayblind.PrivacyClassV1, Assurance: relayblind.PrivacyAssurance,
		BinaryVersion: "0.0.0-fixture", CodeCDHash: "0123456789abcdef0123456789abcdef01234567",
		NotBeforeUnix: record.NotBeforeUnix, ExpiresAtUnix: record.ExpiresAtUnix,
	}
	framed, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	return relayblind.ReservationResponse{
		Version:         relayblind.PrivacyReservationVersion,
		ProviderBinding: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32)),
		BuyerBinding:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x44}, 32)),
		KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
		EndpointFamily: request.EndpointFamily, Model: request.Model, ProviderModel: request.Model,
		Stream: request.Stream, MaxEncryptedRequestBytes: record.MaxEncryptedRequestBytes,
		MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
		ReservationTokenCap: request.MaxOutputTokens + request.InputTokenUpperBound,
		ExpiresAtUnix:       now.Add(30 * time.Second).Unix(), CachePolicy: relayblind.CachePolicyNoStore,
		FailoverPolicy:                 relayblind.FailoverPolicyDisabled,
		PrivacyClass:                   relayblind.PrivacyClassV1,
		PrivacyAssurance:               relayblind.PrivacyAssurance,
		PrivacyKeyAttestation:          &attestation,
		PrivacyKeyAttestationSignature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(identity, framed)),
		PrivacyPostureVerifiedAtUnix:   now.Unix(),
	}
}

func cliPrivacyMaterial(t *testing.T, now time.Time) (relayblind.KeyRecord, relayblind.IdentityPin, ed25519.PrivateKey, *ecdh.PrivateKey) {
	t.Helper()
	identity := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x66}, ed25519.SeedSize))
	provider, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	notBefore := now.Add(-time.Minute)
	expires := notBefore.Add(time.Duration(relayblind.MaxPrivacyKeyLifetimeSeconds) * time.Second)
	record, err := relayblind.NewSignedKeyRecord(provider.PublicKey().Bytes(), identity, []string{"model-a"}, 4096, notBefore, expires)
	if err != nil {
		t.Fatal(err)
	}
	public := identity.Public().(ed25519.PublicKey)
	fingerprint := sha256.Sum256(public)
	pin := relayblind.IdentityPin{
		Version: relayblind.PinVersion, IdentityPublicKey: base64.RawURLEncoding.EncodeToString(public),
		Fingerprint: base64.RawURLEncoding.EncodeToString(fingerprint[:]), Models: []string{"model-a"},
		EndpointFamilies: []string{relayblind.EndpointChatCompletions},
		NotBeforeUnix:    now.Add(-time.Hour).Unix(), ExpiresAtUnix: now.Add(time.Hour).Unix(),
	}
	return record, pin, identity, provider
}

func privacyClearUsage(prompt, completion, verifiedAt int64) map[string]any {
	return map[string]any{
		"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
		"macprovider": map[string]any{
			"requested_privacy_mode": "relay_blind_required", "effective_privacy_outcome": "relay_blind_satisfied",
			"scope": requestScope,
			"settlement": map[string]string{
				"verified_model_settlement": "unavailable_for_relay_blind_request",
				"usage_settlement":          "standard_usage_settlement_and_clear_cap_enforcement_still_apply",
			},
			"privacy": map[string]any{
				"class": relayblind.PrivacyClassV1, "assurance": relayblind.PrivacyAssurance, "scope": privacyScope,
				"protects": privacyProtects, "does_not_protect": privacyDoesNotProtect, "residual_risks": privacyResidualRisks,
				"posture_verified_at_unix": verifiedAt,
			},
		},
	}
}

func privacyObject(usage map[string]any) map[string]any {
	return usage["macprovider"].(map[string]any)["privacy"].(map[string]any)
}

func swapPrivacyProtects(usage map[string]any) map[string]any {
	protects := append([]string(nil), privacyProtects...)
	protects[0], protects[1] = protects[1], protects[0]
	privacyObject(usage)["protects"] = protects
	return usage
}

func setPrivacyBuyerHeaders(h http.Header) {
	h.Set("X-MacProvider-Requested-Privacy-Mode", "relay_blind_required")
	h.Set("X-MacProvider-Effective-Privacy-Outcome", "relay_blind_satisfied")
	h.Set(privacyClassHeader, relayblind.PrivacyClassV1)
	h.Set(privacyAssuranceHeader, relayblind.PrivacyAssurance)
	h.Set(privacyResponseEncryptionHeader, relayblind.PrivacyResponseEncryption)
}

func privacyContent(stream bool) []byte {
	if stream {
		return []byte("data: {\"choices\":[{\"delta\":{\"content\":\"PRIVACY-COMPLETION-9b2c\"}}]}\n\n")
	}
	return []byte(`{"id":"privacy","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"PRIVACY-COMPLETION-9b2c"}}]}`)
}

func tamperCiphertext(t *testing.T, ciphertext string) string {
	t.Helper()
	raw, err := base64.RawURLEncoding.Strict().DecodeString(ciphertext)
	if err != nil || len(raw) == 0 {
		t.Fatal(err)
	}
	raw[len(raw)/2] ^= 0x01
	return base64.RawURLEncoding.EncodeToString(raw)
}

func assertPrivacyStderr(t *testing.T, stderr string) {
	t.Helper()
	for _, part := range []string{relayblind.PrivacyClassV1, relayblind.PrivacyAssurance, privacyScope} {
		if !strings.Contains(stderr, part) {
			t.Fatalf("stderr missing %q in %q", part, stderr)
		}
	}
	for _, risk := range privacyResidualRisks {
		if !strings.Contains(stderr, risk) {
			t.Fatalf("stderr missing residual %q", risk)
		}
	}
	if strings.Contains(stderr, "PRIVACY-CANARY-7f3a") || strings.Contains(stderr, "PRIVACY-COMPLETION-9b2c") || strings.Contains(stderr, "responses_visible_to_relays") {
		t.Fatalf("stderr disclosed plaintext or the relay-visible scope: %q", stderr)
	}
}

func assertPrivacyFailure(t *testing.T, err error, stderr string, calls, wantCalls int32) {
	t.Helper()
	if err == nil || !strings.HasSuffix(err.Error(), "do not resubmit") {
		t.Fatalf("err=%v", err)
	}
	if calls != wantCalls {
		t.Fatalf("calls=%d want %d", calls, wantCalls)
	}
	if stderr != "" || strings.Contains(err.Error(), "PRIVACY-CANARY") || strings.Contains(err.Error(), "PRIVACY-COMPLETION") {
		t.Fatalf("failure leaked stderr=%q err=%v", stderr, err)
	}
}

func int64Ptr(v int64) *int64 { return &v }
