package jcs

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"strings"
	"testing"
)

func TestCanonicalJSONScalarsAndOrdering(t *testing.T) {
	// Keys sort by UTF-16 code units: U+10000 (surrogate 0xD800) sorts before U+FFFD.
	v := map[string]any{
		"�":          int(1),
		"\U00010000": int64(2),
		"b":          []any{nil, true, false, "x"},
		"a":          map[string]any{},
		"":           "e",
	}
	got, err := CanonicalJSON(v)
	if err != nil {
		t.Fatal(err)
	}
	want := "{\"\":\"e\",\"a\":{},\"b\":[null,true,false,\"x\"],\"\U00010000\":2,\"�\":1}"
	if string(got) != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestCanonicalJSONStringEscapingAndNormalization(t *testing.T) {
	in := "\"\\\b\t\n\f\r\x01\x1f/é"
	got, err := CanonicalJSON(in)
	if err != nil {
		t.Fatal(err)
	}
	want := `"\"\\\b\t\n\f\r\u0001\u001f/é"`
	if string(got) != want {
		t.Fatalf("got %s want %s", got, want)
	}

	decomposed := "é" // NFC -> U+00E9
	nfc, _ := CanonicalJSON(decomposed)
	if string(nfc) != "\"é\"" {
		t.Fatalf("NFC not applied: %q", nfc)
	}
	raw, _ := CanonicalJSONRawStrings(decomposed)
	if string(raw) != "\""+decomposed+"\"" {
		t.Fatalf("raw mode must not normalize: %q", raw)
	}
	rs, _ := CanonicalJSON(RawJSONString(decomposed))
	if string(rs) != "\""+decomposed+"\"" {
		t.Fatalf("RawJSONString must not normalize: %q", rs)
	}
}

func TestCanonicalJSONUnsupportedAndNestedErrors(t *testing.T) {
	for _, v := range []any{
		struct{}{},
		float32(1),
		[]any{1, uint(2)},
		map[string]any{"k": []string{"x"}},
		math.NaN(),
		math.Inf(1),
		[]any{math.Inf(-1)},
		json.Number("abc"),
	} {
		if out, err := CanonicalJSON(v); err == nil {
			t.Fatalf("expected error for %#v, got %s", v, out)
		}
	}
}

func TestCanonicalDoubleECMAScriptFormatting(t *testing.T) {
	cases := map[float64]string{
		0:                          "0",
		math.Copysign(0, -1):       "0",
		1.5:                        "1.5",
		-1.5:                       "-1.5",
		100:                        "100",
		1e21:                       "1e+21",
		1e20:                       "100000000000000000000",
		123456789012345678901234.0: "1.2345678901234569e+23",
		0.000001:                   "0.000001",
		0.0000001:                  "1e-7",
		1.25e-7:                    "1.25e-7",
		0.1:                        "0.1",
		5e-324:                     "5e-324",
		1.7976931348623157e308:     "1.7976931348623157e+308",
	}
	for f, want := range cases {
		got, err := CanonicalJSON(f)
		if err != nil {
			t.Fatalf("%v: %v", f, err)
		}
		if string(got) != want {
			t.Errorf("%v: got %s want %s", f, got, want)
		}
	}
}

func TestCanonicalJSONNumber(t *testing.T) {
	cases := map[string]string{
		"0":                    "0",
		"-12":                  "-12",
		"9223372036854775807":  "9223372036854775807",
		"1.0":                  "1",
		"1e3":                  "1000",
		"-2.50":                "-2.5",
		"1E-7":                 "1e-7",
		"18446744073709551616": "18446744073709552000",
		"-0":                   "0",
		"1e400x":               "",
	}
	for in, want := range cases {
		got, err := CanonicalJSON(json.Number(in))
		if want == "" {
			if err == nil {
				t.Errorf("%q: expected error, got %s", in, got)
			}
			continue
		}
		if err != nil || string(got) != want {
			t.Errorf("%q: got %s err %v want %s", in, got, err, want)
		}
	}
	// Out-of-range float must be rejected as invalid, not rendered as infinity.
	if out, err := CanonicalJSON(json.Number("1e999")); err == nil || !strings.Contains(err.Error(), "invalid JSON number") {
		t.Fatalf("1e999: got %s err %v", out, err)
	}
}

func TestCanonicalSHA256HexMatchesCanonicalBytes(t *testing.T) {
	v := map[string]any{"b": int(2), "a": "x"}
	h, canon, err := CanonicalSHA256Hex(v)
	if err != nil {
		t.Fatal(err)
	}
	if string(canon) != `{"a":"x","b":2}` {
		t.Fatalf("canon %s", canon)
	}
	sum := sha256.Sum256([]byte(`{"a":"x","b":2}`))
	if h != hex.EncodeToString(sum[:]) {
		t.Fatalf("hash %s", h)
	}
	if h2, c2, err := CanonicalSHA256Hex(struct{}{}); err == nil || h2 != "" || c2 != nil {
		t.Fatalf("expected error with empty outputs, got %q %q %v", h2, c2, err)
	}
}

func TestUTF16LessAndDecimalDigitsHelpers(t *testing.T) {
	if !utf16Less("a", "ab") || utf16Less("ab", "a") || utf16Less("a", "a") {
		t.Fatal("prefix ordering wrong")
	}
	if !utf16Less("\U00010000", "�") {
		t.Fatal("surrogate must sort before U+FFFD")
	}
	for _, c := range []struct {
		in, digits string
		e          int
		bad        bool
	}{
		{"1.5e+10", "15", 11, false},
		{"0e+00", "0", 1, false},
		{"0.00123", "123", -2, false},
		{"0.0", "0", 1, false},
		{"12", "12", 2, false},
		{"1e+x", "", 0, true},
	} {
		d, e, err := decimalDigitsAndExponent(c.in)
		if c.bad {
			if err == nil {
				t.Errorf("%q: expected error", c.in)
			}
			continue
		}
		if err != nil || d != c.digits || e != c.e {
			t.Errorf("%q: got %q %d %v want %q %d", c.in, d, e, err, c.digits, c.e)
		}
	}
}
