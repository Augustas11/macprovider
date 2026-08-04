package autotune

import (
	"fmt"
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
	catalogDigestMatches := strings.EqualFold(strings.TrimSpace(evidence.CandidateCatalogSHA256), catalog.SHA256)
	if !catalogDigestMatches {
		return AdmissionCap{}, fmt.Errorf("verified evidence candidate_catalog_sha256 mismatch")
	}
	var cap AdmissionCap
	for _, benchmark := range evidence.Benchmarks {
		row, ok := catalog.Row(benchmark.ModelKey)
		if !ok {
			continue
		}
		rowIdentity, _ := catalog.RowIdentity(benchmark.ModelKey)
		if !benchmarkPassesGate(benchmark, row, catalog.SHA256, rowIdentity) {
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
	return evaluateHelloGate(catalog, evidence, helloModelID, "")
}

// EvaluateHelloGateForHello applies the admission decision to the exact hello
// metadata being admitted. v2 evidence is only useful for this purpose if its
// protocol and binary-version bindings survive the database verification path
// and match the live provider hello. The executable digest remains metadata
// bound here; execution authenticity is intentionally a separate signed
// compatibility-manifest concern.
func EvaluateHelloGateForHello(catalog *Catalog, evidence VerifiedEvidence, helloModelID, helloBinaryVersion string) HelloGateDecision {
	if evidence.ProbeProtocol != "spec-023-harmony-stream.v2" ||
		strings.TrimSpace(evidence.BinaryVersion) == "" ||
		strings.TrimSpace(evidence.ExecutableSHA256) == "" ||
		strings.TrimSpace(helloBinaryVersion) == "" ||
		strings.TrimSpace(evidence.BinaryVersion) != strings.TrimSpace(helloBinaryVersion) {
		return HelloGateDecision{Allowed: false, Reason: "autotune_evidence_binary_version_mismatch"}
	}
	return evaluateHelloGate(catalog, evidence, helloModelID, helloBinaryVersion)
}

func evaluateHelloGate(catalog *Catalog, evidence VerifiedEvidence, helloModelID, _ string) HelloGateDecision {
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

func benchmarkPassesGate(benchmark VerifiedBenchmark, row Row, catalogSHA256, rowIdentity string) bool {
	if benchmark.ThermalThrottleDetected {
		return false
	}
	if benchmark.SwapDetected {
		return false
	}
	if strings.TrimSpace(benchmark.CandidateRowIdentity) == "" ||
		!strings.EqualFold(strings.TrimSpace(benchmark.CandidateRowIdentity), strings.TrimSpace(rowIdentity)) {
		return false
	}
	if strings.TrimSpace(benchmark.ModelID) == "" || !strings.EqualFold(strings.TrimSpace(benchmark.ModelID), strings.TrimSpace(row.ModelID)) {
		return false
	}
	if strings.TrimSpace(benchmark.ArtifactSHA256) == "" || !strings.EqualFold(strings.TrimSpace(benchmark.ArtifactSHA256), strings.TrimSpace(row.ModelSHA256)) {
		return false
	}
	// SPEC-023 v0.2: min_sustained_tps and max_4k_ttft_ms are advisory QoS
	// thresholds. The coordinator mirror must not reject an otherwise valid
	// benchmark row for low TPS, high TTFT, or a missing/non-finite TPS value.
	return true
}
