// Package appattesttest builds App Attest objects shaped like the real
// macOS 27 Developer ID output (issue #1840, 2026-10-04) under a throwaway
// test root. It is for tests only; the coordinator never trusts its root.
package appattesttest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"math/big"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest"
)

var (
	oidNonce = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}
	oidACL   = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 6}

	// ProductionAAGUID and DevelopmentAAGUID are the two Apple values.
	ProductionAAGUID  = [16]byte{'a', 'p', 'p', 'a', 't', 't', 'e', 's', 't'}
	DevelopmentAAGUID = [16]byte{'a', 'p', 'p', 'a', 't', 't', 'e', 's', 't', 'd', 'e', 'v', 'e', 'l', 'o', 'p'}
)

// Fixture is a test root and intermediate.
type Fixture struct {
	Root     *x509.Certificate
	rootKey  *ecdsa.PrivateKey
	Inter    *x509.Certificate
	interKey *ecdsa.PrivateKey
	now      time.Time
}

// NewFixture creates a root and an intermediate valid for one day.
func NewFixture() (*Fixture, error) { return NewFixtureAt(time.Now()) }

// NewFixtureAt is NewFixture with every validity window centred on now.
func NewFixtureAt(now time.Time) (*Fixture, error) {
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	rootTemplate := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: "appattesttest root"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, MaxPathLen: 1,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	root, err := sign(rootTemplate, rootTemplate, &rootKey.PublicKey, rootKey)
	if err != nil {
		return nil, err
	}
	interKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	interTemplate := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: "appattesttest intermediate"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	inter, err := sign(interTemplate, root, &interKey.PublicKey, rootKey)
	if err != nil {
		return nil, err
	}
	return &Fixture{Root: root, rootKey: rootKey, Inter: inter, interKey: interKey, now: now}, nil
}

// AttestOptions shape one attestation. The zero value plus AppID and
// ClientDataHash is a valid real-hardware-shaped attestation: no
// authenticator extensions map, production aaguid, counter 0, and the
// SIP and Full Security aclBlob wrapped in [3] EXPLICIT.
type AttestOptions struct {
	AppID          string
	ClientDataHash []byte
	Key            *ecdsa.PrivateKey

	Counter         uint32
	AAGUID          *[16]byte
	ClearATFlag     bool
	ACLInner        []byte
	NoACL           bool
	ACLDirect       bool
	NoNonce         bool
	WrongNonce      bool
	Category        *uint32
	OtherCredential bool
	LeafIsCA        bool
	LeafExpired     bool
	NoIntermediate  bool
	ExtraTopKey     bool
	EmptyReceipt    bool
}

// Attestation is a built object and its key.
type Attestation struct {
	Object []byte
	KeyID  []byte
	Key    *ecdsa.PrivateKey
}

// Attest builds one attestation object.
func (f *Fixture) Attest(opts AttestOptions) (Attestation, error) {
	key := opts.Key
	if key == nil {
		var err error
		key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return Attestation{}, err
		}
	}
	point, err := key.PublicKey.Bytes()
	if err != nil {
		return Attestation{}, err
	}
	keyID := sha256.Sum256(point)
	credential := keyID[:]
	if opts.OtherCredential {
		other := sha256.Sum256(append([]byte("other"), point...))
		credential = other[:]
	}
	aaguid := ProductionAAGUID
	if opts.AAGUID != nil {
		aaguid = *opts.AAGUID
	}
	rp := sha256.Sum256([]byte(opts.AppID))
	var auth []byte
	auth = append(auth, rp[:]...)
	flags := byte(0x40)
	if opts.ClearATFlag {
		flags = 0
	}
	auth = append(auth, flags)
	auth = binary.BigEndian.AppendUint32(auth, opts.Counter)
	auth = append(auth, aaguid[:]...)
	auth = binary.BigEndian.AppendUint16(auth, uint16(len(credential)))
	auth = append(auth, credential...)
	auth = append(auth, cose(&key.PublicKey)...)
	if opts.Category != nil {
		raw := binary.LittleEndian.AppendUint32(nil, *opts.Category)
		auth = append(auth, cborMapHeader(1)...)
		auth = append(auth, cborText("apple_validation_category_01")...)
		auth = append(auth, cborBytes(raw)...)
	}
	nonce := sha256.Sum256(append(append([]byte(nil), auth...), opts.ClientDataHash...))
	if opts.WrongNonce {
		nonce[0] ^= 0xff
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: serial(), Subject: pkix.Name{CommonName: "appattesttest leaf"},
		NotBefore: f.now.Add(-time.Hour), NotAfter: f.now.Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature,
	}
	if opts.LeafExpired {
		leafTemplate.NotBefore = f.now.Add(-48 * time.Hour)
		leafTemplate.NotAfter = f.now.Add(-24 * time.Hour)
	}
	if opts.LeafIsCA {
		leafTemplate.IsCA = true
		leafTemplate.BasicConstraintsValid = true
	}
	if !opts.NoNonce {
		leafTemplate.ExtraExtensions = append(leafTemplate.ExtraExtensions, pkix.Extension{Id: oidNonce, Value: explicitOctet(1, nonce[:])})
	}
	if !opts.NoACL {
		inner := opts.ACLInner
		if inner == nil {
			inner = appattest.RequiredACLBlob()
		}
		value := explicitOctet(3, inner)
		if opts.ACLDirect {
			value = derTLV(0x30, derTLV(0x04, inner))
		}
		leafTemplate.ExtraExtensions = append(leafTemplate.ExtraExtensions, pkix.Extension{Id: oidACL, Value: value})
	}
	leaf, err := sign(leafTemplate, f.Inter, &key.PublicKey, f.interKey)
	if err != nil {
		return Attestation{}, err
	}
	chain := [][]byte{leaf.Raw, f.Inter.Raw}
	if opts.NoIntermediate {
		chain = chain[:1]
	}
	receipt := []byte{0x30, 0x03, 0x02, 0x01, 0x01}
	if opts.EmptyReceipt {
		receipt = nil
	}
	pairs := 3
	if opts.ExtraTopKey {
		pairs = 4
	}
	var out []byte
	out = append(out, cborMapHeader(pairs)...)
	out = append(out, cborText("fmt")...)
	out = append(out, cborText(appattest.AttestationFormat)...)
	out = append(out, cborText("attStmt")...)
	out = append(out, cborMapHeader(2)...)
	out = append(out, cborText("x5c")...)
	out = append(out, cborArrayHeader(len(chain))...)
	for _, der := range chain {
		out = append(out, cborBytes(der)...)
	}
	out = append(out, cborText("receipt")...)
	out = append(out, cborBytes(receipt)...)
	out = append(out, cborText("authData")...)
	out = append(out, cborBytes(auth)...)
	if opts.ExtraTopKey {
		out = append(out, cborText("extra")...)
		out = append(out, cborText("x")...)
	}
	return Attestation{Object: out, KeyID: keyID[:], Key: key}, nil
}

