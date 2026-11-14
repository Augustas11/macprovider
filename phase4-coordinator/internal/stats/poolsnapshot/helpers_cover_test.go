package poolsnapshot

import (
	"math"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/intake"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	statsrollup "github.com/augstar/macprovider-coordinator/internal/stats/rollup"
)

type fakeIntake struct{ out intake.UnmatchedModels }

func (f fakeIntake) Snapshot() intake.UnmatchedModels { return f.out }

func TestIntakeSnapshotDefaultsAndDelegates(t *testing.T) {
	p := newFixed(fakeSrc{})
	got := p.IntakeSnapshot()
	if got.Contract != intake.Contract || got.Windows == nil || len(got.Windows) != 0 {
		t.Fatalf("default intake snapshot = %+v", got)
	}
	want := intake.UnmatchedModels{Contract: "x", Windows: []intake.Window{{WindowID: "w1"}}}
	if p.WithIntake(fakeIntake{want}) != p {
		t.Fatal("WithIntake must return the receiver")
	}
	got = p.IntakeSnapshot()
	if got.Contract != "x" || len(got.Windows) != 1 || got.Windows[0].WindowID != "w1" {
		t.Fatalf("delegated intake snapshot = %+v", got)
	}
}

func TestPublicRoutabilityAdmission(t *testing.T) {
	ok := pool.Provider{ProviderID: "p"}
	if !publicRoutabilityAdmission(ok) {
		t.Fatal("plain provider must be admitted")
	}
	cases := map[string]pool.Provider{
		"blank id":      {ProviderID: "  "},
		"bearerless":    {ProviderID: "p", AuthState: pool.AuthBearerlessDuplicate},
		"self minted":   {ProviderID: "p", AuthState: pool.AuthSelfMinted},
		"legacy":        {ProviderID: "p", CatalogAdmissionMode: "legacy"},
		"update bridge": {ProviderID: "p", CatalogAdmissionMode: "update_bridge"},
		"quarantined":   {ProviderID: "p", BenchmarkQuarantined: true},
		"ceiling":       {ProviderID: "p", AdmissionCeilingExcluded: true},
		"stale":         {ProviderID: "p", AdmissionEvidenceStale: true},
		"sandboxed":     {ProviderID: "p", AdmissionSandboxed: true},
		"scorer":        {ProviderID: "p", ComputeScoreReference: true},
	}
	for name, prov := range cases {
		if publicRoutabilityAdmission(prov) {
			t.Errorf("%s must not be admitted", name)
		}
	}
}

func TestPublicModelAndNetworkState(t *testing.T) {
	models := []struct {
		m    modelRollup
		want string
	}{
		{modelRollup{inServiceProviderCount: 2, routableProviderCount: 2}, "redundant"},
		{modelRollup{inServiceProviderCount: 1, routableProviderCount: 1}, "operational"},
		// #2371: two providers serving on every slot (none routable) stay redundant.
		{modelRollup{providerCount: 2, servingCapableProviderCount: 2, inServiceProviderCount: 2}, "redundant"},
		{modelRollup{providerCount: 1, servingCapableProviderCount: 1, inServiceProviderCount: 1}, "operational"},
		// Serving-capable but held by a fault: no provider can take its traffic.
		{modelRollup{servingCapableProviderCount: 1, providerCount: 1}, "offline"},
		{modelRollup{providerCount: 1}, "offline"},
		{modelRollup{declaredOnly: true}, "unknown"},
		{modelRollup{}, "offline"},
	}
	for _, c := range models {
		if got := publicModelState(&c.m); got != c.want {
			t.Errorf("publicModelState(%+v)=%q want %q", c.m, got, c.want)
		}
	}
	nets := []struct {
		s    statsrollup.RoutabilitySummary
		want string
	}{
		{statsrollup.RoutabilitySummary{ModelsRedundant: 1, ModelsOperational: 1}, "redundant"},
		{statsrollup.RoutabilitySummary{ModelsOperational: 1}, "operational"},
		{statsrollup.RoutabilitySummary{ModelsOperational: 1, ProvidersServingCapable: 1, ProvidersRoutable: 0}, "operational"},
		{statsrollup.RoutabilitySummary{ModelsRedundant: 1, ProvidersServingCapable: 2, ProvidersRoutable: 0}, "redundant"},
		// Serving-capable providers but no model in service: every one is fault-held.
		{statsrollup.RoutabilitySummary{ModelsOffline: 1, ProvidersServingCapable: 1}, "degraded"},
		{statsrollup.RoutabilitySummary{ModelsUnknown: 1}, "unknown"},
		{statsrollup.RoutabilitySummary{}, "offline"},
	}
	for _, c := range nets {
		if got := networkState(c.s); got != c.want {
			t.Errorf("networkState(%+v)=%q want %q", c.s, got, c.want)
		}
	}
}

