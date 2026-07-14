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

func (t *requestPhaseTiming) markProviderDispatchStart(at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.providerDispatchStart = at
	t.providerDispatchDone = time.Time{}
	t.providerFirstByte = time.Time{}
	t.providerDone = time.Time{}
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
	}
}

type requestPhaseTimingSnapshot struct {
	requestStart          time.Time
	coordRoutingDone      time.Time
	providerDispatchStart time.Time
	providerDispatchDone  time.Time
	providerFirstByte     time.Time
	providerDone          time.Time
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
type noPriorDispatchResponseWriter struct {
	http.ResponseWriter
	rec  *billingRecorder
	once sync.Once
}

func (w *noPriorDispatchResponseWriter) WriteHeader(code int) {
	w.mark(code)
	w.ResponseWriter.WriteHeader(code)
}

func (w *noPriorDispatchResponseWriter) Write(b []byte) (int, error) {
	// A Write with no prior WriteHeader is an implicit 200 (net/http default).
	w.mark(http.StatusOK)
	return w.ResponseWriter.Write(b)
}

func (w *noPriorDispatchResponseWriter) Flush() {
	w.mark(http.StatusOK)
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *noPriorDispatchResponseWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func (w *noPriorDispatchResponseWriter) mark(code int) {
	w.once.Do(func() {
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
	})
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
