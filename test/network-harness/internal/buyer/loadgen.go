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
// count parsed from each chunk's usage field if present, and the
// "[DONE]" terminator. Errors mid-stream are recorded but do not panic.
func consumeSSE(body io.Reader, res *Result) {
	reader := bufio.NewReader(body)
	firstByte := true
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
			trimmed := bytes.TrimSpace(line)
			if bytes.HasPrefix(trimmed, []byte("data:")) {
				payload := bytes.TrimSpace(trimmed[len("data:"):])
				if bytes.Equal(payload, []byte("[DONE]")) {
					res.SawTerminator = true
				} else {
					parseChunkTokens(payload, res)
				}
			}
		}
		if err != nil {
			if err == io.EOF {
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
	// Issue #232: presence of this field on any SSE chunk is the buyer-
	// side corroboration the reconciler uses to verify the gateway's
	// fallback outcome label.
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
		Code    string `json:"code"`
	} `json:"error,omitempty"`
}

func parseChunkTokens(payload []byte, res *Result) {
	var c chunkPayload
	if err := json.Unmarshal(payload, &c); err != nil {
		return
	}
	if c.Usage.CompletionTokens > 0 {
		res.CompletionTokensReceived = c.Usage.CompletionTokens
	}
	if c.Usage.PromptTokens > 0 {
		res.PromptTokensReported = c.Usage.PromptTokens
	}
	// #232: any chunk carrying an error envelope flags buyer-side
	// corroboration of a fallback path. Gateway writeSSEError always
	// includes top-level "error" with non-empty `code` so we anchor on
	// code; an empty/nil error envelope (defensive: chunks that have
	// the field but with no code) is treated as not corroborating.
	if c.Error != nil && c.Error.Code != "" {
		res.SawSSEErrorEvent = true
	}
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
