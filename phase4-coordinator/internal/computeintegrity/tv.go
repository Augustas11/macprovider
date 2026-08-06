package computeintegrity

import (
	"fmt"
	"math"
	"sort"
)

// TV computation (FR-7) and compact-distribution validation (FR-6). The TV interval
// formula and support-selection construction are SPEC-030 §FR-7/§FR-9 primitives,
// applied unchanged and pairwise: every provider-vs-reference interval is computed
// over a two-arm [K,2K] support S_r = provider_top_k ∪ reference_r_top_k. SPEC-036's
// only owned change is on the wire (the request carries all references' top-K so one
// probe answers every reference); the math below is the inherited formula.

const massConservationTolerance = 1e-5

// Thresholds is the active threshold record's TV bounds for a covered key (FR-8).
type Thresholds struct {
	TauWarnMedian         float64
	TauWarnPosition       float64
	TauQuarantineMedian   float64
	TauQuarantinePosition float64
}

// ReferenceDistribution is a coordinator-held trusted reference's full next-token
// distribution (token id -> probability). The coordinator recomputes reference
// probabilities and tail mass over each pairwise support itself and MUST NOT accept
// reference-side probabilities from the provider (FR-6, FR-7).
type ReferenceDistribution map[int64]float64

// TVInterval is a provider-vs-reference TV lower/upper interval (SPEC-030 §FR-9).
type TVInterval struct {
	Lower float64
	Upper float64
}

