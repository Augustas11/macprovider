package buyer

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"golang.org/x/text/unicode/norm"
)

func settlementOutputFromChatResponse(body []byte, terminalState string) (*billing.SettlementOutput, bool) {
	return settlementOutputFromChatResponseAt(body, terminalState, time.Now().UTC().UnixMilli())
}

func settlementOutputFromChatResponseAt(body []byte, terminalState string, terminalStateTSUnixMS int64) (*billing.SettlementOutput, bool) {
	var resp struct {
		Choices []struct {
			Message struct {
				Content   any               `json:"content"`
				ToolCalls []json.RawMessage `json:"tool_calls"`
			} `json:"message"`
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &resp); err != nil || len(resp.Choices) == 0 {
		return nil, false
	}
	choice := resp.Choices[0]
	content := ""
	if choice.Message.Content != nil {
		var ok bool
		content, ok = choice.Message.Content.(string)
		if !ok {
			return nil, false
		}
	}
	toolCalls, ok := settlementToolCallsFromRaw(choice.Message.ToolCalls)
	if !ok {
		return nil, false
	}
	return settlementOutputForContentAt(content, choice.FinishReason, toolCalls, terminalState, terminalStateTSUnixMS), true
}

func settlementOutputForContent(content string, finishReason *string, toolCalls []billing.SettlementToolCall, terminalState string) *billing.SettlementOutput {
	return settlementOutputForContentAt(content, finishReason, toolCalls, terminalState, time.Now().UTC().UnixMilli())
}

func settlementOutputForContentAt(content string, finishReason *string, toolCalls []billing.SettlementToolCall, terminalState string, terminalStateTSUnixMS int64) *billing.SettlementOutput {
	content = canonicalSettlementContent(content)
	delivered := billing.SettlementDeliveredOutputBytes(content)
	return &billing.SettlementOutput{
		Content:               content,
		FinishReason:          finishReason,
		Available:             true,
		OutputPrefixStartByte: 0,
		OutputPrefixEndByte:   delivered,
		TerminalState:         terminalState,
		TerminalStateTSUnixMS: terminalStateTSUnixMS,
		ToolCalls:             toolCalls,
	}
}

func settlementOutputUnavailable() *billing.SettlementOutput {
	return settlementOutputUnavailableFor(billing.TerminalStateProviderError)
}

func settlementOutputUnavailableFor(terminalState string) *billing.SettlementOutput {
	return &billing.SettlementOutput{
		TerminalState:         terminalState,
		TerminalStateTSUnixMS: time.Now().UTC().UnixMilli(),
	}
}

func settlementOutputIsUnavailable(output *billing.SettlementOutput) bool {
	return output != nil && !output.Available
}

func canonicalSettlementContent(content string) string {
	content = strings.ReplaceAll(content, "\r\n", "\n")
	content = strings.ReplaceAll(content, "\r", "\n")
	return norm.NFC.String(content)
}

func settlementToolCallsFromRaw(raw []json.RawMessage) ([]billing.SettlementToolCall, bool) {
	if len(raw) == 0 {
		return nil, true
	}
	out := make([]billing.SettlementToolCall, 0, len(raw))
	for _, item := range raw {
		var call struct {
			ID       string `json:"id"`
			Type     string `json:"type"`
			Function struct {
				Name      string `json:"name"`
				Arguments string `json:"arguments"`
			} `json:"function"`
		}
		if err := json.Unmarshal(item, &call); err != nil {
			return nil, false
		}
		if call.ID == "" || call.Type != "function" || call.Function.Name == "" || !json.Valid([]byte(call.Function.Arguments)) {
			return nil, false
		}
		out = append(out, billing.SettlementToolCall{
			ID:        call.ID,
			Type:      call.Type,
			Name:      call.Function.Name,
			Arguments: call.Function.Arguments,
		})
	}
	return out, true
}

type settlementStreamOutputTracker struct {
	content               string
	finishReason          *string
	toolCalls             map[int]*settlementStreamToolCall
	terminalState         string
	terminalStateTSUnixMS int64
}

type settlementStreamToolCall struct {
	id        string
	typ       string
	name      string
	arguments string
}

func newSettlementStreamOutputTracker() *settlementStreamOutputTracker {
	return &settlementStreamOutputTracker{toolCalls: map[int]*settlementStreamToolCall{}}
}

func (t *settlementStreamOutputTracker) observeLine(line []byte) error {
	data, ok := settlementSSEDataValue(strings.TrimRight(string(line), "\r\n"))
	if !ok || data == "" {
		return nil
	}
	if data == "[DONE]" {
		if t.terminalState != billing.TerminalStateNormalDone {
			t.terminalState = billing.TerminalStateNormalDone
			t.terminalStateTSUnixMS = time.Now().UTC().UnixMilli()
		}
		return nil
	}
	if t.terminalState == billing.TerminalStateNormalDone {
		return fmt.Errorf("settlement stream data arrived after [DONE]")
	}
	if !strings.HasPrefix(strings.TrimSpace(data), "{") {
		return fmt.Errorf("settlement stream data is not JSON")
	}
	var chunk struct {
		Choices []struct {
			Delta struct {
				Content   *string `json:"content"`
				ToolCalls []struct {
					Index    int     `json:"index"`
					ID       *string `json:"id"`
					Type     *string `json:"type"`
					Function *struct {
						Name      *string `json:"name"`
						Arguments *string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"delta"`
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(data), &chunk); err != nil {
		return err
	}
	for _, choice := range chunk.Choices {
		if choice.Delta.Content != nil {
			t.content += *choice.Delta.Content
		}
		if choice.FinishReason != nil {
			value := *choice.FinishReason
			t.finishReason = &value
		}
		for _, delta := range choice.Delta.ToolCalls {
			acc := t.toolCalls[delta.Index]
			if acc == nil {
				acc = &settlementStreamToolCall{}
				t.toolCalls[delta.Index] = acc
			}
			if delta.ID != nil {
				acc.id = *delta.ID
			}
			if delta.Type != nil {
				acc.typ = *delta.Type
			}
			if delta.Function != nil {
				if delta.Function.Name != nil {
					acc.name += *delta.Function.Name
				}
				if delta.Function.Arguments != nil {
					acc.arguments += *delta.Function.Arguments
				}
			}
		}
	}
	return nil
}

func settlementSSEDataValue(line string) (string, bool) {
	if !strings.HasPrefix(line, "data:") {
		return "", false
	}
	value := strings.TrimPrefix(line, "data:")
	if strings.HasPrefix(value, " ") {
		value = strings.TrimPrefix(value, " ")
	}
	return value, true
}

func (t *settlementStreamOutputTracker) observeBlock(block []byte) error {
	for _, line := range bytes.SplitAfter(block, []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		if err := t.observeLine(line); err != nil {
			return err
		}
	}
	return nil
}

func (t *settlementStreamOutputTracker) output(terminalState string) *billing.SettlementOutput {
	return t.outputAt(terminalState, time.Now().UTC().UnixMilli())
}

func (t *settlementStreamOutputTracker) outputAt(terminalState string, terminalStateTSUnixMS int64) *billing.SettlementOutput {
	terminalTS := time.Now().UTC().UnixMilli()
	if terminalStateTSUnixMS > 0 {
		terminalTS = terminalStateTSUnixMS
	}
	if terminalStateTSUnixMS <= 0 && terminalState == billing.TerminalStateNormalDone && t.terminalState == billing.TerminalStateNormalDone && t.terminalStateTSUnixMS > 0 {
		terminalTS = t.terminalStateTSUnixMS
	}
	indexes := make([]int, 0, len(t.toolCalls))
	for index := range t.toolCalls {
		indexes = append(indexes, index)
	}
	sort.Ints(indexes)
	var calls []billing.SettlementToolCall
	for _, index := range indexes {
		call := t.toolCalls[index]
		if call == nil || call.id == "" || call.name == "" {
			return settlementOutputUnavailableFor(terminalState)
		}
		if !json.Valid([]byte(call.arguments)) {
			return settlementOutputUnavailableFor(terminalState)
		}
		typ := call.typ
		if typ == "" {
			typ = "function"
		}
		if typ != "function" {
			return settlementOutputUnavailableFor(terminalState)
		}
		calls = append(calls, billing.SettlementToolCall{
			ID:        call.id,
			Type:      typ,
			Name:      call.name,
			Arguments: call.arguments,
		})
	}
	return settlementOutputForContentAt(t.content, t.finishReason, calls, terminalState, terminalTS)
}

func terminalStateFromAttempt(status int, errMsg, errCode string) string {
	switch {
	case errMsg == "Buyer disconnected during request" ||
		errMsg == "Buyer disconnected during streaming" ||
		errMsg == "Buyer disconnected during buffered streaming":
		return billing.TerminalStateBuyerCancel
	case status == http.StatusGatewayTimeout || errCode == "provider_timeout":
		return billing.TerminalStateGatewayTimeout
	case status >= 400 || errMsg != "" || errCode != "":
		return billing.TerminalStateProviderError
	default:
		return billing.TerminalStateNormalDone
	}
}
