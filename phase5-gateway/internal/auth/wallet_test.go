package auth

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestWalletProofVectorAndVerification(t *testing.T) {
	walletPub, walletPriv := deterministicEd25519Key(0x11)
	sessionPub, _ := deterministicEd25519Key(0x22)
	proof := WalletProof{
		Version:            WalletProofVersion,
		ChallengeID:        "wch_01HZX6Y7K4C2Q9E6J8Q0V7Z2PF",
		Audience:           "https://api.malibu.tech",
		AccountID:          "acct_cafe\u0301",
		WalletNamespace:    WalletNamespaceEd25519,
		WalletPublicKey:    base64.RawURLEncoding.EncodeToString(walletPub),
		SessionPublicKey:   base64.RawURLEncoding.EncodeToString(sessionPub),
		Nonce:              "AQIDBAUGBwgJCgsMDQ4PEA",
		ExpiresAtUnix:      1782864000,
		PerRequestTokenCap: 512,
		TotalTokenCap:      5000,
		ModelAllowlist:     []string{"llama", "caf\u00e9"},
	}

	canonical, err := CanonicalWalletProofBytes(proof)
	if err != nil {
		t.Fatalf("canonical proof: %v", err)
	}
	const wantCanonical = `{"account_id":"acct_café","aud":"https://api.malibu.tech","challenge_id":"wch_01HZX6Y7K4C2Q9E6J8Q0V7Z2PF","expires_at_unix":1782864000,"model_allowlist":["llama","café"],"nonce":"AQIDBAUGBwgJCgsMDQ4PEA","per_request_token_cap":512,"session_public_key":"oJql9HpnWYAv-VX43C0qFKXJnSO-l_hkEn_5ODRVpPA","total_token_cap":5000,"version":"wallet-session-proof-v1","wallet_namespace":"ed25519","wallet_public_key":"0EqyMnQrtKs6E2i9RhXk5tAiSrcaAWuvhSCjMsl3hzc"}`
	if string(canonical) != wantCanonical {
		t.Fatalf("canonical proof bytes:\n%s\nwant:\n%s", canonical, wantCanonical)
	}
	sum := sha256.Sum256(canonical)
	const wantSHA256 = "K2sdPyrm41z8Y-TkfKENbj1bkYEwZYEjL5ppIcbPex8"
	if got := base64.RawURLEncoding.EncodeToString(sum[:]); got != wantSHA256 {
		t.Fatalf("proof sha256=%s want %s", got, wantSHA256)
	}

	signature := base64.RawURLEncoding.EncodeToString(ed25519.Sign(walletPriv, canonical))
	const wantSignature = "RjnPlsn-zQMbVNvpmpYPQ73CNqyJgNl4f32fKOb7Qlju5V6EryddcRB76nxeNaTqHKYOxd3DdV6gcvTwfopQBg"
	if signature != wantSignature {
		t.Fatalf("proof signature=%s want %s", signature, wantSignature)
	}
	if err := VerifyWalletProof(proof, signature); err != nil {
		t.Fatalf("verify proof: %v", err)
	}
	proof.WalletNamespace = "secp256k1"
	if err := VerifyWalletProof(proof, signature); !errors.Is(err, ErrWalletAlgorithmUnsupported) {
		t.Fatalf("unsupported algorithm err=%v", err)
	}
}