func TestProviderStateAndScore(t *testing.T) {
	now := fixedTime()
	fresh := now.Add(-5 * time.Second)
	stale := now.Add(-5 * time.Minute)
	withReceipt := []byte{1}

	type tc struct {
		name      string
		prov      pool.Provider
		routable  bool
		serving   bool
		wantState string
		wantScore int
	}
	cases := []tc{
		{"stale serving", pool.Provider{LastHeartbeatAt: stale}, false, true, "unknown", 50},
		{"routable healthy", pool.Provider{LastHeartbeatAt: fresh, ReceiptPubkey: withReceipt}, true, true, "online", 100},
		{"routable no receipt", pool.Provider{LastHeartbeatAt: fresh}, true, true, "online", 75},
		{"routable stale no receipt", pool.Provider{LastHeartbeatAt: stale}, true, false, "online", 50},
		{"full fresh", pool.Provider{LastHeartbeatAt: fresh, State: pool.StateBusy, SlotsTotal: 2}, false, true, "online", 50},
		{"integrity suspended", pool.Provider{LastHeartbeatAt: fresh, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 2, ComputeIntegritySuspended: true}, false, true, "degraded", 50},
		{"catalog recheck pending", pool.Provider{LastHeartbeatAt: fresh, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 2, CatalogRecheckPending: true}, false, true, "degraded", 50},
		{"handshake ack pending", pool.Provider{LastHeartbeatAt: fresh, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 2, HandshakeAckPending: true}, false, true, "degraded", 50},
		{"shard group unavailable", pool.Provider{LastHeartbeatAt: fresh, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 2, ShardGroupHeadV1: true}, false, true, "degraded", 50},
		{"stale full", pool.Provider{LastHeartbeatAt: stale, State: pool.StateBusy, SlotsTotal: 2}, false, true, "unknown", 50},
		{"degraded state", pool.Provider{LastHeartbeatAt: fresh, State: pool.StateDegraded}, false, false, "offline", 25},
		{"offline", pool.Provider{LastHeartbeatAt: fresh}, false, false, "offline", 0},
	}
	for _, c := range cases {
		if got := publicProviderState(c.prov, c.routable, c.serving, now); got != c.wantState {
			t.Errorf("%s: state=%q want %q", c.name, got, c.wantState)
		}
		if got := publicRoutabilityScore(c.prov, c.routable, c.serving, now); got != c.wantScore {
			t.Errorf("%s: score=%d want %d", c.name, got, c.wantScore)
		}
	}
}

func TestHeartbeatStaleAndAgeSeconds(t *testing.T) {
	now := fixedTime()
	if !heartbeatStale(pool.Provider{}, now) {
		t.Error("zero heartbeat must be stale")
	}
	if heartbeatStale(pool.Provider{LastHeartbeatAt: now.Add(-30 * time.Second)}, now) {
		t.Error("exactly 30s old must not be stale")
	}
	if !heartbeatStale(pool.Provider{LastHeartbeatAt: now.Add(-31 * time.Second)}, now) {
		t.Error("31s old must be stale")
	}
	if got := ageSeconds(now, time.Time{}); got != -1 {
		t.Errorf("zero time age=%d want -1", got)
	}
	if got := ageSeconds(now, now.Add(time.Minute)); got != 0 {
		t.Errorf("future time age=%d want 0", got)
	}
	if got := ageSeconds(now, now.Add(-90*time.Second)); got != 90 {
		t.Errorf("age=%d want 90", got)
	}
}

