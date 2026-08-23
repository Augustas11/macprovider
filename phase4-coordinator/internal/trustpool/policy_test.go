package trustpool_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestBuildPolicyDocumentReturnsBuyerSafeCandidatePolicyShape(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000900, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.MinEligibleMembers = 2
			core.MinBinaryVersion = "1.8.33"
			core.RetentionPolicyID = "extended-dispute"
		}),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-secret"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	}
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	generatedAt := time.Unix(1800001000, 0).UTC()
	doc, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, root.poolID, "acct-a", generatedAt)
	if err != nil {
		t.Fatalf("BuildPolicyDocument: %v", err)
	}
	if !found {
		t.Fatal("BuildPolicyDocument found=false, want true")
	}
	if doc.SchemaVersion != trustpool.PolicySchemaVersion {
		t.Fatalf("schema_version=%q", doc.SchemaVersion)
	}
	if doc.GeneratedAtUTC != generatedAt.Format(time.RFC3339Nano) {
		t.Fatalf("generated_at_utc=%q", doc.GeneratedAtUTC)
	}
	if doc.FreshUntilUTC != generatedAt.Add(trustpool.StatusFreshnessTTL).Format(time.RFC3339Nano) {
		t.Fatalf("fresh_until_utc=%q", doc.FreshUntilUTC)
	}
	if doc.Pool.Visibility != "authorized" || doc.Pool.PubliclyAnnounced || !doc.Pool.CandidateOnly || doc.Pool.ProductionReady {
		t.Fatalf("pool=%+v", doc.Pool)
	}
	if doc.Pool.ProviderSupply != "shared" || doc.Pool.SupplyMode != "creator_admitted" || doc.Pool.MVPMode != "single_operator" {
		t.Fatalf("pool supply fields=%+v", doc.Pool)
	}
	if doc.Policy.PolicyHash == "" || doc.Policy.PolicyHash != doc.Policy.ManifestCoreDigest || doc.Policy.MinEligibleMembers != 2 || doc.Policy.MinBinaryVersion != "1.8.33" {
		t.Fatalf("policy=%+v", doc.Policy)
	}
	if len(doc.Policy.ModelAllowlist) != 1 || doc.Policy.ModelAllowlist[0] != "model-a" {
		t.Fatalf("policy model_allowlist=%+v, want [model-a]", doc.Policy.ModelAllowlist)
	}
	if !policyPredicatePresent(doc.Predicates.Enforced, "min_binary_version") {
		t.Fatalf("enforced predicates=%+v, want manifest-only min_binary_version predicate", doc.Predicates.Enforced)
	}
	if !policyPredicatePresent(doc.Predicates.Enforced, "retention_policy_registry_resolution") {
		t.Fatalf("enforced predicates=%+v, want retention-policy registry predicate", doc.Predicates.Enforced)
	}
	if doc.Policy.RetentionPolicyID != "extended-dispute" ||
		doc.Policy.RetentionPolicyStatus != "registered" ||
		doc.Policy.RetentionPolicyGoverningVersion != "retention-policy-v1" ||
		doc.Policy.RetentionPolicyMinPeriod != "365d" ||
		doc.Policy.RetentionPolicyMaxPeriod != "730d" ||
		doc.Policy.RetentionPolicyDeletionSLA != "45d_after_retention_window" ||
		doc.Policy.RetentionPolicyDisputeAuditTrail != "365d" ||
		doc.Policy.SplitExecutionStatus != "declared_not_executed" {
		t.Fatalf("policy status=%+v", doc.Policy)
	}
	if !stringSliceContains(doc.Policy.RetentionPolicyFieldCategories, "pool_audit_log") || !stringSliceContains(doc.Policy.RetentionPolicyFieldCategories, "public_announcement_history") {
		t.Fatalf("retention policy categories=%+v, want resolved registry categories", doc.Policy.RetentionPolicyFieldCategories)
	}
	if doc.RootIssuer.CustodyClass != "unverified" || doc.RootIssuer.CustodyEvidence != "hash_only_not_class_enforced" || doc.RootIssuer.PublicKeyFingerprint == "" {
		t.Fatalf("root issuer=%+v", doc.RootIssuer)
	}
	if doc.Confidentiality.CoordinatorPlaintextVisibility != "prompt_and_response_visible" || doc.Confidentiality.SelectedProviderOperatorVisibility == "" {
		t.Fatalf("confidentiality=%+v", doc.Confidentiality)
	}
	if doc.ClaimControl.CanonicalName != "Trusted Pool" || !strings.Contains(doc.ClaimControl.ValidationStatus, "overclaim") {
		t.Fatalf("claim control=%+v", doc.ClaimControl)
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	body := string(raw)
	if strings.Contains(body, "provider-secret") {
		t.Fatalf("policy leaked provider identity: %s", body)
	}
	for _, want := range []string{
		"not a Privacy Pool",
		"public unauthenticated policy/status exposure requires an operator approval",
		"root issuer custody class is not yet recorded",
		"supply_mode shared",
		"retention policy id is resolved",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("policy missing disclosure %q: %s", want, body)
		}
	}
}