func TestWalletRequestVectorHeadersAndVerification(t *testing.T) {
	sessionPub, sessionPriv := deterministicEd25519Key(0x22)
	body := []byte(`{"model":"llama","messages":[{"role":"user","content":"hi"}]}`)
	headers := http.Header{}
	headers.Set("Accept", " application/json ")
	headers.Set("Idempotency-Key", "idem-123")
	headers.Set("X-MacProvider-Conversation", "thread-7")
	headers.Set("X-MacProvider-Retry", "0")
	headers.Set("Authorization", "Bearer mps_redacted")
	headers.Set("X-MacProvider-Session-Signature", "redacted")

	headerBytes, err := SemanticHeadersBytes("/v1/chat/completions", headers)
	if err != nil {
		t.Fatalf("semantic headers: %v", err)
	}
	const wantHeaders = "accept:application/json\nidempotency-key:idem-123\nx-macprovider-conversation:thread-7\nx-macprovider-retry:0\n"
	if string(headerBytes) != wantHeaders {
		t.Fatalf("headers=%q want %q", headerBytes, wantHeaders)
	}
	obj, err := NewWalletRequestSignatureObject(
		"ws_01HZX72GJQYQE5Y7P1S2X4K6MN",
		"post",
		"/v1/chat/completions",
		"12121212-1212-4212-8212-121212121212",
		body,
		headers,
		1782863990,
	)
	if err != nil {
		t.Fatalf("request object: %v", err)
	}
	canonical, err := CanonicalWalletRequestBytes(obj)
	if err != nil {
		t.Fatalf("canonical request: %v", err)
	}
	const wantCanonical = `{"canonical_route":"/v1/chat/completions","method":"POST","raw_body_sha256":"i0WjclGPRvrAZN7YXc81Y5bxlTY6XqHVe2Sl1WKriXk","request_id":"12121212-1212-4212-8212-121212121212","semantic_headers_sha256":"91-S0AaEij4u1VxE6IKpcTbRKy-GdHUXDgvDiiyEj9k","session_id":"ws_01HZX72GJQYQE5Y7P1S2X4K6MN","timestamp_unix":1782863990,"version":"wallet-session-request-v1"}`
	if string(canonical) != wantCanonical {
		t.Fatalf("canonical request bytes:\n%s\nwant:\n%s", canonical, wantCanonical)
	}
	sum := sha256.Sum256(canonical)
	const wantSHA256 = "YW2tPyavETvGgou4aQPXD8VTb9K8tzI_qa1R1wiyvqw"
	if got := base64.RawURLEncoding.EncodeToString(sum[:]); got != wantSHA256 {
		t.Fatalf("request sha256=%s want %s", got, wantSHA256)
	}
	signature := base64.RawURLEncoding.EncodeToString(ed25519.Sign(sessionPriv, canonical))
	const wantSignature = "B6AHGAH1nPRceq0uEZ22w3Pm9oxVqf2wLLSsLD65_J75-aH24dE1OVibFoPNvhpfGp657CkIPQ_8m8lZorr5Cg"
	if signature != wantSignature {
		t.Fatal("request signature vector mismatch")
	}
	if err := VerifyWalletRequestSignature(obj, signature, sessionPub, time.Unix(1782864000, 0), 5*time.Minute, 30*time.Second); err != nil {
		t.Fatalf("verify request: %v", err)
	}
}

func TestWalletJSONRejectionRules(t *testing.T) {
	walletPub, _ := deterministicEd25519Key(0x11)
	sessionPub, _ := deterministicEd25519Key(0x22)
	challenge := `{"wallet_namespace":"ed25519","wallet_public_key":"` + base64.RawURLEncoding.EncodeToString(walletPub) + `","session_public_key":"` + base64.RawURLEncoding.EncodeToString(sessionPub) + `","expires_at_unix":1782864000,"per_request_token_cap":512,"total_token_cap":5000,"model_allowlist":["llama"]}`
	if _, err := DecodeWalletChallengeRequestJSON([]byte(challenge)); err != nil {
		t.Fatalf("valid challenge json: %v", err)
	}
	if _, err := DecodeWalletChallengeRequestJSON([]byte(strings.Replace(challenge, `"model_allowlist":["llama"]`, `"model_allowlist":["llama"],"extra":true`, 1))); err == nil {
		t.Fatal("challenge unknown field accepted")
	}
	if _, err := DecodeWalletChallengeRequestJSON([]byte(strings.Replace(challenge, `"wallet_namespace":"ed25519"`, `"wallet_namespace":"secp256k1"`, 1))); !errors.Is(err, ErrWalletAlgorithmUnsupported) {
		t.Fatalf("challenge unsupported algorithm err=%v", err)
	}

	valid := `{"version":"wallet-session-proof-v1","challenge_id":"wch_1","aud":"https://api.malibu.tech","account_id":"acct_1","wallet_namespace":"ed25519","wallet_public_key":"` + base64.RawURLEncoding.EncodeToString(walletPub) + `","session_public_key":"` + base64.RawURLEncoding.EncodeToString(sessionPub) + `","nonce":"AQID","expires_at_unix":1782864000,"per_request_token_cap":512,"total_token_cap":5000,"model_allowlist":["llama"]}`
	if _, _, err := DecodeWalletProofJSON([]byte(valid)); err != nil {
		t.Fatalf("valid proof json: %v", err)
	}

	tests := []struct {
		name string
		raw  string
	}{
		{name: "duplicate", raw: strings.Replace(valid, `"version":"wallet-session-proof-v1"`, `"version":"wallet-session-proof-v1","version":"wallet-session-proof-v1"`, 1)},
		{name: "unknown", raw: strings.Replace(valid, `"model_allowlist":["llama"]`, `"model_allowlist":["llama"],"extra":true`, 1)},
		{name: "float", raw: strings.Replace(valid, `"expires_at_unix":1782864000`, `"expires_at_unix":1782864000.0`, 1)},
		{name: "negative", raw: strings.Replace(valid, `"expires_at_unix":1782864000`, `"expires_at_unix":-1`, 1)},
		{name: "base64 padding", raw: strings.Replace(valid, `"nonce":"AQID"`, `"nonce":"AQID="`, 1)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, err := DecodeWalletProofJSON([]byte(tc.raw)); err == nil {
				t.Fatal("DecodeWalletProofJSON succeeded, want error")
			}
		})
	}

	proof, canonical, err := DecodeWalletProofJSON([]byte(valid))
	if err != nil {
		t.Fatalf("proof for registration: %v", err)
	}
	_, priv := deterministicEd25519Key(0x11)
	signature := base64.RawURLEncoding.EncodeToString(ed25519.Sign(priv, canonical))
	registration := `{"proof":` + valid + `,"wallet_signature":"` + signature + `"}`
	decodedRegistration, decodedCanonical, err := DecodeWalletRegistrationRequestJSON([]byte(registration))
	if err != nil {
		t.Fatalf("registration decode: %v", err)
	}
	if !reflect.DeepEqual(decodedRegistration.Proof, proof) || string(decodedCanonical) != string(canonical) {
		t.Fatal("registration proof did not preserve canonical signed object")
	}
	badNested := strings.Replace(registration, `"challenge_id":"wch_1"`, `"challenge_id":"wch_1","challenge_id":"wch_1"`, 1)
	if _, _, err := DecodeWalletRegistrationRequestJSON([]byte(badNested)); err == nil {
		t.Fatal("nested duplicate registration proof field accepted")
	}
	if _, _, err := DecodeWalletRegistrationRequestJSON([]byte(registration + `{"extra":true}`)); err == nil {
		t.Fatal("registration trailing JSON accepted")
	}
}

