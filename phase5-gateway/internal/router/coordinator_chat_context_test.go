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
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// Codex R2 MEDIUM 3 / review R3 LOW-4: every gateway request to the
// coordinator's chat route (the only coordinator route that returns a
// settleable 200) must stamp the signed-finality context through
// setCoordinatorChatContext, or its 200s are held under
// coordinator.require_settlement_trailers. The scan resolves the path of
// every http.NewRequest* against the coordinator buyer URL: string literals
// and constants directly, and a path parameter (relayBlindUpstream's) through
// every call site of its function. A builder whose path cannot be resolved
// fails, so a new builder cannot slip past by computing its path.
func TestEveryCoordinatorChatBuilderNegotiatesSignedFinality(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var parsed []*ast.File
	consts := map[string]string{}
	funcs := map[string]*ast.FuncDecl{}
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		parsed = append(parsed, file)
		ast.Inspect(file, func(n ast.Node) bool {
			switch d := n.(type) {
			case *ast.GenDecl:
				if d.Tok == token.CONST {
					for _, spec := range d.Specs {
						vs := spec.(*ast.ValueSpec)
						for i, id := range vs.Names {
							if i < len(vs.Values) {
								if lit, ok := vs.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
									consts[id.Name], _ = strconv.Unquote(lit.Value)
								}
							}
						}
					}
				}
			case *ast.FuncDecl:
				funcs[d.Name.Name] = d
			}
			return true
		})
	}
	const chatRoute = "chat/completions"
	// Builders whose URL is computed rather than a literal or constant on the
	// coordinator buyer URL. Each was checked by hand to target another
	// coordinator route (receipts, settlement finality) or a non-coordinator
	// host; a new computed URL fails until it is reviewed and listed here.
	unresolvedAllowlist := map[string]bool{
		"disclosure.go:coordinatorRoutingMetadataFresh":                           true, // GET operator /internal/routing
		"public_feeds.go:fetchPublicFeed":                                         true, // GET public stats and rate-card feeds
		"receipts.go:fetchCoordinatorBuyerReceipt":                                true, // GET /internal/settlement/receipts
		"server.go:handleStickyDelete":                                            true, // DELETE operator /internal/sticky
		"server.go:statusFromPoolz":                                               true, // GET operator /poolz
		"settlement_reconcile.go:fetchCoordinatorRequestSettlementFinalityDetail": true, // GET /internal/settlement/finality
	}
	seenAllowlisted := map[string]bool{}
	callsHelper := func(body ast.Node) bool {
		found := false
		ast.Inspect(body, func(n ast.Node) bool {
			if sel, ok := n.(*ast.SelectorExpr); ok && sel.Sel.Name == "setCoordinatorChatContext" {
				found = true
			}
			return !found
		})
		return found
	}
	// urlParts splits a URL expression into its constant text, whether it
	// targets the coordinator buyer URL, and any non-constant identifiers.
	var urlParts func(e ast.Expr) (text string, buyer bool, idents []string, opaque bool)
	urlParts = func(e ast.Expr) (string, bool, []string, bool) {
		switch x := e.(type) {
		case *ast.BasicLit:
			v, _ := strconv.Unquote(x.Value)
			return v, false, nil, false
		case *ast.Ident:
			if v, ok := consts[x.Name]; ok {
				return v, false, nil, false
			}
			return "", false, []string{x.Name}, false
		case *ast.ParenExpr:
			return urlParts(x.X)
		case *ast.BinaryExpr:
			lt, lb, li, lo := urlParts(x.X)
			rt, rb, ri, ro := urlParts(x.Y)
			return lt + rt, lb || rb, append(li, ri...), lo || ro
		case *ast.CallExpr:
			buyer := false
			ast.Inspect(x, func(n ast.Node) bool {
				if sel, ok := n.(*ast.SelectorExpr); ok && (sel.Sel.Name == "coordinatorBuyerURL" || sel.Sel.Name == "BuyerURL") {
					buyer = true
				}
				return true
			})
			if buyer {
				return "", true, nil, false
			}
			return "", false, nil, true
		default:
			return "", false, nil, true
		}
	}
	paramIndex := func(fn *ast.FuncDecl, name string) int {
		i := 0
		for _, field := range fn.Type.Params.List {
			for _, id := range field.Names {
				if id.Name == name {
					return i
				}
				i++
			}
		}
		return -1
	}
	// callSiteArgs returns the constant text of argument idx at every call
	// of fnName, and false if any is not constant.
	callSiteArgs := func(fnName string, idx int) ([]string, bool) {
		var out []string
		ok := true
		for _, file := range parsed {
			ast.Inspect(file, func(n ast.Node) bool {
				call, isCall := n.(*ast.CallExpr)
				if !isCall {
					return true
				}
				sel, isSel := call.Fun.(*ast.SelectorExpr)
				if !isSel || sel.Sel.Name != fnName || idx >= len(call.Args) {
					return true
				}
				text, _, idents, opaque := urlParts(call.Args[idx])
				if len(idents) > 0 || opaque {
					ok = false
				}
				out = append(out, text)
				return true
			})
		}
		return out, ok
	}
	chatBuilders := 0
	for _, file := range parsed {
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
			urlArg := call.Args[1]
			if sel.Sel.Name == "NewRequestWithContext" {
				urlArg = call.Args[2]
			}
			pos := fset.Position(call.Pos())
			var body ast.Node
			var decl *ast.FuncDecl
			for i := len(stack) - 1; i >= 0; i-- {
				switch fn := stack[i].(type) {
				case *ast.FuncLit:
					if body == nil {
						body = fn.Body
					}
				case *ast.FuncDecl:
					if body == nil {
						body = fn.Body
					}
					decl = fn
				}
			}
			text, buyer, idents, opaque := urlParts(urlArg)
			targetsChat := strings.Contains(text, chatRoute)
			if buyer && (len(idents) > 0 || opaque) {
				if opaque || decl == nil {
					t.Errorf("%s: coordinator buyer request with an unresolvable path", pos)
					return true
				}
				for _, id := range idents {
					idx := paramIndex(decl, id)
					if idx < 0 {
						t.Errorf("%s: coordinator buyer path uses %q, which is neither a constant nor a parameter", pos, id)
						continue
					}
					paths, resolved := callSiteArgs(decl.Name.Name, idx)
					if !resolved {
						t.Errorf("%s: a call of %s passes a non-constant %s", pos, decl.Name.Name, id)
					}
					for _, p := range paths {
						if strings.Contains(p, chatRoute) {
							targetsChat = true
						}
					}
				}
			}
			if !buyer && (len(idents) > 0 || opaque) {
				key := filepath.Base(pos.Filename) + ":"
				if decl != nil {
					key += decl.Name.Name
				}
				if !unresolvedAllowlist[key] {
					t.Errorf("%s: request URL is not a resolved constant (%s); review it and add it to the allowlist", pos, key)
				}
				seenAllowlisted[key] = true
			}
			if !buyer && targetsChat {
				t.Errorf("%s: coordinator chat route built without the coordinator buyer URL", pos)
				return true
			}
			if targetsChat {
				chatBuilders++
				if !callsHelper(body) {
					t.Errorf("%s: coordinator chat request built without setCoordinatorChatContext", pos)
				}
			}
			return true
		})
	}
	for key := range unresolvedAllowlist {
		if !seenAllowlisted[key] {
			t.Errorf("allowlisted builder %s no longer exists; remove it", key)
		}
	}
	if chatBuilders < 2 {
		t.Fatalf("found %d coordinator chat builders, want at least the chat proxy and relay-blind ones", chatBuilders)
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
