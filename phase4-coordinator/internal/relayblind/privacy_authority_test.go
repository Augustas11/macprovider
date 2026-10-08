package relayblind

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

const secondFixtureCDHash = "abcdef0123456789abcdef0123456789abcdef01"

func TestPostureAcceptsValid(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	f.accept()
	f.verify(0, nil)
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		t.Fatal("accepted posture is not eligible")
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, "not-a-digest", f.now); ok {
		t.Fatal("unknown digest is eligible")
	}
	f.verify(1, nil)
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		t.Fatal("sequence 1 dropped eligibility")
	}
}

func TestPostureRejectsWrongNonceStaleSkewSeqRegression(t *testing.T) {
	t.Run("wrong nonce", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		other := base64.RawURLEncoding.EncodeToString(bytesRepeat(0x11, 32))
		if other == nonce {
			other = base64.RawURLEncoding.EncodeToString(bytesRepeat(0x22, 32))
		}
		err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(other, 0, issued)), nil, f.now)
		mustReject(t, err, "posture_nonce_mismatch")
		if q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now); err != nil || q {
			t.Fatalf("quarantined = %v, %v", q, err)
		}
		if err := f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 0, issued)), nil, f.now); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("stale", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		f.verify(0, nil)
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		late := f.now.Add(11 * time.Second)
		err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 1, issued)), nil, late)
		mustReject(t, err, "posture_timeout")
		if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, late); ok {
			t.Fatal("stale challenge left the session eligible")
		}
		if q, err := f.store.IsQuarantined(context.Background(), f.providerID, late); err != nil || q {
			t.Fatalf("quarantined = %v, %v", q, err)
		}
	})
	t.Run("skew", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		f.verify(0, nil)
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 1, issued+31)), nil, f.now)
		mustReject(t, err, "posture_clock_skew")
		if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
			t.Fatal("a skewed re-check left the earlier posture eligible")
		}
		if q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now); err != nil || q {
			t.Fatalf("quarantined = %v, %v", q, err)
		}
	})
	t.Run("sequence regression", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		f.verify(1, nil)
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 1, issued)), nil, f.now)
		mustQuarantine(t, err, "posture_sequence_regression")
		if q, qerr := f.store.IsQuarantined(context.Background(), f.providerID, f.now); qerr != nil || !q {
			t.Fatalf("quarantined = %v, %v", q, qerr)
		}
	})
}

// SPEC-049-R006 v0.2: an identity that is merely not approved (here a binary
// version the configured entry does not name) is refused without quarantine.
func TestPostureUnapprovedIdentityIneligibleWithoutQuarantine(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	f.accept()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 0, issued)
	statement.BinaryVersion = "9.9.9"
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	mustReject(t, err, "posture_unapproved_code_identity")
	if q, qerr := f.store.IsQuarantined(context.Background(), f.providerID, f.now); qerr != nil || q {
		t.Fatalf("quarantined = %v, %v", q, qerr)
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
		t.Fatal("unapproved identity is eligible")
	}
	fresh, err := f.store.PrivacyKeyFresh(context.Background(), f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now)
	if err != nil || !fresh {
		t.Fatalf("privacy key fresh = %v, %v; an unapproved identity must not revoke keys", fresh, err)
	}
	f.verify(1, nil)
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		t.Fatal("approved posture after an unapproved one is not eligible")
	}
}

// A denied cdhash quarantines and revokes, even before it is compared with
// the attested cdhash.
func TestPostureDeniedCDHashQuarantinesAndRevokes(t *testing.T) {
	f := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.DeniedCodeCDHashes = []string{secondFixtureCDHash}
	})
	f.accept()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 0, issued)
	statement.CodeCDHash = secondFixtureCDHash
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	mustQuarantine(t, err, "posture_denied_code_identity")
	if q, qerr := f.store.IsQuarantined(context.Background(), f.providerID, f.now); qerr != nil || !q {
		t.Fatalf("quarantined = %v, %v", q, qerr)
	}
	fresh, err := f.store.PrivacyKeyFresh(context.Background(), f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now)
	if err != nil || fresh {
		t.Fatalf("privacy key fresh = %v, %v", fresh, err)
	}
}

