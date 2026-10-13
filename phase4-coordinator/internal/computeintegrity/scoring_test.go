package computeintegrity

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math/rand"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func meas(scored int, top1 float64, meanLogprob float64) Measurement {
	return Measurement{ScoredTokens: scored, Top1Matches: int(top1 * float64(scored)), SumLogprob: meanLogprob * float64(scored)}
}

func TestMeasurementValidity(t *testing.T) {
	if (Measurement{ScoredTokens: 15, Top1Matches: 15}).Valid() {
		t.Fatal("below MinScoredTokens must be invalid")
	}
	if (Measurement{ScoredTokens: 20, Top1Matches: 21}).Valid() {
		t.Fatal("matches above scored must be invalid")
	}
	if (Measurement{ScoredTokens: 20, SumLogprob: 1}).Valid() {
		t.Fatal("positive log-probability sum must be invalid")
	}
	if !meas(64, 0.9, -0.4).Valid() {
		t.Fatal("ordinary measurement must be valid")
	}
}

func TestPriorBandSeparatesHonestFromSubstituted(t *testing.T) {
	greedy := PriorBand(SamplingGreedy)
	if ok, _ := greedy.Evaluate(meas(128, 0.97, -0.15)); !ok {
		t.Fatal("honest cross-chip greedy pair must be in the prior band")
	}
	ok, reason := greedy.Evaluate(meas(128, 0.62, -0.9))
	if ok || reason != OutOfBandTop1 {
		t.Fatalf("substituted greedy output: got ok=%v reason=%q", ok, reason)
	}
	ok, reason = greedy.Evaluate(meas(128, 0.9, -1.6))
	if ok || reason != OutOfBandLogprob {
		t.Fatalf("low-probability greedy output: got ok=%v reason=%q", ok, reason)
	}
	sampled := PriorBand(SamplingSampled)
	if ok, _ := sampled.Evaluate(meas(128, 0.4, -2.2)); !ok {
		t.Fatal("sampled output is judged on log-probability only")
	}
	if ok, _ := sampled.Evaluate(meas(128, 0.4, -5.1)); ok {
		t.Fatal("sampled output far below the prior must be out of band")
	}
}

func TestToleranceWarmsWithOperatorDiversityAndLearnsBand(t *testing.T) {
	tol := NewTolerance()
	key := ToleranceKey{ModelID: "m", ManifestSHA256: "h", Class: SamplingGreedy}
	rng := rand.New(rand.NewSource(1))
	// One operator alone never warms the key, however many samples.
	for i := 0; i < 64; i++ {
		tol.Accept(key, "op-a", meas(128, 0.97, -0.2))
	}
	if b := tol.Band(key); b.Warm || b.Samples != tolerancePerOperatorCap {
		t.Fatalf("single operator: warm=%v samples=%d", b.Warm, b.Samples)
	}
	for i := 0; i < 48; i++ {
		op := []string{"op-b", "op-c", "op-d"}[i%3]
		tol.Accept(key, op, meas(128, 0.95+0.04*rng.Float64(), -0.25+0.1*rng.Float64()))
	}
	band := tol.Band(key)
	if !band.Warm || band.Operators != 4 {
		t.Fatalf("expected warm band over 4 operators, got %+v", band)
	}
	// The learned band is tighter than the prior for this tight honest model.
	if band.MeanLogprobFloor <= priorGreedyLogprobFloor || band.Top1Floor <= priorGreedyTop1Floor {
		t.Fatalf("learned band should tighten: %+v", band)
	}
	if ok, _ := band.Evaluate(meas(128, 0.96, -0.22)); !ok {
		t.Fatal("honest pair must stay in the learned band")
	}
	// A quantization-degraded model the prior would accept is caught.
	if ok, _ := band.Evaluate(meas(128, 0.88, -0.8)); ok {
		t.Fatal("degraded model must fall out of the learned band")
	}
}

func TestToleranceHardFloorsBoundPoisoning(t *testing.T) {
	tol := NewTolerance()
	key := ToleranceKey{ModelID: "m", ManifestSHA256: "h", Class: SamplingGreedy}
	for i := 0; i < 64; i++ {
		tol.Accept(key, []string{"a", "b", "c", "d"}[i%4], meas(128, 0.3+0.5*float64(i%2), -4+3*float64(i%2)))
	}
	band := tol.Band(key)
	if band.Top1Floor < hardGreedyTop1Floor || band.MeanLogprobFloor < hardGreedyLogprobFloor {
		t.Fatalf("learned floors must not drop below the hard floors: %+v", band)
	}
}

