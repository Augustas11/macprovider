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
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

type codeBoundFixture struct {
	*privacyFixture
	apple    *appattesttest.Fixture
	key      *ecdsa.PrivateKey
	keyID    []byte
	counter  uint32
	cbRecord PrivacyKeyRecord

	mu       sync.Mutex
	notified []string
}

func newCodeBoundFixture(t *testing.T, mutate func(*config.PrivacyClassConfig)) *codeBoundFixture {
	t.Helper()
	base := newPrivacyFixture(t, func(cfg *config.PrivacyClassConfig) {
		cfg.CodeBound = config.PrivacyCodeBoundConfig{Enabled: true, TeamID: fixtureTeamID, MaxEnrollmentsPerProviderPerDay: 3}
		if mutate != nil {
			mutate(cfg)
		}
	})
	apple, err := appattesttest.NewFixtureAt(base.now)
	if err != nil {
		t.Fatal(err)
	}
	// Tests chain to a throwaway root; production always uses the compiled
	// Apple root (TestNewPrivacyAuthorityUsesCompiledAppleRoot).
	base.auth.appAttestRoot = apple.Root
	cbAttestation := base.record.Attestation
	cbAttestation.Assurance = PrivacyAssuranceCodeBound
	f := &codeBoundFixture{
		privacyFixture: base, apple: apple,
		cbRecord: PrivacyKeyRecord{KeyRecord: base.record.KeyRecord, Attestation: cbAttestation, Signature: signAttestation(t, base.identity, cbAttestation)},
	}
	base.auth.SetAppAttestNotifier(func(providerID, session, keyID, status string) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.notified = append(f.notified, providerID+"/"+session+"/"+status)
	})
	return f
}

func (f *codeBoundFixture) enrollmentStatement(challenge string, keyID []byte) AppAttestEnrollmentStatement {
	return AppAttestEnrollmentStatement{
		Version: PrivacyAppAttestEnrollmentV1, PrivacyClass: PrivacyClassV1, ProviderID: f.providerID, AssignedSession: f.session,
		Challenge: challenge, AppAttestKeyID: base64.RawURLEncoding.EncodeToString(keyID), TeamID: fixtureTeamID,
		BundleID: PrivacySupervisorBundleID, Environment: PrivacyAppAttestEnvironment,
		SEPublicKey:       base64.RawURLEncoding.EncodeToString(f.seRaw),
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(f.identity.Public().(ed25519.PublicKey)),
		ChildCDHash:       fixtureCDHash, ChildCSFlags: 0x22011311 &^ 0x2, SupervisorBundleVersion: "213", IssuedAtUnix: f.now.Unix(),
	}
}

// enrollmentWire signs statement and attests a key over its framing.
func (f *codeBoundFixture) enrollmentWire(statement AppAttestEnrollmentStatement, key *ecdsa.PrivateKey, opts appattesttest.AttestOptions, mutate func(*privacyAppAttestEnrollmentWire)) []byte {
	f.t.Helper()
	framing, err := statement.Framing()
	if err != nil {
		f.t.Fatal(err)
	}
	hash := sha256.Sum256(framing)
	if opts.AppID == "" {
		opts.AppID = PrivacyAppID(fixtureTeamID)
	}
	opts.ClientDataHash = hash[:]
	opts.Key = key
	att, err := f.apple.Attest(opts)
	if err != nil {
		f.t.Fatal(err)
	}
	seSig, err := ecdsa.SignASN1(rand.Reader, f.se, hash[:])
	if err != nil {
		f.t.Fatal(err)
	}
	rawStatement, _ := json.Marshal(statement)
	wire := privacyAppAttestEnrollmentWire{
		Type: privacyAppAttestEnrollmentType, Version: 1, Statement: rawStatement,
		Attestation:       base64.RawURLEncoding.EncodeToString(att.Object),
		SESignature:       base64.RawURLEncoding.EncodeToString(seSig),
		IdentitySignature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(f.identity, framing)),
	}
	if mutate != nil {
		mutate(&wire)
	}
	raw, _ := json.Marshal(wire)
	return raw
}

func newAppAttestKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	point, _ := key.PublicKey.Bytes()
	sum := sha256.Sum256(point)
	return key, sum[:]
}

// enroll runs request, challenge, and enrollment to the enrolled state.
func (f *codeBoundFixture) enroll() {
	f.t.Helper()
	f.key, f.keyID = newAppAttestKey(f.t)
	reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(f.keyID), f.now)
	if reply.Challenge == "" {
		f.t.Fatalf("no challenge: %+v", reply)
	}
	raw := f.enrollmentWire(f.enrollmentStatement(reply.Challenge, f.keyID), f.key, appattesttest.AttestOptions{}, nil)
	if status := f.auth.CompleteEnrollment(context.Background(), f.providerID, f.session, raw, f.now); status != AppAttestEnrolled {
		f.t.Fatalf("enrollment status %s", status)
	}
	if err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.cbRecord}, f.now); err != nil {
		f.t.Fatal(err)
	}
}

func (f *codeBoundFixture) v2Statement(nonce string, seq uint64, issued int64) PostureStatementV2 {
	base := f.statement(nonce, seq, issued)
	base.Version = PrivacyPostureV2Version
	return PostureStatementV2{
		PostureStatement: base, Assurance: PrivacyAssuranceCodeBound,
		AppAttestKeyID:   base64.RawURLEncoding.EncodeToString(f.keyID),
		SupervisorTeamID: fixtureTeamID, SupervisorBundleID: PrivacySupervisorBundleID, SupervisorBundleVersion: "213",
		ChildCDHash: fixtureCDHash, ChildSigningIdentifier: PrivacyChildSigningIdentifier,
		ChildCSFlags: 0x22011311 &^ 0x2, ChildCheckedAtUnix: issued, ChildChannelPeerVerified: true,
	}
}

func (f *codeBoundFixture) v2Wire(statement PostureStatementV2, counter uint32, mutate func(*privacyPostureV2Wire)) []byte {
	f.t.Helper()
	framing, err := statement.Framing()
	if err != nil {
		f.t.Fatal(err)
	}
	hash := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, f.se, hash[:])
	if err != nil {
		f.t.Fatal(err)
	}
	assertion, err := appattesttest.Assert(f.key, PrivacyAppID(fixtureTeamID), counter, hash[:])
	if err != nil {
		f.t.Fatal(err)
	}
	rawStatement, _ := json.Marshal(statement)
	wire := privacyPostureV2Wire{
		Type: privacyPostureResponseType, Version: 2, Statement: rawStatement,
		SESignature:        base64.RawURLEncoding.EncodeToString(seSig),
		IdentitySignature:  base64.RawURLEncoding.EncodeToString(ed25519.Sign(f.identity, framing)),
		AppAttestAssertion: base64.RawURLEncoding.EncodeToString(assertion),
	}
	if mutate != nil {
		mutate(&wire)
	}
	raw, _ := json.Marshal(wire)
	return raw
}

// verifyV2 challenges and answers with a v2 posture using the next counter.
func (f *codeBoundFixture) verifyV2(seq uint64, change func(*PostureStatementV2), counter uint32) error {
	f.t.Helper()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		f.t.Fatal(err)
	}
	statement := f.v2Statement(nonce, seq, issued)
	if change != nil {
		change(&statement)
	}
	return f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.v2Wire(statement, counter, nil), nil, f.now)
}

func (f *codeBoundFixture) label() (string, bool) {
	_, label, ok := f.auth.EligibleAssurance(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now)
	return label, ok
}

func (f *codeBoundFixture) quarantined() bool {
	q, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now)
	if err != nil {
		f.t.Fatal(err)
	}
	return q
}

func (f *codeBoundFixture) keyRow() AppAttestKey {
	key, found, err := f.store.AppAttestKeyByID(context.Background(), f.keyID)
	if err != nil || !found {
		f.t.Fatalf("key row found=%v err=%v", found, err)
	}
	return key
}