func TestUptimeBucket(t *testing.T) {
	now := fixedTime()
	connected := func(d time.Duration) pool.Provider { return pool.Provider{ConnectedAt: now.Add(-d)} }
	cases := []struct {
		name string
		prov pool.Provider
		want string
	}{
		{"nothing", pool.Provider{}, "unknown"},
		{"just connected", connected(0), "unknown"},
		{"30m", connected(30 * time.Minute), "lt_1h"},
		{"1h", connected(time.Hour), "1h_24h"},
		{"23h", connected(23 * time.Hour), "1h_24h"},
		{"24h", connected(24 * time.Hour), "1d_7d"},
		{"6d", connected(6 * 24 * time.Hour), "1d_7d"},
		{"7d", connected(7 * 24 * time.Hour), "gte_7d"},
		{"telemetry wins", pool.Provider{ConnectedAt: now.Add(-time.Minute), SafetyTelemetry: &pool.ProviderSafetyTelemetry{UptimeS: 8 * 24 * 3600}}, "gte_7d"},
		{"zero telemetry falls back", pool.Provider{ConnectedAt: now.Add(-2 * time.Hour), SafetyTelemetry: &pool.ProviderSafetyTelemetry{}}, "1h_24h"},
	}
	for _, c := range cases {
		if got := uptimeBucket(c.prov, now); got != c.want {
			t.Errorf("%s: %q want %q", c.name, got, c.want)
		}
	}
}

func TestReceiptAttestationAndIntegritySummaries(t *testing.T) {
	if got := receiptValidity(pool.Provider{PendingReceiptPubkey: []byte{1}, ReceiptPubkey: []byte{2}}); got != "pending_rotation" {
		t.Errorf("pending wins: %q", got)
	}
	if got := receiptValidity(pool.Provider{ReceiptPubkey: []byte{2}}); got != "present" {
		t.Errorf("present: %q", got)
	}
	if got := receiptValidity(pool.Provider{}); got != "missing" {
		t.Errorf("missing: %q", got)
	}

	att := pool.AttestationStatusAttested
	cases := []struct {
		prov pool.Provider
		want string
	}{
		{pool.Provider{}, "unknown"},
		{pool.Provider{AttestationStatus: pool.AttestationStatusFailed, AttestationTier: pool.AttestationTierHardware}, "attestation_failed"},
		{pool.Provider{AttestationStatus: att, AttestationTier: pool.AttestationTierHardware}, "hardware"},
		{pool.Provider{AttestationStatus: att, AttestationTier: pool.AttestationTierSelfSigned}, "self_signed"},
		{pool.Provider{AttestationStatus: att}, "attested"},
	}
	for _, c := range cases {
		if got := attestationSummary(c.prov); got != c.want {
			t.Errorf("attestationSummary(%+v)=%q want %q", c.prov.AttestationStatus, got, c.want)
		}
	}

	if got := computeIntegritySummary(pool.Provider{}); got != "unknown" {
		t.Errorf("empty hash status: %q", got)
	}
	if got := computeIntegritySummary(pool.Provider{HashStatus: pool.HashStatus("verified")}); got != "verified" {
		t.Errorf("hash status passthrough: %q", got)
	}
}

