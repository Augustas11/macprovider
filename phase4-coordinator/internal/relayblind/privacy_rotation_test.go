package relayblind

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// rotationSigners lets a test replace any of the three rotation keys.
type rotationSigners struct {
	se       *ecdsa.PrivateKey
	previous ed25519.PrivateKey
	next     ed25519.PrivateKey
}

// enrolledRotationFixture is an enrolled provider (no operator pins) with a
// verified posture, ready to rotate its identity key.
func enrolledRotationFixture(t *testing.T, mutate func(*config.PrivacyClassConfig)) *privacyFixture {
	t.Helper()
	f := newEnrollmentFixture(t, mutate)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(1); err != nil {
		t.Fatal(err)
	}
	if _, ok := activeEnrollment(t, f); !ok {
		t.Fatal("fixture did not enroll")
	}
	return f
}

// age moves the fixture past the SPEC-049-R031 minimum enrollment age.
func (f *privacyFixture) age() {
	f.now = f.now.Add(MinRotationInterval + time.Hour)
}

func rotationKey(seed byte) ed25519.PrivateKey {
	return ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, ed25519.SeedSize))
}

// rotationMessage builds a signed privacy_key_rotation for nonce.
func (f *privacyFixture) rotationMessage(nonce string, seq uint64, signers rotationSigners, mutate func(*KeyRotationStatement, *PostureStatement)) []byte {
	f.t.Helper()
	posture := f.statement(nonce, seq, f.now.Unix())
	statement := KeyRotationStatement{
		Version: PrivacyKeyRotationVersion, PrivacyClass: PrivacyClassV1, ProviderID: f.providerID, AssignedSession: f.session,
		Nonce: nonce, IssuedAtUnix: f.now.Unix(),
		PreviousIdentityPublicKey: encodeBase64URL(signers.previous.Public().(ed25519.PublicKey)),
		IdentityPublicKey:         encodeBase64URL(signers.next.Public().(ed25519.PublicKey)),
		SEPublicKey:               base64.StdEncoding.EncodeToString(f.seRaw),
	}
	if mutate != nil {
		mutate(&statement, &posture)
	}
	if statement.PostureDigest == "" {
		digest, err := PostureDigest(posture)
		if err != nil {
			f.t.Fatal(err)
		}
		statement.PostureDigest = digest
	}
	framing, err := statement.Framing()
	if err != nil {
		f.t.Fatal(err)
	}
	sum := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, signers.se, sum[:])
	if err != nil {
		f.t.Fatal(err)
	}
	raw, err := json.Marshal(privacyRotationWire{
		Type: privacyKeyRotationType, Version: 1, Statement: mustJSON(f.t, statement), Posture: mustJSON(f.t, posture),
		SESignature:               encodeBase64URL(seSig),
		PreviousIdentitySignature: encodeBase64URL(ed25519.Sign(signers.previous, framing)),
		IdentitySignature:         encodeBase64URL(ed25519.Sign(signers.next, framing)),
	})
	if err != nil {
		f.t.Fatal(err)
	}
	return raw
}

func (f *privacyFixture) rotate(seq uint64, signers rotationSigners, mutate func(*KeyRotationStatement, *PostureStatement)) (string, error) {
	f.t.Helper()
	nonce, _, reason := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now)
	if reason != "" {
		return reason, errors.New("challenge refused: " + reason)
	}
	return f.auth.VerifyRotation(context.Background(), f.providerID, f.session, nonce, f.rotationMessage(nonce, seq, signers, mutate), nil, f.now)
}

func (f *privacyFixture) signers(next ed25519.PrivateKey) rotationSigners {
	return rotationSigners{se: f.se, previous: f.identity, next: next}
}

