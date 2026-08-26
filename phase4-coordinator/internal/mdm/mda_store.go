package mdm

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"

	_ "modernc.org/sqlite"
)

// MDAProofRecord is a durable Phase 3 MDA proof for reconnect / restart reuse.
type MDAProofRecord struct {
	ProviderID     string
	Serial         string
	MDACertChain   [][]byte
	BoundSEKeyHash []byte
	VerifiedAt     time.Time
}

// EnqueueLedgerRecord tracks DeviceInformation enqueue rate limits (R3-M3).
type EnqueueLedgerRecord struct {
	LedgerKey          string
	ProviderID         string
	Serial             string
	SEKeyHash          []byte
	LastEnqueueAt      time.Time
	PendingCommandUUID string
	TerminalOutcome    string // "" | "success" | "failed"
}

// PendingMDARecord is a durable webhook correlation for an in-flight
// DeviceInformation attestation (R4-M1).
type PendingMDARecord struct {
	ProviderID  string
	AssignedID  string
	Serial      string
	UDID        string
	SEKeyHash   []byte
	CommandUUID string
	EnqueuedAt  time.Time
}

// DeviceBindingRecord is a durable provider↔serial↔UDID binding (R4-M2).
type DeviceBindingRecord struct {
	ProviderID string
	Serial     string
	UDID       string
	ClaimedAt  time.Time
}

// MDAStore persists MDA proofs, enqueue ledger, pending webhook correlation,
// and device bindings in coordinator SQLite.
type MDAStore struct {
	db *sql.DB
}

