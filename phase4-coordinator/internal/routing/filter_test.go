package routing_test

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// stubChecker is a hand-rolled EligibilityChecker for tests; the
// real implementation lives on internal/buyer/server.go.
type stubChecker struct {
	matches    map[string]bool
	contextOK  map[string]bool
	tier2      map[string]routing.RejectionReason
	tier2Hash  map[string]pool.HashStatus
	quotaOK    map[string]bool
}

func (s *stubChecker) ProviderMatchesRequest(p pool.Provider) bool {
	if v, ok := s.matches[p.ProviderID]; ok {
		return v
	}
	return true
}
func (s *stubChecker) ProviderContextSufficient(p pool.Provider) bool {
	if v, ok := s.contextOK[p.ProviderID]; ok {
		return v
	}
	return true
}
func (s *stubChecker) Tier2Decision(p pool.Provider) (routing.RejectionReason, pool.HashStatus) {
	return s.tier2[p.ProviderID], s.tier2Hash[p.ProviderID]
}
func (s *stubChecker) QuotaPermits(p pool.Provider) bool {
	if v, ok := s.quotaOK[p.ProviderID]; ok {
		return v
	}
	return true
}

func keyer(p pool.Provider) string { return p.ProviderID + "|" + p.AssignedID }

func mkProvider(id string) pool.Provider {
	return pool.Provider{ProviderID: id, AssignedID: "s-" + id}
}

func TestEligibleCandidates_AllEligibleNoCounts(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{mkProvider("a"), mkProvider("b"), mkProvider("c")}
	ex := routing.NewExcluded(0)
	res := routing.EligibleCandidates(providers, ex, keyer, &stubChecker{})
	if len(res.Eligible) != 3 {
		t.Fatalf("all-eligible: want 3, got %d", len(res.Eligible))
	}
	if len(res.Counts) != 0 {
		t.Fatalf("no rejections: want empty Counts, got %v", res.Counts)
	}
}

func TestEligibleCandidates_ExcludedSkippedBeforeAnyCheck(t *testing.T) {
	// Excluded providers MUST NOT count against any other rejection
	// reason — they short-circuit at the top of the loop. This pins
	// AC-SR-1 behavior for the retry / F-4 composition path.
	t.Parallel()
	providers := []pool.Provider{mkProvider("a"), mkProvider("b")}
	ex := routing.NewExcluded(1)
	ex.Add(providers[0], keyer)
	checker := &stubChecker{
		matches: map[string]bool{"a": false, "b": true}, // a would model-mismatch but excluded short-circuits
	}
	res := routing.EligibleCandidates(providers, ex, keyer, checker)
	if len(res.Eligible) != 1 || res.Eligible[0].ProviderID != "b" {
		t.Fatalf("want only b eligible, got %+v", res.Eligible)
	}
	if res.Counts[routing.ReasonExcluded] != 1 {
		t.Errorf("ReasonExcluded count: want 1, got %d", res.Counts[routing.ReasonExcluded])
	}
	if res.Counts[routing.ReasonModelMismatch] != 0 {
		t.Errorf("excluded should NOT also increment ReasonModelMismatch; got %d", res.Counts[routing.ReasonModelMismatch])
	}
}

func TestEligibleCandidates_ModelMismatchReason(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{mkProvider("a"), mkProvider("b")}
	checker := &stubChecker{matches: map[string]bool{"a": false}}
	res := routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	if len(res.Eligible) != 1 {
		t.Fatalf("want 1 eligible, got %d", len(res.Eligible))
	}
	if res.Counts[routing.ReasonModelMismatch] != 1 {
		t.Errorf("ReasonModelMismatch count: want 1, got %d", res.Counts[routing.ReasonModelMismatch])
	}
}

func TestEligibleCandidates_ContextRejectionStopsChecks(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{mkProvider("a")}
	checker := &stubChecker{
		contextOK: map[string]bool{"a": false},
		tier2:     map[string]routing.RejectionReason{"a": routing.ReasonTier2HashMismatch}, // should NOT increment
	}
	res := routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	if res.Counts[routing.ReasonContextTooSmall] != 1 {
		t.Errorf("ReasonContextTooSmall count: want 1")
	}
	if res.Counts[routing.ReasonTier2HashMismatch] != 0 {
		t.Errorf("context-rejected providers must NOT also count tier2 mismatch; got %d", res.Counts[routing.ReasonTier2HashMismatch])
	}
}

