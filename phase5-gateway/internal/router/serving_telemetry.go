package router

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// SPEC-006-R028 gateway serving telemetry. Every value here is telemetry for
// the demand row only. None of it is sent to the coordinator, so none of it can
// reach the SPEC-002-R005 routing performance store.

const (
	servingOutputBytesPerToken = 4
	servingMinOutputTokens     = 8
	servingMinOutputWindow     = 50 * time.Millisecond
	// servingMaxOutputTPS is the coordinator's PerfMaxDecodeTPS ceiling.
	servingMaxOutputTPS = 2_000
	// servingMaxHeldToolArgumentBytes bounds the tool-call arguments held for
	// canonical re-encoding; arguments past it count at their raw length.
	servingMaxHeldToolArgumentBytes = 1 << 20
	// Choice and tool-call indexes are provider-controlled. Past these bounds
	// choices share one think filter, and new tool calls are counted at their
	// raw length without being stored, so neither map grows with the stream
	// and the work at flush stays bounded. Telemetry-only: a stream past the
	// bounds is classified less exactly, never rejected.
	servingMaxThinkFilters = 16
	servingMaxToolCalls    = 64
	// providerTimingLabelMaxMs bounds a provider-reported timing label.
	providerTimingLabelMaxMs = 3_600_000
)

type servingToolKey struct {
	choice int
	tool   int
}

type servingToolCall struct {
	named     bool
	arguments strings.Builder
}

// servingDeltaObserver classifies upstream Chat Completions deltas into
// reasoning and answer deltas and estimates answer tokens with the same rule
// as the coordinator's SPEC-002-R005 output estimator, applied to answer text
// only.
type servingDeltaObserver struct {
	thinkFilters     map[int]*streamThinkFilter
	firstReasoningAt time.Time
	firstAnswerAt    time.Time
	lastAnswerAt     time.Time
	answerBytes      int64
	toolCalls        map[servingToolKey]*servingToolCall
	heldArgBytes     int64
	rawArgBytes      int64
}

type servingStreamDelta struct {
	Content          *string `json:"content"`
	ReasoningContent *string `json:"reasoning_content"`
	Refusal          *string `json:"refusal"`
	Text             *string `json:"text"`
	FunctionCall     *struct {
		Name      *string `json:"name"`
		Arguments *string `json:"arguments"`
	} `json:"function_call"`
	ToolCalls []struct {
		Index    *int `json:"index"`
		Function *struct {
			Name      *string `json:"name"`
			Arguments *string `json:"arguments"`
		} `json:"function"`
	} `json:"tool_calls"`
}

// streamingChoiceIndex reads a choice index for telemetry only; a missing or
// non-integer index shares the overflow filter.
func streamingChoiceIndex(raw json.RawMessage) int {
	var index int
	if len(raw) == 0 || json.Unmarshal(raw, &index) != nil {
		return -1
	}
	return index
}

func hasNonSpace(s string) bool {
	return strings.TrimSpace(s) != ""
}

// observe classifies one upstream frame from its already-parsed choices.
//
// A reasoning delta has non-whitespace reasoning_content or non-whitespace
// content inside <think>...</think>. An answer delta has non-whitespace
// visible content (outside think tags), non-whitespace refusal or text, or a
// tool call with a name or arguments. Whitespace-only visible text counts
// toward the answer estimate only once an answer delta has been seen.
func (o *servingDeltaObserver) observe(choices []streamingChoiceFrame, at time.Time) {
	reasoning, answer := false, false
	var whitespaceBytes int64
	visibleText := func(s string) {
		if hasNonSpace(s) {
			answer = true
			o.answerBytes += int64(len(s))
		} else {
			whitespaceBytes += int64(len(s))
		}
	}
	for _, choice := range choices {
		if len(choice.Delta) == 0 || bytes.Equal(choice.Delta, []byte("null")) {
			continue
		}
		var delta servingStreamDelta
		if err := json.Unmarshal(choice.Delta, &delta); err != nil {
			continue
		}
		index := streamingChoiceIndex(choice.Index)
		if delta.ReasoningContent != nil && hasNonSpace(*delta.ReasoningContent) {
			reasoning = true
		}
		if delta.Content != nil && *delta.Content != "" {
			filter := o.thinkFilter(index)
			before := filter.thinkInsideTextChunks
			visible := filter.filterThinkContent(*delta.Content)
			if filter.thinkInsideTextChunks > before {
				reasoning = true
			}
			if visible != "" {
				visibleText(visible)
			}
		}
		for _, s := range []*string{delta.Refusal, delta.Text} {
			if s != nil && *s != "" {
				visibleText(*s)
			}
		}
		if fc := delta.FunctionCall; fc != nil {
			if o.recordToolCall(servingToolKey{choice: index, tool: -1}, fc.Name, fc.Arguments) {
				answer = true
			}
		}
		for i, tc := range delta.ToolCalls {
			if tc.Function == nil {
				continue
			}
			key := servingToolKey{choice: index, tool: i}
			if tc.Index != nil {
				key.tool = *tc.Index
			}
			if o.recordToolCall(key, tc.Function.Name, tc.Function.Arguments) {
				answer = true
			}
		}
	}
	if reasoning && o.firstReasoningAt.IsZero() {
		o.firstReasoningAt = at
	}
	if answer {
		if o.firstAnswerAt.IsZero() {
			o.firstAnswerAt = at
		}
		o.lastAnswerAt = at
	}
	if !o.firstAnswerAt.IsZero() {
		o.answerBytes += whitespaceBytes
	}
}

