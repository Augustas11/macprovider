package rewards

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

func explainPlan(t *testing.T, db *sql.DB, query string, args ...any) string {
	t.Helper()
	rows, err := db.QueryContext(context.Background(), "EXPLAIN QUERY PLAN "+query, args...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, unused int
		var detail string
		if err := rows.Scan(&id, &parent, &unused, &detail); err != nil {
			t.Fatal(err)
		}
		plan = append(plan, detail)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return strings.Join(plan, "\n")
}

func assertNoSQLiteStats(t *testing.T, db *sql.DB) {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'sqlite_stat1'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("fixture must not carry sqlite_stat1; the regression is the stats-less plan")
	}
}

// The production billing schema without sqlite_stat1 is what Pearl runs. The
// count must walk idx_srv_provider_recent, not the fleet-wide idx_srv_outcome.
func TestCountVerifiedReceiptsUsesProviderIndexOnBillingSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "billing.db")
	store, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	db := store.DB()
	if _, err := billing.NewStore(db); err != nil {
		t.Fatal(err)
	}
	assertNoSQLiteStats(t, db)

	plan := explainPlan(t, db, countVerifiedReceiptsSQL, "provider-a")
	if !strings.Contains(plan, "USING INDEX idx_srv_provider_recent (provider_id=?)") || strings.Contains(plan, "idx_srv_outcome") {
		t.Fatalf("count does not search idx_srv_provider_recent:\n%s", plan)
	}

	runner := &Runner{payoutReader: db, cfg: Config{SQLitePayoutDBPath: filepath.Join(t.TempDir(), "unused.sqlite")}}
	count, err := runner.countVerifiedReceipts(context.Background(), "provider-a")
	if err != nil || count != 0 {
		t.Fatalf("count on shared reader = %d, %v; want 0, nil", count, err)
	}
}

func TestCountVerifiedReceiptsSeededPlanAndCount(t *testing.T) {
	path := filepath.Join(t.TempDir(), "verdicts.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// Same indexes as internal/billing/store.go; minimal columns so rows can
	// be seeded without the full receipt payload.
	if _, err := db.Exec(`
CREATE TABLE settlement_receipt_verdicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    received_at_unix_ms INTEGER NOT NULL,
    closed INTEGER NOT NULL,
    settlement_outcome TEXT NOT NULL,
    receipt_result TEXT NOT NULL
);
CREATE INDEX idx_srv_outcome ON settlement_receipt_verdicts(settlement_outcome, closed, received_at_unix_ms);
CREATE INDEX idx_srv_provider_recent ON settlement_receipt_verdicts(provider_id, received_at_unix_ms DESC, id DESC);
`); err != nil {
		t.Fatal(err)
	}
	insert := func(provider string, closed int, outcome, result string, n int) {
		t.Helper()
		for i := 0; i < n; i++ {
			if _, err := db.Exec(`INSERT INTO settlement_receipt_verdicts
                (provider_id, received_at_unix_ms, closed, settlement_outcome, receipt_result)
                VALUES (?, ?, ?, ?, ?)`, provider, 1_700_000_000_000+i, closed, outcome, result); err != nil {
				t.Fatal(err)
			}
		}
	}
	insert("provider-a", 1, "verified", "valid", 7)
	insert("provider-a", 0, "verified", "valid", 2)
	insert("provider-a", 1, "quarantined", "valid", 3)
	insert("provider-a", 1, "verified", "invalid", 4)
	for i := 0; i < 20; i++ {
		insert(fmt.Sprintf("fleet-%02d", i), 1, "verified", "valid", 5)
	}
	assertNoSQLiteStats(t, db)

	unpinned := strings.Replace(countVerifiedReceiptsSQL, " INDEXED BY idx_srv_provider_recent", "", 1)
	t.Logf("default plan (no INDEXED BY):\n%s", explainPlan(t, db, unpinned, "provider-a"))
	plan := explainPlan(t, db, countVerifiedReceiptsSQL, "provider-a")
	t.Logf("pinned plan:\n%s", plan)
	if !strings.Contains(plan, "USING INDEX idx_srv_provider_recent (provider_id=?)") {
		t.Fatalf("count does not search idx_srv_provider_recent:\n%s", plan)
	}

	var want int
	if err := db.QueryRow(unpinned, "provider-a").Scan(&want); err != nil {
		t.Fatal(err)
	}
	// Fallback path: no shared reader, per-call read-only connection.
	runner := &Runner{cfg: Config{SQLitePayoutDBPath: path}}
	got, err := runner.countVerifiedReceipts(context.Background(), "provider-a")
	if err != nil || got != 7 || got != want {
		t.Fatalf("count = %d, %v; want 7 (unpinned %d)", got, err, want)
	}
	runner = &Runner{payoutReader: db}
	got, err = runner.countVerifiedReceipts(context.Background(), "provider-a")
	if err != nil || got != 7 {
		t.Fatalf("shared reader count = %d, %v; want 7", got, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runner.countVerifiedReceipts(ctx, "provider-a"); err == nil {
		t.Fatal("canceled read must surface an error, not a zero count")
	}
}

func TestRewardHandlersLogProjectionFailure(t *testing.T) {
	broken, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "rewards.db"))
	if err != nil {
		t.Fatal(err)
	}
	_ = broken.Close()
	const token = "secret-provider-token"
	tokens := &readOnlyAuditTokens{providerID: "provider-log"}
	for _, tc := range []struct {
		name    string
		handler func(zerolog.Logger) http.Handler
		path    string
		msg     string
	}{
		{
			name: "accrual",
			handler: func(l zerolog.Logger) http.Handler {
				return NewAccrualHandler(AccrualHandlerDeps{DB: broken, TokenStore: tokens, RequireProviderTokens: true, Logger: l})
			},
			path: "/v1/provider/malibu-accrual",
			msg:  "malibu accrual projection failed",
		},
		{
			name: "wallet",
			handler: func(l zerolog.Logger) http.Handler {
				return NewWalletStatusHandler(WalletHandlerDeps{RewardsDB: broken, TokenStore: tokens, RequireProviderTokens: true, Logger: l})
			},
			path: "/v1/provider/wallet",
			msg:  "provider wallet projection failed",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			req.Header.Set("Authorization", "Bearer "+token)
			rec := httptest.NewRecorder()
			tc.handler(zerolog.New(&buf)).ServeHTTP(rec, req)
			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
			}
			logged := buf.String()
			if !strings.Contains(logged, `"level":"warn"`) || !strings.Contains(logged, tc.msg) || !strings.Contains(logged, `"provider_id":"provider-log"`) || !strings.Contains(logged, `"error":`) {
				t.Fatalf("missing warn log: %q", logged)
			}
			if strings.Contains(logged, token) {
				t.Fatalf("log leaked bearer token: %q", logged)
			}
		})
	}
}