func TestBuildPolicyDocumentDoesNotFallbackToApprovalRetentionAfterManifest(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000925, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	for _, e := range []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.RetentionPolicyID = ""
		}),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	} {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	doc, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, root.poolID, "acct-a", time.Unix(1800001001, 0).UTC())
	if err != nil {
		t.Fatalf("BuildPolicyDocument: %v", err)
	}
	if !found {
		t.Fatal("BuildPolicyDocument found=false, want true")
	}
	if doc.Policy.RetentionPolicyID != "" ||
		doc.Policy.RetentionPolicyStatus != "unknown_policy_activation_blocked" ||
		doc.Policy.RetentionPolicyGoverningVersion != "" ||
		len(doc.Policy.RetentionPolicyFieldCategories) != 0 ||
		doc.Policy.RetentionPolicyMinPeriod != "" ||
		doc.Policy.RetentionPolicyMaxPeriod != "" ||
		doc.Policy.RetentionPolicyDeletionSLA != "" ||
		doc.Policy.RetentionPolicyDisputeAuditTrail != "" {
		t.Fatalf("policy retention fallback=%+v, want manifest-empty activation-blocked without registry fields", doc.Policy)
	}
}

func policyPredicatePresent(predicates []trustpool.PolicyPredicate, id string) bool {
	for _, predicate := range predicates {
		if predicate.ID == id {
			return true
		}
	}
	return false
}

func stringSliceContains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func TestBuildPolicyDocumentCollapsesUnauthorizedAndUnknown(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800001100, 0).UTC()
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	if _, _, _, err := store.AppendValidatedEvent(ctx, ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})); err != nil {
		t.Fatalf("AppendValidatedEvent create: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, ev("op-buyer", ts.Add(time.Second), trustpool.EventBuyerAuthorized, "pool-a", func(e *trustpool.DurableEvent) {
		e.BuyerAccountID = "acct-a"
	})); err != nil {
		t.Fatalf("AppendValidatedEvent buyer: %v", err)
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	if _, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, "pool-a", "acct-denied", ts); err != nil || found {
		t.Fatalf("unauthorized found=%v err=%v, want false nil", found, err)
	}
	if _, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, "pool-missing", "acct-a", ts); err != nil || found {
		t.Fatalf("unknown found=%v err=%v, want false nil", found, err)
	}
}

