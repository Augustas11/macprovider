package ws

import (
	"bytes"
	"encoding/json"
	"math"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	gobwas "github.com/gobwas/ws"
	"github.com/rs/zerolog"
)

func TestLosslessnessDigestFixturesHashInnerPayloadOnly(t *testing.T) {
	fixtures := loadLosslessnessFixtures(t)
	for _, fixture := range fixtures {
		payload := mustMarshal(t, fixture.Payload)
		got, err := LosslessnessDigest(payload)
		if err != nil {
			t.Fatalf("%s digest: %v", fixture.ID, err)
		}
		if got != fixture.ExpectedSHA256 {
			t.Fatalf("%s digest = %q, want %q", fixture.ID, got, fixture.ExpectedSHA256)
		}
	}

	requestPayload := mustMarshal(t, fixtures[0].Payload)
	requestDigest, err := LosslessnessDigest(requestPayload)
	if err != nil {
		t.Fatal(err)
	}
	outer := mustMarshal(t, map[string]any{
		"type":                  losslessnessRequestType,
		"probe_id":              "probe-fixture-001",
		"probe_request_digest":  requestDigest,
		"payload":               fixtures[0].Payload,
		"transport_debug_field": "outer fields are not digest input",
	})
	if _, err := ValidateLosslessnessEnvelope(outer, losslessnessRequestType); err != nil {
		t.Fatalf("valid request outer envelope rejected: %v", err)
	}
	outerDigest, err := LosslessnessDigest(outer)
	if err != nil {
		t.Fatal(err)
	}
	if outerDigest == requestDigest {
		t.Fatal("outer envelope digest unexpectedly matched inner payload digest")
	}
}

func TestLosslessnessEnvelopeRejectsMissingPayloadAndDigestMismatch(t *testing.T) {
	_, err := ValidateLosslessnessEnvelope([]byte(`{"type":"losslessness_probe_v1.request","probe_id":"probe-1","probe_request_digest":"sha256:00"}`), losslessnessRequestType)
	if err == nil {
		t.Fatal("missing payload accepted")
	}

	_, err = ValidateLosslessnessEnvelope([]byte(`{"type":"losslessness_probe_v1.request","probe_id":"probe-1","probe_request_digest":"sha256:00","payload":{"probe_id":"probe-1"}}`), losslessnessRequestType)
	if err == nil {
		t.Fatal("digest mismatch accepted")
	}

	payload := mustMarshal(t, map[string]any{"probe_id": "inner-probe"})
	digest, err := LosslessnessDigest(payload)
	if err != nil {
		t.Fatal(err)
	}
	outer := mustMarshal(t, map[string]any{
		"type":                 losslessnessRequestType,
		"probe_id":             "outer-probe",
		"probe_request_digest": digest,
		"payload":              map[string]any{"probe_id": "inner-probe"},
	})
	if _, err := ValidateLosslessnessEnvelope(outer, losslessnessRequestType); err == nil {
		t.Fatal("inner/outer probe_id mismatch accepted")
	}

	resultPayload := mustMarshal(t, map[string]any{
		"probe_id":               "probe-result",
		"probe_nonce":            "nonce",
		"probe_request_digest":   "",
		"result_kind":            "provider_inconclusive",
		"provider_reason_code":   "inconclusive:unsupported_sampler",
		"target_model_hash":      nil,
		"target_generation":      nil,
		"draft_artifact_binding": nil,
		"draft_generation":       nil,
	})
	resultDigest, err := LosslessnessDigest(resultPayload)
	if err != nil {
		t.Fatal(err)
	}
	resultOuter := mustMarshal(t, map[string]any{
		"type":                losslessnessResultType,
		"probe_id":            "probe-result",
		"probe_result_digest": resultDigest,
		"payload":             json.RawMessage(resultPayload),
	})
	if _, err := ValidateLosslessnessEnvelope(resultOuter, losslessnessResultType); err == nil {
		t.Fatal("result envelope without probe_request_digest accepted")
	}
}

func TestLosslessnessProviderInconclusiveRequiresExplicitIdentityNulls(t *testing.T) {
	base := map[string]any{
		"probe_id":                    "probe-result",
		"probe_nonce":                 "nonce",
		"probe_request_digest":        "sha256:req",
		"result_kind":                 "provider_inconclusive",
		"provider_reason_code":        "inconclusive:unsupported_sampler",
		"identity_unavailable_reason": "sampler hook unavailable",
	}
	if _, err := ValidateLosslessnessResultPayload(mustMarshal(t, base)); err == nil {
		t.Fatal("provider_inconclusive omitted identity fields accepted")
	}

	base["target_model_hash"] = nil
	base["target_generation"] = nil
	base["draft_artifact_binding"] = nil
	base["draft_generation"] = nil
	if _, err := ValidateLosslessnessResultPayload(mustMarshal(t, base)); err != nil {
		t.Fatalf("provider_inconclusive explicit null identity rejected: %v", err)
	}

	base["target_model_hash"] = "sha256:target"
	if _, err := ValidateLosslessnessResultPayload(mustMarshal(t, base)); err == nil {
		t.Fatal("provider_inconclusive partial null identity accepted")
	}

	base["target_model_hash"] = nil
	base["positions"] = []map[string]any{{"position_index": 0}}
	if _, err := ValidateLosslessnessResultPayload(mustMarshal(t, base)); err == nil {
		t.Fatal("provider_inconclusive with measurement positions accepted")
	}
}

