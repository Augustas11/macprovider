package billing

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// PoolProvenAttempt is one SPEC-047-R012 counted attempt: a settled paid
// attempt whose immutable route snapshot took its expected identity from a
// pool manifest entry. It carries the snapshot's pool provenance so the
// aggregate can resolve the owner account and the entry's licence; it never
// leaves the coordinator.
type PoolProvenAttempt struct {
	ProviderID            string
	PoolID                string
	PoolModelID           string
	ManifestVersion       uint64
	ManifestCoreDigest    string
	ArtifactHashAlgorithm string
	ArtifactHash          string
	RuntimeSource         string
	PoolMemberAccountID   string
	PoolOperatorAccountID string
}

// QueryPoolProvenAttempts lists the SPEC-047-R012 counted attempts whose
// coordinator-assigned finality time (the closing time of the settlement
// receipt verdict) lies in [since, until]: an enforce-mode route snapshot with
// expected_model_hash_source pool_manifest, a closed payable verdict whose
// pool label is not label_disputed, and a payable request credit (the SPEC-022
// payable view, so quarantined or reversed credits are excluded) with a
// positive buyer debit and a positive provider credit. It returns at most
// limit rows; the caller treats limit rows as the ceiling being reached.
func QueryPoolProvenAttempts(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}, since, until time.Time, limit int) ([]PoolProvenAttempt, error) {
	if q == nil {
		return nil, errors.New("billing: ledger handle unavailable")
	}
	if limit <= 0 || !until.After(since) {
		return nil, errors.New("billing: invalid pool-proven window")
	}
	query := `
SELECT srs.provider_id,
       COALESCE(srs.pool_id, ''),
       COALESCE(json_extract(srs.route_snapshot_json, '$.pool_model_id'), ''),
       COALESCE(json_extract(srs.route_snapshot_json, '$.manifest_version'), 0),
       COALESCE(json_extract(srs.route_snapshot_json, '$.manifest_core_digest'), ''),
       COALESCE(json_extract(srs.route_snapshot_json, '$.expected_catalog_model_hash_algorithm'), ''),
       srs.expected_catalog_model_hash,
       COALESCE(json_extract(srs.route_snapshot_json, '$.runtime_source'), ''),
       COALESCE(json_extract(srs.route_snapshot_json, '$.pool_member_account_id'), ''),
       COALESCE(json_extract(srs.route_snapshot_json, '$.pool_operator_account_id'), '')
  FROM spec022_payable_request_credits p
  JOIN settlement_route_snapshots srs
    ON srs.request_id = p.request_id
   AND srs.attempt_n = p.attempt_n
   AND srs.provider_id = p.provider_id
   AND srs.route_snapshot_mode = 'enforce'
   AND srs.route_snapshot_policy_version = p.settlement_policy_version
  JOIN settlement_receipt_verdicts srv
    ON srv.account_scope_hash = p.settlement_account_scope_hash
   AND srv.request_id = srs.request_id
   AND srv.attempt_n = srs.attempt_n
   AND srv.provider_id = srs.provider_id
   AND srv.route_snapshot_digest = srs.route_snapshot_digest
 WHERE p.settlement_policy_mode = 'enforce'
   AND p.gross_credits > 0
   AND p.provider_credits > 0
   AND json_extract(srs.route_snapshot_json, '$.expected_model_hash_source') = ?
   AND COALESCE(srs.pool_id, '') <> ''
   AND srv.closed = 1
   AND ` + payableSettlementOutcomeSQL("srv", "srs") + `
   AND COALESCE(srv.pool_label_status, '') <> ?
   AND julianday(COALESCE(srv.updated_at_utc, srv.created_at_utc)) BETWEEN julianday(?) AND julianday(?)
 ORDER BY srs.id
 LIMIT ?`
	rows, err := q.QueryContext(ctx, query,
		ExpectedModelHashSourcePoolManifest, PoolLabelStatusDisputed,
		since.UTC().Format(time.RFC3339Nano), until.UTC().Format(time.RFC3339Nano), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PoolProvenAttempt
	for rows.Next() {
		var a PoolProvenAttempt
		var version sql.NullInt64
		if err := rows.Scan(&a.ProviderID, &a.PoolID, &a.PoolModelID, &version, &a.ManifestCoreDigest,
			&a.ArtifactHashAlgorithm, &a.ArtifactHash, &a.RuntimeSource, &a.PoolMemberAccountID, &a.PoolOperatorAccountID); err != nil {
			return nil, err
		}
		if version.Valid && version.Int64 > 0 {
			a.ManifestVersion = uint64(version.Int64)
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
