package router

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/sourceevidence"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

const (
	refusalTestSourceSHA = "0123456789abcdef0123456789abcdef01234567"
	refusalTestNonce     = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	refusalTestRunID     = "trusted-pool-model-20260529T000000Z"
	refusalTestPoolModel = "pool/" + testPoolID + "/qwen25-05b-mlx8"
)

var refusalTestIntentKey = []byte("0123456789abcdef0123456789abcdef")

// refusalTestSigner provisions a reviewed registry and an Ed25519 key in a
// temp dir, exactly as the fixed release provenance would.
func refusalTestSigner(t *testing.T) (*sourceevidence.Signer, ed25519.PublicKey) {
	t.Helper()
	dir := t.TempDir()
	seed := sha256.Sum256([]byte("gateway refusal test key"))
	priv := ed25519.NewKeyFromSeed(seed[:])
	pub := priv.Public().(ed25519.PublicKey)
	registry := map[string]any{
		"schema_version": "macprovider.source-evidence-key-registry.v1",
		"keys": []any{map[string]any{
			"key_id": "gateway-test-1", "algorithm": "ed25519", "public_key": base64.RawURLEncoding.EncodeToString(pub),
			"producer": "gateway", "instance_id": "gateway-test", "permitted_roles": []any{"refusal_intent"},
			"permitted_domains": []any{"macprovider.source-authenticated-export.v1"},
			"not_before":        "2026-01-01T00:00:00.000Z", "not_after": "2027-01-01T00:00:00.000Z", "revoked_at": nil,
			"reviewed_source_constraints": map[string]any{"source_sha_allowlist": []any{refusalTestSourceSHA}, "notes": "test key"},
		}},
	}
	canonical, err := sourceevidence.CanonicalBytes(registry)
	if err != nil {
		t.Fatalf("CanonicalBytes: %v", err)
	}
	registryPath := filepath.Join(dir, "registry.json")
	keyPath := filepath.Join(dir, "signing.key")
	if err := os.WriteFile(registryPath, canonical, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, []byte(hex.EncodeToString(seed[:])), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(canonical)
	signer, err := sourceevidence.NewSigner(keyPath, sourceevidence.FixedProvenance{
		InstanceID: "gateway-test", SourceSHA: refusalTestSourceSHA, KeyID: "gateway-test-1",
		ReviewedRegistryPath: registryPath, RegistryDigest: "sha256:" + hex.EncodeToString(sum[:]),
		Now: func() time.Time { return fixedNow().Add(time.Minute) },
	})
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	return signer, pub
}

// newRefusalHarness wires a pool-enabled gateway whose fake coordinator
// answers chat with the given status/body. routeable controls whether the
// selected pool is routeable (false models a paused pool).
func newRefusalHarness(t *testing.T, enabled, routeable bool, chatStatus int, chatBody string) (http.Handler, *sqlite.Store, string, *int) {
	t.Helper()
	chatHits := 0
	routing := `{"pools":{"enabled":true,"routeable_pools":[]}}`
	if routeable {
		routing = `{"pools":{"enabled":true,"routeable_pools":["` + testPoolID + `"]}}`
	}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/internal/routing":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, routing), nil
		case "/v1/chat/completions":
			chatHits++
			return responseWithBody(chatStatus, http.Header{"Content-Type": []string{"application/json"}}, chatBody), nil
		}
		t.Fatalf("unexpected coordinator path %s", r.URL.Path)
		return nil, nil
	})}
	opts := []Option{WithHTTPClient(client)}
	if enabled {
		signer, _ := refusalTestSigner(t)
		opts = append(opts, WithRefusalEvidence(refusalTestIntentKey, 0, signer, 0))
	}
	h, st, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Features.TrustedPools = config.TrustedPoolsConfig{Enabled: true, AccountPools: map[string][]string{"acct_pool": {testPoolID}}}
	}, opts...)
	return h, st, createAccountAndKey(t, st, cfg, "acct_pool"), &chatHits
}

