package ws

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestNativeMTPChallengeBankStrictValidation(t *testing.T) {
	t.Parallel()
	raw, binding := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatalf("valid bank rejected: %v", err)
	}
	if bank.SchemaVersion != nativeMTPChallengeBankSchemaVersion || bank.RawSHA256 != binding.ExpectedSHA256 {
		t.Fatalf("bank = %+v", bank)
	}
	if len(bank.Entries) != 2 || bank.Entries[0].ChallengeID != "challenge-a" || bank.Entries[1].ChallengeID != "challenge-b" {
		t.Fatalf("entries not preserved/sorted: %+v", bank.Entries)
	}
	duplicate := []byte(`{"schema_version":"macprovider.native-mtp-challenge-bank.v1","schema_version":"macprovider.native-mtp-challenge-bank.v1","release_id":"release-2026-09-28","issued_at":"2026-09-28T00:00:00Z","expires_at":"2026-09-29T00:00:00Z","signer_key_id":"challenge-bank-key-v1","entries":[]}`)
	duplicateBinding := binding
	sum := sha256.Sum256(duplicate)
	duplicateBinding.ExpectedSHA256 = hex.EncodeToString(sum[:])
	if _, err := ParseNativeMTPChallengeBank(duplicate, duplicateBinding); err == nil {
		t.Fatal("duplicate top-level field accepted")
	}

	cases := map[string]func([]byte) []byte{
		"unknown top field": func(raw []byte) []byte {
			var obj map[string]any
			mustUnmarshalNativeMTP(t, raw, &obj)
			obj["buyer_id"] = "must-not-exist"
			return mustMarshalNativeMTP(t, obj)
		},
		"unsorted challenge ids": func(raw []byte) []byte {
			var obj map[string]any
			mustUnmarshalNativeMTP(t, raw, &obj)
			entries := obj["entries"].([]any)
			entries[0], entries[1] = entries[1], entries[0]
			obj["entries"] = entries
			return mustMarshalNativeMTP(t, obj)
		},
		"prompt token bound": func(raw []byte) []byte {
			var obj map[string]any
			mustUnmarshalNativeMTP(t, raw, &obj)
			entry := obj["entries"].([]any)[0].(map[string]any)
			entry["prompt_token_ids"] = make([]uint32, nativeMTPCanaryMaxPromptTokens+1)
			return mustMarshalNativeMTP(t, obj)
		},
		"completion bound": func(raw []byte) []byte {
			var obj map[string]any
			mustUnmarshalNativeMTP(t, raw, &obj)
			entry := obj["entries"].([]any)[0].(map[string]any)
			entry["max_completion_tokens"] = nativeMTPCanaryMaxCompletionTokens + 1
			return mustMarshalNativeMTP(t, obj)
		},
		"depth bound": func(raw []byte) []byte {
			var obj map[string]any
			mustUnmarshalNativeMTP(t, raw, &obj)
			entry := obj["entries"].([]any)[0].(map[string]any)
			entry["fixed_proposal_depth"] = 0
			return mustMarshalNativeMTP(t, obj)
		},
		"counter shape": func(raw []byte) []byte {
			var obj map[string]any
			mustUnmarshalNativeMTP(t, raw, &obj)
			entry := obj["entries"].([]any)[0].(map[string]any)
			counters := entry["expected_counters"].(map[string]any)
			counters["settlement"] = 1
			return mustMarshalNativeMTP(t, obj)
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			bad := mutate(raw)
			badBinding := binding
			sum := sha256.Sum256(bad)
			badBinding.ExpectedSHA256 = hex.EncodeToString(sum[:])
			if _, err := ParseNativeMTPChallengeBank(bad, badBinding); err == nil {
				t.Fatal("invalid bank accepted")
			}
		})
	}

	if _, err := ParseNativeMTPChallengeBank(raw, NativeMTPChallengeBankBinding{
		ReleaseID:          binding.ReleaseID,
		SidecarValidFrom:   binding.SidecarValidFrom,
		SidecarValidUntil:  binding.SidecarValidUntil,
		SignerKeyID:        binding.SignerKeyID,
		EnvelopeKeyID:      "other-key",
		ExpectedSHA256:     binding.ExpectedSHA256,
		AdmissionModelID:   binding.AdmissionModelID,
		AdmissionModelHash: binding.AdmissionModelHash,
	}); err == nil {
		t.Fatal("envelope signer mismatch accepted")
	}
}

