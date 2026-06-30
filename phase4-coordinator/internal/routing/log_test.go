package routing_test

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/rs/zerolog"
)

func decode(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decode log row: %v\nraw=%s", err, string(raw))
	}
	return out
}

func newCapturingLogger() (zerolog.Logger, *bytes.Buffer) {
	buf := &bytes.Buffer{}
	return zerolog.New(buf), buf
}

func TestLogRoutingDecision_EmitsRoutingDecisionEvent(t *testing.T) {
	t.Parallel()
	log, buf := newCapturingLogger()
	routing.LogRoutingDecision(log, routing.Decision{
		RequestID:        "req-1",
		ChosenProviderID: "p-1",
	})
	row := decode(t, buf.Bytes())
	if row["event"] != "routing_decision" {
		t.Errorf("event: want routing_decision, got %v", row["event"])
	}
	if row["request_id"] != "req-1" {
		t.Errorf("request_id: want req-1, got %v", row["request_id"])
	}
	if row["chosen_provider_id"] != "p-1" {
		t.Errorf("chosen_provider_id: want p-1, got %v", row["chosen_provider_id"])
	}
}

func TestLogRoutingDecision_OmitsEmptyOptionalScalars(t *testing.T) {
	// Per SPEC-004 §7 "Required fields where applicable" — empty
	// optional fields SHOULD be omitted rather than emit empty
	// strings, so consumers parse only present fields.
	t.Parallel()
	log, buf := newCapturingLogger()
	routing.LogRoutingDecision(log, routing.Decision{
		RequestID: "req-1",
	})
	row := decode(t, buf.Bytes())
	if _, ok := row["x_request_id"]; ok {
		t.Errorf("x_request_id should be omitted when empty")
	}
	if _, ok := row["resolved_class"]; ok {
		t.Errorf("resolved_class should be omitted when empty")
	}
	if _, ok := row["sticky_miss_reason"]; ok {
		t.Errorf("sticky_miss_reason should be omitted when empty")
	}
	if _, ok := row["retry_reason"]; ok {
		t.Errorf("retry_reason should be omitted when empty")
	}
}

func TestLogRoutingDecision_EmitsLegacyAliasesAlongsideSpec004Names(t *testing.T) {
	// Pre-Phase-D consumers parse 'candidate_count', 'epsilon',
	// 'seed', 'draw', 'reason' at the top level. The log row MUST
	// emit these alongside the new SPEC-004 §7 names
	// (candidate_count_after_filters, tiebreak_epsilon, random_seed,
	// random_draw, tiebreak_mode) so consumers keep working during
	// the migration window. Per D+A R1 audit CODE-H1.
	t.Parallel()
	log, buf := newCapturingLogger()
	routing.LogRoutingDecision(log, routing.Decision{
		RequestID:                  "req-1",
		CandidateCountAfterFilters: 3,
		TiebreakEpsilon:            0.05,
		RandomSeed:                 12345,
		RandomDraw:                 0.42,
		TiebreakMode:               "random_epsilon",
	})
	row := decode(t, buf.Bytes())
	if row["candidate_count"] != float64(3) {
		t.Errorf("legacy candidate_count: want 3, got %v", row["candidate_count"])
	}
	if row["epsilon"] != 0.05 {
		t.Errorf("legacy epsilon: want 0.05, got %v", row["epsilon"])
	}
	if row["seed"] != float64(12345) {
		t.Errorf("legacy seed: want 12345, got %v", row["seed"])
	}
	if row["draw"] != 0.42 {
		t.Errorf("legacy draw: want 0.42, got %v", row["draw"])
	}
	if row["reason"] != "randomized" {
		t.Errorf("legacy reason: want randomized (mapped from random_epsilon), got %v", row["reason"])
	}
	// And the new SPEC-004 §7 names alongside.
	if row["tiebreak_mode"] != "random_epsilon" {
		t.Errorf("new tiebreak_mode: want random_epsilon, got %v", row["tiebreak_mode"])
	}
	if row["random_seed"] != float64(12345) {
		t.Errorf("new random_seed: want 12345, got %v", row["random_seed"])
	}
}

func TestProviderToCandidateLogEntry_PreservesLegacyAliases(t *testing.T) {
	// Per D+A R1 audit SEC-L1: pre-Phase-D consumers parsed
	// slots_free / slots_total / throughput_tps / metric per
	// candidate. Strict-superset preservation required.
	t.Parallel()
	p := pool.Provider{
		ProviderID:            "p-1",
		ThroughputTPSEstimate: 100,
		SlotsFree:             3,
		SlotsTotal:            5,
		Tier:                  pool.TierPinned,
		ConnectedAt:           time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC),
	}
	w := routing.DefaultWeights()
	entry := routing.ProviderToCandidateLogEntry(p, 0.85, w)
	if entry.SlotsFree != 3 {
		t.Errorf("legacy slots_free: want 3, got %d", entry.SlotsFree)
	}
	if entry.SlotsTotal != 5 {
		t.Errorf("legacy slots_total: want 5, got %d", entry.SlotsTotal)
	}
	if entry.ThroughputTPS != 100 {
		t.Errorf("legacy throughput_tps: want 100, got %v", entry.ThroughputTPS)
	}
	if entry.Metric != 0.85 {
		t.Errorf("legacy metric: want 0.85, got %v", entry.Metric)
	}
}

