package trustpool_test

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestAdminHandler_AppendsCandidateEventsAndRejectsActivation(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    root.poolID,
		Lifecycle: trustpool.LifecycleActive,
	}, "op-active", http.StatusConflict)

	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || snap.Generation != 6 {
		t.Fatalf("registry snapshot = %+v, want non-routeable candidate pool generation 6", snap)
	}
	if len(snap.Members) != 0 {
		t.Fatalf("candidate pool exposed routeable members: %v", snap.Members)
	}
	if !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatal("acct-allowed should be authorized after admin buyer event")
	}

	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	active := registry.Snapshot(root.poolID)
	if !active.Exists || !active.Routeable || !active.Members["provider-a"] || active.Generation != 7 {
		t.Fatalf("registry snapshot after promotion = %+v, want routeable provider-a generation 7", active)
	}
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	retry := registry.Snapshot(root.poolID)
	if retry.Generation != active.Generation || !retry.Routeable {
		t.Fatalf("idempotent promotion retry snapshot = %+v, want unchanged routeable generation %d", retry, active.Generation)
	}
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    root.poolID,
		Lifecycle: trustpool.LifecycleActive,
	}, "op-active-after-promote", http.StatusConflict)
}

func TestAdminHandler_RejectsMalformedMemberProviderID(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "bad/provider",
	}, "op-bad-provider", http.StatusBadRequest)
}

func TestAdminHandler_MalformedDurableStateClearsRouteableRegistry(t *testing.T) {
	t.Parallel()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-a",
	}, "op-buyer", http.StatusAccepted)
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	if snap := registry.Snapshot(root.poolID); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] || !registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatalf("pre-tamper snapshot = %+v buyer_auth=%v, want routeable provider-a/acct-a", snap, registry.BuyerAuthorized(root.poolID, "acct-a"))
	}
	if _, err := db.Exec(`UPDATE trustpool_manifest_acceptances SET manifest_core_digest = ? WHERE pool_id = ? AND manifest_version = ?`, strings.Repeat("a", 64), root.poolID, uint64(1)); err != nil {
		t.Fatalf("tamper manifest acceptance projection: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools", nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("GET pools status=%d body=%s, want 500", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "reconstruct_failed") {
		t.Fatalf("GET pools body=%s, want reconstruct_failed", rec.Body.String())
	}
	if snap := registry.Snapshot(root.poolID); snap.Exists || snap.Routeable || len(snap.Members) != 0 || registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatalf("post-tamper snapshot = %+v buyer_auth=%v, want fail-closed empty", snap, registry.BuyerAuthorized(root.poolID, "acct-a"))
	}
}

func TestAdminHandler_MalformedDurableStateRejectsMutationsAndClearsRegistry(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		mutate func(t *testing.T, handler http.Handler, root rootFixture)
	}{
		{
			name: "append",
			mutate: func(t *testing.T, handler http.Handler, root rootFixture) {
				t.Helper()
				postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
					EventType:  trustpool.EventMemberAdmitted,
					PoolID:     root.poolID,
					ProviderID: "provider-b",
				}, "op-member-b", http.StatusBadRequest)
			},
		},
		{
			name: "promote",
			mutate: func(t *testing.T, handler http.Handler, root rootFixture) {
				t.Helper()
				postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusBadRequest)
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			db := openTrustPoolDB(t)
			store, err := trustpool.NewStore(db)
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			registry := trustpool.NewRegistry()
			if err := registry.LoadRouteableSnapshotsAtRevision(99, []trustpool.RouteableSnapshot{
				{
					PoolID:         "pool-a",
					Members:        []string{"stale-provider"},
					BuyerAccounts:  []string{"acct-a"},
					SettlementMode: "observe",
					Routeable:      true,
					Generation:     99,
				},
			}); err != nil {
				t.Fatalf("seed stale registry: %v", err)
			}
			handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
				Store:       store,
				Registry:    registry,
				OperatorKey: "operator-secret",
			})
			root := newRootFixture(t)
			approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType:        trustpool.EventPoolCreated,
				PoolID:           root.poolID,
				CreatorAccountID: "creator-a",
				ApprovalRecordID: "approval-v1",
			}, "op-create", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType:  trustpool.EventMemberAdmitted,
				PoolID:     root.poolID,
				ProviderID: "provider-a",
			}, "op-member", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType:      trustpool.EventBuyerAuthorized,
				PoolID:         root.poolID,
				BuyerAccountID: "acct-a",
			}, "op-buyer", http.StatusAccepted)
			if _, err := db.Exec(`UPDATE trustpool_manifest_acceptances SET manifest_core_digest = ? WHERE pool_id = ? AND manifest_version = ?`, strings.Repeat("a", 64), root.poolID, uint64(1)); err != nil {
				t.Fatalf("tamper manifest acceptance projection: %v", err)
			}

			tc.mutate(t, handler, root)
			if snap := registry.Snapshot("pool-a"); snap.Exists || snap.Routeable || len(snap.Members) != 0 || registry.BuyerAuthorized("pool-a", "acct-a") {
				t.Fatalf("post-mutation snapshot = %+v buyer_auth=%v, want fail-closed empty", snap, registry.BuyerAuthorized("pool-a", "acct-a"))
			}
		})
	}
}

func TestAdminHandler_MalformedDurableStateRejectsMetadataMutationsAndClearsRegistry(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		mutate func(t *testing.T, handler http.Handler, root rootFixture, reviewedArtifactDigest string)
	}{
		{
			name: "creator",
			mutate: func(t *testing.T, handler http.Handler, _ rootFixture, _ string) {
				t.Helper()
				postAdminCreator(t, handler, "operator-secret", trustpool.CreatorApproval{
					CreatorAccountID:                  "creator-a",
					ApprovalRecordID:                  "approval-v2",
					CurrentApprovalVersion:            "approval-version-2",
					PublicDisplayName:                 "Creator A",
					LegalSupportContact:               "legal@example.test",
					BillingContact:                    "billing@example.test",
					EmergencyNotificationEndpoint:     "https://example.test/emergency",
					AcknowledgedMaxResponseTime:       "15m",
					AllowedProductCategory:            "design-partner",
					DataRetentionCategory:             "standard",
					SupportOwner:                      "ops",
					AllowedLaunchEnvironment:          "candidate",
					CreatorAgreementID:                "agreement-v2",
					CreatorAgreementVersion:           "v2",
					CreatorAgreementExpiresAtUTC:      time.Now().Add(23 * time.Hour),
					CreatorAgreementGraceEndsAtUTC:    time.Now().Add(24 * time.Hour),
					PricingScheduleID:                 "pricing-v2",
					PricingScheduleVersion:            "v2",
					ProhibitedClaimAcknowledgmentHash: hexDigest("prohibited-v2"),
					BuyerDisclosureCommitmentHash:     hexDigest("buyer-disclosure-v2"),
					ApprovalCriteriaHash:              hexDigest("criteria-v2"),
					ApprovedBy:                        "operator-a",
					ApprovedAtUTC:                     testAdminTS(20),
					Status:                            trustpool.CreatorStatusEnabled,
				}, http.StatusBadRequest)
			},
		},
		{
			name: "creator_idempotent_replay",
			mutate: func(t *testing.T, handler http.Handler, _ rootFixture, _ string) {
				t.Helper()
				postAdminCreator(t, handler, "operator-secret", validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", testAdminTS(86400), trustpool.CreatorStatusEnabled), http.StatusBadRequest)
			},
		},
		{
			name: "nonce",
			mutate: func(t *testing.T, handler http.Handler, _ rootFixture, _ string) {
				t.Helper()
				postAdminRootRegistrationNonce(t, handler, "operator-secret", trustpool.RootRegistrationNonceIssue{
					OperationID:            "op-nonce-after-tamper",
					CreatorAccountID:       "creator-a",
					ApprovalRecordID:       "approval-v1",
					CurrentApprovalVersion: "approval-version-1",
					LaunchEnvironment:      "candidate",
					ExpiresAtUTC:           testAdminTS(7200),
				}, http.StatusBadRequest)
			},
		},
		{
			name: "reviewed_artifact",
			mutate: func(t *testing.T, handler http.Handler, root rootFixture, reviewedArtifactDigest string) {
				t.Helper()
				postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
					OperationID:                "op-reviewed-after-tamper",
					ManifestCoreDigest:         signedManifest(t, "op-manifest-unused", testAdminTS(99), root.poolID, 1, root).ManifestCoreDigest,
					ReviewedDistributionDigest: reviewedArtifactDigest,
					ArtifactURI:                "https://example.test/reviewed-after-tamper.json",
					ClaimControlDigest:         hexDigest("claims-after-tamper"),
					ReviewedBy:                 "operator-a",
					ReviewedAtUTC:              testAdminTS(21),
				}, http.StatusBadRequest)
			},
		},
		{
			name: "public_announcement",
			mutate: func(t *testing.T, handler http.Handler, root rootFixture, reviewedArtifactDigest string) {
				t.Helper()
				postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
					OperationID:                "op-public-after-tamper",
					ManifestCoreDigest:         signedManifest(t, "op-manifest-unused", testAdminTS(99), root.poolID, 1, root).ManifestCoreDigest,
					ReviewedDistributionDigest: reviewedArtifactDigest,
					ApprovalRecordID:           "public-after-tamper",
					ApprovedBy:                 "operator-a",
					ApprovedAtUTC:              testAdminTS(22),
				}, http.StatusBadRequest)
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			db := openTrustPoolDB(t)
			store, err := trustpool.NewStore(db)
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			registry := trustpool.NewRegistry()
			handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
				Store:       store,
				Registry:    registry,
				OperatorKey: "operator-secret",
			})
			root := newRootFixture(t)
			approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", testAdminTS(86400), trustpool.CreatorStatusEnabled)
			manifest := signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType:        trustpool.EventPoolCreated,
				PoolID:           root.poolID,
				CreatorAccountID: "creator-a",
				ApprovalRecordID: "approval-v1",
			}, "op-create", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", manifest, "op-manifest", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType:  trustpool.EventMemberAdmitted,
				PoolID:     root.poolID,
				ProviderID: "provider-a",
			}, "op-member", http.StatusAccepted)
			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
				EventType:      trustpool.EventBuyerAuthorized,
				PoolID:         root.poolID,
				BuyerAccountID: "acct-a",
			}, "op-buyer", http.StatusAccepted)
			if err := registry.LoadRouteableSnapshotsAtRevision(99, []trustpool.RouteableSnapshot{
				{
					PoolID:         root.poolID,
					Members:        []string{"stale-provider"},
					BuyerAccounts:  []string{"acct-a"},
					SettlementMode: "observe",
					Routeable:      true,
					Generation:     99,
				},
			}); err != nil {
				t.Fatalf("seed stale registry: %v", err)
			}
			reviewedArtifactDigest := hexDigest("reviewed-artifact-after-tamper")
			if _, err := db.Exec(`UPDATE trustpool_manifest_acceptances SET manifest_core_digest = ? WHERE pool_id = ? AND manifest_version = ?`, strings.Repeat("a", 64), root.poolID, uint64(1)); err != nil {
				t.Fatalf("tamper manifest acceptance projection: %v", err)
			}

			tc.mutate(t, handler, root, reviewedArtifactDigest)
			if snap := registry.Snapshot(root.poolID); snap.Exists || snap.Routeable || len(snap.Members) != 0 || registry.BuyerAuthorized(root.poolID, "acct-a") {
				t.Fatalf("post-metadata mutation snapshot = %+v buyer_auth=%v, want fail-closed empty", snap, registry.BuyerAuthorized(root.poolID, "acct-a"))
			}
		})
	}
}

