package billing

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"

	"golang.org/x/text/unicode/norm"
)

type RawJSONString string

func CanonicalJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeJCS(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func CanonicalSHA256Hex(v any) (string, []byte, error) {
	canonical, err := CanonicalJSON(v)
	if err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), canonical, nil
}

func writeJCS(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case string:
		b.WriteString(escapeJCSString(norm.NFC.String(x)))
	case RawJSONString:
		b.WriteString(escapeJCSString(string(x)))
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case json.Number:
		formatted, err := canonicalJSONNumber(x.String())
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case float64:
		formatted, err := canonicalDouble(x)
		if err != nil {
			return err
		}
		b.WriteString(formatted)
	case []any:
		b.WriteByte('[')
		for i, item := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeJCS(b, item); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for key := range x {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			return utf16Less(keys[i], keys[j])
		})
		b.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(escapeJCSString(key))
			b.WriteByte(':')
			if err := writeJCS(b, x[key]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		return fmt.Errorf("unsupported JCS value %T", v)
	}
	return nil
}

var integerNumberPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]*)$`)

func canonicalJSONNumber(raw string) (string, error) {
	if integerNumberPattern.MatchString(raw) {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err == nil {
			return strconv.FormatInt(n, 10), nil
		}
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("invalid JSON number %q", raw)
	}
	if f == math.Trunc(f) && f >= math.MinInt64 && f <= math.MaxInt64 {
		return strconv.FormatInt(int64(f), 10), nil
	}
	return canonicalDouble(f)
}

func canonicalDouble(f float64) (string, error) {
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return "", fmt.Errorf("non-finite number")
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
			return "", 0, fmt.Errorf("parse float exponent %q: %w", s, err)
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

func utf16Less(a, b string) bool {
	aa := utf16.Encode([]rune(a))
	bb := utf16.Encode([]rune(b))
	for i := 0; i < len(aa) && i < len(bb); i++ {
		if aa[i] != bb[i] {
			return aa[i] < bb[i]
		}
	}
	return len(aa) < len(bb)
}

func escapeJCSString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
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
			if r >= 0 && r <= 0x1f {
				b.WriteString(`\u00`)
				b.WriteString(hex.EncodeToString([]byte{byte(r)}))
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
