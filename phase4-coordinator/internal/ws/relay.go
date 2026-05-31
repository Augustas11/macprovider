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

type relayActive struct {
	requestID string
	stream    bool
	chunks    chan InferenceResponseChunk
	done      chan InferenceResponseEnd
	errs      chan error
}

type providerSession struct {
	providerID string
	assignedID string
	conn       net.Conn
	writeCh    chan []byte
	closeOnce  sync.Once
	writeMu    sync.Mutex
	closed     bool
	activeMu   sync.Mutex
	active     map[string]*relayActive
	httpOnly   bool
	tier2Mu    sync.Mutex
	tier2      *pool.Tier2Session
}

type encryptedInferenceRequest struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id"`
	Stream    bool                   `json:"stream"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

type encryptedInferenceResponseChunk struct {
	Type      string                 `json:"type"`
	RequestID string                 `json:"request_id,omitempty"`
	Encrypted bool                   `json:"encrypted"`
	Enc       tier2.AEADEnvelopeBody `json:"enc"`
}

func newProviderSession(providerID, assignedID string, conn net.Conn, bufferSize int) *providerSession {
	if bufferSize <= 0 {
		bufferSize = 64
	}
	return &providerSession{
		providerID: providerID,
		assignedID: assignedID,
		conn:       conn,
		writeCh:    make(chan []byte, bufferSize),
		active:     map[string]*relayActive{},
	}
}

func (ps *providerSession) runWriter() {
	for payload := range ps.writeCh {
		if err := wsutil.WriteServerText(ps.conn, payload); err != nil {
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
	ps.writeMu.Lock()
	defer ps.writeMu.Unlock()
	if ps.closed {
		return ErrRelayClosed
	}
	select {
	case ps.writeCh <- payload:
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
	}
	return active, ok
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

func (ps *providerSession) sealInferenceRequest(provider pool.Provider, requestID string, body []byte, stream bool) ([]byte, error) {
	ps.tier2Mu.Lock()
	session := ps.tier2
	if session == nil {
		ps.tier2Mu.Unlock()
		msg := InferenceRequest{
			Type:      "inference_request",
			RequestID: requestID,
			Stream:    stream,
			Body:      string(body),
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
	envelope, err := tier2.SealPillarBFrame(session.C2PKey, session.C2PNonceBase, session.KeyID, seq, aad, body)
	if err != nil {
		return nil, err
	}
	session.C2PCounter++
	return json.Marshal(encryptedInferenceRequest{
		Type:      "inference_request",
		RequestID: requestID,
		Stream:    stream,
		Encrypted: true,
		Enc:       envelope.Enc,
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

func (s *Server) DispatchInference(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*RelayStream, error) {
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
	payload, err := session.sealInferenceRequest(provider, requestID, body, stream)
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
	session, ok := s.sessionFor(providerID, assignedID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("request_id", envelope.RequestID).Msg("chunk from unknown provider session")
		return
	}
	var chunk InferenceResponseChunk
	if envelope.Encrypted {
		aad, _, err := tier2.DecodeAEADAAD(envelope.Enc.AAD)
		if err != nil {
			tier2.LogAEADDecryptFailed(s.log, providerID, assignedID, envelope.RequestID, err.Error())
			tier2.LogEncryptedLegSessionClosed(s.log, providerID, assignedID, envelope.RequestID, "aead_decrypt_failed")
			if envelope.RequestID != "" {
				session.failActive(envelope.RequestID, ErrRelayAEADFailed)
			}
			_ = session.conn.Close()
			session.close()
			return
		}
		requestID := aad.RequestID
		if requestID == "" {
			requestID = envelope.RequestID
		}
		active, ok := session.activeFor(requestID)
		if !ok {
			s.log.Warn().Str("provider_id", providerID).Str("request_id", requestID).Msg("unknown encrypted inference_response_chunk request_id")
			return
		}
		chunk, err = session.openInferenceChunk(providerID, assignedID, active, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc})
		if err != nil {
			tier2.LogAEADDecryptFailed(s.log, providerID, assignedID, requestID, err.Error())
			tier2.LogEncryptedLegSessionClosed(s.log, providerID, assignedID, requestID, "aead_decrypt_failed")
			session.failActive(requestID, ErrRelayAEADFailed)
			_ = session.conn.Close()
			session.close()
			return
		}
	} else if err := json.Unmarshal(payload, &chunk); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_chunk")
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
	var end InferenceResponseEnd
	if err := json.Unmarshal(payload, &end); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_end")
		return
	}
	session, ok := s.sessionFor(providerID, assignedID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("request_id", end.RequestID).Msg("end from unknown provider session")
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
	if nak.Error.Code != "unknown_message_type" && nak.Error.Code != "duplicate_request_id" {
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
	if ok && nak.InReplyTo != "" {
		if active, found := session.removeActive(nak.InReplyTo); found {
			active.errs <- ErrRelayNAKFallback
			close(active.chunks)
		}
	}
	s.log.Warn().Str("provider_id", providerID).Str("in_reply_to", nak.InReplyTo).Str("code", nak.Error.Code).Msg("provider nak processed")
}
