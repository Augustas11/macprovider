package trustpool

import (
	"context"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
)

const StatusSchemaVersion = "macprovider.trustpool-status.v1"

const StatusFreshnessTTL = 300 * time.Second

type StatusDocument struct {
	SchemaVersion   string                `json:"schema_version"`
	GeneratedAtUTC  string                `json:"generated_at_utc"`
	FreshUntilUTC   string                `json:"fresh_until_utc"`
	Pool            StatusPool            `json:"pool"`
	Creator         StatusCreator         `json:"creator"`
	Policy          StatusPolicy          `json:"policy"`
	Membership      StatusMembership      `json:"membership"`
	Routeability    StatusRouteability    `json:"routeability"`
	Settlement      StatusSettlement      `json:"settlement"`
	Confidentiality StatusConfidentiality `json:"confidentiality"`
	Disclosures     []string              `json:"disclosures"`
}

type StatusPool struct {
	PoolID          string `json:"pool_id"`
	Lifecycle       string `json:"lifecycle"`
	LifecycleReason string `json:"lifecycle_reason,omitempty"`
	Readiness       string `json:"readiness"`
	ReadinessReason string `json:"readiness_reason,omitempty"`
	MVPMode         string `json:"mvp_mode"`
	SupplyMode      string `json:"supply_mode"`
}

type StatusCreator struct {
	CreatorAccountID             string `json:"creator_account_id"`
	PublicDisplayName            string `json:"public_display_name,omitempty"`
	ApprovalRecordID             string `json:"approval_record_id"`
	CurrentApprovalVersion       string `json:"current_approval_version,omitempty"`
	AllowedProductCategory       string `json:"allowed_product_category,omitempty"`
	AllowedLaunchEnvironment     string `json:"allowed_launch_environment,omitempty"`
	CreatorAgreementID           string `json:"creator_agreement_id,omitempty"`
	CreatorAgreementVersion      string `json:"creator_agreement_version,omitempty"`
	CreatorAgreementExpiresAtUTC string `json:"creator_agreement_expires_at_utc,omitempty"`
	CreatorAgreementGraceEndsUTC string `json:"creator_agreement_grace_ends_at_utc,omitempty"`
	Status                       string `json:"status,omitempty"`
}

type StatusPolicy struct {
	ManifestVersion    uint64 `json:"manifest_version"`
	ManifestCoreDigest string `json:"manifest_core_digest,omitempty"`
	MinBinaryVersion   string `json:"min_binary_version,omitempty"`
	RootIssuerKeyID    string `json:"root_issuer_key_id,omitempty"`
	RootIssuerKeyHash  string `json:"root_issuer_public_key_fingerprint,omitempty"`
	CustodyEvidence    string `json:"custody_evidence,omitempty"`
	RetentionPolicyID  string `json:"retention_policy_id,omitempty"`
}

type StatusMembership struct {
	MinEligibleMembers           int    `json:"min_eligible_members"`
	CurrentMemberCount           int    `json:"current_member_count"`
	CurrentAdmittedMemberCount   int    `json:"current_admitted_member_count"`
	CurrentNonRevokedMemberCount int    `json:"current_non_revoked_member_count"`
	CurrentEligibleMemberCount   int    `json:"current_eligible_member_count"`
	RevokedMemberCount           int    `json:"revoked_member_count"`
	AuthorizedBuyerCount         int    `json:"authorized_buyer_count"`
	LiveEligibilityEvaluation    string `json:"live_eligibility_evaluation"`
}

type StatusRouteability struct {
	Routeable               bool   `json:"routeable"`
	Generation              uint64 `json:"generation"`
	RouteableGeneration     uint64 `json:"routeable_generation"`
	RouteGateCheckedAtUTC   string `json:"route_gate_checked_at_utc,omitempty"`
	RouteableUntilUTC       string `json:"routeable_until_utc,omitempty"`
	CreatorGateReason       string `json:"creator_gate_reason,omitempty"`
	CreatorGateExpiresAtUTC string `json:"creator_gate_expires_at_utc,omitempty"`
}

