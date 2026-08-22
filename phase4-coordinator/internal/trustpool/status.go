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
	PoolID                 string `json:"pool_id"`
	Lifecycle              string `json:"lifecycle"`
	Visibility             string `json:"visibility"`
	PubliclyAnnounced      bool   `json:"publicly_announced"`
	VisibilityGeneration   uint64 `json:"visibility_generation"`
	PublicApprovalID       string `json:"public_announcement_approval_id,omitempty"`
	ReviewedArtifactDigest string `json:"reviewed_distribution_artifact_digest,omitempty"`
	LifecycleReason        string `json:"lifecycle_reason,omitempty"`
	Readiness              string `json:"readiness"`
	ReadinessReason        string `json:"readiness_reason,omitempty"`
	MVPMode                string `json:"mvp_mode"`
	SupplyMode             string `json:"supply_mode"`
}

type StatusCreator struct {
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

type StatusLiveProvider struct {
	ProviderID     string
	ServingCapable bool
	BinaryVersion  string
}

type StatusLiveProviderSet struct {
	Providers []StatusLiveProvider
}

func BuildStatusDocument(ctx context.Context, store *Store, registry *Registry, poolID, accountID string, generatedAt time.Time) (StatusDocument, bool, error) {
	return buildStatusDocument(ctx, store, registry, poolID, accountID, generatedAt, nil)
}

func BuildStatusDocumentWithLiveProviders(ctx context.Context, store *Store, registry *Registry, poolID, accountID string, generatedAt time.Time, live StatusLiveProviderSet) (StatusDocument, bool, error) {
	return buildStatusDocument(ctx, store, registry, poolID, accountID, generatedAt, &live)
}

func buildStatusDocument(ctx context.Context, store *Store, registry *Registry, poolID, accountID string, generatedAt time.Time, live *StatusLiveProviderSet) (StatusDocument, bool, error) {
	poolID = strings.TrimSpace(poolID)
	accountID = strings.TrimSpace(accountID)
	if store == nil || registry == nil || poolID == "" || accountID == "" {
		return StatusDocument{}, false, nil
	}
	snapshot, authorized := registry.AuthorizeAndSnapshot(poolID, accountID)
	if !authorized {
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
	return buildStatusDocumentForPool(state, p, approval, generatedAt, false, snapshot, live), true, nil
}

func BuildPublicStatusDocument(ctx context.Context, store *Store, poolID string, generatedAt time.Time) (StatusDocument, bool, error) {
	return buildPublicStatusDocument(ctx, store, nil, poolID, generatedAt, nil)
}

func BuildPublicStatusDocumentWithRegistry(ctx context.Context, store *Store, registry *Registry, poolID string, generatedAt time.Time) (StatusDocument, bool, error) {
	return buildPublicStatusDocument(ctx, store, registry, poolID, generatedAt, nil)
}

func BuildPublicStatusDocumentWithLiveProviders(ctx context.Context, store *Store, registry *Registry, poolID string, generatedAt time.Time, live StatusLiveProviderSet) (StatusDocument, bool, error) {
	return buildPublicStatusDocument(ctx, store, registry, poolID, generatedAt, &live)
}

func buildPublicStatusDocument(ctx context.Context, store *Store, registry *Registry, poolID string, generatedAt time.Time, live *StatusLiveProviderSet) (StatusDocument, bool, error) {
	poolID = strings.TrimSpace(poolID)
	if store == nil || poolID == "" {
		return StatusDocument{}, false, nil
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		return StatusDocument{}, false, err
	}
	p := state.Pools[poolID]
	if p == nil {
		return StatusDocument{}, false, nil
	}
	if _, ok := matchingPublicAnnouncement(state, p); !ok {
		return StatusDocument{}, false, nil
	}
	approval := state.CreatorApprovals[p.CreatorAccountID]
	snapshot := statusSnapshotForPool(state, p, registry)
	return redactPublicStatusDocument(buildStatusDocumentForPool(state, p, approval, generatedAt, true, snapshot, live)), true, nil
}

func buildStatusDocumentForPool(state *ReconstructedState, p *ReconstructedPoolState, approval CreatorApproval, generatedAt time.Time, publiclyAnnounced bool, snapshot Snapshot, live *StatusLiveProviderSet) StatusDocument {
	generatedAt = generatedAt.UTC()
	if generatedAt.IsZero() {
		generatedAt = time.Now().UTC()
	}
	nonRevoked := nonRevokedMemberCount(p)
	coherentSnapshot := statusSnapshotCoherent(state, snapshot)
	eligibleMemberCount := eligibleMemberCountFromSnapshot(snapshot, p, live, coherentSnapshot)
	readiness, readinessReason := readinessForSnapshot(p, snapshot, eligibleMemberCount, live != nil, coherentSnapshot)
	_, routeabilityReason := poolRouteability(p)
	statusRouteable := readiness == "ready"
	routeableGeneration := snapshot.Generation
	if routeableGeneration == 0 {
		routeableGeneration = p.RouteableSnapshotGeneration()
	}
	routeableUntilUTC := snapshot.RouteableUntilUTC
	if routeableUntilUTC.IsZero() {
		routeableUntilUTC = p.CreatorGateExpiresAtUTC
	}
	visibility := "authorized"
	disclosures := []string{
		"prompts and responses are visible to the MacProvider coordinator",
		"prompts and responses may be visible to the selected provider operator",
		"single-operator Trusted Pools do not provide a high-availability guarantee",
		statusEligibilityDisclosure(false, live != nil),
		"this status document is not a Privacy Pool, anonymous-routing, zero-knowledge, or regulated-compliance claim",
		"public unauthenticated policy/status exposure requires an operator approval bound to the current manifest digest",
	}
	if publiclyAnnounced {
		visibility = "publicly_announced"
		disclosures[3] = statusEligibilityDisclosure(true, live != nil)
		disclosures[len(disclosures)-1] = "public unauthenticated policy/status exposure is approved only for the current manifest_core_digest and reviewed_distribution_artifact_digest and fails closed after either digest changes"
	}
	doc := StatusDocument{
		SchemaVersion:  StatusSchemaVersion,
		GeneratedAtUTC: generatedAt.Format(time.RFC3339Nano),
		FreshUntilUTC:  generatedAt.Add(StatusFreshnessTTL).Format(time.RFC3339Nano),
		Pool: StatusPool{
			PoolID:                 p.PoolID,
			Lifecycle:              p.Lifecycle,
			Visibility:             visibility,
			PubliclyAnnounced:      publiclyAnnounced,
			VisibilityGeneration:   p.PublicVisibilityGeneration,
			PublicApprovalID:       p.PublicAnnouncementApprovalID,
			ReviewedArtifactDigest: p.PublicReviewedArtifactDigest,
			LifecycleReason:        p.LifecycleReason,
			Readiness:              readiness,
			ReadinessReason:        readinessReason,
			MVPMode:                "single_operator",
			SupplyMode:             "creator_admitted",
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
			CurrentEligibleMemberCount:   eligibleMemberCount,
			RevokedMemberCount:           len(p.Revoked),
			AuthorizedBuyerCount:         len(p.BuyerAccounts),
			LiveEligibilityEvaluation:    statusEligibilityEvaluation(live != nil),
		},
		Routeability: StatusRouteability{
			Routeable:               statusRouteable,
			Generation:              p.Generation,
			RouteableGeneration:     routeableGeneration,
			RouteGateCheckedAtUTC:   formatOptionalTime(state.RouteGateCheckedAt),
			RouteableUntilUTC:       formatOptionalTime(routeableUntilUTC),
			CreatorGateReason:       routeabilityReason,
			CreatorGateExpiresAtUTC: formatOptionalTime(routeableUntilUTC),
		},
		Settlement: StatusSettlement{
			SplitExecutionStatus: policySplitExecutionStatus(p),
		},
		Confidentiality: StatusConfidentiality{
			Scope: "trusted_pool_not_privacy_pool",
		},
		Disclosures: disclosures,
	}
	return doc
}

func redactPublicStatusDocument(doc StatusDocument) StatusDocument {
	doc.Pool.PublicApprovalID = ""
	doc.Pool.LifecycleReason = ""
	doc.Creator.CreatorAccountID = ""
	doc.Creator.ApprovalRecordID = ""
	doc.Creator.CurrentApprovalVersion = ""
	doc.Creator.AllowedLaunchEnvironment = ""
	doc.Creator.CreatorAgreementID = ""
	doc.Creator.CreatorAgreementVersion = ""
	doc.Creator.CreatorAgreementExpiresAtUTC = ""
	doc.Creator.CreatorAgreementGraceEndsUTC = ""
	doc.Creator.Status = ""
	doc.Policy.RootIssuerKeyID = ""
	doc.Policy.RootIssuerKeyHash = ""
	doc.Policy.CustodyEvidence = ""
	doc.Membership.CurrentMemberCount = 0
	doc.Membership.CurrentAdmittedMemberCount = 0
	doc.Membership.CurrentNonRevokedMemberCount = 0
	doc.Membership.RevokedMemberCount = 0
	doc.Membership.AuthorizedBuyerCount = 0
	doc.Routeability.RouteableGeneration = 0
	doc.Routeability.RouteGateCheckedAtUTC = ""
	doc.Routeability.RouteableUntilUTC = ""
	doc.Routeability.CreatorGateReason = ""
	doc.Routeability.CreatorGateExpiresAtUTC = ""
	return doc
}

func statusSnapshotForPool(state *ReconstructedState, p *ReconstructedPoolState, registry *Registry) Snapshot {
	if p == nil {
		return Snapshot{Members: map[string]bool{}}
	}
	if registry != nil {
		return registry.Snapshot(p.PoolID)
	}
	routeable, _ := poolRouteability(p)
	members := map[string]bool{}
	if routeable {
		for id := range p.Members {
			if !p.Revoked[id] {
				members[id] = true
			}
		}
	}
	var revision uint64
	if state != nil {
		revision = state.Revision
	}
	return Snapshot{
		PoolID:            p.PoolID,
		Exists:            true,
		Members:           members,
		Routeable:         routeable,
		Generation:        p.RouteableSnapshotGeneration(),
		Revision:          revision,
		RouteableUntilUTC: p.CreatorGateExpiresAtUTC,
	}
}

func statusSnapshotCoherent(state *ReconstructedState, snapshot Snapshot) bool {
	if state == nil {
		return true
	}
	return snapshot.Revision == state.Revision
}

func readinessForSnapshot(p *ReconstructedPoolState, snapshot Snapshot, eligibleMemberCount int, liveEvaluated bool, coherentSnapshot bool) (string, string) {
	if _, reason := poolRouteability(p); reason != "" {
		return "unavailable", reason
	}
	if !coherentSnapshot {
		return "unavailable", "routeable_snapshot_stale"
	}
	if snapshot.Exists && snapshot.Routeable && (!liveEvaluated || eligibleMemberCount >= policyMinEligibleMembers(p)) {
		if liveEvaluated {
			return "ready", "live_provider_snapshot"
		}
		return "ready", "routeable_registry_snapshot"
	}
	if !snapshot.Exists {
		return "unavailable", "routeable_snapshot_missing"
	}
	if !snapshot.Routeable && !snapshot.RouteableUntilUTC.IsZero() && !time.Now().UTC().Before(snapshot.RouteableUntilUTC.UTC()) {
		return "unavailable", "creator_gate_expired"
	}
	if liveEvaluated {
		return "unavailable", "live_provider_eligible_members_unmet"
	}
	return "unavailable", "routeable_snapshot_unavailable"
}

func eligibleMemberCountFromSnapshot(snapshot Snapshot, p *ReconstructedPoolState, live *StatusLiveProviderSet, coherentSnapshot bool) int {
	if !coherentSnapshot || !snapshot.Exists || !snapshot.Routeable {
		return 0
	}
	if live == nil {
		return len(snapshot.Members)
	}
	minBinaryVersion := snapshot.MinBinaryVersion
	if minBinaryVersion == "" {
		minBinaryVersion = policyMinBinaryVersion(p)
	}
	var count int
	for _, provider := range live.Providers {
		if !provider.ServingCapable || !snapshot.Members[provider.ProviderID] {
			continue
		}
		if !statusProviderMeetsBinaryFloor(provider.BinaryVersion, minBinaryVersion) {
			continue
		}
		count++
	}
	return count
}

func statusProviderMeetsBinaryFloor(providerVersion, minBinaryVersion string) bool {
	if minBinaryVersion == "" {
		return true
	}
	cmp, ok := versionfloor.Compare(providerVersion, minBinaryVersion)
	return ok && cmp >= 0
}

func statusEligibilityEvaluation(liveEvaluated bool) string {
	if liveEvaluated {
		return "live_provider_snapshot"
	}
	return "routeable_registry_snapshot"
}

func statusEligibilityDisclosure(publiclyAnnounced, liveEvaluated bool) string {
	visibility := "buyer-authenticated"
	if publiclyAnnounced {
		visibility = "public"
	}
	if liveEvaluated {
		return "live eligible member count and route-time readiness are evaluated from the " + visibility + " routeable registry snapshot plus live provider-serving and binary-floor state; readiness does not promise immediate free capacity"
	}
	return "live eligible member count and route-time readiness are evaluated from the " + visibility + " routeable registry snapshot; readiness does not promise immediate free capacity"
}

func matchingPublicAnnouncement(state *ReconstructedState, p *ReconstructedPoolState) (PublicAnnouncementApproval, bool) {
	if state == nil || p == nil || p.ManifestCoreDigest == "" {
		return PublicAnnouncementApproval{}, false
	}
	if !publicAnnouncementLaunchAllowed(p) {
		return PublicAnnouncementApproval{}, false
	}
	approval, ok := state.PublicAnnouncements[p.PoolID]
	if !ok {
		return PublicAnnouncementApproval{}, false
	}
	if err := validateStoredPublicAnnouncementApproval(approval); err != nil {
		return PublicAnnouncementApproval{}, false
	}
	if approval.ManifestCoreDigest != p.ManifestCoreDigest {
		return PublicAnnouncementApproval{}, false
	}
	artifact, ok := state.ReviewedArtifacts[p.PoolID]
	if !ok || artifact.ManifestCoreDigest != p.ManifestCoreDigest ||
		artifact.ReviewedDistributionDigest != approval.ReviewedDistributionDigest ||
		artifact.ReviewRevision == 0 {
		return PublicAnnouncementApproval{}, false
	}
	binding, ok := currentPublicAnnouncementBinding(state, p)
	if !ok {
		return PublicAnnouncementApproval{}, false
	}
	if approval.CreatorAccountID != binding.CreatorAccountID ||
		approval.CreatorApprovalRecordID != binding.CreatorApprovalRecordID ||
		approval.CreatorApprovalVersion != binding.CreatorApprovalVersion ||
		approval.CreatorApprovalRevision != binding.CreatorApprovalRevision {
		return PublicAnnouncementApproval{}, false
	}
	return approval, true
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