func TestLosslessnessDistributionValidationAndTV(t *testing.T) {
	pos := validLosslessnessPosition()
	result := ValidateLosslessnessDistribution(pos, 64, 70, "tok-v1", "sha256:ctx", expectedLosslessnessIdentity(), true, pos.OfflinePlainSupport)
	if result.ReasonCode != "valid" {
		t.Fatalf("valid distribution reason = %q", result.ReasonCode)
	}
	pos.TargetGeneration = 2
	result = ValidateLosslessnessDistribution(pos, 64, 70, "tok-v1", "sha256:ctx", expectedLosslessnessIdentity(), true, pos.OfflinePlainSupport)
	if result.ReasonCode != "inconclusive:identity_mismatch" {
		t.Fatalf("identity mismatch reason = %q", result.ReasonCode)
	}
	if !LosslessnessRequiresK256Retry(64, 0.001, 0.001, 0.095, 0.095, 0.1, 0.099) {
		t.Fatal("K=64 near-quarantine threshold did not require K=256 retry")
	}

	tv, err := ComputeTVInterval(LosslessnessPositionDistribution{
		SupportTokenIDs: []int{1, 2},
		PlainSupport: []LosslessnessTokenProbability{
			{TokenID: 1, P: 0.4},
			{TokenID: 2, P: 0.1},
		},
		PlainTailMass: 0.5,
		SpecSupport: []LosslessnessTokenProbability{
			{TokenID: 1, P: 0.3},
			{TokenID: 2, P: 0.2},
		},
		SpecTailMass: 0.5,
	})
	if err != nil {
		t.Fatal(err)
	}
	if math.Abs(tv.Lower-0.1) > 1e-12 || math.Abs(tv.Upper-0.6) > 1e-12 {
		t.Fatalf("tv = %+v, want lower=0.1 upper=0.6", tv)
	}
}

func TestLosslessnessDistributionRejectsMalformedEvidence(t *testing.T) {
	cases := []struct {
		name string
		mut  func(*LosslessnessPositionDistribution)
	}{
		{name: "duplicate support", mut: func(p *LosslessnessPositionDistribution) { p.SupportTokenIDs[1] = p.SupportTokenIDs[0] }},
		{name: "negative probability", mut: func(p *LosslessnessPositionDistribution) { p.PlainSupport[0].P = -0.1 }},
		{name: "wrong normalization", mut: func(p *LosslessnessPositionDistribution) { p.NormalizationBasis = "top_k_renormalized" }},
		{name: "wrong sampler stage", mut: func(p *LosslessnessPositionDistribution) { p.SamplerStage = "sampled_token_histogram" }},
		{name: "missing support probability", mut: func(p *LosslessnessPositionDistribution) { p.SpecSupport = p.SpecSupport[:len(p.SpecSupport)-1] }},
		{name: "extra support probability", mut: func(p *LosslessnessPositionDistribution) {
			p.PlainSupport = append(p.PlainSupport, LosslessnessTokenProbability{TokenID: 69, P: 0.001})
			p.PlainSupport[0].P -= 0.001
		}},
		{name: "top-k omits higher support token", mut: func(p *LosslessnessPositionDistribution) {
			for i := range p.PlainSupport {
				switch p.PlainSupport[i].TokenID {
				case 0:
					p.PlainSupport[i].P -= 0.0002
				case 64:
					p.PlainSupport[i].P += 0.0002
				}
			}
		}},
		{name: "inconsistent tail", mut: func(p *LosslessnessPositionDistribution) { p.PlainTailMass = 0.001 }},
		{name: "below offline tail floor", mut: func(p *LosslessnessPositionDistribution) {
			p.HighEntropy = true
			p.PlainTailMass = 0.001
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pos := validLosslessnessPosition()
			tc.mut(&pos)
			result := ValidateLosslessnessDistribution(pos, 64, 70, "tok-v1", "sha256:ctx", expectedLosslessnessIdentity(), true, pos.OfflinePlainSupport)
			if result.ReasonCode != "inconclusive:malformed_distribution" {
				t.Fatalf("reason = %q", result.ReasonCode)
			}
		})
	}

	pos := validLosslessnessPositionK256TailHigh()
	result := ValidateLosslessnessDistribution(pos, 256, 300, "tok-v1", "sha256:ctx", expectedLosslessnessIdentity(), true, pos.OfflinePlainSupport)
	if result.ReasonCode != "inconclusive:tail_mass_high" || !result.Retryable {
		t.Fatalf("K=256 tail reason = %+v", result)
	}
}

