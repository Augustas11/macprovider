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

	// Step 2 — INSERT the orphan row with snapshot columns. Codex
	// Step 3 r1 [code:1.1] MEDIUM closure: a UNIQUE INDEX on
	// (payout_id, attempt_seq, orphan_tx_hash) WHERE
	// resolved_at_utc IS NULL (migration 0011) makes the duplicate
	// path a 409, not a 500 or a silent duplicate row.
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
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "orphan_already_recorded")
			return
		}
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
	// non-NULL (i.e. the cancel was reorg-reactivated), the
	// runner-owned ProduceStaleOutboxRows producer (called every
	// runner cycle) is the canonical path for emitting
	// payout_cancel_self_transfer_reconfirm_stale via the
	// cancel_reconfirm_stale_outbox table.
	//
	// Codex Step 3 r2 [arch:r2-3.2-B] MAJOR closure: the prior
	// admin-side INSERT OR IGNORE was removed because it wrote
	// the same outbox table without the runner's CAS on
	// payout_attempts.cancel_reconfirm_stale_paged_at_utc AND
	// without two-RPC verification — the UNIQUE INDEX is on
	// (payout_id, attempt_seq, stale_started_at_utc) so admin
	// and runner inserts with different timestamps could both
	// survive, causing duplicate PAGE emissions per stale period.
	// The runner is now the single producer; this branch only
	// records the orphan observation.
	//
	// NO ledger_payout_ready revert on the cancel path — that is
	// the v0.1.14 codex round-15 MAJOR-2 normative carve-out.
	_ = isCancelSelf       // retained for the §7.1 emit below
	_ = reorgReactivatedAt // retained for the §7.1 emit below

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

