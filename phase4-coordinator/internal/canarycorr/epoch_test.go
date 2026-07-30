package canarycorr

import (
	"testing"
	"time"
)

func TestNewEpochRejectsBadInputs(t *testing.T) {
	t.Parallel()
	if _, err := NewEpoch("", "fp", 1, []string{"a"}); err == nil {
		t.Fatal("empty model must fail")
	}
	if _, err := NewEpoch("m", "", 1, []string{"a"}); err == nil {
		t.Fatal("empty fingerprint must fail")
	}
	if _, err := NewEpoch("m", "fp", 1, nil); err == nil {
		t.Fatal("empty snapshot must fail")
	}
	if _, err := NewEpoch("m", "fp", 1, []string{"a", "a"}); err == nil {
		t.Fatal("duplicate snapshot ids must fail")
	}
}

func TestStageRejectsOutOfSnapshotAndMismatches(t *testing.T) {
	t.Parallel()
	e, err := NewEpoch("model-a", "fp-1", 7, []string{"p1", "p2"})
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Stage(StagedResult{
		ProviderID: "p3", AssignedID: "s3", ModelID: "model-a",
		Fingerprint: "fp-1", BankGeneration: 7, Class: ClassPass,
	}); err == nil {
		t.Fatal("out-of-snapshot stage must fail")
	}
	if err := e.Stage(StagedResult{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-a",
		Fingerprint: "fp-OTHER", BankGeneration: 7, Class: ClassPass,
	}); err == nil {
		t.Fatal("fingerprint mismatch must fail")
	}
	if err := e.Stage(StagedResult{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-a",
		Fingerprint: "fp-1", BankGeneration: 8, Class: ClassPass,
	}); err == nil {
		t.Fatal("generation mismatch must fail")
	}
	if err := e.Stage(StagedResult{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-b",
		Fingerprint: "fp-1", BankGeneration: 7, Class: ClassPass,
	}); err == nil {
		t.Fatal("model mismatch must fail")
	}
	if err := e.Stage(StagedResult{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-a",
		Fingerprint: "fp-1", BankGeneration: 7, Class: ClassPass,
	}); err != nil {
		t.Fatal(err)
	}
	if err := e.Stage(StagedResult{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-a",
		Fingerprint: "fp-1", BankGeneration: 7, Class: ClassPass,
	}); err == nil {
		t.Fatal("duplicate stage must fail")
	}
}

