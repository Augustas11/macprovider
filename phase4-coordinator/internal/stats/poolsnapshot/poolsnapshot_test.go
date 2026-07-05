package poolsnapshot

import (
	"math"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	statshardware "github.com/augstar/macprovider-coordinator/internal/stats/hardware"
)

type fakeSrc []pool.Provider

func (f fakeSrc) Snapshot() []pool.Provider { return []pool.Provider(f) }

type fakeHardware map[string]statshardware.Capacity

func (f fakeHardware) LookupProviderHardware(providerID string) (statshardware.Capacity, bool) {
	c, ok := f[providerID]
	return c, ok
}

func fixedTime() time.Time { return time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC) }

func newFixed(src Source) *Provider {
	p := New(src)
	p.now = fixedTime
	return p
}

func TestEmptyRegistryReturnsZeroSnapshot(t *testing.T) {
	got := newFixed(fakeSrc{}).OverviewSnapshot()
	if got.NodesOnline != 0 || got.NodesHardwareAttested != 0 ||
		got.UnifiedRAMGBTotal != 0 || got.ModelsServing != 0 ||
		got.NetworkUtilizationPct != 0 {
		t.Fatalf("expected zero snapshot, got %+v", got)
	}
	if !got.At.Equal(fixedTime()) {
		t.Fatalf("expected At=%v, got %v", fixedTime(), got.At)
	}
	if got.BandwidthGBPerSec != 0 || got.NetworkPowerKW != 0 ||
		got.GPUCoresTotal != 0 || got.CPUCoresTotal != 0 {
		t.Fatalf("hardware-inventory fields must default to zero: %+v", got)
	}
}

func TestCountsReadyAndBusyAsOnline(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, RAMGB: 16, ModelID: "m1"},
		{ProviderID: "b", State: pool.StateBusy, RAMGB: 32, ModelID: "m1"},
		{ProviderID: "c", State: pool.StateDegraded, RAMGB: 64, ModelID: "m2"},
		{ProviderID: "d", State: pool.StateDraining, RAMGB: 128, ModelID: "m3"},
		{ProviderID: "e", State: pool.StateUnavailable, RAMGB: 256, ModelID: "m4"},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NodesOnline != 2 {
		t.Fatalf("NodesOnline=%d want 2", got.NodesOnline)
	}
	if got.UnifiedRAMGBTotal != 48 {
		t.Fatalf("UnifiedRAMGBTotal=%d want 48", got.UnifiedRAMGBTotal)
	}
	if got.ModelsServing != 1 {
		t.Fatalf("ModelsServing=%d want 1 (only online provider models counted)", got.ModelsServing)
	}
}

func TestExcludesBearerlessDuplicate(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, RAMGB: 16, ModelID: "m1"},
		{ProviderID: "b", State: pool.StateReady, RAMGB: 32, ModelID: "m2", AuthState: pool.AuthBearerlessDuplicate},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NodesOnline != 1 {
		t.Fatalf("NodesOnline=%d want 1 (bearerless-duplicate excluded)", got.NodesOnline)
	}
	if got.UnifiedRAMGBTotal != 16 {
		t.Fatalf("UnifiedRAMGBTotal=%d want 16", got.UnifiedRAMGBTotal)
	}
	if got.ModelsServing != 1 {
		t.Fatalf("ModelsServing=%d want 1", got.ModelsServing)
	}
}

func TestExcludesSelfMintedFromPublicCapacity(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, RAMGB: 16, ModelID: "m1"},
		{ProviderID: "b", State: pool.StateReady, RAMGB: 32, ModelID: "m2", AuthState: pool.AuthSelfMinted},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NodesOnline != 1 {
		t.Fatalf("NodesOnline=%d want 1 (self-minted excluded)", got.NodesOnline)
	}
	if got.UnifiedRAMGBTotal != 16 {
		t.Fatalf("UnifiedRAMGBTotal=%d want 16", got.UnifiedRAMGBTotal)
	}
	if got.ModelsServing != 1 {
		t.Fatalf("ModelsServing=%d want 1", got.ModelsServing)
	}
}

func TestExcludesPendingReceiptPubkey(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, RAMGB: 16, ModelID: "m1", PendingReceiptPubkey: []byte{1, 2, 3}},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NodesOnline != 0 {
		t.Fatalf("NodesOnline=%d want 0 (pending receipt-key rotation excluded)", got.NodesOnline)
	}
}

func TestHardwareAttestedSubset(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, AttestationStatus: pool.AttestationStatusAttested},
		{ProviderID: "b", State: pool.StateReady, AttestationStatus: pool.AttestationStatusStale},
		{ProviderID: "c", State: pool.StateReady, AttestationStatus: pool.AttestationStatusNotRequired},
		{ProviderID: "d", State: pool.StateBusy, AttestationStatus: pool.AttestationStatusAttested},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NodesOnline != 4 {
		t.Fatalf("NodesOnline=%d want 4", got.NodesOnline)
	}
	if got.NodesHardwareAttested != 2 {
		t.Fatalf("NodesHardwareAttested=%d want 2", got.NodesHardwareAttested)
	}
}

