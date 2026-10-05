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
	"sync/atomic"
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
	reg := pool.NewRegistry(nil)
	registerPrivacyTestSession(t, reg, "session-a", clock)
	server := &Server{
		pool:             reg,
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

// A heartbeat still in flight from a replaced session must not touch the
// provider's privacy keys: its empty privacy_key_records would otherwise
// revoke the replacement session's keys provider-wide.
func TestReplacedSessionHeartbeatDoesNotRevokePrivacyKeys(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	record, identity := wsPrivacyIdentity(t, clock)
	auth := openWSPrivacyAuthority(t, clock, identity)
	reg := pool.NewRegistry(nil)
	server := &Server{
		pool:             reg,
		log:              zerolog.Nop(),
		now:              func() time.Time { return clock },
		privacyAuthority: auth,
	}
	registerPrivacyTestSession(t, reg, "session-a", clock)
	registerPrivacyTestSession(t, reg, "session-b", clock)
	server.handleMessage(nil, "provider-a", "session-b", privacyHeartbeat(t, "ready", []relayblind.PrivacyKeyRecord{record}))
	if n := privacyKeySessions(t, auth, clock); n != 1 {
		t.Fatalf("current session advertised sessions = %d", n)
	}
	server.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "ready", []relayblind.PrivacyKeyRecord{}))
	sessions, err := auth.CandidateSessions(context.Background(), clock)
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 1 || sessions[0].AssignedSession != "session-b" {
		t.Fatalf("replaced-session heartbeat changed privacy keys: %+v", sessions)
	}
}

// SPEC-049-R005: the challenge cadence is posture_challenge_interval_seconds
// (runPrivacyPostureLoop). Heartbeats re-advertising an unchanged key set
// must not challenge; a new or rotated key does, and an explicit empty array
// still revokes immediately.
func TestHeartbeatPrivacyKeysChallengeOnlyOnChange(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0).UTC()
	record, identity := wsPrivacyIdentity(t, clock)
	rotated := wsPrivacyRecordForKey(t, clock, identity, 0x22)
	fresh := wsPrivacyRecordForKey(t, clock, identity, 0x33)
	auth := openWSPrivacyAuthority(t, clock, identity)
	reg := pool.NewRegistry(nil)
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close() })
	t.Cleanup(func() { serverConn.Close() })
	reg.RegisterAt(&pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", Hostname: "provider.local",
		ModelID: "model-a", ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 4096, MaxConcurrency: 1,
		BinaryVersion: "0.0.0-fixture", Tier: pool.TierPinned, State: pool.StateReady,
	}, serverConn, clock)
	var challenges atomic.Int32
	s := &Server{
		pool:                        reg,
		log:                         zerolog.Nop(),
		now:                         func() time.Time { return clock },
		privacyAuthority:            auth,
		privacyPostureChallengeSent: func() { challenges.Add(1) },
	}
	sess := newProviderSession("provider-a", "session-a", serverConn, 64)
	go sess.runWriter()
	t.Cleanup(func() { sess.close() })
	s.sessions.Store(sessionKey("provider-a", "session-a"), sess)
	// The fake provider answers every challenge at once with an unparseable
	// response, so each probe ends without quarantine or a response timeout.
	go func() {
		for {
			payload, _, err := wsutil.ReadServerData(clientConn)
			if err != nil {
				return
			}
			var envelope struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(payload, &envelope) == nil && envelope.Type == "privacy_posture_challenge" {
				s.handlePrivacyPostureResponse("provider-a", "session-a", []byte(`{}`))
			}
		}
	}()
	heartbeat := func(records []relayblind.PrivacyKeyRecord) {
		t.Helper()
		s.handleMessage(nil, "provider-a", "session-a", privacyHeartbeat(t, "ready", records))
		// A scheduled probe holds the in-flight marker until it finishes, so
		// once it clears every challenge this heartbeat caused was counted.
		eventually(t, func() bool {
			_, inFlight := s.privacyPostureInFlight.Load(sessionKey("provider-a", "session-a"))
			return !inFlight
		})
	}

	heartbeat([]relayblind.PrivacyKeyRecord{record})
	if got := challenges.Load(); got != 1 {
		t.Fatalf("first advertisement challenges = %d, want 1", got)
	}
	for i := 0; i < 3; i++ {
		heartbeat([]relayblind.PrivacyKeyRecord{record})
		heartbeat(nil)
	}
	if got := challenges.Load(); got != 1 {
		t.Fatalf("unchanged re-advertisements challenged: total = %d, want 1", got)
	}
	heartbeat([]relayblind.PrivacyKeyRecord{rotated})
	if got := challenges.Load(); got != 2 {
		t.Fatalf("rotated key challenges total = %d, want 2", got)
	}
	heartbeat([]relayblind.PrivacyKeyRecord{})
	if n := privacyKeySessions(t, auth, clock); n != 0 {
		t.Fatalf("empty array did not revoke: sessions = %d", n)
	}
	heartbeat([]relayblind.PrivacyKeyRecord{fresh})
	if got := challenges.Load(); got != 3 {
		t.Fatalf("advertisement after revoke challenges total = %d, want 3", got)
	}
}

