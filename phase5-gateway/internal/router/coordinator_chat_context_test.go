package router

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// Codex R2 MEDIUM 3: every gateway builder of a coordinator chat request
// (the only coordinator route that returns a settleable 200) must stamp the
// signed-finality context through setCoordinatorChatContext, or its 200s
// are held under coordinator.require_settlement_trailers. This scans the
// package source, so a new builder that skips the helper fails here.
func TestEveryCoordinatorChatBuilderNegotiatesSignedFinality(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	builders := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		file, err := parser.ParseFile(fset, name, src, 0)
		if err != nil {
			t.Fatal(err)
		}
		// Innermost enclosing function body for each chat request builder.
		var stack []ast.Node
		ast.Inspect(file, func(n ast.Node) bool {
			if n == nil {
				stack = stack[:len(stack)-1]
				return true
			}
			stack = append(stack, n)
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || (sel.Sel.Name != "NewRequest" && sel.Sel.Name != "NewRequestWithContext") {
				return true
			}
			if !strings.Contains(string(src[fset.Position(call.Pos()).Offset:fset.Position(call.End()).Offset]), `"/v1/chat/completions"`) {
				return true
			}
			builders++
			var body ast.Node
			for i := len(stack) - 1; i >= 0 && body == nil; i-- {
				switch fn := stack[i].(type) {
				case *ast.FuncLit:
					body = fn.Body
				case *ast.FuncDecl:
					body = fn.Body
				}
			}
			text := string(src[fset.Position(body.Pos()).Offset:fset.Position(body.End()).Offset])
			if !strings.Contains(text, "setCoordinatorChatContext(") {
				t.Errorf("%s: coordinator chat request built without setCoordinatorChatContext", fset.Position(call.Pos()))
			}
			return true
		})
	}
	if builders < 2 {
		t.Fatalf("found %d coordinator chat builders, want at least the chat proxy and relay-blind ones", builders)
	}
}

// Codex R2 MEDIUM 3, behaviourally: with the pin on, a relay-blind 200
// from a negotiating coordinator settles instead of holding. The stub
// answers as a v0.2.2 coordinator only when the request advertised the
// capability, with the bearer, account and request id the MAC binds.
func TestRelayBlindNegotiatesSignedFinalityUnderPin(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "nonstream", true: "stream"}[stream], func(t *testing.T) {
			res, _ := pilotReservationFixture(t, stream)
			raw := pilotEnvelopeFixture(t, res)
			digest := sha256.Sum256(raw)
			digestText := base64.RawURLEncoding.EncodeToString(digest[:])
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/v1/relay-blind/route-reservations":
					json.NewEncoder(w).Encode(res)
				case "/v1/relay-blind/consume":
					json.NewEncoder(w).Encode(relayblind.ConsumeResponse{Version: relayblind.ConsumeVersion, ProviderBinding: res.ProviderBinding, BuyerBinding: res.BuyerBinding, EnvelopeDigest: digestText, ExecutionAuthorization: "internal-execution-authorization", ConsumedAtUnix: fixedNow().Unix(), ExpiresAtUnix: res.ExpiresAtUnix})
				case "/v1/chat/completions":
					w.Header().Set(relayBlindValidatedHeader, digestText)
					w.Header().Set(coordinatorInternalRequestIDHeader, testInternal)
					negotiated := r.Header.Get(settlementTrailersCapabilityHeader) == "1" && r.Header.Get("Authorization") == "Bearer "+testKey
					sign := func(h http.Header) {
						signFinality(testKey, r.Header.Get("X-MacProvider-Account"), r.Header.Get("X-Request-ID"), testInternal, h)
					}
					if stream {
						if negotiated {
							w.Header().Set(settlementModeHeader, "legacy")
							sign(w.Header())
						}
						w.Header().Set("Content-Type", "text/event-stream")
						io.WriteString(w, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}\n\ndata: [DONE]\n\n")
						return
					}
					if negotiated {
						w.Header().Add("Trailer", settlementModeHeader)
						w.Header().Add("Trailer", settlementFinalityMACHeader)
					}
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusOK)
					json.NewEncoder(w).Encode(map[string]any{"id": "completion", "object": "chat.completion", "model": "test-model", "choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": "ok"}, "finish_reason": "stop", "index": 0}}, "usage": map[string]any{"prompt_tokens": 20, "completion_tokens": 2, "total_tokens": 22}})
					if negotiated {
						w.Header().Set(settlementModeHeader, "legacy")
						sign(w.Header())
					}
				default:
					w.WriteHeader(404)
				}
			}))
			defer upstream.Close()
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
				c.Features.RelayBlindRequests.Enabled = true
				c.Coordinator.BuyerURL = upstream.URL
				c.Coordinator.ServiceToken = testKey
				c.Coordinator.RequireSettlementTrailers = true
			})
			key := createAccountAndKey(t, store, cfg, "pilot-account")
			req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(raw))
			req.Header.Set("Authorization", "Bearer "+key)
			req.Header.Set("X-Request-ID", "123e4567-e89b-42d3-a456-426614174088")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if w.Code != 200 {
				t.Fatalf("status %d body %s", w.Code, w.Body.String())
			}
			got := gatewaySettlementSnapshot(t, dbPath, "pilot-account")
			if got.usageRows != 1 || got.settledRows != 1 || got.activeRows != 0 {
				t.Fatalf("snapshot=%+v, want the relay-blind 200 settled under the pin", got)
			}
		})
	}
}
