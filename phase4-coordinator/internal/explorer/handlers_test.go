package explorer

import (
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestAC01_BearerRequired(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/overview", "")
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "invalid_operator_token") {
		t.Fatalf("missing auth error: %s", resp.Body.String())
	}
}

func TestAC02_BadBearerRejected(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/overview", "wrong")
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestStaticAssetsBootstrapWithoutBearer(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	for _, path := range []string{"/admin/explorer/", "/admin/explorer/index.html", "/admin/explorer/js/dashboard.js"} {
		resp := requestExplorer(t, h, http.MethodGet, path, "")
		if resp.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
}

func TestAC05_OverviewLoadsUnder500msWithSeededData(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	start := time.Now()
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/overview", "operator-key")
	elapsed := time.Since(start)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if elapsed >= 500*time.Millisecond {
		t.Fatalf("overview took %s", elapsed)
	}
}

func TestAC06_SessionsCursorIsStableWhenNewerRowsArrive(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	for i := 0; i < 60; i++ {
		requestID := "req_page_" + string(rune('A'+i/26)) + string(rune('a'+i%26))
		seedRequestLog(t, db, fixedExplorerTime().Add(-time.Duration(i+1)*time.Minute), requestID)
	}
	from := fixedExplorerTime().Add(-2 * time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	page1 := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions?limit=25&from="+from+"&to="+to, "operator-key")
	if page1.Code != http.StatusOK {
		t.Fatalf("page1 status=%d body=%s", page1.Code, page1.Body.String())
	}
	body1 := decodeObject(t, page1)
	items1 := body1["sessions"].([]any)
	if len(items1) != 25 {
		t.Fatalf("page1 items=%d", len(items1))
	}
	next, ok := body1["next_cursor"].(string)
	if !ok || next == "" {
		t.Fatalf("missing next_cursor: %s", page1.Body.String())
	}
	seedRequestLog(t, db, fixedExplorerTime().Add(30*time.Minute), "req_newer_after_page1")
	page2 := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions?limit=25&from="+from+"&to="+to+"&cursor="+next, "operator-key")
	if page2.Code != http.StatusOK {
		t.Fatalf("page2 status=%d body=%s", page2.Code, page2.Body.String())
	}
	seen := requestIDs(items1)
	for id := range requestIDs(decodeObject(t, page2)["sessions"].([]any)) {
		if seen[id] {
			t.Fatalf("duplicate request id across cursor pages: %s", id)
		}
		if id == "req_newer_after_page1" {
			t.Fatalf("newer row appeared on older cursor page")
		}
	}
}

func TestAC07_SessionDetailIncludesLocalAndGatewayData(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"request_id":"req_seed","gateway_marker":true,"partial":false,"error":null}`)),
		}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/req_seed", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	for _, want := range []string{`"attempts":[`, `"ledger_rows":[`, `"gateway_marker":true`} {
		if !strings.Contains(resp.Body.String(), want) {
			t.Fatalf("session detail missing %q: %s", want, resp.Body.String())
		}
	}
}

// TestSessionDetailGatewayProxyUsesExternalRequestIDAndAccountID pins
// the ISS-212 v0.3 §5.6 security contract: when the coordinator
// resolves the path-segment as an internal request_id and the
// resolved request_log row carries an external_request_id and
// account_id, the gateway proxy URL MUST be
// /admin/explorer/sessions/{external_request_id}?account_id=<account_id>.
// Forwarding the coordinator-internal id risks the gateway
// interpreting it as a buyer-supplied X-Request-ID and returning a
// wrong-account 200 (ISS-212 R3 security MEDIUM).
func TestSessionDetailGatewayProxyUsesExternalRequestIDAndAccountID(t *testing.T) {
	h, db := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream)
		 VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0)`,
		fixedExplorerTime().Format(time.RFC3339Nano), "coord-internal-uuid-aaaa", "buyer-supplied-X", "acct_A", "llama", http.StatusOK); err != nil {
		t.Fatalf("seed request_log: %v", err)
	}
	// Use RequestURI (not URL.Path) so a buggy implementation that
	// path-escapes the `?` is caught here, not silently rendered
	// as a decoded path that looks correct in the test.
	var capturedRequestURI string
	var capturedRawPath string
	var capturedRawQuery string
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		capturedRawPath = r.URL.EscapedPath()
		capturedRawQuery = r.URL.RawQuery
		capturedRequestURI = capturedRawPath
		if capturedRawQuery != "" {
			capturedRequestURI += "?" + capturedRawQuery
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"request_id":"buyer-supplied-X","partial":false,"error":null}`)),
		}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/coord-internal-uuid-aaaa", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	// Wire-level assertions — the `?` MUST be a real query separator,
	// not a path-escaped `%3F`. Catching the R4 false-positive class:
	// a regression that drops account_id into URL.Path would have
	// URL.EscapedPath include `%3Faccount_id%3Dacct_A` and
	// URL.RawQuery be empty.
	// #231 SPEC-007 v0.4: coordinator proxy URL uses the typed
	// `ext_<external_request_id>` form so the gateway's
	// path-segment-typing deprecation audit doesn't fire on every
	// operator-driven session-detail navigation.
	wantPath := "/admin/explorer/sessions/ext_buyer-supplied-X"
	wantQuery := "account_id=acct_A"
	if capturedRawPath != wantPath {
		t.Fatalf("gateway proxy escaped path = %q, want %q (issue #212 v0.3 §5.6: external_request_id in path)", capturedRawPath, wantPath)
	}
	if capturedRawQuery != wantQuery {
		t.Fatalf("gateway proxy raw query = %q, want %q (issue #212 v0.3 §5.6: account_id MUST be a real query parameter, not path-escaped)", capturedRawQuery, wantQuery)
	}
	if capturedRequestURI != wantPath+"?"+wantQuery {
		t.Fatalf("gateway proxy request-URI = %q, want %q", capturedRequestURI, wantPath+"?"+wantQuery)
	}
}

// TestSessionDetailGatewayProxySkippedOnIncompleteIdentity pins the
// ISS-212 R4 security MEDIUM: when the coordinator-resolved row
// lacks either external_request_id or account_id (legacy /
// pre-v0.9.1-gateway / direct-legacy-buyer rows), the coordinator
// MUST NOT proxy to the gateway — forwarding with a partial key
// would risk a wrong-account 200 embed. The gateway section is
// marked `gateway_identity_unavailable`.
func TestSessionDetailGatewayProxySkippedOnIncompleteIdentity(t *testing.T) {
	h, db := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	// Seed a row with internal id but NULL account_id (legacy shape).
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream)
		 VALUES (?, ?, ?, NULL, ?, 0, 0, ?, 0)`,
		fixedExplorerTime().Format(time.RFC3339Nano), "coord-internal-uuid-legacy", "buyer-X", "llama", http.StatusOK); err != nil {
		t.Fatalf("seed request_log: %v", err)
	}
	gatewayCalled := false
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		gatewayCalled = true
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/coord-internal-uuid-legacy", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if gatewayCalled {
		t.Fatalf("gateway MUST NOT be proxied when account_id is NULL (issue #212 v0.3 §5.6 both-or-nothing)")
	}
	if !strings.Contains(resp.Body.String(), `"gateway_identity_unavailable"`) {
		t.Fatalf("response missing gateway_identity_unavailable marker: %s", resp.Body.String())
	}
}

// TestSessionDetailNoCoordinatorRowReturns404 pins the SPEC-007 v0.3
// §5.6 internal-id-only contract: the path-segment is the
// coordinator-internal request_id. When SessionDetail returns
// ErrNoRows (no coordinator row matches), the handler MUST return
// 404 — it MUST NOT fall back to proxying the raw path-segment to
// the gateway, which would silently let operators trigger the
// path-segment-overload class deferred to v0.4 (and risk a
// wrong-account 200 embed). Pre-v0.3 behavior allowed the
// gateway-only fallback; that path was removed in v0.3 per ISS-212
// R5 code MEDIUM.
func TestSessionDetailNoCoordinatorRowReturns404(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	gatewayCalled := false
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		gatewayCalled = true
		return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/no-such-internal-id", "operator-key")
	if resp.Code != http.StatusNotFound {
		t.Fatalf("status=%d body=%s, want 404", resp.Code, resp.Body.String())
	}
	if gatewayCalled {
		t.Fatalf("gateway proxy fired despite no coordinator row (issue #212 v0.3 §5.6: path-segment is internal-id only)")
	}
}

// Test82Item4_ProviderMapExposesAuthState verifies that the explorer
// admin surface includes the SPEC-003 FR-C9.4 auth_state value for every
// provider in the list + detail views, so operators can see WHY a
// session is non-routable (e.g. bearerless_duplicate) without needing to
// cross-reference /poolz.
func Test82Item4_ProviderMapExposesAuthState(t *testing.T) {
	cases := []struct {
		name      string
		authState pool.AuthState
		// What the rendered JSON's "auth_state" field MUST contain.
		wantJSONFrag string
	}{
		{"bearer_validated", pool.AuthBearerValidated, `"auth_state":"bearer_validated"`},
		{"self_minted", pool.AuthSelfMinted, `"auth_state":"self_minted"`},
		{"bearerless_duplicate", pool.AuthBearerlessDuplicate, `"auth_state":"bearerless_duplicate"`},
		{"mint_failed", pool.AuthMintFailed, `"auth_state":"mint_failed"`},
		{"empty_legacy", pool.AuthState(""), `"auth_state":""`},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			h, db := newTestExplorer(t, nil)
			left, right := net.Pipe()
			t.Cleanup(func() { _ = left.Close(); _ = right.Close() })
			providerID := "provider_" + tc.name
			registry := pool.NewRegistry(nil)
			registry.Register(&pool.Provider{
				ProviderID: providerID,
				AssignedID: "assigned_" + tc.name,
				ModelID:    "llama",
				State:      pool.StateReady,
				SlotsFree:  1,
				SlotsTotal: 1,
				AuthState:  tc.authState,
			}, left)
			h.pool = registry
			if _, err := db.ExecContext(context.Background(), `
insert into provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
values (?, ?, ?, ?, ?)`,
				"hash-"+tc.name, "tok_"+tc.name, providerID, tc.name, fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
				t.Fatalf("seed provider token: %v", err)
			}

			// List view.
			respList := requestExplorer(t, h, http.MethodGet, "/admin/explorer/providers", "operator-key")
			if respList.Code != http.StatusOK {
				t.Fatalf("list status=%d body=%s", respList.Code, respList.Body.String())
			}
			if !strings.Contains(respList.Body.String(), tc.wantJSONFrag) {
				t.Fatalf("list missing %q: %s", tc.wantJSONFrag, respList.Body.String())
			}

			// Detail view.
			respDetail := requestExplorer(t, h, http.MethodGet, "/admin/explorer/providers/"+providerID, "operator-key")
			if respDetail.Code != http.StatusOK {
				t.Fatalf("detail status=%d body=%s", respDetail.Code, respDetail.Body.String())
			}
			if !strings.Contains(respDetail.Body.String(), tc.wantJSONFrag) {
				t.Fatalf("detail missing %q: %s", tc.wantJSONFrag, respDetail.Body.String())
			}
		})
	}
}

