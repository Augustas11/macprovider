package rollup

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/intake"
)

func TestBuildFleetRAMClassesAndSuppression(t *testing.T) {
	start := time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC)
	end := start.Add(30 * 24 * time.Hour)
	// 4 × 16 GB, 5 × 32 GB (one at 47 GB is still the 32 class), 1 × 8, 1 × 128, 1 × 4 (below every floor).
	mem := []int{16, 16, 24 - 1, 16, 32, 32, 36, 47, 32, 8, 128, 4}
	fleet := BuildFleetRAM(mem, start, end, intake.KAnonymityMin)
	if fleet.ProviderTotal != 12 {
		t.Fatalf("provider_total = %d, want 12", fleet.ProviderTotal)
	}
	if len(fleet.Classes) != len(fleetRAMClassFloors) {
		t.Fatalf("classes = %d, want %d", len(fleet.Classes), len(fleetRAMClassFloors))
	}
	byFloor := map[int]FleetRAMClass{}
	for _, c := range fleet.Classes {
		byFloor[c.RAMGBFloor] = c
	}
	// 32 GB (5) is emitted; 16 GB (4) is the smallest emitted class and is
	// suppressed complementarily because sub-k classes exist.
	if c := byFloor[32]; c.Suppressed || c.ProviderCount == nil || *c.ProviderCount != 5 {
		t.Fatalf("32 GB class = %+v, want 5", c)
	}
	for _, floor := range []int{8, 16, 24, 48, 64, 96, 128, 192, 256, 512} {
		if c := byFloor[floor]; !c.Suppressed || c.ProviderCount != nil {
			t.Fatalf("%d GB class must be suppressed: %+v", floor, c)
		}
	}
	// 8 GB (1) + 128 GB (1) sub-k, the complementary 16 GB (4), and the
	// 4 GB provider folded in: provider_total == emitted + suppressed.
	if fleet.ProviderSuppressed != 7 {
		t.Fatalf("provider_suppressed = %d, want 7", fleet.ProviderSuppressed)
	}
	emitted := 0
	for _, c := range fleet.Classes {
		if c.ProviderCount != nil {
			emitted += *c.ProviderCount
		}
	}
	if emitted+fleet.ProviderSuppressed != fleet.ProviderTotal {
		t.Fatalf("emitted %d + suppressed %d != total %d", emitted, fleet.ProviderSuppressed, fleet.ProviderTotal)
	}
	if fleet.KAnonymityMin != intake.KAnonymityMin {
		t.Fatalf("k_anonymity_min = %d", fleet.KAnonymityMin)
	}
	if fleet.WindowStart != "2026-08-12T00:00:00Z" || fleet.WindowEnd != "2026-09-11T00:00:00Z" {
		t.Fatalf("window = %s..%s", fleet.WindowStart, fleet.WindowEnd)
	}
	raw, _ := json.Marshal(fleet)
	var generic map[string]any
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"window_start", "window_end", "k_anonymity_min", "provider_total", "provider_suppressed", "classes"} {
		if _, ok := generic[k]; !ok {
			t.Fatalf("fleet_ram missing %q", k)
		}
	}
	if len(generic) != 6 {
		t.Fatalf("fleet_ram carries %d keys, want 6", len(generic))
	}
}

func TestBuildFleetRAMComplementaryTieBreaksToHighestFloor(t *testing.T) {
	start := time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC)
	// 16 GB ×3 and 128 GB ×3 tie as the smallest emitted classes; one 8 GB
	// provider forces complementary suppression, which must hide the
	// 128 GB class (the more identifying end), not the 16 GB one.
	fleet := BuildFleetRAM([]int{16, 16, 16, 128, 128, 128, 64, 64, 64, 64, 8}, start, start.Add(30*24*time.Hour), 3)
	byFloor := map[int]FleetRAMClass{}
	for _, c := range fleet.Classes {
		byFloor[c.RAMGBFloor] = c
	}
	if c := byFloor[128]; !c.Suppressed {
		t.Fatalf("128 GB class must be the complementary suppression: %+v", c)
	}
	if c := byFloor[16]; c.Suppressed || *c.ProviderCount != 3 {
		t.Fatalf("16 GB class must stay emitted: %+v", c)
	}
	if c := byFloor[64]; c.Suppressed || *c.ProviderCount != 4 {
		t.Fatalf("64 GB class must stay emitted: %+v", c)
	}
	if fleet.ProviderSuppressed != 4 {
		t.Fatalf("provider_suppressed = %d, want 4 (8 GB + 128 GB ×3)", fleet.ProviderSuppressed)
	}
}