func outcomeIn(at time.Time, ops ...string) Outcome {
	return Outcome{InBand: true, ScorerOperators: ops, At: at}
}

func outcomeOut(at time.Time, ops ...string) Outcome {
	return Outcome{OutOfBand: true, OutReason: OutOfBandTop1, ScorerOperators: ops, At: at}
}

func TestStateMachineUnverifiedToPassing(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := NewKeyState("p", "m", t0)
	for i := 0; i < 2; i++ {
		if tr := k.Apply(outcomeIn(t0.Add(time.Duration(i)*time.Hour), "s1")); tr != nil {
			t.Fatalf("unexpected transition %+v", tr)
		}
	}
	tr := k.Apply(outcomeIn(t0.Add(2*time.Hour), "s1"))
	if tr == nil || tr.To != VerificationPassing || tr.Reason != ReasonInBandStreak {
		t.Fatalf("expected passing, got %+v", tr)
	}
}

func TestStateMachineFailureNeedsTwoScorerOperators(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := NewKeyState("p", "m", t0)
	k.Apply(outcomeIn(t0, "s1"))
	lastIn := t0.Add(time.Hour)
	k.Apply(outcomeIn(lastIn, "s1"))
	tr := k.Apply(outcomeOut(t0.Add(2*time.Hour), "s1"))
	if tr == nil || tr.To != VerificationSuspect || tr.Reason != ReasonOutOfBandTop1 {
		t.Fatalf("expected suspect, got %+v", tr)
	}
	if !k.WindowStart.Equal(lastIn) {
		t.Fatalf("affected window must open at the last in-band measurement, got %v", k.WindowStart)
	}
	// Three outs from one scorer operator never confirm a failure.
	for i := 0; i < 5; i++ {
		if tr := k.Apply(outcomeOut(t0.Add(time.Duration(3+i)*time.Hour), "s1")); tr != nil && tr.To == VerificationFailed {
			t.Fatal("one scorer operator must not confirm a failure")
		}
	}
	tr = k.Apply(outcomeOut(t0.Add(9*time.Hour), "s1", "s2"))
	if tr == nil || tr.To != VerificationFailed || tr.Reason != ReasonConfirmedFailure {
		t.Fatalf("expected failed, got %+v", tr)
	}
	if tr.Hold.Kind != HoldActionOpenFailure || !tr.Hold.Start.Equal(lastIn) || !tr.Hold.End.Equal(t0.Add(9*time.Hour)) {
		t.Fatalf("failure hold must cover the affected window: %+v", tr.Hold)
	}
	if !k.State.RoutingSuspended() {
		t.Fatal("failed must suspend routing")
	}
	// Outcomes while failed are ignored.
	if tr := k.Apply(outcomeIn(t0.Add(10*time.Hour), "s1", "s2")); tr != nil {
		t.Fatalf("failed key must ignore outcomes, got %+v", tr)
	}
}

func TestStateMachineSuspectClearsOnThreeIns(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := NewKeyState("p", "m", t0)
	k.Apply(outcomeOut(t0, "s1"))
	k.Apply(outcomeOut(t0.Add(time.Minute), "s1", "s2"))
	k.Apply(outcomeIn(t0.Add(2*time.Minute), "s1", "s2"))
	k.Apply(outcomeIn(t0.Add(3*time.Minute), "s2", "s3"))
	tr := k.Apply(outcomeIn(t0.Add(4*time.Minute), "s1", "s3"))
	if tr == nil || tr.To != VerificationPassing || tr.Reason != ReasonEscalationPassed || tr.Hold.Kind != HoldActionNone {
		t.Fatalf("expected escalation_passed, got %+v", tr)
	}
}

