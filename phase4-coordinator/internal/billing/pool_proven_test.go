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

// simulateEvidenceRetentionView adds the SPEC-022 R-15 (#1909) payable-view
// clause that keeps an archived settled credit payable once its evidence
// rows are deleted, so these tests see the view retention will ship.
func simulateEvidenceRetentionView(t *testing.T, store *Store) {
	t.Helper()
	var viewSQL string
	if err := store.db.QueryRow(`SELECT sql FROM sqlite_master WHERE type='view' AND name='spec022_payable_request_credits'`).Scan(&viewSQL); err != nil {
		t.Fatal(err)
	}
	const anchor = "COALESCE(lrc.settlement_policy_mode, 'legacy') IN ('legacy', 'observe')"
	if !strings.Contains(viewSQL, anchor) {
		t.Fatalf("payable view changed shape:\n%s", viewSQL)
	}
	viewSQL = strings.Replace(viewSQL, anchor, anchor+`
       OR (lrc.settled = 1 AND EXISTS (SELECT 1 FROM settlement_evidence_archived_credits archived WHERE archived.request_credit_id = lrc.id))`, 1)
	for _, stmt := range []string{
		`CREATE TABLE settlement_evidence_archived_credits (request_credit_id INTEGER PRIMARY KEY)`,
		`DROP VIEW spec022_payable_request_credits`,
		viewSQL,
	} {
		if _, err := store.db.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
}

// archiveEvidence deletes a request's evidence rows the way retention does
// (outputs, verdicts, snapshots) and keeps its settled credit payable.
func archiveEvidence(t *testing.T, store *Store, requestID string) {
	t.Helper()
	for _, stmt := range []string{
		`UPDATE ledger_request_credits SET settled = 1 WHERE request_id = ?`,
		`INSERT INTO settlement_evidence_archived_credits(request_credit_id) SELECT id FROM ledger_request_credits WHERE request_id = ?`,
		`DELETE FROM settlement_attempt_outputs WHERE request_id = ?`,
		`DELETE FROM settlement_receipt_verdicts WHERE request_id = ?`,
		`DELETE FROM settlement_route_snapshots WHERE request_id = ?`,
	} {
		if _, err := store.db.Exec(stmt, requestID); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
}

// SPEC-047-R012 rollup across SPEC-022 R-15 retention: an archived counted
// attempt keeps counting; one archived before any refresh is still captured;
// a label dispute between the last refresh and archival is what freezes; a
// quarantine of an archived attempt's credit stops it counting; a verdict
// that closed before the window start is not re-read; and a cursor reset
// rebuilds without losing archived attempts.
func TestPoolProvenRollupPersistsAcrossArchivingAndReevaluates(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base := settlementVerifierInputFromFixture(t, fixtures, firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done"), pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	simulateEvidenceRetentionView(t, store)
	ctx := context.Background()
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
		if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_id = ?, pool_label_status = 'verified' WHERE request_id = ?`, testPoolID, requestID); err != nil {
			t.Fatal(err)
		}
		return in
	}
	archived := seed("pp-archived")
	disputed := seed("pp-disputed-then-archived")
	reversed := seed("pp-archived-then-reversed")
	hot := seed("pp-hot")
	final := time.UnixMilli(archived.ReceiptReceivedUnixMS).UTC()
	since, until := final.Add(-time.Hour), final.Add(time.Hour)
	counted := func() map[string]bool {
		t.Helper()
		if err := RefreshPoolProvenRollup(ctx, store.db, store.db, since); err != nil {
			t.Fatalf("refresh: %v", err)
		}
		if _, err := QueryPoolProvenAttempts(ctx, store.db, since, until, 10); err != nil {
			t.Fatal(err)
		}
		rows, err := store.db.Query(`SELECT request_id FROM pool_proven_rollup_attempts WHERE counted = 1 AND julianday(finality_at_utc) BETWEEN julianday(?) AND julianday(?)`,
			since.Format(time.RFC3339Nano), until.Format(time.RFC3339Nano))
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]bool{}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				t.Fatal(err)
			}
			out[id] = true
		}
		return out
	}
	want := func(got map[string]bool, ids ...string) {
		t.Helper()
		if len(got) != len(ids) {
			t.Fatalf("counted = %v, want %v", got, ids)
		}
		for _, id := range ids {
			if !got[id] {
				t.Fatalf("counted = %v, want %v", got, ids)
			}
		}
	}
	// Archived before any refresh: the delete trigger captures it.
	archiveEvidence(t, store, archived.RequestID)
	want(counted(), archived.RequestID, disputed.RequestID, reversed.RequestID, hot.RequestID)
	// Disputed after the last refresh, then archived: the trigger freezes the
	// disputed state, not the earlier verified sample.
	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = 'label_disputed' WHERE request_id = ?`, disputed.RequestID); err != nil {
		t.Fatal(err)
	}
	archiveEvidence(t, store, disputed.RequestID)
	archiveEvidence(t, store, reversed.RequestID)
	want(counted(), archived.RequestID, reversed.RequestID, hot.RequestID)
	// The credit of an archived attempt stays live: a quarantine reverses it.
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'test' WHERE request_id = ?`, reversed.RequestID); err != nil {
		t.Fatal(err)
	}
	want(counted(), archived.RequestID, hot.RequestID)
	// A window that starts after every finality time leaves rows unread.
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
	// A cursor reset rebuilds from hot rows and keeps the archived ones.
	if _, err := store.db.Exec(`UPDATE pool_proven_rollup_cursor SET last_route_snapshot_id = 0`); err != nil {
		t.Fatal(err)
	}
	if err := EnsurePoolProvenRollup(ctx, store.db); err != nil {
		t.Fatal(err)
	}
	want(counted(), archived.RequestID, reversed.RequestID, hot.RequestID)
}

// A pass that read an attempt hot, then lost a race with a dispute and
// retention's delete, never overwrites the verdict the delete trigger froze.
// A NULL pool label freezes as not verified in either deletion order instead
// of failing the delete.
func TestPoolProvenRollupFreezeWinsOverAStaleEvaluation(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base := settlementVerifierInputFromFixture(t, fixtures, firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done"), pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	simulateEvidenceRetentionView(t, store)
	ctx := context.Background()
	seed := func(requestID, label string) SettlementVerifyInput {
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
		if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_id = ?, pool_label_status = NULLIF(?, '') WHERE request_id = ?`, testPoolID, label, requestID); err != nil {
			t.Fatal(err)
		}
		return in
	}
	raced := seed("pp-raced", "verified")
	nullVerdictFirst := seed("pp-null-label-verdict-first", "")
	nullSnapshotFirst := seed("pp-null-label-snapshot-first", "")
	since := time.UnixMilli(raced.ReceiptReceivedUnixMS).UTC().Add(-time.Hour)
	poolProvenAfterEvaluateReadHook = func() {
		poolProvenAfterEvaluateReadHook = nil
		if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET pool_label_status = 'label_disputed' WHERE request_id = ?`, raced.RequestID); err != nil {
			t.Error(err)
		}
		archiveEvidence(t, store, raced.RequestID)
	}
	t.Cleanup(func() { poolProvenAfterEvaluateReadHook = nil })
	if err := RefreshPoolProvenRollup(ctx, store.db, store.db, since); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if err := RefreshPoolProvenRollup(ctx, store.db, store.db, since); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	var verdictOK, counted int
	if err := store.db.QueryRow(`SELECT verdict_ok, counted FROM pool_proven_rollup_attempts WHERE request_id = ?`, raced.RequestID).Scan(&verdictOK, &counted); err != nil {
		t.Fatal(err)
	}
	if verdictOK != 0 || counted != 0 {
		t.Fatalf("stale evaluation overwrote the frozen dispute: verdict_ok=%d counted=%d", verdictOK, counted)
	}
	// NULL labels, deleted in both orders.
	archiveEvidence(t, store, nullVerdictFirst.RequestID)
	for _, stmt := range []string{
		`UPDATE ledger_request_credits SET settled = 1 WHERE request_id = ?`,
		`INSERT INTO settlement_evidence_archived_credits(request_credit_id) SELECT id FROM ledger_request_credits WHERE request_id = ?`,
		`DELETE FROM settlement_route_snapshots WHERE request_id = ?`,
		`DELETE FROM settlement_receipt_verdicts WHERE request_id = ?`,
	} {
		if _, err := store.db.Exec(stmt, nullSnapshotFirst.RequestID); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	if err := RefreshPoolProvenRollup(ctx, store.db, store.db, since); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	var total int
	if err := store.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(counted), 0) FROM pool_proven_rollup_attempts`).Scan(&total, &counted); err != nil {
		t.Fatal(err)
	}
	if total != 3 || counted != 0 {
		t.Fatalf("rollup rows=%d counted=%d, want three uncounted attempts", total, counted)
	}
}

