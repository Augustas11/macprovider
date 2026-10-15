package relayblind

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

const (
	codeBoundFixtureRel = "../../../test/fixtures/relay-blind/privacy-code-bound-v1.json"
	codeBoundBundleID   = "tech.malibu.app"
)

// codeBoundFixture is a privacy fixture plus an App Attest key that SPEC-033
// recorded for the provider.
type codeBoundFixture struct {
	*privacyFixture
	appKey    *ecdsa.PrivateKey
	keyID     []byte
	publicKey []byte
	lookup    func(ctx context.Context, providerID string) ([]byte, []byte, bool, error)
	counter   uint32
}

func appAttestPublicKey(t *testing.T, key *ecdsa.PrivateKey) []byte {
	t.Helper()
	pub, err := key.PublicKey.ECDH()
	if err != nil {
		t.Fatal(err)
	}
	return pub.Bytes()
}

func newCodeBoundFixture(t *testing.T) *codeBoundFixture {
	t.Helper()
	f := &codeBoundFixture{privacyFixture: newPrivacyFixture(t, nil)}
	f.accept()
	appKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f.appKey = appKey
	f.publicKey = appAttestPublicKey(t, appKey)
	digest := sha256.Sum256(f.publicKey)
	f.keyID = digest[:]
	f.lookup = func(_ context.Context, providerID string) ([]byte, []byte, bool, error) {
		if providerID != f.providerID {
			return nil, nil, false, nil
		}
		return f.keyID, f.publicKey, true, nil
	}
	if err := f.auth.UseCodeBound(CodeBoundConfig{
		Lookup:   f.recordLookup,
		TeamID:   fixtureTeamID,
		BundleID: codeBoundBundleID,
	}); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *codeBoundFixture) recordLookup(ctx context.Context, providerID string) ([]byte, []byte, bool, error) {
	return f.lookup(ctx, providerID)
}

// codeBoundStatement is what the attestor would sign for this posture.
func (f *codeBoundFixture) codeBoundStatement(statement PostureStatement) CodeBoundStatement {
	f.t.Helper()
	framing, err := statement.Framing()
	if err != nil {
		f.t.Fatal(err)
	}
	digest := sha256.Sum256(framing)
	return CodeBoundStatement{
		Version: PrivacyCodeBoundVersion, PrivacyClass: PrivacyClassV1,
		ProviderID: statement.ProviderID, AssignedSession: statement.AssignedSession, Nonce: statement.Nonce,
		PostureDigest:            encodeBase64URL(digest[:]),
		SEPublicKey:              base64.StdEncoding.EncodeToString(f.seRaw),
		IdentityPublicKey:        encodeBase64URL(f.identity.Public().(ed25519.PublicKey)),
		AppAttestKeyID:           encodeBase64URL(f.keyID),
		RuntimeTeamID:            statement.TeamID,
		RuntimeSigningIdentifier: statement.SigningIdentifier,
		RuntimeCDHash:            statement.CodeCDHash,
		RuntimeCSFlags:           csRequiredFlags | 0x2000,
		CheckedAtUnix:            f.now.Unix(),
	}
}

func (f *codeBoundFixture) evidence(cb CodeBoundStatement, signer *ecdsa.PrivateKey, appID string, counter uint32) []byte {
	f.t.Helper()
	framing, err := cb.Framing()
	if err != nil {
		f.t.Fatal(err)
	}
	hash := sha256.Sum256(framing)
	assertion, err := appattesttest.Assert(signer, appID, counter, hash[:])
	if err != nil {
		f.t.Fatal(err)
	}
	statement, err := json.Marshal(cb)
	if err != nil {
		f.t.Fatal(err)
	}
	raw, err := json.Marshal(map[string]any{
		"type": privacyCodeBoundEvidenceType, "version": 1, "statement": json.RawMessage(statement),
		"assertion": encodeBase64URL(assertion),
	})
	if err != nil {
		f.t.Fatal(err)
	}
	return raw
}

