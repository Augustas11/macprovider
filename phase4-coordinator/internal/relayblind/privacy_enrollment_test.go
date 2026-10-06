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
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// newEnrollmentFixture is the SPEC-049-R025 fixture: no operator pins, so
// the provider can only be verified through its claim and then enrollment.
func newEnrollmentFixture(t *testing.T, mutate func(*config.PrivacyClassConfig)) *privacyFixture {
	t.Helper()
	var captured config.PrivacyClassConfig
	f := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.ProviderSEPublicKeys = map[string]string{}
		if mutate != nil {
			mutate(cfg)
		}
		captured = *cfg
	})
	auth, err := NewPrivacyAuthority(f.store, captured, nil, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	f.auth = auth
	return f
}

func (f *privacyFixture) claim() *PrivacyEnrollmentClaim {
	return &PrivacyEnrollmentClaim{
		Version:           PrivacyEnrollmentVersion,
		IdentityPublicKey: encodeBase64URL(f.identity.Public().(ed25519.PublicKey)),
		SEPublicKey:       base64.StdEncoding.EncodeToString(f.seRaw),
	}
}

func (f *privacyFixture) acceptClaim() error {
	return f.auth.AcceptPrivacyKeysWithClaim(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.record}, f.claim(), f.now)
}

func (f *privacyFixture) posture(seq uint64) error {
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		f.t.Fatal(err)
	}
	return f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, seq, issued)), nil, f.now)
}

// rekey replaces the fixture's identity, Secure Enclave key, and privacy key
// record with fresh material, as a reinstalled or substituted device would.
func (f *privacyFixture) rekey(seed byte) {
	f.t.Helper()
	identity := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, ed25519.SeedSize))
	agreement, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{seed ^ 0x5a}, 32))
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
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		f.t.Fatal(err)
	}
	seRaw := make([]byte, 64)
	se.X.FillBytes(seRaw[:32])
	se.Y.FillBytes(seRaw[32:])
	f.identity, f.se, f.seRaw = identity, se, seRaw
	f.record = PrivacyKeyRecord{KeyRecord: keyRecord, Attestation: attestation, Signature: signAttestation(f.t, identity, attestation)}
}

func activeEnrollment(t *testing.T, f *privacyFixture) (PrivacyEnrollment, bool) {
	t.Helper()
	enrollment, ok, err := f.store.ActivePrivacyEnrollment(context.Background(), f.providerID)
	if err != nil {
		t.Fatal(err)
	}
	return enrollment, ok
}

func TestEnrollmentOnFirstVerifiedPosture(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.record}, f.now); !errors.Is(err, ErrInvalidPin) {
		t.Fatalf("advertisement without pin, enrollment, or claim accepted: %v", err)
	}
	if err := f.acceptClaim(); err != nil {
		t.Fatalf("claim advertisement: %v", err)
	}
	if _, ok := activeEnrollment(t, f); ok {
		t.Fatal("a claim alone enrolled the provider")
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
		t.Fatal("claimed keys are eligible before a posture verifies")
	}
	if err := f.posture(0); err != nil {
		t.Fatalf("first posture: %v", err)
	}
	enrollment, ok := activeEnrollment(t, f)
	if !ok {
		t.Fatal("verified posture did not enroll the provider")
	}
	if enrollment.IdentityPublicKey != f.claim().IdentityPublicKey || enrollment.SEPublicKey != f.claim().SEPublicKey ||
		enrollment.CodeCDHash != fixtureCDHash || enrollment.TeamID != fixtureTeamID || enrollment.BinaryVersion != fixtureBinary ||
		enrollment.EnrolledAtUnix != f.now.Unix() || enrollment.IdentityFingerprint != PublicKeyFingerprint(f.identity.Public().(ed25519.PublicKey)) {
		t.Fatalf("enrollment row = %+v", enrollment)
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		t.Fatal("enrolled provider is not eligible")
	}
}

