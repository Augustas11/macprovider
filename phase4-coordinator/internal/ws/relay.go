package ws

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/gobwas/ws/wsutil"
)

var (
	ErrRelayBackpressure = errors.New("provider websocket write buffer full")
	ErrRelayNAKFallback  = errors.New("provider rejected ws-tunneled inference")
	ErrRelayClosed       = errors.New("provider websocket closed")
	ErrRelayTimeout      = errors.New("provider websocket inference timed out")
	ErrRelayAEADFailed   = errors.New("tier2 aead decrypt failed")
)

const retiredRelayRequestTTL = 5 * time.Minute

type RelayStream struct {
	RequestID string
	Chunks    <-chan InferenceResponseChunk
	Done      <-chan InferenceResponseEnd
	Errors    <-chan error
	cancel    func(string)
}

func (r *RelayStream) Cancel(reason string) {
	if r.cancel != nil {
		r.cancel(reason)
	}
}

type conversationKeyContextKey struct{}

func ContextWithConversationKey(ctx context.Context, key string) context.Context {
	key = strings.TrimSpace(key)
	if key == "" {
		return ctx
	}
	return context.WithValue(ctx, conversationKeyContextKey{}, key)
}

func ConversationKeyFromContext(ctx context.Context) string {
	key, _ := ctx.Value(conversationKeyContextKey{}).(string)
	return strings.TrimSpace(key)
}

type relayActive struct {
	requestID string
	stream    bool
	chunks    chan InferenceResponseChunk
	done      chan InferenceResponseEnd
	errs      chan error
}

type retiredRelayRequest struct {
	stream    bool
	retiredAt time.Time
}

type providerSession struct {
	providerID string
	assignedID string
	conn       net.Conn
	writeCh    chan providerFrame
	writeLimit time.Duration
	closeOnce  sync.Once
	writeMu    sync.Mutex
	closed     bool
	activeMu   sync.Mutex
	active     map[string]*relayActive
	retired    map[string]retiredRelayRequest
	httpOnly   bool
	tier2Mu    sync.Mutex
	tier2      *pool.Tier2Session
}

// providerFrame is the unit of work consumed by runWriter. Two kinds exist:
//
//   - text payloads (raw == false): JSON-ish coordinator → provider control
//     messages (hello_ack, auth_response, inference_request, cancel_request,
//     drain, etc.); written via wsutil.WriteServerText.
//
//   - pre-baked raw WS frames (raw == true): reactive PONG / Close-echo replies
//     and server-initiated Close frames. Captured upstream as the exact bytes
//     gobwas would have emitted (header + body) and written via a single
//     conn.Write so they cannot interleave with a text frame.
//
// The single runWriter goroutine has exclusive ownership of all post-handshake
// conn writes; every other caller MUST go through send / enqueueRaw.
type providerFrame struct {
	raw     bool
	payload []byte
}

type encryptedInferenceRequest struct {
	Type       string                     `json:"type"`
	RequestID  string                     `json:"request_id"`
	Stream     bool                       `json:"stream"`
	Encrypted  bool                       `json:"encrypted"`
	Enc        tier2.AEADEnvelopeBody     `json:"enc"`
	Settlement *SettlementReceiptMetadata `json:"settlement,omitempty"`
}

type encryptedInferencePlaintext struct {
	Type            string `json:"type"`
	Body            string `json:"body"`
	ConversationKey string `json:"conversation_key,omitempty"`
}

type encryptedInferenceResponseChunk struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id,omitempty"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

type encryptedInferenceResponseEnd struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id,omitempty"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

func newProviderSession(providerID, assignedID string, conn net.Conn, bufferSize int, writeLimits ...time.Duration) *providerSession {
	if bufferSize <= 0 {
		bufferSize = 64
	}
	writeLimit := 10 * time.Second
	if len(writeLimits) > 0 && writeLimits[0] > 0 {
		writeLimit = writeLimits[0]
	}
	return &providerSession{
		providerID: providerID,
		assignedID: assignedID,
		conn:       conn,
		writeCh:    make(chan providerFrame, bufferSize),
		writeLimit: writeLimit,
		active:     map[string]*relayActive{},
		retired:    map[string]retiredRelayRequest{},
	}
}

