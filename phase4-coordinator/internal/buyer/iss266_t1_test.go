package buyer

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// Issue #266 Tranche 1 — unit tests for the four deferred follow-ups
// landed in this PR. Each test pins ONE behavior so a future regression
// trips a single targeted failure rather than a confusing multi-test
// breakage.

func newIss266Server(t *testing.T, logger zerolog.Logger) *Server {
	t.Helper()
	return NewServer(pool.NewRegistry(nil), logger, time.Unix(1716768000, 0))
}

// --- Area 1: SetRoutingClasses + diffModelClasses + InvalidateClass wiring ---

func TestDiffModelClasses_Added(t *testing.T) {
	prev := map[string]config.ModelClassConfig{}
	next := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "b"}},
	}
	got := diffModelClasses(prev, next)
	if len(got) != 1 || got[0] != "fast" {
		t.Fatalf("expected [fast], got %v", got)
	}
}

func TestDiffModelClasses_Removed(t *testing.T) {
	prev := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a"}},
	}
	next := map[string]config.ModelClassConfig{}
	got := diffModelClasses(prev, next)
	if len(got) != 1 || got[0] != "fast" {
		t.Fatalf("expected [fast] (removed), got %v", got)
	}
}

func TestDiffModelClasses_MembershipChanged(t *testing.T) {
	prev := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "b"}},
	}
	next := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "c"}},
	}
	got := diffModelClasses(prev, next)
	if len(got) != 1 || got[0] != "fast" {
		t.Fatalf("expected [fast] (members differ), got %v", got)
	}
}

func TestDiffModelClasses_ObjectiveChanged(t *testing.T) {
	prev := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a"}},
	}
	next := map[string]config.ModelClassConfig{
		"fast": {Objective: "accurate", Models: []string{"a"}},
	}
	got := diffModelClasses(prev, next)
	if len(got) != 1 || got[0] != "fast" {
		t.Fatalf("expected [fast] (objective differs), got %v", got)
	}
}

func TestDiffModelClasses_NoChange(t *testing.T) {
	prev := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "b"}},
	}
	next := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "b"}},
	}
	got := diffModelClasses(prev, next)
	if len(got) != 0 {
		t.Fatalf("expected no changes, got %v", got)
	}
}

func TestDiffModelClasses_MultipleChangesSorted(t *testing.T) {
	prev := map[string]config.ModelClassConfig{
		"zebra": {Models: []string{"a"}},
		"alpha": {Models: []string{"x"}},
	}
	next := map[string]config.ModelClassConfig{
		"alpha": {Models: []string{"y"}}, // changed
		"beta":  {Models: []string{"z"}}, // added
		// zebra removed
	}
	got := diffModelClasses(prev, next)
	if len(got) != 3 || got[0] != "alpha" || got[1] != "beta" || got[2] != "zebra" {
		t.Fatalf("expected sorted [alpha beta zebra], got %v", got)
	}
}

func TestSetRoutingClasses_InvalidatesStickyEntriesForChangedClasses(t *testing.T) {
	s := newIss266Server(t, zerolog.Nop())
	// Seed routing config: one class "fast" with members [a,b].
	s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "b"}},
	})
	// Plant sticky entries under the class scope and a sibling scope.
	s.stickyMap.Update("conv:fast-1", "acct1", "prov-A", "fast")
	s.stickyMap.Update("conv:fast-2", "acct2", "prov-B", "fast")
	s.stickyMap.Update("conv:other-1", "acct3", "prov-C", "other")
	if got := s.stickyMap.Len(); got != 3 {
		t.Fatalf("setup: expected 3 sticky entries, got %d", got)
	}
	// Change "fast" membership: should call InvalidateClass("fast"),
	// dropping the two "fast" entries while leaving the "other" entry
	// untouched. "other" is unchanged so no purge there.
	changed, invalidated := s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a", "c"}},
	})
	if len(changed) != 1 || changed[0] != "fast" {
		t.Fatalf("expected changed=[fast], got %v", changed)
	}
	if invalidated != 2 {
		t.Fatalf("expected 2 sticky entries invalidated, got %d", invalidated)
	}
	if got := s.stickyMap.Len(); got != 1 {
		t.Fatalf("expected 1 sticky entry to remain (the 'other' scope), got %d", got)
	}
}