// OpenMDAStore opens (or creates) MDA tables on the coordinator storage DB.
func OpenMDAStore(path string) (*MDAStore, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("mda store: db path is required")
	}
	if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &MDAStore{db: db}
	if err := s.ensureTables(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *MDAStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *MDAStore) ensureTables(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS mda_proofs (
	provider_id TEXT PRIMARY KEY,
	serial TEXT NOT NULL,
	mda_cert_chain TEXT NOT NULL,
	bound_se_key_hash BLOB NOT NULL,
	verified_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS mda_enqueue_ledger (
	ledger_key TEXT PRIMARY KEY,
	provider_id TEXT NOT NULL,
	serial TEXT NOT NULL,
	se_key_hash BLOB NOT NULL,
	last_enqueue_at TEXT NOT NULL,
	pending_command_uuid TEXT NOT NULL DEFAULT '',
	terminal_outcome TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS mda_pending (
	command_uuid TEXT PRIMARY KEY,
	provider_id TEXT NOT NULL,
	assigned_id TEXT NOT NULL,
	serial TEXT NOT NULL,
	udid TEXT NOT NULL,
	se_key_hash BLOB NOT NULL,
	enqueued_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mda_pending_udid ON mda_pending(udid);
CREATE TABLE IF NOT EXISTS mda_device_bindings (
	provider_id TEXT PRIMARY KEY,
	serial TEXT NOT NULL UNIQUE,
	udid TEXT NOT NULL DEFAULT '',
	claimed_at TEXT NOT NULL
);
`)
	return err
}

func encodeChain(chain [][]byte) (string, error) {
	b64 := make([]string, len(chain))
	for i, der := range chain {
		b64[i] = base64.StdEncoding.EncodeToString(der)
	}
	raw, err := json.Marshal(b64)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func decodeChain(raw string) ([][]byte, error) {
	var b64 []string
	if err := json.Unmarshal([]byte(raw), &b64); err != nil {
		return nil, err
	}
	out := make([][]byte, 0, len(b64))
	for _, s := range b64 {
		der, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			return nil, err
		}
		out = append(out, der)
	}
	return out, nil
}

// SaveProof upserts a verified MDA proof for providerID.
func (s *MDAStore) SaveProof(ctx context.Context, rec MDAProofRecord) error {
	if s == nil || s.db == nil {
		return nil
	}
	chainJSON, err := encodeChain(rec.MDACertChain)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO mda_proofs(provider_id, serial, mda_cert_chain, bound_se_key_hash, verified_at)
VALUES(?, ?, ?, ?, ?)
ON CONFLICT(provider_id) DO UPDATE SET
	serial = excluded.serial,
	mda_cert_chain = excluded.mda_cert_chain,
	bound_se_key_hash = excluded.bound_se_key_hash,
	verified_at = excluded.verified_at`,
		strings.TrimSpace(rec.ProviderID),
		NormalizeSerial(rec.Serial),
		chainJSON,
		append([]byte(nil), rec.BoundSEKeyHash...),
		rec.VerifiedAt.UTC().Format(time.RFC3339Nano),
	)
	return err
}

// LoadProof returns the durable proof for providerID, if any.
func (s *MDAStore) LoadProof(ctx context.Context, providerID string) (MDAProofRecord, bool, error) {
	if s == nil || s.db == nil {
		return MDAProofRecord{}, false, nil
	}
	providerID = strings.TrimSpace(providerID)
	var serial, chainJSON, verifiedAt string
	var seHash []byte
	err := s.db.QueryRowContext(ctx, `
SELECT serial, mda_cert_chain, bound_se_key_hash, verified_at
FROM mda_proofs WHERE provider_id = ?`, providerID).Scan(&serial, &chainJSON, &seHash, &verifiedAt)
	if err == sql.ErrNoRows {
		return MDAProofRecord{}, false, nil
	}
	if err != nil {
		return MDAProofRecord{}, false, err
	}
	chain, err := decodeChain(chainJSON)
	if err != nil {
		return MDAProofRecord{}, false, err
	}
	ts, err := time.Parse(time.RFC3339Nano, verifiedAt)
	if err != nil {
		ts, err = time.Parse(time.RFC3339, verifiedAt)
		if err != nil {
			return MDAProofRecord{}, false, err
		}
	}
	return MDAProofRecord{
		ProviderID:     providerID,
		Serial:         serial,
		MDACertChain:   chain,
		BoundSEKeyHash: append([]byte(nil), seHash...),
		VerifiedAt:     ts.UTC(),
	}, true, nil
}

// DeleteProof removes the durable proof for providerID.
func (s *MDAStore) DeleteProof(ctx context.Context, providerID string) error {
	if s == nil || s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM mda_proofs WHERE provider_id = ?`, strings.TrimSpace(providerID))
	return err
}

// SaveEnqueueLedger upserts an enqueue ledger row.
func (s *MDAStore) SaveEnqueueLedger(ctx context.Context, rec EnqueueLedgerRecord) error {
	if s == nil || s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO mda_enqueue_ledger(ledger_key, provider_id, serial, se_key_hash, last_enqueue_at, pending_command_uuid, terminal_outcome)
VALUES(?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(ledger_key) DO UPDATE SET
	provider_id = excluded.provider_id,
	serial = excluded.serial,
	se_key_hash = excluded.se_key_hash,
	last_enqueue_at = excluded.last_enqueue_at,
	pending_command_uuid = excluded.pending_command_uuid,
	terminal_outcome = excluded.terminal_outcome`,
		rec.LedgerKey,
		strings.TrimSpace(rec.ProviderID),
		NormalizeSerial(rec.Serial),
		append([]byte(nil), rec.SEKeyHash...),
		rec.LastEnqueueAt.UTC().Format(time.RFC3339Nano),
		strings.TrimSpace(rec.PendingCommandUUID),
		strings.TrimSpace(rec.TerminalOutcome),
	)
	return err
}

// LoadEnqueueLedger returns the durable ledger row for key, if any.
func (s *MDAStore) LoadEnqueueLedger(ctx context.Context, ledgerKey string) (EnqueueLedgerRecord, bool, error) {
	if s == nil || s.db == nil {
		return EnqueueLedgerRecord{}, false, nil
	}
	var rec EnqueueLedgerRecord
	var lastEnqueue string
	err := s.db.QueryRowContext(ctx, `
SELECT ledger_key, provider_id, serial, se_key_hash, last_enqueue_at, pending_command_uuid, terminal_outcome
FROM mda_enqueue_ledger WHERE ledger_key = ?`, ledgerKey).Scan(
		&rec.LedgerKey, &rec.ProviderID, &rec.Serial, &rec.SEKeyHash,
		&lastEnqueue, &rec.PendingCommandUUID, &rec.TerminalOutcome,
	)
	if err == sql.ErrNoRows {
		return EnqueueLedgerRecord{}, false, nil
	}
	if err != nil {
		return EnqueueLedgerRecord{}, false, err
	}
	ts, err := time.Parse(time.RFC3339Nano, lastEnqueue)
	if err != nil {
		ts, err = time.Parse(time.RFC3339, lastEnqueue)
		if err != nil {
			return EnqueueLedgerRecord{}, false, err
		}
	}
	rec.LastEnqueueAt = ts.UTC()
	return rec, true, nil
}

// DeleteEnqueueLedger removes a ledger row (used to release a failed reservation).
func (s *MDAStore) DeleteEnqueueLedger(ctx context.Context, ledgerKey string) error {
	if s == nil || s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM mda_enqueue_ledger WHERE ledger_key = ?`, ledgerKey)
	return err
}

// SavePending upserts a durable pending MDA webhook correlation.
func (s *MDAStore) SavePending(ctx context.Context, rec PendingMDARecord) error {
	if s == nil || s.db == nil {
		return nil
	}
	commandUUID := strings.TrimSpace(rec.CommandUUID)
	if commandUUID == "" {
		return fmt.Errorf("mda store: pending command_uuid required")
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO mda_pending(command_uuid, provider_id, assigned_id, serial, udid, se_key_hash, enqueued_at)
VALUES(?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(command_uuid) DO UPDATE SET
	provider_id = excluded.provider_id,
	assigned_id = excluded.assigned_id,
	serial = excluded.serial,
	udid = excluded.udid,
	se_key_hash = excluded.se_key_hash,
	enqueued_at = excluded.enqueued_at`,
		commandUUID,
		strings.TrimSpace(rec.ProviderID),
		strings.TrimSpace(rec.AssignedID),
		NormalizeSerial(rec.Serial),
		strings.TrimSpace(rec.UDID),
		append([]byte(nil), rec.SEKeyHash...),
		rec.EnqueuedAt.UTC().Format(time.RFC3339Nano),
	)
	return err
}

