package verifiedarchive

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// craft writes a gzip archive from raw JSON lines and returns its path and a
// manifest that matches the bytes, so only the content is under test.
func craft(t *testing.T, lines []string, rowCounts map[string]int64, requests int) (string, Manifest) {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	_, _ = gz.Write([]byte(strings.Join(lines, "\n") + "\n"))
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "a"+Suffix)
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(buf.Bytes())
	return path, Manifest{Format: "f", SHA256: hex.EncodeToString(sum[:]), SizeBytes: int64(buf.Len()), RequestCount: requests, RowCounts: rowCounts}
}

const (
	hdr = `{"kind":"header","format":"f"}`
	req = `{"kind":"request","request_id":"g"}`
)

func TestStreamRejectsMalformedContent(t *testing.T) {
	row := func(r string) string { return `{"kind":"row","request_id":"g","table":"t","row":` + r + `}` }
	trailer := `{"kind":"trailer","request_count":1,"row_counts":{"t":1}}`
	// Every case that can reach the trailer carries a valid one and the manifest
	// below matches it, so only the targeted defect can make the archive invalid.
	cases := []struct {
		name  string
		lines []string
		want  string
	}{
		{"unknown kind", []string{hdr, req, row(`{"a":1}`), `{"kind":"zzz"}`, trailer}, "unknown line kind"},
		{"bad json", []string{hdr, req, row(`{"a":1}`), `{not json`, trailer}, "parse line"},
		{"duplicate header", []string{hdr, hdr, req, row(`{"a":1}`), trailer}, "bad header"},
		{"wrong format", []string{`{"kind":"header","format":"x"}`, req, row(`{"a":1}`), trailer}, "bad header"},
		{"request no header", []string{req, row(`{"a":1}`), trailer}, "request before header"},
		{"empty request id", []string{hdr, `{"kind":"request"}`, row(`{"a":1}`), trailer}, "request before header"},
		{"duplicate request", []string{hdr, req, req, row(`{"a":1}`), trailer}, "duplicate request"},
		{"row without group", []string{hdr, row(`{"a":1}`), req, trailer}, "unknown request or table"},
		{"row wrong request", []string{hdr, req, `{"kind":"row","request_id":"h","table":"t","row":{"a":1}}`, trailer}, "unknown request or table"},
		{"row unknown table", []string{hdr, req, `{"kind":"row","request_id":"g","table":"u","row":{"a":1}}`, trailer}, "unknown request or table"},
		{"row nil", []string{hdr, req, `{"kind":"row","request_id":"g","table":"t"}`, trailer}, "unknown request or table"},
		{"row bad object", []string{hdr, req, row(`{"a":{"x":1}}`), trailer}, "unsupported object"},
		{"row bad blob", []string{hdr, req, row(`{"a":{"blob_base64":"!!"}}`), trailer}, "row value"},
		{"row blob extra key", []string{hdr, req, row(`{"a":{"blob_base64":"AA==","y":1}}`), trailer}, "unsupported object"},
		{"row unsupported val", []string{hdr, req, row(`{"a":true}`), trailer}, "unsupported value"},
		{"data after trailer", []string{hdr, req, row(`{"a":1}`), trailer, hdr}, "data after trailer"},
		{"missing trailer", []string{hdr, req, row(`{"a":1}`)}, "missing header or trailer"},
	}
	// Sanity: the same shape without a defect is accepted.
	path, m := craft(t, []string{hdr, req, row(`{"a":1}`), trailer}, map[string]int64{"t": 1}, 1)
	if err := Stream(path, m, known, func(Group) error { return nil }); err != nil {
		t.Fatalf("baseline archive: %v", err)
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path, m := craft(t, tc.lines, map[string]int64{"t": 1}, 1)
			err := Stream(path, m, known, func(Group) error { return nil })
			if !errors.Is(err, ErrInvalid) || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want ErrInvalid containing %q", err, tc.want)
			}
		})
	}
}

