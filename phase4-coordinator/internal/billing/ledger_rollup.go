package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

// SPEC-022 R-15.11 / SPEC-005 §7.8 (#1793 slice 8): settled ledger rollup.
// Once a request's evidence is archived (R-15) and every one of its credits
// settled into a live payout whose window is at least
// billing.ledger_rollup.min_settlement_cycles completed windows old, its
// ledger detail rows (credits, operator credits, provider identity
// snapshots, evidence tombstones) are written to a verified archive and
// replaced by per-payout, per-provider, per-hour, per-model, per-fault-flag
// aggregates in ledger_settled_rollups. Every reader of payable totals,
// earnings, payouts, and statements adds the aggregates, so its totals do
// not change. The frozen settlement finality of the request stays hot.

const (
	ledgerRollupFormat     = "macprovider-ledger-rollup-archive-v1"
	ledgerRollupNamePrefix = "ledger-rollup"
	ledgerRollupRoleDetail = "detail"
	ledgerRollupRoleRef    = "reference"

	ledgerRollupStatusNothingDue = "nothing_due"
	ledgerRollupStatusRolledUp   = "rolled_up"
	ledgerRollupStatusDiskLow    = "refused_archive_disk_low"
	ledgerRollupStatusInvalid    = "refused_archive_invalid"
	ledgerRollupStatusBudget     = "run_budget_spent"

	ledgerRollupPayoutChunk = 200
	// ledgerRollupHoldsPerRun bounds the holds one export re-checks.
	ledgerRollupHoldsPerRun = 2000

	// Reasons that keep a request hot for good: no hold is kept.
	ledgerRollupSkipNoCredit         = "no_ledger_credit"
	ledgerRollupSkipResolution       = "credit_resolution_or_restatement"
	ledgerRollupSkipQuarantined      = "credit_quarantined"
	ledgerRollupSkipPayoutVoided     = "payout_voided"
	ledgerRollupSkipEvidenceKeptHot  = "evidence_kept_hot"
	ledgerRollupSkipChangedAfterCopy = "changed_since_export"
)

// ledgerRollupPermanentSkip reports whether a skip reason never clears. Any
// other reason holds the request for a later re-check.
func ledgerRollupPermanentSkip(reason string) bool {
	switch reason {
	case ledgerRollupSkipNoCredit, ledgerRollupSkipResolution, ledgerRollupSkipQuarantined,
		ledgerRollupSkipPayoutVoided, ledgerRollupSkipEvidenceKeptHot:
		return true
	}
	return false
}

func maxInt64(ids []int64) int64 {
	var m int64
	for _, id := range ids {
		if id > m {
			m = id
		}
	}
	return m
}

// recordLedgerRollupSkip keeps a request skipped for a reason that can clear
// in the holds table, and drops it from there otherwise.
func recordLedgerRollupSkip(ctx context.Context, e evidenceExecer, requestID, reason, stamp string) error {
	if ledgerRollupPermanentSkip(reason) {
		_, err := e.ExecContext(ctx, `DELETE FROM ledger_rollup_holds WHERE request_id = ?`, requestID)
		return err
	}
	_, err := e.ExecContext(ctx, `
INSERT INTO ledger_rollup_holds (request_id, reason, held_at_utc) VALUES (?, ?, ?)
ON CONFLICT(request_id) DO UPDATE SET reason = excluded.reason, held_at_utc = excluded.held_at_utc`, requestID, reason, stamp)
	return err
}

// ledgerRollupDetailTables are deleted in this order: operator credits and
// tombstones reference the credit; identity snapshots are per request.
var ledgerRollupDetailTables = []string{
	"ledger_operator_credits",
	"settlement_evidence_archived_credits",
	"ledger_request_credits",
	"ledger_provider_identity_snapshots",
}

func ledgerRollupKnownTable(table string) bool {
	if table == "ledger_payout_ready" {
		return true
	}
	for _, t := range ledgerRollupDetailTables {
		if t == table {
			return true
		}
	}
	return false
}

// LedgerRollupOptions are the effective rollup settings.
type LedgerRollupOptions struct {
	Enabled               bool
	MinSettlementCycles   int
	CadenceDays           int
	ArchiveDir            string
	BatchSize             int
	BatchPause            time.Duration
	MaxRequestsPerArchive int
	RunBudget             time.Duration
	ArchiveMinFreeBytes   int64
	ArchiveMinFreePercent int
	// RequestLogRetention keeps a payout from rolling up while
	// request_log may still hold rows of its window (plus a day), so no
	// reconcile can see a request_log row whose credit was rolled up.
	RequestLogRetention time.Duration
}

// LedgerRollupOptionsFromConfig derives the rollup options; the archive and
// pacing settings are the evidence retention ones.
func LedgerRollupOptionsFromConfig(lc config.LedgerRollupConfig, rc config.BillingRetentionConfig, sc config.SettlementConfig, requestLogRetentionDays int) LedgerRollupOptions {
	return LedgerRollupOptions{
		RequestLogRetention:   time.Duration(requestLogRetentionDays) * 24 * time.Hour,
		Enabled:               lc.Enabled,
		MinSettlementCycles:   lc.MinSettlementCycles,
		CadenceDays:           sc.CadenceDays,
		ArchiveDir:            rc.ArchiveDir,
		BatchSize:             rc.BatchSize,
		BatchPause:            time.Duration(rc.BatchPauseMS) * time.Millisecond,
		MaxRequestsPerArchive: rc.MaxRequestsPerRun,
		RunBudget:             time.Duration(rc.RunBudgetMinutes) * time.Minute,
		ArchiveMinFreeBytes:   rc.ArchiveMinFreeBytes,
		ArchiveMinFreePercent: rc.ArchiveMinFreePercent,
	}
}

