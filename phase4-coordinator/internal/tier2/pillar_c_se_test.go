package tier2

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// buildSEAttestationToken constructs a complete macprovider-se-p256-v1
// AttestationToken signed with the provided SE key and binding key.
// ecdhKey is the base64url X25519 / ECDH public key string from the auth initial stage.
func buildSEAttestationToken(
	t *testing.T,
	seKey *ecdsa.PrivateKey,
	bindingKey *ecdsa.PrivateKey,
	challenge []byte,
	providerID, ecdhKey string,
	issuedAt, expiresAt time.Time,
) json.RawMessage {
	t.Helper()

	// Raw P-256 public key bytes (x || y, 64 bytes).
	xBytes := seKey.PublicKey.X.Bytes()
	yBytes := seKey.PublicKey.Y.Bytes()
	// Pad to 32 bytes each.
	xPad := make([]byte, 32)
	yPad := make([]byte, 32)
	copy(xPad[32-len(xBytes):], xBytes)
	copy(yPad[32-len(yBytes):], yBytes)
	rawPub := append(xPad, yPad...)
	pubKeyB64 := base64.StdEncoding.EncodeToString(rawPub)

	// Build attestation map (will be sorted by json.Marshal).
	attestation := map[string]interface{}{
		"authenticatedRootEnabled": true,
		"chipName":                 "Apple M4",
		"encryptionPublicKey":      ecdhKey,
		"hardwareModel":            "Mac15,3",
		"osVersion":                "15.5",
		"publicKey":                pubKeyB64,
		"secureBootEnabled":        true,
		"secureEnclaveAvailable":   true,
		"sipEnabled":               true,
		"timestamp":                issuedAt.UTC().Format(time.RFC3339),
	}

	// Canonical JSON: json.Marshal sorts map keys.
	canonicalJSON, err := json.Marshal(attestation)
	if err != nil {
		t.Fatalf("marshal attestation: %v", err)
	}

	// ES256 signature over canonical attestation JSON.
	digest := sha256.Sum256(canonicalJSON)
	sig, err := seKey.Sign(rand.Reader, digest[:], crypto.SHA256)
	if err != nil {
		t.Fatalf("sign attestation: %v", err)
	}

	signed := map[string]interface{}{
		"attestation": attestation,
		"signature":   base64.StdEncoding.EncodeToString(sig),
	}
	signedJSON, err := json.Marshal(signed)
	if err != nil {
		t.Fatalf("marshal signed attestation: %v", err)
	}
	tokenField := base64.RawURLEncoding.EncodeToString(signedJSON)

	// Build the outer AttestationToken.
	outer := AttestationToken{
		Format:        seAttestationFormat,
		Token:         tokenField,
		Challenge:     base64.RawURLEncoding.EncodeToString(challenge),
		IssuedAt:      issuedAt,
		ExpiresAt:     expiresAt,
		ProviderID:    providerID,
		BinaryVersion: "1.2.0",
		Claimed: map[string]any{
			"hardware_family": "apple_silicon",
			"ram_gb":          16,
		},
		KeyBinding: AttestationKeyBinding{ProviderECDHPublicKey: ecdhKey},
	}

	// Build binding signature using the binding key (or SE key if bindingKey==nil).
	bk := bindingKey
	if bk == nil {
		bk = seKey
	}
	bindingSig, err := BuildAttestationBindingSignature(outer, "auth-test", bk)
	if err != nil {
		t.Fatalf("build binding sig: %v", err)
	}
	outer.Signature = bindingSig

	raw, err := json.Marshal(outer)
	if err != nil {
		t.Fatalf("marshal outer token: %v", err)
	}
	return raw
}

func resignSEAttestationClaims(t *testing.T, raw json.RawMessage, signer *ecdsa.PrivateKey, claims map[string]any) json.RawMessage {
	t.Helper()
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal SE token: %v", err)
	}
	if token.Claimed == nil {
		token.Claimed = map[string]any{}
	}
	for key, value := range claims {
		token.Claimed[key] = value
	}
	signature, err := BuildAttestationBindingSignature(token, "auth-test", signer)
	if err != nil {
		t.Fatalf("rebuild binding sig: %v", err)
	}
	token.Signature = signature
	out, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal SE token: %v", err)
	}
	return out
}

