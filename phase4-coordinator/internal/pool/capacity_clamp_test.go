package pool

import "testing"

func TestClampCapacity(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name                              string
		maxConcurrency, total, free, ceil int
		wantMax, wantTotal, wantFree      int
		wantOverClaim                     bool
	}{
		{
			name:           "under ceiling is untouched",
			maxConcurrency: 4, total: 4, free: 2, ceil: 8,
			wantMax: 4, wantTotal: 4, wantFree: 2,
		},
		{
			name:           "exactly at ceiling is not an over-claim",
			maxConcurrency: 8, total: 8, free: 8, ceil: 8,
			wantMax: 8, wantTotal: 8, wantFree: 8,
		},
		{
			name:           "absurd idle claim collapses to the ceiling and stays fully free",
			maxConcurrency: 9999, total: 9999, free: 9999, ceil: 8,
			wantMax: 8, wantTotal: 8, wantFree: 8,
			wantOverClaim: true,
		},
		{
			name:           "absurd saturated claim stays saturated after clamping",
			maxConcurrency: 9999, total: 9999, free: 0, ceil: 8,
			wantMax: 8, wantTotal: 8, wantFree: 0,
			wantOverClaim: true,
		},
		{
			name:           "partial usage is carried across the clamp",
			maxConcurrency: 100, total: 100, free: 97, ceil: 8,
			// used = 3 → free = 8 - 3 = 5
			wantMax: 8, wantTotal: 8, wantFree: 5,
			wantOverClaim: true,
		},
		{
			name:           "usage above the clamped total cannot drive free negative",
			maxConcurrency: 100, total: 100, free: 1, ceil: 8,
			wantMax: 8, wantTotal: 8, wantFree: 0,
			wantOverClaim: true,
		},
		{
			name:           "slots_total above max_concurrency is repaired below the ceiling",
			maxConcurrency: 2, total: 4, free: 4, ceil: 8,
			wantMax: 2, wantTotal: 2, wantFree: 2,
		},
		{
			name:           "slots_total alone above the ceiling is an over-claim",
			maxConcurrency: 4, total: 9999, free: 9999, ceil: 8,
			wantMax: 4, wantTotal: 4, wantFree: 4,
			wantOverClaim: true,
		},
		{
			name:           "zero ceiling disables the clamp entirely",
			maxConcurrency: 9999, total: 9999, free: 9999, ceil: 0,
			wantMax: 9999, wantTotal: 9999, wantFree: 9999,
		},
		{
			// Audit R1 (security): a negative claim must NOT pass through —
			// the relay admission guard only enforces when MaxConcurrency > 0,
			// so an untouched -1 would disable concurrency admission
			// entirely. Floor to 1 and count it on the tripwire.
			name:           "negative claim floors to one and trips the counter",
			maxConcurrency: -1, total: 0, free: 0, ceil: 8,
			wantMax: 1, wantTotal: 0, wantFree: 0,
			wantOverClaim: true,
		},
		{
			name:           "negative claim with inflated slots floors and clamps",
			maxConcurrency: -1, total: 9999, free: 9999, ceil: 8,
			wantMax: 1, wantTotal: 1, wantFree: 1,
			wantOverClaim: true,
		},
		{
			name:           "zero claim floors to one and trips the counter",
			maxConcurrency: 0, total: 0, free: 0, ceil: 8,
			wantMax: 1, wantTotal: 0, wantFree: 0,
			wantOverClaim: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := ClampCapacity(tc.maxConcurrency, tc.total, tc.free, tc.ceil)
			if got.MaxConcurrency != tc.wantMax || got.SlotsTotal != tc.wantTotal || got.SlotsFree != tc.wantFree {
				t.Fatalf("ClampCapacity(%d,%d,%d,%d) = (max %d, total %d, free %d), want (%d, %d, %d)",
					tc.maxConcurrency, tc.total, tc.free, tc.ceil,
					got.MaxConcurrency, got.SlotsTotal, got.SlotsFree,
					tc.wantMax, tc.wantTotal, tc.wantFree)
			}
			if got.OverClaimed != tc.wantOverClaim {
				t.Fatalf("OverClaimed = %v, want %v", got.OverClaimed, tc.wantOverClaim)
			}
			if got.ReportedMax != tc.maxConcurrency {
				t.Fatalf("ReportedMax = %d, want the raw claim %d", got.ReportedMax, tc.maxConcurrency)
			}
		})
	}
}

// Slot coherence is the invariant the ranking layer depends on: a clamped
// provider must never advertise more free slots than it has total, and never
// more total than its clamped concurrency.
func TestClampCapacitySlotCoherence(t *testing.T) {
	t.Parallel()
	const ceiling = 8
	for maxConcurrency := 0; maxConcurrency <= 40; maxConcurrency += 7 {
		for total := 0; total <= 40; total += 5 {
			for free := 0; free <= 40; free += 3 {
				got := ClampCapacity(maxConcurrency, total, free, ceiling)
				if got.MaxConcurrency > ceiling {
					t.Fatalf("max_concurrency %d exceeds ceiling for (%d,%d,%d)", got.MaxConcurrency, maxConcurrency, total, free)
				}
				if got.SlotsTotal > got.MaxConcurrency {
					t.Fatalf("slots_total %d exceeds clamped max %d for (%d,%d,%d)", got.SlotsTotal, got.MaxConcurrency, maxConcurrency, total, free)
				}
				if got.SlotsFree > got.SlotsTotal {
					t.Fatalf("slots_free %d exceeds slots_total %d for (%d,%d,%d)", got.SlotsFree, got.SlotsTotal, maxConcurrency, total, free)
				}
				if got.SlotsFree < 0 {
					t.Fatalf("slots_free %d is negative for (%d,%d,%d)", got.SlotsFree, maxConcurrency, total, free)
				}
			}
		}
	}
}
