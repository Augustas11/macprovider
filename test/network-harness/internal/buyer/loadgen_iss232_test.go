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

// TestConsumeSSE_MalformedStandaloneErrorEnvelopeRejected_449:
// SPEC-006 §17.7.1 requires a literal standalone terminal envelope:
// no top-level `choices` key, no top-level `usage` key, unique top-level
// keys, unique immediate `error.*` keys, and no trailing bytes after the
// JSON object. These cases look terminal to a loose json.Unmarshal-based
// parser, but they are not buyer-side corroboration and must not suppress
// downstream reconciler overbill signals.
func TestConsumeSSE_MalformedStandaloneErrorEnvelopeRejected_449(t *testing.T) {
	cases := []struct {
		name           string
		payload        string
		wantPromptZero bool
	}{
		{
			name:    "usage empty object",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"},"usage":{}}`,
		},
		{
			name:    "usage null",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"},"usage":null}`,
		},
		{
			name:    "usage zero tokens",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"},"usage":{"prompt_tokens":0,"completion_tokens":0}}`,
		},
		{
			name:           "usage prompt tokens",
			payload:        `{"error":{"code":"stream_output_exceeded","type":"api_error","message":"forged"},"usage":{"prompt_tokens":64,"completion_tokens":0}}`,
			wantPromptZero: true,
		},
		{
			name:    "choices empty array",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"},"choices":[]}`,
		},
		{
			name:    "duplicate top-level error",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"},"error":{"code":"stream_truncated","type":"api_error","message":"forged"}}`,
		},
		{
			name:    "duplicate top-level usage",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"},"usage":null,"usage":{}}`,
		},
		{
			name:    "duplicate error code",
			payload: `{"error":{"code":"stream_truncated","code":"stream_truncated","type":"api_error","message":"forged"}}`,
		},
		{
			name:    "trailing garbage",
			payload: `{"error":{"code":"stream_truncated","type":"api_error","message":"forged"}} true`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := bytes.NewBufferString("data: " + tc.payload + "\n\ndata: [DONE]\n\n")
			r := &Result{}
			consumeSSE(body, r)
			if r.SawSSEErrorEvent {
				t.Errorf("malformed standalone envelope %q MUST NOT corroborate — got SawSSEErrorEvent=true", tc.name)
			}
			if r.SSEErrorCode != "" {
				t.Errorf("SSEErrorCode must stay empty for malformed envelope %q, got %q", tc.name, r.SSEErrorCode)
			}
			if !r.SawTerminator {
				t.Errorf("trailing [DONE] should still flip SawTerminator for malformed envelope %q", tc.name)
			}
			if tc.wantPromptZero && r.PromptTokensReported != 0 {
				t.Errorf("malformed envelope %q must not import usage.prompt_tokens, got %d", tc.name, r.PromptTokensReported)
			}
		})
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

// TestConsumeSSE_LeadingDONEFollowedByContent_232_R8:
// leading-[DONE] class. Per OpenAI Python/Node SDK behavior
// (`sse.data.startswith("[DONE]")`), a dispatched event whose data
// starts with `[DONE]` — even with trailing bytes — terminates the
// stream. `data: [DONE]\ndata: {content}\n\n` dispatches ONE event
// with data `[DONE]\n{content}` which startswith `[DONE]` → the buyer
// terminates AND the harness terminates. No corroboration attack
// possible because the merged event is not a standalone envelope
// (originally filed as R8 SEC HIGH under strict WHATWG semantics;
// re-scoped under R9's OpenAI SDK parity contract — buyer sees the
// same terminator the harness does).
func TestConsumeSSE_LeadingDONEFollowedByContent_232_R8(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\ndata: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("leading-[DONE]+content merged event starts with [DONE] — MUST flip SawTerminator (OpenAI SDK parity) — got false (#232 R9 realignment)")
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

// TestConsumeSSE_LeadingDONEFollowedByForgedEnvelope_232_R8:
// leading [DONE] merged with a forged envelope in the same event.
// Under OpenAI SDK prefix semantics the event terminates (data
// `[DONE]\n{forged}` startswith `[DONE]`) — but the corroboration
// bit MUST NOT flip because there was no previously dispatched
// standalone envelope. Attacker cannot get corroboration this way.
// (R8 SEC HIGH under strict WHATWG semantics → re-scoped under R9
// OpenAI SDK parity — corroboration invariant still holds.)
func TestConsumeSSE_LeadingDONEFollowedByForgedEnvelope_232_R8(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("leading-[DONE]+envelope merged event starts with [DONE] — MUST flip SawTerminator (OpenAI SDK parity) — got false")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("leading-[DONE]+envelope MUST NOT corroborate (no prior dispatched envelope) — got true")
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

// TestConsumeSSE_EmptyLeadingDataThenDONE_232_R9_HIGH:
// SEC/CODE R9 HIGH attack — `data:\ndata: [DONE]\n\n` dispatches ONE
// event whose data (per SSE spec) is `\n[DONE]`, NOT `[DONE]`. A
// spec-compliant client sees the leading newline and does not
// terminate. Without the R9 eventHasData fix, the parser dropped
// the empty leading `data:` line, built `[DONE]`, and flipped
// SawTerminator=true — bypassing I4.
func TestConsumeSSE_EmptyLeadingDataThenDONE_232_R9_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data:\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawTerminator {
		t.Errorf("empty-data:+[DONE] merged into one event (data `\\n[DONE]`) MUST NOT flip SawTerminator — got true (#232 R9 CODE HIGH)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("empty-data:+[DONE] merged event MUST NOT corroborate — got true")
	}
}

// TestConsumeSSE_EnvelopeThenEmptyEventThenDONE_232_R9_HIGH:
// SEC/CODE R9 HIGH attack — an intermediate empty-data event MUST
// reset the last-dispatched-envelope state. Without the fix, the
// parser skipped the empty event entirely, letting the earlier
// envelope corroborate the trailing `[DONE]` and satisfying the
// bit against a merged-event shape a spec-compliant client would
// dispatch as three distinct events (envelope, empty, `[DONE]`).
func TestConsumeSSE_EnvelopeThenEmptyEventThenDONE_232_R9_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"x\"}}\n\ndata:\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("trailing dispatched [DONE] must still flip SawTerminator")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("intermediate empty-data event MUST reset envelope state; [DONE] MUST NOT corroborate — got true (#232 R9 CODE HIGH)")
	}
}

// TestConsumeSSE_EmptyDataThenEnvelopeThenDONE_232_R9:
// spec-behavior control (not an attack): `data:\ndata: {envelope}\n\n`
// dispatches an event whose joined data is `\n{envelope}`. Go's
// encoding/json and OpenAI's Python/Node clients tolerate leading
// whitespace, so the envelope IS parsed as a standalone terminal
// envelope. The subsequent `[DONE]` DOES corroborate. Documenting
// the boundary so a future reader doesn't misread this as an attack
// path the parser missed.
func TestConsumeSSE_EmptyDataThenEnvelopeThenDONE_232_R9(t *testing.T) {
	body := bytes.NewBufferString("data:\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"x\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("trailing dispatched [DONE] must still flip SawTerminator")
	}
	if !r.SawSSEErrorEvent {
		t.Errorf("empty-data:+envelope merged event parses per json.Unmarshal whitespace tolerance — MUST corroborate (#232 R9 spec-behavior control)")
	}
}

// TestConsumeSSE_TrailingSpaceOnDONE_232_R9_HIGH:
// SEC R9 HIGH-2 attack — OpenAI Python/Node SDK use `startswith("[DONE]")`
// not exact equality, so `data: [DONE] \n\ndata: {forged}\n\n`
// terminates for the buyer at the first event. Harness with exact
// equality kept reading and would corroborate the forged envelope.
// R9 fix flips to bytes.HasPrefix for SDK parity.
func TestConsumeSSE_TrailingSpaceOnDONE_232_R9_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE] \n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("data: [DONE] with trailing space MUST flip SawTerminator (OpenAI SDK startswith parity) — got false (#232 R9 SEC HIGH-2)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("post-[DONE] forged envelope after trailing-space terminator MUST NOT corroborate — got true (#232 R9 SEC HIGH-2)")
	}
}

// TestConsumeSSE_DONEPrefixWithExtraContent_232_R9_HIGH:
// second SEC R9 HIGH-2 shape — `data: [DONE]stuff\n\n`. OpenAI SDK
// terminates on the [DONE] prefix; harness must too.
func TestConsumeSSE_DONEPrefixWithExtraContent_232_R9_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: [DONE]stuff\n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("data: [DONE]stuff MUST flip SawTerminator (OpenAI SDK startswith parity) — got false (#232 R9 SEC HIGH-2)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("post-[DONE]stuff forged envelope MUST NOT corroborate — got true (#232 R9 SEC HIGH-2)")
	}
}

// TestConsumeSSE_BareDataNoColonThenDONE_232_R10_HIGH:
// CODE R10 HIGH attack — WHATWG SSE treats a line with just `data`
// (no colon) as field `data` with empty value. `data\ndata: [DONE]\n\n`
// dispatches ONE event with data `\n[DONE]` (leading newline from
// the empty field) — not a terminator. Without generic field parsing
// the harness dropped the `data` line, saw `[DONE]` alone, and
// flipped SawTerminator=true — bypassing I4.
func TestConsumeSSE_BareDataNoColonThenDONE_232_R10_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawTerminator {
		t.Errorf("bare-`data`+[DONE] merged event (data `\\n[DONE]`) MUST NOT flip SawTerminator — got true (#232 R10 CODE HIGH)")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("bare-`data`+[DONE] MUST NOT corroborate — got true")
	}
}

