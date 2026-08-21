package trustpool_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

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
	doc, found, err := trustpool.BuildStatusDocument(ctx, store, registry, root.poolID, "acct-a", generatedAt)
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
	if doc.Pool.Readiness != "unknown" || doc.Pool.ReadinessReason != "live_eligibility_not_evaluated" || doc.Routeability.Routeable {
		t.Fatalf("readiness=%q routeable=%v", doc.Pool.Readiness, doc.Routeability.Routeable)
	}
	if doc.Membership.CurrentMemberCount != 1 || doc.Membership.CurrentAdmittedMemberCount != 1 || doc.Membership.CurrentNonRevokedMemberCount != 1 || doc.Membership.CurrentEligibleMemberCount != 0 || doc.Membership.RevokedMemberCount != 1 || doc.Membership.LiveEligibilityEvaluation != "not_evaluated" {
		t.Fatalf("membership=%+v", doc.Membership)
	}
	if doc.Policy.ManifestVersion != 1 || doc.Policy.MinBinaryVersion != "1.8.33" || doc.Policy.RootIssuerKeyID == "" {
		t.Fatalf("policy=%+v", doc.Policy)
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
	if !strings.Contains(body, "live eligible member count and route-time readiness are not evaluated") {
		t.Fatalf("status missing live-eligibility disclosure: %s", body)
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
