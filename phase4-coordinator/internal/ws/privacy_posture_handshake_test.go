package ws_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// The provider CLI requires hello_ack / auth_response v2 as the very next
// frame after its handshake message and aborts the session otherwise. A
// SPEC-049 posture challenge triggered by handshake privacy_key_records must
// therefore never be enqueued ahead of the ack.
func TestPrivacyPostureChallengeFollowsHelloAck(t *testing.T) {
	record := handshakePrivacyRecord(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithPrivacyAuthority(handshakePrivacyAuthority(t, record)),
		providerws.WithBeforeHandshakeAckSendForTest(slowHandshakeAck),
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["privacy_key_records"] = []relayblind.PrivacyKeyRecord{record.record}
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	if got := readFrameType(t, conn); got != "hello_ack" {
		t.Fatalf("first frame after hello = %q, want hello_ack", got)
	}
	if got := readFrameType(t, conn); got != "privacy_posture_challenge" {
		t.Fatalf("second frame after hello = %q, want privacy_posture_challenge", got)
	}
}

func TestPrivacyPostureChallengeFollowsAuthResponseV2(t *testing.T) {
	record := handshakePrivacyRecord(t)
	h := newProviderHarnessWithServerOptions(t, nil, []providerws.Option{
		providerws.WithPrivacyAuthority(handshakePrivacyAuthority(t, record)),
		providerws.WithBeforeHandshakeAckSendForTest(slowHandshakeAck),
	}, func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	initial := validAuthInitialWithFreshKey(t, "m4-anon")
	initial["privacy_key_records"] = []relayblind.PrivacyKeyRecord{record.record}
	if err := wsutil.WriteClientText(conn, mustJSON(initial)); err != nil {
		t.Fatalf("write auth initial: %v", err)
	}
	challenge := readAuthChallenge(t, conn)
	writeAuthProof(t, conn, challenge, "m4-anon", nil)
	if got := readFrameType(t, conn); got != "auth_response" {
		t.Fatalf("first frame after auth proof = %q, want auth_response", got)
	}
	if got := readFrameType(t, conn); got != "privacy_posture_challenge" {
		t.Fatalf("second frame after auth proof = %q, want privacy_posture_challenge", got)
	}
}

// slowHandshakeAck widens the ack-build window so a posture challenge
// scheduled before the ack would deterministically be enqueued first.
func slowHandshakeAck() { time.Sleep(200 * time.Millisecond) }

func readFrameType(t *testing.T, conn net.Conn) string {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	defer conn.SetReadDeadline(time.Time{})
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read frame: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("frame json: %v", err)
	}
	return envelope.Type
}

type handshakePrivacyFixture struct {
	record   relayblind.PrivacyKeyRecord
	identity ed25519.PrivateKey
}

func handshakePrivacyRecord(t *testing.T) handshakePrivacyFixture {
	t.Helper()
	now := time.Now().UTC()
	_, identity, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	x25519, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	keyRecord, err := relayblind.NewSignedKeyRecord(x25519.PublicKey().Bytes(), identity, []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}, 4096, now, now.Add(time.Duration(relayblind.MaxPrivacyKeyLifetimeSeconds)*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	attestation := relayblind.PrivacyKeyAttestation{
		Version: relayblind.PrivacyKeyAttestationVersion, KeyRecordDigest: keyRecord.KeyRecordDigest,
		PrivacyClass: relayblind.PrivacyClassV1, Assurance: relayblind.PrivacyAssurance, BinaryVersion: "0.1.0",
		CodeCDHash: "0123456789abcdef0123456789abcdef01234567", NotBeforeUnix: keyRecord.NotBeforeUnix, ExpiresAtUnix: keyRecord.ExpiresAtUnix,
	}
	framed, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	return handshakePrivacyFixture{
		record: relayblind.PrivacyKeyRecord{
			KeyRecord: keyRecord, Attestation: attestation, Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(identity, framed)),
		},
		identity: identity,
	}
}

func handshakePrivacyAuthority(t *testing.T, fixture handshakePrivacyFixture) *relayblind.PrivacyAuthority {
	t.Helper()
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	seRaw := make([]byte, 64)
	se.X.FillBytes(seRaw[:32])
	se.Y.FillBytes(seRaw[32:])
	cfg := config.PrivacyClassConfig{
		Enabled:              true,
		ProviderSEPublicKeys: map[string]string{"m4-anon": base64.StdEncoding.EncodeToString(seRaw)},
		ApprovedCodeIdentities: []config.ApprovedCodeIdentity{{
			TeamID: "AB12CD34EF", SigningIdentifier: "live.malibu.provider.cli", CDHash: "0123456789abcdef0123456789abcdef01234567",
			BinaryVersion: "0.1.0", ExpiresAt: time.Now().Add(24 * time.Hour),
		}},
		AllowedSEKeyBackends:            []string{"file", "keychain"},
		PostureChallengeIntervalSeconds: 60,
		PostureMaxAgeSeconds:            150,
		PostureResponseTimeoutSeconds:   10,
		QuarantineSeconds:               86400,
	}
	store, err := relayblind.OpenStore(filepath.Join(t.TempDir(), "privacy.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	public := fixture.identity.Public().(ed25519.PublicKey)
	auth, err := relayblind.NewPrivacyAuthority(store, cfg, map[string]string{"m4-anon": base64.RawURLEncoding.EncodeToString(public)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	return auth
}
