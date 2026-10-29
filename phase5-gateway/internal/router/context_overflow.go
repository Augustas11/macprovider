package router

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
)

var contextCapacityMessage = regexp.MustCompile(`^This model's maximum context length is ([1-9][0-9]{0,18}) tokens\.$`)

// Normalize only an explicit context refusal, after settlement and receipt
// classification have consumed the coordinator's original status and code.
func clientContextOverflow(status int, body []byte) (int, []byte) {
	if status != http.StatusRequestEntityTooLarge && status != http.StatusBadRequest {
		return status, body
	}
	var envelope struct {
		Error map[string]json.RawMessage `json:"error"`
	}
	if json.Unmarshal(body, &envelope) != nil {
		return status, body
	}
	var code string
	if json.Unmarshal(envelope.Error["code"], &code) != nil || (code != "context_exceeds_capacity" && code != "context_length_exceeded") {
		return status, body
	}
	message := "Request exceeds the model's maximum context length."
	var raw string
	if json.Unmarshal(envelope.Error["message"], &raw) == nil {
		if match := contextCapacityMessage.FindStringSubmatch(raw); match != nil {
			if n, err := strconv.ParseInt(match[1], 10, 64); err == nil && n > 0 {
				message = fmt.Sprintf("This model's maximum context length is %d tokens.", n)
			}
		}
	}
	result := map[string]any{"message": message, "type": "invalid_request_error", "code": "context_length_exceeded", "param": nil, "retryable": false}
	// Preserve the bounded execution/settlement facts, never provider text or
	// arbitrary extensions that could contain prompt or infrastructure details.
	for _, key := range []string{"inference_ran", "settlement_ran"} {
		var value bool
		if json.Unmarshal(envelope.Error[key], &value) == nil {
			result[key] = value
		}
	}
	normalized, _ := json.Marshal(map[string]any{"error": result})
	return http.StatusBadRequest, normalized
}
