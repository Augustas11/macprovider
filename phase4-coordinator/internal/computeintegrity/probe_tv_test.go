package computeintegrity

import (
	"math"
	"testing"
)

func sampleRequest() RequestEnvelope {
	return RequestEnvelope{
		Type:          ProbeRequestType,
		SchemaVersion: ProbeRequestSchema,
		Payload: RequestPayload{
			SchemaVersion:        ProbeRequestSchema,
			ProbeID:              "probe-1",
			Nonce:                "0123456789abcdef0123456789abcdef",
			ExpiresAt:            "2026-08-06T00:02:00Z",
			ModelID:              "model-x",
			TargetModelHash:      "hash-x",
			TokenizerIdentity:    "tok-x",
			SamplerStage:         SamplerStagePostSampler,
			TargetGeneration:     1,
			SamplingProfile:      "temp-0.7",
			CorpusVersion:        "corpus-1",
			ThresholdVersion:     "thr-1",
			HardwareRuntimeClass: "m3-max",
			SupportSelection:     SupportSelectionV1,
			NormalizationBasis:   NormalizationFullDist,
			K:                    64,
			Positions: []RequestPosition{{
				PromptID:          "p1",
				PromptRef:         "corpus://p1",
				PositionIndex:     0,
				TokenPrefixDigest: "sha256:pfx",
				ContextHash:       "sha256:ctx",
				ReferenceTopKSets: []ReferenceTopKSet{{
					ReferenceEventDigest:  "sha256:ref1",
					ReferenceTopKTokenIDs: []int64{1, 2, 3},
				}},
			}},
		},
	}
}

