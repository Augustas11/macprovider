package ws

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/google/uuid"
)

var (
	ErrRelayBackpressure         = errors.New("provider websocket write buffer full")
	ErrRelayNAKFallback          = errors.New("provider rejected ws-tunneled inference")
	ErrRelayClosed               = errors.New("provider websocket closed")
	ErrRelayTimeout              = errors.New("provider websocket inference timed out")
	ErrRelayAEADFailed           = errors.New("tier2 aead decrypt failed")
	ErrRelayBufferExceeded       = errors.New("relay_buffer_exceeded")
	ErrRelaySettlementIDMismatch = errors.New("settlement request ID mismatch")
	errTier2C2PCounterExhausted  = errors.New("tier2 c2p frame counter exhausted")
)

const retiredRelayRequestTTL = 5 * time.Minute
const providerDispatchWriteProbeTimeout = 500 * time.Millisecond

// Bound sparse p2c sequence gaps so multiplexed responses can arrive out of
// order without giving an admitted provider an unbounded replay-cache sink.
const tier2MaxOutOfOrderP2CFrames = 4096

var relayEndFrameAADMismatchTotal atomic.Uint64
var relayBufferExceededTotal atomic.Uint64

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
	requestID     string
	stream        bool
	bufferMu      sync.Mutex
	bufferedBytes int64
	chunks        chan InferenceResponseChunk
	done          chan InferenceResponseEnd
	errs          chan error
}

func (a *relayActive) delivered(ctx context.Context) (<-chan InferenceResponseChunk, <-chan InferenceResponseEnd) {
	outChunks := make(chan InferenceResponseChunk)
	outDone := make(chan InferenceResponseEnd, 1)
	go func() {
		defer close(outChunks)
		for chunk := range a.chunks {
			n := len([]byte(chunk.Data))
			select {
			case outChunks <- chunk:
				a.releaseBufferedBytes(n)
			case <-ctx.Done():
				a.releaseBufferedBytes(n)
				return
			}
		}
		select {
		case end := <-a.done:
			select {
			case outDone <- end:
			case <-ctx.Done():
			}
		default:
		}
	}()
	return outChunks, outDone
}

func (a *relayActive) reserveBufferedBytes(limit int64, n int) bool {
	if a == nil || n <= 0 || limit <= 0 {
		return true
	}
	a.bufferMu.Lock()
	defer a.bufferMu.Unlock()
	next := a.bufferedBytes + int64(n)
	if next > limit {
		return false
	}
	a.bufferedBytes = next
	return true
}

func (a *relayActive) releaseBufferedBytes(n int) {
	if a == nil || n <= 0 {
		return
	}
	a.bufferMu.Lock()
	defer a.bufferMu.Unlock()
	a.bufferedBytes -= int64(n)
	if a.bufferedBytes < 0 {
		a.bufferedBytes = 0
	}
}

func RelayEndFrameAADMismatchTotalForTest() uint64 {
	return relayEndFrameAADMismatchTotal.Load()
}

func RelayBufferExceededTotalForTest() uint64 {
	return relayBufferExceededTotal.Load()
}

type retiredRelayRequest struct {
	stream    bool
	retiredAt time.Time
}

type tier2RekeyExchange struct {
	id                 string
	reason             string
	requestID          string
	oldKID             string
	coordinatorPrivate *ecdh.PrivateKey
	request            AEADRekeyRequest
	next               *pool.Tier2Session
	proof              []byte
	phase              string
	done               chan struct{}
	err                error
	setupErr           error
	failureReason      string
}

type providerSession struct {
	providerID     string
	assignedID     string
	conn           net.Conn
	writeCh        chan providerFrame
	writeLimit     time.Duration
	probeWrites    bool
	onWriteFailure func(*providerSession, error)
	closeOnce      sync.Once
	closeEventOnce sync.Once
	writeMu        sync.Mutex
	closed         bool
	activeMu       sync.Mutex
	active         map[string]*relayActive
	retired        map[string]retiredRelayRequest
	activeChanged  chan struct{}
	closedCh       chan struct{}
	httpOnly       bool
	tier2Mu        sync.Mutex
	tier2          *pool.Tier2Session
	rekeyMu        sync.Mutex
	rekey          *tier2RekeyExchange
	rekeyWaiters   int
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
	raw        bool
	payload    []byte
	writeLimit time.Duration
	result     chan error
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

type encryptedInferenceChunkPlaintext struct {
	Type string `json:"type"`
	Seq  int    `json:"seq"`
	Data string `json:"data"`
}

type encryptedInferenceChunkPlaintextDecode struct {
	Type string  `json:"type"`
	Seq  *int    `json:"seq"`
	Data *string `json:"data"`
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
		providerID:    providerID,
		assignedID:    assignedID,
		conn:          conn,
		writeCh:       make(chan providerFrame, bufferSize),
		writeLimit:    writeLimit,
		active:        map[string]*relayActive{},
		retired:       map[string]retiredRelayRequest{},
		activeChanged: make(chan struct{}, 1),
		closedCh:      make(chan struct{}),
	}
}

