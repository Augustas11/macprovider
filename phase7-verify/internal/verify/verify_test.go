package verify

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/cache"
	"github.com/augstar/macprovider/phase7-verify/internal/canon"
)

const testProviderID = "m1-anon"

var verifyNow = time.Date(2026, 6, 23, 12, 0, 0, 0, time.UTC)

func TestVerifyAcceptanceAC18ThroughAC23(t *testing.T) {
	tests := []struct {
		name        string
		mutate      func(*verifyFixture)
		status      int
		offline     bool
		explicit    bool
		wantResult  string
		wantReason  string
		wantDetails string
		wantCalls   int32
		wantWarning string
	}{
		{
			name:       "AC-18 valid live current key",
			wantResult: resultValid,
			wantReason: reasonValid,
			wantCalls:  1,
		},
		{
			name: "AC-19 response content flip reports output hash mismatch",
			mutate: func(f *verifyFixture) {
				f.response["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)["content"] = "goodbye"
			},
			wantResult:  resultInvalid,
			wantReason:  reasonOutputHashMismatch,
			wantDetails: "output_hash",
			wantCalls:   1,
		},
		{
			name: "AC-20 request content flip reports prompt hash mismatch",
			mutate: func(f *verifyFixture) {
				f.request["messages"].([]any)[0].(map[string]any)["content"] = "different prompt"
			},
			wantResult:  resultInvalid,
			wantReason:  reasonPromptHashMismatch,
			wantDetails: "prompt_hash",
			wantCalls:   1,
		},
		{
			name: "AC-21 tuple byte mutation fails signature before hash checks",
			mutate: func(f *verifyFixture) {
				f.header = mutateTupleUnixTS(t, f.header, f.unixTS)
			},
			wantResult:  resultInvalid,
			wantReason:  reasonSignatureFailed,
			wantDetails: "signature",
			wantCalls:   1,
		},
		{
			name:        "AC-22 unreachable live with no cache is inconclusive",
			status:      http.StatusInternalServerError,
			wantResult:  resultInconclusive,
			wantReason:  reasonPubkeyUnresolvable,
			wantCalls:   1,
			wantWarning: "network_unreachable",
		},
		{
			name:        "AC-23 offline explicit pubkey uses no network",
			offline:     true,
			explicit:    true,
			wantResult:  resultValid,
			wantReason:  reasonValid,
			wantCalls:   0,
			wantWarning: "offline_flag",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fixture := newVerifyFixture(t, makeKey(1), verifyNow.Unix())
			if tt.mutate != nil {
				tt.mutate(fixture)
			}

			var calls int32
			status := tt.status
			if status == 0 {
				status = http.StatusOK
			}
			server := receiptKeyServer(t, resolverResponse{
				current: fixture.pub,
				status:  status,
				calls:   &calls,
			})
			defer server.Close()

			input := VerifyInput{
				Header:     fixture.header,
				Request:    fixture.request,
				Response:   fixture.response,
				ProviderID: testProviderID,
			}
			if tt.explicit {
				input.ExplicitPubkey = fixture.pub
			}
			result, err := Verify(input, VerifyOpts{
				Offline:         tt.offline,
				CoordinatorHost: server.URL,
				HTTPClient:      server.Client(),
				Cache:           openTempCache(t),
				Now:             func() time.Time { return verifyNow },
			})
			if err != nil {
				t.Fatalf("Verify: %v", err)
			}
			assertResult(t, result, tt.wantResult, tt.wantReason)
			if tt.wantDetails != "" && (result.Details == nil || result.Details.Field != tt.wantDetails) {
				t.Fatalf("details.field = %#v, want %q", result.Details, tt.wantDetails)
			}
			if got := atomic.LoadInt32(&calls); got != tt.wantCalls {
				t.Fatalf("network calls = %d, want %d", got, tt.wantCalls)
			}
			if tt.wantWarning != "" {
				assertWarningReason(t, result, tt.wantWarning)
			}
		})
	}
}