func TestAC08_ProviderDirectoryCombinesPoolAndTokenStatus(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	left, right := net.Pipe()
	t.Cleanup(func() { _ = left.Close(); _ = right.Close() })
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID:        "provider_live",
		AssignedID:        "assigned_live",
		Hostname:          "host-live",
		ModelID:           "llama",
		State:             pool.StateReady,
		SlotsFree:         1,
		SlotsTotal:        2,
		LastHeartbeatAt:   fixedExplorerTime(),
		LastActivityAt:    fixedExplorerTime(),
		ConnectedAt:       fixedExplorerTime().Add(-time.Minute),
		BinaryVersion:     "v1",
		HashStatus:        pool.HashStatusVerified,
		EncryptedLeg:      true,
		InferencePath:     pool.InferencePathWSTunneled,
		AttestationStatus: pool.AttestationStatusNotRequired,
	}, left)
	h.pool = registry
	if _, err := db.ExecContext(context.Background(), `
insert into provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
values ('hash-live', 'tok_live', 'provider_live', 'live', ?)`, fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed provider token: %v", err)
	}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/providers", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	for _, want := range []string{"provider_live", `"state":"ready"`, `"token_status":"active"`, `"token_prefix":"tok_live"`} {
		if !strings.Contains(resp.Body.String(), want) {
			t.Fatalf("providers missing %q: %s", want, resp.Body.String())
		}
	}
}