func (o LedgerRollupOptions) normalized() (LedgerRollupOptions, error) {
	if o.MinSettlementCycles < 2 {
		return o, fmt.Errorf("ledger rollup min_settlement_cycles must be >= 2")
	}
	if o.CadenceDays <= 0 {
		return o, fmt.Errorf("settlement cadence_days must be positive")
	}
	if o.BatchSize < 1 {
		o.BatchSize = 1
	}
	if o.MaxRequestsPerArchive < 1 {
		o.MaxRequestsPerArchive = 1
	}
	if o.RunBudget <= 0 {
		o.RunBudget = evidenceRetentionDefaultRunBudget
	}
	return o, nil
}

// LedgerRollupReport is what one rollup run did.
type LedgerRollupReport struct {
	Status             string `json:"status"`
	CutoffWindowEndUTC string `json:"cutoff_window_end_utc,omitempty"`
	PayoutCursor       int64  `json:"payout_cursor"`
	Archives           int    `json:"archives"`
	RolledRequests     int    `json:"rolled_requests"`
	RolledCredits      int64  `json:"rolled_credits"`
	KeptRequests       int    `json:"kept_requests"`
	ArchiveFile        string `json:"archive_file,omitempty"`
	ArchiveSHA256      string `json:"archive_sha256,omitempty"`
	Error              string `json:"error,omitempty"`
}