func TestVerifyAC24JSONResultShape(t *testing.T) {
	fixture := newVerifyFixture(t, makeKey(2), verifyNow.Unix())
	server := receiptKeyServer(t, resolverResponse{current: fixture.pub, status: http.StatusOK})
	defer server.Close()

	result, err := Verify(VerifyInput{
		Header:     fixture.header,
		Request:    fixture.request,
		Response:   fixture.response,
		ProviderID: testProviderID,
	}, VerifyOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           openTempCache(t),
		Now:             func() time.Time { return verifyNow },
	})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}

	data, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("Marshal result: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("Unmarshal result JSON: %v", err)
	}
	for _, key := range []string{"result", "reason", "provider_id", "model_id", "signed_at", "trust_source", "coordinator_host"} {
		if _, ok := decoded[key]; !ok {
			t.Fatalf("JSON result missing key %q in %s", key, data)
		}
	}
	if _, ok := decoded["Result"]; ok {
		t.Fatalf("JSON used Go field name instead of schema key: %s", data)
	}
}

func TestVerifyAC25StateAndTypedErrorBoundary(t *testing.T) {
	exitForResult := func(result Result) int {
		switch result.Result {
		case resultValid:
			return 0
		case resultInvalid:
			return 1
		case resultInconclusive:
			return 2
		default:
			return -1
		}
	}
	if got := exitForResult(Result{Result: resultValid}); got != 0 {
		t.Fatalf("valid exit = %d, want 0", got)
	}
	if got := exitForResult(Result{Result: resultInvalid}); got != 1 {
		t.Fatalf("invalid exit = %d, want 1", got)
	}
	if got := exitForResult(Result{Result: resultInconclusive}); got != 2 {
		t.Fatalf("inconclusive exit = %d, want 2", got)
	}

	_, err := Verify(VerifyInput{}, VerifyOpts{Cache: openTempCache(t), Now: func() time.Time { return verifyNow }})
	var usageErr *UsageError
	if !errors.As(err, &usageErr) {
		t.Fatalf("missing receipt error = %T %[1]v, want UsageError (exit 64)", err)
	}

	_, err = Verify(VerifyInput{Header: "not-a-receipt"}, VerifyOpts{Cache: openTempCache(t), Now: func() time.Time { return verifyNow }})
	var formatErr *InputFormatError
	if !errors.As(err, &formatErr) {
		t.Fatalf("bad receipt error = %T %[1]v, want InputFormatError (exit 65)", err)
	}
}

func TestVerifyAC26StaleCacheTriggersLiveFetch(t *testing.T) {
	key := makeKey(3)
	fixture := newVerifyFixture(t, key, verifyNow.Unix())
	c := openTempCache(t)

	var calls int32
	server := receiptKeyServer(t, resolverResponse{current: publicKey(key), status: http.StatusOK, calls: &calls})
	defer server.Close()
	writeCacheEntry(t, c, serverHost(t, server), testProviderID, makePubkey(99), verifyNow.Add(-8*24*time.Hour), nil)

	result, err := Verify(VerifyInput{
		Header:     fixture.header,
		Request:    fixture.request,
		Response:   fixture.response,
		ProviderID: testProviderID,
	}, VerifyOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return verifyNow },
	})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	assertResult(t, result, resultValid, reasonValid)
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("network calls = %d, want stale-cache live refresh", got)
	}
}

func TestVerifyAC26StaleCacheLiveFailureIsInconclusive(t *testing.T) {
	key := makeKey(4)
	fixture := newVerifyFixture(t, key, verifyNow.Unix())
	c := openTempCache(t)

	server := receiptKeyServer(t, resolverResponse{current: publicKey(key), status: http.StatusInternalServerError})
	defer server.Close()
	writeCacheEntry(t, c, serverHost(t, server), testProviderID, publicKey(key), verifyNow.Add(-8*24*time.Hour), nil)

	result, err := Verify(VerifyInput{
		Header:     fixture.header,
		Request:    fixture.request,
		Response:   fixture.response,
		ProviderID: testProviderID,
	}, VerifyOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return verifyNow },
	})
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	assertResult(t, result, resultInconclusive, reasonCacheStaleAndLiveUnreachable)
}

