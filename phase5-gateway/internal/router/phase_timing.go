package router

import (
	"net/http"
	"strconv"
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

type gatewayPhaseTiming struct {
	startedAt             time.Time
	coordinatorStartAt    time.Time
	coordinatorResponseAt time.Time
	firstTokenAt          time.Time

	coordRoutingMS     int64
	coordAdmissionMS   int64
	providerDispatchMS int64
	providerPrefillMS  int64
	providerDecodeMS   int64
	coordinatorTotalMS int64
}

func newGatewayPhaseTiming(start time.Time) *gatewayPhaseTiming {
	return &gatewayPhaseTiming{startedAt: start}
}

func (t *gatewayPhaseTiming) markCoordinatorStart(at time.Time) {
	t.coordinatorStartAt = at
}

func (t *gatewayPhaseTiming) markFirstToken(at time.Time) {
	if t == nil || !t.firstTokenAt.IsZero() {
		return
	}
	t.firstTokenAt = at
}

func (t *gatewayPhaseTiming) observeCoordinatorResponse(h http.Header, at time.Time) {
	t.coordinatorResponseAt = at
	t.observeCoordinatorTimings(h)
}

func (t *gatewayPhaseTiming) observeCoordinatorTrailers(h http.Header) {
	t.observeCoordinatorTimings(h)
}

func (t *gatewayPhaseTiming) observeCoordinatorTimings(h http.Header) {
	setHeaderMillis(h, phaseTimingCoordRoutingHeader, &t.coordRoutingMS)
	setHeaderMillis(h, phaseTimingCoordAdmissionHeader, &t.coordAdmissionMS)
	setHeaderMillis(h, phaseTimingProviderDispatchHeader, &t.providerDispatchMS)
	setHeaderMillis(h, phaseTimingProviderPrefillHeader, &t.providerPrefillMS)
	setHeaderMillis(h, phaseTimingProviderDecodeHeader, &t.providerDecodeMS)
	setHeaderMillis(h, phaseTimingCoordinatorTotalHeader, &t.coordinatorTotalMS)
}

type demandTimingSnapshot struct {
	queueLatencyMS                   int64
	timeToFirstTokenMS               int64
	providerPrefillMS                int64
	providerDecodeMS                 int64
	outputTokensPerSecondMilliTokens int64
}

func (t *gatewayPhaseTiming) demandSnapshot(completionTokens int64) demandTimingSnapshot {
	if t == nil {
		return demandTimingSnapshot{}
	}
	queueMS := t.coordAdmissionMS
	ttftMS := millisBetween(t.startedAt, t.firstTokenAt)
	if ttftMS == 0 && t.providerPrefillMS > 0 {
		ttftMS = t.coordRoutingMS + t.coordAdmissionMS + t.providerDispatchMS + t.providerPrefillMS
	}
	decodeMS := t.providerDecodeMS
	throughputMilliTokens := int64(0)
	if completionTokens > 0 && decodeMS > 0 {
		throughputMilliTokens = completionTokens * 1_000_000 / decodeMS
	}
	return demandTimingSnapshot{
		queueLatencyMS:                   queueMS,
		timeToFirstTokenMS:               ttftMS,
		providerPrefillMS:                t.providerPrefillMS,
		providerDecodeMS:                 decodeMS,
		outputTokensPerSecondMilliTokens: throughputMilliTokens,
	}
}

func (t *gatewayPhaseTiming) attrs(now time.Time) []any {
	return []any{
		"timing_dns_ms", int64(0),
		"timing_tls_ms", int64(0),
		"timing_gateway_queue_ms", millisBetween(t.startedAt, t.coordinatorStartAt),
		"timing_coord_admission_ms", t.coordAdmissionMS,
		"timing_ws_send_ms", t.providerDispatchMS,
		"timing_provider_prefill_ms", t.providerPrefillMS,
		"timing_provider_decode_ms", t.providerDecodeMS,
		"timing_flush_ms", millisBetween(t.coordinatorResponseAt, now),
		"timing_coord_routing_ms", t.coordRoutingMS,
		"timing_coord_total_ms", t.coordinatorTotalMS,
	}
}

func headerMillis(h http.Header, name string) int64 {
	value, err := strconv.ParseInt(h.Get(name), 10, 64)
	if err != nil || value < 0 {
		return 0
	}
	return value
}

func setHeaderMillis(h http.Header, name string, dst *int64) {
	if h.Get(name) == "" {
		return
	}
	*dst = headerMillis(h, name)
}

func millisBetween(start, end time.Time) int64 {
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return 0
	}
	return end.Sub(start).Milliseconds()
}
