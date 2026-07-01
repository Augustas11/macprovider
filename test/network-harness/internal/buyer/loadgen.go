// Package buyer runs the concurrent buyer fleet for a scenario.
package buyer

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// Run spawns Buyers.Count goroutines and fires Buyers.RequestsPerBuyer
// requests per goroutine according to Buyers.Pattern. It returns one
// Result per request (success or failure), in the order they completed.
//
// Run honors ctx cancellation — SIGINT during a 5-minute scenario will
// stop new requests, allow in-flight ones to complete with their normal
// timeouts, and return the partial results.
func Run(ctx context.Context, sc *scenario.Scenario) ([]Result, error) {
	if sc.Buyers.Count < 1 {
		return nil, fmt.Errorf("buyers.count must be >= 1")
	}

	deadline := time.Time{}
	if sc.Duration > 0 {
		deadline = time.Now().Add(sc.Duration)
	}

	var (
		mu      sync.Mutex
		results = make([]Result, 0, sc.Buyers.Count*sc.Buyers.RequestsPerBuyer)
		wg      sync.WaitGroup
	)

	// Per-buyer HTTP client — gateway calls don't share connection
	// affinity. We disable HTTP/2 push of automatic retries because the
	// invariants need to observe the FIRST failure, not a transparently
	// retried success.
	transport := &http.Transport{
		MaxIdleConnsPerHost:   sc.Buyers.Count,
		ResponseHeaderTimeout: sc.RequestTimeout,
		DisableCompression:    false,
	}

	for i := 0; i < sc.Buyers.Count; i++ {
		buyerIdx := i

		// Ramp pattern: stagger goroutine starts across RampDuration.
		startAfter := time.Duration(0)
		if sc.Buyers.Pattern == "ramp" && sc.Buyers.Count > 1 {
			startAfter = sc.Buyers.RampDuration * time.Duration(buyerIdx) / time.Duration(sc.Buyers.Count-1)
		}

		wg.Add(1)
		go func() {
			defer wg.Done()

			if startAfter > 0 {
				select {
				case <-time.After(startAfter):
				case <-ctx.Done():
					return
				}
			}

			client := &http.Client{
				Transport: transport,
				Timeout:   sc.RequestTimeout,
			}

			for reqIdx := 0; reqIdx < sc.Buyers.RequestsPerBuyer; reqIdx++ {
				if ctx.Err() != nil {
					return
				}
				if !deadline.IsZero() && time.Now().After(deadline) {
					return
				}

				// cold_warm_pairs: each (cold, warm) pair is two consecutive
				// requests. Even reqIdx > 0 → idle before firing the next
				// "cold". Odd reqIdx → fire immediately as "warm". The first
				// cold (reqIdx=0) fires without a leading idle since the
				// provider is in its natural state when the scenario starts.
				if sc.Buyers.Pattern == "cold_warm_pairs" && reqIdx > 0 && reqIdx%2 == 0 {
					select {
					case <-time.After(time.Duration(sc.Buyers.InterPairIdleSeconds) * time.Second):
					case <-ctx.Done():
						return
					}
				}

				prompt := sc.PromptFor(buyerIdx, reqIdx)
				res := fireOnce(ctx, client, sc, prompt, buyerIdx, reqIdx)
				if sc.Buyers.Pattern == "cold_warm_pairs" {
					if reqIdx%2 == 0 {
						res.Phase = "cold"
					} else {
						res.Phase = "warm"
					}
				}

				mu.Lock()
				results = append(results, res)
				mu.Unlock()

				if sc.Buyers.Pattern == "burst" {
					return
				}
				if sc.Buyers.Pattern == "interval" && sc.Buyers.IntervalMs > 0 {
					select {
					case <-time.After(time.Duration(sc.Buyers.IntervalMs) * time.Millisecond):
					case <-ctx.Done():
						return
					}
				}
			}
		}()
	}

	wg.Wait()
	return results, nil
}