func TestNewPrivacyAuthorityUsesCompiledAppleRoot(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	if f.auth.appAttestRoot == nil || f.auth.appAttestRoot.Subject.CommonName != "Apple App Attestation Root CA" {
		t.Fatal("authority did not load the compiled Apple root")
	}
	if f.auth.CodeBoundActive() {
		t.Fatal("code-bound active by default")
	}
}

func TestCodeBoundEnrollmentAndLabelGrant(t *testing.T) {
	f := newCodeBoundFixture(t, nil)
	f.accept()
	f.verify(0, nil)
	if label, ok := f.label(); !ok || label != PrivacyAssurance {
		t.Fatalf("beta label = %q %v", label, ok)
	}
	f.enroll()
	if _, ok := f.label(); ok {
		t.Fatal("enrolled session kept the Beta label before a v2 posture")
	}
	row := f.keyRow()
	if row.State != AppAttestKeyActive || row.LastCounter != 0 || len(row.PublicKey) != 65 || row.TeamID != fixtureTeamID {
		t.Fatalf("row = %+v", row)
	}
	if err := f.verifyV2(1, nil, 1); err != nil {
		t.Fatal(err)
	}
	if label, ok := f.label(); !ok || label != PrivacyAssuranceCodeBound {
		t.Fatalf("code-bound label = %q %v", label, ok)
	}
	if err := f.verifyV2(2, nil, 5); err != nil {
		t.Fatal(err)
	}
	if got := f.keyRow().LastCounter; got != 5 {
		t.Fatalf("durable counter %d", got)
	}

	// Disabling code-bound never hands an enrolled session the Beta label.
	f.auth.codeBound = false
	if _, ok := f.label(); ok {
		t.Fatal("disabled code-bound left an enrolled session eligible")
	}
	f.auth.codeBound = true

	// A reconnecting session re-presents the keyId and is enrolled without a
	// new attestation; the counter survives.
	f.auth.DropSession(f.providerID, f.session)
	f.session = "session-b"
	f.accept()
	reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(f.keyID), f.now)
	if reply.Status != AppAttestEnrolled {
		t.Fatalf("re-presented key = %+v", reply)
	}
	if err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.cbRecord}, f.now); err != nil {
		t.Fatal(err)
	}
	if err := f.verifyV2(0, nil, 5); err == nil || !strings.Contains(err.Error(), ReasonAppAttestCounterRegression) {
		t.Fatalf("replayed counter after restart = %v", err)
	}
	if !f.quarantined() || f.keyRow().State != AppAttestKeyRevoked || f.keyRow().RevokedReason != ReasonAppAttestCounterRegression {
		t.Fatal("counter regression did not quarantine and revoke the key")
	}
}