func TestLosslessnessStateTransitionsAndGridReadiness(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	record := LosslessnessProfileRecord{Key: losslessnessProfile(0.7), CalibrationAccepted: true}
	var err error
	record, err = ApplyLosslessnessReason(record, "quarantine_candidate:tv_lower_exceeded", now)
	if err != nil {
		t.Fatal(err)
	}
	record, err = ApplyLosslessnessReason(record, "warn:threshold_exceeded", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if record.State != LosslessnessStatusWarn || record.ConsecutiveQuarantine != 1 {
		t.Fatalf("after Q,W = %+v", record)
	}
	record, err = ApplyLosslessnessReason(record, "quarantine_candidate:tv_lower_exceeded", now.Add(2*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if record.State != LosslessnessStatusDisabled {
		t.Fatalf("Q,W,Q state = %q, want disabled", record.State)
	}
	qThenQ := LosslessnessProfileRecord{Key: losslessnessProfile(0.7), CalibrationAccepted: true}
	qThenQ, err = ApplyLosslessnessReason(qThenQ, "quarantine_candidate:tv_lower_exceeded", now)
	if err != nil {
		t.Fatal(err)
	}
	qThenQ, err = ApplyLosslessnessReason(qThenQ, "quarantine_candidate:tv_lower_exceeded", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if qThenQ.State != LosslessnessStatusDisabled {
		t.Fatalf("Q,Q state = %q, want disabled", qThenQ.State)
	}
	qThenInconclusiveThenQ := LosslessnessProfileRecord{Key: losslessnessProfile(0.7), CalibrationAccepted: true}
	for _, reason := range []string{
		"quarantine_candidate:tv_lower_exceeded",
		"inconclusive:tail_mass_high",
		"quarantine_candidate:tv_lower_exceeded",
	} {
		qThenInconclusiveThenQ, err = ApplyLosslessnessReason(qThenInconclusiveThenQ, reason, now)
		if err != nil {
			t.Fatal(err)
		}
	}
	if qThenInconclusiveThenQ.State != LosslessnessStatusDisabled {
		t.Fatalf("Q,inconclusive,Q state = %q, want disabled", qThenInconclusiveThenQ.State)
	}
	qThenPassThenQ := LosslessnessProfileRecord{Key: losslessnessProfile(0.7), VerdictEngineReady: true, CalibrationAccepted: true}
	for _, reason := range []string{
		"quarantine_candidate:tv_lower_exceeded",
		"pass:fresh",
		"quarantine_candidate:tv_lower_exceeded",
	} {
		qThenPassThenQ, err = ApplyLosslessnessReason(qThenPassThenQ, reason, now)
		if err != nil {
			t.Fatal(err)
		}
	}
	if qThenPassThenQ.State != LosslessnessStatusWarn {
		t.Fatalf("Q,pass,Q state = %q, want warn", qThenPassThenQ.State)
	}

	missingCalibration := LosslessnessProfileRecord{Key: losslessnessProfile(0.7)}
	missingCalibration, err = ApplyLosslessnessReason(missingCalibration, "quarantine_candidate:tv_lower_exceeded", now)
	if err != nil {
		t.Fatal(err)
	}
	if missingCalibration.ReasonCode != "blocked:calibration_missing" || missingCalibration.State != LosslessnessStatusBlocked {
		t.Fatalf("missing calibration state = %+v", missingCalibration)
	}
	noVerdictPass := LosslessnessProfileRecord{Key: losslessnessProfile(0.7), CalibrationAccepted: true}
	if _, err := ApplyLosslessnessReason(noVerdictPass, "pass:fresh", now); err == nil {
		t.Fatal("pass:fresh accepted without verdict engine")
	}

	abuse := LosslessnessProfileRecord{Key: losslessnessProfile(0.5), VerdictEngineReady: true, CalibrationAccepted: true}
	for i := 0; i < 3; i++ {
		abuse, err = ApplyLosslessnessReason(abuse, "inconclusive:timeout", now.Add(time.Duration(i)*time.Hour))
		if err != nil {
			t.Fatal(err)
		}
	}
	if abuse.State != LosslessnessStatusBlocked {
		t.Fatalf("abuse state = %q, want blocked", abuse.State)
	}
	abuse, err = ApplyLosslessnessReason(abuse, "pass:fresh", now.Add(4*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(abuse.AbusiveInconclusiveEvents) != 3 {
		t.Fatalf("pass erased abuse events: %+v", abuse.AbusiveInconclusiveEvents)
	}
	if abuse.State != LosslessnessStatusBlocked {
		t.Fatalf("pass re-enabled abusive profile: %q", abuse.State)
	}

	repeated := LosslessnessProfileRecord{Key: losslessnessProfile(0.2)}
	for i := 0; i < 6; i++ {
		repeated, err = ApplyLosslessnessReason(repeated, "inconclusive:tail_mass_high", now.Add(time.Duration(i)*time.Hour))
		if err != nil {
			t.Fatal(err)
		}
	}
	if repeated.State != LosslessnessStatusBlocked || len(repeated.AbusiveInconclusiveEvents) != 3 {
		t.Fatalf("repeated tail_mass_high state/events = %q/%d", repeated.State, len(repeated.AbusiveInconclusiveEvents))
	}

	greedy := LosslessnessProfileRecord{Key: losslessnessProfile(0)}
	greedy, err = ApplyLosslessnessReason(greedy, "blocked:greedy_control_failed", now)
	if err != nil {
		t.Fatal(err)
	}
	if greedy.GreedyControlFailureCount != 1 || len(greedy.AbusiveInconclusiveEvents) != 0 {
		t.Fatalf("greedy counters = %+v", greedy)
	}

	required := LosslessnessDefaultProfiles()
	var records []LosslessnessProfileRecord
	for _, profile := range required {
		rec := LosslessnessProfileRecord{Key: losslessnessProfile(profile.Temperature), VerdictEngineReady: true, CalibrationAccepted: true}
		rec.Key.SamplingProfile = profile
		rec, err = ApplyLosslessnessReason(rec, "pass:fresh", now)
		if err != nil {
			t.Fatal(err)
		}
		records = append(records, rec)
	}
	grid := records[0].Key.GridKey()
	if got := LosslessnessGridState(records, grid, required, now.Add(time.Hour)); got != "all_profiles_fresh" {
		t.Fatalf("grid state = %q", got)
	}
	records[1].VerdictEngineReady = false
	if got := LosslessnessGridState(records, grid, required, now.Add(time.Hour)); got != "not_ready" {
		t.Fatalf("uncalibrated grid state = %q", got)
	}
	records[1].VerdictEngineReady = true
	records[0].Key.TargetGeneration = 99
	if got := LosslessnessGridState(records, grid, required, now.Add(time.Hour)); got != "not_ready" {
		t.Fatalf("mixed grid state = %q", got)
	}
	records[0].Key.TargetGeneration = 1
	records[2].StaleAfter = now.Add(-time.Second)
	if got := LosslessnessGridState(records, grid, required, now); got != "not_ready" {
		t.Fatalf("stale grid state = %q", got)
	}
}

func TestLosslessnessConfigDefaultsDisabledAndValidateBounds(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "operator-key"
	if cfg.Pool.LosslessnessProbe.Enabled {
		t.Fatal("losslessness probe must default disabled")
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("default config validates: %v", err)
	}
	cfg.Pool.LosslessnessProbe.Enabled = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("enabled bounded config validates: %v", err)
	}
	cfg.Pool.LosslessnessProbe.IntervalS = 3599
	if err := cfg.Validate(); err == nil {
		t.Fatal("non-SPEC losslessness interval accepted")
	}
	cfg.Pool.LosslessnessProbe.IntervalS = 3600
	cfg.Pool.LosslessnessProbe.TimeoutS = 61
	if err := cfg.Validate(); err == nil {
		t.Fatal("non-SPEC losslessness timeout accepted")
	}
	cfg.Pool.LosslessnessProbe.TimeoutS = 60
	cfg.Pool.LosslessnessProbe.MaxConcurrentPerProvider = 2
	if err := cfg.Validate(); err == nil {
		t.Fatal("unsafe losslessness concurrency accepted")
	}
}

func TestLosslessnessTier2UsesDedicatedCarrier(t *testing.T) {
	s, provider, _ := newEncryptedRelayHarness(t)
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("missing session")
	}
	payload := []byte(`{"type":"losslessness_probe_v1.request","probe_id":"probe-1","probe_request_digest":"sha256:test","payload":{"probe_id":"probe-1"}}`)
	inferenceFrame, err := session.sealInferenceRequest(*provider, "probe-1", payload, false, nil, "")
	if err != nil {
		t.Fatalf("baseline inference seal: %v", err)
	}
	if bytes.Contains(inferenceFrame, []byte(losslessnessEncryptedRequestType)) {
		t.Fatal("inference_request carrier accidentally used losslessness type")
	}

	sealed, err := session.sealLosslessnessProbeRequest(*provider, "probe-2", payload)
	if err != nil {
		t.Fatalf("seal losslessness request: %v", err)
	}
	var frame encryptedLosslessnessRequest
	if err := json.Unmarshal(sealed, &frame); err != nil {
		t.Fatalf("json: %v", err)
	}
	if frame.Type != losslessnessEncryptedRequestType || frame.RequestID != "probe-2" || frame.Stream || !frame.Encrypted {
		t.Fatalf("frame = %+v", frame)
	}
	aad := tier2.AEADFrameAAD{
		Type:       losslessnessEncryptedRequestType,
		Direction:  "c2p",
		RequestID:  "probe-2",
		Stream:     false,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        1,
	}
	opened, err := tier2.OpenPillarBFrame(provider.Tier2Session.C2PKey, provider.Tier2Session.C2PNonceBase, provider.Tier2Session.KeyID, 1, aad, tier2.AEADEnvelope{Encrypted: true, Enc: frame.Enc})
	if err != nil {
		t.Fatalf("open losslessness request: %v", err)
	}
	var plaintext encryptedLosslessnessPlaintext
	if err := json.Unmarshal(opened, &plaintext); err != nil {
		t.Fatal(err)
	}
	if plaintext.Type != losslessnessRequestPlaintextType || !bytes.Equal(plaintext.Payload, payload) {
		t.Fatalf("plaintext = %+v", plaintext)
	}
}

func TestLosslessnessCorpusRejectsBuyerOriginPrompts(t *testing.T) {
	err := ValidateLosslessnessCorpusPrompt(LosslessnessPromptPayload{
		PromptID:         "buyer-derived",
		Prompt:           "secret buyer prompt",
		CoordinatorOwned: true,
		BuyerOrigin:      true,
	})
	if err == nil {
		t.Fatal("buyer-origin corpus prompt accepted")
	}
}

func TestLosslessnessPendingProbeBindsNonceDigestExpiryAndSingleUse(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop(), WithNow(func() time.Time { return now }))
	request := losslessnessTestRequestPayload(now.Add(time.Minute))
	pending, err := s.recordLosslessnessPendingProbe("provider-a", "assigned-a", request, "sha256:req", now)
	if err != nil {
		t.Fatal(err)
	}
	result := LosslessnessProbeResultPayload{
		ProbeID:            request.ProbeID,
		ProbeNonce:         "wrong",
		ProbeRequestDigest: "sha256:req",
	}
	if _, err := s.consumeLosslessnessPendingProbe("provider-a", "assigned-a", result, now); err == nil {
		t.Fatal("nonce mismatch accepted")
	}
	s.losslessnessPending.Store(losslessnessProbeStoreKey("provider-a", "assigned-a", request.ProbeID), pending)
	result.ProbeNonce = request.ProbeNonce
	result.ProbeRequestDigest = "sha256:wrong"
	if _, err := s.consumeLosslessnessPendingProbe("provider-a", "assigned-a", result, now); err == nil {
		t.Fatal("digest mismatch accepted")
	}
	s.losslessnessPending.Store(losslessnessProbeStoreKey("provider-a", "assigned-a", request.ProbeID), pending)
	result.ProbeRequestDigest = "sha256:req"
	if _, err := s.consumeLosslessnessPendingProbe("provider-a", "assigned-a", result, now.Add(2*time.Minute)); err == nil {
		t.Fatal("expired result accepted")
	}
	s.losslessnessPending.Store(losslessnessProbeStoreKey("provider-a", "assigned-a", request.ProbeID), pending)
	if _, err := s.consumeLosslessnessPendingProbe("provider-a", "assigned-a", result, now); err != nil {
		t.Fatalf("valid result rejected: %v", err)
	}
	if _, err := s.consumeLosslessnessPendingProbe("provider-a", "assigned-a", result, now); err == nil {
		t.Fatal("replayed result accepted")
	}
}

func TestLosslessnessPendingProbeRejectsDuplicateIndexes(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop(), WithNow(func() time.Time { return now }))
	request := losslessnessTestRequestPayload(now.Add(time.Minute))
	if _, err := s.recordLosslessnessPendingProbe("provider-a", "assigned-a", request, "sha256:req", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.recordLosslessnessPendingProbe("provider-a", "assigned-a", request, "sha256:req-2", now); err == nil {
		t.Fatal("duplicate probe_id accepted")
	}
	duplicateNonce := request
	duplicateNonce.ProbeID = "probe-b"
	if _, err := s.recordLosslessnessPendingProbe("provider-a", "assigned-a", duplicateNonce, "sha256:req-b", now); err == nil {
		t.Fatal("duplicate nonce accepted")
	}
	duplicateDigest := request
	duplicateDigest.ProbeID = "probe-c"
	duplicateDigest.ProbeNonce = "nonce-c"
	if _, err := s.recordLosslessnessPendingProbe("provider-a", "assigned-a", duplicateDigest, "sha256:req", now); err == nil {
		t.Fatal("duplicate request digest accepted")
	}
}

func TestLosslessnessHandlerRequiresPendingProbeAndPersistsProfileState(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop(), WithNow(func() time.Time { return now }))
	request := losslessnessTestRequestPayload(now.Add(time.Minute))
	result := losslessnessProviderInconclusivePayload(request.ProbeID, request.ProbeNonce, "sha256:req")
	cleartext := losslessnessResultOuter(t, result, "sha256:req")
	s.handleLosslessnessProbeResult("provider-a", "assigned-a", cleartext)
	if _, ok := s.losslessnessProfileSnapshot(losslessnessProfile(0.7)); ok {
		t.Fatal("result without pending probe created profile state")
	}
	if _, err := s.recordLosslessnessPendingProbe("provider-a", "assigned-a", request, "sha256:req", now); err != nil {
		t.Fatal(err)
	}
	s.handleLosslessnessProbeResult("provider-a", "assigned-a", cleartext)
	record, ok := s.losslessnessProfileSnapshot(losslessnessProfile(0.7))
	if !ok {
		t.Fatal("pending result did not create profile state")
	}
	if record.State != LosslessnessStatusBlocked || record.ReasonCode != "inconclusive:unsupported_sampler" {
		t.Fatalf("record = %+v, want blocked unsupported_sampler", record)
	}
	s.handleLosslessnessProbeResult("provider-a", "assigned-a", cleartext)
	recordAfterReplay, _ := s.losslessnessProfileSnapshot(losslessnessProfile(0.7))
	if len(recordAfterReplay.AbusiveInconclusiveEvents) != len(record.AbusiveInconclusiveEvents) {
		t.Fatalf("replay mutated profile events: before=%d after=%d", len(record.AbusiveInconclusiveEvents), len(recordAfterReplay.AbusiveInconclusiveEvents))
	}
}

func TestLosslessnessHandlerRejectsPlaintextResultForTier2Session(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s, provider, _ := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), now)
	s.now = func() time.Time { return now }
	request := losslessnessTestRequestPayload(now.Add(time.Minute))
	if _, err := s.recordLosslessnessPendingProbe(provider.ProviderID, provider.AssignedID, request, "sha256:req", now); err != nil {
		t.Fatal(err)
	}
	result := losslessnessProviderInconclusivePayload(request.ProbeID, request.ProbeNonce, "sha256:req")
	s.handleLosslessnessProbeResult(provider.ProviderID, provider.AssignedID, losslessnessResultOuter(t, result, "sha256:req"))
	if _, ok := s.losslessnessProfileSnapshot(losslessnessProfile(0.7)); ok {
		t.Fatal("plaintext result for active tier2 session created profile state")
	}
	if _, ok := s.losslessnessPending.Load(losslessnessProbeStoreKey(provider.ProviderID, provider.AssignedID, request.ProbeID)); !ok {
		t.Fatal("plaintext tier2 rejection consumed pending probe")
	}
}