// postureWith runs one posture challenge carrying the evidence that build
// returns for it.
func (f *codeBoundFixture) postureWith(seq uint64, build func(PostureStatement) []byte) (CodeBoundOutcome, error) {
	f.t.Helper()
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		f.t.Fatal(err)
	}
	statement := f.statement(nonce, seq, issued)
	var evidence []byte
	if build != nil {
		evidence = build(statement)
	}
	return f.auth.VerifyPostureWithEvidence(context.Background(), f.providerID, f.session, nonce, f.response(statement), evidence, nil, f.now)
}

func (f *codeBoundFixture) validEvidence(statement PostureStatement) []byte {
	f.counter++
	return f.evidence(f.codeBoundStatement(statement), f.appKey, fixtureTeamID+"."+codeBoundBundleID, f.counter)
}

func (f *codeBoundFixture) requireLabel(want string) {
	f.t.Helper()
	if _, ok := f.auth.Eligible(f.providerID, f.session, f.record.KeyRecord.KeyRecordDigest, f.now); !ok {
		f.t.Fatal("posture is not eligible")
	}
	if got := f.auth.SessionAssurance(f.providerID, f.session, f.now); got != want {
		f.t.Fatalf("session assurance = %q, want %q", got, want)
	}
}

// SPEC-049-R033: a posture asserted by the recorded App Attest key, after the
// attestor checked the approved runtime, is code_bound_attested.
func TestCodeBoundPostureEarnsTheLabel(t *testing.T) {
	f := newCodeBoundFixture(t)
	outcome, err := f.postureWith(1, f.validEvidence)
	if err != nil {
		t.Fatal(err)
	}
	if outcome.Assurance != PrivacyAssuranceCodeBound || outcome.Reason != "" {
		t.Fatalf("outcome = %+v", outcome)
	}
	f.requireLabel(PrivacyAssuranceCodeBound)
	// The next posture without evidence is device-bound again: the label is
	// per posture.
	if outcome, err := f.postureWith(2, nil); err != nil || outcome.Assurance != PrivacyAssurance || outcome.Reason != "" {
		t.Fatalf("posture without evidence: %+v %v", outcome, err)
	}
	f.requireLabel(PrivacyAssurance)
	// The label lapses with its posture (SPEC-049-R005).
	if outcome, err := f.postureWith(3, f.validEvidence); err != nil || outcome.Assurance != PrivacyAssuranceCodeBound {
		t.Fatalf("third posture: %+v %v", outcome, err)
	}
	if got := f.auth.SessionAssurance(f.providerID, f.session, f.now.Add(151*time.Second)); got != "" {
		t.Fatalf("assurance after max age = %q", got)
	}
}