func TestPostureAttestationDeniedQuarantinesUnapprovedRejects(t *testing.T) {
	denied := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.DeniedCodeCDHashes = []string{fixtureCDHash}
	})
	err := denied.auth.AcceptPrivacyKeys(context.Background(), denied.providerID, denied.session, []PrivacyKeyRecord{denied.record}, denied.now)
	mustQuarantine(t, err, "posture_denied_code_identity")

	unapproved := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.ApprovedCodeIdentities = []config.ApprovedCodeIdentity{approvedIdentity(secondFixtureCDHash, time.Unix(1_800_000_000, 0).Add(time.Hour))}
	})
	err = unapproved.auth.AcceptPrivacyKeys(context.Background(), unapproved.providerID, unapproved.session, []PrivacyKeyRecord{unapproved.record}, unapproved.now)
	mustReject(t, err, "posture_unapproved_code_identity")
	if q, qerr := unapproved.store.IsQuarantined(context.Background(), unapproved.providerID, unapproved.now); qerr != nil || q {
		t.Fatalf("quarantined = %v, %v", q, qerr)
	}
}

func TestPostureEachRequiredFlagFalseQuarantines(t *testing.T) {
	flags := []struct {
		name string
		set  func(*PostureStatement)
	}{
		{"hardened_runtime", func(s *PostureStatement) { s.HardenedRuntime = false }},
		{"library_validation", func(s *PostureStatement) { s.LibraryValidation = false }},
		{"pt_deny_attach_applied", func(s *PostureStatement) { s.PTDenyAttachApplied = false }},
		{"core_dumps_disabled", func(s *PostureStatement) { s.CoreDumpsDisabled = false }},
		{"sip_enabled", func(s *PostureStatement) { s.SIPEnabled = false }},
		{"diagnostic_env_clear", func(s *PostureStatement) { s.DiagnosticEnvClear = false }},
		{"kv_disk_tier_disabled", func(s *PostureStatement) { s.KVDiskTierDisabled = false }},
		{"get_task_allow", func(s *PostureStatement) { s.GetTaskAllow = true }},
		{"cs_debugged", func(s *PostureStatement) { s.CSDebugged = true }},
		{"p_traced", func(s *PostureStatement) { s.PTraced = true }},
	}
	for _, flag := range flags {
		t.Run(flag.name, func(t *testing.T) {
			f := newPrivacyFixture(t, nil)
			f.accept()
			nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
			if err != nil {
				t.Fatal(err)
			}
			statement := f.statement(nonce, 0, issued)
			flag.set(&statement)
			err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
			mustQuarantine(t, err, "posture_required_value")
		})
	}
}

func TestPostureSessionSEKeyMismatchRejected(t *testing.T) {
	t.Run("different key", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		other := bytesRepeat(0x03, 64)
		if subtleEqual(other, f.seRaw) {
			other[0] ^= 0xff
		}
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 0, issued)), other, f.now)
		mustQuarantine(t, err, "posture_se_key_mismatch")
	})
	t.Run("truncated key", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		if err != nil {
			t.Fatal(err)
		}
		err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 0, issued)), []byte{1, 2, 3}, f.now)
		mustQuarantine(t, err, "posture_se_key_mismatch")
	})
}

func TestPostureSignatureFailureQuarantines(t *testing.T) {
	t.Run("se", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		raw := f.signedResponse(0, func(w *privacyPostureWire) {
			w.SESignature = base64.RawURLEncoding.EncodeToString(bytesRepeat(0x04, 70))
		})
		err := f.auth.VerifyPosture(context.Background(), f.providerID, f.session, f.pendingNonce, raw, nil, f.now)
		mustQuarantine(t, err, "posture_signature_failure")
	})
	t.Run("identity", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		raw := f.signedResponse(0, func(w *privacyPostureWire) {
			w.IdentitySignature = base64.RawURLEncoding.EncodeToString(bytesRepeat(0x05, ed25519.SignatureSize))
		})
		err := f.auth.VerifyPosture(context.Background(), f.providerID, f.session, f.pendingNonce, raw, nil, f.now)
		mustQuarantine(t, err, "posture_signature_failure")
	})
	t.Run("bad attestation does not quarantine", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		bad := f.record
		bad.Signature = base64.RawURLEncoding.EncodeToString(bytesRepeat(0x06, ed25519.SignatureSize))
		err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{bad}, f.now)
		if err == nil || errors.Is(err, ErrPrivacyQuarantined) {
			t.Fatalf("accept = %v", err)
		}
		if q, qerr := f.store.IsQuarantined(context.Background(), f.providerID, f.now); qerr != nil || q {
			t.Fatalf("quarantined = %v, %v", q, qerr)
		}
	})
}

