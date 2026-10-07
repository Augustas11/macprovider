package sourceevidence

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

const (
	maxStrictJSONDepth      = 512
	maxCanonicalArrayItems  = 1000
	maxCanonicalStringBytes = 4096
	maxCanonicalKeyBytes    = 128
)

func decodeStrictJSONFromReader(r io.Reader, maxBytes int64, dst any) error {
	if maxBytes <= 0 {
		maxBytes = defaultMaxBodyBytes
	}
	data, err := io.ReadAll(io.LimitReader(r, maxBytes+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > maxBytes {
		return fmt.Errorf("source evidence JSON exceeds %d bytes", maxBytes)
	}
	return decodeStrictJSONBytes(data, dst)
}

func loadStrictJSONFileBounded(path string, maxBytes int64) (any, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("path is required")
	}
	if maxBytes <= 0 {
		maxBytes = defaultMaxBodyBytes
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out any
	if err := decodeStrictJSONFromReader(f, maxBytes, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func decodeStrictJSONBytes(data []byte, dst any) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	value, err := parseStrictJSONValue(dec, 0)
	if err != nil {
		return err
	}
	if tok, err := dec.Token(); err != io.EOF {
		if err != nil {
			return err
		}
		return fmt.Errorf("source evidence JSON has trailing value %v", tok)
	}
	if err := validateCanonical(value); err != nil {
		return err
	}
	if dst == nil {
		return nil
	}
	if ptr, ok := dst.(*any); ok {
		*ptr = value
		return nil
	}
	dec = json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	if tok, err := dec.Token(); err != io.EOF {
		if err != nil {
			return err
		}
		return fmt.Errorf("source evidence JSON has trailing value %v", tok)
	}
	return nil
}

func parseStrictJSONValue(dec *json.Decoder, depth int) (any, error) {
	if depth > maxStrictJSONDepth {
		return nil, fmt.Errorf("source evidence JSON nesting exceeds safe depth")
	}
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch v := tok.(type) {
	case json.Delim:
		switch v {
		case '{':
			out := map[string]any{}
			seen := map[string]struct{}{}
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key, ok := keyTok.(string)
				if !ok {
					return nil, fmt.Errorf("source evidence JSON object key must be a string")
				}
				if _, ok := seen[key]; ok {
					return nil, fmt.Errorf("duplicate source evidence JSON key %q", key)
				}
				seen[key] = struct{}{}
				val, err := parseStrictJSONValue(dec, depth+1)
				if err != nil {
					return nil, err
				}
				out[key] = val
			}
			end, err := dec.Token()
			if err != nil {
				return nil, err
			}
			if end != json.Delim('}') {
				return nil, fmt.Errorf("source evidence JSON object not closed")
			}
			return out, nil
		case '[':
			out := []any{}
			for dec.More() {
				val, err := parseStrictJSONValue(dec, depth+1)
				if err != nil {
					return nil, err
				}
				out = append(out, val)
			}
			end, err := dec.Token()
			if err != nil {
				return nil, err
			}
			if end != json.Delim(']') {
				return nil, fmt.Errorf("source evidence JSON array not closed")
			}
			return out, nil
		default:
			return nil, fmt.Errorf("unexpected source evidence JSON delimiter %q", v)
		}
	case string:
		return v, nil
	case json.Number:
		return v, nil
	case bool, nil:
		return v, nil
	default:
		return nil, fmt.Errorf("unsupported source evidence JSON token %T", tok)
	}
}

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
		if len(x) > maxCanonicalStringBytes {
			return fmt.Errorf("source evidence string exceeds safe bound")
		}
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
		if int64(x) > maxSafeIntegerInt64 {
			return fmt.Errorf("source evidence integer exceeds safe bound")
		}
		return nil
	case int64:
		if x < 0 {
			return fmt.Errorf("negative source evidence integer")
		}
		if x > maxSafeIntegerInt64 {
			return fmt.Errorf("source evidence integer exceeds safe bound")
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
		if len(x) > maxCanonicalArrayItems {
			return fmt.Errorf("source evidence array exceeds safe bound")
		}
		for _, item := range x {
			if err := validateCanonical(item); err != nil {
				return err
			}
		}
		return nil
	case map[string]any:
		for k, val := range x {
			if len(k) > maxCanonicalKeyBytes {
				return fmt.Errorf("source evidence object key exceeds safe bound")
			}
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
		buf.WriteString(strconv.Quote(x))
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
			buf.WriteString(strconv.Quote(k))
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