func TestVerifyAC27PreviousKeyGraceWindow(t *testing.T) {
	current := makePubkey(5)
	prevPriv := makeKey(6)
	prev := publicKey(prevPriv)
	rotatedAt := verifyNow.Add(-time.Hour)
	expiresAt := rotatedAt.Add(7 * 24 * time.Hour)

	tests := []struct {
		name       string
		unixTS     int64
		wantResult string
		wantReason string
	}{
		{
			name:       "lower boundary rotated_at minus 60 seconds is valid",
			unixTS:     rotatedAt.Add(-60 * time.Second).Unix(),
			wantResult: resultValid,
			wantReason: reasonValid,
		},
		{
			name:       "upper boundary expires_at is valid",
			unixTS:     expiresAt.Unix(),
			wantResult: resultValid,
			wantReason: reasonValid,
		},
		{
			name:       "after expires_at is invalid",
			unixTS:     expiresAt.Add(time.Second).Unix(),
			wantResult: resultInvalid,
			wantReason: reasonPreviousKeyOutsideGraceWindow,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fixture := newVerifyFixture(t, prevPriv, tt.unixTS)
			server := receiptKeyServer(t, resolverResponse{
				current: current,
				prev: &previousResponse{
					pubkey:    prev,
					rotatedAt: rotatedAt,
					expiresAt: expiresAt,
				},
				status: http.StatusOK,
			})
			defer server.Close()

			result, err := Verify(VerifyInput{
				Header:     fixture.header,
				Request:    fixture.request,
				Response:   fixture.response,
				ProviderID: testProviderID,
			}, VerifyOpts{
				CoordinatorHost: server.URL,
				HTTPClient:      server.Client(),
				Cache:           openTempCache(t),
				Now:             func() time.Time { return verifyNow },
			})
			if err != nil {
				t.Fatalf("Verify: %v", err)
			}
			assertResult(t, result, tt.wantResult, tt.wantReason)
			if tt.wantResult == resultInvalid && (result.Details == nil || result.Details.Field != "grace_window") {
				t.Fatalf("details = %#v, want grace_window", result.Details)
			}
		})
	}
}

func TestVerifyPubkeyNotEndorsedAndExplicitDoesNotBypassSignature(t *testing.T) {
	t.Run("endorsed provider with different receipt pubkey is invalid", func(t *testing.T) {
		fixture := newVerifyFixture(t, makeKey(7), verifyNow.Unix())
		server := receiptKeyServer(t, resolverResponse{current: makePubkey(8), status: http.StatusOK})
		defer server.Close()

		result, err := Verify(VerifyInput{
			Header:     fixture.header,
			Request:    fixture.request,
			Response:   fixture.response,
			ProviderID: testProviderID,
		}, VerifyOpts{
			CoordinatorHost: server.URL,
			HTTPClient:      server.Client(),
			Cache:           openTempCache(t),
			Now:             func() time.Time { return verifyNow },
		})
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		assertResult(t, result, resultInvalid, reasonPubkeyNotEndorsed)
		if result.Details == nil || result.Details.Field != "pubkey" {
			t.Fatalf("details = %#v, want pubkey", result.Details)
		}
	})

	t.Run("explicit wrong pubkey still fails signature", func(t *testing.T) {
		fixture := newVerifyFixture(t, makeKey(9), verifyNow.Unix())
		result, err := Verify(VerifyInput{
			Header:         fixture.header,
			Request:        fixture.request,
			Response:       fixture.response,
			ProviderID:     testProviderID,
			ExplicitPubkey: makePubkey(10),
		}, VerifyOpts{
			Offline: true,
			Cache:   openTempCache(t),
			Now:     func() time.Time { return verifyNow },
		})
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		assertResult(t, result, resultInvalid, reasonSignatureFailed)
	})
}