func (s *Store) ensureLedgerRollupTables(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS ledger_settled_rollups (
    settlement_id INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    hour_utc TEXT NOT NULL,
    model TEXT NOT NULL,
    fault_flag TEXT NOT NULL,
    credit_count INTEGER NOT NULL CHECK(credit_count > 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    provider_credits INTEGER NOT NULL CHECK(provider_credits >= 0),
    operator_credits INTEGER NOT NULL CHECK(operator_credits >= 0),
    min_ts_utc TEXT NOT NULL,
    max_ts_utc TEXT NOT NULL,
    max_attestation_class TEXT NULL,
    -- The SPEC-043-R010 pool binding ('' for none) creator earnings read.
    pool_id TEXT NOT NULL DEFAULT '',
    PRIMARY KEY(settlement_id, provider_id, hour_utc, model, fault_flag, pool_id)
);
CREATE INDEX IF NOT EXISTS idx_lsr_provider_hour ON ledger_settled_rollups(provider_id, hour_utc);
CREATE INDEX IF NOT EXISTS idx_lsr_hour ON ledger_settled_rollups(hour_utc);
CREATE TRIGGER IF NOT EXISTS trg_lsr_no_delete
BEFORE DELETE ON ledger_settled_rollups
BEGIN
    SELECT RAISE(ABORT, 'ledger settled rollup is permanent');
END;
CREATE TRIGGER IF NOT EXISTS trg_lsr_add_only
BEFORE UPDATE ON ledger_settled_rollups
WHEN NEW.settlement_id != OLD.settlement_id OR NEW.provider_id != OLD.provider_id
  OR NEW.hour_utc != OLD.hour_utc OR NEW.model != OLD.model OR NEW.fault_flag != OLD.fault_flag
  OR NEW.pool_id != OLD.pool_id
  OR NEW.credit_count <= OLD.credit_count
  OR NEW.gross_credits < OLD.gross_credits OR NEW.provider_credits < OLD.provider_credits
  OR NEW.operator_credits < OLD.operator_credits
BEGIN
    SELECT RAISE(ABORT, 'ledger settled rollup only grows');
END;
CREATE TABLE IF NOT EXISTS ledger_rollup_archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL UNIQUE,
    sha256 TEXT NOT NULL CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    size_bytes INTEGER NOT NULL CHECK(size_bytes > 0),
    request_count INTEGER NOT NULL CHECK(request_count > 0),
    row_counts_json TEXT NOT NULL,
    cutoff_window_end_utc TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('exported','deleted','failed')),
    deleted_requests INTEGER NOT NULL DEFAULT 0 CHECK(deleted_requests >= 0),
    last_error TEXT NOT NULL DEFAULT '',
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lra_status ON ledger_rollup_archives(status, id);
CREATE TABLE IF NOT EXISTS ledger_rollup_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    payout_cursor INTEGER NOT NULL DEFAULT 0 CHECK(payout_cursor >= 0),
    -- A payout larger than one archive is walked across archives:
    -- partial_payout_id is that payout and partial_request_cursor the last
    -- request id an archive took from it.
    partial_payout_id INTEGER NOT NULL DEFAULT 0 CHECK(partial_payout_id >= 0),
    partial_request_cursor TEXT NOT NULL DEFAULT '',
    updated_at_utc TEXT NOT NULL
);
-- Requests the walk passed for a reason that can clear; every run re-checks
-- them before walking payouts, so none stays hot only because the cursor
-- moved on.
CREATE TABLE IF NOT EXISTS ledger_rollup_holds (
    request_id TEXT PRIMARY KEY,
    reason TEXT NOT NULL,
    held_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lrh_held ON ledger_rollup_holds(held_at_utc);
-- SPEC-022 R-15.11: a tombstone leaves only with its credit, in the rollup
-- transaction that deletes the credit first.
DROP TRIGGER IF EXISTS trg_seac_no_delete;
CREATE TRIGGER trg_seac_no_delete
BEFORE DELETE ON settlement_evidence_archived_credits
WHEN EXISTS (SELECT 1 FROM ledger_request_credits c WHERE c.id = OLD.request_credit_id)
BEGIN
    SELECT RAISE(ABORT, 'settlement evidence archived credit is permanent');
END;`)
	return err
}

// ledgerRollupCutoff is the end of the settlement window that has at least
// MinSettlementCycles completed windows after it, and never later than the
// request_log retention horizon minus a day.
func (s *Store) ledgerRollupCutoff(ctx context.Context, opts LedgerRollupOptions) (time.Time, bool, error) {
	var endText string
	err := s.reader().QueryRowContext(ctx, `
SELECT window_end_utc FROM ledger_settlement_windows
 WHERE cadence_days = ?
 ORDER BY window_end_utc DESC
 LIMIT 1 OFFSET ?`, opts.CadenceDays, opts.MinSettlementCycles).Scan(&endText)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, err
	}
	end, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(endText))
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse settlement window end: %w", err)
	}
	keep := opts.RequestLogRetention
	// The request_log window the process runs with is set at start
	// (SetRequestLogRetention); a reloaded value does not move the horizon
	// until the pruner and the reconcile guard move with it.
	if startup := time.Duration(s.requestLogRetention.Load()); startup > 0 {
		keep = startup
	}
	if keep > 0 {
		if horizon := s.nowUTC().Add(-keep - 24*time.Hour); horizon.Before(end) {
			end = horizon
		}
	}
	return end.UTC(), true, nil
}

// LedgerRollupMirrorWatermark reports the highest ledger credit id the stats
// billing mirror has copied. A credit above it is not rolled up: the mirror
// copies live rows by id and would never see it.
type LedgerRollupMirrorWatermark func(ctx context.Context) (int64, error)

// SetLedgerRollupMirrorWatermark installs the stats billing mirror gate; nil
// (no stats mirror configured) means no gate.
func (s *Store) SetLedgerRollupMirrorWatermark(f LedgerRollupMirrorWatermark) {
	if s == nil {
		return
	}
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	s.evidenceRetention.mirrorWatermark = f
}

func (s *Store) ledgerRollupMirrorWatermark() LedgerRollupMirrorWatermark {
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	return s.evidenceRetention.mirrorWatermark
}

// ledgerRollupBundle is one request's detail rows.
type ledgerRollupBundle struct {
	requestID string
	creditIDs []int64
	rows      map[string][]archiveRow
	payouts   []archiveRow
}

// collectLedgerRollupBundle reads one request and reports why it must stay
// hot ("" when it may roll up). A request rolls up only when every credit is
// settled into a ready or consumed payout whose window ended at or before
// cutoff, is payable, unquarantined, with no quarantine resolution or ceiling
// restatement, and is tombstoned by a deleted evidence archive.
func collectLedgerRollupBundle(ctx context.Context, q evidenceQueryer, requestID string, cutoff time.Time) (ledgerRollupBundle, string, error) {
	b := ledgerRollupBundle{requestID: requestID, rows: map[string][]archiveRow{}}
	credits, err := queryArchiveRows(ctx, q, `SELECT * FROM ledger_request_credits WHERE request_id = ? ORDER BY id`, requestID)
	if err != nil {
		return b, "", err
	}
	if len(credits) == 0 {
		return b, ledgerRollupSkipNoCredit, nil
	}
	b.rows["ledger_request_credits"] = credits
	var settlementIDs []int64
	for _, c := range credits {
		id, _ := c.int64("id")
		b.creditIDs = append(b.creditIDs, id)
		settled, _ := c.int64("settled")
		quarantined, _ := c.int64("quarantined")
		sid := c.nullInt("settlement_id")
		if settled != 1 || sid == nil {
			return b, "credit_unsettled", nil
		}
		if quarantined != 0 {
			return b, ledgerRollupSkipQuarantined, nil
		}
		settlementIDs = append(settlementIDs, *sid)
	}
	ph, args := int64Placeholders(b.creditIDs)
	var blockers, payable, tombstoned int64
	if err := q.QueryRowContext(ctx, `
SELECT (SELECT COUNT(*) FROM ledger_quarantine_resolutions WHERE request_credit_id IN (`+ph+`))
     + (SELECT COUNT(*) FROM ledger_ceiling_restatements WHERE request_credit_id IN (`+ph+`)),
       (SELECT COUNT(*) FROM spec022_payable_request_credits WHERE id IN (`+ph+`)),
       (SELECT COUNT(*) FROM settlement_evidence_archived_credits a
          JOIN settlement_evidence_archives sea ON sea.id = a.archive_id
         WHERE a.request_credit_id IN (`+ph+`) AND sea.status = 'deleted')`,
		append(append(append(append([]any{}, args...), args...), args...), args...)...).Scan(&blockers, &payable, &tombstoned); err != nil {
		return b, "", err
	}
	switch {
	case blockers > 0:
		return b, ledgerRollupSkipResolution, nil
	case payable != int64(len(credits)):
		return b, "credit_not_payable", nil
	case tombstoned != int64(len(credits)):
		// Evidence retention either has not reached the request yet (it is
		// held there, above the retention watermark, or in an archive still
		// being deleted) or keeps it hot for good.
		var pending int64
		if err := q.QueryRowContext(ctx, `
SELECT EXISTS (SELECT 1 FROM settlement_evidence_retention_holds WHERE request_id = ?)
    OR EXISTS (SELECT 1 FROM settlement_evidence_archived_credits WHERE request_credit_id IN (`+ph+`))
    OR ? > COALESCE((SELECT archived_low_watermark_credit_id FROM settlement_evidence_retention_state WHERE id = 1), 0)`,
			append(append([]any{requestID}, args...), maxInt64(b.creditIDs))...).Scan(&pending); err != nil {
			return b, "", err
		}
		if pending != 0 {
			return b, "evidence_not_archived", nil
		}
		return b, ledgerRollupSkipEvidenceKeptHot, nil
	}
	// SPEC-022 R-15.11: a request whose request_log rows remain (not yet
	// pruned or folded) stays until they leave, so no reconcile, recovery,
	// or wholesale fold can meet a request_log row whose credit or identity
	// was rolled up.
	var logged int64
	if err := q.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM request_log WHERE request_id = ?)`, requestID).Scan(&logged); err != nil {
		return b, "", err
	}
	if logged != 0 {
		return b, "request_log_present", nil
	}
	sph, sargs := int64Placeholders(settlementIDs)
	if b.payouts, err = queryArchiveRows(ctx, q, `SELECT * FROM ledger_payout_ready WHERE id IN (`+sph+`) ORDER BY id`, sargs...); err != nil {
		return b, "", err
	}
	byID := map[int64]archiveRow{}
	for _, p := range b.payouts {
		id, _ := p.int64("id")
		byID[id] = p
	}
	for _, sid := range settlementIDs {
		p, ok := byID[sid]
		if !ok {
			return b, "payout_missing", nil
		}
		status, _ := p.str("status")
		if status != "ready" && status != "consumed" {
			return b, ledgerRollupSkipPayoutVoided, nil
		}
		endText, _ := p.str("window_end_utc")
		end, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(endText))
		if err != nil || end.After(cutoff) {
			return b, "settlement_window_too_recent", nil
		}
	}
	if b.rows["ledger_operator_credits"], err = queryArchiveRows(ctx, q, `SELECT * FROM ledger_operator_credits WHERE request_credit_id IN (`+ph+`) ORDER BY id`, args...); err != nil {
		return b, "", err
	}
	if len(b.rows["ledger_operator_credits"]) != len(credits) {
		return b, "operator_split_missing", nil
	}
	if b.rows["settlement_evidence_archived_credits"], err = queryArchiveRows(ctx, q, `SELECT * FROM settlement_evidence_archived_credits WHERE request_credit_id IN (`+ph+`) ORDER BY request_credit_id`, args...); err != nil {
		return b, "", err
	}
	if b.rows["ledger_provider_identity_snapshots"], err = queryArchiveRows(ctx, q, `SELECT * FROM ledger_provider_identity_snapshots WHERE request_id = ? ORDER BY id`, requestID); err != nil {
		return b, "", err
	}
	return b, "", nil
}