func TestLosslessnessIssueProbeSeedsPendingAndUsesDedicatedCarrier(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s, provider, providerConn := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), now)
	s.now = func() time.Time { return now }
	seedLosslessnessDraftAdmission(t, s, provider, now.Add(time.Hour))
	if err := s.issueLosslessnessProbeRequest(*provider, LosslessnessSamplingProfile{Temperature: 0.7, TopP: 1}); err != nil {
		t.Fatalf("issue probe: %v", err)
	}
	if err := providerConn.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	frame, err := gobwas.ReadFrame(providerConn)
	if err != nil {
		t.Fatalf("read probe frame: %v", err)
	}
	var carrier encryptedLosslessnessRequest
	if err := json.Unmarshal(frame.Payload, &carrier); err != nil {
		t.Fatal(err)
	}
	if carrier.Type != losslessnessEncryptedRequestType || carrier.RequestID == "" || !carrier.Encrypted || carrier.Stream {
		t.Fatalf("carrier = %+v", carrier)
	}
	value, ok := s.losslessnessPending.Load(losslessnessProbeStoreKey(provider.ProviderID, provider.AssignedID, carrier.RequestID))
	if !ok {
		t.Fatal("issued probe did not seed pending store")
	}
	pending := value.(losslessnessPendingProbe)
	if pending.VocabSize <= 0 || pending.ExpectedContextHash[0] == "" || len(pending.OfflinePlainSupport[0]) == 0 {
		t.Fatalf("pending missing safety metadata: %+v", pending)
	}
	if len(pending.RequestedPositions) != 8 || !pending.HighEntropyPosition[0] {
		t.Fatalf("pending missing requested/high-entropy metadata: %+v", pending)
	}
}

