package ws

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
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestPrivacyPostureProbeRoundTrip(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	material := newWSPrivacyMaterial(t, clock)
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

	clientDone := make(chan error, 1)
	go func() {
		payload, op, err := wsutil.ReadServerData(clientConn)
		if err != nil {
			clientDone <- err
			return
		}
		if op != gobwas.OpText {
			clientDone <- err
			return
		}
		var challenge PrivacyPostureChallenge
		if err := json.Unmarshal(payload, &challenge); err != nil {
			clientDone <- err
			return
		}
		raw := material.response(t, challenge.Nonce, challenge.IssuedAtUnix)
		s.handlePrivacyPostureResponse(provider.ProviderID, provider.AssignedID, raw)
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
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, clock); !ok {
		t.Fatal("probe did not make the privacy key eligible")
	}

	// A provider whose posture latched a failure after advertising sends an
	// explicit empty privacy_key_records. Eligibility drops on that heartbeat,
	// well inside the posture max-age; an absent field leaves it unchanged.
	s.handleMessage(nil, provider.ProviderID, provider.AssignedID, privacyHeartbeat(t, "ready", nil))
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, clock); !ok {
		t.Fatal("absent privacy_key_records revoked eligibility")
	}
	s.handleMessage(nil, provider.ProviderID, provider.AssignedID, privacyHeartbeat(t, "ready", []relayblind.PrivacyKeyRecord{}))
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, clock.Add(time.Second)); ok {
		t.Fatal("explicit empty privacy_key_records kept the privacy key eligible")
	}
}

func TestPrivacyKeyRecordsParseBound(t *testing.T) {
	var absent []relayblind.PrivacyKeyRecord
	raw := map[string]json.RawMessage{}
	if _, err := parsePrivacyKeyRecords(raw, &absent); err != nil || absent != nil {
		t.Fatalf("absent = %#v, %v", absent, err)
	}
	raw["privacy_key_records"] = json.RawMessage("[]")
	var empty []relayblind.PrivacyKeyRecord
	if _, err := parsePrivacyKeyRecords(raw, &empty); err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty = %#v, %v", empty, err)
	}
	raw["privacy_key_records"] = json.RawMessage("null")
	if _, err := parsePrivacyKeyRecords(raw, &empty); err == nil {
		t.Fatal("null privacy_key_records accepted")
	}
	raw["privacy_key_records"] = json.RawMessage("[{},{},{},{},{},{},{},{},{}]")
	if _, err := parsePrivacyKeyRecords(raw, &empty); err == nil || !strings.Contains(err.Error(), "8") {
		t.Fatalf("nine records = %v", err)
	}
	raw["privacy_key_records"] = json.RawMessage("[{},{},{},{},{},{},{},{}]")
	if _, err := parsePrivacyKeyRecords(raw, &empty); err == nil || strings.Contains(err.Error(), "at most") {
		t.Fatalf("eight invalid records = %v", err)
	}

	record := wsPrivacyRecord(t, time.Unix(1_800_000_000, 0).UTC())
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	heartbeat := []byte(`{"type":"heartbeat","status":"ready","model_id":"model-a","model_params_b":7,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"slots_free":1,"slots_total":1,"throughput_tps_estimate":10,"requests_served_since_last":0,"avg_latency_ms_since_last":1,"throughput_tps_since_last":1,"privacy_key_records":[` + string(encoded) + `]}`)
	parsed, _, field, err := ParseHeartbeat(heartbeat)
	if err != nil || field != "" || len(parsed.PrivacyKeyRecords) != 1 || parsed.PrivacyKeyRecords[0].KeyRecord.KeyRecordDigest != record.KeyRecord.KeyRecordDigest {
		t.Fatalf("heartbeat privacy records field=%s err=%v records=%d", field, err, len(parsed.PrivacyKeyRecords))
	}
	hello := []byte(`{"type":"hello","version":1,"tier":1,"provider_id":"provider-a","hostname":"host.local","model_id":"model-a","model_params_b":7,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"throughput_tps_estimate":10,"binary_version":"0.0.0-fixture"}`)
	without, _, err := ParseHello(hello)
	if err != nil || without.PrivacyKeyRecords != nil {
		t.Fatalf("hello without privacy records = %#v, %v", without.PrivacyKeyRecords, err)
	}
	withField := []byte(`{"type":"hello","version":1,"tier":1,"provider_id":"provider-a","hostname":"host.local","model_id":"model-a","model_params_b":7,"ram_gb":16,"max_context_tokens":4096,"max_concurrency":1,"throughput_tps_estimate":10,"binary_version":"0.0.0-fixture","privacy_key_records":[]}`)
	with, _, err := ParseHello(withField)
	if err != nil || with.PrivacyKeyRecords == nil || len(with.PrivacyKeyRecords) != 0 {
		t.Fatalf("hello empty privacy records = %#v, %v", with.PrivacyKeyRecords, err)
	}
}

