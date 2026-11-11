package sourceevidence

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCanonicalBytesSortsKeysAndNormalizesTypes(t *testing.T) {
	in := map[string]any{
		"b": []any{int64(2), json.Number("3"), true, nil},
		"a": "x\"y",
		"c": map[string]any{"z": 1, "y": false},
	}
	got, err := canonicalBytes(in)
	if err != nil {
		t.Fatalf("canonicalBytes: %v", err)
	}
	want := `{"a":"x\"y","b":[2,3,true,null],"c":{"y":false,"z":1}}`
	if string(got) != want {
		t.Fatalf("got %s want %s", got, want)
	}
	// Typed structs go through the JSON round trip default branch.
	got, err = canonicalBytes(struct {
		B int    `json:"b"`
		A string `json:"a"`
	}{B: 7, A: "q"})
	if err != nil {
		t.Fatalf("canonicalBytes struct: %v", err)
	}
	if string(got) != `{"a":"q","b":7}` {
		t.Fatalf("struct canonical = %s", got)
	}
}

func TestValidateCanonicalRejectsUnsafeValues(t *testing.T) {
	over := maxSafeIntegerInt64 + 1
	cases := map[string]any{
		"negative int":       -1,
		"negative int64":     int64(-5),
		"int over bound":     int(over),
		"int64 over bound":   over,
		"float64":            1.5,
		"float32":            float32(1),
		"number leading 0":   json.Number("01"),
		"number fraction":    json.Number("1.0"),
		"number negative":    json.Number("-1"),
		"number over bound":  json.Number("9007199254740993"),
		"non-ascii string":   "café",
		"control char":       "a\nb",
		"long string":        strings.Repeat("a", maxCanonicalStringBytes+1),
		"long array":         make([]any, maxCanonicalArrayItems+1),
		"empty key":          map[string]any{" ": "v"},
		"non-ascii key":      map[string]any{"ké": "v"},
		"long key":           map[string]any{strings.Repeat("k", maxCanonicalKeyBytes+1): "v"},
		"nested bad value":   map[string]any{"a": []any{1.5}},
		"unmarshalable type": make(chan int),
	}
	for name, v := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := canonicalBytes(v); err == nil {
				t.Fatalf("canonicalBytes accepted %s", name)
			}
		})
	}
	if _, err := canonicalBytes(maxSafeIntegerInt64); err != nil {
		t.Fatalf("max safe integer rejected: %v", err)
	}
}

func TestDecodeStrictJSONBytesTypedDestination(t *testing.T) {
	var s Scope
	err := decodeStrictJSONBytes([]byte(`{"account_id":"a","external_request_id":"e","required_internal_request_id":"r","not_before_unix_ms":5}`), &s)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if s.AccountID != "a" || s.NotBeforeUnixMS != 5 {
		t.Fatalf("scope = %+v", s)
	}
	if err := decodeStrictJSONBytes([]byte(`{"account_id":"a","bogus":"x"}`), &s); err == nil {
		t.Fatalf("unknown field accepted")
	}
	if err := decodeStrictJSONBytes([]byte(`{"account_id":1.5}`), &s); err == nil {
		t.Fatalf("float accepted")
	}
	if err := decodeStrictJSONBytes([]byte(`{}`), nil); err != nil {
		t.Fatalf("nil dst: %v", err)
	}
	for _, bad := range []string{`[1,2`, `{"a":1`, `{"a"`, `{1:2}`, ``, `{"a":1}}`} {
		if err := decodeStrictJSONBytes([]byte(bad), nil); err == nil {
			t.Fatalf("malformed %q accepted", bad)
		}
	}
	deep := strings.Repeat("[", maxStrictJSONDepth+5) + strings.Repeat("]", maxStrictJSONDepth+5)
	if err := decodeStrictJSONBytes([]byte(deep), nil); err == nil {
		t.Fatalf("over-deep JSON accepted")
	}
}