func TestVerifyProviderNotInPoolAndClockSkewWarning(t *testing.T) {
	t.Run("404 maps to provider_id_not_in_pool", func(t *testing.T) {
		fixture := newVerifyFixture(t, makeKey(11), verifyNow.Unix())
		server := receiptKeyServer(t, resolverResponse{current: fixture.pub, status: http.StatusNotFound})
		defer server.Close()

		result, err := Verify(VerifyInput{
			Header:     fixture.header,
			Request:    fixture.request,
			Response:   fixture.response,
			ProviderID: testProviderID,
		}, VerifyOpts{
			CoordinatorHost: server.URL,
			HTTPClient:      server.Client(),
			Cache:           openTempCache(t),
			Now:             func() time.Time { return verifyNow },
		})
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		assertResult(t, result, resultInconclusive, reasonProviderIDNotInPool)
	})

	t.Run("unresolved provider id maps to spec-legal pubkey_unresolvable", func(t *testing.T) {
		fixture := newVerifyFixture(t, makeKey(13), verifyNow.Unix())
		result, err := Verify(VerifyInput{
			Header:   fixture.header,
			Request:  fixture.request,
			Response: fixture.response,
		}, VerifyOpts{
			Cache: openTempCache(t),
			Now:   func() time.Time { return verifyNow },
		})
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		assertResult(t, result, resultInconclusive, reasonPubkeyUnresolvable)
		assertWarningReason(t, result, "provider_id_unresolvable")
	})

	t.Run("clock skew is warning only", func(t *testing.T) {
		fixture := newVerifyFixture(t, makeKey(12), verifyNow.Add(-25*time.Hour).Unix())
		server := receiptKeyServer(t, resolverResponse{current: fixture.pub, status: http.StatusOK})
		defer server.Close()

		result, err := Verify(VerifyInput{
			Header:     fixture.header,
			Request:    fixture.request,
			Response:   fixture.response,
			ProviderID: testProviderID,
		}, VerifyOpts{
			CoordinatorHost: server.URL,
			HTTPClient:      server.Client(),
			Cache:           openTempCache(t),
			Now:             func() time.Time { return verifyNow },
		})
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		assertResult(t, result, resultValid, reasonValid)
		assertWarningKind(t, result, "clock_skew")
	})
}

type verifyFixture struct {
	header   string
	request  map[string]any
	response map[string]any
	pub      []byte
	unixTS   int64
}

func newVerifyFixture(t *testing.T, priv ed25519.PrivateKey, unixTS int64) *verifyFixture {
	t.Helper()
	pub := priv.Public().(ed25519.PublicKey)
	request := baseRequest()
	response := baseResponse()
	_, promptHash, err := canon.CanonicalPrompt(request)
	if err != nil {
		t.Fatalf("CanonicalPrompt: %v", err)
	}
	_, outputHash, err := canon.CanonicalOutput(response)
	if err != nil {
		t.Fatalf("CanonicalOutput: %v", err)
	}
	tupleRaw := []byte(fmt.Sprintf(
		`{"model_id":"fixture-model","prompt_hash":"%x","output_hash":"%x","provider_pubkey":"%s","ttft_ms":123,"tokens_out":4,"unix_ts":%d}`,
		promptHash,
		outputHash,
		base64.StdEncoding.EncodeToString(pub),
		unixTS,
	))
	signature := ed25519.Sign(priv, tupleRaw)
	return &verifyFixture{
		header:   base64.StdEncoding.EncodeToString(tupleRaw) + "." + base64.StdEncoding.EncodeToString(signature),
		request:  request,
		response: response,
		pub:      pub,
		unixTS:   unixTS,
	}
}

func baseRequest() map[string]any {
	return map[string]any{
		"model": "fixture-model",
		"messages": []any{
			map[string]any{
				"role":    "user",
				"content": "hello",
			},
		},
	}
}

func baseResponse() map[string]any {
	return map[string]any{
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"content": "world",
				},
				"finish_reason": "stop",
			},
		},
	}
}

type resolverResponse struct {
	current []byte
	prev    *previousResponse
	status  int
	calls   *int32
}

type previousResponse struct {
	pubkey    []byte
	rotatedAt time.Time
	expiresAt time.Time
}

func receiptKeyServer(t *testing.T, response resolverResponse) *httptest.Server {
	t.Helper()
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if response.calls != nil {
			atomic.AddInt32(response.calls, 1)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/v1/receipt-keys/"+testProviderID {
			t.Fatalf("path = %s, want /v1/receipt-keys/%s", r.URL.Path, testProviderID)
		}
		if response.status != http.StatusOK {
			w.WriteHeader(response.status)
			_, _ = w.Write([]byte(`{"error":{"code":"provider_not_found"}}`))
			return
		}
		body := map[string]any{
			"provider_id":         testProviderID,
			"receipt_pubkey":      base64.StdEncoding.EncodeToString(response.current),
			"receipt_pubkey_prev": nil,
			"fetched_at":          verifyNow.Format(time.RFC3339),
		}
		if response.prev != nil {
			body["receipt_pubkey_prev"] = map[string]any{
				"pubkey":     base64.StdEncoding.EncodeToString(response.prev.pubkey),
				"rotated_at": response.prev.rotatedAt.UTC().Format(time.RFC3339),
				"expires_at": response.prev.expiresAt.UTC().Format(time.RFC3339),
			}
		}
		if err := json.NewEncoder(w).Encode(body); err != nil {
			t.Fatalf("encode resolver response: %v", err)
		}
	}))
}

