package rewards

import "time"

// Criterion IDs per SPEC-026 §5.2.
const (
	CriterionE1Receipts       = "E1"
	CriterionE2WalletEconomic = "E2"
	CriterionE3Operator       = "E3"
	CriterionUptime72h        = "A1"
	CriterionWalletBalance72h = "A3"
	CriterionAppAttest        = "A4"
)

const (
	trustRequalifyWindow = 72 * time.Hour
	uptimeGapThreshold   = 5 * time.Minute
	uptimeRequiredWindow = 72 * time.Hour
	minVerifiedReceipts  = 100
	minUSDCMicro         = int64(100_000_000) // 100 USDC with 6 decimals
)

// ProviderConnectivity exposes live heartbeat state for uptime evaluation.
type ProviderConnectivity interface {
	HeartbeatOK(providerID string, now time.Time) bool
}

// TrustCriteriaStatus is the provider-facing unlock snapshot.
type TrustCriteriaStatus struct {
	TrustTier              string
	DemotionCooldownUntil  *time.Time
	EconomicSatisfied      []string
	AdditionalSatisfied    []string
	CriteriaMet            int
	CriteriaRequired       int
	UnlockPairOKSince      *time.Time
	VerifiedReceiptCount   int
	WalletBound            bool
	AppAttested            bool
	OperatorPromoted       bool
	UptimeOK               bool
	WalletBalanceOK        bool
}
