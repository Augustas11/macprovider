package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// SPEC-022 R-15 (#1793): settled-evidence retention. Per-attempt settlement
// evidence of requests whose credits all settled at least
// min_settlement_cycles completed settlement windows ago is exported to a
// local archive, verified by re-reading it (checksum, size, row counts, and
// row-for-row equality with the hot rows), optionally confirmed off host,
// and then deleted from the hot tables in short batches. The money record (ledger credits, operator credits,
// payouts, settlement windows, quarantine resolutions) is never deleted.

// evidenceRetentionTables are deleted in this order: the outbox references
// verdicts and compute-integrity captures reference route snapshots.
var evidenceRetentionTables = []string{
	"settlement_receipt_audit_outbox",
	"settlement_compute_integrity_captures",
	"settlement_attempt_outputs",
	"settlement_receipt_verdicts",
	"settlement_route_snapshots",
}

// evidenceRetentionJournalTable is the route-snapshot journal, in its own
// database file. Its rows are archived losslessly with the request and
// deleted only after the main-database rows they mirror.
const evidenceRetentionJournalTable = "settlement_route_snapshot_journal"

// evidenceReferenceTables are copied into the archive so a settled credit
// can be rederived from the archive alone. They are never deleted.
var evidenceReferenceTables = []string{
	"ledger_request_credits",
	"ledger_operator_credits",
	"ledger_payout_ready",
	"ledger_provider_identity_snapshots",
	"ledger_config_snapshots",
}

const (
	evidenceArchiveStatusExported        = "exported"
	evidenceArchiveStatusOffhostVerified = "offhost_verified"
	evidenceArchiveStatusDeleted         = "deleted"
	evidenceArchiveStatusFailed          = "failed"

	// Report statuses.
	EvidenceRetentionStatusDryRun            = "dry_run"
	EvidenceRetentionStatusNothingEligible   = "nothing_eligible"
	EvidenceRetentionStatusOffhostUnverified = "refused_offhost_unverified"
	EvidenceRetentionStatusArchiveInvalid    = "refused_archive_invalid"
	EvidenceRetentionStatusArchiveDiskLow    = "refused_archive_disk_low"
	EvidenceRetentionStatusDeleted           = "deleted"

	evidenceRetentionScanChunk = 2000
	evidenceRetentionMinBatch  = 1
	// evidenceRetentionBatchBytes bounds the archived payload one delete
	// batch holds in memory, whatever batch_size says. A single request
	// larger than it is still processed, alone.
	evidenceRetentionBatchBytes = 16 << 20
)

// Ineligibility reasons (SPEC-022 R-15.2). A request with any of them stays
// hot in full.
const (
	retentionSkipNoCredit           = "no_ledger_credit"
	retentionSkipUnsettled          = "credit_unsettled"
	retentionSkipQuarantined        = "credit_quarantined"
	retentionSkipResolution         = "credit_quarantine_resolution"
	retentionSkipNotPayable         = "credit_not_payable"
	retentionSkipPayoutMissing      = "payout_missing"
	retentionSkipPayoutVoided       = "payout_voided"
	retentionSkipWindowTooRecent    = "settlement_window_too_recent"
	retentionSkipInsideReconcile    = "inside_reconcile_horizon"
	retentionSkipVerdictOpen        = "verdict_open"
	retentionSkipVerdictQuarantined = "verdict_quarantined"
	retentionSkipOutboxUndelivered  = "audit_outbox_undelivered"
	retentionSkipOutboxPoisoned     = "audit_outbox_poisoned"
	retentionSkipOutputJournal      = "output_journal_open"
	retentionSkipRouteJournal       = "route_snapshot_journal_unmirrored"
	retentionSkipFirstVerified      = "provider_first_verified_verdict"
	retentionSkipAlreadyArchived    = "already_archived"
	retentionSkipHotRowNotArchived  = "hot_row_not_in_archive"
	retentionSkipHotRowChanged      = "hot_row_changed_since_archive"
	retentionSkipRelayBlind         = "relay_blind_attempt"
	retentionSkipScopeUnresolved    = "settlement_scope_unresolved"
	retentionSkipFinalityOpen       = "settlement_finality_open"
	retentionSkipPoolProvenUnrolled = "pool_proven_rollup_pending"
)

var (
	ErrEvidenceRetentionBusy     = errors.New("settlement evidence retention is already running")
	ErrEvidenceRetentionDisabled = errors.New("settlement evidence retention was disabled during the run")
)

// EvidenceArchiveOffhostVerifier confirms that an archive with this SHA-256
// is present at an off-host destination. It is optional: a nil verifier
// skips this extra check; a configured one that fails refuses deletion.
type EvidenceArchiveOffhostVerifier func(ctx context.Context, archivePath, sha256Hex string) error

// CommandOffhostVerifier runs argv + [archivePath, sha256Hex] without a
// shell; exit status 0 confirms the off-host copy.
func CommandOffhostVerifier(argv []string, timeout time.Duration) EvidenceArchiveOffhostVerifier {
	if len(argv) == 0 {
		return nil
	}
	args := append([]string(nil), argv...)
	return func(ctx context.Context, archivePath, sha256Hex string) error {
		runCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		cmd := exec.CommandContext(runCtx, args[0], append(args[1:], archivePath, sha256Hex)...)
		cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
		out, err := cmd.CombinedOutput()
		if err != nil {
			detail := strings.TrimSpace(string(out))
			if len(detail) > 500 {
				detail = detail[:500]
			}
			return fmt.Errorf("off-host verification command failed: %v: %s", err, detail)
		}
		return nil
	}
}

// EvidenceRetentionOptions are the effective SPEC-022 R-15 settings.
type EvidenceRetentionOptions struct {
	Enabled                   bool
	ArchiveDir                string
	MinSettlementCycles       int
	CadenceDays               int
	ReconcileHorizon          time.Duration
	BatchSize                 int
	BatchPause                time.Duration
	MaxRequestsPerRun         int
	MaxScanRowsPerRun         int
	IncrementalVacuumPages    int
	IncrementalVacuumMaxSteps int
	// ArchiveMinFreeBytes and ArchiveMinFreePercent are the archive
	// filesystem's free-space floor; zero disables that bound.
	ArchiveMinFreeBytes   int64
	ArchiveMinFreePercent int
	OffhostVerifier       EvidenceArchiveOffhostVerifier
}

// EvidenceRetentionOptionsFromConfig derives options from coordinator
// config. The reconcile horizon keeps retention outside every window the
// nightly reconcile or startup scan may re-read, plus a day of margin.
func EvidenceRetentionOptionsFromConfig(rc config.BillingRetentionConfig, sc config.SettlementConfig) EvidenceRetentionOptions {
	horizon := time.Duration(sc.NightlyReconcileWindowDays) * 24 * time.Hour
	if startup := time.Duration(sc.StartupReconcileWindowHours) * time.Hour; startup > horizon {
		horizon = startup
	}
	horizon += time.Duration(sc.RecoveryGraceSeconds)*time.Second + 24*time.Hour
	return EvidenceRetentionOptions{
		Enabled:                   rc.Enabled,
		ArchiveDir:                rc.ArchiveDir,
		MinSettlementCycles:       rc.MinSettlementCycles,
		CadenceDays:               sc.CadenceDays,
		ReconcileHorizon:          horizon,
		BatchSize:                 rc.BatchSize,
		BatchPause:                time.Duration(rc.BatchPauseMS) * time.Millisecond,
		MaxRequestsPerRun:         rc.MaxRequestsPerRun,
		MaxScanRowsPerRun:         rc.MaxScanRowsPerRun,
		IncrementalVacuumPages:    rc.IncrementalVacuumPages,
		IncrementalVacuumMaxSteps: rc.IncrementalVacuumMaxSteps,
		ArchiveMinFreeBytes:       rc.ArchiveMinFreeBytes,
		ArchiveMinFreePercent:     rc.ArchiveMinFreePercent,
		OffhostVerifier:           CommandOffhostVerifier(rc.OffhostVerifyCommand, time.Duration(rc.OffhostVerifyTimeoutSeconds)*time.Second),
	}
}

func (o EvidenceRetentionOptions) normalized() (EvidenceRetentionOptions, error) {
	if o.MinSettlementCycles < 2 {
		return o, fmt.Errorf("min_settlement_cycles must be >= 2")
	}
	if o.CadenceDays <= 0 {
		return o, fmt.Errorf("settlement cadence_days must be positive")
	}
	if o.ReconcileHorizon <= 0 {
		return o, fmt.Errorf("reconcile horizon must be positive")
	}
	if o.BatchSize < evidenceRetentionMinBatch {
		o.BatchSize = evidenceRetentionMinBatch
	}
	if o.MaxRequestsPerRun < 1 {
		o.MaxRequestsPerRun = 1
	}
	if o.MaxScanRowsPerRun < 1 {
		o.MaxScanRowsPerRun = 1
	}
	return o, nil
}

// EvidenceRetentionTableStats is per-table work. PayloadBytes is the summed
// length() of every column: a payload estimate, not page usage.
type EvidenceRetentionTableStats struct {
	Rows         int64 `json:"rows"`
	PayloadBytes int64 `json:"payload_bytes"`
	DeletedRows  int64 `json:"deleted_rows,omitempty"`
}

