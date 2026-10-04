package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"math/big"
	"strings"
	"testing"
	"time"
)

func TestAppleRootIsPinnedCA(t *testing.T) {
	root, err := loadAppleRoot()
	if err != nil {
		t.Fatal(err)
	}
	if fingerprint(root) != appleRootFingerprint {
		t.Fatalf("fingerprint %s", fingerprint(root))
	}
	if !strings.Contains(root.Subject.CommonName, "Apple App Attestation Root CA") {
		t.Fatalf("subject %s", root.Subject)
	}
}

func TestNonceExtensionMatchesDocumentedLayout(t *testing.T) {
	nonce := bytes.Repeat([]byte{0x5a}, 32)
	manual := nonceExtensionDER(t, nonce)
	want := append([]byte{0x30, 0x24, 0xa1, 0x22, 0x04, 0x20}, nonce...)
	if !bytes.Equal(manual, want) {
		t.Fatalf("manual nonce DER %x", manual)
	}
	got, err := explicitOctet(manual, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, nonce) {
		t.Fatalf("extracted %x", got)
	}
	type nonceExt struct {
		Nonce []byte `asn1:"explicit,tag:1"`
	}
	encoded, err := asn1.Marshal(nonceExt{Nonce: nonce})
	if err != nil {
		t.Fatal(err)
	}
	got, err = explicitOctet(encoded, 1)
	if err != nil {
		t.Fatalf("asn1 form %x: %v", encoded, err)
	}
	if !bytes.Equal(got, nonce) {
		t.Fatal("asn1 nonce mismatch")
	}
}

func TestACLDumpShowsInnerLabels(t *testing.T) {
	inner := aclPolicyDER(t, "osgn")
	outer := explicitOctetDER(t, 3, inner)
	got, err := singleOctet(outer)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, inner) {
		t.Fatal("inner octet mismatch")
	}
	direct := append([]byte{0x30, byte(len(inner) + 2), 0x04, byte(len(inner))}, inner...)
	got, err = singleOctet(direct)
	if err != nil || !bytes.Equal(got, inner) {
		t.Fatalf("direct SEQUENCE { OCTET STRING } form: %v", err)
	}
	dump, err := dumpDER(outer)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(dump, "UTF8STRING") || !strings.Contains(dump, "osgn") || !strings.Contains(dump, "BOOLEAN") {
		t.Fatalf("dump missing labels:\n%s", dump)
	}
}

