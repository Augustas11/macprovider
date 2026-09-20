package buyer

import (
	"bytes"
	"strings"
	"testing"
)

func TestConcatSafeCoalesceFlushesNameOpenImmediately(t *testing.T) {
	stream := newConcatSafeToolStream()
	open := []byte(`data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}` + "\n\n")
	out, err := stream.observeBlock(open)
	if err != nil {
		t.Fatalf("role: %v", err)
	}
	if !bytes.Contains(out, []byte(`"role":"assistant"`)) {
		t.Fatalf("role chunk must flush immediately: %s", out)
	}

	nameOpen := []byte(`data: {"id":"chatcmpl-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":null}]}` + "\n\n")
	out, err = stream.observeBlock(nameOpen)
	if err != nil {
		t.Fatalf("name-open: %v", err)
	}
	if !bytes.Contains(out, []byte(`"name":"bash"`)) {
		t.Fatalf("name-open must flush immediately: %s", out)
	}
	if bytes.Contains(out, []byte(`"arguments":"{}"`)) {
		t.Fatalf("opening {} must not reach the buyer: %s", out)
	}
	if bytes.Contains(out, []byte(`"arguments":"{\"command\"`)) {
		t.Fatalf("arguments must be held until finish: %s", out)
	}
}

func TestConcatSafeCoalesceReplacesEmptyObjectWithCompleteArgs(t *testing.T) {
	stream := newConcatSafeToolStream()
	_, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{}"}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	held, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"echo hello\"}"}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if concatSSEToolArguments(t, held) != `{"command":"echo hello"}` {
		t.Fatalf("complete non-empty arguments must flush once they are concat-safe: %s", held)
	}
	finish, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	got := concatSSEToolArguments(t, append(held, finish...))
	if got != `{"command":"echo hello"}` {
		t.Fatalf("concatenated arguments = %q body=%s", got, append(held, finish...))
	}
	if bytes.Contains(finish, []byte(`{}{"command"`)) {
		t.Fatalf("buyer concat glued empty object onto arguments: %s", finish)
	}
}

func TestConcatSafeCoalescePassThroughConcatSafeCLI(t *testing.T) {
	stream := newConcatSafeToolStream()
	open, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":""}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(open, []byte(`"name":"bash"`)) {
		t.Fatalf("concat-safe name-open must flush: %s", open)
	}
	held, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"echo hello\"}"}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if concatSSEToolArguments(t, held) != `{"command":"echo hello"}` {
		t.Fatalf("concat-safe complete object must flush before finish: %s", held)
	}
	finish, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n\ndata: [DONE]\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	got := concatSSEToolArguments(t, append(held, finish...))
	if got != `{"command":"echo hello"}` {
		t.Fatalf("concatenated arguments = %q body=%s", got, append(held, finish...))
	}
	if !bytes.Contains(finish, []byte("data: [DONE]")) {
		t.Fatalf("DONE must still be forwarded: %s", finish)
	}
}

func TestConcatSafeCoalescePrefixFragmentsJoinIntoOneObject(t *testing.T) {
	stream := newConcatSafeToolStream()
	_, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":""}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	first, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\""}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if concatSSEToolArguments(t, first) != `{"command":"` {
		t.Fatalf("incomplete prefix must flush: %s", first)
	}
	second, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"echo hello\"}"}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	finish, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	got := concatSSEToolArguments(t, append(append(first, second...), finish...))
	if got != `{"command":"echo hello"}` {
		t.Fatalf("prefix concat = %q body=%s", got, append(append(first, second...), finish...))
	}
}

