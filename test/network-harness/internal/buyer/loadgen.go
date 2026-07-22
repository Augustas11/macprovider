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
	if sc.Buyers.Count > scenario.MaxBuyerCount {
		return nil, fmt.Errorf("buyers.count must be <= %d", scenario.MaxBuyerCount)
	}
	if sc.Buyers.RequestsPerBuyer < 1 {
		return nil, fmt.Errorf("buyers.requests_per_buyer must be >= 1")
	}
	if sc.Buyers.RequestsPerBuyer > scenario.MaxRequestsPerBuyer {
		return nil, fmt.Errorf("buyers.requests_per_buyer must be <= %d", scenario.MaxRequestsPerBuyer)
	}
	if sc.Buyers.Count > scenario.MaxTotalBuyerRequests/sc.Buyers.RequestsPerBuyer {
		return nil, fmt.Errorf("buyers.count * buyers.requests_per_buyer must be <= %d", scenario.MaxTotalBuyerRequests)
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
		startAfter := sc.Buyers.InitialDelay
		if sc.Buyers.Pattern == "ramp" && sc.Buyers.Count > 1 {
			startAfter += sc.Buyers.RampDuration * time.Duration(buyerIdx) / time.Duration(sc.Buyers.Count-1)
		}

		wg.Add(1)
		go func() {
			defer wg.Done()

			if startAfter > 0 {
				ok, interrupted := waitForDispatchDelay(ctx, startAfter, deadline)
				if interrupted || !ok {
					return
				}
			}

			client := &http.Client{
				Transport: transport,
				Timeout:   sc.RequestTimeout,
			}
			// LAB-ONLY redirect guard for B10 soaks: even though the
			// configured URLs are validated as lab addresses, a lab gateway
			// that 3xx-redirects could otherwise send the sustained load to a
			// public host (e.g. prod). Refuse any redirect whose destination
			// is not itself a lab address, so the soak can never reach prod
			// via a redirect (#584).
			if sc.BenchmarkHasB10() {
				client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
					if !scenario.LabHostAllowed(req.URL.Hostname()) {
						return fmt.Errorf("B10 soak refused redirect to non-lab host %q (#584)", req.URL.Hostname())
					}
					if len(via) >= 10 {
						return fmt.Errorf("stopped after 10 redirects")
					}
					return nil
				}
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
					ok, interrupted := waitForDispatchDelay(ctx, time.Duration(sc.Buyers.InterPairIdleSeconds)*time.Second, deadline)
					if interrupted || !ok {
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
					ok, interrupted := waitForDispatchDelay(ctx, time.Duration(sc.Buyers.IntervalMs)*time.Millisecond, deadline)
					if interrupted || !ok {
						return
					}
				}
			}
		}()
	}

	wg.Wait()
	return results, nil
}

func waitForDispatchDelay(ctx context.Context, delay time.Duration, deadline time.Time) (ok bool, interrupted bool) {
	if delay <= 0 {
		return true, false
	}
	waitUntil := time.Now().Add(delay)
	if !deadline.IsZero() && waitUntil.After(deadline) {
		waitUntil = deadline
	}
	wait := time.Until(waitUntil)
	if wait <= 0 {
		return !deadlineExpired(deadline), false
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return deadlineExpired(deadline) == false, false
	case <-ctx.Done():
		return false, true
	}
}