func TestEnrollmentIsDurableAndBecomesThePin(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	// Restart: a new authority over the same store holds no session state.
	restarted, err := NewPrivacyAuthority(f.store, config.PrivacyClassConfig{
		Enabled: true, ApprovedCodeIdentities: []config.ApprovedCodeIdentity{approvedIdentity(fixtureCDHash, f.now.Add(24*time.Hour))},
		AllowedSEKeyBackends: []string{PrivacySEBackendFile}, PostureChallengeIntervalSeconds: 60, PostureMaxAgeSeconds: 150,
		PostureResponseTimeoutSeconds: 10, QuarantineSeconds: 86400,
	}, nil, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	f.auth = restarted
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
		t.Fatal("eligibility survived a restart")
	}
	// Without any claim the enrollment alone verifies records and posture.
	f.accept()
	if err := f.posture(0); err != nil {
		t.Fatalf("posture against the enrollment: %v", err)
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		t.Fatal("enrolled provider is not eligible after restart")
	}
}

func TestEnrollmentKeyChangeQuarantinesWithoutReplacing(t *testing.T) {
	for _, change := range []string{"identity_and_se", "se_only"} {
		t.Run(change, func(t *testing.T) {
			f := newEnrollmentFixture(t, nil)
			if err := f.acceptClaim(); err != nil {
				t.Fatal(err)
			}
			if err := f.posture(0); err != nil {
				t.Fatal(err)
			}
			original, _ := activeEnrollment(t, f)
			if change == "identity_and_se" {
				f.rekey(0x61)
			} else {
				se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				f.se = se
				f.seRaw = make([]byte, 64)
				se.X.FillBytes(f.seRaw[:32])
				se.Y.FillBytes(f.seRaw[32:])
			}
			mustQuarantine(t, f.acceptClaim(), "privacy_enrollment_key_changed")
			if q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now); err != nil || !q {
				t.Fatalf("quarantined = %v, %v", q, err)
			}
			after, ok := activeEnrollment(t, f)
			if !ok || after != original {
				t.Fatalf("key change replaced the enrollment: %+v", after)
			}
			// After the quarantine expires the same different key quarantines again.
			f.now = f.now.Add(86401 * time.Second)
			if change == "se_only" {
				mustQuarantine(t, f.acceptClaim(), "privacy_enrollment_key_changed")
			} else {
				f.rekey(0x61)
				mustQuarantine(t, f.acceptClaim(), "privacy_enrollment_key_changed")
			}
		})
	}
}

func TestEnrollmentPostureKeyChangeQuarantines(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	// A posture signed by a different Secure Enclave key fails against the
	// enrolled key and quarantines; the enrollment is unchanged.
	original, _ := activeEnrollment(t, f)
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f.se = se
	mustQuarantine(t, f.posture(1), "posture_signature_failure")
	if after, _ := activeEnrollment(t, f); after != original {
		t.Fatalf("posture key change replaced the enrollment")
	}
}