func TestLosslessnessIssueProbeBlocksWithoutDraftAdmission(t *testing.T) {
	now := time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s, provider, _ := newEncryptedRelayHarnessWithConfig(t, cfg, zerolog.Nop(), now)
	s.now = func() time.Time { return now }
	if err := s.issueLosslessnessProbeRequest(*provider, LosslessnessSamplingProfile{Temperature: 0.7, TopP: 1}); err == nil {
		t.Fatal("probe issued without draft admission")
	}
	events := s.losslessnessTelemetrySnapshot()
	if len(events) != 1 || events[0].EventSubtype != "admission_blocked" || events[0].ReasonCode != "inconclusive:draft_identity_unbound" {
		t.Fatalf("admission-blocked telemetry = %+v", events)
	}
}

func TestLosslessnessSchedulerRotatesDefaultProfiles(t *testing.T) {
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop())
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "assigned-a", ModelID: "model-a"}
	want := LosslessnessDefaultProfiles()
	for i, expected := range append(want, want[0]) {
		got := s.nextLosslessnessProfile(provider)
		if got != expected {
			t.Fatalf("profile[%d] = %+v, want %+v", i, got, expected)
		}
	}
}

func TestLosslessnessMeasurementVerdictFailsClosedWithoutSafetyMetadataAndRequiresK256Retry(t *testing.T) {
	pos := validLosslessnessPosition()
	expected := expectedLosslessnessIdentity()
	result := LosslessnessProbeResultPayload{
		ProbeID:              "probe-a",
		ProbeNonce:           "nonce-a",
		ProbeRequestDigest:   "sha256:req",
		ResultKind:           "measurement",
		TargetModelHash:      "sha256:target",
		TargetGeneration:     1,
		DraftArtifactBinding: &expected.DraftArtifactBinding,
		DraftGeneration:      1,
		TokenizerIdentity:    "tok-v1",
		Positions:            []LosslessnessPositionDistribution{pos},
	}
	pending := losslessnessPendingProbe{
		RequestedK:        64,
		TokenizerIdentity: "tok-v1",
		ExpectedIdentity:  *expected,
	}
	if got := losslessnessReasonForMeasurement(result, pending); got != "inconclusive:position_mismatch" {
		t.Fatalf("missing metadata reason = %q", got)
	}
	pending.VocabSize = 70
	pending.RequestedPositions = map[int]struct{}{pos.PositionIndex: struct{}{}}
	pending.ExpectedContextHash = map[int]string{pos.PositionIndex: pos.ContextHash}
	pending.HighEntropyPosition = map[int]bool{pos.PositionIndex: true}
	pending.OfflinePlainSupport = map[int][]LosslessnessTokenProbability{pos.PositionIndex: pos.OfflinePlainSupport}
	pos.HighEntropy = false
	result.Positions = []LosslessnessPositionDistribution{pos}
	if got := losslessnessReasonForMeasurement(result, pending); got != "inconclusive:tail_mass_high" {
		t.Fatalf("K=64 retry reason = %q", got)
	}
	extraPos := pos
	extraPos.PositionIndex = 99
	result.Positions = []LosslessnessPositionDistribution{pos, extraPos}
	if got := losslessnessReasonForMeasurement(result, pending); got != "inconclusive:position_mismatch" {
		t.Fatalf("extra position reason = %q", got)
	}
	if losslessnessCanonicalMedian([]float64{0.03, 0.01, 0.02, 0.04}) != 0.02 {
		t.Fatal("canonical median did not use lower-middle index")
	}
}