// useIdentity switches the fixture to identity and a fresh key record
// signed by it, as the provider does after an accepted rotation.
func (f *privacyFixture) useIdentity(identity ed25519.PrivateKey, seed byte) {
	f.t.Helper()
	agreement, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{seed}, 32))
	if err != nil {
		f.t.Fatal(err)
	}
	keyRecord, err := NewSignedKeyRecord(agreement.PublicKey().Bytes(), identity, []string{"model-a"}, 4096, f.now, f.now.Add(time.Duration(MaxPrivacyKeyLifetimeSeconds)*time.Second))
	if err != nil {
		f.t.Fatal(err)
	}
	attestation := PrivacyKeyAttestation{
		Version: PrivacyKeyAttestationVersion, KeyRecordDigest: keyRecord.KeyRecordDigest,
		PrivacyClass: PrivacyClassV1, Assurance: PrivacyAssurance, BinaryVersion: fixtureBinary,
		CodeCDHash: fixtureCDHash, NotBeforeUnix: keyRecord.NotBeforeUnix, ExpiresAtUnix: keyRecord.ExpiresAtUnix,
	}
	f.identity = identity
	f.record = PrivacyKeyRecord{KeyRecord: keyRecord, Attestation: attestation, Signature: signAttestation(f.t, identity, attestation)}
}

func quarantinedNow(t *testing.T, f *privacyFixture) bool {
	t.Helper()
	quarantined, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now)
	if err != nil {
		t.Fatal(err)
	}
	return quarantined
}

