package main

import (
	"bytes"
	"testing"
)

func TestCBORRoundTripScalars(t *testing.T) {
	values := []Value{
		uintValue(0),
		uintValue(23),
		uintValue(24),
		uintValue(255),
		uintValue(256),
		uintValue(65535),
		uintValue(65536),
		uintValue(1 << 32),
		negValue(-1),
		negValue(-7),
		negValue(-24),
		negValue(-25),
		negValue(-256),
		bytesValue(nil),
		bytesValue([]byte{0x00, 0xff}),
		textValue(""),
		textValue("apple-appattest"),
		{Kind: KindBool, Bool: false},
		{Kind: KindBool, Bool: true},
		{Kind: KindNull},
		{Kind: KindArray, Array: []Value{uintValue(1), textValue("a")}},
		{Kind: KindMap, Pairs: []Pair{
			{Key: uintValue(1), Val: uintValue(2)},
			{Key: negValue(-1), Val: uintValue(1)},
			{Key: negValue(-2), Val: bytesValue([]byte{9, 8, 7})},
			{Key: textValue("fmt"), Val: textValue("apple-appattest")},
		}},
	}
	for _, value := range values {
		encoded, err := Encode(value)
		if err != nil {
			t.Fatalf("encode %#v: %v", value, err)
		}
		decoded, err := Decode(encoded)
		if err != nil {
			t.Fatalf("decode %x: %v", encoded, err)
		}
		again, err := Encode(decoded)
		if err != nil {
			t.Fatalf("re-encode: %v", err)
		}
		if !bytes.Equal(encoded, again) {
			t.Fatalf("round trip changed bytes: %x vs %x", encoded, again)
		}
	}
}

func TestCBORRejectsIndefiniteReservedTagAndFloat(t *testing.T) {
	cases := [][]byte{
		{0x5f},
		{0x7f},
		{0x9f},
		{0xbf},
		{0x1c},
		{0x1d},
		{0x1e},
		{0xc0},
		{0xf9, 0x00, 0x00},
		{0xfa, 0x00, 0x00, 0x00, 0x00},
		{0x41},
		{0x01, 0x02},
	}
	for _, input := range cases {
		if _, err := Decode(input); err == nil {
			t.Fatalf("accepted %x", input)
		}
	}
}

func TestCBORRejectsDuplicateKeysAndDepth(t *testing.T) {
	dup := []byte{0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02}
	if _, err := Decode(dup); err == nil {
		t.Fatal("duplicate key accepted")
	}
	nested := bytes.Repeat([]byte{0x81}, maxCBORDepth+1)
	nested = append(nested, 0x01)
	if _, err := Decode(nested); err == nil {
		t.Fatal("over-deep array accepted")
	}
	ok := bytes.Repeat([]byte{0x81}, maxCBORDepth)
	ok = append(ok, 0x01)
	if _, err := Decode(ok); err != nil {
		t.Fatalf("depth limit is too strict: %v", err)
	}
}

func TestCBORPrefixLeavesTheTail(t *testing.T) {
	value, n, err := DecodePrefix([]byte{0x01, 0x02})
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 || value.Kind != KindUint || value.Uint != 1 {
		t.Fatalf("prefix decode = %#v n=%d", value, n)
	}
}

func TestCBORMapLookup(t *testing.T) {
	value, err := Decode(mustEncode(t, Value{Kind: KindMap, Pairs: []Pair{
		{Key: textValue("fmt"), Val: textValue("apple-appattest")},
		{Key: negValue(-7), Val: uintValue(3)},
	}}))
	if err != nil {
		t.Fatal(err)
	}
	got, ok := value.TextKey("fmt")
	if !ok || got.Text != "apple-appattest" {
		t.Fatalf("text lookup %#v", got)
	}
	got, ok = value.IntKey(-7)
	if !ok || got.Uint != 3 {
		t.Fatalf("int lookup %#v", got)
	}
	if _, err := Decode([]byte{0xf7}); err == nil {
		t.Fatal("undefined simple value accepted")
	}
}

func mustEncode(t *testing.T, value Value) []byte {
	t.Helper()
	encoded, err := Encode(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestCBORRejectsEmptyInput(t *testing.T) {
	if _, err := Decode(nil); err == nil {
		t.Fatal("nil input accepted")
	}
}
