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

type TelemetryDriftConfig struct {
	Enabled                  bool
	TPSRatioThreshold        float64
	TPSMinAbsolute           float64
	HashAlertOnStatus        []pool.HashStatus
	HashAlertOnArtifactDrift bool
	OPoIPassRateWindow       int
	OPoIPassRateThreshold    float64
	AlertCooldown            time.Duration
}

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

func (e *Evaluator) EvaluateHeartbeat(ctx context.Context, provider pool.Provider) []Alert {
	if e == nil || !e.cfg.Enabled {
		return nil
	}
	evidence, ok, err := e.evidence.LatestVerified(ctx, provider.ProviderID, e.evidenceTTL)
	if err != nil || !ok {
		return nil
	}
	benchmark, hasBenchmark := ResolveVerifiedBenchmark(e.catalog, evidence, provider.ModelID)
	var alerts []Alert
	if alert, ok := e.evaluateTPS(provider, benchmark, hasBenchmark); ok {
		alerts = append(alerts, alert)
	}
	if alert, ok := e.evaluateHash(provider, benchmark, hasBenchmark); ok {
		alerts = append(alerts, alert)
	}
	return e.filterCooldown(alerts)
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
	live := provider.ThroughputTPSEstimate
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
				Signal:     "hash_status",
				ProviderID: provider.ProviderID,
				AssignedID: provider.AssignedID,
				ModelID:    provider.ModelID,
				HashStatus: provider.HashStatus,
				LiveModelHash: strings.TrimSpace(provider.ModelHash),
			}, true
		}
	}
	if !e.cfg.HashAlertOnArtifactDrift || !hasBenchmark {
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

func TelemetryDriftConfigFrom(enabled bool, tpsRatio, tpsMinAbsolute float64, hashStatuses []string, hashArtifactDrift bool, opoiWindow int, opoiThreshold float64, cooldownSeconds int) (TelemetryDriftConfig, error) {
	statuses, err := ParseHashAlertStatuses(hashStatuses)
	if err != nil {
		return TelemetryDriftConfig{}, err
	}
	cooldown := time.Duration(cooldownSeconds) * time.Second
	return TelemetryDriftConfig{
		Enabled:                  enabled,
		TPSRatioThreshold:        tpsRatio,
		TPSMinAbsolute:           tpsMinAbsolute,
		HashAlertOnStatus:        statuses,
		HashAlertOnArtifactDrift: hashArtifactDrift,
		OPoIPassRateWindow:       opoiWindow,
		OPoIPassRateThreshold:    opoiThreshold,
		AlertCooldown:            cooldown,
	}, nil
}