func fireOnce(ctx context.Context, client *http.Client, sc *scenario.Scenario, p scenario.Prompt, buyerIdx, reqIdx int) Result {
	res := Result{
		BuyerIndex:   buyerIdx,
		RequestIndex: reqIdx,
		Model:        p.Model,
		Stream:       sc.Buyers.Stream,
		StartUTC:     time.Now().UTC(),
		Outcome:      "transport_error",
	}

	body, err := buildBody(p, sc.Buyers.Stream)
	if err != nil {
		res.EndUTC = time.Now().UTC()
		res.TotalMillis = res.EndUTC.Sub(res.StartUTC).Milliseconds()
		res.ErrorCode = "build_body"
		res.ErrorMsg = err.Error()
		return res
	}

	reqCtx, cancel := context.WithTimeout(ctx, sc.RequestTimeout)
	defer cancel()

	url := strings.TrimRight(sc.Target.GatewayURL, "/") + "/v1/chat/completions"
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		res.EndUTC = time.Now().UTC()
		res.TotalMillis = res.EndUTC.Sub(res.StartUTC).Milliseconds()
		res.ErrorCode = "build_request"
		res.ErrorMsg = err.Error()
		return res
	}
	req.Header.Set("Content-Type", "application/json")
	if sc.Buyers.Stream {
		req.Header.Set("Accept", "text/event-stream")
	} else {
		req.Header.Set("Accept", "application/json")
	}
	if sc.Target.BuyerToken != "" {
		req.Header.Set("Authorization", "Bearer "+sc.Target.BuyerToken)
	}
	if sc.Target.DemoIdentity != "" {
		req.Header.Set("X-Demo-Identity", sc.Target.DemoIdentity)
	}
	// Stamp a harness-side correlation hint. Gateways that pass it
	// through become reconcilable by this id; gateways that don't,
	// the harness falls back to ts-range correlation in reconcile/.
	hReqID := fmt.Sprintf("harness-%d-%d-%d", buyerIdx, reqIdx, res.StartUTC.UnixNano())
	req.Header.Set("X-Request-Id", hReqID)
	res.RequestID = hReqID

	resp, err := client.Do(req)
	if err != nil {
		res.EndUTC = time.Now().UTC()
		res.TotalMillis = res.EndUTC.Sub(res.StartUTC).Milliseconds()
		res.ErrorCode = "transport"
		res.ErrorMsg = err.Error()
		if reqCtx.Err() == context.DeadlineExceeded {
			res.Outcome = "timeout"
			res.ErrorCode = "timeout"
		} else if ctx.Err() == context.Canceled {
			res.Outcome = "client_abort"
		}
		return res
	}
	defer resp.Body.Close()

	res.HTTPStatus = resp.StatusCode
	// Capture gateway-issued request id if it overrode ours.
	if gwID := resp.Header.Get("X-Request-Id"); gwID != "" {
		res.RequestID = gwID
	}
	// Provider attribution headers — names are speculative; whichever
	// is present, capture it. Triage will tell us which to standardize on.
	for _, h := range []string{"X-Provider-Id", "X-Provider-ID", "X-Provider-Assigned-Id", "X-Route-Provider"} {
		if v := resp.Header.Get(h); v != "" {
			res.RouteHeader = h
			res.RouteProviderID = v
			break
		}
	}

	if sc.Buyers.Stream && isSSE(resp) {
		consumeSSE(resp.Body, &res)
	} else {
		consumeJSON(resp.Body, &res)
	}

	res.EndUTC = time.Now().UTC()
	res.TotalMillis = res.EndUTC.Sub(res.StartUTC).Milliseconds()

	if res.Outcome == "transport_error" {
		switch {
		case resp.StatusCode >= 500:
			res.Outcome = "http_error"
			if res.ErrorCode == "" {
				res.ErrorCode = fmt.Sprintf("http_%d", resp.StatusCode)
			}
		case resp.StatusCode >= 400:
			res.Outcome = "http_error"
			if res.ErrorCode == "" {
				res.ErrorCode = fmt.Sprintf("http_%d", resp.StatusCode)
			}
		default:
			res.Outcome = "ok"
		}
	}

	return res
}

func buildBody(p scenario.Prompt, stream bool) ([]byte, error) {
	msgs := []map[string]string{}
	if p.System != "" {
		msgs = append(msgs, map[string]string{"role": "system", "content": p.System})
	}
	msgs = append(msgs, map[string]string{"role": "user", "content": p.User})
	req := map[string]any{
		"model":    p.Model,
		"messages": msgs,
		"stream":   stream,
	}
	if p.MaxTokens > 0 {
		req["max_tokens"] = p.MaxTokens
	}
	return json.Marshal(req)
}

func isSSE(resp *http.Response) bool {
	ct := resp.Header.Get("Content-Type")
	return strings.HasPrefix(ct, "text/event-stream")
}