func (ps *providerSession) runWriter() {
	for f := range ps.writeCh {
		_ = ps.conn.SetWriteDeadline(time.Now().Add(ps.writeLimit))
		var err error
		if f.raw {
			// Single Write of an already-framed control reply. The header and
			// body were assembled into f.payload upstream so they cannot be
			// split across goroutines mid-frame.
			_, err = ps.conn.Write(f.payload)
		} else {
			err = wsutil.WriteServerText(ps.conn, f.payload)
		}
		if err != nil {
			ps.failAll(ErrRelayClosed)
			_ = ps.conn.Close()
			return
		}
	}
}

func (ps *providerSession) close() {
	ps.closeOnce.Do(func() {
		ps.writeMu.Lock()
		ps.closed = true
		close(ps.writeCh)
		ps.writeMu.Unlock()
		ps.failAll(ErrRelayClosed)
	})
}

func (ps *providerSession) send(payload []byte) error {
	return ps.enqueueFrame(providerFrame{payload: payload})
}

// enqueueRaw queues a pre-baked WS frame (header + body, already assembled by
// the caller) for runWriter to emit with a single conn.Write. Used by the
// post-handshake control-frame handler and by server-initiated Close paths so
// reactive PONG / Close / shutdown frames cannot interleave with an in-flight
// text frame from the writer.
func (ps *providerSession) enqueueRaw(rawFrame []byte) error {
	return ps.enqueueFrame(providerFrame{raw: true, payload: rawFrame})
}

func (ps *providerSession) enqueueFrame(f providerFrame) error {
	ps.writeMu.Lock()
	defer ps.writeMu.Unlock()
	if ps.closed {
		return ErrRelayClosed
	}
	select {
	case ps.writeCh <- f:
		return nil
	default:
		return ErrRelayBackpressure
	}
}

func (ps *providerSession) addActive(requestID string, maxConcurrency int, stream bool) (*relayActive, error) {
	ps.activeMu.Lock()
	defer ps.activeMu.Unlock()
	if ps.httpOnly {
		return nil, ErrRelayNAKFallback
	}
	if _, exists := ps.active[requestID]; exists {
		return nil, errors.New("duplicate active request_id")
	}
	if maxConcurrency > 0 && len(ps.active) >= maxConcurrency {
		return nil, ErrRelayBackpressure
	}
	active := &relayActive{
		requestID: requestID,
		stream:    stream,
		chunks:    make(chan InferenceResponseChunk, 256),
		done:      make(chan InferenceResponseEnd, 1),
		errs:      make(chan error, 1),
	}
	ps.active[requestID] = active
	return active, nil
}

func (ps *providerSession) removeActive(requestID string) (*relayActive, bool) {
	ps.activeMu.Lock()
	defer ps.activeMu.Unlock()
	active, ok := ps.active[requestID]
	if ok {
		delete(ps.active, requestID)
		ps.markRetiredLocked(active, time.Now())
	}
	return active, ok
}

func (ps *providerSession) markRetiredLocked(active *relayActive, now time.Time) {
	if active == nil || strings.TrimSpace(active.requestID) == "" {
		return
	}
	cutoff := now.Add(-retiredRelayRequestTTL)
	for id, retired := range ps.retired {
		if retired.retiredAt.Before(cutoff) {
			delete(ps.retired, id)
		}
	}
	ps.retired[active.requestID] = retiredRelayRequest{
		stream:    active.stream,
		retiredAt: now,
	}
}

func (ps *providerSession) recentlyRetired(requestID string) (retiredRelayRequest, bool) {
	ps.activeMu.Lock()
	defer ps.activeMu.Unlock()
	retired, ok := ps.retired[requestID]
	if !ok {
		return retiredRelayRequest{}, false
	}
	if time.Since(retired.retiredAt) > retiredRelayRequestTTL {
		delete(ps.retired, requestID)
		return retiredRelayRequest{}, false
	}
	return retired, true
}