func TestBuildFleetRAMNoSuppressionWhenEveryClassClearsK(t *testing.T) {
	start := time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC)
	mem := []int{}
	for _, floor := range fleetRAMClassFloors {
		mem = append(mem, floor, floor, floor)
	}
	fleet := BuildFleetRAM(mem, start, start.Add(30*24*time.Hour), 3)
	for _, c := range fleet.Classes {
		if c.Suppressed || c.ProviderCount == nil || *c.ProviderCount != 3 {
			t.Fatalf("no class should be suppressed when all clear k: %+v", c)
		}
	}
	if fleet.ProviderSuppressed != 0 {
		t.Fatalf("provider_suppressed = %d", fleet.ProviderSuppressed)
	}
	empty := BuildFleetRAM(nil, start, start.Add(30*24*time.Hour), 3)
	if empty.ProviderTotal != 0 || empty.ProviderSuppressed != 0 || len(empty.Classes) != len(fleetRAMClassFloors) {
		t.Fatalf("empty fleet = %+v", empty)
	}
}

// fleetFitFractionPPM is the SPEC-023 §16.2(c) evaluation over the
// histogram: unsuppressed classes whose floor − 4 ≥ min_ram_gb, over total.
func fleetFitFractionPPM(f FleetRAM, minRAMGB int) int {
	fit := 0
	for _, c := range f.Classes {
		if c.Suppressed || c.ProviderCount == nil {
			continue
		}
		if c.RAMGBFloor-4 >= minRAMGB {
			fit += *c.ProviderCount
		}
	}
	if f.ProviderTotal == 0 {
		return 0
	}
	return fit * 1_000_000 / f.ProviderTotal
}

func TestFleetFitEvaluationIsConservativeAtClassBoundaries(t *testing.T) {
	start := time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC)
	// Four 16 GB, three 32 GB, three 64 GB, one 8 GB (sub-k → suppressed;
	// 32 and 64 tie as smallest emitted, so 64 — the higher floor — is
	// suppressed complementarily).
	fleet := BuildFleetRAM([]int{16, 16, 16, 16, 32, 32, 32, 64, 64, 64, 8}, start, start.Add(30*24*time.Hour), 3)
	// min_ram_gb 12 fits the 16 GB class (16 − 4 = 12): 16 (4) + 32 (3) = 7 of 11.
	if got := fleetFitFractionPPM(fleet, 12); got != 7*1_000_000/11 {
		t.Fatalf("fit(12) = %d ppm, want %d", got, 7*1_000_000/11)
	}
	// min_ram_gb 13 does NOT fit the 16 GB class by floor: 32 (3) of 11.
	if got := fleetFitFractionPPM(fleet, 13); got != 3*1_000_000/11 {
		t.Fatalf("fit(13) = %d ppm, want %d", got, 3*1_000_000/11)
	}
	// min_ram_gb 60 would fit 64 only, which is suppressed: 0 of 11.
	if got := fleetFitFractionPPM(fleet, 60); got != 0 {
		t.Fatalf("fit(60) = %d ppm, want 0", got)
	}
}

func TestFleetRAMPeriodFreeze(t *testing.T) {
	period := 30 * 24 * time.Hour
	boundary := time.Unix(0, 0).UTC().Add(time.Duration(fleetRAMPeriodIndex(time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC))) * period)
	materialized := boundary.Add(20 * time.Minute)
	raw, _ := json.Marshal(BuildFleetRAM([]int{16, 16, 16}, materialized.Add(-period), materialized, 3))
	if !fleetRAMCurrent(raw, materialized.Add(29*24*time.Hour)) {
		t.Fatalf("a histogram materialized in this period must be reused for the whole period")
	}
	if fleetRAMCurrent(raw, boundary.Add(period+time.Minute)) {
		t.Fatalf("a histogram from the previous period must be recomputed")
	}
	if fleetRAMCurrent(raw, materialized.Add(-time.Minute)) {
		t.Fatalf("a histogram materialized in the future must be recomputed")
	}
	for _, bad := range []string{
		`{}`,
		`not json`,
		strings.Replace(string(raw), `"k_anonymity_min":3`, `"k_anonymity_min":2`, 1),
		strings.Replace(string(raw), materialized.Add(-period).Format(time.RFC3339), materialized.Add(-period-time.Hour).Format(time.RFC3339), 1),
	} {
		if fleetRAMCurrent([]byte(bad), materialized.Add(time.Hour)) {
			t.Fatalf("malformed persisted histogram must be recomputed: %s", bad)
		}
	}
}