func TestLedgerWindowRejectsOverMaxRange(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	from := fixedExplorerTime().Add(-32 * 24 * time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Format(time.RFC3339)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/ledger?from="+from+"&to="+to, "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestAC09_ProviderTokenHashNeverReturned(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	left, right := net.Pipe()
	t.Cleanup(func() { _ = left.Close(); _ = right.Close() })
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{ProviderID: "provider_hash", AssignedID: "assigned_hash", ModelID: "llama", State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1}, left)
	h.pool = registry
	if _, err := db.ExecContext(context.Background(), `
insert into provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
values ('secret-token-hash', 'tok_hash', 'provider_hash', 'hash', ?)`, fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed provider token: %v", err)
	}
	for _, path := range []string{"/admin/explorer/providers", "/admin/explorer/providers/provider_hash"} {
		resp := requestExplorer(t, h, http.MethodGet, path, "operator-key")
		if resp.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
		if !strings.Contains(resp.Body.String(), "tok_hash") {
			t.Fatalf("%s missing token prefix: %s", path, resp.Body.String())
		}
		if strings.Contains(resp.Body.String(), "secret-token-hash") {
			t.Fatalf("%s leaked token hash: %s", path, resp.Body.String())
		}
	}
}

func TestAC12_SettlementsReadOnlyMethods(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodPost, "/admin/explorer/settlements", "operator-key")
	if resp.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST collection status=%d body=%s", resp.Code, resp.Body.String())
	}
	if resp.Header().Get("Allow") != http.MethodGet {
		t.Fatalf("Allow=%q", resp.Header().Get("Allow"))
	}
	resp = requestExplorer(t, h, http.MethodPatch, "/admin/explorer/settlements/1", "operator-key")
	if resp.Code != http.StatusNotFound {
		t.Fatalf("PATCH detail status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestAC13_ConsumedAndVoidedSettlementsAreImmutable(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	seedSettlement(t, db, "provider_consumed", "consumed", fixedExplorerTime().Add(-48*time.Hour), "settlement_consumed")
	seedSettlement(t, db, "provider_voided", "voided", fixedExplorerTime().Add(-72*time.Hour), "settlement_voided")
	before := tableCounts(t, db)
	// parseWindow defaults `to` to time.Now().UTC(), so the
	// default window drifts past the fixedExplorerTime() seeds as
	// wall-clock advances (TestAC13 started failing once real-now
	// crossed 30 days past 2026-06-01). Pass explicit from/to that
	// bracket the seeded windowEnd values so the test is wall-
	// clock-independent.
	from := fixedExplorerTime().Add(-96 * time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	for _, status := range []string{"consumed", "voided"} {
		resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/settlements?status="+status+"&from="+from+"&to="+to, "operator-key")
		if resp.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", status, resp.Code, resp.Body.String())
		}
		if !strings.Contains(resp.Body.String(), status) {
			t.Fatalf("%s settlement missing: %s", status, resp.Body.String())
		}
	}
	for _, path := range []string{"/admin/explorer/settlements", "/admin/explorer/settlements/1"} {
		resp := requestExplorer(t, h, http.MethodDelete, path, "operator-key")
		if resp.Code != http.StatusMethodNotAllowed && resp.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
	after := tableCounts(t, db)
	for table, count := range before {
		if after[table] != count {
			t.Fatalf("%s count changed: before=%d after=%d", table, count, after[table])
		}
	}
}

func TestAC10_LedgerBoundedWindowEnforced(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	from := fixedExplorerTime().Add(-32 * 24 * time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Format(time.RFC3339)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/ledger?from="+from+"&to="+to, "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("32-day status=%d body=%s", resp.Code, resp.Body.String())
	}
	from = fixedExplorerTime().Add(-31 * 24 * time.Hour).Format(time.RFC3339)
	resp = requestExplorer(t, h, http.MethodGet, "/admin/explorer/ledger?from="+from+"&to="+to, "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("31-day status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestAC11_LedgerViewShowsSeededEntries(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	from := fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/ledger?from="+from+"&to="+to, "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	for _, want := range []string{"req_seed", `"gross_credits":15`, `"provider_credits":13`, `"operator_credits":2`} {
		if !strings.Contains(body, want) {
			t.Fatalf("ledger missing %q: %s", want, body)
		}
	}
}

func TestPollingPausesOnHiddenTabWiring(t *testing.T) {
	raw := readStatic(t, "static/js/lib/poll.js")
	for _, want := range []string{"document.visibilityState", "visibilitychange", "clearTimeout"} {
		if !strings.Contains(raw, want) {
			t.Fatalf("poll.js missing %q", want)
		}
	}
}

func TestAC20_GatewayUnreachableReturnsPartial(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) {
		cfg.Explorer.GatewayBaseURL = "http://127.0.0.1:1"
		cfg.Explorer.GatewayTimeoutMs = 100
	})
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/overview", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"partial":true`) {
		t.Fatalf("expected partial gateway degradation: %s", resp.Body.String())
	}
}

func TestOverviewUsesRawGatewayBuyerMetrics(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"gateway_health":"ok","capacity_tier":2,"public_api_paused":false,"demo_paused":false,"active_accounts_window":7,"new_accounts_window":3,"active_api_keys":11}`)),
		}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/overview", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	buyers := decodeObject(t, resp)["buyers"].(map[string]any)
	if buyers["active_accounts_window"] != float64(7) || buyers["new_accounts_window"] != float64(3) || buyers["active_api_keys"] != float64(11) {
		t.Fatalf("buyer metrics lost: %s", resp.Body.String())
	}
}

func TestBuyerProxyGatewayErrorsKeepStatusSemantics(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, io.ErrUnexpectedEOF
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/buyers", "operator-key")
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("unavailable status=%d body=%s", resp.Code, resp.Body.String())
	}

	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader(`{"error":{"code":"not_found"}}`))}, nil
	})}
	resp = requestExplorer(t, h, http.MethodGet, "/admin/explorer/buyers/acct_missing", "operator-key")
	if resp.Code != http.StatusNotFound {
		t.Fatalf("not found status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestAC14_HealthExposesReconciliationDelta(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/health", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"last_reconciliation_delta":123`) {
		t.Fatalf("delta missing: %s", resp.Body.String())
	}
}