func TestPublicProviderLessOrdering(t *testing.T) {
	base := statsrollup.ProviderRoutability{}
	mut := []struct {
		name string
		lo   func(*statsrollup.ProviderRoutability)
		hi   func(*statsrollup.ProviderRoutability)
	}{
		{"model", func(r *statsrollup.ProviderRoutability) { r.ModelID = "a" }, func(r *statsrollup.ProviderRoutability) { r.ModelID = "b" }},
		{"state", func(r *statsrollup.ProviderRoutability) { r.State = "a" }, func(r *statsrollup.ProviderRoutability) { r.State = "b" }},
		{"routable", func(r *statsrollup.ProviderRoutability) {}, func(r *statsrollup.ProviderRoutability) { r.Routable = true }},
		{"serving", func(r *statsrollup.ProviderRoutability) {}, func(r *statsrollup.ProviderRoutability) { r.ServingCapable = true }},
		{"score", func(r *statsrollup.ProviderRoutability) { r.RoutabilityScore = 1 }, func(r *statsrollup.ProviderRoutability) { r.RoutabilityScore = 2 }},
		{"slotsFree", func(r *statsrollup.ProviderRoutability) { r.SlotsFree = 1 }, func(r *statsrollup.ProviderRoutability) { r.SlotsFree = 2 }},
		{"slotsTotal", func(r *statsrollup.ProviderRoutability) { r.SlotsTotal = 1 }, func(r *statsrollup.ProviderRoutability) { r.SlotsTotal = 2 }},
		{"age", func(r *statsrollup.ProviderRoutability) { r.LastHeartbeatAgeSeconds = 1 }, func(r *statsrollup.ProviderRoutability) { r.LastHeartbeatAgeSeconds = 2 }},
		{"uptime", func(r *statsrollup.ProviderRoutability) { r.UptimeBucket = "a" }, func(r *statsrollup.ProviderRoutability) { r.UptimeBucket = "b" }},
		{"recent", func(r *statsrollup.ProviderRoutability) {}, func(r *statsrollup.ProviderRoutability) { r.RecentSuccess1h = true }},
		{"receipt", func(r *statsrollup.ProviderRoutability) { r.ReceiptValidity = "a" }, func(r *statsrollup.ProviderRoutability) { r.ReceiptValidity = "b" }},
		{"attestation", func(r *statsrollup.ProviderRoutability) { r.Attestation = "a" }, func(r *statsrollup.ProviderRoutability) { r.Attestation = "b" }},
		{"integrity", func(r *statsrollup.ProviderRoutability) { r.ComputeIntegrity = "a" }, func(r *statsrollup.ProviderRoutability) { r.ComputeIntegrity = "b" }},
		{"stale", func(r *statsrollup.ProviderRoutability) {}, func(r *statsrollup.ProviderRoutability) { r.StaleData = true }},
	}
	for _, m := range mut {
		lo, hi := base, base
		m.lo(&lo)
		m.hi(&hi)
		if !publicProviderLess(lo, hi) {
			t.Errorf("%s: lo must sort before hi", m.name)
		}
		if publicProviderLess(hi, lo) {
			t.Errorf("%s: hi must not sort before lo", m.name)
		}
	}
	if publicProviderLess(base, base) {
		t.Error("equal rows must not be less")
	}
}

func TestSaturatingAndClampHelpers(t *testing.T) {
	if got := nonNegativeInt(-3); got != 0 {
		t.Errorf("nonNegativeInt(-3)=%d", got)
	}
	if got := nonNegativeInt(7); got != 7 {
		t.Errorf("nonNegativeInt(7)=%d", got)
	}
	if got := saturatingAddInt64(5, -2, 100); got != 5 {
		t.Errorf("int64 negative add=%d", got)
	}
	if got := saturatingAddInt64(100, 1, 100); got != 100 {
		t.Errorf("int64 at max=%d", got)
	}
	if got := saturatingAddInt64(1, 100, 100); got != 100 {
		t.Errorf("int64 overflow=%d", got)
	}
	if got := saturatingAddInt64(5, 0, 100); got != 5 {
		t.Errorf("int64 zero add=%d", got)
	}
	if got := saturatingAddInt64(40, 60, 100); got != 100 {
		t.Errorf("int64 exact boundary=%d", got)
	}
	if got := saturatingAddInt(4, 6, 10); got != 10 {
		t.Errorf("int exact boundary=%d", got)
	}
	if got := saturatingAddInt64(1, 2, 100); got != 3 {
		t.Errorf("int64 add=%d", got)
	}
	if got := saturatingAddInt(5, 0, 10); got != 5 {
		t.Errorf("int zero add=%d", got)
	}
	if got := saturatingAddInt(10, 1, 10); got != 10 {
		t.Errorf("int at max=%d", got)
	}
	if got := saturatingAddInt(5, 6, 10); got != 10 {
		t.Errorf("int overflow=%d", got)
	}
	if got := saturatingAddInt(5, 4, 10); got != 9 {
		t.Errorf("int add=%d", got)
	}
	if got := saturatingAddFloat64(1, math.NaN(), 10); got != 1 {
		t.Errorf("float NaN add=%v", got)
	}
	if got := saturatingAddFloat64(1, math.Inf(1), 10); got != 1 {
		t.Errorf("float Inf add=%v", got)
	}
	if got := saturatingAddFloat64(1, -1, 10); got != 1 {
		t.Errorf("float negative add=%v", got)
	}
	if got := saturatingAddFloat64(8, 5, 10); got != 10 {
		t.Errorf("float cap=%v", got)
	}
	if got := saturatingAddFloat64(8, 1.5, 10); got != 9.5 {
		t.Errorf("float add=%v", got)
	}
}
