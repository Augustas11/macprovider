package appattest_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest"
	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
)

const testAppID = "ABCDE12345.tech.malibu.app"

func clientHash(label string) []byte {
	sum := sha256.Sum256([]byte(label))
	return sum[:]
}

func build(t *testing.T, f *appattesttest.Fixture, opts appattesttest.AttestOptions) (appattesttest.Attestation, appattest.AttestationInput) {
	t.Helper()
	if opts.AppID == "" {
		opts.AppID = testAppID
	}
	if opts.ClientDataHash == nil {
		opts.ClientDataHash = clientHash("enrollment")
	}
	att, err := f.Attest(opts)
	if err != nil {
		t.Fatal(err)
	}
	return att, appattest.AttestationInput{
		Attestation: att.Object, KeyID: att.KeyID, ClientDataHash: clientHash("enrollment"),
		AppID: testAppID, Now: time.Now(), Root: f.Root,
	}
}

// The real macOS 27 Developer ID shape: no authenticator extensions map,
// production aaguid, counter 0, the SIP and Full Security aclBlob, and
// bare 37-byte assertions that keep the AT flag set.
func TestRealHardwareShapedVectors(t *testing.T) {
	f, err := appattesttest.NewFixture()
	if err != nil {
		t.Fatal(err)
	}
	att, in := build(t, f, appattesttest.AttestOptions{})
	key, err := appattest.VerifyAttestation(in)
	if err != nil {
		t.Fatal(err)
	}
	if len(key.PublicKey) != 65 {
		t.Fatalf("public key length %d", len(key.PublicKey))
	}
	for i, counter := range []uint32{1, 2} {
		hash := clientHash("posture")
		body, err := appattesttest.Assert(att.Key, testAppID, counter, hash)
		if err != nil {
			t.Fatal(err)
		}
		got, err := appattest.VerifyAssertion(appattest.AssertionInput{Assertion: body, PublicKey: key.PublicKey, ClientDataHash: hash, AppID: testAppID})
		if err != nil || got != counter {
			t.Fatalf("assertion %d: counter=%d err=%v", i, got, err)
		}
	}
	// The ACL may sit directly in the SEQUENCE.
	_, direct := build(t, f, appattesttest.AttestOptions{ACLDirect: true})
	if _, err := appattest.VerifyAttestation(direct); err != nil {
		t.Fatalf("direct aclBlob: %v", err)
	}
	// An optional extensions map with Developer ID category is accepted.
	six := uint32(6)
	_, devID := build(t, f, appattesttest.AttestOptions{Category: &six})
	if _, err := appattest.VerifyAttestation(devID); err != nil {
		t.Fatalf("category 6: %v", err)
	}
}

func TestAttestationNegativeSingleFieldMutations(t *testing.T) {
	f, err := appattesttest.NewFixture()
	if err != nil {
		t.Fatal(err)
	}
	other, err := appattesttest.NewFixture()
	if err != nil {
		t.Fatal(err)
	}
	dev := appattesttest.DevelopmentAAGUID
	three := uint32(3)
	weak := []byte{0x30, 0x03, 0x0c, 0x01, 'x'}
	attestCases := map[string]appattesttest.AttestOptions{
		"wrong rpIdHash":     {AppID: "ABCDE12345.tech.malibu.other"},
		"development aaguid": {AAGUID: &dev},
		"nonzero counter":    {Counter: 1},
		"missing nonce":      {NoNonce: true},
		"wrong nonce":        {WrongNonce: true},
		"AT flag clear":      {ClearATFlag: true},
		"other credential":   {OtherCredential: true},
		"leaf is CA":         {LeafIsCA: true},
		"leaf expired":       {LeafExpired: true},
		"no intermediate":    {NoIntermediate: true},
		"extra top key":      {ExtraTopKey: true},
		"empty receipt":      {EmptyReceipt: true},
		"category 3":         {Category: &three},
	}
	for name, opts := range attestCases {
		_, in := build(t, f, opts)
		if _, err := appattest.VerifyAttestation(in); !errors.Is(err, appattest.ErrAttestationInvalid) {
			t.Errorf("%s: err=%v", name, err)
		}
	}
	aclCases := map[string]appattesttest.AttestOptions{
		"missing aclBlob":   {NoACL: true},
		"different aclBlob": {ACLInner: weak},
	}
	for name, opts := range aclCases {
		_, in := build(t, f, opts)
		if _, err := appattest.VerifyAttestation(in); !errors.Is(err, appattest.ErrACLMismatch) {
			t.Errorf("%s: err=%v", name, err)
		}
	}
	_, base := build(t, f, appattesttest.AttestOptions{})
	inputCases := map[string]func(*appattest.AttestationInput){
		"chain to other root": func(in *appattest.AttestationInput) { in.Root = other.Root },
		"other clientData":    func(in *appattest.AttestationInput) { in.ClientDataHash = clientHash("other") },
		"other key id":        func(in *appattest.AttestationInput) { in.KeyID = clientHash("key") },
		"other app id":        func(in *appattest.AttestationInput) { in.AppID = "ZZZZZ99999.tech.malibu.app" },
		"future clock":        func(in *appattest.AttestationInput) { in.Now = time.Now().Add(72 * time.Hour) },
		"truncated object":    func(in *appattest.AttestationInput) { in.Attestation = in.Attestation[:len(in.Attestation)-1] },
		"trailing byte": func(in *appattest.AttestationInput) {
			in.Attestation = append(append([]byte(nil), in.Attestation...), 0x00)
		},
		"oversized object": func(in *appattest.AttestationInput) { in.Attestation = make([]byte, appattest.MaxAttestationBytes+1) },
		"short clientData": func(in *appattest.AttestationInput) { in.ClientDataHash = in.ClientDataHash[:31] },
		"no root":          func(in *appattest.AttestationInput) { in.Root = nil },
	}
	for name, mutate := range inputCases {
		in := base
		mutate(&in)
		if _, err := appattest.VerifyAttestation(in); !errors.Is(err, appattest.ErrAttestationInvalid) {
			t.Errorf("%s: err=%v", name, err)
		}
	}
	if _, err := appattest.VerifyAttestation(base); err != nil {
		t.Fatalf("baseline: %v", err)
	}
}

