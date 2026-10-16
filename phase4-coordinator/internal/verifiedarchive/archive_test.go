package verifiedarchive

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func known(table string) bool { return table == "t" }

func TestWriterRoundTripVerifiesAndDetectsTampering(t *testing.T) {
	dir := t.TempDir()
	w, err := NewWriter(dir, "test", "test-format-v1", time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), "2026-10-01")
	if err != nil {
		t.Fatal(err)
	}
	rows := []Row{
		{"id": int64(1), "s": "a", "n": nil, "f": 1.5, "b": Blob{Base64: "AAE="}},
		{"id": int64(2), "s": "b", "n": nil, "f": float64(2), "b": Blob{Base64: "AAI="}},
	}
	if err := w.WriteGroup("g1", []int64{7}, []TableRows{{Table: "t", Role: "r", Rows: rows}}); err != nil {
		t.Fatal(err)
	}
	manifest, path, err := w.Finish()
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != dir || manifest.RequestCount != 1 || manifest.RowCounts["t"] != 2 {
		t.Fatalf("manifest = %+v path = %s", manifest, path)
	}
	read, err := ReadManifest(path)
	if err != nil || read.SHA256 != manifest.SHA256 {
		t.Fatalf("read manifest = %+v %v", read, err)
	}
	verified, err := Verify(path, manifest, known)
	if err != nil {
		t.Fatal(err)
	}
	var got []Row
	if err := Stream(path, manifest, known, func(g Group) error {
		if verified.Digests[g.ID] != g.Digest || len(g.CreditIDs) != 1 || g.CreditIDs[0] != 7 {
			t.Fatalf("group %+v", g)
		}
		got = append(got, g.Rows["t"]...)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for i := range rows {
		if !RowsEqual(got[i], rows[i]) {
			t.Fatalf("row %d = %#v want %#v", i, got[i], rows[i])
		}
	}
	// Unknown tables, a wrong format, and changed bytes all fail closed.
	if _, err := Verify(path, manifest, func(string) bool { return false }); !errors.Is(err, ErrInvalid) {
		t.Fatalf("unknown table err = %v", err)
	}
	bad := manifest
	bad.Format = "other"
	if _, err := Verify(path, bad, known); !errors.Is(err, ErrInvalid) {
		t.Fatalf("format err = %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-3] ^= 0x01
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Verify(path, manifest, known); !errors.Is(err, ErrInvalid) {
		t.Fatalf("tampered err = %v", err)
	}
}

func TestBelowFloor(t *testing.T) {
	if BelowFloor(10, 100, 20, 0) == "" || BelowFloor(5, 100, 0, 10) == "" {
		t.Fatal("floor not enforced")
	}
	if BelowFloor(50, 100, 20, 10) != "" {
		t.Fatal("floor refused room")
	}
}
