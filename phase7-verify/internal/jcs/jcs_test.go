package jcs

import (
	"errors"
	"math"
	"strings"
	"testing"
)

func canonicalString(t *testing.T, value Value) string {
	t.Helper()
	canonical, err := Canonicalize(value)
	if err != nil {
		t.Fatalf("Canonicalize() error = %v", err)
	}
	return string(canonical)
}

func TestSwiftRFC8785JCSTestCases(t *testing.T) {
	t.Run("testStringValuesAreNormalizedToNFCBeforeEscaping", func(t *testing.T) {
		decomposed := "Cafe\u0301"
		precomposed := "Caf\u00e9"

		if got := canonicalString(t, Value{Kind: KindString, String: decomposed}); got != `"`+precomposed+`"` {
			t.Fatalf("canonical decomposed = %q", got)
		}
		if got, want := canonicalString(t, Value{Kind: KindString, String: decomposed}), canonicalString(t, Value{Kind: KindString, String: precomposed}); got != want {
			t.Fatalf("decomposed canonical = %q, precomposed canonical = %q", got, want)
		}
	})

	t.Run("testASCIIStringNormalizationIsNoOp", func(t *testing.T) {
		if got := canonicalString(t, Value{Kind: KindString, String: "plain ASCII"}); got != `"plain ASCII"` {
			t.Fatalf("canonical ASCII = %q", got)
		}
	})

	t.Run("testDoubleFormattingMatchesRFC8785ECMAScriptRules", func(t *testing.T) {
		cases := []struct {
			name string
			in   float64
			want string
		}{
			{"zero", 0.0, "0"},
			{"negativeZero", -0.0, "0"},
			{"one", 1.0, "1"},
			{"onePointOne", 1.1, "1.1"},
			{"oneEMinusSeven", 1e-7, "1e-7"},
			{"oneEMinusSix", 1e-6, "0.000001"},
			{"oneETwenty", 1e20, "100000000000000000000"},
			{"oneETwentyOne", 1e21, "1e+21"},
			{"rounding", 333333333.33333329, "333333333.3333333"},
			{"fourPointFive", 4.5, "4.5"},
			{"twoEMinusThree", 2e-3, "0.002"},
			{"oneEMinusTwentySeven", 1e-27, "1e-27"},
			{"largePrecise", 1.2345678901234568e30, "1.2345678901234568e+30"},
		}

		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				if got := canonicalString(t, Value{Kind: KindDouble, Double: tc.in}); got != tc.want {
					t.Fatalf("canonical double = %q, want %q", got, tc.want)
				}
			})
		}
	})

	t.Run("testNonFiniteDoublesAreRejected", func(t *testing.T) {
		for _, value := range []Value{
			{Kind: KindDouble, Double: math.NaN()},
			{Kind: KindDouble, Double: math.Inf(1)},
			{Kind: KindDouble, Double: math.Inf(-1)},
		} {
			_, err := Canonicalize(value)
			if !errors.Is(err, ErrNonFiniteDouble) {
				t.Fatalf("Canonicalize(%v) error = %v, want ErrNonFiniteDouble", value.Double, err)
			}
		}
	})

	t.Run("testExistingIntegerBooleanNullArrayAndObjectBehaviorIsUnchanged", func(t *testing.T) {
		value := Value{Kind: KindObject, Object: map[string]Value{
			"z": {Kind: KindArray, Array: []Value{
				{Kind: KindInt, Int: 1},
				{Kind: KindBool, Bool: false},
				{Kind: KindNull},
			}},
			"a": {Kind: KindString, String: "line\nquote\"slash\\"},
			"m": {Kind: KindObject, Object: map[string]Value{
				"b": {Kind: KindInt, Int: 2},
				"a": {Kind: KindBool, Bool: true},
			}},
		}}

		want := `{"a":"line\nquote\"slash\\","m":{"a":true,"b":2},"z":[1,false,null]}`
		if got := canonicalString(t, value); got != want {
			t.Fatalf("canonical object = %q, want %q", got, want)
		}
	})

	t.Run("testReplacementCharacterIsEmittedAsRawUTF8PerRFC8785", func(t *testing.T) {
		if got := canonicalString(t, Value{Kind: KindString, String: "hi\uFFFD"}); got != "\"hi\uFFFD\"" {
			t.Fatalf("canonical replacement string = %q", got)
		}
		if got := canonicalString(t, Value{Kind: KindRawString, RawString: "k\uFFFD"}); got != "\"k\uFFFD\"" {
			t.Fatalf("canonical replacement raw string = %q", got)
		}
	})

	t.Run("testControlCharactersBeyondU001FAreEmittedAsRawUTF8", func(t *testing.T) {
		if got := canonicalString(t, Value{Kind: KindString, String: "x\u007Fy"}); got != "\"x\u007Fy\"" {
			t.Fatalf("canonical DEL string = %q", got)
		}
		if got := canonicalString(t, Value{Kind: KindString, String: "x\u0080y"}); got != "\"x\u0080y\"" {
			t.Fatalf("canonical U+0080 string = %q", got)
		}
	})

	t.Run("testAdditionalRFC8785ECMAScriptDoubleVectors", func(t *testing.T) {
		cases := []struct {
			name string
			in   float64
			want string
		}{
			{"negativeOnePointOne", -1.1, "-1.1"},
			{"oneEMinusSix", 0.000001, "0.000001"},
			{"largeRounding", 9.999999999999997e22, "9.999999999999997e+22"},
			{"maxFloat", 1.7976931348623157e308, "1.7976931348623157e+308"},
			{"smallestSubnormal", 5e-324, "5e-324"},
			{"negativePointOne", -0.1, "-0.1"},
			{"hundred", 100.0, "100"},
			{"half", 0.5, "0.5"},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				if got := canonicalString(t, Value{Kind: KindDouble, Double: tc.in}); got != tc.want {
					t.Fatalf("canonical double = %q, want %q", got, tc.want)
				}
			})
		}
	})

	t.Run("testTupleTierASCIIFieldsHashUnchangedByNFCStep", func(t *testing.T) {
		value := Value{Kind: KindObject, Object: map[string]Value{
			"model_id":        {Kind: KindString, String: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"},
			"output_hash":     {Kind: KindString, String: strings.Repeat("b", 64)},
			"prompt_hash":     {Kind: KindString, String: strings.Repeat("a", 64)},
			"provider_pubkey": {Kind: KindString, String: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},
			"tokens_out":      {Kind: KindInt, Int: 42},
			"ttft_ms":         {Kind: KindInt, Int: 1234},
			"unix_ts":         {Kind: KindInt, Int: 1771234567},
		}}

		want := `{"model_id":"mlx-community/Qwen2.5-Coder-7B-Instruct-4bit","output_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","prompt_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tokens_out":42,"ttft_ms":1234,"unix_ts":1771234567}`
		if got := canonicalString(t, value); got != want {
			t.Fatalf("canonical tuple = %q, want %q", got, want)
		}
	})
}