func (ps *providerSession) failActive(requestID string, err error) {
	active, ok := ps.removeActive(requestID)
	if !ok {
		return
	}
	select {
	case active.errs <- err:
	default:
	}
	close(active.chunks)
}

func (ps *providerSession) failActiveOrAll(requestID string, err error) {
	if strings.TrimSpace(requestID) == "" {
		ps.failAll(err)
		return
	}
	if _, ok := ps.activeFor(requestID); !ok {
		ps.failAll(err)
		return
	}
	ps.failActive(requestID, err)
}

func (ps *providerSession) cancelActive(requestID string, reason string, err error) {
	active, ok := ps.removeActive(requestID)
	if !ok {
		return
	}
	b, _ := json.Marshal(CancelRequest{Type: "cancel_request", RequestID: requestID, Reason: reason})
	_ = ps.send(b)
	if err != nil {
		select {
		case active.errs <- err:
		default:
		}
	}
	close(active.chunks)
}

func (ps *providerSession) activeFor(requestID string) (*relayActive, bool) {
	ps.activeMu.Lock()
	defer ps.activeMu.Unlock()
	active, ok := ps.active[requestID]
	return active, ok
}

func (ps *providerSession) hasActive() bool {
	ps.activeMu.Lock()
	defer ps.activeMu.Unlock()
	return len(ps.active) > 0
}

func (ps *providerSession) failAll(err error) {
	ps.activeMu.Lock()
	active := make([]*relayActive, 0, len(ps.active))
	for requestID, a := range ps.active {
		active = append(active, a)
		delete(ps.active, requestID)
	}
	ps.activeMu.Unlock()
	for _, a := range active {
		select {
		case a.errs <- err:
		default:
		}
		close(a.chunks)
	}
}

func (ps *providerSession) useTier2Session(session *pool.Tier2Session) {
	if session == nil {
		return
	}
	ps.tier2Mu.Lock()
	if ps.tier2 == nil {
		ps.tier2 = session
	}
	ps.tier2Mu.Unlock()
}

func (ps *providerSession) hasTier2Session() bool {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	return ps.tier2 != nil
}

func (ps *providerSession) sealInferenceRequest(provider pool.Provider, requestID string, body []byte, stream bool, settlement *SettlementReceiptMetadata, conversationKey string) ([]byte, error) {
	ps.tier2Mu.Lock()
	session := ps.tier2
	if session == nil {
		ps.tier2Mu.Unlock()
		msg := InferenceRequest{
			Type:            "inference_request",
			RequestID:       requestID,
			Stream:          stream,
			Body:            string(body),
			Settlement:      settlement,
			ConversationKey: conversationKey,
		}
		return json.Marshal(msg)
	}
	defer ps.tier2Mu.Unlock()
	if session.C2PCounter == ^uint64(0) {
		return nil, errors.New("tier2 c2p frame counter exhausted")
	}
	seq := session.C2PCounter
	aad := tier2.AEADFrameAAD{
		Type:       "inference_request",
		Direction:  "c2p",
		RequestID:  requestID,
		Stream:     stream,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	plaintext, err := json.Marshal(encryptedInferencePlaintext{
		Type:            "inference_request_plaintext",
		Body:            string(body),
		ConversationKey: strings.TrimSpace(conversationKey),
	})
	if err != nil {
		return nil, err
	}
	envelope, err := tier2.SealPillarBFrame(session.C2PKey, session.C2PNonceBase, session.KeyID, seq, aad, plaintext)
	if err != nil {
		return nil, err
	}
	session.C2PCounter++
	return json.Marshal(encryptedInferenceRequest{
		Type:       "inference_request",
		RequestID:  requestID,
		Stream:     stream,
		Encrypted:  true,
		Enc:        envelope.Enc,
		Settlement: settlement,
	})
}

func (ps *providerSession) openInferenceChunk(providerID, assignedID string, active *relayActive, envelope tier2.AEADEnvelope) (InferenceResponseChunk, error) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return InferenceResponseChunk{}, errors.New("encrypted chunk for provider without tier2 session")
	}
	if ps.tier2.P2CCounter == ^uint64(0) {
		return InferenceResponseChunk{}, errors.New("tier2 p2c frame counter exhausted")
	}
	seq := ps.tier2.P2CCounter
	expectedAAD := tier2.AEADFrameAAD{
		Type:       "inference_response_chunk",
		Direction:  "p2c",
		RequestID:  active.requestID,
		Stream:     active.stream,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        seq,
	}
	plaintext, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, expectedAAD, envelope)
	if err != nil {
		return InferenceResponseChunk{}, err
	}
	ps.tier2.P2CCounter++
	return InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: active.requestID,
		Seq:       int(seq),
		Data:      string(plaintext),
	}, nil
}

