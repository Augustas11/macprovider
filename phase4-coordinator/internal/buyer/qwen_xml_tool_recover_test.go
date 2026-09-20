package buyer

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

const leakedPiIssueXML = `Let me look at the issue to understand what needs to be inspected:

<tool_call>
<function=bash>
<parameter=command>
curl -s https://api.github.com/repos/Augustas11/macprovider/issues/1588
</parameter>
</function>
<tool_call>`

func TestRecoverQwenFunctionXMLCompletionPiUnclosedWrapper(t *testing.T) {
	raw := leakedProviderJSON(leakedPiIssueXML, "stop", nil)
	allowed := map[string]struct{}{"bash": {}}
	got, ok := recoverQwenFunctionXMLCompletion(raw, allowed)
	if !ok {
		t.Fatal("expected recovery of inner function-XML")
	}
	var resp struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      struct {
				Content   *string `json:"content"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Type     string `json:"type"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(got, &resp); err != nil {
		t.Fatalf("recovered json: %v", err)
	}
	if len(resp.Choices) != 1 {
		t.Fatalf("choices=%d", len(resp.Choices))
	}
	choice := resp.Choices[0]
	if choice.FinishReason != "tool_calls" {
		t.Fatalf("finish_reason=%q", choice.FinishReason)
	}
	if len(choice.Message.ToolCalls) != 1 {
		t.Fatalf("tool_calls=%d", len(choice.Message.ToolCalls))
	}
	call := choice.Message.ToolCalls[0]
	if call.Type != "function" || call.Function.Name != "bash" {
		t.Fatalf("call=%+v", call)
	}
	if !strings.HasPrefix(call.ID, "call_") || len(call.ID) != 5+32 {
		t.Fatalf("id=%q want call_ + 32 hex", call.ID)
	}
	if call.Function.Arguments != `{"command":"curl -s https://api.github.com/repos/Augustas11/macprovider/issues/1588"}` {
		t.Fatalf("arguments=%q", call.Function.Arguments)
	}
	if choice.Message.Content == nil || *choice.Message.Content != "Let me look at the issue to understand what needs to be inspected:" {
		t.Fatalf("content=%v", choice.Message.Content)
	}
}

func TestRecoverQwenFunctionXMLCompletionDoesNotOverrideExistingToolCalls(t *testing.T) {
	raw := []byte(strings.Replace(providerCompleteToolJSON, `"model":"model-a"`, `"model":"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"`, 1))
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("must not rewrite a completion that already has tool_calls: %s", got)
	}
}

func TestRecoverQwenFunctionXMLCompletionUndeclaredFailsClosed(t *testing.T) {
	raw := leakedProviderJSON(`<tool_call>
<function=evil>
<parameter=path>/</parameter>
</function>
<tool_call>`, "stop", nil)
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("undeclared function must not recover: %s", got)
	}
}

func TestRecoverQwenFunctionXMLCompletionIgnoresNonQwenModel(t *testing.T) {
	raw := leakedProviderJSON(leakedPiIssueXML, "stop", json.RawMessage(`"mlx-community/Llama-3.2-3B-Instruct-4bit"`))
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("non-Qwen model must not parse function-XML: %s", got)
	}
}

func TestRecoverQwenUnclosedJSONToolCallEchoHello(t *testing.T) {
	raw := leakedProviderJSON(`<tool_call>
{"arguments": {"command": "echo hello"}, "name": "bash"}
`, "stop", nil)
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if !ok {
		t.Fatal("expected recovery of hybrid JSON-in-<tool_call>")
	}
	var resp struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      struct {
				Content   *string `json:"content"`
				ToolCalls []struct {
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(got, &resp); err != nil {
		t.Fatalf("recovered json: %v", err)
	}
	if resp.Choices[0].FinishReason != "tool_calls" {
		t.Fatalf("finish_reason=%q", resp.Choices[0].FinishReason)
	}
	call := resp.Choices[0].Message.ToolCalls[0]
	if call.Function.Name != "bash" {
		t.Fatalf("name=%q", call.Function.Name)
	}
	if !strings.Contains(call.Function.Arguments, "echo hello") {
		t.Fatalf("arguments=%q", call.Function.Arguments)
	}
	if call.Function.Arguments == "{}" {
		t.Fatal("recovered empty {} arguments")
	}
	if resp.Choices[0].Message.Content != nil {
		t.Fatalf("content should be null, got %v", *resp.Choices[0].Message.Content)
	}
}

func TestRecoverQwenUnclosedJSONToolCallUndeclaredFailsClosed(t *testing.T) {
	raw := leakedProviderJSON(`<tool_call>{"name":"evil","arguments":{"command":"rm"}}`, "stop", nil)
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("undeclared JSON tool must not recover: %s", got)
	}
}

func TestRecoverQwenUnclosedJSONToolCallRejectsOversizedArguments(t *testing.T) {
	args, err := json.Marshal(map[string]string{"command": strings.Repeat("x", maxToolCallArgumentsBytes)})
	if err != nil {
		t.Fatal(err)
	}
	if len(args) <= maxToolCallArgumentsBytes {
		t.Fatalf("fixture arguments=%d want > %d", len(args), maxToolCallArgumentsBytes)
	}
	raw := leakedProviderJSON("<tool_call>{\"name\":\"bash\",\"arguments\":"+string(args)+"}", "stop", nil)
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("oversized recovered arguments must fail closed: %s", got)
	}
}

