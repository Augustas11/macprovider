package onboarding

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

const (
	defaultMaxAppAttestObjectBytes = 4 * 1024
	authDataFlagAttestedCredential = 0x40
	cborMaxDepth                   = 8
)

var appleAppAttestNonceOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}

const appleAppAttestationRootCAPEM = `-----BEGIN CERTIFICATE-----
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

type AppleAppAttestVerifier struct {
	Config            AppAttestConfig
	RootCertPEM       []byte
	Now               func() time.Time
	MaxObjectBytes    int
	SkipAAGUIDEnforce bool
}

func (v AppleAppAttestVerifier) Verify(ctx context.Context, evidence AppAttestEvidence) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, ErrAppAttestTransient
	}
	maxBytes := v.MaxObjectBytes
	if maxBytes <= 0 {
		maxBytes = defaultMaxAppAttestObjectBytes
	}
	if len(evidence.Object) == 0 || len(evidence.Object) > maxBytes || len(evidence.KeyID) != 32 {
		return false, ErrAppAttestBinding
	}
	teamID := strings.TrimSpace(v.Config.TeamID)
	bundleID := strings.TrimSpace(v.Config.BundleID)
	if teamID == "" || bundleID == "" {
		return false, ErrAppAttestTransient
	}
	appID := teamID + "." + bundleID
	rootPEM := v.RootCertPEM
	if len(rootPEM) == 0 {
		rootPEM = []byte(appleAppAttestationRootCAPEM)
	}
	root, err := parseSinglePEMCert(rootPEM)
	if err != nil {
		return false, ErrAppAttestTransient
	}
	att, err := parseAppAttestObject(evidence.Object)
	if err != nil {
		return false, ErrAppAttestBinding
	}
	if err := ctx.Err(); err != nil {
		return false, ErrAppAttestTransient
	}
	if att.fmt != "apple-appattest" || len(att.authData) == 0 || len(att.certs) == 0 {
		return false, ErrAppAttestBinding
	}
	parsedAuthData, err := parseAppAttestAuthData(att.authData)
	if err != nil {
		return false, ErrAppAttestBinding
	}
	if err := ctx.Err(); err != nil {
		return false, ErrAppAttestTransient
	}
	if !bytes.Equal(parsedAuthData.credentialID, evidence.KeyID) {
		return false, ErrAppAttestBinding
	}
	appIDHash := sha256.Sum256([]byte(appID))
	if !bytes.Equal(parsedAuthData.rpIDHash, appIDHash[:]) {
		return false, ErrAppAttestBinding
	}
	if parsedAuthData.signCount != 0 {
		return false, ErrAppAttestBinding
	}
	leaf, intermediates, err := parseAttestationCerts(att.certs)
	if err != nil {
		return false, ErrAppAttestBinding
	}
	if err := ctx.Err(); err != nil {
		return false, ErrAppAttestTransient
	}
	roots := x509.NewCertPool()
	roots.AddCert(root)
	intermediatePool := x509.NewCertPool()
	for _, cert := range intermediates {
		intermediatePool.AddCert(cert)
	}
	now := time.Now()
	if v.Now != nil {
		now = v.Now()
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         roots,
		Intermediates: intermediatePool,
		CurrentTime:   now,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return false, ErrAppAttestBinding
	}
	leafKey, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || leafKey.Curve != elliptic.P256() {
		return false, ErrAppAttestBinding
	}
	if parsedAuthData.publicKeyX.Cmp(leafKey.X) != 0 || parsedAuthData.publicKeyY.Cmp(leafKey.Y) != 0 {
		return false, ErrAppAttestBinding
	}
	wantNonceInput := make([]byte, 0, len(att.authData)+sha256.Size)
	wantNonceInput = append(wantNonceInput, att.authData...)
	wantNonceInput = append(wantNonceInput, evidence.ClientDataHash[:]...)
	wantNonce := sha256.Sum256(wantNonceInput)
	gotNonce, ok := appAttestNonceExtension(leaf.Extensions)
	if !ok || !bytes.Equal(gotNonce, wantNonce[:]) {
		return false, ErrAppAttestBinding
	}
	return true, nil
}

func parseSinglePEMCert(certPEM []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(certPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("missing certificate PEM")
	}
	return x509.ParseCertificate(block.Bytes)
}

type parsedAppAttestObject struct {
	fmt      string
	authData []byte
	certs    [][]byte
}

func parseAppAttestObject(raw []byte) (parsedAppAttestObject, error) {
	v, rest, err := newCBORDecoder(raw).parse()
	if err != nil {
		return parsedAppAttestObject{}, err
	}
	if len(rest) != 0 || v.kind != cborKindMap {
		return parsedAppAttestObject{}, errors.New("attestation object is not one bounded CBOR map")
	}
	fmtValue, ok := v.stringKey("fmt")
	if !ok {
		return parsedAppAttestObject{}, errors.New("missing fmt")
	}
	authData, ok := v.bytesKey("authData")
	if !ok {
		return parsedAppAttestObject{}, errors.New("missing authData")
	}
	stmt, ok := v.mapKey("attStmt")
	if !ok {
		return parsedAppAttestObject{}, errors.New("missing attStmt")
	}
	x5c, ok := stmt.arrayKey("x5c")
	if !ok || len(x5c) == 0 || len(x5c) > 4 {
		return parsedAppAttestObject{}, errors.New("missing x5c")
	}
	certs := make([][]byte, 0, len(x5c))
	for _, item := range x5c {
		if item.kind != cborKindBytes || len(item.bytes) == 0 || len(item.bytes) > 2048 {
			return parsedAppAttestObject{}, errors.New("invalid x5c cert")
		}
		certs = append(certs, item.bytes)
	}
	return parsedAppAttestObject{fmt: fmtValue, authData: authData, certs: certs}, nil
}

type parsedAuthData struct {
	rpIDHash     []byte
	signCount    uint32
	credentialID []byte
	publicKeyX   *big.Int
	publicKeyY   *big.Int
}

func parseAppAttestAuthData(authData []byte) (parsedAuthData, error) {
	if len(authData) < 55 {
		return parsedAuthData{}, errors.New("authData too short")
	}
	if authData[32]&authDataFlagAttestedCredential == 0 {
		return parsedAuthData{}, errors.New("authData missing attested credential")
	}
	out := parsedAuthData{
		rpIDHash:  append([]byte(nil), authData[:32]...),
		signCount: binary.BigEndian.Uint32(authData[33:37]),
	}
	offset := 37 + 16
	credentialIDLen := int(binary.BigEndian.Uint16(authData[offset : offset+2]))
	offset += 2
	if credentialIDLen <= 0 || credentialIDLen > 1024 || len(authData) < offset+credentialIDLen {
		return parsedAuthData{}, errors.New("invalid credential id length")
	}
	out.credentialID = append([]byte(nil), authData[offset:offset+credentialIDLen]...)
	offset += credentialIDLen
	cose, rest, err := newCBORDecoder(authData[offset:]).parse()
	if err != nil {
		return parsedAuthData{}, err
	}
	if len(rest) != 0 || cose.kind != cborKindMap {
		return parsedAuthData{}, errors.New("credential public key is not a bounded CBOR map")
	}
	if kty, ok := cose.intKey(1); !ok || kty != 2 {
		return parsedAuthData{}, errors.New("credential key is not EC2")
	}
	if crv, ok := cose.intKey(-1); !ok || crv != 1 {
		return parsedAuthData{}, errors.New("credential key is not P-256")
	}
	x, ok := cose.bytesIntKey(-2)
	if !ok || len(x) != 32 {
		return parsedAuthData{}, errors.New("credential x coordinate invalid")
	}
	y, ok := cose.bytesIntKey(-3)
	if !ok || len(y) != 32 {
		return parsedAuthData{}, errors.New("credential y coordinate invalid")
	}
	out.publicKeyX = new(big.Int).SetBytes(x)
	out.publicKeyY = new(big.Int).SetBytes(y)
	if !elliptic.P256().IsOnCurve(out.publicKeyX, out.publicKeyY) {
		return parsedAuthData{}, errors.New("credential key not on P-256")
	}
	return out, nil
}

func parseAttestationCerts(raw [][]byte) (*x509.Certificate, []*x509.Certificate, error) {
	leaf, err := x509.ParseCertificate(raw[0])
	if err != nil {
		return nil, nil, err
	}
	intermediates := make([]*x509.Certificate, 0, len(raw)-1)
	for _, der := range raw[1:] {
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, nil, err
		}
		intermediates = append(intermediates, cert)
	}
	return leaf, intermediates, nil
}

func appAttestNonceExtension(exts []pkix.Extension) ([]byte, bool) {
	for _, ext := range exts {
		if !ext.Id.Equal(appleAppAttestNonceOID) {
			continue
		}
		if len(ext.Value) == sha256.Size {
			return ext.Value, true
		}
		var raw asn1.RawValue
		rest, err := asn1.Unmarshal(ext.Value, &raw)
		if err != nil || len(rest) != 0 {
			return nil, false
		}
		switch raw.Tag {
		case asn1.TagOctetString:
			if len(raw.Bytes) == sha256.Size {
				return raw.Bytes, true
			}
		case asn1.TagSequence:
			var inner asn1.RawValue
			innerRest, err := asn1.Unmarshal(raw.Bytes, &inner)
			if err == nil && len(innerRest) == 0 && inner.Tag == asn1.TagOctetString && len(inner.Bytes) == sha256.Size {
				return inner.Bytes, true
			}
		}
		return nil, false
	}
	return nil, false
}

const (
	cborKindUint = iota
	cborKindInt
	cborKindBytes
	cborKindString
	cborKindArray
	cborKindMap
	cborKindBool
	cborKindNull
)

type cborValue struct {
	kind       int
	uintValue  uint64
	intValue   int64
	bytes      []byte
	string     string
	array      []cborValue
	mapEntries []cborPair
	boolValue  bool
}

type cborPair struct {
	key   cborValue
	value cborValue
}

func (v cborValue) stringKey(key string) (string, bool) {
	item, ok := v.getStringKey(key)
	if !ok || item.kind != cborKindString {
		return "", false
	}
	return item.string, true
}

func (v cborValue) bytesKey(key string) ([]byte, bool) {
	item, ok := v.getStringKey(key)
	if !ok || item.kind != cborKindBytes {
		return nil, false
	}
	return item.bytes, true
}

func (v cborValue) mapKey(key string) (cborValue, bool) {
	item, ok := v.getStringKey(key)
	if !ok || item.kind != cborKindMap {
		return cborValue{}, false
	}
	return item, true
}

func (v cborValue) arrayKey(key string) ([]cborValue, bool) {
	item, ok := v.getStringKey(key)
	if !ok || item.kind != cborKindArray {
		return nil, false
	}
	return item.array, true
}

func (v cborValue) intKey(key int64) (int64, bool) {
	item, ok := v.getIntKey(key)
	if !ok {
		return 0, false
	}
	switch item.kind {
	case cborKindUint:
		if item.uintValue > uint64(^uint(0)>>1) {
			return 0, false
		}
		return int64(item.uintValue), true
	case cborKindInt:
		return item.intValue, true
	default:
		return 0, false
	}
}

func (v cborValue) bytesIntKey(key int64) ([]byte, bool) {
	item, ok := v.getIntKey(key)
	if !ok || item.kind != cborKindBytes {
		return nil, false
	}
	return item.bytes, true
}

func (v cborValue) getStringKey(key string) (cborValue, bool) {
	if v.kind != cborKindMap {
		return cborValue{}, false
	}
	for _, pair := range v.mapEntries {
		if pair.key.kind == cborKindString && pair.key.string == key {
			return pair.value, true
		}
	}
	return cborValue{}, false
}

func (v cborValue) getIntKey(key int64) (cborValue, bool) {
	if v.kind != cborKindMap {
		return cborValue{}, false
	}
	for _, pair := range v.mapEntries {
		switch pair.key.kind {
		case cborKindUint:
			if key >= 0 && pair.key.uintValue == uint64(key) {
				return pair.value, true
			}
		case cborKindInt:
			if pair.key.intValue == key {
				return pair.value, true
			}
		}
	}
	return cborValue{}, false
}

type cborDecoder struct {
	data []byte
	off  int
}

func newCBORDecoder(data []byte) *cborDecoder {
	return &cborDecoder{data: data}
}

func (d *cborDecoder) parse() (cborValue, []byte, error) {
	v, err := d.parseValue(0)
	if err != nil {
		return cborValue{}, nil, err
	}
	return v, d.data[d.off:], nil
}

func (d *cborDecoder) parseValue(depth int) (cborValue, error) {
	if depth > cborMaxDepth {
		return cborValue{}, errors.New("CBOR nesting too deep")
	}
	if d.off >= len(d.data) {
		return cborValue{}, errors.New("CBOR truncated")
	}
	initial := d.data[d.off]
	d.off++
	major := initial >> 5
	additional := initial & 0x1f
	n, err := d.readLength(additional)
	if err != nil {
		return cborValue{}, err
	}
	switch major {
	case 0:
		return cborValue{kind: cborKindUint, uintValue: n}, nil
	case 1:
		if n > uint64(^uint(0)>>1) {
			return cborValue{}, errors.New("CBOR negative integer too large")
		}
		return cborValue{kind: cborKindInt, intValue: -1 - int64(n)}, nil
	case 2:
		if n > 4096 || int(n) > len(d.data)-d.off {
			return cborValue{}, errors.New("CBOR byte string invalid")
		}
		out := append([]byte(nil), d.data[d.off:d.off+int(n)]...)
		d.off += int(n)
		return cborValue{kind: cborKindBytes, bytes: out}, nil
	case 3:
		if n > 1024 || int(n) > len(d.data)-d.off {
			return cborValue{}, errors.New("CBOR text string invalid")
		}
		out := string(d.data[d.off : d.off+int(n)])
		d.off += int(n)
		return cborValue{kind: cborKindString, string: out}, nil
	case 4:
		if n > 128 {
			return cborValue{}, errors.New("CBOR array too large")
		}
		arr := make([]cborValue, 0, int(n))
		for i := 0; i < int(n); i++ {
			item, err := d.parseValue(depth + 1)
			if err != nil {
				return cborValue{}, err
			}
			arr = append(arr, item)
		}
		return cborValue{kind: cborKindArray, array: arr}, nil
	case 5:
		if n > 128 {
			return cborValue{}, errors.New("CBOR map too large")
		}
		entries := make([]cborPair, 0, int(n))
		for i := 0; i < int(n); i++ {
			key, err := d.parseValue(depth + 1)
			if err != nil {
				return cborValue{}, err
			}
			value, err := d.parseValue(depth + 1)
			if err != nil {
				return cborValue{}, err
			}
			entries = append(entries, cborPair{key: key, value: value})
		}
		return cborValue{kind: cborKindMap, mapEntries: entries}, nil
	case 7:
		switch additional {
		case 20:
			return cborValue{kind: cborKindBool, boolValue: false}, nil
		case 21:
			return cborValue{kind: cborKindBool, boolValue: true}, nil
		case 22:
			return cborValue{kind: cborKindNull}, nil
		default:
			return cborValue{}, errors.New("unsupported CBOR simple value")
		}
	default:
		return cborValue{}, fmt.Errorf("unsupported CBOR major type %d", major)
	}
}

func (d *cborDecoder) readLength(additional byte) (uint64, error) {
	switch {
	case additional <= 23:
		return uint64(additional), nil
	case additional == 24:
		if d.off+1 > len(d.data) {
			return 0, errors.New("CBOR uint8 truncated")
		}
		v := d.data[d.off]
		d.off++
		return uint64(v), nil
	case additional == 25:
		if d.off+2 > len(d.data) {
			return 0, errors.New("CBOR uint16 truncated")
		}
		v := binary.BigEndian.Uint16(d.data[d.off : d.off+2])
		d.off += 2
		return uint64(v), nil
	case additional == 26:
		if d.off+4 > len(d.data) {
			return 0, errors.New("CBOR uint32 truncated")
		}
		v := binary.BigEndian.Uint32(d.data[d.off : d.off+4])
		d.off += 4
		return uint64(v), nil
	case additional == 27:
		if d.off+8 > len(d.data) {
			return 0, errors.New("CBOR uint64 truncated")
		}
		v := binary.BigEndian.Uint64(d.data[d.off : d.off+8])
		d.off += 8
		return v, nil
	default:
		return 0, errors.New("indefinite or reserved CBOR length rejected")
	}
}