func postRefusalExport(t *testing.T, h http.Handler, bearer string, scopes []sourceevidence.Intent, nonce string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"schema_version": sourceevidence.RequestSchema, "run_id": refusalTestRunID, "challenge_nonce": nonce, "scopes": scopes,
	})
	req := httptest.NewRequest(http.MethodPost, refusalEvidenceExportPath, strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer "+bearer)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func TestRefusalEvidenceRecordsAndExportsPoolRefusals(t *testing.T) {
	const notFound = `{"error":{"type":"invalid_request_error","code":"model_not_found","message":"The requested model is not available"}}`
	cases := []struct {
		name          string
		routeable     bool
		headers       map[string]string
		wantStatus    int
		wantCode      string
		wantTerminal  string
		wantForwarded bool
		wantQuota     string
		wantChatHits  int
	}{
		{
			name: "paused pool refuses before quota", routeable: false,
			headers:    map[string]string{"X-MacProvider-Pool-Select": testPoolID, "X-MacProvider-Engine-Select": "llamacpp"},
			wantStatus: http.StatusServiceUnavailable, wantCode: "pool_unavailable",
			wantTerminal: storage.RefusalTerminalPreQuota, wantForwarded: false, wantQuota: "none", wantChatHits: 0,
		},
		{
			name: "pool model without a pool header is refunded", routeable: true,
			headers:    map[string]string{},
			wantStatus: http.StatusNotFound, wantCode: "model_not_found",
			wantTerminal: storage.RefusalTerminalPostReservation, wantForwarded: true, wantQuota: "refunded", wantChatHits: 1,
		},
		{
			name: "selected pool refusal is refunded", routeable: true,
			headers:    map[string]string{"X-MacProvider-Pool-Select": testPoolID},
			wantStatus: http.StatusNotFound, wantCode: "model_not_found",
			wantTerminal: storage.RefusalTerminalPostReservation, wantForwarded: true, wantQuota: "refunded", wantChatHits: 1,
		},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h, st, key, chatHits := newRefusalHarness(t, true, tc.routeable, http.StatusNotFound, notFound)
			rid := "00000000-0000-4000-8000-00000000000" + string(rune('1'+i))
			headers := map[string]string{"X-Request-ID": rid}
			for k, v := range tc.headers {
				headers[k] = v
			}
			resp := postChat(t, h, key, `{"model":"`+refusalTestPoolModel+`","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, headers)
			if resp.Code != tc.wantStatus {
				t.Fatalf("status=%d body=%s, want %d", resp.Code, resp.Body.String(), tc.wantStatus)
			}
			assertErrorCode(t, resp.Body.String(), tc.wantCode)
			if *chatHits != tc.wantChatHits {
				t.Fatalf("chat hits=%d, want %d", *chatHits, tc.wantChatHits)
			}
			resolved, err := st.ResolveRefusalRecords(context.Background(), []storage.RefusalRecordKey{{AccountID: "acct_pool", ExternalRequestID: rid}})
			if err != nil {
				t.Fatalf("ResolveRefusalRecords: %v", err)
			}
			rec := resolved[0].Record
			if rec.TerminalKind != tc.wantTerminal || rec.Forwarded != tc.wantForwarded || rec.Status != tc.wantStatus || rec.ErrorCode != tc.wantCode {
				t.Fatalf("record=%+v", rec)
			}
			intent := sourceevidence.Intent{AccountID: "acct_pool", ExternalRequestID: rid, Model: refusalTestPoolModel,
				PoolSelect: tc.headers["X-MacProvider-Pool-Select"], EngineSelect: tc.headers["X-MacProvider-Engine-Select"]}
			if rec.IntentCommitment != sourceevidence.IntentCommitment(refusalTestIntentKey, intent) {
				t.Fatalf("intent commitment does not bind the request intent")
			}
			if strings.Contains(rec.IntentCommitment, testPoolID) || len(rec.IntentCommitment) != 64 {
				t.Fatalf("stored commitment leaks or is malformed: %q", rec.IntentCommitment)
			}

			export := postRefusalExport(t, h, "operator-key", []sourceevidence.Intent{intent}, refusalTestNonce)
			if export.Code != http.StatusOK {
				t.Fatalf("export status=%d body=%s", export.Code, export.Body.String())
			}
			if strings.Contains(export.Body.String(), rid) || strings.Contains(export.Body.String(), testPoolID) || strings.Contains(export.Body.String(), "acct_pool") {
				t.Fatalf("export emitted raw request material: %s", export.Body.String())
			}
			var envelope struct {
				Signed     map[string]any `json:"signed"`
				Signatures []struct {
					SignedSHA256 string `json:"signed_sha256"`
					Signature    string `json:"signature"`
				} `json:"signatures"`
			}
			if err := json.Unmarshal(export.Body.Bytes(), &envelope); err != nil {
				t.Fatal(err)
			}
			records := envelope.Signed["records"].([]any)
			got := records[0].(map[string]any)
			if got["request_scope_commitment"] != sourceevidence.IntentBinding(refusalTestRunID, refusalTestNonce, intent) ||
				got["terminal_kind"] != tc.wantTerminal || got["forwarded_to_coordinator"] != tc.wantForwarded ||
				got["quota"].(map[string]any)["reservation"] != tc.wantQuota || got["usage_debit_tokens"] != float64(0) {
				t.Fatalf("exported record=%v", got)
			}
			if envelope.Signed["producer"] != "gateway" || envelope.Signed["role"] != "refusal_intent" {
				t.Fatalf("signed producer/role=%v/%v", envelope.Signed["producer"], envelope.Signed["role"])
			}
		})
	}
}

func TestRefusalEvidenceExportSignatureVerifies(t *testing.T) {
	signer, pub := refusalTestSigner(t)
	intent := sourceevidence.Intent{AccountID: "a", ExternalRequestID: "r", Model: refusalTestPoolModel}
	env, err := signer.Sign(refusalTestRunID, refusalTestNonce, fixedNow(), []map[string]any{{"request_scope_commitment": sourceevidence.IntentBinding(refusalTestRunID, refusalTestNonce, intent)}})
	if err != nil {
		t.Fatal(err)
	}
	signedBytes, err := sourceevidence.CanonicalBytes(env["signed"])
	if err != nil {
		t.Fatal(err)
	}
	sig := env["signatures"].([]map[string]any)[0]
	raw, _ := base64.RawURLEncoding.DecodeString(sig["signature"].(string))
	if !ed25519.Verify(pub, append([]byte(sourceevidence.SignDomain+"\n"), signedBytes...), raw) {
		t.Fatal("signature does not verify over the domain-separated canonical body")
	}
	sum := sha256.Sum256(signedBytes)
	if sig["signed_sha256"] != hex.EncodeToString(sum[:]) {
		t.Fatal("signed_sha256 mismatch")
	}
}

func TestRefusalEvidenceExportFailsClosed(t *testing.T) {
	h, _, key, _ := newRefusalHarness(t, true, false, http.StatusOK, poolChatOK)
	rid := "00000000-0000-4000-8000-0000000000aa"
	resp := postChat(t, h, key, `{"model":"`+refusalTestPoolModel+`","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`,
		map[string]string{"X-Request-ID": rid, "X-MacProvider-Pool-Select": testPoolID})
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d", resp.Code)
	}
	good := sourceevidence.Intent{AccountID: "acct_pool", ExternalRequestID: rid, Model: refusalTestPoolModel, PoolSelect: testPoolID}
	wrongModel := good
	wrongModel.Model = "pool/" + testPoolID + "/other"
	wrongPool := good
	wrongPool.PoolSelect = "zzzzzzzzzzzzzzzzzzzzzz"
	missing := good
	missing.ExternalRequestID = "00000000-0000-4000-8000-0000000000bb"
	for _, tc := range []struct {
		name   string
		bearer string
		scopes []sourceevidence.Intent
		nonce  string
		want   int
	}{
		{"buyer credential", key, []sourceevidence.Intent{good}, refusalTestNonce, http.StatusUnauthorized},
		{"wrong model", "operator-key", []sourceevidence.Intent{wrongModel}, refusalTestNonce, http.StatusConflict},
		{"wrong pool", "operator-key", []sourceevidence.Intent{wrongPool}, refusalTestNonce, http.StatusConflict},
		{"missing record fails the whole export", "operator-key", []sourceevidence.Intent{good, missing}, refusalTestNonce, http.StatusConflict},
		{"duplicate scope", "operator-key", []sourceevidence.Intent{good, good}, refusalTestNonce, http.StatusBadRequest},
		{"bad nonce", "operator-key", []sourceevidence.Intent{good}, "short", http.StatusBadRequest},
		{"good", "operator-key", []sourceevidence.Intent{good}, refusalTestNonce, http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := postRefusalExport(t, h, tc.bearer, tc.scopes, tc.nonce)
			if got.Code != tc.want {
				t.Fatalf("status=%d body=%s, want %d", got.Code, got.Body.String(), tc.want)
			}
			if tc.want != http.StatusOK && (strings.Contains(got.Body.String(), "other") || strings.Contains(got.Body.String(), "zzzz")) {
				t.Fatalf("error reflects input: %s", got.Body.String())
			}
		})
	}
}

func TestRefusalEvidenceRecordsNothingWhenDisabledOrNotPoolRelevant(t *testing.T) {
	const notFound = `{"error":{"type":"invalid_request_error","code":"model_not_found","message":"x"}}`
	for _, tc := range []struct {
		name    string
		enabled bool
		model   string
	}{
		{"disabled", false, refusalTestPoolModel},
		{"global model", true, "llama"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, st, key, _ := newRefusalHarness(t, tc.enabled, true, http.StatusNotFound, notFound)
			rid := "00000000-0000-4000-8000-0000000000cc"
			resp := postChat(t, h, key, `{"model":"`+tc.model+`","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, map[string]string{"X-Request-ID": rid})
			if resp.Code != http.StatusNotFound {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			_, err := st.ResolveRefusalRecords(context.Background(), []storage.RefusalRecordKey{{AccountID: "acct_pool", ExternalRequestID: rid}})
			if !errors.Is(err, storage.ErrNotFound) {
				t.Fatalf("record written: err=%v", err)
			}
			if !tc.enabled {
				if got := postRefusalExport(t, h, "operator-key", nil, refusalTestNonce); got.Code == http.StatusOK {
					t.Fatalf("export served while disabled")
				}
			}
		})
	}
}
