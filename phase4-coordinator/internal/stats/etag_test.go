package stats

import "testing"

func TestWeakETagFormat(t *testing.T) {
	got := weakETag([]byte(`{"hello":"world"}`))
	if got == "" {
		t.Fatal("etag is empty")
	}
	if len(got) < 4 || got[:2] != `W/` {
		t.Errorf("etag missing W/ prefix: %q", got)
	}
	if got[2] != '"' || got[len(got)-1] != '"' {
		t.Errorf("etag missing quotes: %q", got)
	}
	// Deterministic.
	got2 := weakETag([]byte(`{"hello":"world"}`))
	if got != got2 {
		t.Errorf("etag not deterministic: %q vs %q", got, got2)
	}
}

func TestIfNoneMatchEquals(t *testing.T) {
	etag := weakETag([]byte(`X`))
	if !ifNoneMatchEquals(etag, etag) {
		t.Errorf("identity should match")
	}
	// Weak comparison ignores the W/ prefix per RFC 7232.
	if !ifNoneMatchEquals(`"`+etag[3:len(etag)-1]+`"`, etag) {
		t.Errorf("weak comparison should strip W/ prefix")
	}
	if ifNoneMatchEquals("", etag) {
		t.Errorf("empty If-None-Match should not match")
	}
	if ifNoneMatchEquals(etag, "") {
		t.Errorf("empty etag should not match")
	}
}