// SPEC-049-R031: a rotation signed by the enrolled identity key, the enrolled
// Secure Enclave key, and the new key swaps the enrollment in one step,
// revokes the old privacy keys, and rejects held predispatch reservations.
// The provider then serves under the new key without an operator step.
func TestRotationSwapsEnrollmentWithoutOperator(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	old := f.identity
	oldRecord := f.record
	held := mustReserve(t, f.store, oldRecord.KeyRecord, "acct-held", true, f.now)
	f.age()
	next := rotationKey(0x42)
	reason, err := f.rotate(2, f.signers(next), nil)
	if err != nil || reason != RotationAccepted {
		t.Fatalf("rotation = %q, %v", reason, err)
	}
	active, ok := activeEnrollment(t, f)
	if !ok || active.IdentityPublicKey != encodeBase64URL(next.Public().(ed25519.PublicKey)) || active.SEPublicKey != base64.StdEncoding.EncodeToString(f.seRaw) ||
		active.PreviousIdentityFingerprint != PublicKeyFingerprint(old.Public().(ed25519.PublicKey)) || active.CodeCDHash != fixtureCDHash {
		t.Fatalf("active enrollment = %+v", active)
	}
	all, err := f.store.ListPrivacyEnrollments(context.Background(), f.now.Add(-time.Hour))
	if err != nil || len(all) != 2 || all[0].RevokedReason != enrollmentRotatedReason || all[0].RevokedAtUnix != f.now.Unix() {
		t.Fatalf("enrollments = %+v, %v", all, err)
	}
	if revoked, _, _ := keyRevocation(t, f.store, oldRecord.KeyRecord.KID); !revoked {
		t.Fatal("rotation left the retired key's privacy record fresh")
	}
	if state, code := reservationTerminal(t, f.store, held.ProviderBinding); state != ReservationStateRejected || code != PrivacyKeyRotatedTerminalCode {
		t.Fatalf("held reservation state=%s code=%s", state, code)
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, oldRecord.KeyRecord.KeyRecordDigest, f.now); ok {
		t.Fatal("retired key still eligible")
	}
	if quarantinedNow(t, f) {
		t.Fatal("an accepted rotation quarantined the provider")
	}

	// item 7: the retired claim is refused without quarantine.
	err = f.auth.AcceptPrivacyKeysWithClaim(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{oldRecord}, f.claim(), f.now)
	mustReject(t, err, privacyKeyRotationPendingReason)
	if quarantinedNow(t, f) {
		t.Fatal("the retired identity quarantined the provider")
	}

	// item 5: the provider switches keys and serves again.
	f.useIdentity(next, 0x43)
	if err := f.acceptClaim(); err != nil {
		t.Fatalf("new claim: %v", err)
	}
	if err := f.posture(3); err != nil {
		t.Fatalf("posture under the new key: %v", err)
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		t.Fatal("rotated provider is not eligible")
	}

	// The directory publishes the retired identity as revoked.
	directory, err := f.auth.BuildIdentityDirectory(context.Background(), f.now, 300*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	states := map[string]bool{}
	for _, entry := range directory.Entries {
		states[entry.Fingerprint] = entry.Revoked
	}
	if revoked, ok := states[PublicKeyFingerprint(old.Public().(ed25519.PublicKey))]; !ok || !revoked {
		t.Fatalf("retired identity not published as revoked: %v", states)
	}
	if revoked, ok := states[PublicKeyFingerprint(next.Public().(ed25519.PublicKey))]; !ok || revoked {
		t.Fatalf("new identity not published as active: %v", states)
	}

	// A different, unsigned key change still quarantines.
	f.rekey(0x77)
	mustQuarantine(t, f.acceptClaim(), "privacy_enrollment_key_changed")
}

// Unsigned or mismatched rotations quarantine and never change the
// enrollment (SPEC-049-R031 item 3).
func TestRotationUnsignedOrMismatchedQuarantines(t *testing.T) {
	stranger, err := ecdsa.GenerateKey(f256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name    string
		signers func(*privacyFixture) rotationSigners
		mutate  func(*privacyFixture, *KeyRotationStatement, *PostureStatement)
	}{
		{name: "previous identity signature from another key", signers: func(f *privacyFixture) rotationSigners {
			return rotationSigners{se: f.se, previous: rotationKey(0x01), next: rotationKey(0x42)}
		}, mutate: func(f *privacyFixture, s *KeyRotationStatement, _ *PostureStatement) {
			s.PreviousIdentityPublicKey = encodeBase64URL(f.identity.Public().(ed25519.PublicKey))
		}},
		{name: "secure enclave signature from another key", signers: func(f *privacyFixture) rotationSigners {
			return rotationSigners{se: stranger, previous: f.identity, next: rotationKey(0x42)}
		}},
		{name: "previous key is not the enrolled key", signers: func(f *privacyFixture) rotationSigners {
			return rotationSigners{se: f.se, previous: rotationKey(0x02), next: rotationKey(0x42)}
		}},
		{name: "secure enclave key changed", signers: func(f *privacyFixture) rotationSigners { return f.signers(rotationKey(0x42)) },
			mutate: func(f *privacyFixture, s *KeyRotationStatement, _ *PostureStatement) {
				raw := make([]byte, 64)
				stranger.X.FillBytes(raw[:32])
				stranger.Y.FillBytes(raw[32:])
				s.SEPublicKey = base64.StdEncoding.EncodeToString(raw)
			}},
		{name: "posture violates a required value", signers: func(f *privacyFixture) rotationSigners { return f.signers(rotationKey(0x42)) },
			mutate: func(_ *privacyFixture, _ *KeyRotationStatement, p *PostureStatement) { p.PTraced = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := enrolledRotationFixture(t, nil)
			f.age()
			f.age()
			before, _ := activeEnrollment(t, f)
			var mutate func(*KeyRotationStatement, *PostureStatement)
			if tc.mutate != nil {
				mutate = func(s *KeyRotationStatement, p *PostureStatement) { tc.mutate(f, s, p) }
			}
			reason, err := f.rotate(2, tc.signers(f), mutate)
			if !errors.Is(err, ErrPrivacyQuarantined) || reason != RotationInvalid {
				t.Fatalf("rotation = %q, %v; want quarantine", reason, err)
			}
			if !quarantinedNow(t, f) {
				t.Fatal("provider not quarantined")
			}
			after, ok := activeEnrollment(t, f)
			if !ok || after != before {
				t.Fatalf("enrollment changed: before=%+v after=%+v", before, after)
			}
		})
	}
}

// Refusals that the provider cannot be blamed for, or that only say "not
// now", reject without quarantine and change nothing.
func TestRotationRejectsWithoutQuarantine(t *testing.T) {
	t.Run("unapproved code identity", func(t *testing.T) {
		f := enrolledRotationFixture(t, nil)
		f.age()
		// The running release's approval is withdrawn after enrollment.
		f.auth.identities = []config.ApprovedCodeIdentity{approvedIdentity(secondFixtureCDHash)}
		reason, err := f.rotate(2, f.signers(rotationKey(0x42)), nil)
		if reason != RotationUnapprovedCodeIdentity || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
			t.Fatalf("rotation = %q, %v", reason, err)
		}
	})
	t.Run("binding to another session", func(t *testing.T) {
		f := enrolledRotationFixture(t, nil)
		f.age()
		reason, err := f.rotate(2, f.signers(rotationKey(0x42)), func(s *KeyRotationStatement, _ *PostureStatement) { s.AssignedSession = "session-b" })
		if reason != RotationInvalid || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
			t.Fatalf("rotation = %q, %v", reason, err)
		}
	})
	t.Run("posture digest mismatch", func(t *testing.T) {
		f := enrolledRotationFixture(t, nil)
		f.age()
		reason, err := f.rotate(2, f.signers(rotationKey(0x42)), func(s *KeyRotationStatement, _ *PostureStatement) {
			s.PostureDigest = encodeBase64URL(make([]byte, 32))
		})
		if reason != RotationInvalid || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
			t.Fatalf("rotation = %q, %v", reason, err)
		}
	})
	t.Run("stale clock", func(t *testing.T) {
		f := enrolledRotationFixture(t, nil)
		f.age()
		reason, err := f.rotate(2, f.signers(rotationKey(0x42)), func(s *KeyRotationStatement, _ *PostureStatement) { s.IssuedAtUnix -= 120 })
		if reason != RotationStale || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
			t.Fatalf("rotation = %q, %v", reason, err)
		}
	})
	t.Run("rotating back to a used key", func(t *testing.T) {
		f := enrolledRotationFixture(t, nil)
		f.age()
		first := f.identity
		next := rotationKey(0x42)
		if reason, err := f.rotate(2, f.signers(next), nil); reason != RotationAccepted {
			t.Fatalf("first rotation = %q, %v", reason, err)
		}
		f.identity = next
		f.age()
		reason, err := f.rotate(3, f.signers(first), nil)
		if reason != RotationKeyInUse || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
			t.Fatalf("rotation back = %q, %v", reason, err)
		}
	})
	t.Run("operator-pinned identity", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		if _, _, reason := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now); reason != RotationIdentityPinned {
			t.Fatalf("pinned identity challenge reason = %q", reason)
		}
	})
	t.Run("not enrolled", func(t *testing.T) {
		f := newEnrollmentFixture(t, nil)
		if _, _, reason := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now); reason != RotationNotEnrolled {
			t.Fatalf("unenrolled challenge reason = %q", reason)
		}
	})
	t.Run("quarantined", func(t *testing.T) {
		f := enrolledRotationFixture(t, nil)
		f.age()
		if err := f.store.Quarantine(context.Background(), f.providerID, "review", f.now, time.Hour); err != nil {
			t.Fatal(err)
		}
		if _, _, reason := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now); reason != RotationQuarantined {
			t.Fatalf("quarantined challenge reason = %q", reason)
		}
	})
}