func (ps *providerSession) runWriter() {
	for f := range ps.writeCh {
		writeLimit := ps.writeLimit
		if f.writeLimit > 0 && (writeLimit <= 0 || f.writeLimit < writeLimit) {
			writeLimit = f.writeLimit
		}
		_ = ps.conn.SetWriteDeadline(time.Now().Add(writeLimit))
		var err error
		if f.raw {
			// Single Write of an already-framed control reply. The header and
			// body were assembled into f.payload upstream so they cannot be
			// split across goroutines mid-frame.
			_, err = ps.conn.Write(f.payload)
		} else {
			err = wsutil.WriteServerText(ps.conn, f.payload)
		}
		ps.completeFrame(f, err)
		if err != nil {
			ps.failAll(ErrRelayClosed)
			_ = ps.conn.Close()
			if ps.onWriteFailure != nil {
				ps.onWriteFailure(ps, err)
			} else {
				ps.close()
			}
			return
		}
	}
}

func (ps *providerSession) completeFrame(f providerFrame, err error) {
	if f.result == nil {
		return
	}
	select {
	case f.result <- err:
	default:
	}
}

func (ps *providerSession) close() {
	ps.closeOnce.Do(func() {
		ps.writeMu.Lock()
		// Publish the closed-state to isOpen() (which reads closedCh lock-free)
		// BEFORE flipping ps.closed, both under writeMu. This makes isOpen() a
		// conservative signal: it can only observe closedCh-closed at-or-before
		// dispatch begins rejecting on ps.closed, so there is never a window where
		// isOpen() returns true while enqueueFrame would return ErrRelayClosed (the
		// canary floor must not count a session dispatch has already given up on).
		close(ps.closedCh)
		ps.closed = true
		close(ps.writeCh)
		ps.writeMu.Unlock()
		ps.failAll(ErrRelayClosed)
	})
}

// isOpen reports whether the session has not yet been closed. Lock-free — a
// non-blocking receive on closedCh (which close() closes) — so it is safe to call
// from under the registry lock (canaryBuyerServing / the FR-CAN22 floor). Dispatch
// to a closed-but-not-yet-deleted session returns ErrRelayClosed, so such a session
// must not count as buyer-serving.
func (ps *providerSession) isOpen() bool {
	select {
	case <-ps.closedCh:
		return false
	default:
		return true
	}
}

func (ps *providerSession) send(payload []byte) error {
	return ps.enqueueFrame(providerFrame{payload: payload})
}

func (ps *providerSession) sendProbe(payload []byte, timeout time.Duration) error {
	if timeout <= 0 || !ps.probeWrites {
		return ps.send(payload)
	}
	frame, err := providerWriteProbeFrame()
	if err != nil {
		return err
	}
	if err := ps.writeProbe(frame, timeout); err != nil {
		return err
	}
	return ps.send(payload)
}

func (ps *providerSession) writeProbe(rawFrame []byte, timeout time.Duration) error {
	result := make(chan error, 1)
	if err := ps.enqueueFrame(providerFrame{raw: true, payload: rawFrame, writeLimit: timeout, result: result}); err != nil {
		return err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-result:
		if err != nil {
			return ErrRelayClosed
		}
		return nil
	case <-timer.C:
		_ = ps.conn.Close()
		ps.close()
		return ErrRelayClosed
	}
}

