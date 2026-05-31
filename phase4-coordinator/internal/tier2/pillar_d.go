package tier2

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

const pillarDPhase = 3

type PillarDRejectError struct {
	Reason string
}

func (e *PillarDRejectError) Error() string {
	return "tier2 output encoding invalid: " + e.Reason
}

type PillarDGuard struct {
	cfg         config.Tier2Config
	requestID   string
	provider    pool.Provider
	logger      zerolog.Logger
	outputBytes int64
	capClosed   bool
}

func NewPillarDGuard(cfg config.Tier2Config, requestID string, provider pool.Provider, logger zerolog.Logger) *PillarDGuard {
	return &PillarDGuard{
		cfg:       cfg,
		requestID: requestID,
		provider:  provider,
		logger:    logger,
	}
}

func BehavioralSafetyActive(cfg config.Tier2Config) bool {
	return cfg.BehavioralSafetyEnabled
}

func BehavioralSafetyState(cfg config.Tier2Config) string {
	if !cfg.BehavioralSafetyEnabled {
		return "none"
	}
	if cfg.OutputSizeCapBytes <= 0 && !cfg.EncodingValidationEnabled && !cfg.ResponseTimeAnomalyEnabled {
		return "none"
	}
	if cfg.OutputSizeCapBytes > 0 && cfg.EncodingValidationEnabled && cfg.ResponseTimeAnomalyEnabled {
		return "enforced"
	}
	return "partial"
}

func (g *PillarDGuard) Active() bool {
	return g != nil && BehavioralSafetyActive(g.cfg)
}

func (g *PillarDGuard) CheckStreamingChunk(data string) (string, bool, error) {
	if !g.Active() {
		return data, false, nil
	}
	needsOutputCheck := g.cfg.EncodingValidationEnabled || g.cfg.OutputSizeCapBytes > 0
	if !needsOutputCheck {
		return data, false, nil
	}
	if !utf8.ValidString(data) {
		if !g.cfg.EncodingValidationEnabled {
			return data, false, nil
		}
		return "", false, g.reject("invalid_utf8", "tier2.encoding_validation_enabled")
	}
	events, err := parseSSEDataEvents(data)
	if err != nil {
		if !g.cfg.EncodingValidationEnabled {
			return data, false, nil
		}
		return "", false, g.reject(err.Error(), "tier2.encoding_validation_enabled")
	}

	changed := false
	stop := false
	for i := range events {
		if events[i].Done {
			continue
		}
		payload := events[i].Payload
		doc, err := decodeCompletionPayload(payload)
		if err != nil {
			if g.cfg.EncodingValidationEnabled {
				return "", false, g.reject("invalid_json", "tier2.encoding_validation_enabled")
			}
			continue
		}
		if g.cfg.EncodingValidationEnabled {
			if reason, ok := forbiddenCompletionControl(doc); ok {
				return "", false, g.reject(reason, "tier2.encoding_validation_enabled")
			}
		}
		if g.cfg.OutputSizeCapBytes > 0 {
			truncated := g.enforceOutputCap(doc)
			if truncated {
				raw, err := json.Marshal(doc)
				if err != nil {
					return "", false, err
				}
				events[i].Payload = string(raw)
				events = events[:i+1]
				changed = true
				stop = true
				g.logEvent("oversized_completion_truncated", "WARN", "truncate", "output_size_cap_exceeded", "tier2.output_size_cap_bytes")
				break
			}
		}
	}
	if !changed {
		return data, false, nil
	}
	return renderSSEDataEvents(events, stop), stop, nil
}

func (g *PillarDGuard) CheckNonStreamingBody(body []byte) ([]byte, error) {
	if !g.Active() {
		return body, nil
	}
	needsOutputCheck := g.cfg.EncodingValidationEnabled || g.cfg.OutputSizeCapBytes > 0
	if !needsOutputCheck {
		return body, nil
	}
	if !utf8.Valid(body) {
		if !g.cfg.EncodingValidationEnabled {
			return body, nil
		}
		return nil, g.reject("invalid_utf8", "tier2.encoding_validation_enabled")
	}
	doc, err := decodeCompletionPayload(string(body))
	if err != nil {
		if g.cfg.EncodingValidationEnabled {
			return nil, g.reject("invalid_json", "tier2.encoding_validation_enabled")
		}
		return body, nil
	}
	if g.cfg.EncodingValidationEnabled {
		if reason, ok := forbiddenCompletionControl(doc); ok {
			return nil, g.reject(reason, "tier2.encoding_validation_enabled")
		}
	}
	if g.cfg.OutputSizeCapBytes <= 0 {
		return body, nil
	}
	if !g.enforceOutputCap(doc) {
		return body, nil
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		return nil, err
	}
	g.logEvent("oversized_completion_truncated", "WARN", "truncate", "output_size_cap_exceeded", "tier2.output_size_cap_bytes")
	return raw, nil
}

func (g *PillarDGuard) LogTTFT(ttft time.Duration) {
	if !g.Active() || !g.cfg.ResponseTimeAnomalyEnabled || g.provider.ModelLoadTimeMs <= 0 {
		return
	}
	ttftMS := ttft.Milliseconds()
	baselineMS := g.provider.ModelLoadTimeMs
	thresholdMS := int64(float64(baselineMS) * g.cfg.ResponseTimeAnomalyFactor)
	if minMS := int64(g.cfg.ResponseTimeAnomalyMinMS); thresholdMS < minMS {
		thresholdMS = minMS
	}
	if ttftMS <= thresholdMS {
		return
	}
	g.logger.Warn().
		Str("event", "response_time_anomaly").
		Str("category", "T2.D").
		Str("severity", "WARN").
		Str("request_id", g.requestID).
		Str("provider_id", g.provider.ProviderID).
		Str("assigned_id", g.provider.AssignedID).
		Str("model_id", g.provider.ModelID).
		Int("tier2_phase", pillarDPhase).
		Str("pillar", "D").
		Int64("ttft_ms", ttftMS).
		Int64("baseline_ms", baselineMS).
		Int64("threshold_ms", thresholdMS).
		Str("decision", "observe").
		Str("reason", "ttft_above_baseline").
		Str("config_flag", "tier2.response_time_anomaly_enabled").
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 behavioral safety event")
}

