package router

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
)

// spec018RequestAcceptedToolCallID is SPEC-018 AC-31:
// ^call_[A-Za-z0-9]{16,64}$
func spec018RequestAcceptedToolCallID(id string) bool {
	if !strings.HasPrefix(id, "call_") {
		return false
	}
	suffix := id[5:]
	if len(suffix) < 16 || len(suffix) > 64 {
		return false
	}
	for i := 0; i < len(suffix); i++ {
		c := suffix[i]
		if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			continue
		}
		return false
	}
	return true
}

func toRequestAcceptedToolCallID(id string) string {
	if spec018RequestAcceptedToolCallID(id) {
		return id
	}
	sum := sha256.Sum256([]byte(id))
	return "call_" + hex.EncodeToString(sum[:])[:32]
}

// rewriteChatRequestToolCallIDs maps inbound OpenAI chat tool IDs that
// coordinator/provider validation would reject onto deterministic
// SPEC-018-accepted IDs. Empty IDs are left untouched so the coordinator
// still returns invalid_tool_call_id. IDs that already match AC-31 are
// forwarded unchanged (Cline / macprovider-emitted UUIDs).
func rewriteChatRequestToolCallIDs(body []byte) []byte {
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(body, &payload); err != nil {
		return body
	}
	rawMsgs, ok := payload["messages"]
	if !ok {
		return body
	}
	var messages []map[string]any
	dec := json.NewDecoder(bytes.NewReader(rawMsgs))
	dec.UseNumber()
	if err := dec.Decode(&messages); err != nil {
		return body
	}
	idMap := map[string]string{}
	canonicalize := func(id string) string {
		if mapped, ok := idMap[id]; ok {
			return mapped
		}
		mapped := toRequestAcceptedToolCallID(id)
		idMap[id] = mapped
		return mapped
	}
	changed := false
	for _, msg := range messages {
		if calls, ok := msg["tool_calls"].([]any); ok {
			for _, call := range calls {
				m, ok := call.(map[string]any)
				if !ok {
					continue
				}
				id, ok := m["id"].(string)
				if !ok || strings.TrimSpace(id) == "" {
					continue
				}
				newID := canonicalize(id)
				if newID != id {
					m["id"] = newID
					changed = true
				}
			}
		}
		if id, ok := msg["tool_call_id"].(string); ok && strings.TrimSpace(id) != "" {
			newID := canonicalize(id)
			if newID != id {
				msg["tool_call_id"] = newID
				changed = true
			}
		}
	}
	if !changed {
		return body
	}
	newMsgs, err := json.Marshal(messages)
	if err != nil {
		return body
	}
	idx := bytes.Index(body, rawMsgs)
	if idx < 0 {
		return body
	}
	out := make([]byte, 0, len(body)-len(rawMsgs)+len(newMsgs))
	out = append(out, body[:idx]...)
	out = append(out, newMsgs...)
	out = append(out, body[idx+len(rawMsgs):]...)
	return out
}