func TestStreamChecksManifestAgainstContent(t *testing.T) {
	lines := []string{hdr, req, `{"kind":"row","request_id":"g","table":"t","row":{"a":1}}`,
		`{"kind":"trailer","request_count":1,"row_counts":{"t":1}}`}
	path, good := craft(t, lines, map[string]int64{"t": 1}, 1)
	if err := Stream(path, good, known, func(Group) error { return nil }); err != nil {
		t.Fatalf("good archive: %v", err)
	}
	mut := map[string]func(m *Manifest){
		"no format": func(m *Manifest) { m.Format = "" },
		"size":      func(m *Manifest) { m.SizeBytes++ },
		"sha":       func(m *Manifest) { m.SHA256 = strings.Repeat("0", 64) },
		"requests":  func(m *Manifest) { m.RequestCount = 2 },
		"rows":      func(m *Manifest) { m.RowCounts = map[string]int64{"t": 2} },
	}
	for name, f := range mut {
		m := good
		f(&m)
		if err := Stream(path, m, known, func(Group) error { return nil }); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: err = %v, want ErrInvalid", name, err)
		}
	}
	// Trailer disagreeing with the manifest is also rejected.
	lines[3] = `{"kind":"trailer","request_count":1,"row_counts":{"t":5}}`
	path, m := craft(t, lines, map[string]int64{"t": 1}, 1)
	if err := Stream(path, m, known, func(Group) error { return nil }); !errors.Is(err, ErrInvalid) {
		t.Fatalf("trailer rows err = %v", err)
	}
	if err := Stream(filepath.Join(t.TempDir(), "missing"), good, known, nil); !errors.Is(err, ErrInvalid) {
		t.Fatalf("missing file err = %v", err)
	}
	notgz := filepath.Join(t.TempDir(), "x")
	_ = os.WriteFile(notgz, []byte("plain"), 0o600)
	if err := Stream(notgz, good, known, nil); !errors.Is(err, ErrInvalid) {
		t.Fatalf("non-gzip err = %v", err)
	}
}

func TestStreamPropagatesVisitorError(t *testing.T) {
	lines := []string{hdr, req, `{"kind":"request","request_id":"h"}`,
		`{"kind":"trailer","request_count":2}`}
	path, m := craft(t, lines, nil, 2)
	boom := errors.New("boom")
	calls := 0
	err := Stream(path, m, known, func(g Group) error { calls++; return boom })
	if !errors.Is(err, boom) || calls != 1 {
		t.Fatalf("err = %v calls = %d", err, calls)
	}
}

func TestStreamDecodesNumbersAndBlobs(t *testing.T) {
	lines := []string{hdr, req,
		`{"kind":"row","request_id":"g","table":"t","row":{"i":9007199254740993,"f":1.25,"s":"x","n":null,"b":{"blob_base64":"AAE="}}}`,
		`{"kind":"trailer","request_count":1,"row_counts":{"t":1}}`}
	path, m := craft(t, lines, map[string]int64{"t": 1}, 1)
	var got Row
	if err := Stream(path, m, known, func(g Group) error { got = g.Rows["t"][0]; return nil }); err != nil {
		t.Fatal(err)
	}
	want := Row{"i": int64(9007199254740993), "f": 1.25, "s": "x", "n": nil, "b": Blob{Base64: "AAE="}}
	if !RowsEqual(got, want) {
		t.Fatalf("got %#v", got)
	}
}

