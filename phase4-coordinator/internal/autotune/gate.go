package autotune

import (
	"fmt"
	"math"
	"strings"
)

type HelloGateDecision struct {
	Allowed             bool
	Reason              string
	MaxAdmittedModelKey string
	MaxAdmittedModelID  string
	MaxAdmittedMinRAMGB int
	ClaimedModelKey     string
	ClaimedMinRAMGB     int
}

func ResolveMaxAdmission(catalog *Catalog, evidence VerifiedEvidence) (AdmissionCap, error) {
	if catalog == nil {
		return AdmissionCap{}, fmt.Errorf("autotune catalog is nil")
	}
	if strings.TrimSpace(evidence.CandidateCatalogSHA256) == "" {
		return AdmissionCap{}, fmt.Errorf("verified evidence missing candidate_catalog_sha256")
	}
	if !strings.EqualFold(strings.TrimSpace(evidence.CandidateCatalogSHA256), catalog.SHA256) {
		return AdmissionCap{}, fmt.Errorf("verified evidence candidate_catalog_sha256 mismatch")
	}
	var cap AdmissionCap
	for _, benchmark := range evidence.Benchmarks {
		row, ok := catalog.Row(benchmark.ModelKey)
		if !ok {
			continue
		}
		if !benchmarkPassesGate(benchmark, row, evidence.CandidateCatalogSHA256) {
			continue
		}
		if row.MinRAMGB >= cap.MinRAMGB {
			cap = AdmissionCap{
				ModelKey: benchmark.ModelKey,
				ModelID:  row.ModelID,
				MinRAMGB: row.MinRAMGB,
			}
		}
	}
	if cap.ModelKey == "" {
		return AdmissionCap{}, fmt.Errorf("verified evidence has no passing benchmark rows")
	}
	return cap, nil
}

func EvaluateHelloGate(catalog *Catalog, evidence VerifiedEvidence, helloModelID string) HelloGateDecision {
	decision := HelloGateDecision{Allowed: true}
	cap, err := ResolveMaxAdmission(catalog, evidence)
	if err != nil {
		decision.Allowed = false
		decision.Reason = "autotune_evidence_invalid"
		return decision
	}
	decision.MaxAdmittedModelKey = cap.ModelKey
	decision.MaxAdmittedModelID = cap.ModelID
	decision.MaxAdmittedMinRAMGB = cap.MinRAMGB

	claimedKey, claimedRow, ok := catalog.HighestClaimedTier(helloModelID)
	if !ok {
		decision.Allowed = false
		decision.Reason = "autotune_model_uncatalogued"
		return decision
	}
	decision.ClaimedModelKey = claimedKey
	decision.ClaimedMinRAMGB = claimedRow.MinRAMGB
	if claimedRow.MinRAMGB > cap.MinRAMGB {
		decision.Allowed = false
		decision.Reason = "autotune_model_cap_exceeded"
	}
	return decision
}

func benchmarkPassesGate(benchmark VerifiedBenchmark, row Row, catalogSHA256 string) bool {
	if benchmark.ThermalThrottleDetected {
		return false
	}
	if !strings.EqualFold(strings.TrimSpace(benchmark.CandidateCatalogSHA256), strings.TrimSpace(catalogSHA256)) {
		return false
	}
	if strings.TrimSpace(benchmark.ModelID) == "" || !strings.EqualFold(strings.TrimSpace(benchmark.ModelID), strings.TrimSpace(row.ModelID)) {
		return false
	}
	if strings.TrimSpace(benchmark.ArtifactSHA256) == "" || !strings.EqualFold(strings.TrimSpace(benchmark.ArtifactSHA256), strings.TrimSpace(row.ModelSHA256)) {
		return false
	}
	if math.IsNaN(benchmark.SustainedTPS) || math.IsInf(benchmark.SustainedTPS, 0) || benchmark.SustainedTPS < row.BenchGate.MinSustainedTPS {
		return false
	}
	if benchmark.TTFTMS > row.BenchGate.Max4KTTFTMS {
		return false
	}
	return true
}