// EvidenceRetentionReport is what a dry run or run reports.
type EvidenceRetentionReport struct {
	Status             string                                 `json:"status"`
	DryRun             bool                                   `json:"dry_run"`
	StartedAtUTC       string                                 `json:"started_at_utc"`
	FinishedAtUTC      string                                 `json:"finished_at_utc,omitempty"`
	CutoffWindowEndUTC string                                 `json:"cutoff_window_end_utc,omitempty"`
	CreditAgeCutoffUTC string                                 `json:"credit_age_cutoff_utc,omitempty"`
	ScanFromCreditID   int64                                  `json:"scan_from_credit_id"`
	ScanToCreditID     int64                                  `json:"scan_to_credit_id"`
	ScannedCredits     int64                                  `json:"scanned_credits"`
	ScanWrapped        bool                                   `json:"scan_wrapped"`
	EligibleRequests   int                                    `json:"eligible_requests"`
	SkippedRequests    map[string]int                         `json:"skipped_requests"`
	Tables             map[string]EvidenceRetentionTableStats `json:"tables"`
	ArchiveID          int64                                  `json:"archive_id,omitempty"`
	ArchiveFile        string                                 `json:"archive_file,omitempty"`
	ArchiveSHA256      string                                 `json:"archive_sha256,omitempty"`
	ArchiveBytes       int64                                  `json:"archive_bytes,omitempty"`
	// ArchiveFreeBytes is the free space of the archive filesystem when the
	// run started; ArchiveDiskBytes is that filesystem's size.
	ArchiveFreeBytes int64 `json:"archive_free_bytes,omitempty"`
	ArchiveDiskBytes int64 `json:"archive_disk_bytes,omitempty"`
	ResumedArchive   bool  `json:"resumed_archive,omitempty"`
	DeletedRequests  int   `json:"deleted_requests"`
	// DeleteBatches counts the short delete transactions of the run.
	DeleteBatches           int   `json:"delete_batches"`
	RouteJournalDeletedRows int64 `json:"route_snapshot_journal_deleted_rows"`
	// RouteJournalKeptRows are archived journal rows left hot because the
	// live row no longer equals its archived copy.
	RouteJournalKeptRows int64                           `json:"route_snapshot_journal_kept_rows,omitempty"`
	Vacuum               []EvidenceRetentionVacuumReport `json:"vacuum,omitempty"`
	Error                string                          `json:"error,omitempty"`
}

// EvidenceRetentionVacuumReport is the incremental-vacuum outcome of one
// database file. A database not in INCREMENTAL mode needs the operator's
// one-time conversion (runbook); retention never runs a full VACUUM.
type EvidenceRetentionVacuumReport struct {
	Database        string `json:"database"`
	AutoVacuumMode  string `json:"auto_vacuum_mode"`
	FreelistBefore  int64  `json:"freelist_pages_before"`
	FreelistAfter   int64  `json:"freelist_pages_after"`
	Steps           int    `json:"steps"`
	ConversionNeeds bool   `json:"needs_one_time_conversion"`
}

type evidenceRetentionRuntime struct {
	mu         sync.Mutex
	settings   *EvidenceRetentionOptions
	lastReport *EvidenceRetentionReport
}

// SetEvidenceRetentionOptions installs the effective retention settings for
// the nightly job and the admin route.
func (s *Store) SetEvidenceRetentionOptions(opts EvidenceRetentionOptions) {
	if s == nil {
		return
	}
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	copied := opts
	s.evidenceRetention.settings = &copied
}

func (s *Store) evidenceRetentionOptions() (EvidenceRetentionOptions, bool) {
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	if s.evidenceRetention.settings == nil {
		return EvidenceRetentionOptions{}, false
	}
	return *s.evidenceRetention.settings, true
}

func (s *Store) setLastEvidenceRetentionReport(r EvidenceRetentionReport) {
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	s.evidenceRetention.lastReport = &r
}

// LastEvidenceRetentionReport is the report of the most recent run.
func (s *Store) LastEvidenceRetentionReport() (EvidenceRetentionReport, bool) {
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	if s.evidenceRetention.lastReport == nil {
		return EvidenceRetentionReport{}, false
	}
	return *s.evidenceRetention.lastReport, true
}