func BenchmarkLosslessnessDispatchDisabledDefault(b *testing.B) {
	cfg := config.Default()
	registry := losslessnessBenchmarkRegistry(100, pool.StateReady)
	s := NewServer(cfg, registry, zerolog.Nop())

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		s.dispatchLosslessnessProbeRound()
	}
}

func BenchmarkLosslessnessDispatchEnabledUnavailableProviders(b *testing.B) {
	cfg := config.Default()
	cfg.Pool.LosslessnessProbe.Enabled = true
	cfg.Pool.LosslessnessProbe.IntervalS = 0
	registry := losslessnessBenchmarkRegistry(100, pool.StateUnavailable)
	s := NewServer(cfg, registry, zerolog.Nop())

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		s.dispatchLosslessnessProbeRound()
	}
}

func BenchmarkLosslessnessValidateDistributionK64(b *testing.B) {
	pos := validLosslessnessPosition()
	expected := expectedLosslessnessIdentity()

	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		result := ValidateLosslessnessDistribution(pos, 64, 70, "tok-v1", "sha256:ctx", expected, true, pos.OfflinePlainSupport)
		if result.ReasonCode != "valid" {
			b.Fatalf("reason = %q", result.ReasonCode)
		}
	}
}

type losslessnessFixture struct {
	ID             string         `json:"id"`
	ExpectedSHA256 string         `json:"expected_sha256"`
	Payload        map[string]any `json:"payload"`
}