func TestUtilizationFromSlots(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, SlotsTotal: 4, SlotsFree: 3},
		{ProviderID: "b", State: pool.StateBusy, SlotsTotal: 4, SlotsFree: 0},
		{ProviderID: "c", State: pool.StateReady, SlotsTotal: 2, SlotsFree: 1},
	}
	got := newFixed(src).OverviewSnapshot()
	// used = (4-3) + (4-0) + (2-1) = 6, total = 10, pct = 60
	if got.NetworkUtilizationPct != 60 {
		t.Fatalf("NetworkUtilizationPct=%d want 60", got.NetworkUtilizationPct)
	}
}

func TestUtilizationIgnoresOfflineProviders(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, SlotsTotal: 4, SlotsFree: 4},
		{ProviderID: "b", State: pool.StateDegraded, SlotsTotal: 100, SlotsFree: 0},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NetworkUtilizationPct != 0 {
		t.Fatalf("NetworkUtilizationPct=%d want 0 (offline provider's slots ignored)", got.NetworkUtilizationPct)
	}
}

func TestUtilizationClampsAtHundred(t *testing.T) {
	src := fakeSrc{
		// pathological: SlotsFree > SlotsTotal shouldn't produce negative used.
		{ProviderID: "a", State: pool.StateReady, SlotsTotal: 2, SlotsFree: 5},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.NetworkUtilizationPct != 0 {
		t.Fatalf("NetworkUtilizationPct=%d want 0 when SlotsFree > SlotsTotal", got.NetworkUtilizationPct)
	}
}

func TestModelsServingDistinct(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady, ModelID: "llama-3.1-8b"},
		{ProviderID: "b", State: pool.StateReady, ModelID: "llama-3.1-8b"},
		{ProviderID: "c", State: pool.StateReady, ModelID: "qwen-2.5-32b"},
		{ProviderID: "d", State: pool.StateReady, ModelID: ""},
	}
	got := newFixed(src).OverviewSnapshot()
	if got.ModelsServing != 2 {
		t.Fatalf("ModelsServing=%d want 2 (distinct non-empty models across online providers)", got.ModelsServing)
	}
}

func TestHardwareCapacityFromMemorySource(t *testing.T) {
	src := fakeSrc{
		{ProviderID: "a", State: pool.StateReady},
		{ProviderID: "b", State: pool.StateBusy},
		{ProviderID: "c", State: pool.StateDegraded},
		{ProviderID: "d", State: pool.StateReady},
	}
	p := NewWithHardware(src, fakeHardware{
		"a": {BandwidthGBPerSec: 120, NetworkPowerKW: 0.035, GPUCoresTotal: 10, CPUCoresTotal: 10},
		"b": {BandwidthGBPerSec: 400, NetworkPowerKW: 0.070, GPUCoresTotal: 32, CPUCoresTotal: 12},
		"c": {BandwidthGBPerSec: 999, NetworkPowerKW: 9.999, GPUCoresTotal: 99, CPUCoresTotal: 99},
	})
	p.now = fixedTime

	got := p.OverviewSnapshot()
	if got.BandwidthGBPerSec != 520 {
		t.Fatalf("BandwidthGBPerSec=%d want 520", got.BandwidthGBPerSec)
	}
	if math.Abs(got.NetworkPowerKW-0.105) > 0.000001 {
		t.Fatalf("NetworkPowerKW=%f want 0.105", got.NetworkPowerKW)
	}
	if got.GPUCoresTotal != 42 || got.CPUCoresTotal != 22 {
		t.Fatalf("cores gpu=%d cpu=%d want gpu=42 cpu=22", got.GPUCoresTotal, got.CPUCoresTotal)
	}
}

func TestMissingHardwareProfileContributesZero(t *testing.T) {
	p := NewWithHardware(fakeSrc{
		{ProviderID: "a", State: pool.StateReady, RAMGB: 24, ModelID: "m4"},
	}, fakeHardware{})
	p.now = fixedTime

	got := p.OverviewSnapshot()
	if got.NodesOnline != 1 || got.UnifiedRAMGBTotal != 24 || got.ModelsServing != 1 {
		t.Fatalf("missing hardware must not remove provider from live stats: %+v", got)
	}
	if got.BandwidthGBPerSec != 0 || got.NetworkPowerKW != 0 ||
		got.GPUCoresTotal != 0 || got.CPUCoresTotal != 0 {
		t.Fatalf("missing hardware should contribute zero capacity: %+v", got)
	}
}

func TestNilSourcePanics(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on nil source")
		}
	}()
	New(nil)
}