// LoadPendingByCommandUUID returns a durable pending row by command UUID.
func (s *MDAStore) LoadPendingByCommandUUID(ctx context.Context, commandUUID string) (PendingMDARecord, bool, error) {
	if s == nil || s.db == nil {
		return PendingMDARecord{}, false, nil
	}
	return s.scanPending(ctx, `
SELECT command_uuid, provider_id, assigned_id, serial, udid, se_key_hash, enqueued_at
FROM mda_pending WHERE command_uuid = ?`, strings.TrimSpace(commandUUID))
}

// LoadPendingByUDID returns a durable pending row by UDID (first match).
func (s *MDAStore) LoadPendingByUDID(ctx context.Context, udid string) (PendingMDARecord, bool, error) {
	if s == nil || s.db == nil {
		return PendingMDARecord{}, false, nil
	}
	return s.scanPending(ctx, `
SELECT command_uuid, provider_id, assigned_id, serial, udid, se_key_hash, enqueued_at
FROM mda_pending WHERE udid = ? LIMIT 1`, strings.TrimSpace(udid))
}

func (s *MDAStore) scanPending(ctx context.Context, query string, arg string) (PendingMDARecord, bool, error) {
	var rec PendingMDARecord
	var enqueuedAt string
	err := s.db.QueryRowContext(ctx, query, arg).Scan(
		&rec.CommandUUID, &rec.ProviderID, &rec.AssignedID, &rec.Serial,
		&rec.UDID, &rec.SEKeyHash, &enqueuedAt,
	)
	if err == sql.ErrNoRows {
		return PendingMDARecord{}, false, nil
	}
	if err != nil {
		return PendingMDARecord{}, false, err
	}
	ts, err := time.Parse(time.RFC3339Nano, enqueuedAt)
	if err != nil {
		ts, err = time.Parse(time.RFC3339, enqueuedAt)
		if err != nil {
			return PendingMDARecord{}, false, err
		}
	}
	rec.EnqueuedAt = ts.UTC()
	rec.SEKeyHash = append([]byte(nil), rec.SEKeyHash...)
	return rec, true, nil
}

