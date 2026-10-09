package rewards

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestDistinctUnlockPairRequiresDistinctCriteria(t *testing.T) {
	if distinctUnlockPair([]string{CriterionE2WalletEconomic}, []string{CriterionWalletBalance72h}) {
		t.Fatal("wallet-only pair must not unlock")
	}
	if !distinctUnlockPair([]string{CriterionE1Receipts}, []string{CriterionAppAttest}) {
		t.Fatal("E1 + app attest should unlock")
	}
}

func TestCriteriaOverlap(t *testing.T) {
	if !criteriaOverlap(CriterionE1Receipts, CriterionE1Receipts) {
		t.Fatal("same criterion must overlap")
	}
	if !criteriaOverlap(CriterionE2WalletEconomic, CriterionWalletBalance72h) {
		t.Fatal("E2 and A3 must overlap")
	}
}

func TestSatisfiedCriteriaE1CountsBothSlots(t *testing.T) {
	econ, addl := satisfiedCriteria(satisfiedInput{ReceiptCount: 100})
	if len(econ) != 1 || len(addl) != 1 {
		t.Fatalf("econ=%v addl=%v", econ, addl)
	}
	if distinctUnlockPair(econ, addl) {
		t.Fatal("E1 alone in both slots must not unlock")
	}
}

// SPEC-022 R-15.6: verdicts moved to the settled-evidence archive still
// count toward the E1 verified-receipt threshold.
func TestCountVerifiedReceiptsIncludesArchivedVerdicts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "billing.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
CREATE TABLE settlement_receipt_verdicts (
    id INTEGER PRIMARY KEY, provider_id TEXT NOT NULL, closed INTEGER NOT NULL,
    settlement_outcome TEXT NOT NULL, receipt_result TEXT NOT NULL
);
INSERT INTO settlement_receipt_verdicts (provider_id, closed, settlement_outcome, receipt_result)
VALUES ('p', 1, 'verified', 'valid'), ('p', 1, 'zero_settled', 'valid'), ('q', 1, 'verified', 'valid');
`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	runner := &Runner{cfg: Config{SQLitePayoutDBPath: path}}
	if got, err := runner.countVerifiedReceipts(context.Background(), "p"); err != nil || got != 1 {
		t.Fatalf("hot-only count=%d err=%v want 1", got, err)
	}
	db, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
CREATE TABLE settlement_evidence_archived_verdict_counts (
    provider_id TEXT NOT NULL, settlement_outcome TEXT NOT NULL, receipt_result TEXT NOT NULL,
    verdict_count INTEGER NOT NULL, PRIMARY KEY(provider_id, settlement_outcome, receipt_result)
);
INSERT INTO settlement_evidence_archived_verdict_counts VALUES
    ('p', 'verified', 'valid', 120), ('p', 'zero_settled', 'valid', 7), ('q', 'verified', 'valid', 5);
`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if got, err := runner.countVerifiedReceipts(context.Background(), "p"); err != nil || got != 121 {
		t.Fatalf("hot+archived count=%d err=%v want 121", got, err)
	}
}
