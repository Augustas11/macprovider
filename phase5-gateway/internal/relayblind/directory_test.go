package relayblind

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/elliptic"
	"encoding/base64"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"testing"
	"time"
)

func directoryTestKey(seed byte) ed25519.PrivateKey {
	return ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, ed25519.SeedSize))
}

func directoryTestSEKey(t *testing.T, seed byte) string {
	t.Helper()
	curve := elliptic.P256()
	d := bytes.Repeat([]byte{seed}, 32)
	x, y := curve.ScalarBaseMult(d)
	raw := make([]byte, 64)
	x.FillBytes(raw[:32])
	y.FillBytes(raw[32:])
	return base64.StdEncoding.EncodeToString(raw)
}

func directoryTestEntry(t *testing.T, identity ed25519.PrivateKey, seSeed byte, revoked bool) IdentityDirectoryEntry {
	t.Helper()
	pub := identity.Public().(ed25519.PublicKey)
	se, err := DecodeSEPublicKey(directoryTestSEKey(t, seSeed))
	if err != nil {
		t.Fatal(err)
	}
	return IdentityDirectoryEntry{
		IdentityPublicKey:      encodeBase64URL(pub),
		Fingerprint:            PublicKeyFingerprint(pub),
		SEPublicKeyFingerprint: PublicKeyFingerprint(se),
		Source:                 IdentityDirectorySourceEnrolled,
		EnrolledAtUnix:         1_700_000_000,
		Revoked:                revoked,
	}
}

func directoryTestDirectory(t *testing.T, now time.Time, entries ...IdentityDirectoryEntry) IdentityDirectory {
	t.Helper()
	sort.Slice(entries, func(i, j int) bool { return entries[i].Fingerprint < entries[j].Fingerprint })
	if entries == nil {
		entries = []IdentityDirectoryEntry{}
	}
	return IdentityDirectory{
		Version:       IdentityDirectoryVersion,
		PrivacyClass:  PrivacyClassV1,
		IssuedAtUnix:  now.Unix(),
		ExpiresAtUnix: now.Unix() + 300,
		Entries:       entries,
	}
}

func TestIdentityDirectorySignVerifyRoundTrip(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	signer := directoryTestKey(0x41)
	directory := directoryTestDirectory(t, now,
		directoryTestEntry(t, directoryTestKey(0x01), 0x11, false),
		directoryTestEntry(t, directoryTestKey(0x02), 0x12, true),
	)
	raw, err := SignIdentityDirectory(directory, signer)
	if err != nil {
		t.Fatalf("SignIdentityDirectory: %v", err)
	}
	got, err := VerifyIdentityDirectory(raw, signer.Public().(ed25519.PublicKey), now.Add(10*time.Second))
	if err != nil {
		t.Fatalf("VerifyIdentityDirectory: %v", err)
	}
	if len(got.Entries) != 2 || got.IssuedAtUnix != directory.IssuedAtUnix {
		t.Fatalf("round trip lost content: %+v", got)
	}
	for _, entry := range directory.Entries {
		found, ok := got.Lookup(entry.Fingerprint)
		if !ok || found != entry {
			t.Fatalf("lookup %s = %+v %v", entry.Fingerprint, found, ok)
		}
	}
}