func TestNativeMTPCanaryCoreRequestAndResultEvaluation(t *testing.T) {
	t.Parallel()
	raw, binding := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatal(err)
	}
	record := bank.Entries[0]
	now := time.Date(2026, 9, 28, 10, 0, 0, 0, time.UTC)
	tuple := nativeMTPTuple(bank.RawSHA256)
	req, err := NewNativeMTPCanaryCoreRequestWithNonce(tuple, record, strings.Repeat("a", 32), now)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	pass := NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		RequestID:                  req.RequestDigestSHA256,
		ProviderID:                 req.ProviderID,
		AssignedID:                 req.AssignedID,
		TargetGeneration:           req.TargetGeneration,
		ProviderRevision:           "1.8.123",
		RuntimeRevision:            "mlx-swift-lm-e874140",
		RuntimeTupleSHA256:         req.RuntimeTupleSHA256,
		ChallengeBankSHA256:        req.ChallengeBankSHA256,
		ChallengeID:                req.ChallengeID,
		Nonce:                      req.Nonce,
		RequestDigestSHA256:        req.RequestDigestSHA256,
		ActualDecodePath:           "native_mtp",
		FallbackUsed:               false,
		ExpectedTokenIDSHA256:      req.ExpectedTokenIDSHA256,
		ActualTokenIDSHA256:        record.ExpectedTokenIDSHA256,
		ActualTerminalReason:       record.ExpectedTerminalReason,
		ActualCounters:             record.ExpectedCounters,
		ActualCommittedStateSHA256: record.ExpectedCommittedStateSHA256,
		RuntimeTuple:               nativeMTPCoreRuntimeTuple(record),
	}
	pass.ResultDigestSHA256 = pass.resultDigest()
	if got := EvaluateNativeMTPCanaryCoreResult(req, record, pass, now.Add(time.Second)); got.Outcome != NativeMTPCanaryPass || got.DisableTupleOnly {
		t.Fatalf("pass evaluation = %+v", got)
	}

	fallback := pass
	fallback.ActualDecodePath = "ordinary"
	fallback.ResultDigestSHA256 = fallback.resultDigest()
	got := EvaluateNativeMTPCanaryCoreResult(req, record, fallback, now.Add(time.Second))
	if got.Outcome != NativeMTPCanaryFail || got.Reason != "unsupported_path_fallback" || !got.DisableTupleOnly {
		t.Fatalf("fallback evaluation = %+v", got)
	}

	capacity := pass
	capacity.CapacityUnavailable = true
	capacity.ResultDigestSHA256 = capacity.resultDigest()
	got = EvaluateNativeMTPCanaryCoreResult(req, record, capacity, now.Add(time.Second))
	if got.Outcome != NativeMTPCanaryReschedule || got.DisableTupleOnly {
		t.Fatalf("capacity evaluation = %+v", got)
	}
	staleCapacity := capacity
	staleCapacity.Nonce = strings.Repeat("0", 32)
	staleCapacity.ResultDigestSHA256 = staleCapacity.resultDigest()
	got = EvaluateNativeMTPCanaryCoreResult(req, record, staleCapacity, now.Add(time.Second))
	if got.Outcome != NativeMTPCanaryFail || got.Reason != "binding_mismatch" || !got.DisableTupleOnly {
		t.Fatalf("stale capacity evaluation = %+v", got)
	}

	late := EvaluateNativeMTPCanaryCoreResult(req, record, pass, req.ExpiresAt.Add(time.Nanosecond))
	if late.Outcome != NativeMTPCanaryFail || late.Reason != "expired_result" || !late.DisableTupleOnly {
		t.Fatalf("late evaluation = %+v", late)
	}
}

