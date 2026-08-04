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
	// These immutable v2 bindings are retained after database verification so
	// admission can compare the evidence to the exact provider hello that is
	// being admitted. ExecutableSHA256 is an evidence binding, not execution
	// authenticity; that requires a separately trusted signed manifest.
	ProbeProtocol    string
	BinaryVersion    string
	ExecutableSHA256 string
	// Admitted hardware-trust tuple (issue #582 FIX B). HardwareIdentityHash
	// comes from the verified evidence payload; ChipNormalized/UnifiedMemoryGB
	// come from the matched verified job row. Together they identify the EXACT
	// trust root that authorized admission, so the revalidation sweep can bind
	// its re-check to that tuple rather than to the provider_id alone.
	HardwareIdentityHash string
	ChipNormalized       string
	UnifiedMemoryGB      int
	Benchmarks           []VerifiedBenchmark
}

type EvidenceStore interface {
	LatestVerified(ctx context.Context, providerID string, ttl time.Duration) (VerifiedEvidence, bool, error)
}

type AdmissionCap struct {
	ModelKey string
	ModelID  string
	MinRAMGB int
}
