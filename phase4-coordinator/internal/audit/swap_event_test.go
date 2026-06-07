package audit

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestBuildSwapPayloadIncludes8RequiredKeys(t *testing.T) {
	payload := buildPayloadMap(t, validSwapEvent())

	for _, key := range []string{
		"event",
		"ts",
		"provider_assigned_id",
		"from_model_id",
		"to_model_id",
		"to_model_hash",
		"loading_window_ms",
		"hash_verification_result",
	} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("missing required key %q in %#v", key, payload)
		}
	}
	if payload["event"] != "operator_model_swap" {
		t.Fatalf("event=%#v", payload["event"])
	}
	if _, ok := payload["ts"].(string); !ok {
		t.Fatalf("ts type=%T want string", payload["ts"])
	}
	if _, ok := payload["provider_assigned_id"].(string); !ok {
		t.Fatalf("provider_assigned_id type=%T want string", payload["provider_assigned_id"])
	}
	if _, ok := payload["from_model_id"].(string); !ok {
		t.Fatalf("from_model_id type=%T want string", payload["from_model_id"])
	}
	if payload["from_model_hash"] != "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12" {
		t.Fatalf("from_model_hash=%#v", payload["from_model_hash"])
	}
	if _, ok := payload["to_model_id"].(string); !ok {
		t.Fatalf("to_model_id type=%T want string", payload["to_model_id"])
	}
	if _, ok := payload["to_model_hash"].(string); !ok {
		t.Fatalf("to_model_hash type=%T want string", payload["to_model_hash"])
	}
	if _, ok := payload["loading_window_ms"].(float64); !ok {
		t.Fatalf("loading_window_ms type=%T want JSON number", payload["loading_window_ms"])
	}
	if _, ok := payload["hash_verification_result"].(string); !ok {
		t.Fatalf("hash_verification_result type=%T want string", payload["hash_verification_result"])
	}
	if _, ok := payload["drain_inflight_count_estimate"]; ok {
		t.Fatalf("drain_inflight_count_estimate must be omitted: %#v", payload)
	}
}

func TestBuildSwapPayloadOmitsEmptyFromModelHash(t *testing.T) {
	event := validSwapEvent()
	event.FromModelHash = ""
	payload := buildPayloadMap(t, event)
	if _, ok := payload["from_model_hash"]; ok {
		t.Fatalf("from_model_hash present with empty source: %#v", payload)
	}
}

func TestBuildSwapPayloadTopLevelKeyAllowlist(t *testing.T) {
	payload := buildPayloadMap(t, validSwapEvent())
	allowed := map[string]bool{
		"event":                    true,
		"ts":                       true,
		"provider_assigned_id":     true,
		"from_model_id":            true,
		"from_model_hash":          true,
		"to_model_id":              true,
		"to_model_hash":            true,
		"loading_window_ms":        true,
		"hash_verification_result": true,
	}
	for key := range payload {
		if !allowed[key] {
			t.Fatalf("unexpected top-level key %q in %#v", key, payload)
		}
	}
}

func TestBuildSwapPayloadTSIsRFC3339UTC(t *testing.T) {
	payload := buildPayloadMap(t, validSwapEvent())
	rawTS, ok := payload["ts"].(string)
	if !ok {
		t.Fatalf("ts type=%T want string", payload["ts"])
	}
	parsed, err := time.Parse(time.RFC3339, rawTS)
	if err != nil {
		t.Fatalf("parse ts %q: %v", rawTS, err)
	}
	if parsed.Location() != time.UTC {
		t.Fatalf("ts location=%v want UTC", parsed.Location())
	}
}

func TestSwapEventPayloadEnforcesF15Invariants(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	event := validSwapEvent()
	event.AssignedID = "assigned-account_id"
	event.FromModelID = "mlx/conv:evil"
	event.FromModelHash = "account_id"
	event.ToModelID = "account_id/x"
	event.ToModelHash = "conv:bad"
	event.HashVerificationResult = pool.HashStatus("account_id")

	err := store.EmitSwap(context.Background(), event)
	assertErrorContains(t, err, "F-1.5")
	if got := countAuditRows(t, store); got != 0 {
		t.Fatalf("audit rows=%d want 0", got)
	}
}

func TestLoadingWindowMillisZeroLoadingStartedAt(t *testing.T) {
	event := validSwapEvent()
	event.LoadingStartedAt = time.Time{}
	if got := loadingWindowMillis(event); got != 0 {
		t.Fatalf("loadingWindowMillis=%d want 0", got)
	}
}

func TestLoadingWindowMillisComputesCorrectDuration(t *testing.T) {
	t0 := time.Date(2026, 6, 7, 14, 23, 9, 0, time.UTC)
	event := validSwapEvent()
	event.LoadingStartedAt = t0
	event.CompletedAt = t0.Add(18243 * time.Millisecond)
	if got := loadingWindowMillis(event); got != 18243 {
		t.Fatalf("loadingWindowMillis=%d want 18243", got)
	}
}

func buildPayloadMap(t *testing.T, event pool.SwapEvent) map[string]any {
	t.Helper()
	raw, err := buildSwapPayload(event)
	if err != nil {
		t.Fatalf("build payload: %v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	return payload
}

func validSwapEvent() pool.SwapEvent {
	loadingStartedAt := time.Date(2026, 6, 7, 14, 22, 50, 757000000, time.UTC)
	return pool.SwapEvent{
		ProviderID:             "provider-a",
		AssignedID:             "p_01HK4Z3VYE",
		FromModelID:            "mlx-community/Qwen2.5-7B-Instruct-4bit",
		FromModelHash:          "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12",
		ToModelID:              "mlx-community/Llama-3.1-8B-Instruct-4bit",
		ToModelHash:            "cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12ab12",
		HashVerificationResult: pool.HashStatusVerified,
		LoadingStartedAt:       loadingStartedAt,
		CompletedAt:            loadingStartedAt.Add(18243 * time.Millisecond),
	}
}