func TestHandleMessageAcceptsHeartbeatPrivacyKeys(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	record, identity := wsPrivacyIdentity(t, clock)
	auth := openWSPrivacyAuthority(t, clock, identity)
	server := &Server{
		pool:             pool.NewRegistry(nil),
		log:              zerolog.Nop(),
		now:              func() time.Time { return clock },
		privacyAuthority: auth,
	}
	server.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "ready", nil))
	if n := privacyKeySessions(t, auth, clock); n != 0 {
		t.Fatalf("absent field sessions = %d", n)
	}
	server.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "ready", []relayblind.PrivacyKeyRecord{record}))
	if n := privacyKeySessions(t, auth, clock); n != 1 {
		t.Fatalf("advertised sessions = %d", n)
	}
	server.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "ready", nil))
	if n := privacyKeySessions(t, auth, clock); n != 1 {
		t.Fatalf("later absent field sessions = %d", n)
	}
	server.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "nope", []relayblind.PrivacyKeyRecord{}))
	if n := privacyKeySessions(t, auth, clock); n != 1 {
		t.Fatalf("invalid heartbeat sessions = %d", n)
	}
	server.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "ready", []relayblind.PrivacyKeyRecord{}))
	if n := privacyKeySessions(t, auth, clock); n != 0 {
		t.Fatalf("empty array sessions = %d", n)
	}
}

