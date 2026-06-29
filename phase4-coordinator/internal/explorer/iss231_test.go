package explorer

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// TestSessionDetail_IntPrefixIsStripped pins SPEC-007 v0.4 §5.6
// (#231) path-segment typing: the coordinator handler MUST accept
// an `int_<request_id>` prefix and resolve the stripped value as
// the coordinator-internal request_id. Backward compatibility is
// covered by the existing v0.3 tests that pass bare UUIDs.
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

// TestSessionDetail_UntypedEmitsDeprecationLog pins the v0.4
// deprecation contract: untyped (bare-UUID) path-segments are still
// accepted in v0.4 BUT MUST emit a structured
// payout_explorer_path_segment_untyped log row so operators see
// the upcoming v0.5 break.
func TestSessionDetail_UntypedEmitsDeprecationLog(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream)
		 VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0)`,
		fixedExplorerTime().Format(time.RFC3339Nano), "untyped-bare-uuid", "", "", "llama", http.StatusOK); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// Capture stdlib log output (the handler's untyped-deprecation
	// path uses stdLog.Printf — same mechanism as logBearerAccepted).
	var buf bytes.Buffer
	prevOut := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prevOut)
	prevFlags := log.Flags()
	log.SetFlags(0)
	defer log.SetFlags(prevFlags)

	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/untyped-bare-uuid", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	out := buf.String()
	if !strings.Contains(out, `"event":"payout_explorer_path_segment_untyped"`) {
		t.Errorf("expected deprecation log line; got: %q", out)
	}
	if !strings.Contains(out, `"severity":"WARN"`) {
		t.Errorf("expected WARN severity; got: %q", out)
	}
	if !strings.Contains(out, `"request_id":"untyped-bare-uuid"`) {
		t.Errorf("expected request_id field; got: %q", out)
	}
}

// TestSessionDetail_TypedPrefixSuppressesDeprecationLog pins the
// inverse: when `int_` IS supplied, NO deprecation log fires.
func TestSessionDetail_TypedPrefixSuppressesDeprecationLog(t *testing.T) {
	h, db := newTestExplorer(t, nil)
	if _, err := db.ExecContext(context.Background(),
		`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream)
		 VALUES (?, ?, ?, ?, ?, 0, 0, ?, 0)`,
		fixedExplorerTime().Format(time.RFC3339Nano), "typed-uuid-aaaa", "", "", "llama", http.StatusOK); err != nil {
		t.Fatalf("seed: %v", err)
	}
	var buf bytes.Buffer
	prevOut := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prevOut)
	resp := requestExplorer(t, h, http.MethodGet, "/admin/explorer/sessions/int_typed-uuid-aaaa", "operator-key")
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if strings.Contains(buf.String(), "payout_explorer_path_segment_untyped") {
		t.Errorf("typed prefix MUST NOT emit deprecation log; got: %q", buf.String())
	}
}

// ensure unused-import guard
var _ = io.Discard
var _ = config.Config{}
