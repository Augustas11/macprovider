package tier2

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
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
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	got := VerifyAttestationToken(raw, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop())

	if got != pool.AttestationStatusAttested {
		t.Fatalf("attestation status=%q want %q", got, pool.AttestationStatusAttested)
	}
}

func TestVerifyAttestationTokenRejectsBindingAndReplayFailures(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], []byte("challenge-1"), "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, []byte("different-challenge"), "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusStale {
		t.Fatalf("challenge mismatch status=%q want stale", got)
	}
	if got := VerifyAttestationToken(raw, cfg, []byte("challenge-1"), "provider-b", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("provider mismatch status=%q want failed", got)
	}
	if got := VerifyAttestationToken(raw, cfg, []byte("challenge-1"), "provider-a", "different-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("ecdh mismatch status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsHardwareFamilyPolicyMismatch(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
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

	if got := VerifyAttestationToken(mismatch, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("hardware family mismatch status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenMissingOrInvalidStates(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	if got := VerifyAttestationToken(nil, cfg, nil, "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusNotRequired {
		t.Fatalf("default missing token status=%q want not_required", got)
	}
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
	if got := VerifyAttestationToken(nil, cfg, nil, "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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
	if got := VerifyAttestationToken(invalidRaw, cfg, []byte("challenge-1"), "provider-a", "", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("unsupported format status=%q want unsupported", got)
	}
}

func TestVerifyAttestationTokenRejectsMalformedTokenEncoding(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
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

	if got := VerifyAttestationToken(malformed, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("malformed token status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenRejectsNonMockTokenForMockRoot(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = []string{"mock-root"}
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

	if got := VerifyAttestationToken(compactJWS, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(raw, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("production root without verifier status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenOptionalProductionRootUnsupportedWithoutVerifier(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	cfg.AttestationRoots = []string{"prod-root"}
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
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

	if got := VerifyAttestationToken(compactJWS, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
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

	if got := VerifyAttestationToken(malformed, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("malformed production certificate chain status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenValidatesProductionCertificateChainButDoesNotAttestYet(t *testing.T) {
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
	token.CertificateChain = []string{base64.StdEncoding.EncodeToString(leafDER)}
	withChain, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal chain token: %v", err)
	}

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("optional production certificate chain status=%q want unsupported", got)
	}
	cfg.RequireAttestation = true
	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withJWSChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("compact jws x5c chain status=%q want unsupported", got)
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusAttested {
		t.Fatalf("optional production CSR-bound chain status=%q want attested", got)
	}
	cfg.RequireAttestation = true
	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusAttested {
		t.Fatalf("required production CSR-bound chain status=%q want attested", got)
	}
}

func TestVerifyAttestationTokenRejectsProductionChainWithMissingFreshness(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg, challenge, withChain := productionChainToken(t, now, testAttestationCertificateOptions{
		IncludeDeviceProperty: true,
		LeafKeyType:           "p256",
	})

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
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

	if got := VerifyAttestationToken(withChain, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("mismatched MDA CSR key status=%q want failed", got)
	}
}

func TestVerifyAttestationTokenWithoutRootsNeverMarksAttested(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	cfg := config.Default().Tier2
	challenge := []byte("challenge-1")
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))

	if got := VerifyAttestationToken(raw, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusUnsupported {
		t.Fatalf("rootless optional token status=%q want unsupported", got)
	}
	cfg.RequireAttestation = true
	if got := VerifyAttestationToken(raw, cfg, challenge, "provider-a", "provider-ecdh", now, zerolog.Nop()); got != pool.AttestationStatusFailed {
		t.Fatalf("rootless required token status=%q want failed", got)
	}
}

type testAttestationCertificateOptions struct {
	FreshnessToken        string
	IncludeFreshness      bool
	IncludeDeviceProperty bool
	DevicePropertyValue   []byte
	IncludeCSR            bool
	MalformedCSR          bool
	MismatchCSR           bool
	LeafKeyType           string
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
	raw := BuildMockAttestationToken(cfg.AttestationFormats[0], challenge, "provider-a", "provider-ecdh", now.Add(-time.Minute), now.Add(time.Minute))
	var token AttestationToken
	if err := json.Unmarshal(raw, &token); err != nil {
		t.Fatalf("unmarshal mock token: %v", err)
	}
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
	withChain, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal chain token: %v", err)
	}
	return cfg, challenge, withChain
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
		digest := expectedMDAFreshnessDigest(opts.FreshnessToken)
		leaf.ExtraExtensions = append(leaf.ExtraExtensions, pkix.Extension{
			Id:    mdaOIDFreshness,
			Value: digest[:],
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