func deadlineExpired(deadline time.Time) bool {
	return !deadline.IsZero() && !time.Now().Before(deadline)
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

	// SPEC-004 Pillar A sticky affinity — per-buyer conversation tag.
	// Gateway (with routing.sticky_enabled=true and key_hash_secret set)
	// derives an HMAC internal key from (account_id, tag) and forwards
	// it to coord as X-MacProvider-Internal-Conv. Coord routes by that
	// key when its own routing.sticky_enabled is true. Empty template =
	// header not emitted, sticky path stays inert.
	if sc.Buyers.StickyConversationKey != "" {
		req.Header.Set("X-MacProvider-Conversation", fmt.Sprintf(sc.Buyers.StickyConversationKey, buyerIdx))
	}

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
//
// Terminator predicate (#232 R9 SEC HIGH-2): OpenAI Python/Node SDK
// use `sse.data.startswith("[DONE]")`, not exact equality. The
// harness matches that: `bytes.HasPrefix(eventBuf, "[DONE]")` on
// dispatch. Exact equality left `data: [DONE] \n\ndata: forged\n\n`
// (trailing whitespace) and `data: [DONE]\ndata: X\n\n` (merged
// event) unterminated on the harness while the buyer's SDK
// terminated — reopening the R3 post-terminator forgery class for
// SDK parity. Prefix matching aligns both sides.
//
// Line-ending scope: `\n` and `\r\n` are handled by trimming trailing
// CR/LF. Bare `\r` line endings (WHATWG SSE permits them) are NOT
// handled. OpenAI Python/Node SDKs DO handle bare-CR event separation
// (SEC R10 LOW correction), but production gateway code emits `\n`
// exclusively (see writeSSEError / writeStructuredOutputTimeoutSSE in
// chat_proxy.go). The remaining shape mismatch is conservative for
// corroboration: a bare-CR-only stream the SDK dispatches as multiple
// events, the harness treats as one long line — making corroboration
// LESS likely, not more. No known suppression-bypass attack path.
// Deferred (SEC R9 LOW → R10 LOW correction) as out-of-scope for
// #232 corroboration correctness.
func consumeSSE(body io.Reader, res *Result) {
	reader := bufio.NewReader(body)
	firstByte := true
	bomConsumed := false
	// eventBuf accumulates the current SSE event's data payload. Per
	// SSE spec, consecutive `data:` field lines concatenate with `\n`
	// separators; the event is dispatched on the first blank line and
	// discarded on EOF without a terminating blank line.
	var eventBuf []byte
	// eventHasData tracks whether the current event has received AT
	// LEAST ONE `data:` field line — including empty ones. Per SSE
	// spec, `data:\n\n` dispatches an event whose data is the empty
	// string; `data:\ndata: [DONE]\n\n` dispatches an event whose
	// data is `\n[DONE]` (NOT a terminator). Tracking this separately
	// from `len(eventBuf) > 0` is required to (a) insert the `\n`
	// separator between data lines when the FIRST payload was empty,
	// and (b) reset dispatched-envelope state on intermediate empty
	// events. (#232 R9 CODE HIGH — closes the "empty leading data:"
	// terminator-bypass class.)
	eventHasData := false
	// currentEventName tracks the SSE event name for the current
	// pending event (set by `event:` field lines). Per SSE spec, this
	// resets on each blank-line dispatch. Corroboration is gated on
	// the default event name (empty or "message"): the OpenAI Python/
	// Node SDK stream decoders route non-default events like
	// `event: thread.*` and `event: response.*` through Assistants /
	// Responses API handlers that do NOT surface `data.error` on the
	// normal chat.completions terminal-envelope path. A malicious
	// gateway sending
	//   event: thread.message.delta
	//   data: {"error":{"code":"stream_truncated",...}}
	//   \n
	//   data: [DONE]
	//   \n
	// would have the buyer's SDK NOT treat the envelope as terminal,
	// but the harness (ignoring event:) would corroborate. (#232 R10
	// SEC HIGH — closes the event-type-forge class.) SPEC-006 §17.7.1
	// pins the terminal envelope to the default chat.completions
	// data path; the gateway's writeSSEError never emits `event:`.
	var currentEventName []byte
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
				// Blank line: dispatch the current event, if any. Per
				// SSE spec, "if any" is gated on `eventHasData`, NOT
				// on `len(eventBuf) > 0`: an event that received ONLY
				// empty `data:` lines dispatches with empty data and
				// still counts as a dispatched event for corroboration
				// state.
				if eventHasData {
					if bytes.HasPrefix(eventBuf, []byte("[DONE]")) {
						// A dispatched event whose data starts with
						// `[DONE]` is the terminator. Prefix match (not
						// exact equality) matches the OpenAI Python/Node
						// SDK behavior (`sse.data.startswith("[DONE]")`),
						// which is the buyer contract SPEC-006 §17.7.1
						// pins. Prefix matters (#232 R9 SEC HIGH-2):
						// exact equality left `data: [DONE] \n\n` (or
						// `data: [DONE]\ndata: forged\n\n`) unterminated
						// on the harness side while OpenAI SDK consumers
						// terminated at the first `[DONE]` prefix — an
						// attacker could then forge a post-terminator
						// envelope invisible to the buyer but visible
						// (and corroborating) to the harness.
						// Corroborate ONLY if the previously dispatched
						// event was a standalone error envelope.
						res.SawTerminator = true
						if lastDispatchedWasEnvelope {
							res.SawSSEErrorEvent = true
							res.SSEErrorCode = lastDispatchedErrorCode
						}
						return
					}
					code, isStandalone := parseChunkTokens(eventBuf, res)
					// Gate corroboration on default event name (empty or
					// "message"). Non-default event names route to
					// non-chat-completion SDK handlers where `data.error`
					// is not surfaced as the terminal envelope the buyer
					// contract pins. (#232 R10 SEC HIGH.)
					if isStandalone && isDefaultEventName(currentEventName) {
						lastDispatchedWasEnvelope = true
						lastDispatchedErrorCode = code
					} else {
						lastDispatchedWasEnvelope = false
						lastDispatchedErrorCode = ""
					}
					eventBuf = eventBuf[:0]
					eventHasData = false
					currentEventName = currentEventName[:0]
				}
				continue
			}
			// Generic WHATWG SSE field parse: split at the first colon.
			// If no colon is present, the entire line is the field name
			// and the value is empty. `data:` and bare `data` both
			// count as a data field — the latter is CODE R10 HIGH:
			// `data\ndata: [DONE]\n\n` dispatches one event with data
			// `\n[DONE]` (not a terminator), and `data: {env}\n\ndata\n\n
			// data: [DONE]\n\n` must reset the envelope state on the
			// empty-payload event before `[DONE]`. Only the `data`
			// field affects corroboration; `event:`/`id:`/`retry:` and
			// comments (colon-first) are still ignored.
			var field, value []byte
			if colon := bytes.IndexByte(fieldLine, ':'); colon < 0 {
				field = fieldLine
			} else {
				field = fieldLine[:colon]
				value = fieldLine[colon+1:]
				if len(value) > 0 && value[0] == ' ' {
					value = value[1:]
				}
			}
			if bytes.Equal(field, []byte("event")) {
				// Record the SSE event name for the current pending
				// event. Reset on blank-line dispatch. Used to gate
				// corroboration on the default chat.completions event
				// path (#232 R10 SEC HIGH).
				currentEventName = append(currentEventName[:0], value...)
			} else if bytes.Equal(field, []byte("data")) {
				// Append to current event buffer. Per SSE spec,
				// consecutive data fields concatenate with `\n` —
				// including when the FIRST payload was empty. Gating
				// the separator on `eventHasData` (not eventBuf length)
				// preserves leading empty lines in the joined data.
				// Classification is deferred to blank-line dispatch —
				// a data value of `[DONE]` here does NOT terminate; it
				// is merely appended, and only becomes a terminator if
				// the dispatched event's full data has `[DONE]` as its
				// prefix (OpenAI SDK parity, R9 SEC HIGH-2). (#232 R8
				// SEC HIGH + R9 CODE HIGH + R10 CODE HIGH.)
				if eventHasData {
					eventBuf = append(eventBuf, '\n')
				}
				eventBuf = append(eventBuf, value...)
				eventHasData = true
			}
			// Non-data fields (event, id, retry) and comment lines
			// (leading colon → empty field name) are ignored — none of
			// them affect corroboration.
		}
		if err != nil {
			if err == io.EOF {
				// EOF: any pending event (eventHasData=true without a
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
	// Issue #232: presence of this field on the last DISPATCHED SSE
	// event before `[DONE]`/EOF (and ONLY as a standalone envelope) is
	// the buyer-side corroboration the reconciler uses to verify the
	// gateway's fallback outcome label.
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
		Code    string `json:"code"`
	} `json:"error,omitempty"`
}

