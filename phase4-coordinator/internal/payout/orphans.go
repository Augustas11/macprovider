package payout

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

// OrphansService backs the §4.7 POST /admin/payout/record-orphan
// endpoint. Records a reorg-detected orphan into
// payout_reorg_orphans with the IMMUTABLE snapshot columns
// (observed_provider_id / observed_provider_credits /
// observed_gross_credits / observed_amount_base_units) required
// by §9.5b.1 SPEC-005 vX.Y+1 compensation binding.
//
// Two operational shapes, both routed through this one endpoint
// per §4.7:
//
//  1. Provider-payout orphan (is_cancel_self_transfer=0):
//     follows the provider-orphan flow + later compensation path
//     via the SPEC-005 admin endpoint.
//
//  2. Cancel-self-transfer orphan (is_cancel_self_transfer=1):
//     v0.1.14 codex round-15 MAJOR-2 carve-out — NO
//     ledger_payout_ready revert, NO compensation row;
//     observability via payout_reorg_revert
//     is_cancel_self_transfer=1 event + reconfirm-stale outbox if
//     the runner-side stale marker is non-NULL.
//
// The endpoint also supports a "resolve" variant per §4.7's
// "record-only resolution" surface — supplying operator_resolution
// against an existing orphan id is treated as a resolution write,
// not a new-orphan insert. Both variants are recorded in the same
// table so §7.4 reconciliation can detect a forged
// compensation_settlement_id.
type OrphansService struct {
	db    *sql.DB
	log   zerolog.Logger
	nowFn func() time.Time
}

// OrphansOptions bundles the service dependencies.
type OrphansOptions struct {
	DB     *sql.DB
	Logger zerolog.Logger
	NowFn  func() time.Time
}

// NewOrphansService constructs the service.
func NewOrphansService(opts OrphansOptions) (*OrphansService, error) {
	if opts.DB == nil {
		return nil, errors.New("payout.NewOrphansService: DB required")
	}
	nowFn := opts.NowFn
	if nowFn == nil {
		nowFn = time.Now
	}
	return &OrphansService{db: opts.DB, log: opts.Logger, nowFn: nowFn}, nil
}

// recordOrphanRequest mirrors the §4.7 request body. Either
// (payout_id, attempt_seq) identifies a NEW orphan to record, OR
// (id) identifies an EXISTING orphan to resolve. operator_resolution
// + reason are required for either variant.
type recordOrphanRequest struct {
	OrphanID           int64  `json:"id"`
	PayoutID           int64  `json:"payout_id"`
	AttemptSeq         int    `json:"attempt_seq"`
	OrphanTxHash       string `json:"orphan_tx_hash"`
	LastSeenBlock      uint64 `json:"last_seen_block"`
	RPCSource          string `json:"rpc_source"`
	OperatorResolution string `json:"operator_resolution"`
	Reason             string `json:"reason"`
}

// ServeRecordOrphan handles POST /admin/payout/record-orphan.
//
// Response table per §4.7:
//   - 200 OK on existing-orphan resolution.
//   - 201 Created on new-orphan insert.
//   - 400 missing_field / bad_format.
//   - 404 — no matching orphan row (resolution variant only).
//   - 409 — orphan row already exists for (payout_id, attempt_seq, orphan_tx_hash).
//   - 422 — referenced payout_attempts row not found.
//   - 500 internal_error.
func (s *OrphansService) ServeRecordOrphan(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64*1024))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	var req recordOrphanRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	if strings.TrimSpace(req.Reason) == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}

	// Branch on (id) presence: if non-zero, resolution variant;
	// else new-orphan insert.
	if req.OrphanID > 0 {
		s.serveResolve(w, r, req)
		return
	}
	s.serveRecord(w, r, req)
}