func TestAdminHandler_PromoteRejectsMissingPrecondition(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)

	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+root.poolID+"/promote", nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	req.Header.Set("Idempotency-Key", "op-promote")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("promote status=%d body=%s, want 409", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var body struct {
		Error struct {
			Code   string `json:"code"`
			Reason string `json:"reason"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode promotion error: %v", err)
	}
	if body.Error.Code != "promotion_precondition_failed" || body.Error.Reason != "root_issuer_missing" {
		t.Fatalf("promotion error = %+v, want root_issuer_missing precondition", body.Error)
	}
}

func TestAdminHandler_PromoteRetryRefreshesStaleRegistry(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)

	if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID: "op-promote",
		PoolID:      root.poolID,
	}); err != nil {
		t.Fatalf("direct PromotePool: %v", err)
	}
	stale := registry.Snapshot(root.poolID)
	if stale.Routeable {
		t.Fatalf("registry unexpectedly routeable before retry refresh: %+v", stale)
	}
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	active := registry.Snapshot(root.poolID)
	if !active.Exists || !active.Routeable || !active.Members["provider-a"] {
		t.Fatalf("registry snapshot after idempotent retry = %+v, want routeable provider-a", active)
	}
}

func TestAdminHandler_RestrictiveLifecyclePausesRouteablePool(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root
	if snap := registry.Snapshot(root.poolID); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] || !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatalf("pre-pause snapshot = %+v buyer_auth=%v, want routeable provider-a/acct-allowed", snap, registry.BuyerAuthorized(root.poolID, "acct-allowed"))
	}

	rec := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
	var body struct {
		Pool struct {
			Lifecycle string `json:"lifecycle"`
			Routeable bool   `json:"routeable"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode lifecycle response: %v", err)
	}
	if body.Pool.Lifecycle != trustpool.LifecyclePaused || body.Pool.Routeable {
		t.Fatalf("lifecycle response pool=%+v, want paused/non-routeable", body.Pool)
	}
	paused := registry.Snapshot(root.poolID)
	if !paused.Exists || paused.Routeable || len(paused.Members) != 0 || !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatalf("paused snapshot = %+v buyer_auth=%v, want fail-closed members with buyer allowlist retained", paused, registry.BuyerAuthorized(root.poolID, "acct-allowed"))
	}

	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
	retry := registry.Snapshot(root.poolID)
	if retry.Generation != paused.Generation || retry.Routeable || len(retry.Members) != 0 {
		t.Fatalf("idempotent pause retry snapshot = %+v, want unchanged non-routeable generation %d", retry, paused.Generation)
	}
}

func TestAdminHandler_SignedLifecyclePausesRouteablePool(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root
	if snap := registry.Snapshot(root.poolID); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] {
		t.Fatalf("pre-signed-pause snapshot = %+v, want routeable provider-a", snap)
	}

	rec := postAdminSignedLifecycle(t, routeable.store, handler, "", root, "op-signed-pause", trustpool.LifecyclePaused, "signed incident", false, http.StatusAccepted)
	var body struct {
		Event struct {
			Lifecycle         string `json:"lifecycle"`
			SignedControl     string `json:"signed_control"`
			ControlSignatures string `json:"control_signatures"`
		} `json:"event"`
		Pool struct {
			Lifecycle string `json:"lifecycle"`
			Routeable bool   `json:"routeable"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode signed lifecycle response: %v", err)
	}
	if body.Event.Lifecycle != trustpool.LifecyclePaused || body.Event.SignedControl == "" || body.Event.ControlSignatures == "" {
		t.Fatalf("signed lifecycle event=%+v, want paused with persisted proof", body.Event)
	}
	if body.Pool.Lifecycle != trustpool.LifecyclePaused || body.Pool.Routeable {
		t.Fatalf("signed lifecycle pool=%+v, want paused/non-routeable", body.Pool)
	}
	paused := registry.Snapshot(root.poolID)
	if !paused.Exists || paused.Routeable || len(paused.Members) != 0 || !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatalf("signed paused snapshot = %+v buyer_auth=%v, want fail-closed members with buyer allowlist retained", paused, registry.BuyerAuthorized(root.poolID, "acct-allowed"))
	}
}

func TestAdminHandler_SignedRevokeImmediateRevokesProviderAndBumpsGeneration(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root
	before := registry.Snapshot(root.poolID)
	if !before.Exists || !before.Routeable || !before.Members["provider-a"] {
		t.Fatalf("pre-revoke snapshot = %+v, want routeable provider-a", before)
	}

	revokeBody := signedLifecycleRequestBodyWithTarget(t, routeable.store, root, "op-revoke-immediate", poolmanifest.EmergencyLifecycleRevokeImmediate, "provider-a", "provider compromise", false)
	rec := postAdminSignedLifecycleBody(t, handler, "", root.poolID, revokeBody, "", http.StatusAccepted)
	var body struct {
		Event struct {
			EventType         string `json:"event_type"`
			ProviderID        string `json:"provider_id"`
			SignedControl     string `json:"signed_control"`
			ControlSignatures string `json:"control_signatures"`
		} `json:"event"`
		Pool struct {
			Lifecycle           string   `json:"lifecycle"`
			Members             []string `json:"members"`
			Revoked             []string `json:"revoked"`
			Routeable           bool     `json:"routeable"`
			RouteableGeneration uint64   `json:"routeable_generation"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode signed revoke response: %v", err)
	}
	if body.Event.EventType != trustpool.EventMemberRevoked || body.Event.ProviderID != "provider-a" || body.Event.SignedControl == "" || body.Event.ControlSignatures == "" {
		t.Fatalf("signed revoke event=%+v, want proof-bearing member_revoked for provider-a", body.Event)
	}
	if body.Pool.Lifecycle != trustpool.LifecycleActive || body.Pool.Routeable || len(body.Pool.Members) != 0 || len(body.Pool.Revoked) != 1 || body.Pool.Revoked[0] != "provider-a" {
		t.Fatalf("signed revoke pool=%+v, want active but non-routeable under min-member gate with provider-a revoked", body.Pool)
	}
	after := registry.Snapshot(root.poolID)
	if !after.Exists || after.Routeable || len(after.Members) != 0 || after.Generation <= before.Generation || registry.BuyerAuthorized(root.poolID, "acct-allowed") != true {
		t.Fatalf("post-revoke snapshot = %+v buyer_auth=%v, want advanced fail-closed snapshot with buyer auth retained", after, registry.BuyerAuthorized(root.poolID, "acct-allowed"))
	}

	postAdminSignedLifecycleBody(t, handler, "", root.poolID, revokeBody, "", http.StatusAccepted)
	retry := registry.Snapshot(root.poolID)
	if retry.Generation != after.Generation || retry.Routeable || len(retry.Members) != 0 {
		t.Fatalf("idempotent signed revoke retry snapshot = %+v, want unchanged generation %d", retry, after.Generation)
	}
}