func (o *servingDeltaObserver) thinkFilter(choice int) *streamThinkFilter {
	if o.thinkFilters == nil {
		o.thinkFilters = map[int]*streamThinkFilter{}
	}
	if choice < 0 || choice >= servingMaxThinkFilters {
		choice = -1
	}
	filter := o.thinkFilters[choice]
	if filter == nil {
		filter = &streamThinkFilter{}
		o.thinkFilters[choice] = filter
	}
	return filter
}

// recordToolCall counts a tool call's name once per (choice, index) and holds
// its arguments for canonical re-encoding, within the key and byte bounds.
func (o *servingDeltaObserver) recordToolCall(key servingToolKey, name, arguments *string) bool {
	hasName := name != nil && *name != ""
	hasArguments := arguments != nil && *arguments != ""
	if !hasName && !hasArguments {
		return false
	}
	if o.toolCalls == nil {
		o.toolCalls = map[servingToolKey]*servingToolCall{}
	}
	call := o.toolCalls[key]
	if call == nil {
		if len(o.toolCalls) >= servingMaxToolCalls {
			if hasName {
				o.rawArgBytes += int64(len(*name))
			}
			if hasArguments {
				o.rawArgBytes += int64(len(*arguments))
			}
			return true
		}
		call = &servingToolCall{}
		o.toolCalls[key] = call
	}
	if hasName && !call.named {
		call.named = true
		o.answerBytes += int64(len(*name))
	}
	if hasArguments {
		if o.heldArgBytes+int64(len(*arguments)) > servingMaxHeldToolArgumentBytes {
			o.rawArgBytes += int64(len(*arguments))
		} else {
			call.arguments.WriteString(*arguments)
			o.heldArgBytes += int64(len(*arguments))
		}
	}
	return true
}

// estimatedAnswerTokens applies the coordinator's output-estimate rule
// (generatedOutputTokens) to answer text only: visible answer bytes, each
// tool-call name once, and tool-call arguments at their canonical compact-JSON
// length, divided by 4 and rounded up.
func (o *servingDeltaObserver) estimatedAnswerTokens() int64 {
	n := o.answerBytes + o.rawArgBytes
	if !o.firstAnswerAt.IsZero() {
		for _, filter := range o.thinkFilters {
			n += int64(len(filter.thinkPendingOutside()))
		}
	}
	for _, call := range o.toolCalls {
		n += servingCanonicalArgumentsLen(call.arguments.String())
	}
	return (n + servingOutputBytesPerToken - 1) / servingOutputBytesPerToken
}

// thinkPendingOutside is the held suffix that never became a <think> tag; it
// is answer text once the stream ends.
func (a *streamThinkFilter) thinkPendingOutside() string {
	if a.thinkInBlock {
		return ""
	}
	return a.thinkPending
}

// servingCanonicalArgumentsLen follows the same rule as the coordinator's
// canonicalArgumentsLen: arguments re-encoded as compact JSON with every number in its shortest
// spelling; arguments that are not one JSON value count at their raw length.
func servingCanonicalArgumentsLen(arguments string) int64 {
	dec := json.NewDecoder(strings.NewReader(arguments))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil || dec.More() {
		return int64(len(arguments))
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(servingShortestNumbers(v)); err != nil {
		return int64(len(arguments))
	}
	return int64(len(bytes.TrimRight(buf.Bytes(), "\n")))
}

func servingShortestNumbers(v any) any {
	switch t := v.(type) {
	case json.Number:
		f, err := strconv.ParseFloat(string(t), 64)
		if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
			return json.Number("0")
		}
		return json.Number(strconv.FormatFloat(f, 'g', -1, 64))
	case map[string]any:
		for k, e := range t {
			t[k] = servingShortestNumbers(e)
		}
	case []any:
		for i, e := range t {
			t[i] = servingShortestNumbers(e)
		}
	}
	return v
}