func TestAC15_ActivityCursorMonotonic(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	seedRequestLog(t, db, fixedExplorerTime().Add(-time.Minute), "req_activity_next")
	from := fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?limit=1&from="+from+"&to="+to, "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("page1 status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := decodeObject(t, resp)
	if body["latest_cursor"] == nil || body["latest_cursor"] == "" {
		t.Fatalf("missing latest_cursor: %s", resp.Body.String())
	}
	next := body["next_cursor"].(string)
	items := body["events"].([]any)
	if len(items) == 0 || items[0].(map[string]any)["cursor"] == "" {
		t.Fatalf("activity row cursor missing: %s", resp.Body.String())
	}
	page2 := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?limit=1&from="+from+"&to="+to+"&cursor="+next, "operator-key")
	if page2.Code != http.StatusOK {
		t.Fatalf("page2 status=%d body=%s", page2.Code, page2.Body.String())
	}
	page2Items := decodeObject(t, page2)["events"].([]any)
	if page2Items[0].(map[string]any)["request_id"] == items[0].(map[string]any)["request_id"] {
		t.Fatalf("activity cursor replayed boundary row: page1=%s page2=%s", resp.Body.String(), page2.Body.String())
	}
}

func TestAC16_ActivityReplayFromCursorContiguous(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	want := map[string]bool{"req_seed": true}
	for i := 0; i < 39; i++ {
		requestID := "req_replay_" + string(rune('A'+i/26)) + string(rune('a'+i%26))
		want[requestID] = true
		seedRequestLog(t, db, fixedExplorerTime().Add(-time.Duration(i+1)*time.Minute), requestID)
	}
	from := fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	seen := map[string]bool{}
	cursor := ""
	for {
		path := "/admin/explorer/activity?limit=7&from=" + from + "&to=" + to
		if cursor != "" {
			path += "&cursor=" + cursor
		}
		resp := requestExplorer(t, h, http.MethodGet, path, "operator-key")
		if resp.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
		body := decodeObject(t, resp)
		for id := range requestIDs(body["events"].([]any)) {
			if seen[id] {
				t.Fatalf("duplicate activity id %s", id)
			}
			seen[id] = true
		}
		next, ok := body["next_cursor"].(string)
		if !ok || next == "" {
			break
		}
		cursor = next
	}
	if len(seen) != len(want) {
		t.Fatalf("seen=%d want=%d values=%v", len(seen), len(want), seen)
	}
	for id := range want {
		if !seen[id] {
			t.Fatalf("missing activity id %s", id)
		}
	}
}

func TestAC17_ActivitySinceCursorReturnsOnlyNewEvents(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	from := fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	initial := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?from="+from+"&to="+to, "operator-key")
	if initial.Code != http.StatusOK {
		t.Fatalf("initial status=%d body=%s", initial.Code, initial.Body.String())
	}
	latest := decodeObject(t, initial)["latest_cursor"].(string)
	seedRequestLog(t, db, fixedExplorerTime().Add(30*time.Minute), "req_live_activity")
	seedRequestLog(t, db, fixedExplorerTime().Add(31*time.Minute), "req_live_activity_2")
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?from="+from+"&to="+to+"&since_cursor="+latest, "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := decodeObject(t, resp)
	ids := requestIDs(body["events"].([]any))
	if len(ids) != 2 || !ids["req_live_activity"] || !ids["req_live_activity_2"] {
		t.Fatalf("new activity missing: %s", resp.Body.String())
	}
	if ids["req_seed"] {
		t.Fatalf("old activity repeated: %s", resp.Body.String())
	}
	if body["latest_cursor"] == latest {
		t.Fatalf("latest cursor did not advance: %s", resp.Body.String())
	}
}

func TestActivitySinceCursorPagesNewEventsWithoutReplay(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	from := fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	initial := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?from="+from+"&to="+to, "operator-key")
	if initial.Code != http.StatusOK {
		t.Fatalf("initial status=%d body=%s", initial.Code, initial.Body.String())
	}
	cursor := decodeObject(t, initial)["latest_cursor"].(string)
	seedRequestLog(t, db, fixedExplorerTime().Add(30*time.Minute), "req_live_page_1")
	seedRequestLog(t, db, fixedExplorerTime().Add(31*time.Minute), "req_live_page_2")
	seedRequestLog(t, db, fixedExplorerTime().Add(32*time.Minute), "req_live_page_3")

	seen := map[string]bool{}
	for {
		resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?limit=1&from="+from+"&to="+to+"&since_cursor="+url.QueryEscape(cursor), "operator-key")
		if resp.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
		}
		body := decodeObject(t, resp)
		events := body["events"].([]any)
		if len(events) != 1 {
			t.Fatalf("events=%d body=%s", len(events), resp.Body.String())
		}
		for id := range requestIDs(events) {
			if seen[id] {
				t.Fatalf("replayed id %s", id)
			}
			seen[id] = true
		}
		next, ok := body["next_cursor"].(string)
		if !ok || next == "" {
			break
		}
		cursor = next
	}
	for _, id := range []string{"req_live_page_1", "req_live_page_2", "req_live_page_3"} {
		if !seen[id] {
			t.Fatalf("missing %s seen=%v", id, seen)
		}
	}
}

