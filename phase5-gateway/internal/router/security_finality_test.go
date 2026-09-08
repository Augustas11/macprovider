package router

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// Real HTTP transport does not expose trailers until EOF. The facades can end
// earlier, but neither that nor a missing trailer may authorize a local debit.
func TestSecurityFinalityDelayedTrailers(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/messages", "/v1/responses"} {
		for _, outcome := range []string{"verified", "pending", "quarantined", "zero_settled", "missing", "observe", "missing_observe"} {
			t.Run(endpoint+"/"+outcome, func(t *testing.T) {
				flushed := make(chan struct{})
				release := make(chan struct{})
				var releaseOnce sync.Once
				unblock := func() { releaseOnce.Do(func() { close(release) }) }
				defer unblock()
				result, closed := "valid", true
				if outcome == "pending" {
					result, closed = "inconclusive", false
				} else if outcome == "quarantined" {
					result = "invalid"
				}
				coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.URL.Path == "/internal/settlement/finality" {
						if outcome == "missing_observe" && r.URL.Query().Get("required_internal_request_id") != "internal_current" {
							t.Error("observe recovery omitted current coordinator attempt")
						}
						finalOutcome := outcome
						mode := "enforce"
						if outcome == "observe" || outcome == "missing_observe" {
							mode, finalOutcome = "observe", "quarantined"
						}
						if finalOutcome == "missing" {
							finalOutcome = "pending"
						}
						finalResult, finalClosed := result, closed
						prompt, completion, total := 3, 4, 7
						if mode == "observe" {
							finalResult = "invalid"
							// Receipt-only totals deliberately differ from local usage.
							prompt, completion, total = 0, 0, 0
						}
						if finalOutcome == "pending" {
							finalResult, finalClosed = "inconclusive", false
						}
						writeJSON(w, http.StatusOK, map[string]any{
							"required_internal_request_id": r.URL.Query().Get("required_internal_request_id"),
							"request_id":                   r.URL.Query().Get("request_id"),
							"policy_version":               settlementPolicyVersion, "mode": mode, "mode_scope_complete": true,
							"outcome": finalOutcome, "receipt_result": finalResult,
							"closed": finalClosed, "reason": "security_regression",
							"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": total,
							"token_source": "coordinator_observed", "verified_attempts": 1,
							"pending_deadline_unix_ms": fixedNow().Add(5 * time.Minute).UnixMilli(),
						})
						return
					}
					w.Header().Set("Content-Type", "text/event-stream")
					w.Header().Set("X-MacProvider-Internal-Request-ID", "internal_current")
					w.Header().Set("Trailer", strings.Join(settlementFinalityHeaderNamesForTest(), ", "))
					_, _ = io.WriteString(w, "data: {\"id\":\"chatcmpl_finality\",\"object\":\"chat.completion.chunk\",\"model\":\"llama\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7}}\n\ndata: [DONE]\n\n")
					w.(http.Flusher).Flush()
					close(flushed)
					<-release
					if outcome != "missing" && outcome != "missing_observe" {
						mode := "enforce"
						if outcome == "observe" {
							mode = "observe"
						}
						finality := settlementFinalityTrailerForTest(mode, settlementPolicyVersion, outcome, result, fmt.Sprint(closed), "security_regression", fixedNow().Add(5*time.Minute).UnixMilli())
						for key, values := range finality {
							w.Header()[key] = values
						}
					}
				}))
				defer coordinator.Close()
				// Unblock before Close even if an assertion aborts the test.
				defer unblock()
				h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
					cfg.Coordinator.BuyerURL = coordinator.URL
					cfg.Coordinator.OperatorURL = coordinator.URL
					cfg.Features.AnthropicMessagesEnabled = true
					cfg.Features.ResponsesAPIEnabled = true
				}, WithHTTPClient(coordinator.Client()))
				accountID := "acct_finality_http"
				key := createAccountAndKey(t, store, cfg, accountID)
				body := `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
				if endpoint == "/v1/responses" {
					body = `{"model":"llama","stream":true,"max_output_tokens":20,"input":"hi"}`
				}
				req := httptest.NewRequest(http.MethodPost, endpoint, strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer "+key)
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("anthropic-version", "2023-06-01")
				resp := httptest.NewRecorder()
				done := make(chan struct{})
				go func() {
					defer close(done)
					h.ServeHTTP(resp, req)
				}()
				defer func() {
					unblock()
					select {
					case <-done:
					case <-time.After(5 * time.Second):
						t.Error("gateway handler did not stop")
					}
				}()
				select {
				case <-flushed:
				case <-done:
					t.Fatalf("gateway returned before upstream stream: %d %s", resp.Code, resp.Body.String())
				case <-time.After(5 * time.Second):
					t.Fatal("upstream stream did not start")
				}
				snap := gatewaySettlementSnapshot(t, dbPath, accountID)
				if snap.usageRows != 0 || snap.settledRows != 0 || snap.activeRows != 1 {
					t.Fatalf("before finality: %+v, want reservation without debit", snap)
				}
				unblock()
				select {
				case <-done:
				case <-time.After(5 * time.Second):
					t.Fatal("gateway did not finish")
				}
				if resp.Code != http.StatusOK || strings.Contains(resp.Body.String(), "invalid_provider_response") {
					t.Fatalf("response=%d %s", resp.Code, resp.Body.String())
				}
				snap = gatewaySettlementSnapshot(t, dbPath, accountID)
				observe := outcome == "observe" || outcome == "missing_observe"
				if !observe && (snap.usageRows != 0 || snap.settledRows != 0) {
					t.Fatalf("response path locally debited: %+v", snap)
				}
				reconcile := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
				reconcile.Header.Set("Authorization", "Bearer operator-key")
				reconciled := httptest.NewRecorder()
				h.ServeHTTP(reconciled, reconcile)
				if reconciled.Code != http.StatusOK {
					t.Fatalf("reconcile=%d %s", reconciled.Code, reconciled.Body.String())
				}
				snap = gatewaySettlementSnapshot(t, dbPath, accountID)
				switch outcome {
				case "observe", "missing_observe":
					if snap.usageRows != 1 || snap.settledRows != 1 || snap.heldRows != 0 {
						t.Fatalf("observe fallback accounting: %+v", snap)
					}
					_, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
					if source != "provider_reported" || prompt != 3 || completion != 4 {
						t.Fatalf("observe did not retain local usage: %s/%d/%d", source, prompt, completion)
					}
				case "verified":
					if snap.usageRows != 1 || snap.settledRows != 1 || snap.activeRows != 0 {
						t.Fatalf("verified reconcile: %+v", snap)
					}
				case "quarantined", "zero_settled":
					if snap.usageRows != 0 || snap.refundedRows != 1 || snap.activeRows != 0 {
						t.Fatalf("refund reconcile: %+v", snap)
					}
				default:
					if snap.usageRows != 0 || snap.settledRows != 0 || snap.heldRows != 1 {
						t.Fatalf("pending reconcile: %+v", snap)
					}
				}
			})
		}
	}
}

func TestSecurityInvalidFacadeResponsePreservesFinality(t *testing.T) {
	for _, endpoint := range []string{"/v1/messages", "/v1/responses"} {
		for _, stream := range []bool{false, true} {
			for _, outcome := range []string{"verified", "pending", "quarantined", "zero_settled", "observe"} {
				t.Run(fmt.Sprintf("%s/stream=%t/%s", endpoint, stream, outcome), func(t *testing.T) {
					mode, receipt, closed := "enforce", "valid", "true"
					if outcome == "observe" {
						mode = "observe"
					} else if outcome == "pending" {
						receipt, closed = "inconclusive", "false"
					} else if outcome == "quarantined" {
						receipt = "invalid"
					}
					finality := settlementFinalityTrailerForTest(mode, settlementPolicyVersion, outcome, receipt, closed, "security_regression")
					client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
						payload := `{"id":"bad","object":"chat.completion","model":"llama","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"","unsupported_output":"hidden"},"finish_reason":"stop"}]}`
						if endpoint == "/v1/responses" {
							payload = "not-json"
						}
						h := finality.Clone()
						h.Set("Content-Type", "application/json")
						resp := responseWithBody(http.StatusOK, h, payload)
						if stream {
							payload = "data: {\"id\":\"bad\",\"object\":\"chat.completion.chunk\",\"model\":\"llama\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7},\"choices\":[{\"index\":0,\"delta\":{\"unsupported_output\":\"hidden\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
							if endpoint == "/v1/responses" {
								payload = "data: not-json\n\n"
							}
							resp.Header = http.Header{"Content-Type": {"text/event-stream"}, "Trailer": {strings.Join(settlementFinalityHeaderNamesForTest(), ", ")}}
							resp.Body = io.NopCloser(strings.NewReader(payload))
							resp.Trailer = finality.Clone()
						}
						return resp, nil
					})}
					h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
						cfg.Coordinator.BuyerURL = "http://coordinator.test"
						cfg.Features.AnthropicMessagesEnabled = true
						cfg.Features.ResponsesAPIEnabled = true
					}, WithHTTPClient(client))
					key := createAccountAndKey(t, store, cfg, "acct_invalid_finality")
					body := fmt.Sprintf(`{"model":"llama","max_tokens":20,"stream":%t,"messages":[{"role":"user","content":"hi"}]}`, stream)
					if endpoint == "/v1/responses" {
						body = fmt.Sprintf(`{"model":"llama","max_output_tokens":20,"stream":%t,"input":"hi"}`, stream)
					}
					req := httptest.NewRequest(http.MethodPost, endpoint, strings.NewReader(body))
					req.Header.Set("Authorization", "Bearer "+key)
					req.Header.Set("Content-Type", "application/json")
					req.Header.Set("anthropic-version", "2023-06-01")
					resp := httptest.NewRecorder()
					h.ServeHTTP(resp, req)
					wantCode := "invalid_provider_response"
					if endpoint == "/v1/responses" && stream {
						wantCode = "stream_malformed"
					}
					if !strings.Contains(resp.Body.String(), wantCode) {
						t.Fatalf("missing invalid-response error: %d %s", resp.Code, resp.Body.String())
					}
					snap := gatewaySettlementSnapshot(t, dbPath, "acct_invalid_finality")
					switch outcome {
					case "observe":
						if snap.usageRows != 1 || snap.settledRows != 1 {
							t.Fatalf("observe compatibility: %+v", snap)
						}
					case "quarantined", "zero_settled":
						if snap.usageRows != 0 || snap.refundedRows != 1 || snap.activeRows != 0 {
							t.Fatalf("finality refund: %+v", snap)
						}
					default:
						if snap.usageRows != 0 || snap.heldRows != 1 || snap.settledRows != 0 {
							t.Fatalf("finality hold: %+v", snap)
						}
					}
				})
			}
		}
	}
}