func (s *Store) ensureSettlementEvidenceRetentionTables(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS settlement_evidence_archives (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL UNIQUE,
    sha256 TEXT NOT NULL CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    size_bytes INTEGER NOT NULL CHECK(size_bytes > 0),
    request_count INTEGER NOT NULL CHECK(request_count > 0),
    row_counts_json TEXT NOT NULL,
    cutoff_window_end_utc TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('exported','offhost_verified','deleted','failed')),
    deleted_requests INTEGER NOT NULL DEFAULT 0 CHECK(deleted_requests >= 0),
    last_error TEXT NOT NULL DEFAULT '',
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sea_status ON settlement_evidence_archives(status, id);
CREATE TABLE IF NOT EXISTS settlement_evidence_archived_credits (
    request_credit_id INTEGER PRIMARY KEY,
    request_id TEXT NOT NULL,
    archive_id INTEGER NOT NULL REFERENCES settlement_evidence_archives(id),
    spec022_verified INTEGER NOT NULL CHECK(spec022_verified IN (0,1)),
    archived_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_seac_request ON settlement_evidence_archived_credits(request_id);
CREATE TRIGGER IF NOT EXISTS trg_seac_immutable
BEFORE UPDATE ON settlement_evidence_archived_credits
BEGIN
    SELECT RAISE(ABORT, 'settlement evidence archived credit is immutable');
END;
CREATE TRIGGER IF NOT EXISTS trg_seac_no_delete
BEFORE DELETE ON settlement_evidence_archived_credits
BEGIN
    SELECT RAISE(ABORT, 'settlement evidence archived credit is permanent');
END;
CREATE TABLE IF NOT EXISTS settlement_evidence_archived_verdict_counts (
    provider_id TEXT NOT NULL,
    settlement_outcome TEXT NOT NULL,
    receipt_result TEXT NOT NULL,
    verdict_count INTEGER NOT NULL CHECK(verdict_count >= 0),
    PRIMARY KEY(provider_id, settlement_outcome, receipt_result)
);
CREATE TABLE IF NOT EXISTS settlement_evidence_archived_finality (
    account_scope_hash TEXT NOT NULL,
    request_id TEXT NOT NULL,
    archive_id INTEGER NOT NULL REFERENCES settlement_evidence_archives(id),
    finality_json TEXT NOT NULL,
    archived_at_utc TEXT NOT NULL,
    PRIMARY KEY(account_scope_hash, request_id)
);
CREATE TRIGGER IF NOT EXISTS trg_seaf_immutable
BEFORE UPDATE ON settlement_evidence_archived_finality
BEGIN
    SELECT RAISE(ABORT, 'settlement evidence archived finality is immutable');
END;
CREATE TRIGGER IF NOT EXISTS trg_seaf_no_delete
BEFORE DELETE ON settlement_evidence_archived_finality
BEGIN
    SELECT RAISE(ABORT, 'settlement evidence archived finality is permanent');
END;
CREATE TABLE IF NOT EXISTS settlement_evidence_retention_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    scan_cursor_credit_id INTEGER NOT NULL DEFAULT 0 CHECK(scan_cursor_credit_id >= 0),
    updated_at_utc TEXT NOT NULL
);`)
	return err
}

type evidenceQueryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func queryArchiveRows(ctx context.Context, q evidenceQueryer, query string, args ...any) ([]archiveRow, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var out []archiveRow
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(archiveRow, len(cols))
		for i, c := range cols {
			row[c] = normalizeArchiveValue(vals[i])
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

func int64Placeholders(ids []int64) (string, []any) {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return sqlPlaceholders(len(ids)), args
}

// retentionCredit is the typed view of one ledger credit of a request.
type retentionCredit struct {
	id           int64
	settled      bool
	quarantined  bool
	settlementID *int64
	tsUTC        time.Time
	payable      bool
	resolutions  int64
	scopeHash    string
	attemptN     int64
	providerID   string
}

// requestEvidenceBundle is everything retention knows about one request:
// rows to archive and the facts the R-15.2 predicate reads.
type requestEvidenceBundle struct {
	requestID string
	credits   []retentionCredit
	payouts   map[int64]archiveRow
	reference map[string][]archiveRow
	evidence  map[string][]archiveRow
	scopes    []string
	// outputJournal holds (materialized, poisoned) facts.
	outputJournal []archiveRow
	// routeJournal holds the journal rows from the route-snapshot journal DB.
	routeJournal []archiveRow
	// poolProvenUnrolled is true when a route snapshot of the request that the
	// SPEC-047-R012 pool-proven rollup counts is not yet held there with a
	// final state.
	poolProvenUnrolled bool
}

// collectRequestEvidence reads one request through q (the reader for export,
// the delete transaction for the re-check).
func collectRequestEvidence(ctx context.Context, q evidenceQueryer, requestID string) (requestEvidenceBundle, error) {
	b := requestEvidenceBundle{
		requestID: requestID,
		payouts:   map[int64]archiveRow{},
		reference: map[string][]archiveRow{},
		evidence:  map[string][]archiveRow{},
	}
	credits, err := queryArchiveRows(ctx, q, `SELECT * FROM ledger_request_credits WHERE request_id = ? ORDER BY id`, requestID)
	if err != nil {
		return b, err
	}
	b.reference["ledger_request_credits"] = credits
	if len(credits) == 0 {
		return b, nil
	}
	payable := map[int64]bool{}
	rows, err := q.QueryContext(ctx, `SELECT id FROM spec022_payable_request_credits WHERE request_id = ?`, requestID)
	if err != nil {
		return b, err
	}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return b, err
		}
		payable[id] = true
	}
	if err := rows.Close(); err != nil {
		return b, err
	}
	creditIDs := make([]int64, 0, len(credits))
	var settlementIDs []int64
	scopeHashes := map[string]bool{}
	for _, c := range credits {
		id, _ := c.int64("id")
		creditIDs = append(creditIDs, id)
		settled, _ := c.int64("settled")
		quarantined, _ := c.int64("quarantined")
		ts, _ := c.str("ts_utc")
		parsed, _ := time.Parse(time.RFC3339Nano, strings.TrimSpace(ts))
		attempt, _ := c.int64("attempt_n")
		providerID, _ := c.str("provider_id")
		rc := retentionCredit{id: id, settled: settled == 1, quarantined: quarantined == 1, tsUTC: parsed, payable: payable[id], attemptN: attempt, providerID: providerID}
		if sid := c.nullInt("settlement_id"); sid != nil {
			rc.settlementID = sid
			settlementIDs = append(settlementIDs, *sid)
		}
		if h, ok := c.str("settlement_account_scope_hash"); ok && h != "" {
			rc.scopeHash = h
			scopeHashes[h] = true
		}
		b.credits = append(b.credits, rc)
	}
	ph, args := int64Placeholders(creditIDs)
	resolutions := map[int64]int64{}
	rows, err = q.QueryContext(ctx, `SELECT request_credit_id, COUNT(*) FROM ledger_quarantine_resolutions WHERE request_credit_id IN (`+ph+`) GROUP BY request_credit_id`, args...)
	if err != nil {
		return b, err
	}
	for rows.Next() {
		var id, n int64
		if err := rows.Scan(&id, &n); err != nil {
			rows.Close()
			return b, err
		}
		resolutions[id] = n
	}
	if err := rows.Close(); err != nil {
		return b, err
	}
	for i := range b.credits {
		b.credits[i].resolutions = resolutions[b.credits[i].id]
	}
	if b.reference["ledger_operator_credits"], err = queryArchiveRows(ctx, q, `SELECT * FROM ledger_operator_credits WHERE request_credit_id IN (`+ph+`) ORDER BY id`, args...); err != nil {
		return b, err
	}
	if len(settlementIDs) > 0 {
		sph, sargs := int64Placeholders(settlementIDs)
		payouts, err := queryArchiveRows(ctx, q, `SELECT * FROM ledger_payout_ready WHERE id IN (`+sph+`) ORDER BY id`, sargs...)
		if err != nil {
			return b, err
		}
		b.reference["ledger_payout_ready"] = payouts
		for _, p := range payouts {
			id, _ := p.int64("id")
			b.payouts[id] = p
		}
	}
	identities, err := queryArchiveRows(ctx, q, `SELECT * FROM ledger_provider_identity_snapshots WHERE request_id = ? ORDER BY id`, requestID)
	if err != nil {
		return b, err
	}
	b.reference["ledger_provider_identity_snapshots"] = identities
	var configIDs []int64
	seenConfig := map[int64]bool{}
	for _, row := range identities {
		if id, ok := row.int64("config_snapshot_id"); ok && !seenConfig[id] {
			seenConfig[id] = true
			configIDs = append(configIDs, id)
		}
	}
	if len(configIDs) > 0 {
		cph, cargs := int64Placeholders(configIDs)
		if b.reference["ledger_config_snapshots"], err = queryArchiveRows(ctx, q, `SELECT * FROM ledger_config_snapshots WHERE id IN (`+cph+`) ORDER BY id`, cargs...); err != nil {
			return b, err
		}
	}
	snapshots, err := queryArchiveRows(ctx, q, `SELECT * FROM settlement_route_snapshots WHERE request_id = ? ORDER BY id`, requestID)
	if err != nil {
		return b, err
	}
	b.evidence["settlement_route_snapshots"] = snapshots
	if b.poolProvenUnrolled, err = poolProvenRollupPending(ctx, q, snapshots); err != nil {
		return b, err
	}
	seenScope := map[string]bool{}
	for _, row := range snapshots {
		if scope, ok := row.str("account_scope"); ok && !seenScope[scope] {
			seenScope[scope] = true
			b.scopes = append(b.scopes, scope)
			scopeHashes[SettlementAccountScopeHash(scope)] = true
		}
	}
	var verdictIDs []int64
	for hash := range scopeHashes {
		verdicts, err := queryArchiveRows(ctx, q, `SELECT * FROM settlement_receipt_verdicts WHERE account_scope_hash = ? AND request_id = ? ORDER BY id`, hash, requestID)
		if err != nil {
			return b, err
		}
		for _, v := range verdicts {
			id, _ := v.int64("id")
			verdictIDs = append(verdictIDs, id)
		}
		b.evidence["settlement_receipt_verdicts"] = append(b.evidence["settlement_receipt_verdicts"], verdicts...)
	}
	if len(verdictIDs) > 0 {
		vph, vargs := int64Placeholders(verdictIDs)
		if b.evidence["settlement_receipt_audit_outbox"], err = queryArchiveRows(ctx, q, `SELECT * FROM settlement_receipt_audit_outbox WHERE settlement_receipt_verdict_id IN (`+vph+`) ORDER BY id`, vargs...); err != nil {
			return b, err
		}
	}
	for _, scope := range b.scopes {
		outputs, err := queryArchiveRows(ctx, q, `SELECT * FROM settlement_attempt_outputs WHERE account_scope = ? AND request_id = ? ORDER BY id`, scope, requestID)
		if err != nil {
			return b, err
		}
		b.evidence["settlement_attempt_outputs"] = append(b.evidence["settlement_attempt_outputs"], outputs...)
		captures, err := queryArchiveRows(ctx, q, `SELECT * FROM settlement_compute_integrity_captures WHERE account_scope = ? AND request_id = ? ORDER BY id`, scope, requestID)
		if err != nil {
			return b, err
		}
		b.evidence["settlement_compute_integrity_captures"] = append(b.evidence["settlement_compute_integrity_captures"], captures...)
		journal, err := queryArchiveRows(ctx, q, `SELECT id, materialized_at_utc, poisoned_at_utc FROM settlement_attempt_output_journal WHERE account_scope = ? AND request_id = ?`, scope, requestID)
		if err != nil {
			return b, err
		}
		b.outputJournal = append(b.outputJournal, journal...)
	}
	return b, nil
}

// poolProvenRollupPending reports whether a route snapshot of the request
// that the SPEC-047-R012 pool-proven rollup captures (poolProvenSnapshotSQL)
// has no rollup row with a recorded finality yet. Retention keeps such a
// request hot until the rollup holds the attempt's final state; the
// rollup's delete triggers then freeze it as the rows leave.
func poolProvenRollupPending(ctx context.Context, q evidenceQueryer, snapshots []archiveRow) (bool, error) {
	pooled := false
	for _, row := range snapshots {
		if pool, ok := row.str("pool_id"); ok && strings.TrimSpace(pool) != "" {
			pooled = true
			break
		}
	}
	if !pooled {
		return false, nil
	}
	requestID, _ := snapshots[0].str("request_id")
	var pending int
	err := q.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM settlement_route_snapshots srs
 WHERE srs.request_id = ?
   AND `+poolProvenSnapshotSQL("srs")+`
   AND NOT EXISTS (
       SELECT 1 FROM pool_proven_rollup_attempts a
        WHERE a.route_snapshot_id = srs.id
          AND a.finality_at_utc IS NOT NULL)`, requestID).Scan(&pending)
	return pending > 0, err
}

// collectRouteJournal reads the request's rows from the separate
// route-snapshot journal database (nil handle: no journal configured).
func collectRouteJournal(ctx context.Context, journalDB *sql.DB, b *requestEvidenceBundle) error {
	b.routeJournal = nil
	if journalDB == nil {
		return nil
	}
	for _, scope := range b.scopes {
		// Every column: the rows are archived losslessly (R-15.3).
		rows, err := queryArchiveRows(ctx, journalDB, `
SELECT * FROM settlement_route_snapshot_journal
 WHERE account_scope = ? AND request_id = ?
 ORDER BY id`, scope, b.requestID)
		if err != nil {
			return err
		}
		b.routeJournal = append(b.routeJournal, rows...)
	}
	return nil
}

// evidenceRetentionCutoffs are the R-15.2 finality points of one run.
type evidenceRetentionCutoffs struct {
	windowEnd    time.Time
	windowEndSet bool
	creditBefore time.Time
}