// servingEngineFromRouteTrace returns the engine member of an exact
// SPEC-002-R007 route trace, or "unknown".
func servingEngineFromRouteTrace(h http.Header) string {
	for _, value := range h.Values(routeTraceResponseHeader) {
		trace := buyerVisibleRouteTraceHeader(value)
		if trace == "" {
			continue
		}
		for _, part := range strings.Split(trace, "; ") {
			if engine, ok := strings.CutPrefix(part, "engine="); ok {
				return engine
			}
		}
	}
	return "unknown"
}

func streamingModeFromHeader(h http.Header) string {
	for _, value := range h.Values(streamingModeResponseHeader) {
		if mode := buyerVisibleStreamingModeHeader(value); mode != "" {
			return mode
		}
	}
	return ""
}

// providerTimingLabels are the provider-reported usage timing fields. They
// label a demand row and never enter a gateway quantity or a routing input.
type providerTimingLabels struct {
	queueMS       *int64
	firstTokenMS  *int64
	firstAnswerMS *int64
	decodeMS      *int64
}

func providerTimingLabelsFromJSON(body []byte) (providerTimingLabels, bool) {
	var envelope struct {
		Usage map[string]json.RawMessage `json:"usage"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil || envelope.Usage == nil {
		return providerTimingLabels{}, false
	}
	return providerTimingLabels{
		queueMS:       providerTimingLabel(envelope.Usage["macprovider_queue_ms"]),
		firstTokenMS:  providerTimingLabel(envelope.Usage["macprovider_first_token_ms"]),
		firstAnswerMS: providerTimingLabel(envelope.Usage["macprovider_first_answer_ms"]),
		decodeMS:      providerTimingLabel(envelope.Usage["macprovider_decode_ms"]),
	}, true
}

func providerTimingLabel(raw json.RawMessage) *int64 {
	if len(raw) == 0 {
		return nil
	}
	value, err := strconv.ParseInt(string(bytes.TrimSpace(raw)), 10, 64)
	if err != nil || value < 0 || value > providerTimingLabelMaxMs {
		return nil
	}
	return &value
}

type servingTelemetrySnapshot struct {
	firstReasoningMS     *int64
	firstAnswerMS        *int64
	outputTPSMilliTokens *int64
	streamingMode        string
	servingEngine        string
}

func (t *gatewayPhaseTiming) observeStreamDelta(choices []streamingChoiceFrame, at time.Time) {
	if t == nil {
		return
	}
	t.deltas.observe(choices, at)
}

// servingSnapshot returns the SPEC-006-R028 quantities. All three are absent
// unless the coordinator relayed the stream incrementally.
func (t *gatewayPhaseTiming) servingSnapshot() servingTelemetrySnapshot {
	if t == nil {
		return servingTelemetrySnapshot{servingEngine: "unknown"}
	}
	out := servingTelemetrySnapshot{streamingMode: t.streamingMode, servingEngine: t.servingEngine}
	if out.servingEngine == "" {
		out.servingEngine = "unknown"
	}
	if t.streamingMode != "incremental" {
		return out
	}
	since := func(at time.Time) *int64 {
		if at.IsZero() || at.Before(t.startedAt) {
			return nil
		}
		ms := at.Sub(t.startedAt).Milliseconds()
		return &ms
	}
	out.firstReasoningMS = since(t.deltas.firstReasoningAt)
	out.firstAnswerMS = since(t.deltas.firstAnswerAt)
	window := t.deltas.lastAnswerAt.Sub(t.deltas.firstAnswerAt)
	if tokens := t.deltas.estimatedAnswerTokens(); !t.deltas.firstAnswerAt.IsZero() && tokens >= servingMinOutputTokens && window >= servingMinOutputWindow {
		tps := math.Min(float64(tokens-1)/window.Seconds(), servingMaxOutputTPS)
		milli := int64(tps * 1000)
		out.outputTPSMilliTokens = &milli
	}
	return out
}