func TestEnrollmentNotCreatedWhenPostureFails(t *testing.T) {
	t.Run("unapproved identity", func(t *testing.T) {
		f := newEnrollmentFixture(t, nil)
		if err := f.acceptClaim(); err != nil {
			t.Fatal(err)
		}
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		statement := f.statement(nonce, 0, issued)
		statement.BinaryVersion = "9.9.9"
		mustReject(t, f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now), "posture_unapproved_code_identity")
		if _, ok := activeEnrollment(t, f); ok {
			t.Fatal("unapproved posture enrolled")
		}
	})
	t.Run("required value", func(t *testing.T) {
		f := newEnrollmentFixture(t, nil)
		if err := f.acceptClaim(); err != nil {
			t.Fatal(err)
		}
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		statement := f.statement(nonce, 0, issued)
		statement.SIPEnabled = false
		mustQuarantine(t, f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now), "posture_required_value")
		if _, ok := activeEnrollment(t, f); ok {
			t.Fatal("failed posture enrolled")
		}
	})
	t.Run("session secure enclave mismatch", func(t *testing.T) {
		f := newEnrollmentFixture(t, nil)
		if err := f.acceptClaim(); err != nil {
			t.Fatal(err)
		}
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		other := bytes.Repeat([]byte{0x01}, 64)
		mustQuarantine(t, f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 0, issued)), other, f.now), "posture_se_key_mismatch")
		if _, ok := activeEnrollment(t, f); ok {
			t.Fatal("SPEC-008 mismatch enrolled")
		}
	})
	t.Run("kill switch", func(t *testing.T) {
		f := newEnrollmentFixture(t, nil)
		if err := f.acceptClaim(); err != nil {
			t.Fatal(err)
		}
		if err := f.store.SetPrivacyDisabled(context.Background(), true, "test", f.now); err != nil {
			t.Fatal(err)
		}
		mustReject(t, f.posture(0), "privacy_class_disabled")
		if _, ok := activeEnrollment(t, f); ok {
			t.Fatal("kill switch did not block enrollment")
		}
	})
}

// Before enrollment a session cannot swap its claim: the records verified
// under the first claim are revoked and the new claim is refused, so no
// posture can enroll one identity beside records signed by another.
func TestUnenrolledSessionClaimChangeRevokes(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	firstDigest := f.record.KeyRecord.KeyRecordDigest
	f.rekey(0x63)
	mustReject(t, f.acceptClaim(), "privacy_enrollment_claim_changed")
	fresh, err := f.store.PrivacyKeyFresh(context.Background(), f.providerID, f.session, firstDigest, f.now)
	if err != nil || fresh {
		t.Fatalf("first-claim key fresh = %v, %v", fresh, err)
	}
	if q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now); err != nil || q {
		t.Fatalf("unenrolled claim change quarantined = %v, %v", q, err)
	}
	// The forgotten advertisement lets the session start over cleanly.
	if err := f.acceptClaim(); err != nil {
		t.Fatalf("re-advertisement after reset: %v", err)
	}
	if err := f.posture(0); err != nil {
		t.Fatalf("posture after reset: %v", err)
	}
	enrollment, ok := activeEnrollment(t, f)
	if !ok || enrollment.IdentityPublicKey != f.claim().IdentityPublicKey {
		t.Fatalf("enrollment = %+v %v", enrollment, ok)
	}
}

func TestEnrollmentRejectsKeyActiveForAnotherProvider(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	f.providerID, f.session = "provider-b", "session-b"
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	mustReject(t, f.posture(0), "privacy_enrollment_key_in_use")
	if _, ok := activeEnrollment(t, f); ok {
		t.Fatal("shared keys enrolled a second provider")
	}
	if q, err := f.store.IsQuarantined(context.Background(), "provider-b", f.now); err != nil || q {
		t.Fatalf("key in use quarantined = %v, %v", q, err)
	}
}

func TestReenrollAllowsNewKeys(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	original, _ := activeEnrollment(t, f)
	f.rekey(0x62)
	mustQuarantine(t, f.acceptClaim(), "privacy_enrollment_key_changed")
	changed, err := f.store.ReenrollPrivacyProvider(context.Background(), f.providerID, "operator verified device swap", f.now, 5*time.Minute)
	if err != nil || !changed {
		t.Fatalf("reenroll = %v, %v", changed, err)
	}
	if q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now); err != nil || q {
		t.Fatalf("reenroll left quarantine = %v, %v", q, err)
	}
	f.session = "session-a2"
	if err := f.acceptClaim(); err != nil {
		t.Fatalf("new keys after reenroll: %v", err)
	}
	if err := f.posture(0); err != nil {
		t.Fatalf("posture after reenroll: %v", err)
	}
	enrollment, ok := activeEnrollment(t, f)
	if !ok || enrollment.IdentityPublicKey == original.IdentityPublicKey {
		t.Fatalf("reenroll did not enroll the new keys: %+v", enrollment)
	}
	listed, err := f.store.ListPrivacyEnrollments(context.Background(), f.now.Add(-EnrollmentRevocationRetention))
	if err != nil || len(listed) != 2 {
		t.Fatalf("enrollments = %d, %v", len(listed), err)
	}
}