func loadLosslessnessFixtures(t *testing.T) []losslessnessFixture {
	t.Helper()
	path := filepath.Join("..", "..", "test", "jcs_fixtures", "spec029", "losslessness_probe_v1.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []losslessnessFixture
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatal(err)
	}
	return fixtures
}

func losslessnessBenchmarkRegistry(n int, state pool.State) *pool.Registry {
	registry := pool.NewRegistry(nil)
	for i := 0; i < n; i++ {
		suffix := strconv.Itoa(i)
		registry.Register(&pool.Provider{
			ProviderID:     "bench-provider-" + suffix,
			AssignedID:     "bench-session-" + suffix,
			ModelID:        "bench-model",
			State:          state,
			SlotsFree:      1,
			SlotsTotal:     1,
			MaxConcurrency: 1,
			Tier:           pool.TierProvisional,
			InferencePath:  pool.InferencePathWSTunneled,
			EncryptedLeg:   true,
		}, nil)
	}
	return registry
}

func validLosslessnessPosition() LosslessnessPositionDistribution {
	plainTop := make([]int, 64)
	specTop := make([]int, 64)
	for i := 0; i < 64; i++ {
		plainTop[i] = i
		specTop[i] = i
	}
	support := numericUnion(plainTop, specTop)
	plainSupport, plainTail := descendingSupport(support, 0)
	specSupport, specTail := descendingSupport(support, 1)
	return LosslessnessPositionDistribution{
		PositionIndex:     4,
		ContextHash:       "sha256:ctx",
		SupportSelection:  losslessnessSupportSelection,
		PlainTopKTokenIDs: plainTop,
		SpecTopKTokenIDs:  specTop,
		SupportTokenIDs:   support,
		PlainSupport:      plainSupport,
		PlainTailMass:     plainTail,
		SpecSupport:       specSupport,
		SpecTailMass:      specTail,
		TargetModelHash:   "sha256:target",
		TargetGeneration:  1,
		DraftArtifactBinding: LosslessnessDraftArtifactBinding{
			DraftModelID:             "draft-a",
			DraftArtifactSHA256:      "sha256:draft",
			TokenizerIdentity:        "tok-v1",
			CompatibilityCheckDigest: "sha256:compat",
		},
		DraftGeneration:     1,
		TokenizerIdentity:   "tok-v1",
		NormalizationBasis:  losslessnessNormalizationBasis,
		SamplerStage:        losslessnessSamplerStage,
		HighEntropy:         true,
		OfflinePlainSupport: plainSupport,
	}
}

func expectedLosslessnessIdentity() *LosslessnessExpectedPositionIdentity {
	return &LosslessnessExpectedPositionIdentity{
		TargetModelHash:  "sha256:target",
		TargetGeneration: 1,
		DraftArtifactBinding: LosslessnessDraftArtifactBinding{
			DraftModelID:             "draft-a",
			DraftArtifactSHA256:      "sha256:draft",
			TokenizerIdentity:        "tok-v1",
			CompatibilityCheckDigest: "sha256:compat",
		},
		DraftGeneration: 1,
	}
}

func validLosslessnessPositionK256TailHigh() LosslessnessPositionDistribution {
	top := make([]int, 256)
	probs := make([]LosslessnessTokenProbability, 256)
	for i := 0; i < 256; i++ {
		top[i] = i
		probs[i] = LosslessnessTokenProbability{TokenID: i, P: 0.994 / 256.0}
	}
	pos := validLosslessnessPosition()
	pos.PlainTopKTokenIDs = top
	pos.SpecTopKTokenIDs = top
	pos.SupportTokenIDs = append([]int(nil), top...)
	pos.PlainSupport = probs
	pos.SpecSupport = probs
	pos.PlainTailMass = 0.006
	pos.SpecTailMass = 0.006
	pos.OfflinePlainSupport = probs
	return pos
}

func descendingSupport(ids []int, offset int) ([]LosslessnessTokenProbability, float64) {
	out := make([]LosslessnessTokenProbability, 0, len(ids))
	var sum float64
	for _, id := range ids {
		p := float64(80-id-offset) / 10000.0
		if p < 0.0001 {
			p = 0.0001
		}
		out = append(out, LosslessnessTokenProbability{TokenID: id, P: p})
		sum += p
	}
	return out, 1 - sum
}

func losslessnessProfile(temp float64) LosslessnessProfileKey {
	return LosslessnessProfileKey{
		ProviderID:       "provider-a",
		AssignedID:       "assigned-a",
		ModelID:          "model-a",
		TargetModelHash:  "sha256:target",
		TargetGeneration: 1,
		DraftModelID:     "draft-a",
		DraftArtifactBinding: LosslessnessDraftArtifactBinding{
			DraftModelID:             "draft-a",
			DraftArtifactSHA256:      "sha256:draft",
			TokenizerIdentity:        "tok-v1",
			CompatibilityCheckDigest: "sha256:compat",
		},
		DraftGeneration:  1,
		SamplingProfile:  LosslessnessSamplingProfile{Temperature: temp, TopP: 1},
		CorpusVersion:    "corpus-v1",
		ThresholdVersion: "threshold-v1",
	}
}