func TestActivityRejectsBadCursor(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?cursor=not-a-cursor", "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestActivityRejectsBadGatewayCursorInsideComposite(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	cursor := encodeFederatedActivityCursor(federatedActivityCursor{Version: 1, Gateway: "not-a-gateway-cursor"})
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?since_cursor="+url.QueryEscape(*cursor), "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestActivityGatewayBadCursorPropagatesBadRequest(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusBadRequest,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"error":{"code":"bad_request"}}`)),
		}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity", "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestActivityCompositeCursorSeparatesLocalAndGatewaySources(t *testing.T) {
	h, db := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	seedRequestLog(t, db, fixedExplorerTime().Add(-time.Minute), "req_local_composite")
	gatewayCursor0 := "eyJ0cyI6IjIwMjYtMDYtMDFUMTE6NTk6MDBaIiwicmFuayI6ODAsInNvdXJjZSI6InVzYWdlIiwiaWQiOiJyZXFfZ2F0ZXdheV9jb21wb3NpdGVfMCJ9"
	gatewayCursor1 := "eyJ0cyI6IjIwMjYtMDYtMDFUMTE6NTk6MzBaIiwicmFuayI6ODAsInNvdXJjZSI6InVzYWdlIiwiaWQiOiJyZXFfZ2F0ZXdheV9jb21wb3NpdGVfMSJ9"
	gatewayCursor2 := "eyJ0cyI6IjIwMjYtMDYtMDFUMTI6MDA6MzBaIiwicmFuayI6ODAsInNvdXJjZSI6InVzYWdlIiwiaWQiOiJyZXFfZ2F0ZXdheV9jb21wb3NpdGVfMiJ9"
	var gotQueries []string
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		gotQueries = append(gotQueries, r.URL.RawQuery)
		body := `{"events":[{"event_time_utc":"2026-06-01T11:59:00Z","event_type":"usage","source":"gateway","source_id":"req_gateway_composite_0","request_id":"req_gateway_composite_0","cursor":"` + gatewayCursor0 + `"}],"latest_cursor":"` + gatewayCursor0 + `","next_cursor":null,"partial":false,"error":null}`
		if strings.Contains(r.URL.RawQuery, "since_cursor=") {
			body = `{"events":[{"event_time_utc":"2026-06-01T11:59:30Z","event_type":"usage","source":"gateway","source_id":"req_gateway_composite_1","request_id":"req_gateway_composite_1","cursor":"` + gatewayCursor1 + `"},{"event_time_utc":"2026-06-01T12:00:30Z","event_type":"usage","source":"gateway","source_id":"req_gateway_composite_2","request_id":"req_gateway_composite_2","cursor":"` + gatewayCursor2 + `"}],"latest_cursor":"` + gatewayCursor2 + `","next_cursor":"` + gatewayCursor2 + `","partial":false,"error":null}`
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(body)),
		}, nil
	})}
	from := fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339)
	to := fixedExplorerTime().Add(time.Hour).Format(time.RFC3339)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?limit=1&from="+from+"&to="+to, "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := decodeObject(t, resp)
	if got := len(body["events"].([]any)); got != 1 {
		t.Fatalf("merged limit not enforced: got %d body=%s", got, resp.Body.String())
	}
	latest, ok := body["latest_cursor"].(string)
	if !ok || latest == "" {
		t.Fatalf("missing composite latest cursor: %s", resp.Body.String())
	}
	resp = requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?limit=1&from="+from+"&to="+to+"&since_cursor="+url.QueryEscape(latest), "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("since status=%d body=%s", resp.Code, resp.Body.String())
	}
	body = decodeObject(t, resp)
	if got := len(body["events"].([]any)); got != 1 {
		t.Fatalf("since merged limit not enforced: got %d body=%s", got, resp.Body.String())
	}
	if len(gotQueries) < 2 || strings.Contains(gotQueries[1], latest) || !strings.Contains(gotQueries[1], "since_cursor="+url.QueryEscape(gatewayCursor0)) {
		t.Fatalf("gateway did not receive source cursor only: queries=%v latest=%s", gotQueries, latest)
	}
	next, ok := body["next_cursor"].(string)
	if !ok || next == "" {
		t.Fatalf("missing next cursor for overflow: %s", resp.Body.String())
	}
	resp = requestExplorer(t, h, http.MethodGet, "/admin/explorer/activity?limit=1&from="+from+"&to="+to+"&since_cursor="+url.QueryEscape(next), "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("next since status=%d body=%s", resp.Code, resp.Body.String())
	}
	if len(gotQueries) < 3 || !strings.Contains(gotQueries[2], "since_cursor="+url.QueryEscape(gatewayCursor1)) {
		t.Fatalf("next page did not advance to newest delivered gateway cursor: queries=%v", gotQueries)
	}
}

func TestAC18_PollingPausesOnHiddenTab(t *testing.T) {
	raw := readStatic(t, "static/js/lib/poll.js")
	for _, want := range []string{"document.visibilityState === \"visible\"", "document.visibilityState === \"hidden\"", "timers.clear()"} {
		if !strings.Contains(raw, want) {
			t.Fatalf("poll.js missing %q", want)
		}
	}
}

func TestAC19_RequestCapClientWiring(t *testing.T) {
	raw := readStatic(t, "static/js/lib/api.js")
	for _, want := range []string{"REQUESTS_PER_MINUTE_CAP = 60", "queue = queue.catch", "stamps.length >= REQUESTS_PER_MINUTE_CAP"} {
		if !strings.Contains(raw, want) {
			t.Fatalf("api.js missing %q", want)
		}
	}
}

func TestServerRequestCapUsesClientHostNotPort(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.RequestsPerMinuteCap = 1 })
	for i, remote := range []string{"203.0.113.10:1000", "203.0.113.10:1001"} {
		req := httptest.NewRequest(http.MethodGet, "/admin/explorer/overview", nil)
		req.RemoteAddr = remote
		req.Header.Set("Authorization", "Bearer operator-key")
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		want := http.StatusOK
		if i == 1 {
			want = http.StatusTooManyRequests
		}
		if resp.Code != want {
			t.Fatalf("%s status=%d want=%d body=%s", remote, resp.Code, want, resp.Body.String())
		}
	}
}

func TestDashboardCrossViewLinkWiring(t *testing.T) {
	raw := readStatic(t, "static/js/dashboard.js")
	for _, want := range []string{
		`dataset.view`,
		`/admin/explorer/sessions/${encodeURIComponent(v)}`,
		`/admin/explorer/buyers/${encodeURIComponent(v)}`,
		`/admin/explorer/providers/${encodeURIComponent(v)}`,
		`/admin/explorer/settlements/${encodeURIComponent(v)}`,
		`Last reconciliation ledger window`,
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("dashboard.js missing %q", want)
		}
	}
	if strings.Contains(raw, "innerHTML") {
		t.Fatal("dashboard.js must render with DOM nodes and textContent, not innerHTML")
	}
}

func TestGatewayHealthUnknownWhenDisabled(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/health", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"gateway_health":"unknown"`) {
		t.Fatalf("gateway health unknown missing: %s", resp.Body.String())
	}
}