func (ps *providerSession) openInferenceEnd(providerID, assignedID string, active *relayActive, envelope tier2.AEADEnvelope) (InferenceResponseEnd, error) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return InferenceResponseEnd{}, errors.New("encrypted end for provider without tier2 session")
	}
	if ps.tier2.P2CCounter == ^uint64(0) {
		return InferenceResponseEnd{}, errors.New("tier2 p2c frame counter exhausted")
	}
	seq := ps.tier2.P2CCounter
	expectedAAD := tier2.AEADFrameAAD{
		Type:       "inference_response_end",
		Direction:  "p2c",
		RequestID:  active.requestID,
		Stream:     active.stream,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        seq,
	}
	plaintext, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, expectedAAD, envelope)
	if err != nil {
		return InferenceResponseEnd{}, err
	}
	ps.tier2.P2CCounter++
	var end InferenceResponseEnd
	if err := json.Unmarshal(plaintext, &end); err != nil {
		return InferenceResponseEnd{}, err
	}
	return end, nil
}

func (ps *providerSession) consumeRetiredEncryptedFrame(providerID, assignedID string, retired retiredRelayRequest, expectedType, expectedRequestID string, aad tier2.AEADFrameAAD, envelope tier2.AEADEnvelope) error {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return errors.New("encrypted frame for provider without tier2 session")
	}
	if ps.tier2.P2CCounter == ^uint64(0) {
		return errors.New("tier2 p2c frame counter exhausted")
	}
	if aad.Type != expectedType {
		return errors.New("tier2 retired frame type mismatch")
	}
	if aad.Direction != "p2c" {
		return errors.New("tier2 retired frame direction mismatch")
	}
	if aad.RequestID != expectedRequestID {
		return errors.New("tier2 retired frame request_id mismatch")
	}
	if aad.Stream != retired.stream {
		return errors.New("tier2 retired frame stream mismatch")
	}
	seq := ps.tier2.P2CCounter
	expectedAAD := tier2.AEADFrameAAD{
		Type:       expectedType,
		Direction:  "p2c",
		RequestID:  expectedRequestID,
		Stream:     retired.stream,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        seq,
	}
	if _, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, expectedAAD, envelope); err != nil {
		return err
	}
	ps.tier2.P2CCounter++
	return nil
}

func (ps *providerSession) markTier2RequestDispatched() {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 != nil {
		ps.tier2.RequestsDispatched++
	}
}

func (ps *providerSession) tier2RekeyReason(now time.Time, cfg config.Tier2Config) (string, bool) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return "", false
	}
	if cfg.EncryptedLegRekeyAfterRequests > 0 && ps.tier2.RequestsDispatched >= uint64(cfg.EncryptedLegRekeyAfterRequests) {
		return "request_threshold", true
	}
	if cfg.EncryptedLegRekeyAfterSeconds > 0 && !ps.tier2.StartedAt.IsZero() {
		deadline := ps.tier2.StartedAt.Add(time.Duration(cfg.EncryptedLegRekeyAfterSeconds) * time.Second)
		if !now.Before(deadline) {
			return "age_threshold", true
		}
	}
	return "", false
}

