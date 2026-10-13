package ws

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// SPEC-049-R031 over the provider WebSocket: request, challenge, signed
// rotation, accepted result, and the enrollment swapped without an operator.
func TestPrivacyKeyRotationExchange(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	record, identity := wsPrivacyIdentity(t, clock)
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	seRaw := make([]byte, 64)
	se.X.FillBytes(seRaw[:32])
	se.Y.FillBytes(seRaw[32:])
	store, err := relayblind.OpenStore(filepath.Join(t.TempDir(), "privacy.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	auth, err := relayblind.NewPrivacyAuthority(store, config.PrivacyClassConfig{
		Enabled:                         true,
		ApprovedCodeIdentities:          []config.ApprovedCodeIdentity{wsApproved("0123456789abcdef0123456789abcdef01234567")},
		AllowedSEKeyBackends:            []string{"file", "keychain"},
		PostureChallengeIntervalSeconds: 60,
		PostureMaxAgeSeconds:            150,
		PostureResponseTimeoutSeconds:   10,
		QuarantineSeconds:               86400,
	}, nil, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	claim := &relayblind.PrivacyEnrollmentClaim{
		Version: relayblind.PrivacyEnrollmentVersion, IdentityPublicKey: base64.RawURLEncoding.EncodeToString(identity.Public().(ed25519.PublicKey)),
		SEPublicKey: base64.StdEncoding.EncodeToString(seRaw),
	}
	if err := auth.AcceptPrivacyKeysWithClaim(context.Background(), "provider-a", "session-a", []relayblind.PrivacyKeyRecord{record}, claim, clock); err != nil {
		t.Fatal(err)
	}
	material := wsPrivacyMaterial{auth: auth, identity: identity, se: se, seRaw: seRaw, digest: record.KeyRecord.KeyRecordDigest, record: record}
	nonce, issued, err := auth.BeginChallenge("provider-a", "session-a", clock)
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.VerifyPosture(context.Background(), "provider-a", "session-a", nonce, material.responseSeq(t, nonce, issued, 1), seRaw, clock); err != nil {
		t.Fatalf("enrolling posture: %v", err)
	}

	reg := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", Hostname: "provider.local",
		ModelID: "model-a", ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 4096, MaxConcurrency: 1,
		BinaryVersion: "0.0.0-fixture", Tier: pool.TierPinned, State: pool.StateReady,
		SEPublicKey: append([]byte(nil), seRaw...),
	}
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close() })
	t.Cleanup(func() { serverConn.Close() })
	reg.RegisterAt(&provider, serverConn, clock)
	s := &Server{pool: reg, log: zerolog.Nop(), now: func() time.Time { return clock }, privacyAuthority: auth}
	sess := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 64)
	go sess.runWriter()
	t.Cleanup(func() { sess.close() })
	s.sessions.Store(provider.ProviderID+"/"+provider.AssignedID, sess)

	next := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x42}, ed25519.SeedSize))
	results := make(chan PrivacyKeyRotationResult, 1)
	errs := make(chan error, 1)
	go func() {
		payload, _, err := wsutil.ReadServerData(clientConn)
		if err != nil {
			errs <- err
			return
		}
		var challenge PrivacyKeyRotationChallenge
		if err := json.Unmarshal(payload, &challenge); err != nil || challenge.Type != "privacy_key_rotation_challenge" {
			errs <- err
			return
		}
		s.handleMessage(nil, provider.ProviderID, provider.AssignedID, wsRotationMessage(t, material, next, challenge.Nonce, clock.Unix(), 2))
		payload, _, err = wsutil.ReadServerData(clientConn)
		if err != nil {
			errs <- err
			return
		}
		var result PrivacyKeyRotationResult
		if err := json.Unmarshal(payload, &result); err != nil {
			errs <- err
			return
		}
		results <- result
	}()
	s.handleMessage(nil, provider.ProviderID, provider.AssignedID, []byte(`{"type":"privacy_key_rotation_request","version":1}`))
	select {
	case result := <-results:
		if result.Type != "privacy_key_rotation_result" || result.Status != "accepted" || result.Reason != relayblind.RotationAccepted || result.Nonce == "" {
			t.Fatalf("result = %+v", result)
		}
	case err := <-errs:
		t.Fatal(err)
	case <-time.After(5 * time.Second):
		t.Fatal("rotation exchange timed out")
	}
	enrollment, ok, err := store.ActivePrivacyEnrollment(context.Background(), "provider-a")
	if err != nil || !ok || enrollment.IdentityPublicKey != base64.RawURLEncoding.EncodeToString(next.Public().(ed25519.PublicKey)) {
		t.Fatalf("enrollment = %+v ok=%v err=%v", enrollment, ok, err)
	}
	if quarantined, err := store.IsQuarantined(context.Background(), "provider-a", clock); err != nil || quarantined {
		t.Fatalf("quarantined=%v err=%v", quarantined, err)
	}
}

// A coordinator without the privacy class ignores the request entirely.
func TestPrivacyKeyRotationRequestIgnoredWithoutClass(t *testing.T) {
	s := &Server{log: zerolog.Nop()}
	s.handlePrivacyKeyRotationRequest("provider-a", "session-a", []byte(`{"type":"privacy_key_rotation_request","version":1}`))
	s.handlePrivacyKeyRotation("provider-a", "session-a", []byte(`{}`))
}

func wsRotationMessage(t *testing.T, m wsPrivacyMaterial, next ed25519.PrivateKey, nonce string, issued int64, sequence uint64) []byte {
	t.Helper()
	var postureWire struct {
		Statement json.RawMessage `json:"statement"`
	}
	if err := json.Unmarshal(m.responseSeq(t, nonce, issued, sequence), &postureWire); err != nil {
		t.Fatal(err)
	}
	posture, err := relayblind.ParsePostureStatement(postureWire.Statement)
	if err != nil {
		t.Fatal(err)
	}
	digest, err := relayblind.PostureDigest(posture)
	if err != nil {
		t.Fatal(err)
	}
	statement := relayblind.KeyRotationStatement{
		Version: relayblind.PrivacyKeyRotationVersion, PrivacyClass: relayblind.PrivacyClassV1, ProviderID: "provider-a",
		AssignedSession: "session-a", Nonce: nonce, IssuedAtUnix: issued,
		PreviousIdentityPublicKey: base64.RawURLEncoding.EncodeToString(m.identity.Public().(ed25519.PublicKey)),
		IdentityPublicKey:         base64.RawURLEncoding.EncodeToString(next.Public().(ed25519.PublicKey)),
		SEPublicKey:               base64.StdEncoding.EncodeToString(m.seRaw),
		PostureDigest:             digest,
	}
	framing, err := statement.Framing()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, m.se, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	rawStatement, _ := json.Marshal(statement)
	raw, err := json.Marshal(map[string]any{
		"type": "privacy_key_rotation", "version": 1, "statement": json.RawMessage(rawStatement), "posture": postureWire.Statement,
		"se_signature":                base64.RawURLEncoding.EncodeToString(seSig),
		"previous_identity_signature": base64.RawURLEncoding.EncodeToString(ed25519.Sign(m.identity, framing)),
		"identity_signature":          base64.RawURLEncoding.EncodeToString(ed25519.Sign(next, framing)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