// SPEC-049-R033: every failure withholds only the label. The posture stays
// verified and eligible as device-bound, and nothing is quarantined.
func TestCodeBoundFailuresOnlyWithholdTheLabel(t *testing.T) {
	appID := fixtureTeamID + "." + codeBoundBundleID
	otherKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name   string
		reason string
		setup  func(*codeBoundFixture)
		build  func(*codeBoundFixture, PostureStatement) []byte
	}{
		{name: "not json", reason: CodeBoundRejectEvidenceInvalid, build: func(*codeBoundFixture, PostureStatement) []byte { return []byte("{") }},
		{name: "unknown field", reason: CodeBoundRejectEvidenceInvalid, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			return bytes.Replace(f.validEvidence(s), []byte(`{"assertion"`), []byte(`{"extra":1,"assertion"`), 1)
		}},
		{name: "posture digest", reason: CodeBoundRejectBindingMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.PostureDigest = encodeBase64URL(bytes.Repeat([]byte{1}, 32))
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "other session", reason: CodeBoundRejectBindingMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.AssignedSession = "session-b"
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "other secure enclave key", reason: CodeBoundRejectBindingMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			other := make([]byte, 64)
			otherKey.X.FillBytes(other[:32])
			otherKey.Y.FillBytes(other[32:])
			cb.SEPublicKey = base64.StdEncoding.EncodeToString(other)
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "other identity key", reason: CodeBoundRejectBindingMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.IdentityPublicKey = encodeBase64URL(ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32)).Public().(ed25519.PublicKey))
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "runtime cdhash", reason: CodeBoundRejectRuntimeIdentityMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.RuntimeCDHash = "ffffffffffffffffffffffffffffffffffffffff"
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "runtime identifier", reason: CodeBoundRejectRuntimeIdentityMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.RuntimeSigningIdentifier = "live.malibu.other"
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "runtime team", reason: CodeBoundRejectRuntimeIdentityMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.RuntimeTeamID = "ZZ12CD34EF"
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "debugged runtime", reason: CodeBoundRejectRuntimeIdentityMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.RuntimeCSFlags |= 0x1000_0000
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "get-task-allow runtime", reason: CodeBoundRejectRuntimeIdentityMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.RuntimeCSFlags |= 0x4
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "no hardened runtime", reason: CodeBoundRejectRuntimeIdentityMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.RuntimeCSFlags &^= 0x0001_0000
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "stale check", reason: CodeBoundRejectClockSkew, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			cb.CheckedAtUnix -= 31
			return f.evidence(cb, f.appKey, appID, 1)
		}},
		{name: "no record", reason: CodeBoundRejectRecordMissing, setup: func(f *codeBoundFixture) {
			f.lookup = func(context.Context, string) ([]byte, []byte, bool, error) { return nil, nil, false, nil }
		}, build: (*codeBoundFixture).validEvidence},
		{name: "record before migration 033", reason: CodeBoundRejectRecordMissing, setup: func(f *codeBoundFixture) {
			f.lookup = func(context.Context, string) ([]byte, []byte, bool, error) { return f.keyID, nil, true, nil }
		}, build: (*codeBoundFixture).validEvidence},
		{name: "record unreadable", reason: CodeBoundRejectRecordUnavailable, setup: func(f *codeBoundFixture) {
			f.lookup = func(context.Context, string) ([]byte, []byte, bool, error) {
				return nil, nil, false, errors.New("down")
			}
		}, build: (*codeBoundFixture).validEvidence},
		{name: "another key", reason: CodeBoundRejectKeyMismatch, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			cb := f.codeBoundStatement(s)
			digest := sha256.Sum256(appAttestPublicKey(f.t, otherKey))
			cb.AppAttestKeyID = encodeBase64URL(digest[:])
			return f.evidence(cb, otherKey, appID, 1)
		}},
		{name: "signature by another key", reason: CodeBoundRejectAssertionInvalid, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			return f.evidence(f.codeBoundStatement(s), otherKey, appID, 1)
		}},
		{name: "another app", reason: CodeBoundRejectAssertionInvalid, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			return f.evidence(f.codeBoundStatement(s), f.appKey, fixtureTeamID+".tech.malibu.other", 1)
		}},
		{name: "zero counter", reason: CodeBoundRejectCounterNotIncreasing, build: func(f *codeBoundFixture, s PostureStatement) []byte {
			return f.evidence(f.codeBoundStatement(s), f.appKey, appID, 0)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newCodeBoundFixture(t)
			if tc.setup != nil {
				tc.setup(f)
			}
			outcome, err := f.postureWith(1, func(s PostureStatement) []byte { return tc.build(f, s) })
			if err != nil {
				t.Fatalf("posture failed: %v", err)
			}
			if outcome.Assurance != PrivacyAssurance || outcome.Reason != tc.reason {
				t.Fatalf("outcome = %+v, want device-bound with %q", outcome, tc.reason)
			}
			f.requireLabel(PrivacyAssurance)
			if quarantined, err := f.store.IsQuarantined(context.Background(), f.providerID, f.now); err != nil || quarantined {
				t.Fatalf("quarantined=%v err=%v", quarantined, err)
			}
		})
	}
}

// Without UseCodeBound (no SPEC-033 record connection) evidence is ignored
// and the posture is device-bound.
func TestCodeBoundUnconfiguredIsDeviceBound(t *testing.T) {
	f := newCodeBoundFixture(t)
	f.auth.codeBound.Store(nil)
	outcome, err := f.postureWith(1, f.validEvidence)
	if err != nil || outcome.Assurance != PrivacyAssurance || outcome.Reason != CodeBoundRejectRecordUnavailable {
		t.Fatalf("outcome = %+v err=%v", outcome, err)
	}
	if err := f.auth.UseCodeBound(CodeBoundConfig{Lookup: f.recordLookup, TeamID: "", BundleID: codeBoundBundleID}); err == nil {
		t.Fatal("an empty team id was accepted")
	}
}

