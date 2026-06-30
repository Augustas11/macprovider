package buyer

import (
	"bytes"
	"testing"
)

// TestConsumeSSE_StandaloneTerminalErrorBeforeDONE_232_R1:
// the legitimate gateway shape (writeSSEError / writeStructuredOutputTimeoutSSE):
//
//	data: {"error":{"code":"stream_truncated","type":"api_error","message":"..."}}
//	data: [DONE]
//
// Buyer corroboration MUST flip true and the error code MUST be captured.
func TestConsumeSSE_StandaloneTerminalErrorBeforeDONE_232_R1(t *testing.T) {
	body := bytes.NewBufferString(`data: {"error":{"code":"stream_truncated","type":"api_error","message":"Upstream stream failed"}}

data: [DONE]

`)
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("legit terminal error envelope must flip SawSSEErrorEvent, got false")
	}
	if r.SSEErrorCode != "stream_truncated" {
		t.Errorf("SSEErrorCode = %q, want stream_truncated", r.SSEErrorCode)
	}
	if !r.SawTerminator {
		t.Errorf("[DONE] should also flip SawTerminator")
	}
}

// TestConsumeSSE_StandaloneTerminalErrorThenEOFNoDONE_232:
// a fallback path that closes without [DONE] (e.g. provider-disconnect
// edge). Still corroborated when the LAST data chunk was a standalone
// error envelope.
func TestConsumeSSE_StandaloneTerminalErrorThenEOFNoDONE_232(t *testing.T) {
	body := bytes.NewBufferString(`data: {"error":{"code":"provider_disconnected","type":"server_error","message":"x"}}

`)
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("EOF after terminal envelope must still flip SawSSEErrorEvent, got false")
	}
	if r.SSEErrorCode != "provider_disconnected" {
		t.Errorf("SSEErrorCode = %q, want provider_disconnected", r.SSEErrorCode)
	}
	if r.SawTerminator {
		t.Errorf("no [DONE] should leave SawTerminator false")
	}
}

// TestConsumeSSE_AttackerInjectsErrorInContentChunk_232_R2_HIGH:
// SEC R2 HIGH-1 attack vector. A malicious gateway emits a chunk that
// looks like a content chunk (has `choices`/`usage`) but also injects
// a top-level `error.code`. The buyer's stream still ends cleanly with
// [DONE]. Detection MUST NOT corroborate because the chunk is not a
// standalone error envelope.
func TestConsumeSSE_AttackerInjectsErrorInContentChunk_232_R2_HIGH(t *testing.T) {
	body := bytes.NewBufferString(`data: {"choices":[{"delta":{"content":"hello"}}],"usage":{"completion_tokens":8},"error":{"code":"stream_truncated","type":"api_error","message":"forged"}}

data: [DONE]

`)
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("error.code injected into content chunk MUST NOT flip SawSSEErrorEvent — got true (#232 R2 SEC HIGH)")
	}
	if r.SSEErrorCode != "" {
		t.Errorf("SSEErrorCode must stay empty on injection, got %q", r.SSEErrorCode)
	}
}

// TestConsumeSSE_AttackerEmitsStandaloneErrorMidStreamThenContinues_232_R2_HIGH:
// the second SEC R2 HIGH-1 attack vector. Gateway emits a real-looking
// standalone error envelope mid-stream, then continues to emit content
// chunks and closes with [DONE]. Detection MUST NOT corroborate because
// the LAST chunk before [DONE] was content, not the envelope.
func TestConsumeSSE_AttackerEmitsStandaloneErrorMidStreamThenContinues_232_R2_HIGH(t *testing.T) {
	body := bytes.NewBufferString(`data: {"choices":[{"delta":{"content":"hello"}}]}

data: {"error":{"code":"stream_truncated","type":"api_error","message":"forged"}}

data: {"choices":[{"delta":{"content":"world"}}],"usage":{"completion_tokens":12}}

data: [DONE]

`)
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("mid-stream error envelope followed by more content MUST NOT corroborate — got true (#232 R2 SEC HIGH)")
	}
	if r.SSEErrorCode != "" {
		t.Errorf("SSEErrorCode must stay empty when last chunk was content, got %q", r.SSEErrorCode)
	}
}

// TestConsumeSSE_NoErrorEnvelopeBenignNoDONE_232:
// the SEC R1 HIGH-1 benign-no-DONE shape. Plain clean content chunks,
// no terminator, no error envelope. No corroboration → flagged as
// trust-gap candidate by the reconciler.
func TestConsumeSSE_NoErrorEnvelopeBenignNoDONE_232(t *testing.T) {
	body := bytes.NewBufferString(`data: {"choices":[{"delta":{"content":"hello"}}],"usage":{"completion_tokens":8}}

`)
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("benign no-DONE stream must not corroborate, got true")
	}
	if r.SSEErrorCode != "" {
		t.Errorf("SSEErrorCode must be empty, got %q", r.SSEErrorCode)
	}
}

// TestConsumeSSE_ErrorWithEmptyCodeNotCorroborating_232:
// defensive check: an error envelope with no code (malformed) must not
// be treated as a valid terminal envelope.
func TestConsumeSSE_ErrorWithEmptyCodeNotCorroborating_232(t *testing.T) {
	body := bytes.NewBufferString(`data: {"error":{"code":"","type":"api_error","message":"x"}}

data: [DONE]

`)
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("empty error.code must not corroborate")
	}
}

// TestConsumeSSE_PostDONEForgedEnvelope_232_R3_HIGH:
// SEC R3 HIGH attack — gateway delivers a clean buyer-visible
// completion (content chunks + `[DONE]`), then forges a terminal
// error envelope + second `[DONE]`. An OpenAI-style client stops
// reading at the first `[DONE]`. The harness MUST also stop reading
// there; otherwise the forged envelope flips corroboration despite
// the buyer never seeing it.
func TestConsumeSSE_PostDONEForgedEnvelope_232_R3_HIGH(t *testing.T) {
	body := bytes.NewBufferString(`data: {"choices":[{"delta":{"content":"hello"}}],"usage":{"completion_tokens":8}}

data: [DONE]

data: {"error":{"code":"stream_truncated","type":"api_error","message":"forged"}}

data: [DONE]

`)
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("post-[DONE] forged envelope MUST NOT corroborate — got true (#232 R3 SEC HIGH)")
	}
	if r.SSEErrorCode != "" {
		t.Errorf("SSEErrorCode must stay empty when forged post-[DONE], got %q", r.SSEErrorCode)
	}
	if !r.SawTerminator {
		t.Errorf("first [DONE] must still flip SawTerminator")
	}
}

// TestConsumeSSE_PostDONEForgedEnvelopeWithEOF_232_R3_HIGH:
// the EOF variant of the same attack. Clean completion + first `[DONE]`,
// then forged envelope, then EOF (no second `[DONE]`).
func TestConsumeSSE_PostDONEForgedEnvelopeWithEOF_232_R3_HIGH(t *testing.T) {
	body := bytes.NewBufferString(`data: {"choices":[{"delta":{"content":"hello"}}],"usage":{"completion_tokens":8}}

data: [DONE]

data: {"error":{"code":"stream_truncated","type":"api_error","message":"forged"}}

`)
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("post-[DONE]+EOF forged envelope MUST NOT corroborate — got true")
	}
	if !r.SawTerminator {
		t.Errorf("first [DONE] must still flip SawTerminator")
	}
}