func TestPostureCDHashChangeQuarantines(t *testing.T) {
	f := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.ApprovedCodeIdentities = append(cfg.ApprovedCodeIdentities, approvedIdentity(secondFixtureCDHash, time.Unix(1_800_000_000, 0).UTC().Add(24*time.Hour)))
	})
	f.accept()
	f.verify(0, nil)
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 1, issued)
	statement.CodeCDHash = secondFixtureCDHash
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	mustQuarantine(t, err, "posture_cdhash_changed")
}

func TestPostureAttestationCDHashMismatchQuarantines(t *testing.T) {
	f := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.ApprovedCodeIdentities = append(cfg.ApprovedCodeIdentities, approvedIdentity(secondFixtureCDHash, time.Unix(1_800_000_000, 0).UTC().Add(24*time.Hour)))
	})
	f.accept()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 0, issued)
	statement.CodeCDHash = secondFixtureCDHash
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	mustQuarantine(t, err, "posture_attestation_cdhash_mismatch")
}

func TestPostureDisallowedBackendDoesNotQuarantine(t *testing.T) {
	f := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.AllowedSEKeyBackends = []string{"file"}
	})
	f.accept()
	f.verify(0, nil)
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 1, issued)
	statement.SEKeyBackend = PrivacySEBackendKeychain
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now)
	mustReject(t, err, "posture_key_backend")
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
		t.Fatal("a disallowed backend left the earlier posture eligible")
	}
	if q, qerr := f.store.IsQuarantined(context.Background(), f.providerID, f.now); qerr != nil || q {
		t.Fatalf("quarantined = %v, %v", q, qerr)
	}
}

func TestPostureDropSessionRejectsInFlight(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	f.accept()
	f.verify(0, nil)
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	f.auth.DropSession(f.providerID, f.session)
	err = f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 1, issued)), nil, f.now)
	mustReject(t, err, "posture_nonce_mismatch")
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
		t.Fatal("dropped session stayed eligible")
	}
	if q, qerr := f.store.IsQuarantined(context.Background(), f.providerID, f.now); qerr != nil || q {
		t.Fatalf("quarantined = %v, %v", q, qerr)
	}
}

func TestEligibilityExpiresAfterMaxAge(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	f.accept()
	f.verify(0, nil)
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now.Add(150*time.Second)); !ok {
		t.Fatal("eligibility ended before max age")
	}
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now.Add(151*time.Second)); ok {
		t.Fatal("eligibility survived past max age")
	}
	if q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now.Add(151*time.Second)); err != nil || q {
		t.Fatalf("quarantined = %v, %v", q, err)
	}
}

func TestKillSwitchStoreErrorFailsClosed(t *testing.T) {
	t.Run("kill switch", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		f.verify(0, nil)
		if err := f.store.SetPrivacyDisabled(context.Background(), true, "incident", f.now); err != nil {
			t.Fatal(err)
		}
		if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
			t.Fatal("kill switch left the session eligible")
		}
	})
	t.Run("closed store", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		f.verify(0, nil)
		if err := f.store.Close(); err != nil {
			t.Fatal(err)
		}
		if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); ok {
			t.Fatal("closed store left the session eligible")
		}
	})
}

type privacyFixture struct {
	t          *testing.T
	store      *Store
	auth       *PrivacyAuthority
	now        time.Time
	providerID string
	session    string
	record     PrivacyKeyRecord
	identity   ed25519.PrivateKey
	se         *ecdsa.PrivateKey
	seRaw      []byte

	pendingNonce string
}