// TestSEAttestationRoundtrip verifies a well-formed macprovider-se-p256-v1 token
// is accepted and returns AttestationStatusAttested with the correct SE pubkey.
func TestSEAttestationRoundtrip(t *testing.T) {
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("test-challenge-roundtrip")
	ecdhKey := "dGVzdC1lY2RoLXB1YmxpY2tleQ" // stable test value

	cfg := config.Default().Tier2
	raw := buildSEAttestationToken(t, seKey, nil, challenge, "provider-se-1", ecdhKey, now.Add(-time.Minute), now.Add(time.Minute))

	result := VerifyAttestationTokenExt(raw, cfg, challenge, "auth-test", "provider-se-1", ecdhKey, nil, now, zerolog.Nop())

	if result.Status != pool.AttestationStatusAttested {
		t.Fatalf("status=%q want attested", result.Status)
	}
	if result.SEResult == nil {
		t.Fatal("SEResult is nil; expected SE public key")
	}
	if len(result.SEResult.SEPublicKey) != rawP256PubkeyBytes {
		t.Fatalf("SEPublicKey len=%d want %d", len(result.SEResult.SEPublicKey), rawP256PubkeyBytes)
	}
	// Verify the returned raw key reconstructs to the same ECDSA key.
	recovered, err := rawP256ToECDSA(result.SEResult.SEPublicKey)
	if err != nil {
		t.Fatalf("rawP256ToECDSA: %v", err)
	}
	if recovered.X.Cmp(seKey.PublicKey.X) != 0 || recovered.Y.Cmp(seKey.PublicKey.Y) != 0 {
		t.Fatal("recovered SE public key does not match original")
	}
}

func TestSEAttestationSignedModelHashMismatchWarnsButAttests(t *testing.T) {
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("model-hash-mismatch")
	ecdhKey := "dGVzdC1lY2RoLXB1YmxpY2tleQ"
	raw := buildSEAttestationToken(t, seKey, nil, challenge, "provider-se-1", ecdhKey, now.Add(-time.Minute), now.Add(time.Minute))
	raw = resignSEAttestationClaims(t, raw, seKey, map[string]any{
		"model_id":   "model-a",
		"model_hash": otherHash,
	})
	catalogRaw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	cfg := config.Default().Tier2
	cfg.CatalogPath = writeTempCatalog(t, catalogRaw)
	cfg.CatalogPublicKey = publicKey
	catalog := NewCatalog()
	if err := catalog.ConfigureStrict(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("configure catalog: %v", err)
	}
	var logs bytes.Buffer

	result := VerifyAttestationTokenExtWithCatalog(raw, cfg, challenge, "auth-test", "provider-se-1", ecdhKey, "model-a", catalog, nil, now, zerolog.New(&logs))

	if result.Status != pool.AttestationStatusAttested {
		t.Fatalf("status=%q want attested", result.Status)
	}
	rawLog := logs.String()
	for _, want := range []string{
		`"event":"attestation_model_hash_mismatch"`,
		`"category":"T2.C"`,
		`"severity":"WARN"`,
		`"provider_id":"provider-se-1"`,
		`"model_id":"model-a"`,
		`"claimed_hash_prefix":"ffffffff"`,
		`"expected_hash_prefix":"01234567"`,
		`"catalog_id":"test-catalog"`,
		`"decision":"observe"`,
		`"reason":"signed_model_hash_mismatch"`,
		`"message":"tier2 attestation event"`,
	} {
		if !strings.Contains(rawLog, want) {
			t.Fatalf("attestation model-hash log missing %s: %s", want, rawLog)
		}
	}
}

