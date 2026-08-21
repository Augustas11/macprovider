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
			core.RetentionPolicyID = "retention-from-manifest"
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
	if !policyPredicatePresent(doc.Predicates.Enforced, "min_binary_version") {
		t.Fatalf("enforced predicates=%+v, want manifest-only min_binary_version predicate", doc.Predicates.Enforced)
	}
	if doc.Policy.RetentionPolicyID != "retention-from-manifest" || doc.Policy.RetentionPolicyStatus != "approval_category_only_not_registry_resolved" || doc.Policy.SplitExecutionStatus != "declared_not_executed" {
		t.Fatalf("policy status=%+v", doc.Policy)
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
		"public unauthenticated policy/status exposure is unavailable",
		"root issuer custody class is not yet recorded",
		"supply_mode shared",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("policy missing disclosure %q: %s", want, body)
		}
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