func completeWindow(id, start string) intake.Window {
	s, _ := time.Parse(time.RFC3339, start)
	end := s.Add(intake.WindowMaxDays * 24 * time.Hour).Format(time.RFC3339)
	return intake.Window{
		WindowID:            id,
		WindowStart:         start,
		WindowEnd:           &end,
		Parameters:          intake.Parameters{KeyBuckets: 64, PrincipalsPerBucket: 64, DistinctKeyCap: 10000, BuyerRequestFloor: 250, PrincipalCapPct: 10, PrincipalCapRequests: 25, KAnonymityMin: intake.KAnonymityMin, WindowMaxDays: intake.WindowMaxDays},
		EligibilityPolicyID: strings.Repeat("b", 32),
		Buckets:             []intake.Bucket{},
	}
}

func TestMergeIntakeWindowsValidatesAndFailsClosedOnConflict(t *testing.T) {
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	idA, idB := strings.Repeat("a", 32), strings.Repeat("c", 32)
	open := completeWindow(strings.Repeat("d", 32), "2026-09-01T00:00:00Z")
	open.WindowEnd = nil
	short := completeWindow(strings.Repeat("e", 32), "2026-08-15T00:00:00Z")
	shortEnd := "2026-08-20T00:00:00Z"
	short.WindowEnd = &shortEnd
	persisted := []intake.Window{completeWindow(idA, "2026-08-01T00:00:00Z")}

	// An incomplete window on either side is a contract violation, not a skip.
	for _, bad := range []intake.Window{open, short} {
		if _, err := MergeIntakeWindows([]intake.Window{bad}, persisted, now); !errors.Is(err, ErrIntakeWindowInvalid) {
			t.Fatalf("incomplete window must fail closed, got %v", err)
		}
		if _, err := MergeIntakeWindows(nil, append([]intake.Window{bad}, persisted...), now); !errors.Is(err, ErrIntakeWindowInvalid) {
			t.Fatalf("incomplete persisted window must fail closed, got %v", err)
		}
	}
	// A sub-floor bucket in a persisted window can never resurrect.
	subFloor := completeWindow(idA, "2026-08-01T00:00:00Z")
	subFloor.Buckets = []intake.Bucket{{ModelKey: "some-key", LowerBound: 10, Count: 12, Error: 2}}
	if _, err := MergeIntakeWindows(nil, []intake.Window{subFloor}, now); !errors.Is(err, ErrIntakeWindowInvalid) {
		t.Fatalf("sub-floor persisted bucket must fail closed, got %v", err)
	}
	// One id, two byte representations: conflict on both sides and within one side.
	stale := completeWindow(idA, "2026-08-01T00:00:00Z")
	stale.SuppressedBucketCount = 9
	if _, err := MergeIntakeWindows([]intake.Window{stale}, persisted, now); !errors.Is(err, ErrIntakeWindowConflict) {
		t.Fatalf("cross-set conflict must fail closed, got %v", err)
	}
	if _, err := MergeIntakeWindows(nil, []intake.Window{persisted[0], stale}, now); !errors.Is(err, ErrIntakeWindowConflict) {
		t.Fatalf("in-set conflict must fail closed, got %v", err)
	}
	// Identical bytes merge once; ordering is descending start.
	merged, err := MergeIntakeWindows([]intake.Window{completeWindow(idA, "2026-08-01T00:00:00Z"), completeWindow(idB, "2026-07-02T00:00:00Z")}, persisted, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(merged) != 2 || merged[0].WindowID != idA || merged[1].WindowID != idB {
		t.Fatalf("merged = %+v, want [a, c]", merged)
	}
}

func TestMergeIntakeWindowsBoundsAndRetention(t *testing.T) {
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	var persisted []intake.Window
	for i := 0; i < 12; i++ {
		start := now.Add(-time.Duration(i+1) * 30 * 24 * time.Hour)
		persisted = append(persisted, completeWindow(fmt.Sprintf("%032x", i+1), start.Format(time.RFC3339)))
	}
	merged, err := MergeIntakeWindows(nil, persisted, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(merged) != intake.MaxEmittedWindows {
		t.Fatalf("emitted %d windows, want the cap %d", len(merged), intake.MaxEmittedWindows)
	}
	cutoff := now.Add(-intake.EmissionRetention)
	for i, w := range merged {
		end, _ := time.Parse(time.RFC3339, *w.WindowEnd)
		if end.Before(cutoff) {
			t.Fatalf("window older than retention emitted: %+v", w)
		}
		if i > 0 && merged[i-1].WindowStart < w.WindowStart {
			t.Fatalf("windows not in descending start order")
		}
	}
	// Only windows ending within the trailing 90 days survive even below the cap.
	old := []intake.Window{completeWindow(strings.Repeat("f", 32), now.Add(-121*24*time.Hour).Format(time.RFC3339))}
	if merged, err := MergeIntakeWindows(nil, old, now); err != nil || len(merged) != 0 {
		t.Fatalf("window ending 91 days ago must be dropped: %v %v", merged, err)
	}
}
