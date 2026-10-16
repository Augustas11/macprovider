package ws

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// codeBoundEvidenceFor builds the §4.13 evidence an attestor would return
// for the posture response raw, asserted by appKey.
func codeBoundEvidenceFor(t *testing.T, material wsPrivacyMaterial, appKey *ecdsa.PrivateKey, raw []byte, counter uint32, now time.Time) []byte {
	t.Helper()
	var response struct {
		Statement json.RawMessage `json:"statement"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		t.Fatal(err)
	}
	statement, err := relayblind.ParsePostureStatement(response.Statement)
	if err != nil {
		t.Fatal(err)
	}
	postureDigest, err := relayblind.PostureDigest(statement)
	if err != nil {
		t.Fatal(err)
	}
	appPublic, err := appKey.PublicKey.ECDH()
	if err != nil {
		t.Fatal(err)
	}
	keyID := sha256.Sum256(appPublic.Bytes())
	cb := relayblind.CodeBoundStatement{
		Version: relayblind.PrivacyCodeBoundVersion, PrivacyClass: relayblind.PrivacyClassV1,
		ProviderID: statement.ProviderID, AssignedSession: statement.AssignedSession, Nonce: statement.Nonce,
		PostureDigest:            postureDigest,
		SEPublicKey:              base64.StdEncoding.EncodeToString(material.seRaw),
		IdentityPublicKey:        base64.RawURLEncoding.EncodeToString(material.identity.Public().(ed25519.PublicKey)),
		AppAttestKeyID:           base64.RawURLEncoding.EncodeToString(keyID[:]),
		RuntimeTeamID:            statement.TeamID,
		RuntimeSigningIdentifier: statement.SigningIdentifier,
		RuntimeCDHash:            statement.CodeCDHash,
		RuntimeCSFlags:           0x0001_0301,
		CheckedAtUnix:            now.Unix(),
	}
	framing, err := cb.Framing()
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(framing)
	assertion, err := appattesttest.Assert(appKey, statement.TeamID+".tech.malibu.app", counter, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	rawStatement, err := json.Marshal(cb)
	if err != nil {
		t.Fatal(err)
	}
	evidence, err := json.Marshal(map[string]any{
		"type": "privacy_code_bound_evidence", "version": 1, "statement": json.RawMessage(rawStatement),
		"assertion": base64.RawURLEncoding.EncodeToString(assertion),
	})
	if err != nil {
		t.Fatal(err)
	}
	return evidence
}

// SPEC-049-R033 over the WebSocket: evidence sent right before the posture on
// the same session makes that posture code_bound_attested.
func TestPrivacyCodeBoundEvidenceRoundTrip(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	material := newWSPrivacyMaterial(t, clock)
	appKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	appPublic, err := appKey.PublicKey.ECDH()
	if err != nil {
		t.Fatal(err)
	}
	keyID := sha256.Sum256(appPublic.Bytes())
	if err := material.auth.UseCodeBound(relayblind.CodeBoundConfig{
		Lookup: func(_ context.Context, providerID string) ([]byte, []byte, bool, error) {
			return keyID[:], appPublic.Bytes(), providerID == "provider-a", nil
		},
		TeamID: "AB12CD34EF", BundleID: "tech.malibu.app",
	}); err != nil {
		t.Fatal(err)
	}
	reg := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", Hostname: "provider.local",
		ModelID: "model-a", ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 4096, MaxConcurrency: 1,
		BinaryVersion: "0.0.0-fixture", Tier: pool.TierPinned, State: pool.StateReady,
		SEPublicKey: append([]byte(nil), material.seRaw...),
	}
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close() })
	t.Cleanup(func() { serverConn.Close() })
	reg.RegisterAt(&provider, serverConn, clock)
	s := &Server{
		pool:             reg,
		log:              zerolog.Nop(),
		now:              func() time.Time { return clock },
		privacyAuthority: material.auth,
	}
	sess := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 64)
	go sess.runWriter()
	t.Cleanup(func() { sess.close() })
	s.sessions.Store(provider.ProviderID+"/"+provider.AssignedID, sess)

	// Evidence with no challenge outstanding is not held.
	stray := codeBoundEvidenceFor(t, material, appKey, material.response(t, base64.RawURLEncoding.EncodeToString(make([]byte, 32)), clock.Unix()), 1, clock)
	s.handleMessage(nil, provider.ProviderID, provider.AssignedID, stray)
	if _, held := s.privacyCodeBoundEvidence.Load(sessionKey(provider.ProviderID, provider.AssignedID)); held {
		t.Fatal("evidence held without an outstanding challenge")
	}

	probe := func(sequence uint64, counter uint32, withEvidence bool) {
		t.Helper()
		clientDone := make(chan error, 1)
		go func() {
			payload, _, err := wsutil.ReadServerData(clientConn)
			if err != nil {
				clientDone <- err
				return
			}
			var challenge PrivacyPostureChallenge
			if err := json.Unmarshal(payload, &challenge); err != nil {
				clientDone <- err
				return
			}
			raw := material.responseSeq(t, challenge.Nonce, challenge.IssuedAtUnix, sequence)
			if withEvidence {
				s.handleMessage(nil, provider.ProviderID, provider.AssignedID, codeBoundEvidenceFor(t, material, appKey, raw, counter, clock))
			}
			s.handleMessage(nil, provider.ProviderID, provider.AssignedID, raw)
			clientDone <- nil
		}()
		s.runPrivacyPostureProbe(provider)
		select {
		case err := <-clientDone:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("privacy posture client timed out")
		}
	}

	probe(1, 1, true)
	if got := wsSessionAssurance(material, clock); got != relayblind.PrivacyAssuranceCodeBound {
		t.Fatalf("assurance = %q, want code-bound", got)
	}
	if _, held := s.privacyCodeBoundEvidence.Load(sessionKey(provider.ProviderID, provider.AssignedID)); held {
		t.Fatal("evidence outlived its challenge")
	}
	// A posture without evidence is device-bound and still eligible.
	probe(2, 0, false)
	if got := wsSessionAssurance(material, clock); got != relayblind.PrivacyAssurance {
		t.Fatalf("assurance = %q, want device-bound", got)
	}
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, clock); !ok {
		t.Fatal("device-bound posture is not eligible")
	}
	// A replayed counter withholds the label only.
	probe(3, 1, true)
	if got := wsSessionAssurance(material, clock); got != relayblind.PrivacyAssurance {
		t.Fatalf("assurance after a replayed counter = %q", got)
	}
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, clock); !ok {
		t.Fatal("a replayed counter made the posture ineligible")
	}
}

func wsSessionAssurance(material wsPrivacyMaterial, now time.Time) string {
	if _, reason := material.auth.EligibilityReasonFor("provider-a", "session-a", material.digest, relayblind.PrivacyAssuranceCodeBound, now, true); reason == "" {
		return relayblind.PrivacyAssuranceCodeBound
	}
	if _, ok := material.auth.Eligible("provider-a", "session-a", material.digest, now); ok {
		return relayblind.PrivacyAssurance
	}
	return ""
}