func providerWriteProbeFrame() ([]byte, error) {
	var buf bytes.Buffer
	if err := gobwas.WriteFrame(&buf, gobwas.NewPingFrame([]byte("probe"))); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
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
	active, ok := ps.active[requestID]
	if ok {
		delete(ps.active, requestID)
		ps.markRetiredLocked(active, time.Now())
	}
	ps.activeMu.Unlock()
	if ok {
		ps.signalActiveChanged()
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

func (ps *providerSession) cancelActive(requestID string, reason string, err error) bool {
	active, ok := ps.removeActive(requestID)
	if !ok {
		return false
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
	return true
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
	if len(active) > 0 {
		ps.signalActiveChanged()
	}
	for _, a := range active {
		select {
		case a.errs <- err:
		default:
		}
		close(a.chunks)
	}
}

func (ps *providerSession) signalActiveChanged() {
	select {
	case ps.activeChanged <- struct{}{}:
	default:
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
		return nil, errTier2C2PCounterExhausted
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

func (ps *providerSession) openInferenceChunk(providerID, assignedID string, active *relayActive, aad tier2.AEADFrameAAD, envelope tier2.AEADEnvelope) (InferenceResponseChunk, error) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return InferenceResponseChunk{}, errors.New("encrypted chunk for provider without tier2 session")
	}
	seq := aad.Seq
	if seq == ^uint64(0) {
		return InferenceResponseChunk{}, errors.New("tier2 p2c frame counter exhausted")
	}
	expectedAAD := tier2.AEADFrameAAD{
		Type:       "inference_response_chunk",
		Direction:  "p2c",
		RequestID:  active.requestID,
		Stream:     active.stream,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        seq,
	}
	if ps.tier2P2CSequenceOutsideWindow(seq) {
		return InferenceResponseChunk{}, errors.New("tier2 p2c frame sequence outside receive window")
	}
	if ps.tier2P2CSequenceSeen(seq) {
		return InferenceResponseChunk{}, errors.New("tier2 p2c frame replayed")
	}
	plaintext, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, expectedAAD, envelope)
	if err != nil {
		return InferenceResponseChunk{}, err
	}
	responseChunkPlaintextEnvelope := ps.tier2.ResponseChunkPlaintextEnvelope
	ps.markTier2P2CSequenceSeen(seq)
	chunk, err := decodeEncryptedInferenceChunkPlaintext(active.requestID, seq, responseChunkPlaintextEnvelope, plaintext)
	if err != nil {
		return InferenceResponseChunk{}, err
	}
	return InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: active.requestID,
		Seq:       chunk.Seq,
		Data:      chunk.Data,
	}, nil
}

func decodeEncryptedInferenceChunkPlaintext(requestID string, legacySeq uint64, responseChunkPlaintextEnvelope bool, plaintext []byte) (InferenceResponseChunk, error) {
	if !responseChunkPlaintextEnvelope {
		return legacyEncryptedInferenceChunk(requestID, legacySeq, plaintext)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(plaintext, &fields); err != nil {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext envelope must be valid JSON")
	}
	var plaintextType string
	rawType, ok := fields["type"]
	if !ok {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext type is required")
	}
	if err := json.Unmarshal(rawType, &plaintextType); err != nil {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext type must be a string")
	}
	if plaintextType != "inference_response_chunk_plaintext" {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext type mismatch")
	}
	var envelope encryptedInferenceChunkPlaintextDecode
	if err := json.Unmarshal(plaintext, &envelope); err != nil {
		return InferenceResponseChunk{}, err
	}
	if envelope.Seq == nil {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext seq is required")
	}
	if *envelope.Seq < 0 {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext seq must be >= 0")
	}
	if envelope.Data == nil {
		return InferenceResponseChunk{}, errors.New("encrypted chunk plaintext data is required")
	}
	return InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Seq:       *envelope.Seq,
		Data:      *envelope.Data,
	}, nil
}

func legacyEncryptedInferenceChunk(requestID string, legacySeq uint64, plaintext []byte) (InferenceResponseChunk, error) {
	if legacySeq > uint64(^uint(0)>>1) {
		return InferenceResponseChunk{}, errors.New("legacy encrypted chunk seq overflows int")
	}
	return InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: requestID,
		Seq:       int(legacySeq),
		Data:      string(plaintext),
	}, nil
}