func TestOperatorPinsOverrideEnrollment(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	// Configured pins: a claim naming other keys is ignored, never enrolled,
	// and never quarantines; the pins keep verifying.
	other := f.claim()
	other.SEPublicKey = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x02}, 64))
	if err := f.auth.AcceptPrivacyKeysWithClaim(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.record}, other, f.now); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	if _, ok := activeEnrollment(t, f); ok {
		t.Fatal("a fully pinned provider was enrolled")
	}
}

func writeSignedReleaseMetadata(t *testing.T, dir, name string, key *ecdsa.PrivateKey, identity map[string]any) {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"schema_version":         1,
		"release_lane":           "pearl_runtime_catalog",
		"tag":                    "v" + identity["binary_version"].(string),
		"provider_code_identity": identity,
	})
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(payload)
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".json"), payload, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".json.sig"), signature, 0o644); err != nil {
		t.Fatal(err)
	}
}

func releaseIdentityObject(version, cdhash string) map[string]any {
	return map[string]any{
		"asset":              "macprovider-cli-v" + version + "-darwin-arm64.tar.gz",
		"member":             "macprovider-cli",
		"binary_version":     version,
		"binary_sha256":      strings.Repeat("a", 64),
		"team_id":            fixtureTeamID,
		"signing_identifier": "live.malibu.provider.cli",
		"slices":             []any{map[string]any{"arch": "arm64", "code_cdhash": cdhash}},
	}
}