func TestAC21_BuyerDirectoryPathProxy(t *testing.T) {
	var gotPath, gotQuery, gotAuth string
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		gotAuth = r.Header.Get("Authorization")
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"items":[{"account_id":"acct_proxy"}],"next_cursor":null,"partial":false,"error":null}`)),
		}, nil
	})}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/buyers?limit=7", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if gotPath != "/admin/explorer/buyers" || gotQuery != "limit=7" {
		t.Fatalf("gateway got path=%q query=%q", gotPath, gotQuery)
	}
	if gotAuth != "Bearer operator-key" {
		t.Fatalf("gateway auth=%q", gotAuth)
	}
	if !strings.Contains(resp.Body.String(), "acct_proxy") {
		t.Fatalf("proxied account missing: %s", resp.Body.String())
	}
}

func TestAC23_DeferredEndpointsDoNotExist(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/in-flight", "operator-key")
	if resp.Code != http.StatusNotFound {
		t.Fatalf("in-flight status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestAC24_NoSSEEndpoint(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	for _, path := range []string{"/admin/explorer/stream", "/admin/explorer/events"} {
		resp := requestExplorer(t, h, http.MethodGet, path, "operator-key")
		if resp.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
}

func TestAC25_CoreExplorerRoutesTraverseSuccessfully(t *testing.T) {
	h, _ := newTestExplorer(t, func(cfg *config.Config) { cfg.Explorer.GatewayBaseURL = "http://gateway.test" })
	left, right := net.Pipe()
	t.Cleanup(func() { _ = left.Close(); _ = right.Close() })
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{ProviderID: "provider_seed", AssignedID: "assigned_seed", ModelID: "llama", State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1}, left)
	h.pool = registry
	h.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"items":[{"account_id":"acct_walk"}],"next_cursor":null,"partial":false,"error":null}`)),
		}, nil
	})}
	for _, path := range []string{
		"/admin/explorer/overview?include_gateway=false",
		"/admin/explorer/sessions",
		"/admin/explorer/sessions/req_seed",
		"/admin/explorer/buyers",
		"/admin/explorer/providers",
		"/admin/explorer/providers/provider_seed",
		"/admin/explorer/ledger",
		"/admin/explorer/settlements",
		"/admin/explorer/settlements/1",
		"/admin/explorer/health",
		"/admin/explorer/activity",
	} {
		resp := requestExplorer(t, h, http.MethodGet, path, "operator-key")
		if resp.Code != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
}