func (ps *providerSession) openInferenceEnd(providerID, assignedID string, active *relayActive, aad tier2.AEADFrameAAD, envelope tier2.AEADEnvelope) (InferenceResponseEnd, error) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return InferenceResponseEnd{}, errors.New("encrypted end for provider without tier2 session")
	}
	seq := aad.Seq
	if seq == ^uint64(0) {
		return InferenceResponseEnd{}, errors.New("tier2 p2c frame counter exhausted")
	}
	expectedAAD := tier2.AEADFrameAAD{
		Type:       "inference_response_end",
		Direction:  "p2c",
		RequestID:  active.requestID,
		Stream:     active.stream,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        seq,
	}
	if ps.tier2P2CSequenceOutsideWindow(seq) {
		return InferenceResponseEnd{}, errors.New("tier2 p2c frame sequence outside receive window")
	}
	if ps.tier2P2CSequenceSeen(seq) {
		return InferenceResponseEnd{}, errors.New("tier2 p2c frame replayed")
	}
	plaintext, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, expectedAAD, envelope)
	if err != nil {
		return InferenceResponseEnd{}, err
	}
	ps.markTier2P2CSequenceSeen(seq)
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
	seq := aad.Seq
	if seq == ^uint64(0) {
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
	expectedAAD := tier2.AEADFrameAAD{
		Type:       expectedType,
		Direction:  "p2c",
		RequestID:  expectedRequestID,
		Stream:     retired.stream,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        seq,
	}
	if ps.tier2P2CSequenceOutsideWindow(seq) {
		return errors.New("tier2 p2c frame sequence outside receive window")
	}
	if ps.tier2P2CSequenceSeen(seq) {
		return errors.New("tier2 p2c frame replayed")
	}
	if _, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, expectedAAD, envelope); err != nil {
		return err
	}
	ps.markTier2P2CSequenceSeen(seq)
	return nil
}

func (ps *providerSession) tier2P2CSequenceOutsideWindow(seq uint64) bool {
	if ps.tier2 == nil || seq <= ps.tier2.P2CCounter {
		return false
	}
	return seq-ps.tier2.P2CCounter > tier2MaxOutOfOrderP2CFrames
}

func (ps *providerSession) tier2P2CSequenceSeen(seq uint64) bool {
	if ps.tier2 == nil {
		return false
	}
	if seq < ps.tier2.P2CCounter {
		return true
	}
	if ps.tier2.P2CSeen == nil {
		return false
	}
	_, ok := ps.tier2.P2CSeen[seq]
	return ok
}

func (ps *providerSession) markTier2P2CSequenceSeen(seq uint64) {
	if ps.tier2 == nil {
		return
	}
	if seq == ps.tier2.P2CCounter {
		ps.tier2.P2CCounter++
		for {
			if ps.tier2.P2CSeen == nil {
				return
			}
			if _, ok := ps.tier2.P2CSeen[ps.tier2.P2CCounter]; !ok {
				return
			}
			delete(ps.tier2.P2CSeen, ps.tier2.P2CCounter)
			ps.tier2.P2CCounter++
		}
	}
	if seq < ps.tier2.P2CCounter {
		return
	}
	if ps.tier2.P2CSeen == nil {
		ps.tier2.P2CSeen = make(map[uint64]struct{})
	}
	ps.tier2.P2CSeen[seq] = struct{}{}
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

func (s *Server) closeProviderForTier2RekeyIfDrained(session *providerSession, providerID, assignedID, requestID string) {
	s.beginTier2RekeyIfDue(session, providerID, assignedID, requestID)
}

func (s *Server) newTier2RekeyExchange(session *providerSession, assignedID, requestID, reason string) *tier2RekeyExchange {
	rekeyID := uuid.NewString()
	exchange := &tier2RekeyExchange{
		id:        rekeyID,
		reason:    reason,
		requestID: requestID,
		phase:     "draining",
		done:      make(chan struct{}),
	}
	session.tier2Mu.Lock()
	current := session.tier2
	if current == nil {
		session.tier2Mu.Unlock()
		exchange.setupErr = ErrRelayClosed
		exchange.failureReason = "session_missing"
		return exchange
	}
	exchange.oldKID = current.KeyID
	if !current.InBandAEADRekeyV1 {
		session.tier2Mu.Unlock()
		exchange.setupErr = ErrRelayClosed
		exchange.failureReason = "unsupported"
		return exchange
	}
	selectedAEAD := current.AEADSuite
	responseChunkPlaintextEnvelope := current.ResponseChunkPlaintextEnvelope
	session.tier2Mu.Unlock()

	coordinatorPrivate, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		exchange.setupErr = err
		exchange.failureReason = "key_generation_failed"
		return exchange
	}
	request := AEADRekeyRequest{
		Type:                           "aead_rekey_request",
		Version:                        1,
		RekeyID:                        rekeyID,
		AssignedID:                     assignedID,
		Reason:                         reason,
		OldKID:                         exchange.oldKID,
		CoordinatorECDHPublicKey:       base64.RawURLEncoding.EncodeToString(coordinatorPrivate.PublicKey().Bytes()),
		SelectedAEAD:                   selectedAEAD,
		ResponseChunkPlaintextEnvelope: responseChunkPlaintextEnvelope,
	}
	exchange.coordinatorPrivate = coordinatorPrivate
	exchange.request = request
	return exchange
}