func (b ledgerRollupBundle) tables() []verifiedarchive.TableRows {
	out := make([]verifiedarchive.TableRows, 0, len(ledgerRollupDetailTables)+1)
	for _, table := range ledgerRollupDetailTables {
		out = append(out, archiveTableRows(table, ledgerRollupRoleDetail, b.rows[table]))
	}
	out = append(out, archiveTableRows("ledger_payout_ready", ledgerRollupRoleRef, b.payouts))
	return out
}

// RunLedgerRollup resumes or writes a rollup archive, verifies it, and rolls
// its requests up in short transactions, repeating until no eligible payout
// remains, a refusal stops it, or the run budget is spent. It shares the
// evidence retention single-flight lock.
func (s *Store) RunLedgerRollup(ctx context.Context, opts LedgerRollupOptions) (report LedgerRollupReport, err error) {
	if !s.evidenceRetentionRun.TryLock() {
		return LedgerRollupReport{}, ErrEvidenceRetentionBusy
	}
	defer s.evidenceRetentionRun.Unlock()
	opts, err = opts.normalized()
	if err != nil {
		return LedgerRollupReport{}, err
	}
	if opts.ArchiveDir == "" {
		if opts.ArchiveDir, err = s.defaultEvidenceArchiveDir(ctx); err != nil {
			return LedgerRollupReport{}, err
		}
	}
	report = LedgerRollupReport{Status: ledgerRollupStatusNothingDue}
	defer func() {
		if err != nil {
			report.Error = err.Error()
		}
	}()
	deadline := s.nowUTC().Add(opts.RunBudget)
	cutoff, ok, err := s.ledgerRollupCutoff(ctx, opts)
	if err != nil {
		return report, err
	}
	if ok {
		report.CutoffWindowEndUTC = sqliteTimeText(cutoff)
	}
	for {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		if !s.nowUTC().Before(deadline) {
			report.Status = ledgerRollupStatusBudget
			return report, nil
		}
		archive, err := s.pendingLedgerRollupArchive(ctx)
		if err != nil {
			return report, err
		}
		if archive == nil {
			if !ok {
				return report, nil
			}
			free, total, err := archiveFilesystemSpaceFunc(opts.ArchiveDir)
			if err != nil {
				return report, err
			}
			if reason := verifiedarchive.BelowFloor(free, total, opts.ArchiveMinFreeBytes, opts.ArchiveMinFreePercent); reason != "" {
				report.Status = ledgerRollupStatusDiskLow
				report.Error = reason
				return report, nil
			}
			var kept int
			archive, kept, err = s.exportLedgerRollupArchive(ctx, opts, cutoff, deadline)
			report.KeptRequests += kept
			if errors.Is(err, errEvidenceArchiveDiskLow) {
				report.Status = ledgerRollupStatusDiskLow
				report.Error = err.Error()
				return report, nil
			}
			if err != nil {
				return report, err
			}
			if archive == nil {
				return report, s.fillLedgerRollupCursor(ctx, &report)
			}
		}
		report.ArchiveFile, report.ArchiveSHA256 = archive.fileName, archive.manifest.SHA256
		path := filepath.Join(opts.ArchiveDir, archive.fileName)
		verified, verr := verifiedarchive.Verify(path, archive.manifest, ledgerRollupKnownTable)
		if verr != nil {
			report.Status = ledgerRollupStatusInvalid
			return report, errors.Join(verr, s.setLedgerRollupArchiveStatus(context.WithoutCancel(ctx), archive.id, "failed", verr.Error()))
		}
		rolled, credits, err := s.applyLedgerRollupArchive(ctx, opts, archive.id, verified, cutoff, deadline)
		report.RolledRequests += rolled
		report.RolledCredits += credits
		if errors.Is(err, errEvidenceRetentionBudgetSpent) {
			report.Status = ledgerRollupStatusBudget
			return report, s.fillLedgerRollupCursor(ctx, &report)
		}
		if err != nil {
			if errors.Is(err, verifiedarchive.ErrInvalid) {
				report.Status = ledgerRollupStatusInvalid
				return report, errors.Join(err, s.setLedgerRollupArchiveStatus(context.WithoutCancel(ctx), archive.id, "failed", err.Error()))
			}
			return report, err
		}
		if err := s.setLedgerRollupArchiveStatus(ctx, archive.id, "deleted", ""); err != nil {
			return report, err
		}
		report.Archives++
		report.Status = ledgerRollupStatusRolledUp
	}
}

func (s *Store) fillLedgerRollupCursor(ctx context.Context, report *LedgerRollupReport) error {
	err := s.reader().QueryRowContext(ctx, `SELECT payout_cursor FROM ledger_rollup_state WHERE id = 1`).Scan(&report.PayoutCursor)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	return err
}

