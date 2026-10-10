package billing

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// SPEC-047-R012 counting predicate: only an enforce-mode pool_manifest
// attempt with a closed payable verdict, a verified pool label, and a
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
			if pool {
				if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = 'verified' WHERE request_id = ?`, requestID); err != nil {
					t.Fatal(err)
				}
			}
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
	unverifiedLabel := seed("pp-unverified-label", true, true, 600)
	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = 'unverified' WHERE request_id = ?`, unverifiedLabel.RequestID); err != nil {
		t.Fatal(err)
	}
	noLabel := seed("pp-no-label", true, true, 600)
	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = NULL WHERE request_id = ?`, noLabel.RequestID); err != nil {
		t.Fatal(err)
	}
	quarantined := seed("pp-quarantined", true, true, 600)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'test' WHERE request_id = ?`, quarantined.RequestID); err != nil {
		t.Fatal(err)
	}

	final := time.UnixMilli(counted.ReceiptReceivedUnixMS).UTC()
	since, until := final.Add(-time.Hour), final.Add(time.Hour)
	if err := EnsurePoolProvenRollup(ctx, store.db); err != nil {
		t.Fatal(err)
	}
	if err := RefreshPoolProvenRollup(ctx, store.db, store.db, since); err != nil {
		t.Fatalf("refresh: %v", err)
	}
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

// SPEC-047-R012 rollup: a counted attempt keeps counting after SPEC-022 R-15
// retention removes its snapshot, verdict, and output rows from the hot
// database; a later quarantine of a still-hot credit stops it counting; a
// verdict that closed before the window start is not re-read; and the rollup
// rebuilds from hot evidence after a version change.
func TestPoolProvenRollupPersistsAcrossArchivingAndReevaluates(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base := settlementVerifierInputFromFixture(t, fixtures, firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done"), pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	ctx := context.Background()
	if err := EnsurePoolProvenRollup(ctx, store.db); err != nil {
		t.Fatal(err)
	}
	seed := func(requestID string) SettlementVerifyInput {
		t.Helper()
		in := base
		in.RequestID = requestID
		in.RouteSnapshot.RequestID = requestID
		in.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
		in.RouteSnapshot = poolManifestSnapshot(in.RouteSnapshot)
		in.RouteSnapshot.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
		in.RouteSnapshot.ProviderReportedModelHashAlgorithm = modelidentity.SnapshotManifestV1
		seedSettlementReceiptEvidence(t, store, in)
		insertSPEC022LedgerCredit(t, store.db, in, 600)
		markSPEC022ReceiptVerified(t, store.db, in)
		if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = 'verified' WHERE request_id = ?`, requestID); err != nil {
			t.Fatal(err)
		}
		return in
	}
	archived := seed("pp-archived")
	reversed := seed("pp-reversed")
	final := time.UnixMilli(archived.ReceiptReceivedUnixMS).UTC()
	since, until := final.Add(-time.Hour), final.Add(time.Hour)
	count := func() int {
		t.Helper()
		if err := RefreshPoolProvenRollup(ctx, store.db, store.db, since); err != nil {
			t.Fatalf("refresh: %v", err)
		}
		attempts, err := QueryPoolProvenAttempts(ctx, store.db, since, until, 10)
		if err != nil {
			t.Fatal(err)
		}
		return len(attempts)
	}
	if got := count(); got != 2 {
		t.Fatalf("counted = %d, want 2", got)
	}
	// Retention moves the evidence out of the hot tables; the ledger credit
	// stays. The archived attempt still counts.
	for _, table := range []string{"settlement_attempt_outputs", "settlement_receipt_verdicts", "settlement_route_snapshots"} {
		if _, err := store.db.Exec(`DELETE FROM `+table+` WHERE request_id = ?`, archived.RequestID); err != nil {
			t.Fatalf("archive %s: %v", table, err)
		}
	}
	if got := count(); got != 2 {
		t.Fatalf("after archiving counted = %d, want 2", got)
	}
	// A quarantine of a hot credit is a reversal: it stops counting.
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'test' WHERE request_id = ?`, reversed.RequestID); err != nil {
		t.Fatal(err)
	}
	if got := count(); got != 1 {
		t.Fatalf("after reversal counted = %d, want 1", got)
	}
	// A window that starts after every finality time leaves both rows
	// unread: re-evaluation is bounded to the open window.
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 0 WHERE request_id = ?`, reversed.RequestID); err != nil {
		t.Fatal(err)
	}
	if err := RefreshPoolProvenRollup(ctx, store.db, store.db, until); err != nil {
		t.Fatal(err)
	}
	var stillOff int
	if err := store.db.QueryRow(`SELECT counted FROM pool_proven_rollup_attempts WHERE request_id = ?`, reversed.RequestID).Scan(&stillOff); err != nil || stillOff != 0 {
		t.Fatalf("closed-before-window row re-read: counted=%d err=%v", stillOff, err)
	}
	// A version change rebuilds from hot evidence only.
	if _, err := store.db.Exec(`UPDATE pool_proven_rollup_cursor SET rollup_version = 0`); err != nil {
		t.Fatal(err)
	}
	if err := EnsurePoolProvenRollup(ctx, store.db); err != nil {
		t.Fatal(err)
	}
	if got := count(); got != 1 {
		t.Fatalf("after rebuild counted = %d, want the hot attempt only", got)
	}
}

// The rollup's reads never scan the ledger, snapshot, or verdict tables: the
// capture reads a rowid range and every evaluation join is a key lookup. The
// pre-rollup query drove the payable view over every enforce-mode credit and
// timed out on the production ledger.
func TestPoolProvenRollupQueryPlansAvoidFullScans(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	if err := EnsurePoolProvenRollup(ctx, store.db); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`ANALYZE`); err != nil {
		t.Fatal(err)
	}
	plans := map[string][]any{
		"capture":  {`SELECT id FROM settlement_route_snapshots WHERE id > ? AND id <= ? AND pool_id IS NOT NULL AND pool_id <> '' AND route_snapshot_mode = 'enforce' AND json_extract(route_snapshot_json, '$.expected_model_hash_source') = ? ORDER BY id`, 0, 10, ExpectedModelHashSourcePoolManifest},
		"evaluate": {poolProvenEvaluateSQL(), PoolLabelStatusVerified, 0, time.Now().UTC().Format(time.RFC3339Nano), poolProvenEvaluateBatch},
	}
	for name, p := range plans {
		rows, err := store.db.QueryContext(ctx, "EXPLAIN QUERY PLAN "+p[0].(string), p[1:]...)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var plan []string
		for rows.Next() {
			var id, parent, unused int
			var detail string
			if err := rows.Scan(&id, &parent, &unused, &detail); err != nil {
				t.Fatal(err)
			}
			plan = append(plan, detail)
		}
		rows.Close()
		t.Logf("%s plan:\n%s", name, strings.Join(plan, "\n"))
		for _, line := range plan {
			for _, table := range []string{"settlement_route_snapshots", "settlement_receipt_verdicts", "ledger_request_credits", "lrc", "srs", "srv", "settlement_attempt_outputs", "sao"} {
				if strings.HasPrefix(line, "SCAN "+table) {
					t.Fatalf("%s plan scans %s:\n%s", name, table, strings.Join(plan, "\n"))
				}
			}
		}
	}
}