// ProduceStaleOutboxRows is the §4.7 step 5 RUNNER-OWNED
// stale-transition producer (codex Step 3 r1 [arch:3.2] MAJOR
// closure; round 2 [arch:r2-3.2-A] MAJOR closure adds both-RPC
// not-found verification; round 2 [arch:r2-3.3] + [code:r2-2.1]
// MEDIUM closure persists run_id).
//
// SPEC §4.7 + §4.8c: when a reorg-reactivated cancel row has been
// re-broadcast-ready-but-not-confirmed for longer than 3 ×
// run_interval AND BOTH RPCs still return "not found" for the
// cancel tx, the runner MUST do the NULL→now CAS on
// payout_attempts.cancel_reconfirm_stale_paged_at_utc and insert
// the cancel_reconfirm_stale_outbox row in the SAME BEGIN
// IMMEDIATE transaction. The sync emit happens AFTER commit via
// the shared ClaimAndEmitStaleOutbox helper.
//
// The two-RPC check at the START of each candidate evaluation is
// the v0.1.21 SPEC §4.7 escalation predicate: a cancel that one
// of the two RPCs has already re-observed is NOT a stranded
// cancel, so emitting the PAGE prematurely would mask the next
// cycle's normal pollCancelOnce confirmation.
//
// Selection criteria for a stale cancel row:
//
//   - is_cancel_self_transfer = 1
//   - raw_signed_tx IS NOT NULL AND broadcast_at_utc IS NOT NULL
//     (the cancel was broadcast)
//   - confirmed_at_utc IS NULL (still un-reconfirmed after reorg)
//   - cancel_reconfirm_stale_paged_at_utc IS NULL (no prior PAGE)
//   - abandoned_at_utc IS NULL (operator hasn't intervened)
//   - updated_at_utc < now - 3 × run_interval (stale threshold;
//     the field doubles as reorg_reactivated_at_utc since the
//     §4.7 LIVE-AGAIN UPDATE writes this column atomically with
//     the confirmed_at_utc=NULL flip)
//   - PLUS: TwoRPCs.Primary AND TwoRPCs.Secondary BOTH return
//     nil receipt + nil error for the tx_hash (codex Step 3 r2
//     [arch:r2-3.2-A] MAJOR closure).
//
// Idempotent per-row via the partial UNIQUE INDEX
// idx_crso_one_per_stale_period at the DB layer — if two
// concurrent runners both selected the same row (lease takeover
// race), the second INSERT would violate the UNIQUE constraint
// and abort that row's txn without affecting others.
//
// runID is the §7.1 run_id captured at the top of the runner
// cycle — persisted in cancel_reconfirm_stale_outbox.run_id so
// the reaper can emit it on the recovery path without
// reconstructing.
//
// Returns the count of rows that produced outbox rows. Passing
// a zero-value TwoRPCs (i.e. nil clients) disables the producer
// entirely and returns (0, nil); tests use this path to avoid
// wiring mock RPCs when the producer is not under test.
//
// limit bounds the per-cycle PRODUCED outbox row count (#165 A1:
// derived from snap.MaxRowsPerRun). The SCAN is bounded only by
// the WHERE predicate (un-paged cancel-self-transfer rows older
// than the stale cutoff) and traversed in keyset-paginated chunks
// of staleOutboxChunkSize so memory stays O(chunk) regardless of
// backlog size. A defensive runner-cycle ceiling of
// staleOutboxScanCeiling rows caps total scan work; reaching it
// promotes the backlog WARN to PAGE severity. Non-actionable
// candidates (no tx_hash, transient RPC error, one-RPC-still-
// sees-receipt) do NOT consume the production limit — they're
// silently skipped and re-evaluated next cycle (their
// updated_at_utc doesn't advance, so they stay in the candidate
// set under cursor).
//
// A limit <= 0 is treated as "no production cap" (back-compat for
// any caller wiring a zero-value MaxRowsPerRun before the snapshot
// bound check fires).
//
// When production is capped before the candidate set is exhausted
// the producer emits a payout_stale_outbox_backlog WARN with the
// remaining-un-paged backlog count so operators can see drain
// progress; subsequent cycles continue.
func ProduceStaleOutboxRows(
	ctx context.Context, db *sql.DB, log zerolog.Logger,
	rpcs TwoRPCs, runID string,
	now time.Time, runInterval time.Duration, limit int,
) (int, error) {
	if rpcs.Primary == nil || rpcs.Secondary == nil {
		// Producer disabled — typically a test path. The reaper
		// + admin orphan path provide the recovery floor.
		return 0, nil
	}
	cutoff := now.Add(-3 * runInterval).UTC().Format(time.RFC3339Nano)
	// #165 R1+R2+R3 SECURITY HIGH closure: bound the PRODUCED outbox
	// row count, NOT the scanned candidate set. Non-actionable skip
	// branches (empty tx_hash, RPC error, one-RPC-still-sees-receipt)
	// persist in the candidate set across cycles (updated_at_utc
	// doesn't advance on skip), so any *tight* ceiling on scanned
	// rows reintroduces prefix-starvation denial-of-detection.
	//
	// R3 SEC HIGH closure refines this further: load via keyset
	// pagination in chunks of staleOutboxChunkSize so memory stays
	// bounded at O(chunk) regardless of pathological backlog, and
	// terminate as soon as `produced == limit` (zero wasted scan
	// past the production cap). A defensive hard ceiling
	// staleOutboxScanCeiling caps total cycle scan rows to prevent
	// runaway scans from blowing past the runner cycle budget; when
	// hit, the producer emits payout_stale_outbox_backlog WARN with
	// scan_ceiling_hit=true so operators see the emergency.
	const (
		staleOutboxChunkSize     = 256
		staleOutboxScanCeiling   = 20000
	)
	type cand struct {
		PayoutID         int64
		AttemptSeq       int
		Nonce            int64
		TxHash           sql.NullString
		BlockNumber      sql.NullInt64
		ReorgReactivated string
	}

	produced := 0
	scannedAll := true
	scanCeilingHit := false
	totalScanned := 0
	var (
		cursorUpdated   = ""
		cursorPayoutID  int64
		cursorAttemptSeq int
		firstChunk      = true
	)
	staleStarted := now.UTC().Format(time.RFC3339Nano)

chunkLoop:
	for {
		if totalScanned >= staleOutboxScanCeiling {
			scanCeilingHit = true
			scannedAll = false
			break
		}
		// #165 R4 code LOW closure: clamp the chunk LIMIT to the
		// remaining ceiling so we never scan past
		// staleOutboxScanCeiling rows in a single cycle (R4 audit
		// flagged a 20224-row worst case at chunk 256 + ceiling
		// 20000 — off by one chunk).
		chunkLimit := staleOutboxChunkSize
		if remaining := staleOutboxScanCeiling - totalScanned; remaining < chunkLimit {
			chunkLimit = remaining
		}
		// Keyset query: portable strict-tuple-ordering form
		// `(updated_at_utc > ?) OR (... = ? AND payout_id > ?) OR
		// (... = ? AND ... = ? AND attempt_seq > ?)`. Works on all
		// SQLite versions in the project's mattn/go-sqlite3 line.
		var (
			chunk      []cand
			rows       *sql.Rows
			queryErr   error
		)
		if firstChunk {
			rows, queryErr = db.QueryContext(ctx, `
SELECT payout_id, attempt_seq, nonce, tx_hash, block_number, updated_at_utc
  FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND raw_signed_tx IS NOT NULL
   AND broadcast_at_utc IS NOT NULL
   AND confirmed_at_utc IS NULL
   AND cancel_reconfirm_stale_paged_at_utc IS NULL
   AND abandoned_at_utc IS NULL
   AND updated_at_utc < ?
 ORDER BY updated_at_utc ASC, payout_id ASC, attempt_seq ASC
 LIMIT ?`, cutoff, chunkLimit)
		} else {
			rows, queryErr = db.QueryContext(ctx, `
SELECT payout_id, attempt_seq, nonce, tx_hash, block_number, updated_at_utc
  FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND raw_signed_tx IS NOT NULL
   AND broadcast_at_utc IS NOT NULL
   AND confirmed_at_utc IS NULL
   AND cancel_reconfirm_stale_paged_at_utc IS NULL
   AND abandoned_at_utc IS NULL
   AND updated_at_utc < ?
   AND (
        updated_at_utc > ?
     OR (updated_at_utc = ? AND payout_id > ?)
     OR (updated_at_utc = ? AND payout_id = ? AND attempt_seq > ?)
   )
 ORDER BY updated_at_utc ASC, payout_id ASC, attempt_seq ASC
 LIMIT ?`,
				cutoff,
				cursorUpdated,
				cursorUpdated, cursorPayoutID,
				cursorUpdated, cursorPayoutID, cursorAttemptSeq,
				chunkLimit,
			)
		}
		firstChunk = false
		if queryErr != nil {
			return produced, fmt.Errorf("ProduceStaleOutboxRows: SELECT: %w", queryErr)
		}
		for rows.Next() {
			var c cand
			if err := rows.Scan(&c.PayoutID, &c.AttemptSeq, &c.Nonce,
				&c.TxHash, &c.BlockNumber, &c.ReorgReactivated); err != nil {
				rows.Close()
				return produced, err
			}
			chunk = append(chunk, c)
		}
		rows.Close()
		if len(chunk) == 0 {
			break
		}
		// Advance cursor to the LAST row in this chunk before
		// processing — even on per-row early return / break, the
		// next cycle resumes past this chunk.
		last := chunk[len(chunk)-1]
		cursorUpdated = last.ReorgReactivated
		cursorPayoutID = last.PayoutID
		cursorAttemptSeq = last.AttemptSeq
		totalScanned += len(chunk)
		for _, c := range chunk {
			if ctx.Err() != nil {
				return produced, ctx.Err()
			}
			if limit > 0 && produced >= limit {
				scannedAll = false
				break chunkLoop
			}
		// Codex Step 3 r2 [arch:r2-3.2-A] MAJOR closure: SPEC §4.7
		// requires BOTH RPCs to still return "not found" before
		// the stale PAGE fires. A cancel that one of the two
		// RPCs has already re-observed is NOT a stranded cancel
		// — the next pollCancelOnce cycle will re-confirm it.
		// Skip silently; the next cycle re-evaluates.
		if !c.TxHash.Valid || c.TxHash.String == "" {
			continue
		}
		txHash := c.TxHash.String
		recA, errA := rpcs.Primary.TransactionReceipt(ctx, txHash)
		recB, errB := rpcs.Secondary.TransactionReceipt(ctx, txHash)
		if errA != nil || errB != nil {
			// RPC error is NOT a stale signal — skip; the reorg
			// poll cycle's payout_reorg_poll_rpc_error will fire
			// on the same row.
			continue
		}
		if recA != nil || recB != nil {
			// At least one RPC sees a receipt → the cancel is
			// reconfirmable; do NOT page.
			continue
		}
		// Per-row BEGIN IMMEDIATE: CAS the marker + INSERT outbox.
		conn, err := db.Conn(ctx)
		if err != nil {
			log.Error().Err(err).Int64("payout_id", c.PayoutID).
				Int("attempt_seq", c.AttemptSeq).
				Str("event", "payout_stale_outbox_producer_conn_failed").Send()
			continue
		}
		if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
			conn.Close()
			log.Error().Err(err).Int64("payout_id", c.PayoutID).Send()
			continue
		}
		committed := false
		// CAS: only flip NULL→now. If another runner beat us, the
		// row count = 0 and we skip this row.
		// Codex Step 3 r3 [code:r3-3.1] MEDIUM closure: SPEC §4.7
		// stale transition SQL sets BOTH the stale marker AND
		// updated_at_utc. Advancing updated_at_utc preserves the
		// "row was just touched by the runner" semantics that
		// stale-reservation halts (§5.3) and the reorg-poll
		// cadence both rely on.
		res, err := conn.ExecContext(ctx, `
UPDATE payout_attempts
   SET cancel_reconfirm_stale_paged_at_utc = ?,
       updated_at_utc = ?
 WHERE payout_id = ? AND attempt_seq = ?
   AND cancel_reconfirm_stale_paged_at_utc IS NULL
   AND confirmed_at_utc IS NULL`,
			staleStarted, staleStarted, c.PayoutID, c.AttemptSeq,
		)
		if err != nil {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
			conn.Close()
			log.Error().Err(err).Int64("payout_id", c.PayoutID).Send()
			continue
		}
		affected, _ := res.RowsAffected()
		if affected == 0 {
			// Beaten by another runner OR re-confirmed in the
			// same cycle. Skip.
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
			conn.Close()
			continue
		}
		// Insert the outbox row. INSERT OR IGNORE protects against
		// the rare (payout_id, attempt_seq, stale_started_at_utc)
		// collision (same-second produce by two processes). Codex
		// Step 3 r2 [arch:r2-3.3] MEDIUM closure adds the run_id
		// column so the reaper can emit the §7.1 run_id field.
		lastBlock := int64(0)
		if c.BlockNumber.Valid {
			lastBlock = c.BlockNumber.Int64
		}
		if _, err := conn.ExecContext(ctx, `
INSERT OR IGNORE INTO cancel_reconfirm_stale_outbox
    (payout_id, attempt_seq, stale_started_at_utc, nonce, tx_hash,
     last_seen_block, reorg_reactivated_at_utc, run_id)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			c.PayoutID, c.AttemptSeq, staleStarted, c.Nonce, txHash,
			lastBlock, c.ReorgReactivated, runID,
		); err != nil {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
			conn.Close()
			log.Error().Err(err).Int64("payout_id", c.PayoutID).Send()
			continue
		}
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
			conn.Close()
			log.Error().Err(err).Int64("payout_id", c.PayoutID).Send()
			continue
		}
		committed = true
		conn.Close()
		if committed {
			produced++
			// Post-commit sync CAS-claim emit. Look up the row
			// we just produced (UNIQUE INDEX matches) and emit.
			var outboxID int64
			_ = db.QueryRowContext(ctx, `
SELECT id FROM cancel_reconfirm_stale_outbox
 WHERE payout_id = ? AND attempt_seq = ? AND stale_started_at_utc = ?`,
				c.PayoutID, c.AttemptSeq, staleStarted,
			).Scan(&outboxID)
			if outboxID > 0 {
				_ = ClaimAndEmitStaleOutbox(ctx, db, outboxID, func(row StaleOutboxRow) {
					// Codex Step 3 r2 [arch:r2-3.3] + [code:r2-2.1]
					// MEDIUM closure: full §7.1 field set including
					// run_id + updated_at_utc (== reorg_reactivated_at_utc
					// per SPEC §4.8c column definition).
					log.Error().
						Str("event", "payout_cancel_self_transfer_reconfirm_stale").
						Int64("event_id", row.ID).
						Str("run_id", row.RunID).
						Int64("payout_id", row.PayoutID).
						Int("attempt_seq", row.AttemptSeq).
						Str("stale_started_at_utc", row.StaleStartedAtUTC).
						Int64("nonce", row.Nonce).
						Str("tx_hash", row.TxHash).
						Uint64("last_seen_block", row.LastSeenBlock).
						Str("reorg_reactivated_at_utc", row.ReorgReactivatedAtUTC).
						Str("updated_at_utc", row.ReorgReactivatedAtUTC).
						Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
						Str("severity", "PAGE").Send()
				})
			}
		}
		} // close inner per-row range
		if len(chunk) < chunkLimit {
			// Drained — no more candidates past the cursor.
			break
		}
	} // close chunkLoop

	// #165 A1 backlog gauge. Emit payout_stale_outbox_backlog WARN
	// when production was capped before the candidate set was
	// exhausted (limit > 0 AND produced == limit AND we broke early)
	// OR when the defensive scan ceiling was hit (true emergency:
	// backlog is so deep the producer can't drain it under cycle
	// budget). The event repeats every runner cycle while backlog
	// persists — intentionally, so the operator sees the gauge each
	// cycle until the queue drains under cap.
	productionCapped := limit > 0 && produced >= limit && !scannedAll
	if productionCapped || scanCeilingHit {
		var total int
		if err := db.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM payout_attempts
 WHERE is_cancel_self_transfer = 1
   AND raw_signed_tx IS NOT NULL
   AND broadcast_at_utc IS NOT NULL
   AND confirmed_at_utc IS NULL
   AND cancel_reconfirm_stale_paged_at_utc IS NULL
   AND abandoned_at_utc IS NULL
   AND updated_at_utc < ?`, cutoff).Scan(&total); err != nil {
			// COUNT failure is observability-only; degrade to a
			// cap-hit signal (total=-1 sentinel) rather than
			// stalling the producer.
			total = -1
		}
		// Severity is PAGE when scan_ceiling_hit (true emergency:
		// backlog exceeds the defensive runner-cycle scan budget) and
		// WARN otherwise (normal cap-throttled drain in progress).
		severity := "WARN"
		if scanCeilingHit {
			severity = "PAGE"
		}
		log.Warn().
			Str("event", "payout_stale_outbox_backlog").
			Str("run_id", runID).
			Int("limit", limit).
			Int("produced", produced).
			Int("total_candidates", total).
			Bool("scan_ceiling_hit", scanCeilingHit).
			Int("total_scanned", totalScanned).
			Str("ts_utc", now.UTC().Format(time.RFC3339Nano)).
			Str("severity", severity).
			Send()
	}
	return produced, nil
}

