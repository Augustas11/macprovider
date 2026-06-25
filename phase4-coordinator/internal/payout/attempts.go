package payout

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// SPEC-016 §4.5 + §4.6 — payout_attempts CRUD + nonce cursor.
//
// All write-side operations gate on the partial UNIQUE indexes
// from §4.5 (idx_pa_one_live_non_cancel_per_payout +
// idx_pa_from_nonce_active); a UNIQUE-violation surfaces as
// ErrDuplicateLiveAttempt so the runner can emit the
// payout_invariant_violation event per SPEC.

// AttemptRow mirrors the §4.5 schema. Nullable columns surface
// as sql.NullX so callers can distinguish missing from zero.
type AttemptRow struct {
	PayoutID                       int64
	AttemptSeq                     int
	Chain                          string
	FromAddress                    string
	ToAddress                      string
	AmountBaseUnits                int64
	Nonce                          int64
	RawSignedTx                    []byte
	TxHash                         sql.NullString
	BroadcastAtUtc                 sql.NullString
	ConfirmedAtUtc                 sql.NullString
	BlockNumber                    sql.NullInt64
	GasUsedNativeWei               sql.NullInt64
	IsCancelSelfTransfer           bool
	LastError                      sql.NullString
	AbandonedAtUtc                 sql.NullString
	AbandonedReason                sql.NullString
	CancelReconfirmStalePagedAtUtc sql.NullString
	UpdatedAtUtc                   string
}

// ErrDuplicateLiveAttempt is the typed error surfaced when the
// idx_pa_one_live_non_cancel_per_payout UNIQUE index trips. The
// runner converts this into payout_invariant_violation
// where='duplicate live attempt' per SPEC §4.5.
var ErrDuplicateLiveAttempt = errors.New("payout: duplicate live attempt")

// ErrAttemptRowMissing / ErrAttemptStateChanged surface the §4.3
// step 6 CAS-failure disambiguations.
var (
	ErrAttemptRowMissing             = errors.New("payout: attempt row missing during sign")
	ErrAttemptStateChangedDuringSign = errors.New("payout: attempt state changed during sign")
	ErrRawSignedTxAlreadyPresent     = errors.New("payout: raw_signed_tx already present (reuse persisted bytes)")
)

// ReservedAttempt is the in-memory record of an attempt the
// runner has reserved (INSERTed) inside the BEGIN IMMEDIATE txn.
// The runner carries it through sign+CAS+broadcast+poll.
type ReservedAttempt struct {
	PayoutID        int64
	AttemptSeq      int
	Nonce           int64
	AmountBaseUnits int64
	ToAddress       string
}

// SelectReadyPayouts implements SPEC-016 §4.3 step 1 — the
// SELECT joining ledger_payout_ready with
// provider_payout_addresses on the current hot wallet and the
// cooling-off / rotated_from rules.
//
// NOTE on [arch:1.1] SPEC drift: SPEC v0.1.21 §4.7 references
// payout_attempts.id and payout_external_id columns that do not
// exist in §4.5. This SELECT lives at §4.3 step 1 where the
// column references match §4.5 exactly; the reorg-poll query is
// implemented in reorg.go against the corrected column set per
// the architect r1 deferral.
const selectReadyPayoutsSQL = `
SELECT lpr.id, lpr.provider_id, lpr.gross_credits,
       lpr.provider_credits, lpr.window_start_utc, lpr.window_end_utc,
       CASE WHEN ppa.pending_until_utc IS NOT NULL
              AND ppa.pending_until_utc > ?
             THEN ppa.rotated_from
             ELSE ppa.address END AS effective_address
  FROM ledger_payout_ready lpr
  INNER JOIN provider_payout_addresses ppa
    ON ppa.provider_id = lpr.provider_id
   AND ppa.chain = 'base-mainnet'
   AND ppa.payout_allowed = 1
   AND ppa.registered_against_hot_wallet = ?
 WHERE lpr.status = 'ready'
   AND (ppa.pending_until_utc IS NULL
        OR ppa.pending_until_utc <= ?
        OR ppa.rotated_from IS NOT NULL)
 ORDER BY lpr.id ASC
 LIMIT ?
`