func TestAdminHandler_SignedLifecycleRetireRequiresDeliveryDrain(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root

	postAdminSignedLifecycle(t, routeable.store, handler, "", root, "op-signed-drain", trustpool.LifecycleDraining, "signed drain", false, http.StatusAccepted)
	endDelivery := registry.BeginPoolDelivery(root.poolID)
	blocked := postAdminSignedLifecycle(t, routeable.store, handler, "", root, "op-signed-retire-blocked", trustpool.LifecycleRetired, "signed retire", false, http.StatusConflict)
	var blockedBody struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(blocked.Body.Bytes(), &blockedBody); err != nil {
		t.Fatalf("decode signed blocked retire response: %v", err)
	}
	if blockedBody.Error.Code != "delivery_drain_pending" {
		t.Fatalf("signed blocked retire code=%q, want delivery_drain_pending", blockedBody.Error.Code)
	}
	if got := registry.ActivePoolDeliveries(root.poolID); got != 1 {
		t.Fatalf("active deliveries after blocked retire=%d want 1", got)
	}
	endDelivery()

	postAdminSignedLifecycle(t, routeable.store, handler, "", root, "op-signed-retire", trustpool.LifecycleRetired, "signed retire", false, http.StatusAccepted)
	retired := registry.Snapshot(root.poolID)
	if !retired.Exists || retired.Routeable || len(retired.Members) != 0 {
		t.Fatalf("signed retired snapshot = %+v, want non-routeable empty members", retired)
	}
}

func TestAdminHandler_SignedLifecycleRejectsBadSignatureWithoutRegistryMutation(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root
	before := registry.Snapshot(root.poolID)
	if !before.Exists || !before.Routeable || !before.Members["provider-a"] {
		t.Fatalf("pre-bad-signature snapshot = %+v, want routeable provider-a", before)
	}

	postAdminSignedLifecycle(t, routeable.store, handler, "operator-secret", root, "op-bad-signature-pause", trustpool.LifecyclePaused, "signed incident", true, http.StatusBadRequest)
	after := registry.Snapshot(root.poolID)
	if !after.Exists || !after.Routeable || !after.Members["provider-a"] || after.Generation != before.Generation {
		t.Fatalf("post-bad-signature snapshot = %+v, want unchanged routeable generation %d", after, before.Generation)
	}
}

func TestAdminHandler_SignedLifecycleIdempotentRetryDoesNotReverifyCurrentManifest(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	handler := routeable.handler
	root := routeable.root

	body := signedLifecycleRequestBody(t, routeable.store, root, "op-signed-idempotent", trustpool.LifecyclePaused, "signed incident", false)
	postAdminSignedLifecycleBody(t, handler, "operator-secret", root.poolID, body, "", http.StatusAccepted)
	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-after-signed-pause", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
	postAdminSignedLifecycleBody(t, handler, "operator-secret", root.poolID, body, "", http.StatusAccepted)
}

func TestAdminHandler_SignedLifecycleRejectsHeaderOnlyOperationID(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	handler := routeable.handler
	root := routeable.root
	body := signedLifecycleRequestBody(t, routeable.store, root, "op-header-only", trustpool.LifecyclePaused, "signed incident", false)
	control := body["control"].(map[string]any)
	control["operation_id"] = ""
	postAdminSignedLifecycleBody(t, handler, "operator-secret", root.poolID, body, "op-header-only", http.StatusBadRequest)
}

func TestAdminHandler_PromoteReactivatesPausedPoolAfterPreflight(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root

	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
	paused := registry.Snapshot(root.poolID)
	if !paused.Exists || paused.Routeable || len(paused.Members) != 0 {
		t.Fatalf("paused snapshot = %+v, want non-routeable empty members", paused)
	}

	rec := postAdminPromote(t, handler, "operator-secret", root.poolID, "op-resume", http.StatusAccepted)
	var body struct {
		Pool struct {
			Lifecycle           string `json:"lifecycle"`
			Routeable           bool   `json:"routeable"`
			RouteableGeneration uint64 `json:"routeable_generation"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode reactivation response: %v", err)
	}
	if body.Pool.Lifecycle != trustpool.LifecycleActive || !body.Pool.Routeable || body.Pool.RouteableGeneration != paused.Generation+1 {
		t.Fatalf("reactivation response pool=%+v, want active routeable generation %d", body.Pool, paused.Generation+1)
	}
	active := registry.Snapshot(root.poolID)
	if !active.Exists || !active.Routeable || !active.Members["provider-a"] || !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatalf("reactivated snapshot = %+v buyer_auth=%v, want routeable provider-a/acct-allowed", active, registry.BuyerAuthorized(root.poolID, "acct-allowed"))
	}

	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-resume", http.StatusAccepted)
	retry := registry.Snapshot(root.poolID)
	if retry.Generation != active.Generation || !retry.Routeable || !retry.Members["provider-a"] {
		t.Fatalf("idempotent resume retry snapshot = %+v, want unchanged routeable generation %d", retry, active.Generation)
	}
}

func TestAdminHandler_RestrictiveLifecycleDrainsAndRetiresRouteablePool(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root

	rec := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-drain", trustpool.LifecycleDraining, "drain", http.StatusAccepted)
	var body struct {
		Pool struct {
			Lifecycle string `json:"lifecycle"`
			Routeable bool   `json:"routeable"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode drain response: %v", err)
	}
	if body.Pool.Lifecycle != trustpool.LifecycleDraining || body.Pool.Routeable {
		t.Fatalf("drain response pool=%+v, want draining/non-routeable", body.Pool)
	}
	draining := registry.Snapshot(root.poolID)
	if !draining.Exists || draining.Routeable || len(draining.Members) != 0 {
		t.Fatalf("draining snapshot = %+v, want non-routeable empty members", draining)
	}

	endDelivery := registry.BeginPoolDelivery(root.poolID)
	blocked := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-blocked", trustpool.LifecycleRetired, "retire", http.StatusConflict)
	var blockedBody struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(blocked.Body.Bytes(), &blockedBody); err != nil {
		t.Fatalf("decode blocked retire response: %v", err)
	}
	if blockedBody.Error.Code != "delivery_drain_pending" {
		t.Fatalf("blocked retire code=%q, want delivery_drain_pending", blockedBody.Error.Code)
	}
	endDelivery()

	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
	retired := registry.Snapshot(root.poolID)
	if !retired.Exists || retired.Routeable || len(retired.Members) != 0 {
		t.Fatalf("retired snapshot = %+v, want non-routeable empty members", retired)
	}
	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
	retry := registry.Snapshot(root.poolID)
	if retry.Generation != retired.Generation || retry.Routeable || len(retry.Members) != 0 {
		t.Fatalf("idempotent retire retry snapshot = %+v, want unchanged non-routeable generation %d", retry, retired.Generation)
	}
}

func TestAdminHandler_RestrictiveLifecycleRejectsRouteableRetireUntilDrained(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	registry := routeable.registry
	handler := routeable.handler
	root := routeable.root

	endDelivery := registry.BeginPoolDelivery(root.poolID)
	blocked := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-blocked", trustpool.LifecycleRetired, "retire", http.StatusConflict)
	var blockedBody struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(blocked.Body.Bytes(), &blockedBody); err != nil {
		t.Fatalf("decode direct blocked retire response: %v", err)
	}
	if blockedBody.Error.Code != "delivery_drain_pending" {
		t.Fatalf("direct blocked retire code=%q, want delivery_drain_pending", blockedBody.Error.Code)
	}
	endDelivery()

	blocked = postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-routeable-blocked", trustpool.LifecycleRetired, "retire", http.StatusConflict)
	if err := json.Unmarshal(blocked.Body.Bytes(), &blockedBody); err != nil {
		t.Fatalf("decode routeable blocked retire response: %v", err)
	}
	if blockedBody.Error.Code != "delivery_drain_pending" {
		t.Fatalf("routeable blocked retire code=%q, want delivery_drain_pending", blockedBody.Error.Code)
	}

	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-drain-before-retire", trustpool.LifecycleDraining, "drain", http.StatusAccepted)
	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
	retired := registry.Snapshot(root.poolID)
	if !retired.Exists || retired.Routeable || len(retired.Members) != 0 {
		t.Fatalf("retired snapshot = %+v, want non-routeable empty members", retired)
	}
}

func TestAdminHandler_RestrictiveLifecycleRejectsActivationAndInvalidTransition(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)

	rec := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-active", trustpool.LifecycleActive, "manual activation", http.StatusConflict)
	var activeErr struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &activeErr); err != nil {
		t.Fatalf("decode activation error: %v", err)
	}
	if activeErr.Error.Code != "activation_requires_promotion" {
		t.Fatalf("activation error code=%q, want activation_requires_promotion", activeErr.Error.Code)
	}
	rec = postAdminLifecycleWithIDs(t, handler, "operator-secret", root.poolID, "body-active", "header-active", trustpool.LifecycleActive, "manual activation", http.StatusConflict)
	if err := json.Unmarshal(rec.Body.Bytes(), &activeErr); err != nil {
		t.Fatalf("decode conflicting activation error: %v", err)
	}
	if activeErr.Error.Code != "operation_conflict" {
		t.Fatalf("conflicting activation error code=%q, want operation_conflict", activeErr.Error.Code)
	}
	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "prelaunch pause", http.StatusBadRequest)
	if snap := registry.Snapshot(root.poolID); snap.Exists || snap.Routeable || len(snap.Members) != 0 {
		t.Fatalf("post-invalid-transition snapshot = %+v, want fail-closed empty registry", snap)
	}
}