func TestStateMachineEscalationInconclusiveCap(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := NewKeyState("p", "m", t0)
	k.Apply(outcomeOut(t0, "s1"))
	var last *Transition
	for i := 0; i < escalationMaxMeasured; i++ {
		split := Outcome{ScorerOperators: []string{"s1", "s2"}, At: t0.Add(time.Duration(i+1) * time.Minute)}
		if tr := k.Apply(split); tr != nil {
			last = tr
		}
	}
	if last == nil || last.To != VerificationPassing || last.Reason != ReasonEscalationInconclusive {
		t.Fatalf("expected escalation_inconclusive, got %+v", last)
	}
}

func failKey(t *testing.T, t0 time.Time) *KeyState {
	t.Helper()
	k := NewKeyState("p", "m", t0)
	k.Apply(outcomeOut(t0, "s1"))
	for i := 0; i < 3; i++ {
		k.Apply(outcomeOut(t0.Add(time.Duration(i+1)*time.Minute), "s1", "s2"))
	}
	if k.State != VerificationFailed {
		t.Fatalf("setup: expected failed, got %s", k.State)
	}
	return k
}

func TestStateMachineRecoveryReleasesRecoveryHold(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := failKey(t, t0)
	if tr := k.Tick(t0.Add(time.Hour)); tr != nil {
		t.Fatal("cooldown has not elapsed")
	}
	rec := t0.Add(25 * time.Hour)
	tr := k.Tick(rec)
	if tr == nil || tr.To != VerificationRecovering || tr.Hold.Kind != HoldActionOpenRecovery || !tr.Hold.Start.Equal(rec) {
		t.Fatalf("expected recovering with an open recovery hold, got %+v", tr)
	}
	if k.State.RoutingSuspended() {
		t.Fatal("recovering resumes routing")
	}
	// Five in-band measurements from a single scorer operator are not enough.
	for i := 0; i < 5; i++ {
		if tr := k.Apply(outcomeIn(rec.Add(time.Duration(i+1)*time.Minute), "s1")); tr != nil {
			t.Fatalf("one scorer operator must not requalify, got %+v", tr)
		}
	}
	tr = k.Apply(outcomeIn(rec.Add(10*time.Minute), "s2"))
	if tr == nil || tr.To != VerificationPassing || tr.Reason != ReasonRecoveryPassed || tr.Hold.Kind != HoldActionReleaseRecovery {
		t.Fatalf("expected recovery_passed releasing the recovery hold, got %+v", tr)
	}
}

func TestStateMachineRecoveryFailureKeepsHold(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := failKey(t, t0)
	rec := t0.Add(25 * time.Hour)
	k.Tick(rec)
	k.Apply(outcomeOut(rec.Add(time.Minute), "s1", "s2"))
	k.Apply(outcomeIn(rec.Add(2*time.Minute), "s1", "s2"))
	k.Apply(outcomeOut(rec.Add(3*time.Minute), "s2", "s3"))
	tr := k.Apply(outcomeOut(rec.Add(4*time.Minute), "s1", "s3"))
	if tr == nil || tr.To != VerificationFailed || tr.Hold.Kind != HoldActionCloseRecovery {
		t.Fatalf("expected failed closing (not releasing) the recovery hold, got %+v", tr)
	}
	if !k.CooldownUntil.Equal(rec.Add(4*time.Minute + DefaultRecoveryCooldown)) {
		t.Fatalf("cooldown restarts at the new failure: %v", k.CooldownUntil)
	}
}

func TestOperatorClearResetsKey(t *testing.T) {
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := failKey(t, t0)
	tr := k.OperatorClear(t0.Add(time.Hour))
	if tr == nil || tr.To != VerificationUnverified || tr.Reason != ReasonOperatorClear || tr.Hold.Kind != HoldActionNone {
		t.Fatalf("expected operator_clear, got %+v", tr)
	}
	if k.NextStep() != "none" || !k.CooldownUntil.IsZero() {
		t.Fatalf("clear must reset recovery state: %+v", k)
	}
}

