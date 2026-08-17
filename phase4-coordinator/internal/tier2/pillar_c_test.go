package tier2

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestVerifyAttestationTokenAcceptsValidMockToken(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	cfg.AllowMockAttestation = true
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	got := VerifyAttestationToken(raw, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop())

	if got != pool.AttestationStatusAttested {
		t.Fatalf("attestation status=%q want %q", got, pool.AttestationStatusAttested)
	}
}

func TestVerifyAttestationTokenRejectsBindingAndReplayFailures(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	cfg.AllowMockAttestation = true
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], []byte("challenge-1"), "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, []byte("different-challenge"), "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusStale {
		t.Fatalf("challenge mismatch status=%q want stale", got)
	}
	if got := VerifyAttestationToken(raw, cfg, []byte("challenge-1"), "auth-test", "provider-b", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("provider mismatch status=%q want failed", got)
	}
	if got := VerifyAttestationToken(raw, cfg, []byte("challenge-1"), "auth-test", "provider-a", "different-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("ecdh mismatch status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsHardwareFamilyPolicyMismatch(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	cfg.AllowMockAttestation = true
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	token.Claimed["hardware_family"] = "unknown"
	mismatch, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal hardware family mismatch token: %v", err)
	}

	if got := VerifyAttestationToken(mismatch, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("hardware family mismatch status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenMissingOrInvalidStates(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	if got := VerifyAttestationToken(nil, cfg, nil, "auth-test", "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusNotRequired {
		t.Fatalf("default missing token status=%q want not_required", got)
	}
	if got := VerifyAttestationToken(json.RawMessage("null"), cfg, []byte("challenge-1"), "auth-test", "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusNotRequired {
		t.Fatalf("optional JSON null status=%q want not_required", got)
	}
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	cfg.AllowMockAttestation = true
	if got := VerifyAttestationToken(nil, cfg, nil, "auth-test", "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("required missing token status=%q want failed", got)
	}
	invalidRaw, err := json.Marshal(AttestationToken{
		Format:     "unsupported",
		Challenge:  "bad",
		IssuedAt:   now.Add(-time.Minute),
		ExpiresAt:  now.Add(time.Minute),
		ProviderID: "provider-a",
	})
	if err != nil {
		t.Fatalf("marshal invalid token: %v", err)
	}
	if got := VerifyAttestationToken(invalidRaw, cfg, []byte("challenge-1"), "auth-test", "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("unsupported format status=%q want unsupported", got)
	}
}

func TestVerifyAttestationTokenRejectsMalformedTokenEncoding(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	cfg.AllowMockAttestation = true
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	token.Token = "not base64!"
	malformed, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal malformed token: %v", err)
	}

	if got := VerifyAttestationToken(malformed, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("malformed token status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsNonMockTokenForMockRoot(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	cfg.AllowMockAttestation = true
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	segment := base64.RawURLEncoding.EncodeToString([]byte("jws-segment"))
	token.Token = strings.Join([]string{header, segment, segment}, ".")
	compactJWS, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal compact jws token: %v", err)
	}

	if got := VerifyAttestationToken(compactJWS, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("non-mock token with mock root status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenFailsClosedForProductionRootWithoutVerifier(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"prod-root"}
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("production root without verifier status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenOptionalProductionRootUnsupportedWithoutVerifier(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.AttestationRoots = []string{"prod-root"}
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("optional production root without verifier status=%q want unsupported", got)
	}
}

func TestVerifyAttestationTokenCompactJWSProductionRootUnsupportedWithoutVerifier(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.AttestationRoots = []string{"prod-root"}
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
	segment := base64.RawURLEncoding.EncodeToString([]byte("jws-segment"))
	token.Token = strings.Join([]string{header, segment, segment}, ".")
	compactJWS, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal compact jws token: %v", err)
	}

	if got := VerifyAttestationToken(compactJWS, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("compact jws production root status=%q want unsupported", got)
	}
}

func TestVerifyAttestationTokenRejectsMalformedProductionCertificateChain(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.AttestationRoots = []string{"prod-root"}
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	token.CertificateChain = []string{"not-a-certificate"}
	malformed, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal malformed chain token: %v", err)
	}

	if got := VerifyAttestationToken(malformed, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("malformed production certificate chain status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenValidatesProductionCertificateChainButDoesNotAttestYet(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg, challenge, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("optional production certificate chain status=%q want unsupported", got)
	}
	cfg.RequireAttestation = true
	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("required production certificate chain status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenExtractsCompactJWSX5CCertificateChain(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	challenge := []byte("challenge-1")
	challengeToken := base64.RawURLEncoding.EncodeToString(challenge)
	rootDER, leafDER, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		FreshnessToken:        challengeToken,
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})
	cfg.AttestationRoots = []string{base64.StdEncoding.EncodeToString(rootDER)}
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	header, err := json.Marshal(map[string]any{
		"alg": "none",
		"x5c": []string{base64.StdEncoding.EncodeToString(leafDER)},
	})
	if err != nil {
		t.Fatalf("marshal jws header: %v", err)
	}
	payload := base64.RawURLEncoding.EncodeToString([]byte("{}"))
	signature := base64.RawURLEncoding.EncodeToString([]byte("sig"))
	token.Token = strings.Join([]string{base64.RawURLEncoding.EncodeToString(header), payload, signature}, ".")
	withJWSChain, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal compact jws chain token: %v", err)
	}

	if got := VerifyAttestationToken(withJWSChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("compact jws x5c chain status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenAttestsProductionChainWithCSRKeyBinding(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		IncludeCSR:            true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusAttested {
		t.Fatalf("optional production CSR-bound chain status=%q want attested", got)
	}
	cfg.RequireAttestation = true
	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusAttested {
		t.Fatalf("required production CSR-bound chain status=%q want attested", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMissingFreshness(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg, challenge, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("missing MDA freshness status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMismatchedFreshness(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg, challenge, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        "different-device-attest-token",
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("mismatched MDA freshness status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMissingDeviceProperty(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:   base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness: true,
		LeafKeyType:      "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("missing MDA device property status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithBlankDeviceProperty(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		DevicePropertyValue:   []byte{},
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("blank MDA device property status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithUnsupportedLeafKey(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "ed25519",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("unsupported MDA leaf public key status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMalformedCSR(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		MalformedCSR:          true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("malformed MDA CSR status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMismatchedCSRKey(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		IncludeCSR:            true,
		MismatchCSR:           true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("mismatched MDA CSR key status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithoutBindingSignature(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:          base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:        true,
		IncludeDeviceProperty:   true,
		IncludeCSR:              true,
		MissingBindingSignature: true,
		LeafKeyType:             "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("missing binding signature status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMismatchedBindingSignature(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:           base64.RawURLEncoding.EncodeToString(challenge),
		IncludeFreshness:         true,
		IncludeDeviceProperty:    true,
		IncludeCSR:               true,
		MismatchBindingSignature: true,
		LeafKeyType:              "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("mismatched binding signature status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenUsesDeviceTokenForMDAFreshness(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	deviceToken := base64.RawURLEncoding.EncodeToString([]byte("device-attestation-token"))
	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        deviceToken,
		TokenValue:            deviceToken,
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		IncludeCSR:            true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusAttested {
		t.Fatalf("device-token freshness status=%q want attested", got)
	}
}

func TestVerifyAttestationTokenWithoutRootsNeverMarksAttested(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("rootless optional token status=%q want unsupported", got)
	}
	cfg.RequireAttestation = true
	if got := VerifyAttestationToken(raw, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("rootless required token status=%q want failed", got)
	}
}

type testAttestationCertificateOptions struct {
	FreshnessToken           string
	// RawFreshnessDigest, when set, overrides the freshness digest in the leaf
	// certificate extension (instead of SHA256(FreshnessToken)). Used to embed
	// SHA256(sePublicKey) without mangling the token field.
	RawFreshnessDigest       []byte
	TokenValue               string
	IncludeFreshness         bool
	IncludeDeviceProperty    bool
	DevicePropertyValue      []byte
	SerialNumber             string
	IncludeCSR               bool
	MalformedCSR             bool
	MismatchCSR              bool
	MissingBindingSignature  bool
	MismatchBindingSignature bool
	LeafKeyType              string
}

func productionChainToken(t *testing.T, now time.Time, opts testAttestationCertificateOptions) (config.Tier2Config, []byte, json.RawMessage) {
	t.Helper()
	challenge := []byte("challenge-1")
	if opts.FreshnessToken == "" {
		opts.FreshnessToken = base64.RawURLEncoding.EncodeToString(challenge)
	}
	rootDER, leafDER, leafSigner := testAttestationCertificateChain(t, now, opts)
	cfg := config.Default().Tier2
	cfg.AttestationRoots = []string{base64.StdEncoding.EncodeToString(rootDER)}
	tokenValue := opts.TokenValue
	if tokenValue == "" {
		tokenValue = base64.RawURLEncoding.EncodeToString(challenge)
	}
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
	token.Token = tokenValue
	token.CertificateChain = []string{base64.StdEncoding.EncodeToString(leafDER)}
	switch {
	case opts.MalformedCSR:
		token.CertificateCSR = "not-a-csr"
	case opts.IncludeCSR:
		csrSigner := leafSigner
		if opts.MismatchCSR {
			mismatchKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				t.Fatalf("generate mismatched CSR key: %v", err)
			}
			csrSigner = mismatchKey
		}
		token.CertificateCSR = base64.StdEncoding.EncodeToString(testCertificateSigningRequest(t, csrSigner))
	}
	if !opts.MissingBindingSignature {
		if opts.MismatchBindingSignature {
			token.BinaryVersion = "1.2.6-before-signature-mutation"
		}
		payload, err := attestationBindingPayload(token, "auth-test")
		if err != nil {
			t.Fatalf("build attestation binding payload: %v", err)
		}
		leafKey, ok := leafSigner.(*ecdsa.PrivateKey)
		if !ok {
			return cfg, challenge, mustMarshalAttestationToken(t, token)
		}
		digest := sha256.Sum256(payload)
		signature, err := ecdsa.SignASN1(rand.Reader, leafKey, digest[:])
		if err != nil {
			t.Fatalf("sign attestation binding payload: %v", err)
		}
		token.Signature = map[string]interface{}{
			"alg":       "ES256",
			"signature": base64.RawURLEncoding.EncodeToString(signature),
		}
		if opts.MismatchBindingSignature {
			token.BinaryVersion = "1.2.6-after-signature-mutation"
		}
	}
	return cfg, challenge, mustMarshalAttestationToken(t, token)
}

func mustMarshalAttestationToken(t *testing.T, token AttestationToken) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal chain token: %v", err)
	}
	return raw
}

func testAttestationCertificateChain(t *testing.T, now time.Time, opts testAttestationCertificateOptions) ([]byte, []byte, crypto.Signer) {
	t.Helper()
	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate root key: %v", err)
	}
	root := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Apple Enterprise Attestation Root CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, rootPub, rootPriv)
	if err != nil {
		t.Fatalf("create root certificate: %v", err)
	}
	var leafSigner crypto.Signer
	switch opts.LeafKeyType {
	case "", "p256":
		leafPriv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatalf("generate leaf key: %v", err)
		}
		leafSigner = leafPriv
	case "ed25519":
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatalf("generate ed25519 leaf key: %v", err)
		}
		leafSigner = priv
	default:
		t.Fatalf("unsupported test leaf key type %q", opts.LeafKeyType)
	}
	leaf := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Managed Device Attestation Leaf"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	if opts.IncludeFreshness {
		var digestBytes []byte
		if len(opts.RawFreshnessDigest) > 0 {
			digestBytes = opts.RawFreshnessDigest
		} else {
			d := expectedMDAFreshnessDigest(opts.FreshnessToken)
			digestBytes = d[:]
		}
		leaf.ExtraExtensions = append(leaf.ExtraExtensions, pkix.Extension{
			Id:    mdaOIDFreshness,
			Value: digestBytes,
		})
	}
	if opts.IncludeDeviceProperty {
		value := opts.DevicePropertyValue
		if value == nil {
			value = []byte("macOS 14.5")
		}
		leaf.ExtraExtensions = append(leaf.ExtraExtensions, pkix.Extension{
			Id:    mdaOIDOSVersion,
			Value: value,
		})
	}
	if opts.SerialNumber != "" {
		enc, err := asn1.Marshal(opts.SerialNumber)
		if err != nil {
			t.Fatalf("marshal serial: %v", err)
		}
		leaf.ExtraExtensions = append(leaf.ExtraExtensions, pkix.Extension{
			Id:    mdaOIDSerialNumber,
			Value: enc,
		})
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, root, leafSigner.Public(), rootPriv)
	if err != nil {
		t.Fatalf("create leaf certificate: %v", err)
	}
	return rootDER, leafDER, leafSigner
}

func testCertificateSigningRequest(t *testing.T, signer crypto.Signer) []byte {
	t.Helper()
	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{CommonName: "Managed Device Attestation CSR"},
	}, signer)
	if err != nil {
		t.Fatalf("create certificate signing request: %v", err)
	}
	return csrDER
}

// TestVerifyMDAFreshnessWithSEPublicKey verifies that verifyMDAFreshness accepts
// SHA256(sePublicKey) as a valid freshness digest and returns seKeyUsed=true.
func TestVerifyMDAFreshnessWithSEPublicKey(t *testing.T) {
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate SE key: %v", err)
	}
	xBytes := make([]byte, 32)
	yBytes := make([]byte, 32)
	copy(xBytes[32-len(seKey.PublicKey.X.Bytes()):], seKey.PublicKey.X.Bytes())
	copy(yBytes[32-len(seKey.PublicKey.Y.Bytes()):], seKey.PublicKey.Y.Bytes())
	sePub := append(xBytes, yBytes...)

	// Build a leaf cert whose freshness extension = SHA256(sePub).
	now := time.Unix(1716768000, 0).UTC()
	seDigest := sha256.Sum256(sePub)
	_, leafDER, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		RawFreshnessDigest:    seDigest[:],
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatalf("parse leaf: %v", err)
	}

	reason, seKeyUsed := verifyMDAFreshness(leaf, "unrelated-token", sePub)
	if reason != "" {
		t.Fatalf("freshness check failed: %s", reason)
	}
	if !seKeyUsed {
		t.Fatal("expected seKeyUsed=true when SE key digest matched")
	}
}

// TestVerifyMDAFreshnessWithSEPublicKeyMismatch verifies that verifyMDAFreshness
// fails (mda_freshness_mismatch) when neither the token hash nor the SE key hash
// matches the certificate freshness extension.
func TestVerifyMDAFreshnessWithSEPublicKeyMismatch(t *testing.T) {
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate SE key: %v", err)
	}
	xBytes := make([]byte, 32)
	yBytes := make([]byte, 32)
	copy(xBytes[32-len(seKey.PublicKey.X.Bytes()):], seKey.PublicKey.X.Bytes())
	copy(yBytes[32-len(seKey.PublicKey.Y.Bytes()):], seKey.PublicKey.Y.Bytes())
	sePub := append(xBytes, yBytes...)

	// Build a leaf cert whose freshness extension = SHA256("different-token").
	now := time.Unix(1716768000, 0).UTC()
	_, leafDER, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		FreshnessToken:        "different-token",
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatalf("parse leaf: %v", err)
	}

	reason, seKeyUsed := verifyMDAFreshness(leaf, "wrong-token-too", sePub)
	if reason != "mda_freshness_mismatch" {
		t.Fatalf("expected mda_freshness_mismatch, got reason=%q seKeyUsed=%v", reason, seKeyUsed)
	}
	if seKeyUsed {
		t.Fatal("expected seKeyUsed=false on mismatch")
	}
}