func TestCodeBoundEnrollmentReplies(t *testing.T) {
	t.Run("disabled", func(t *testing.T) {
		f := newPrivacyFixture(t, nil)
		f.accept()
		reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(bytesRepeat(1, 32)), f.now)
		if reply.Status != AppAttestUnavailable {
			t.Fatalf("reply %+v", reply)
		}
	})
	t.Run("root failed", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.auth.appAttestRoot = nil
		f.accept()
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(bytesRepeat(1, 32)), f.now); reply.Status != AppAttestUnavailable {
			t.Fatalf("reply %+v", reply)
		}
	})
	t.Run("before key records", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(bytesRepeat(1, 32)), f.now); reply.Status != AppAttestUnavailable {
			t.Fatalf("reply %+v", reply)
		}
	})
	t.Run("outstanding and rate limit", func(t *testing.T) {
		f := newCodeBoundFixture(t, func(cfg *config.PrivacyClassConfig) { cfg.CodeBound.MaxEnrollmentsPerProviderPerDay = 1 })
		f.accept()
		keyID := base64.RawURLEncoding.EncodeToString(bytesRepeat(1, 32))
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, keyID, f.now); reply.Challenge == "" {
			t.Fatalf("first reply %+v", reply)
		}
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, keyID, f.now); reply.Status != AppAttestUnavailable {
			t.Fatalf("outstanding reply %+v", reply)
		}
		later := f.now.Add(61 * time.Second)
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, keyID, later); reply.Status != AppAttestUnavailable {
			t.Fatalf("rate limit reply %+v", reply)
		}
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, keyID, f.now.Add(25*time.Hour)); reply.Challenge == "" {
			t.Fatalf("after 24h reply %+v", reply)
		}
	})
	t.Run("late or wrong challenge is unavailable without quarantine", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		key, keyID := newAppAttestKey(t)
		reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(keyID), f.now)
		raw := f.enrollmentWire(f.enrollmentStatement(reply.Challenge, keyID), key, appattesttest.AttestOptions{}, nil)
		if status := f.auth.CompleteEnrollment(context.Background(), f.providerID, f.session, raw, f.now.Add(61*time.Second)); status != AppAttestUnavailable {
			t.Fatalf("late status %s", status)
		}
		if status := f.auth.CompleteEnrollment(context.Background(), f.providerID, f.session, raw, f.now); status != AppAttestUnavailable {
			t.Fatalf("reused challenge status %s", status)
		}
		reply = f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(keyID), f.now)
		wrong := f.enrollmentStatement(base64.RawURLEncoding.EncodeToString(bytesRepeat(9, 32)), keyID)
		if status := f.auth.CompleteEnrollment(context.Background(), f.providerID, f.session, f.enrollmentWire(wrong, key, appattesttest.AttestOptions{}, nil), f.now); status != AppAttestUnavailable {
			t.Fatalf("wrong challenge status %s", status)
		}
		if f.quarantined() {
			t.Fatal("late enrollment quarantined")
		}
	})
	t.Run("revoked and other provider", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		if _, err := f.store.RevokeAppAttestKey(context.Background(), f.providerID, f.keyID, ReasonOperatorRevoked, f.now); err != nil {
			t.Fatal(err)
		}
		f.auth.DropSession(f.providerID, f.session)
		f.accept()
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(f.keyID), f.now); reply.Status != AppAttestReenrollRequired {
			t.Fatalf("revoked reply %+v", reply)
		}
		other := newCodeBoundFixture(t, nil)
		other.store = f.store
		other.auth.store = f.store
		other.providerID = "provider-b"
		other.auth.sessions[privacySessionID{providerID: "provider-b", session: other.session}] = &privacySession{attestations: map[string]string{"x": fixtureCDHash}}
		if reply := other.auth.BeginEnrollment(context.Background(), "provider-b", other.session, base64.RawURLEncoding.EncodeToString(f.keyID), f.now); reply.Status != AppAttestRejected {
			t.Fatalf("other provider reply %+v", reply)
		}
		if q, _ := f.store.IsQuarantined(context.Background(), "provider-b", f.now); !q {
			t.Fatal("cross-provider keyId did not quarantine")
		}
	})
	t.Run("stale binding", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		if _, err := f.store.db.Exec(`UPDATE privacy_app_attest_keys SET team_id='ZZZZZ99999'`); err != nil {
			t.Fatal(err)
		}
		f.auth.DropSession(f.providerID, f.session)
		f.accept()
		if reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(f.keyID), f.now); reply.Status != AppAttestReenrollRequired {
			t.Fatalf("stale reply %+v", reply)
		}
		if row := f.keyRow(); row.State != AppAttestKeyRevoked || row.RevokedReason != ReasonBindingStale {
			t.Fatalf("row %+v", row)
		}
		if f.quarantined() {
			t.Fatal("binding_stale quarantined")
		}
	})
}