// parseChunkTokens decodes a dispatched SSE event's joined `data:`
// payload and updates `res` with any token counts the event carried.
// It returns the event's classification for #232 corroboration
// tracking:
//
//   - code: the non-empty `error.code` value if the dispatched event
//     is a STANDALONE error envelope; "" otherwise.
//   - isStandaloneError: true ONLY if the event has a non-empty
//     `error.code`, no `choices` key, no `usage` key, no duplicate
//     top-level keys, and no duplicate immediate `error.*` keys.
//
// The caller in consumeSSE tracks whether the LAST DISPATCHED event
// before `[DONE]`/EOF was a standalone error envelope; only that
// position flips `Result.SawSSEErrorEvent`. This makes the
// corroboration bit position-aware so that injecting
// `"error":{"code":"..."}` into a content-bearing dispatched event, or
// into an event followed by more content events, does not satisfy the
// buyer-corroboration check. (#232 R2 SEC HIGH.)
func parseChunkTokens(payload []byte, res *Result) (code string, isStandaloneError bool) {
	var c chunkPayload
	if err := json.Unmarshal(payload, &c); err != nil {
		return "", false
	}
	// Error-bearing frames are either strict standalone terminal envelopes or
	// untrusted for both corroboration and token extraction. Otherwise a
	// malformed `error` + `usage` frame could fail the envelope gate but still
	// donate prompt tokens to the harness side and erase the overbill drift
	// the gate is meant to preserve.
	if topLevelJSONKeyPresent(payload, "error") {
		if code, ok := standaloneSSEErrorCode(payload); ok {
			return code, true
		}
		return "", false
	}
	if c.Usage.CompletionTokens > 0 {
		res.CompletionTokensReceived = c.Usage.CompletionTokens
	}
	if c.Usage.PromptTokens > 0 {
		res.PromptTokensReported = c.Usage.PromptTokens
	}
	return "", false
}