// item 8: the nonce is single-use and challenges are rate-limited, so a
// captured rotation cannot be replayed.
func TestRotationReplayIsRejected(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	f.age()
	next := rotationKey(0x42)
	nonce, _, reason := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now)
	if reason != "" {
		t.Fatal(reason)
	}
	raw := f.rotationMessage(nonce, 2, f.signers(next), nil)
	if _, _, again := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now); again != RotationUnavailable {
		t.Fatalf("second outstanding challenge = %q", again)
	}
	if got, err := f.auth.VerifyRotation(context.Background(), f.providerID, f.session, nonce, raw, nil, f.now); got != RotationAccepted {
		t.Fatalf("rotation = %q, %v", got, err)
	}
	before, _ := activeEnrollment(t, f)
	if got, err := f.auth.VerifyRotation(context.Background(), f.providerID, f.session, nonce, raw, nil, f.now); got != RotationStale || !errors.Is(err, ErrPrivacyRejected) {
		t.Fatalf("replay = %q, %v", got, err)
	}
	if _, _, again := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now.Add(30*time.Second)); again != RotationUnavailable {
		t.Fatalf("challenge inside the interval = %q", again)
	}
	if after, _ := activeEnrollment(t, f); after != before || quarantinedNow(t, f) {
		t.Fatalf("replay changed state: %+v", after)
	}
}