func newPrivacyFixture(t *testing.T, mutate func(*config.PrivacyClassConfig)) *privacyFixture {
	t.Helper()
	now := time.Unix(1_800_000_000, 0).UTC()
	keyRecord, _, identity := testPrivacyMaterial(t, now)
	attestation := PrivacyKeyAttestation{
		Version: PrivacyKeyAttestationVersion, KeyRecordDigest: keyRecord.KeyRecordDigest,
		PrivacyClass: PrivacyClassV1, Assurance: PrivacyAssurance, BinaryVersion: fixtureBinary,
		CodeCDHash: fixtureCDHash, NotBeforeUnix: keyRecord.NotBeforeUnix, ExpiresAtUnix: keyRecord.ExpiresAtUnix,
	}
	record := PrivacyKeyRecord{KeyRecord: keyRecord, Attestation: attestation, Signature: signAttestation(t, identity, attestation)}
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	seRaw := make([]byte, 64)
	se.X.FillBytes(seRaw[:32])
	se.Y.FillBytes(seRaw[32:])
	cfg := config.PrivacyClassConfig{
		Enabled:                         true,
		ProviderSEPublicKeys:            map[string]string{"provider-a": base64.StdEncoding.EncodeToString(seRaw)},
		ApprovedCodeIdentities:          []config.ApprovedCodeIdentity{approvedIdentity(fixtureCDHash, now.Add(24*time.Hour))},
		AllowedSEKeyBackends:            []string{PrivacySEBackendFile, PrivacySEBackendKeychain},
		PostureChallengeIntervalSeconds: 60,
		PostureMaxAgeSeconds:            150,
		PostureResponseTimeoutSeconds:   10,
		QuarantineSeconds:               86400,
	}
	if mutate != nil {
		mutate(&cfg)
	}
	store, err := OpenStore(filepath.Join(t.TempDir(), "privacy.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	public := identity.Public().(ed25519.PublicKey)
	auth, err := NewPrivacyAuthority(store, cfg, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(public)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	return &privacyFixture{
		t: t, store: store, auth: auth, now: now, providerID: "provider-a", session: "session-a",
		record: record, identity: identity, se: se, seRaw: seRaw,
	}
}

func approvedIdentity(cdhash string, expiry time.Time) config.ApprovedCodeIdentity {
	return config.ApprovedCodeIdentity{
		TeamID: fixtureTeamID, SigningIdentifier: "live.malibu.provider.cli", CDHash: cdhash,
		BinaryVersion: fixtureBinary, ExpiresAt: expiry,
	}
}

func (f *privacyFixture) accept() {
	f.t.Helper()
	if err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.record}, f.now); err != nil {
		f.t.Fatal(err)
	}
}

func (f *privacyFixture) verify(seq uint64, sessionSE []byte) {
	f.t.Helper()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		f.t.Fatal(err)
	}
	if err := f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, seq, issued)), sessionSE, f.now); err != nil {
		f.t.Fatal(err)
	}
}

func (f *privacyFixture) statement(nonce string, seq uint64, issued int64) PostureStatement {
	statement := testPosture(f.record.KeyRecord.KeyRecordDigest)
	statement.ProviderID = f.providerID
	statement.AssignedSession = f.session
	statement.Nonce = nonce
	statement.Sequence = seq
	statement.IssuedAtUnix = issued
	return statement
}

func (f *privacyFixture) response(statement PostureStatement) []byte {
	f.t.Helper()
	return f.wire(statement, nil)
}

func (f *privacyFixture) signedResponse(seq uint64, mutate func(*privacyPostureWire)) []byte {
	f.t.Helper()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		f.t.Fatal(err)
	}
	f.pendingNonce = nonce
	return f.wire(f.statement(nonce, seq, issued), mutate)
}

func (f *privacyFixture) wire(statement PostureStatement, mutate func(*privacyPostureWire)) []byte {
	f.t.Helper()
	rawStatement, err := json.Marshal(statement)
	if err != nil {
		f.t.Fatal(err)
	}
	framing, err := statement.Framing()
	if err != nil {
		f.t.Fatal(err)
	}
	digest := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, f.se, digest[:])
	if err != nil {
		f.t.Fatal(err)
	}
	wire := privacyPostureWire{
		Type: privacyPostureResponseType, Version: 1, Statement: rawStatement,
		SESignature:       base64.RawURLEncoding.EncodeToString(seSig),
		IdentitySignature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(f.identity, framing)),
	}
	if mutate != nil {
		mutate(&wire)
	}
	raw, err := json.Marshal(wire)
	if err != nil {
		f.t.Fatal(err)
	}
	return raw
}

func mustQuarantine(t *testing.T, err error, reason string) {
	t.Helper()
	if !errors.Is(err, ErrPrivacyQuarantined) || !strings.Contains(err.Error(), reason) {
		t.Fatalf("err = %v, want quarantine %s", err, reason)
	}
}

func mustReject(t *testing.T, err error, reason string) {
	t.Helper()
	if !errors.Is(err, ErrPrivacyRejected) || !strings.Contains(err.Error(), reason) {
		t.Fatalf("err = %v, want reject %s", err, reason)
	}
}

func bytesRepeat(b byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func subtleEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