func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met within 5s")
		}
		time.Sleep(time.Millisecond)
	}
}

func wsPrivacyRecordForKey(t *testing.T, now time.Time, identity ed25519.PrivateKey, keyByte byte) relayblind.PrivacyKeyRecord {
	t.Helper()
	provider, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{keyByte}, 32))
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
	}
}

// SPEC-049-R005: the sweep challenges a session whose key set is unchanged;
// an answered challenge makes it eligible, and an unanswered one (here a
// response arriving after posture_response_timeout_seconds) makes it
// ineligible without quarantine.
func TestPrivacyPostureSweepChallengesUnchangedKeys(t *testing.T) {
	start := time.Unix(1_800_000_000, 0).UTC()
	material := newWSPrivacyMaterial(t, start)
	var clockUnix atomic.Int64
	clockUnix.Store(start.Unix())
	now := func() time.Time { return time.Unix(clockUnix.Load(), 0).UTC() }
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
	reg.RegisterAt(&provider, serverConn, start)
	s := &Server{pool: reg, log: zerolog.Nop(), now: now, privacyAuthority: material.auth}
	sess := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 64)
	go sess.runWriter()
	t.Cleanup(func() { sess.close() })
	s.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), sess)
	challenges := make(chan PrivacyPostureChallenge, 4)
	go func() {
		for {
			payload, _, err := wsutil.ReadServerData(clientConn)
			if err != nil {
				return
			}
			var challenge PrivacyPostureChallenge
			if json.Unmarshal(payload, &challenge) == nil && challenge.Type == "privacy_posture_challenge" {
				challenges <- challenge
			}
		}
	}()
	nextChallenge := func() PrivacyPostureChallenge {
		t.Helper()
		select {
		case challenge := <-challenges:
			return challenge
		case <-time.After(5 * time.Second):
			t.Fatal("sweep sent no posture challenge")
			return PrivacyPostureChallenge{}
		}
	}
	probeDone := func() bool {
		_, inFlight := s.privacyPostureInFlight.Load(sessionKey(provider.ProviderID, provider.AssignedID))
		return !inFlight
	}

	s.runPrivacyPostureSweep()
	first := nextChallenge()
	s.handlePrivacyPostureResponse(provider.ProviderID, provider.AssignedID, material.responseSeq(t, first.Nonce, first.IssuedAtUnix, 1))
	eventually(t, probeDone)
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, now()); !ok {
		t.Fatal("answered sweep challenge did not make the session eligible")
	}

	s.runPrivacyPostureSweep()
	second := nextChallenge()
	clockUnix.Add(int64(material.auth.ResponseTimeout()/time.Second) + 1)
	s.handlePrivacyPostureResponse(provider.ProviderID, provider.AssignedID, material.responseSeq(t, second.Nonce, second.IssuedAtUnix, 2))
	eventually(t, probeDone)
	if _, ok := material.auth.Eligible(provider.ProviderID, provider.AssignedID, material.digest, now()); ok {
		t.Fatal("unanswered sweep challenge left the session eligible")
	}
	if err := material.auth.AcceptPrivacyKeys(context.Background(), provider.ProviderID, provider.AssignedID, []relayblind.PrivacyKeyRecord{material.record}, now()); err != nil {
		t.Fatalf("unanswered challenge quarantined the provider: %v", err)
	}
}

func registerPrivacyTestSession(t *testing.T, reg *pool.Registry, assignedID string, now time.Time) {
	t.Helper()
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close() })
	t.Cleanup(func() { serverConn.Close() })
	reg.RegisterAt(&pool.Provider{
		ProviderID: "provider-a", AssignedID: assignedID, Hostname: "provider.local",
		ModelID: "model-a", ModelParamsB: 7, RAMGB: 16, MaxContextTokens: 4096, MaxConcurrency: 1,
		BinaryVersion: "0.0.0-fixture", Tier: pool.TierPinned, State: pool.StateReady,
	}, serverConn, now)
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
	return m.responseSeq(t, nonce, issued, 0)
}

func (m wsPrivacyMaterial) responseSeq(t *testing.T, nonce string, issued int64, sequence uint64) []byte {
	t.Helper()
	statement := relayblind.PostureStatement{
		Version: relayblind.PrivacyPostureVersion, PrivacyClass: relayblind.PrivacyClassV1,
		ProviderID: "provider-a", AssignedSession: "session-a", Nonce: nonce, Sequence: sequence, IssuedAtUnix: issued,
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