func topLevelJSONKeyPresent(payload []byte, want string) bool {
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.UseNumber()

	tok, err := dec.Token()
	if err != nil {
		return false
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return false
	}

	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return false
		}
		key, ok := tok.(string)
		if !ok {
			return false
		}
		if key == want {
			return true
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return false
		}
	}
	return false
}

func standaloneSSEErrorCode(payload []byte) (string, bool) {
	top, ok := strictJSONRawObject(payload)
	if !ok {
		return "", false
	}
	if _, hasChoices := top["choices"]; hasChoices {
		return "", false
	}
	if _, hasUsage := top["usage"]; hasUsage {
		return "", false
	}
	errorRaw, ok := top["error"]
	if !ok {
		return "", false
	}
	errorFields, ok := strictJSONRawObject(errorRaw)
	if !ok {
		return "", false
	}
	codeRaw, ok := errorFields["code"]
	if !ok {
		return "", false
	}
	var code string
	if err := json.Unmarshal(codeRaw, &code); err != nil || code == "" {
		return "", false
	}
	return code, true
}

func strictJSONRawObject(payload []byte) (map[string]json.RawMessage, bool) {
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.UseNumber()

	tok, err := dec.Token()
	if err != nil {
		return nil, false
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return nil, false
	}

	fields := make(map[string]json.RawMessage)
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, false
		}
		key, ok := tok.(string)
		if !ok {
			return nil, false
		}
		if _, exists := fields[key]; exists {
			return nil, false
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, false
		}
		fields[key] = raw
	}

	tok, err = dec.Token()
	if err != nil {
		return nil, false
	}
	delim, ok = tok.(json.Delim)
	if !ok || delim != '}' {
		return nil, false
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, false
	}
	return fields, true
}

// isDefaultEventName returns true when the SSE event name is empty or
// exactly "message" — the two spec-equivalent defaults per WHATWG SSE.
// The OpenAI Python/Node stream decoders route these through the
// normal chat.completions data handler where `data.error` surfaces
// as the terminal envelope SPEC-006 §17.7.1 pins. Non-default names
// (Assistants API `thread.*`, Responses API `response.*`, etc.) route
// through handlers that do NOT treat the envelope as terminal.
// (#232 R10 SEC HIGH.)
func isDefaultEventName(name []byte) bool {
	return len(name) == 0 || bytes.Equal(name, []byte("message"))
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
	c, err := parseNonStreamingChatCompletion(b)
	if err != nil {
		if res.HTTPStatus >= 200 && res.HTTPStatus < 300 {
			res.Outcome = "invalid_response"
			res.ErrorCode = "invalid_response"
			res.ErrorMsg = err.Error()
		}
		return
	}
	if c.Usage != nil {
		if c.Usage.CompletionTokens > 0 {
			res.CompletionTokensReceived = c.Usage.CompletionTokens
		}
		if c.Usage.PromptTokens > 0 {
			res.PromptTokensReported = c.Usage.PromptTokens
		}
	}
	res.SawTerminator = true
}

