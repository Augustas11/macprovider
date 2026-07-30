package ws

import (
	"math"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Issue #764 asked for TTFT/TPS rollups segmented by binary_version so a slow
// or misbehaving backend build is separable from the honest fleet. The SPEC-017
// stats rollup pipeline has no TTFT/TPS aggregate to extend — its overview
// schema is a locked 14-field counter set with no latency at all — so the
// cheapest ADDITIVE surface is the live /poolz snapshot, which already carries
// binary_version per provider. This adds a `by_binary_version` block to the
// /poolz summary; no existing field name or shape changes.
//
// The latency inputs are the canary probe metrics recorded on the pool entry
// (pool.Registry.RecordCanaryLatency) — the coordinator's only live TTFT/TPS
// measurement. Buyer relays are not timed into the pool, so a provider that has
// never been canary-probed contributes to the counts but not to the latency
// averages; the `*_samples` fields make that explicit rather than letting a
// zero read as "fast".

// poolzVersionSegment is one binary_version's slice of the live pool.
type poolzVersionSegment struct {
	Providers       int `json:"providers"`
	RoutingEligible int `json:"routing_eligible"`
	SlotsTotal      int `json:"slots_total"`
	SlotsFree       int `json:"slots_free"`

	// Canary-measured latency. Averages are omitted (null) when no provider on
	// this version has been probed yet.
	CanaryTTFTSamples int      `json:"canary_ttft_samples"`
	CanaryTTFTMSAvg   *float64 `json:"canary_ttft_ms_avg"`
	CanaryTTFTMSMax   *int     `json:"canary_ttft_ms_max"`
	CanaryTPSSamples  int      `json:"canary_sustained_tps_samples"`
	CanaryTPSAvg      *float64 `json:"canary_sustained_tps_avg"`

	// Provider-reported throughput estimate, kept alongside the measured values
	// so a version whose SELF-REPORTED number diverges from its canary-measured
	// number is visible in one place.
	ReportedTPSSamples int      `json:"reported_tps_estimate_samples"`
	ReportedTPSAvg     *float64 `json:"reported_tps_estimate_avg"`

	Models []string `json:"models"`
}

// poolzUnknownBinaryVersion keys providers that report no binary_version
// (pre-versioning builds). Never an empty JSON key.
const poolzUnknownBinaryVersion = "unknown"

// poolzVersionSegments builds the per-binary_version breakdown. Pure over the
// snapshot; safe to call under the /poolz handler with no additional locking.
func poolzVersionSegments(providers []pool.Provider) map[string]poolzVersionSegment {
	type accumulator struct {
		seg          poolzVersionSegment
		ttftSum      float64
		tpsSum       float64
		reportedSum  float64
		ttftMax      int
		modelsSeen   map[string]struct{}
		modelsSorted []string
	}
	acc := map[string]*accumulator{}
	for _, p := range providers {
		version := strings.TrimSpace(p.BinaryVersion)
		if version == "" {
			version = poolzUnknownBinaryVersion
		}
		a := acc[version]
		if a == nil {
			a = &accumulator{modelsSeen: map[string]struct{}{}}
			acc[version] = a
		}
		a.seg.Providers++
		if p.RoutingEligible() {
			a.seg.RoutingEligible++
		}
		a.seg.SlotsTotal += p.SlotsTotal
		a.seg.SlotsFree += p.SlotsFree
		if p.CanaryLastTTFTMS > 0 {
			a.seg.CanaryTTFTSamples++
			a.ttftSum += float64(p.CanaryLastTTFTMS)
			if p.CanaryLastTTFTMS > a.ttftMax {
				a.ttftMax = p.CanaryLastTTFTMS
			}
		}
		if finitePositive(p.CanaryLastSustainedTPS) {
			a.seg.CanaryTPSSamples++
			a.tpsSum += p.CanaryLastSustainedTPS
		}
		if finitePositive(p.ThroughputTPSEstimate) {
			a.seg.ReportedTPSSamples++
			a.reportedSum += p.ThroughputTPSEstimate
		}
		if model := strings.TrimSpace(p.ModelID); model != "" {
			if _, seen := a.modelsSeen[model]; !seen {
				a.modelsSeen[model] = struct{}{}
				a.modelsSorted = append(a.modelsSorted, model)
			}
		}
	}
	out := make(map[string]poolzVersionSegment, len(acc))
	for version, a := range acc {
		seg := a.seg
		if seg.CanaryTTFTSamples > 0 {
			avg := a.ttftSum / float64(seg.CanaryTTFTSamples)
			seg.CanaryTTFTMSAvg = &avg
			maxTTFT := a.ttftMax
			seg.CanaryTTFTMSMax = &maxTTFT
		}
		if seg.CanaryTPSSamples > 0 {
			avg := a.tpsSum / float64(seg.CanaryTPSSamples)
			seg.CanaryTPSAvg = &avg
		}
		if seg.ReportedTPSSamples > 0 {
			avg := a.reportedSum / float64(seg.ReportedTPSSamples)
			seg.ReportedTPSAvg = &avg
		}
		sort.Strings(a.modelsSorted)
		seg.Models = a.modelsSorted
		out[version] = seg
	}
	return out
}

func finitePositive(v float64) bool {
	return v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0)
}
