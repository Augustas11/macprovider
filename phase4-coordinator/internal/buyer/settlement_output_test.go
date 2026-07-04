package buyer

import (
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

func TestTerminalStateFromAttemptCoversReceiptTerminalStates(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		errMsg  string
		errCode string
		want    string
	}{
		{
			name:   "buyer cancel",
			status: http.StatusOK,
			errMsg: "Buyer disconnected during streaming",
			want:   billing.TerminalStateBuyerCancel,
		},
		{
			name:   "gateway timeout status",
			status: http.StatusGatewayTimeout,
			want:   billing.TerminalStateGatewayTimeout,
		},
		{
			name:    "gateway timeout code",
			status:  http.StatusOK,
			errCode: "provider_timeout",
			want:    billing.TerminalStateGatewayTimeout,
		},
		{
			name:   "provider error",
			status: http.StatusBadGateway,
			errMsg: "Selected provider failed; buyer should retry",
			want:   billing.TerminalStateProviderError,
		},
		{
			name:   "normal done",
			status: http.StatusOK,
			want:   billing.TerminalStateNormalDone,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := terminalStateFromAttempt(tt.status, tt.errMsg, tt.errCode)
			if got != tt.want {
				t.Fatalf("terminalStateFromAttempt()=%q, want %q", got, tt.want)
			}
		})
	}
}

func TestSettlementStreamOutputQuarantinesIncompleteToolCall(t *testing.T) {
	tracker := newSettlementStreamOutputTracker()
	line := []byte(`data: {"choices":[{"delta":{"content":"ok","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup"}}]}}]}` + "\n\n")
	if err := tracker.observeLine(line); err != nil {
		t.Fatalf("observeLine: %v", err)
	}

	output := tracker.output(billing.TerminalStateUpstreamTransportDisconnect)
	if output.Available {
		t.Fatalf("output.Available=true, want unavailable for incomplete tool call: %#v", output)
	}
	if output.TerminalState != billing.TerminalStateUpstreamTransportDisconnect {
		t.Fatalf("terminal_state=%q, want %q", output.TerminalState, billing.TerminalStateUpstreamTransportDisconnect)
	}
	if output.TerminalStateTSUnixMS <= 0 {
		t.Fatalf("terminal_state_ts_unix_ms missing: %#v", output)
	}
}

func TestSettlementStreamOutputLatchesDoneAndRejectsPostDoneData(t *testing.T) {
	tracker := newSettlementStreamOutputTracker()
	if err := tracker.observeLine([]byte(`data: {"choices":[{"delta":{"content":"ok"}}]}` + "\n\n")); err != nil {
		t.Fatalf("observe content: %v", err)
	}
	if err := tracker.observeLine([]byte("data: [DONE]\n\n")); err != nil {
		t.Fatalf("observe done: %v", err)
	}
	output := tracker.output(billing.TerminalStateNormalDone)
	if !output.Available {
		t.Fatalf("output unavailable after [DONE]: %#v", output)
	}
	if output.TerminalStateTSUnixMS != tracker.terminalStateTSUnixMS {
		t.Fatalf("terminal ts=%d, want latched [DONE] ts %d", output.TerminalStateTSUnixMS, tracker.terminalStateTSUnixMS)
	}
	firstDoneTS := tracker.terminalStateTSUnixMS
	if err := tracker.observeLine([]byte("data: [DONE]\n\n")); err != nil {
		t.Fatalf("observe duplicate done: %v", err)
	}
	if tracker.terminalStateTSUnixMS != firstDoneTS {
		t.Fatalf("duplicate [DONE] changed terminal ts from %d to %d", firstDoneTS, tracker.terminalStateTSUnixMS)
	}
	if err := tracker.observeLine([]byte(`data: {"choices":[{"delta":{"content":"late"}}]}` + "\n\n")); err == nil {
		t.Fatal("post-[DONE] settlement data accepted")
	}
}

func TestSettlementOutputRejectsDuplicateJSONKeys(t *testing.T) {
	body := []byte(`{"choices":[{"message":{"content":"first","tool_calls":[]},"finish_reason":"stop"}],"usage":{"prompt_tokens":1},"usage":{"prompt_tokens":999}}`)
	if output, ok := settlementOutputFromChatResponseAt(body, billing.TerminalStateNormalDone, 1710000000000); ok || output != nil {
		t.Fatalf("duplicate-key response accepted: output=%#v ok=%v", output, ok)
	}
}

func TestSettlementOutputRejectsDuplicateToolArgumentKeys(t *testing.T) {
	body := []byte(`{"choices":[{"message":{"content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"a\":1,\"a\":2}"}}]},"finish_reason":"tool_calls"}]}`)
	if output, ok := settlementOutputFromChatResponseAt(body, billing.TerminalStateNormalDone, 1710000000000); ok || output != nil {
		t.Fatalf("duplicate-key tool arguments accepted: output=%#v ok=%v", output, ok)
	}
}

func TestSettlementStreamOutputQuarantinesDuplicateToolArgumentKeys(t *testing.T) {
	tracker := newSettlementStreamOutputTracker()
	line := []byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"a\":1,\"a\":2}"}}]}}]}` + "\n\n")
	if err := tracker.observeLine(line); err != nil {
		t.Fatalf("observeLine: %v", err)
	}

	output := tracker.output(billing.TerminalStateNormalDone)
	if output.Available {
		t.Fatalf("output.Available=true, want unavailable for duplicate-key tool arguments: %#v", output)
	}
}