func TestAdminHandler_AppendEventRejectsForgedSignedLifecycleProof(t *testing.T) {
	t.Parallel()
	routeable := newRouteableAdminPool(t)
	handler := routeable.handler
	root := routeable.root

	cases := []struct {
		name        string
		operationID string
		event       trustpool.DurableEvent
	}{
		{
			name:        "lifecycle",
			operationID: "op-forged-lifecycle",
			event: trustpool.DurableEvent{
				EventType:         trustpool.EventLifecycleChanged,
				PoolID:            root.poolID,
				Lifecycle:         trustpool.LifecyclePaused,
				Reason:            "forged",
				SignedControl:     `{"operation_id":"op-forged-lifecycle"}`,
				ControlSignatures: `[{"key_id":"k1","signature":"forged"}]`,
			},
		},
		{
			name:        "member_revoked",
			operationID: "op-forged-revoke",
			event: trustpool.DurableEvent{
				EventType:         trustpool.EventMemberRevoked,
				PoolID:            root.poolID,
				ProviderID:        "provider-a",
				Reason:            "forged",
				SignedControl:     `{"operation_id":"op-forged-revoke"}`,
				ControlSignatures: `[{"key_id":"k1","signature":"forged"}]`,
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			postAdminEvent(t, handler, "operator-secret", tc.event, tc.operationID, http.StatusBadRequest)
		})
	}
	if snap := routeable.registry.Snapshot(root.poolID); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] {
		t.Fatalf("forged proof mutated registry: %+v", snap)
	}
}

func TestAdminHandler_RejectsUnsignedManifest(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:                      trustpool.EventManifestAccepted,
		PoolID:                         root.poolID,
		ManifestVersion:                1,
		ManifestCoreDigest:             hexDigest("digest-a"),
		RootIssuerKeyID:                "root-key-1",
		RootIssuerPublicKeyFingerprint: root.fingerprint,
	}, "op-manifest-unsigned", http.StatusBadRequest)
}

func TestAdminHandler_RejectsManifestPromiseOverclaim(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	manifest := signedManifest(t, "op-manifest-overclaim", testAdminTS(2), root.poolID, 1, root)
	manifest.ManifestSnapshot = base64.StdEncoding.EncodeToString([]byte(`{"buyer_visible_claim":"Privacy Pool with anonymous routing"}`))
	body, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator-secret")
	req.Header.Set("Idempotency-Key", "op-manifest-overclaim")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST overclaim status=%d body=%s, want 400", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var got struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode overclaim response: %v", err)
	}
	if got.Error.Code != "prohibited_promise_claim" {
		t.Fatalf("error code=%q body=%s, want prohibited_promise_claim", got.Error.Code, rec.Body.String())
	}
}

