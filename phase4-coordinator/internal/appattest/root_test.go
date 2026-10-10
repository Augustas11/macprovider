package appattest

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"strings"
	"testing"
)

// corruptRootPEM is the copy main embedded before SPEC-033 v0.8.0: one
// base64 line differs from Apple's root, so its subject reads "Apple Aps."
// while its issuer reads "Apple Inc." and its self-signature fails. No
// genuine attestation can chain to it.
const corruptRootPEM = `-----BEGIN CERTIFICATE-----
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

func corruptRootDER(t *testing.T) []byte {
	t.Helper()
	block, _ := pem.Decode([]byte(corruptRootPEM))
	if block == nil {
		t.Fatal("corrupt root PEM did not decode")
	}
	return block.Bytes
}

func TestPinnedRootIsApplesRoot(t *testing.T) {
	root, err := AppleRoot()
	if err != nil {
		t.Fatalf("pinned root refused: %v", err)
	}
	sum := sha256.Sum256(root.Raw)
	if hex.EncodeToString(sum[:]) != AppleRootFingerprint {
		t.Fatalf("pinned root fingerprint %x", sum)
	}
	if root.Subject.String() != root.Issuer.String() ||
		!strings.Contains(root.Subject.String(), "O=Apple Inc.") ||
		root.Subject.CommonName != "Apple App Attestation Root CA" {
		t.Fatalf("pinned root subject %q issuer %q", root.Subject, root.Issuer)
	}
}

// TestPinnedRootRefusesCorruptCopy is the regression for the corrupt root:
// it is refused under the real pin (fingerprint), and refused even when a
// caller pins its own fingerprint (self-signature).
func TestPinnedRootRefusesCorruptCopy(t *testing.T) {
	sum := sha256.Sum256(corruptRootDER(t))
	if hex.EncodeToString(sum[:]) == AppleRootFingerprint {
		t.Fatal("corrupt root matches the Apple fingerprint")
	}
	if _, err := parsePinnedRoot([]byte(corruptRootPEM), AppleRootFingerprint); err == nil {
		t.Fatal("corrupt root accepted under the Apple fingerprint")
	}
	if _, err := parsePinnedRoot([]byte(corruptRootPEM), hex.EncodeToString(sum[:])); err == nil ||
		!strings.Contains(err.Error(), "self-signed") {
		t.Fatalf("corrupt root under its own fingerprint: err=%v, want self-signature failure", err)
	}
}