func TestEligibleCandidates_Tier2HashMismatchRecordedInList(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{mkProvider("bad"), mkProvider("good")}
	checker := &stubChecker{
		tier2:     map[string]routing.RejectionReason{"bad": routing.ReasonTier2HashMismatch},
		tier2Hash: map[string]pool.HashStatus{"bad": pool.HashStatusMismatch},
	}
	res := routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	if len(res.HashMismatches) != 1 || res.HashMismatches[0].Provider.ProviderID != "bad" {
		t.Fatalf("want HashMismatches=[bad], got %+v", res.HashMismatches)
	}
	if res.HashMismatches[0].HashStatus != pool.HashStatusMismatch {
		t.Errorf("HashStatus on rejected entry: want mismatch, got %v", res.HashMismatches[0].HashStatus)
	}
	if res.Counts[routing.ReasonTier2HashMismatch] != 1 {
		t.Errorf("ReasonTier2HashMismatch count: want 1, got %d", res.Counts[routing.ReasonTier2HashMismatch])
	}
}

func TestEligibleCandidates_QuotaIsSecondPass(t *testing.T) {
	// Quota rejection MUST NOT prevent earlier-pass counts from
	// being recorded — quota is a SOFT filter applied only to
	// providers that passed every other gate.
	t.Parallel()
	providers := []pool.Provider{
		mkProvider("model-mismatch"),
		mkProvider("quota-blocked"),
		mkProvider("ok"),
	}
	checker := &stubChecker{
		matches: map[string]bool{"model-mismatch": false},
		quotaOK: map[string]bool{"quota-blocked": false},
	}
	res := routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	if len(res.Eligible) != 1 || res.Eligible[0].ProviderID != "ok" {
		t.Fatalf("want only 'ok' eligible, got %+v", res.Eligible)
	}
	if res.Counts[routing.ReasonModelMismatch] != 1 {
		t.Errorf("ReasonModelMismatch count: want 1, got %d", res.Counts[routing.ReasonModelMismatch])
	}
	if res.Counts[routing.ReasonQuotaBlocked] != 1 {
		t.Errorf("ReasonQuotaBlocked count: want 1, got %d", res.Counts[routing.ReasonQuotaBlocked])
	}
}

func TestEligibleCandidates_QuotaBlocksAllReturnsEmpty(t *testing.T) {
	// SPEC-002 contract: when EVERY otherwise-eligible provider is
	// quota-blocked, the eligible list is empty and server.go emits
	// 429 provisional_quota_exceeded based on the count.
	t.Parallel()
	providers := []pool.Provider{mkProvider("a"), mkProvider("b")}
	checker := &stubChecker{quotaOK: map[string]bool{"a": false, "b": false}}
	res := routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	if len(res.Eligible) != 0 {
		t.Fatalf("all quota-blocked: want empty Eligible, got %+v", res.Eligible)
	}
	if res.Counts[routing.ReasonQuotaBlocked] != 2 {
		t.Errorf("ReasonQuotaBlocked count: want 2, got %d", res.Counts[routing.ReasonQuotaBlocked])
	}
}

func TestEligibleCandidates_PreQuotaCountTracksFirstLoopSurvivors(t *testing.T) {
	// Server.go uses PreQuotaCount to distinguish:
	//   - first loop dropped everything (PreQuotaCount=0) → 503 family
	//   - first loop had survivors but all quota-blocked (Eligible=0, PreQuotaCount>0) → 429
	t.Parallel()
	providers := []pool.Provider{
		mkProvider("model-mismatch"), // dropped before quota
		mkProvider("quota-blocked-1"),
		mkProvider("quota-blocked-2"),
	}
	checker := &stubChecker{
		matches: map[string]bool{"model-mismatch": false},
		quotaOK: map[string]bool{"quota-blocked-1": false, "quota-blocked-2": false},
	}
	res := routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	if res.PreQuotaCount != 2 {
		t.Fatalf("PreQuotaCount should count first-loop survivors only: want 2, got %d", res.PreQuotaCount)
	}
	if len(res.Eligible) != 0 {
		t.Fatalf("Eligible: want 0 (all quota-blocked), got %d", len(res.Eligible))
	}
}

// recordingChecker logs every (providerID, gate-name) pair as
// EligibleCandidates invokes it, so tests can assert FR-SR-18
// composition order (excluded → match/state → context → tier2 →
// quota) is enforced for every provider AND a rejected provider
// never reaches a later gate.
type recordingChecker struct {
	t            *testing.T
	calls        []string // "providerID/gate"
	matchFail    map[string]bool
	contextFail  map[string]bool
	tier2Reason  map[string]routing.RejectionReason
	quotaFail    map[string]bool
}