func TestAdminHandler_CreatorApprovalEndpointRefreshesRegistry(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approval := approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		{
			EventType:        trustpool.EventPoolCreated,
			PoolID:           root.poolID,
			CreatorAccountID: "creator-a",
			ApprovalRecordID: "approval-v1",
		},
		signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", testAdminTS(2), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.MinBinaryVersion = "1.8.33"
		}),
		{
			EventType:  trustpool.EventMemberAdmitted,
			PoolID:     root.poolID,
			ProviderID: "provider-a",
		},
		{
			EventType:      trustpool.EventBuyerAuthorized,
			PoolID:         root.poolID,
			BuyerAccountID: "acct-a",
		},
		{
			EventType: trustpool.EventLifecycleChanged,
			PoolID:    root.poolID,
			Lifecycle: trustpool.LifecycleActive,
		},
	}
	for i, e := range events {
		e.OperationID = []string{"op-create", "op-root", "op-manifest", "op-member", "op-buyer", "op-active"}[i]
		e.TimestampUTC = testAdminTS(int64(i))
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
	if err := registry.LoadRouteableSnapshotsAtRevision(state.Revision, state.RouteableSnapshots()); err != nil {
		t.Fatalf("initial registry load: %v", err)
	}
	if snap := registry.Snapshot(root.poolID); !snap.Routeable {
		t.Fatalf("initial snapshot = %+v, want routeable", snap)
	}
	approval.Status = trustpool.CreatorStatusSuspended
	approval.SuspensionReason = "agreement_hold"
	postAdminCreator(t, handler, "operator-secret", approval, http.StatusAccepted)
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || len(snap.Members) != 0 {
		t.Fatalf("snapshot after creator suspension = %+v, want present but non-routeable", snap)
	}
	suspendedGeneration := snap.Generation
	postAdminCreator(t, handler, "operator-secret", approval, http.StatusAccepted)
	retrySnap := registry.Snapshot(root.poolID)
	if retrySnap.Generation != suspendedGeneration {
		t.Fatalf("duplicate creator approval generation = %d, want unchanged %d", retrySnap.Generation, suspendedGeneration)
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/creators/creator-a", nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET creator status=%d body=%s, want 200", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)

	req = httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID, nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET pool status=%d body=%s, want 200", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var body struct {
		Pool struct {
			CreatorGateReason     string `json:"creator_gate_reason"`
			RouteableGeneration   uint64 `json:"routeable_generation"`
			RouteGateCheckedAtUTC string `json:"route_gate_checked_at_utc"`
			MinBinaryVersion      string `json:"min_binary_version"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode GET pool body: %v", err)
	}
	if body.Pool.CreatorGateReason != "creator_suspended" || body.Pool.RouteableGeneration == 0 || body.Pool.RouteGateCheckedAtUTC == "" {
		t.Fatalf("GET pool gate fields = %+v, want suspended gate status", body.Pool)
	}
	if body.Pool.MinBinaryVersion != "1.8.33" {
		t.Fatalf("GET pool min_binary_version = %q, want manifest-only floor", body.Pool.MinBinaryVersion)
	}
}

func TestAdminHandler_PublicAnnouncementApprovalIsDigestBound(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "public", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssueInEnvironment(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonceInEnvironment(t, store, "creator-a", "approval-v1", "public", testAdminTS(3600)), root, "public"), "op-root", http.StatusAccepted)
	manifest := signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root)
	postAdminEvent(t, handler, "operator-secret", manifest, "op-manifest", http.StatusAccepted)
	reviewedArtifactDigest := hexDigest("reviewed-artifact-v1")

	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-mismatch",
		PoolID:                     "different-pool",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(3),
	}, http.StatusBadRequest)
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-stale",
		ManifestCoreDigest:         hexDigest("stale-manifest"),
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(3),
	}, http.StatusConflict)
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-before-review",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(3),
	}, http.StatusConflict)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID,
		ClaimControlDigest:         hexDigest("claim-control-v1"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(3),
	}, http.StatusAccepted)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID,
		ClaimControlDigest:         hexDigest("claim-control-v1"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(3),
	}, http.StatusAccepted)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-same-content",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID,
		ClaimControlDigest:         hexDigest("claim-control-v1"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(3),
	}, http.StatusConflict)
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-reviewed-artifact-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusConflict)
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-reviewed-artifact-v1", http.StatusConflict)
	rec := postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusAccepted)
	var body struct {
		PublicAnnouncement trustpool.PublicAnnouncementApproval `json:"public_announcement"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode public announcement response: %v", err)
	}
	if body.PublicAnnouncement.OperationID != "op-public-v1" ||
		body.PublicAnnouncement.PoolID != root.poolID ||
		body.PublicAnnouncement.ManifestCoreDigest != manifest.ManifestCoreDigest ||
		body.PublicAnnouncement.ReviewedDistributionDigest != reviewedArtifactDigest ||
		body.PublicAnnouncement.PublicAnnouncementRevision != 1 {
		t.Fatalf("public announcement response=%+v", body.PublicAnnouncement)
	}
	retry := postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusAccepted)
	var retryBody struct {
		PublicAnnouncement trustpool.PublicAnnouncementApproval `json:"public_announcement"`
	}
	if err := json.Unmarshal(retry.Body.Bytes(), &retryBody); err != nil {
		t.Fatalf("decode public announcement retry response: %v", err)
	}
	if retryBody.PublicAnnouncement.PublicAnnouncementRevision != 1 {
		t.Fatalf("public announcement retry revision=%d, want 1", retryBody.PublicAnnouncement.PublicAnnouncementRevision)
	}
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: hexDigest("different-reviewed-artifact"),
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusConflict)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: hexDigest("reviewed-artifact-v2"),
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID + "/v2",
		ClaimControlDigest:         hexDigest("claim-control-v2"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(5),
	}, http.StatusConflict)
	auditReq := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID+"/audit", nil)
	auditReq.Header.Set("Authorization", "Bearer operator-secret")
	auditRec := httptest.NewRecorder()
	handler.ServeHTTP(auditRec, auditReq)
	if auditRec.Code != http.StatusOK {
		t.Fatalf("GET audit status=%d body=%s, want 200", auditRec.Code, auditRec.Body.String())
	}
	var auditBody struct {
		ReviewedDistributionArtifactHistory []trustpool.ReviewedDistributionArtifact `json:"reviewed_distribution_artifact_history"`
		PublicAnnouncementHistory           []trustpool.PublicAnnouncementApproval   `json:"public_announcement_history"`
	}
	if err := json.Unmarshal(auditRec.Body.Bytes(), &auditBody); err != nil {
		t.Fatalf("decode audit response: %v", err)
	}
	if len(auditBody.ReviewedDistributionArtifactHistory) != 1 || auditBody.ReviewedDistributionArtifactHistory[0].OperationID != "op-reviewed-artifact-v1" {
		t.Fatalf("reviewed artifact history=%+v, want one immutable op-reviewed-artifact-v1 row", auditBody.ReviewedDistributionArtifactHistory)
	}
	if len(auditBody.PublicAnnouncementHistory) != 1 || auditBody.PublicAnnouncementHistory[0].OperationID != "op-public-v1" {
		t.Fatalf("public announcement history=%+v, want one immutable op-public-v1 row", auditBody.PublicAnnouncementHistory)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(t.Context(), store, root.poolID, testAdminTS(5)); err != nil || !found {
		t.Fatalf("BuildPublicPolicyDocument found=%v err=%v, want true nil", found, err)
	}
}

func TestAdminHandler_IssuesRootNonceAndExportsPoolArtifacts(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	nonceBody, err := json.Marshal(trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	})
	if err != nil {
		t.Fatalf("marshal nonce issue: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(nonceBody))
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST nonce status=%d body=%s, want 201", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var nonceResp struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &nonceResp); err != nil {
		t.Fatalf("decode nonce response: %v", err)
	}
	if nonceResp.RootRegistrationNonce.Nonce == "" || nonceResp.RootRegistrationNonce.CreatorAccountID != "creator-a" {
		t.Fatalf("nonce response = %+v", nonceResp.RootRegistrationNonce)
	}
	retryReq := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(nonceBody))
	retryReq.Header.Set("Authorization", "Bearer operator-secret")
	retryRec := httptest.NewRecorder()
	handler.ServeHTTP(retryRec, retryReq)
	if retryRec.Code != http.StatusCreated {
		t.Fatalf("POST nonce retry status=%d body=%s, want 201", retryRec.Code, retryRec.Body.String())
	}
	var retryNonceResp struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(retryRec.Body.Bytes(), &retryNonceResp); err != nil {
		t.Fatalf("decode retry nonce response: %v", err)
	}
	if retryNonceResp.RootRegistrationNonce.Nonce != nonceResp.RootRegistrationNonce.Nonce {
		t.Fatalf("retry nonce = %q, want original %q", retryNonceResp.RootRegistrationNonce.Nonce, nonceResp.RootRegistrationNonce.Nonce)
	}

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonceResp.RootRegistrationNonce, root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-a",
	}, "op-buyer", http.StatusAccepted)

	root2 := newRootFixture(t)
	nonceBody2, err := json.Marshal(trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-2",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(7200),
	})
	if err != nil {
		t.Fatalf("marshal second nonce issue: %v", err)
	}
	req2 := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(nonceBody2))
	req2.Header.Set("Authorization", "Bearer operator-secret")
	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusCreated {
		t.Fatalf("POST second nonce status=%d body=%s, want 201", rec2.Code, rec2.Body.String())
	}
	var nonceResp2 struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(rec2.Body.Bytes(), &nonceResp2); err != nil {
		t.Fatalf("decode second nonce response: %v", err)
	}
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root2.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create-2", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root-2", testAdminTS(3), root2.poolID, "creator-a", "approval-v1", nonceResp2.RootRegistrationNonce, root2), "op-root-2", http.StatusAccepted)

	for _, tc := range []struct {
		path        string
		wants       []string
		wantsAbsent []string
	}{
		{
			path: "/admin/trust-pools/pools/" + root.poolID + "/audit",
			wants: []string{
				`"events"`,
				`"creator_approval"`,
				`"root_registration_nonces"`,
				`"nonce_sha256"`,
				`"operation_id":"op-nonce"`,
			},
			wantsAbsent: []string{`op-nonce-2`},
		},
		{path: "/admin/trust-pools/pools/" + root.poolID + "/health", wants: []string{`"health_events"`}},
		{
			path: "/admin/trust-pools/pools/" + root.poolID + "/distribution",
			wants: []string{
				`"distribution_package"`,
				`"candidate_only":true`,
				`"production_ready":false`,
				`"launch_environment":"candidate"`,
			},
		},
	} {
		req := httptest.NewRequest(http.MethodGet, tc.path, nil)
		req.Header.Set("Authorization", "Bearer operator-secret")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s status=%d body=%s, want 200", tc.path, rec.Code, rec.Body.String())
		}
		assertAdminSchemaVersion(t, rec)
		if got := rec.Header().Get("Cache-Control"); got != "no-store" {
			t.Fatalf("GET %s Cache-Control=%q, want no-store", tc.path, got)
		}
		for _, want := range tc.wants {
			if !strings.Contains(rec.Body.String(), want) {
				t.Fatalf("GET %s body=%s missing %s", tc.path, rec.Body.String(), want)
			}
		}
		for _, wantAbsent := range tc.wantsAbsent {
			if strings.Contains(rec.Body.String(), wantAbsent) {
				t.Fatalf("GET %s body=%s unexpectedly included %s", tc.path, rec.Body.String(), wantAbsent)
			}
		}
	}
}