func TestConcatSafeCoalesceEmptyObjectOnlyToolCall(t *testing.T) {
	stream := newConcatSafeToolStream()
	if _, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"noop","arguments":"{}"}}]}}]}` + "\n\n")); err != nil {
		t.Fatal(err)
	}
	finish, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	got := concatSSEToolArguments(t, finish)
	if got != `{}` {
		t.Fatalf("legitimate empty args = %q body=%s", got, finish)
	}
}

func TestConcatSafeCoalesceSameEventNameOpenAndFinish(t *testing.T) {
	stream := newConcatSafeToolStream()
	out, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hello\"}"}}]},"finish_reason":"tool_calls"}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	nameAt := bytes.Index(out, []byte(`"name":"bash"`))
	argsAt := bytes.Index(out, []byte(`"arguments":"{\"command\":\"echo hello\"}"`))
	finishAt := bytes.Index(out, []byte(`"finish_reason":"tool_calls"`))
	if nameAt < 0 || argsAt < 0 || finishAt < 0 {
		t.Fatalf("missing name/args/finish: %s", out)
	}
	if !(nameAt < argsAt && argsAt < finishAt) {
		t.Fatalf("expected name-open then args then finish, got %s", out)
	}
	if concatSSEToolArguments(t, out) != `{"command":"echo hello"}` {
		t.Fatalf("concat=%q body=%s", concatSSEToolArguments(t, out), out)
	}
}

func TestConcatSafeCoalesceContentPassesThrough(t *testing.T) {
	stream := newConcatSafeToolStream()
	in := []byte(`data: {"choices":[{"delta":{"content":"hello"}}]}` + "\n\n")
	out, err := stream.observeBlock(in)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out, in) {
		t.Fatalf("content chunk rewritten: %s", out)
	}
}

func TestConcatSafeCoalesceCommentPassesThrough(t *testing.T) {
	stream := newConcatSafeToolStream()
	in := []byte(": macprovider_tool_call_open unix_ms=1716768000000\n\n")
	out, err := stream.observeBlock(in)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out, in) {
		t.Fatalf("comment rewritten: %s", out)
	}
}

func TestCoalesceToolArgumentsReplacesEmptyObject(t *testing.T) {
	got := coalesceToolArguments("{}", `{"command":"echo hello"}`)
	if got != `{"command":"echo hello"}` {
		t.Fatalf("got %q", got)
	}
	if strings.Contains(got, "{}{") {
		t.Fatal("concat glued empty object")
	}
}

func TestCoalesceToolArgumentsDoesNotReplaceNonEmptyGarbage(t *testing.T) {
	got := coalesceToolArguments(`{"bad":`, `{"command":"echo hello"}`)
	if got == `{"command":"echo hello"}` {
		t.Fatal("non-empty held garbage must not be replaced by a later object")
	}
}

func TestConcatSafeRejectsArgumentsBeforeNameOpen(t *testing.T) {
	stream := newConcatSafeToolStream()
	_, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"x\"}"}}]}}]}` + "\n\n"))
	if err == nil {
		t.Fatal("arguments before a valid name-open must fail closed")
	}
}

func TestConcatSafeDoesNotFlushEmptyObjectWithoutFinish(t *testing.T) {
	stream := newConcatSafeToolStream()
	open, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{}"}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(open, []byte(`"arguments":"{}"`)) {
		t.Fatalf("opening {} must not reach the buyer: %s", open)
	}
	out, err := stream.flush()
	if err != nil {
		t.Fatal(err)
	}
	if len(bytes.TrimSpace(out)) != 0 {
		t.Fatalf("held {} must not reach the buyer without finish_reason: %s", out)
	}
}

func TestConcatSafeFinishDoesNotEmitEmptyToolCallsAfterPrefixFlush(t *testing.T) {
	stream := newConcatSafeToolStream()
	if _, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":""}}]}}]}` + "\n\n")); err != nil {
		t.Fatal(err)
	}
	args, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"echo hello\"}"}}]}}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if concatSSEToolArguments(t, args) != `{"command":"echo hello"}` {
		t.Fatalf("args=%s", args)
	}
	finish, err := stream.observeBlock([]byte(`data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}` + "\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(finish, []byte(`"tool_calls":[]`)) {
		t.Fatalf("empty tool_calls delta after prefix flush: %s", finish)
	}
}
