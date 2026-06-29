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

	// Phase tags requests fired under the cold_warm_pairs pattern:
	// "cold" for the first request after each idle gap, "warm" for the
	// immediately-following request in the same pair. Empty for all
	// other patterns. Drives the B7 (TTFT cold/warm ratio) verdict.
	Phase string `json:"phase,omitempty"`
}
