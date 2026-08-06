package computeintegrity

import (
	"sort"
	"strings"
)

// FR-13 third-party audit + FR-14 audit logging. The auditor bundle is a signed
// artifact over a closed payload; a verifier verifies the signature over
// bundle_digest, recomputes bundle_digest from the payload, then recomputes the TV
// intervals from the retained evidence. Bundles and audit rows expose linkable
// identifiers without raw buyer prompts or output.

const (
	AuditorBundleType   = "compute_integrity_auditor_bundle_v1"
	AuditorBundleSchema = "compute_integrity_auditor_bundle_v1"

	RequestStartSnapshotType   = "compute_integrity_request_start_snapshot_v1"
	RequestStartSnapshotSchema = "compute_integrity_request_start_snapshot_v1"
)

// RetainedPositionEvidence is the inline compact per-position evidence sufficient to
// recompute a TV interval (FR-5, FR-13). It carries no raw prompt or output text.
type RetainedPositionEvidence struct {
	PromptID                     string    `json:"prompt_id"`
	PositionIndex                int       `json:"position_index"`
	TokenPrefixDigest            string    `json:"token_prefix_digest"`
	ContextHash                  string    `json:"context_hash"`
	K                            int       `json:"k"`
	SamplerStage                 string    `json:"sampler_stage"`
	SupportTokenIDs              []int64   `json:"support_token_ids"`
	ProviderSupportProbabilities []float64 `json:"provider_support_probabilities"`
	ProviderTailMass             float64   `json:"provider_tail_mass"`
	// ReferenceSupport maps reference_event_digest -> per-support-token probabilities,
	// so a verifier can recompute reference probabilities/tails over the same support.
	ReferenceSupport  map[string][]float64 `json:"reference_support"`
	ReferenceTailMass map[string]float64   `json:"reference_tail_mass"`
}

// AuditorBundlePayload is the closed FR-13 auditor-bundle payload.
type AuditorBundlePayload struct {
	PolicyVersion              string                     `json:"policy_version"`
	PolicyMode                 Mode                       `json:"policy_mode"`
	ProviderModelKeyDigest     string                     `json:"provider_model_key_digest"`
	CurrentState               State                      `json:"current_state"`
	WindowID                   string                     `json:"window_id"`
	ThresholdVersion           string                     `json:"threshold_version"`
	ThresholdRecordDigest      string                     `json:"threshold_record_digest"`
	ReferenceEventDigests      []string                   `json:"reference_event_digests"`
	ReferenceSetAdmissibility  string                     `json:"reference_set_admissibility_digest"`
	RetainedEvidence           []RetainedPositionEvidence `json:"retained_evidence"`
	LatestCanaryDigests        []string                   `json:"latest_canary_digests"`
	StateTransitionLog         []string                   `json:"state_transition_log"`
	RequestStartSnapshotDigest string                     `json:"request_start_snapshot_digest"`
	SettlementRowID            string                     `json:"settlement_row_id"`
	SigningKeyID               string                     `json:"signing_key_id"`
	AggregationRule            string                     `json:"aggregation_rule"`
}

// AuditorBundle is the signed outer artifact (FR-13).
type AuditorBundle struct {
	Type          string               `json:"type"`
	SchemaVersion string               `json:"schema_version"`
	Payload       AuditorBundlePayload `json:"payload"`
	BundleDigest  string               `json:"bundle_digest"`
	Signature     string               `json:"signature"`
}

// ComputeBundleDigest returns the FR-13 bundle_digest over {type, schema_version,
// payload}, excluding bundle_digest and signature.
func (b AuditorBundle) ComputeBundleDigest() (string, error) {
	return jcsDigest(map[string]any{
		"type":           b.Type,
		"schema_version": b.SchemaVersion,
		"payload":        b.Payload,
	})
}

// RequestStartSnapshotDigest returns the FR-13 request-start snapshot digest over the
// closed FR-4 capture (the composite SPEC-022 + SPEC-036 capture).
func RequestStartSnapshotDigest(c Capture) (string, error) {
	return jcsDigest(map[string]any{
		"type":           RequestStartSnapshotType,
		"schema_version": RequestStartSnapshotSchema,
		"payload":        c,
	})
}

// forbiddenRawSubstrings are field markers that MUST NOT appear in an auditor bundle,
// so raw buyer prompts/output are never exported (FR-13, FR-14).
var forbiddenRawSubstrings = []string{"prompt_text", "output_text", "raw_prompt", "raw_output", "buyer_output"}

// BundleOmitsRawContent reports whether a serialized auditor bundle omits raw
// prompt/output content (FR-13). It checks the canonical serialization for forbidden
// field markers.
func BundleOmitsRawContent(b AuditorBundle) (bool, error) {
	canonical, err := jcsCanonical(map[string]any{
		"type": b.Type, "schema_version": b.SchemaVersion, "payload": b.Payload,
	})
	if err != nil {
		return false, err
	}
	lc := strings.ToLower(string(canonical))
	for _, f := range forbiddenRawSubstrings {
		if strings.Contains(lc, f) {
			return false, nil
		}
	}
	return true, nil
}

// RecomputeTVFromEvidence recomputes the provider-vs-reference TV intervals for a
// retained position from the exported evidence (FR-13 verifier path), using the same
// FR-7 math. references maps reference_event_digest -> full distribution and top-K.
func RecomputeTVFromEvidence(ev RetainedPositionEvidence, providerTopK []int64,
	references map[string]struct {
		TopK []int64
		Full ReferenceDistribution
	}) (map[string]TVInterval, error) {
	providerSupport := map[int64]float64{}
	for i, id := range ev.SupportTokenIDs {
		if i < len(ev.ProviderSupportProbabilities) {
			providerSupport[id] = ev.ProviderSupportProbabilities[i]
		}
	}
	out := map[string]TVInterval{}
	digests := make([]string, 0, len(references))
	for d := range references {
		digests = append(digests, d)
	}
	sort.Strings(digests)
	for _, d := range digests {
		r := references[d]
		iv, err := ProviderVsReferenceTV(providerTopK, providerSupport, ev.ProviderTailMass, r.TopK, r.Full)
		if err != nil {
			return nil, err
		}
		out[d] = iv
	}
	return out, nil
}