func TestNewWriterValidatesDirAndAbortRemovesPartial(t *testing.T) {
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, d := range []string{"", "  ", "relative/dir"} {
		if _, err := NewWriter(d, "p", "f", now, "c"); err == nil {
			t.Errorf("dir %q accepted", d)
		}
	}
	dir := filepath.Join(t.TempDir(), "sub")
	w, err := NewWriter(dir, "pre", "f", now, "c")
	if err != nil {
		t.Fatal(err)
	}
	if err := w.WriteGroup("g", nil, []TableRows{{Table: "t", Rows: []Row{{"a": int64(1)}}}}); err != nil {
		t.Fatal(err)
	}
	if w.Groups() != 1 {
		t.Fatalf("groups = %d", w.Groups())
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 1 || !strings.HasPrefix(files[0].Name(), "pre-20260102T030405Z-") || !strings.HasSuffix(files[0].Name(), Suffix+".partial") {
		t.Fatalf("files = %v", files)
	}
	w.Abort()
	if files, _ = os.ReadDir(dir); len(files) != 0 {
		t.Fatalf("partial left: %v", files)
	}
	(*Writer)(nil).Abort()
}

func TestSpaceGuardStopsWriterWithinStep(t *testing.T) {
	dir := t.TempDir()
	w, err := NewWriter(dir, "g", "f", time.Now(), "c")
	if err != nil {
		t.Fatal(err)
	}
	stop := errors.New("disk full")
	calls := 0
	w.SetSpaceGuard(16, func() error {
		calls++
		if calls > 1 {
			return stop
		}
		return nil
	})
	// Incompressible-ish rows so the gzip output exceeds the guard step.
	var rows []Row
	for i := 0; i < 2000; i++ {
		rows = append(rows, Row{"v": strings.Repeat(string(rune('a'+i%26)), 5) + hex.EncodeToString([]byte{byte(i), byte(i >> 8), byte(i * 7)})})
	}
	if err := w.WriteGroup("g", nil, []TableRows{{Table: "t", Rows: rows}}); err != nil {
		t.Fatalf("buffered write should not reach guard yet: %v", err)
	}
	if _, _, err := w.Finish(); !errors.Is(err, stop) {
		t.Fatalf("Finish err = %v, want guard error", err)
	}
	if files, _ := os.ReadDir(dir); len(files) != 0 {
		t.Fatalf("failed Finish left files: %v", files)
	}
}

func TestCountingWriterGuardSplitsAndShortWrite(t *testing.T) {
	var sink bytes.Buffer
	var chunks []int
	c := &countingWriter{w: &recW{&sink, &chunks}, guardStep: 4, guard: func() error { return nil }}
	if n, err := c.Write([]byte("0123456789")); n != 10 || err != nil || c.n != 10 {
		t.Fatalf("n=%d err=%v c.n=%d", n, err, c.n)
	}
	if len(chunks) != 3 || chunks[0] != 4 || chunks[1] != 4 || chunks[2] != 2 || sink.String() != "0123456789" {
		t.Fatalf("chunks = %v", chunks)
	}
	short := &countingWriter{w: shortW{}}
	if _, err := short.Write([]byte("abc")); err != errShort {
		t.Fatalf("err = %v", err)
	}
}

type recW struct {
	b *bytes.Buffer
	c *[]int
}

func (r *recW) Write(p []byte) (int, error) { *r.c = append(*r.c, len(p)); return r.b.Write(p) }

var errShort = errors.New("short")

type shortW struct{}

func (shortW) Write(p []byte) (int, error) { return 1, errShort }

func TestManifestReadErrorsAndFsyncDir(t *testing.T) {
	dir := t.TempDir()
	if _, err := ReadManifest(filepath.Join(dir, "none")); err == nil {
		t.Fatal("missing manifest accepted")
	}
	p := filepath.Join(dir, "a")
	if err := os.WriteFile(p+ManifestSuffix, []byte("{bad"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadManifest(p); err == nil {
		t.Fatal("corrupt manifest accepted")
	}
	want := Manifest{Format: "f", SHA256: "ab", RequestCount: 3, RowCounts: map[string]int64{"t": 4}}
	if err := WriteManifest(p, want); err != nil {
		t.Fatal(err)
	}
	got, err := ReadManifest(p)
	if err != nil || got.Format != "f" || got.RequestCount != 3 || got.RowCounts["t"] != 4 {
		t.Fatalf("got %+v %v", got, err)
	}
	if _, err := os.Stat(p + ManifestSuffix + ".partial"); !os.IsNotExist(err) {
		t.Fatal("partial manifest left behind")
	}
	if err := WriteManifest(filepath.Join(dir, "nodir", "a"), want); err == nil {
		t.Fatal("write into missing dir succeeded")
	}
	if err := FsyncDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := FsyncDir(filepath.Join(dir, "nodir")); err == nil {
		t.Fatal("fsync of missing dir succeeded")
	}
}

func TestNormalizeValue(t *testing.T) {
	ts := time.Date(2026, 1, 2, 3, 4, 5, 6, time.FixedZone("x", 3600))
	cases := []struct{ in, want any }{
		{nil, nil}, {int64(5), int64(5)}, {2.5, 2.5}, {"s", "s"},
		{[]byte{0, 1}, Blob{Base64: "AAE="}},
		{true, int64(1)}, {false, int64(0)}, {int(7), int64(7)},
		{ts, "2026-01-02T02:04:05.000000006Z"},
		{struct{ A int }{3}, "{3}"},
	}
	for _, c := range cases {
		if got := NormalizeValue(c.in); got != c.want {
			t.Errorf("NormalizeValue(%#v) = %#v want %#v", c.in, got, c.want)
		}
	}
}

func TestValuesAndRowsEqual(t *testing.T) {
	eq := []struct{ a, b any }{
		{nil, nil}, {"a", "a"}, {Blob{"x"}, Blob{"x"}}, {int64(2), float64(2)}, {float64(2), int64(2)},
		{int64(3), int64(3)}, {1.5, 1.5},
	}
	for _, c := range eq {
		if !ValuesEqual(c.a, c.b) {
			t.Errorf("%#v != %#v", c.a, c.b)
		}
	}
	ne := []struct{ a, b any }{
		{nil, "a"}, {"a", "b"}, {"a", int64(1)}, {Blob{"x"}, Blob{"y"}}, {Blob{"x"}, "x"},
		{int64(2), float64(2.5)}, {float64(2.5), int64(2)}, {int64(2), int64(3)}, {1.5, 2.5},
		{int64(1), "1"}, {1.5, "x"}, {true, true},
	}
	for _, c := range ne {
		if ValuesEqual(c.a, c.b) {
			t.Errorf("%#v == %#v", c.a, c.b)
		}
	}
	if RowsEqual(Row{"a": int64(1)}, Row{"a": int64(1), "b": nil}) ||
		RowsEqual(Row{"a": int64(1)}, Row{"b": int64(1)}) ||
		RowsEqual(Row{"a": int64(1)}, Row{"a": int64(2)}) ||
		!RowsEqual(Row{"a": int64(1)}, Row{"a": float64(1)}) {
		t.Fatal("RowsEqual wrong")
	}
}

func TestEqualRowCountsIgnoresZeroEntries(t *testing.T) {
	if !equalRowCounts(map[string]int64{"a": 0, "b": 2}, map[string]int64{"b": 2}) ||
		!equalRowCounts(nil, map[string]int64{}) ||
		equalRowCounts(map[string]int64{"a": 1}, map[string]int64{"a": 2}) ||
		equalRowCounts(map[string]int64{"a": 1}, map[string]int64{"b": 1}) {
		t.Fatal("equalRowCounts wrong")
	}
}

func TestFilesystemSpaceAndClamp(t *testing.T) {
	if _, _, err := FilesystemSpace("rel"); err == nil {
		t.Fatal("relative dir accepted")
	}
	dir := filepath.Join(t.TempDir(), "new")
	free, total, err := FilesystemSpace(dir)
	if err != nil || total <= 0 || free < 0 || free > total {
		t.Fatalf("free=%d total=%d err=%v", free, total, err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("dir not created: %v", err)
	}
	if clampInt64(5) != 5 || clampInt64(^uint64(0)) != 1<<62 {
		t.Fatal("clampInt64 wrong")
	}
}