// The rollup's reads never scan the ledger, snapshot, or verdict tables: the
// capture reads a rowid range and every evaluation join is a key lookup. The
// pre-rollup query drove the payable view over every enforce-mode credit and
// timed out on a production-size ledger.
func TestPoolProvenRollupQueryPlansAvoidFullScans(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	if _, err := store.db.Exec(`ANALYZE`); err != nil {
		t.Fatal(err)
	}
	// The delete triggers' capture lookups, with OLD bound to one row.
	triggerCapture := func(table, capture string) string {
		return `SELECT o.id FROM ` + table + ` o WHERE o.id = ? AND EXISTS (` + capture + `)`
	}
	plans := map[string][]any{
		"snapshot-delete capture": {triggerCapture("settlement_route_snapshots", poolProvenSnapshotDeleteCaptureSQL("o")), 1},
		"verdict-delete capture":  {triggerCapture("settlement_receipt_verdicts", poolProvenVerdictDeleteCaptureSQL("o")), 1},
		"capture":                 {poolProvenCaptureSQL(), 0, 10},
		"evaluate":                {poolProvenEvaluateSQL(), 0, time.Now().UTC().Format(time.RFC3339Nano), poolProvenEvaluateBatch},
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
		if len(plan) == 0 {
			t.Fatalf("%s: empty plan", name)
		}
		for _, line := range plan {
			if strings.HasPrefix(line, "SCAN ") || strings.Contains(line, "TEMP B-TREE") {
				t.Fatalf("%s plan has %q:\n%s", name, line, strings.Join(plan, "\n"))
			}
		}
	}
}