func TestAdminHandler_RejectsUnauthorized(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{Store: store, Registry: trustpool.NewRegistry(), OperatorKey: "operator-secret"})
	body, _ := json.Marshal(trustpool.DurableEvent{EventType: trustpool.EventPoolCreated, PoolID: "pool-a"})
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d body=%s, want 401", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
}

func TestAdminHandler_CreatorSurfaceAllowsOwnedCandidateLaunch(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         registry,
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	postCreatorEvent(t, handler, "creator-token-a", creatorPoolCreatedEvent(t, root, "approval-v1"), "op-create", http.StatusAccepted)
	existing, ok, err := store.ExistingEvent(t.Context(), "op-create")
	if err != nil {
		t.Fatalf("ExistingEvent: %v", err)
	}
	if !ok || existing.CreatorCredentialID != "creator-a-cred" {
		t.Fatalf("stored create credential=%q ok=%v, want creator-a-cred", existing.CreatorCredentialID, ok)
	}
	nonce := postCreatorRootRegistrationNonce(t, handler, "creator-token-a", trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	}, http.StatusCreated)
	if nonce.CreatorCredentialID != "creator-a-cred" {
		t.Fatalf("nonce creator credential id = %q, want creator-a-cred", nonce.CreatorCredentialID)
	}
	postCreatorEvent(t, handler, "creator-token-a", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonce, root), "op-root", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)

	state, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || pool.CreatorAccountID != "creator-a" || !pool.Members["provider-a"] || !pool.BuyerAccounts["acct-allowed"] {
		t.Fatalf("pool state = %+v, want creator-owned member and buyer authorization", pool)
	}
	if snap := registry.Snapshot(root.poolID); !snap.Exists || snap.Routeable || snap.Generation != 6 {
		t.Fatalf("candidate registry snapshot = %+v, want non-routeable generation 6", snap)
	}
	if !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatal("acct-allowed should be authorized on the creator-owned candidate pool")
	}

	rec := getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools", http.StatusOK)
	if !strings.Contains(rec.Body.String(), root.poolID) {
		t.Fatalf("creator pool list body=%s missing owned pool", rec.Body.String())
	}
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools/"+root.poolID, http.StatusOK)
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools/"+root.poolID+"/health", http.StatusOK)
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools/"+root.poolID+"/distribution", http.StatusOK)
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools/"+root.poolID+"/audit", http.StatusOK)
}

func TestAdminHandler_CreatorSurfaceReloadRevokesCredentialAndCeilings(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         trustpool.NewRegistry(),
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-a"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools", http.StatusOK)

	reloader, ok := handler.(trustpool.CreatorAdminConfigReloader)
	if !ok {
		t.Fatal("admin handler does not implement creator admin config reloader")
	}
	reloader.SetCreatorAdminConfig(nil, nil, nil, nil)
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools", http.StatusUnauthorized)

	reloader.SetCreatorAdminConfig(
		creatorCredentials("creator-a", "creator-a-cred-v2", "creator-token-b"),
		map[string][]string{"creator-a": {"provider-b"}},
		map[string][]string{"creator-a": {"provider-b"}},
		map[string][]string{"creator-a": {"acct-b"}},
	)
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools", http.StatusUnauthorized)
	getCreator(t, handler, "creator-token-b", "/creator/trust-pools/pools", http.StatusOK)
}

func TestAdminHandler_CreatorSurfaceRejectsCrossCreatorAndOperatorOnlyActions(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                   store,
		Registry:                trustpool.NewRegistry(),
		OperatorKey:             "operator-secret",
		CreatorAdminCredentials: append(creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"), creatorCredentials("creator-b", "creator-b-cred", "creator-token-b")...),
		CreatorAdminProviderIDs: map[string][]string{
			"creator-a": {"provider-a"},
			"creator-b": {"provider-b"},
		},
		CreatorAdminProviderDelegatedIDs: map[string][]string{
			"creator-a": {"provider-a"},
			"creator-b": {"provider-b"},
		},
		CreatorAdminBuyerAccountIDs: map[string][]string{
			"creator-a": {"acct-a"},
			"creator-b": {"acct-b"},
		},
		CreatorProviderAdmitted: admittedProviderIDs("provider-a", "provider-b"),
	})
	rootA := newRootFixture(t)
	rootB := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-a", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	approveCreator(t, store, "creator-b", "approval-b", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postCreatorEvent(t, handler, "creator-token-a", creatorPoolCreatedEvent(t, rootA, "approval-a"), "op-create-a", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-b", creatorPoolCreatedEvent(t, rootB, "approval-b"), "op-create-b", http.StatusAccepted)

	postCreatorEvent(t, handler, "creator-token-a", creatorPoolCreatedEvent(t, rootB, "approval-b"), "op-create-b", http.StatusNotFound)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     rootB.poolID,
		ProviderID: "provider-b",
	}, "op-member-b", http.StatusNotFound)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     rootA.poolID,
		ProviderID: "provider-z",
	}, "op-member-z", http.StatusForbidden)
	getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools/"+rootB.poolID, http.StatusNotFound)
	rec := getCreator(t, handler, "creator-token-a", "/creator/trust-pools/pools", http.StatusOK)
	if strings.Contains(rec.Body.String(), rootB.poolID) {
		t.Fatalf("creator-a pool list body=%s included creator-b pool", rec.Body.String())
	}

	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-c",
		CreatorAccountID: "creator-b",
		ApprovalRecordID: "approval-a",
	}, "op-create-mismatch", http.StatusForbidden)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    rootA.poolID,
		Lifecycle: trustpool.LifecycleActive,
	}, "op-active", http.StatusConflict)
	postCreatorLifecycle(t, handler, "creator-token-a", rootA.poolID, "op-active-2", trustpool.LifecycleActive, "creator cannot activate", http.StatusConflict)

	for _, path := range []string{
		"/creator/trust-pools/creators",
		"/creator/trust-pools/pools/" + rootA.poolID + "/promote",
		"/creator/trust-pools/pools/" + rootA.poolID + "/public-announcement",
		"/creator/trust-pools/pools/" + rootA.poolID + "/reviewed-distribution-artifact",
		"/creator/trust-pools/pools/" + rootA.poolID + "/signed-lifecycle",
	} {
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader([]byte(`{}`)))
		req.Header.Set("Authorization", "Bearer creator-token-a")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("POST %s status=%d body=%s, want 404", path, rec.Code, rec.Body.String())
		}
		assertAdminSchemaVersion(t, rec)
	}
}