func TestBuildPublicPolicyDocumentRequiresMatchingAnnouncementApproval(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800001200, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "public", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	for _, e := range []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssueInEnvironment(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonceInEnvironment(t, store, "creator-a", "approval-v1", "public", ts.Add(time.Hour)), root, "public"),
		manifest,
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-secret"
		}),
	} {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, ts); err != nil || found {
		t.Fatalf("public policy before approval found=%v err=%v, want false nil", found, err)
	}
	approval := approvePublicAnnouncement(t, store, root.poolID, manifest.ManifestCoreDigest)
	if approval.PublicAnnouncementRevision != 1 {
		t.Fatalf("public announcement revision=%d, want 1", approval.PublicAnnouncementRevision)
	}
	generatedAt := time.Unix(1800001300, 0).UTC()
	doc, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, generatedAt)
	if err != nil {
		t.Fatalf("BuildPublicPolicyDocument: %v", err)
	}
	if !found {
		t.Fatal("BuildPublicPolicyDocument found=false, want true")
	}
	if doc.Pool.Visibility != "publicly_announced" || !doc.Pool.PubliclyAnnounced || !doc.Pool.CandidateOnly || doc.Pool.ProductionReady {
		t.Fatalf("public policy pool=%+v", doc.Pool)
	}
	if doc.Pool.PublicApprovalID != "" || doc.Pool.ReviewedArtifactDigest != approval.ReviewedDistributionDigest {
		t.Fatalf("public policy approval binding=%+v, want redacted approval id and artifact %q", doc.Pool, approval.ReviewedDistributionDigest)
	}
	if !policyPredicatePresent(doc.Predicates.Enforced, "publicly_announced_approval") {
		t.Fatalf("public policy enforced predicates=%+v, want public announcement predicate", doc.Predicates.Enforced)
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	body := string(raw)
	if strings.Contains(body, "provider-secret") {
		t.Fatalf("public policy leaked provider identity: %s", body)
	}
	if strings.Contains(body, `"creator_account_id"`) || strings.Contains(body, `"approval_record_id"`) || strings.Contains(body, `"current_approval_version"`) {
		t.Fatalf("public policy leaked internal creator approval fields: %s", body)
	}
	if !strings.Contains(body, "reviewed_distribution_artifact_digest") {
		t.Fatalf("public policy missing digest-bound disclosure: %s", body)
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct after public approval: %v", err)
	}
	publicGeneration := state.Pools[root.poolID].PublicVisibilityGeneration
	if !state.Pools[root.poolID].PubliclyAnnounced || publicGeneration <= state.Pools[root.poolID].Generation {
		t.Fatalf("public replay state=%+v, want publicly announced generation above event generation", state.Pools[root.poolID])
	}
	reviewedArtifactV2Digest := hexDigest("reviewed-distribution-v2")
	reviewedArtifactV2, err := store.UpsertReviewedDistributionArtifact(ctx, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-v2",
		PoolID:                     root.poolID,
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactV2Digest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID + "/v2",
		ClaimControlDigest:         hexDigest("claim-control-v2"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              ts.Add(5 * time.Second),
	})
	if err != nil {
		t.Fatalf("UpsertReviewedDistributionArtifact(v2): %v", err)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, generatedAt); err != nil || found {
		t.Fatalf("public policy after reviewed artifact rotation found=%v err=%v, want false nil", found, err)
	}
	approvalV2, err := store.UpsertPublicAnnouncementApproval(ctx, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-announcement-v2",
		PoolID:                     root.poolID,
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactV2.ReviewedDistributionDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              ts.Add(6 * time.Second),
	})
	if err != nil {
		t.Fatalf("UpsertPublicAnnouncementApproval(v2): %v", err)
	}
	if approvalV2.PublicAnnouncementRevision != 2 {
		t.Fatalf("public announcement revision after reviewed artifact rotation=%d, want 2", approvalV2.PublicAnnouncementRevision)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, generatedAt); err != nil || !found {
		t.Fatalf("public policy after reviewed artifact reapproval found=%v err=%v, want true nil", found, err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "public", time.Now().Add(24*time.Hour), trustpool.CreatorStatusSuspended)
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, generatedAt); err != nil || found {
		t.Fatalf("public policy after creator suspension found=%v err=%v, want false nil", found, err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "public", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, generatedAt); err != nil || found {
		t.Fatalf("public policy after creator reapproval without public reapproval found=%v err=%v, want false nil", found, err)
	}
	approvalAfterCreatorReapproval, err := store.UpsertPublicAnnouncementApproval(ctx, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-announcement-after-creator-reapproval",
		PoolID:                     root.poolID,
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactV2.ReviewedDistributionDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              ts.Add(7 * time.Second),
	})
	if err != nil {
		t.Fatalf("UpsertPublicAnnouncementApproval(after creator reapproval): %v", err)
	}
	if approvalAfterCreatorReapproval.PublicAnnouncementRevision != 3 {
		t.Fatalf("public announcement revision after creator reapproval=%d, want 3", approvalAfterCreatorReapproval.PublicAnnouncementRevision)
	}

	nextManifest := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-v2", ts.Add(4*time.Second), manifest, root, func(core *poolmanifest.PolicyCore) {
		core.RetentionPolicyID = "extended-dispute"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, nextManifest); err != nil {
		t.Fatalf("AppendValidatedEvent(%s): %v", nextManifest.OperationID, err)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, generatedAt); err != nil || found {
		t.Fatalf("public policy after digest change found=%v err=%v, want false nil", found, err)
	}
	state, err = store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct after digest change: %v", err)
	}
	if state.Pools[root.poolID].PubliclyAnnounced || state.Pools[root.poolID].PublicVisibilityGeneration <= publicGeneration {
		t.Fatalf("public replay state after digest change=%+v, want closed visibility and advanced generation", state.Pools[root.poolID])
	}
}