// consumeSSE reads the SSE stream, recording TTFT, byte count, token
// count parsed from each dispatched SSE event's usage field if present,
// the "[DONE]" terminator, and (#232) whether the final DISPATCHED SSE
// event before terminator or EOF was a standalone error envelope.
// Errors mid-stream are recorded but do not panic.
//
// Parser model (#232 R8 SEC HIGH): fully event-boundary. Data payloads
// are accumulated into `eventBuf`; classification (`[DONE]` terminator,
// standalone error envelope, content/usage chunk, or unparseable
// merged garbage) happens ONLY when a blank line dispatches the event.
// A pending event with no blank-line terminator (EOF or transport
// error) is DISCARDED per HTML5/SSE spec, matching what OpenAI's
// Python/Node clients and browser EventSource do. This closes the full
// class of "buyer sees X, harness sees Y" attacks that arise when
// classification is done at line-read time instead of event-dispatch
// time.
func consumeSSE(body io.Reader, res *Result) {
	reader := bufio.NewReader(body)
	firstByte := true
	bomConsumed := false
	// eventBuf accumulates the current SSE event's data payload. Per
	// SSE spec, consecutive `data:` field lines concatenate with `\n`
	// separators; the event is dispatched on the first blank line and
	// discarded on EOF without a terminating blank line.
	var eventBuf []byte
	// lastDispatchedWasEnvelope + lastDispatchedErrorCode track the
	// most-recently DISPATCHED event's classification. Only the last
	// dispatched event before `[DONE]` or EOF can corroborate the
	// gateway's fallback outcome.
	lastDispatchedWasEnvelope := false
	var lastDispatchedErrorCode string
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			now := time.Now().UTC()
			res.LastByteUTC = now
			if firstByte {
				res.TTFTMillis = now.Sub(res.StartUTC).Milliseconds()
				firstByte = false
			}
			res.BytesReceived += int64(len(line))
			// #232 R5 SEC HIGH-1: strip a leading UTF-8 BOM (U+FEFF =
			// EF BB BF) at stream start. Per the WHATWG SSE spec the
			// BOM is removed before line parsing.
			workLine := line
			if !bomConsumed {
				bomConsumed = true
				if len(workLine) >= 3 && workLine[0] == 0xEF && workLine[1] == 0xBB && workLine[2] == 0xBF {
					workLine = workLine[3:]
				}
			}
			// #232 R4 SEC HIGH — strict SSE field parsing. The HTML5
			// SSE spec requires field lines to start at column 0; any
			// leading whitespace makes the line an unrecognized non-
			// field line that a strict client (and browser EventSource)
			// ignores. We strip ONLY the trailing CR/LF, then require
			// `data:` at column 0. After the colon, the spec allows at
			// most one optional space before the value.
			fieldLine := workLine
			for len(fieldLine) > 0 && (fieldLine[len(fieldLine)-1] == '\n' || fieldLine[len(fieldLine)-1] == '\r') {
				fieldLine = fieldLine[:len(fieldLine)-1]
			}
			if len(fieldLine) == 0 {
				// Blank line: dispatch the current event, if any.
				if len(eventBuf) > 0 {
					if bytes.Equal(eventBuf, []byte("[DONE]")) {
						// A standalone dispatched `[DONE]` event is the
						// terminator. Corroborate ONLY if the previously
						// dispatched event was a standalone error
						// envelope.
						res.SawTerminator = true
						if lastDispatchedWasEnvelope {
							res.SawSSEErrorEvent = true
							res.SSEErrorCode = lastDispatchedErrorCode
						}
						return
					}
					code, isStandalone := parseChunkTokens(eventBuf, res)
					if isStandalone {
						lastDispatchedWasEnvelope = true
						lastDispatchedErrorCode = code
					} else {
						lastDispatchedWasEnvelope = false
						lastDispatchedErrorCode = ""
					}
					eventBuf = eventBuf[:0]
				}
				continue
			}
			if bytes.HasPrefix(fieldLine, []byte("data:")) {
				payload := fieldLine[len("data:"):]
				if len(payload) > 0 && payload[0] == ' ' {
					payload = payload[1:]
				}
				// Append to current event buffer. Per SSE spec,
				// consecutive `data:` lines concatenate with `\n`.
				// Classification is deferred to blank-line dispatch —
				// a `data: [DONE]` line here does NOT terminate; it is
				// merely appended, and only becomes a terminator if the
				// dispatched event's full data equals exactly `[DONE]`.
				// (#232 R8 SEC HIGH — closes the symmetric leading-
				// `[DONE]` attack: `data: [DONE]\ndata: {content}\n\n`
				// dispatches ONE event with data `[DONE]\n{content}`,
				// which is neither a terminator nor an envelope.)
				if len(eventBuf) > 0 {
					eventBuf = append(eventBuf, '\n')
				}
				eventBuf = append(eventBuf, payload...)
			}
			// Non-data field lines (event:, id:, retry:) and non-field
			// lines are ignored — none of them affect corroboration.
		}
		if err != nil {
			if err == io.EOF {
				// EOF: any pending event (non-empty eventBuf without a
				// terminating blank line) is DISCARDED per SSE spec.
				// Corroborate ONLY if the last DISPATCHED event was a
				// standalone error envelope. This closes the EOF variant
				// of the R8 leading-`[DONE]` attack: `data: [DONE]\n<EOF>`
				// has no blank-line dispatch, so the pending `[DONE]`
				// event is discarded — no terminator, no corroboration.
				if lastDispatchedWasEnvelope {
					res.SawSSEErrorEvent = true
					res.SSEErrorCode = lastDispatchedErrorCode
				}
				return
			}
			// Mid-stream read failure. Phase A records the outcome; I4
			// inspects (now - LastByteUTC) vs SilentHangThreshold.
			res.Outcome = "transport_error"
			res.ErrorCode = "stream_read"
			res.ErrorMsg = err.Error()
			return
		}
	}
}

