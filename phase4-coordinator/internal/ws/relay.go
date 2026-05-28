package ws

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
)

var (
	ErrRelayBackpressure = errors.New("provider websocket write buffer full")
	ErrRelayNAKFallback  = errors.New("provider rejected ws-tunneled inference")
	ErrRelayClosed       = errors.New("provider websocket closed")
	ErrRelayTimeout      = errors.New("provider websocket inference timed out")
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

func (ps *providerSession) addActive(requestID string, maxConcurrency int) (*relayActive, error) {
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

func (s *Server) DispatchInference(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*RelayStream, error) {
	if !strings.HasPrefix(requestID, "req-") {
		requestID = "req-" + requestID
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return nil, ErrRelayClosed
	}
	active, err := session.addActive(requestID, provider.MaxConcurrency)
	if err != nil {
		return nil, err
	}
	msg := InferenceRequest{
		Type:      "inference_request",
		RequestID: requestID,
		Stream:    stream,
		Body:      string(body),
	}
	payload, err := json.Marshal(msg)
	if err != nil {
		session.removeActive(requestID)
		return nil, err
	}
	if err := session.send(payload); err != nil {
		session.removeActive(requestID)
		return nil, err
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

func (s *Server) handleInferenceChunk(providerID string, payload []byte) {
	var chunk InferenceResponseChunk
	if err := json.Unmarshal(payload, &chunk); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_chunk")
		return
	}
	session, ok := s.sessionByProvider(providerID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("request_id", chunk.RequestID).Msg("chunk from unknown provider session")
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

func (s *Server) handleInferenceEnd(providerID string, payload []byte) {
	var end InferenceResponseEnd
	if err := json.Unmarshal(payload, &end); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid inference_response_end")
		return
	}
	session, ok := s.sessionByProvider(providerID)
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
}

func (s *Server) handleNAK(providerID, assignedID string, payload []byte) {
	var nak NAK
	if err := json.Unmarshal(payload, &nak); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid nak")
		return
	}
	if nak.Code != "unknown_message_type" && nak.Code != "duplicate_request_id" {
		s.log.Warn().Str("provider_id", providerID).Str("code", nak.Code).Msg("provider nak")
		return
	}
	session, ok := s.sessionFor(providerID, assignedID)
	if ok && nak.Code == "unknown_message_type" {
		session.activeMu.Lock()
		session.httpOnly = true
		session.activeMu.Unlock()
		s.pool.MarkHTTPForwardingOnly(providerID, assignedID)
	}
	if ok && nak.RequestID != "" {
		if active, found := session.removeActive(nak.RequestID); found {
			active.errs <- ErrRelayNAKFallback
			close(active.chunks)
		}
	}
	s.log.Warn().Str("provider_id", providerID).Str("request_id", nak.RequestID).Str("code", nak.Code).Msg("provider nak processed")
}