type nonStreamingChatCompletion struct {
	Choices []struct {
		Text    *string `json:"text"`
		Message *struct {
			Content      *string         `json:"content"`
			Role         *string         `json:"role"`
			Refusal      *string         `json:"refusal"`
			Reasoning    *string         `json:"reasoning"`
			ToolCalls    json.RawMessage `json:"tool_calls"`
			FunctionCall json.RawMessage `json:"function_call"`
		} `json:"message"`
	} `json:"choices"`
	Usage *struct {
		PromptTokens     int64 `json:"prompt_tokens"`
		CompletionTokens int64 `json:"completion_tokens"`
	} `json:"usage"`
}

func parseNonStreamingChatCompletion(body []byte) (nonStreamingChatCompletion, error) {
	var c nonStreamingChatCompletion
	if err := json.Unmarshal(body, &c); err != nil {
		return c, fmt.Errorf("invalid JSON response: %w", err)
	}
	if len(c.Choices) == 0 {
		return c, fmt.Errorf("missing choices")
	}
	for i, choice := range c.Choices {
		if nonEmptyString(choice.Text) {
			continue
		}
		if choice.Message == nil {
			return c, fmt.Errorf("choices[%d].message is required", i)
		}
		if len(choice.Message.ToolCalls) > 0 {
			if ok, err := validToolCalls(choice.Message.ToolCalls); err != nil {
				return c, fmt.Errorf("choices[%d].message.tool_calls: %w", i, err)
			} else if ok {
				continue
			}
		}
		if len(choice.Message.FunctionCall) > 0 {
			if ok, err := validFunctionCall(choice.Message.FunctionCall); err != nil {
				return c, fmt.Errorf("choices[%d].message.function_call: %w", i, err)
			} else if ok {
				continue
			}
		}
		if nonEmptyString(choice.Message.Content) ||
			nonEmptyString(choice.Message.Refusal) ||
			nonEmptyString(choice.Message.Reasoning) {
			continue
		}
		return c, fmt.Errorf("choices[%d].message has no OpenAI-compatible signal", i)
	}
	return c, nil
}

func nonEmptyString(v *string) bool {
	return v != nil && *v != ""
}

func validToolCalls(raw json.RawMessage) (bool, error) {
	if len(raw) == 0 {
		return false, nil
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return false, fmt.Errorf("must not be null")
	}
	var calls []struct {
		ID       string `json:"id"`
		Type     string `json:"type"`
		Function *struct {
			Name      string  `json:"name"`
			Arguments *string `json:"arguments"`
		} `json:"function"`
	}
	if err := json.Unmarshal(raw, &calls); err != nil {
		return false, fmt.Errorf("must be an array: %w", err)
	}
	if len(calls) == 0 {
		return false, fmt.Errorf("must not be empty")
	}
	for i, call := range calls {
		if call.ID == "" {
			return false, fmt.Errorf("[%d].id is required", i)
		}
		if call.Type != "function" {
			return false, fmt.Errorf("[%d].type must be function", i)
		}
		if call.Function == nil {
			return false, fmt.Errorf("[%d].function is required", i)
		}
		if call.Function.Name == "" {
			return false, fmt.Errorf("[%d].function.name is required", i)
		}
		if call.Function.Arguments == nil {
			return false, fmt.Errorf("[%d].function.arguments is required", i)
		}
	}
	return true, nil
}

func validFunctionCall(raw json.RawMessage) (bool, error) {
	if len(raw) == 0 {
		return false, nil
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return false, fmt.Errorf("must not be null")
	}
	var call struct {
		Name      string  `json:"name"`
		Arguments *string `json:"arguments"`
	}
	if err := json.Unmarshal(raw, &call); err != nil {
		return false, fmt.Errorf("must be an object: %w", err)
	}
	if call.Name == "" {
		return false, fmt.Errorf("name is required")
	}
	if call.Arguments == nil {
		return false, fmt.Errorf("arguments is required")
	}
	return true, nil
}