// chunkPayload is a partial decode — we only need the bits relevant to
// the invariants (token counts, terminal error envelope) and route
// attribution. Other fields are preserved as-is by the SSE byte counter.
type chunkPayload struct {
	Usage struct {
		PromptTokens     int64 `json:"prompt_tokens"`
		CompletionTokens int64 `json:"completion_tokens"`
	} `json:"usage"`
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	// Error is the OpenAI-style terminal error envelope the gateway
	// emits on fallback paths via writeSSEError before `data: [DONE]`.
	// Issue #232: presence of this field on the FINAL data chunk before
	// `[DONE]`/EOF (and ONLY as a standalone envelope) is the buyer-
	// side corroboration the reconciler uses to verify the gateway's
	// fallback outcome label.
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
		Code    string `json:"code"`
	} `json:"error,omitempty"`
}

// parseChunkTokens decodes a single SSE chunk's `data:` payload and
// updates `res` with any token counts the chunk carried. It returns
// the chunk's classification for #232 corroboration tracking:
//
//   - code: the non-empty `error.code` value if the chunk is a
//     STANDALONE error envelope; "" otherwise.
//   - isStandaloneError: true ONLY if the chunk has a non-empty
//     `error.code` AND no `choices` AND no `usage` tokens.
//
// The caller in consumeSSE tracks whether the LAST data chunk before
// `[DONE]`/EOF was a standalone error envelope; only that position
// flips `Result.SawSSEErrorEvent`. This makes the corroboration bit
// position-aware so that injecting `"error":{"code":"..."}` into a
// content-bearing chunk or before more content chunks does not
// satisfy the buyer-corroboration check. (#232 R2 SEC HIGH.)
func parseChunkTokens(payload []byte, res *Result) (code string, isStandaloneError bool) {
	var c chunkPayload
	if err := json.Unmarshal(payload, &c); err != nil {
		return "", false
	}
	if c.Usage.CompletionTokens > 0 {
		res.CompletionTokensReceived = c.Usage.CompletionTokens
	}
	if c.Usage.PromptTokens > 0 {
		res.PromptTokensReported = c.Usage.PromptTokens
	}
	// Standalone terminal-envelope shape: error.code present AND no
	// choices AND no usage tokens. Both writeSSEError and
	// writeStructuredOutputTimeoutSSE emit chunks of this exact shape
	// — see phase5-gateway/internal/router/chat_proxy.go:1239 / :1256.
	if c.Error != nil && c.Error.Code != "" &&
		len(c.Choices) == 0 &&
		c.Usage.CompletionTokens == 0 &&
		c.Usage.PromptTokens == 0 {
		return c.Error.Code, true
	}
	return "", false
}

func consumeJSON(body io.Reader, res *Result) {
	b, err := io.ReadAll(body)
	res.BytesReceived = int64(len(b))
	if len(b) > 0 {
		res.LastByteUTC = time.Now().UTC()
		res.TTFTMillis = res.LastByteUTC.Sub(res.StartUTC).Milliseconds()
	}
	if err != nil {
		res.Outcome = "transport_error"
		res.ErrorCode = "json_read"
		res.ErrorMsg = err.Error()
		return
	}
	var c chunkPayload
	if err := json.Unmarshal(b, &c); err == nil {
		if c.Usage.CompletionTokens > 0 {
			res.CompletionTokensReceived = c.Usage.CompletionTokens
		}
		if c.Usage.PromptTokens > 0 {
			res.PromptTokensReported = c.Usage.PromptTokens
		}
		res.SawTerminator = true
	}
}