func TestRawStringDoesNotNormalizeNFC(t *testing.T) {
	raw := "Cafe\u0301"
	if got := canonicalString(t, Value{Kind: KindRawString, RawString: raw}); got != `"`+raw+`"` {
		t.Fatalf("canonical raw string = %q", got)
	}
}

func TestUTF16LexicographicObjectKeyOrdering(t *testing.T) {
	value := Value{Kind: KindObject, Object: map[string]Value{
		"\uE000":     {Kind: KindString, String: "bmp-private-use"},
		"\U00010000": {Kind: KindString, String: "supplementary"},
		"a":          {Kind: KindString, String: "ascii"},
	}}

	want := "{\"a\":\"ascii\",\"\U00010000\":\"supplementary\",\"\uE000\":\"bmp-private-use\"}"
	if got := canonicalString(t, value); got != want {
		t.Fatalf("canonical UTF-16 keys = %q, want %q", got, want)
	}
}

func TestSHA256Hex(t *testing.T) {
	got, err := SHA256Hex(Value{Kind: KindString, String: "abc"})
	if err != nil {
		t.Fatalf("SHA256Hex() error = %v", err)
	}
	const want = "6cc43f858fbb763301637b5af970e2a46b46f461f27e5a0f41e009c59b827b25"
	if got != want {
		t.Fatalf("SHA256Hex() = %q, want %q", got, want)
	}
}
