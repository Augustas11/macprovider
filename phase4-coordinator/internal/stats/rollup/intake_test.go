package rollup

import (
	"encoding/json"
	"errors"
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
	// 8 GB (1) + 128 GB (1) sub-k, plus the complementary 16 GB (4); the
	// 4 GB provider is in no class.
	if fleet.ProviderSuppressed != 6 {
		t.Fatalf("provider_suppressed = %d, want 6", fleet.ProviderSuppressed)
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
	// Four 16 GB, three 32 GB, three 64 GB, one 8 GB (sub-k → suppressed,
	// and the smallest emitted class, 32 GB, is suppressed complementarily).
	fleet := BuildFleetRAM([]int{16, 16, 16, 16, 32, 32, 32, 64, 64, 64, 8}, start, start.Add(30*24*time.Hour), 3)
	// min_ram_gb 12 fits the 16 GB class (16 − 4 = 12): 16 (4) + 64 (3) = 7 of 11.
	if got := fleetFitFractionPPM(fleet, 12); got != 7*1_000_000/11 {
		t.Fatalf("fit(12) = %d ppm, want %d", got, 7*1_000_000/11)
	}
	// min_ram_gb 13 does NOT fit the 16 GB class by floor; 32 is suppressed: 3 of 11.
	if got := fleetFitFractionPPM(fleet, 13); got != 3*1_000_000/11 {
		t.Fatalf("fit(13) = %d ppm, want %d", got, 3*1_000_000/11)
	}
	// min_ram_gb 60 fits 64 only: 3 of 11.
	if got := fleetFitFractionPPM(fleet, 60); got != 3*1_000_000/11 {
		t.Fatalf("fit(60) = %d ppm, want %d", got, 3*1_000_000/11)
	}
}

func win(id, start string, end *string, reason string) intake.Window {
	w := intake.Window{WindowID: id, WindowStart: start, Buckets: []intake.Bucket{}}
	if end != nil {
		w.WindowEnd = end
		r := reason
		w.CloseReason = &r
	}
	return w
}

func str(s string) *string { return &s }

func TestMergeIntakeWindowsKeepsCompleteOnlyAndAggregatorWins(t *testing.T) {
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	persisted := []intake.Window{
		win("open-old", "2026-09-01T00:00:00Z", nil, ""), // never persisted in practice; dropped
		win("stopped", "2026-08-15T00:00:00Z", str("2026-08-20T00:00:00Z"), intake.CloseReasonAggregatorStopped),
		win("complete-a", "2026-08-01T00:00:00Z", str("2026-08-31T00:00:00Z"), intake.CloseReasonEpochElapsed),
	}
	stale := win("complete-a", "2026-08-01T00:00:00Z", str("2026-08-31T00:00:00Z"), intake.CloseReasonEpochElapsed)
	stale.EligibleRequestTotal = 99
	current := []intake.Window{
		win("open-new", "2026-09-11T00:00:00Z", nil, ""),
		stale,
		win("complete-b", "2026-07-02T00:00:00Z", str("2026-08-01T00:00:00Z"), intake.CloseReasonEpochElapsed),
	}
	if _, err := MergeIntakeWindows(current, persisted, now); !errors.Is(err, ErrIntakeWindowConflict) {
		t.Fatalf("one window_id with two byte representations must fail closed, got %v", err)
	}
	current[1].EligibleRequestTotal = 0
	merged, err := MergeIntakeWindows(current, persisted, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(merged) != 2 || merged[0].WindowID != "complete-a" || merged[1].WindowID != "complete-b" {
		t.Fatalf("merged = %+v, want complete windows only, newest first", merged)
	}
	for _, w := range merged {
		if !w.Complete() {
			t.Fatalf("incomplete window persisted: %+v", w)
		}
	}
}

func TestMergeIntakeWindowsBoundsAndRetention(t *testing.T) {
	now := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	var persisted []intake.Window
	for i := 0; i < 12; i++ {
		start := now.Add(-time.Duration(i+1) * 30 * 24 * time.Hour)
		end := start.Add(30 * 24 * time.Hour)
		persisted = append(persisted, win(
			"w"+string(rune('a'+i)),
			start.Format(time.RFC3339),
			str(end.Format(time.RFC3339)),
			intake.CloseReasonEpochElapsed))
	}
	merged, err := MergeIntakeWindows(nil, persisted, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(merged) > intake.MaxEmittedWindows {
		t.Fatalf("emitted %d windows, max %d", len(merged), intake.MaxEmittedWindows)
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
	// Ends at -0d, -30d, -60d, -90d (inclusive cutoff) are within 90 days.
	if len(merged) != 4 {
		t.Fatalf("merged = %d windows, want 4 within 90 days", len(merged))
	}
}