// evaluateRetentionEligibility is the SPEC-022 R-15.2 predicate over one
// collected request. firstVerified maps provider_id to that provider's
// earliest closed, valid, verified verdict id.
func evaluateRetentionEligibility(b requestEvidenceBundle, cut evidenceRetentionCutoffs, firstVerified map[string]int64, checkRouteJournal bool) (bool, string) {
	if len(b.credits) == 0 {
		return false, retentionSkipNoCredit
	}
	if !cut.windowEndSet {
		return false, retentionSkipWindowTooRecent
	}
	for _, c := range b.credits {
		switch {
		case !c.settled || c.settlementID == nil:
			return false, retentionSkipUnsettled
		case c.quarantined:
			return false, retentionSkipQuarantined
		case c.resolutions > 0:
			return false, retentionSkipResolution
		case !c.payable:
			return false, retentionSkipNotPayable
		case c.tsUTC.IsZero() || !c.tsUTC.Before(cut.creditBefore):
			return false, retentionSkipInsideReconcile
		}
		payout, ok := b.payouts[*c.settlementID]
		if !ok {
			return false, retentionSkipPayoutMissing
		}
		status, _ := payout.str("status")
		if status != "ready" && status != "consumed" {
			return false, retentionSkipPayoutVoided
		}
		endText, _ := payout.str("window_end_utc")
		end, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(endText))
		if err != nil || end.After(cut.windowEnd) {
			return false, retentionSkipWindowTooRecent
		}
	}
	// The gateway's relay-blind recovery reads R-14 coverage from the route
	// snapshot itself, so a relay-blind request stays hot. Every other
	// request's finality is frozen at deletion under its snapshot scope
	// (R-15.6), which needs every scope the request settles under.
	if b.poolProvenUnrolled {
		return false, retentionSkipPoolProvenUnrolled
	}
	snapshotScopes := map[string]bool{}
	for _, srs := range b.evidence["settlement_route_snapshots"] {
		entrypoint, _ := srs.str("paid_entrypoint")
		basis, _ := srs.str("prompt_hash_basis")
		if entrypoint == PaidEntrypointRelayBlindChat || basis == PromptHashBasisRelayBlindEnvelopeV1 {
			return false, retentionSkipRelayBlind
		}
		if scope, ok := srs.str("account_scope"); ok {
			snapshotScopes[SettlementAccountScopeHash(scope)] = true
		}
	}
	for _, c := range b.credits {
		if c.scopeHash != "" && !snapshotScopes[c.scopeHash] {
			return false, retentionSkipScopeUnresolved
		}
	}
	for _, v := range b.evidence["settlement_receipt_verdicts"] {
		if outcome, _ := v.str("settlement_outcome"); outcome == SettlementOutcomeRelayBlindSettled {
			return false, retentionSkipRelayBlind
		}
		if h, ok := v.str("account_scope_hash"); ok && !snapshotScopes[h] {
			return false, retentionSkipScopeUnresolved
		}
	}
	for _, v := range b.evidence["settlement_receipt_verdicts"] {
		closed, _ := v.int64("closed")
		outcome, _ := v.str("settlement_outcome")
		if closed != 1 || outcome == SettlementOutcomePending {
			return false, retentionSkipVerdictOpen
		}
		if outcome == SettlementOutcomeQuarantined {
			return false, retentionSkipVerdictQuarantined
		}
		id, _ := v.int64("id")
		providerID, _ := v.str("provider_id")
		if first, ok := firstVerified[providerID]; ok && first == id {
			return false, retentionSkipFirstVerified
		}
	}
	for _, o := range b.evidence["settlement_receipt_audit_outbox"] {
		if !o.isNull("poisoned_at_utc") {
			return false, retentionSkipOutboxPoisoned
		}
		if o.isNull("drained_at_utc") {
			return false, retentionSkipOutboxUndelivered
		}
	}
	for _, j := range b.outputJournal {
		if j.isNull("materialized_at_utc") || !j.isNull("poisoned_at_utc") {
			return false, retentionSkipOutputJournal
		}
	}
	if checkRouteJournal {
		return evaluateRouteJournalOnly(b)
	}
	return true, ""
}

func routeJournalKey(row archiveRow) string {
	scope, _ := row.str("account_scope")
	req, _ := row.str("request_id")
	attempt, _ := row.int64("attempt_n")
	provider, _ := row.str("provider_id")
	return fmt.Sprintf("%s\x00%s\x00%d\x00%s", scope, req, attempt, provider)
}

// providerFirstVerifiedVerdicts caches each provider's earliest closed,
// valid, verified verdict: the referral serving evidence stays hot.
type providerFirstVerifiedVerdicts struct {
	q     evidenceQueryer
	cache map[string]int64
}

func (p *providerFirstVerifiedVerdicts) forBundle(ctx context.Context, b requestEvidenceBundle) (map[string]int64, error) {
	out := map[string]int64{}
	for _, v := range b.evidence["settlement_receipt_verdicts"] {
		providerID, _ := v.str("provider_id")
		if _, done := out[providerID]; done {
			continue
		}
		if id, ok := p.cache[providerID]; ok {
			out[providerID] = id
			continue
		}
		rows, err := p.q.QueryContext(ctx, `
SELECT id FROM settlement_receipt_verdicts
 WHERE provider_id = ?
   AND closed = 1
   AND +settlement_outcome = 'verified'
   AND receipt_result = 'valid'
 ORDER BY received_at_unix_ms, id
 LIMIT 1`, providerID)
		if err != nil {
			return nil, err
		}
		id := int64(-1)
		if rows.Next() {
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
		}
		if err := rows.Close(); err != nil {
			return nil, err
		}
		p.cache[providerID] = id
		out[providerID] = id
	}
	return out, nil
}

// evidenceRetentionCutoffsAt computes the settlement-window cutoff: the end
// of the window that has at least minCycles completed windows after it.
func (s *Store) evidenceRetentionCutoffsAt(ctx context.Context, opts EvidenceRetentionOptions, now time.Time) (evidenceRetentionCutoffs, error) {
	cut := evidenceRetentionCutoffs{creditBefore: now.Add(-opts.ReconcileHorizon)}
	var endText string
	err := s.reader().QueryRowContext(ctx, `
SELECT window_end_utc FROM ledger_settlement_windows
 WHERE cadence_days = ?
 ORDER BY window_end_utc DESC
 LIMIT 1 OFFSET ?`, opts.CadenceDays, opts.MinSettlementCycles).Scan(&endText)
	if errors.Is(err, sql.ErrNoRows) {
		return cut, nil
	}
	if err != nil {
		return cut, err
	}
	end, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(endText))
	if err != nil {
		return cut, fmt.Errorf("parse settlement window end: %w", err)
	}
	cut.windowEnd, cut.windowEndSet = end.UTC(), true
	return cut, nil
}

// selectRetentionCandidates walks ledger credits by primary key from the
// persisted cursor, bounded by MaxScanRowsPerRun, and hands each eligible
// request bundle (at most MaxRequestsPerRun) to emit as soon as it is
// evaluated. Bundles are never accumulated, so memory holds one request's
// evidence at a time. It returns the number emitted and the next cursor.
func (s *Store) selectRetentionCandidates(ctx context.Context, opts EvidenceRetentionOptions, cut evidenceRetentionCutoffs, report *EvidenceRetentionReport, emit func(requestEvidenceBundle) error) (int, int64, error) {
	var cursor int64
	err := s.reader().QueryRowContext(ctx, `SELECT scan_cursor_credit_id FROM settlement_evidence_retention_state WHERE id = 1`).Scan(&cursor)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, 0, err
	}
	report.ScanFromCreditID = cursor
	first := &providerFirstVerifiedVerdicts{q: s.reader(), cache: map[string]int64{}}
	journalDB := s.routeSnapshotJournalDB.Load()
	selected := 0
	seen := map[string]bool{}
	next := cursor
	wrapped := false
	for report.ScannedCredits < int64(opts.MaxScanRowsPerRun) && selected < opts.MaxRequestsPerRun {
		if err := ctx.Err(); err != nil {
			return 0, 0, err
		}
		limit := evidenceRetentionScanChunk
		if remaining := int64(opts.MaxScanRowsPerRun) - report.ScannedCredits; remaining < int64(limit) {
			limit = int(remaining)
		}
		rows, err := s.reader().QueryContext(ctx, `
SELECT lrc.id, lrc.request_id, lrc.settled, lrc.ts_utc,
       EXISTS (SELECT 1 FROM settlement_evidence_archived_credits a WHERE a.request_credit_id = lrc.id)
  FROM ledger_request_credits lrc
 WHERE lrc.id > ?
 ORDER BY lrc.id
 LIMIT ?`, next, limit)
		if err != nil {
			return 0, 0, err
		}
		type candidate struct {
			requestID string
			creditID  int64
		}
		var candidates []candidate
		n := 0
		for rows.Next() {
			var id, settled int64
			var requestID, ts string
			var archived bool
			if err := rows.Scan(&id, &requestID, &settled, &ts, &archived); err != nil {
				rows.Close()
				return 0, 0, err
			}
			n++
			next = id
			if settled != 1 || archived || seen[requestID] {
				continue
			}
			if parsed, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(ts)); err != nil || !parsed.Before(cut.creditBefore) {
				continue
			}
			seen[requestID] = true
			candidates = append(candidates, candidate{requestID: requestID, creditID: id})
		}
		if err := rows.Close(); err != nil {
			return 0, 0, err
		}
		report.ScannedCredits += int64(n)
		capped := false
		for _, cand := range candidates {
			if selected >= opts.MaxRequestsPerRun {
				// Resume the next run at the first candidate not evaluated.
				next = cand.creditID - 1
				capped = true
				break
			}
			b, err := collectRequestEvidence(ctx, s.reader(), cand.requestID)
			if err != nil {
				return 0, 0, err
			}
			if archivedAny, err := s.anyCreditArchived(ctx, s.reader(), b); err != nil {
				return 0, 0, err
			} else if archivedAny {
				report.SkippedRequests[retentionSkipAlreadyArchived]++
				continue
			}
			if err := collectRouteJournal(ctx, journalDB, &b); err != nil {
				return 0, 0, err
			}
			firstVerified, err := first.forBundle(ctx, b)
			if err != nil {
				return 0, 0, err
			}
			if ok, reason := evaluateRetentionEligibility(b, cut, firstVerified, true); !ok {
				report.SkippedRequests[reason]++
				continue
			}
			if err := emit(b); err != nil {
				return 0, 0, err
			}
			selected++
		}
		if capped {
			break
		}
		if n < limit {
			wrapped = true
			next = 0
			break
		}
	}
	report.ScanToCreditID = next
	report.ScanWrapped = wrapped
	return selected, next, nil
}

