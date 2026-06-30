package spec015contract

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"testing"
	"unicode/utf16"

	"golang.org/x/text/unicode/norm"
)

var (
	routeSnapshotKeys = []string{
		"account_scope",
		"attempt_n",
		"catalog_body_digest",
		"catalog_expires_at_unix_ms",
		"catalog_id",
		"catalog_signature_key_id",
		"catalog_signature_pubkey_fingerprint",
		"expected_catalog_model_hash",
		"model_id",
		"paid_entrypoint",
		"pending_deadline_seconds",
		"prompt_hash",
		"prompt_hash_basis",
		"provider_generation_id",
		"provider_id",
		"provider_receipt_key_id",
		"provider_receipt_key_source",
		"provider_reported_model_hash",
		"provider_session_id",
		"request_id",
		"request_start_ts_unix_ms",
		"route_decision_ts_unix_ms",
		"route_snapshot_mode",
		"route_snapshot_policy_version",
		"spec008_hash_status",
	}
	settlementOutputKeys = []string{
		"content",
		"finish_reason",
		"output_prefix_end_byte",
		"output_prefix_start_byte",
		"terminal_state",
		"tool_calls",
	}
	usageKeys = []string{
		"billable_input_tokens",
		"billable_output_tokens",
		"delivered_output_bytes",
		"observed_input_tokens",
		"observed_output_tokens",
	}
	receiptTupleKeys = []string{
		"account_scope",
		"attempt_n",
		"catalog_body_digest",
		"catalog_id",
		"expected_catalog_model_hash",
		"issued_at_unix_ms",
		"model_hash",
		"model_id",
		"output_hash",
		"output_prefix_end_byte",
		"output_prefix_start_byte",
		"prompt_hash",
		"provider_id",
		"provider_receipt_key_id",
		"receipt_version",
		"request_id",
		"route_snapshot_digest",
		"route_snapshot_mode",
		"route_snapshot_policy_version",
		"signature_key_alg",
		"terminal_state",
		"terminal_state_ts_unix_ms",
		"usage",
	}
)

func decodeJSONUseNumber(raw []byte, out any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	return decoder.Decode(out)
}

func canonicalizeJSONValue(kind string, value any) ([]byte, error) {
	var b strings.Builder
	if err := writeCanonical(&b, value, kind == "settlement_output_v1", nil); err != nil {
		return nil, err
	}
	return []byte(b.String()), nil
}

func writeCanonical(b *strings.Builder, value any, rawToolCallArguments bool, path []string) error {
	switch v := value.(type) {
	case map[string]any:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool {
			return utf16LexicographicLess(keys[i], keys[j])
		})
		b.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeEscapedString(b, key, false)
			b.WriteByte(':')
			childPath := append(append([]string(nil), path...), key)
			if rawToolCallArguments && isToolCallArgumentPath(childPath) {
				raw, ok := v[key].(string)
				if !ok {
					return fmt.Errorf("tool-call arguments value %T is not a string", v[key])
				}
				writeEscapedString(b, raw, false)
				continue
			}
			if err := writeCanonical(b, v[key], rawToolCallArguments, childPath); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	case []any:
		b.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeCanonical(b, item, rawToolCallArguments, path); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case string:
		writeEscapedString(b, v, true)
	case json.Number:
		if strings.ContainsAny(v.String(), ".eE") {
			return fmt.Errorf("non-integer JSON number %q unsupported by v0.4 fixtures", v.String())
		}
		if _, err := strconv.ParseInt(v.String(), 10, 64); err != nil {
			return err
		}
		b.WriteString(v.String())
	case bool:
		if v {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case nil:
		b.WriteString("null")
	default:
		return fmt.Errorf("unsupported JSON fixture value %T", value)
	}
	return nil
}

func isToolCallArgumentPath(path []string) bool {
	if len(path) < 3 {
		return false
	}
	if path[len(path)-2] != "function" || path[len(path)-1] != "arguments" {
		return false
	}
	for _, segment := range path[:len(path)-2] {
		if segment == "tool_calls" {
			return true
		}
	}
	return false
}

func writeEscapedString(b *strings.Builder, s string, normalizeNFC bool) {
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

func assertStrictKeys(t *testing.T, id string, value map[string]any, want []string) {
	t.Helper()
	got := make([]string, 0, len(value))
	for key := range value {
		got = append(got, key)
	}
	wantSorted := sortedCopy(want)
	sort.Strings(got)
	if strings.Join(got, "\x00") != strings.Join(wantSorted, "\x00") {
		t.Fatalf("%s strict keys = %#v, want %#v", id, got, wantSorted)
	}
}

func assertFixtureStrictKeys(t *testing.T, id string, fixtureKeys, want []string) {
	t.Helper()
	got := sortedCopy(fixtureKeys)
	wantSorted := sortedCopy(want)
	if strings.Join(got, "\x00") != strings.Join(wantSorted, "\x00") {
		t.Fatalf("%s fixture strict_keys = %#v, want %#v", id, got, wantSorted)
	}
}

func expectedKeysForKind(t *testing.T, kind string) []string {
	t.Helper()
	switch kind {
	case "route_snapshot_v1":
		return routeSnapshotKeys
	case "settlement_output_v1":
		return settlementOutputKeys
	case "usage":
		return usageKeys
	default:
		t.Fatalf("unknown fixture kind %q", kind)
		return nil
	}
}

func int64Value(t *testing.T, id, field string, value any) int64 {
	t.Helper()
	number, ok := value.(json.Number)
	if !ok {
		t.Fatalf("%s %s = %#v, want json.Number", id, field, value)
	}
	out, err := strconv.ParseInt(number.String(), 10, 64)
	if err != nil {
		t.Fatalf("%s %s parse: %v", id, field, err)
	}
	return out
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