func (s *Server) beginTier2RekeyIfDue(session *providerSession, providerID, assignedID, requestID string) *tier2RekeyExchange {
	session.rekeyMu.Lock()
	if session.rekey != nil {
		exchange := session.rekey
		session.rekeyMu.Unlock()
		return exchange
	}
	reason, due := session.tier2RekeyReason(s.now(), s.tier2Config())
	if !due {
		session.rekeyMu.Unlock()
		return nil
	}
	exchange := s.newTier2RekeyExchange(session, assignedID, requestID, reason)
	session.rekey = exchange
	session.rekeyMu.Unlock()
	tier2.LogAEADRekey(s.log, providerID, assignedID, requestID, exchange.oldKID, reason)
	go s.runTier2Rekey(session, providerID, assignedID, exchange)
	return exchange
}

func (s *Server) runTier2Rekey(session *providerSession, providerID, assignedID string, exchange *tier2RekeyExchange) {
	barrierPoll := time.NewTicker(25 * time.Millisecond)
	defer barrierPoll.Stop()
	for session.hasActive() || s.losslessnessProviderHasPending(providerID, assignedID) {
		select {
		case <-session.activeChanged:
		case <-barrierPoll.C:
		case <-session.closedCh:
			s.failTier2Rekey(session, providerID, assignedID, exchange, "session_closed", ErrRelayClosed)
			return
		}
	}
	if exchange.setupErr != nil {
		s.failTier2Rekey(session, providerID, assignedID, exchange, exchange.failureReason, exchange.setupErr)
		return
	}

	session.rekeyMu.Lock()
	if session.rekey != exchange {
		session.rekeyMu.Unlock()
		return
	}
	exchange.request.ExpiresAt = s.now().Add(s.cfg.ProviderWSHandshakeTimeout()).UTC().Format(time.RFC3339Nano)
	exchange.phase = "requested"
	payload, err := json.Marshal(exchange.request)
	if err == nil {
		err = session.send(payload)
	}
	session.rekeyMu.Unlock()
	if err != nil {
		s.failTier2Rekey(session, providerID, assignedID, exchange, "request_send_failed", err)
		return
	}

	timer := time.NewTimer(s.cfg.ProviderWSHandshakeTimeout())
	defer timer.Stop()
	select {
	case <-exchange.done:
		return
	case <-session.closedCh:
		s.failTier2Rekey(session, providerID, assignedID, exchange, "session_closed", ErrRelayClosed)
	case <-timer.C:
		s.failTier2Rekey(session, providerID, assignedID, exchange, "timeout", ErrRelayTimeout)
	}
}

func (s *Server) failTier2Rekey(session *providerSession, providerID, assignedID string, exchange *tier2RekeyExchange, reason string, err error) bool {
	session.rekeyMu.Lock()
	if session.rekey != exchange {
		session.rekeyMu.Unlock()
		return false
	}
	s.pool.MarkState(providerID, assignedID, pool.StateUnavailable)
	s.sessions.Delete(sessionKey(providerID, assignedID))
	_ = session.conn.Close()
	exchange.err = err
	session.rekey = nil
	tier2.LogAEADRekeyFailed(s.log, providerID, assignedID, exchange.requestID, exchange.id, exchange.oldKID, reason)
	close(exchange.done)
	session.rekeyMu.Unlock()
	session.close()
	return true
}

