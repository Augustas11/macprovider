package explorer

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestWindowAndLimitParsing(t *testing.T) {
	h := &Handler{}
	cases := []struct {
		name    string
		query   string
		ok      bool
		limit   int
		hours   float64
		errText string
	}{
		{"defaults", "to=2026-01-10T00:00:00Z", true, 50, 24, ""},
		{"limit capped", "to=2026-01-10T00:00:00Z&limit=999", true, 200, 24, ""},
		{"window_hours capped at max days", "to=2026-01-10T00:00:00Z&window_hours=9999", true, 50, 72, ""},
		{"window_hours explicit", "to=2026-01-10T00:00:00Z&window_hours=6", true, 50, 6, ""},
		{"bad limit", "limit=abc", false, 0, 0, "invalid limit"},
		{"zero limit", "limit=0", false, 0, 0, "invalid limit"},
		{"bad window_hours", "window_hours=-1", false, 0, 0, "invalid window_hours"},
		{"bad to", "to=yesterday", false, 0, 0, "invalid to"},
		{"bad from", "from=nope", false, 0, 0, "invalid from"},
		{"from after to", "from=2026-01-10T00:00:00Z&to=2026-01-09T00:00:00Z", false, 0, 0, "from must be before to"},
		{"explicit window too large", "from=2026-01-01T00:00:00Z&to=2026-01-10T00:00:00Z", false, 0, 0, "window exceeds maximum"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/x?"+tc.query, nil)
			rec := httptest.NewRecorder()
			win, limit, ok := h.windowAndLimit(rec, req, 24, 3)
			if ok != tc.ok {
				t.Fatalf("ok=%v body=%s", ok, rec.Body.String())
			}
			if !ok {
				if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), tc.errText) {
					t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
				}
				return
			}
			if limit != tc.limit {
				t.Fatalf("limit=%d want %d", limit, tc.limit)
			}
			if got := win.to.Sub(win.from).Hours(); got != tc.hours {
				t.Fatalf("window hours=%v want %v", got, tc.hours)
			}
		})
	}
}

func TestCursorValidators(t *testing.T) {
	enc := func(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }
	good := enc(`{"ts":"2026-01-01T00:00:00Z","id":5}`)
	if c, err := decodeCursor(good); err != nil || c.ID != 5 {
		t.Fatalf("good cursor: %+v %v", c, err)
	}
	for _, bad := range []string{"!!!", enc("not json"), enc(`{"ts":"","id":1}`), enc(`{"ts":"2026-01-01T00:00:00Z","id":0}`), enc(`{"ts":"garbage","id":1}`)} {
		if _, err := decodeCursor(bad); !errors.Is(err, ErrBadCursor) {
			t.Errorf("decodeCursor(%q) err=%v", bad, err)
		}
	}
	gwGood := enc(`{"ts":"2026-01-01T00:00:00Z","id":"abc"}`)
	if err := validateGatewayActivityCursor(gwGood); err != nil {
		t.Fatalf("gateway good: %v", err)
	}
	for _, bad := range []string{"!!!", enc("x"), enc(`{"ts":"2026-01-01T00:00:00Z","id":""}`), enc(`{"ts":"","id":"a"}`), enc(`{"ts":"bad","id":"a"}`)} {
		if err := validateGatewayActivityCursor(bad); !errors.Is(err, ErrBadCursor) {
			t.Errorf("validateGatewayActivityCursor(%q) err=%v", bad, err)
		}
	}
}

func TestEncodeCursorFromItem(t *testing.T) {
	item := map[string]any{"ts": "2026-01-01T00:00:00Z", "id": int32(7)}
	raw, ok := encodeCursorFromItem(item, "ts", "id")
	if !ok {
		t.Fatal("expected cursor")
	}
	c, err := decodeCursor(raw)
	if err != nil || c.ID != 7 || c.TS != "2026-01-01T00:00:00Z" {
		t.Fatalf("roundtrip %+v %v", c, err)
	}
	for _, bad := range []map[string]any{
		{"ts": "", "id": 1},
		{"ts": 5, "id": 1},
		{"ts": "2026-01-01T00:00:00Z", "id": 0},
		{"ts": "2026-01-01T00:00:00Z", "id": -3},
		{"ts": "2026-01-01T00:00:00Z", "id": "7"},
		{"ts": "2026-01-01T00:00:00Z"},
	} {
		if _, ok := encodeCursorFromItem(bad, "ts", "id"); ok {
			t.Errorf("expected no cursor for %v", bad)
		}
	}
}

func TestInt64Value(t *testing.T) {
	good := []any{int(3), int64(3), int32(3), int16(3), int8(3), uint(3), uint64(3), uint32(3), uint16(3), uint8(3)}
	for _, v := range good {
		if n, ok := int64Value(v); !ok || n != 3 {
			t.Errorf("%T: %d %v", v, n, ok)
		}
	}
	if _, ok := int64Value(^uint64(0)); ok {
		t.Error("overflowing uint64 must be rejected")
	}
	if _, ok := int64Value("3"); ok {
		t.Error("string must be rejected")
	}
	if _, ok := int64Value(3.0); ok {
		t.Error("float must be rejected")
	}
}

