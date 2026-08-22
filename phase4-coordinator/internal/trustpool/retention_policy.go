package trustpool

import "strings"

type RetentionPolicyRecord struct {
	ID                            string
	FieldCategories               []string
	MinRetentionPeriod            string
	MaxRetentionPeriod            string
	DeletionSLA                   string
	GoverningPolicyVersion        string
	DisputeAuditTrailMinRetention string
}

var registeredRetentionPolicies = map[string]RetentionPolicyRecord{
	"minimal": {
		ID:                            "minimal",
		FieldCategories:               []string{"pool_audit_log", "route_snapshot", "settlement_record"},
		MinRetentionPeriod:            "30d",
		MaxRetentionPeriod:            "90d",
		DeletionSLA:                   "30d_after_retention_window",
		GoverningPolicyVersion:        "retention-policy-v1",
		DisputeAuditTrailMinRetention: "30d",
	},
	"standard": {
		ID:                            "standard",
		FieldCategories:               []string{"request_log", "route_snapshot", "settlement_record", "provider_receipt", "pool_audit_log"},
		MinRetentionPeriod:            "180d",
		MaxRetentionPeriod:            "365d",
		DeletionSLA:                   "30d_after_retention_window",
		GoverningPolicyVersion:        "retention-policy-v1",
		DisputeAuditTrailMinRetention: "180d",
	},
	"extended-dispute": {
		ID:                            "extended-dispute",
		FieldCategories:               []string{"request_log", "route_snapshot", "settlement_record", "provider_receipt", "pool_audit_log", "public_announcement_history"},
		MinRetentionPeriod:            "365d",
		MaxRetentionPeriod:            "730d",
		DeletionSLA:                   "45d_after_retention_window",
		GoverningPolicyVersion:        "retention-policy-v1",
		DisputeAuditTrailMinRetention: "365d",
	},
}

func resolveRetentionPolicyByID(id string) (RetentionPolicyRecord, bool) {
	if id == "" || id != strings.TrimSpace(id) {
		return RetentionPolicyRecord{}, false
	}
	record, ok := registeredRetentionPolicies[id]
	if !ok {
		return RetentionPolicyRecord{}, false
	}
	record.FieldCategories = append([]string(nil), record.FieldCategories...)
	return record, true
}

func retentionPolicyIDForPool(p *ReconstructedPoolState, approval CreatorApproval) string {
	if p != nil && p.ManifestVersion > 0 {
		return p.ManifestRetentionPolicyID
	}
	return strings.TrimSpace(approval.DataRetentionCategory)
}

func resolveRetentionPolicyForPool(p *ReconstructedPoolState, approval CreatorApproval) (RetentionPolicyRecord, bool) {
	return resolveRetentionPolicyByID(retentionPolicyIDForPool(p, approval))
}

func poolManifestRetentionPolicyResolved(p *ReconstructedPoolState) bool {
	if p == nil {
		return false
	}
	_, ok := resolveRetentionPolicyByID(p.ManifestRetentionPolicyID)
	return ok
}