func (s *Server) handleAEADRekeyResponse(providerID, assignedID string, payload []byte) {
	var response AEADRekeyResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Msg("invalid aead_rekey_response")
		return
	}
	session, ok := s.storedSessionFor(providerID, assignedID)
	if !ok {
		return
	}

	session.rekeyMu.Lock()
	exchange := session.rekey
	if exchange == nil || exchange.phase != "requested" {
		session.rekeyMu.Unlock()
		s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Msg("stale aead_rekey_response ignored")
		return
	}
	invalid := response.Type != "aead_rekey_response" || response.Version != 1 ||
		response.RekeyID != exchange.id || response.AssignedID != assignedID ||
		response.OldKID != exchange.oldKID || response.NewKID == "" || response.NewKID == exchange.oldKID
	expiresAt := mustParseRekeyExpiry(exchange.request.ExpiresAt)
	if invalid || expiresAt.IsZero() || !s.now().Before(expiresAt) {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "invalid_response_binding", ErrRelayAEADFailed)
		return
	}
	providerPublic, _, err := tier2.ParseX25519PublicKey(response.ProviderECDHPublicKey)
	if err != nil {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "invalid_provider_public_key", ErrRelayAEADFailed)
		return
	}
	keys, err := tier2.DerivePillarBKeys(exchange.coordinatorPrivate, providerPublic, providerID, assignedID, exchange.request.SelectedAEAD)
	if err != nil || keys.KeyID != response.NewKID {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "key_confirmation_mismatch", ErrRelayAEADFailed)
		return
	}
	proof := AEADRekeyProof{
		Type:                     "aead_rekey_proof",
		Version:                  1,
		RekeyID:                  exchange.id,
		ProviderID:               providerID,
		AssignedID:               assignedID,
		OldKID:                   exchange.oldKID,
		NewKID:                   keys.KeyID,
		ProviderECDHPublicKey:    response.ProviderECDHPublicKey,
		CoordinatorECDHPublicKey: exchange.request.CoordinatorECDHPublicKey,
		SelectedAEAD:             exchange.request.SelectedAEAD,
		ExpiresAt:                exchange.request.ExpiresAt,
	}
	proofBytes, err := json.Marshal(proof)
	if err != nil {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "proof_encode_failed", ErrRelayAEADFailed)
		return
	}
	commitAAD := tier2.AEADFrameAAD{
		Type:       "aead_rekey_commit",
		Direction:  "c2p",
		RequestID:  exchange.id,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        0,
	}
	commitEnvelope, err := tier2.SealPillarBFrame(keys.C2PKey, keys.C2PNonceBase, keys.KeyID, 0, commitAAD, proofBytes)
	if err != nil {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "commit_seal_failed", ErrRelayAEADFailed)
		return
	}
	next := &pool.Tier2Session{
		AEADSuite:                      keys.AEADSuite,
		ResponseChunkPlaintextEnvelope: exchange.request.ResponseChunkPlaintextEnvelope,
		InBandAEADRekeyV1:              true,
		C2PKey:                         keys.C2PKey,
		P2CKey:                         keys.P2CKey,
		C2PNonceBase:                   keys.C2PNonceBase,
		P2CNonceBase:                   keys.P2CNonceBase,
		C2PCounter:                     1,
		KeyID:                          keys.KeyID,
	}
	exchange.next = next
	exchange.proof = proofBytes
	exchange.phase = "commit_sent"
	commit := AEADRekeyConfirmation{
		Type:       "aead_rekey_commit",
		Version:    1,
		RekeyID:    exchange.id,
		AssignedID: assignedID,
		OldKID:     exchange.oldKID,
		NewKID:     keys.KeyID,
		Encrypted:  true,
		Enc:        commitEnvelope.Enc,
	}
	commitPayload, err := json.Marshal(commit)
	if err == nil {
		err = session.send(commitPayload)
	}
	session.rekeyMu.Unlock()
	if err != nil {
		s.failTier2Rekey(session, providerID, assignedID, exchange, "commit_send_failed", ErrRelayClosed)
	}
}

func (s *Server) handleAEADRekeyCommitted(providerID, assignedID string, payload []byte) {
	var committed AEADRekeyConfirmation
	if err := json.Unmarshal(payload, &committed); err != nil {
		s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Msg("invalid aead_rekey_committed")
		return
	}
	session, ok := s.storedSessionFor(providerID, assignedID)
	if !ok {
		return
	}
	session.rekeyMu.Lock()
	exchange := session.rekey
	if exchange == nil || exchange.phase != "commit_sent" {
		session.rekeyMu.Unlock()
		s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Msg("stale aead_rekey_committed ignored")
		return
	}
	expiresAt := mustParseRekeyExpiry(exchange.request.ExpiresAt)
	if expiresAt.IsZero() || !s.now().Before(expiresAt) {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "commit_expired", ErrRelayAEADFailed)
		return
	}
	invalid := committed.Type != "aead_rekey_committed" || committed.Version != 1 || !committed.Encrypted ||
		committed.RekeyID != exchange.id || committed.AssignedID != assignedID ||
		committed.OldKID != exchange.oldKID || exchange.next == nil || committed.NewKID != exchange.next.KeyID
	if invalid {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "invalid_commit_binding", ErrRelayAEADFailed)
		return
	}
	committedAAD := tier2.AEADFrameAAD{
		Type:       "aead_rekey_committed",
		Direction:  "p2c",
		RequestID:  exchange.id,
		ProviderID: providerID,
		AssignedID: assignedID,
		Seq:        0,
	}
	plaintext, err := tier2.OpenPillarBFrame(exchange.next.P2CKey, exchange.next.P2CNonceBase, exchange.next.KeyID, 0, committedAAD, tier2.AEADEnvelope{Encrypted: true, Enc: committed.Enc})
	if err != nil || !bytes.Equal(plaintext, exchange.proof) {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "commit_proof_mismatch", ErrRelayAEADFailed)
		return
	}
	exchange.next.P2CCounter = 1
	session.tier2Mu.Lock()
	currentMatches := session.tier2 != nil && session.tier2.KeyID == exchange.oldKID
	session.tier2Mu.Unlock()
	exchange.next.StartedAt = s.now()
	if !currentMatches || !s.pool.ReplaceTier2Session(providerID, assignedID, exchange.oldKID, exchange.next) {
		session.rekeyMu.Unlock()
		s.failTier2Rekey(session, providerID, assignedID, exchange, "stale_session", ErrRelayClosed)
		return
	}
	session.tier2Mu.Lock()
	session.tier2 = exchange.next
	session.tier2Mu.Unlock()
	exchange.err = nil
	session.rekey = nil
	tier2.LogAEADRekeyCommitted(s.log, providerID, assignedID, exchange.requestID, exchange.id, exchange.oldKID, exchange.next.KeyID, exchange.reason)
	close(exchange.done)
	session.rekeyMu.Unlock()
}