func TestSetRoutingClasses_NoChangeIsNoOp(t *testing.T) {
	s := newIss266Server(t, zerolog.Nop())
	s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a"}},
	})
	s.stickyMap.Update("conv:1", "a", "p", "fast")
	changed, invalidated := s.SetRoutingClasses(map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a"}},
	})
	if len(changed) != 0 || invalidated != 0 {
		t.Fatalf("expected no-op, got changed=%v invalidated=%d", changed, invalidated)
	}
	if got := s.stickyMap.Len(); got != 1 {
		t.Fatalf("expected sticky entry preserved, got %d", got)
	}
}

func TestSetRoutingClasses_SnapshotIsReadable(t *testing.T) {
	s := newIss266Server(t, zerolog.Nop())
	in := map[string]config.ModelClassConfig{
		"fast": {Objective: "fast", Models: []string{"a"}},
	}
	s.SetRoutingClasses(in)
	got := s.snapshotModelClasses()
	if len(got) != 1 {
		t.Fatalf("expected snapshot len=1, got %d", len(got))
	}
	// Mutate the snapshot — must NOT affect server state.
	got["fast"] = config.ModelClassConfig{Objective: "accurate"}
	again := s.snapshotModelClasses()
	if again["fast"].Objective != "fast" {
		t.Fatalf("snapshot mutation leaked back into server state")
	}
}

// --- Area 2: Per-attempt FR-SR-17 log threading ---

func TestLogRoutingDecisionRetry_EmitsPerAttemptFields(t *testing.T) {
	var buf bytes.Buffer
	s := newIss266Server(t, zerolog.New(&buf))
	provider := pool.Provider{ProviderID: "prov-X", AssignedID: "asg-X", State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1}
	s.logRoutingDecisionRetry("req-abc", []pool.Provider{provider}, "retry", "prov-X", "retry_2", retryDecisionAttrs{
		AttemptIndex:    3,
		RetryCount:      2,
		Retried:         2,
		RetryReason:     "streaming_advance",
		PreflightResult: "accepted",
	})
	row := map[string]any{}
	if err := json.Unmarshal(buf.Bytes(), &row); err != nil {
		t.Fatalf("invalid log row %q: %v", buf.String(), err)
	}
	if got := row["event"]; got != "routing_decision" {
		t.Fatalf("expected event=routing_decision, got %v", got)
	}
	if got := row["attempt_index"]; got != float64(3) {
		t.Fatalf("expected attempt_index=3, got %v", got)
	}
	if got := row["retry_count"]; got != float64(2) {
		t.Fatalf("expected retry_count=2, got %v", got)
	}
	if got := row["retried"]; got != float64(2) {
		t.Fatalf("expected retried=2, got %v", got)
	}
	if got := row["retry_reason"]; got != "streaming_advance" {
		t.Fatalf("expected retry_reason=streaming_advance, got %v", got)
	}
	if got := row["preflight_result"]; got != "accepted" {
		t.Fatalf("expected preflight_result=accepted, got %v", got)
	}
	// Legacy back-compat — pre-issue-#266 consumers key off "reason".
	if got := row["reason"]; got != "retry_2" {
		t.Fatalf("expected legacy reason=retry_2 preserved, got %v", got)
	}
}

// --- Area 3: Mid-request stable seed across UTC midnight ---

func TestForwardState_DailyKeyStableAcrossMidnight(t *testing.T) {
	// Simulate handleChatCompletions starting a request at 23:59:59 UTC.
	// The forwardState.dailyKey snapshot is "2026-06-30". A retry that
	// fires at 00:00:01 UTC the next day MUST produce the SAME seed
	// because it reads state.dailyKey, not time.Now().
	dailyKeyAtStart := "2026-06-30"
	seedAtStart := seedForRequestWithKey("req-XYZ", dailyKeyAtStart)
	seedAtRetry := seedForRequestWithKey("req-XYZ", dailyKeyAtStart)
	if seedAtStart != seedAtRetry {
		t.Fatalf("seed must be stable when dailyKey is held; got %d vs %d", seedAtStart, seedAtRetry)
	}
	seedNextDay := seedForRequestWithKey("req-XYZ", "2026-07-01")
	if seedNextDay == seedAtStart {
		t.Fatalf("seed must rotate when dailyKey changes")
	}
}