type StatusSettlement struct {
	SplitExecutionStatus string `json:"split_execution_status"`
}

type StatusConfidentiality struct {
	Scope string `json:"scope"`
}

func BuildStatusDocument(ctx context.Context, store *Store, registry *Registry, poolID, accountID string, generatedAt time.Time) (StatusDocument, bool, error) {
	poolID = strings.TrimSpace(poolID)
	accountID = strings.TrimSpace(accountID)
	if store == nil || registry == nil || poolID == "" || accountID == "" {
		return StatusDocument{}, false, nil
	}
	if !registry.BuyerAuthorized(poolID, accountID) {
		return StatusDocument{}, false, nil
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		return StatusDocument{}, false, err
	}
	p := state.Pools[poolID]
	if p == nil || !p.BuyerAccounts[accountID] {
		return StatusDocument{}, false, nil
	}
	approval := state.CreatorApprovals[p.CreatorAccountID]
	generatedAt = generatedAt.UTC()
	if generatedAt.IsZero() {
		generatedAt = time.Now().UTC()
	}
	nonRevoked := nonRevokedMemberCount(p)
	readiness := "unknown"
	readinessReason := readinessReasonForPool(p)
	_, routeabilityReason := poolRouteability(p)
	if routeabilityReason != "" {
		readiness = "unavailable"
	}
	statusRouteable := false
	doc := StatusDocument{
		SchemaVersion:  StatusSchemaVersion,
		GeneratedAtUTC: generatedAt.Format(time.RFC3339Nano),
		FreshUntilUTC:  generatedAt.Add(StatusFreshnessTTL).Format(time.RFC3339Nano),
		Pool: StatusPool{
			PoolID:          p.PoolID,
			Lifecycle:       p.Lifecycle,
			LifecycleReason: p.LifecycleReason,
			Readiness:       readiness,
			ReadinessReason: readinessReason,
			MVPMode:         "single_operator",
			SupplyMode:      "creator_admitted",
		},
		Creator: StatusCreator{
			CreatorAccountID:             p.CreatorAccountID,
			PublicDisplayName:            approval.PublicDisplayName,
			ApprovalRecordID:             p.ApprovalRecordID,
			CurrentApprovalVersion:       approval.CurrentApprovalVersion,
			AllowedProductCategory:       approval.AllowedProductCategory,
			AllowedLaunchEnvironment:     approval.AllowedLaunchEnvironment,
			CreatorAgreementID:           approval.CreatorAgreementID,
			CreatorAgreementVersion:      approval.CreatorAgreementVersion,
			CreatorAgreementExpiresAtUTC: formatOptionalTime(approval.CreatorAgreementExpiresAtUTC),
			CreatorAgreementGraceEndsUTC: formatOptionalTime(approval.CreatorAgreementGraceEndsAtUTC),
			Status:                       approval.Status,
		},
		Policy: StatusPolicy{
			ManifestVersion:    p.ManifestVersion,
			ManifestCoreDigest: p.ManifestCoreDigest,
			MinBinaryVersion:   policyMinBinaryVersion(p),
			RootIssuerKeyID:    statusRootIssuerKeyID(p),
			RootIssuerKeyHash:  statusRootIssuerFingerprint(p),
			CustodyEvidence:    statusCustodyEvidence(p),
			RetentionPolicyID:  policyRetentionPolicyID(p, approval),
		},
		Membership: StatusMembership{
			MinEligibleMembers:           policyMinEligibleMembers(p),
			CurrentMemberCount:           len(p.Members),
			CurrentAdmittedMemberCount:   len(p.Members),
			CurrentNonRevokedMemberCount: nonRevoked,
			CurrentEligibleMemberCount:   0,
			RevokedMemberCount:           len(p.Revoked),
			AuthorizedBuyerCount:         len(p.BuyerAccounts),
			LiveEligibilityEvaluation:    "not_evaluated",
		},
		Routeability: StatusRouteability{
			Routeable:               statusRouteable,
			Generation:              p.Generation,
			RouteableGeneration:     p.RouteableSnapshotGeneration(),
			RouteGateCheckedAtUTC:   formatOptionalTime(state.RouteGateCheckedAt),
			RouteableUntilUTC:       formatOptionalTime(p.CreatorGateExpiresAtUTC),
			CreatorGateReason:       routeabilityReason,
			CreatorGateExpiresAtUTC: formatOptionalTime(p.CreatorGateExpiresAtUTC),
		},
		Settlement: StatusSettlement{
			SplitExecutionStatus: policySplitExecutionStatus(p),
		},
		Confidentiality: StatusConfidentiality{
			Scope: "trusted_pool_not_privacy_pool",
		},
		Disclosures: []string{
			"prompts and responses are visible to the MacProvider coordinator",
			"prompts and responses may be visible to the selected provider operator",
			"single-operator Trusted Pools do not provide a high-availability guarantee",
			"live eligible member count and route-time readiness are not evaluated by this buyer-authenticated status surface",
			"this status document is not a Privacy Pool, anonymous-routing, zero-knowledge, or regulated-compliance claim",
		},
	}
	return doc, true, nil
}

