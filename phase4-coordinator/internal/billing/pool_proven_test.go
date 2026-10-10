package billing

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// SPEC-047-R012 counting predicate: only an enforce-mode pool_manifest
// attempt with a closed payable verdict, an undisputed pool label, and a
// payable credit with positive buyer debit and provider credit counts, by
// verdict finality time, and the ceiling is applied at the query.
func TestQueryPoolProvenAttemptsCountingPredicate(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base := settlementVerifierInputFromFixture(t, fixtures, firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done"), pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	ctx := context.Background()
	seed := func(requestID string, pool, verified bool, providerCredits int64) SettlementVerifyInput {
		t.Helper()
		in := base
		in.RequestID = requestID
		in.RouteSnapshot.RequestID = requestID
		in.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
		if pool {
			in.RouteSnapshot = poolManifestSnapshot(in.RouteSnapshot)
			in.RouteSnapshot.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
			in.RouteSnapshot.ProviderReportedModelHashAlgorithm = modelidentity.SnapshotManifestV1
		}
		seedSettlementReceiptEvidence(t, store, in)
		insertSPEC022LedgerCredit(t, store.db, in, providerCredits)
		if verified {
			markSPEC022ReceiptVerified(t, store.db, in)
		}
		return in
	}
	counted := seed("pp-counted", true, true, 600)
	seed("pp-counted-2", true, true, 600)
	seed("pp-catalog", false, true, 600)
	seed("pp-unsettled", true, false, 600)
	seed("pp-zero-credit", true, true, 0)
	disputed := seed("pp-disputed", true, true, 600)
	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = 'label_disputed' WHERE request_id = ?`, disputed.RequestID); err != nil {
		t.Fatal(err)
	}
	quarantined := seed("pp-quarantined", true, true, 600)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'test' WHERE request_id = ?`, quarantined.RequestID); err != nil {
		t.Fatal(err)
	}

	final := time.UnixMilli(counted.ReceiptReceivedUnixMS).UTC()
	since, until := final.Add(-time.Hour), final.Add(time.Hour)
	attempts, err := QueryPoolProvenAttempts(ctx, store.db, since, until, 10)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(attempts) != 2 {
		t.Fatalf("counted attempts = %+v, want the two settled undisputed pool attempts", attempts)
	}
	a := attempts[0]
	if a.ProviderID != counted.ProviderID || a.PoolID != testPoolID || a.PoolModelID != "pool/"+testPoolID+"/creator-mlx" ||
		a.ManifestVersion != 2 || a.ManifestCoreDigest != strings.Repeat("d", 64) ||
		a.ArtifactHash != counted.RouteSnapshot.ExpectedCatalogModelHash ||
		a.ArtifactHashAlgorithm != modelidentity.SnapshotManifestV1 {
		t.Fatalf("attempt = %+v", a)
	}
	if outside, err := QueryPoolProvenAttempts(ctx, store.db, until, until.Add(time.Hour), 10); err != nil || len(outside) != 0 {
		t.Fatalf("outside the window = %+v err=%v", outside, err)
	}
	if limited, err := QueryPoolProvenAttempts(ctx, store.db, since, until, 1); err != nil || len(limited) != 1 {
		t.Fatalf("limit = %+v err=%v", limited, err)
	}
	if _, err := QueryPoolProvenAttempts(ctx, store.db, until, since, 10); err == nil {
		t.Fatal("an inverted window was accepted")
	}
}