// DeletePending removes durable pending rows by command UUID and/or UDID.
func (s *MDAStore) DeletePending(ctx context.Context, commandUUID, udid string) error {
	if s == nil || s.db == nil {
		return nil
	}
	commandUUID = strings.TrimSpace(commandUUID)
	udid = strings.TrimSpace(udid)
	if commandUUID == "" && udid == "" {
		return nil
	}
	if commandUUID != "" && udid != "" {
		_, err := s.db.ExecContext(ctx,
			`DELETE FROM mda_pending WHERE command_uuid = ? OR udid = ?`, commandUUID, udid)
		return err
	}
	if commandUUID != "" {
		_, err := s.db.ExecContext(ctx, `DELETE FROM mda_pending WHERE command_uuid = ?`, commandUUID)
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM mda_pending WHERE udid = ?`, udid)
	return err
}

// SaveBinding upserts a durable device binding.
func (s *MDAStore) SaveBinding(ctx context.Context, rec DeviceBindingRecord) error {
	if s == nil || s.db == nil {
		return nil
	}
	providerID := strings.TrimSpace(rec.ProviderID)
	serial := NormalizeSerial(rec.Serial)
	if providerID == "" || serial == "" {
		return fmt.Errorf("mda store: binding provider_id and serial required")
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO mda_device_bindings(provider_id, serial, udid, claimed_at)
VALUES(?, ?, ?, ?)
ON CONFLICT(provider_id) DO UPDATE SET
	serial = excluded.serial,
	udid = excluded.udid,
	claimed_at = excluded.claimed_at`,
		providerID,
		serial,
		strings.TrimSpace(rec.UDID),
		rec.ClaimedAt.UTC().Format(time.RFC3339Nano),
	)
	return err
}

// LoadAllBindings returns every durable device binding.
func (s *MDAStore) LoadAllBindings(ctx context.Context) ([]DeviceBindingRecord, error) {
	if s == nil || s.db == nil {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, serial, udid, claimed_at FROM mda_device_bindings`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DeviceBindingRecord
	for rows.Next() {
		var rec DeviceBindingRecord
		var claimedAt string
		if err := rows.Scan(&rec.ProviderID, &rec.Serial, &rec.UDID, &claimedAt); err != nil {
			return nil, err
		}
		ts, err := time.Parse(time.RFC3339Nano, claimedAt)
		if err != nil {
			ts, err = time.Parse(time.RFC3339, claimedAt)
			if err != nil {
				return nil, err
			}
		}
		rec.ClaimedAt = ts.UTC()
		out = append(out, rec)
	}
	return out, rows.Err()
}

// DeleteBinding removes a durable binding by provider ID.
func (s *MDAStore) DeleteBinding(ctx context.Context, providerID string) error {
	if s == nil || s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM mda_device_bindings WHERE provider_id = ?`, strings.TrimSpace(providerID))
	return err
}

// DeleteBindingBySerial removes a durable binding by serial.
func (s *MDAStore) DeleteBindingBySerial(ctx context.Context, serial string) error {
	if s == nil || s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM mda_device_bindings WHERE serial = ?`, NormalizeSerial(serial))
	return err
}
