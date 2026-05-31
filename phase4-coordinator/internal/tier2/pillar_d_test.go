package tier2

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestPillarDInactivePreservesStreamingAndBodyExactly(t *testing.T) {
	cfg := config.Default().Tier2
	cfg.EncodingValidationEnabled = true
	cfg.OutputSizeCapBytes = 1
	guard := NewPillarDGuard(cfg, "req", pool.Provider{}, zerolog.Nop())
	streaming := "data: not-json\n\n"
	body := []byte(`not-json`)

	gotStreaming, stop, err := guard.CheckStreamingChunk(streaming)
	if err != nil || stop || gotStreaming != streaming {
		t.Fatalf("streaming got=%q stop=%t err=%v", gotStreaming, stop, err)
	}
	gotBody, err := guard.CheckNonStreamingBody(body)
	if err != nil || !bytes.Equal(gotBody, body) {
		t.Fatalf("body got=%q err=%v", string(gotBody), err)
	}
}

func TestPillarDACD1StreamingASCIIExactCap(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default().Tier2
	cfg.BehavioralSafetyEnabled = true
	cfg.OutputSizeCapBytes = 32
	guard := NewPillarDGuard(cfg, "req", pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a"}, zerolog.New(&logs))

	got, stop, err := guard.CheckStreamingChunk("data: {\"choices\":[{\"delta\":{\"content\":\"" + strings.Repeat("a", 64) + "\"}}]}\n\n")
	if err != nil {
		t.Fatalf("CheckStreamingChunk: %v", err)
	}
	if !stop {
		t.Fatal("stop=false, want true after cap")
	}
	if content := streamingContent(t, got); content != strings.Repeat("a", 32) {
		t.Fatalf("forwarded completion bytes=%d content=%q", len(content), content)
	}
	if !strings.HasSuffix(got, "data: [DONE]\n\n") {
		t.Fatalf("truncated stream wrong: %q", got)
	}
	for _, want := range []string{`"event":"oversized_completion_truncated"`, `"configured_cap_bytes":32`, `"emitted_bytes":32`} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("missing log field %s: %s", want, logs.String())
		}
	}
}

func TestPillarDACD2StreamingCapPrefersValidUTF8(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default().Tier2
	cfg.BehavioralSafetyEnabled = true
	cfg.OutputSizeCapBytes = 4
	guard := NewPillarDGuard(cfg, "req", pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a"}, zerolog.New(&logs))

	got, stop, err := guard.CheckStreamingChunk("data: {\"choices\":[{\"delta\":{\"content\":\"hi世\"}}]}\n\n")
	if err != nil {
		t.Fatalf("CheckStreamingChunk: %v", err)
	}
	if !stop {
		t.Fatal("stop=false, want true after UTF-8 truncation")
	}
	if content := streamingContent(t, got); content != "hi" {
		t.Fatalf("content=%q want complete UTF-8 prefix", content)
	}
	for _, want := range []string{`"configured_cap_bytes":4`, `"emitted_bytes":2`} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("missing log field %s: %s", want, logs.String())
		}
	}
}

func TestPillarDNonStreamingCapReturnsValidJSON(t *testing.T) {
	cfg := config.Default().Tier2
	cfg.BehavioralSafetyEnabled = true
	cfg.OutputSizeCapBytes = 4
	guard := NewPillarDGuard(cfg, "req", pool.Provider{}, zerolog.Nop())

	got, err := guard.CheckNonStreamingBody([]byte(`{"choices":[{"message":{"content":"hello"}}]}`))
	if err != nil {
		t.Fatalf("CheckNonStreamingBody: %v", err)
	}
	if !json.Valid(got) {
		t.Fatalf("truncated body is not JSON: %s", string(got))
	}
	if !strings.Contains(string(got), `"content":"hell"`) {
		t.Fatalf("truncated body wrong: %s", string(got))
	}
}

func TestPillarDEncodingValidationRejectsForbiddenControl(t *testing.T) {
	var logs bytes.Buffer
	cfg := config.Default().Tier2
	cfg.BehavioralSafetyEnabled = true
	cfg.EncodingValidationEnabled = true
	guard := NewPillarDGuard(cfg, "req", pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a"}, zerolog.New(&logs))

	_, err := guard.CheckNonStreamingBody([]byte(`{"choices":[{"message":{"content":"bad\u0000"}}]}`))
	if err == nil || !strings.Contains(err.Error(), "forbidden_control_character") {
		t.Fatalf("err=%v, want forbidden control rejection", err)
	}
	if !strings.Contains(logs.String(), `"event":"output_encoding_rejected"`) {
		t.Fatalf("missing rejection log: %s", logs.String())
	}
}

func TestPillarDACD3RejectsInvalidUTF8BeforeCommit(t *testing.T) {
	cfg := config.Default().Tier2
	cfg.BehavioralSafetyEnabled = true
	cfg.EncodingValidationEnabled = true
	guard := NewPillarDGuard(cfg, "req", pool.Provider{}, zerolog.Nop())

	_, _, err := guard.CheckStreamingChunk(string([]byte{'d', 'a', 't', 'a', ':', ' ', 0xff, '\n', '\n'}))
	if err == nil || !strings.Contains(err.Error(), "invalid_utf8") {
		t.Fatalf("err=%v, want invalid_utf8 rejection", err)
	}
}

func TestPillarDACD5TTFTAnomalyWarnsWithoutRejecting(t *testing.T) {
	cfg := config.Default().Tier2
	cfg.BehavioralSafetyEnabled = true
	cfg.ResponseTimeAnomalyEnabled = true
	cfg.ResponseTimeAnomalyFactor = 5.0
	cfg.ResponseTimeAnomalyMinMS = 0

	var noBaseline bytes.Buffer
	NewPillarDGuard(cfg, "req", pool.Provider{ProviderID: "p1"}, zerolog.New(&noBaseline)).LogTTFT(5001 * time.Millisecond)
	if noBaseline.Len() != 0 {
		t.Fatalf("logged without provider baseline: %s", noBaseline.String())
	}

	var logs bytes.Buffer
	provider := pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", ModelLoadTimeMs: 1000}
	guard := NewPillarDGuard(cfg, "req", provider, zerolog.New(&logs))
	guard.LogTTFT(5001 * time.Millisecond)
	got, stop, err := guard.CheckStreamingChunk("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")
	if err != nil || stop || got == "" {
		t.Fatalf("TTFT must not reject response: got=%q stop=%t err=%v", got, stop, err)
	}
	if !strings.Contains(logs.String(), `"event":"response_time_anomaly"`) {
		t.Fatalf("missing TTFT anomaly log: %s", logs.String())
	}
}

func streamingContent(t *testing.T, data string) string {
	t.Helper()
	for _, line := range strings.Split(data, "\n") {
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		var resp struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(payload), &resp); err != nil {
			t.Fatalf("stream payload json: %v payload=%s", err, payload)
		}
		if len(resp.Choices) == 0 {
			t.Fatalf("no choices in payload=%s", payload)
		}
		return resp.Choices[0].Delta.Content
	}
	t.Fatalf("no data payload in %q", data)
	return ""
}
