package intake

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestParamsValidateRejectsEachBoundary(t *testing.T) {
	mut := map[string]func(p *Params){
		"key_buckets zero":      func(p *Params) { p.KeyBuckets = 0 },
		"principals zero":       func(p *Params) { p.PrincipalsPerBucket = 0 },
		"distinct cap zero":     func(p *Params) { p.DistinctKeyCap = 0 },
		"floor zero":            func(p *Params) { p.BuyerRequestFloor = 0 },
		"pct zero":              func(p *Params) { p.PrincipalCapPct = 0 },
		"pct 11":                func(p *Params) { p.PrincipalCapPct = 11 },
		"principals over max":   func(p *Params) { p.PrincipalsPerBucket = MaxPrincipalsPerBucket + 1 },
		"distinct cap over max": func(p *Params) { p.DistinctKeyCap = MaxDistinctKeyCap + 1 },
		"floor over max":        func(p *Params) { p.BuyerRequestFloor = MaxBuyerRequestFloor + 1 },
		"key buckets over max":  func(p *Params) { p.KeyBuckets = MaxKeyBuckets + 1 },
	}
	for name, f := range mut {
		p := DefaultParams()
		f(&p)
		if err := p.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// The maxima themselves are valid.
	p := Params{KeyBuckets: MaxKeyBuckets, PrincipalsPerBucket: MaxPrincipalsPerBucket, DistinctKeyCap: MaxDistinctKeyCap, BuyerRequestFloor: MaxBuyerRequestFloor, PrincipalCapPct: 10}
	if err := p.Validate(); err != nil {
		t.Fatalf("maxima rejected: %v", err)
	}
}

func TestNewRequiresNormalizeAndValidParams(t *testing.T) {
	if _, err := New(DefaultParams(), nil, WithPolicy(policyA, 0)); err == nil {
		t.Fatal("nil normalize accepted")
	}
	bad := DefaultParams()
	bad.KeyBuckets = 0
	if _, err := New(bad, lowerNormalize, WithPolicy(policyA, 0)); err == nil {
		t.Fatal("invalid params accepted")
	}
	if _, err := New(DefaultParams(), lowerNormalize); err == nil {
		t.Fatal("missing policy id accepted")
	}
}

func TestSnapshotSpansMultipleMissedEpochsWithEmptyWindows(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	start := c.t
	c.t = start.Add(65 * 24 * time.Hour)
	snap := a.Snapshot()
	if len(snap.Windows) != 2 {
		t.Fatalf("want 2 empty complete windows, got %d", len(snap.Windows))
	}
	for i, w := range snap.Windows {
		if len(w.Buckets) != 0 || w.Buckets == nil || !w.Complete() {
			t.Fatalf("window %d: %+v", i, w)
		}
		if err := ValidateWindow(w); err != nil {
			t.Fatalf("window %d invalid: %v", i, err)
		}
	}
	// Newest first: the first served window is the later epoch.
	if snap.Windows[0].WindowStart != start.Add(30*24*time.Hour).Format(time.RFC3339) {
		t.Fatalf("not newest first: %s", snap.Windows[0].WindowStart)
	}
	// Mutating a served copy must not alter stored state.
	wantEnd := *snap.Windows[0].WindowEnd
	*snap.Windows[0].WindowEnd = "x"
	again := a.Snapshot()
	if len(again.Windows) != 2 || *again.Windows[0].WindowEnd != wantEnd {
		t.Fatalf("snapshot aliases internal window: %+v", again.Windows)
	}
}

func TestOtherSuppressedSaturation(t *testing.T) {
	var o OtherSuppressed
	o.addRequests(5)
	o.addRequests(7)
	if o.RequestCount != 12 || o.RequestCountSaturated {
		t.Fatalf("%+v", o)
	}
	o.addRequests(requestCountSaturation - 12) // exactly reaches the ceiling
	if o.RequestCount != requestCountSaturation || !o.RequestCountSaturated {
		t.Fatalf("not saturated at ceiling: %+v", o)
	}
	o.addRequests(1)
	if o.RequestCount != requestCountSaturation {
		t.Fatalf("grew past saturation: %d", o.RequestCount)
	}

	o.addDistinct(3, 10)
	if o.DistinctKeyCount != 3 || o.DistinctKeyCountSaturated {
		t.Fatalf("%+v", o)
	}
	o.addDistinct(7, 10)
	if o.DistinctKeyCount != 10 || !o.DistinctKeyCountSaturated {
		t.Fatalf("not saturated at cap: %+v", o)
	}
	o.addDistinct(5, 10)
	if o.DistinctKeyCount != 10 {
		t.Fatalf("grew past cap: %d", o.DistinctKeyCount)
	}
}

func TestSortBucketsOrdersByBoundDescThenKeyAsc(t *testing.T) {
	b := []Bucket{{ModelKey: "b", LowerBound: 5}, {ModelKey: "z", LowerBound: 9}, {ModelKey: "a", LowerBound: 5}, {ModelKey: "c", LowerBound: 7}}
	sortBuckets(b)
	var got []string
	for _, x := range b {
		got = append(got, x.ModelKey)
	}
	if strings.Join(got, ",") != "z,c,a,b" {
		t.Fatalf("order = %v", got)
	}
}

func TestHexIDIsStrictLowercase32(t *testing.T) {
	for s, want := range map[string]bool{
		policyA:                  true,
		strings.Repeat("0", 32):  true,
		strings.ToUpper(policyA): false,
		strings.Repeat("g", 32):  false,
		strings.Repeat("a", 31):  false,
		strings.Repeat("a", 33):  false,
		"":                       false,
	} {
		if hexID(s) != want {
			t.Errorf("hexID(%q) = %v, want %v", s, !want, want)
		}
	}
}

func TestValidateAtRejectsFutureWindows(t *testing.T) {
	a, c := newTestAggregator(t, DefaultParams())
	c.t = c.t.Add(WindowMaxDays * 24 * time.Hour)
	w := a.Snapshot().Windows[0]
	end, _ := ParseUTC(*w.WindowEnd)
	if err := ValidateWindowAt(w, end); err != nil {
		t.Fatalf("window closed exactly now rejected: %v", err)
	}
	if err := ValidateWindowAt(w, end.Add(-time.Second)); err == nil {
		t.Fatal("future-dated window accepted")
	}
	bad := cloneWindow(w)
	bad.WindowID = "x"
	if err := ValidateWindowAt(bad, end); err == nil {
		t.Fatal("structurally invalid window accepted")
	}

	raw := fleetJSON("2026-08-12T00:00:00Z", "2026-09-11T00:00:00Z")
	endF := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	if err := ValidateFleetRAMJSONAt([]byte(raw), endF); err != nil {
		t.Fatalf("fleet window ending now rejected: %v", err)
	}
	if err := ValidateFleetRAMJSONAt([]byte(raw), endF.Add(-time.Second)); err == nil {
		t.Fatal("future fleet window accepted")
	}
	if err := ValidateFleetRAMJSONAt([]byte(`{}`), endF); err == nil {
		t.Fatal("invalid fleet_ram accepted")
	}
}

func fleetJSON(start, end string) string {
	var cls []string
	for _, f := range FleetRAMClassFloors {
		cls = append(cls, `{"ram_gb_floor":`+strconv.Itoa(f)+`,"provider_count":null,"suppressed":true}`)
	}
	return `{"window_start":"` + start + `","window_end":"` + end + `","k_anonymity_min":3,"provider_total":0,"provider_suppressed":0,"classes":[` + strings.Join(cls, ",") + `]}`
}