func privacyKeySessions(t *testing.T, auth *relayblind.PrivacyAuthority, now time.Time) int {
	t.Helper()
	sessions, err := auth.CandidateSessions(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	return len(sessions)
}

func privacyHeartbeat(t *testing.T, status string, records []relayblind.PrivacyKeyRecord) []byte {
	t.Helper()
	body := map[string]any{
		"type": "heartbeat", "status": status, "model_id": "model-a", "model_params_b": 7,
		"ram_gb": 16, "max_context_tokens": 4096, "max_concurrency": 1, "slots_free": 1, "slots_total": 1,
		"throughput_tps_estimate": 10, "requests_served_since_last": 0, "avg_latency_ms_since_last": 1, "throughput_tps_since_last": 1,
	}
	if records != nil {
		body["privacy_key_records"] = records
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

type wsPrivacyMaterial struct {
	auth     *relayblind.PrivacyAuthority
	identity ed25519.PrivateKey
	se       *ecdsa.PrivateKey
	seRaw    []byte
	digest   string
	record   relayblind.PrivacyKeyRecord
}

func openWSPrivacyAuthority(t *testing.T, now time.Time, identity ed25519.PrivateKey) *relayblind.PrivacyAuthority {
	t.Helper()
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
		ApprovedCodeIdentities:          []config.ApprovedCodeIdentity{wsApproved("0123456789abcdef0123456789abcdef01234567", now.Add(24*time.Hour))},
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
	public := identity.Public().(ed25519.PublicKey)
	auth, err := relayblind.NewPrivacyAuthority(store, cfg, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(public)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	return auth
}

func newWSPrivacyMaterial(t *testing.T, now time.Time) wsPrivacyMaterial {
	t.Helper()
	record, identity := wsPrivacyIdentity(t, now)
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
		ApprovedCodeIdentities:          []config.ApprovedCodeIdentity{wsApproved("0123456789abcdef0123456789abcdef01234567", now.Add(24*time.Hour))},
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
	public := identity.Public().(ed25519.PublicKey)
	auth, err := relayblind.NewPrivacyAuthority(store, cfg, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(public)}, 8, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.AcceptPrivacyKeys(context.Background(), "provider-a", "session-a", []relayblind.PrivacyKeyRecord{record}, now); err != nil {
		t.Fatal(err)
	}
	return wsPrivacyMaterial{auth: auth, identity: identity, se: se, seRaw: seRaw, digest: record.KeyRecord.KeyRecordDigest, record: record}
}

func (m wsPrivacyMaterial) response(t *testing.T, nonce string, issued int64) []byte {
	t.Helper()
	statement := relayblind.PostureStatement{
		Version: relayblind.PrivacyPostureVersion, PrivacyClass: relayblind.PrivacyClassV1,
		ProviderID: "provider-a", AssignedSession: "session-a", Nonce: nonce, Sequence: 0, IssuedAtUnix: issued,
		BinaryVersion: "0.0.0-fixture", CodeCDHash: "0123456789abcdef0123456789abcdef01234567",
		TeamID: "AB12CD34EF", SigningIdentifier: "live.malibu.provider.cli",
		HardenedRuntime: true, LibraryValidation: true, PTDenyAttachApplied: true, CoreDumpsDisabled: true,
		SIPEnabled: true, RuntimeSource: relayblind.PrivacyRuntimeSource, DiagnosticEnvClear: true,
		KVDiskTierDisabled: true, SEKeyBackend: relayblind.PrivacySEBackendFile,
		PrivacyKeyRecordDigests: []string{m.digest},
	}
	rawStatement, err := json.Marshal(statement)
	if err != nil {
		t.Fatal(err)
	}
	framing, err := statement.Framing()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, m.se, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(struct {
		Type              string          `json:"type"`
		Version           int             `json:"version"`
		Statement         json.RawMessage `json:"statement"`
		SESignature       string          `json:"se_signature"`
		IdentitySignature string          `json:"identity_signature"`
	}{
		Type: "privacy_posture_response", Version: 1, Statement: rawStatement,
		SESignature:       base64.RawURLEncoding.EncodeToString(seSig),
		IdentitySignature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(m.identity, framing)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func wsPrivacyRecord(t *testing.T, now time.Time) relayblind.PrivacyKeyRecord {
	t.Helper()
	record, _ := wsPrivacyIdentity(t, now)
	return record
}

func wsPrivacyIdentity(t *testing.T, now time.Time) (relayblind.PrivacyKeyRecord, ed25519.PrivateKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	identity := ed25519.NewKeyFromSeed(seed)
	provider, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := relayblind.NewSignedKeyRecord(provider.PublicKey().Bytes(), identity, []string{"model-a"}, 4096, now, now.Add(time.Duration(relayblind.MaxPrivacyKeyLifetimeSeconds)*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	attestation := relayblind.PrivacyKeyAttestation{
		Version: relayblind.PrivacyKeyAttestationVersion, KeyRecordDigest: record.KeyRecordDigest,
		PrivacyClass: relayblind.PrivacyClassV1, Assurance: relayblind.PrivacyAssurance, BinaryVersion: "0.0.0-fixture",
		CodeCDHash: "0123456789abcdef0123456789abcdef01234567", NotBeforeUnix: record.NotBeforeUnix, ExpiresAtUnix: record.ExpiresAtUnix,
	}
	framed, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	return relayblind.PrivacyKeyRecord{
		KeyRecord: record, Attestation: attestation, Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(identity, framed)),
	}, identity
}

func wsApproved(cdhash string, expiry time.Time) config.ApprovedCodeIdentity {
	return config.ApprovedCodeIdentity{
		TeamID: "AB12CD34EF", SigningIdentifier: "live.malibu.provider.cli", CDHash: cdhash,
		BinaryVersion: "0.0.0-fixture", ExpiresAt: expiry,
	}
}