type ledgerRollupArchiveRecord struct {
	id       int64
	fileName string
	manifest verifiedarchive.Manifest
}

func (s *Store) pendingLedgerRollupArchive(ctx context.Context) (*ledgerRollupArchiveRecord, error) {
	var rec ledgerRollupArchiveRecord
	var countsJSON string
	err := s.db.QueryRowContext(ctx, `
SELECT id, file_name, sha256, size_bytes, request_count, row_counts_json, cutoff_window_end_utc, created_at_utc
  FROM ledger_rollup_archives
 WHERE status = 'exported'
 ORDER BY id
 LIMIT 1`).Scan(&rec.id, &rec.fileName, &rec.manifest.SHA256, &rec.manifest.SizeBytes, &rec.manifest.RequestCount, &countsJSON, &rec.manifest.CutoffWindowEndUTC, &rec.manifest.CreatedAtUTC)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(countsJSON), &rec.manifest.RowCounts); err != nil {
		return nil, err
	}
	rec.manifest.Format = ledgerRollupFormat
	rec.manifest.ArchiveFile = rec.fileName
	return &rec, nil
}

func (s *Store) setLedgerRollupArchiveStatus(ctx context.Context, id int64, status, lastError string) error {
	if len(lastError) > 1000 {
		lastError = lastError[:1000]
	}
	_, err := s.db.ExecContext(ctx, `
UPDATE ledger_rollup_archives SET status = ?, last_error = ?, updated_at_utc = ? WHERE id = ?`,
		status, lastError, sqliteTimeText(s.nowUTC()), id)
	return err
}

// exportLedgerRollupArchive walks payouts from the persisted cursor and
// writes the eligible requests of each payout whose window ended at or
// before cutoff. The walk reads a payout's credits through the provider's
// time index up to the window end, so it touches only that provider's
// rows that are still hot, and takes them in request-id order, so a payout
// larger than one archive continues in the next. The archive record and the
// cursor commit in one transaction, so a request is never written to two
// pending archives.
func (s *Store) exportLedgerRollupArchive(ctx context.Context, opts LedgerRollupOptions, cutoff, deadline time.Time) (*ledgerRollupArchiveRecord, int, error) {
	var cursor, partialPayout int64
	var partialRequest string
	err := s.reader().QueryRowContext(ctx, `SELECT payout_cursor, partial_payout_id, partial_request_cursor FROM ledger_rollup_state WHERE id = 1`).Scan(&cursor, &partialPayout, &partialRequest)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, 0, err
	}
	var w *verifiedarchive.Writer
	abort := func() { w.Abort() }
	spaceGuard := func() error {
		free, total, err := archiveFilesystemSpaceFunc(opts.ArchiveDir)
		if err != nil {
			return err
		}
		if reason := verifiedarchive.BelowFloor(free, total, opts.ArchiveMinFreeBytes, opts.ArchiveMinFreePercent); reason != "" {
			return fmt.Errorf("%w: %s", errEvidenceArchiveDiskLow, reason)
		}
		return nil
	}
	seen := map[string]bool{}
	selected, kept := 0, 0
	stamp := sqliteTimeText(s.nowUTC())
	var skips [][2]string
	// The stats billing mirror copies live credits by id; a credit it has
	// not copied yet stays hot. A watermark that cannot be read rolls
	// nothing up this run.
	mirrored := int64(-1)
	if f := s.ledgerRollupMirrorWatermark(); f != nil {
		w, err := f(ctx)
		if err != nil {
			return nil, 0, fmt.Errorf("read the stats billing mirror watermark: %w", err)
		}
		mirrored = w
	}
	consider := func(requestID string) error {
		if seen[requestID] {
			return nil
		}
		seen[requestID] = true
		b, reason, err := collectLedgerRollupBundle(ctx, s.reader(), requestID, cutoff)
		if err != nil {
			return err
		}
		if reason == "" && mirrored >= 0 && maxInt64(b.creditIDs) > mirrored {
			reason = "billing_mirror_behind"
		}
		if reason != "" {
			kept++
			skips = append(skips, [2]string{requestID, reason})
			return nil
		}
		if w == nil {
			if w, err = verifiedarchive.NewWriter(opts.ArchiveDir, ledgerRollupNamePrefix, ledgerRollupFormat, s.nowUTC(), sqliteTimeText(cutoff)); err != nil {
				return err
			}
			w.SetSpaceGuard(evidenceArchiveSpaceCheckBytes, spaceGuard)
		}
		if err := w.WriteGroup(requestID, b.creditIDs, b.tables()); err != nil {
			return err
		}
		selected++
		return nil
	}
	// Phase 1: re-check the oldest holds; a request that cleared joins this
	// archive, one that never will leaves the holds table.
	holds, err := s.reader().QueryContext(ctx, `SELECT request_id FROM ledger_rollup_holds ORDER BY held_at_utc, request_id LIMIT ?`, min(ledgerRollupHoldsPerRun, opts.MaxRequestsPerArchive))
	if err != nil {
		return nil, 0, err
	}
	var held []string
	for holds.Next() {
		var r string
		if err := holds.Scan(&r); err != nil {
			holds.Close()
			return nil, 0, err
		}
		held = append(held, r)
	}
	if err := holds.Err(); err != nil {
		holds.Close()
		return nil, 0, err
	}
	if err := holds.Close(); err != nil {
		return nil, 0, err
	}
	for _, requestID := range held {
		if err := consider(requestID); err != nil {
			abort()
			return nil, kept, err
		}
	}
	// Phase 2: walk payouts from the cursor. The cursor only passes payouts
	// that can gain no more credits and are fully walked: consumed and voided
	// ones in an unbroken run from the cursor. A ready payout (settlement may
	// still add credits to it) or a too-recent one is walked again by later
	// runs, and the walk goes on past it to older-window payouts with larger
	// ids.
	state := ledgerRollupWalk{cursor: cursor, partialPayout: partialPayout, partialRequest: partialRequest}
	pos, advance := cursor, true