// ReadyRow is the result-shape of SelectReadyPayouts.
type ReadyRow struct {
	PayoutID         int64
	ProviderID       string
	GrossCredits     int64
	ProviderCredits  int64
	WindowStartUtc   string
	WindowEndUtc     string
	EffectiveAddress sql.NullString
}

// SelectReadyPayouts runs the §4.3 step 1 SELECT.
func SelectReadyPayouts(ctx context.Context, db *sql.DB, hotWallet, nowUTC string, limit int) ([]ReadyRow, error) {
	rows, err := db.QueryContext(ctx, selectReadyPayoutsSQL, nowUTC, hotWallet, nowUTC, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReadyRow{}
	for rows.Next() {
		var r ReadyRow
		if err := rows.Scan(&r.PayoutID, &r.ProviderID, &r.GrossCredits, &r.ProviderCredits,
			&r.WindowStartUtc, &r.WindowEndUtc, &r.EffectiveAddress); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// LookupExistingLatest fetches the most recent non-abandoned,
// non-cancel attempt for a given payout_id (§4.3 step 5 query).
// Returns (nil, nil) when no such attempt exists.
func LookupExistingLatest(ctx context.Context, conn *sql.Conn, payoutID int64) (*AttemptRow, error) {
	row := conn.QueryRowContext(ctx, `
SELECT payout_id, attempt_seq, chain, from_address, to_address,
       amount_base_units, nonce, raw_signed_tx, tx_hash,
       broadcast_at_utc, confirmed_at_utc, block_number,
       gas_used_native_wei, is_cancel_self_transfer, last_error,
       abandoned_at_utc, abandoned_reason,
       cancel_reconfirm_stale_paged_at_utc, updated_at_utc
  FROM payout_attempts
 WHERE payout_id = ?
   AND abandoned_at_utc IS NULL
   AND is_cancel_self_transfer = 0
 ORDER BY attempt_seq DESC
 LIMIT 1`, payoutID)
	a := &AttemptRow{}
	var isCancel int
	if err := row.Scan(&a.PayoutID, &a.AttemptSeq, &a.Chain, &a.FromAddress, &a.ToAddress,
		&a.AmountBaseUnits, &a.Nonce, &a.RawSignedTx, &a.TxHash, &a.BroadcastAtUtc,
		&a.ConfirmedAtUtc, &a.BlockNumber, &a.GasUsedNativeWei, &isCancel,
		&a.LastError, &a.AbandonedAtUtc, &a.AbandonedReason,
		&a.CancelReconfirmStalePagedAtUtc, &a.UpdatedAtUtc,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	a.IsCancelSelfTransfer = isCancel == 1
	return a, nil
}

// LookupLiveCancels returns ordered live cancel-self-transfer
// rows for the given payout_id (§4.3 step 5 cancel pre-check).
func LookupLiveCancels(ctx context.Context, conn *sql.Conn, payoutID int64) ([]AttemptRow, error) {
	rows, err := conn.QueryContext(ctx, `
SELECT payout_id, attempt_seq, nonce, raw_signed_tx, tx_hash,
       broadcast_at_utc, confirmed_at_utc, abandoned_at_utc, updated_at_utc
  FROM payout_attempts
 WHERE payout_id = ?
   AND is_cancel_self_transfer = 1
   AND abandoned_at_utc IS NULL
 ORDER BY attempt_seq ASC`, payoutID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AttemptRow{}
	for rows.Next() {
		a := AttemptRow{IsCancelSelfTransfer: true}
		if err := rows.Scan(&a.PayoutID, &a.AttemptSeq, &a.Nonce, &a.RawSignedTx, &a.TxHash,
			&a.BroadcastAtUtc, &a.ConfirmedAtUtc, &a.AbandonedAtUtc, &a.UpdatedAtUtc,
		); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// NextAttemptSeq returns the next attempt_seq for the given
// payout_id (max(attempt_seq) + 1; 1 if no rows).
func NextAttemptSeq(ctx context.Context, conn *sql.Conn, payoutID int64) (int, error) {
	var max sql.NullInt64
	if err := conn.QueryRowContext(ctx,
		`SELECT MAX(attempt_seq) FROM payout_attempts WHERE payout_id=?`, payoutID,
	).Scan(&max); err != nil {
		return 0, err
	}
	if !max.Valid {
		return 1, nil
	}
	return int(max.Int64) + 1, nil
}

// InsertAttempt inserts a fresh provider-payout attempt row.
// The caller MUST hold an open BEGIN IMMEDIATE transaction on
// conn and MUST have already verified:
//
//   - The amount_base_units == ledger_payout_ready.provider_credits
//     invariant (SPEC §4.3 step 5 C3 closure — v0.1.20 round-20)
//   - The cancel pre-check (no live unconfirmed cancel)
//   - The per-payout and per-day caps
//
// On UNIQUE violation against
// idx_pa_one_live_non_cancel_per_payout, returns
// ErrDuplicateLiveAttempt — the runner emits
// payout_invariant_violation where='duplicate live attempt'.
func InsertAttempt(ctx context.Context, conn *sql.Conn, payoutID int64, attemptSeq int,
	fromAddress, toAddress string, amountBaseUnits, nonce int64, nowUTC string,
) error {
	_, err := conn.ExecContext(ctx, `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, is_cancel_self_transfer, updated_at_utc)
VALUES (?, ?, 'base-mainnet', ?, ?, ?, ?, 0, ?)`,
		payoutID, attemptSeq, strings.ToLower(fromAddress), strings.ToLower(toAddress),
		amountBaseUnits, nonce, nowUTC,
	)
	if err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("%w: payout_id=%d attempt_seq=%d", ErrDuplicateLiveAttempt, payoutID, attemptSeq)
		}
		return err
	}
	return nil
}

// CASPersistSignedTx is the §4.3 step 6 CAS UPDATE: persists
// raw_signed_tx + tx_hash ONLY IF the row is still in the live,
// unbroadcast, unconfirmed, unabandoned, signed-bytes-absent
// state. The caller MUST hold an open BEGIN IMMEDIATE on conn
// AND MUST have already re-read the lease holder_token.
//
// Disambiguation on row-count = 0:
//   - row missing                    → ErrAttemptRowMissing
//   - confirmed_at_utc IS NOT NULL OR abandoned_at_utc IS NOT NULL
//     → ErrAttemptStateChangedDuringSign
//   - raw_signed_tx IS NOT NULL      → ErrRawSignedTxAlreadyPresent
func CASPersistSignedTx(ctx context.Context, conn *sql.Conn, payoutID int64, attemptSeq int,
	rawSignedTx []byte, txHash, nowUTC string,
) error {
	res, err := conn.ExecContext(ctx, `
UPDATE payout_attempts
   SET raw_signed_tx = ?,
       tx_hash       = ?,
       updated_at_utc = ?
 WHERE payout_id = ?
   AND attempt_seq = ?
   AND raw_signed_tx IS NULL
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL`,
		rawSignedTx, txHash, nowUTC, payoutID, attemptSeq)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 1 {
		return nil
	}
	// Disambiguate via a follow-up read.
	var (
		gotRow      int
		isAbandoned sql.NullString
		isConfirmed sql.NullString
		hasSignedTx sql.NullString
	)
	row := conn.QueryRowContext(ctx, `
SELECT 1, abandoned_at_utc, confirmed_at_utc,
       CASE WHEN raw_signed_tx IS NULL THEN NULL ELSE 'set' END
  FROM payout_attempts
 WHERE payout_id = ? AND attempt_seq = ?`, payoutID, attemptSeq)
	if err := row.Scan(&gotRow, &isAbandoned, &isConfirmed, &hasSignedTx); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("%w: payout_id=%d attempt_seq=%d", ErrAttemptRowMissing, payoutID, attemptSeq)
		}
		return err
	}
	if isAbandoned.Valid || isConfirmed.Valid {
		detail := "unknown"
		if isAbandoned.Valid {
			detail = "abandoned"
		}
		if isConfirmed.Valid {
			detail = "confirmed"
		}
		return fmt.Errorf("%w: detail=%s payout_id=%d attempt_seq=%d", ErrAttemptStateChangedDuringSign, detail, payoutID, attemptSeq)
	}
	if hasSignedTx.Valid {
		return fmt.Errorf("%w: payout_id=%d attempt_seq=%d", ErrRawSignedTxAlreadyPresent, payoutID, attemptSeq)
	}
	return fmt.Errorf("CASPersistSignedTx: 0 rows affected with no disambiguation match — possible concurrent UPDATE")
}

// StampBroadcastAtTx stamps broadcast_at_utc on the row inside
// an open BEGIN IMMEDIATE tx — used by the §4.3 step 6
// post-COMMIT broadcast path and by the §4.6 cancel-row CAS path.
func StampBroadcastAtTx(ctx context.Context, conn *sql.Conn, payoutID int64, attemptSeq int, nowUTC string) (int64, error) {
	res, err := conn.ExecContext(ctx, `
UPDATE payout_attempts
   SET broadcast_at_utc = ?,
       updated_at_utc   = ?
 WHERE payout_id = ?
   AND attempt_seq = ?
   AND broadcast_at_utc IS NULL
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL`,
		nowUTC, nowUTC, payoutID, attemptSeq)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// StampBroadcastAt is the non-tx variant for the §4.3 step 6 path
// where the broadcast happens AFTER COMMIT — no concurrent writer
// can flip the row to abandoned in the gap because the lease
// guards it.
func StampBroadcastAt(ctx context.Context, db *sql.DB, payoutID int64, attemptSeq int, nowUTC string) error {
	_, err := db.ExecContext(ctx, `
UPDATE payout_attempts
   SET broadcast_at_utc = ?, updated_at_utc = ?
 WHERE payout_id = ? AND attempt_seq = ? AND broadcast_at_utc IS NULL`,
		nowUTC, nowUTC, payoutID, attemptSeq)
	return err
}

// MarkConfirmedAtTx stamps confirmed_at_utc + block_number +
// gas_used_native_wei on the row. The §4.3 step 7 verification
// has already passed at the caller; this is the durable record.
// Returns the rows-affected count so the caller can detect a
// concurrent abandon (count = 0).
func MarkConfirmedAtTx(ctx context.Context, conn *sql.Conn, payoutID int64, attemptSeq int,
	blockNumber int64, gasUsedNativeWei int64, nowUTC string,
) (int64, error) {
	res, err := conn.ExecContext(ctx, `
UPDATE payout_attempts
   SET confirmed_at_utc = ?,
       block_number = ?,
       gas_used_native_wei = ?,
       updated_at_utc = ?,
       cancel_reconfirm_stale_paged_at_utc = NULL
 WHERE payout_id = ?
   AND attempt_seq = ?
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL`,
		nowUTC, blockNumber, gasUsedNativeWei, nowUTC, payoutID, attemptSeq)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// SumAmountWindow returns the SUM of amount_base_units for live
// (non-abandoned non-cancel) attempts AND broadcasts in the
// rolling 24h window — used by the §5.3 reservation-aware
// per-day cap re-read inside the BEGIN IMMEDIATE txn.
func SumAmountWindow(ctx context.Context, conn *sql.Conn, fromAddress, since string) (int64, error) {
	var sum sql.NullInt64
	if err := conn.QueryRowContext(ctx, `
SELECT COALESCE(SUM(amount_base_units), 0) FROM payout_attempts
 WHERE from_address = ?
   AND is_cancel_self_transfer = 0
   AND abandoned_at_utc IS NULL
   AND (
        (broadcast_at_utc IS NOT NULL AND broadcast_at_utc >= ?)
        OR (broadcast_at_utc IS NULL AND confirmed_at_utc IS NULL)
   )`, strings.ToLower(fromAddress), since,
	).Scan(&sum); err != nil {
		return 0, err
	}
	if !sum.Valid {
		return 0, nil
	}
	return sum.Int64, nil
}

// CountStaleUnbroadcastTx returns the count of attempts that are
// reserved-but-unbroadcast older than 24h (the §4.3 step 4
// stale-reservation halt per v0.1.10 codex round-11 MAJOR-1).
func CountStaleUnbroadcastTx(ctx context.Context, conn *sql.Conn, fromAddress, nowMinus24h string) (int64, error) {
	var n int64
	if err := conn.QueryRowContext(ctx, `
SELECT COUNT(*) FROM payout_attempts
 WHERE from_address = ?
   AND broadcast_at_utc IS NULL
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL
   AND updated_at_utc < ?`, strings.ToLower(fromAddress), nowMinus24h,
	).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

// ---- wallet_nonce_cursor ------------------------------------------------

// UpsertNonceCursor records the runner's chosen cold-start nonce
// for the given from_address. RPC values are persisted for
// post-hoc forensics.
func UpsertNonceCursor(ctx context.Context, db *sql.DB, fromAddress string, nextNonce uint64,
	rpcAValue, rpcBValue uint64, nowUTC string,
) error {
	_, err := db.ExecContext(ctx, `
INSERT INTO wallet_nonce_cursor
  (from_address, next_nonce, last_synced_at_utc, rpc_a_last_value, rpc_b_last_value)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(from_address) DO UPDATE SET
  next_nonce = excluded.next_nonce,
  last_synced_at_utc = excluded.last_synced_at_utc,
  rpc_a_last_value = excluded.rpc_a_last_value,
  rpc_b_last_value = excluded.rpc_b_last_value`,
		strings.ToLower(fromAddress), int64(nextNonce), nowUTC, int64(rpcAValue), int64(rpcBValue),
	)
	return err
}

// ReadNonceCursor returns the persisted next_nonce for the
// address, or (0, false, nil) if no row exists.
func ReadNonceCursor(ctx context.Context, db *sql.DB, fromAddress string) (uint64, bool, error) {
	var v int64
	err := db.QueryRowContext(ctx,
		`SELECT next_nonce FROM wallet_nonce_cursor WHERE from_address=?`,
		strings.ToLower(fromAddress),
	).Scan(&v)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, false, nil
		}
		return 0, false, err
	}
	if v < 0 {
		return 0, false, fmt.Errorf("nonce cursor for %s is negative (%d)", fromAddress, v)
	}
	return uint64(v), true, nil
}

// AllocateNextNonceTx allocates the next nonce for the given
// from_address INSIDE an open BEGIN IMMEDIATE transaction. The
// caller MUST hold the lease + the per-attempt txn. Returns the
// chosen nonce.
//
// The cursor is bumped AFTER this call by the broadcast path
// (UpsertNonceCursor); the in-txn allocation here just reserves
// the value for the attempt INSERT.
func AllocateNextNonceTx(ctx context.Context, conn *sql.Conn, fromAddress string) (int64, error) {
	row := conn.QueryRowContext(ctx,
		`SELECT next_nonce FROM wallet_nonce_cursor WHERE from_address=?`,
		strings.ToLower(fromAddress),
	)
	var v int64
	if err := row.Scan(&v); err != nil {
		return 0, err
	}
	return v, nil
}

// BumpNonceCursorTx increments the persisted cursor by 1 inside
// the same txn as the attempt INSERT — keeps the durable record
// consistent with the on-chain expected next nonce.
func BumpNonceCursorTx(ctx context.Context, conn *sql.Conn, fromAddress string, nowUTC string) error {
	_, err := conn.ExecContext(ctx,
		`UPDATE wallet_nonce_cursor SET next_nonce = next_nonce + 1, last_synced_at_utc = ? WHERE from_address = ?`,
		nowUTC, strings.ToLower(fromAddress),
	)
	return err
}

// ---- helpers ------------------------------------------------------------

// NowUTC is a small clock helper used across CRUD functions.
func NowUTC() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}