func readinessReasonForPool(p *ReconstructedPoolState) string {
	if _, reason := poolRouteability(p); reason != "" {
		return reason
	}
	return "live_eligibility_not_evaluated"
}

func poolRouteability(p *ReconstructedPoolState) (bool, string) {
	if p == nil {
		return false, "pool_not_found"
	}
	if p.CreatorGateReason != "" {
		return false, p.CreatorGateReason
	}
	if p.Lifecycle != LifecycleActive {
		return false, "lifecycle_" + p.Lifecycle
	}
	if nonRevokedMemberCount(p) < policyMinEligibleMembers(p) {
		return false, "min_eligible_members_unmet"
	}
	return true, ""
}

func nonRevokedMemberCount(p *ReconstructedPoolState) int {
	if p == nil {
		return 0
	}
	var n int
	for id := range p.Members {
		if !p.Revoked[id] {
			n++
		}
	}
	return n
}

func statusRootIssuerKeyID(p *ReconstructedPoolState) string {
	if p == nil || p.RootIssuer == nil {
		return ""
	}
	return p.RootIssuer.KeyID
}

func statusRootIssuerFingerprint(p *ReconstructedPoolState) string {
	if p == nil || p.RootIssuer == nil {
		return ""
	}
	return p.RootIssuer.PublicKeyFingerprint
}

func statusCustodyEvidence(p *ReconstructedPoolState) string {
	if p == nil || p.RootIssuer == nil {
		return ""
	}
	return p.RootIssuer.StructuredCustodyDisclosureHash
}

func policyMinEligibleMembers(p *ReconstructedPoolState) int {
	if p != nil && p.ManifestMinEligibleMembers > 0 {
		if p.ManifestMinEligibleMembers > uint64(maxInt()) {
			return maxInt()
		}
		return int(p.ManifestMinEligibleMembers)
	}
	return 1
}

func maxInt() int {
	return int(^uint(0) >> 1)
}

func policyMinBinaryVersion(p *ReconstructedPoolState) string {
	if p == nil {
		return ""
	}
	if p.MinBinaryVersion == "" {
		return p.ManifestMinBinaryVersion
	}
	if p.ManifestMinBinaryVersion == "" {
		return p.MinBinaryVersion
	}
	cmp, ok := versionfloor.Compare(p.ManifestMinBinaryVersion, p.MinBinaryVersion)
	if ok && cmp > 0 {
		return p.ManifestMinBinaryVersion
	}
	return p.MinBinaryVersion
}

func policyRetentionPolicyID(p *ReconstructedPoolState, approval CreatorApproval) string {
	if p != nil && p.ManifestRetentionPolicyID != "" {
		return p.ManifestRetentionPolicyID
	}
	return approval.DataRetentionCategory
}

func policySplitExecutionStatus(p *ReconstructedPoolState) string {
	if p != nil && p.ManifestSplitExecutionStatus != "" {
		return p.ManifestSplitExecutionStatus
	}
	return "declared_not_executed"
}

func formatOptionalTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}
