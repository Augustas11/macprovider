package sourceevidence

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCanonicalBytesSortsKeysAndNormalizesTypes(t *testing.T) {
	in := map[string]any{
		"b": []any{int64(2), json.Number("3"), true, nil},
		"a": "x\"y",
		"c": map[string]any{"z": 1, "y": false},
		"d": []any{int64(1234567890), json.Number("9007199254740991"), 10, 255},
	}
	got, err := canonicalBytes(in)
	if err != nil {
		t.Fatalf("canonicalBytes: %v", err)
	}
	want := `{"a":"x\"y","b":[2,3,true,null],"c":{"y":false,"z":1},"d":[1234567890,9007199254740991,10,255]}`
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