func TestBuildPublicPolicyDocumentIgnoresLegacyUnboundPublicAnnouncementRows(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800001350, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	for _, e := range []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		manifest,
	} {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO trustpool_public_announcements (
    pool_id, operation_id, manifest_core_digest, reviewed_distribution_artifact_digest,
    creator_account_id, creator_approval_record_id,
    creator_approval_version, creator_approval_revision, approval_record_id, approved_by,
    approved_at_utc, public_announcement_revision, updated_at_utc
) VALUES (?, '', ?, '', '', '', '', 0, 'legacy-public-approval', 'operator-a', ?, 1, ?)`,
		root.poolID,
		manifest.ManifestCoreDigest,
		ts.Format(time.RFC3339Nano),
		ts.Format(time.RFC3339Nano),
	); err != nil {
		t.Fatalf("insert legacy public announcement: %v", err)
	}
	if _, err := store.Reconstruct(ctx); err != nil {
		t.Fatalf("Reconstruct with legacy public announcement: %v", err)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, ts); err != nil || found {
		t.Fatalf("public policy for legacy unbound row found=%v err=%v, want false nil", found, err)
	}
}

func TestPublicAnnouncementApprovalRejectsCandidateLaunchEnvironment(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800001500, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	for _, e := range []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		manifest,
	} {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	artifact := approveReviewedDistributionArtifact(t, store, root.poolID, manifest.ManifestCoreDigest)
	_, err = store.UpsertPublicAnnouncementApproval(ctx, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-candidate",
		PoolID:                     root.poolID,
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: artifact.ReviewedDistributionDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              ts.Add(3 * time.Second),
	})
	if !errors.Is(err, trustpool.ErrPublicAnnouncementGate) {
		t.Fatalf("candidate public announcement err=%v, want ErrPublicAnnouncementGate", err)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(ctx, store, root.poolID, ts); err != nil || found {
		t.Fatalf("candidate public policy found=%v err=%v, want false nil", found, err)
	}
}

func TestPromiseClaimControlRejectsSubmittedProhibitedTerms(t *testing.T) {
	t.Parallel()
	for _, value := range []string{
		"this is a Privacy Pool with anonymous routing",
		"HIPAA compliant medical records pool",
		"coordinator-blind content for clients",
		"provider-blind enclave for clients",
		"dedicated supply for buyers",
		"not marketing language; this is confidential compute",
		"not marketing language; this is confidential-compute",
		"SOC-2 ready pool",
		"FERPA compliant education records pool",
		"regulated compliance pool",
		"regulatory-compliance workload",
		"compliance certified pool",
		"certified compliant pool",
		"ZK proof pool",
		"ZK-backed Trusted Pool",
		"Z-K proof pool",
		"Z.K. privacy pool",
		"Z K pool",
		"Z\u200dK proof pool",
		"Z K-backed Trusted Pool",
		"Z-K-backed Trusted Pool",
		"end_to_end_encryption for buyer traffic",
		"not merely a Privacy Pool",
		"without sacrificing Privacy Pool guarantees",
		"this policy document is not a Privacy Pool",
		"does not provide anonymous routing or zero-knowledge inference",
		"not end-to-end encryption",
	} {
		if err := trustpool.ValidatePromiseClaimsText(value); err == nil {
			t.Fatalf("ValidatePromiseClaimsText(%q) = nil, want rejection", value)
		}
	}
	if err := trustpool.ValidatePromiseClaimsText("creator-run Trusted Pool with coordinator and selected-provider operator content visibility disclosed"); err != nil {
		t.Fatalf("ValidatePromiseClaimsText allowed claim = %v, want nil", err)
	}
}