func TestSEAttestationSignedModelHashMatchDoesNotWarn(t *testing.T) {
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("model-hash-match")
	ecdhKey := "dGVzdC1lY2RoLXB1YmxpY2tleQ"
	raw := buildSEAttestationToken(t, seKey, nil, challenge, "provider-se-1", ecdhKey, now.Add(-time.Minute), now.Add(time.Minute))
	raw = resignSEAttestationClaims(t, raw, seKey, map[string]any{
		"model_id":   "model-a",
		"model_hash": testHash,
	})
	catalogRaw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	cfg := config.Default().Tier2
	cfg.CatalogPath = writeTempCatalog(t, catalogRaw)
	cfg.CatalogPublicKey = publicKey
	catalog := NewCatalog()
	if err := catalog.ConfigureStrict(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("configure catalog: %v", err)
	}
	var logs bytes.Buffer

	result := VerifyAttestationTokenExtWithCatalog(raw, cfg, challenge, "auth-test", "provider-se-1", ecdhKey, "model-a", catalog, nil, now, zerolog.New(&logs))

	if result.Status != pool.AttestationStatusAttested {
		t.Fatalf("status=%q want attested", result.Status)
	}
	if strings.Contains(logs.String(), `"event":"attestation_model_hash_mismatch"`) {
		t.Fatalf("matching model hash emitted mismatch warning: %s", logs.String())
	}
}

func TestSEAttestationInvalidSignedModelHashWarnsButAttests(t *testing.T) {
	for _, tc := range []struct {
		name  string
		claim any
	}{
		{name: "uppercase", claim: strings.ToUpper(testHash)},
		{name: "blank", claim: "   "},
		{name: "non_string", claim: 123},
	} {
		t.Run(tc.name, func(t *testing.T) {
			seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				t.Fatalf("generate key: %v", err)
			}
			now := time.Unix(1716768000, 0).UTC()
			challenge := []byte("model-hash-invalid")
			ecdhKey := "dGVzdC1lY2RoLXB1YmxpY2tleQ"
			raw := buildSEAttestationToken(t, seKey, nil, challenge, "provider-se-1", ecdhKey, now.Add(-time.Minute), now.Add(time.Minute))
			raw = resignSEAttestationClaims(t, raw, seKey, map[string]any{
				"model_id":   "model-a",
				"model_hash": tc.claim,
			})
			catalogRaw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
			cfg := config.Default().Tier2
			cfg.CatalogPath = writeTempCatalog(t, catalogRaw)
			cfg.CatalogPublicKey = publicKey
			catalog := NewCatalog()
			if err := catalog.ConfigureStrict(cfg, zerolog.Nop()); err != nil {
				t.Fatalf("configure catalog: %v", err)
			}
			var logs bytes.Buffer

			result := VerifyAttestationTokenExtWithCatalog(raw, cfg, challenge, "auth-test", "provider-se-1", ecdhKey, "model-a", catalog, nil, now, zerolog.New(&logs))

			if result.Status != pool.AttestationStatusAttested {
				t.Fatalf("status=%q want attested", result.Status)
			}
			rawLog := logs.String()
			for _, want := range []string{
				`"event":"attestation_model_hash_mismatch"`,
				`"decision":"observe"`,
				`"reason":"signed_model_hash_invalid"`,
				`"message":"tier2 attestation event"`,
			} {
				if !strings.Contains(rawLog, want) {
					t.Fatalf("invalid signed model-hash log missing %s: %s", want, rawLog)
				}
			}
		})
	}
}

// TestSEAttestationChallengeMismatch verifies that a stale challenge returns
// AttestationStatusStale.
func TestSEAttestationChallengeMismatch(t *testing.T) {
	seKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("original-challenge")
	ecdhKey := "dGVzdC1lY2RoLXB1YmxpY2tleQ"

	cfg := config.Default().Tier2
	raw := buildSEAttestationToken(t, seKey, nil, challenge, "provider-se-2", ecdhKey, now.Add(-time.Minute), now.Add(time.Minute))

	result := VerifyAttestationTokenExt(raw, cfg, []byte("different-challenge"), "auth-test", "provider-se-2", ecdhKey, nil, now, zerolog.Nop())

	if result.Status != pool.AttestationStatusStale {
		t.Fatalf("status=%q want stale on challenge mismatch", result.Status)
	}
	if result.SEResult != nil {
		t.Fatal("SEResult must be nil on rejection")
	}
}