// serveRecord inserts a new orphan row, populating the §4.7
// IMMUTABLE snapshot columns from a join against
// ledger_payout_ready + payout_attempts. Also writes the
// is_cancel_self_transfer outbox row on the cancel carve-out
// when the attempt's reorg_reactivated_at_utc is non-NULL.
func (s *OrphansService) serveRecord(w http.ResponseWriter, r *http.Request, req recordOrphanRequest) {
	if req.PayoutID == 0 || req.AttemptSeq == 0 ||
		strings.TrimSpace(req.OrphanTxHash) == "" ||
		strings.TrimSpace(req.RPCSource) == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}

	ctx := r.Context()
	conn, err := s.db.Conn(ctx)
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Step 1 — join lpr + pa to compute snapshot columns AND
	// pull is_cancel_self_transfer + reorg metadata for the
	// carve-out decision.
	var (
		providerID         string
		providerCredits    int64
		grossCredits       int64
		amountBaseUnits    int64
		isCancelSelf       int
		nonce              int64
		reorgReactivatedAt sql.NullString
	)
	err = conn.QueryRowContext(ctx, `
SELECT lpr.provider_id,
       lpr.provider_credits,
       lpr.gross_credits,
       pa.amount_base_units,
       pa.is_cancel_self_transfer,
       pa.nonce,
       pa.updated_at_utc
  FROM payout_attempts pa
  JOIN ledger_payout_ready lpr ON lpr.id = pa.payout_id
 WHERE pa.payout_id = ? AND pa.attempt_seq = ?`,
		req.PayoutID, req.AttemptSeq,
	).Scan(&providerID, &providerCredits, &grossCredits,
		&amountBaseUnits, &isCancelSelf, &nonce, &reorgReactivatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusUnprocessableEntity, "attempt_not_found")
			return
		}
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	stamp := s.nowFn().UTC().Format(time.RFC3339Nano)
	txHashLower := strings.ToLower(strings.TrimSpace(req.OrphanTxHash))

	// Step 2 — INSERT the orphan row with snapshot columns.
	res, err := conn.ExecContext(ctx, `
INSERT INTO payout_reorg_orphans
    (payout_id, attempt_seq, orphan_tx_hash, last_seen_block,
     observed_at_utc, rpc_source,
     observed_provider_id, observed_provider_credits,
     observed_gross_credits, observed_amount_base_units)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		req.PayoutID, req.AttemptSeq, txHashLower, req.LastSeenBlock,
		stamp, req.RPCSource,
		providerID, providerCredits, grossCredits, amountBaseUnits,
	)
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	orphanID, err := res.LastInsertId()
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	// Step 3 — cancel-self-transfer carve-out. When the orphaned
	// attempt is a cancel AND the runner-side stale marker is
	// non-NULL (i.e. the cancel was reorg-reactivated), insert a
	// cancel_reconfirm_stale_outbox row so the §4.7 PAGE event
	// fires durably after the 3 × run_interval window.
	//
	// NO ledger_payout_ready revert on the cancel path — that is
	// the v0.1.14 codex round-15 MAJOR-2 normative carve-out.
	if isCancelSelf == 1 && reorgReactivatedAt.Valid && reorgReactivatedAt.String != "" {
		if _, err := conn.ExecContext(ctx, `
INSERT OR IGNORE INTO cancel_reconfirm_stale_outbox
    (payout_id, attempt_seq, stale_started_at_utc, nonce, tx_hash,
     last_seen_block, reorg_reactivated_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?)`,
			req.PayoutID, req.AttemptSeq, stamp, nonce, txHashLower,
			req.LastSeenBlock, reorgReactivatedAt.String,
		); err != nil {
			s.log.Error().Err(err).Send()
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed = true

	s.emitOrphanRecorded(orphanID, req, providerID, providerCredits, grossCredits, amountBaseUnits, isCancelSelf)
	writeJSON(w, http.StatusCreated, map[string]any{
		"ok":                      true,
		"id":                      orphanID,
		"is_cancel_self_transfer": isCancelSelf == 1,
	})
}

// serveResolve updates an existing orphan row's
// operator_resolution + resolved_at_utc. Per §4.7 the
// resolution flow is record-only (the compensation row itself,
// when warranted, is INSERTed via the SPEC-005 vX.Y+1 admin
// endpoint, NOT raw SQL here).
func (s *OrphansService) serveResolve(w http.ResponseWriter, r *http.Request, req recordOrphanRequest) {
	if strings.TrimSpace(req.OperatorResolution) == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}
	stamp := s.nowFn().UTC().Format(time.RFC3339Nano)
	res, err := s.db.ExecContext(r.Context(), `
UPDATE payout_reorg_orphans
   SET operator_resolution = ?,
       resolved_at_utc = ?
 WHERE id = ?
   AND resolved_at_utc IS NULL`,
		req.OperatorResolution, stamp, req.OrphanID,
	)
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	rows, _ := res.RowsAffected()
	if rows == 0 {
		writeError(w, http.StatusNotFound, "orphan_not_found_or_already_resolved")
		return
	}
	s.emitOrphanResolved(req.OrphanID, req.OperatorResolution, req.Reason)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"id":              req.OrphanID,
		"resolved_at_utc": stamp,
	})
}

func (s *OrphansService) emitOrphanRecorded(
	orphanID int64, req recordOrphanRequest,
	providerID string, providerCredits, grossCredits, amountBaseUnits int64,
	isCancelSelf int,
) {
	// §7.1 payout_reorg_orphan_recorded event.
	s.log.Warn().
		Str("event", "payout_reorg_orphan_recorded").
		Int64("orphan_id", orphanID).
		Int64("payout_id", req.PayoutID).
		Int("attempt_seq", req.AttemptSeq).
		Str("orphan_tx_hash", strings.ToLower(req.OrphanTxHash)).
		Uint64("last_seen_block", req.LastSeenBlock).
		Str("rpc_source", req.RPCSource).
		Str("observed_provider_id", providerID).
		Int64("observed_provider_credits", providerCredits).
		Int64("observed_gross_credits", grossCredits).
		Int64("observed_amount_base_units", amountBaseUnits).
		Int("is_cancel_self_transfer", isCancelSelf).
		Str("reason", req.Reason).
		Str("ts_utc", s.nowFn().UTC().Format(time.RFC3339Nano)).
		Str("severity", "PAGE").
		Send()
}

func (s *OrphansService) emitOrphanResolved(orphanID int64, resolution, reason string) {
	s.log.Info().
		Str("event", "payout_reorg_orphan_resolved").
		Int64("orphan_id", orphanID).
		Str("resolution", resolution).
		Str("reason", reason).
		Str("ts_utc", s.nowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}

// ListUnemittedStaleOutboxOlderThan returns cancel_reconfirm_stale_outbox
// rows that the reaper should pick up. Mirrors the §4.8a list
// helper but for the §4.8c outbox table. Cutoff is now -
// 3 × run_interval per §4.7.
func ListUnemittedStaleOutboxOlderThan(ctx context.Context, db *sql.DB, cutoff time.Time) ([]StaleOutboxRow, error) {
	cutoffStr := cutoff.UTC().Format(time.RFC3339Nano)
	rows, err := db.QueryContext(ctx, `
SELECT id, payout_id, attempt_seq, stale_started_at_utc, nonce,
       tx_hash, last_seen_block, reorg_reactivated_at_utc
  FROM cancel_reconfirm_stale_outbox
 WHERE emitted_to_log = 0
   AND stale_started_at_utc < ?
 ORDER BY id ASC`, cutoffStr,
	)
	if err != nil {
		return nil, fmt.Errorf("list stale outbox: %w", err)
	}
	defer rows.Close()
	var out []StaleOutboxRow
	for rows.Next() {
		var r StaleOutboxRow
		if err := rows.Scan(&r.ID, &r.PayoutID, &r.AttemptSeq,
			&r.StaleStartedAtUTC, &r.Nonce, &r.TxHash,
			&r.LastSeenBlock, &r.ReorgReactivatedAtUTC); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// StaleOutboxRow is one cancel_reconfirm_stale_outbox row.
type StaleOutboxRow struct {
	ID                    int64
	PayoutID              int64
	AttemptSeq            int
	StaleStartedAtUTC     string
	Nonce                 int64
	TxHash                string
	LastSeenBlock         uint64
	ReorgReactivatedAtUTC string
}

// ClaimAndEmitStaleOutbox CAS-claims one cancel_reconfirm_stale_outbox
// row by id. Mirrors RuntimeFlagWriter.ClaimAndEmit. emit is
// invoked only when the CAS UPDATE returned 1 row.
func ClaimAndEmitStaleOutbox(
	ctx context.Context, db *sql.DB, id int64,
	emit func(row StaleOutboxRow),
) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	var got int64
	err = conn.QueryRowContext(ctx,
		`UPDATE cancel_reconfirm_stale_outbox
		    SET emitted_to_log = 1
		  WHERE id = ? AND emitted_to_log = 0
		 RETURNING id`, id,
	).Scan(&got)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			if _, cerr := conn.ExecContext(ctx, `COMMIT`); cerr != nil {
				return cerr
			}
			committed = true
			return nil
		}
		return fmt.Errorf("cas claim stale outbox %d: %w", id, err)
	}

	var row StaleOutboxRow
	err = conn.QueryRowContext(ctx, `
SELECT id, payout_id, attempt_seq, stale_started_at_utc, nonce,
       tx_hash, last_seen_block, reorg_reactivated_at_utc
  FROM cancel_reconfirm_stale_outbox
 WHERE id = ?`, got,
	).Scan(&row.ID, &row.PayoutID, &row.AttemptSeq,
		&row.StaleStartedAtUTC, &row.Nonce, &row.TxHash,
		&row.LastSeenBlock, &row.ReorgReactivatedAtUTC)
	if err != nil {
		return fmt.Errorf("read stale outbox row %d: %w", got, err)
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	if emit != nil {
		emit(row)
	}
	return nil
}
