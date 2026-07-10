package autotune

import (
	"context"
	"time"
)

type VerifiedBenchmark struct {
	ModelKey                string
	ModelID                 string
	SustainedTPS            float64
	TTFTMS                  int
	SwapDetected            bool
	ThermalThrottleDetected bool
	ArtifactSHA256          string
	CandidateCatalogSHA256  string
	CandidateRowIdentity    string
}

type VerifiedEvidence struct {
	GeneratedAt            time.Time
	CandidateCatalogSHA256 string
	Benchmarks             []VerifiedBenchmark
}

type EvidenceStore interface {
	LatestVerified(ctx context.Context, providerID string, ttl time.Duration) (VerifiedEvidence, bool, error)
}

type AdmissionCap struct {
	ModelKey string
	ModelID  string
	MinRAMGB int
}