// TestVerifyMDAFreshnessTokenPathStillWorks ensures the legacy SHA256(token) path
// still succeeds and returns seKeyUsed=false, regardless of a sePublicKey being passed.
func TestVerifyMDAFreshnessTokenPathStillWorks(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	tokenStr := base64.RawURLEncoding.EncodeToString([]byte("legacy-device-token"))
	_, leafDER, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		FreshnessToken:        tokenStr,
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatalf("parse leaf: %v", err)
	}

	// Even with a non-nil SE key, the token path matches first.
	dummySEKey := make([]byte, rawP256PubkeyBytes)
	reason, seKeyUsed := verifyMDAFreshness(leaf, tokenStr, dummySEKey)
	if reason != "" {
		t.Fatalf("token-path freshness check failed: %s", reason)
	}
	if seKeyUsed {
		t.Fatal("expected seKeyUsed=false when token digest matched")
	}
}

// TestVerifyAttestationTokenExtMDAHardwareTierWithSEKey is an integration test
// verifying that VerifyAttestationTokenExt returns MDAHardware=true when the
// production MDA chain's freshness is bound to the SE public key.
func TestVerifyAttestationTokenExtMDAHardwareTierWithSEKey(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")

	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate SE key: %v", err)
	}
	xBytes := make([]byte, 32)
	yBytes := make([]byte, 32)
	copy(xBytes[32-len(seKey.PublicKey.X.Bytes()):], seKey.PublicKey.X.Bytes())
	copy(yBytes[32-len(seKey.PublicKey.Y.Bytes()):], seKey.PublicKey.Y.Bytes())
	sePub := append(xBytes, yBytes...)
	seDigest := sha256.Sum256(sePub)

	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		RawFreshnessDigest:    seDigest[:],
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		IncludeCSR:            true,
		LeafKeyType:           "p256",
		// Token value doesn't matter for freshness; use the challenge as token.
		TokenValue: base64.RawURLEncoding.EncodeToString(challenge),
	})

	result := VerifyAttestationTokenExt(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", sePub, now, zerolog.Nop())
	if result.Status != pool.AttestationStatusAttested {
		t.Fatalf("expected attested, got %q", result.Status)
	}
	if !result.MDAHardware {
		t.Fatal("expected MDAHardware=true when SE key digest matched freshness")
	}
}

