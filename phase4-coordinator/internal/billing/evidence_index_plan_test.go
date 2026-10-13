package billing

import (
	"context"
	"strings"
	"testing"
)

var droppedJournalIndexes = []string{"idx_srsj_request", "idx_srsj_provider", "idx_srsj_digest"}

// SPEC-022 R-15.10: startup drops the redundant evidence indexes created by
// an earlier release, and a fresh database never has them.
func TestMigrateDropsRedundantEvidenceIndexes(t *testing.T) {
	ctx := context.Background()
	store, journalDB := newJournalPruneStore(t)
	assertNoIndex := func(stage string) {
		t.Helper()
		for _, name := range redundantEvidenceIndexes {
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?`, name); got != 0 {
				t.Fatalf("%s: index %s still exists", stage, name)
			}
		}
		for _, name := range droppedJournalIndexes {
			if got := scalar(t, journalDB, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?`, name); got != 0 {
				t.Fatalf("%s: journal index %s still exists", stage, name)
			}
		}
	}
	assertNoIndex("fresh")
	for _, stmt := range []string{
		`CREATE INDEX idx_lrc_request ON ledger_request_credits(request_id)`,
		`CREATE INDEX idx_srs_request ON settlement_route_snapshots(account_scope, request_id, attempt_n)`,
		`CREATE INDEX idx_srs_digest ON settlement_route_snapshots(route_snapshot_digest)`,
		`CREATE INDEX idx_sao_output_hash ON settlement_attempt_outputs(output_hash)`,
		`CREATE INDEX idx_srv_request ON settlement_receipt_verdicts(account_scope_hash, request_id, attempt_n)`,
	} {
		if _, err := store.db.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	for _, stmt := range []string{
		`CREATE INDEX idx_srsj_request ON settlement_route_snapshot_journal(account_scope, request_id, attempt_n)`,
		`CREATE INDEX idx_srsj_provider ON settlement_route_snapshot_journal(provider_id, created_at_utc)`,
		`CREATE INDEX idx_srsj_digest ON settlement_route_snapshot_journal(route_snapshot_digest)`,
	} {
		if _, err := journalDB.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if err := store.InitRouteSnapshotJournal(ctx); err != nil {
		t.Fatal(err)
	}
	assertNoIndex("reopened")
}

// Every query shape that read a dropped index still searches an index: the
// table's unique key, the SPEC-022 payable indexes, or idx_sao_request_range.
// Only the admin verdict counters scan, as they did before (a full GROUP BY).
func TestEvidenceQueriesKeepIndexedPlansWithoutDroppedIndexes(t *testing.T) {
	store, journalDB := newJournalPruneStore(t)
	dropped := append(append([]string{}, redundantEvidenceIndexes...), droppedJournalIndexes...)
	for _, q := range []struct {
		name  string
		db    string
		query string
		args  []any
	}{
		{"credits by request", "main", `SELECT id FROM ledger_request_credits WHERE request_id = ?`, []any{"r"}},
		{"snapshots by scope and request", "main", `SELECT * FROM settlement_route_snapshots WHERE account_scope = ? AND request_id = ? ORDER BY id`, []any{"a", "r"}},
		{"snapshots by request", "main", `SELECT COUNT(*) FROM settlement_route_snapshots srs WHERE srs.request_id = ?`, []any{"r"}},
		{"snapshot digest by attempt", "main", `SELECT route_snapshot_digest FROM settlement_route_snapshots WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`, []any{"a", "r", 0, "p"}},
		{"verdicts by scope and request", "main", `SELECT * FROM settlement_receipt_verdicts WHERE account_scope_hash = ? AND request_id = ?`, []any{"h", "r"}},
		{"finality lookup", "main", `
SELECT srv.attempt_n, COALESCE(srs.paid_entrypoint, '')
  FROM settlement_receipt_verdicts srv
  LEFT JOIN settlement_route_snapshots srs
    ON srs.account_scope = ? AND srs.request_id = srv.request_id AND srs.attempt_n = srv.attempt_n
   AND srs.provider_id = srv.provider_id AND srs.route_snapshot_digest = srv.route_snapshot_digest
 WHERE srv.account_scope_hash = ? AND srv.request_id = ?
 ORDER BY srv.attempt_n ASC, srv.id ASC`, []any{"a", "h", "r"}},
		{"relay-blind bound attempt", "main", `
SELECT EXISTS (SELECT 1 FROM settlement_receipt_verdicts srv
  JOIN settlement_route_snapshots srs
    ON srs.request_id = srv.request_id AND srs.attempt_n = srv.attempt_n
   AND srs.provider_id = srv.provider_id AND srs.route_snapshot_digest = srv.route_snapshot_digest
 WHERE srv.account_scope_hash = ? AND srv.request_id = ? AND srv.provider_id = ? AND srv.closed = 1)`, []any{"h", "r", "p"}},
		{"pool sweep join", "main", `
SELECT v.id, rs.id FROM settlement_receipt_verdicts v
  JOIN settlement_route_snapshots rs
    ON rs.route_snapshot_digest = v.route_snapshot_digest AND rs.request_id = v.request_id
   AND rs.attempt_n = v.attempt_n AND rs.provider_id = v.provider_id
 WHERE v.settlement_outcome = 'pending' AND v.closed = 0 AND v.pending_deadline_unix_ms > 0 AND v.pending_deadline_unix_ms < ?
 ORDER BY v.pending_deadline_unix_ms, v.id, rs.id LIMIT 10`, []any{1}},
		{"output overlap", "main", `
SELECT COUNT(*) FROM settlement_attempt_outputs
 WHERE account_scope = ? AND request_id = ? AND NOT (attempt_n = ? AND provider_id = ?)
   AND (NOT (output_prefix_end_byte <= ? OR output_prefix_start_byte >= ?) OR output_hash = ?)`, []any{"a", "r", 0, "p", 0, 1, "x"}},
		{"journal by attempt", "journal", `SELECT id FROM settlement_route_snapshot_journal WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`, []any{"a", "r", 0, "p"}},
		{"journal by scope and request", "journal", `SELECT * FROM settlement_route_snapshot_journal WHERE account_scope = ? AND request_id = ? ORDER BY id`, []any{"a", "r"}},
		{"journal prune walk", "journal", `SELECT id FROM settlement_route_snapshot_journal WHERE id > ? ORDER BY id LIMIT ?`, []any{0, 10}},
	} {
		db := store.db
		if q.db == "journal" {
			db = journalDB
		}
		plan := explainQueryPlan(t, db, q.query, q.args...)
		for _, step := range strings.Split(plan, " | ") {
			if strings.HasPrefix(step, "SCAN ") && !strings.Contains(step, "CONSTANT ROW") {
				t.Errorf("%s: full scan %q (plan %q)", q.name, step, plan)
			}
		}
		for _, name := range dropped {
			if strings.Contains(plan, name) {
				t.Errorf("%s: plan uses dropped index %s", q.name, name)
			}
		}
	}
}