func TestAdminHandler_CreatorSurfaceIdempotencyAndPolicyGuards(t *testing.T) {
	t.Parallel()
	providerIDs := map[string][]string{"creator-a": {"provider-a"}}
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         registry,
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          providerIDs,
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	reloader, ok := handler.(trustpool.CreatorAdminConfigReloader)
	if !ok {
		t.Fatal("admin handler does not implement creator admin config reloader")
	}
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	create := creatorPoolCreatedEvent(t, root, "approval-v1")
	postCreatorEvent(t, handler, "creator-token-a", create, "op-create", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", create, "op-create", http.StatusAccepted)

	nonce := postCreatorRootRegistrationNonce(t, handler, "creator-token-a", trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	}, http.StatusCreated)
	postCreatorEvent(t, handler, "creator-token-a", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonce, root), "op-root", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)

	admit := trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}
	postCreatorEvent(t, handler, "creator-token-a", admit, "op-member", http.StatusAccepted)
	reloader.SetCreatorAdminConfig(
		creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		map[string][]string{"creator-a": {}},
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"acct-allowed"}},
	)
	postCreatorEvent(t, handler, "creator-token-a", admit, "op-member", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member-again", http.StatusForbidden)
	reloader.SetCreatorAdminConfig(
		creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"acct-allowed"}},
	)

	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-other",
	}, "op-buyer-other", http.StatusForbidden)
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	activeSnap := registry.Snapshot(root.poolID)
	if !activeSnap.Routeable || !activeSnap.Members["provider-a"] || !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatalf("active registry snapshot = %+v buyer_authorized=%v, want routeable provider and buyer", activeSnap, registry.BuyerAuthorized(root.poolID, "acct-allowed"))
	}
	activeGeneration := activeSnap.Generation
	reloader.SetCreatorAdminConfig(
		creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		map[string][]string{"creator-a": {}},
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"acct-allowed"}},
	)
	if snap := registry.Snapshot(root.poolID); snap.Members["provider-a"] || snap.Generation == activeGeneration {
		t.Fatalf("provider ceiling snapshot = %+v, want provider removed and generation bumped from %d", snap, activeGeneration)
	}
	if _, ok := registry.BeginPoolDeliveryAtGeneration(root.poolID, activeGeneration); ok {
		t.Fatal("BeginPoolDeliveryAtGeneration accepted stale pre-ceiling generation")
	}
	reloader.SetCreatorAdminConfig(
		creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {}},
	)
	if registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatal("buyer ceiling removal left stale buyer authorization live")
	}
	if _, authorized := registry.AuthorizeAndSnapshot(root.poolID, "acct-allowed"); authorized {
		t.Fatal("AuthorizeAndSnapshot accepted buyer removed by creator ceiling")
	}
	reloader.SetCreatorAdminConfig(nil, nil, nil, nil)
	if snap := registry.Snapshot(root.poolID); snap.Members["provider-a"] {
		t.Fatalf("credential removal snapshot = %+v, want provider denied by retained empty ceiling", snap)
	}
	if registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatal("credential removal cleared ceiling and left stale buyer authorization live")
	}
	reloader.SetCreatorAdminConfig(
		creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"provider-a"}},
		map[string][]string{"creator-a": {"acct-allowed"}},
	)
	postCreatorLifecycle(t, handler, "creator-token-a", root.poolID, "op-pause", trustpool.LifecyclePaused, "pause for maintenance", http.StatusAccepted)
	postCreatorLifecycle(t, handler, "creator-token-a", root.poolID, "op-pause", trustpool.LifecyclePaused, "pause for maintenance", http.StatusAccepted)

	approveCreator(t, store, "creator-a", "approval-v2", "approval-version-2", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusSuspended)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberRevoked,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-revoke-suspended", http.StatusConflict)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorizationRm,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer-rm-suspended", http.StatusConflict)
	postCreatorLifecycle(t, handler, "creator-token-a", root.poolID, "op-retire-suspended", trustpool.LifecycleRetired, "retire while suspended", http.StatusConflict)

	state, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || !pool.Members["provider-a"] || !pool.BuyerAccounts["acct-allowed"] || pool.Lifecycle != trustpool.LifecyclePaused {
		t.Fatalf("pool after guarded mutations = %+v, want provider/buyer retained and paused", pool)
	}
}

func TestAdminHandler_CreatorSurfaceRejectsBadEventsWithoutDisablingRegistry(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         registry,
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	create := creatorPoolCreatedEvent(t, root, "approval-v1")
	postCreatorEvent(t, handler, "creator-token-a", create, "op-create", http.StatusAccepted)
	if snap := registry.Snapshot(root.poolID); !snap.Exists {
		t.Fatalf("registry snapshot before bad event = %+v, want existing pool", snap)
	}

	postCreatorEvent(t, handler, "creator-token-a", create, "op-duplicate-create", http.StatusBadRequest)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool.with.dot",
		ApprovalRecordID: "approval-v1",
	}, "op-bad-pool-id", http.StatusBadRequest)
	if snap := registry.Snapshot(root.poolID); !snap.Exists {
		t.Fatalf("registry snapshot after rejected creator event = %+v, want still present", snap)
	}
}

func TestAdminHandler_CreatorSurfaceRejectsAllowlistedUnadmittedProvider(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         trustpool.NewRegistry(),
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs(),
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postCreatorEvent(t, handler, "creator-token-a", creatorPoolCreatedEvent(t, root, "approval-v1"), "op-create", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member-unadmitted", http.StatusForbidden)
	state, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if pool := state.Pools[root.poolID]; pool == nil || pool.Members["provider-a"] {
		t.Fatalf("pool after unadmitted provider admit = %+v, want provider not admitted", pool)
	}
}

func TestAdminHandler_CreatorSurfaceRejectsUndelegatedProvider(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         trustpool.NewRegistry(),
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postCreatorEvent(t, handler, "creator-token-a", creatorPoolCreatedEvent(t, root, "approval-v1"), "op-create", http.StatusAccepted)
	postCreatorEvent(t, handler, "creator-token-a", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member-undelegated", http.StatusForbidden)
	state, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if pool := state.Pools[root.poolID]; pool == nil || pool.Members["provider-a"] {
		t.Fatalf("pool after undelegated provider admit = %+v, want provider not admitted", pool)
	}
}

func TestAdminHandler_CreatorSurfaceRejectsUnauthorized(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         trustpool.NewRegistry(),
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	req := httptest.NewRequest(http.MethodGet, "/creator/trust-pools/pools", nil)
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d body=%s, want 401", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
}

func TestAdminHandler_CreatorSurfaceRejectsExpiredCredential(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         trustpool.NewRegistry(),
		OperatorKey:                      "operator-secret",
		CreatorAdminCredentials:          expiredCreatorCredentials("creator-a", "creator-a-cred", "creator-token-a"),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {"provider-a"}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {"acct-allowed"}},
		CreatorProviderAdmitted:          admittedProviderIDs("provider-a"),
	})
	req := httptest.NewRequest(http.MethodGet, "/creator/trust-pools/pools", nil)
	req.Header.Set("Authorization", "Bearer creator-token-a")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d body=%s, want 401", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
}

func TestAdminHandler_ReplayChecksBeforeAppend(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    "pool-a",
		Lifecycle: trustpool.LifecycleActive,
	}, "op-bad-active", http.StatusConflict)

	reconstructed, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("history should remain reconstructable after rejected append: %v", err)
	}
	if reconstructed.Pools["pool-a"].Generation != 1 {
		t.Fatalf("generation = %d, want only the accepted create event", reconstructed.Pools["pool-a"].Generation)
	}
}

func TestAdminHandler_IdempotencyConflict(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	create := trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}
	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusAccepted)
	create.CreatorAccountID = "creator-b"
	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusConflict)
}