func TestSmallHelpers(t *testing.T) {
	if sourceRank("coordinator") <= sourceRank("gateway") || sourceRank(nil) != sourceRank("gateway") {
		t.Error("coordinator must outrank other sources")
	}
	ts := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	if !timeFromAny(ts).Equal(ts) || !timeFromAny(ts.Format(time.RFC3339Nano)).Equal(ts) {
		t.Error("timeFromAny time/string")
	}
	if !timeFromAny(42).IsZero() || !timeFromAny("junk").IsZero() {
		t.Error("timeFromAny should return zero for junk")
	}
	if valueOrFalse(nil) != false || valueOrFalse(true) != true || valueOrZero(nil) != 0 || valueOrZero(9) != 9 {
		t.Error("valueOr helpers")
	}
	if firstOrNil(nil) != nil {
		t.Error("firstOrNil empty")
	}
	if r := firstOrNil([]map[string]any{{"a": 1}, {"a": 2}}).(map[string]any); r["a"] != 1 {
		t.Error("firstOrNil first")
	}
	if nullString(sql.NullString{}) != nil || nullString(sql.NullString{String: "x", Valid: true}) != "x" {
		t.Error("nullString")
	}
	if clientAddrKey("10.0.0.1:5555") != "10.0.0.1" || clientAddrKey("nohostport") != "nohostport" {
		t.Error("clientAddrKey")
	}
	if encodeTime(time.Time{}) != "" {
		t.Error("zero time must encode empty")
	}
}

func TestWriteExplorerStorageErrorMapping(t *testing.T) {
	cases := []struct {
		err  error
		code int
		body string
	}{
		{sql.ErrNoRows, http.StatusNotFound, "not_found"},
		{context.DeadlineExceeded, http.StatusRequestTimeout, "query_timeout"},
		{errors.New("boom secret detail"), http.StatusInternalServerError, "internal_error"},
	}
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		writeExplorerStorageError(rec, tc.err)
		if rec.Code != tc.code || !strings.Contains(rec.Body.String(), tc.body) {
			t.Errorf("%v: code=%d body=%s", tc.err, rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "secret") {
			t.Errorf("internal error detail leaked: %s", rec.Body.String())
		}
	}
}

func TestExplorerHandlerErrorPaths(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	paths := map[string]int{
		"/admin/explorer/sessions?limit=zzz":         http.StatusBadRequest,
		"/admin/explorer/sessions?cursor=%21%21":     http.StatusBadRequest,
		"/admin/explorer/providers/no-such-provider": http.StatusNotFound,
		"/admin/explorer/settlements/does-not-exist": http.StatusNotFound,
		"/admin/explorer/ledger?window_hours=bad":    http.StatusBadRequest,
		"/admin/explorer/settlements?limit=-2":       http.StatusBadRequest,
		"/admin/explorer/static-missing.js":          http.StatusNotFound,
		"/admin/explorer/activity?limit=0":           http.StatusBadRequest,
	}
	for p, want := range paths {
		resp := requestExplorer(t, h, http.MethodGet, p, "operator-key")
		if resp.Code != want {
			t.Errorf("%s: status=%d want %d body=%s", p, resp.Code, want, resp.Body.String())
			continue
		}
		if ct := resp.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("%s: content-type=%q want application/json", p, ct)
		}
		if !strings.Contains(resp.Body.String(), `"error"`) || !strings.Contains(resp.Body.String(), `"code"`) {
			t.Errorf("%s: body is not a structured error: %s", p, resp.Body.String())
		}
	}
}

func TestGatewayActivityRawQuery(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/a?limit=5&cursor=old", nil)
	q, _ := url.ParseQuery(gatewayActivityRawQuery(req, "new"))
	if q.Get("cursor") != "new" || q.Get("since_cursor") != "" || q.Get("limit") != "5" {
		t.Errorf("cursor mode: %v", q)
	}
	req = httptest.NewRequest(http.MethodGet, "/a?since_cursor=old&cursor=x", nil)
	q, _ = url.ParseQuery(gatewayActivityRawQuery(req, "new"))
	if q.Get("since_cursor") != "new" || q.Get("cursor") != "" {
		t.Errorf("since mode: %v", q)
	}
	q, _ = url.ParseQuery(gatewayActivityRawQuery(req, ""))
	if q.Get("since_cursor") != "" || q.Get("cursor") != "" {
		t.Errorf("empty cursor must drop both: %v", q)
	}
}

func TestServeStaticContentTypes(t *testing.T) {
	h, _ := newTestExplorer(t, nil)
	base := h.cfg.Explorer.BindPath
	root := requestExplorer(t, h, http.MethodGet, base, "")
	if root.Code != http.StatusOK || !strings.HasPrefix(root.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("root code=%d ct=%q", root.Code, root.Header().Get("Content-Type"))
	}
	css := requestExplorer(t, h, http.MethodGet, strings.TrimSuffix(base, "/")+"/css/dashboard.css", "")
	if css.Code != http.StatusOK || css.Header().Get("Content-Type") != "text/css; charset=utf-8" {
		t.Fatalf("css code=%d ct=%q", css.Code, css.Header().Get("Content-Type"))
	}
	js := requestExplorer(t, h, http.MethodGet, strings.TrimSuffix(base, "/")+"/js/dashboard.js", "")
	if js.Code != http.StatusOK || js.Header().Get("Content-Type") != "text/javascript; charset=utf-8" {
		t.Fatalf("js code=%d ct=%q", js.Code, js.Header().Get("Content-Type"))
	}
	missing := requestExplorer(t, h, http.MethodGet, strings.TrimSuffix(base, "/")+"/js/nope.js", "")
	if missing.Code != http.StatusNotFound || missing.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("missing code=%d ct=%q", missing.Code, missing.Header().Get("Content-Type"))
	}
	rec := httptest.NewRecorder()
	h.serveStatic(rec, httptest.NewRequest(http.MethodPost, "/", nil), "/")
	if rec.Code != http.StatusMethodNotAllowed || rec.Header().Get("Allow") != http.MethodGet {
		t.Fatalf("post code=%d allow=%q", rec.Code, rec.Header().Get("Allow"))
	}
}
