package ws

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// generateTestSEKey returns a fresh P-256 key pair and its 64-byte raw public key.
func generateTestSEKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate SE key: %v", err)
	}
	pubRaw := make([]byte, 64)
	priv.PublicKey.X.FillBytes(pubRaw[:32])
	priv.PublicKey.Y.FillBytes(pubRaw[32:])
	return priv, pubRaw
}

// signSELiveness signs UTF-8(nonce+timestamp) with the P-256 key and returns
// a base64-encoded DER ECDSA signature (matching the runbook §1.1.B wire format).
func signSELiveness(t *testing.T, priv *ecdsa.PrivateKey, nonce, timestamp string) string {
	t.Helper()
	msg := nonce + timestamp
	digest := sha256.Sum256([]byte(msg))
	r, s, err := ecdsa.Sign(rand.Reader, priv, digest[:])
	if err != nil {
		t.Fatalf("sign SE liveness: %v", err)
	}
	sig, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	if err != nil {
		t.Fatalf("marshal DER sig: %v", err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

// --- verifySELivenessResponse unit tests ---

func TestVerifySELivenessResponseOK(t *testing.T) {
	priv, pubRaw := generateTestSEKey(t)
	s := &Server{log: zerolog.Nop()}
	nonce := "abc-nonce-123"
	ts := "2026-07-08T12:00:00Z"
	sig := signSELiveness(t, priv, nonce, ts)

	resp := SELivenessResponse{
		Type:      "se_liveness_response",
		Version:   1,
		Nonce:     nonce,
		Timestamp: ts,
		PublicKey: base64.StdEncoding.EncodeToString(pubRaw),
		Signature: sig,
	}
	if !s.verifySELivenessResponse(resp, nonce, ts, pubRaw) {
		t.Fatal("expected verification to pass")
	}
}

func TestVerifySELivenessResponseWrongNonce(t *testing.T) {
	priv, pubRaw := generateTestSEKey(t)
	s := &Server{log: zerolog.Nop()}
	nonce := "correct-nonce"
	ts := "2026-07-08T12:00:00Z"
	sig := signSELiveness(t, priv, nonce, ts)

	resp := SELivenessResponse{
		Nonce:     "wrong-nonce",
		Timestamp: ts,
		Signature: sig,
	}
	if s.verifySELivenessResponse(resp, nonce, ts, pubRaw) {
		t.Fatal("expected verification to fail on nonce mismatch")
	}
}

func TestVerifySELivenessResponseWrongTimestamp(t *testing.T) {
	priv, pubRaw := generateTestSEKey(t)
	s := &Server{log: zerolog.Nop()}
	nonce := "nonce-x"
	ts := "2026-07-08T12:00:00Z"
	sig := signSELiveness(t, priv, nonce, ts)

	resp := SELivenessResponse{
		Nonce:     nonce,
		Timestamp: "2026-01-01T00:00:00Z",
		Signature: sig,
	}
	if s.verifySELivenessResponse(resp, nonce, ts, pubRaw) {
		t.Fatal("expected verification to fail on timestamp mismatch")
	}
}

func TestVerifySELivenessResponseBadSignature(t *testing.T) {
	_, pubRaw := generateTestSEKey(t)
	s := &Server{log: zerolog.Nop()}
	nonce := "nonce-y"
	ts := "2026-07-08T12:00:00Z"

	otherPriv, _ := generateTestSEKey(t)
	sig := signSELiveness(t, otherPriv, nonce, ts)

	resp := SELivenessResponse{Nonce: nonce, Timestamp: ts, Signature: sig}
	if s.verifySELivenessResponse(resp, nonce, ts, pubRaw) {
		t.Fatal("expected verification to fail with wrong signing key")
	}
}

func TestVerifySELivenessResponseBadPubkeyLength(t *testing.T) {
	priv, _ := generateTestSEKey(t)
	s := &Server{log: zerolog.Nop()}
	nonce := "nonce-z"
	ts := "2026-07-08T12:00:00Z"
	sig := signSELiveness(t, priv, nonce, ts)

	resp := SELivenessResponse{Nonce: nonce, Timestamp: ts, Signature: sig}
	if s.verifySELivenessResponse(resp, nonce, ts, []byte{0x01, 0x02}) {
		t.Fatal("expected verification to fail on short pubkey")
	}
}

// --- pool.Registry.RecordSELivenessResult tests ---

func TestRecordSELivenessResultPassResetsFailCount(t *testing.T) {
	reg := pool.NewRegistry(nil)
	p := seTestProvider("prov-1")
	p.SEPublicKey = make([]byte, 64)
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()
	reg.RegisterAt(&p, c1, time.Now())

	now := time.Now()
	for range 2 {
		reg.RecordSELivenessResult("prov-1", p.AssignedID, false, now, 3)
	}
	result := reg.RecordSELivenessResult("prov-1", p.AssignedID, true, now, 3)
	if !result.Current || !result.Passed || result.FailCount != 0 {
		t.Fatalf("expected pass result with FailCount=0: %+v", result)
	}
	snap := providerSnapshot(reg, "prov-1")
	if snap == nil {
		t.Fatal("provider not found")
	}
	if snap.SELivenessFailCount != 0 {
		t.Fatalf("FailCount = %d, want 0", snap.SELivenessFailCount)
	}
}

func TestRecordSELivenessResultThreeFailuresMarkStale(t *testing.T) {
	reg := pool.NewRegistry(nil)
	p := seTestProvider("prov-2")
	p.SEPublicKey = make([]byte, 64)
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()
	reg.RegisterAt(&p, c1, time.Now())

	now := time.Now()
	var lastResult pool.SELivenessResult
	for i := range 3 {
		lastResult = reg.RecordSELivenessResult("prov-2", p.AssignedID, false, now, 3)
		if i < 2 && lastResult.Stale {
			t.Fatalf("stale set too early at failure %d", i+1)
		}
	}
	if !lastResult.Stale {
		t.Fatal("expected Stale=true after 3 consecutive failures")
	}
	if lastResult.FailCount != 3 {
		t.Fatalf("FailCount = %d, want 3", lastResult.FailCount)
	}
	snap := providerSnapshot(reg, "prov-2")
	if snap == nil {
		t.Fatal("provider not found")
	}
	if snap.AttestationStatus != pool.AttestationStatusStale {
		t.Fatalf("AttestationStatus = %q, want attestation_stale", snap.AttestationStatus)
	}
}

func TestRecordSELivenessResultUnknownProvider(t *testing.T) {
	reg := pool.NewRegistry(nil)
	result := reg.RecordSELivenessResult("no-such-provider", "no-such-session", false, time.Now(), 3)
	if result.Current {
		t.Fatal("expected Current=false for unknown provider")
	}
}

// --- deliverSELivenessResponse delivery test ---

func TestDeliverSELivenessResponseRouted(t *testing.T) {
	s := newSELivenessTestServer(t)
	ch := make(chan SELivenessResponse, 1)
	s.seLivenessChans.Store("prov/sess", ch)

	resp := SELivenessResponse{Nonce: "nn", Timestamp: "tt", Signature: "ss"}
	s.deliverSELivenessResponse("prov", "sess", resp)

	select {
	case got := <-ch:
		if got.Nonce != "nn" {
			t.Fatalf("nonce = %q, want nn", got.Nonce)
		}
	default:
		t.Fatal("response not delivered to channel")
	}
}

func TestDeliverSELivenessResponseNoProbeIgnored(t *testing.T) {
	s := newSELivenessTestServer(t)
	s.deliverSELivenessResponse("unknown", "sess", SELivenessResponse{})
}

// --- handleSELivenessResponse dispatch ---

func TestHandleSELivenessResponseDispatch(t *testing.T) {
	s := newSELivenessTestServer(t)
	ch := make(chan SELivenessResponse, 1)
	s.seLivenessChans.Store("prov/sess", ch)

	payload, _ := json.Marshal(SELivenessResponse{
		Type:      "se_liveness_response",
		Version:   1,
		Nonce:     "mynonce",
		Timestamp: "myts",
		Signature: "mysig",
	})
	s.handleSELivenessResponse("prov", "sess", payload)

	select {
	case got := <-ch:
		if got.Nonce != "mynonce" {
			t.Fatalf("nonce = %q, want mynonce", got.Nonce)
		}
	default:
		t.Fatal("response not dispatched")
	}
}

// --- Integration: probe passes with valid signed response ---
//
// TestSELivenessProbePassesAndUpdatesTimestamp exercises the full probe path:
// challenge is sent over a real net.Pipe WS connection; the client side reads
// the frame, signs the nonce+timestamp with the test EC key, and delivers the
// response via deliverSELivenessResponse (simulating handleMessage dispatch).
func TestSELivenessProbePassesAndUpdatesTimestamp(t *testing.T) {
	priv, pubRaw := generateTestSEKey(t)

	reg := pool.NewRegistry(nil)
	p := seTestProvider("se-prov")
	p.SEPublicKey = pubRaw
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { clientConn.Close() })
	t.Cleanup(func() { serverConn.Close() })
	reg.RegisterAt(&p, serverConn, time.Now())

	cfg := config.Default()
	cfg.Auth.OperatorKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	cfg.Pool.CanaryEnabled = false
	cfg.Tier2.SELivenessTimeoutS = 5

	s := newSELivenessServerWithRegistry(t, cfg, reg)

	// Plant the session with runWriter running so session.send() succeeds.
	sess := newProviderSession(p.ProviderID, p.AssignedID, serverConn, 64)
	go sess.runWriter()
	t.Cleanup(func() { sess.close() })
	s.sessions.Store(p.ProviderID+"/"+p.AssignedID, sess)

	// Client goroutine: read WS frame, extract challenge JSON, deliver response.
	clientDone := make(chan error, 1)
	go func() {
		payload, op, err := wsutil.ReadServerData(clientConn)
		if err != nil {
			clientDone <- err
			return
		}
		if op != gobwas.OpText {
			clientDone <- nil
			return
		}
		var challenge SELivenessChallenge
		if err := json.Unmarshal(payload, &challenge); err != nil {
			clientDone <- err
			return
		}
		if challenge.Type != "se_liveness_challenge" {
			clientDone <- nil
			return
		}
		sig := signSELiveness(t, priv, challenge.Nonce, challenge.Timestamp)
		s.deliverSELivenessResponse(p.ProviderID, p.AssignedID, SELivenessResponse{
			Type:      "se_liveness_response",
			Version:   1,
			Nonce:     challenge.Nonce,
			Timestamp: challenge.Timestamp,
			Signature: sig,
		})
		clientDone <- nil
	}()

	s.runSELivenessProbe(pool.Provider{
		ProviderID:  p.ProviderID,
		AssignedID:  p.AssignedID,
		SEPublicKey: pubRaw,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	select {
	case err := <-clientDone:
		if err != nil {
			t.Fatalf("client goroutine error: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("client goroutine timed out")
	}

	snap := providerSnapshot(reg, p.ProviderID)
	if snap == nil {
		t.Fatal("provider not found in snapshot")
	}
	if snap.LastSELivenessAt == nil {
		t.Fatal("LastSELivenessAt was not set after a passing probe")
	}
	if snap.SELivenessFailCount != 0 {
		t.Fatalf("FailCount = %d, want 0 after pass", snap.SELivenessFailCount)
	}
}

// TestSELivenessProbeThreeFailuresDegrade verifies that 3 consecutive timeouts
// set AttestationStatusStale on the provider.
func TestSELivenessProbeThreeFailuresDegrade(t *testing.T) {
	_, pubRaw := generateTestSEKey(t)

	reg := pool.NewRegistry(nil)
	p := seTestProvider("stale-prov")
	p.SEPublicKey = pubRaw
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { serverConn.Close() })
	t.Cleanup(func() { clientConn.Close() })
	reg.RegisterAt(&p, serverConn, time.Now())

	cfg := config.Default()
	cfg.Auth.OperatorKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	cfg.Pool.CanaryEnabled = false
	cfg.Tier2.SELivenessTimeoutS = 1 // short timeout so failures are fast
	cfg.Tier2.SELivenessMaxFailures = 3

	s := newSELivenessServerWithRegistry(t, cfg, reg)

	provSnap := pool.Provider{
		ProviderID:  p.ProviderID,
		AssignedID:  p.AssignedID,
		SEPublicKey: pubRaw,
	}

	for i := range 3 {
		// Create a fresh session for each probe attempt (previous may be closed on stale).
		sConn, cConn := net.Pipe()
		sess := newProviderSession(p.ProviderID, p.AssignedID, sConn, 64)
		go sess.runWriter()
		s.sessions.Store(p.ProviderID+"/"+p.AssignedID, sess)
		// Drain the client side so WS frame writes succeed.
		go func() {
			var buf [4096]byte
			for {
				_, err := cConn.Read(buf[:])
				if err != nil {
					return
				}
			}
		}()
		// Don't reply → probe times out → failure recorded.
		s.runSELivenessProbe(provSnap)
		sess.close()
		sConn.Close()
		cConn.Close()
		_ = i
	}

	snap := providerSnapshot(reg, p.ProviderID)
	if snap == nil {
		t.Fatal("provider not found in snapshot after 3 failures")
	}
	if snap.AttestationStatus != pool.AttestationStatusStale {
		t.Fatalf("AttestationStatus = %q, want attestation_stale", snap.AttestationStatus)
	}
}

// --- helpers ---

func seTestProvider(providerID string) pool.Provider {
	return pool.Provider{
		ProviderID:       providerID,
		AssignedID:       "assigned-" + providerID,
		Hostname:         "provider.local",
		ModelID:          "mlx-community/test-model",
		ModelParamsB:     7.0,
		RAMGB:            16,
		MaxContextTokens: 4096,
		MaxConcurrency:   1,
		BinaryVersion:    "0.1.0",
		Tier:             pool.TierPinned,
		State:            pool.StateReady,
	}
}

func providerSnapshot(reg *pool.Registry, providerID string) *pool.Provider {
	for _, p := range reg.Snapshot() {
		if p.ProviderID == providerID {
			clone := p
			return &clone
		}
	}
	return nil
}

func newSELivenessTestServer(t *testing.T) *Server {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.OperatorKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	return &Server{
		cfg:   cfg,
		tier2: cfg.Tier2,
		log:   zerolog.Nop(),
		now:   func() time.Time { return time.Now().UTC() },
	}
}

func newSELivenessServerWithRegistry(t *testing.T, cfg config.Config, reg *pool.Registry) *Server {
	t.Helper()
	return &Server{
		cfg:   cfg,
		tier2: cfg.Tier2,
		pool:  reg,
		log:   zerolog.Nop(),
		now:   func() time.Time { return time.Now().UTC() },
	}
}