func (s *Server) closeProviderForTier2Rekey(session *providerSession, providerID, assignedID, requestID, reason string) {
	tier2.LogAEADRekey(s.log, providerID, assignedID, requestID, reason)
	s.pool.MarkState(providerID, assignedID, pool.StateUnavailable)
	s.sessions.Delete(sessionKey(providerID, assignedID))
	_ = session.conn.Close()
	session.close()
}

func (s *Server) closeProviderForTier2AEADFailure(session *providerSession, providerID, assignedID, requestID, reason string) {
	tier2.LogAEADDecryptFailed(s.log, providerID, assignedID, requestID, reason)
	tier2.LogEncryptedLegSessionClosed(s.log, providerID, assignedID, requestID, "aead_decrypt_failed")
	session.failActiveOrAll(requestID, ErrRelayAEADFailed)
	s.pool.MarkState(providerID, assignedID, pool.StateUnavailable)
	s.sessions.Delete(sessionKey(providerID, assignedID))
	_ = session.conn.Close()
	session.close()
}

func (s *Server) DispatchInference(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*RelayStream, error) {
	return s.dispatchInference(ctx, provider, requestID, body, stream, nil)
}

func (s *Server) DispatchInferenceWithSettlement(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool, settlement *SettlementReceiptMetadata) (*RelayStream, error) {
	return s.dispatchInference(ctx, provider, requestID, body, stream, settlement)
}

func (s *Server) dispatchInference(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool, settlementMetadata *SettlementReceiptMetadata) (*RelayStream, error) {
	if !strings.HasPrefix(requestID, "req-") {
		requestID = "req-" + requestID
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return nil, ErrRelayClosed
	}
	if provider.EncryptedLeg {
		session.useTier2Session(provider.Tier2Session)
		if reason, ok := session.tier2RekeyReason(s.now(), s.tier2Config()); ok {
			if session.hasActive() {
				return nil, ErrRelayBackpressure
			}
			s.closeProviderForTier2Rekey(session, provider.ProviderID, provider.AssignedID, requestID, reason)
			return nil, ErrRelayClosed
		}
	}
	active, err := session.addActive(requestID, provider.MaxConcurrency, stream)
	if err != nil {
		return nil, err
	}
	payload, err := session.sealInferenceRequest(provider, requestID, body, stream, settlementMetadata, ConversationKeyFromContext(ctx))
	if err != nil {
		session.removeActive(requestID)
		return nil, err
	}
	if err := session.send(payload); err != nil {
		session.removeActive(requestID)
		return nil, err
	}
	if provider.EncryptedLeg {
		session.markTier2RequestDispatched()
	}
	cancel := func(reason string) {
		if reason == "" {
			reason = "buyer_disconnected"
		}
		session.cancelActive(requestID, reason, nil)
	}
	go func() {
		<-ctx.Done()
		switch {
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			session.cancelActive(requestID, "timeout", ErrRelayTimeout)
		default:
			session.cancelActive(requestID, "buyer_disconnected", ErrRelayClosed)
		}
	}()
	return &RelayStream{
		RequestID: requestID,
		Chunks:    active.chunks,
		Done:      active.done,
		Errors:    active.errs,
		cancel:    cancel,
	}, nil
}