func TestNativeMTPCanaryCoreResultDigestMatchesWireVector(t *testing.T) {
	t.Parallel()
	result := NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		RequestID:                  "canary-1",
		ProviderID:                 "provider-a",
		AssignedID:                 "assigned-a",
		TargetGeneration:           7,
		ProviderRevision:           "1.8.123",
		RuntimeRevision:            "mlx-swift-lm-e874140",
		RuntimeTupleSHA256:         "919d2f171e70f1cca3bc93b88cb4234f13fe4cda883ad69b976a4169a3a3bc24",
		ChallengeBankSHA256:        strings.Repeat("4", 64),
		ChallengeID:                "challenge-a",
		Nonce:                      "0123456789abcdef0123456789abcdef",
		RequestDigestSHA256:        strings.Repeat("6", 64),
		ActualDecodePath:           "native_mtp",
		FallbackUsed:               true,
		ExpectedTokenIDSHA256:      strings.Repeat("5", 64),
		ActualTokenIDSHA256:        strings.Repeat("5", 64),
		ActualTerminalReason:       "passed",
		ActualCounters:             NativeMTPCanaryExpectedCounters{Accepted: 2, Rejected: 1, Bonus: 0, Committed: 3},
		ActualCommittedStateSHA256: strings.Repeat("2", 64),
		RuntimeTuple:               nativeMTPTestRuntimeTuple(),
	}
	if got, want := result.resultDigest(), "0e19abd8896de79b7fc46ad56630647d27551aafe57c95f579527eb02eab5e2f"; got != want {
		t.Fatalf("core result digest = %s, want %s", got, want)
	}
}

func TestNativeMTPCanaryStoreIsTupleScopedAndReplaySafe(t *testing.T) {
	t.Parallel()
	raw, binding := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatal(err)
	}
	record := bank.Entries[0]
	now := time.Date(2026, 9, 28, 11, 0, 0, 0, time.UTC)
	tuple := nativeMTPTuple(bank.RawSHA256)
	req, err := NewNativeMTPCanaryCoreRequestWithNonce(tuple, record, strings.Repeat("b", 32), now)
	if err != nil {
		t.Fatal(err)
	}
	store := NewMemoryNativeMTPCanaryStateStore()
	if err := store.BeginNativeMTPCanary(tuple, req, now); err != nil {
		t.Fatalf("begin: %v", err)
	}
	if err := store.BeginNativeMTPCanary(tuple, req, now.Add(time.Second)); err != errNativeMTPCanaryInFlight {
		t.Fatalf("second begin err = %v", err)
	}
	otherTuple := tuple
	otherTuple.RuntimeTupleSHA256 = strings.Repeat("3", 64)
	otherReq, err := NewNativeMTPCanaryCoreRequestWithNonce(otherTuple, record, strings.Repeat("c", 32), now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BeginNativeMTPCanary(otherTuple, otherReq, now.Add(time.Second)); err != nil {
		t.Fatalf("different tuple should have independent in-flight slot: %v", err)
	}

	result := NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		RequestID:                  req.RequestDigestSHA256,
		ProviderID:                 req.ProviderID,
		AssignedID:                 req.AssignedID,
		TargetGeneration:           req.TargetGeneration,
		ProviderRevision:           "1.8.123",
		RuntimeRevision:            "mlx-swift-lm-e874140",
		RuntimeTupleSHA256:         req.RuntimeTupleSHA256,
		ChallengeBankSHA256:        req.ChallengeBankSHA256,
		ChallengeID:                req.ChallengeID,
		Nonce:                      req.Nonce,
		RequestDigestSHA256:        req.RequestDigestSHA256,
		ActualDecodePath:           "native_mtp",
		ExpectedTokenIDSHA256:      req.ExpectedTokenIDSHA256,
		ActualTokenIDSHA256:        record.ExpectedTokenIDSHA256,
		ActualTerminalReason:       record.ExpectedTerminalReason,
		ActualCounters:             record.ExpectedCounters,
		ActualCommittedStateSHA256: record.ExpectedCommittedStateSHA256,
		RuntimeTuple:               nativeMTPCoreRuntimeTuple(record),
	}
	result.ResultDigestSHA256 = result.resultDigest()
	eval := EvaluateNativeMTPCanaryCoreResult(req, record, result, now.Add(time.Second))
	if err := store.CompleteNativeMTPCanary(tuple, req, result, eval, 0, now.Add(time.Second)); err != nil {
		t.Fatalf("complete: %v", err)
	}
	state, ok := store.NativeMTPCanaryState(tuple, now.Add(time.Second))
	if !ok || state.Status != NativeMTPCanaryTupleFresh || state.FreshUntil.Sub(now.Add(time.Second)) != 2*nativeMTPCanaryDefaultInterval {
		t.Fatalf("fresh state = %+v ok=%v", state, ok)
	}
	if err := store.BeginNativeMTPCanary(tuple, req, now.Add(2*time.Second)); err != errNativeMTPCanaryReplay {
		t.Fatalf("replay begin err = %v", err)
	}

	failingReq, err := NewNativeMTPCanaryCoreRequestWithNonce(tuple, record, strings.Repeat("d", 32), req.ExpiresAt.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BeginNativeMTPCanary(tuple, failingReq, req.ExpiresAt.Add(time.Second)); err != nil {
		t.Fatalf("begin failing request: %v", err)
	}
	failingResult := result
	failingResult.RequestID = failingReq.RequestDigestSHA256
	failingResult.Nonce = failingReq.Nonce
	failingResult.RequestDigestSHA256 = failingReq.RequestDigestSHA256
	failingResult.ActualDecodePath = "classic_draft_spec"
	failingResult.ResultDigestSHA256 = failingResult.resultDigest()
	eval = EvaluateNativeMTPCanaryCoreResult(failingReq, record, failingResult, req.ExpiresAt.Add(2*time.Second))
	if err := store.CompleteNativeMTPCanary(tuple, failingReq, failingResult, eval, time.Minute, req.ExpiresAt.Add(2*time.Second)); err != nil {
		t.Fatalf("complete failure: %v", err)
	}
	state, _ = store.NativeMTPCanaryState(tuple, req.ExpiresAt.Add(2*time.Second))
	if state.Status != NativeMTPCanaryTupleDisabled || state.DisabledReason != "unsupported_path_fallback" {
		t.Fatalf("disabled state = %+v", state)
	}
	otherState, _ := store.NativeMTPCanaryState(otherTuple, now.Add(time.Second))
	if otherState.Status == NativeMTPCanaryTupleDisabled {
		t.Fatalf("other tuple was disabled by exact-tuple failure: %+v", otherState)
	}
}