func releaseSigningKey(t *testing.T) (*ecdsa.PrivateKey, *ecdsa.PublicKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := ParseReleaseSigningPublicKey(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	if err != nil {
		t.Fatal(err)
	}
	return key, parsed
}

func TestLoadReleaseCodeIdentities(t *testing.T) {
	dir := t.TempDir()
	key, public := releaseSigningKey(t)
	other, _ := releaseSigningKey(t)
	writeSignedReleaseMetadata(t, dir, "v1.8.220", key, releaseIdentityObject("1.8.220", fixtureCDHash))
	writeSignedReleaseMetadata(t, dir, "v1.8.221-dup", key, releaseIdentityObject("1.8.220", fixtureCDHash))
	writeSignedReleaseMetadata(t, dir, "v1.8.222-wrong-key", other, releaseIdentityObject("1.8.222", secondFixtureCDHash))
	badIdentifier := releaseIdentityObject("1.8.223", secondFixtureCDHash)
	badIdentifier["signing_identifier"] = "com.example.other"
	writeSignedReleaseMetadata(t, dir, "v1.8.223-identifier", key, badIdentifier)
	twoSlices := releaseIdentityObject("1.8.224", secondFixtureCDHash)
	twoSlices["slices"] = []any{map[string]any{"arch": "arm64", "code_cdhash": secondFixtureCDHash}, map[string]any{"arch": "x86_64", "code_cdhash": secondFixtureCDHash}}
	writeSignedReleaseMetadata(t, dir, "v1.8.224-slices", key, twoSlices)
	extraField := releaseIdentityObject("1.8.225", secondFixtureCDHash)
	extraField["note"] = "x"
	writeSignedReleaseMetadata(t, dir, "v1.8.225-extra", key, extraField)
	if err := os.WriteFile(filepath.Join(dir, "v1.8.226-unsigned.json"), []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "v1.8.220.json"), filepath.Join(dir, "v1.8.227-link.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "v1.8.220.json.sig"), filepath.Join(dir, "v1.8.227-link.json.sig")); err != nil {
		t.Fatal(err)
	}
	identities, rejected, err := LoadReleaseCodeIdentities(dir, public)
	if err != nil {
		t.Fatal(err)
	}
	if len(identities) != 1 || identities[0].CDHash != fixtureCDHash || identities[0].BinaryVersion != "1.8.220" || identities[0].TeamID != fixtureTeamID || !identities[0].ExpiresAt.IsZero() {
		t.Fatalf("identities = %+v", identities)
	}
	if len(rejected) != 6 {
		t.Fatalf("rejected = %v", rejected)
	}
	if _, _, err := LoadReleaseCodeIdentities(filepath.Join(dir, "missing"), public); err == nil {
		t.Fatal("missing directory loaded")
	}
}

func TestReleaseDerivedApprovalAndOverrides(t *testing.T) {
	dir := t.TempDir()
	key, public := releaseSigningKey(t)
	writeSignedReleaseMetadata(t, dir, "v-fixture", key, releaseIdentityObject("1.8.230", fixtureCDHash))

	setup := func(t *testing.T, mutate func(*config.PrivacyClassConfig)) *privacyFixture {
		f := newEnrollmentFixture(t, func(cfg *config.PrivacyClassConfig) {
			cfg.ApprovedCodeIdentities = nil
			if mutate != nil {
				mutate(cfg)
			}
		})
		f.auth.ConfigureReleaseIdentities(dir, public)
		f.record.Attestation.BinaryVersion = "1.8.230"
		f.record.Signature = signAttestation(t, f.identity, f.record.Attestation)
		return f
	}
	postureAt := func(f *privacyFixture, version string) error {
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		statement := f.statement(nonce, 0, issued)
		statement.BinaryVersion = version
		return f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	}

	t.Run("signed release approves without config", func(t *testing.T) {
		f := setup(t, nil)
		if err := f.acceptClaim(); err != nil {
			t.Fatal(err)
		}
		if err := postureAt(f, "1.8.230"); err != nil {
			t.Fatalf("release-derived posture: %v", err)
		}
		if _, ok := activeEnrollment(t, f); !ok {
			t.Fatal("release-derived posture did not enroll")
		}
	})
	t.Run("binary version must match the release", func(t *testing.T) {
		f := setup(t, nil)
		if err := f.acceptClaim(); err != nil {
			t.Fatal(err)
		}
		mustReject(t, postureAt(f, "1.8.231"), "posture_unapproved_code_identity")
	})
	t.Run("expired config entry withdraws approval", func(t *testing.T) {
		f := setup(t, func(cfg *config.PrivacyClassConfig) {
			cfg.ApprovedCodeIdentities = []config.ApprovedCodeIdentity{approvedIdentity(fixtureCDHash, time.Unix(1_700_000_000, 0))}
		})
		mustReject(t, f.acceptClaim(), "posture_unapproved_code_identity")
	})
	t.Run("deny list wins", func(t *testing.T) {
		f := setup(t, func(cfg *config.PrivacyClassConfig) {
			cfg.DeniedCodeCDHashes = []string{fixtureCDHash}
		})
		mustQuarantine(t, f.acceptClaim(), "posture_denied_code_identity")
	})
	t.Run("unreadable directory fails closed", func(t *testing.T) {
		f := setup(t, nil)
		f.auth.ConfigureReleaseIdentities(filepath.Join(dir, "missing"), public)
		mustReject(t, f.acceptClaim(), "posture_unapproved_code_identity")
	})
}

func TestIdentityDirectoryBuildPublishesEnrollmentAndRevocation(t *testing.T) {
	f := newEnrollmentFixture(t, nil)
	if err := f.acceptClaim(); err != nil {
		t.Fatal(err)
	}
	if err := f.posture(0); err != nil {
		t.Fatal(err)
	}
	signer := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x77}, ed25519.SeedSize))
	service, err := NewIdentityDirectoryService(f.auth, signer, 300*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := PublicKeyFingerprint(f.identity.Public().(ed25519.PublicKey))
	read := func(now time.Time) IdentityDirectory {
		raw, err := service.Envelope(context.Background(), now)
		if err != nil {
			t.Fatal(err)
		}
		directory, err := VerifyIdentityDirectory(raw, signer.Public().(ed25519.PublicKey), now)
		if err != nil {
			t.Fatal(err)
		}
		return directory
	}
	directory := read(f.now)
	entry, ok := directory.Lookup(fingerprint)
	if !ok || entry.Revoked || entry.Source != IdentityDirectorySourceEnrolled || entry.SEPublicKeyFingerprint != PublicKeyFingerprint(f.seRaw) {
		t.Fatalf("enrolled entry = %+v %v", entry, ok)
	}
	pin, err := directory.PinForRecord(f.record.KeyRecord, "model-a")
	if err != nil {
		t.Fatal(err)
	}
	if err := pin.VerifyRecord(f.record.KeyRecord, f.now); err != nil {
		t.Fatalf("directory pin rejects the enrolled record: %v", err)
	}

	if err := f.store.Quarantine(context.Background(), f.providerID, "test", f.now, time.Hour); err != nil {
		t.Fatal(err)
	}
	// The cached envelope is reused for at most 15 seconds.
	if cached := read(f.now.Add(5 * time.Second)); cached.IssuedAtUnix != directory.IssuedAtUnix {
		t.Fatal("cache window not honored")
	}
	later := f.now.Add(20 * time.Second)
	if entry, _ := read(later).Lookup(fingerprint); !entry.Revoked {
		t.Fatal("quarantined provider not published as revoked")
	}
	if _, err := f.store.ReenrollPrivacyProvider(context.Background(), f.providerID, "reenroll", later, time.Minute); err != nil {
		t.Fatal(err)
	}
	afterReenroll := f.now.Add(40 * time.Second)
	if entry, ok := read(afterReenroll).Lookup(fingerprint); !ok || !entry.Revoked {
		t.Fatalf("revoked enrollment not retained as revoked: %+v %v", entry, ok)
	}
	expired := later.Add(EnrollmentRevocationRetention + time.Minute)
	if _, ok := read(expired).Lookup(fingerprint); ok {
		t.Fatal("revoked enrollment published past retention")
	}
}

