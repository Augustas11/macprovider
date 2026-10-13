package billing

import (
	"context"
	"strconv"
	"testing"
	"time"
)

// SPEC-022 R-15.10: only rows drained into the audit database before the
// cutoff leave; undelivered and poisoned rows stay for the drainer and the
// operator.
func TestSettlementReceiptAuditOutboxPruneKeepsPoisonedAndUndeliveredRows(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	in := f.seed(t, "a")
	f.addDrainedOutbox(t, "a", true, false)  // drained long ago: pruned
	f.addDrainedOutbox(t, "a", false, false) // undelivered: kept
	f.addDrainedOutbox(t, "a", false, true)  // poisoned: kept
	f.addDrainedOutbox(t, "a", true, true)   // poisoned and stamped drained: kept
	f.addDrainedOutbox(t, "a", true, false)  // drained inside the window: kept
	recentID := scalar(t, f.store.db, `SELECT MAX(id) FROM settlement_receipt_audit_outbox`)
	if _, err := f.store.db.Exec(`UPDATE settlement_receipt_audit_outbox SET drained_at_utc = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339Nano), recentID); err != nil {
		t.Fatal(err)
	}

	pruned, err := f.store.PruneSettlementReceiptAuditOutbox(ctx, time.Now().UTC().Add(-24*time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	if pruned != 1 {
		t.Fatalf("pruned=%d want 1", pruned)
	}
	for _, check := range []struct {
		name  string
		query string
		want  int64
	}{
		{"undelivered", `drained_at_utc IS NULL AND poisoned_at_utc IS NULL`, 1},
		{"poisoned", `poisoned_at_utc IS NOT NULL`, 2},
		{"recently drained", `id = ` + strconv.FormatInt(recentID, 10), 1},
		{"all", `1 = 1`, 4},
	} {
		if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox WHERE request_id = ? AND `+check.query, in.RequestID); got != check.want {
			t.Fatalf("%s rows=%d want %d", check.name, got, check.want)
		}
	}
}

// Retention only loops over outbox rows that exist: a request whose drained
// outbox rows were pruned stays eligible and archives without them.
func TestEvidenceRetentionAfterDrainedOutboxPrune(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.addDrainedOutbox(t, "b", true, false)
	if pruned, err := f.store.PruneSettlementReceiptAuditOutbox(ctx, time.Now().UTC().Add(-24*time.Hour), 100); err != nil || pruned != 1 {
		t.Fatalf("pruned=%d err=%v", pruned, err)
	}
	f.settle(t)
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || report.DeletedRequests != 1 {
		t.Fatalf("run report=%+v", report)
	}
	if f.hotRows(t, "b") != 0 {
		t.Fatalf("hot rows b=%d want 0", f.hotRows(t, "b"))
	}
	if st := report.Tables["settlement_receipt_audit_outbox"]; st.Rows != 0 {
		t.Fatalf("archived outbox rows=%+v want 0", st)
	}
}