func TestIdentityDirectoryRejectsWrongKeyTamperAndStaleness(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	signer := directoryTestKey(0x41)
	pinned := signer.Public().(ed25519.PublicKey)
	directory := directoryTestDirectory(t, now, directoryTestEntry(t, directoryTestKey(0x01), 0x11, false))
	raw, err := SignIdentityDirectory(directory, signer)
	if err != nil {
		t.Fatal(err)
	}

	other := directoryTestKey(0x42)
	otherRaw, err := SignIdentityDirectory(directory, other)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyIdentityDirectory(otherRaw, pinned, now); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("directory signed by another key accepted: %v", err)
	}

	var envelope IdentityDirectoryEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatal(err)
	}
	// A key_id that matches but a signature by another key still fails.
	forged := envelope
	var otherEnvelope IdentityDirectoryEnvelope
	_ = json.Unmarshal(otherRaw, &otherEnvelope)
	forged.Signature = otherEnvelope.Signature
	forgedRaw, _ := json.Marshal(forged)
	if _, err := VerifyIdentityDirectory(forgedRaw, pinned, now); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("forged signature accepted: %v", err)
	}

	payload, _ := base64.RawURLEncoding.DecodeString(envelope.Payload)
	tampered := envelope
	tampered.Payload = encodeBase64URL(bytes.Replace(payload, []byte(`"revoked":false`), []byte(`"revoked":true `), 1))
	tamperedRaw, _ := json.Marshal(tampered)
	if _, err := VerifyIdentityDirectory(tamperedRaw, pinned, now); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("tampered payload accepted: %v", err)
	}

	if _, err := VerifyIdentityDirectory(raw, pinned, now.Add(300*time.Second)); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("expired directory accepted: %v", err)
	}
	if _, err := VerifyIdentityDirectory(raw, pinned, now.Add(-61*time.Second)); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("future directory accepted: %v", err)
	}
	if _, err := VerifyIdentityDirectory(raw, pinned, now.Add(-60*time.Second)); err != nil {
		t.Fatalf("directory within future skew rejected: %v", err)
	}

	extra := strings.Replace(string(raw), `{"version"`, `{"extra":1,"version"`, 1)
	if _, err := VerifyIdentityDirectory([]byte(extra), pinned, now); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("open envelope accepted: %v", err)
	}
	if _, err := VerifyIdentityDirectory(bytes.Repeat([]byte{' '}, MaxIdentityDirectoryBytes+1), pinned, now); !errors.Is(err, ErrInvalidDirectory) {
		t.Fatalf("oversize envelope accepted: %v", err)
	}
}

func TestIdentityDirectoryValidateClosedPayload(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	a := directoryTestEntry(t, directoryTestKey(0x01), 0x11, false)
	b := directoryTestEntry(t, directoryTestKey(0x02), 0x12, false)
	base := directoryTestDirectory(t, now, a, b)
	cases := map[string]func(d *IdentityDirectory){
		"unsorted":         func(d *IdentityDirectory) { d.Entries[0], d.Entries[1] = d.Entries[1], d.Entries[0] },
		"duplicate":        func(d *IdentityDirectory) { d.Entries[1] = d.Entries[0] },
		"wrong version":    func(d *IdentityDirectory) { d.Version = "privacy-identity-directory-v2" },
		"wrong class":      func(d *IdentityDirectory) { d.PrivacyClass = "other" },
		"ttl too short":    func(d *IdentityDirectory) { d.ExpiresAtUnix = d.IssuedAtUnix + 59 },
		"ttl too long":     func(d *IdentityDirectory) { d.ExpiresAtUnix = d.IssuedAtUnix + 3601 },
		"fingerprint":      func(d *IdentityDirectory) { d.Entries[0].Fingerprint = d.Entries[1].Fingerprint },
		"source":           func(d *IdentityDirectory) { d.Entries[0].Source = "tofu" },
		"nil entries":      func(d *IdentityDirectory) { d.Entries = nil },
		"negative enroll":  func(d *IdentityDirectory) { d.Entries[0].EnrolledAtUnix = -1 },
		"se fingerprint":   func(d *IdentityDirectory) { d.Entries[0].SEPublicKeyFingerprint = "short" },
		"identity encoded": func(d *IdentityDirectory) { d.Entries[0].IdentityPublicKey += "=" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			d := base
			d.Entries = append([]IdentityDirectoryEntry(nil), base.Entries...)
			mutate(&d)
			if err := d.Validate(); err == nil {
				t.Fatalf("invalid directory validated")
			}
			if _, err := SignIdentityDirectory(d, directoryTestKey(0x41)); err == nil {
				t.Fatalf("invalid directory signed")
			}
		})
	}
	empty := directoryTestDirectory(t, now)
	if err := empty.Validate(); err != nil {
		t.Fatalf("empty directory rejected: %v", err)
	}
}