func makeKey(seedByte byte) ed25519.PrivateKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = seedByte + byte(i)
	}
	return ed25519.NewKeyFromSeed(seed)
}

func makePubkey(seedByte byte) []byte {
	return publicKey(makeKey(seedByte))
}

func publicKey(priv ed25519.PrivateKey) []byte {
	return []byte(priv.Public().(ed25519.PublicKey))
}

func mutateTupleUnixTS(t *testing.T, header string, unixTS int64) string {
	t.Helper()
	parts := strings.Split(header, ".")
	if len(parts) != 2 {
		t.Fatalf("fixture header is malformed")
	}
	tupleRaw, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode tuple: %v", err)
	}
	from := []byte(fmt.Sprintf(`"unix_ts":%d`, unixTS))
	to := []byte(fmt.Sprintf(`"unix_ts":%d`, unixTS+1))
	if !strings.Contains(string(tupleRaw), string(from)) {
		t.Fatalf("tuple does not contain unix_ts fragment %q: %s", from, tupleRaw)
	}
	mutated := strings.Replace(string(tupleRaw), string(from), string(to), 1)
	return base64.StdEncoding.EncodeToString([]byte(mutated)) + "." + parts[1]
}

func openTempCache(t *testing.T) *cache.Cache {
	t.Helper()
	c, err := cache.Open(filepath.Join(t.TempDir(), "verify-cache.jsonl"))
	if err != nil {
		t.Fatalf("cache Open: %v", err)
	}
	return c
}

func writeCacheEntry(t *testing.T, c *cache.Cache, coordinatorHost, providerID string, pubkey []byte, fetchedAt time.Time, prev *previousResponse) {
	t.Helper()
	line := map[string]any{
		"coordinator_host":    coordinatorHost,
		"provider_id":         providerID,
		"receipt_pubkey":      base64.StdEncoding.EncodeToString(pubkey),
		"receipt_pubkey_prev": nil,
		"fetched_at":          fetchedAt.UTC().Format(time.RFC3339),
	}
	if prev != nil {
		line["receipt_pubkey_prev"] = map[string]any{
			"pubkey":     base64.StdEncoding.EncodeToString(prev.pubkey),
			"rotated_at": prev.rotatedAt.UTC().Format(time.RFC3339),
			"expires_at": prev.expiresAt.UTC().Format(time.RFC3339),
		}
	}
	data, err := json.Marshal(line)
	if err != nil {
		t.Fatalf("marshal cache line: %v", err)
	}
	if err := os.WriteFile(c.Path(), append(data, '\n'), 0o600); err != nil {
		t.Fatalf("write cache: %v", err)
	}
}

func serverHost(t *testing.T, server *httptest.Server) string {
	t.Helper()
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}
	return parsed.Host
}

func assertResult(t *testing.T, result Result, wantResult, wantReason string) {
	t.Helper()
	if result.Result != wantResult || result.Reason != wantReason {
		t.Fatalf("result=(%s,%s), want (%s,%s): %#v", result.Result, result.Reason, wantResult, wantReason, result)
	}
}

func assertWarningReason(t *testing.T, result Result, wantReason string) {
	t.Helper()
	for _, warning := range result.Warnings {
		if warning.Kind == "live_check_skipped" && warning.Fields["reason"] == wantReason {
			return
		}
	}
	t.Fatalf("missing live_check_skipped warning reason=%q in %#v", wantReason, result.Warnings)
}

func assertWarningKind(t *testing.T, result Result, kind string) {
	t.Helper()
	for _, warning := range result.Warnings {
		if warning.Kind == kind {
			return
		}
	}
	t.Fatalf("missing warning kind=%q in %#v", kind, result.Warnings)
}
