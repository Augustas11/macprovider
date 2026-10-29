package buyer

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
)

// Provider error strings are untrusted. Recognize only the complete runtime
// templates and propagate the capacity number, never arbitrary error text.
var providerContextCapacityPatterns = []*regexp.Regexp{
	regexp.MustCompile(`^max_tokens \([0-9]+\) exceeds this provider's context window \(([1-9][0-9]{0,18}) tokens\)\.$`),
	regexp.MustCompile(`^Prompt length \([0-9]+ tokens\) exceeds this provider's safe capacity \(([1-9][0-9]{0,18}) tokens\)\.$`),
	regexp.MustCompile(`^Prompt length \([0-9]+ tokens\) plus max_tokens \([0-9]+\) exceeds this provider's context window \(([1-9][0-9]{0,18}) tokens\)\.$`),
	regexp.MustCompile(`^This model's maximum context length is ([1-9][0-9]{0,18}) tokens\.$`),
}

func contextOverflowMessage(detail string) string {
	if len(detail) <= 512 {
		for _, pattern := range providerContextCapacityPatterns {
			if match := pattern.FindStringSubmatch(detail); match != nil {
				if n, err := strconv.ParseInt(match[1], 10, 64); err == nil && n > 0 {
					return fmt.Sprintf("This model's maximum context length is %d tokens.", n)
				}
			}
		}
	}
	return "Request exceeds provider context capacity"
}

func httpContextOverflowMessage(body []byte) string {
	var envelope struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &envelope) != nil {
		return contextOverflowMessage("")
	}
	return contextOverflowMessage(envelope.Error.Message)
}

func pinnedContextOverflowMessage(capacity int) string {
	if capacity > 0 {
		return fmt.Sprintf("This model's maximum context length is %d tokens.", capacity)
	}
	return contextOverflowMessage("")
}

func writeSSEContextOverflow(w http.ResponseWriter, detail string) {
	payload, _ := json.Marshal(map[string]any{"error": map[string]any{"message": contextOverflowMessage(detail), "type": "invalid_request_error", "code": "context_length_exceeded", "param": nil, "retryable": false, "inference_ran": true, "settlement_ran": false}})
	_, _ = fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", payload)
}
