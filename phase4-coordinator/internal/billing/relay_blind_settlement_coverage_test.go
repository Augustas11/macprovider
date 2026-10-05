package billing

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

func insertRelayBlindRequestLogRow(t *testing.T, store *Store, accountID, externalRequestID, internalRequestID, bindingDigest, envelopeDigest string) {
	t.Helper()
	if _, err := store.db.Exec(`INSERT INTO request_log (ts_utc, request_id, external_request_id, account_id, model, latency_ms, routing_ms, status, stream,
		relay_blind_provider_binding_digest, relay_blind_envelope_digest)
		VALUES ('2026-10-05T00:00:00Z', ?, ?, ?, 'model', 0, 0, 200, 0, ?, ?)`,
		internalRequestID, externalRequestID, accountID, bindingDigest, envelopeDigest); err != nil {
		t.Fatal(err)
	}
}

// SPEC-022 R-14: the coordinator, not a header the gateway saw, says whether
// a relay-blind attempt was enforce-covered. Enforce needs an enforce
// relay-blind snapshot whose envelope digest and recorded provider-binding
// digest are the ones asked for; observe needs the attempt's request-log row
// with the same binding and envelope digests and no relay-blind snapshot;
// anything else is unknown.
func TestRelayBlindSettlementCoverageIsCoordinatorAuthority(t *testing.T) {
	ctx := context.Background()
	const account = "acct_rb_coverage"
	binding := strings.Repeat("B", 43)
	envelope := strings.Repeat("E", 43)
	snapshotBinding := relayBlindVectorDigest("vector provider binding")
	snapshotEnvelope := relayBlindVectorDigest("vector envelope bytes")

	enforce := seedRelayBlindAttempt(t, func(s *RouteSnapshot) { s.AccountScope = AccountScopeForSettlement(account) })
	internalID := enforce.identity.RequestID
	got, err := enforce.store.RelayBlindSettlementCoverage(ctx, account, "ext-1", internalID, snapshotBinding, snapshotEnvelope)
	if err != nil || got != RelayBlindCoverageEnforce {
		t.Fatalf("enforce snapshot coverage=%q err=%v", got, err)
	}
	// A crossed or replayed internal id names this snapshot with another
	// attempt's digests: the coordinator does not answer enforce for it.
	for name, args := range map[string][2]string{
		"wrong envelope digest": {snapshotBinding, relayBlindVectorDigest("other envelope bytes")},
		"wrong binding digest":  {relayBlindVectorDigest("other provider binding"), snapshotEnvelope},
		"both digests wrong":    {binding, envelope},
	} {
		if got, err := enforce.store.RelayBlindSettlementCoverage(ctx, account, "ext-1", internalID, args[0], args[1]); err != nil || got != "" {
			t.Fatalf("%s: coverage=%q err=%v, want unknown", name, got, err)
		}
	}
	// A request-log row never downgrades an enforce snapshot, and never
	// substitutes for a binding the snapshot recorded differently.
	insertRelayBlindRequestLogRow(t, enforce.store, account, "ext-1", internalID, snapshotBinding, snapshotEnvelope)
	if got, err := enforce.store.RelayBlindSettlementCoverage(ctx, account, "ext-1", internalID, snapshotBinding, snapshotEnvelope); err != nil || got != RelayBlindCoverageEnforce {
		t.Fatalf("enforce snapshot with request log coverage=%q err=%v", got, err)
	}
	wrongBinding := relayBlindVectorDigest("other provider binding")
	insertRelayBlindRequestLogRow(t, enforce.store, account, "ext-1", internalID, wrongBinding, snapshotEnvelope)
	if got, err := enforce.store.RelayBlindSettlementCoverage(ctx, account, "ext-1", internalID, wrongBinding, snapshotEnvelope); err != nil || got != "" {
		t.Fatalf("logged wrong binding coverage=%q err=%v, want unknown", got, err)
	}
	// Another account never sees the snapshot.
	if got, err := enforce.store.RelayBlindSettlementCoverage(ctx, "acct_other", "ext-1", internalID, snapshotBinding, snapshotEnvelope); err != nil || got != "" {
		t.Fatalf("cross-account coverage=%q err=%v", got, err)
	}

	// A snapshot committed before the binding column existed is bound
	// through the attempt's request-log row instead, still with both digests.
	legacy := seedRelayBlindAttempt(t, func(s *RouteSnapshot) {
		s.AccountScope = AccountScopeForSettlement(account)
		s.RelayBlindProviderBindingDigest = ""
	})
	legacyID := legacy.identity.RequestID
	if got, err := legacy.store.RelayBlindSettlementCoverage(ctx, account, "ext-3", legacyID, snapshotBinding, snapshotEnvelope); err != nil || got != "" {
		t.Fatalf("legacy snapshot without request log coverage=%q err=%v, want unknown", got, err)
	}
	insertRelayBlindRequestLogRow(t, legacy.store, account, "ext-3", legacyID, snapshotBinding, snapshotEnvelope)
	if got, err := legacy.store.RelayBlindSettlementCoverage(ctx, account, "ext-3", legacyID, snapshotBinding, snapshotEnvelope); err != nil || got != RelayBlindCoverageEnforce {
		t.Fatalf("legacy snapshot with request log coverage=%q err=%v", got, err)
	}
	for name, args := range map[string][2]string{
		"legacy wrong binding":  {wrongBinding, snapshotEnvelope},
		"legacy wrong envelope": {snapshotBinding, relayBlindVectorDigest("other envelope bytes")},
	} {
		if got, err := legacy.store.RelayBlindSettlementCoverage(ctx, account, "ext-3", legacyID, args[0], args[1]); err != nil || got != "" {
			t.Fatalf("%s: coverage=%q err=%v, want unknown", name, got, err)
		}
	}

	_, store := newRequestAndBillingStores(t)
	if got, err := store.RelayBlindSettlementCoverage(ctx, account, "ext-2", "internal-observe", binding, envelope); err != nil || got != "" {
		t.Fatalf("unknown attempt coverage=%q err=%v", got, err)
	}
	insertRelayBlindRequestLogRow(t, store, account, "ext-2", "internal-observe", binding, envelope)
	if got, err := store.RelayBlindSettlementCoverage(ctx, account, "ext-2", "internal-observe", binding, envelope); err != nil || got != RelayBlindCoverageObserve {
		t.Fatalf("observe attempt coverage=%q err=%v", got, err)
	}
	for name, args := range map[string][5]string{
		"other external request": {account, "ext-x", "internal-observe", binding, envelope},
		"other binding":          {account, "ext-2", "internal-observe", strings.Repeat("C", 43), envelope},
		"other envelope":         {account, "ext-2", "internal-observe", binding, strings.Repeat("F", 43)},
		"other account":          {"acct_other", "ext-2", "internal-observe", binding, envelope},
		"other attempt":          {account, "ext-2", "internal-other", binding, envelope},
		"blank internal id":      {account, "ext-2", "", binding, envelope},
	} {
		if got, err := store.RelayBlindSettlementCoverage(ctx, args[0], args[1], args[2], args[3], args[4]); err != nil || got != "" {
			t.Fatalf("%s: coverage=%q err=%v, want unknown", name, got, err)
		}
	}
}