// item 6: a provider that lost the result retries the same rotation and is
// told it was accepted, without a second store change.
func TestRotationRetryIsIdempotent(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	f.age()
	next := rotationKey(0x42)
	if reason, err := f.rotate(2, f.signers(next), nil); reason != RotationAccepted {
		t.Fatalf("rotation = %q, %v", reason, err)
	}
	before, _ := activeEnrollment(t, f)
	f.now = f.now.Add(61 * time.Second)
	if reason, err := f.rotate(3, f.signers(next), nil); reason != RotationAccepted || err != nil {
		t.Fatalf("retry = %q, %v", reason, err)
	}
	if after, _ := activeEnrollment(t, f); after != before {
		t.Fatalf("retry changed the enrollment: %+v", after)
	}
	all, err := f.store.ListPrivacyEnrollments(context.Background(), f.now.Add(-time.Hour))
	if err != nil || len(all) != 2 {
		t.Fatalf("retry added an enrollment: %+v, %v", all, err)
	}
}

// item 7: a posture this session signs with the retired key after the swap
// is refused without quarantine.
func TestRotationRetiredKeyPostureIsNotQuarantined(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	f.age()
	if reason, err := f.rotate(2, f.signers(rotationKey(0x42)), nil); reason != RotationAccepted {
		t.Fatalf("rotation = %q, %v", reason, err)
	}
	err := f.posture(3)
	mustReject(t, err, privacyKeyRotationPendingReason)
	if quarantinedNow(t, f) {
		t.Fatal("retired-key posture quarantined the provider")
	}
}

func TestKeyRotationStatementIsClosed(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	f.age()
	nonce, _, _ := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now)
	raw := f.rotationMessage(nonce, 2, f.signers(rotationKey(0x42)), nil)
	var wire map[string]any
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	wire["extra"] = true
	extra, _ := json.Marshal(wire)
	if _, _, _, err := parsePrivacyRotation(extra); err == nil {
		t.Fatal("unknown field accepted")
	}
	if _, _, _, err := parsePrivacyRotation(bytes.Repeat([]byte(" "), MaxPrivacyKeyRotationBytes+1)); err == nil {
		t.Fatal("oversized message accepted")
	}
	if _, _, _, err := parsePrivacyRotation(raw); err != nil {
		t.Fatalf("valid message rejected: %v", err)
	}
	if !strings.Contains(string(raw), `"previous_identity_signature"`) {
		t.Fatal("wire field name drifted")
	}
}

func f256() elliptic.Curve { return elliptic.P256() }

// SPEC-049-R031 item 11: one rotation per provider per MinRotationInterval,
// checked inside the transaction; a refusal changes nothing.
func TestRotationTooSoonIsRefused(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	before, _ := activeEnrollment(t, f)
	reason, err := f.rotate(2, f.signers(rotationKey(0x42)), nil)
	if reason != RotationUnavailable || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
		t.Fatalf("rotation of a fresh enrollment = %q, %v", reason, err)
	}
	if after, _ := activeEnrollment(t, f); after != before {
		t.Fatalf("refusal changed the enrollment: %+v", after)
	}
	f.age()
	if reason, err := f.rotate(3, f.signers(rotationKey(0x42)), nil); reason != RotationAccepted {
		t.Fatalf("rotation after the interval = %q, %v", reason, err)
	}
	f.identity = rotationKey(0x42)
	f.now = f.now.Add(2 * time.Hour)
	if reason, _ := f.rotate(4, f.signers(rotationKey(0x43)), nil); reason != RotationUnavailable {
		t.Fatalf("second rotation inside the interval = %q", reason)
	}
}

