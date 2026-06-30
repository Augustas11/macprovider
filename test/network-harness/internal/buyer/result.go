package buyer

import "time"

// Result captures everything observable about one buyer request,
// regardless of success or failure. One row per request_id.
//
// Field choice is governed by what the 4 hard invariants need plus
// what phase-A triage will look at — provider route, per-request
// latency shape, error taxonomy, and the byte/token timeline needed
// to detect silent hangs (I4) and overcharges (I3).
type Result struct {
	// Identity
	RequestID    string    `json:"request_id"`
	BuyerIndex   int       `json:"buyer_index"`
	RequestIndex int       `json:"request_index"`
	Model        string    `json:"model"`
	StartUTC     time.Time `json:"start_utc"`
	EndUTC       time.Time `json:"end_utc"`

	// Timing (zero values when not observed — e.g. TTFTMillis is 0 on
	// non-streaming or when the request failed before first byte).
	TTFTMillis  int64 `json:"ttft_ms"`
	TotalMillis int64 `json:"total_ms"`

	// Bytes & tokens observed on the wire by the harness.
	// CompletionTokensReceived is parsed from SSE chunks for streaming;
	// from the `usage` block for non-streaming. Used by I3.
	BytesReceived            int64 `json:"bytes_received"`
	CompletionTokensReceived int64 `json:"completion_tokens_received"`
	PromptTokensReported     int64 `json:"prompt_tokens_reported"`

	// HTTP outcome.
	HTTPStatus int    `json:"http_status"`
	Outcome    string `json:"outcome"` // ok | http_error | transport_error | timeout | silent_hang | client_abort

	// Error detail (empty on Outcome=ok).
	ErrorCode string `json:"error_code,omitempty"`
	ErrorMsg  string `json:"error_msg,omitempty"`

	// Route attribution. Populated from response headers exposed by the
	// gateway (X-Provider-ID / X-Provider-Assigned-ID if present). Phase
	// A may not know these — leave empty if absent, triage will tell us
	// to plumb them through.
	RouteProviderID string `json:"route_provider_id,omitempty"`
	RouteHeader     string `json:"route_header,omitempty"`

	// LastByteUTC tracks the most recent byte seen on the wire. I4 uses
	// (EndUTC - LastByteUTC) on long-running streams to spot silent
	// hangs even when the request "technically completes."
	LastByteUTC time.Time `json:"last_byte_utc"`

	// Stream tells the invariants layer whether SSE semantics applied.
	Stream bool `json:"stream"`

	// SawTerminator is true when the SSE stream ended with the explicit
	// `data: [DONE]` marker (streaming) or when a complete JSON response
	// was parsed (non-streaming). False + Outcome=ok is suspicious and
	// I4 may flag it.
	SawTerminator bool `json:"saw_terminator"`

	// SawSSEErrorEvent is true when the SSE stream's final data chunk
	// before `[DONE]` (or EOF) was a STANDALONE terminal error envelope
	// — `{"error": {"code": "...", ...}}` with no `choices` and no
	// `usage` tokens. This shape matches the gateway's writeSSEError and
	// writeStructuredOutputTimeoutSSE helpers in chat_proxy.go.
	//
	// Used by the reconciler (#232) to corroborate fallback outcome
	// labels — the gateway's outcome label alone is a trust gate, but
	// satisfying this bit requires the gateway to actually present the
	// buyer with a standalone terminal error envelope as the LAST data
	// frame before `[DONE]` or EOF. Post-`[DONE]` envelopes are
	// invisible to OpenAI-style clients (and to this parser per #232
	// R3) and do not corroborate. Leading-whitespace forged envelopes
	// are dropped by the strict SSE field-line parser per #232 R4.
	//
	// Tightening (#232 R2 SEC HIGH): position-aware. An attacker who
	// injects `"error":{"code":"..."}` into a normal-looking content
	// chunk (with `choices`/`usage`) does NOT flip this bit — that's
	// not a standalone envelope. An attacker who emits a standalone
	// error envelope but then continues with content chunks does NOT
	// flip this bit either — the LAST data chunk before the terminator
	// must be the envelope. Either bypass requires the gateway to
	// present the buyer with a stream that actually ends in a visible
	// failure event.
	//
	// Streaming-only. Non-streaming responses never set this; for those,
	// the gateway returns HTTP 4xx/5xx instead of an SSE error envelope,
	// and HTTPStatus + Outcome handle the classification.
	SawSSEErrorEvent bool `json:"saw_sse_error_event"`

	// SSEErrorCode carries the `error.code` value the gateway sent in
	// the terminal error envelope (e.g. "stream_truncated",
	// "stream_output_exceeded", "stream_malformed", "provider_timeout",
	// "provider_disconnected"). Empty when SawSSEErrorEvent is false.
	// Triage cross-checks the buyer-visible code against the gateway's
	// `outcome` column in usage_events. (#232 R2 ARCH LOW.)
	SSEErrorCode string `json:"sse_error_code,omitempty"`

	// Phase tags requests fired under the cold_warm_pairs pattern:
	// "cold" for the first request after each idle gap, "warm" for the
	// immediately-following request in the same pair. Empty for all
	// other patterns. Drives the B7 (TTFT cold/warm ratio) verdict.
	Phase string `json:"phase,omitempty"`
}