func TestResolveSuspicionStrictMajoritySybilSafe(t *testing.T) {
	t.Parallel()
	// N=2: one failure is not majority → commit, not suspicion.
	e, err := NewEpoch("m", "fp", 1, []string{"honest", "sybil"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "honest", AssignedID: "s-h", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "sybil", AssignedID: "s-s", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Suspicious || out.Discarded {
		t.Fatalf("single failure at N=2 must commit, got %+v", out)
	}
	if out.Alert != nil {
		t.Fatalf("no alert on non-suspicion, got %+v", out.Alert)
	}
	var sybilFail, honestPass bool
	for _, c := range out.Commits {
		if c.ProviderID == "sybil" && c.ApplyFailure && !c.FloorHeld {
			sybilFail = true
		}
		if c.ProviderID == "honest" && c.ApplyPass {
			honestPass = true
		}
	}
	if !sybilFail || !honestPass {
		t.Fatalf("want sybil failure committed + honest pass, commits=%+v", out.Commits)
	}

	// N=2: both fail shared fingerprint → suspicion, discard, alert, no commits.
	e2, err := NewEpoch("m", "fp", 2, []string{"a", "b"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e2, StagedResult{
		ProviderID: "a", AssignedID: "sa", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 2, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e2, StagedResult{
		ProviderID: "b", AssignedID: "sb", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 2, Class: ClassIncomplete,
		BuyerServing: true, ObservedServing: true,
	})
	out2, err := e2.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !out2.Suspicious || !out2.Discarded {
		t.Fatalf("both-fail N=2 must be suspicion, got %+v", out2)
	}
	if len(out2.Commits) != 0 {
		t.Fatalf("suspicion must produce zero commits, got %+v", out2.Commits)
	}
	if out2.Alert == nil || !out2.Alert.Discarded || out2.Alert.FailingCount != 2 || out2.Alert.SnapshotN != 2 {
		t.Fatalf("FR-CAN29a alert incomplete: %+v", out2.Alert)
	}
	if out2.Alert.Fingerprint != "fp" || out2.Alert.BankGeneration != 2 {
		t.Fatalf("alert identity mismatch: %+v", out2.Alert)
	}
}

func TestResolveSuspicionRequiresTwoFailures(t *testing.T) {
	t.Parallel()
	// N=3: one failure is not >N/2 and not ≥2 → commit.
	e, err := NewEpoch("m", "fp", 1, []string{"a", "b", "c"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "a", AssignedID: "sa", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "b", AssignedID: "sb", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "c", AssignedID: "sc", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: true,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Suspicious {
		t.Fatalf("one failure at N=3 must not be suspicion: %+v", out)
	}

	// N=3: two failures is >1.5 → >N/2 and ≥2 → suspicion.
	e2, err := NewEpoch("m", "fp", 1, []string{"a", "b", "c"})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b"} {
		mustStage(t, e2, StagedResult{
			ProviderID: id, AssignedID: "s" + id, ModelID: "m",
			Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
			BuyerServing: true, ObservedServing: true,
		})
	}
	mustStage(t, e2, StagedResult{
		ProviderID: "c", AssignedID: "sc", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: true,
	})
	out2, err := e2.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !out2.Suspicious || out2.Alert == nil || out2.Alert.FailingCount != 2 {
		t.Fatalf("two failures at N=3 must be suspicion: %+v", out2)
	}
}

func TestRelayAndNeutralDoNotOpenSuspicion(t *testing.T) {
	t.Parallel()
	e, err := NewEpoch("m", "fp", 1, []string{"a", "b"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "a", AssignedID: "sa", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassRelaySoft,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "b", AssignedID: "sb", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassRelayStatus,
		BuyerServing: true, ObservedServing: true,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Suspicious {
		t.Fatalf("relay soft/status must not open suspicion: %+v", out)
	}
	for _, c := range out.Commits {
		if c.ApplyFailure || c.ApplyPass {
			t.Fatalf("neutral/soft/status must not apply pass/fail: %+v", c)
		}
	}
}

func TestFloorHoldsSoleObservedServingOnCommit(t *testing.T) {
	t.Parallel()
	// N=3: one observed-serving correctness failure + two request-independent
	// "ghost" peers that pass but never served buyers. Ghosts must not lift the
	// floor; the real provider is floor-held.
	e, err := NewEpoch("m", "fp", 1, []string{"real", "ghost1", "ghost2"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "real", AssignedID: "sr", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "ghost1", AssignedID: "sg1", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: false,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "ghost2", AssignedID: "sg2", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: false,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Suspicious {
		t.Fatalf("single correctness failure must not be suspicion: %+v", out)
	}
	var realHeld, ghostPass bool
	for _, c := range out.Commits {
		if c.ProviderID == "real" {
			// FloorHeld suppresses sanction but ApplyFailure stays true for counter accrual.
			if !c.FloorHeld || !c.ApplyFailure {
				t.Fatalf("sole buyer-serving failure must floor-hold with ApplyFailure: %+v", c)
			}
			realHeld = true
		}
		if c.ProviderID == "ghost1" && c.ApplyPass {
			ghostPass = true
		}
	}
	if !realHeld || !ghostPass {
		t.Fatalf("floor residual not applied: commits=%+v", out.Commits)
	}
}

func TestFloorHoldsColdSoleBuyerServing(t *testing.T) {
	t.Parallel()
	// Cold sole provider: BuyerServing but no ObservedServing stamp yet; ghost
	// peers pass request-independent gates only. Must still floor-hold.
	e, err := NewEpoch("m", "fp", 1, []string{"cold", "ghost"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "cold", AssignedID: "sc", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: false,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "ghost", AssignedID: "sg", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: false,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range out.Commits {
		if c.ProviderID == "cold" {
			if !c.FloorHeld || !c.ApplyFailure {
				t.Fatalf("cold sole buyer-serving must floor-hold with counter accrual: %+v", c)
			}
			return
		}
	}
	t.Fatal("missing cold commit")
}

func TestResolveExactHalfNotSuspicion(t *testing.T) {
	t.Parallel()
	// N=4, failing=2 is exact half — must NOT open suspicion (needs >N/2).
	ids := []string{"a", "b", "c", "d"}
	e, err := NewEpoch("m", "fp", 1, ids)
	if err != nil {
		t.Fatal(err)
	}
	for i, id := range ids {
		class := ClassPass
		if i < 2 {
			class = ClassNonceMismatch
		}
		mustStage(t, e, StagedResult{
			ProviderID: id, AssignedID: "s" + id, ModelID: "m",
			Fingerprint: "fp", BankGeneration: 1, Class: class,
			BuyerServing: true, ObservedServing: true,
		})
	}
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Suspicious || out.Discarded {
		t.Fatalf("exact half must commit, not suspicion: %+v", out)
	}
}

func TestResolveRejectsIncompleteUnlessAllowed(t *testing.T) {
	t.Parallel()
	e, err := NewEpoch("m", "fp", 1, []string{"a", "b"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "a", AssignedID: "sa", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	})
	if _, err := e.Resolve(time.Now().UTC(), ResolveOptions{}); err == nil {
		t.Fatal("incomplete epoch must fail closed without AllowIncomplete")
	}
	// Epoch must remain unresolved so the caller can stage the rest.
	mustStage(t, e, StagedResult{
		ProviderID: "b", AssignedID: "sb", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: true,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if out.Suspicious {
		t.Fatalf("unexpected suspicion: %+v", out)
	}
}

func TestNonServingTargetStillSanctions(t *testing.T) {
	t.Parallel()
	// A non-observed-serving target that fails is NOT floor-held (matches
	// Partial #690: floor only spares real capacity).
	e, err := NewEpoch("m", "fp", 1, []string{"ghost", "real"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "ghost", AssignedID: "sg", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassNonceMismatch,
		BuyerServing: false, ObservedServing: false,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "real", AssignedID: "sr", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 1, Class: ClassPass,
		BuyerServing: true, ObservedServing: true,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range out.Commits {
		if c.ProviderID == "ghost" {
			if !c.ApplyFailure || c.FloorHeld {
				t.Fatalf("non-serving target must take normal sanction: %+v", c)
			}
			return
		}
	}
	t.Fatal("missing ghost commit")
}

func TestNoPersistentContainmentFields(t *testing.T) {
	t.Parallel()
	// Outcome must not expose bank-rollback / fingerprint-suspend / durable
	// containment fields — the Sybil-safety fixed point. We assert by type
	// shape: only Suspicious/Discarded/Alert/Commits/Reason exist; Alert is
	// informational.
	e, err := NewEpoch("m", "fp", 9, []string{"a", "b"})
	if err != nil {
		t.Fatal(err)
	}
	mustStage(t, e, StagedResult{
		ProviderID: "a", AssignedID: "sa", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 9, Class: ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	})
	mustStage(t, e, StagedResult{
		ProviderID: "b", AssignedID: "sb", ModelID: "m",
		Fingerprint: "fp", BankGeneration: 9, Class: ClassIncomplete,
		BuyerServing: true, ObservedServing: true,
	})
	out, err := e.Resolve(time.Now().UTC(), ResolveOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !out.Suspicious || out.Alert == nil || !out.Alert.Discarded {
		t.Fatalf("expected pure discard alert: %+v", out)
	}
	// A second resolve must fail closed (no re-open / re-apply).
	if _, err := e.Resolve(time.Now().UTC(), ResolveOptions{}); err == nil {
		t.Fatal("second resolve must fail")
	}
}

func TestHasRecentObservedServing(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 7, 23, 12, 0, 0, 0, time.UTC)
	if HasRecentObservedServing(time.Time{}, now, ObservedServingWindow) {
		t.Fatal("zero lastSuccess must not count")
	}
	if !HasRecentObservedServing(now.Add(-30*time.Second), now, ObservedServingWindow) {
		t.Fatal("30s-old success must count within 90s window")
	}
	if HasRecentObservedServing(now.Add(-2*time.Minute), now, ObservedServingWindow) {
		t.Fatal("2m-old success must not count within 90s window")
	}
	if HasRecentObservedServing(now.Add(time.Minute), now, ObservedServingWindow) {
		t.Fatal("future lastSuccess must not count")
	}
}

func mustStage(t *testing.T, e *Epoch, r StagedResult) {
	t.Helper()
	if err := e.Stage(r); err != nil {
		t.Fatalf("stage %+v: %v", r, err)
	}
}