walk:
	for selected < opts.MaxRequestsPerArchive {
		if err := ctx.Err(); err != nil {
			abort()
			return nil, kept, err
		}
		if !s.nowUTC().Before(deadline) {
			break
		}
		payouts, err := queryArchiveRows(ctx, s.reader(), `
SELECT id, provider_id, window_end_utc, status FROM ledger_payout_ready
 WHERE id > ?
 ORDER BY id
 LIMIT ?`, pos, ledgerRollupPayoutChunk)
		if err != nil {
			abort()
			return nil, kept, err
		}
		if len(payouts) == 0 {
			break
		}
		for _, p := range payouts {
			id, _ := p.int64("id")
			pos = id
			status, _ := p.str("status")
			endText, _ := p.str("window_end_utc")
			end, perr := time.Parse(time.RFC3339Nano, strings.TrimSpace(endText))
			if status == "voided" {
				// A voided payout's credits never roll up; they stay hot.
				if advance {
					state.cursor = id
				}
				continue
			}
			if perr != nil || end.After(cutoff) {
				advance = false
				continue
			}
			after := ""
			if state.partialPayout == id {
				after = state.partialRequest
			}
			limit := opts.MaxRequestsPerArchive - selected
			providerID, _ := p.str("provider_id")
			rows, err := s.reader().QueryContext(ctx, `
SELECT DISTINCT request_id FROM ledger_request_credits
 WHERE provider_id = ? AND ts_utc < ? AND settlement_id = ? AND request_id > ?
 ORDER BY request_id
 LIMIT ?`, providerID, endText, id, after, limit)
			if err != nil {
				abort()
				return nil, kept, err
			}
			var requests []string
			for rows.Next() {
				var r string
				if err := rows.Scan(&r); err != nil {
					rows.Close()
					abort()
					return nil, kept, err
				}
				requests = append(requests, r)
			}
			if err := rows.Err(); err != nil {
				rows.Close()
				abort()
				return nil, kept, err
			}
			if err := rows.Close(); err != nil {
				abort()
				return nil, kept, err
			}
			for _, requestID := range requests {
				if err := consider(requestID); err != nil {
					abort()
					return nil, kept, err
				}
			}
			if len(requests) == limit {
				// The archive is full inside this payout: the next archive
				// continues after its last request.
				state.partialPayout, state.partialRequest = id, requests[len(requests)-1]
				break walk
			}
			if state.partialPayout == id {
				state.partialPayout, state.partialRequest = 0, ""
			}
			if advance && status == "consumed" {
				state.cursor = id
			} else {
				advance = false
			}
		}
	}
	saveSkips := func(e evidenceExecer) error {
		for _, sk := range skips {
			if err := recordLedgerRollupSkip(ctx, e, sk[0], sk[1], stamp); err != nil {
				return err
			}
		}
		return nil
	}
	if w == nil {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return nil, kept, err
		}
		defer func() { _ = tx.Rollback() }()
		if err := saveSkips(tx); err != nil {
			return nil, kept, err
		}
		if state != (ledgerRollupWalk{cursor: cursor, partialPayout: partialPayout, partialRequest: partialRequest}) {
			if err := s.saveLedgerRollupWalk(ctx, tx, state); err != nil {
				return nil, kept, err
			}
		}
		return nil, kept, tx.Commit()
	}
	manifest, _, err := w.Finish()
	if err != nil {
		return nil, kept, err
	}
	countsJSON, err := json.Marshal(manifest.RowCounts)
	if err != nil {
		return nil, kept, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, kept, err
	}
	defer func() { _ = tx.Rollback() }()
	res, err := tx.ExecContext(ctx, `
INSERT INTO ledger_rollup_archives (
    file_name, sha256, size_bytes, request_count, row_counts_json, cutoff_window_end_utc,
    status, created_at_utc, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, 'exported', ?, ?)`,
		manifest.ArchiveFile, manifest.SHA256, manifest.SizeBytes, manifest.RequestCount, string(countsJSON),
		manifest.CutoffWindowEndUTC, manifest.CreatedAtUTC, stamp)
	if err != nil {
		return nil, kept, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, kept, err
	}
	if err := s.saveLedgerRollupWalk(ctx, tx, state); err != nil {
		return nil, kept, err
	}
	if err := saveSkips(tx); err != nil {
		return nil, kept, err
	}
	if err := tx.Commit(); err != nil {
		return nil, kept, err
	}
	return &ledgerRollupArchiveRecord{id: id, fileName: manifest.ArchiveFile, manifest: manifest}, kept, nil
}

// ledgerRollupWalk is the persisted payout walk position.
type ledgerRollupWalk struct {
	cursor         int64
	partialPayout  int64
	partialRequest string
}

// saveLedgerRollupWalk stores the walk position; the payout cursor never
// moves back.
func (s *Store) saveLedgerRollupWalk(ctx context.Context, e evidenceExecer, w ledgerRollupWalk) error {
	_, err := e.ExecContext(ctx, `
INSERT INTO ledger_rollup_state (id, payout_cursor, partial_payout_id, partial_request_cursor, updated_at_utc) VALUES (1, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    payout_cursor = MAX(payout_cursor, excluded.payout_cursor),
    partial_payout_id = excluded.partial_payout_id,
    partial_request_cursor = excluded.partial_request_cursor,
    updated_at_utc = excluded.updated_at_utc`, w.cursor, w.partialPayout, w.partialRequest, sqliteTimeText(s.nowUTC()))
	return err
}