func mustParseRekeyExpiry(raw string) time.Time {
	parsed, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Time{}
	}
	return parsed
}

func rekeyWaitError(ctx context.Context, exchange *tier2RekeyExchange) error {
	select {
	case <-exchange.done:
		return exchange.err
	case <-ctx.Done():
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return ErrRelayTimeout
		}
		return ErrRelayClosed
	}
}

func tier2RekeyWaiterLimit(maxConcurrency int) int {
	limit := maxConcurrency * 2
	if limit < 8 {
		return 8
	}
	if limit > 64 {
		return 64
	}
	return limit
}

// waitForTier2Rekey registers a bounded per-provider waiter while rekeyMu is
// held, then releases the gate for the duration of the context-aware wait.
func waitForTier2Rekey(ctx context.Context, session *providerSession, exchange *tier2RekeyExchange, maxConcurrency int) error {
	if session.rekeyWaiters >= tier2RekeyWaiterLimit(maxConcurrency) {
		session.rekeyMu.Unlock()
		return ErrRelayBackpressure
	}
	session.rekeyWaiters++
	session.rekeyMu.Unlock()
	err := rekeyWaitError(ctx, exchange)
	session.rekeyMu.Lock()
	session.rekeyWaiters--
	session.rekeyMu.Unlock()
	return err
}

func (s *Server) addTier2Active(ctx context.Context, session *providerSession, provider pool.Provider, requestID string, stream bool) (*relayActive, error) {
	for {
		session.rekeyMu.Lock()
		if exchange := session.rekey; exchange != nil {
			if err := waitForTier2Rekey(ctx, session, exchange, provider.MaxConcurrency); err != nil {
				return nil, err
			}
			continue
		}
		if reason, due := session.tier2RekeyReason(s.now(), s.tier2Config()); due {
			exchange := s.newTier2RekeyExchange(session, provider.AssignedID, requestID, reason)
			session.rekey = exchange
			tier2.LogAEADRekey(s.log, provider.ProviderID, provider.AssignedID, requestID, exchange.oldKID, reason)
			go s.runTier2Rekey(session, provider.ProviderID, provider.AssignedID, exchange)
			if err := waitForTier2Rekey(ctx, session, exchange, provider.MaxConcurrency); err != nil {
				return nil, err
			}
			continue
		}
		active, err := session.addActive(requestID, provider.MaxConcurrency, stream)
		if err == nil {
			session.markTier2RequestDispatched()
		}
		session.rekeyMu.Unlock()
		return active, err
	}
}

func (s *Server) closeProviderForTier2AEADFailure(session *providerSession, providerID, assignedID, requestID, reason string) {
	tier2.LogAEADDecryptFailed(s.log, providerID, assignedID, requestID, reason)
	s.closeProviderForTier2SessionFailure(session, providerID, assignedID, requestID, "aead_decrypt_failed", ErrRelayAEADFailed)
}