func (r *recordingChecker) ProviderMatchesRequest(p pool.Provider) bool {
	r.calls = append(r.calls, p.ProviderID+"/match")
	return !r.matchFail[p.ProviderID]
}
func (r *recordingChecker) ProviderContextSufficient(p pool.Provider) bool {
	r.calls = append(r.calls, p.ProviderID+"/context")
	return !r.contextFail[p.ProviderID]
}
func (r *recordingChecker) Tier2Decision(p pool.Provider) (routing.RejectionReason, pool.HashStatus) {
	r.calls = append(r.calls, p.ProviderID+"/tier2")
	return r.tier2Reason[p.ProviderID], pool.HashStatus("")
}
func (r *recordingChecker) QuotaPermits(p pool.Provider) bool {
	r.calls = append(r.calls, p.ProviderID+"/quota")
	return !r.quotaFail[p.ProviderID]
}

func TestEligibleCandidates_OrderingExcludedShortCircuitsEverything(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{
		{ProviderID: "excluded-x", AssignedID: "s1"},
		{ProviderID: "match-fail-y", AssignedID: "s2"},
		{ProviderID: "ok-z", AssignedID: "s3"},
	}
	ex := routing.NewExcluded(1)
	ex.Add(providers[0], keyer)
	checker := &recordingChecker{t: t, matchFail: map[string]bool{"match-fail-y": true}}
	res := routing.EligibleCandidates(providers, ex, keyer, checker)
	// Excluded provider MUST never reach match/context/tier2/quota.
	for _, c := range checker.calls {
		if c == "excluded-x/match" || c == "excluded-x/context" || c == "excluded-x/tier2" || c == "excluded-x/quota" {
			t.Fatalf("excluded provider hit later gate: %q (full calls: %v)", c, checker.calls)
		}
	}
	// match-fail-y reaches match but NOT context/tier2/quota.
	for _, c := range checker.calls {
		if c == "match-fail-y/context" || c == "match-fail-y/tier2" || c == "match-fail-y/quota" {
			t.Fatalf("match-rejected provider hit later gate: %q", c)
		}
	}
	if len(res.Eligible) != 1 || res.Eligible[0].ProviderID != "ok-z" {
		t.Fatalf("want only ok-z eligible, got %+v", res.Eligible)
	}
}

func TestEligibleCandidates_OrderingPerProviderSequence(t *testing.T) {
	// For a provider that passes every gate, the call sequence MUST
	// be exactly match → context → tier2 → quota. FR-SR-18 order.
	t.Parallel()
	providers := []pool.Provider{{ProviderID: "p", AssignedID: "s"}}
	checker := &recordingChecker{t: t}
	routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	want := []string{"p/match", "p/context", "p/tier2", "p/quota"}
	if len(checker.calls) != len(want) {
		t.Fatalf("call count: want %d, got %d (calls=%v)", len(want), len(checker.calls), checker.calls)
	}
	for i := range want {
		if checker.calls[i] != want[i] {
			t.Errorf("call[%d]: want %q, got %q (full=%v)", i, want[i], checker.calls[i], checker.calls)
		}
	}
}

func TestEligibleCandidates_OrderingContextRejectStopsBeforeTier2AndQuota(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{{ProviderID: "p", AssignedID: "s"}}
	checker := &recordingChecker{t: t, contextFail: map[string]bool{"p": true}}
	routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	want := []string{"p/match", "p/context"}
	if len(checker.calls) != len(want) {
		t.Fatalf("context-reject: want sequence %v, got %v", want, checker.calls)
	}
	for i := range want {
		if checker.calls[i] != want[i] {
			t.Errorf("call[%d]: want %q, got %q", i, want[i], checker.calls[i])
		}
	}
}

func TestEligibleCandidates_OrderingTier2RejectStopsBeforeQuota(t *testing.T) {
	t.Parallel()
	providers := []pool.Provider{{ProviderID: "p", AssignedID: "s"}}
	checker := &recordingChecker{t: t, tier2Reason: map[string]routing.RejectionReason{"p": routing.ReasonTier2EncryptedLeg}}
	routing.EligibleCandidates(providers, routing.NewExcluded(0), keyer, checker)
	for _, c := range checker.calls {
		if c == "p/quota" {
			t.Fatalf("tier2-rejected provider must NOT reach quota gate; full calls: %v", checker.calls)
		}
	}
}

func TestEligibleCandidates_EmptyInputEmptyResult(t *testing.T) {
	t.Parallel()
	res := routing.EligibleCandidates(nil, routing.NewExcluded(0), keyer, &stubChecker{})
	if len(res.Eligible) != 0 {
		t.Errorf("empty input: want empty Eligible, got %d", len(res.Eligible))
	}
	if len(res.Counts) != 0 {
		t.Errorf("empty input: want empty Counts, got %v", res.Counts)
	}
}