func (s *Store) anyCreditArchived(ctx context.Context, q evidenceQueryer, b requestEvidenceBundle) (bool, error) {
	if len(b.credits) == 0 {
		return false, nil
	}
	ids := make([]int64, len(b.credits))
	for i, c := range b.credits {
		ids[i] = c.id
	}
	ph, args := int64Placeholders(ids)
	rows, err := q.QueryContext(ctx, `SELECT 1 FROM settlement_evidence_archived_credits WHERE request_credit_id IN (`+ph+`) LIMIT 1`, args...)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	return rows.Next(), rows.Err()
}

// creditTombstones counts the request's credits that retention already
// tombstoned and reports whether archiveID wrote every one of them.
func creditTombstones(ctx context.Context, q evidenceQueryer, b requestEvidenceBundle, archiveID int64) (int, bool, error) {
	if len(b.credits) == 0 {
		return 0, false, nil
	}
	ids := make([]int64, len(b.credits))
	for i, c := range b.credits {
		ids[i] = c.id
	}
	ph, args := int64Placeholders(ids)
	rows, err := q.QueryContext(ctx, `SELECT archive_id FROM settlement_evidence_archived_credits WHERE request_credit_id IN (`+ph+`)`, args...)
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()
	n, all := 0, true
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return 0, false, err
		}
		n++
		all = all && id == archiveID
	}
	return n, all, rows.Err()
}

func addRetentionStats(report *EvidenceRetentionReport, b requestEvidenceBundle) {
	add := func(table string, rows []archiveRow) {
		st := report.Tables[table]
		for _, row := range rows {
			st.Rows++
			st.PayloadBytes += archiveRowPayloadBytes(row)
		}
		report.Tables[table] = st
	}
	for _, table := range evidenceRetentionTables {
		add(table, b.evidence[table])
	}
	if len(b.routeJournal) > 0 {
		add(evidenceRetentionJournalTable, b.routeJournal)
	}
}

func archiveRowPayloadBytes(row archiveRow) int64 {
	var n int64
	for _, v := range row {
		switch t := v.(type) {
		case string:
			n += int64(len(t))
		case archiveBlob:
			n += int64(len(t.Base64)) * 3 / 4
		case nil:
		default:
			n += 8
		}
	}
	return n
}

func newEvidenceRetentionReport(dryRun bool, now time.Time) EvidenceRetentionReport {
	tables := map[string]EvidenceRetentionTableStats{}
	for _, t := range evidenceRetentionTables {
		tables[t] = EvidenceRetentionTableStats{}
	}
	return EvidenceRetentionReport{DryRun: dryRun, StartedAtUTC: sqliteTimeText(now), SkippedRequests: map[string]int{}, Tables: tables}
}

// DryRunEvidenceRetention reports what one run would archive and delete,
// per table, without writing anything (SPEC-022 R-15.8).
func (s *Store) DryRunEvidenceRetention(ctx context.Context, opts EvidenceRetentionOptions) (EvidenceRetentionReport, error) {
	opts, err := opts.normalized()
	if err != nil {
		return EvidenceRetentionReport{}, err
	}
	now := s.nowUTC()
	report := newEvidenceRetentionReport(true, now)
	cut, err := s.evidenceRetentionCutoffsAt(ctx, opts, now)
	if err != nil {
		return report, err
	}
	fillCutoffs(&report, cut)
	selected, _, err := s.selectRetentionCandidates(ctx, opts, cut, &report, func(b requestEvidenceBundle) error {
		addRetentionStats(&report, b)
		return nil
	})
	if err != nil {
		return report, err
	}
	report.EligibleRequests = selected
	report.Status = EvidenceRetentionStatusDryRun
	report.FinishedAtUTC = sqliteTimeText(s.nowUTC())
	return report, nil
}

func fillCutoffs(report *EvidenceRetentionReport, cut evidenceRetentionCutoffs) {
	report.CreditAgeCutoffUTC = sqliteTimeText(cut.creditBefore)
	if cut.windowEndSet {
		report.CutoffWindowEndUTC = sqliteTimeText(cut.windowEnd)
	}
}

// RunEvidenceRetention performs one bounded retention run: resume or create
// an archive, re-verify it, confirm the off-host copy, delete in short
// batches, then reclaim space with incremental vacuum.
func (s *Store) RunEvidenceRetention(ctx context.Context, opts EvidenceRetentionOptions) (report EvidenceRetentionReport, err error) {
	if !s.evidenceRetentionRun.TryLock() {
		return EvidenceRetentionReport{}, ErrEvidenceRetentionBusy
	}
	defer s.evidenceRetentionRun.Unlock()
	opts, err = opts.normalized()
	if err != nil {
		return EvidenceRetentionReport{}, err
	}
	if opts.ArchiveDir == "" {
		if opts.ArchiveDir, err = s.defaultEvidenceArchiveDir(ctx); err != nil {
			return EvidenceRetentionReport{}, err
		}
	}
	now := s.nowUTC()
	report = newEvidenceRetentionReport(false, now)
	defer func() {
		report.FinishedAtUTC = sqliteTimeText(s.nowUTC())
		if err != nil {
			report.Error = err.Error()
		}
		s.setLastEvidenceRetentionReport(report)
	}()
	archive, resumed, err := s.pendingEvidenceArchive(ctx, opts)
	if err != nil {
		return report, err
	}
	if archive == nil {
		// A new archive needs room: refuse below the free-space floor rather
		// than fill the filesystem the coordinator may share.
		free, total, err := archiveFilesystemSpaceFunc(opts.ArchiveDir)
		if err != nil {
			return report, err
		}
		report.ArchiveFreeBytes, report.ArchiveDiskBytes = free, total
		if reason := archiveDiskBelowFloor(free, total, opts); reason != "" {
			report.Status = EvidenceRetentionStatusArchiveDiskLow
			report.Error = reason
			return report, nil
		}
		cut, err := s.evidenceRetentionCutoffsAt(ctx, opts, now)
		if err != nil {
			return report, err
		}
		fillCutoffs(&report, cut)
		// Each eligible request is written to the archive as it is selected
		// and then dropped, so the run never holds more than one request.
		// Free space is re-read as the archive grows, so neither the archive
		// nor concurrent database growth can push the filesystem below the
		// floor during export.
		var w *evidenceArchiveWriter
		spaceGuard := func() error {
			free, total, err := archiveFilesystemSpaceFunc(opts.ArchiveDir)
			if err != nil {
				return err
			}
			if reason := archiveDiskBelowFloor(free, total, opts); reason != "" {
				return fmt.Errorf("%w: %s", errEvidenceArchiveDiskLow, reason)
			}
			return nil
		}
		selected, nextCursor, err := s.selectRetentionCandidates(ctx, opts, cut, &report, func(b requestEvidenceBundle) error {
			if w == nil {
				created, err := newEvidenceArchiveWriter(opts.ArchiveDir, now, sqliteTimeText(cut.windowEnd))
				if err != nil {
					return err
				}
				created.setSpaceGuard(evidenceArchiveSpaceCheckBytes, spaceGuard)
				w = created
			}
			addRetentionStats(&report, b)
			return w.writeRequest(b)
		})
		if err == nil {
			err = s.saveEvidenceRetentionCursor(ctx, nextCursor)
		}
		if err != nil {
			// The partial archive is removed and the scan cursor is not
			// advanced, so the next run re-selects the same requests.
			w.abort()
			if errors.Is(err, errEvidenceArchiveDiskLow) {
				report.Status = EvidenceRetentionStatusArchiveDiskLow
				report.Error = err.Error()
				return report, nil
			}
			return report, err
		}
		if selected == 0 {
			report.Status = EvidenceRetentionStatusNothingEligible
			report.Vacuum = s.incrementalVacuumAll(ctx, opts)
			return report, nil
		}
		report.EligibleRequests = selected
		archive, err = s.recordEvidenceArchive(ctx, w)
		if errors.Is(err, errEvidenceArchiveDiskLow) {
			// finish() removed the partial archive; the cursor already moved
			// past these requests and the scan wraps back to them.
			report.Status = EvidenceRetentionStatusArchiveDiskLow
			report.Error = err.Error()
			return report, nil
		}
		if err != nil {
			return report, err
		}
	}
	report.ResumedArchive = resumed
	report.ArchiveID = archive.id
	report.ArchiveFile = archive.fileName
	report.ArchiveSHA256 = archive.manifest.SHA256
	report.ArchiveBytes = archive.manifest.SizeBytes
	verified, err := verifyEvidenceArchive(filepath.Join(opts.ArchiveDir, archive.fileName), archive.manifest)
	if err != nil {
		report.Status = EvidenceRetentionStatusArchiveInvalid
		_ = s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusFailed, err.Error(), 0)
		return report, err
	}
	if resumed {
		report.EligibleRequests = verified.Manifest.RequestCount
	}
	// The local re-read above is the verification deletion requires. An
	// off-host verification command, when configured, is one more check
	// that must pass first.
	if archive.status != evidenceArchiveStatusOffhostVerified && opts.OffhostVerifier != nil {
		if verr := opts.OffhostVerifier(ctx, verified.Path, verified.Manifest.SHA256); verr != nil {
			report.Status = EvidenceRetentionStatusOffhostUnverified
			report.Error = verr.Error()
			_ = s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusExported, verr.Error(), 0)
			return report, nil
		}
		if err := s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusOffhostVerified, "", 0); err != nil {
			return report, err
		}
	}
	deleted, err := s.deleteArchivedEvidence(ctx, opts, archive.id, verified, &report)
	if err != nil {
		if errors.Is(err, ErrEvidenceArchiveInvalid) {
			report.Status = EvidenceRetentionStatusArchiveInvalid
			_ = s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusFailed, err.Error(), 0)
		}
		return report, err
	}
	if err := s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusDeleted, "", 0); err != nil {
		return report, err
	}
	report.DeletedRequests = deleted
	report.Status = EvidenceRetentionStatusDeleted
	report.Vacuum = s.incrementalVacuumAll(ctx, opts)
	return report, nil
}