type sseDataEvent struct {
	Payload string
	Done    bool
}

func parseSSEDataEvents(data string) ([]sseDataEvent, error) {
	var events []sseDataEvent
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			return nil, fmt.Errorf("invalid_sse")
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" {
			return nil, fmt.Errorf("invalid_sse")
		}
		events = append(events, sseDataEvent{Payload: payload, Done: payload == "[DONE]"})
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("invalid_sse")
	}
	return events, nil
}

func renderSSEDataEvents(events []sseDataEvent, stop bool) string {
	var out strings.Builder
	for _, event := range events {
		if event.Done {
			out.WriteString("data: [DONE]\n\n")
			continue
		}
		out.WriteString("data: ")
		out.WriteString(event.Payload)
		out.WriteString("\n\n")
	}
	if stop {
		out.WriteString("data: [DONE]\n\n")
	}
	return out.String()
}

func decodeCompletionPayload(payload string) (map[string]any, error) {
	var doc map[string]any
	if err := json.Unmarshal([]byte(payload), &doc); err != nil {
		return nil, err
	}
	return doc, nil
}

func (g *PillarDGuard) enforceOutputCap(doc map[string]any) bool {
	choices, ok := doc["choices"].([]any)
	if !ok {
		return false
	}
	truncated := false
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if g.capChoiceContent(choice, "text") {
			truncated = true
		}
		for _, key := range []string{"delta", "message"} {
			container, ok := choice[key].(map[string]any)
			if !ok {
				continue
			}
			if g.capChoiceContent(container, "content") {
				truncated = true
			}
		}
	}
	return truncated
}

func (g *PillarDGuard) capChoiceContent(container map[string]any, key string) bool {
	content, ok := container[key].(string)
	if !ok || content == "" {
		return false
	}
	if g.capClosed {
		container[key] = ""
		return true
	}
	capBytes := g.cfg.OutputSizeCapBytes
	remaining := capBytes - g.outputBytes
	if remaining <= 0 {
		container[key] = ""
		g.capClosed = true
		return true
	}
	contentBytes := int64(len(content))
	if contentBytes <= remaining {
		g.outputBytes += contentBytes
		if g.outputBytes >= capBytes {
			g.capClosed = true
			return true
		}
		return false
	}
	truncated := truncateUTF8(content, remaining)
	container[key] = truncated
	g.outputBytes += int64(len(truncated))
	g.capClosed = true
	return true
}

func truncateUTF8(value string, maxBytes int64) string {
	if maxBytes <= 0 {
		return ""
	}
	if int64(len(value)) <= maxBytes {
		return value
	}
	var b strings.Builder
	for _, r := range value {
		next := b.Len() + utf8.RuneLen(r)
		if int64(next) > maxBytes {
			break
		}
		b.WriteRune(r)
	}
	return b.String()
}

func forbiddenCompletionControl(doc map[string]any) (string, bool) {
	choices, ok := doc["choices"].([]any)
	if !ok {
		return "", false
	}
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if reason, ok := forbiddenControlInChoiceField(choice, "text"); ok {
			return reason, true
		}
		for _, key := range []string{"delta", "message"} {
			container, ok := choice[key].(map[string]any)
			if !ok {
				continue
			}
			if reason, ok := forbiddenControlInChoiceField(container, "content"); ok {
				return reason, true
			}
		}
	}
	return "", false
}

func forbiddenControlInChoiceField(container map[string]any, key string) (string, bool) {
	content, ok := container[key].(string)
	if !ok {
		return "", false
	}
	for _, r := range content {
		if forbiddenControl(r) {
			return "forbidden_control_character", true
		}
	}
	return "", false
}

func forbiddenControl(r rune) bool {
	if r == '\t' || r == '\n' || r == '\r' {
		return false
	}
	return (r >= 0 && r < 0x20) || r == 0x7f || (r >= 0x80 && r <= 0x9f)
}

func (g *PillarDGuard) reject(reason, configFlag string) error {
	g.logEvent("output_encoding_rejected", "WARN", "reject", reason, configFlag)
	return &PillarDRejectError{Reason: reason}
}

func (g *PillarDGuard) logEvent(event, severity, decision, reason, configFlag string) {
	g.logger.WithLevel(levelForSeverity(severity)).
		Str("event", event).
		Str("category", "T2.D").
		Str("severity", severity).
		Str("request_id", g.requestID).
		Str("provider_id", g.provider.ProviderID).
		Str("assigned_id", g.provider.AssignedID).
		Str("model_id", g.provider.ModelID).
		Int("tier2_phase", pillarDPhase).
		Str("pillar", "D").
		Int64("configured_cap_bytes", g.cfg.OutputSizeCapBytes).
		Int64("emitted_bytes", g.outputBytes).
		Bool("encoding_validation_enabled", g.cfg.EncodingValidationEnabled).
		Str("decision", decision).
		Str("reason", reason).
		Str("config_flag", configFlag).
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 behavioral safety event")
}
