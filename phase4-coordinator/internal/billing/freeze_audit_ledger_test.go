package billing

import (
	"context"
	"strings"
	"testing"
)

// Freeze audit R1 (#1690) SECURITY H1: a loopback-served attempt never carries
// ledger credit or buyer debit unless the recorder derived it
// pool_operator_attested, whatever routing decided.
func TestWriteHotPath_LoopbackRuntimeNeverEarnsOutsideAttestedPool(t *testing.T) {
	for _, tc := range []struct {
		source        string
		attested      bool
		byteEstimated bool
		wantPaid      bool
	}{
		{"", false, false, true},
		{"mlx_cache", false, false, true},
		{"mlx_cache", false, true, true},
		{"llamacpp_loopback", false, false, false},
		{"ollama_loopback", false, false, false},
		{"lmstudio_loopback", false, false, false},
		{"openai_compatible_loopback", false, false, false},
		{"llamacpp_loopback", true, false, true},
		// A pool attempt whose runtime reported no usage (a cancelled
		// stream) has only a byte estimate: zero billable at the source.
		{"llamacpp_loopback", true, true, false},
	} {
		name := tc.source
		if tc.attested {
			name += "+pool_operator_attested"
		}
		if tc.byteEstimated {
			name += "+byte_estimated"
		}
		t.Run("source="+name, func(t *testing.T) {
			reqStore, store := newRequestAndBillingStores(t)
			input, row := testHotPathInput(t, store)
			input.ProviderRuntimeSource = tc.source
			input.PoolOperatorAttested = tc.attested
			if tc.attested {
				// The decision's pool fence, held at commit (audit R2).
				store.SetPoolOperatorAttestationAuthority(stableFencedAuthority())
				store.SetSettlementPoolLabelSource(labelsChangingAfter(1 << 30))
				input.PoolAttestationFence = testPoolFence()
			}
			if tc.byteEstimated {
				estimate := int64(75)
				input.CompletionTokens, row.CompletionTokens = nil, nil
				input.EstimatedCompTokens, row.EstimatedCompTokens = &estimate, &estimate
			}
			if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
				t.Fatal(err)
			}
			var gross, provider, quarantined int64
			var reason *string
			if err := store.db.QueryRow(`SELECT gross_credits, provider_credits, quarantined, quarantine_reason FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).
				Scan(&gross, &provider, &quarantined, &reason); err != nil {
				t.Fatal(err)
			}
			if tc.wantPaid {
				if gross == 0 || provider == 0 || quarantined != 0 {
					t.Fatalf("paid attempt gross=%d provider=%d quarantined=%d", gross, provider, quarantined)
				}
				return
			}
			if gross != 0 || provider != 0 || quarantined != 1 || reason == nil || *reason != LoopbackRuntimeNotSettlementEligible {
				t.Fatalf("loopback attempt must be zero and quarantined: gross=%d provider=%d quarantined=%d reason=%v", gross, provider, quarantined, reason)
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits`); got != 0 {
				t.Fatalf("loopback attempt wrote %d operator credit rows", got)
			}
		})
	}
}

// Freeze audit R1 CODE M6: a legacy pool_id-only route snapshot has no
// routing-time manifest labels, so settlement can never verify its label.
func TestSettlementPoolLabelStatus_LegacyPoolOnlySnapshotIsUnverified(t *testing.T) {
	legacy := testRouteSnapshot()
	legacy.PoolID = "pool-abc"
	labels := &SettlementPoolLabels{PoolID: "pool-abc", RouteSnapshotHash: "h"}
	if got := settlementPoolLabelStatus(legacy, "h", labels); got != PoolLabelStatusUnverified {
		t.Fatalf("legacy pool-only snapshot status=%q, want unverified", got)
	}
	labels.ManifestVersion = 2
	labels.ManifestCoreDigest = strings.Repeat("d", 64)
	if got := settlementPoolLabelStatus(legacy, "h", labels); got != PoolLabelStatusUnverified {
		t.Fatalf("legacy pool-only snapshot with live labels status=%q, want unverified", got)
	}
	labels.PoolID = "pool-other"
	if got := settlementPoolLabelStatus(legacy, "h", labels); got != PoolLabelStatusDisputed {
		t.Fatalf("legacy pool-only snapshot with another pool status=%q, want disputed", got)
	}
}

// Freeze audit R1 ARCH M2: a verdict row written against a different route
// snapshot digest than the loaded route is stamped label_disputed by
// settlement identity, never silently skipped.
func TestRecordSettlementPoolLabels_VerdictDigestMismatchIsDisputed(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.PoolID = "pool-abc"
	input.RouteSnapshot.ManifestVersion = 2
	input.RouteSnapshot.ManifestCoreDigest = strings.Repeat("d", 64)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	id := SettlementReceiptIdentity{AccountScope: input.AccountScope, RequestID: input.RequestID, AttemptN: input.AttemptN, ProviderID: input.ProviderID}
	ctx := context.Background()
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	if _, err := store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{SettlementReceiptIdentity: id, NowUnixMS: deadline - 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET route_snapshot_digest = ? WHERE request_id = ?`, strings.Repeat("f", 64), input.RequestID); err != nil {
		t.Fatal(err)
	}
	match := &SettlementPoolLabels{PoolID: "pool-abc", ManifestVersion: 2, ManifestCoreDigest: strings.Repeat("d", 64)}
	rec, err := store.RecordSettlementPoolLabels(ctx, id, match)
	if err != nil {
		t.Fatal(err)
	}
	if rec.Status != PoolLabelStatusDisputed || rec.VerdictRouteSnapshotDigest != strings.Repeat("f", 64) || rec.RouteSnapshotHash == rec.VerdictRouteSnapshotDigest {
		t.Fatalf("digest-mismatched verdict record=%+v, want disputed with both digests", rec)
	}
}