func TestCodeBoundEnrollmentRejections(t *testing.T) {
	dev := appattesttest.DevelopmentAAGUID
	cases := []struct {
		name   string
		reason string
		stmt   func(*AppAttestEnrollmentStatement)
		opts   appattesttest.AttestOptions
		wire   func(*privacyAppAttestEnrollmentWire)
	}{
		{name: "wrong team", reason: ReasonAppAttestBindingMismatch, stmt: func(s *AppAttestEnrollmentStatement) { s.TeamID = "ZZZZZ99999" }},
		{name: "wrong session", reason: ReasonAppAttestBindingMismatch, stmt: func(s *AppAttestEnrollmentStatement) { s.AssignedSession = "other" }},
		{name: "wrong environment", reason: ReasonAppAttestBindingMismatch, stmt: func(s *AppAttestEnrollmentStatement) { s.Environment = "development" }},
		{name: "wrong se pin", reason: ReasonAppAttestBindingMismatch, stmt: func(s *AppAttestEnrollmentStatement) {
			s.SEPublicKey = base64.RawURLEncoding.EncodeToString(bytesRepeat(7, 64))
		}},
		{name: "bad identity signature", reason: ReasonAppAttestBindingMismatch, wire: func(w *privacyAppAttestEnrollmentWire) {
			w.IdentitySignature = base64.RawURLEncoding.EncodeToString(bytesRepeat(1, 64))
		}},
		{name: "unknown field", reason: ReasonAppAttestBindingMismatch, wire: func(w *privacyAppAttestEnrollmentWire) {
			w.Statement = json.RawMessage(strings.Replace(string(w.Statement), "{", `{"extra":1,`, 1))
		}},
		{name: "wrong rpIdHash", reason: ReasonAppAttestAttestationInvalid, opts: appattesttest.AttestOptions{AppID: fixtureTeamID + ".tech.malibu.other"}},
		{name: "development aaguid", reason: ReasonAppAttestAttestationInvalid, opts: appattesttest.AttestOptions{AAGUID: &dev}},
		{name: "nonzero counter", reason: ReasonAppAttestAttestationInvalid, opts: appattesttest.AttestOptions{Counter: 1}},
		{name: "missing nonce", reason: ReasonAppAttestAttestationInvalid, opts: appattesttest.AttestOptions{NoNonce: true}},
		{name: "missing aclBlob", reason: ReasonAppAttestACLMismatch, opts: appattesttest.AttestOptions{NoACL: true}},
		{name: "different aclBlob", reason: ReasonAppAttestACLMismatch, opts: appattesttest.AttestOptions{ACLInner: []byte{0x30, 0x00}}},
		{name: "unapproved child", reason: ReasonSupervisorChildCheckFailed, stmt: func(s *AppAttestEnrollmentStatement) { s.ChildCDHash = secondFixtureCDHash }},
		{name: "debugged child", reason: ReasonSupervisorChildCheckFailed, stmt: func(s *AppAttestEnrollmentStatement) { s.ChildCSFlags |= 0x10000000 }},
		{name: "child without runtime", reason: ReasonSupervisorChildCheckFailed, stmt: func(s *AppAttestEnrollmentStatement) { s.ChildCSFlags &^= 0x00010000 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newCodeBoundFixture(t, nil)
			f.accept()
			key, keyID := newAppAttestKey(t)
			reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(keyID), f.now)
			statement := f.enrollmentStatement(reply.Challenge, keyID)
			if tc.stmt != nil {
				tc.stmt(&statement)
			}
			raw := f.enrollmentWire(statement, key, tc.opts, tc.wire)
			if status := f.auth.CompleteEnrollment(context.Background(), f.providerID, f.session, raw, f.now); status != AppAttestRejected {
				t.Fatalf("status %s", status)
			}
			var reason string
			if err := f.store.db.QueryRow(`SELECT reason FROM privacy_class_quarantine WHERE provider_id=?`, f.providerID).Scan(&reason); err != nil || reason != tc.reason {
				t.Fatalf("reason %q err %v", reason, err)
			}
			if _, found, _ := f.store.AppAttestKeyByID(context.Background(), keyID); found {
				t.Fatal("rejected key stored")
			}
		})
	}
	t.Run("chain to other root", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		other, err := appattesttest.NewFixtureAt(f.now)
		if err != nil {
			t.Fatal(err)
		}
		f.auth.appAttestRoot = other.Root
		f.accept()
		key, keyID := newAppAttestKey(t)
		reply := f.auth.BeginEnrollment(context.Background(), f.providerID, f.session, base64.RawURLEncoding.EncodeToString(keyID), f.now)
		raw := f.enrollmentWire(f.enrollmentStatement(reply.Challenge, keyID), key, appattesttest.AttestOptions{}, nil)
		if status := f.auth.CompleteEnrollment(context.Background(), f.providerID, f.session, raw, f.now); status != AppAttestRejected {
			t.Fatalf("status %s", status)
		}
	})
}

