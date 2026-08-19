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
	"fmt"
	"math"
	"sort"
	"strings"
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
		// Hardware-attested means hardware-rooted attestation, not key custody:
		// a self-signed SE key satisfies AttestationStatusAttested but must not
		// count toward the public nodes_hardware_attested figure.
		if prov.AttestationStatus == pool.AttestationStatusAttested && prov.AttestationTier == pool.AttestationTierHardware {
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

// RoutabilitySnapshot implements statsrollup.RoutabilitySnapshotProvider.
func (p *Provider) RoutabilitySnapshot() statsrollup.RoutabilitySnapshot {
	now := p.now()
	providers := p.src.Snapshot()
	models := make(map[string]*modelRollup, len(providers))
	out := statsrollup.RoutabilitySnapshot{At: now}

	for _, prov := range providers {
		if !publicRoutabilityAdmission(prov) {
			continue
		}
		out.Summary.ProvidersTotal++
		routable := prov.RoutingEligible()
		serving := prov.ServingCapable()
		if routable {
			out.Summary.ProvidersRoutable++
		}
		if serving {
			out.Summary.ProvidersServingCapable++
		}

		modelID := strings.TrimSpace(prov.ModelID)
		if modelID != "" {
			m := modelStats(models, modelID)
			m.providerCount++
			if routable {
				m.routableProviderCount++
			}
			if serving {
				m.servingCapableProviderCount++
			}
			if prov.SlotsFree > 0 {
				m.slotsFree += prov.SlotsFree
			}
			if prov.SlotsTotal > 0 {
				m.slotsTotal += prov.SlotsTotal
			}
			if prov.MaxContextTokens > m.maxContextTokens {
				m.maxContextTokens = prov.MaxContextTokens
			}
			if recentSuccess1h(prov, now) {
				m.recentSuccessProviderCount1h++
			}
		}
		if prov.PublishesSupportedModels {
			for _, supported := range prov.SupportedModels {
				supported = strings.TrimSpace(supported)
				if supported == "" {
					continue
				}
				modelStats(models, supported).declaredOnly = true
			}
		}

		out.Providers = append(out.Providers, statsrollup.ProviderRoutability{
			ModelID:                 modelID,
			State:                   publicProviderState(prov, routable, serving, now),
			Routable:                routable,
			ServingCapable:          serving,
			RoutabilityScore:        publicRoutabilityScore(prov, routable, serving, now),
			SlotsFree:               nonNegativeInt(prov.SlotsFree),
			SlotsTotal:              nonNegativeInt(prov.SlotsTotal),
			LastHeartbeatAgeSeconds: ageSeconds(now, prov.LastHeartbeatAt),
			UptimeBucket:            uptimeBucket(prov, now),
			RecentSuccess1h:         recentSuccess1h(prov, now),
			ReceiptValidity:         receiptValidity(prov),
			Attestation:             attestationSummary(prov),
			ComputeIntegrity:        computeIntegritySummary(prov),
			StaleData:               heartbeatStale(prov, now),
		})
	}

	modelKeys := make([]string, 0, len(models))
	for modelID := range models {
		modelKeys = append(modelKeys, modelID)
	}
	sort.Strings(modelKeys)
	for _, modelID := range modelKeys {
		m := models[modelID]
		row := statsrollup.ModelRoutability{
			ModelID:                      modelID,
			State:                        publicModelState(m),
			ProviderCount:                m.providerCount,
			RoutableProviderCount:        m.routableProviderCount,
			ServingCapableProviderCount:  m.servingCapableProviderCount,
			SlotsFree:                    m.slotsFree,
			SlotsTotal:                   m.slotsTotal,
			MaxContextTokens:             m.maxContextTokens,
			RecentSuccessProviderCount1h: m.recentSuccessProviderCount1h,
		}
		out.Models = append(out.Models, row)
		switch row.State {
		case "redundant":
			out.Summary.ModelsRedundant++
		case "operational":
			out.Summary.ModelsOperational++
		case "degraded":
			out.Summary.ModelsDegraded++
		case "unknown":
			out.Summary.ModelsUnknown++
		case "offline":
			out.Summary.ModelsOffline++
		}
	}
	out.Summary.ModelsTotal = len(out.Models)
	out.Summary.State = networkState(out.Summary)
	sort.Slice(out.Providers, func(i, j int) bool { return publicProviderLess(out.Providers[i], out.Providers[j]) })
	for i := range out.Providers {
		out.Providers[i].ProviderRef = fmt.Sprintf("provider_%06d", i+1)
	}
	return out
}

type modelRollup struct {
	providerCount                int
	routableProviderCount        int
	servingCapableProviderCount  int
	slotsFree                    int
	slotsTotal                   int
	maxContextTokens             int
	recentSuccessProviderCount1h int
	declaredOnly                 bool
}

func modelStats(models map[string]*modelRollup, modelID string) *modelRollup {
	m := models[modelID]
	if m == nil {
		m = &modelRollup{}
		models[modelID] = m
	}
	return m
}

func publicRoutabilityAdmission(prov pool.Provider) bool {
	if strings.TrimSpace(prov.ProviderID) == "" {
		return false
	}
	if prov.AuthState == pool.AuthBearerlessDuplicate || prov.AuthState == pool.AuthSelfMinted {
		return false
	}
	if prov.CatalogAdmissionMode == "legacy" || prov.CatalogAdmissionMode == "update_bridge" {
		return false
	}
	if prov.BenchmarkQuarantined || prov.AdmissionCeilingExcluded || prov.AdmissionEvidenceStale || prov.AdmissionSandboxed {
		return false
	}
	return true
}

func publicProviderLess(a, b statsrollup.ProviderRoutability) bool {
	if a.ModelID != b.ModelID {
		return a.ModelID < b.ModelID
	}
	if a.State != b.State {
		return a.State < b.State
	}
	if a.Routable != b.Routable {
		return !a.Routable && b.Routable
	}
	if a.ServingCapable != b.ServingCapable {
		return !a.ServingCapable && b.ServingCapable
	}
	if a.RoutabilityScore != b.RoutabilityScore {
		return a.RoutabilityScore < b.RoutabilityScore
	}
	if a.SlotsFree != b.SlotsFree {
		return a.SlotsFree < b.SlotsFree
	}
	if a.SlotsTotal != b.SlotsTotal {
		return a.SlotsTotal < b.SlotsTotal
	}
	if a.LastHeartbeatAgeSeconds != b.LastHeartbeatAgeSeconds {
		return a.LastHeartbeatAgeSeconds < b.LastHeartbeatAgeSeconds
	}
	if a.UptimeBucket != b.UptimeBucket {
		return a.UptimeBucket < b.UptimeBucket
	}
	if a.RecentSuccess1h != b.RecentSuccess1h {
		return !a.RecentSuccess1h && b.RecentSuccess1h
	}
	if a.ReceiptValidity != b.ReceiptValidity {
		return a.ReceiptValidity < b.ReceiptValidity
	}
	if a.Attestation != b.Attestation {
		return a.Attestation < b.Attestation
	}
	if a.ComputeIntegrity != b.ComputeIntegrity {
		return a.ComputeIntegrity < b.ComputeIntegrity
	}
	if a.StaleData != b.StaleData {
		return !a.StaleData && b.StaleData
	}
	return false
}

func publicModelState(m *modelRollup) string {
	switch {
	case m.routableProviderCount >= 2:
		return "redundant"
	case m.routableProviderCount == 1:
		return "operational"
	case m.servingCapableProviderCount > 0:
		return "degraded"
	case m.providerCount > 0:
		return "offline"
	case m.declaredOnly:
		return "unknown"
	default:
		return "offline"
	}
}

func networkState(s statsrollup.RoutabilitySummary) string {
	switch {
	case s.ModelsRedundant > 0:
		return "redundant"
	case s.ModelsOperational > 0:
		return "operational"
	case s.ModelsDegraded > 0 || s.ProvidersServingCapable > 0:
		return "degraded"
	case s.ModelsUnknown > 0:
		return "unknown"
	default:
		return "offline"
	}
}

func publicProviderState(prov pool.Provider, routable, serving bool, now time.Time) string {
	if heartbeatStale(prov, now) && serving {
		return "unknown"
	}
	if routable {
		return "online"
	}
	if serving {
		return "degraded"
	}
	return "offline"
}

func publicRoutabilityScore(prov pool.Provider, routable, serving bool, now time.Time) int {
	switch {
	case routable:
		score := 100
		if heartbeatStale(prov, now) {
			score -= 25
		}
		if receiptValidity(prov) != "present" {
			score -= 25
		}
		if score < 0 {
			return 0
		}
		return score
	case serving:
		return 50
	case prov.State == pool.StateDegraded:
		return 25
	default:
		return 0
	}
}

func heartbeatStale(prov pool.Provider, now time.Time) bool {
	if prov.LastHeartbeatAt.IsZero() {
		return true
	}
	return now.Sub(prov.LastHeartbeatAt) > 30*time.Second
}

func ageSeconds(now, at time.Time) int {
	if at.IsZero() {
		return -1
	}
	age := int(now.Sub(at).Seconds())
	if age < 0 {
		return 0
	}
	return age
}

func uptimeBucket(prov pool.Provider, now time.Time) string {
	var seconds int
	if prov.SafetyTelemetry != nil && prov.SafetyTelemetry.UptimeS > 0 {
		seconds = prov.SafetyTelemetry.UptimeS
	} else if !prov.ConnectedAt.IsZero() {
		seconds = ageSeconds(now, prov.ConnectedAt)
	}
	switch {
	case seconds <= 0:
		return "unknown"
	case seconds < 3600:
		return "lt_1h"
	case seconds < 24*3600:
		return "1h_24h"
	case seconds < 7*24*3600:
		return "1d_7d"
	default:
		return "gte_7d"
	}
}

func recentSuccess1h(prov pool.Provider, now time.Time) bool {
	if prov.LastBuyerSuccessAt == nil {
		return false
	}
	return now.Sub(*prov.LastBuyerSuccessAt) <= time.Hour
}

func receiptValidity(prov pool.Provider) string {
	switch {
	case len(prov.PendingReceiptPubkey) > 0:
		return "pending_rotation"
	case len(prov.ReceiptPubkey) > 0:
		return "present"
	default:
		return "missing"
	}
}

func attestationSummary(prov pool.Provider) string {
	if prov.AttestationStatus != pool.AttestationStatusAttested {
		if prov.AttestationStatus == "" {
			return "unknown"
		}
		return string(prov.AttestationStatus)
	}
	if prov.AttestationTier == pool.AttestationTierHardware {
		return "hardware"
	}
	if prov.AttestationTier == pool.AttestationTierSelfSigned {
		return "self_signed"
	}
	return "attested"
}

func computeIntegritySummary(prov pool.Provider) string {
	if prov.HashStatus == "" {
		return "unknown"
	}
	return string(prov.HashStatus)
}

func nonNegativeInt(v int) int {
	if v < 0 {
		return 0
	}
	return v
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
