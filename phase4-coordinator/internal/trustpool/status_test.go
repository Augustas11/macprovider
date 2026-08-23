package trustpool_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestBuildStatusDocumentReturnsBuyerSafePromiseShape(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000600, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-floor", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
			e.MinBinaryVersion = "1.8.33"
		}),
		ev("op-member-a", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-member-b", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-revoke-b", ts.Add(6*time.Second), trustpool.EventMemberRevoked, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-buyer", ts.Add(7*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", ts.Add(8*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
	}
	for _, e := range events {
		if e.EventType == trustpool.EventLifecycleChanged && e.Lifecycle == trustpool.LifecycleActive {
			insertPromotedEvent(t, ctx, db, e)
			continue
		}
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
	generatedAt := time.Unix(1800000700, 123).UTC()
	doc, found, err := trustpool.BuildStatusDocumentWithLiveProviders(ctx, store, registry, root.poolID, "acct-a", generatedAt, trustpool.StatusLiveProviderSet{Providers: []trustpool.StatusLiveProvider{
		{ProviderID: "provider-a", ServingCapable: true, BinaryVersion: "1.8.33"},
		{ProviderID: "provider-b", ServingCapable: true, BinaryVersion: "1.8.33"},
	}})
	if err != nil {
		t.Fatalf("BuildStatusDocument: %v", err)
	}
	if !found {
		t.Fatal("BuildStatusDocument found=false, want true")
	}
	if doc.SchemaVersion != trustpool.StatusSchemaVersion {
		t.Fatalf("schema_version=%q", doc.SchemaVersion)
	}
	if doc.GeneratedAtUTC != generatedAt.Format(time.RFC3339Nano) {
		t.Fatalf("generated_at_utc=%q", doc.GeneratedAtUTC)
	}
	if doc.FreshUntilUTC != generatedAt.Add(trustpool.StatusFreshnessTTL).Format(time.RFC3339Nano) {
		t.Fatalf("fresh_until_utc=%q", doc.FreshUntilUTC)
	}
	if doc.Pool.Readiness != "ready" || doc.Pool.ReadinessReason != "live_provider_snapshot" || !doc.Routeability.Routeable {
		t.Fatalf("readiness=%q routeable=%v", doc.Pool.Readiness, doc.Routeability.Routeable)
	}
	if doc.Membership.CurrentMemberCount != 1 || doc.Membership.CurrentAdmittedMemberCount != 1 || doc.Membership.CurrentNonRevokedMemberCount != 1 || doc.Membership.CurrentEligibleMemberCount != 1 || doc.Membership.RevokedMemberCount != 1 || doc.Membership.LiveEligibilityEvaluation != "live_provider_snapshot" {
		t.Fatalf("membership=%+v", doc.Membership)
	}
	if doc.Policy.ManifestVersion != 1 || doc.Policy.MinBinaryVersion != "1.8.33" || doc.Policy.RootIssuerKeyID == "" {
		t.Fatalf("policy=%+v", doc.Policy)
	}
	if len(doc.Policy.ModelAllowlist) != 1 || doc.Policy.ModelAllowlist[0] != "model-a" {
		t.Fatalf("status model_allowlist=%+v, want [model-a]", doc.Policy.ModelAllowlist)
	}
	if doc.Policy.RetentionPolicyID != "standard" ||
		doc.Policy.RetentionPolicyStatus != "registered" ||
		doc.Policy.RetentionPolicyGoverningVersion != "retention-policy-v1" ||
		!stringSliceContains(doc.Policy.RetentionPolicyFieldCategories, "request_log") ||
		!stringSliceContains(doc.Policy.RetentionPolicyFieldCategories, "pool_audit_log") {
		t.Fatalf("status retention policy=%+v, want resolved standard registry record", doc.Policy)
	}
	if doc.Settlement.SplitExecutionStatus != "declared_not_executed" {
		t.Fatalf("settlement=%+v", doc.Settlement)
	}
	if doc.Confidentiality.Scope != "trusted_pool_not_privacy_pool" {
		t.Fatalf("confidentiality=%+v", doc.Confidentiality)
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	body := string(raw)
	if strings.Contains(body, "provider-a") || strings.Contains(body, "provider-b") {
		t.Fatalf("status leaked provider identity: %s", body)
	}
	if !strings.Contains(body, "not a Privacy Pool") {
		t.Fatalf("status missing non-privacy-pool disclosure: %s", body)
	}
	if !strings.Contains(body, "live eligible member count and route-time readiness are evaluated from the buyer-authenticated routeable registry snapshot plus live provider-serving and binary-floor state") {
		t.Fatalf("status missing live-eligibility disclosure: %s", body)
	}

	emptyLiveDoc, found, err := trustpool.BuildStatusDocumentWithLiveProviders(ctx, store, registry, root.poolID, "acct-a", generatedAt, trustpool.StatusLiveProviderSet{})
	if err != nil {
		t.Fatalf("BuildStatusDocumentWithLiveProviders empty live snapshot: %v", err)
	}
	if !found {
		t.Fatal("BuildStatusDocumentWithLiveProviders empty live snapshot found=false, want true")
	}
	if emptyLiveDoc.Pool.Readiness != "unavailable" || emptyLiveDoc.Pool.ReadinessReason != "live_provider_eligible_members_unmet" || emptyLiveDoc.Membership.CurrentEligibleMemberCount != 0 || emptyLiveDoc.Routeability.Routeable {
		t.Fatalf("empty live readiness=%q reason=%q eligible=%d routeable=%v", emptyLiveDoc.Pool.Readiness, emptyLiveDoc.Pool.ReadinessReason, emptyLiveDoc.Membership.CurrentEligibleMemberCount, emptyLiveDoc.Routeability.Routeable)
	}
}

func TestBuildStatusDocumentDoesNotFallbackToApprovalRetentionAfterManifest(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000625, 0).UTC()
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
	doc, found, err := trustpool.BuildStatusDocument(ctx, store, registry, root.poolID, "acct-a", time.Unix(1800000701, 0).UTC())
	if err != nil {
		t.Fatalf("BuildStatusDocument: %v", err)
	}
	if !found {
		t.Fatal("BuildStatusDocument found=false, want true")
	}
	if doc.Policy.RetentionPolicyID != "" ||
		doc.Policy.RetentionPolicyStatus != "unknown_policy_activation_blocked" ||
		doc.Policy.RetentionPolicyGoverningVersion != "" ||
		len(doc.Policy.RetentionPolicyFieldCategories) != 0 {
		t.Fatalf("status retention fallback=%+v, want manifest-empty activation-blocked without registry fields", doc.Policy)
	}
}

func TestBuildStatusDocumentFailsClosedOnStaleRouteableSnapshot(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000750, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	for _, e := range []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", ts.Add(5*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
	} {
		if e.EventType == trustpool.EventLifecycleChanged && e.Lifecycle == trustpool.LifecycleActive {
			insertPromotedEvent(t, ctx, db, e)
			continue
		}
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	staleState, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct stale state: %v", err)
	}
	staleRegistry, err := staleState.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry stale: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, ev("op-floor-raised", ts.Add(6*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
		e.MinBinaryVersion = "9.9.9"
	})); err != nil {
		t.Fatalf("AppendValidatedEvent floor: %v", err)
	}
	doc, found, err := trustpool.BuildStatusDocumentWithLiveProviders(ctx, store, staleRegistry, root.poolID, "acct-a", ts.Add(7*time.Second), trustpool.StatusLiveProviderSet{Providers: []trustpool.StatusLiveProvider{
		{ProviderID: "provider-a", ServingCapable: true, BinaryVersion: "1.8.33"},
	}})
	if err != nil {
		t.Fatalf("BuildStatusDocumentWithLiveProviders stale registry: %v", err)
	}
	if !found {
		t.Fatal("BuildStatusDocumentWithLiveProviders stale registry found=false, want true")
	}
	if doc.Policy.MinBinaryVersion != "9.9.9" {
		t.Fatalf("policy min_binary_version=%q, want durable raised floor", doc.Policy.MinBinaryVersion)
	}
	if doc.Pool.Readiness != "unavailable" || doc.Pool.ReadinessReason != "routeable_snapshot_stale" || doc.Routeability.Routeable || doc.Routeability.CreatorGateReason != "" {
		t.Fatalf("stale registry readiness=%q reason=%q routeable=%v creator_gate_reason=%q", doc.Pool.Readiness, doc.Pool.ReadinessReason, doc.Routeability.Routeable, doc.Routeability.CreatorGateReason)
	}
	if doc.Membership.CurrentEligibleMemberCount != 0 || doc.Membership.LiveEligibilityEvaluation != "live_provider_snapshot" {
		t.Fatalf("stale registry membership=%+v", doc.Membership)
	}
}