func TestSecurityStreamingFinalityHeaderWithoutTrailer(t *testing.T) {
	h := settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "pending", "inconclusive", "false", "pending")
	if got := coordinatorStreamingSettlementFinality(&http.Response{Header: h}); got.Action != settlementFinalityHold {
		t.Fatalf("enforce header was treated as legacy: %+v", got)
	}
}

func TestSecurityFacadeFinalityDrainBounds(t *testing.T) {
	for _, canceledContext := range []bool{false, true} {
		t.Run(fmt.Sprint(canceledContext), func(t *testing.T) {
			ctx, stop := context.WithCancel(context.Background())
			defer stop()
			if canceledContext {
				stop()
			}
			resp := responseWithBody(http.StatusOK, http.Header{
				"Trailer": {settlementModeHeader},
			}, strings.Repeat("x", maxStreamingLineBytes*2))
			var canceled atomic.Bool
			drainFacadeSettlementTrailers(ctx, bufio.NewReaderSize(resp.Body, maxStreamingLineBytes), resp, func() {
				canceled.Store(true)
			})
			if !canceled.Load() {
				t.Fatal("unbounded or canceled trailer tail did not cancel upstream")
			}
		})
	}
}

func TestSecurityMissingFinalityObserveAuthority(t *testing.T) {
	for _, tc := range []struct {
		name, mode, policy, returnedID, reason, headerMode string
		closed, missingAdmission                           bool
		incompleteScope                                    bool
		missingInternalID                                  bool
		missingInternalEcho                                bool
		status                                             int
		want                                               bool
	}{
		{name: "observe", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", reason: "receipt_invalid", closed: true, want: true},
		{name: "observe_pending", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", reason: "receipt_verdict_pending", want: true},
		{name: "enforce", mode: "enforce", policy: settlementPolicyVersion, returnedID: "req_fence", closed: true},
		{name: "wrong_request", mode: "observe", policy: settlementPolicyVersion, returnedID: "other", closed: true},
		{name: "missing_request", mode: "observe", policy: settlementPolicyVersion, closed: true},
		{name: "unknown_policy", mode: "observe", policy: "future", returnedID: "req_fence", closed: true},
		{name: "old_coordinator_without_scope", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", closed: true, incompleteScope: true},
		{name: "contradictory_header", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", headerMode: "enforce", closed: true},
		{name: "missing_generation", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", missingAdmission: true, closed: true},
		{name: "missing_current_internal_id", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", missingInternalID: true, closed: true},
		{name: "lookup_ignored_current_internal_id", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", missingInternalEcho: true, closed: true},
		{name: "lookup_unavailable", status: http.StatusServiceUnavailable},
		{name: "lookup_not_found", status: http.StatusNotFound},
		{name: "mixed_policy", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", reason: "mixed_settlement_policy_snapshot"},
		{name: "missing_current_scope", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", reason: "missing_current_settlement_finality"},
		{name: "unknown_pending", mode: "observe", policy: settlementPolicyVersion, returnedID: "req_fence", reason: "future_pending"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.Default()
			cfg.Coordinator.OperatorURL = "http://coordinator.test"
			cfg.Coordinator.ServiceToken = "test-internal"
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				if r.Header.Get("Authorization") != "Bearer test-internal" ||
					r.URL.Query().Get("required_internal_request_id") != "internal_current" ||
					r.URL.Query().Get("account_id") != "acct_fence" ||
					r.URL.Query().Get("request_id") != "req_fence" ||
					r.URL.Query().Get("reservation_created_at_unix_ms") != fmt.Sprint(fixedNow().UnixMilli()) {
					t.Errorf("lookup did not bind service authority/account/request/generation")
				}
				if deadline, ok := r.Context().Deadline(); !ok || time.Until(deadline) > 5*time.Second {
					t.Error("lookup lacks bounded deadline")
				}
				status := tc.status
				if status == 0 {
					status = http.StatusOK
				}
				outcome, receipt := "quarantined", "invalid"
				pendingAttempts := int64(0)
				if !tc.closed {
					outcome, receipt = "pending", "inconclusive"
					pendingAttempts = 1
				}
				internalEcho := "internal_current"
				if tc.missingInternalEcho {
					internalEcho = ""
				}
				body, err := json.Marshal(coordinatorRequestSettlementFinality{
					RequiredInternalRequestID: internalEcho,
					RequestID:                 tc.returnedID, Mode: tc.mode, PolicyVersion: tc.policy,
					ModeScopeComplete: !tc.incompleteScope,
					Outcome:           outcome, ReceiptResult: receipt, Reason: tc.reason, Closed: tc.closed, PendingAttempts: pendingAttempts,
				})
				if err != nil {
					return nil, err
				}
				return responseWithBody(status, http.Header{}, string(body)), nil
			})}
			s := &Server{cfg: cfg, client: client}
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			req = req.WithContext(context.WithValue(req.Context(), requestIDKey{}, "req_fence"))
			subject := usageSubject{AccountID: "acct_fence", ReservationCreatedAt: fixedNow()}
			if tc.missingAdmission {
				subject.ReservationCreatedAt = time.Time{}
			}
			resp := &http.Response{Header: http.Header{}}
			if !tc.missingInternalID {
				resp.Header.Set("X-MacProvider-Internal-Request-ID", "internal_current")
			}
			if tc.headerMode != "" {
				resp.Header.Set(settlementModeHeader, tc.headerMode)
			}
			if got := s.resolveMissingFinalityAsObserve(req, subject, resp); got != tc.want {
				t.Fatalf("observe authority=%t want %t", got, tc.want)
			}
		})
	}
}

func TestSecurityStreamingTerminalPreservesHeaderFinality(t *testing.T) {
	for _, mode := range []string{"enforce", "observe"} {
		t.Run(mode, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				h := settlementFinalityTrailerForTest(mode, settlementPolicyVersion, "pending", "inconclusive", "false", "pending")
				h.Set("Content-Type", "text/event-stream")
				payload := fmt.Sprintf("data: {\"choices\":[{\"delta\":{\"content\":%q}}]}\n\n", strings.Repeat("x", 1024))
				return responseWithBody(http.StatusOK, h, payload), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.BuyerURL = "http://coordinator.test"
			}, WithHTTPClient(client))
			key := createAccountAndKey(t, store, cfg, "acct_header_finality")
			resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"stream":true,"messages":[{"role":"user","content":"hi"}]}`, nil)
			if !strings.Contains(resp.Body.String(), "stream_output_exceeded") {
				t.Fatalf("expected gateway truncation: %d %s", resp.Code, resp.Body.String())
			}
			snap := gatewaySettlementSnapshot(t, dbPath, "acct_header_finality")
			if mode == "enforce" {
				if snap.usageRows != 0 || snap.heldRows != 1 || snap.settledRows != 0 {
					t.Fatalf("header finality bypass: %+v", snap)
				}
			} else if snap.usageRows != 1 || snap.settledRows != 1 {
				t.Fatalf("observe compatibility: %+v", snap)
			}
		})
	}
}
