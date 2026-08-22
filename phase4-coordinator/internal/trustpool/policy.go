package trustpool

import (
	"context"
	"regexp"
	"strings"
	"time"
)

const PolicySchemaVersion = "macprovider.trustpool-policy.v1"

type PolicyDocument struct {
	SchemaVersion   string                `json:"schema_version"`
	GeneratedAtUTC  string                `json:"generated_at_utc"`
	FreshUntilUTC   string                `json:"fresh_until_utc"`
	Pool            PolicyPool            `json:"pool"`
	Creator         PolicyCreator         `json:"creator"`
	Policy          PolicyPolicy          `json:"policy"`
	RootIssuer      PolicyRootIssuer      `json:"root_issuer"`
	Predicates      PolicyPredicates      `json:"predicates"`
	Confidentiality PolicyConfidentiality `json:"confidentiality"`
	ClaimControl    PolicyClaimControl    `json:"claim_control"`
	Disclosures     []string              `json:"disclosures"`
}

type PolicyPool struct {
	PoolID                 string `json:"pool_id"`
	Lifecycle              string `json:"lifecycle"`
	Visibility             string `json:"visibility"`
	PubliclyAnnounced      bool   `json:"publicly_announced"`
	VisibilityGeneration   uint64 `json:"visibility_generation"`
	PublicApprovalID       string `json:"public_announcement_approval_id,omitempty"`
	ReviewedArtifactDigest string `json:"reviewed_distribution_artifact_digest,omitempty"`
	MVPMode                string `json:"mvp_mode"`
	SupplyMode             string `json:"supply_mode"`
	ProviderSupply         string `json:"provider_supply"`
	CandidateOnly          bool   `json:"candidate_only"`
	ProductionReady        bool   `json:"production_ready"`
	ProductionBlocker      string `json:"production_blocker"`
	LaunchEnvironment      string `json:"launch_environment,omitempty"`
	LifecycleReason        string `json:"lifecycle_reason,omitempty"`
	CreatorGateReason      string `json:"creator_gate_reason,omitempty"`
	CreatorGateExpiresAt   string `json:"creator_gate_expires_at_utc,omitempty"`
}

type PolicyCreator struct {
	CreatorAccountID             string `json:"creator_account_id,omitempty"`
	PublicDisplayName            string `json:"public_display_name,omitempty"`
	ApprovalRecordID             string `json:"approval_record_id,omitempty"`
	CurrentApprovalVersion       string `json:"current_approval_version,omitempty"`
	AllowedProductCategory       string `json:"allowed_product_category,omitempty"`
	AllowedLaunchEnvironment     string `json:"allowed_launch_environment,omitempty"`
	CreatorAgreementID           string `json:"creator_agreement_id,omitempty"`
	CreatorAgreementVersion      string `json:"creator_agreement_version,omitempty"`
	CreatorAgreementExpiresAtUTC string `json:"creator_agreement_expires_at_utc,omitempty"`
	CreatorAgreementGraceEndsUTC string `json:"creator_agreement_grace_ends_at_utc,omitempty"`
	Status                       string `json:"status,omitempty"`
}

type PolicyPolicy struct {
	ManifestVersion                  uint64   `json:"manifest_version"`
	PolicyHash                       string   `json:"policy_hash,omitempty"`
	ManifestCoreDigest               string   `json:"manifest_core_digest,omitempty"`
	MinEligibleMembers               int      `json:"min_eligible_members"`
	MinBinaryVersion                 string   `json:"min_binary_version,omitempty"`
	RetentionPolicyID                string   `json:"retention_policy_id,omitempty"`
	RetentionPolicyStatus            string   `json:"retention_policy_status"`
	RetentionPolicyGoverningVersion  string   `json:"retention_policy_governing_version,omitempty"`
	RetentionPolicyFieldCategories   []string `json:"retention_policy_field_categories,omitempty"`
	RetentionPolicyMinPeriod         string   `json:"retention_policy_min_period,omitempty"`
	RetentionPolicyMaxPeriod         string   `json:"retention_policy_max_period,omitempty"`
	RetentionPolicyDeletionSLA       string   `json:"retention_policy_deletion_sla,omitempty"`
	RetentionPolicyDisputeAuditTrail string   `json:"retention_policy_dispute_audit_trail_min_period,omitempty"`
	SplitExecutionStatus             string   `json:"split_execution_status"`
}