func TestIdentityDirectoryPinForRecord(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	identity := directoryTestKey(0x07)
	provider, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x33}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewSignedKeyRecord(provider.PublicKey().Bytes(), identity, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	directory := directoryTestDirectory(t, now, directoryTestEntry(t, identity, 0x11, false))
	pin, err := directory.PinForRecord(record, "model-a")
	if err != nil {
		t.Fatalf("PinForRecord: %v", err)
	}
	if err := pin.VerifyRecord(record, now); err != nil {
		t.Fatalf("directory pin rejects its own record: %v", err)
	}
	if pin.ExpiresAtUnix != directory.ExpiresAtUnix || pin.NotBeforeUnix != directory.IssuedAtUnix {
		t.Fatalf("pin window is not the directory window: %+v", pin)
	}
	if _, err := directory.PinForRecord(record, "model-b"); !errors.Is(err, ErrInvalidPin) {
		t.Fatalf("record outside requested model accepted: %v", err)
	}

	revoked := directoryTestDirectory(t, now, directoryTestEntry(t, identity, 0x11, true))
	if _, err := revoked.PinForRecord(record, "model-a"); !errors.Is(err, ErrInvalidPin) {
		t.Fatalf("revoked identity accepted: %v", err)
	}
	missing := directoryTestDirectory(t, now, directoryTestEntry(t, directoryTestKey(0x08), 0x11, false))
	if _, err := missing.PinForRecord(record, "model-a"); !errors.Is(err, ErrInvalidPin) {
		t.Fatalf("identity absent from directory accepted: %v", err)
	}
	// An entry whose identity differs from the record signer cannot verify it.
	if err := (IdentityPin{
		Version: PinVersion, IdentityPublicKey: missing.Entries[0].IdentityPublicKey, Fingerprint: missing.Entries[0].Fingerprint,
		Models: []string{"model-a"}, EndpointFamilies: []string{EndpointChatCompletions}, NotBeforeUnix: 0, ExpiresAtUnix: now.Unix() + 10,
	}).VerifyRecord(record, now); err == nil {
		t.Fatalf("record verified under another identity")
	}
}

func TestPrivacyEnrollmentClaimClosed(t *testing.T) {
	identity := directoryTestKey(0x09).Public().(ed25519.PublicKey)
	se := directoryTestSEKey(t, 0x13)
	valid := map[string]any{
		"version":             PrivacyEnrollmentVersion,
		"identity_public_key": encodeBase64URL(identity),
		"se_public_key":       se,
	}
	raw, _ := json.Marshal(valid)
	claim, err := ParsePrivacyEnrollmentClaim(raw)
	if err != nil {
		t.Fatalf("ParsePrivacyEnrollmentClaim: %v", err)
	}
	if claim.SEPublicKey != se {
		t.Fatalf("claim lost the secure enclave key")
	}
	offCurve := make([]byte, 64)
	offCurve[63] = 1
	invalid := map[string]map[string]any{
		"extra field":   {"version": PrivacyEnrollmentVersion, "identity_public_key": encodeBase64URL(identity), "se_public_key": se, "provider_id": "p"},
		"missing field": {"version": PrivacyEnrollmentVersion, "identity_public_key": encodeBase64URL(identity)},
		"version":       {"version": "privacy-enrollment-v2", "identity_public_key": encodeBase64URL(identity), "se_public_key": se},
		"identity":      {"version": PrivacyEnrollmentVersion, "identity_public_key": base64.StdEncoding.EncodeToString(identity), "se_public_key": se},
		"se off curve":  {"version": PrivacyEnrollmentVersion, "identity_public_key": encodeBase64URL(identity), "se_public_key": base64.StdEncoding.EncodeToString(offCurve)},
		"se url form":   {"version": PrivacyEnrollmentVersion, "identity_public_key": encodeBase64URL(identity), "se_public_key": strings.TrimRight(base64.URLEncoding.EncodeToString(mustDecodeStd(t, se)), "=")},
		"null":          {"version": PrivacyEnrollmentVersion, "identity_public_key": nil, "se_public_key": se},
	}
	for name, value := range invalid {
		raw, _ := json.Marshal(value)
		if _, err := ParsePrivacyEnrollmentClaim(raw); err == nil {
			t.Fatalf("%s: invalid claim accepted", name)
		}
	}
}

func mustDecodeStd(t *testing.T, value string) []byte {
	t.Helper()
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}