func TestAdminHandler_ConflictingOperationIDSourcesRejected(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	body, err := json.Marshal(trustpool.DurableEvent{
		OperationID:      "body-op",
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator-secret")
	req.Header.Set("Idempotency-Key", "different-op")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status=%d body=%s, want 409", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
}

func postAdminEvent(t *testing.T, h http.Handler, operatorKey string, e trustpool.DurableEvent, operationID string, want int) {
	t.Helper()
	body, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST event %s status=%d body=%s, want %d", operationID, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func postAdminCreator(t *testing.T, h http.Handler, operatorKey string, approval trustpool.CreatorApproval, want int) {
	t.Helper()
	body, err := json.Marshal(approval)
	if err != nil {
		t.Fatalf("marshal creator approval: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/creators", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST creator status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func postAdminRootRegistrationNonce(t *testing.T, h http.Handler, operatorKey string, issue trustpool.RootRegistrationNonceIssue, want int) {
	t.Helper()
	body, err := json.Marshal(issue)
	if err != nil {
		t.Fatalf("marshal root registration nonce issue: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST root registration nonce status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func postCreatorEvent(t *testing.T, h http.Handler, creatorToken string, e trustpool.DurableEvent, operationID string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal creator event: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+creatorToken)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST creator event %s status=%d body=%s, want %d", operationID, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminRootCompromise(t *testing.T, h http.Handler, operatorKey, poolID, fingerprint, operationID string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{
		"operation_id":                       operationID,
		"pool_id":                            poolID,
		"root_issuer_public_key_fingerprint": fingerprint,
	})
	if err != nil {
		t.Fatalf("marshal admin root compromise: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/emergency/root-compromise", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST admin root compromise status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postCreatorRootRegistrationNonce(t *testing.T, h http.Handler, creatorToken string, issue trustpool.RootRegistrationNonceIssue, want int) trustpool.RootRegistrationNonceRecord {
	t.Helper()
	body, err := json.Marshal(issue)
	if err != nil {
		t.Fatalf("marshal creator root registration nonce issue: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/root-registration-nonces", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+creatorToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST creator root registration nonce status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	var decoded struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("decode creator root registration nonce: %v", err)
	}
	return decoded.RootRegistrationNonce
}

func postCreatorRootCompromise(t *testing.T, h http.Handler, creatorToken, poolID, fingerprint, operationID string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{
		"operation_id":                       operationID,
		"pool_id":                            poolID,
		"root_issuer_public_key_fingerprint": fingerprint,
	})
	if err != nil {
		t.Fatalf("marshal root compromise: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/emergency/root-compromise", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+creatorToken)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST creator root compromise status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postCreatorLifecycle(t *testing.T, h http.Handler, creatorToken, poolID, operationID, lifecycle, reason string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{
		"lifecycle": lifecycle,
		"reason":    reason,
	})
	if err != nil {
		t.Fatalf("marshal creator lifecycle request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/pools/"+poolID+"/lifecycle", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+creatorToken)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST creator lifecycle %s/%s status=%d body=%s, want %d", operationID, lifecycle, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func getCreator(t *testing.T, h http.Handler, creatorToken, path string, want int) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+creatorToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("GET creator %s status=%d body=%s, want %d", path, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func admittedProviderIDs(ids ...string) func(string) bool {
	allowed := make(map[string]bool, len(ids))
	for _, id := range ids {
		allowed[id] = true
	}
	return func(providerID string) bool {
		return allowed[providerID]
	}
}

func creatorCredentials(creatorID, credentialID, token string) []trustpool.CreatorAdminCredential {
	now := time.Now().UTC()
	return []trustpool.CreatorAdminCredential{{
		CreatorAccountID: creatorID,
		CredentialID:     credentialID,
		Token:            token,
		NotBeforeUTC:     now.Add(-time.Hour),
		ExpiresAtUTC:     now.Add(24 * time.Hour),
		Status:           trustpool.CreatorAdminCredentialStatusEnabled,
	}}
}

func expiredCreatorCredentials(creatorID, credentialID, token string) []trustpool.CreatorAdminCredential {
	now := time.Now().UTC()
	return []trustpool.CreatorAdminCredential{{
		CreatorAccountID: creatorID,
		CredentialID:     credentialID,
		Token:            token,
		NotBeforeUTC:     now.Add(-2 * time.Hour),
		ExpiresAtUTC:     now.Add(-time.Hour),
		Status:           trustpool.CreatorAdminCredentialStatusEnabled,
	}}
}

func creatorPoolCreatedEvent(t *testing.T, root rootFixture, approvalID string) trustpool.DurableEvent {
	t.Helper()
	snapshot, _ := manifestSnapshotWithPolicyCoreMutation(t, 1, root, nil)
	return trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		ApprovalRecordID: approvalID,
		ManifestSnapshot: snapshot,
	}
}

func postAdminPublicAnnouncement(t *testing.T, h http.Handler, operatorKey, poolID string, approval trustpool.PublicAnnouncementApproval, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(approval)
	if err != nil {
		t.Fatalf("marshal public announcement approval: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/public-announcement", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST public announcement status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminReviewedDistributionArtifact(t *testing.T, h http.Handler, operatorKey, poolID string, artifact trustpool.ReviewedDistributionArtifact, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(artifact)
	if err != nil {
		t.Fatalf("marshal reviewed distribution artifact: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/reviewed-distribution-artifact", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST reviewed distribution artifact status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminPromote(t *testing.T, h http.Handler, operatorKey, poolID, operationID string, want int) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/promote", nil)
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST promote %s status=%d body=%s, want %d", operationID, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminLifecycle(t *testing.T, h http.Handler, operatorKey, poolID, operationID, lifecycle, reason string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{
		"lifecycle": lifecycle,
		"reason":    reason,
	})
	if err != nil {
		t.Fatalf("marshal lifecycle request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/lifecycle", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST lifecycle %s/%s status=%d body=%s, want %d", operationID, lifecycle, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminLifecycleWithIDs(t *testing.T, h http.Handler, operatorKey, poolID, bodyOperationID, headerOperationID, lifecycle, reason string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{
		"operation_id": bodyOperationID,
		"lifecycle":    lifecycle,
		"reason":       reason,
	})
	if err != nil {
		t.Fatalf("marshal lifecycle request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/lifecycle", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", headerOperationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST lifecycle body=%s header=%s %s status=%d body=%s, want %d", bodyOperationID, headerOperationID, lifecycle, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminSignedLifecycle(t *testing.T, store *trustpool.Store, h http.Handler, operatorKey string, root rootFixture, operationID, lifecycle, reason string, corrupt bool, want int) *httptest.ResponseRecorder {
	t.Helper()
	body := signedLifecycleRequestBody(t, store, root, operationID, lifecycle, reason, corrupt)
	return postAdminSignedLifecycleBody(t, h, operatorKey, root.poolID, body, "", want)
}

func postAdminSignedLifecycleWithTarget(t *testing.T, store *trustpool.Store, h http.Handler, operatorKey string, root rootFixture, operationID, lifecycle, targetProviderID, reason string, corrupt bool, want int) *httptest.ResponseRecorder {
	t.Helper()
	body := signedLifecycleRequestBodyWithTarget(t, store, root, operationID, lifecycle, targetProviderID, reason, corrupt)
	return postAdminSignedLifecycleBody(t, h, operatorKey, root.poolID, body, "", want)
}

func signedLifecycleRequestBody(t *testing.T, store *trustpool.Store, root rootFixture, operationID, lifecycle, reason string, corrupt bool) map[string]any {
	t.Helper()
	return signedLifecycleRequestBodyWithTarget(t, store, root, operationID, lifecycle, "", reason, corrupt)
}

func signedLifecycleRequestBodyWithTarget(t *testing.T, store *trustpool.Store, root rootFixture, operationID, lifecycle, targetProviderID, reason string, corrupt bool) map[string]any {
	t.Helper()
	state, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("Reconstruct for signed lifecycle: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil {
		t.Fatalf("pool %q not reconstructed", root.poolID)
	}
	digest, err := hex.DecodeString(pool.ManifestCoreDigest)
	if err != nil {
		t.Fatalf("decode manifest digest: %v", err)
	}
	issued := uint64(time.Now().Add(-time.Minute).Unix())
	control := poolmanifest.EmergencyLifecycleControl{
		PoolID:             root.poolID,
		ManifestVersion:    pool.ManifestVersion,
		ManifestCoreDigest: digest,
		SignerSetVersion:   1,
		OperationID:        operationID,
		Action:             lifecycle,
		TargetProviderID:   targetProviderID,
		Reason:             reason,
		IssuedAtUnix:       issued,
		ExpiresAtUnix:      issued + 600,
	}
	controlDigest, err := control.Digest()
	if err != nil {
		t.Fatalf("control Digest: %v", err)
	}
	msg, err := poolmanifest.EmergencyLifecycleControlSigningMessage(controlDigest)
	if err != nil {
		t.Fatalf("control signing message: %v", err)
	}
	sig := ed25519.Sign(root.policySignerPrivateKey, msg)
	if corrupt {
		sig = append([]byte(nil), sig...)
		sig[0] ^= 0xff
	}
	body := map[string]any{
		"control": map[string]any{
			"pool_id":              control.PoolID,
			"manifest_version":     control.ManifestVersion,
			"manifest_core_digest": pool.ManifestCoreDigest,
			"signer_set_version":   control.SignerSetVersion,
			"operation_id":         control.OperationID,
			"action":               control.Action,
			"reason":               control.Reason,
			"issued_at_unix":       control.IssuedAtUnix,
			"expires_at_unix":      control.ExpiresAtUnix,
		},
		"signatures": []map[string]string{{
			"key_id":    root.policySigner.KeyID,
			"signature": base64.StdEncoding.EncodeToString(sig),
		}},
	}
	if targetProviderID != "" {
		body["control"].(map[string]any)["target_provider_id"] = targetProviderID
	}
	return body
}

func postAdminSignedLifecycleBody(t *testing.T, h http.Handler, operatorKey, poolID string, payload map[string]any, headerOperationID string, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal signed lifecycle request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/signed-lifecycle", bytes.NewReader(body))
	if operatorKey != "" {
		req.Header.Set("Authorization", "Bearer "+operatorKey)
	}
	if headerOperationID != "" {
		req.Header.Set("Idempotency-Key", headerOperationID)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST signed lifecycle status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func assertAdminSchemaVersion(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("admin response is not JSON: %v body=%s", err, rec.Body.String())
	}
	if body["schema_version"] != trustpool.AdminSchemaVersion {
		t.Fatalf("schema_version=%v, want %s; body=%s", body["schema_version"], trustpool.AdminSchemaVersion, rec.Body.String())
	}
}

func testAdminTS(offset int64) time.Time {
	return time.Unix(1800020000+offset, 0).UTC()
}

type routeableAdminPool struct {
	store    *trustpool.Store
	registry *trustpool.Registry
	handler  http.Handler
	root     rootFixture
}

func newRouteableAdminPool(t *testing.T) routeableAdminPool {
	t.Helper()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	return routeableAdminPool{store: store, registry: registry, handler: handler, root: root}
}
