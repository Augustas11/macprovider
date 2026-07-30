package buyer

import (
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

const (
	phaseTimingCoordRoutingHeader     = "X-MacProvider-Timing-Coord-Routing-Ms"
	phaseTimingCoordAdmissionHeader   = "X-MacProvider-Timing-Coord-Admission-Ms"
	phaseTimingProviderDispatchHeader = "X-MacProvider-Timing-Provider-Dispatch-Ms"
	phaseTimingProviderPrefillHeader  = "X-MacProvider-Timing-Provider-Prefill-Ms"
	phaseTimingProviderDecodeHeader   = "X-MacProvider-Timing-Provider-Decode-Ms"
	phaseTimingCoordinatorTotalHeader = "X-MacProvider-Timing-Coordinator-Total-Ms"
)

type requestPhaseTiming struct {
	mu sync.Mutex

	requestStart          time.Time
	coordRoutingDone      time.Time
	providerDispatchStart time.Time
	providerDispatchDone  time.Time
	providerFirstByte     time.Time
	providerDone          time.Time
	providerAssignedID    string
}

func (t *requestPhaseTiming) init(start time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.requestStart = start
}

func (t *requestPhaseTiming) markCoordRoutingDone(at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.coordRoutingDone = at
}

func (t *requestPhaseTiming) markProviderDispatchStart(at time.Time, providerAssignedID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.providerDispatchStart = at
	t.providerDispatchDone = time.Time{}
	t.providerFirstByte = time.Time{}
	t.providerDone = time.Time{}
	t.providerAssignedID = providerAssignedID
}

func (t *requestPhaseTiming) markProviderDispatchDone(at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.providerDispatchDone = at
}

func (t *requestPhaseTiming) markProviderFirstByte(at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.providerFirstByte.IsZero() {
		t.providerFirstByte = at
	}
}

func (t *requestPhaseTiming) markProviderDone(at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.providerDone.IsZero() {
		t.providerDone = at
	}
}

func (t *requestPhaseTiming) snapshot() requestPhaseTimingSnapshot {
	t.mu.Lock()
	defer t.mu.Unlock()
	return requestPhaseTimingSnapshot{
		requestStart:          t.requestStart,
		coordRoutingDone:      t.coordRoutingDone,
		providerDispatchStart: t.providerDispatchStart,
		providerDispatchDone:  t.providerDispatchDone,
		providerFirstByte:     t.providerFirstByte,
		providerDone:          t.providerDone,
		providerAssignedID:    t.providerAssignedID,
	}
}

type requestPhaseTimingSnapshot struct {
	requestStart          time.Time
	coordRoutingDone      time.Time
	providerDispatchStart time.Time
	providerDispatchDone  time.Time
	providerFirstByte     time.Time
	providerDone          time.Time
	providerAssignedID    string
}

type phaseTimingResponseWriter struct {
	http.ResponseWriter
	state *forwardState
	now   func() time.Time
	once  sync.Once
}

func (w *phaseTimingResponseWriter) WriteHeader(code int) {
	w.inject()
	w.ResponseWriter.WriteHeader(code)
}

func (w *phaseTimingResponseWriter) Write(b []byte) (int, error) {
	w.inject()
	return w.ResponseWriter.Write(b)
}

func (w *phaseTimingResponseWriter) Flush() {
	w.inject()
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *phaseTimingResponseWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func (w *phaseTimingResponseWriter) inject() {
	w.once.Do(func() {
		now := time.Now()
		if w.now != nil {
			now = w.now()
		}
		writePhaseTimingHeaders(w.Header(), w.state, now)
	})
}

// noPriorDispatchResponseWriter centrally stamps the item-18 POSITIVE
// no-charge marker (settlementNoPriorDispatchHeader) on the FIRST response
// write iff NO provider has been (or is about to be) billably credited for
// this request. It derives that from the ledger-exact recorder signals rather
// than a request-log ordinal:
//
//   - rec.providerCredited — true once ANY provider-bound billable row has
//     durably persisted this request (set inside recordRow, status != 503).
//     Failover-hit attempts bill via onFailoverHit BEFORE the next attempt's
//     write, so this covers every attempt EXCEPT the current terminal one,
//     whose own billing row is recorded after its terminal HTTP write on the
//     WS paths.
//   - rec.dispatchedThisAttempt && code != 503 — covers that current terminal
//     attempt: a dispatched attempt whose terminal write is non-503 WILL be
//     billed (recordRow bills iff status != 503), so it must be left unmarked.
//     A dispatched attempt that terminates 503 (queue-full / relay-unavailable)
//     is NOT billed, so it stays eligible for the marker.
//
// Stamping at the first write — the moment the header is committed — means one
// wrapper covers every terminal response path: a genuine no-provider error
// (route_snapshot_failed 500, cold no_provider 503) carries the marker, while
// any response following (or constituting) a billed provider attempt is left
// unmarked so the gateway settles-on-estimate rather than refunds. On a
// streaming 200 the attempt was dispatched and non-503, so the marker is
// absent; the gateway ignores the marker on 200 regardless.
//
// #766: this is ALSO the single-terminal latch. The first write through this
// wrapper is by definition the buyer-visible terminal (net/http discards any
// later status), so the same one-shot gate that stamps the marker publishes
// the claim to the request arbiter (terminal_arbiter.go). The sync.Once became
// mu+claimed only so the already-claimed branch can record the late write; the
// marker decision body itself is preserved verbatim in stampNoChargeMarker —
// settlementNoPriorDispatchHeader semantics are read by the gateway for
// settle-vs-refund and are pinned by the item-18 tests.
type noPriorDispatchResponseWriter struct {
	http.ResponseWriter
	rec *billingRecorder

	mu      sync.Mutex
	claimed bool
}

func (w *noPriorDispatchResponseWriter) WriteHeader(code int) {
	w.mark(code, true)
	w.ResponseWriter.WriteHeader(code)
}

func (w *noPriorDispatchResponseWriter) Write(b []byte) (int, error) {
	// A Write with no prior WriteHeader is an implicit 200 (net/http default).
	w.mark(http.StatusOK, false)
	return w.ResponseWriter.Write(b)
}

func (w *noPriorDispatchResponseWriter) Flush() {
	w.mark(http.StatusOK, false)
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *noPriorDispatchResponseWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

// mark is the one-shot latch. explicit distinguishes a real status assertion
// (WriteHeader) from the implicit-200 that Write/Flush carry: once the terminal
// is claimed, subsequent body writes and flushes are ordinary response traffic,
// NOT competing terminals, and must not be counted as late writes — otherwise
// buyerTerminalLateTotal would just be a stream-chunk counter. A WriteHeader
// after the latch IS a competing terminal (net/http discards it and logs
// "superfluous WriteHeader"), so it is counted.
func (w *noPriorDispatchResponseWriter) mark(code int, explicit bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.claimed {
		if explicit {
			// Lost the latch: net/http already committed the earlier status,
			// so this terminal is telemetry-only. Never suppressed, never
			// billed against — just counted (#766, observe-only).
			w.rec.noteLateBuyerTerminal(code)
		}
		return
	}
	w.claimed = true
	w.stampNoChargeMarker(code)
	w.rec.claimBuyerTerminal(code)
}

// stampNoChargeMarker is the item-18 marker body, preserved VERBATIM from the
// pre-#766 sync.Once closure. It is extracted only so the terminal claim in
// mark can run unconditionally — the decision logic, the early returns, and
// the header write are byte-identical to the previous implementation.
func (w *noPriorDispatchResponseWriter) stampNoChargeMarker(code int) {
	if w.rec == nil {
		return
	}
	// Any billed prior attempt, or a billable current terminal attempt,
	// means the response must NOT carry the no-charge marker.
	if w.rec.providerCredited {
		return
	}
	if w.rec.dispatchedThisAttempt && code != http.StatusServiceUnavailable {
		return
	}
	w.Header().Set(settlementNoPriorDispatchHeader, "1")
}

func writePhaseTimingHeaders(h http.Header, state *forwardState, now time.Time) {
	if state == nil {
		return
	}
	snap := state.phaseTiming.snapshot()
	h.Set(phaseTimingCoordRoutingHeader, strconv.FormatInt(durationMillisBetween(snap.requestStart, snap.coordRoutingDone), 10))
	h.Set(phaseTimingCoordAdmissionHeader, strconv.FormatInt(durationMillis(state.queueWait), 10))
	h.Set(phaseTimingProviderDispatchHeader, strconv.FormatInt(durationMillisBetween(snap.providerDispatchStart, snap.providerDispatchDone), 10))
	h.Set(phaseTimingProviderPrefillHeader, strconv.FormatInt(durationMillisBetween(snap.providerDispatchDone, snap.providerFirstByte), 10))
	h.Set(phaseTimingProviderDecodeHeader, strconv.FormatInt(durationMillisBetween(snap.providerFirstByte, snap.providerDone), 10))
	h.Set(phaseTimingCoordinatorTotalHeader, strconv.FormatInt(durationMillisBetween(snap.requestStart, now), 10))
}

func writePhaseTimingTrailers(h http.Header, state *forwardState, now time.Time) {
	if state == nil {
		return
	}
	snap := state.phaseTiming.snapshot()
	h.Set(http.TrailerPrefix+phaseTimingProviderDecodeHeader, strconv.FormatInt(durationMillisBetween(snap.providerFirstByte, snap.providerDone), 10))
	h.Set(http.TrailerPrefix+phaseTimingCoordinatorTotalHeader, strconv.FormatInt(durationMillisBetween(snap.requestStart, now), 10))
}

func durationMillisBetween(start, end time.Time) int64 {
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return 0
	}
	return durationMillis(end.Sub(start))
}

func nullableDurationMillisBetween(start, end time.Time) *float64 {
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return nil
	}
	ms := float64(durationMillis(end.Sub(start)))
	return &ms
}

func (snap requestPhaseTimingSnapshot) requestLogTTFTMs() *float64 {
	return nullableDurationMillisBetween(snap.providerDispatchDone, snap.providerFirstByte)
}

func (snap requestPhaseTimingSnapshot) requestLogDecodeMs() *float64 {
	return nullableDurationMillisBetween(snap.providerFirstByte, snap.providerDone)
}

func (snap requestPhaseTimingSnapshot) matchesProviderAssignedID(providerAssignedID string) bool {
	return providerAssignedID != "" && snap.providerAssignedID == providerAssignedID
}

func durationMillis(d time.Duration) int64 {
	if d <= 0 {
		return 0
	}
	return d.Milliseconds()
}

func phaseTimingNow(s *Server) time.Time {
	if s != nil && s.now != nil {
		return s.now()
	}
	return time.Now()
}

type firstByteTimingReader struct {
	r      io.Reader
	mark   func()
	marked bool
}

func (r *firstByteTimingReader) Read(p []byte) (int, error) {
	n, err := r.r.Read(p)
	if n > 0 && !r.marked {
		r.marked = true
		r.mark()
	}
	return n, err
}