func TestAssertionNegativeSingleFieldMutations(t *testing.T) {
	f, err := appattesttest.NewFixture()
	if err != nil {
		t.Fatal(err)
	}
	att, in := build(t, f, appattesttest.AttestOptions{})
	key, err := appattest.VerifyAttestation(in)
	if err != nil {
		t.Fatal(err)
	}
	hash := clientHash("posture")
	good, err := appattesttest.Assert(att.Key, testAppID, 7, hash)
	if err != nil {
		t.Fatal(err)
	}
	base := appattest.AssertionInput{Assertion: good, PublicKey: key.PublicKey, ClientDataHash: hash, AppID: testAppID}
	if got, err := appattest.VerifyAssertion(base); err != nil || got != 7 {
		t.Fatalf("baseline counter=%d err=%v", got, err)
	}
	otherKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	wrongSigner, _ := appattesttest.Assert(otherKey, testAppID, 7, hash)
	wrongApp, _ := appattesttest.Assert(att.Key, "ABCDE12345.tech.malibu.other", 7, hash)
	rp := sha256.Sum256([]byte(testAppID))
	auth := binary.BigEndian.AppendUint32(append(append([]byte(nil), rp[:]...), 0x40), 7)
	trailing := append(append([]byte(nil), auth...), 0x01)
	withMap := append(append([]byte(nil), auth...), 0xa0)
	sigOverMap := signAuth(t, att.Key, withMap, hash)
	if got, err := appattest.VerifyAssertion(appattest.AssertionInput{Assertion: sigOverMap, PublicKey: key.PublicKey, ClientDataHash: hash, AppID: testAppID}); err != nil || got != 7 {
		t.Fatalf("authenticatorData with an extensions map: %v", err)
	}
	cases := map[string]func(*appattest.AssertionInput){
		"bad signature":      func(in *appattest.AssertionInput) { in.Assertion = wrongSigner },
		"wrong rpIdHash":     func(in *appattest.AssertionInput) { in.Assertion = wrongApp },
		"other clientData":   func(in *appattest.AssertionInput) { in.ClientDataHash = clientHash("other") },
		"other stored key":   func(in *appattest.AssertionInput) { p, _ := otherKey.PublicKey.Bytes(); in.PublicKey = p },
		"invalid stored key": func(in *appattest.AssertionInput) { in.PublicKey = make([]byte, 65) },
		"trailing auth byte": func(in *appattest.AssertionInput) { in.Assertion = signAuth(t, att.Key, trailing, hash) },
		"short auth": func(in *appattest.AssertionInput) {
			in.Assertion = appattesttest.AssertionObject([]byte{0x30}, auth[:36])
		},
		"oversized signature": func(in *appattest.AssertionInput) {
			in.Assertion = appattesttest.AssertionObject(make([]byte, 73), auth)
		},
		"trailing object byte": func(in *appattest.AssertionInput) { in.Assertion = append(append([]byte(nil), good...), 0x00) },
		"oversized object":     func(in *appattest.AssertionInput) { in.Assertion = make([]byte, appattest.MaxAssertionBytes+1) },
		"extra key": func(in *appattest.AssertionInput) {
			in.Assertion = append([]byte{0xa3}, append(good[1:], 0x61, 'x', 0x01)...)
		},
	}
	for name, mutate := range cases {
		mutated := base
		mutate(&mutated)
		if _, err := appattest.VerifyAssertion(mutated); !errors.Is(err, appattest.ErrAssertionInvalid) {
			t.Errorf("%s: err=%v", name, err)
		}
	}
}

func signAuth(t *testing.T, key *ecdsa.PrivateKey, auth, hash []byte) []byte {
	t.Helper()
	nonce := sha256.Sum256(append(append([]byte(nil), auth...), hash...))
	digest := sha256.Sum256(nonce[:])
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return appattesttest.AssertionObject(sig, auth)
}
