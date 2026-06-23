package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/verify"
)

type jsonResult struct {
	Result          string        `json:"result"`
	Reason          string        `json:"reason"`
	ProviderID      *string       `json:"provider_id"`
	ModelID         *string       `json:"model_id"`
	SignedAt        *int64        `json:"signed_at"`
	TrustSource     string        `json:"trust_source"`
	CoordinatorHost *string       `json:"coordinator_host"`
	Details         *jsonDetails  `json:"details,omitempty"`
	Warnings        []jsonWarning `json:"warnings,omitempty"`
}

type jsonDetails struct {
	Field    string         `json:"field"`
	Computed *string        `json:"computed,omitempty"`
	Receipt  string         `json:"receipt"`
	Extra    map[string]any `json:"extra,omitempty"`
}

type jsonWarning struct {
	Kind   string
	Fields map[string]any
}

func renderJSON(result verify.Result) ([]byte, error) {
	payload := jsonResult{
		Result:          result.Result,
		Reason:          result.Reason,
		ProviderID:      stringOrNull(result.ProviderID),
		ModelID:         stringOrNull(result.ModelID),
		SignedAt:        int64OrNull(result.SignedAt),
		TrustSource:     result.TrustSource,
		CoordinatorHost: coordinatorHostOrNull(result),
	}
	if result.Result == "invalid" && result.Details != nil {
		payload.Details = renderJSONDetails(result.Details)
	}
	if len(result.Warnings) > 0 {
		payload.Warnings = make([]jsonWarning, 0, len(result.Warnings))
		for _, warning := range result.Warnings {
			payload.Warnings = append(payload.Warnings, jsonWarning{
				Kind:   warning.Kind,
				Fields: warning.Fields,
			})
		}
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func renderJSONDetails(details *verify.Details) *jsonDetails {
	out := &jsonDetails{
		Field:   details.Field,
		Receipt: details.Receipt,
		Extra:   details.Extra,
	}
	if details.Field != "signature" {
		out.Computed = &details.Computed
	}
	return out
}

func (w jsonWarning) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	buf.WriteString(`"kind":`)
	kind, err := json.Marshal(w.Kind)
	if err != nil {
		return nil, err
	}
	buf.Write(kind)

	keys := make([]string, 0, len(w.Fields))
	for key := range w.Fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		value, err := json.Marshal(w.Fields[key])
		if err != nil {
			return nil, err
		}
		encodedKey, err := json.Marshal(key)
		if err != nil {
			return nil, err
		}
		buf.WriteByte(',')
		buf.Write(encodedKey)
		buf.WriteByte(':')
		buf.Write(value)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

func renderHuman(result verify.Result) string {
	switch result.Result {
	case "valid":
		return fmt.Sprintf("valid (%s · %s · signed %s · trust=%s)\n",
			humanOrUnknown(result.ProviderID),
			humanOrUnknown(result.ModelID),
			signedAtRFC3339(result.SignedAt),
			humanTrust(result),
		)
	case "invalid":
		return renderHumanInvalid(result) + "\n"
	case "inconclusive":
		return "inconclusive: " + inconclusiveReason(result) + "\n"
	default:
		return fmt.Sprintf("%s: %s\n", result.Result, result.Reason)
	}
}

func renderHumanInvalid(result verify.Result) string {
	if result.Details == nil {
		return "invalid: " + result.Reason
	}
	details := result.Details
	switch details.Field {
	case "prompt_hash", "output_hash", "pubkey":
		return fmt.Sprintf("invalid: %s mismatch (computed=%s receipt=%s)", details.Field, details.Computed, details.Receipt)
	case "grace_window":
		return fmt.Sprintf("invalid: previous_key_outside_grace_window (unix_ts=%s rotated_at=%s expires_at=%s)",
			extraValue(details.Extra, "unix_ts"),
			extraValue(details.Extra, "rotated_at"),
			extraValue(details.Extra, "expires_at"),
		)
	default:
		return "invalid: " + result.Reason
	}
}

func renderWarningsToStderr(w io.Writer, warnings []verify.Warning) {
	for _, warning := range warnings {
		switch warning.Kind {
		case "non_default_coordinator":
			fmt.Fprintf(w, "warning: non-default coordinator %s\n", fieldString(warning.Fields, "coordinator_host"))
		case "explicit_vs_live_divergence":
			fmt.Fprintf(w, "warning: explicit --pubkey differs from coordinator-published pubkey %s at %s\n",
				fieldString(warning.Fields, "live_pubkey"),
				fieldString(warning.Fields, "coordinator_host"),
			)
		case "live_check_skipped":
			fmt.Fprintf(w, "warning: live divergence check skipped (%s)\n", fieldString(warning.Fields, "reason"))
		case "clock_skew":
			fmt.Fprintf(w, "warning: clock skew (receipt unix_ts=%s, system_time=%s, delta=%ss)\n",
				fieldIntString(warning.Fields, "unix_ts"),
				fieldIntString(warning.Fields, "system_time"),
				fieldIntString(warning.Fields, "delta_seconds"),
			)
		default:
			fmt.Fprintf(w, "warning: %s\n", warning.Kind)
		}
	}
}

func stringOrNull(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func int64OrNull(value int64) *int64 {
	if value == 0 {
		return nil
	}
	return &value
}

func coordinatorHostOrNull(result verify.Result) *string {
	if result.TrustSource != "live" && result.TrustSource != "cache" {
		return nil
	}
	return stringOrNull(result.CoordinatorHost)
}

func humanOrUnknown(value string) string {
	if value == "" {
		return "unknown"
	}
	return value
}

func signedAtRFC3339(unix int64) string {
	if unix == 0 {
		return "unknown"
	}
	return time.Unix(unix, 0).UTC().Format(time.RFC3339)
}

func humanTrust(result verify.Result) string {
	if result.TrustSource == "live" || result.TrustSource == "cache" {
		if result.CoordinatorHost != "" {
			return result.TrustSource + "@" + result.CoordinatorHost
		}
	}
	return result.TrustSource
}

func inconclusiveReason(result verify.Result) string {
	switch result.Reason {
	case "pubkey_unresolvable":
		return "pubkey unresolvable"
	case "cache_stale_and_live_unreachable":
		host := result.CoordinatorHost
		if host == "" {
			host = "unknown"
		}
		return "cache stale and /v1/receipt-keys unreachable on " + host
	case "provider_id_not_in_pool":
		return "provider_id not in coordinator pool"
	case "provider_id_unresolvable":
		return "provider_id could not be resolved"
	default:
		return strings.ReplaceAll(result.Reason, "_", " ")
	}
}

func fieldString(fields map[string]any, key string) string {
	value, _ := fields[key].(string)
	return value
}

func fieldIntString(fields map[string]any, key string) string {
	return scalarString(fields[key])
}

func extraValue(fields map[string]any, key string) string {
	return scalarString(fields[key])
}

func scalarString(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case int:
		return strconv.Itoa(typed)
	case int64:
		return strconv.FormatInt(typed, 10)
	case int32:
		return strconv.FormatInt(int64(typed), 10)
	case float64:
		if typed == float64(int64(typed)) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	default:
		return fmt.Sprint(typed)
	}
}