func TestChainRejectsSelfMadeCA(t *testing.T) {
	fixture := buildFixture(t, fixtureOpts{})
	apple, err := loadAppleRoot()
	if err != nil {
		t.Fatal(err)
	}
	fixture.input.Root = apple
	if _, err := VerifyAttestation(fixture.input); err == nil {
		t.Fatal("self-made chain verified against the Apple root")
	}
	otherKey, other := makeCA(t, "other-root")
	_ = otherKey
	if err := verifyChain(fixture.leaf, []*x509.Certificate{fixture.intermediate}, other, time.Now()); err == nil {
		t.Fatal("chain accepted a different trust anchor")
	}
	if err := verifyChain(fixture.leaf, []*x509.Certificate{fixture.intermediate}, fixture.root, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func TestAttestationSyntheticChain(t *testing.T) {
	fixture := buildFixture(t, fixtureOpts{})
	report, err := VerifyAttestation(fixture.input)
	if err != nil {
		t.Fatal(err)
	}
	if !report.ACLPresent || !report.ACLFullSecurity || !bytes.Equal(report.PublicKeySHA256, fixture.keyID) {
		t.Fatalf("report missing acl or key hash: %+v", report.ValidationCategory)
	}
	if report.ValidationCategory != 6 || report.BundleVersion != "1.0.0" {
		t.Fatalf("extensions = %d %q", report.ValidationCategory, report.BundleVersion)
	}
	if !strings.Contains(report.ACLInnerDump, "osgn") || !strings.Contains(report.ACLInnerDump, "rsec") {
		t.Fatalf("acl dump:\n%s", report.ACLInnerDump)
	}

	bad := fixture.input
	bad.ClientDataHash = bytes.Clone(fixture.input.ClientDataHash)
	bad.ClientDataHash[0] ^= 0xff
	if _, err := VerifyAttestation(bad); err == nil {
		t.Fatal("nonce mismatch accepted")
	}

	wrongID := fixture.input
	wrongID.Bundle = "tech.malibu.other"
	if _, err := VerifyAttestation(wrongID); err == nil {
		t.Fatal("wrong app id accepted")
	}

	dev := fixture.input
	dev.Env = EnvDevelopment
	dev.Category = CategoryPolicy{Value: 3}
	if _, err := VerifyAttestation(dev); err == nil {
		t.Fatal("production aaguid accepted as development")
	}
}

func TestAttestationACLPolicy(t *testing.T) {
	weak := buildFixture(t, fixtureOpts{aclInner: aclPolicyDER(t, "osgn")})
	if _, err := VerifyAttestation(weak.input); err == nil {
		t.Fatal("non Full Security aclBlob accepted under --acl require")
	}
	weak.input.ACL = ACLRecord
	report, err := VerifyAttestation(weak.input)
	if err != nil {
		t.Fatal(err)
	}
	if !report.ACLPresent || report.ACLFullSecurity {
		t.Fatalf("acl present=%t full=%t", report.ACLPresent, report.ACLFullSecurity)
	}
	missing := buildFixture(t, fixtureOpts{noACL: true})
	if _, err := VerifyAttestation(missing.input); err == nil {
		t.Fatal("missing aclBlob accepted under --acl require")
	}
	missing.input.ACL = ACLRecord
	if _, err := VerifyAttestation(missing.input); err != nil {
		t.Fatal(err)
	}
}

func TestClientChallenge(t *testing.T) {
	if err := checkClientChallenge([]byte(`{"challenge":"abc","seq":1}`), "abc"); err != nil {
		t.Fatal(err)
	}
	for _, doc := range []string{`{"challenge":"abd"}`, `{"seq":1}`, `not json`} {
		if err := checkClientChallenge([]byte(doc), "abc"); err == nil {
			t.Fatalf("accepted %s", doc)
		}
	}
	if err := checkClientChallenge([]byte(`{"challenge":""}`), ""); err == nil {
		t.Fatal("accepted an empty nonce")
	}
}

func TestAttestationRejectsBadCounterAndCategory(t *testing.T) {
	counter := buildFixture(t, fixtureOpts{counter: 1})
	if _, err := VerifyAttestation(counter.input); err == nil {
		t.Fatal("nonzero attestation counter accepted")
	}
	badCategory := buildFixture(t, fixtureOpts{category: 0, categorySet: true})
	if _, err := VerifyAttestation(badCategory.input); err == nil {
		t.Fatal("category 0 accepted")
	}
	uintCategory := buildFixture(t, fixtureOpts{categoryAsUint: true, category: 6})
	if _, err := VerifyAttestation(uintCategory.input); err != nil {
		t.Fatal(err)
	}
}

func TestAssertionCounterIncreases(t *testing.T) {
	fixture := buildFixture(t, fixtureOpts{})
	report, err := VerifyAttestation(fixture.input)
	if err != nil {
		t.Fatal(err)
	}
	app := fixture.input.Team + "." + fixture.input.Bundle
	firstData := []byte(`{"purpose":"spike-1840-posture","seq":1}`)
	secondData := []byte(`{"purpose":"spike-1840-posture","seq":2}`)
	items := []Assertion{
		{Body: signAssertion(t, fixture.leafKey, app, 1, firstData), ClientData: firstData},
		{Body: signAssertion(t, fixture.leafKey, app, 2, secondData), ClientData: secondData},
	}
	assertReport, err := VerifyAssertions(report.PublicKey, fixture.input.Team, fixture.input.Bundle, items, CategoryPolicy{Value: 6})
	if err != nil {
		t.Fatal(err)
	}
	if len(assertReport.Counters) != 2 || assertReport.Counters[0] != 1 || assertReport.Counters[1] != 2 {
		t.Fatalf("counters %#v", assertReport.Counters)
	}
	if !bytes.Equal(assertReport.PublicKeySHA256, report.PublicKeySHA256) {
		t.Fatal("assertion key hash diverged")
	}

	stalled := []Assertion{items[0], items[0]}
	if _, err := VerifyAssertions(report.PublicKey, fixture.input.Team, fixture.input.Bundle, stalled, CategoryPolicy{Any: true}); err == nil {
		t.Fatal("repeated counter accepted")
	}

	tampered := items[1]
	tampered.Body = bytes.Clone(tampered.Body)
	tampered.Body[len(tampered.Body)-1] ^= 0x01
	if _, err := VerifyAssertions(report.PublicKey, fixture.input.Team, fixture.input.Bundle, []Assertion{items[0], tampered}, CategoryPolicy{Any: true}); err == nil {
		t.Fatal("tampered signature accepted")
	}

	wrong := signAssertion(t, fixture.leafKey, "1234567890.other.example", 2, secondData)
	if _, err := VerifyAssertions(report.PublicKey, fixture.input.Team, fixture.input.Bundle, []Assertion{items[0], {Body: wrong, ClientData: secondData}}, CategoryPolicy{Any: true}); err == nil {
		t.Fatal("wrong rpIdHash accepted")
	}
}

type fixtureOpts struct {
	aclInner       []byte
	noACL          bool
	counter        uint32
	category       uint32
	categorySet    bool
	categoryAsUint bool
}

type fixture struct {
	input        AttestInput
	leaf         *x509.Certificate
	intermediate *x509.Certificate
	root         *x509.Certificate
	leafKey      *ecdsa.PrivateKey
	keyID        []byte
}

func buildFixture(t *testing.T, opts fixtureOpts) fixture {
	t.Helper()
	if !opts.categorySet {
		opts.category = 6
	}
	rootKey, root := makeCA(t, "spike-test-root")
	interKey, inter := makeIntermediate(t, root, rootKey)
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	team := "1234567890"
	bundle := "tech.malibu.app"
	app := team + "." + bundle
	auth := buildAuthData(t, &leafKey.PublicKey, app, EnvProduction, opts.counter, "1.0.0", opts.category, opts.categoryAsUint)
	challenge := make([]byte, 32)
	if _, err := rand.Read(challenge); err != nil {
		t.Fatal(err)
	}
	clientHash := sha256.Sum256(challenge)
	nonceInput := append(append([]byte{}, auth...), clientHash[:]...)
	nonce := sha256.Sum256(nonceInput)
	var aclExt []byte
	if !opts.noACL {
		inner := opts.aclInner
		if inner == nil {
			inner = fullSecurityACL(t)
		}
		aclExt = explicitOctetDER(t, 3, inner)
	}
	leaf := makeLeaf(t, inter, interKey, leafKey, nonce[:], aclExt)
	keyHash, err := publicKeyHash(&leafKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	body, err := Encode(Value{Kind: KindMap, Pairs: []Pair{
		{Key: textValue("fmt"), Val: textValue(attestFmt)},
		{Key: textValue("attStmt"), Val: Value{Kind: KindMap, Pairs: []Pair{
			{Key: textValue("x5c"), Val: Value{Kind: KindArray, Array: []Value{
				bytesValue(leaf.Raw),
				bytesValue(inter.Raw),
			}}},
			{Key: textValue("receipt"), Val: bytesValue([]byte{0x30, 0x03, 0x02, 0x01, 0x01})},
		}}},
		{Key: textValue("authData"), Val: bytesValue(auth)},
	}})
	if err != nil {
		t.Fatal(err)
	}
	return fixture{
		input: AttestInput{
			Attestation:    body,
			KeyID:          keyHash,
			ClientDataHash: clientHash[:],
			Team:           team,
			Bundle:         bundle,
			Env:            EnvProduction,
			Category:       CategoryPolicy{Value: 6},
			BundleVersion:  "1.0.0",
			ACL:            ACLRequire,
			Now:            time.Now(),
			Root:           root,
		},
		leaf:         leaf,
		intermediate: inter,
		root:         root,
		leafKey:      leafKey,
		keyID:        keyHash,
	}
}

func buildAuthData(t *testing.T, pub *ecdsa.PublicKey, app string, env Environment, counter uint32, version string, category uint32, categoryAsUint bool) []byte {
	t.Helper()
	rp := sha256.Sum256([]byte(app))
	keyHash, err := publicKeyHash(pub)
	if err != nil {
		t.Fatal(err)
	}
	cose, err := Encode(cosePublicKey(pub))
	if err != nil {
		t.Fatal(err)
	}
	var categoryValue Value
	if categoryAsUint {
		categoryValue = uintValue(uint64(category))
	} else {
		raw := make([]byte, 4)
		binary.LittleEndian.PutUint32(raw, category)
		categoryValue = bytesValue(raw)
	}
	ext, err := Encode(Value{Kind: KindMap, Pairs: []Pair{
		{Key: textValue("apple_bundle_version_01"), Val: textValue(version)},
		{Key: textValue("apple_validation_category_01"), Val: categoryValue},
	}})
	if err != nil {
		t.Fatal(err)
	}
	aaguid, err := env.aaguid()
	if err != nil {
		t.Fatal(err)
	}
	var out []byte
	out = append(out, rp[:]...)
	out = append(out, authFlagAT)
	var counterBytes [4]byte
	binary.BigEndian.PutUint32(counterBytes[:], counter)
	out = append(out, counterBytes[:]...)
	out = append(out, aaguid[:]...)
	out = append(out, 0x00, 0x20)
	out = append(out, keyHash...)
	out = append(out, cose...)
	out = append(out, ext...)
	return out
}

func cosePublicKey(pub *ecdsa.PublicKey) Value {
	return Value{Kind: KindMap, Pairs: []Pair{
		{Key: uintValue(1), Val: uintValue(2)},
		{Key: uintValue(3), Val: negValue(-7)},
		{Key: negValue(-1), Val: uintValue(1)},
		{Key: negValue(-2), Val: bytesValue(pub.X.FillBytes(make([]byte, 32)))},
		{Key: negValue(-3), Val: bytesValue(pub.Y.FillBytes(make([]byte, 32)))},
	}}
}

func signAssertion(t *testing.T, key *ecdsa.PrivateKey, app string, counter uint32, client []byte) []byte {
	t.Helper()
	rp := sha256.Sum256([]byte(app))
	auth := make([]byte, 37)
	copy(auth, rp[:])
	binary.BigEndian.PutUint32(auth[33:], counter)
	clientHash := sha256.Sum256(client)
	nonce := sha256.Sum256(append(append([]byte{}, auth...), clientHash[:]...))
	digest := sha256.Sum256(nonce[:])
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := Encode(Value{Kind: KindMap, Pairs: []Pair{
		{Key: textValue("signature"), Val: bytesValue(sig)},
		{Key: textValue("authenticatorData"), Val: bytesValue(auth)},
	}})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func makeCA(t *testing.T, name string) (*ecdsa.PrivateKey, *x509.Certificate) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          serial(t),
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLen:            1,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	return key, signCert(t, template, template, &key.PublicKey, key)
}

func makeIntermediate(t *testing.T, root *x509.Certificate, rootKey *ecdsa.PrivateKey) (*ecdsa.PrivateKey, *x509.Certificate) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          serial(t),
		Subject:               pkix.Name{CommonName: "spike-test-intermediate"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLenZero:        true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	return key, signCert(t, template, root, &key.PublicKey, rootKey)
}

func makeLeaf(t *testing.T, parent *x509.Certificate, parentKey, leafKey *ecdsa.PrivateKey, nonce, aclExt []byte) *x509.Certificate {
	t.Helper()
	template := &x509.Certificate{
		SerialNumber: serial(t),
		Subject:      pkix.Name{CommonName: "spike-test-leaf"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{Id: oidAttestNonce, Critical: true, Value: nonceExtensionDER(t, nonce)},
		},
	}
	if aclExt != nil {
		template.ExtraExtensions = append(template.ExtraExtensions, pkix.Extension{Id: oidAttestACL, Value: aclExt})
	}
	return signCert(t, template, parent, &leafKey.PublicKey, parentKey)
}

func signCert(t *testing.T, template, parent *x509.Certificate, pub any, signer *ecdsa.PrivateKey) *x509.Certificate {
	t.Helper()
	der, err := x509.CreateCertificate(rand.Reader, template, parent, pub, signer)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return cert
}

func serial(t *testing.T) *big.Int {
	t.Helper()
	n, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 64))
	if err != nil {
		t.Fatal(err)
	}
	return n.Add(n, big.NewInt(1))
}

func nonceExtensionDER(t *testing.T, nonce []byte) []byte {
	t.Helper()
	return explicitOctetDER(t, 1, nonce)
}

func explicitOctetDER(t *testing.T, tag int, payload []byte) []byte {
	t.Helper()
	if tag > 30 || len(payload) > 120 {
		t.Fatalf("test helper length tag=%d payload=%d", tag, len(payload))
	}
	octet := append([]byte{0x04, byte(len(payload))}, payload...)
	wrap := append([]byte{0xa0 | byte(tag), byte(len(octet))}, octet...)
	return append([]byte{0x30, byte(len(wrap))}, wrap...)
}

func aclPolicyDER(t *testing.T, label string) []byte {
	t.Helper()
	name := append([]byte{0x0c, byte(len(label))}, label...)
	flag := []byte{0xa1, 0x03, 0x01, 0x01, 0xff}
	entry := append([]byte{0x30, byte(len(name) + len(flag))}, name...)
	entry = append(entry, flag...)
	return append([]byte{0x30, byte(len(entry))}, entry...)
}

func fullSecurityACL(t *testing.T) []byte {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(aclFullSecurityB64)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
