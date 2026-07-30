package pow

import (
	"context"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const EventTelemetryDriftDetected = "pow_telemetry_drift_detected"

const defaultTPSMinRequestsWindow = 2

// SignalMissingBenchmark is the issue-#765 suspect bucket: the provider has no
// verified autotune benchmark, so the TPS and artifact-drift gates below have
// no baseline to compare against. Before #765 that state exited the evaluator
// silently (fail-open) — it is now a named signal and, when
// QuarantineMissingBenchmark is set, a routing quarantine.
const SignalMissingBenchmark = "missing_benchmark"

type TelemetryDriftConfig struct {
	Enabled                  bool
	TPSRatioThreshold        float64
	TPSMinAbsolute           float64
	TPSMinRequestsWindow     int
	HashAlertOnStatus        []pool.HashStatus
	HashAlertOnArtifactDrift bool
	OPoIPassRateWindow       int
	OPoIPassRateThreshold    float64
	AlertCooldown            time.Duration
	// QuarantineMissingBenchmark escalates SignalMissingBenchmark from an
	// observe-only alert to BenchmarkVerdictMissing, which the caller applies
	// as a routing quarantine. Default false so the evaluator keeps its
	// existing observe posture until an operator opts in.
	QuarantineMissingBenchmark bool
}

// BenchmarkVerdict is the evaluator's per-heartbeat opinion on whether the
// provider has a verified-benchmark baseline. It is deliberately tri-state: an
// evidence-store failure MUST NOT read as "no benchmark", or a database blip
// would quarantine the whole fleet.
type BenchmarkVerdict int

const (
	// BenchmarkVerdictUnknown — evaluator disabled, quarantine gate off, or the
	// evidence lookup errored. The caller leaves the quarantine flag as-is.
	BenchmarkVerdictUnknown BenchmarkVerdict = iota
	// BenchmarkVerdictVerified — a verified benchmark resolved for the
	// provider's live model. The caller clears any quarantine.
	BenchmarkVerdictVerified
	// BenchmarkVerdictMissing — the provider has no verified benchmark. The
	// caller quarantines it until one exists.
	BenchmarkVerdictMissing
)

type Alert struct {
	Signal               string
	ProviderID           string
	AssignedID           string
	ModelID              string
	LiveTPS              float64
	BaselineTPS          float64
	TPSThreshold         float64
	HashStatus           pool.HashStatus
	LiveModelHash        string
	ExpectedArtifactHash string
	OPoIPassRate         float64
	OPoIPassRateWindow   int
	OPoIPassCount        int
	SwapDetected         bool
}

type Evaluator struct {
	cfg         TelemetryDriftConfig
	catalog     *autotune.Catalog
	evidence    autotune.EvidenceStore
	evidenceTTL time.Duration
	opoi        *rollingPassRate
	lastAlert   map[string]time.Time
	mu          sync.Mutex
	now         func() time.Time
}

func NewEvaluator(cfg TelemetryDriftConfig, catalog *autotune.Catalog, evidence autotune.EvidenceStore, evidenceTTL time.Duration) *Evaluator {
	if cfg.OPoIPassRateWindow <= 0 {
		cfg.OPoIPassRateWindow = 10
	}
	if cfg.OPoIPassRateThreshold <= 0 {
		cfg.OPoIPassRateThreshold = 0.80
	}
	if cfg.TPSRatioThreshold <= 0 {
		cfg.TPSRatioThreshold = 0.70
	}
	if cfg.TPSMinRequestsWindow <= 0 {
		cfg.TPSMinRequestsWindow = defaultTPSMinRequestsWindow
	}
	if cfg.AlertCooldown <= 0 {
		cfg.AlertCooldown = 15 * time.Minute
	}
	return &Evaluator{
		cfg:         cfg,
		catalog:     catalog,
		evidence:    evidence,
		evidenceTTL: evidenceTTL,
		opoi:        newRollingPassRate(cfg.OPoIPassRateWindow),
		lastAlert:   make(map[string]time.Time),
		now:         time.Now,
	}
}

func ResolveVerifiedBenchmark(catalog *autotune.Catalog, evidence autotune.VerifiedEvidence, modelID string) (autotune.VerifiedBenchmark, bool) {
	if catalog == nil {
		return autotune.VerifiedBenchmark{}, false
	}
	key, _, ok := catalog.HighestClaimedTier(modelID)
	if !ok {
		return autotune.VerifiedBenchmark{}, false
	}
	for _, benchmark := range evidence.Benchmarks {
		if strings.EqualFold(strings.TrimSpace(benchmark.ModelKey), key) {
			return benchmark, true
		}
	}
	normalized := strings.ToLower(strings.TrimSpace(modelID))
	for _, benchmark := range evidence.Benchmarks {
		if strings.EqualFold(strings.TrimSpace(benchmark.ModelID), normalized) {
			return benchmark, true
		}
	}
	return autotune.VerifiedBenchmark{}, false
}

// EvaluateHeartbeat preserves the pre-#765 alert-only contract for callers that
// do not act on the benchmark verdict.
func (e *Evaluator) EvaluateHeartbeat(ctx context.Context, provider pool.Provider) []Alert {
	alerts, _ := e.EvaluateHeartbeatWithVerdict(ctx, provider)
	return alerts
}

// EvaluateHeartbeatWithVerdict returns the drift alerts plus the issue-#765
// verified-benchmark verdict.
//
// The verdict is computed from the SAME evidence lookup the alerts use, so the
// quarantine costs no extra evidence-store round trip. Note the two distinct
// "no benchmark" paths, both of which used to exit silently: the provider may
// have no verified evidence AT ALL (LatestVerified !ok), or evidence that
// carries no benchmark for the model it is currently serving
// (ResolveVerifiedBenchmark false). Both are suspect; a store ERROR is not.
func (e *Evaluator) EvaluateHeartbeatWithVerdict(ctx context.Context, provider pool.Provider) ([]Alert, BenchmarkVerdict) {
	if e == nil || !e.cfg.Enabled {
		return nil, BenchmarkVerdictUnknown
	}
	evidence, ok, err := e.evidence.LatestVerified(ctx, provider.ProviderID, e.evidenceTTL)
	if err != nil {
		// Infrastructure failure, not a provider claim. Fail neutral: keep the
		// previous verdict rather than quarantining (or releasing) on a blip.
		return nil, BenchmarkVerdictUnknown
	}
	var (
		benchmark    autotune.VerifiedBenchmark
		hasBenchmark bool
	)
	if ok {
		benchmark, hasBenchmark = ResolveVerifiedBenchmark(e.catalog, evidence, provider.ModelID)
	}
	var alerts []Alert
	if !hasBenchmark {
		alerts = append(alerts, Alert{
			Signal:     SignalMissingBenchmark,
			ProviderID: provider.ProviderID,
			AssignedID: provider.AssignedID,
			ModelID:    provider.ModelID,
		})
	}
	if ok {
		// Unchanged pre-#765 behavior: the TPS and hash gates run only when the
		// provider has verified evidence. A provider with no evidence at all
		// reaches only the missing-benchmark signal above, exactly as it
		// previously reached nothing.
		if alert, fired := e.evaluateTPS(provider, benchmark, hasBenchmark); fired {
			alerts = append(alerts, alert)
		}
		if alert, fired := e.evaluateHash(provider, benchmark, hasBenchmark); fired {
			alerts = append(alerts, alert)
		}
	}
	return e.filterCooldown(alerts), e.benchmarkVerdict(hasBenchmark)
}

// benchmarkVerdict keeps the enforcement decision behind the second config
// gate. With the gate off the caller is told nothing changed, so the flag it
// owns is never set and routing is byte-for-byte the pre-#765 behavior.
func (e *Evaluator) benchmarkVerdict(hasBenchmark bool) BenchmarkVerdict {
	if !e.cfg.QuarantineMissingBenchmark {
		return BenchmarkVerdictUnknown
	}
	if hasBenchmark {
		return BenchmarkVerdictVerified
	}
	return BenchmarkVerdictMissing
}

func (e *Evaluator) RecordModelClassCanary(provider pool.Provider, passed bool) []Alert {
	if e == nil || !e.cfg.Enabled || e.opoi == nil {
		return nil
	}
	key := provider.ProviderID + "|" + provider.AssignedID
	rate, count, window := e.opoi.record(key, passed)
	if count < window {
		return nil
	}
	if rate >= e.cfg.OPoIPassRateThreshold {
		return nil
	}
	alert := Alert{
		Signal:             "opoi_pass_rate",
		ProviderID:         provider.ProviderID,
		AssignedID:         provider.AssignedID,
		ModelID:            provider.ModelID,
		OPoIPassRate:       rate,
		OPoIPassRateWindow: window,
		OPoIPassCount:      count,
	}
	return e.filterCooldown([]Alert{alert})
}

func (e *Evaluator) evaluateTPS(provider pool.Provider, benchmark autotune.VerifiedBenchmark, hasBenchmark bool) (Alert, bool) {
	if !hasBenchmark {
		return Alert{}, false
	}
	baseline := benchmark.SustainedTPS
	if baseline <= 0 || math.IsNaN(baseline) || math.IsInf(baseline, 0) {
		return Alert{}, false
	}
	if provider.RequestsServedSinceLast < e.cfg.TPSMinRequestsWindow {
		return Alert{}, false
	}
	live := provider.ThroughputTPSSinceLast
	if live <= 0 || math.IsNaN(live) || math.IsInf(live, 0) {
		return Alert{}, false
	}
	threshold := math.Max(e.cfg.TPSMinAbsolute, baseline*e.cfg.TPSRatioThreshold)
	if live >= threshold {
		return Alert{}, false
	}
	return Alert{
		Signal:       "tps",
		ProviderID:   provider.ProviderID,
		AssignedID:   provider.AssignedID,
		ModelID:      provider.ModelID,
		LiveTPS:      live,
		BaselineTPS:  baseline,
		TPSThreshold: threshold,
		SwapDetected: benchmark.SwapDetected,
	}, true
}

func (e *Evaluator) evaluateHash(provider pool.Provider, benchmark autotune.VerifiedBenchmark, hasBenchmark bool) (Alert, bool) {
	for _, status := range e.cfg.HashAlertOnStatus {
		if provider.HashStatus == status {
			return Alert{
				Signal:        "hash_status",
				ProviderID:    provider.ProviderID,
				AssignedID:    provider.AssignedID,
				ModelID:       provider.ModelID,
				HashStatus:    provider.HashStatus,
				LiveModelHash: strings.TrimSpace(provider.ModelHash),
			}, true
		}
	}
	if !e.cfg.HashAlertOnArtifactDrift || !hasBenchmark {
		return Alert{}, false
	}
	if provider.HashStatus == pool.HashStatusVerified {
		return Alert{}, false
	}
	expected := strings.ToLower(strings.TrimSpace(benchmark.ArtifactSHA256))
	live := strings.ToLower(strings.TrimSpace(provider.ModelHash))
	if expected == "" || live == "" || expected == live {
		return Alert{}, false
	}
	return Alert{
		Signal:               "hash_artifact",
		ProviderID:           provider.ProviderID,
		AssignedID:           provider.AssignedID,
		ModelID:              provider.ModelID,
		HashStatus:           provider.HashStatus,
		LiveModelHash:        live,
		ExpectedArtifactHash: expected,
		SwapDetected:         benchmark.SwapDetected,
	}, true
}

func (e *Evaluator) filterCooldown(alerts []Alert) []Alert {
	if len(alerts) == 0 {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	out := make([]Alert, 0, len(alerts))
	for _, alert := range alerts {
		key := alert.ProviderID + "|" + alert.Signal
		if last, ok := e.lastAlert[key]; ok && now.Sub(last) < e.cfg.AlertCooldown {
			continue
		}
		e.lastAlert[key] = now
		out = append(out, alert)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

type rollingPassRate struct {
	window int
	mu     sync.Mutex
	byKey  map[string][]bool
}

func newRollingPassRate(window int) *rollingPassRate {
	if window <= 0 {
		window = 10
	}
	return &rollingPassRate{
		window: window,
		byKey:  make(map[string][]bool),
	}
}

func (r *rollingPassRate) record(key string, passed bool) (rate float64, count int, window int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	history := append(r.byKey[key], passed)
	if len(history) > r.window {
		history = history[len(history)-r.window:]
	}
	r.byKey[key] = history
	passes := 0
	for _, ok := range history {
		if ok {
			passes++
		}
	}
	if len(history) == 0 {
		return 0, 0, r.window
	}
	return float64(passes) / float64(len(history)), len(history), r.window
}

func ParseHashAlertStatuses(values []string) ([]pool.HashStatus, error) {
	if len(values) == 0 {
		return []pool.HashStatus{pool.HashStatusMismatch, pool.HashStatusInvalid}, nil
	}
	out := make([]pool.HashStatus, 0, len(values))
	for _, raw := range values {
		status := pool.HashStatus(strings.TrimSpace(raw))
		switch status {
		case pool.HashStatusMismatch, pool.HashStatusInvalid, pool.HashStatusUncatalogued, pool.HashStatusCatalogUnavailable, pool.HashStatusVerified:
			out = append(out, status)
		default:
			return nil, fmt.Errorf("unsupported hash_alert_on_status value %q", raw)
		}
	}
	return out, nil
}

func TelemetryDriftConfigFrom(enabled bool, tpsRatio, tpsMinAbsolute float64, tpsMinRequestsWindow int, hashStatuses []string, hashArtifactDrift bool, opoiWindow int, opoiThreshold float64, cooldownSeconds int, quarantineMissingBenchmark bool) (TelemetryDriftConfig, error) {
	statuses, err := ParseHashAlertStatuses(hashStatuses)
	if err != nil {
		return TelemetryDriftConfig{}, err
	}
	cooldown := time.Duration(cooldownSeconds) * time.Second
	return TelemetryDriftConfig{
		QuarantineMissingBenchmark: quarantineMissingBenchmark,
		Enabled:                    enabled,
		TPSRatioThreshold:          tpsRatio,
		TPSMinAbsolute:             tpsMinAbsolute,
		TPSMinRequestsWindow:       tpsMinRequestsWindow,
		HashAlertOnStatus:          statuses,
		HashAlertOnArtifactDrift:   hashArtifactDrift,
		OPoIPassRateWindow:         opoiWindow,
		OPoIPassRateThreshold:      opoiThreshold,
		AlertCooldown:              cooldown,
	}, nil
}