func (s *Server) handleInferenceChunk(providerID, assignedID string, payload []byte) {
	var envelope encryptedInferenceResponseChunk
	if err := json.Unmarshal(payload, &envelope); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_chunk")
		return
	}
	// SPEC-002 v1.5.1 R-2 / issue #197 R6 code: reject control-character
	// payloads in envelope.RequestID and decoded AAD request_id BEFORE any
	// log statement or tier2 log helper call. Otherwise a malicious
	// provider can route through the encrypted-frame failure paths
	// (closeProviderForTier2AEADFailure, LogAEADDecryptFailed,
	// LogEncryptedLegSessionClosed) and reach structured logs with raw
	// C1/CSI before the post-parse containsControlChar check fires.
	if containsControlChar(envelope.RequestID) {
		s.log.Warn().Str("provider_id", providerID).Msg("inference_response_chunk envelope.request_id contains control chars; dropping")
		return
	}
	session, ok := s.sessionFor(providerID, assignedID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("request_id", envelope.RequestID).Msg("chunk from unknown provider session")
		return
	}
	var chunk InferenceResponseChunk
	if envelope.Encrypted {
		aad, _, err := tier2.DecodeAEADAAD(envelope.Enc.AAD)
		if err != nil {
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, envelope.RequestID, err.Error())
			return
		}
		requestID := aad.RequestID
		if requestID == "" {
			requestID = envelope.RequestID
		}
		if containsControlChar(requestID) {
			s.log.Warn().Str("provider_id", providerID).Msg("encrypted inference_response_chunk AAD request_id contains control chars; dropping")
			return
		}
		active, ok := session.activeFor(requestID)
		if !ok {
			if retired, ok := session.recentlyRetired(requestID); ok {
				if err := session.consumeRetiredEncryptedFrame(providerID, assignedID, retired, "inference_response_chunk", requestID, aad, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc}); err != nil {
					s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, err.Error())
					return
				}
				s.log.Warn().Str("provider_id", providerID).Str("request_id", requestID).Msg("late encrypted inference_response_chunk for retired request dropped")
				return
			}
			s.log.Warn().Str("provider_id", providerID).Str("request_id", requestID).Msg("unknown encrypted inference_response_chunk request_id")
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, "unknown encrypted inference_response_chunk request_id")
			return
		}
		chunk, err = session.openInferenceChunk(providerID, assignedID, active, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc})
		if err != nil {
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, err.Error())
			return
		}
	} else if session.hasTier2Session() {
		requestID := envelope.RequestID
		if requestID == "" {
			requestID = "unknown"
		}
		tier2.LogAEADDecryptFailed(s.log, providerID, assignedID, requestID, "tier2 encrypted response chunk required")
		tier2.LogEncryptedLegSessionClosed(s.log, providerID, assignedID, requestID, "unencrypted_tier2_frame")
		session.failActiveOrAll(envelope.RequestID, ErrRelayAEADFailed)
		s.pool.MarkState(providerID, assignedID, pool.StateUnavailable)
		s.sessions.Delete(sessionKey(providerID, assignedID))
		_ = session.conn.Close()
		session.close()
		return
	} else if err := json.Unmarshal(payload, &chunk); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_chunk")
		return
	}
	if containsControlChar(chunk.RequestID) {
		s.log.Warn().Str("provider_id", providerID).Msg("invalid inference_response_chunk request_id (control chars)")
		return
	}
	active, ok := session.activeFor(chunk.RequestID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("request_id", chunk.RequestID).Msg("unknown inference_response_chunk request_id")
		return
	}
	select {
	case active.chunks <- chunk:
	default:
		if active, found := session.removeActive(chunk.RequestID); found {
			select {
			case active.errs <- errors.New("buyer relay chunk buffer full"):
			default:
			}
			close(active.chunks)
		}
	}
}