func (s *Server) closeProviderForTier2SessionFailure(session *providerSession, providerID, assignedID, requestID, reason string, relayErr error) {
	tier2.LogEncryptedLegSessionClosed(s.log, providerID, assignedID, requestID, reason)
	session.failActiveOrAll(requestID, relayErr)
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
	// Settlement receipts bind request_id to the durable route snapshot.
	// Preserve that canonical ID on the wire; adding the legacy relay prefix
	// would make the outer request and signed settlement metadata disagree,
	// causing current providers to reject the request before inference.
	if settlementMetadata != nil {
		if requestID == "" || settlementMetadata.RequestID != requestID {
			return nil, ErrRelaySettlementIDMismatch
		}
	} else if !strings.HasPrefix(requestID, "req-") {
		requestID = "req-" + requestID
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return nil, ErrRelayClosed
	}
	if provider.EncryptedLeg {
		session.useTier2Session(provider.Tier2Session)
	}
	var active *relayActive
	var err error
	if provider.EncryptedLeg {
		active, err = s.addTier2Active(ctx, session, provider, requestID, stream)
	} else {
		active, err = session.addActive(requestID, provider.MaxConcurrency, stream)
	}
	if err != nil {
		return nil, err
	}
	s.extendProviderReadDeadlineForActive(provider)
	payload, err := session.sealInferenceRequest(provider, requestID, body, stream, settlementMetadata, ConversationKeyFromContext(ctx))
	if err != nil {
		if errors.Is(err, errTier2C2PCounterExhausted) {
			s.closeProviderForTier2SessionFailure(session, provider.ProviderID, provider.AssignedID, requestID, "counter_exhausted", ErrRelayAEADFailed)
			return nil, ErrRelayAEADFailed
		}
		session.removeActive(requestID)
		return nil, err
	}
	if err := session.sendProbe(payload, providerDispatchWriteProbeTimeout); err != nil {
		session.removeActive(requestID)
		if errors.Is(err, ErrRelayClosed) {
			s.handleProviderWriteFailure(session, err)
		}
		return nil, err
	}
	cancel := func(reason string) {
		if reason == "" {
			reason = "buyer_disconnected"
		}
		if session.cancelActive(requestID, reason, nil) {
			s.closeProviderForTier2RekeyIfDrained(session, provider.ProviderID, provider.AssignedID, requestID)
		}
	}
	go func() {
		<-ctx.Done()
		switch {
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			if session.cancelActive(requestID, "timeout", ErrRelayTimeout) {
				s.closeProviderForTier2RekeyIfDrained(session, provider.ProviderID, provider.AssignedID, requestID)
			}
		default:
			if session.cancelActive(requestID, "buyer_disconnected", ErrRelayClosed) {
				s.closeProviderForTier2RekeyIfDrained(session, provider.ProviderID, provider.AssignedID, requestID)
			}
		}
	}()
	chunks, done := active.delivered(ctx)
	return &RelayStream{
		RequestID: requestID,
		Chunks:    chunks,
		Done:      done,
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
		chunk, err = session.openInferenceChunk(providerID, assignedID, active, aad, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc})
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
	if s.relayChunkWouldExceed(active, len([]byte(chunk.Data))) {
		relayBufferExceededTotal.Add(1)
		s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Str("request_id", chunk.RequestID).Msg("relay buffer cap exceeded")
		if session.cancelActive(chunk.RequestID, "relay_buffer_exceeded", ErrRelayBufferExceeded) {
			s.closeProviderForTier2RekeyIfDrained(session, providerID, assignedID, chunk.RequestID)
		}
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
			s.closeProviderForTier2RekeyIfDrained(session, providerID, assignedID, chunk.RequestID)
		}
	}
}

func (s *Server) relayChunkWouldExceed(active *relayActive, n int) bool {
	return !active.reserveBufferedBytes(s.cfg.RelayMaxRequestBufferBytes(), n)
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
		opened, err := session.openInferenceEnd(providerID, assignedID, active, aad, tier2.AEADEnvelope{Encrypted: true, Enc: envelope.Enc})
		if err != nil {
			s.closeProviderForTier2AEADFailure(session, providerID, assignedID, requestID, err.Error())
			return
		}
		if opened.RequestID != "" && opened.RequestID != requestID {
			relayEndFrameAADMismatchTotal.Add(1)
			s.log.Warn().
				Str("provider_id", providerID).
				Str("assigned_id", assignedID).
				Str("aad_request_id", requestID).
				Str("plaintext_request_id", opened.RequestID).
				Msg("encrypted inference_response_end request_id mismatch; routing by AAD")
		}
		opened.RequestID = requestID
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
	s.closeProviderForTier2RekeyIfDrained(session, providerID, assignedID, end.RequestID)
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
			s.closeProviderForTier2RekeyIfDrained(session, providerID, assignedID, nak.InReplyTo)
		}
	}
	s.log.Warn().Str("provider_id", providerID).Str("in_reply_to", nak.InReplyTo).Str("code", nak.Error.Code).Msg("provider nak processed")
}
