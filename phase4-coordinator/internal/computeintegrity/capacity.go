package computeintegrity

// FR-17 cost, capacity, and funding. All SPEC-036 probe/reference/consensus work is
// non-billable and MUST NOT create buyer debit, provider credit, earnings, payout
// readiness, or uncapped reward accrual, and MUST NOT appear in SPEC-015 usage. Any
// operator compensation uses an explicitly capped operator/network-funded instrument
// with per-provider daily caps and anti-Sybil eligibility.

// WorkloadClass enumerates the three non-billable SPEC-036 workload classes (FR-17).
type WorkloadClass string

const (
	WorkloadProviderProbe        WorkloadClass = "provider_probe_response"
	WorkloadReferenceForwardPass WorkloadClass = "coordinator_reference_forward_pass"
	WorkloadConsensusTelemetry   WorkloadClass = "consensus_telemetry"
)

// IsBillable reports whether a SPEC-036 workload creates any buyer/provider money
// movement (FR-17). It never does: all three classes are non-billable.
func IsBillable(WorkloadClass) bool { return false }

// AppearsInSpec015Usage reports whether a SPEC-036 workload appears in SPEC-015 v0.4
// usage (FR-17). It never does.
func AppearsInSpec015Usage(WorkloadClass) bool { return false }

// CappedInstrument is the operator/network-funded compensation instrument (FR-5,
// FR-17): explicitly capped, with per-provider daily caps and anti-Sybil eligibility.
type CappedInstrument struct {
	PerProviderDailyCap  float64
	AntiSybilEligible    bool
	BuyerFunded          bool // MUST be false
	UncappedRewardFunded bool // MUST be false
}

// ValidCompensationInstrument reports whether a compensation instrument satisfies the
// FR-17 funding rules: capped, anti-Sybil, and never buyer- or uncapped-reward-funded.
func ValidCompensationInstrument(in CappedInstrument) bool {
	return in.PerProviderDailyCap > 0 && in.AntiSybilEligible && !in.BuyerFunded && !in.UncappedRewardFunded
}

// DailyCanaries applies the FR-17 daily-canary capacity formula.
func DailyCanaries(stableProviderIdentities, coveredKeys, canariesPerKeyPerDay int) int {
	return stableProviderIdentities * coveredKeys * canariesPerKeyPerDay
}

// DailyReferenceForwardPassUnits applies the FR-17 reference-forward-pass formula.
func DailyReferenceForwardPassUnits(dailyCanaries, activeReferenceReplicas, promptsPerCanary,
	positionsPerPrompt, promptTokenEquivalentPerPosition int) int {
	return dailyCanaries * activeReferenceReplicas * promptsPerCanary *
		positionsPerPrompt * promptTokenEquivalentPerPosition
}

// ReferenceRefreshThroughputSufficient reports the FR-17 enforce-activation throughput
// gate: completed reference events per hour must be >= covered_key_cardinality *
// active_reference_replicas / freshness_ttl (in hours), i.e. enough to keep at least
// active_reference_replicas (>=2) fresh reference events per covered key within the TTL.
func ReferenceRefreshThroughputSufficient(coveredKeyCardinality, activeReferenceReplicas,
	freshnessTTLHours int, completedRefEventsPerHour float64) bool {
	if freshnessTTLHours <= 0 || activeReferenceReplicas < 2 {
		return false
	}
	required := float64(coveredKeyCardinality*activeReferenceReplicas) / float64(freshnessTTLHours)
	return completedRefEventsPerHour >= required
}

// SLOTargets are the operator-approved detection SLOs (FR-17).
type SLOTargets struct {
	TimeToOnboardMinutes    int
	TimeToQuarantineMinutes int
	TimeToClearMinutes      int
}

// MeetsSLO reports whether the provisioned capacity's measured latencies meet the
// operator-approved SLO targets (FR-17). All three measured latencies must be at or
// below their targets.
func MeetsSLO(measured, target SLOTargets) bool {
	return measured.TimeToOnboardMinutes <= target.TimeToOnboardMinutes &&
		measured.TimeToQuarantineMinutes <= target.TimeToQuarantineMinutes &&
		measured.TimeToClearMinutes <= target.TimeToClearMinutes
}