// AC-3: probe schema + TV computation.
func TestAC03_ProbeSchemaAndTV(t *testing.T) {
	t.Run("digest domain separation: request and result digests differ by construction", func(t *testing.T) {
		req := sampleRequest()
		if err := req.SetRequestDigest(); err != nil {
			t.Fatal(err)
		}
		// A result envelope with an identical inner payload shape still digests
		// differently because type/schema_version are part of the preimage.
		res := ResultEnvelope{
			Type:               ProbeResultType,
			SchemaVersion:      ProbeResultSchema,
			ProbeRequestDigest: req.ProbeRequestDigest,
			Payload: ResultPayload{
				SchemaVersion:      ProbeResultSchema,
				ProbeID:            "probe-1",
				Nonce:              req.Payload.Nonce,
				ProbeRequestDigest: req.ProbeRequestDigest,
				ResultKind:         ResultKindMeasurement,
			},
		}
		if err := res.SetResultDigest(); err != nil {
			t.Fatal(err)
		}
		if req.ProbeRequestDigest == res.ProbeResultDigest {
			t.Fatal("request and result digests must differ (domain separation)")
		}
		if res.Payload.ProbeRequestDigest != req.ProbeRequestDigest {
			t.Fatal("result must echo probe_request_digest")
		}
		// Digest is deterministic.
		again, _ := ComputeRequestDigest(req)
		if again != req.ProbeRequestDigest {
			t.Fatal("request digest is not deterministic")
		}
	})

	t.Run("request bounds: k must be 64 or 256", func(t *testing.T) {
		req := sampleRequest()
		req.Payload.K = 100
		if err := ValidateRequestBounds(req); err == nil {
			t.Fatal("expected k!=64/256 rejection")
		}
	})

	t.Run("request bounds: reject 5+ distinct prompts and 9+ positions", func(t *testing.T) {
		req := sampleRequest()
		req.Payload.Positions = nil
		for i := 0; i < 5; i++ { // 5 distinct prompts, each 1 position
			req.Payload.Positions = append(req.Payload.Positions, RequestPosition{
				PromptID: string(rune('a' + i)), PromptRef: "r" + string(rune('a'+i)),
				TokenPrefixDigest: "d", ContextHash: "c",
				ReferenceTopKSets: []ReferenceTopKSet{{ReferenceEventDigest: "x", ReferenceTopKTokenIDs: []int64{1}}},
			})
		}
		if err := ValidateRequestBounds(req); err == nil {
			t.Fatal("expected >4 distinct prompts rejection")
		}

		req2 := sampleRequest()
		req2.Payload.Positions = nil
		for i := 0; i < 9; i++ { // 9 positions, 1 prompt
			req2.Payload.Positions = append(req2.Payload.Positions, RequestPosition{
				PromptID: "p1", PromptRef: "corpus://p1", PositionIndex: i,
				TokenPrefixDigest: "d", ContextHash: "c",
				ReferenceTopKSets: []ReferenceTopKSet{{ReferenceEventDigest: "x", ReferenceTopKTokenIDs: []int64{1}}},
			})
		}
		if err := ValidateRequestBounds(req2); err == nil {
			t.Fatal("expected >8 positions rejection")
		}
	})

	t.Run("retry_of_probe_id present only for K=256", func(t *testing.T) {
		req := sampleRequest() // K=64
		req.Payload.RetryOfProbeID = "probe-0"
		if err := ValidateRequestBounds(req); err == nil {
			t.Fatal("retry_of_probe_id with K=64 must be rejected")
		}
		req.Payload.K = 256
		if err := ValidateRequestBounds(req); err != nil {
			t.Fatalf("retry_of_probe_id with K=256 should be valid: %v", err)
		}
	})

	t.Run("TV interval matches the two-arm formula; identical distributions give TV 0", func(t *testing.T) {
		providerTopK := []int64{1, 2}
		providerSupport := map[int64]float64{1: 0.6, 2: 0.4}
		refFull := ReferenceDistribution{1: 0.6, 2: 0.4}
		iv, err := ProviderVsReferenceTV(providerTopK, providerSupport, 0.0, []int64{1, 2}, refFull)
		if err != nil {
			t.Fatal(err)
		}
		if math.Abs(iv.Lower) > 1e-9 || math.Abs(iv.Upper) > 1e-9 {
			t.Fatalf("identical distributions: want TV 0, got %+v", iv)
		}
	})

	t.Run("TV interval reflects divergence and tail", func(t *testing.T) {
		// provider puts 0.5/0.5 on {1,2}; reference puts 0.5/0.5 on {1,3}.
		// S_r = {1,2,3}. provider mass in S_r = 1.0 (0.5 on 1, 0.5 on 2, 0 on 3).
		// reference mass in S_r = 1.0 (0.5 on 1, 0 on 2, 0.5 on 3).
		// diff = |0.5-0.5| + |0.5-0| + |0-0.5| = 1.0; tails both 0.
		iv, err := ProviderVsReferenceTV([]int64{1, 2}, map[int64]float64{1: 0.5, 2: 0.5}, 0.0,
			[]int64{1, 3}, ReferenceDistribution{1: 0.5, 3: 0.5})
		if err != nil {
			t.Fatal(err)
		}
		if math.Abs(iv.Lower-0.5) > 1e-9 || math.Abs(iv.Upper-0.5) > 1e-9 {
			t.Fatalf("want TV 0.5, got %+v", iv)
		}
	})

	t.Run("K=64 retry predicate fires near quarantine boundary", func(t *testing.T) {
		th := Thresholds{TauWarnMedian: 0.01, TauWarnPosition: 0.02, TauQuarantineMedian: 0.05, TauQuarantinePosition: 0.10}
		// tv_lower just under quarantine-median minus 0.005 slack triggers retry.
		iv := []TVInterval{{Lower: 0.046, Upper: 0.005}}
		if !RequiresK256Retry(64, iv, 0.0, th) {
			t.Fatal("expected K=256 retry near quarantine boundary")
		}
		// Clean low-divergence canary does not require retry.
		if RequiresK256Retry(64, []TVInterval{{Lower: 0.001, Upper: 0.001}}, 0.0, th) {
			t.Fatal("clean canary should not require retry")
		}
	})

	t.Run("K=256 tail ceiling maps to tail_mass_high", func(t *testing.T) {
		if !K256TailExceeded(256, 0.006) {
			t.Fatal("K=256 tail>0.005 must be tail_mass_high")
		}
		if K256TailExceeded(256, 0.004) {
			t.Fatal("K=256 tail<=0.005 is fine")
		}
	})

	t.Run("validation rejects broken mass conservation", func(t *testing.T) {
		pos := ResultPosition{
			ProviderTopKTokenIDs:         []int64{1, 2},
			SupportTokenIDs:              []int64{1, 2, 3},
			ProviderSupportProbabilities: []float64{0.5, 0.4, 0.05}, // sum 0.95
			ProviderTailMass:             0.20,                      // 0.95+0.20 = 1.15
		}
		if err := ValidateMeasurementPosition(pos, 2, [][]int64{{1, 3}}, 0); err == nil {
			t.Fatal("expected mass-conservation rejection")
		}
	})
}