// numericUnion returns the numeric-ascending union of two token-id lists, no dups.
func numericUnion(a, b []int64) []int64 {
	seen := make(map[int64]struct{}, len(a)+len(b))
	for _, x := range a {
		seen[x] = struct{}{}
	}
	for _, x := range b {
		seen[x] = struct{}{}
	}
	out := make([]int64, 0, len(seen))
	for x := range seen {
		out = append(out, x)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func sameInts(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func noDuplicates(ids []int64) bool {
	seen := make(map[int64]struct{}, len(ids))
	for _, x := range ids {
		if _, ok := seen[x]; ok {
			return false
		}
		seen[x] = struct{}{}
	}
	return true
}

// ValidateMeasurementPosition validates a measurement-kind result position's compact
// distribution before TV computation (FR-6): finite probabilities in [0,1], no
// duplicate ids, provider top-K length K (small-vocab exception), the shared support
// equal to the union of the provider top-K and every reference top-K, support length
// in [K,(N+1)K], and mass conservation within the fixed tolerance.
func ValidateMeasurementPosition(pos ResultPosition, k int, refTopKs [][]int64, vocabSize int) error {
	effK := k
	if vocabSize > 0 && vocabSize < k {
		effK = vocabSize
	}
	if len(pos.ProviderTopKTokenIDs) != effK {
		return fmt.Errorf("provider top-K length %d != %d", len(pos.ProviderTopKTokenIDs), effK)
	}
	if !noDuplicates(pos.ProviderTopKTokenIDs) {
		return fmt.Errorf("provider top-K has duplicates")
	}
	if len(pos.SupportTokenIDs) != len(pos.ProviderSupportProbabilities) {
		return fmt.Errorf("support/probability length mismatch")
	}
	if !noDuplicates(pos.SupportTokenIDs) {
		return fmt.Errorf("support has duplicate ids")
	}
	// Every reference top-K must itself be well-formed (length effK unless the
	// vocabulary is smaller, no duplicates) before it is used to build the union.
	for i, r := range refTopKs {
		if vocabSize > 0 && vocabSize < k {
			if len(r) != vocabSize {
				return fmt.Errorf("reference %d top-K length %d != vocab %d", i, len(r), vocabSize)
			}
		} else if len(r) != effK {
			return fmt.Errorf("reference %d top-K length %d != %d", i, len(r), effK)
		}
		if !noDuplicates(r) {
			return fmt.Errorf("reference %d top-K has duplicates", i)
		}
	}
	// Shared support must be exactly the union of provider top-K and all references'
	// top-K. This exact-union equality already bounds the support length to
	// [effK, (N+1)*effK], so no separate length check is needed.
	want := pos.ProviderTopKTokenIDs
	for _, r := range refTopKs {
		want = numericUnion(want, r)
	}
	gotSorted := append([]int64(nil), pos.SupportTokenIDs...)
	sort.Slice(gotSorted, func(i, j int) bool { return gotSorted[i] < gotSorted[j] })
	if !sameInts(gotSorted, want) {
		return fmt.Errorf("support is not the exact provider∪references union")
	}
	var sum float64
	for _, p := range pos.ProviderSupportProbabilities {
		if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1 {
			return fmt.Errorf("provider probability out of [0,1]: %v", p)
		}
		sum += p
	}
	if math.IsNaN(pos.ProviderTailMass) || math.IsInf(pos.ProviderTailMass, 0) ||
		pos.ProviderTailMass < 0 || pos.ProviderTailMass > 1 {
		return fmt.Errorf("provider tail mass out of [0,1]")
	}
	if math.Abs(sum+pos.ProviderTailMass-1.0) > massConservationTolerance {
		return fmt.Errorf("provider mass not conserved: sum=%v tail=%v", sum, pos.ProviderTailMass)
	}
	return nil
}

// ProviderVsReferenceTV computes the two-arm [K,2K] TV interval for one active
// reference r (FR-7). providerSupport maps the provider's reported union-support
// token ids to probabilities; refTopK is reference r's top-K; refFull is reference
// r's coordinator-held full distribution. The provider tail masses are recomputed
// outside the pairwise support S_r.
func ProviderVsReferenceTV(providerTopK []int64, providerSupport map[int64]float64, providerUnionTail float64,
	refTopK []int64, refFull ReferenceDistribution) (TVInterval, error) {
	sr := numericUnion(providerTopK, refTopK)

	var providerMassInSr, refMassInSr, diff float64
	for _, t := range sr {
		pp := providerSupport[t] // 0 if provider did not place t in its union support
		rp := refFull[t]         // 0 if reference did not place mass on t
		if math.IsNaN(rp) || math.IsInf(rp, 0) || rp < 0 || rp > 1 {
			return TVInterval{}, fmt.Errorf("reference probability out of [0,1] for token %d", t)
		}
		providerMassInSr += pp
		refMassInSr += rp
		diff += math.Abs(pp - rp)
	}
	providerTailR := 1.0 - providerMassInSr
	refTailR := 1.0 - refMassInSr
	if providerTailR < 0 {
		providerTailR = 0
	}
	if refTailR < 0 {
		refTailR = 0
	}
	return TVInterval{
		Lower: 0.5 * (diff + math.Abs(providerTailR-refTailR)),
		Upper: 0.5 * (diff + providerTailR + refTailR),
	}, nil
}

// canonicalMedian returns the SPEC-030 §FR-9 lower-middle median of xs.
func canonicalMedian(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	s := append([]float64(nil), xs...)
	sort.Float64s(s)
	// lower-middle rule: for even length, take the lower of the two middles.
	return s[(len(s)-1)/2]
}

// RequiresK256Retry reports whether, at K=64, the coordinator MUST retry at K=256
// before assigning pass/warn/quarantine_candidate (FR-7). intervals are the
// per-reference intervals for one canary; providerTail/refTail are the max observed
// tail masses across positions/references.
func RequiresK256Retry(k int, intervals []TVInterval, maxTailMass float64, th Thresholds) bool {
	if k != 64 {
		return false
	}
	if maxTailMass > 0.01 {
		return true
	}
	uppers := make([]float64, len(intervals))
	lowers := make([]float64, len(intervals))
	for i, iv := range intervals {
		uppers[i] = iv.Upper
		lowers[i] = iv.Lower
		if iv.Upper >= th.TauWarnPosition {
			return true
		}
		if iv.Lower >= th.TauQuarantinePosition-0.005 {
			return true
		}
	}
	if canonicalMedian(uppers) >= th.TauWarnMedian {
		return true
	}
	if canonicalMedian(lowers) >= th.TauQuarantineMedian-0.005 {
		return true
	}
	return false
}

// K256TailExceeded reports whether, at K=256, either tail mass exceeds 0.005, which
// finalizes the canary as inconclusive:tail_mass_high (FR-7).
func K256TailExceeded(k int, maxTailMass float64) bool {
	return k == 256 && maxTailMass > 0.005
}