func TestBuildStatusDocumentCollapsesUnauthorizedAndUnknown(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000800, 0).UTC()
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
	if _, found, err := trustpool.BuildStatusDocument(ctx, store, registry, "pool-a", "acct-denied", ts); err != nil || found {
		t.Fatalf("unauthorized found=%v err=%v, want false nil", found, err)
	}
	if _, found, err := trustpool.BuildStatusDocument(ctx, store, registry, "pool-missing", "acct-a", ts); err != nil || found {
		t.Fatalf("unknown found=%v err=%v, want false nil", found, err)
	}
}

func TestBuildPublicStatusDocumentRequiresMatchingAnnouncementApproval(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800001400, 0).UTC()
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
		ev("op-active", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
	} {
		if e.EventType == trustpool.EventLifecycleChanged && e.Lifecycle == trustpool.LifecycleActive {
			insertPromotedEvent(t, ctx, db, e)
			continue
		}
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	if _, found, err := trustpool.BuildPublicStatusDocument(ctx, store, root.poolID, ts); err != nil || found {
		t.Fatalf("public status before approval found=%v err=%v, want false nil", found, err)
	}
	approval := approvePublicAnnouncement(t, store, root.poolID, manifest.ManifestCoreDigest)
	doc, found, err := trustpool.BuildPublicStatusDocument(ctx, store, root.poolID, ts)
	if err != nil {
		t.Fatalf("BuildPublicStatusDocument: %v", err)
	}
	if !found {
		t.Fatal("BuildPublicStatusDocument found=false, want true")
	}
	if doc.Pool.Visibility != "publicly_announced" || !doc.Pool.PubliclyAnnounced {
		t.Fatalf("public status pool=%+v", doc.Pool)
	}
	if doc.Pool.VisibilityGeneration == 0 {
		t.Fatalf("public status visibility generation=%d, want non-zero", doc.Pool.VisibilityGeneration)
	}
	if doc.Pool.PublicApprovalID != "" || doc.Pool.ReviewedArtifactDigest != approval.ReviewedDistributionDigest {
		t.Fatalf("public status approval binding=%+v, want redacted approval id and artifact %q", doc.Pool, approval.ReviewedDistributionDigest)
	}
	if doc.Policy.RootIssuerKeyID != "" || doc.Policy.RootIssuerKeyHash != "" || doc.Policy.CustodyEvidence != "" {
		t.Fatalf("public status policy=%+v, want root-key and custody evidence redacted", doc.Policy)
	}
	if doc.Membership.CurrentMemberCount != 0 ||
		doc.Membership.CurrentAdmittedMemberCount != 0 ||
		doc.Membership.CurrentNonRevokedMemberCount != 0 ||
		doc.Membership.RevokedMemberCount != 0 ||
		doc.Membership.AuthorizedBuyerCount != 0 {
		t.Fatalf("public status membership=%+v, want supply and buyer counts redacted", doc.Membership)
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	body := string(raw)
	if strings.Contains(body, "provider-secret") {
		t.Fatalf("public status leaked provider identity: %s", body)
	}
	if strings.Contains(body, `"creator_account_id"`) || strings.Contains(body, `"approval_record_id"`) || strings.Contains(body, `"current_approval_version"`) {
		t.Fatalf("public status leaked internal creator approval fields: %s", body)
	}
	if strings.Contains(body, `"custody_evidence"`) {
		t.Fatalf("public status leaked custody evidence: %s", body)
	}
	if !strings.Contains(body, "reviewed_distribution_artifact_digest") {
		t.Fatalf("public status missing digest-bound disclosure: %s", body)
	}

	doc, found, err = trustpool.BuildPublicStatusDocumentWithLiveProviders(ctx, store, trustpool.NewRegistry(), root.poolID, ts, trustpool.StatusLiveProviderSet{Providers: []trustpool.StatusLiveProvider{
		{ProviderID: "provider-secret", ServingCapable: true},
	}})
	if err != nil {
		t.Fatalf("BuildPublicStatusDocumentWithLiveProviders missing registry snapshot: %v", err)
	}
	if !found {
		t.Fatal("BuildPublicStatusDocumentWithLiveProviders missing registry snapshot found=false, want true")
	}
	if doc.Pool.Readiness != "unavailable" || doc.Pool.ReadinessReason != "routeable_snapshot_stale" || doc.Membership.CurrentEligibleMemberCount != 0 || doc.Routeability.Routeable {
		t.Fatalf("missing registry snapshot readiness=%q reason=%q eligible=%d routeable=%v", doc.Pool.Readiness, doc.Pool.ReadinessReason, doc.Membership.CurrentEligibleMemberCount, doc.Routeability.Routeable)
	}
}