func TestLogRoutingDecision_EmitsFullSpec004Section7Fields(t *testing.T) {
	t.Parallel()
	log, buf := newCapturingLogger()
	routing.LogRoutingDecision(log, routing.Decision{
		RequestID:                   "req-1",
		ExternalRequestID:           "ext-XYZ",
		RequestedModel:              "model-A",
		ResolvedModelType:           "class",
		ResolvedClass:               "fast-class",
		ClassModels:                 []string{"model-A", "model-B"},
		Objective:                   "fast",
		HardPinType:                 "none",
		StickyResult:                "hit",
		StickyMissReason:            "",
		CandidateCountBeforeFilters: 5,
		CandidateCountAfterFilters:  2,
		FilteredCounts:              map[string]int{"breaker_held": 1, "context_too_small": 2},
		CandidateSet: []routing.CandidateLogEntry{
			{ProviderID: "p-1", AssignedID: "s-1", ObjectiveMetric: 100.0, State: "ready",
				Slots: 4, EffectiveThroughput: 100.0, ModelParams: 70, ConnectedAt: "2026-06-30T00:00:00.000Z", Tier: "pinned"},
		},
		TiebreakMode:     "random_epsilon",
		TiebreakEpsilon:  0.05,
		RandomSeed:       12345,
		RandomDraw:       0.42,
		ChosenProviderID: "p-1",
		ChosenAssignedID: "s-1",
		AttemptIndex:     2,
		RetryCount:       1,
		RetryReason:      "breaker_tripped",
		Retried:          1,
		PreflightResult:  "accepted",
	})
	row := decode(t, buf.Bytes())
	wantFields := []string{
		"event", "request_id", "x_request_id", "requested_model",
		"resolved_model_type", "resolved_class", "class_models",
		"objective", "hard_pin_type", "sticky_result",
		"candidate_count_before_filters", "candidate_count_after_filters",
		"filtered_counts", "candidate_set",
		"tiebreak_mode", "tiebreak_epsilon", "random_seed", "random_draw",
		"chosen_provider_id", "chosen_assigned_id",
		"attempt_index", "retry_count", "retry_reason", "retried",
		"preflight_result",
	}
	for _, f := range wantFields {
		if _, ok := row[f]; !ok {
			t.Errorf("SPEC-004 §7 field missing from log row: %q", f)
		}
	}
}

func TestLogRoutingDecision_RandomSeedAndDrawOnlyWhenRandomEpsilon(t *testing.T) {
	t.Parallel()
	log, buf := newCapturingLogger()
	routing.LogRoutingDecision(log, routing.Decision{
		RequestID:    "req-1",
		TiebreakMode: "deterministic",
		RandomSeed:   12345,
		RandomDraw:   0.42,
	})
	row := decode(t, buf.Bytes())
	if _, ok := row["random_seed"]; ok {
		t.Errorf("deterministic mode: random_seed must be omitted")
	}
	if _, ok := row["random_draw"]; ok {
		t.Errorf("deterministic mode: random_draw must be omitted")
	}
}

func TestProviderToCandidateLogEntry_PopulatesAllFields(t *testing.T) {
	t.Parallel()
	p := pool.Provider{
		ProviderID:            "p-1",
		AssignedID:            "s-1",
		State:                 "ready",
		SlotsFree:             3,
		ThroughputTPSEstimate: 100,
		ModelParamsB:          70,
		Tier:                  pool.TierPinned,
		ConnectedAt:           time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC),
	}
	w := routing.DefaultWeights()
	entry := routing.ProviderToCandidateLogEntry(p, 42.5, w)
	if entry.ProviderID != "p-1" || entry.AssignedID != "s-1" {
		t.Errorf("ids: got %+v", entry)
	}
	if entry.ObjectiveMetric != 42.5 {
		t.Errorf("ObjectiveMetric: want 42.5, got %v", entry.ObjectiveMetric)
	}
	if entry.EffectiveThroughput != 100.0 {
		t.Errorf("EffectiveThroughput (pinned 100*1.0): want 100, got %v", entry.EffectiveThroughput)
	}
	if entry.State != "ready" {
		t.Errorf("State: want ready, got %v", entry.State)
	}
	if entry.Slots != 3 {
		t.Errorf("Slots: want 3, got %v", entry.Slots)
	}
	if entry.ModelParams != 70 {
		t.Errorf("ModelParams: want 70, got %v", entry.ModelParams)
	}
	if entry.Tier != "pinned" {
		t.Errorf("Tier: want pinned, got %v", entry.Tier)
	}
	if entry.ConnectedAt != "2026-06-30T12:00:00.000Z" {
		t.Errorf("ConnectedAt: want UTC ISO, got %v", entry.ConnectedAt)
	}
}