func (s *Server) handleInferenceEnd(providerID, assignedID string, payload []byte) {
	session, ok := s.sessionFor(providerID, assignedID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("end from unknown provider session")
		return
	}
	var envelope encryptedInferenceResponseEnd
	var end InferenceResponseEnd
	if err := json.Unmarshal(payload, &envelope); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_end")
		return
	}
	// SPEC-002 v1.5.1 R-2 / issue #197 R6 code: reject control-character
	// envelope.RequestID before any tier2 log helper or structured log.
	if containsControlChar(envelope.RequestID) {
		s.log.Warn().Str("provider_id", providerID).Msg("inference_response_end envelope.request_id contains control chars; dropping")
		return
	}
	if envelope.Encrypted {
		aad, _, err := tier2.DecodeAEADAAD(envelope.Enc.AAD)
		if err != nil {
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, envelope.RequestID, err.Error())
			return
		}
		requestID := aad.RequestID
		if requestID == "" {
			requestID = envelope.RequestID
		}
		if containsControlChar(requestID) {
			s.log.Warn().Str("provider_id", providerID).Msg("encrypted inference_response_end AAD request_id contains control chars; dropping")
			return
		}
		active, ok := session.activeFor(requestID)
		if !ok {
			if retired, ok := session.recentlyRetired(requestID); ok {
				if err := session.consumeRetiredEncryptedFrame(providerID, assignedID, retired, "inference_response_end", requestID, aad, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc}); err != nil {
					s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, err.Error())
					return
				}
				s.log.Warn().Str("provider_id", providerID).Str("request_id", requestID).Msg("late encrypted inference_response_end for retired request dropped")
				return
			}
			s.log.Warn().Str("provider_id", providerID).Str("request_id", requestID).Msg("unknown encrypted inference_response_end request_id")
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, "unknown encrypted inference_response_end request_id")
			return
		}
		opened, err := session.openInferenceEnd(providerID, assignedID, active, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc})
		if err != nil {
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, err.Error())
			return
		}
		end = opened
	} else if session.hasTier2Session() {
		requestID := envelope.RequestID
		if requestID == "" {
			requestID = "unknown"
		}
		s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, "tier2 encrypted response end required")
		return
	} else if err := json.Unmarshal(payload, &end); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_end")
		return
	}
	if containsControlChar(end.RequestID) {
		s.log.Warn().Str("provider_id", providerID).Msg("invalid inference_response_end request_id (control chars)")
		return
	}
	active, ok := session.removeActive(end.RequestID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("request_id", end.RequestID).Msg("unknown inference_response_end request_id")
		return
	}
	active.done <- end
	close(active.chunks)
	if reason, ok := session.tier2RekeyReason(s.now(), s.tier2Config()); ok {
		s.closeProviderForTier2Rekey(session, providerID, assignedID, end.RequestID, reason)
	}
}

func (s *Server) handleNAK(providerID, assignedID string, payload []byte) {
	nak, field, err := ParseNak(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid nak")
		return
	}
	if nak.Error.Code != "unknown_message_type" && nak.Error.Code != "duplicate_request_id" && nak.Error.Code != "tier2_aead_decrypt_failed" && nak.Error.Code != "tier2_encrypted_frame_required" {
		s.log.Warn().Str("provider_id", providerID).Str("code", nak.Error.Code).Msg("provider nak")
		return
	}
	session, ok := s.sessionFor(providerID, assignedID)
	if ok && nak.Error.Code == "unknown_message_type" {
		session.activeMu.Lock()
		session.httpOnly = true
		session.activeMu.Unlock()
		s.pool.MarkHTTPForwardingOnly(providerID, assignedID)
	}
	if ok && (nak.Error.Code == "tier2_aead_decrypt_failed" || nak.Error.Code == "tier2_encrypted_frame_required") {
		session.failActiveOrAll(nak.InReplyTo, ErrRelayAEADFailed)
		tier2.LogEncryptedLegSessionClosed(s.log, providerID, assignedID, nak.InReplyTo, nak.Error.Code)
		s.pool.MarkState(providerID, assignedID, pool.StateUnavailable)
		s.sessions.Delete(sessionKey(providerID, assignedID))
		_ = session.conn.Close()
		session.close()
	} else if ok && nak.InReplyTo != "" {
		if active, found := session.removeActive(nak.InReplyTo); found {
			active.errs <- ErrRelayNAKFallback
			close(active.chunks)
		}
	}
	s.log.Warn().Str("provider_id", providerID).Str("in_reply_to", nak.InReplyTo).Str("code", nak.Error.Code).Msg("provider nak processed")
}
