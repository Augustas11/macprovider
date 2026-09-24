package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// SPEC-042 R006 pool label status on a settlement-receipt verdict row. Only
// PoolLabelStatusVerified may count toward pool-scoped accounting. A disputed,
// unverified, or never-recorded (NULL) label still settles under the unchanged
// SPEC-005 rules; it is only kept out of per-pool attribution.
const (
	PoolLabelStatusVerified   = "verified"
	PoolLabelStatusDisputed   = "label_disputed"
	PoolLabelStatusUnverified = "unverified"
)

// SettlementPoolLabels are the pool labels observed at settlement time. They
// are compared with the routing-time labels bound into the route snapshot
// digest.
type SettlementPoolLabels struct {
	PoolID             string
	ManifestVersion    uint64
	ManifestCoreDigest string
	// RouteSnapshotHash is the digest the router recorded at routing time.
	// Empty means the caller did not hold one, and it is not compared.
	RouteSnapshotHash string
}

// SettlementPoolLabelRecord is what RecordSettlementPoolLabels wrote.
type SettlementPoolLabelRecord struct {
	PoolID             string
	ManifestVersion    uint64
	ManifestCoreDigest string
	RouteSnapshotHash  string
	Status             string
}

// settlementPoolLabelStatus returns "" for global traffic, which leaves global
// verdict rows byte-identical to the pre-R006 shape.
func settlementPoolLabelStatus(route RouteSnapshot, routeHash string, labels *SettlementPoolLabels) string {
	if route.PoolID == "" {
		if labels != nil && labels.PoolID != "" {
			return PoolLabelStatusDisputed
		}
		return ""
	}
	if labels == nil {
		return PoolLabelStatusUnverified
	}
	if labels.PoolID != route.PoolID ||
		labels.ManifestVersion != route.ManifestVersion ||
		labels.ManifestCoreDigest != route.ManifestCoreDigest ||
		(labels.RouteSnapshotHash != "" && labels.RouteSnapshotHash != routeHash) {
		return PoolLabelStatusDisputed
	}
	return PoolLabelStatusVerified
}

// RecordSettlementPoolLabels stamps the SPEC-042 R006 labels onto an existing
// settlement-receipt verdict row. It runs after the verdict is written and
// never touches outcome, usage, or ledger columns, so settlement arithmetic is
// unchanged. The routing-time labels come from the digest-verified route
// snapshot; labels are the settlement-time view. A disputed status is sticky.
// It returns a zero record when the attempt is global or has no verdict row.
func (s *Store) RecordSettlementPoolLabels(ctx context.Context, id SettlementReceiptIdentity, labels *SettlementPoolLabels) (SettlementPoolLabelRecord, error) {
	if s == nil || s.db == nil {
		return SettlementPoolLabelRecord{}, fmt.Errorf("billing store is closed")
	}
	if err := id.validate(); err != nil {
		return SettlementPoolLabelRecord{}, err
	}
	var out SettlementPoolLabelRecord
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		route, routeHash, err := loadSettlementRouteSnapshotConn(ctx, conn, id)
		if err != nil {
			return err
		}
		status := settlementPoolLabelStatus(route, routeHash, labels)
		if status == "" {
			return nil
		}
		poolID := route.PoolID
		if poolID == "" {
			poolID = labels.PoolID
		}
		var manifestVersion sql.NullInt64
		if route.ManifestVersion != 0 {
			manifestVersion = sql.NullInt64{Int64: int64(route.ManifestVersion), Valid: true}
		}
		var recorded string
		err = conn.QueryRowContext(ctx, `
UPDATE settlement_receipt_verdicts
   SET pool_id = ?,
       pool_manifest_version = ?,
       pool_manifest_core_digest = ?,
       pool_label_status = CASE WHEN pool_label_status = 'label_disputed' THEN 'label_disputed' ELSE ? END
 WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
   AND route_snapshot_digest = ?
RETURNING pool_label_status`,
			poolID, manifestVersion, nullString(route.ManifestCoreDigest), status,
			redactedAccountScopeHash(id.AccountScope), id.RequestID, id.AttemptN, id.ProviderID,
			routeHash,
		).Scan(&recorded)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		out = SettlementPoolLabelRecord{
			PoolID:             poolID,
			ManifestVersion:    route.ManifestVersion,
			ManifestCoreDigest: route.ManifestCoreDigest,
			RouteSnapshotHash:  routeHash,
			Status:             recorded,
		}
		return nil
	})
	if err != nil {
		return SettlementPoolLabelRecord{}, err
	}
	return out, nil
}

func (s *Store) ensureSettlementReceiptPoolLabelColumns(ctx context.Context) error {
	add := []struct {
		name string
		sql  string
	}{
		{"pool_id", `ALTER TABLE settlement_receipt_verdicts ADD COLUMN pool_id TEXT NULL`},
		{"pool_manifest_version", `ALTER TABLE settlement_receipt_verdicts ADD COLUMN pool_manifest_version INTEGER NULL CHECK(pool_manifest_version IS NULL OR pool_manifest_version > 0)`},
		{"pool_manifest_core_digest", `ALTER TABLE settlement_receipt_verdicts ADD COLUMN pool_manifest_core_digest TEXT NULL CHECK(pool_manifest_core_digest IS NULL OR (length(pool_manifest_core_digest) = 64 AND pool_manifest_core_digest NOT GLOB '*[^0-9a-f]*'))`},
		{"pool_label_status", `ALTER TABLE settlement_receipt_verdicts ADD COLUMN pool_label_status TEXT NULL CHECK(pool_label_status IS NULL OR pool_label_status IN ('verified','label_disputed','unverified'))`},
	}
	for _, col := range add {
		exists, err := s.columnExists(ctx, "settlement_receipt_verdicts", col.name)
		if err != nil {
			return err
		}
		if exists {
			continue
		}
		if _, err := s.db.ExecContext(ctx, col.sql); err != nil {
			return err
		}
	}
	return nil
}