func TestAC26_StaticBundleHasNoThirdPartyJS(t *testing.T) {
	raw := readStatic(t, "static/index.html") + readStatic(t, "static/js/dashboard.js") + readStatic(t, "static/js/lib/api.js")
	for _, forbidden := range []string{"https://", "http://", "react", "next", "chart.js", "fonts.googleapis"} {
		if strings.Contains(strings.ToLower(raw), forbidden) {
			t.Fatalf("static bundle contains forbidden reference %q", forbidden)
		}
	}
}

func TestAC27_EndpointMethodsAreReadOnly(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	for _, path := range []string{
		"/admin/explorer/overview",
		"/admin/explorer/sessions",
		"/admin/explorer/providers",
		"/admin/explorer/ledger",
		"/admin/explorer/settlements",
		"/admin/explorer/health",
		"/admin/explorer/activity",
		"/admin/explorer/feedback",
	} {
		resp := requestExplorer(t, h, http.MethodDelete, path, "operator-key")
		if resp.Code != http.StatusNotFound && resp.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s delete status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
}

func TestAC28_NoExplorerWrites(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	before := tableSnapshots(t, db)
	for _, path := range []string{
		"/admin/explorer/overview",
		"/admin/explorer/sessions",
		"/admin/explorer/providers",
		"/admin/explorer/ledger",
		"/admin/explorer/settlements",
		"/admin/explorer/health",
		"/admin/explorer/activity",
		"/admin/explorer/feedback",
		"/admin/explorer/buyers",
	} {
		resp := requestExplorer(t, h, http.MethodGet, path, "operator-key")
		if resp.Code >= 500 && resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s status=%d body=%s", path, resp.Code, resp.Body.String())
		}
	}
	after := tableSnapshots(t, db)
	for table, beforeState := range before {
		if after[table] != beforeState {
			t.Fatalf("%s changed: before=%+v after=%+v", table, beforeState, after[table])
		}
	}
}

