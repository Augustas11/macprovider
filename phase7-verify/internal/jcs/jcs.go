// Package jcs is a Go hand-port of
// phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift.
//
// The implementation intentionally mirrors the Swift source of truth: object
// keys are sorted by UTF-16 code units, string values are normalized to NFC
// before escaping, raw strings and object keys are not normalized, and finite
// doubles are rendered with ECMAScript Number.toString thresholds. The double
// formatter uses Go's shortest round-tripping decimal as the digit source, then
// applies the ECMAScript fixed/scientific rendering rules from ECMA-262:
// fixed for exponents in [-6, 20], scientific otherwise, signed exponent, and
// no leading zeroes in the exponent.
package jcs

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"

	"golang.org/x/text/unicode/norm"
)

type Value struct {
	Kind      Kind
	Object    map[string]Value
	Array     []Value
	String    string
	RawString string
	Int       int64
	Double    float64
	Bool      bool
}

type Kind int

const (
	KindObject Kind = iota
	KindArray
	KindString
	KindRawString
	KindInt
	KindDouble
	KindBool
	KindNull
)

var (
	ErrMissingObjectMember = errors.New("jcs: missing object member")
	ErrNonFiniteDouble     = errors.New("jcs: non-finite double")
)

func Canonicalize(v Value) ([]byte, error) {
	var b bytes.Buffer
	if err := writeCanonical(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func SHA256Hex(v Value) (string, error) {
	canonical, err := Canonicalize(v)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}

func CanonicalizeJSON(raw []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()

	var input any
	if err := decoder.Decode(&input); err != nil {
		return nil, err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, errors.New("jcs: trailing JSON data")
		}
		return nil, err
	}

	value, err := valueFromJSON(input)
	if err != nil {
		return nil, err
	}
	return Canonicalize(value)
}

func writeCanonical(b *bytes.Buffer, v Value) error {
	switch v.Kind {
	case KindObject:
		keys := make([]string, 0, len(v.Object))
		for key := range v.Object {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			return utf16LexicographicLess(keys[i], keys[j])
		})

		b.WriteByte('{')
		for i, key := range keys {
			member, ok := v.Object[key]
			if !ok {
				return fmt.Errorf("%w: %s", ErrMissingObjectMember, key)
			}
			if i > 0 {
				b.WriteByte(',')
			}
			writeEscapedString(b, key, false)
			b.WriteByte(':')
			if err := writeCanonical(b, member); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	case KindArray:
		b.WriteByte('[')
		for i, item := range v.Array {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeCanonical(b, item); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case KindString:
		writeEscapedString(b, v.String, true)
	case KindRawString:
		writeEscapedString(b, v.RawString, false)
	case KindInt:
		b.WriteString(strconv.FormatInt(v.Int, 10))
	case KindDouble:
		formatted, err := canonicalDouble(v.Double)
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case KindBool:
		if v.Bool {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case KindNull:
		b.WriteString("null")
	default:
		return fmt.Errorf("jcs: unknown kind %d", v.Kind)
	}
	return nil
}

func utf16LexicographicLess(lhs, rhs string) bool {
	l := utf16.Encode([]rune(lhs))
	r := utf16.Encode([]rune(rhs))
	for i := 0; i < len(l) && i < len(r); i++ {
		if l[i] != r[i] {
			return l[i] < r[i]
		}
	}
	return len(l) < len(r)
}

func writeEscapedString(b *bytes.Buffer, s string, normalizeNFC bool) {
	if normalizeNFC {
		s = norm.NFC.String(s)
	}

	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r >= 0x00 && r <= 0x1f {
				b.WriteString(`\u00`)
				b.WriteByte("0123456789abcdef"[r>>4])
				b.WriteByte("0123456789abcdef"[r&0x0f])
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

func canonicalDouble(f float64) (string, error) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "", ErrNonFiniteDouble
	}
	if f == 0 {
		return "0", nil
	}

	sign := ""
	if f < 0 {
		sign = "-"
		f = -f
	}

	digits, e, err := decimalDigitsAndExponent(strconv.FormatFloat(f, 'g', -1, 64))
	if err != nil {
		return "", err
	}

	return sign + renderECMAScriptNumber(digits, e), nil
}

func decimalDigitsAndExponent(s string) (string, int, error) {
	if split := strings.IndexAny(s, "eE"); split >= 0 {
		mantissa := s[:split]
		exp, err := strconv.Atoi(s[split+1:])
		if err != nil {
			return "", 0, fmt.Errorf("jcs: parse float exponent %q: %w", s, err)
		}
		point := strings.IndexByte(mantissa, '.')
		integerDigits := len(mantissa)
		if point >= 0 {
			integerDigits = point
			mantissa = mantissa[:point] + mantissa[point+1:]
		}
		digits := strings.TrimLeft(mantissa, "0")
		if digits == "" {
			return "0", 1, nil
		}
		return digits, exp + integerDigits, nil
	}

	point := strings.IndexByte(s, '.')
	if point < 0 {
		point = len(s)
	} else {
		s = s[:point] + s[point+1:]
	}

	leadingZeroes := len(s) - len(strings.TrimLeft(s, "0"))
	digits := strings.TrimLeft(s, "0")
	if digits == "" {
		return "0", 1, nil
	}
	return digits, point - leadingZeroes, nil
}

func renderECMAScriptNumber(digits string, e int) string {
	k := len(digits)
	switch {
	case k <= e && e <= 21:
		return digits + strings.Repeat("0", e-k)
	case 0 < e && e <= 21:
		return digits[:e] + "." + digits[e:]
	case -6 < e && e <= 0:
		return "0." + strings.Repeat("0", -e) + digits
	default:
		exponent := e - 1
		mantissa := digits[:1]
		if k > 1 {
			mantissa += "." + digits[1:]
		}
		if exponent >= 0 {
			return mantissa + "e+" + strconv.Itoa(exponent)
		}
		return mantissa + "e-" + strconv.Itoa(-exponent)
	}
}

func valueFromJSON(input any) (Value, error) {
	switch x := input.(type) {
	case map[string]any:
		object := make(map[string]Value, len(x))
		for key, member := range x {
			value, err := valueFromJSON(member)
			if err != nil {
				return Value{}, err
			}
			object[key] = value
		}
		return Value{Kind: KindObject, Object: object}, nil
	case []any:
		array := make([]Value, 0, len(x))
		for _, item := range x {
			value, err := valueFromJSON(item)
			if err != nil {
				return Value{}, err
			}
			array = append(array, value)
		}
		return Value{Kind: KindArray, Array: array}, nil
	case string:
		return Value{Kind: KindString, String: x}, nil
	case json.Number:
		if !strings.ContainsAny(x.String(), ".eE") {
			if i, err := x.Int64(); err == nil {
				return Value{Kind: KindInt, Int: i}, nil
			}
		}
		f, err := x.Float64()
		if err != nil {
			return Value{}, fmt.Errorf("jcs: parse JSON number %q: %w", x.String(), err)
		}
		return Value{Kind: KindDouble, Double: f}, nil
	case bool:
		return Value{Kind: KindBool, Bool: x}, nil
	case nil:
		return Value{Kind: KindNull}, nil
	default:
		return Value{}, fmt.Errorf("jcs: unsupported JSON value %T", input)
	}
}