// AC-3 (verdict): coordinator-owned verdict with the FR-5 agreed-envelope and the
// FR-9 measurement-validation precedence.
func TestAC03_VerdictAndPrecedence(t *testing.T) {
	th := Thresholds{TauWarnMedian: 0.01, TauWarnPosition: 0.02, TauQuarantineMedian: 0.05, TauQuarantinePosition: 0.10}

	t.Run("pass requires the pass predicate against EVERY reference", func(t *testing.T) {
		// ref A clean, ref B above warn: overall not pass.
		v := AssignVerdict([][]TVInterval{
			{{Lower: 0.001, Upper: 0.001}}, // ref A: pass
			{{Lower: 0.001, Upper: 0.03}},  // ref B: upper>tau_warn_position -> not pass
		}, th)
		if v == VerdictPass {
			t.Fatal("must not pass when one reference fails the pass predicate")
		}
	})

	t.Run("quarantine_candidate requires the quarantine predicate against EVERY reference", func(t *testing.T) {
		// ref A quarantine, ref B not: overall warn (not quarantine_candidate).
		v := AssignVerdict([][]TVInterval{
			{{Lower: 0.20, Upper: 0.25}},   // ref A: lower>tau_quarantine_position
			{{Lower: 0.001, Upper: 0.001}}, // ref B: clean
		}, th)
		if v == VerdictQuarantineCandidate {
			t.Fatal("must not quarantine when one reference disagrees")
		}
		if v != VerdictWarn {
			t.Fatalf("expected warn, got %s", v)
		}
	})

	t.Run("all references quarantine -> quarantine_candidate", func(t *testing.T) {
		v := AssignVerdict([][]TVInterval{
			{{Lower: 0.20, Upper: 0.25}},
			{{Lower: 0.20, Upper: 0.25}},
		}, th)
		if v != VerdictQuarantineCandidate {
			t.Fatalf("expected quarantine_candidate, got %s", v)
		}
	})

	t.Run("measurement-validation precedence: auth/replay before model_swap", func(t *testing.T) {
		r, inc := ResolveMeasurementValidation(MeasurementValidationInputs{
			AuthReplayEnvelopeFail: true,
			PerPositionHashGenSwap: true,
		})
		if !inc || r != IncIdentityReject {
			t.Fatalf("auth/replay must win: got %q", r)
		}
	})

	t.Run("model_swap before global identity mismatch", func(t *testing.T) {
		r, _ := ResolveMeasurementValidation(MeasurementValidationInputs{
			PerPositionHashGenSwap: true,
			GlobalIdentityMismatch: true,
		})
		if r != IncModelSwap {
			t.Fatalf("model_swap must precede global identity mismatch: got %q", r)
		}
	})

	t.Run("model_swap is not abusive; identity_reject is", func(t *testing.T) {
		if IsAbusiveInconclusive(IncModelSwap, false) {
			t.Fatal("model_swap must not be abusive")
		}
		if !IsAbusiveInconclusive(IncIdentityReject, false) {
			t.Fatal("identity_reject must be abusive")
		}
		if IsAbusiveInconclusive(IncIdentityReject, true) {
			t.Fatal("coordinator-fault-attributed identity_reject is exempt")
		}
	})

	t.Run("provider reference_unavailable is abusive unless coordinator confirms outage", func(t *testing.T) {
		if !ProviderReasonToInconclusive("inconclusive:reference_unavailable", false) {
			t.Fatal("unconfirmed reference_unavailable must be abusive")
		}
		if ProviderReasonToInconclusive("inconclusive:reference_unavailable", true) {
			t.Fatal("confirmed outage exempts reference_unavailable")
		}
	})
}