// ListUnemittedStaleOutboxOlderThan returns cancel_reconfirm_stale_outbox
// rows that the reaper should pick up. Mirrors the §4.8a list
// helper but for the §4.8c outbox table. Cutoff is now -
// 3 × run_interval per §4.7.
func ListUnemittedStaleOutboxOlderThan(ctx context.Context, db *sql.DB, cutoff time.Time) ([]StaleOutboxRow, error) {
	cutoffStr := cutoff.UTC().Format(time.RFC3339Nano)
	rows, err := db.QueryContext(ctx, `
SELECT id, payout_id, attempt_seq, stale_started_at_utc, nonce,
       tx_hash, last_seen_block, reorg_reactivated_at_utc,
       COALESCE(run_id, '')
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
			&r.LastSeenBlock, &r.ReorgReactivatedAtUTC, &r.RunID); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// StaleOutboxRow is one cancel_reconfirm_stale_outbox row.
// Codex Step 3 r2 [arch:r2-3.3] + [code:r2-2.1] MEDIUM closure
// added RunID so the reaper can emit the SPEC §7.1 run_id field
// on the recovery path. ReorgReactivatedAtUTC IS the
// updated_at_utc value at LIVE-AGAIN time per §4.8c column
// definition — emitters surface it as `updated_at_utc`.
type StaleOutboxRow struct {
	ID                    int64
	PayoutID              int64
	AttemptSeq            int
	StaleStartedAtUTC     string
	Nonce                 int64
	TxHash                string
	LastSeenBlock         uint64
	ReorgReactivatedAtUTC string
	RunID                 string
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
       tx_hash, last_seen_block, reorg_reactivated_at_utc,
       COALESCE(run_id, '')
  FROM cancel_reconfirm_stale_outbox
 WHERE id = ?`, got,
	).Scan(&row.ID, &row.PayoutID, &row.AttemptSeq,
		&row.StaleStartedAtUTC, &row.Nonce, &row.TxHash,
		&row.LastSeenBlock, &row.ReorgReactivatedAtUTC, &row.RunID)
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