// evidenceArchiveDirName is the default archive directory, created next to
// the coordinator database file when billing.retention.archive_dir is unset.
const evidenceArchiveDirName = "retention-archive"

// defaultEvidenceArchiveDir is evidenceArchiveDirName in the directory of the
// main database file.
func (s *Store) defaultEvidenceArchiveDir(ctx context.Context) (string, error) {
	rows, err := s.db.QueryContext(ctx, `PRAGMA database_list`)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	for rows.Next() {
		var seq int
		var name, file string
		if err := rows.Scan(&seq, &name, &file); err != nil {
			return "", err
		}
		if name == "main" && filepath.IsAbs(file) {
			return filepath.Join(filepath.Dir(file), evidenceArchiveDirName), nil
		}
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	return "", errors.New("settlement evidence archive_dir is unset and the database has no file path; set billing.retention.archive_dir")
}

type evidenceArchiveRecord struct {
	id       int64
	fileName string
	status   string
	manifest EvidenceArchiveManifest
}

// pendingEvidenceArchive returns the oldest archive that was exported but
// not yet deleted, so a refused or interrupted run resumes it instead of
// writing a duplicate.
func (s *Store) pendingEvidenceArchive(ctx context.Context, opts EvidenceRetentionOptions) (*evidenceArchiveRecord, bool, error) {
	var rec evidenceArchiveRecord
	var countsJSON string
	err := s.db.QueryRowContext(ctx, `
SELECT id, file_name, status, sha256, size_bytes, request_count, row_counts_json, cutoff_window_end_utc, created_at_utc
  FROM settlement_evidence_archives
 WHERE status IN ('exported','offhost_verified')
 ORDER BY id
 LIMIT 1`).Scan(&rec.id, &rec.fileName, &rec.status, &rec.manifest.SHA256, &rec.manifest.SizeBytes, &rec.manifest.RequestCount, &countsJSON, &rec.manifest.CutoffWindowEndUTC, &rec.manifest.CreatedAtUTC)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if err := json.Unmarshal([]byte(countsJSON), &rec.manifest.RowCounts); err != nil {
		return nil, false, err
	}
	rec.manifest.Format = evidenceArchiveFormat
	rec.manifest.ArchiveFile = rec.fileName
	return &rec, true, nil
}

// recordEvidenceArchive finishes a written archive and records it as
// exported.
func (s *Store) recordEvidenceArchive(ctx context.Context, w *evidenceArchiveWriter) (*evidenceArchiveRecord, error) {
	manifest, path, err := w.finish()
	if err != nil {
		return nil, err
	}
	countsJSON, err := json.Marshal(manifest.RowCounts)
	if err != nil {
		return nil, err
	}
	stamp := sqliteTimeText(s.nowUTC())
	res, err := s.db.ExecContext(ctx, `
INSERT INTO settlement_evidence_archives (
    file_name, sha256, size_bytes, request_count, row_counts_json,
    cutoff_window_end_utc, status, created_at_utc, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, 'exported', ?, ?)`,
		manifest.ArchiveFile, manifest.SHA256, manifest.SizeBytes, manifest.RequestCount, string(countsJSON),
		manifest.CutoffWindowEndUTC, stamp, stamp)
	if err != nil {
		// Keep the durable file: it is harmless and the next run re-selects.
		return nil, fmt.Errorf("record archive %s: %w", filepath.Base(path), err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &evidenceArchiveRecord{id: id, fileName: manifest.ArchiveFile, status: evidenceArchiveStatusExported, manifest: manifest}, nil
}

func (s *Store) updateEvidenceArchiveStatus(ctx context.Context, id int64, status, lastError string, deleted int) error {
	if len(lastError) > 1000 {
		lastError = lastError[:1000]
	}
	_, err := s.db.ExecContext(ctx, `
UPDATE settlement_evidence_archives
   SET status = ?, last_error = ?, deleted_requests = deleted_requests + ?, updated_at_utc = ?
 WHERE id = ?`, status, lastError, deleted, sqliteTimeText(s.nowUTC()), id)
	return err
}

func (s *Store) saveEvidenceRetentionCursor(ctx context.Context, cursor int64) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO settlement_evidence_retention_state (id, scan_cursor_credit_id, updated_at_utc)
VALUES (1, ?, ?)
ON CONFLICT(id) DO UPDATE SET scan_cursor_credit_id = excluded.scan_cursor_credit_id, updated_at_utc = excluded.updated_at_utc`,
		cursor, sqliteTimeText(s.nowUTC()))
	return err
}

// deleteArchivedEvidence deletes, batch by batch, only rows present in the
// verified archive. It re-reads the archive as a stream and holds one batch
// (batch_size requests, at most evidenceRetentionBatchBytes of archived
// payload) at a time; every re-read request must match the digest of the
// verified pass, so a file changed since verification deletes nothing. Each
// batch is one short BEGIN IMMEDIATE transaction that re-checks R-15.2 for
// every request; the run then pauses so the hot-path writer is never starved.
func (s *Store) deleteArchivedEvidence(ctx context.Context, opts EvidenceRetentionOptions, archiveID int64, archive verifiedEvidenceArchive, report *EvidenceRetentionReport) (int, error) {
	now := s.nowUTC()
	cut, err := s.evidenceRetentionCutoffsAt(ctx, opts, now)
	if err != nil {
		return 0, err
	}
	fillCutoffs(report, cut)
	journalDB := s.routeSnapshotJournalDB.Load()
	deleted := 0
	processed := 0
	var batch []archivedRequest
	var batchBytes int64
	runBatch := func() error {
		if len(batch) == 0 {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		// A SIGHUP that disables retention stops deletion at the next batch.
		if current, ok := s.evidenceRetentionOptions(); ok && !current.Enabled {
			return ErrEvidenceRetentionDisabled
		}
		if processed > 0 && opts.BatchPause > 0 {
			timer := time.NewTimer(opts.BatchPause)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
		// The route-snapshot journal lives in another database file, so it is
		// checked before the main transaction: every live journal row of the
		// request must equal its archived copy.
		journalOK := map[string]bool{}
		for _, req := range batch {
			b := requestEvidenceBundle{requestID: req.RequestID, scopes: archivedScopes(req)}
			if err := collectRouteJournal(ctx, journalDB, &b); err != nil {
				return err
			}
			journalOK[req.RequestID] = rowsMatchArchive(b.routeJournal, req.Rows[evidenceRetentionJournalTable]) == ""
		}
		// The finality the gateway reads for each request is computed before
		// the transaction (the lookup may write) and frozen with the deletion,
		// so a buyer reservation still held at the gateway can settle after
		// the evidence is gone. The in-transaction row comparison refuses any
		// request whose evidence changed after this read.
		finalities := map[string][]frozenFinality{}
		for _, req := range batch {
			frozen, ok, err := s.frozenRequestFinality(ctx, req, s.nowUTC().UnixMilli())
			if err != nil {
				return err
			}
			if ok {
				finalities[req.RequestID] = frozen
			}
		}
		done, cleanup, err := s.deleteArchivedBatch(ctx, archiveID, batch, cut, journalOK, finalities, report)
		if err != nil {
			return err
		}
		report.DeleteBatches++
		deleted += len(done)
		processed += len(batch)
		batch, batchBytes = nil, 0
		// Journal copies go after the main rows commit. Requests this archive
		// tombstoned in an earlier, interrupted run are in cleanup too, so the
		// journal step is retried until the archive is marked deleted.
		return deleteArchivedRouteJournalRows(ctx, journalDB, cleanup, report)
	}
	err = streamEvidenceArchive(archive.Path, archive.Manifest, func(req archivedRequest) error {
		if want, ok := archive.Digests[req.RequestID]; !ok || want != req.Digest {
			return fmt.Errorf("%w: request %q changed since verification", ErrEvidenceArchiveInvalid, req.RequestID)
		}
		batch = append(batch, req)
		batchBytes += req.Bytes
		if len(batch) >= opts.BatchSize || batchBytes >= evidenceRetentionBatchBytes {
			return runBatch()
		}
		return nil
	})
	if err != nil {
		return deleted, err
	}
	return deleted, runBatch()
}

func archivedScopes(req archivedRequest) []string {
	var out []string
	seen := map[string]bool{}
	for _, row := range req.Rows["settlement_route_snapshots"] {
		if scope, ok := row.str("account_scope"); ok && !seen[scope] {
			seen[scope] = true
			out = append(out, scope)
		}
	}
	return out
}

func evaluateRouteJournalOnly(b requestEvidenceBundle) (bool, string) {
	digests := map[string]string{}
	for _, srs := range b.evidence["settlement_route_snapshots"] {
		digests[routeJournalKey(srs)], _ = srs.str("route_snapshot_digest")
	}
	for _, j := range b.routeJournal {
		digest, _ := j.str("route_snapshot_digest")
		want, ok := digests[routeJournalKey(j)]
		if j.isNull("mirrored_at_utc") || !ok || want != digest {
			return false, retentionSkipRouteJournal
		}
	}
	return true, ""
}

// deleteArchivedBatch deletes one batch in one transaction. It returns the
// requests it deleted and the requests whose route-journal copies must now be
// removed: those plus requests this archive already tombstoned in an earlier
// run that stopped before its journal step.
func (s *Store) deleteArchivedBatch(ctx context.Context, archiveID int64, batch []archivedRequest, cut evidenceRetentionCutoffs, journalOK map[string]bool, finalities map[string][]frozenFinality, report *EvidenceRetentionReport) ([]archivedRequest, []archivedRequest, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return nil, nil, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	stamp := sqliteTimeText(s.nowUTC())
	first := &providerFirstVerifiedVerdicts{q: conn, cache: map[string]int64{}}
	var done, cleanup []archivedRequest
	tableDeleted := map[string]int64{}
	floorRecorded := false
	for _, req := range batch {
		b, err := collectRequestEvidence(ctx, conn, req.RequestID)
		if err != nil {
			return nil, nil, err
		}
		tombstones, byThisArchive, err := creditTombstones(ctx, conn, b, archiveID)
		if err != nil {
			return nil, nil, err
		}
		if tombstones > 0 {
			if byThisArchive && tombstones == len(b.credits) && sameCredits(b, req) {
				cleanup = append(cleanup, req)
			} else {
				report.SkippedRequests[retentionSkipAlreadyArchived]++
			}
			continue
		}
		if !journalOK[req.RequestID] {
			report.SkippedRequests[retentionSkipRouteJournal]++
			continue
		}
		firstVerified, err := first.forBundle(ctx, b)
		if err != nil {
			return nil, nil, err
		}
		if ok, reason := evaluateRetentionEligibility(b, cut, firstVerified, false); !ok {
			report.SkippedRequests[reason]++
			continue
		}
		if !sameCredits(b, req) {
			report.SkippedRequests[retentionSkipHotRowNotArchived]++
			continue
		}
		if reason := hotRowsMatchArchive(b, req); reason != "" {
			report.SkippedRequests[reason]++
			continue
		}
		frozen, ok := finalities[req.RequestID]
		if !ok {
			report.SkippedRequests[retentionSkipFinalityOpen]++
			continue
		}
		if !floorRecorded {
			// SPEC-022 R-15.9: archived credits are payable only through the
			// tombstones, which a pre-retention coordinator cannot read. Open
			// already recorded this floor; recording it again here makes every
			// deletion commit with it, whatever happened to the row since.
			if err := recordBillingCompatFloorExec(ctx, conn, billingCompatContractEvidenceRetention); err != nil {
				return nil, nil, err
			}
			floorRecorded = true
		}
		for _, table := range evidenceRetentionTables {
			for _, row := range b.evidence[table] {
				id, _ := row.int64("id")
				res, err := conn.ExecContext(ctx, `DELETE FROM `+table+` WHERE id = ?`, id)
				if err != nil {
					return nil, nil, fmt.Errorf("delete %s id=%d: %w", table, id, err)
				}
				n, _ := res.RowsAffected()
				tableDeleted[table] += n
				if table == "settlement_receipt_verdicts" && n == 1 {
					providerID, _ := row.str("provider_id")
					outcome, _ := row.str("settlement_outcome")
					result, _ := row.str("receipt_result")
					if _, err := conn.ExecContext(ctx, `
INSERT INTO settlement_evidence_archived_verdict_counts (provider_id, settlement_outcome, receipt_result, verdict_count)
VALUES (?, ?, ?, 1)
ON CONFLICT(provider_id, settlement_outcome, receipt_result) DO UPDATE SET verdict_count = verdict_count + 1`,
						providerID, outcome, result); err != nil {
						return nil, nil, err
					}
				}
			}
		}
		for _, f := range frozen {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO settlement_evidence_archived_finality (account_scope_hash, request_id, archive_id, finality_json, archived_at_utc)
VALUES (?, ?, ?, ?, ?)`, f.scopeHash, req.RequestID, archiveID, f.json, stamp); err != nil {
				return nil, nil, err
			}
		}
		for _, c := range b.credits {
			verified := archivedCreditVerified(c, b.evidence["settlement_receipt_verdicts"])
			if _, err := conn.ExecContext(ctx, `
INSERT INTO settlement_evidence_archived_credits (request_credit_id, request_id, archive_id, spec022_verified, archived_at_utc)
VALUES (?, ?, ?, ?, ?)`, c.id, req.RequestID, archiveID, boolInt(verified), stamp); err != nil {
				return nil, nil, err
			}
		}
		done = append(done, req)
		cleanup = append(cleanup, req)
	}
	// The count commits with the deletion it counts, so a run interrupted
	// before its journal step never leaves the archive's total short.
	if len(done) > 0 {
		if _, err := conn.ExecContext(ctx, `
UPDATE settlement_evidence_archives SET deleted_requests = deleted_requests + ? WHERE id = ?`, len(done), archiveID); err != nil {
			return nil, nil, err
		}
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return nil, nil, err
	}
	committed = true
	for table, n := range tableDeleted {
		st := report.Tables[table]
		st.DeletedRows += n
		report.Tables[table] = st
	}
	return done, cleanup, nil
}

