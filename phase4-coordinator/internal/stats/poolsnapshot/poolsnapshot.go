// Package poolsnapshot adapts an in-process pool.Registry into a
// stats/rollup.SnapshotProvider, so the SPEC-017 §5.1 overview
// endpoint surfaces the live nodes_online / utilization / RAM /
// models_serving / hardware_attested counts that ZeroSnapshotProvider
// leaves at zero.
//
// Fields derivable from pool.Provider today are wired here. Fields that
// need a per-chip hardware profile (bandwidth, power, GPU cores, CPU
// cores) are filled only from an optional in-memory hardware source so
// stats enrichment never performs database work while observing the
// live provider registry.
package poolsnapshot

import (
	"math"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	statshardware "github.com/augstar/macprovider-coordinator/internal/stats/hardware"
	statsrollup "github.com/augstar/macprovider-coordinator/internal/stats/rollup"
)

const (
	maxOverviewInt            = int(^uint32(0) >> 1)
	maxOverviewBandwidthGBSec = int64(^uint64(0) >> 1)
	maxOverviewNetworkPowerKW = 1_000_000.0
)

// Source is the narrow subset of pool.Registry the snapshot needs.
// Kept as an interface so tests can inject a fake without spinning
// up a full Registry.
type Source interface {
	Snapshot() []pool.Provider
}

// HardwareSource is intentionally memory-only. Implementations must not query
// databases or external services from LookupProviderHardware.
type HardwareSource interface {
	LookupProviderHardware(providerID string) (statshardware.Capacity, bool)
}

// Provider satisfies statsrollup.SnapshotProvider by computing the
// live overview snapshot from the current pool state on each tick.
type Provider struct {
	src      Source
	hardware HardwareSource
	now      func() time.Time
}

// New returns a Provider that reads from src. Panics if src is nil.
func New(src Source) *Provider {
	if src == nil {
		panic("poolsnapshot.New: src must not be nil")
	}
	return &Provider{src: src, now: func() time.Time { return time.Now().UTC() }}
}

// NewWithHardware returns a Provider that enriches eligible live providers
// from a memory-only hardware cache.
func NewWithHardware(src Source, hardware HardwareSource) *Provider {
	p := New(src)
	p.hardware = hardware
	return p
}

// OverviewSnapshot implements statsrollup.SnapshotProvider.
func (p *Provider) OverviewSnapshot() statsrollup.OverviewSnapshot {
	snap := statsrollup.OverviewSnapshot{At: p.now()}
	models := map[string]struct{}{}
	var slotsFree, slotsTotal int
	for _, prov := range p.src.Snapshot() {
		if !onlineForStats(prov) {
			continue
		}
		snap.NodesOnline++
		snap.CapacityEligibleProviderIDs = append(snap.CapacityEligibleProviderIDs, prov.ProviderID)
		if prov.AttestationStatus == pool.AttestationStatusAttested {
			snap.NodesHardwareAttested++
		}
		snap.UnifiedRAMGBTotal += prov.RAMGB
		if prov.ModelID != "" {
			models[prov.ModelID] = struct{}{}
		}
		if cap, ok := p.providerHardwareCapacity(prov); ok {
			snap.BandwidthGBPerSec = saturatingAddInt64(snap.BandwidthGBPerSec, cap.BandwidthGBPerSec, maxOverviewBandwidthGBSec)
			snap.NetworkPowerKW = saturatingAddFloat64(snap.NetworkPowerKW, cap.NetworkPowerKW, maxOverviewNetworkPowerKW)
			snap.GPUCoresTotal = saturatingAddInt(snap.GPUCoresTotal, cap.GPUCoresTotal, maxOverviewInt)
			snap.CPUCoresTotal = saturatingAddInt(snap.CPUCoresTotal, cap.CPUCoresTotal, maxOverviewInt)
		}
		if prov.SlotsTotal > 0 {
			slotsFree += prov.SlotsFree
			slotsTotal += prov.SlotsTotal
		}
	}
	snap.ModelsServing = len(models)
	if slotsTotal > 0 {
		used := slotsTotal - slotsFree
		if used < 0 {
			used = 0
		}
		snap.NetworkUtilizationPct = int((int64(used) * 100) / int64(slotsTotal))
		if snap.NetworkUtilizationPct > 100 {
			snap.NetworkUtilizationPct = 100
		}
	}
	return snap
}

func saturatingAddInt64(a, b, max int64) int64 {
	if b <= 0 {
		return a
	}
	if a >= max || b > max-a {
		return max
	}
	return a + b
}

func saturatingAddInt(a, b, max int) int {
	if b <= 0 {
		return a
	}
	if a >= max || b > max-a {
		return max
	}
	return a + b
}

func saturatingAddFloat64(a, b, max float64) float64 {
	if b <= 0 || math.IsNaN(b) || math.IsInf(b, 0) {
		return a
	}
	sum := a + b
	if math.IsNaN(sum) || math.IsInf(sum, 0) || sum > max {
		return max
	}
	return sum
}

func (p *Provider) providerHardwareCapacity(prov pool.Provider) (statshardware.Capacity, bool) {
	if p.hardware != nil {
		if cap, ok := p.hardware.LookupProviderHardware(prov.ProviderID); ok {
			return cap, true
		}
	}
	if prov.HardwareCapacity == nil {
		return statshardware.Capacity{}, false
	}
	cap := statshardware.Capacity{
		BandwidthGBPerSec: prov.HardwareCapacity.BandwidthGBPerSec,
		NetworkPowerKW:    prov.HardwareCapacity.NetworkPowerKW,
		GPUCoresTotal:     prov.HardwareCapacity.GPUCoresTotal,
		CPUCoresTotal:     prov.HardwareCapacity.CPUCoresTotal,
	}
	return cap, cap.BandwidthGBPerSec != 0 || cap.NetworkPowerKW != 0 ||
		cap.GPUCoresTotal != 0 || cap.CPUCoresTotal != 0
}

// onlineForStats mirrors "genuinely serving traffic" for the public stats
// surface: ready or busy (a busy provider is online, just out of free slots),
// while reusing the pool-level capacity trust predicate.
func onlineForStats(p pool.Provider) bool {
	return p.CapacityEligible()
}