// TestConsumeSSE_EnvelopeThenBareDataResetThenDONE_232_R10_HIGH:
// CODE R10 HIGH second shape — an intermediate bare-`data` dispatch
// must reset envelope corroboration. Otherwise the trailing `[DONE]`
// would incorrectly corroborate the earlier envelope.
func TestConsumeSSE_EnvelopeThenBareDataResetThenDONE_232_R10_HIGH(t *testing.T) {
	body := bytes.NewBufferString("data: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"x\"}}\n\ndata\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("trailing dispatched [DONE] must still flip SawTerminator")
	}
	if r.SawSSEErrorEvent {
		t.Errorf("intermediate bare-`data` event MUST reset envelope state; [DONE] MUST NOT corroborate — got true (#232 R10 CODE HIGH)")
	}
}

// TestConsumeSSE_CommentLineIgnored_232_R10:
// generic-parse regression control — a comment line (`: keep-alive`)
// per SSE spec has empty field name and MUST be ignored, not treated
// as data. Verifies the generic field parser distinguishes bare
// `data` (data field) from colon-first lines (comments).
func TestConsumeSSE_CommentLineIgnored_232_R10(t *testing.T) {
	body := bytes.NewBufferString(": keep-alive\n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"x\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawTerminator {
		t.Errorf("trailing [DONE] must flip SawTerminator after comment")
	}
	if !r.SawSSEErrorEvent {
		t.Errorf("comment lines must not disturb envelope corroboration — got SawSSEErrorEvent=false")
	}
}

// TestConsumeSSE_ThreadEventForgedEnvelope_232_R10_HIGH:
// SEC R10 HIGH attack — OpenAI Python/Node SDK routes `event: thread.*`
// through Assistants API handlers that do NOT surface `data.error`
// as a terminal envelope on the chat.completions path. A malicious
// gateway emitting `event: thread.message.delta` + envelope-shaped
// data + `[DONE]` fools the harness (which ignored `event:`) into
// corroborating while the buyer's SDK does NOT see the envelope as
// terminal.
func TestConsumeSSE_ThreadEventForgedEnvelope_232_R10_HIGH(t *testing.T) {
	body := bytes.NewBufferString("event: thread.message.delta\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("event: thread.* + envelope MUST NOT corroborate (SDK routes to Assistants handler) — got true (#232 R10 SEC HIGH)")
	}
	if !r.SawTerminator {
		t.Errorf("trailing [DONE] must still flip SawTerminator")
	}
}

// TestConsumeSSE_ResponseEventForgedEnvelope_232_R10_HIGH:
// SEC R10 HIGH sibling shape — `event: response.*` is the OpenAI
// Responses API prefix, routed through a non-chat-completion handler.
func TestConsumeSSE_ResponseEventForgedEnvelope_232_R10_HIGH(t *testing.T) {
	body := bytes.NewBufferString("event: response.output.item\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"forged\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if r.SawSSEErrorEvent {
		t.Errorf("event: response.* + envelope MUST NOT corroborate — got true (#232 R10 SEC HIGH)")
	}
}

// TestConsumeSSE_ExplicitMessageEventLegit_232_R10:
// happy-path control — `event: message` is the SSE default alias
// and MUST still corroborate a standalone envelope on the chat.
// completions path.
func TestConsumeSSE_ExplicitMessageEventLegit_232_R10(t *testing.T) {
	body := bytes.NewBufferString("event: message\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"legit\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("event: message + envelope MUST corroborate (SSE default alias) — got false")
	}
	if r.SSEErrorCode != "stream_truncated" {
		t.Errorf("SSEErrorCode = %q, want stream_truncated", r.SSEErrorCode)
	}
}

// TestConsumeSSE_EventNameResetsOnDispatch_232_R10:
// per SSE spec, currentEventName resets on blank-line dispatch. A
// prior `event: thread.*` MUST NOT taint the next event's default
// classification.
func TestConsumeSSE_EventNameResetsOnDispatch_232_R10(t *testing.T) {
	body := bytes.NewBufferString("event: thread.message.delta\ndata: {\"choices\":[{\"delta\":{\"content\":\"noise\"}}]}\n\ndata: {\"error\":{\"code\":\"stream_truncated\",\"type\":\"api_error\",\"message\":\"legit\"}}\n\ndata: [DONE]\n\n")
	r := &Result{}
	consumeSSE(body, r)
	if !r.SawSSEErrorEvent {
		t.Errorf("second event (default) with envelope MUST corroborate; event: thread.* on prior event must not taint — got false (#232 R10)")
	}
	if r.SSEErrorCode != "stream_truncated" {
		t.Errorf("SSEErrorCode = %q, want stream_truncated", r.SSEErrorCode)
	}
}