func TestCodeBoundPostureRules(t *testing.T) {
	t.Run("assertion signature", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		nonce, issued, _ := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		raw := f.v2Wire(f.v2Statement(nonce, 1, issued), 1, func(w *privacyPostureV2Wire) {
			other, _ := newAppAttestKey(t)
			body, _ := appattesttest.Assert(other, PrivacyAppID(fixtureTeamID), 1, bytesRepeat(1, 32))
			w.AppAttestAssertion = base64.RawURLEncoding.EncodeToString(body)
		})
		mustQuarantine(t, f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, raw, nil, f.now), ReasonAppAttestAssertionInvalid)
		if row := f.keyRow(); row.State != AppAttestKeyRevoked || row.RevokedReason != ReasonAppAttestAssertionInvalid {
			t.Fatalf("row %+v", row)
		}
		// Unquarantine never reactivates the key.
		if err := f.store.Unquarantine(context.Background(), f.providerID); err != nil {
			t.Fatal(err)
		}
		if _, err := f.store.db.Exec(`UPDATE privacy_app_attest_keys SET state='active',revoked_reason=NULL,revoked_at_unix=NULL`); err == nil {
			t.Fatal("revoked key reactivated")
		}
	})
	t.Run("counter regression", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		if err := f.verifyV2(1, nil, 3); err != nil {
			t.Fatal(err)
		}
		mustQuarantine(t, f.verifyV2(2, nil, 3), ReasonAppAttestCounterRegression)
	})
	child := map[string]func(*PostureStatementV2){
		"child cdhash":      func(s *PostureStatementV2) { s.ChildCDHash = secondFixtureCDHash },
		"child identifier":  func(s *PostureStatementV2) { s.ChildSigningIdentifier = "other.cli" },
		"child flags":       func(s *PostureStatementV2) { s.ChildCSFlags |= 0x4 },
		"child checked at":  func(s *PostureStatementV2) { s.ChildCheckedAtUnix += 6 },
		"peer not verified": func(s *PostureStatementV2) { s.ChildChannelPeerVerified = false },
	}
	for name, change := range child {
		t.Run(name, func(t *testing.T) {
			f := newCodeBoundFixture(t, nil)
			f.accept()
			f.enroll()
			mustQuarantine(t, f.verifyV2(1, change, 1), ReasonSupervisorChildCheckFailed)
		})
	}
	binding := map[string]func(*PostureStatementV2){
		"other key id": func(s *PostureStatementV2) {
			s.AppAttestKeyID = base64.RawURLEncoding.EncodeToString(bytesRepeat(2, 32))
		},
		"other team":   func(s *PostureStatementV2) { s.SupervisorTeamID = "ZZZZZ99999" },
		"other bundle": func(s *PostureStatementV2) { s.SupervisorBundleID = "tech.malibu.other" },
		"assurance":    func(s *PostureStatementV2) { s.Assurance = PrivacyAssurance },
	}
	for name, change := range binding {
		t.Run(name, func(t *testing.T) {
			f := newCodeBoundFixture(t, nil)
			f.accept()
			f.enroll()
			mustReject(t, f.verifyV2(1, change, 1), "posture_code_bound_binding")
			if f.quarantined() {
				t.Fatal("binding field quarantined")
			}
		})
	}
	t.Run("v2 before enrollment", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.key, f.keyID = newAppAttestKey(t)
		mustReject(t, f.verifyV2(1, nil, 1), "posture_v2_not_enrolled")
		if f.quarantined() {
			t.Fatal("unenrolled v2 quarantined")
		}
	})
	t.Run("v1 after enrollment is a regression", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		nonce, issued, _ := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		statement := f.statement(nonce, 1, issued)
		statement.PrivacyKeyRecordDigests = []string{f.record.KeyRecord.KeyRecordDigest}
		mustQuarantine(t, f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(statement), nil, f.now), ReasonAssuranceRegression)
	})
	t.Run("beta key attestation after enrollment", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.record}, f.now)
		mustQuarantine(t, err, ReasonAssuranceRegression)
	})
	t.Run("code-bound key attestation before enrollment is dropped", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		if err := f.auth.AcceptPrivacyKeys(context.Background(), f.providerID, f.session, []PrivacyKeyRecord{f.cbRecord}, f.now); err != nil {
			t.Fatal(err)
		}
		fresh, err := f.store.PrivacyKeyFresh(context.Background(), f.providerID, f.session, f.cbRecord.KeyRecord.KeyRecordDigest, f.now)
		if err != nil || fresh || f.quarantined() {
			t.Fatalf("fresh=%v err=%v quarantined=%v", fresh, err, f.quarantined())
		}
	})
	t.Run("posture lists a record of the other label", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		nonce, issued, _ := f.auth.BeginChallenge(f.providerID, f.session, f.now)
		f.auth.mu.Lock()
		f.auth.sessions[privacySessionID{providerID: f.providerID, session: f.session}].assurances[f.record.KeyRecord.KeyRecordDigest] = PrivacyAssuranceCodeBound
		f.auth.mu.Unlock()
		mustQuarantine(t, f.auth.VerifyPosture(context.Background(), f.providerID, f.session, nonce, f.response(f.statement(nonce, 1, issued)), nil, f.now), ReasonAssuranceMismatch)
	})
	t.Run("operator revocation ends enrolled state", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		if err := f.verifyV2(1, nil, 1); err != nil {
			t.Fatal(err)
		}
		if _, err := f.store.RevokeActiveAppAttestKey(context.Background(), f.providerID, ReasonOperatorRevoked, f.now); err != nil {
			t.Fatal(err)
		}
		if _, ok := f.label(); ok {
			t.Fatal("revoked key left the session eligible")
		}
		mustReject(t, f.verifyV2(2, nil, 2), "posture_app_attest_key_inactive")
		if len(f.notified) != 1 || !strings.HasSuffix(f.notified[0], AppAttestReenrollRequired) || f.quarantined() {
			t.Fatalf("notified %v quarantined %v", f.notified, f.quarantined())
		}
		if f.auth.sessionEnrolled(privacySessionID{providerID: f.providerID, session: f.session}) {
			t.Fatal("enrolled state survived revocation")
		}
	})
	t.Run("counter exhausted", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		if err := f.verifyV2(1, nil, MaxAppAttestCounter); err != nil {
			t.Fatal(err)
		}
		if row := f.keyRow(); row.State != AppAttestKeyRevoked || row.RevokedReason != ReasonCounterExhausted || row.LastCounter != MaxAppAttestCounter {
			t.Fatalf("row %+v", row)
		}
		if _, ok := f.label(); ok || len(f.notified) != 1 || f.quarantined() {
			t.Fatalf("exhausted key still usable or not notified: %v", f.notified)
		}
	})
	t.Run("store write failure leaves posture unverified", func(t *testing.T) {
		f := newCodeBoundFixture(t, nil)
		f.accept()
		f.enroll()
		if _, err := f.store.db.Exec(`CREATE TRIGGER block_counter BEFORE UPDATE OF last_counter ON privacy_app_attest_keys BEGIN SELECT RAISE(ABORT,'blocked'); END`); err != nil {
			t.Fatal(err)
		}
		mustReject(t, f.verifyV2(1, nil, 1), "posture_counter_not_committed")
		if _, ok := f.label(); ok || f.quarantined() {
			t.Fatal("unpersisted counter granted the label or quarantined")
		}
	})
}