// applyLedgerRollupArchive re-reads the verified archive and rolls its
// requests up in BEGIN IMMEDIATE transactions of BatchSize requests. Each
// request is re-checked inside the transaction and rolled up only when
// every hot detail row equals its archived copy; its aggregates are added
// for exactly the rows deleted, so a request is never counted twice.
func (s *Store) applyLedgerRollupArchive(ctx context.Context, opts LedgerRollupOptions, archiveID int64, verified verifiedarchive.Verified, cutoff, deadline time.Time) (int, int64, error) {
	rolled, credits, batches := 0, int64(0), 0
	var batch []verifiedarchive.Group
	run := func() error {
		if len(batch) == 0 {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if !s.nowUTC().Before(deadline) {
			return errEvidenceRetentionBudgetSpent
		}
		// A SIGHUP that disables the rollup stops it at the next batch.
		if current, ok := s.ledgerRollupOptions(); ok && !current.Enabled {
			return ErrEvidenceRetentionDisabled
		}
		if batches > 0 && opts.BatchPause > 0 {
			timer := time.NewTimer(opts.BatchPause)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
		n, c, err := s.applyLedgerRollupBatch(ctx, archiveID, batch, cutoff)
		if err != nil {
			return err
		}
		rolled += n
		credits += c
		batches++
		batch = nil
		return nil
	}
	err := verifiedarchive.Stream(verified.Path, verified.Manifest, ledgerRollupKnownTable, func(g verifiedarchive.Group) error {
		if want, ok := verified.Digests[g.ID]; !ok || want != g.Digest {
			return fmt.Errorf("%w: request %q changed since verification", verifiedarchive.ErrInvalid, g.ID)
		}
		batch = append(batch, g)
		if len(batch) >= opts.BatchSize {
			return run()
		}
		return nil
	})
	if err != nil {
		return rolled, credits, err
	}
	return rolled, credits, run()
}

func (s *Store) applyLedgerRollupBatch(ctx context.Context, archiveID int64, batch []verifiedarchive.Group, cutoff time.Time) (int, int64, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return 0, 0, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	rolled := 0
	var credits int64
	floorRecorded := false
	stamp := sqliteTimeText(s.nowUTC())
	for _, g := range batch {
		b, reason, err := collectLedgerRollupBundle(ctx, conn, g.ID, cutoff)
		if err != nil {
			return 0, 0, err
		}
		if reason == "" && !ledgerRollupRowsMatch(b, g) {
			reason = ledgerRollupSkipChangedAfterCopy
		}
		if reason != "" {
			// Already rolled up (no credit left), or no longer eligible, or
			// changed since export: the request stays as it is, held for a
			// re-check when the reason can clear.
			if reason == ledgerRollupSkipChangedAfterCopy {
				if err := recordLedgerRollupSkip(ctx, conn, g.ID, "changed_since_export_recheck", stamp); err != nil {
					return 0, 0, err
				}
			} else if err := recordLedgerRollupSkip(ctx, conn, g.ID, reason, stamp); err != nil {
				return 0, 0, err
			}
			continue
		}
		if !floorRecorded {
			// SPEC-022 R-15.9 contract 6: payable totals now include
			// ledger_settled_rollups, which a contract-5 binary does not read.
			if err := recordBillingCompatFloorExec(ctx, conn, billingCompatContractLedgerRollup); err != nil {
				return 0, 0, err
			}
			floorRecorded = true
		}
		operatorByCredit := map[int64]int64{}
		for _, row := range b.rows["ledger_operator_credits"] {
			cid, _ := row.int64("request_credit_id")
			oc, _ := row.int64("operator_credits")
			operatorByCredit[cid] += oc
		}
		for _, c := range b.rows["ledger_request_credits"] {
			id, _ := c.int64("id")
			if _, err := conn.ExecContext(ctx, `
INSERT INTO ledger_settled_rollups (
    settlement_id, provider_id, hour_utc, model, fault_flag, credit_count,
    gross_credits, provider_credits, operator_credits, min_ts_utc, max_ts_utc, max_attestation_class, pool_id
)
SELECT lrc.settlement_id, lrc.provider_id, `+earningsHourKeySQL("lrc.ts_utc")+`, lrc.model, lrc.fault_flag, 1,
       lrc.gross_credits, lrc.provider_credits, ?, lrc.ts_utc, lrc.ts_utc, lrc.attestation_class,
       COALESCE((SELECT a.pool_id FROM settlement_evidence_archived_credits a WHERE a.request_credit_id = lrc.id), '')
  FROM ledger_request_credits lrc WHERE lrc.id = ?
ON CONFLICT(settlement_id, provider_id, hour_utc, model, fault_flag, pool_id) DO UPDATE SET
    credit_count = credit_count + 1,
    gross_credits = gross_credits + excluded.gross_credits,
    provider_credits = provider_credits + excluded.provider_credits,
    operator_credits = operator_credits + excluded.operator_credits,
    min_ts_utc = MIN(min_ts_utc, excluded.min_ts_utc),
    max_ts_utc = MAX(max_ts_utc, excluded.max_ts_utc),
    max_attestation_class = CASE
        WHEN excluded.max_attestation_class IS NULL THEN max_attestation_class
        WHEN max_attestation_class IS NULL THEN excluded.max_attestation_class
        ELSE MAX(max_attestation_class, excluded.max_attestation_class) END`, operatorByCredit[id], id); err != nil {
				return 0, 0, fmt.Errorf("roll up credit %d: %w", id, err)
			}
		}
		ph, args := int64Placeholders(b.creditIDs)
		for _, stmt := range []string{
			`DELETE FROM ledger_operator_credits WHERE request_credit_id IN (` + ph + `)`,
			`DELETE FROM ledger_request_credits WHERE id IN (` + ph + `)`,
			`DELETE FROM settlement_evidence_archived_credits WHERE request_credit_id IN (` + ph + `)`,
		} {
			if _, err := conn.ExecContext(ctx, stmt, args...); err != nil {
				return 0, 0, err
			}
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM ledger_provider_identity_snapshots WHERE request_id = ?`, g.ID); err != nil {
			return 0, 0, err
		}
		if _, err := conn.ExecContext(ctx, `DELETE FROM ledger_rollup_holds WHERE request_id = ?`, g.ID); err != nil {
			return 0, 0, err
		}
		rolled++
		credits += int64(len(b.creditIDs))
	}
	if rolled > 0 {
		if _, err := conn.ExecContext(ctx, `
UPDATE ledger_rollup_archives SET deleted_requests = deleted_requests + ?, updated_at_utc = ? WHERE id = ?`,
			rolled, sqliteTimeText(s.nowUTC()), archiveID); err != nil {
			return 0, 0, err
		}
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return 0, 0, err
	}
	committed = true
	return rolled, credits, nil
}

// ledgerRollupRowsMatch reports whether the request's hot detail rows are
// exactly the archived ones, column for column.
func ledgerRollupRowsMatch(b ledgerRollupBundle, g verifiedarchive.Group) bool {
	for _, table := range ledgerRollupDetailTables {
		live := b.rows[table]
		archived := g.Rows[table]
		if len(live) != len(archived) {
			return false
		}
		converted := make([]archiveRow, len(archived))
		for i, row := range archived {
			converted[i] = row
		}
		if rowsMatchArchive(live, converted) != "" {
			// Tombstones are keyed by request_credit_id, not id.
			if table != "settlement_evidence_archived_credits" || !tombstonesMatch(live, converted) {
				return false
			}
		}
	}
	return true
}

func tombstonesMatch(live, archived []archiveRow) bool {
	byID := map[int64]archiveRow{}
	for _, row := range archived {
		id, _ := row.int64("request_credit_id")
		byID[id] = row
	}
	for _, row := range live {
		id, _ := row.int64("request_credit_id")
		want, ok := byID[id]
		if !ok || !archiveRowsEqual(row, want) {
			return false
		}
	}
	return true
}

// ledgerRollupTotals are summed rollup rows.
type ledgerRollupTotals struct {
	count, gross, provider, operator, faults int64
}

// sumLedgerRollups sums the rollup rows of providerID ("" for every
// provider) with loHour <= hour_utc < hiHour ("" for unbounded).
func sumLedgerRollups(ctx context.Context, q sqlQueryer, providerID, loHour, hiHour string) (ledgerRollupTotals, error) {
	where, args := ledgerRollupWhere(providerID, loHour, hiHour)
	var t ledgerRollupTotals
	err := q.QueryRowContext(ctx, `
SELECT COALESCE(SUM(credit_count), 0), COALESCE(SUM(gross_credits), 0), COALESCE(SUM(provider_credits), 0),
       COALESCE(SUM(operator_credits), 0), COALESCE(SUM(CASE WHEN fault_flag != 'none' THEN credit_count ELSE 0 END), 0)
  FROM ledger_settled_rollups WHERE `+where, args...).Scan(&t.count, &t.gross, &t.provider, &t.operator, &t.faults)
	return t, err
}

func ledgerRollupWhere(providerID, loHour, hiHour string) (string, []any) {
	where := "1=1"
	var args []any
	if providerID != "" {
		where += " AND provider_id = ?"
		args = append(args, providerID)
	}
	if loHour != "" {
		where += " AND hour_utc >= ?"
		args = append(args, loHour)
	}
	if hiHour != "" {
		where += " AND hour_utc < ?"
		args = append(args, hiHour)
	}
	return where, args
}

// addLedgerRollupEarnings adds a provider's rolled-up credits to the figures
// the payable-view fallback computed: the range-scoped total, week, today,
// models and faults, and the lifetime pending sum. Ranges and windows are
// whole hours, so whole rollup hours fall inside or outside them.
func addLedgerRollupEarnings(ctx context.Context, q sqlQueryer, providerID string, win earningsWindows, out *providerEarningsFigures) error {
	lo, hi := "", ""
	if win.hasRange {
		lo, hi = earningsHourKey(win.from), earningsHourKey(win.to)
	}
	where, args := ledgerRollupWhere(providerID, lo, hi)
	rows, err := q.QueryContext(ctx, `
SELECT model, SUM(provider_credits),
       SUM(CASE WHEN hour_utc >= ? THEN provider_credits ELSE 0 END),
       SUM(CASE WHEN hour_utc >= ? THEN provider_credits ELSE 0 END),
       SUM(CASE WHEN fault_flag != 'none' THEN credit_count ELSE 0 END)
  FROM ledger_settled_rollups
 WHERE `+where+`
 GROUP BY model`, append([]any{earningsHourKey(win.week), earningsHourKey(win.today)}, args...)...)
	if err != nil {
		return err
	}
	defer rows.Close()
	models := map[string]bool{}
	for _, m := range out.models {
		models[m] = true
	}
	var rangeTotal int64
	for rows.Next() {
		var model string
		var total, week, today, faults int64
		if err := rows.Scan(&model, &total, &week, &today, &faults); err != nil {
			return err
		}
		rangeTotal += total
		out.week += week
		out.today += today
		out.faults += faults
		if !models[model] {
			models[model] = true
			out.models = append(out.models, model)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	sort.Strings(out.models)
	out.total += rangeTotal
	if !win.hasRange {
		out.pending += rangeTotal
		return nil
	}
	lifetime, err := sumLedgerRollups(ctx, q, providerID, "", "")
	if err != nil {
		return err
	}
	out.pending += lifetime.provider
	return nil
}

// VerifyLedgerRollupArchiveFile re-verifies a rollup archive against its
// sidecar manifest (operator restore procedure).
func VerifyLedgerRollupArchiveFile(archivePath string) (EvidenceArchiveManifest, error) {
	manifest, err := verifiedarchive.ReadManifest(archivePath)
	if err != nil {
		return EvidenceArchiveManifest{}, err
	}
	if manifest.Format != ledgerRollupFormat {
		return EvidenceArchiveManifest{}, fmt.Errorf("%w: manifest format %q", verifiedarchive.ErrInvalid, manifest.Format)
	}
	if _, err := verifiedarchive.Verify(archivePath, manifest, ledgerRollupKnownTable); err != nil {
		return EvidenceArchiveManifest{}, err
	}
	return manifest, nil
}