// SPEC-049-R033 item 7: the counter strictly increases, is durable, and
// survives a coordinator restart.
func TestCodeBoundCounterIsDurableAndStrictlyIncreasing(t *testing.T) {
	f := newCodeBoundFixture(t)
	appID := fixtureTeamID + "." + codeBoundBundleID
	at := func(counter uint32) func(PostureStatement) []byte {
		return func(s PostureStatement) []byte { return f.evidence(f.codeBoundStatement(s), f.appKey, appID, counter) }
	}
	if outcome, err := f.postureWith(1, at(5)); err != nil || outcome.Assurance != PrivacyAssuranceCodeBound {
		t.Fatalf("counter 5: %+v %v", outcome, err)
	}
	if outcome, err := f.postureWith(2, at(5)); err != nil || outcome.Reason != CodeBoundRejectCounterNotIncreasing {
		t.Fatalf("replayed counter: %+v %v", outcome, err)
	}
	if outcome, err := f.postureWith(3, at(4)); err != nil || outcome.Reason != CodeBoundRejectCounterNotIncreasing {
		t.Fatalf("lower counter: %+v %v", outcome, err)
	}
	// A restarted coordinator reads the same store.
	restarted, err := NewPrivacyAuthority(f.store, config.PrivacyClassConfig{
		Enabled:                         true,
		ProviderSEPublicKeys:            map[string]string{f.providerID: base64.StdEncoding.EncodeToString(f.seRaw)},
		ApprovedCodeIdentities:          []config.ApprovedCodeIdentity{approvedIdentity(fixtureCDHash)},
		AllowedSEKeyBackends:            []string{PrivacySEBackendFile, PrivacySEBackendKeychain},
		PostureChallengeIntervalSeconds: 60,
		PostureMaxAgeSeconds:            150,
		PostureResponseTimeoutSeconds:   10,
		QuarantineSeconds:               86400,
	}, map[string]string{f.providerID: encodeBase64URL(f.identity.Public().(ed25519.PublicKey))}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.UseCodeBound(CodeBoundConfig{Lookup: f.recordLookup, TeamID: fixtureTeamID, BundleID: codeBoundBundleID}); err != nil {
		t.Fatal(err)
	}
	f.auth = restarted
	f.accept()
	if outcome, err := f.postureWith(4, at(5)); err != nil || outcome.Reason != CodeBoundRejectCounterNotIncreasing {
		t.Fatalf("counter after restart: %+v %v", outcome, err)
	}
	if outcome, err := f.postureWith(5, at(6)); err != nil || outcome.Assurance != PrivacyAssuranceCodeBound {
		t.Fatalf("counter 6 after restart: %+v %v", outcome, err)
	}
	// A key id is bound to the provider that first used it.
	advanced, err := f.store.AdvanceAppAttestCounter(context.Background(), encodeBase64URL(f.keyID), "provider-b", 100, f.now)
	if err != nil || advanced {
		t.Fatalf("another provider advanced the counter: %v %v", advanced, err)
	}
}

// A failed posture never consults the evidence, and evidence never makes a
// valid posture fail.
func TestCodeBoundEvidenceNeverChangesPostureVerdict(t *testing.T) {
	f := newCodeBoundFixture(t)
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	statement := f.statement(nonce, 1, issued)
	evidence := f.validEvidence(statement)
	statement.IssuedAtUnix -= 120
	if _, err := f.auth.VerifyPostureWithEvidence(context.Background(), f.providerID, f.session, nonce, f.response(statement), evidence, nil, f.now); err == nil {
		t.Fatal("a skewed posture verified because it carried evidence")
	}
	if got := f.auth.SessionAssurance(f.providerID, f.session, f.now); got != "" {
		t.Fatalf("assurance of an unverified session = %q", got)
	}
}

func TestCodeBoundEvidenceIsClosed(t *testing.T) {
	f := newCodeBoundFixture(t)
	nonce, issued, err := f.auth.BeginChallenge(f.providerID, f.session, f.now)
	if err != nil {
		t.Fatal(err)
	}
	valid := f.validEvidence(f.statement(nonce, 1, issued))
	if _, err := ParseCodeBoundEvidence(valid); err != nil {
		t.Fatal(err)
	}
	if got, ok := CodeBoundEvidenceNonce(valid); !ok || got != nonce {
		t.Fatalf("nonce = %q ok=%v", got, ok)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(valid, &fields); err != nil {
		t.Fatal(err)
	}
	var assertion string
	if err := json.Unmarshal(fields["assertion"], &assertion); err != nil {
		t.Fatal(err)
	}
	padded := bytes.Replace(valid, []byte(`"`+assertion+`"`), []byte(`"`+assertion+`="`), 1)
	for name, raw := range map[string][]byte{
		"oversized":      append(valid, bytes.Repeat([]byte(" "), MaxPrivacyCodeBoundEvidenceBytes)...),
		"version 2":      bytes.Replace(valid, []byte(`"version":1`), []byte(`"version":2`), 1),
		"wrong type":     bytes.Replace(valid, []byte(privacyCodeBoundEvidenceType), []byte("privacy_posture_response"), 1),
		"padded base64":  padded,
		"duplicate":      bytes.Replace(valid, []byte(`{"assertion"`), []byte(`{"type":"x","assertion"`), 1),
		"negative flags": bytes.Replace(valid, []byte(`"runtime_cs_flags":`), []byte(`"runtime_cs_flags":-`), 1),
	} {
		if bytes.Equal(raw, valid) {
			t.Fatalf("%s: mutation did not apply", name)
		}
		if _, err := ParseCodeBoundEvidence(raw); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}

// codeBoundVector is the shared Go/Swift SPEC-049 §4.13 framing vector.
type codeBoundVector struct {
	Version        string             `json:"version"`
	Statement      CodeBoundStatement `json:"statement"`
	FramingHex     string             `json:"framing_hex"`
	ClientDataHash string             `json:"client_data_hash_hex"`
}

func codeBoundFixtureBytes(t *testing.T) []byte {
	t.Helper()
	posture := testPosture("xPyccfRu3euY3JtLkfdfuR5x2vDS7c4jjS1C0f1v6Yo")
	posture.ProviderID, posture.AssignedSession = "provider-fixture", "session-fixture"
	posture.Nonce = encodeBase64URL(bytes.Repeat([]byte{0x5a}, 32))
	posture.Sequence, posture.IssuedAtUnix = 7, 1_700_000_000
	postureDigest, err := PostureDigest(posture)
	if err != nil {
		t.Fatal(err)
	}
	se, _ := hex.DecodeString("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
	identity := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x01}, ed25519.SeedSize))
	statement := CodeBoundStatement{
		Version: PrivacyCodeBoundVersion, PrivacyClass: PrivacyClassV1, ProviderID: posture.ProviderID,
		AssignedSession: posture.AssignedSession, Nonce: posture.Nonce, PostureDigest: postureDigest,
		SEPublicKey:              base64.StdEncoding.EncodeToString(se),
		IdentityPublicKey:        encodeBase64URL(identity.Public().(ed25519.PublicKey)),
		AppAttestKeyID:           encodeBase64URL(bytes.Repeat([]byte{0x33}, 32)),
		RuntimeTeamID:            posture.TeamID,
		RuntimeSigningIdentifier: posture.SigningIdentifier,
		RuntimeCDHash:            posture.CodeCDHash,
		RuntimeCSFlags:           0x2621_0301,
		CheckedAtUnix:            1_700_000_001,
	}
	framing, err := statement.Framing()
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(framing)
	raw, err := json.MarshalIndent(codeBoundVector{
		Version: PrivacyCodeBoundVersion, Statement: statement,
		FramingHex: hex.EncodeToString(framing), ClientDataHash: hex.EncodeToString(hash[:]),
	}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(raw, '\n')
}

func TestPrivacyCodeBoundVectorGenerate(t *testing.T) {
	if os.Getenv("MACPROVIDER_REGEN_FIXTURES") != "1" {
		t.Skip("set MACPROVIDER_REGEN_FIXTURES=1 to regenerate privacy-code-bound-v1.json")
	}
	if err := os.WriteFile(filepath.Clean(codeBoundFixtureRel), codeBoundFixtureBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPrivacyCodeBoundVector(t *testing.T) {
	got, err := os.ReadFile(codeBoundFixtureRel)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, codeBoundFixtureBytes(t)) {
		t.Fatal("privacy-code-bound-v1.json drifted from the Go framing")
	}
}
