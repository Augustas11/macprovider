package sourceevidence

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

func canonicalBytes(v any) ([]byte, error) {
	if err := validateCanonical(v); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	writeCanonical(&buf, v)
	return buf.Bytes(), nil
}

func validateCanonical(v any) error {
	switch x := v.(type) {
	case nil, bool:
		return nil
	case string:
		for _, r := range x {
			if r < 0x20 || r > 0x7e {
				return fmt.Errorf("non-ascii source evidence string")
			}
		}
		return nil
	case int:
		if x < 0 {
			return fmt.Errorf("negative source evidence integer")
		}
		return nil
	case int64:
		if x < 0 {
			return fmt.Errorf("negative source evidence integer")
		}
		return nil
	case json.Number:
		i, err := x.Int64()
		if err != nil || i < 0 || x.String() != fmt.Sprintf("%d", i) {
			return fmt.Errorf("source evidence number must be a non-negative safe integer")
		}
		if i > maxSafeIntegerInt64 {
			return fmt.Errorf("source evidence integer exceeds safe bound")
		}
		return nil
	case float64, float32:
		return fmt.Errorf("floating source evidence values are not admitted")
	case []any:
		for _, item := range x {
			if err := validateCanonical(item); err != nil {
				return err
			}
		}
		return nil
	case map[string]any:
		for k, val := range x {
			if strings.TrimSpace(k) == "" {
				return fmt.Errorf("empty source evidence object key")
			}
			for _, r := range k {
				if r < 0x20 || r > 0x7e {
					return fmt.Errorf("non-ascii source evidence object key")
				}
			}
			if err := validateCanonical(val); err != nil {
				return err
			}
		}
		return nil
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		var out any
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.UseNumber()
		if err := dec.Decode(&out); err != nil {
			return err
		}
		return validateCanonical(out)
	}
}

func writeCanonical(buf *bytes.Buffer, v any) {
	switch x := v.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		if x {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case string:
		b, _ := json.Marshal(x)
		buf.Write(b)
	case int:
		buf.WriteString(fmt.Sprintf("%d", x))
	case int64:
		buf.WriteString(fmt.Sprintf("%d", x))
	case json.Number:
		buf.WriteString(x.String())
	case []any:
		buf.WriteByte('[')
		for i, item := range x {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeCanonical(buf, item)
		}
		buf.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			kb, _ := json.Marshal(k)
			buf.Write(kb)
			buf.WriteByte(':')
			writeCanonical(buf, x[k])
		}
		buf.WriteByte('}')
	default:
		b, _ := json.Marshal(x)
		var out any
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.UseNumber()
		_ = dec.Decode(&out)
		writeCanonical(buf, normalizeJSON(out))
	}
}

func normalizeJSON(v any) any {
	switch x := v.(type) {
	case []any:
		for i := range x {
			x[i] = normalizeJSON(x[i])
		}
	case map[string]any:
		for k := range x {
			x[k] = normalizeJSON(x[k])
		}
	}
	return v
}