func losslessnessTestRequestPayload(expiresAt time.Time) LosslessnessProbeRequestPayload {
	pos := validLosslessnessPosition()
	return LosslessnessProbeRequestPayload{
		ProbeVersion:     LosslessnessProbeVersion,
		ProbeID:          "probe-a",
		ProbeNonce:       "nonce-a",
		ExpiresAt:        expiresAt.UTC().Format(time.RFC3339Nano),
		ModelID:          "model-a",
		TargetModelHash:  "sha256:target",
		TargetGeneration: 1,
		DraftModelID:     "draft-a",
		DraftArtifactBinding: LosslessnessDraftArtifactBinding{
			DraftModelID:             "draft-a",
			DraftArtifactSHA256:      "sha256:draft",
			TokenizerIdentity:        "tok-v1",
			CompatibilityCheckDigest: "sha256:compat",
		},
		DraftGeneration:        1,
		TokenizerIdentity:      "tok-v1",
		SamplingProfile:        LosslessnessSamplingProfile{Temperature: 0.7, TopP: 1},
		CorpusVersion:          "corpus-v1",
		ThresholdVersion:       "threshold-v1",
		MeasurementPositions:   []int{pos.PositionIndex},
		RequestedK:             64,
		SupportSelection:       losslessnessSupportSelection,
		MaxPrompts:             4,
		MaxStochasticPositions: 8,
		TimeoutMS:              60000,
		VocabSize:              70,
		PositionContextHashes:  map[int]string{pos.PositionIndex: pos.ContextHash},
		HighEntropyPositions:   map[int]bool{pos.PositionIndex: true},
		OfflinePlainSupport:    map[int][]LosslessnessTokenProbability{pos.PositionIndex: pos.OfflinePlainSupport},
	}
}

func seedLosslessnessDraftAdmission(t *testing.T, s *Server, provider *pool.Provider, expiresAt time.Time) {
	t.Helper()
	s.recordLosslessnessDraftAdmission(LosslessnessDraftAdmissionRecord{
		ProviderID:       provider.ProviderID,
		AssignedID:       provider.AssignedID,
		ModelID:          provider.ModelID,
		TargetModelHash:  "sha256:target",
		TargetGeneration: 1,
		DraftModelID:     "draft-a",
		DraftArtifactBinding: LosslessnessDraftArtifactBinding{
			DraftModelID:             "draft-a",
			DraftArtifactSHA256:      "sha256:draft",
			TokenizerIdentity:        "tok-v1",
			CompatibilityCheckDigest: "sha256:compat",
		},
		DraftGeneration:   1,
		TokenizerIdentity: "tok-v1",
		ExpiresAt:         expiresAt,
	})
}

func losslessnessProviderInconclusivePayload(probeID, nonce, requestDigest string) map[string]any {
	return map[string]any{
		"probe_id":                    probeID,
		"probe_nonce":                 nonce,
		"probe_request_digest":        requestDigest,
		"result_kind":                 "provider_inconclusive",
		"provider_reason_code":        "inconclusive:unsupported_sampler",
		"identity_unavailable_reason": "sampler hook unavailable",
		"target_model_hash":           nil,
		"target_generation":           nil,
		"draft_artifact_binding":      nil,
		"draft_generation":            nil,
	}
}

func losslessnessResultOuter(t *testing.T, payload map[string]any, requestDigest string) []byte {
	t.Helper()
	payloadRaw := mustMarshal(t, payload)
	resultDigest, err := LosslessnessDigest(payloadRaw)
	if err != nil {
		t.Fatal(err)
	}
	return mustMarshal(t, map[string]any{
		"type":                 losslessnessResultType,
		"probe_id":             payload["probe_id"],
		"probe_request_digest": requestDigest,
		"probe_result_digest":  resultDigest,
		"payload":              json.RawMessage(payloadRaw),
	})
}

func mustMarshal(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestLosslessnessPlaintextTier2ResultOpensDedicatedCarrier(t *testing.T) {
	_, provider, _ := newEncryptedRelayHarness(t)
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 4)
	session.useTier2Session(provider.Tier2Session)

	cleartext := []byte(`{"type":"losslessness_probe_v1.result","probe_id":"probe-result","probe_request_digest":"sha256:req","probe_result_digest":"sha256:res","payload":{"probe_id":"probe-result"}}`)
	plaintext, err := json.Marshal(encryptedLosslessnessPlaintext{Type: losslessnessResultPlaintextType, Payload: cleartext})
	if err != nil {
		t.Fatal(err)
	}
	aad := tier2.AEADFrameAAD{
		Type:       losslessnessEncryptedResultType,
		Direction:  "p2c",
		RequestID:  "probe-result",
		Stream:     false,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        0,
	}
	envelope, err := tier2.SealPillarBFrame(provider.Tier2Session.P2CKey, provider.Tier2Session.P2CNonceBase, provider.Tier2Session.KeyID, 0, aad, plaintext)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := session.openLosslessnessProbeResult(*provider, "probe-result", envelope)
	if err != nil {
		t.Fatalf("open result: %v", err)
	}
	if !bytes.Equal(opened, cleartext) {
		t.Fatalf("opened = %s", opened)
	}
}