// frozenFinality is one account scope's settlement finality for an archived
// request, as the gateway's finality lookup returned it before deletion.
type frozenFinality struct {
	scopeHash string
	json      string
}

// frozenRequestFinality computes the finality of every account scope the
// archived request settled under. ok is false when any scope's finality is
// not closed and complete: such a request stays hot so a held buyer
// reservation can still resolve from live evidence. A scope with no finality
// stores nothing; its lookup already answers not found.
func (s *Store) frozenRequestFinality(ctx context.Context, req archivedRequest, nowUnixMS int64) ([]frozenFinality, bool, error) {
	var out []frozenFinality
	for _, scope := range archivedScopes(req) {
		finality, found, err := s.RequestSettlementFinality(ctx, scope, req.RequestID, nowUnixMS)
		if err != nil {
			return nil, false, err
		}
		if !found {
			continue
		}
		if !finality.Closed || !finality.ModeScopeComplete || finality.PendingAttempts > 0 {
			return nil, false, nil
		}
		finality.RequiredInternalRequestID = ""
		finality.RelayBlindSettlementCoverage = ""
		raw, err := json.Marshal(finality)
		if err != nil {
			return nil, false, err
		}
		out = append(out, frozenFinality{scopeHash: SettlementAccountScopeHash(scope), json: string(raw)})
	}
	return out, true, nil
}