// TestSEAttestationECDHBindMismatch verifies that a mismatched ECDH key returns
// AttestationStatusFailed (encryptionPublicKey in the SE blob vs key_binding mismatch).
func TestSEAttestationECDHBindMismatch(t *testing.T) {
	seKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("bind-mismatch-challenge")
	ecdhKeyInToken := "dGVzdC1lY2RoLXB1YmxpY2tleQ"       // key embedded in SE blob
	ecdhKeyInBinding := "ZGlmZmVyZW50LWVjZGgta2V5LXZhbA" // key in outer key_binding

	cfg := config.Default().Tier2
	// Token is built with ecdhKeyInToken in the SE blob AND in the outer key_binding
	// (so outer ECDH check passes), but the coordinator presents ecdhKeyInBinding at
	// the auth initial stage — triggering the outer ecdh_binding_mismatch.
	raw := buildSEAttestationToken(t, seKey, nil, challenge, "provider-se-3", ecdhKeyInToken, now.Add(-time.Minute), now.Add(time.Minute))

	result := VerifyAttestationTokenExt(raw, cfg, challenge, "auth-test", "provider-se-3", ecdhKeyInBinding, nil, now, zerolog.Nop())

	if result.Status != pool.AttestationStatusFailed {
		t.Fatalf("status=%q want failed on ECDH mismatch", result.Status)
	}
	if result.SEResult != nil {
		t.Fatal("SEResult must be nil on rejection")
	}
}

// TestSEAttestationWrongSignature verifies that a tampered SE blob signature
// returns AttestationStatusFailed.
func TestSEAttestationWrongSignature(t *testing.T) {
	seKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	wrongKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("wrong-sig-challenge")
	ecdhKey := "dGVzdC1lY2RoLXB1YmxpY2tleQ"

	cfg := config.Default().Tier2

	// Build a valid token but replace the SE key's sig with a signature from wrongKey.
	xBytes := seKey.PublicKey.X.Bytes()
	yBytes := seKey.PublicKey.Y.Bytes()
	xPad, yPad := make([]byte, 32), make([]byte, 32)
	copy(xPad[32-len(xBytes):], xBytes)
	copy(yPad[32-len(yBytes):], yBytes)
	rawPub := append(xPad, yPad...)

	attestation := map[string]interface{}{
		"chipName":               "Apple M4",
		"encryptionPublicKey":    ecdhKey,
		"hardwareModel":          "Mac15,3",
		"publicKey":              base64.StdEncoding.EncodeToString(rawPub),
		"secureEnclaveAvailable": true,
		"timestamp":              now.UTC().Format(time.RFC3339),
	}
	canonicalJSON, _ := json.Marshal(attestation)
	digest := sha256.Sum256(canonicalJSON)
	badSig, _ := wrongKey.Sign(rand.Reader, digest[:], crypto.SHA256)

	signed := map[string]interface{}{
		"attestation": attestation,
		"signature":   base64.StdEncoding.EncodeToString(badSig),
	}
	signedJSON, _ := json.Marshal(signed)
	tokenField := base64.RawURLEncoding.EncodeToString(signedJSON)

	outer := AttestationToken{
		Format:        seAttestationFormat,
		Token:         tokenField,
		Challenge:     base64.RawURLEncoding.EncodeToString(challenge),
		IssuedAt:      now.Add(-time.Minute),
		ExpiresAt:     now.Add(time.Minute),
		ProviderID:    "provider-se-4",
		BinaryVersion: "1.2.0",
		Claimed:       map[string]any{"hardware_family": "apple_silicon"},
		KeyBinding:    AttestationKeyBinding{ProviderECDHPublicKey: ecdhKey},
	}
	bindingSig, _ := BuildAttestationBindingSignature(outer, "auth-test", seKey)
	outer.Signature = bindingSig
	raw, _ := json.Marshal(outer)

	result := VerifyAttestationTokenExt(raw, cfg, challenge, "auth-test", "provider-se-4", ecdhKey, nil, now, zerolog.Nop())

	if result.Status != pool.AttestationStatusFailed {
		t.Fatalf("status=%q want failed on wrong SE signature", result.Status)
	}
	if result.SEResult != nil {
		t.Fatal("SEResult must be nil on rejection")
	}
}