func newTestExplorer(t *testing.T, mutate func(*config.Config)) (*Handler, *sql.DB) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	tokenStore, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("auth.OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = tokenStore.Close() })
	reqStore, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("requestlog.OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	_, err = billing.NewStore(reqStore.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	// SPEC-007 v0.3 §5.6 both-or-nothing: the default fixture row
	// MUST carry both external_request_id and account_id so the
	// gateway-proxy path is exercised by existing tests (e.g.
	// TestAC07_SessionDetailIncludesLocalAndGatewayData). Legacy /
	// incomplete-identity rows are exercised by their own targeted
	// tests (e.g. TestSessionDetailGatewayProxySkippedOnIncompleteIdentity).
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:             fixedExplorerTime(),
		RequestID:         "req_seed",
		ExternalRequestID: "buyer_seed_X",
		AccountID:         "acct_seed",
		Model:             "llama",
		Status:            http.StatusOK,
	}); err != nil {
		t.Fatalf("request log insert: %v", err)
	}
	if _, err := reqStore.DB().ExecContext(context.Background(), `
insert into ledger_request_credits (
	request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model, status, stream,
	prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
	prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm,
	gross_credits, provider_share_bps, provider_credits, created_at_utc
) values (?, 0, 'provider_seed', 'assigned_seed', ?, 'llama', 200, 0, 10, 5, NULL, 'provider_reported', 1, 1, 1000000, 15, 9000, 13, ?)`,
		"req_seed", fixedExplorerTime().Format(time.RFC3339Nano), fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed ledger_request_credits: %v", err)
	}
	if _, err := reqStore.DB().ExecContext(context.Background(), `
insert into ledger_operator_credits (
	request_credit_id, request_id, attempt_n, provider_id, ts_utc, gross_credits,
	operator_share_bps, operator_credits, created_at_utc
) values (1, 'req_seed', 0, 'provider_seed', ?, 15, 1000, 2, ?)`,
		fixedExplorerTime().Format(time.RFC3339Nano), fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed ledger_operator_credits: %v", err)
	}
	if _, err := reqStore.DB().ExecContext(context.Background(), `
insert into ledger_reconciliation_runs (
	run_type, from_utc, to_utc, request_log_rows_scanned, missing_credit_rows_created,
	orphan_credit_rows_quarantined, buyer_equivalent_credits, provider_gross_credits,
	reconciliation_delta_credits, started_at_utc, finished_at_utc, status, created_at_utc
) values ('nightly_reconcile', ?, ?, 1, 0, 0, 15, 15, 123, ?, ?, 'complete', ?)`,
		fixedExplorerTime().Add(-time.Hour).Format(time.RFC3339Nano),
		fixedExplorerTime().Format(time.RFC3339Nano),
		fixedExplorerTime().Format(time.RFC3339Nano),
		fixedExplorerTime().Format(time.RFC3339Nano),
		fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed ledger_reconciliation_runs: %v", err)
	}
	if _, err := reqStore.DB().ExecContext(context.Background(), `
insert into ledger_payout_ready (
	provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
	gross_credits, provider_credits, operator_credits, min_payout_credits,
	payout_currency, payout_external_id, status, idempotency_key, created_at_utc
) values ('provider_seed', ?, ?, 1, 1, 15, 13, 2, 1, 'credits', NULL, 'ready', 'settlement_seed', ?)`,
		fixedExplorerTime().Add(-24*time.Hour).Format(time.RFC3339Nano),
		fixedExplorerTime().Format(time.RFC3339Nano),
		fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed ledger_payout_ready: %v", err)
	}
	cfg := config.Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Explorer.Enabled = true
	if mutate != nil {
		mutate(&cfg)
	}
	return NewHandler(cfg, reqStore.DB(), pool.NewRegistry(nil), fixedExplorerTime()), reqStore.DB()
}

func requestExplorer(t *testing.T, h *Handler, method, path, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	return resp
}

func seedRequestLog(t *testing.T, db *sql.DB, ts time.Time, requestID string) {
	t.Helper()
	if _, err := db.ExecContext(context.Background(), `
insert into request_log (
	ts_utc, request_id, model, provider_assigned_id, prompt_tokens, completion_tokens,
	total_tokens, latency_ms, routing_ms, status, stream, buyer_ip, error, error_code,
	pref_header, provider_header, retried
) values (?, ?, 'llama', 'assigned_seed', 1, 1, 2, 10, 2, 200, 0, '', NULL, NULL, NULL, NULL, 0)`,
		ts.UTC().Format(time.RFC3339Nano), requestID); err != nil {
		t.Fatalf("seed request_log: %v", err)
	}
}

func seedSettlement(t *testing.T, db *sql.DB, providerID, status string, windowEnd time.Time, key string) {
	t.Helper()
	if _, err := db.ExecContext(context.Background(), `
insert into ledger_payout_ready (
	provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
	gross_credits, provider_credits, operator_credits, min_payout_credits,
	payout_currency, payout_external_id, status, idempotency_key, created_at_utc
) values (?, ?, ?, 1, 1, 21, 19, 2, 1, 'credits', NULL, ?, ?, ?)`,
		providerID,
		windowEnd.Add(-24*time.Hour).Format(time.RFC3339Nano),
		windowEnd.Format(time.RFC3339Nano),
		status,
		key,
		fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("seed settlement: %v", err)
	}
}

func decodeObject(t *testing.T, resp *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode json: %v body=%s", err, resp.Body.String())
	}
	return out
}

func requestIDs(items []any) map[string]bool {
	out := map[string]bool{}
	for _, item := range items {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if id, ok := row["request_id"].(string); ok {
			out[id] = true
		}
	}
	return out
}

func tableCounts(t *testing.T, db *sql.DB) map[string]int {
	t.Helper()
	out := map[string]int{}
	for _, table := range []string{"request_log", "ledger_request_credits", "ledger_operator_credits", "ledger_payout_ready", "ledger_reconciliation_runs", "provider_tokens"} {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		out[table] = n
	}
	return out
}

type tableSnapshot struct {
	Count int
	MaxID int64
}

func tableSnapshots(t *testing.T, db *sql.DB) map[string]tableSnapshot {
	t.Helper()
	out := map[string]tableSnapshot{}
	for _, table := range []string{"request_log", "ledger_request_credits", "ledger_operator_credits", "ledger_payout_ready", "ledger_reconciliation_runs", "provider_tokens"} {
		var snap tableSnapshot
		if err := db.QueryRow(`SELECT COUNT(*), COALESCE(MAX(rowid), 0) FROM `+table).Scan(&snap.Count, &snap.MaxID); err != nil {
			t.Fatalf("snapshot %s: %v", table, err)
		}
		out[table] = snap
	}
	return out
}

func readStatic(t *testing.T, name string) string {
	t.Helper()
	b, err := staticFS.ReadFile(name)
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(b)
}

func fixedExplorerTime() time.Time {
	return time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}