func TestApplyRandomTiebreak_UsesProvidedDailyKey(t *testing.T) {
	// applyRandomTiebreak with the dailyKey arg must use that key,
	// not defaultDailyKey(). Verify by giving the same requestID and
	// two different dailyKeys; the resulting seed in the returned
	// tuple must differ.
	s := newIss266Server(t, zerolog.Nop())
	s.tiebreakRandomize = true
	s.tiebreakEpsilon = 0.99 // wide cohort so both providers tie
	mk := func(id string, tps float64) pool.Provider {
		return pool.Provider{ProviderID: id, AssignedID: id, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, ThroughputTPSEstimate: tps}
	}
	candA := []pool.Provider{mk("p1", 100), mk("p2", 100)}
	candB := []pool.Provider{mk("p1", 100), mk("p2", 100)}
	_, seedDayA, _, reasonA := s.applyRandomTiebreak("req-K", candA, "fast", "2026-06-30")
	_, seedDayB, _, reasonB := s.applyRandomTiebreak("req-K", candB, "fast", "2026-07-01")
	if reasonA != "randomized" || reasonB != "randomized" {
		t.Fatalf("expected randomized cohort both days, got %q / %q", reasonA, reasonB)
	}
	if seedDayA == seedDayB {
		t.Fatalf("seeds must rotate with dailyKey; got same %d", seedDayA)
	}
}

func TestApplyRandomTiebreak_EmptyDailyKeyFallsBackToDefault(t *testing.T) {
	// Defensive: callers without a forwardState (admin paths, future
	// entry points) pass "". applyRandomTiebreak must NOT panic and
	// must derive a non-zero seed via defaultDailyKey().
	s := newIss266Server(t, zerolog.Nop())
	s.tiebreakRandomize = true
	s.tiebreakEpsilon = 0.99
	mk := func(id string, tps float64) pool.Provider {
		return pool.Provider{ProviderID: id, AssignedID: id, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, ThroughputTPSEstimate: tps}
	}
	candidates := []pool.Provider{mk("p1", 100), mk("p2", 100)}
	_, seed, _, reason := s.applyRandomTiebreak("req-K", candidates, "fast", "")
	if reason != "randomized" {
		t.Fatalf("expected randomized cohort, got %q", reason)
	}
	if seed == 0 {
		t.Fatalf("expected non-zero seed from defaultDailyKey fallback")
	}
}

// --- Area 4: stickyMismatchLimiter ---

func TestStickyMismatchLimiter_FirstCallAllows(t *testing.T) {
	l := newStickyMismatchLimiter(time.Minute, 100)
	if !l.allow("conv:1") {
		t.Fatalf("first call must allow")
	}
}

func TestStickyMismatchLimiter_SecondWithinWindowDenies(t *testing.T) {
	l := newStickyMismatchLimiter(time.Minute, 100)
	base := time.Unix(1_700_000_000, 0)
	l.now = func() time.Time { return base }
	if !l.allow("conv:1") {
		t.Fatalf("first call must allow")
	}
	l.now = func() time.Time { return base.Add(30 * time.Second) }
	if l.allow("conv:1") {
		t.Fatalf("second call within window must deny")
	}
}

func TestStickyMismatchLimiter_AfterWindowAllowsAgain(t *testing.T) {
	l := newStickyMismatchLimiter(time.Minute, 100)
	base := time.Unix(1_700_000_000, 0)
	l.now = func() time.Time { return base }
	if !l.allow("conv:1") {
		t.Fatalf("first call must allow")
	}
	l.now = func() time.Time { return base.Add(2 * time.Minute) }
	if !l.allow("conv:1") {
		t.Fatalf("call past window must allow again")
	}
}

func TestStickyMismatchLimiter_PerKeyIndependent(t *testing.T) {
	l := newStickyMismatchLimiter(time.Minute, 100)
	if !l.allow("conv:1") {
		t.Fatalf("conv:1 first call must allow")
	}
	if !l.allow("conv:2") {
		t.Fatalf("conv:2 first call must allow (different key)")
	}
}

func TestStickyMismatchLimiter_BoundedByMaxEntries(t *testing.T) {
	l := newStickyMismatchLimiter(time.Hour, 2)
	base := time.Unix(1_700_000_000, 0)
	l.now = func() time.Time { return base }
	l.allow("conv:a")
	l.now = func() time.Time { return base.Add(1 * time.Second) }
	l.allow("conv:b")
	l.now = func() time.Time { return base.Add(2 * time.Second) }
	l.allow("conv:c") // evicts oldest (conv:a) because cap=2 and all in-window
	if got := l.lenLocked(); got != 2 {
		t.Fatalf("expected at-cap len=2, got %d", got)
	}
	// conv:a was evicted, so it should allow again on the next call.
	l.now = func() time.Time { return base.Add(3 * time.Second) }
	if !l.allow("conv:a") {
		t.Fatalf("conv:a was evicted — must allow again")
	}
}