func TestLoadStrictJSONFileBounded(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	if err := os.WriteFile(good, []byte(`{"b":1,"a":[true]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	v, err := loadStrictJSONFileBounded(good, 0)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	m, ok := v.(map[string]any)
	if !ok || len(m) != 2 {
		t.Fatalf("value = %#v", v)
	}
	if _, err := loadStrictJSONFileBounded(good, 5); err == nil {
		t.Fatalf("size bound not enforced")
	}
	if _, err := loadStrictJSONFileBounded("  ", 10); err == nil {
		t.Fatalf("blank path accepted")
	}
	if _, err := loadStrictJSONFileBounded(filepath.Join(dir, "missing.json"), 10); err == nil {
		t.Fatalf("missing file accepted")
	}
	dup := filepath.Join(dir, "dup.json")
	if err := os.WriteFile(dup, []byte(`{"a":1,"a":2}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadStrictJSONFileBounded(dup, 100); err == nil {
		t.Fatalf("duplicate key accepted")
	}
}

func TestFixedProvenanceValidate(t *testing.T) {
	ok := FixedProvenance{
		InstanceID: "i", KeyID: "k", ReviewedRegistryPath: "/r",
		SourceSHA:      strings.Repeat("a", 40),
		RegistryDigest: "sha256:" + strings.Repeat("b", 64),
	}
	if err := ok.validate(); err != nil {
		t.Fatalf("valid provenance rejected: %v", err)
	}
	mut := map[string]func(*FixedProvenance){
		"blank instance":   func(p *FixedProvenance) { p.InstanceID = " " },
		"blank key":        func(p *FixedProvenance) { p.KeyID = "" },
		"blank path":       func(p *FixedProvenance) { p.ReviewedRegistryPath = "" },
		"short sha":        func(p *FixedProvenance) { p.SourceSHA = "abc" },
		"uppercase sha":    func(p *FixedProvenance) { p.SourceSHA = strings.Repeat("A", 40) },
		"digest no prefix": func(p *FixedProvenance) { p.RegistryDigest = strings.Repeat("b", 64) },
		"digest short":     func(p *FixedProvenance) { p.RegistryDigest = "sha256:abc" },
	}
	for name, f := range mut {
		p := ok
		f(&p)
		if err := p.validate(); !errors.Is(err, ErrProvenanceMissing) {
			t.Fatalf("%s: err=%v want ErrProvenanceMissing", name, err)
		}
	}
	if sha := DefaultFixedProvenance().SourceSHA; sha != "" && !hex40RE.MatchString(sha) {
		t.Fatalf("default sha %q is not a clean 40-hex revision", sha)
	}
}

func TestCommitmentsAreDomainSeparatedAndLengthPrefixed(t *testing.T) {
	key := []byte("01234567890123456789012345678901")
	a := ScopeCommitment(key, Scope{AccountID: "ab", ExternalRequestID: "c", RequiredInternalRequestID: "d"})
	b := ScopeCommitment(key, Scope{AccountID: "a", ExternalRequestID: "bc", RequiredInternalRequestID: "d"})
	if a == b || !hex64RE.MatchString(a) {
		t.Fatalf("length prefixing failed: %s %s", a, b)
	}
	if a != ScopeCommitment(key, Scope{AccountID: "ab", ExternalRequestID: "c", RequiredInternalRequestID: "d", NotBeforeUnixMS: 99}) {
		t.Fatalf("not_before must not affect scope commitment")
	}
	if InternalRequestCommitment(key, "7") == ClosureIDCommitment(key, 7) {
		t.Fatalf("domains not separated")
	}
	if ClosureIDCommitment(key, 7) == ClosureIDCommitment([]byte("abcdefghijklmnopqrstuvwxyz012345"), 7) {
		t.Fatalf("key not mixed in")
	}
	if got := utcMillis(time.Date(2026, 1, 2, 3, 4, 5, 6_000_000, time.FixedZone("x", 3600))); got != "2026-01-02T02:04:05.006Z" {
		t.Fatalf("utcMillis = %s", got)
	}
}

func TestNewStoreAndMigrateValidation(t *testing.T) {
	if _, err := NewStore(nil, make([]byte, 32), nil); err == nil {
		t.Fatalf("nil db accepted")
	}
	store, db := newTestStore(t)
	if _, err := NewStore(db, make([]byte, 31), nil); err == nil {
		t.Fatalf("short key accepted")
	}
	if err := Migrate(context.Background(), nil); err == nil {
		t.Fatalf("Migrate nil db accepted")
	}
	if err := Migrate(context.Background(), db); err != nil {
		t.Fatalf("Migrate not idempotent: %v", err)
	}
	k := store.HMACKey()
	k[0] ^= 0xff
	if store.HMACKey()[0] == k[0] {
		t.Fatalf("HMACKey returned aliased slice")
	}
	def, err := NewStore(db, make([]byte, 32), nil)
	if err != nil || def.now == nil {
		t.Fatalf("default clock not set: %v", err)
	}
}

func TestRecordNoDispatchRejectsInvalidInputs(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t)
	id := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	base := func() ClosureInput {
		return ClosureInput{TerminalKind: TerminalModelNotFound, Row: testNoDispatchRow("acct", "ext", id, 404, "")}
	}
	mut := map[string]func(*ClosureInput){
		"provider assigned":    func(c *ClosureInput) { c.Row.ProviderAssignedID = "p" },
		"missing request id":   func(c *ClosureInput) { c.Row.RequestID = "" },
		"missing account":      func(c *ClosureInput) { c.Row.AccountID = "" },
		"missing external id":  func(c *ClosureInput) { c.Row.ExternalRequestID = "" },
		"unknown terminal":     func(c *ClosureInput) { c.TerminalKind = "other" },
		"model-not-found 503":  func(c *ClosureInput) { c.Row.Status = 503 },
		"model-not-found text": func(c *ClosureInput) { c.Row.Error = "boom" },
		"pool status":          func(c *ClosureInput) { c.TerminalKind = TerminalPoolUnavailable },
	}
	for name, f := range mut {
		in := base()
		f(&in)
		if err := store.RecordNoDispatch(ctx, in); !errors.Is(err, ErrUnavailable) {
			t.Fatalf("%s: err=%v want ErrUnavailable", name, err)
		}
	}
	var nilStore *Store
	if err := nilStore.RecordNoDispatch(ctx, base()); !errors.Is(err, ErrDisabled) {
		t.Fatalf("nil store err=%v", err)
	}
	if _, err := nilStore.ResolveClosedBatch(ctx, []Scope{{}}); !errors.Is(err, ErrDisabled) {
		t.Fatalf("nil store resolve err=%v", err)
	}
	if _, err := store.ResolveClosedBatch(ctx, nil); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("empty batch err=%v", err)
	}
}