func TestWalletRequestValidationHelpers(t *testing.T) {
	validID := "12121212-1212-4212-8212-121212121212"
	if !ValidateUUIDv4RequestID(validID) {
		t.Fatal("valid UUIDv4 rejected")
	}
	for _, id := range []string{
		"12121212-1212-4212-7212-121212121212",
		"12121212-1212-3212-8212-121212121212",
		"12121212-1212-4212-8212-12121212121Z",
		"12121212-1212-4212-8212-12121212121A",
	} {
		if ValidateUUIDv4RequestID(id) {
			t.Fatalf("invalid UUIDv4 accepted: %s", id)
		}
	}

	now := time.Unix(1000, 0)
	if err := ValidateWalletRequestFreshness(1000, now, 5*time.Minute, 30*time.Second); err != nil {
		t.Fatalf("fresh timestamp rejected: %v", err)
	}
	if err := ValidateWalletRequestFreshness(699, now, 5*time.Minute, 30*time.Second); !errors.Is(err, ErrWalletSignatureStale) {
		t.Fatalf("stale err=%v", err)
	}
	if err := ValidateWalletRequestFreshness(1031, now, 5*time.Minute, 30*time.Second); !errors.Is(err, ErrWalletSignatureStale) {
		t.Fatalf("future err=%v", err)
	}

	h := http.Header{}
	h.Add("Accept", "application/json")
	h.Add("Accept", "text/event-stream")
	if _, err := SemanticHeadersBytes("/v1/messages", h); err == nil {
		t.Fatal("repeated semantic header accepted")
	}
	emptyHash, err := SemanticHeadersSHA256Base64URL("/v1/models", http.Header{"Accept": []string{"ignored"}})
	if err != nil {
		t.Fatalf("metadata headers: %v", err)
	}
	shaEmpty := sha256.Sum256(nil)
	if emptyHash != base64.RawURLEncoding.EncodeToString(shaEmpty[:]) {
		t.Fatalf("metadata hash=%s", emptyHash)
	}
}

func TestWalletFingerprintIsKeyed(t *testing.T) {
	walletPub, _ := deterministicEd25519Key(0x11)
	pub := base64.RawURLEncoding.EncodeToString(walletPub)
	fp1, err := WalletFingerprint([]byte("01234567890123456789012345678901"), WalletNamespaceEd25519, pub)
	if err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	fp2, err := WalletFingerprint([]byte("different-012345678901234567890"), WalletNamespaceEd25519, pub)
	if err != nil {
		t.Fatalf("fingerprint 2: %v", err)
	}
	if fp1 == fp2 || fp1 == pub {
		t.Fatalf("fingerprint not keyed/pseudonymous: fp1=%s fp2=%s pub=%s", fp1, fp2, pub)
	}
}

func deterministicEd25519Key(seedByte byte) (ed25519.PublicKey, ed25519.PrivateKey) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = seedByte
	}
	priv := ed25519.NewKeyFromSeed(seed)
	return priv.Public().(ed25519.PublicKey), priv
}
