package onboarding

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
)

const realStudioFixturePath = "../appattest/testdata/macos27-studio-2026-10-04.json"

// realStudioTime is inside the real leaf's validity
// (2026-10-03T11:04:37Z .. 2026-10-06T11:04:37Z).
var realStudioTime = time.Date(2026, 10, 4, 23, 0, 0, 0, time.UTC)

// realStudioEvidence loads the #1840 spike: a Developer ID Malibu.app
// (team YF7XNRJUG4) on macOS 27.0.1. Its clientDataHash is SHA-256 of the
// 32 nonce bytes.
func realStudioEvidence(t *testing.T) AppAttestEvidence {
	t.Helper()
	raw, err := os.ReadFile(realStudioFixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		AttestationB64 string `json:"attestation_b64"`
		KeyID          string `json:"key_id"`
		NonceB64       string `json:"nonce_b64"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	decode := func(s string) []byte {
		out, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	return AppAttestEvidence{
		Object:         decode(fixture.AttestationB64),
		KeyID:          decode(fixture.KeyID),
		ClientDataHash: sha256.Sum256(decode(fixture.NonceB64)),
	}
}

func realStudioVerifier() AppleAppAttestVerifier {
	return AppleAppAttestVerifier{
		Config: AppAttestConfig{TeamID: "YF7XNRJUG4", BundleID: "tech.malibu.app", CoordinatorDomain: "coordinator.malibu.tech"},
		Now:    func() time.Time { return realStudioTime },
	}
}

// TestAppleAppAttestVerifierAcceptsRealMacOS27Attestation is the regression
// for the pre-v0.8.0 verifier, which refused this attestation (corrupt root,
// misparsed nonce extension).
func TestAppleAppAttestVerifierAcceptsRealMacOS27Attestation(t *testing.T) {
	ok, err := realStudioVerifier().Verify(t.Context(), realStudioEvidence(t))
	if err != nil || !ok {
		t.Fatalf("real macOS 27 attestation: ok=%v err=%v", ok, err)
	}

	// The same attestation is refused for another binding.
	for name, mutate := range map[string]func(*AppAttestEvidence, *AppleAppAttestVerifier){
		"client data": func(e *AppAttestEvidence, _ *AppleAppAttestVerifier) { e.ClientDataHash[0] ^= 1 },
		"key id": func(e *AppAttestEvidence, _ *AppleAppAttestVerifier) {
			e.KeyID = append([]byte(nil), e.KeyID...)
			e.KeyID[0] ^= 1
		},
		"team":   func(_ *AppAttestEvidence, v *AppleAppAttestVerifier) { v.Config.TeamID = "ZZZZZ99999" },
		"bundle": func(_ *AppAttestEvidence, v *AppleAppAttestVerifier) { v.Config.BundleID = "tech.malibu.other" },
		"after expiry": func(_ *AppAttestEvidence, v *AppleAppAttestVerifier) {
			v.Now = func() time.Time { return realStudioTime.AddDate(0, 0, 3) }
		},
	} {
		evidence, verifier := realStudioEvidence(t), realStudioVerifier()
		mutate(&evidence, &verifier)
		if ok, err := verifier.Verify(t.Context(), evidence); ok || !errors.Is(err, ErrAppAttestBinding) {
			t.Fatalf("%s: ok=%v err=%v, want ErrAppAttestBinding", name, ok, err)
		}
	}
}

// TestAppleAppAttestVerifierRejectsCorruptRoot pins the regression: with the
// root main embedded before v0.8.0, the real attestation does not verify.
func TestAppleAppAttestVerifierRejectsCorruptRoot(t *testing.T) {
	block, _ := pem.Decode([]byte(preV080CorruptRootPEM))
	if block == nil {
		t.Fatal("corrupt root PEM")
	}
	corrupt, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	verifier := realStudioVerifier()
	verifier.Root = corrupt
	if ok, err := verifier.Verify(t.Context(), realStudioEvidence(t)); ok || !errors.Is(err, ErrAppAttestBinding) {
		t.Fatalf("corrupt root: ok=%v err=%v, want ErrAppAttestBinding", ok, err)
	}
}

func TestAppleAppAttestVerifierPolicy(t *testing.T) {
	now := time.Now()
	fixture, err := appattesttest.NewFixtureAt(now)
	if err != nil {
		t.Fatal(err)
	}
	const appID = "TEAM123456.tech.malibu.app"
	clientDataHash := sha256.Sum256([]byte("client data"))
	verifier := AppleAppAttestVerifier{
		Config: AppAttestConfig{TeamID: "TEAM123456", BundleID: "tech.malibu.app"},
		Root:   fixture.Root,
		Now:    func() time.Time { return now },
	}
	attest := func(opts appattesttest.AttestOptions) AppAttestEvidence {
		t.Helper()
		opts.AppID = appID
		opts.ClientDataHash = clientDataHash[:]
		att, err := fixture.Attest(opts)
		if err != nil {
			t.Fatal(err)
		}
		return AppAttestEvidence{Object: att.Object, KeyID: att.KeyID, ClientDataHash: clientDataHash}
	}

	if ok, err := verifier.Verify(t.Context(), attest(appattesttest.AttestOptions{})); !ok || err != nil {
		t.Fatalf("valid: ok=%v err=%v", ok, err)
	}
	// A genuine key on a Mac without SIP and Full Security is not attested,
	// and not a binding failure.
	if ok, err := verifier.Verify(t.Context(), attest(appattesttest.AttestOptions{ACLInner: []byte{0x30, 0x00}})); ok || err != nil {
		t.Fatalf("acl mismatch: ok=%v err=%v, want (false, nil)", ok, err)
	}
	dev := appattesttest.DevelopmentAAGUID
	for name, opts := range map[string]appattesttest.AttestOptions{
		"development aaguid": {AAGUID: &dev},
		"wrong nonce":        {WrongNonce: true},
		"no nonce":           {NoNonce: true},
		"counter":            {Counter: 1},
		"other credential":   {OtherCredential: true},
		"expired leaf":       {LeafExpired: true},
		"no intermediate":    {NoIntermediate: true},
	} {
		if ok, err := verifier.Verify(t.Context(), attest(opts)); ok || !errors.Is(err, ErrAppAttestBinding) {
			t.Fatalf("%s: ok=%v err=%v, want ErrAppAttestBinding", name, ok, err)
		}
	}
	// The pinned Apple root does not anchor the synthetic chain.
	pinned := verifier
	pinned.Root = nil
	if ok, err := pinned.Verify(t.Context(), attest(appattesttest.AttestOptions{})); ok || !errors.Is(err, ErrAppAttestBinding) {
		t.Fatalf("synthetic chain under the Apple root: ok=%v err=%v", ok, err)
	}
	unpinned := verifier
	unpinned.Config.TeamID = ""
	if _, err := unpinned.Verify(t.Context(), attest(appattesttest.AttestOptions{})); !errors.Is(err, ErrAppAttestTransient) {
		t.Fatalf("missing team pin: err=%v, want ErrAppAttestTransient", err)
	}
}

// preV080CorruptRootPEM is the root main embedded before SPEC-033 v0.8.0
// (subject "Apple Aps.", self-signature invalid).
const preV080CorruptRootPEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBBcHMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`