// The relay-blind provider-binding digest rides beside the snapshot through
// the route-snapshot journal into the primary row, outside the digested
// preimage, so a journal-backed enforce attempt is bound the same way.
func TestRelayBlindBindingDigestSurvivesRouteSnapshotJournal(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqStore, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	store, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
	if err != nil {
		t.Fatal(err)
	}
	journalDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = journalDB.Close() })
	store.SetRouteSnapshotJournalDB(journalDB)
	ctx := context.Background()
	for i := 0; i < 2; i++ { // the column migration is idempotent
		if err := store.InitRouteSnapshotJournal(ctx); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := relayBlindSignedInputWithSnapshot(t, nil, nil).RouteSnapshot
	withoutBinding := snapshot
	withoutBinding.RelayBlindProviderBindingDigest = ""
	wantDigest, _, err := withoutBinding.Digest()
	if err != nil {
		t.Fatal(err)
	}
	digest, err := store.InsertRouteSnapshot(ctx, snapshot)
	if err != nil || digest != wantDigest {
		t.Fatalf("digest=%s want %s (binding must stay outside the preimage) err=%v", digest, wantDigest, err)
	}
	if _, err := store.db.Exec(`DELETE FROM settlement_route_snapshots`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MirrorPendingRouteSnapshots(ctx, 10); err != nil {
		t.Fatal(err)
	}
	var stored string
	if err := store.db.QueryRow(`SELECT relay_blind_provider_binding_digest FROM settlement_route_snapshots WHERE request_id = ?`, snapshot.RequestID).Scan(&stored); err != nil || stored != snapshot.RelayBlindProviderBindingDigest {
		t.Fatalf("mirrored binding=%q want %q err=%v", stored, snapshot.RelayBlindProviderBindingDigest, err)
	}
	bad := snapshot
	bad.RequestID = "bad-binding"
	bad.RelayBlindProviderBindingDigest = strings.Repeat("B", 43)
	if _, err := store.InsertRouteSnapshot(ctx, bad); err == nil {
		t.Fatal("non-canonical binding digest accepted")
	}
}

// An existing table gains the binding column through ALTER TABLE without a
// CHECK, so startup never validates every historical snapshot row.
func TestRelayBlindBindingDigestColumnAddsToExistingTablesWithoutCheck(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqStore, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	store, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
	if err != nil {
		t.Fatal(err)
	}
	journalDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = journalDB.Close() })
	store.SetRouteSnapshotJournalDB(journalDB)
	ctx := context.Background()
	if err := store.InitRouteSnapshotJournal(ctx); err != nil {
		t.Fatal(err)
	}
	for _, db := range []*sql.DB{reqStore.DB(), journalDB} {
		table := "settlement_route_snapshots"
		if db == journalDB {
			table = "settlement_route_snapshot_journal"
		}
		if _, err := db.ExecContext(ctx, `ALTER TABLE `+table+` DROP COLUMN relay_blind_provider_binding_digest`); err != nil {
			t.Fatalf("drop %s: %v", table, err)
		}
	}
	if err := store.ensureSettlementRouteSnapshotComputeIntegrityColumns(ctx); err != nil {
		t.Fatal(err)
	}
	if err := store.InitRouteSnapshotJournal(ctx); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		db    *sql.DB
		table string
	}{{reqStore.DB(), "settlement_route_snapshots"}, {journalDB, "settlement_route_snapshot_journal"}} {
		var n int
		if err := c.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pragma_table_info('`+c.table+`') WHERE name = 'relay_blind_provider_binding_digest'`).Scan(&n); err != nil || n != 1 {
			t.Fatalf("%s binding column after migration: n=%d err=%v", c.table, n, err)
		}
		var ddl string
		if err := c.db.QueryRowContext(ctx, `SELECT sql FROM sqlite_master WHERE type='table' AND name=?`, c.table).Scan(&ddl); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(ddl, "CHECK(relay_blind_provider_binding_digest") {
			t.Fatalf("%s: added column must not carry a CHECK: %s", c.table, ddl)
		}
	}
	bad := relayBlindSignedInputWithSnapshot(t, nil, nil).RouteSnapshot
	bad.RelayBlindProviderBindingDigest = "not-canonical"
	if err := bad.Validate(); err == nil {
		t.Fatal("Validate must reject a non-canonical binding before insert")
	}
}