type PolicyRootIssuer struct {
	KeyID                 string `json:"key_id,omitempty"`
	PublicKeyFingerprint  string `json:"public_key_fingerprint,omitempty"`
	CustodyClass          string `json:"custody_class"`
	CustodyEvidence       string `json:"custody_evidence"`
	CustodyDisclosureHash string `json:"custody_disclosure_hash,omitempty"`
	LaunchEnvironment     string `json:"launch_environment,omitempty"`
}

type PolicyPredicate struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Scope  string `json:"scope"`
}

type PolicyPredicates struct {
	Enforced    []PolicyPredicate `json:"enforced"`
	ObserveOnly []PolicyPredicate `json:"observe_only"`
}

type PolicyConfidentiality struct {
	Scope                              string `json:"scope"`
	CoordinatorPlaintextVisibility     string `json:"coordinator_plaintext_visibility"`
	SelectedProviderOperatorVisibility string `json:"selected_provider_operator_visibility"`
	EncryptedLegClaim                  string `json:"encrypted_leg_claim"`
}

type PolicyClaimControl struct {
	CanonicalName     string   `json:"canonical_name"`
	ValidationStatus  string   `json:"validation_status"`
	ProhibitedClaims  []string `json:"prohibited_claims"`
	AllowedClaimScope string   `json:"allowed_claim_scope"`
}

func BuildPolicyDocument(ctx context.Context, store *Store, registry *Registry, poolID, accountID string, generatedAt time.Time) (PolicyDocument, bool, error) {
	poolID = strings.TrimSpace(poolID)
	accountID = strings.TrimSpace(accountID)
	if store == nil || registry == nil || poolID == "" || accountID == "" {
		return PolicyDocument{}, false, nil
	}
	if !registry.BuyerAuthorized(poolID, accountID) {
		return PolicyDocument{}, false, nil
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		return PolicyDocument{}, false, err
	}
	p := state.Pools[poolID]
	if p == nil || !p.BuyerAccounts[accountID] {
		return PolicyDocument{}, false, nil
	}
	approval := state.CreatorApprovals[p.CreatorAccountID]
	return buildPolicyDocumentForPool(p, approval, generatedAt, false), true, nil
}

func BuildPublicPolicyDocument(ctx context.Context, store *Store, poolID string, generatedAt time.Time) (PolicyDocument, bool, error) {
	poolID = strings.TrimSpace(poolID)
	if store == nil || poolID == "" {
		return PolicyDocument{}, false, nil
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		return PolicyDocument{}, false, err
	}
	p := state.Pools[poolID]
	if p == nil {
		return PolicyDocument{}, false, nil
	}
	if _, ok := matchingPublicAnnouncement(state, p); !ok {
		return PolicyDocument{}, false, nil
	}
	approval := state.CreatorApprovals[p.CreatorAccountID]
	return redactPublicPolicyDocument(buildPolicyDocumentForPool(p, approval, generatedAt, true)), true, nil
}

