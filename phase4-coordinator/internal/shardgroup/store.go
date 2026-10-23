package shardgroup

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// ErrEpochNotIncreasing refuses a record whose epoch is not strictly greater
// than the last accepted epoch of its group (SPEC-051-R005).
var ErrEpochNotIncreasing = errors.New("shardgroup: group_epoch is not strictly increasing")

// Store is the durable SPEC-051 state: the append-only accepted group
// records, the member receipt keys bound to each epoch, and the verified or
// failed group attestation of each attempt.
type Store struct {
	db *sql.DB
}

// NewStore creates the shard group tables if absent.
func NewStore(db *sql.DB) (*Store, error) {
	if db == nil {
		return nil, errors.New("shardgroup: nil database")
	}
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS shard_group_records (
			group_provider_id TEXT NOT NULL,
			group_epoch INTEGER NOT NULL CHECK(group_epoch >= 1),
			record_json TEXT NOT NULL,
			record_digest TEXT NOT NULL,
			record_signature TEXT NOT NULL,
			accepted_at_unix_ms INTEGER NOT NULL,
			PRIMARY KEY (group_provider_id, group_epoch)
		)`,
		`CREATE TABLE IF NOT EXISTS shard_group_member_bindings (
			group_provider_id TEXT NOT NULL,
			group_epoch INTEGER NOT NULL,
			member_device_id TEXT NOT NULL,
			role TEXT NOT NULL CHECK(role IN ('stage', 'spare')),
			stage_index INTEGER NOT NULL,
			receipt_public_key TEXT NOT NULL,
			bound_at_unix_ms INTEGER NOT NULL,
			PRIMARY KEY (group_provider_id, group_epoch, member_device_id)
		)`,
		`CREATE TABLE IF NOT EXISTS shard_group_attestations (
			request_id TEXT NOT NULL,
			attempt_n INTEGER NOT NULL,
			group_provider_id TEXT NOT NULL,
			receipt_tuple_sha256 TEXT NOT NULL,
			verdict TEXT NOT NULL CHECK(verdict IN ('verified', 'failed')),
			fault_kind TEXT NOT NULL,
			fault_member_device_id TEXT NOT NULL,
			attestation_json TEXT NOT NULL,
			takeover_from_epoch INTEGER NOT NULL DEFAULT 0,
			takeover_reason TEXT NOT NULL DEFAULT '',
			recorded_at_unix_ms INTEGER NOT NULL,
			PRIMARY KEY (request_id, attempt_n, group_provider_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_shard_group_attestations_fault_member
			ON shard_group_attestations(fault_member_device_id) WHERE verdict = 'failed'`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("shardgroup: migrate: %w", err)
		}
	}
	return nil
}

// StoredRecord is one accepted group record.
type StoredRecord struct {
	GroupProviderID string
	GroupEpoch      uint64
	RecordJSON      string
	RecordDigest    string
	RecordSignature string
}

// AcceptRecord appends a record when its epoch is strictly greater than the
// group's last accepted epoch. An identical re-registration of the latest
// accepted record (same epoch and digest) is acknowledged without a new row
// and reports created=false.
func (s *Store) AcceptRecord(ctx context.Context, rec StoredRecord, nowUnixMS int64) (created bool, err error) {
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		var lastEpoch sql.NullInt64
		var lastDigest sql.NullString
		row := conn.QueryRowContext(ctx, `SELECT group_epoch, record_digest FROM shard_group_records WHERE group_provider_id = ? ORDER BY group_epoch DESC LIMIT 1`, rec.GroupProviderID)
		if err := row.Scan(&lastEpoch, &lastDigest); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if lastEpoch.Valid {
			if uint64(lastEpoch.Int64) == rec.GroupEpoch && lastDigest.String == rec.RecordDigest {
				return nil
			}
			if rec.GroupEpoch <= uint64(lastEpoch.Int64) {
				return ErrEpochNotIncreasing
			}
		}
		if _, err := conn.ExecContext(ctx, `INSERT INTO shard_group_records (group_provider_id, group_epoch, record_json, record_digest, record_signature, accepted_at_unix_ms) VALUES (?, ?, ?, ?, ?, ?)`,
			rec.GroupProviderID, int64(rec.GroupEpoch), rec.RecordJSON, rec.RecordDigest, rec.RecordSignature, nowUnixMS); err != nil {
			return err
		}
		created = true
		return nil
	})
	return created, err
}

// LatestRecord returns a group's latest accepted record.
func (s *Store) LatestRecord(ctx context.Context, groupProviderID string) (StoredRecord, bool, error) {
	var out StoredRecord
	var epoch int64
	err := s.db.QueryRowContext(ctx, `SELECT group_provider_id, group_epoch, record_json, record_digest, record_signature FROM shard_group_records WHERE group_provider_id = ? ORDER BY group_epoch DESC LIMIT 1`, groupProviderID).
		Scan(&out.GroupProviderID, &epoch, &out.RecordJSON, &out.RecordDigest, &out.RecordSignature)
	if errors.Is(err, sql.ErrNoRows) {
		return StoredRecord{}, false, nil
	}
	if err != nil {
		return StoredRecord{}, false, err
	}
	out.GroupEpoch = uint64(epoch)
	return out, true, nil
}

// MemberBinding is one member's receipt key bound to one epoch.
type MemberBinding struct {
	GroupProviderID  string
	GroupEpoch       uint64
	MemberDeviceID   string
	Role             string
	StageIndex       int
	ReceiptPublicKey string
}

// BindMember records the receipt key a member session carried when its hello
// for the epoch was accepted. A later rebind of the same member and epoch
// (a reconnect) replaces the key.
func (s *Store) BindMember(ctx context.Context, b MemberBinding, nowUnixMS int64) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO shard_group_member_bindings (group_provider_id, group_epoch, member_device_id, role, stage_index, receipt_public_key, bound_at_unix_ms)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(group_provider_id, group_epoch, member_device_id) DO UPDATE SET
			role = excluded.role, stage_index = excluded.stage_index,
			receipt_public_key = excluded.receipt_public_key, bound_at_unix_ms = excluded.bound_at_unix_ms`,
		b.GroupProviderID, int64(b.GroupEpoch), b.MemberDeviceID, b.Role, b.StageIndex, b.ReceiptPublicKey, nowUnixMS)
	return err
}

// AttestationRecord is one attempt's attestation verdict.
type AttestationRecord struct {
	RequestID           string
	AttemptN            int
	GroupProviderID     string
	ReceiptTupleSHA256  string
	Verified            bool
	FaultKind           string
	FaultMemberDeviceID string
	AttestationJSON     string
	// A verified takeover: the epoch the spare took over from and why;
	// zero and empty otherwise.
	TakeoverFromEpoch uint64
	TakeoverReason    string
}

// RecordAttestation stores an attempt's verdict. The first verdict for an
// attempt is kept.
func (s *Store) RecordAttestation(ctx context.Context, a AttestationRecord, nowUnixMS int64) error {
	verdict := "failed"
	if a.Verified {
		verdict = "verified"
	}
	_, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO shard_group_attestations (request_id, attempt_n, group_provider_id, receipt_tuple_sha256, verdict, fault_kind, fault_member_device_id, attestation_json, takeover_from_epoch, takeover_reason, recorded_at_unix_ms)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.RequestID, a.AttemptN, a.GroupProviderID, a.ReceiptTupleSHA256, verdict, a.FaultKind, a.FaultMemberDeviceID, a.AttestationJSON,
		int64(a.TakeoverFromEpoch), a.TakeoverReason, nowUnixMS)
	return err
}

// Attestation reads one attempt's stored verdict.
func (s *Store) Attestation(ctx context.Context, requestID string, attemptN int, groupProviderID string) (AttestationRecord, bool, error) {
	out := AttestationRecord{RequestID: requestID, AttemptN: attemptN, GroupProviderID: groupProviderID}
	var verdict string
	var takeoverFrom int64
	err := s.db.QueryRowContext(ctx, `SELECT receipt_tuple_sha256, verdict, fault_kind, fault_member_device_id, attestation_json, takeover_from_epoch, takeover_reason FROM shard_group_attestations WHERE request_id = ? AND attempt_n = ? AND group_provider_id = ?`,
		requestID, attemptN, groupProviderID).Scan(&out.ReceiptTupleSHA256, &verdict, &out.FaultKind, &out.FaultMemberDeviceID, &out.AttestationJSON, &takeoverFrom, &out.TakeoverReason)
	if errors.Is(err, sql.ErrNoRows) {
		return AttestationRecord{}, false, nil
	}
	if err != nil {
		return AttestationRecord{}, false, err
	}
	out.Verified = verdict == "verified"
	out.TakeoverFromEpoch = uint64(takeoverFrom)
	return out, true, nil
}
