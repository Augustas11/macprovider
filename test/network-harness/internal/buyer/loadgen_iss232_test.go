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

// TestConsumeSSE_LeadingSpaceForgedEnvelope_232_R4_HIGH:
// SEC R4 HIGH attack — gateway emits a forged terminal error envelope
// on a line with leading whitespace (` data: {...}`). A strict
// OpenAI/EventSource client treats this as an unrecognized non-field
// line and ignores it; the buyer never sees the envelope. The harness
// MUST also reject it.
func TestConsumeSSE_LeadingSpaceForgedEnvelope_232_R4_HIGH(t *testing.T) {
	body := bytes.NewBufferString(" data: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("leading-space data: line MUST NOT corroborate — got true (#232 R4 SEC HIGH)")
	}
	if r.SSEErrorCode != "" {
		t.Errorf("SSEErrorCode must stay empty, got %q", r.SSEErrorCode)
	}
}

// TestConsumeSSE_LeadingTabForgedEnvelope_232_R4_HIGH:
// same attack vector but using a tab prefix.
func TestConsumeSSE_LeadingTabForgedEnvelope_232_R4_HIGH(t *testing.T) {
	body := bytes.NewBufferString("\tdata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("leading-tab data: line MUST NOT corroborate — got true (#232 R4 SEC HIGH)")
	}
}

// TestConsumeSSE_LeadingWhitespaceDONEIgnored_232_R4:
// confirm that a leading-whitespace `[DONE]` is also rejected (would
// otherwise let an attacker inject a "fake early terminator" to truncate
// our reading).
func TestConsumeSSE_LeadingWhitespaceDONEIgnored_232_R4(t *testing.T) {
	body := bytes.NewBufferString(" data: [DONE]\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"x\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("real terminal envelope after leading-whitespace fake-DONE MUST corroborate, got false")
	}
	if r.SSEErrorCode != "stream_truncated" {
		t.Errorf("SSEErrorCode = %q, want stream_truncated", r.SSEErrorCode)
	}
}

// TestConsumeSSE_BOMPrefixedDONEThenForgedEnvelope_232_R5_HIGH:
// SEC R5 HIGH-1 attack — gateway prefixes the [DONE] terminator with a
// UTF-8 BOM. Spec-compliant clients (EventSource, OpenAI Python/Node)
// strip the BOM at stream start and treat the line as `data: [DONE]`,
// terminating there. The harness must also strip the BOM so the forged
// envelope after the BOM-DONE is invisible to corroboration.
func TestConsumeSSE_BOMPrefixedDONEThenForgedEnvelope_232_R5_HIGH(t *testing.T) {
	body := bytes.NewBufferString("\xEF\xBB\xBFdata: [DONE]\n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("BOM-stripped [DONE] must flip SawTerminator")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("post-BOM-DONE forged envelope MUST NOT corroborate — got true (#232 R5 SEC HIGH)")
	}
	if r.SSEErrorCode != "" {
		t.Errorf("SSEErrorCode must stay empty, got %q", r.SSEErrorCode)
	}
}

// TestConsumeSSE_BOMPrefixedLegitimateEnvelopeStillWorks_232_R5:
// confirm BOM stripping doesn't break the happy path — a real
// terminal error envelope after a BOM-prefixed first line still
// corroborates.
func TestConsumeSSE_BOMPrefixedLegitimateEnvelopeStillWorks_232_R5(t *testing.T) {
	body := bytes.NewBufferString("\xEF\xBB\xBFdata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"legit\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("legit envelope after BOM-prefixed content must corroborate")
	}
	if r.SSEErrorCode != "stream_truncated" {
		t.Errorf("SSEErrorCode = %q, want stream_truncated", r.SSEErrorCode)
	}
}

// TestConsumeSSE_EnvelopeThenEOFNoBlankLine_232_R5_HIGH:
// SEC R5 HIGH-2 attack — gateway emits a standalone envelope without
// the trailing blank-line that completes the SSE event, then EOFs.
// Spec-compliant clients DISCARD the pending event because it was
// never dispatched. The harness must not corroborate this case.
func TestConsumeSSE_EnvelopeThenEOFNoBlankLine_232_R5_HIGH(t *testing.T) {
	// Single `\n` after envelope, then EOF — no blank-line dispatch.
	body := bytes.NewBufferString("data: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("envelope without blank-line dispatch + EOF MUST NOT corroborate — got true (#232 R5 SEC HIGH-2)")
	}
}

// TestConsumeSSE_EnvelopeThenBlankLineThenEOF_232_R5:
// happy path confirmation: envelope + blank line + EOF (no [DONE])
// still corroborates because the blank line dispatched the event
// before EOF.
func TestConsumeSSE_EnvelopeThenBlankLineThenEOF_232_R5(t *testing.T) {
	body := bytes.NewBufferString("data: {\"error\":{\"code\":\"provider_disconnected\",\"type\":\"server_error\",\"message\":\"x\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("envelope + blank-line + EOF must corroborate")
	}
	if r.SSEErrorCode != "provider_disconnected" {
		t.Errorf("SSEErrorCode = %q, want provider_disconnected", r.SSEErrorCode)
	}
}

// TestConsumeSSE_EnvelopeImmediatelyBeforeDONENoBlankLine_232_R6_HIGH:
// SEC R6 HIGH-1 attack vector. Per HTML5/SSE spec, consecutive `data:`
// lines without an intervening blank line form ONE event with data
// concatenated by `\n`. So `data: {error}\ndata: [DONE]\n\n` is NOT
// a dispatched envelope + terminator — it is ONE event whose data is
// `{error}\n[DONE]`. Spec-compliant clients dispatch that one merged
// event, which is neither a clean `[DONE]` (so no termination) nor a
// standalone envelope (so no corroboration). The harness must require
// envelopeDispatched on the `[DONE]` path too.
func TestConsumeSSE_EnvelopeImmediatelyBeforeDONENoBlankLine_232_R6_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("envelope+immediate-[DONE] (no blank-line dispatch) MUST NOT corroborate — got true (#232 R6 SEC HIGH)")
	}
	// #232 R7 SEC HIGH / CODE MED — same event-boundary reasoning as
	// R6, extended to SawTerminator. This is one undispatched merged
	// event whose data is `{forged}\n[DONE]`; spec-compliant clients
	// see no terminator. Without this assertion, I4 would skip the
	// stream even though the buyer never saw completion.
	if r.SawTerminator {
		t.Errorf("envelope+immediate-[DONE] (no blank-line dispatch) MUST NOT flip SawTerminator — got true (#232 R7 SEC HIGH / CODE MED)")
	}
}

// TestConsumeSSE_ContentImmediatelyBeforeDONENoBlankLine_232_R7_HIGH:
// SEC R7 HIGH attack vector — no envelope, just content data merged
// with [DONE] in a single undispatched SSE event. Per HTML5/SSE spec,
// `data: hello\ndata: [DONE]\n\n` dispatches ONE event whose data is
// `hello\n[DONE]`; a spec-compliant OpenAI-style client does not
// terminate on this because the event's data is not exactly `[DONE]`.
// The harness must match: SawTerminator=false so I4 still checks the
// silent-hang path.
func TestConsumeSSE_ContentImmediatelyBeforeDONENoBlankLine_232_R7_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawTerminator {
		t.Errorf("content+immediate-[DONE] (no blank-line dispatch) MUST NOT flip SawTerminator — got true (#232 R7 SEC HIGH)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("content+immediate-[DONE] MUST NOT corroborate — got true")
	}
}

// TestConsumeSSE_LeadingDONENoDispatch_232_R7:
// happy-path control at event start — a leading `data: [DONE]` at
// the very start of the stream IS a standalone terminator event
// (blank line before is implicit at stream start).
func TestConsumeSSE_LeadingDONE_232_R7(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("leading standalone [DONE] must flip SawTerminator")
	}
}

// TestConsumeSSE_EnvelopeBlankLineDONE_232_R6:
// happy-path control: envelope + blank line + [DONE] DOES corroborate
// (event was dispatched between envelope and terminator).
func TestConsumeSSE_EnvelopeBlankLineDONE_232_R6(t *testing.T) {
	body := bytes.NewBufferString("data: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"legit\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("envelope+blank-line+[DONE] must corroborate")
	}
	if r.SSEErrorCode != "stream_truncated" {
		t.Errorf("SSEErrorCode = %q, want stream_truncated", r.SSEErrorCode)
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

// TestConsumeSSE_LeadingDONEFollowedByContent_232_R8_HIGH:
// SEC R8 HIGH attack — symmetric leading-[DONE] class. Per HTML5/SSE
// spec, `data: [DONE]\ndata: {content}\n\n` dispatches ONE event whose
// data is `[DONE]\n{content}` — spec-compliant clients see neither a
// clean [DONE] terminator nor a standalone envelope. The R7 fix
// closed the trailing case (envelope/content before [DONE]); this
// closes the leading case where [DONE] arrives first but the event
// has NOT yet been dispatched by a blank line. Without the R8
// event-boundary refactor the harness returned SawTerminator=true on
// the first line-read, letting I4 (invariants/hard.go:304) skip the
// stream.
func TestConsumeSSE_LeadingDONEFollowedByContent_232_R8_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\ndata: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawTerminator {
		t.Errorf("leading-[DONE]+content (no blank-line dispatch) MUST NOT flip SawTerminator — got true (#232 R8 SEC HIGH)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("leading-[DONE]+content MUST NOT corroborate — got true")
	}
}

// TestConsumeSSE_LeadingDONEEOFNoDispatch_232_R8_HIGH:
// second SEC R8 HIGH shape — `data: [DONE]\n<EOF>` with no blank
// line. The pending event is DISCARDED per SSE spec (browser
// EventSource + OpenAI Python/Node parsers). The harness must match:
// no terminator, no corroboration.
func TestConsumeSSE_LeadingDONEEOFNoDispatch_232_R8_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawTerminator {
		t.Errorf("leading-[DONE]+EOF (no blank-line dispatch) MUST NOT flip SawTerminator — got true (#232 R8 SEC HIGH)")
	}
}

// TestConsumeSSE_LeadingDONEFollowedByForgedEnvelope_232_R8_HIGH:
// third SEC R8 HIGH shape — leading [DONE] merged with a forged
// envelope in the same undispatched event. Buyer sees ONE event with
// data `[DONE]\n{forged}`, neither terminator nor standalone envelope.
func TestConsumeSSE_LeadingDONEFollowedByForgedEnvelope_232_R8_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawTerminator {
		t.Errorf("leading-[DONE]+envelope (no blank-line dispatch) MUST NOT flip SawTerminator — got true (#232 R8 SEC HIGH)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("leading-[DONE]+envelope MUST NOT corroborate — got true (#232 R8 SEC HIGH)")
	}
}

// TestConsumeSSE_LeadingDONEBlankThenEnvelope_232_R8_HIGH:
// R8 confirms `[DONE]` dispatch stops the reader — a well-formed
// `data: [DONE]\n\n` followed by a forged post-terminator envelope
// MUST NOT corroborate. This is the R3 post-[DONE] attack recast for
// the R8 event-boundary parser.
func TestConsumeSSE_LeadingDONEBlankThenEnvelope_232_R8(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("dispatched leading [DONE] must flip SawTerminator")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("post-[DONE] forged envelope MUST NOT corroborate — got true (#232 R3 recheck)")
	}
}