// A posture verified after the rotation nonce was issued overtakes the
// rotation's posture: that is stale, not a sequence regression.
func TestRotationOvertakenByPostureIsStale(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	f.age()
	nonce, _, reason := f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now)
	if reason != "" {
		t.Fatal(reason)
	}
	rotation := f.rotationMessage(nonce, 2, f.signers(rotationKey(0x42)), nil)
	f.record = PrivacyKeyRecord{}
	f.useIdentity(f.identity, 0x51)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(5); err != nil {
		t.Fatalf("interleaved posture: %v", err)
	}
	got, err := f.auth.VerifyRotation(context.Background(), f.providerID, f.session, nonce, rotation, nil, f.now)
	if got != RotationStale || !errors.Is(err, ErrPrivacyRejected) || quarantinedNow(t, f) {
		t.Fatalf("overtaken rotation = %q, %v", got, err)
	}
	// At or below the sequence accepted when the nonce was issued is still
	// a regression and quarantines.
	f.now = f.now.Add(61 * time.Second)
	nonce, _, reason = f.auth.BeginRotationChallenge(context.Background(), f.providerID, f.session, f.now)
	if reason != "" {
		t.Fatal(reason)
	}
	got, err = f.auth.VerifyRotation(context.Background(), f.providerID, f.session, nonce, f.rotationMessage(nonce, 5, f.signers(rotationKey(0x42)), nil), nil, f.now)
	if got != RotationInvalid || !errors.Is(err, ErrPrivacyQuarantined) {
		t.Fatalf("regressed rotation = %q, %v", got, err)
	}
}

// The directory keeps at most four rotated identities per provider and never
// fails for a provider that rotated many times.
func TestDirectoryCapsRotatedEntries(t *testing.T) {
	f := enrolledRotationFixture(t, nil)
	for i := byte(0); i < 7; i++ {
		f.age()
		next := rotationKey(0x60 + i)
		if reason, err := f.rotate(uint64(10+2*int(i)), f.signers(next), nil); reason != RotationAccepted {
			t.Fatalf("rotation %d = %q, %v", i, reason, err)
		}
		f.identity = next
	}
	directory, err := f.auth.BuildIdentityDirectory(context.Background(), f.now, 300*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	revoked, active := 0, 0
	for _, entry := range directory.Entries {
		if entry.Revoked {
			revoked++
		} else {
			active++
		}
	}
	if active != 1 || revoked != maxRotatedDirectoryEntriesPerProvider {
		t.Fatalf("directory active=%d revoked=%d", active, revoked)
	}
}

// An identity key that another provider ever enrolled, even after that
// enrollment was revoked, is never enrolled for a second provider, and the
// directory keeps that fingerprint revoked.
func TestEnrollmentRefusesIdentityRevokedForAnotherProvider(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ReenrollPrivacyProvider(context.Background(), f.providerID, "operator", f.now, time.Minute); err != nil {
		t.Fatal(err)
	}
	f.providerID, f.session = "provider-b", "session-b"
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	mustReject(t, f.posture(1), "privacy_enrollment_key_in_use")
	if _, ok := activeEnrollment(t, f); ok {
		t.Fatal("a revoked identity enrolled a second provider")
	}
	// Even a row written around the store check never un-revokes it.
	if _, err := f.store.db.Exec(`INSERT INTO privacy_class_enrollment(provider_id,identity_public_key,identity_fingerprint,se_public_key,se_fingerprint,team_id,signing_identifier,code_cdhash,binary_version,enrolled_at_unix) SELECT 'provider-z',identity_public_key,identity_fingerprint,se_public_key,se_fingerprint,team_id,signing_identifier,code_cdhash,binary_version,enrolled_at_unix FROM privacy_class_enrollment WHERE provider_id='provider-a'`); err != nil {
		t.Fatal(err)
	}
	directory, err := f.auth.BuildIdentityDirectory(context.Background(), f.now, 300*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range directory.Entries {
		if entry.Fingerprint == PublicKeyFingerprint(f.identity.Public().(ed25519.PublicKey)) && !entry.Revoked {
			t.Fatal("another provider's row un-revoked the fingerprint")
		}
	}
}