// archivedRequestSettlementFinality is the finality frozen when retention
// deleted the request's evidence (SPEC-022 R-15.6).
func (s *Store) archivedRequestSettlementFinality(ctx context.Context, accountScope, requestID string) (RequestSettlementFinality, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	var raw string
	err := s.reader().QueryRowContext(ctx, `
SELECT finality_json FROM settlement_evidence_archived_finality
 WHERE account_scope_hash = ? AND request_id = ?`, SettlementAccountScopeHash(accountScope), requestID).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return RequestSettlementFinality{}, false, nil
	}
	if err != nil {
		return RequestSettlementFinality{}, false, err
	}
	var finality RequestSettlementFinality
	if err := json.Unmarshal([]byte(raw), &finality); err != nil {
		return RequestSettlementFinality{}, false, fmt.Errorf("decode archived settlement finality: %w", err)
	}
	return finality, true, nil
}

// archivedCreditVerified mirrors the billing mirror's spec022_verified
// predicate: a literal closed, valid, verified verdict for the credit.
func archivedCreditVerified(c retentionCredit, verdicts []archiveRow) bool {
	if c.scopeHash == "" {
		return false
	}
	for _, v := range verdicts {
		h, _ := v.str("account_scope_hash")
		a, _ := v.int64("attempt_n")
		p, _ := v.str("provider_id")
		closed, _ := v.int64("closed")
		result, _ := v.str("receipt_result")
		outcome, _ := v.str("settlement_outcome")
		if h == c.scopeHash && a == c.attemptN && p == c.providerID && closed == 1 &&
			result == SettlementReceiptResultValid && outcome == SettlementOutcomeVerified {
			return true
		}
	}
	return false
}

// hotRowsMatchArchive refuses a request whose hot evidence includes a row
// the verified archive does not hold, or a row whose content changed after
// it was archived (SPEC-022 R-15.4): deletion must lose nothing.
func hotRowsMatchArchive(b requestEvidenceBundle, req archivedRequest) string {
	for _, table := range evidenceRetentionTables {
		if reason := rowsMatchArchive(b.evidence[table], req.Rows[table]); reason != "" {
			return reason
		}
	}
	return ""
}

// rowsMatchArchive reports why live rows are not all present, column for
// column, among the archived rows ("" when they are).
func rowsMatchArchive(live, archived []archiveRow) string {
	byID := make(map[int64]archiveRow, len(archived))
	for _, row := range archived {
		if id, ok := row.int64("id"); ok {
			byID[id] = row
		}
	}
	for _, row := range live {
		id, ok := row.int64("id")
		if !ok {
			return retentionSkipHotRowNotArchived
		}
		want, ok := byID[id]
		if !ok {
			return retentionSkipHotRowNotArchived
		}
		if !archiveRowsEqual(row, want) {
			return retentionSkipHotRowChanged
		}
	}
	return ""
}

// archiveRowsEqual compares two rows column by column. A REAL that holds an
// integral value is written to JSON without a fraction and reads back as an
// integer, so numbers compare by value.
func archiveRowsEqual(a, b archiveRow) bool {
	if len(a) != len(b) {
		return false
	}
	for col, av := range a {
		bv, ok := b[col]
		if !ok || !archiveValuesEqual(av, bv) {
			return false
		}
	}
	return true
}

func archiveValuesEqual(a, b any) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case string:
		y, ok := b.(string)
		return ok && x == y
	case archiveBlob:
		y, ok := b.(archiveBlob)
		return ok && x == y
	case int64:
		switch y := b.(type) {
		case int64:
			return x == y
		case float64:
			return float64(x) == y && int64(y) == x
		}
	case float64:
		switch y := b.(type) {
		case float64:
			return x == y
		case int64:
			return float64(y) == x && int64(x) == y
		}
	}
	return false
}

func sameCredits(b requestEvidenceBundle, req archivedRequest) bool {
	if len(b.credits) != len(req.CreditIDs) {
		return false
	}
	want := map[int64]bool{}
	for _, id := range req.CreditIDs {
		want[id] = true
	}
	for _, c := range b.credits {
		if !want[c.id] {
			return false
		}
	}
	return true
}

// deleteArchivedRouteJournalRows removes the route-snapshot journal rows
// archived with each request, by id, only while the live row still equals
// its archived copy. A row already gone is the expected state on a retry; a
// row that changed stays hot and is reported.
func deleteArchivedRouteJournalRows(ctx context.Context, journalDB *sql.DB, reqs []archivedRequest, report *EvidenceRetentionReport) error {
	if journalDB == nil || len(reqs) == 0 {
		return nil
	}
	tx, err := journalDB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var deleted, kept int64
	for _, req := range reqs {
		for _, archived := range req.Rows[evidenceRetentionJournalTable] {
			id, ok := archived.int64("id")
			if !ok {
				kept++
				continue
			}
			live, err := queryArchiveRows(ctx, tx, `SELECT * FROM settlement_route_snapshot_journal WHERE id = ?`, id)
			if err != nil {
				return err
			}
			if len(live) == 0 {
				continue
			}
			if !archiveRowsEqual(live[0], archived) {
				kept++
				continue
			}
			res, err := tx.ExecContext(ctx, `DELETE FROM settlement_route_snapshot_journal WHERE id = ?`, id)
			if err != nil {
				return err
			}
			n, _ := res.RowsAffected()
			deleted += n
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	report.RouteJournalDeletedRows += deleted
	report.RouteJournalKeptRows += kept
	st := report.Tables[evidenceRetentionJournalTable]
	st.DeletedRows += deleted
	report.Tables[evidenceRetentionJournalTable] = st
	return nil
}

func (s *Store) incrementalVacuumAll(ctx context.Context, opts EvidenceRetentionOptions) []EvidenceRetentionVacuumReport {
	out := []EvidenceRetentionVacuumReport{incrementalVacuum(ctx, s.db, "coordinator", opts)}
	if journalDB := s.routeSnapshotJournalDB.Load(); journalDB != nil {
		out = append(out, incrementalVacuum(ctx, journalDB, "route_snapshot_journal", opts))
	}
	return out
}

// incrementalVacuum reclaims free pages in bounded steps. It never runs a
// full VACUUM; a database outside INCREMENTAL mode only reports it.
func incrementalVacuum(ctx context.Context, db *sql.DB, name string, opts EvidenceRetentionOptions) EvidenceRetentionVacuumReport {
	r := EvidenceRetentionVacuumReport{Database: name}
	var mode int
	if err := db.QueryRowContext(ctx, `PRAGMA auto_vacuum`).Scan(&mode); err != nil {
		r.AutoVacuumMode = "unknown"
		return r
	}
	switch mode {
	case 0:
		r.AutoVacuumMode = "none"
	case 1:
		r.AutoVacuumMode = "full"
	case 2:
		r.AutoVacuumMode = "incremental"
	default:
		r.AutoVacuumMode = fmt.Sprintf("unknown(%d)", mode)
	}
	_ = db.QueryRowContext(ctx, `PRAGMA freelist_count`).Scan(&r.FreelistBefore)
	r.FreelistAfter = r.FreelistBefore
	if mode != 2 {
		r.ConversionNeeds = mode == 0
		return r
	}
	for r.Steps < opts.IncrementalVacuumMaxSteps && opts.IncrementalVacuumPages > 0 {
		if ctx.Err() != nil || r.FreelistAfter == 0 {
			break
		}
		if _, err := db.ExecContext(ctx, fmt.Sprintf(`PRAGMA incremental_vacuum(%d)`, opts.IncrementalVacuumPages)); err != nil {
			break
		}
		r.Steps++
		if err := db.QueryRowContext(ctx, `PRAGMA freelist_count`).Scan(&r.FreelistAfter); err != nil {
			break
		}
		if opts.BatchPause > 0 {
			timer := time.NewTimer(opts.BatchPause)
			select {
			case <-ctx.Done():
				timer.Stop()
				return r
			case <-timer.C:
			}
		}
	}
	return r
}

// StartEvidenceRetention runs retention daily at 03:00 UTC, away from the
// 00:00 nightly reconcile and the Monday 00:00 weekly settlement. It reads
// the installed options on each tick and does nothing while disabled.
func (s *Store) StartEvidenceRetention(ctx context.Context, logf func(EvidenceRetentionReport, error)) {
	go func() {
		for {
			now := time.Now().UTC()
			next := time.Date(now.Year(), now.Month(), now.Day(), 3, 0, 0, 0, time.UTC)
			if !next.After(now) {
				next = next.AddDate(0, 0, 1)
			}
			timer := time.NewTimer(time.Until(next))
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			opts, ok := s.evidenceRetentionOptions()
			if !ok || !opts.Enabled {
				continue
			}
			report, err := s.RunEvidenceRetention(ctx, opts)
			level := "info"
			if report.Status == EvidenceRetentionStatusArchiveDiskLow {
				level = "warn"
			}
			log.Printf("settlement evidence retention: level=%s status=%s archive_bytes=%d archive_free_bytes=%d archive_disk_bytes=%d delete_batches=%d deleted_requests=%d reason=%q",
				level, report.Status, report.ArchiveBytes, report.ArchiveFreeBytes, report.ArchiveDiskBytes, report.DeleteBatches, report.DeletedRequests, report.Error)
			if logf != nil {
				logf(report, err)
			}
		}
	}()
}