func TestAppAttestStore(t *testing.T) {
	f := newPrivacyFixture(t, nil)
	ctx := context.Background()
	key := AppAttestKey{KeyID: bytesRepeat(1, 32), ProviderID: "p", PublicKey: append([]byte{4}, bytesRepeat(2, 64)...), TeamID: fixtureTeamID, SEPublicKeySHA256: bytesRepeat(3, 32), IdentityPublicKeySHA256: bytesRepeat(4, 32)}
	if err := f.store.EnrollAppAttestKey(ctx, key, f.now); err != nil {
		t.Fatal(err)
	}
	if err := f.store.EnrollAppAttestKey(ctx, key, f.now); err != ErrAppAttestKeyExists {
		t.Fatalf("duplicate keyId = %v", err)
	}
	second := key
	second.KeyID = bytesRepeat(5, 32)
	if err := f.store.EnrollAppAttestKey(ctx, second, f.now); err != nil {
		t.Fatal(err)
	}
	first, _, _ := f.store.AppAttestKeyByID(ctx, key.KeyID)
	if first.State != AppAttestKeyRevoked || first.RevokedReason != ReasonSuperseded {
		t.Fatalf("superseded row %+v", first)
	}
	if err := f.store.AdvanceAppAttestCounter(ctx, "p", second.KeyID, 2); err != nil {
		t.Fatal(err)
	}
	for _, counter := range []uint32{2, 1} {
		if err := f.store.AdvanceAppAttestCounter(ctx, "p", second.KeyID, counter); err != ErrAppAttestCounterNotAdvanced {
			t.Fatalf("counter %d = %v", counter, err)
		}
	}
	if err := f.store.AdvanceAppAttestCounter(ctx, "p", key.KeyID, 9); err != ErrAppAttestCounterNotAdvanced {
		t.Fatalf("revoked key advanced: %v", err)
	}
	if _, err := f.store.RevokeAppAttestKey(ctx, "p", second.KeyID, "made_up", f.now); err == nil {
		t.Fatal("unknown reason accepted")
	}
	if _, err := f.store.db.Exec(`INSERT INTO privacy_app_attest_keys(app_attest_key_id,provider_id,public_key,team_id,se_public_key_sha256,identity_public_key_sha256,enrolled_at_unix,last_counter,state) VALUES(?,?,?,?,?,?,?,0,'active')`, bytesRepeat(6, 32), "p", key.PublicKey, fixtureTeamID, bytesRepeat(3, 32), bytesRepeat(4, 32), f.now.Unix()); err == nil {
		t.Fatal("second active key for one provider accepted")
	}
	list, err := f.store.ListAppAttestKeys(ctx)
	if err != nil || len(list) != 2 || list[1].LastCounter != 2 || list[1].State != AppAttestKeyActive {
		t.Fatalf("list %+v err %v", list, err)
	}
	// A quarantine with a §4.12 reason revokes the active key in the same
	// transaction; a v0.1 reason does not.
	if err := f.store.QuarantineAndRevokePrivacy(ctx, "p", "posture_signature_failure", f.now, time.Hour, time.Minute); err != nil {
		t.Fatal(err)
	}
	if row, _, _ := f.store.AppAttestKeyByID(ctx, second.KeyID); row.State != AppAttestKeyActive {
		t.Fatal("v0.1 quarantine revoked the app attest key")
	}
	if err := f.store.QuarantineAndRevokePrivacy(ctx, "p", ReasonAppAttestAssertionInvalid, f.now, time.Hour, time.Minute); err != nil {
		t.Fatal(err)
	}
	if row, _, _ := f.store.AppAttestKeyByID(ctx, second.KeyID); row.State != AppAttestKeyRevoked || row.RevokedReason != ReasonAppAttestAssertionInvalid {
		t.Fatalf("row %+v", row)
	}
	var count int
	if err := f.store.db.QueryRow(`SELECT COUNT(*) FROM privacy_app_attest_keys`).Scan(&count); err != nil || count != 2 {
		t.Fatalf("revoked rows not kept: %d %v", count, err)
	}
}