func buildPolicyDocumentForPool(p *ReconstructedPoolState, approval CreatorApproval, generatedAt time.Time, publiclyAnnounced bool) PolicyDocument {
	generatedAt = generatedAt.UTC()
	if generatedAt.IsZero() {
		generatedAt = time.Now().UTC()
	}
	root := policyRootIssuer(p)
	retention, retentionResolved := resolveRetentionPolicyForPool(p, approval)
	retentionStatus := "registered"
	if !retentionResolved {
		retentionStatus = "unknown_policy_activation_blocked"
	}
	visibility := "authorized"
	productionBlocker := "public_announcement_and_production_gates_not_implemented"
	claimValidationStatus := "manifest_overclaim_rejection_enabled_candidate_surface_not_public"
	disclosures := []string{
		"prompts and responses are visible to the MacProvider coordinator",
		"prompts and responses may be visible to the selected provider operator",
		"supply_mode shared means admitted providers may also serve global traffic",
		"single-operator Trusted Pools do not provide a high-availability guarantee",
		"root issuer custody class is not yet recorded as an immutable approved class; production activation remains blocked",
		"retention policy id is resolved against MacProvider registered retention policy records; unknown ids fail activation",
		"this policy document is not a Privacy Pool, anonymous-routing, zero-knowledge, confidential-compute, end-to-end-encryption, or regulated-compliance claim",
		"public unauthenticated policy/status exposure requires an operator approval bound to the current manifest digest",
	}
	if publiclyAnnounced {
		visibility = "publicly_announced"
		productionBlocker = "production_gates_not_implemented"
		claimValidationStatus = "manifest_overclaim_rejection_enabled_publicly_announced_surface"
		disclosures[len(disclosures)-1] = "public unauthenticated policy/status exposure is approved only for the current manifest_core_digest and reviewed_distribution_artifact_digest and fails closed after either digest changes"
	}
	doc := PolicyDocument{
		SchemaVersion:  PolicySchemaVersion,
		GeneratedAtUTC: generatedAt.Format(time.RFC3339Nano),
		FreshUntilUTC:  generatedAt.Add(StatusFreshnessTTL).Format(time.RFC3339Nano),
		Pool: PolicyPool{
			PoolID:                 p.PoolID,
			Lifecycle:              p.Lifecycle,
			Visibility:             visibility,
			PubliclyAnnounced:      publiclyAnnounced,
			VisibilityGeneration:   p.PublicVisibilityGeneration,
			PublicApprovalID:       p.PublicAnnouncementApprovalID,
			ReviewedArtifactDigest: p.PublicReviewedArtifactDigest,
			MVPMode:                "single_operator",
			SupplyMode:             "creator_admitted",
			ProviderSupply:         "shared",
			CandidateOnly:          true,
			ProductionReady:        false,
			ProductionBlocker:      productionBlocker,
			LaunchEnvironment:      root.LaunchEnvironment,
			LifecycleReason:        p.LifecycleReason,
			CreatorGateReason:      p.CreatorGateReason,
			CreatorGateExpiresAt:   formatOptionalTime(p.CreatorGateExpiresAtUTC),
		},
		Creator: PolicyCreator{
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
		Policy: PolicyPolicy{
			ManifestVersion:                  p.ManifestVersion,
			PolicyHash:                       p.ManifestCoreDigest,
			ManifestCoreDigest:               p.ManifestCoreDigest,
			MinEligibleMembers:               policyMinEligibleMembers(p),
			MinBinaryVersion:                 policyMinBinaryVersion(p),
			RetentionPolicyID:                retentionPolicyIDForPool(p, approval),
			RetentionPolicyStatus:            retentionStatus,
			RetentionPolicyGoverningVersion:  retention.GoverningPolicyVersion,
			RetentionPolicyFieldCategories:   retention.FieldCategories,
			RetentionPolicyMinPeriod:         retention.MinRetentionPeriod,
			RetentionPolicyMaxPeriod:         retention.MaxRetentionPeriod,
			RetentionPolicyDeletionSLA:       retention.DeletionSLA,
			RetentionPolicyDisputeAuditTrail: retention.DisputeAuditTrailMinRetention,
			SplitExecutionStatus:             policySplitExecutionStatus(p),
		},
		RootIssuer:      root,
		Predicates:      policyPredicates(p, publiclyAnnounced),
		Confidentiality: policyConfidentiality(),
		ClaimControl: PolicyClaimControl{
			CanonicalName:     "Trusted Pool",
			ValidationStatus:  claimValidationStatus,
			ProhibitedClaims:  ProhibitedPromiseClaims(),
			AllowedClaimScope: "creator-run Trusted Pool with explicit policy controls; not content privacy, unlinkability, confidential compute, or regulated compliance",
		},
		Disclosures: disclosures,
	}
	return doc
}

func redactPublicPolicyDocument(doc PolicyDocument) PolicyDocument {
	doc.Pool.PublicApprovalID = ""
	doc.Pool.LaunchEnvironment = ""
	doc.Pool.LifecycleReason = ""
	doc.Pool.CreatorGateReason = ""
	doc.Pool.CreatorGateExpiresAt = ""
	doc.Creator.CreatorAccountID = ""
	doc.Creator.ApprovalRecordID = ""
	doc.Creator.CurrentApprovalVersion = ""
	doc.Creator.AllowedLaunchEnvironment = ""
	doc.Creator.CreatorAgreementID = ""
	doc.Creator.CreatorAgreementVersion = ""
	doc.Creator.CreatorAgreementExpiresAtUTC = ""
	doc.Creator.CreatorAgreementGraceEndsUTC = ""
	doc.Creator.Status = ""
	doc.RootIssuer.KeyID = ""
	doc.RootIssuer.PublicKeyFingerprint = ""
	doc.RootIssuer.CustodyDisclosureHash = ""
	doc.RootIssuer.LaunchEnvironment = ""
	return doc
}

func policyRootIssuer(p *ReconstructedPoolState) PolicyRootIssuer {
	if p == nil || p.RootIssuer == nil {
		return PolicyRootIssuer{
			CustodyClass:    "unverified",
			CustodyEvidence: "missing_root_registration",
		}
	}
	return PolicyRootIssuer{
		KeyID:                 p.RootIssuer.KeyID,
		PublicKeyFingerprint:  p.RootIssuer.PublicKeyFingerprint,
		CustodyClass:          "unverified",
		CustodyEvidence:       "hash_only_not_class_enforced",
		CustodyDisclosureHash: p.RootIssuer.StructuredCustodyDisclosureHash,
		LaunchEnvironment:     p.RootIssuer.LaunchEnvironment,
	}
}

func policyPredicates(p *ReconstructedPoolState, publiclyAnnounced bool) PolicyPredicates {
	predicates := PolicyPredicates{
		Enforced: []PolicyPredicate{
			{ID: "buyer_account_authorized", Status: "enforced", Scope: "gateway_authenticated_account"},
			{ID: "pool_lifecycle_non_active_fail_closed", Status: "enforced", Scope: "routeable_registry"},
			{ID: "non_revoked_creator_admitted_member", Status: "enforced", Scope: "routeable_registry"},
			{ID: "coordinator_pool_id_binding", Status: "enforced", Scope: "buyer_dispatch"},
			{ID: "retention_policy_registry_resolution", Status: "enforced", Scope: "promotion_gate_and_routeable_registry"},
		},
		ObserveOnly: []PolicyPredicate{
			{ID: "live_eligible_member_count", Status: "evaluated", Scope: "pool_status_live_provider_snapshot"},
			{ID: "root_issuer_custody_class", Status: "not_enforced", Scope: "production_gate"},
			{ID: "creator_self_service_authentication", Status: "not_implemented", Scope: "admin_surface"},
			{ID: "signed_launch_journey", Status: "not_implemented", Scope: "production_gate"},
		},
	}
	if publiclyAnnounced {
		predicates.Enforced = append(predicates.Enforced, PolicyPredicate{ID: "publicly_announced_approval", Status: "enforced", Scope: "visibility_gate"})
	} else {
		predicates.ObserveOnly = append(predicates.ObserveOnly, PolicyPredicate{ID: "publicly_announced_approval", Status: "not_enabled", Scope: "visibility_gate"})
	}
	if policyMinBinaryVersion(p) != "" {
		predicates.Enforced = append(predicates.Enforced, PolicyPredicate{ID: "min_binary_version", Status: "enforced", Scope: "routeable_registry"})
	}
	return predicates
}

func policyConfidentiality() PolicyConfidentiality {
	return PolicyConfidentiality{
		Scope:                              "trusted_pool_not_privacy_pool",
		CoordinatorPlaintextVisibility:     "prompt_and_response_visible",
		SelectedProviderOperatorVisibility: "prompt_and_response_may_be_visible",
		EncryptedLegClaim:                  "transport_coordinator_to_provider_only_if_pool_policy_requires_it",
	}
}

func ProhibitedPromiseClaims() []string {
	return []string{
		"Privacy Pool",
		"privacy-pool",
		"privacy_pool",
		"anonymous routing",
		"anonymous-routing",
		"anonymous_routing",
		"coordinator-blind content",
		"coordinator blind content",
		"coordinator_blind_content",
		"coordinator-blind",
		"coordinator blind",
		"coordinator_blind",
		"provider-blind",
		"provider blind",
		"provider_blind",
		"private from provider",
		"end-to-end encryption",
		"end to end encryption",
		"end-to-end-encryption",
		"end_to_end_encryption",
		"end-to-end encrypted",
		"confidential compute",
		"confidential-compute",
		"confidential_compute",
		"confidential computing",
		"confidential-computing",
		"confidential_computing",
		"zero-knowledge inference",
		"zero knowledge inference",
		"zero-knowledge-inference",
		"zero_knowledge_inference",
		"zero-knowledge",
		"zero knowledge",
		"zero_knowledge",
		"ZK inference",
		"ZK proof",
		"ZK private",
		"ZK privacy",
		"ZK pool",
		"dedicated supply",
		"dedicated-supply",
		"dedicated_supply",
		"isolated compute",
		"isolated-compute",
		"isolated_compute",
		"HIPAA",
		"GLBA",
		"SOC 2",
		"SOC-2",
		"SOC_2",
		"SOC2",
		"PCI-DSS",
		"PCI DSS",
		"PCI_DSS",
		"GDPR adequacy",
		"GDPR-adequacy",
		"GDPR_adequacy",
		"FERPA",
		"regulated compliance",
		"regulated-compliance",
		"regulated_compliance",
		"regulatory compliance",
		"regulatory-compliance",
		"regulatory_compliance",
		"compliance certified",
		"compliance-certified",
		"compliance_certified",
		"certified compliant",
		"certified-compliant",
		"certified_compliant",
	}
}

func ValidatePromiseClaimsText(values ...string) error {
	for _, value := range values {
		if prohibitedPromiseClaim(value) != "" {
			return ErrProhibitedPromiseClaim
		}
	}
	return nil
}

func prohibitedPromiseClaim(value string) string {
	normalizedValue := normalizePromiseClaimText(value)
	compactValue := compactPromiseClaimText(value)
	if promiseClaimTokenPresent(normalizedValue, "zk") || promiseClaimTokenPairPresent(normalizedValue, "z", "k") {
		return "ZK"
	}
	for _, claim := range ProhibitedPromiseClaims() {
		needle := normalizePromiseClaimText(claim)
		if needle != "" && strings.Contains(normalizedValue, needle) {
			return claim
		}
		compactNeedle := compactPromiseClaimText(claim)
		if compactNeedle != "" && strings.Contains(compactValue, compactNeedle) {
			return claim
		}
	}
	return ""
}

var promiseClaimSeparatorRE = regexp.MustCompile(`[^a-z0-9]+`)

func normalizePromiseClaimText(value string) string {
	lower := strings.ToLower(value)
	return strings.TrimSpace(promiseClaimSeparatorRE.ReplaceAllString(lower, " "))
}

func compactPromiseClaimText(value string) string {
	lower := strings.ToLower(value)
	return promiseClaimSeparatorRE.ReplaceAllString(lower, "")
}

func promiseClaimTokenPresent(normalizedValue, token string) bool {
	for _, field := range strings.Fields(normalizedValue) {
		if field == token {
			return true
		}
	}
	return false
}

func promiseClaimTokenPairPresent(normalizedValue, first, second string) bool {
	previous := ""
	for _, field := range strings.Fields(normalizedValue) {
		if previous == first && field == second {
			return true
		}
		previous = field
	}
	return false
}