func TestRecoverQwenUnclosedJSONToolCallRejectsOverDepthArguments(t *testing.T) {
	nested := `{"x":0}`
	for i := 0; i < maxToolCallArgumentsDepth+1; i++ {
		nested = `{"n":` + nested + `}`
	}
	raw := leakedProviderJSON("<tool_call>{\"name\":\"bash\",\"arguments\":"+nested+"}", "stop", nil)
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("over-depth recovered arguments must fail closed: %s", got)
	}
}

func TestStripQwenLeakedToolMarkupFollowUpContent(t *testing.T) {
	raw := leakedProviderJSON("The output of the command `echo hello` is: **hello**. <tool_call>", "stop", nil)
	got, ok := stripQwenLeakedToolMarkupCompletion(raw)
	if !ok {
		t.Fatal("expected leaked <tool_call> to be stripped")
	}
	var resp struct {
		Choices []struct {
			Message struct {
				Content *string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(got, &resp); err != nil {
		t.Fatalf("json: %v", err)
	}
	if resp.Choices[0].Message.Content == nil {
		t.Fatal("prose before leaked markup must remain")
	}
	if strings.Contains(*resp.Choices[0].Message.Content, "<tool_call>") {
		t.Fatalf("markup leaked: %q", *resp.Choices[0].Message.Content)
	}
	if !strings.Contains(*resp.Choices[0].Message.Content, "hello") {
		t.Fatalf("stripped content=%q", *resp.Choices[0].Message.Content)
	}
}

func TestSanitizeQwenLeakedToolMarkupSSEContentDelta(t *testing.T) {
	state := &forwardState{declaredFunctionNames: map[string]struct{}{"bash": {}}}
	in := []byte(`data: {"choices":[{"delta":{"content":"The command printed hello. <tool_call>"}}]}` + "\n\n")
	out := sanitizeQwenLeakedToolMarkupBlock(in, state)
	if bytes.Contains(out, []byte("<tool_call>")) {
		t.Fatalf("markup leaked: %s", out)
	}
	if !bytes.Contains(out, []byte("hello")) {
		t.Fatalf("prose dropped: %s", out)
	}
}

func TestRecoverQwenFunctionXMLCompletionRequiresClosedFunction(t *testing.T) {
	raw := leakedProviderJSON(`<tool_call>
<function=bash>
<parameter=command>
curl -s https://example.test
`, "stop", nil)
	got, ok := recoverQwenFunctionXMLCompletion(raw, map[string]struct{}{"bash": {}})
	if ok {
		t.Fatalf("truncated function must not recover: %s", got)
	}
}

func leakedProviderJSON(content string, finish string, model json.RawMessage) []byte {
	if len(model) == 0 {
		model = json.RawMessage(`"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"`)
	}
	contentJSON, err := json.Marshal(content)
	if err != nil {
		panic(err)
	}
	raw := []byte(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":`)
	raw = append(raw, model...)
	raw = append(raw, `,"choices":[{"index":0,"message":{"role":"assistant","content":`...)
	raw = append(raw, contentJSON...)
	raw = append(raw, `},"finish_reason":`...)
	finishJSON, err := json.Marshal(finish)
	if err != nil {
		panic(err)
	}
	raw = append(raw, finishJSON...)
	raw = append(raw, `}],"usage":{"prompt_tokens":12,"completion_tokens":57,"total_tokens":69}}`...)
	return raw
}