func TestResolveClosedFencesAndMissingScope(t *testing.T) {
	ctx := context.Background()
	store, db := newTestStore(t)
	row := testNoDispatchRow("acct-f", "ext-f", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", 503, "Pool unavailable")
	if err := store.RecordNoDispatch(ctx, ClosureInput{TerminalKind: TerminalPoolUnavailable, Row: row}); err != nil {
		t.Fatal(err)
	}
	scope := Scope{AccountID: row.AccountID, ExternalRequestID: row.ExternalRequestID, RequiredInternalRequestID: row.RequestID}
	rec, err := store.ResolveClosed(ctx, scope)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if rec.LogStatus != 503 || rec.Closure.TerminalKind != TerminalPoolUnavailable || !hex64RE.MatchString(rec.ClosureIDHMAC) {
		t.Fatalf("record = %+v", rec)
	}
	if rec.ClosureIDHMAC != ClosureIDCommitment(store.HMACKey(), rec.Closure.ID) {
		t.Fatalf("closure id hmac mismatch")
	}
	if len(rec.Absence) != len(settlementTables) {
		t.Fatalf("absence = %+v", rec.Absence)
	}
	for table, a := range rec.Absence {
		if a.Count != 0 || a.MaxID != 0 {
			t.Fatalf("%s absence = %+v", table, a)
		}
	}
	// Fence in the future (log ts is 11:59:59, closure 12:00:00).
	fenced := scope
	fenced.NotBeforeUnixMS = time.Date(2026, 10, 7, 11, 59, 59, 500_000_000, time.UTC).UnixMilli()
	if _, err := store.ResolveClosed(ctx, fenced); !errors.Is(err, ErrScopeNotClosed) {
		t.Fatalf("stale fence err=%v", err)
	}
	// Fence after the log row but before closure still fails on the log row.
	fenced.NotBeforeUnixMS = time.Date(2026, 10, 7, 12, 0, 0, 1_000_000, time.UTC).UnixMilli()
	if _, err := store.ResolveClosed(ctx, fenced); !errors.Is(err, ErrScopeNotClosed) {
		t.Fatalf("stale fence (closure) err=%v", err)
	}
	// Wrong scope components never resolve.
	wrong := scope
	wrong.AccountID = "other"
	if _, err := store.ResolveClosed(ctx, wrong); !errors.Is(err, ErrScopeNotClosed) {
		t.Fatalf("wrong account err=%v", err)
	}
	// Tampering: a provider assigned after closure invalidates the proof.
	if _, err := db.ExecContext(ctx, `UPDATE request_log SET provider_assigned_id = 'p1' WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResolveClosed(ctx, scope); !errors.Is(err, ErrScopeNotClosed) {
		t.Fatalf("provider-assigned err=%v", err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE request_log SET provider_assigned_id = NULL, status = 500 WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ResolveClosed(ctx, scope); !errors.Is(err, ErrScopeNotClosed) {
		t.Fatalf("status mismatch err=%v", err)
	}
}

func TestHandlerMethodBodyAndStrictness(t *testing.T) {
	h := NewHandler("op", nil, 0)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/x", nil))
	if rec.Code != http.StatusMethodNotAllowed || rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("GET status=%d", rec.Code)
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.Error.Code != "method_not_allowed" {
		t.Fatalf("body=%s err=%v", rec.Body.String(), err)
	}
	// Producer present but request body malformed: 400 before any export.
	hh := &Handler{operatorKey: "op", producer: &Producer{}, maxBody: 32}
	for name, payload := range map[string]string{
		"duplicate key": `{"run_id":"a","run_id":"b"}`,
		"too large":     `{"run_id":"` + strings.Repeat("a", 64) + `"}`,
		"unknown field": `{"nope":1}`,
	} {
		req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(payload))
		req.Header.Set("Authorization", "Bearer op")
		rec := httptest.NewRecorder()
		hh.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: status=%d body=%s", name, rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "invalid_source_evidence_request") {
			t.Fatalf("%s: body=%s", name, rec.Body.String())
		}
	}
}