// Assert builds a real-hardware-shaped assertion: a bare 37-byte
// authenticatorData with the AT flag set and the given counter.
func Assert(key *ecdsa.PrivateKey, appID string, counter uint32, clientDataHash []byte) ([]byte, error) {
	if key == nil {
		return nil, errors.New("appattesttest: key required")
	}
	rp := sha256.Sum256([]byte(appID))
	auth := make([]byte, 0, 37)
	auth = append(auth, rp[:]...)
	auth = append(auth, 0x40)
	auth = binary.BigEndian.AppendUint32(auth, counter)
	nonce := sha256.Sum256(append(append([]byte(nil), auth...), clientDataHash...))
	digest := sha256.Sum256(nonce[:])
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return nil, err
	}
	return AssertionObject(sig, auth), nil
}

// AssertionObject encodes {signature, authenticatorData}.
func AssertionObject(signature, authenticatorData []byte) []byte {
	var out []byte
	out = append(out, cborMapHeader(2)...)
	out = append(out, cborText("signature")...)
	out = append(out, cborBytes(signature)...)
	out = append(out, cborText("authenticatorData")...)
	out = append(out, cborBytes(authenticatorData)...)
	return out
}

func cose(pub *ecdsa.PublicKey) []byte {
	var out []byte
	out = append(out, cborMapHeader(5)...)
	out = append(out, 0x01, 0x02) // kty: EC2
	out = append(out, 0x03, 0x26) // alg: -7
	out = append(out, 0x20, 0x01) // crv: P-256
	out = append(out, 0x21)       // x
	out = append(out, cborBytes(pub.X.FillBytes(make([]byte, 32)))...)
	out = append(out, 0x22) // y
	out = append(out, cborBytes(pub.Y.FillBytes(make([]byte, 32)))...)
	return out
}

func cborHead(major byte, n uint64) []byte {
	prefix := major << 5
	switch {
	case n < 24:
		return []byte{prefix | byte(n)}
	case n <= 0xff:
		return []byte{prefix | 24, byte(n)}
	case n <= 0xffff:
		return binary.BigEndian.AppendUint16([]byte{prefix | 25}, uint16(n))
	default:
		return binary.BigEndian.AppendUint32([]byte{prefix | 26}, uint32(n))
	}
}

func cborBytes(b []byte) []byte    { return append(cborHead(2, uint64(len(b))), b...) }
func cborText(s string) []byte     { return append(cborHead(3, uint64(len(s))), s...) }
func cborArrayHeader(n int) []byte { return cborHead(4, uint64(n)) }
func cborMapHeader(n int) []byte   { return cborHead(5, uint64(n)) }
func explicitOctet(tag byte, payload []byte) []byte {
	return derTLV(0x30, derTLV(0xa0|tag, derTLV(0x04, payload)))
}

func derTLV(tag byte, content []byte) []byte {
	out := []byte{tag}
	switch n := len(content); {
	case n < 0x80:
		out = append(out, byte(n))
	case n <= 0xff:
		out = append(out, 0x81, byte(n))
	default:
		out = append(out, 0x82, byte(n>>8), byte(n))
	}
	return append(out, content...)
}

func sign(template, parent *x509.Certificate, pub any, signer *ecdsa.PrivateKey) (*x509.Certificate, error) {
	der, err := x509.CreateCertificate(rand.Reader, template, parent, pub, signer)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 63))
	return n.Add(n, big.NewInt(1))
}
