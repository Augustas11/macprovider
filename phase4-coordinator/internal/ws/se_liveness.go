package ws

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// seLivenessInterval returns the configured interval between SE liveness challenges.
func (s *Server) seLivenessInterval() time.Duration {
	s.tier2Mu.RLock()
	seconds := s.tier2.SELivenessIntervalS
	s.tier2Mu.RUnlock()
	if seconds <= 0 {
		seconds = 300
	}
	return time.Duration(seconds) * time.Second
}

// seLivenessTimeout returns the configured timeout for awaiting an SE liveness response.
func (s *Server) seLivenessTimeout() time.Duration {
	s.tier2Mu.RLock()
	seconds := s.tier2.SELivenessTimeoutS
	s.tier2Mu.RUnlock()
	if seconds <= 0 {
		seconds = 30
	}
	return time.Duration(seconds) * time.Second
}

// seLivenessMaxFailures returns the configured consecutive failure count that
// triggers attestation_stale / session close.
func (s *Server) seLivenessMaxFailures() int {
	s.tier2Mu.RLock()
	n := s.tier2.SELivenessMaxFailures
	s.tier2Mu.RUnlock()
	if n <= 0 {
		n = 3
	}
	return n
}

// runSELivenessLoop is the main periodic goroutine. It sweeps all SE-attested
// providers every seLivenessInterval and fires a per-provider probe goroutine
// (at most one in-flight per provider).
func (s *Server) runSELivenessLoop() {
	ticker := time.NewTicker(s.seLivenessInterval())
	defer ticker.Stop()
	for range ticker.C {
		s.runSELivenessSweep()
	}
}

func (s *Server) runSELivenessSweep() {
	for _, provider := range s.pool.Snapshot() {
		if len(provider.SEPublicKey) == 0 {
			continue
		}
		key := sessionKey(provider.ProviderID, provider.AssignedID)
		if _, loaded := s.seLivenessInFlight.LoadOrStore(key, struct{}{}); loaded {
			continue
		}
		go func(p pool.Provider, key string) {
			defer s.seLivenessInFlight.Delete(key)
			s.runSELivenessProbe(p)
		}(provider, key)
	}
}

// runSELivenessProbe sends a single SE liveness challenge to one provider and
// waits for a verified response.
func (s *Server) runSELivenessProbe(provider pool.Provider) {
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}

	nonceBytes, err := randomBytes(32)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("se_liveness: nonce generation failed")
		return
	}
	nonce := base64.URLEncoding.EncodeToString(nonceBytes)
	timestamp := s.now().UTC().Format(time.RFC3339)

	ch := make(chan SELivenessResponse, 1)
	pendingKey := sessionKey(provider.ProviderID, provider.AssignedID)
	s.seLivenessChans.Store(pendingKey, ch)
	defer s.seLivenessChans.Delete(pendingKey)

	raw, err := json.Marshal(SELivenessChallenge{
		Type:      "se_liveness_challenge",
		Version:   1,
		Nonce:     nonce,
		Timestamp: timestamp,
	})
	if err != nil {
		return
	}
	if err := session.send(raw); err != nil {
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("se_liveness: challenge send failed")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), s.seLivenessTimeout())
	defer cancel()

	var passed bool
	select {
	case resp := <-ch:
		passed = s.verifySELivenessResponse(resp, nonce, timestamp, provider.SEPublicKey)
		if !passed {
			s.log.Warn().
				Str("provider_id", provider.ProviderID).
				Msg("se_liveness: response verification failed")
		}
	case <-ctx.Done():
		s.log.Warn().
			Str("provider_id", provider.ProviderID).
			Msg("se_liveness: response timed out")
	}

	result := s.pool.RecordSELivenessResult(
		provider.ProviderID, provider.AssignedID,
		passed, s.now(), s.seLivenessMaxFailures(),
	)
	if !result.Current {
		return
	}
	if passed {
		s.log.Debug().
			Str("provider_id", provider.ProviderID).
			Msg("se_liveness: challenge passed")
		return
	}
	s.log.Warn().
		Str("provider_id", provider.ProviderID).
		Int("fail_count", result.FailCount).
		Bool("stale", result.Stale).
		Msg("se_liveness: challenge failed")
	if result.Stale {
		// Max consecutive failures reached: attestation marked stale, close session.
		if sess, ok := s.sessionFor(provider.ProviderID, provider.AssignedID); ok {
			s.closeSession(sess, CloseTier2AttestationFailed, "se_liveness_stale")
		}
	}
}

// verifySELivenessResponse validates the nonce/timestamp echo and ES256
// signature over UTF-8(nonce+timestamp) using the stored SE public key.
// sePubKey must be 64 raw bytes (P-256 X||Y, no 0x04 prefix).
func (s *Server) verifySELivenessResponse(
	resp SELivenessResponse,
	expectedNonce, expectedTimestamp string,
	sePubKey []byte,
) bool {
	if resp.Nonce != expectedNonce {
		return false
	}
	if resp.Timestamp != expectedTimestamp {
		return false
	}
	if len(sePubKey) != 64 {
		return false
	}
	x := new(big.Int).SetBytes(sePubKey[:32])
	y := new(big.Int).SetBytes(sePubKey[32:])
	pub := &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}

	sigDER, err := base64.StdEncoding.DecodeString(resp.Signature)
	if err != nil {
		return false
	}
	var ecSig struct{ R, S *big.Int }
	if rest, err := asn1.Unmarshal(sigDER, &ecSig); err != nil || len(rest) > 0 {
		return false
	}

	// Message is UTF-8(nonce+timestamp); digest with SHA-256.
	msg := resp.Nonce + resp.Timestamp
	digest := sha256.Sum256([]byte(msg))
	return ecdsa.Verify(pub, digest[:], ecSig.R, ecSig.S)
}

// deliverSELivenessResponse routes an incoming se_liveness_response frame to
// the probe goroutine waiting for this provider's challenge reply.
// Called from handleMessage when envelope.Type == "se_liveness_response".
func (s *Server) deliverSELivenessResponse(providerID, assignedID string, resp SELivenessResponse) {
	key := sessionKey(providerID, assignedID)
	v, ok := s.seLivenessChans.Load(key)
	if !ok {
		s.log.Debug().Str("provider_id", providerID).Msg("se_liveness: unexpected response (no probe in flight)")
		return
	}
	ch, ok := v.(chan SELivenessResponse)
	if !ok {
		return
	}
	select {
	case ch <- resp:
	default:
		// Channel full means probe already received a response or timed out.
	}
}