func TestIdentityDirectoryIncludesOperatorPins(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	directory, err := f.auth.BuildIdentityDirectory(context.Background(), f.now, 300*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	entry, ok := directory.Lookup(PublicKeyFingerprint(f.identity.Public().(ed25519.PublicKey)))
	if !ok || entry.Source != IdentityDirectorySourceOperatorPin || entry.Revoked {
		t.Fatalf("operator pin entry = %+v %v", entry, ok)
	}
}

func TestIdentityDirectorySigningKeyCustody(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "directory.key")
	public, err := GenerateIdentityDirectorySigningKey(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := GenerateIdentityDirectorySigningKey(path); err == nil {
		t.Fatal("keygen overwrote an existing key")
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("key mode = %v, %v", info.Mode(), err)
	}
	loaded, err := LoadIdentityDirectorySigningKey(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(loaded.Public().(ed25519.PublicKey), public) {
		t.Fatal("loaded key does not match generated public key")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadIdentityDirectorySigningKey(path); err == nil {
		t.Fatal("world-readable key loaded")
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadIdentityDirectorySigningKey(path); err != nil {
		t.Fatalf("0400 key rejected: %v", err)
	}
	link := filepath.Join(dir, "link.key")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadIdentityDirectorySigningKey(link); err == nil {
		t.Fatal("symlinked key loaded")
	}
	garbage := filepath.Join(dir, "garbage.key")
	if err := os.WriteFile(garbage, []byte("not-a-key\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadIdentityDirectorySigningKey(garbage); err == nil || strings.Contains(err.Error(), "not-a-key") {
		t.Fatalf("garbage key error = %v", err)
	}
}