func TestSelectScorersRules(t *testing.T) {
	verified := ScorerCandidate{ProviderID: "v", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:1"}
	candidates := []ScorerCandidate{
		{ProviderID: "same-op", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:1", Capable: true, Ready: true},
		{ProviderID: "old-cli", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:2", Capable: false, Ready: true},
		{ProviderID: "other-hash", ModelID: "m", ManifestSHA256: "x", OperatorKey: "github:3", Capable: true, Ready: true},
		{ProviderID: "other-model", ModelID: "n", ManifestSHA256: "h", OperatorKey: "github:4", Capable: true, Ready: true},
		{ProviderID: "offline", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:5", Capable: true, Ready: false},
		{ProviderID: "excluded", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:6", Capable: true, Ready: true},
		{ProviderID: "ok-a", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:7", Capable: true, Ready: true},
		{ProviderID: "ok-a2", ModelID: "m", ManifestSHA256: "h", OperatorKey: "github:7", Capable: true, Ready: true},
		{ProviderID: "ok-b", ModelID: "m", ManifestSHA256: "h", OperatorKey: "provider:ok-b", Capable: true, Ready: true},
	}
	eligible := func(c ScorerCandidate) bool { return c.ProviderID != "excluded" }
	for seed := int64(0); seed < 20; seed++ {
		got := SelectScorers(rand.New(rand.NewSource(seed)), verified, candidates, 3, eligible)
		if len(got) != 2 {
			t.Fatalf("seed %d: expected two distinct-operator scorers, got %+v", seed, got)
		}
		if got[0].OperatorKey == got[1].OperatorKey {
			t.Fatalf("seed %d: scorers must have different operators", seed)
		}
		for _, c := range got {
			switch c.ProviderID {
			case "ok-a", "ok-a2", "ok-b":
			default:
				t.Fatalf("seed %d: ineligible scorer %s selected", seed, c.ProviderID)
			}
		}
	}
}

func TestScorerTrackerExcludesPersistentDisagreer(t *testing.T) {
	tr := NewScorerTracker(nil)
	for i := 0; i < 3; i++ {
		tr.RecordPair("bad", "good"+string(rune('a'+i)), false)
	}
	if tr.Excluded("bad") {
		t.Fatal("three splits are below the FR-24 minimum")
	}
	newly := tr.RecordPair("bad", "goodd", false)
	if !tr.Excluded("bad") || len(newly) == 0 || newly[0] != "bad" {
		t.Fatalf("four splits in a disagreeing window must exclude, newly=%v", newly)
	}
	if tr.Excluded("gooda") {
		t.Fatal("a scorer with one split must not be excluded")
	}
	tr.Clear("bad")
	if tr.Excluded("bad") {
		t.Fatal("operator clear must lift the exclusion")
	}
	seeded := NewScorerTracker([]string{"persisted"})
	if !seeded.Excluded("persisted") {
		t.Fatal("persisted exclusions must load")
	}
}

func TestKnownSequencesOfferPickAndCheck(t *testing.T) {
	ks := NewKnownSequences()
	now := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	key := ToleranceKey{ModelID: "m", ManifestSHA256: "h", Class: SamplingGreedy}
	if ks.Offer(key, KnownSequence{Scorers: []string{"a", "b"}}, meas(64, 0.95, -0.2), meas(64, 0.95, -0.6), now) {
		t.Fatal("scorers more than 0.25 apart must not form a known sequence")
	}
	seqIn := KnownSequence{OutputText: "x", SourceProvider: "src", SourceOperator: "op-src", Scorers: []string{"a", "b"}, ScorerOperators: []string{"op-a", "op-b"}}
	if !ks.Offer(key, seqIn, meas(64, 0.95, -0.2), meas(64, 0.97, -0.3), now) {
		t.Fatal("agreeing scorers must form a known sequence")
	}
	rng := rand.New(rand.NewSource(3))
	for name, c := range map[string]ScorerCandidate{
		"original scorer":         {ProviderID: "a", OperatorKey: "op-z"},
		"original scorer op":      {ProviderID: "a2", OperatorKey: "op-a"},
		"source provider":         {ProviderID: "src", OperatorKey: "op-y"},
		"source operator sibling": {ProviderID: "src-2", OperatorKey: "op-src"},
		"unknown operator":        {ProviderID: "c"},
	} {
		if _, ok := ks.Pick(rng, key, c); ok {
			t.Fatalf("%s must not check this sequence", name)
		}
	}
	seq, ok := ks.Pick(rng, key, ScorerCandidate{ProviderID: "c", OperatorKey: "op-c"})
	if !ok {
		t.Fatal("expected a known sequence for an independent scorer")
	}
	if !KnownCheckPassed(seq, meas(64, 0.94, -0.4)) {
		t.Fatal("close answer must pass")
	}
	if KnownCheckPassed(seq, meas(64, 0.94, -1.0)) || KnownCheckPassed(seq, meas(64, 0.7, -0.25)) {
		t.Fatal("answers far below the consensus must fail")
	}
}

func TestSelectScorersIsOperatorWeighted(t *testing.T) {
	verified := ScorerCandidate{ProviderID: "v", ModelID: "m", ManifestSHA256: "h", OperatorKey: "op-v"}
	var candidates []ScorerCandidate
	for i := 0; i < 20; i++ {
		candidates = append(candidates, ScorerCandidate{ProviderID: fmt.Sprintf("farm-%d", i), ModelID: "m", ManifestSHA256: "h", OperatorKey: "op-farm", Capable: true, Ready: true})
	}
	candidates = append(candidates, ScorerCandidate{ProviderID: "solo", ModelID: "m", ManifestSHA256: "h", OperatorKey: "op-solo", Capable: true, Ready: true})
	rng := rand.New(rand.NewSource(7))
	solo := 0
	const draws = 2000
	for i := 0; i < draws; i++ {
		if got := SelectScorers(rng, verified, candidates, 1, nil); got[0].OperatorKey == "op-solo" {
			solo++
		}
	}
	// Operators are drawn uniformly: about half, not 1/21, of the draws.
	if solo < draws*40/100 || solo > draws*60/100 {
		t.Fatalf("solo operator chosen %d/%d times; selection must weight operators, not Macs", solo, draws)
	}
}

func TestDefaultCorpusAndProbeBody(t *testing.T) {
	c := DefaultCorpus()
	if c.Len() < 32 || c.Version() == "" {
		t.Fatalf("default corpus too small: %d", c.Len())
	}
	rng := rand.New(rand.NewSource(9))
	seen := map[SamplingClass]bool{}
	for i := 0; i < 50; i++ {
		p, err := DrawProbe(rng, c, "model-x", false)
		if err != nil {
			t.Fatal(err)
		}
		var body map[string]any
		if err := json.Unmarshal(p.Body, &body); err != nil {
			t.Fatal(err)
		}
		if body["model"] != "model-x" || body["stream"] != false {
			t.Fatalf("unexpected body %v", body)
		}
		msgs := body["messages"].([]any)
		if len(msgs) != 2 || msgs[0].(map[string]any)["role"] != "system" {
			t.Fatalf("probe must carry a system and a user message: %v", msgs)
		}
		user := msgs[1].(map[string]any)["content"].(string)
		for j := 0; j < c.Len(); j++ {
			if user == c.Prompt(j).User {
				t.Fatalf("probe repeated corpus entry %d verbatim", j)
			}
		}
		if int(body["max_tokens"].(float64)) != p.MaxTokens {
			t.Fatal("max_tokens mismatch")
		}
		seen[p.Class] = true
	}
	if !seen[SamplingGreedy] || !seen[SamplingSampled] {
		t.Fatal("probes must draw both sampling classes")
	}
	for i := 0; i < 20; i++ {
		if p, _ := DrawProbe(rng, c, "model-x", true); p.Class != SamplingGreedy {
			t.Fatal("greedyOnly must draw the greedy profile")
		}
	}
	if _, err := ParseCorpus([]byte(`{"version":"v","prompts":[{"system":"","user":"x"}]}`)); err == nil {
		t.Fatal("empty message must be rejected")
	}
}

func TestScoringStoreRoundTrip(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "ci.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	store, err := NewScoringStore(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	k := failKey(t, t0)
	if err := store.UpsertKeyState(ctx, k, t0); err != nil {
		t.Fatal(err)
	}
	k.Tick(t0.Add(48 * time.Hour))
	if err := store.UpsertKeyState(ctx, k, t0.Add(48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.LoadKeyStates(ctx)
	if err != nil || len(loaded) != 1 {
		t.Fatalf("load: %v %d", err, len(loaded))
	}
	if loaded[0].State != VerificationRecovering || !loaded[0].FailedAt.Equal(k.FailedAt) {
		t.Fatalf("round trip lost state: %+v", loaded[0])
	}
	if err := store.ExcludeScorer(ctx, "s9", t0); err != nil {
		t.Fatal(err)
	}
	ex, err := store.LoadScorerExclusions(ctx)
	if err != nil || len(ex) != 1 || ex[0] != "s9" {
		t.Fatalf("exclusions: %v %v", ex, err)
	}
	if err := store.ClearScorerExclusion(ctx, "s9"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE compute_integrity_scoring_keys SET state_json = '{"provider_id":"p","model_id":"m","state":"bogus"}'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.LoadKeyStates(ctx); err == nil {
		t.Fatal("an unknown persisted state must fail the load")
	}
}

// FR-24: failed known checks count as split answers but never enter the
// double-scored window, so on their own they cannot exclude a scorer.
func TestScorerTrackerKnownChecksDoNotDiluteOrForgePairWindow(t *testing.T) {
	tr := NewScorerTracker(nil)
	for i := 0; i < 10; i++ {
		if tr.RecordKnownCheck("s", false) {
			t.Fatal("known-check failures alone must not exclude")
		}
	}
	// Agreeing pairs keep the window clean even after many split answers.
	for i := 0; i < 8; i++ {
		tr.RecordPair("s", "peer", true)
	}
	if tr.Excluded("s") {
		t.Fatal("a scorer agreeing on every pair must not be excluded")
	}
	// Now a disagreeing majority in the pair window excludes it.
	for i := 0; i < 5; i++ {
		tr.RecordPair("s", "peer", false)
	}
	if !tr.Excluded("s") {
		t.Fatal("majority pair disagreement with enough splits must exclude")
	}
}

// FR-24 availability back-off: a persistently silent scorer rests, then
// returns; any valid answer resets the count.
func TestScorerTrackerAvailabilityBackOff(t *testing.T) {
	tr := NewScorerTracker(nil)
	now := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	for i := 0; i < scorerSilentLimit-1; i++ {
		tr.RecordNoAnswer("s", now)
	}
	tr.RecordAnswer("s")
	for i := 0; i < scorerSilentLimit-1; i++ {
		tr.RecordNoAnswer("s", now)
	}
	if !tr.Available("s", now) {
		t.Fatal("an answer resets the silence count")
	}
	tr.RecordNoAnswer("s", now)
	if tr.Available("s", now.Add(time.Minute)) {
		t.Fatal("a persistently silent scorer must rest")
	}
	if !tr.Available("s", now.Add(scorerRest)) {
		t.Fatal("a rested scorer returns")
	}
}

func TestScoringStorePruneAndRecentRequests(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "ci.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	store, err := NewScoringStore(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	if n, err := store.RecentVerificationRequests(ctx, t0); err != nil || n != 0 {
		t.Fatalf("no request log: n=%d err=%v", n, err)
	}
	old := NewKeyState("idle", "m", t0)
	failed := failKey(t, t0)
	if err := store.UpsertKeyState(ctx, old, t0); err != nil {
		t.Fatal(err)
	}
	if err := store.UpsertKeyState(ctx, failed, t0); err != nil {
		t.Fatal(err)
	}
	if n, err := store.PruneStaleKeyStates(ctx, t0.Add(time.Hour)); err != nil || n != 1 {
		t.Fatalf("prune removed %d rows, err=%v; want only the idle unverified row", n, err)
	}
	left, _ := store.LoadKeyStates(ctx)
	if len(left) != 1 || left[0].State != VerificationFailed {
		t.Fatalf("adverse state must survive pruning: %+v", left)
	}
	if _, err := db.Exec(`CREATE TABLE request_log (ts_utc TEXT NOT NULL, account_id TEXT NULL)`); err != nil {
		t.Fatal(err)
	}
	for _, row := range [][2]string{
		{"2026-10-13T00:30:00.000000000Z", "cip_aa"},
		{"2026-10-13T00:40:00.000000000Z", "cip_bb"},
		{"2026-10-13T00:45:00.000000000Z", "acct_buyer"},
		{"2026-10-12T22:00:00.000000000Z", "cip_old"},
		{"2026-10-13T00:50:00.000000000Z", "cipXnotreserved"},
	} {
		if _, err := db.Exec(`INSERT INTO request_log VALUES (?, ?)`, row[0], row[1]); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := store.RecentVerificationRequests(ctx, t0); err != nil || n != 2 {
		t.Fatalf("recent verification requests=%d err=%v, want 2", n, err)
	}
}