func TestNativeMTPCanaryStoreTimeoutAndCapacityReschedule(t *testing.T) {
	t.Parallel()
	raw, binding := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatal(err)
	}
	record := bank.Entries[0]
	now := time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)
	tuple := nativeMTPTuple(bank.RawSHA256)
	req, err := NewNativeMTPCanaryCoreRequestWithNonce(tuple, record, strings.Repeat("e", 32), now)
	if err != nil {
		t.Fatal(err)
	}
	store := NewMemoryNativeMTPCanaryStateStore()
	if err := store.BeginNativeMTPCanary(tuple, req, now); err != nil {
		t.Fatal(err)
	}
	expired, err := store.ExpireNativeMTPCanary(tuple, now.Add(nativeMTPCanaryDeadline+time.Nanosecond))
	if err != nil || !expired {
		t.Fatalf("expire = %v err=%v", expired, err)
	}
	state, _ := store.NativeMTPCanaryState(tuple, now.Add(nativeMTPCanaryDeadline+time.Nanosecond))
	if state.Status != NativeMTPCanaryTupleDisabled || state.DisabledReason != "timeout" {
		t.Fatalf("timeout state = %+v", state)
	}

	req2, err := NewNativeMTPCanaryCoreRequestWithNonce(tuple, record, strings.Repeat("f", 32), now.Add(2*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BeginNativeMTPCanary(tuple, req2, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	result := NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		RequestID:                  req2.RequestDigestSHA256,
		ProviderID:                 req2.ProviderID,
		AssignedID:                 req2.AssignedID,
		TargetGeneration:           req2.TargetGeneration,
		ProviderRevision:           "1.8.123",
		RuntimeRevision:            "mlx-swift-lm-e874140",
		RuntimeTupleSHA256:         req2.RuntimeTupleSHA256,
		ChallengeBankSHA256:        req2.ChallengeBankSHA256,
		ChallengeID:                req2.ChallengeID,
		Nonce:                      req2.Nonce,
		RequestDigestSHA256:        req2.RequestDigestSHA256,
		CapacityUnavailable:        true,
		ActualDecodePath:           "unavailable",
		ExpectedTokenIDSHA256:      req2.ExpectedTokenIDSHA256,
		ActualTokenIDSHA256:        record.ExpectedTokenIDSHA256,
		ActualTerminalReason:       record.ExpectedTerminalReason,
		ActualCounters:             record.ExpectedCounters,
		ActualCommittedStateSHA256: record.ExpectedCommittedStateSHA256,
		RuntimeTuple:               nativeMTPCoreRuntimeTuple(record),
	}
	result.ResultDigestSHA256 = result.resultDigest()
	eval := EvaluateNativeMTPCanaryCoreResult(req2, record, result, now.Add(2*time.Minute+time.Second))
	if err := store.CompleteNativeMTPCanary(tuple, req2, result, eval, time.Minute, now.Add(2*time.Minute+time.Second)); err != nil {
		t.Fatal(err)
	}
	state, _ = store.NativeMTPCanaryState(tuple, now.Add(2*time.Minute+time.Second))
	if state.Status == NativeMTPCanaryTupleDisabled || state.LastOutcome != NativeMTPCanaryReschedule || state.NextDueAt.Sub(now.Add(2*time.Minute+time.Second)) != nativeMTPCanaryMinimumInterval {
		t.Fatalf("capacity state = %+v", state)
	}
}

func nativeMTPValidBankFixture(t *testing.T) ([]byte, NativeMTPChallengeBankBinding) {
	t.Helper()
	base := time.Date(2026, 9, 28, 0, 0, 0, 0, time.UTC)
	modelHash := strings.Repeat("1", 64)
	obj := map[string]any{
		"schema_version": nativeMTPChallengeBankSchemaVersion,
		"release_id":     "release-2026-09-28",
		"issued_at":      base.Format(time.RFC3339),
		"expires_at":     base.Add(24 * time.Hour).Format(time.RFC3339),
		"signer_key_id":  "challenge-bank-key-v1",
		"entries": []any{
			nativeMTPChallengeEntry("challenge-a", modelHash),
			nativeMTPChallengeEntry("challenge-b", modelHash),
		},
	}
	raw := mustMarshalNativeMTP(t, obj)
	sum := sha256.Sum256(raw)
	return raw, NativeMTPChallengeBankBinding{
		ReleaseID:          "release-2026-09-28",
		SidecarValidFrom:   base.Add(-time.Hour),
		SidecarValidUntil:  base.Add(48 * time.Hour),
		SignerKeyID:        "challenge-bank-key-v1",
		EnvelopeKeyID:      "challenge-bank-key-v1",
		ExpectedSHA256:     hex.EncodeToString(sum[:]),
		AdmissionModelID:   "qwen3-fixture",
		AdmissionModelHash: modelHash,
	}
}

func nativeMTPChallengeEntry(challengeID string, modelHash string) map[string]any {
	expectedTokens := []uint32{42, 43}
	counters := map[string]any{"accepted": uint64(2), "rejected": uint64(0), "bonus": uint64(0), "committed": uint64(len(expectedTokens))}
	return map[string]any{
		"challenge_id":                    challengeID,
		"model_id":                        "qwen3-fixture",
		"model_hash":                      modelHash,
		"tokenizer_sha256":                strings.Repeat("2", 64),
		"artifact_sha256":                 strings.Repeat("3", 64),
		"mtp_manifest_sha256":             strings.Repeat("4", 64),
		"prompt_token_ids":                []uint32{10, 11, 12},
		"max_completion_tokens":           uint32(16),
		"fixed_proposal_depth":            uint32(2),
		"expected_token_ids":              expectedTokens,
		"expected_token_id_sha256":        digestTokenIDs(expectedTokens),
		"expected_terminal_reason":        "stop",
		"expected_counters":               counters,
		"expected_committed_state_sha256": strings.Repeat("6", 64),
	}
}

func nativeMTPTuple(bankSHA string) NativeMTPCanaryTupleKey {
	return NativeMTPCanaryTupleKey{
		ProviderID:          "provider-a",
		AssignedID:          "assigned-a",
		TargetGeneration:    7,
		RuntimeTupleSHA256:  strings.Repeat("7", 64),
		ChallengeBankSHA256: bankSHA,
	}
}

func nativeMTPCoreRuntimeTuple(record NativeMTPChallengeRecord) NativeMTPRuntimeTuple {
	return NativeMTPRuntimeTuple{
		ModelID:              record.ModelID,
		ModelHash:            record.ModelHash,
		ModelHashAlgorithm:   "sha256",
		ProviderRevision:     "1.8.123",
		RuntimeRevision:      "mlx-swift-lm-e874140",
		TokenizerDigest:      record.TokenizerSHA256,
		ArtifactDigest:       record.ArtifactSHA256,
		ManifestDigest:       record.MTPManifestSHA256,
		SidecarDigest:        strings.Repeat("8", 64),
		ProviderBinarySHA256: strings.Repeat("9", 64),
		RuntimeCDHash:        strings.Repeat("a", 64),
		CacheNamespace:       "native-mtp-test",
		StateDigest:          record.ExpectedCommittedStateSHA256,
		ProposalDepth:        int(record.FixedProposalDepth),
	}
}

func mustMarshalNativeMTP(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustUnmarshalNativeMTP(t *testing.T, raw []byte, v any) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatal(err)
	}
}
