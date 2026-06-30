package routing

import (
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// Decision is the SPEC-004 §7 / FR-SR-17 routing-decision log
// payload. Every field listed here maps to a SPEC-004 §7 required
// field (the BUILD prompt's Phase D log block names them
// verbatim). Fields not applicable to a given decision SHOULD be
// left at their zero value; LogRoutingDecision omits zero-valued
// scalar fields where SPEC-004 §7 allows ("Required fields where
// applicable").
//
// Per SPEC-004 §7 closing paragraph, Pillar D's reproducibility
// requirement is satisfied ONLY if randomized candidate set,
// metrics, epsilon, and selected provider are present in logs for
// every randomized selection. RandomSeed + RandomDraw MUST be
// populated when TiebreakMode == "random_epsilon"; the values MUST
// be derivable from RequestID + a daily key (NEVER from time.Now
// alone) so audit replay can reproduce the chosen index.
type Decision struct {
	RequestID                   string
	ExternalRequestID           string // X-Request-ID buyer header, empty if absent
	RequestedModel              string
	ResolvedModelType           string // "exact" or "class"
	ResolvedClass               string // when ResolvedModelType == "class"
	ClassModels                 []string
	Objective                   string // "default" / "fast" / "accurate" / "balanced"
	HardPinType                 string // "none" / "provider" / "session"
	StickyResult                string // "disabled" / "no_key" / "hit" / "miss" / "updated" / "evicted"
	StickyMissReason            string // when StickyResult == "miss"
	CandidateCountBeforeFilters int
	CandidateCountAfterFilters  int
	FilteredCounts              map[string]int // keyed by reason: model_mismatch / not_ready / warming / breaker_held / busy / context_too_small / quota_blocked / excluded_retry
	CandidateSet                []CandidateLogEntry
	TiebreakMode                string // "deterministic" or "random_epsilon"
	TiebreakEpsilon             float64
	RandomSeed                  int64   // populated when TiebreakMode == "random_epsilon"
	RandomDraw                  float64 // populated when TiebreakMode == "random_epsilon"
	ChosenProviderID            string
	ChosenAssignedID            string
	AttemptIndex                int
	RetryCount                  int
	RetryReason                 string
	Retried                     int // count of additional provider attempts beyond the first per SPEC-004 §7 + request_log.retried column write contract
	PreflightResult             string
}

// CandidateLogEntry is the per-candidate metadata in
// Decision.CandidateSet — SPEC-004 §7 explainability surface.
// Every field name matches SPEC-004 §7 verbatim so log consumers
// parse a stable shape.
type CandidateLogEntry struct {
	ProviderID          string  `json:"provider_id"`
	AssignedID          string  `json:"assigned_id"`
	ObjectiveMetric     float64 `json:"objective_metric"`
	State               string  `json:"state"`
	Slots               int     `json:"slots"`
	EffectiveThroughput float64 `json:"effective_throughput"`
	ModelParams         float64 `json:"model_params"`
	ConnectedAt         string  `json:"connected_at"`
	Tier                string  `json:"tier"`
}

// LogRoutingDecision emits one zerolog Info row with the SPEC-004
// §7 routing-decision event. Per SPEC-004 §7: "Every routed
// request SHOULD produce a structured routing-decision log."
// Callers fire this AFTER candidate selection AND at each retry /
// preflight attempt so AttemptIndex / RetryCount / RetryReason /
// PreflightResult reflect the current attempt.
func LogRoutingDecision(log zerolog.Logger, d Decision) {
	event := log.Info().Str("event", "routing_decision")
	if d.RequestID != "" {
		event = event.Str("request_id", d.RequestID)
	}
	if d.ExternalRequestID != "" {
		event = event.Str("x_request_id", d.ExternalRequestID)
	}
	if d.RequestedModel != "" {
		event = event.Str("requested_model", d.RequestedModel)
	}
	if d.ResolvedModelType != "" {
		event = event.Str("resolved_model_type", d.ResolvedModelType)
	}
	if d.ResolvedClass != "" {
		event = event.Str("resolved_class", d.ResolvedClass)
	}
	if len(d.ClassModels) > 0 {
		event = event.Strs("class_models", d.ClassModels)
	}
	if d.Objective != "" {
		event = event.Str("objective", d.Objective)
	}
	if d.HardPinType != "" {
		event = event.Str("hard_pin_type", d.HardPinType)
	}
	if d.StickyResult != "" {
		event = event.Str("sticky_result", d.StickyResult)
	}
	if d.StickyMissReason != "" {
		event = event.Str("sticky_miss_reason", d.StickyMissReason)
	}
	event = event.
		Int("candidate_count_before_filters", d.CandidateCountBeforeFilters).
		Int("candidate_count_after_filters", d.CandidateCountAfterFilters)
	if len(d.FilteredCounts) > 0 {
		event = event.Interface("filtered_counts", d.FilteredCounts)
	}
	if len(d.CandidateSet) > 0 {
		event = event.Interface("candidate_set", d.CandidateSet)
	}
	if d.TiebreakMode != "" {
		event = event.Str("tiebreak_mode", d.TiebreakMode)
	}
	event = event.Float64("tiebreak_epsilon", d.TiebreakEpsilon)
	if d.TiebreakMode == "random_epsilon" {
		event = event.Int64("random_seed", d.RandomSeed).Float64("random_draw", d.RandomDraw)
	}
	if d.ChosenProviderID != "" {
		event = event.Str("chosen_provider_id", d.ChosenProviderID)
	}
	if d.ChosenAssignedID != "" {
		event = event.Str("chosen_assigned_id", d.ChosenAssignedID)
	}
	event = event.
		Int("attempt_index", d.AttemptIndex).
		Int("retry_count", d.RetryCount)
	if d.RetryReason != "" {
		event = event.Str("retry_reason", d.RetryReason)
	}
	event = event.Int("retried", d.Retried)
	if d.PreflightResult != "" {
		event = event.Str("preflight_result", d.PreflightResult)
	}
	event.Msg("routing decision")
}

// ProviderToCandidateLogEntry converts a pool.Provider to the
// per-candidate log shape, sourcing each metric from the SPEC-002
// + SPEC-004 canonical fields. Caller supplies the objective-driven
// score (caller computes it because the routing helpers only know
// pure metric formulas, not per-objective dispatch).
func ProviderToCandidateLogEntry(p pool.Provider, objectiveMetric float64, weights Weights) CandidateLogEntry {
	return CandidateLogEntry{
		ProviderID:          p.ProviderID,
		AssignedID:          p.AssignedID,
		ObjectiveMetric:     objectiveMetric,
		State:               string(p.State),
		Slots:               p.SlotsFree,
		EffectiveThroughput: EffectiveThroughput(p, weights),
		ModelParams:         p.ModelParamsB,
		ConnectedAt:         p.ConnectedAt.UTC().Format("2006-01-02T15:04:05.000Z"),
		Tier:                string(p.Tier),
	}
}
