package explorer

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestSessionDetail_IntPrefixIsStripped pins SPEC-007 v0.4 §5.6
// (#231) path-segment typing: the coordinator handler MUST accept
// an `int_<request_id>` prefix and resolve the stripped value as
// the coordinator-internal request_id. v0.5 (#245) made the prefix
// the ONLY accepted form — see TestSessionDetail_UntypedReturns400.
func TestSessionDetail_IntPrefixIsStripped(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream)
		 VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0)`,
		fixedExplorerTime().Format(time.RFC3339Nano), "int-prefix-test-uuid", "", "", "llama", http.StatusOK); err != nil {
		t.Fatalf("seed: %v", err)
	}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/int_int-prefix-test-uuid", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s — int_ prefix should strip and resolve", resp.Code, resp.Body.String())
	}
}

// TestSessionDetail_UntypedReturns400 pins SPEC-007 v0.5 §5.6
// (#245): untyped (legacy bare-UUID) path-segments MUST be rejected
// with 400 session_id_untyped. Replaces the v0.4 deprecation-window
// log test (which asserted untyped was accepted with a WARN log).
func TestSessionDetail_UntypedReturns400(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream)
		 VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0)`,
		fixedExplorerTime().Format(time.RFC3339Nano), "untyped-bare-uuid", "", "", "llama", http.StatusOK); err != nil {
		t.Fatalf("seed: %v", err)
	}
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/untyped-bare-uuid", "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s — untyped path-segment MUST return 400", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if !strings.Contains(body, `"code":"session_id_untyped"`) {
		t.Errorf("expected session_id_untyped code; body=%s", body)
	}
	// R1 SEC LOW-1: envelope MUST carry type=invalid_request_error so
	// dashboard / runbook matchers behave the same across coordinator
	// (§5.6) and gateway (§6.4).
	if !strings.Contains(body, `"type":"invalid_request_error"`) {
		t.Errorf("expected type=invalid_request_error; body=%s", body)
	}
}

// TestSessionDetail_EmptyIntPrefixReturns400 pins that
// `int_` with nothing after the prefix is treated as untyped
// (parseTypedSegment-style guard: empty stripped value is not a
// valid typed segment).
func TestSessionDetail_EmptyIntPrefixReturns400(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/int_", "operator-key")
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s — empty int_ prefix MUST 400", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"session_id_untyped"`) {
		t.Errorf("expected session_id_untyped code; body=%s", resp.Body.String())
	}
}