// TestVerifyAttestationTokenExtMDAHardwareFalseWithoutSEKey verifies that when
// no SE key is provided, MDAHardware=false even when the MDA chain validates via
// the legacy token-hash freshness path.
func TestVerifyAttestationTokenExtMDAHardwareFalseWithoutSEKey(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	challenge := []byte("challenge-1")
	tokenStr := base64.RawURLEncoding.EncodeToString(challenge)

	cfg, _, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		FreshnessToken:        tokenStr,
		TokenValue:            tokenStr,
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		IncludeCSR:            true,
		LeafKeyType:           "p256",
	})

	result := VerifyAttestationTokenExt(withChain, cfg, challenge, "auth-test", "provider-a", "provider-ecdh", nil, now, zerolog.Nop())
	if result.Status != pool.AttestationStatusAttested {
		t.Fatalf("expected attested, got %q", result.Status)
	}
	if result.MDAHardware {
		t.Fatal("expected MDAHardware=false when SE key was nil (legacy token path)")
	}
}

func TestVerifyMDACertChainWithSEKeyRequiresDeviceProperties(t *testing.T) {
	seKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate SE key: %v", err)
	}
	xBytes := make([]byte, 32)
	yBytes := make([]byte, 32)
	copy(xBytes[32-len(seKey.PublicKey.X.Bytes()):], seKey.PublicKey.X.Bytes())
	copy(yBytes[32-len(seKey.PublicKey.Y.Bytes()):], seKey.PublicKey.Y.Bytes())
	sePub := append(xBytes, yBytes...)
	now := time.Unix(1716768000, 0).UTC()
	seDigest := sha256.Sum256(sePub)

	rootDER, leafDER, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		RawFreshnessDigest:    seDigest[:],
		IncludeFreshness:      true,
		IncludeDeviceProperty: false,
		LeafKeyType:           "p256",
	})
	cfg := config.Default().Tier2
	cfg.AttestationRoots = []string{base64.StdEncoding.EncodeToString(rootDER)}

	ok, seKeyUsed := VerifyMDACertChainWithSEKey([][]byte{leafDER}, cfg, sePub, now, zerolog.Nop())
	if ok || seKeyUsed {
		t.Fatalf("expected device-property failure, got ok=%v seKeyUsed=%v", ok, seKeyUsed)
	}

	rootDER2, leafDER2, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		RawFreshnessDigest:    seDigest[:],
		IncludeFreshness:      true,
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})
	cfg.AttestationRoots = []string{base64.StdEncoding.EncodeToString(rootDER2)}
	ok, seKeyUsed = VerifyMDACertChainWithSEKey([][]byte{leafDER2}, cfg, sePub, now, zerolog.Nop())
	if !ok || !seKeyUsed {
		t.Fatalf("expected success with device property, got ok=%v seKeyUsed=%v", ok, seKeyUsed)
	}
}

func TestExtractMDASerialNumber(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	_, leafDER, _ := testAttestationCertificateChain(t, now, testAttestationCertificateOptions{
		IncludeFreshness:      true,
		FreshnessToken:        "tok",
		IncludeDeviceProperty: true,
		SerialNumber:          "C02TESTSERIAL",
		LeafKeyType:           "p256",
	})
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatalf("parse leaf: %v", err)
	}
	got := ExtractMDASerialNumber(leaf)
	if got != "C02TESTSERIAL" {
		t.Fatalf("ExtractMDASerialNumber=%q want C02TESTSERIAL", got)
	}
	if ExtractMDASerialNumber(nil) != "" {
		t.Fatal("nil leaf should return empty")
	}
}
