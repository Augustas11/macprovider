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
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

// SPEC-022 R-15 (#1793): settled-evidence retention. Per-attempt settlement
// evidence of requests whose verdicts all closed, and whose credits were all
// created, before the R-15.2 finality point (verdict close plus a grace
// period, after a completed nightly reconcile) is exported to a local
// archive, verified by re-reading it (checksum, size, row counts, and
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
	// EvidenceRetentionStatusBudgetSpent is a run whose wall-clock budget
	// ran out before it deleted anything; a pending archive resumes next run.
	EvidenceRetentionStatusBudgetSpent = "run_budget_spent"

	// Why a run stopped (EvidenceRetentionReport.StopReason).
	EvidenceRetentionStopDrained   = "drained"
	EvidenceRetentionStopBudget    = "run_budget"
	EvidenceRetentionStopScanBound = "scan_bound"
	EvidenceRetentionStopRefused   = "refused"
	// EvidenceRetentionStopLapComplete: the run completed a scan lap that
	// found eligible requests. A run never starts a second lap (it would
	// re-select requests the deletion re-check kept hot); the next run's lap
	// shows whether the backlog drained.
	EvidenceRetentionStopLapComplete = "lap_complete"

	// evidenceRetentionDefaultRunBudget applies when no budget is set.
	evidenceRetentionDefaultRunBudget = 30 * time.Minute
	// evidenceRetentionBacklogTimeout bounds the end-of-run backlog count.
	evidenceRetentionBacklogTimeout = 2 * time.Minute

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
	// retentionSkipVerdictGrace: a verdict of the request closed at or after
	// the finality point (SPEC-022 v0.4.5 R-15.2).
	retentionSkipVerdictGrace = "verdict_inside_grace"
	// retentionSkipSettlementLink: settled without a payout, or a payout id
	// on an unsettled credit (the weekly settlement quarantines the latter).
	retentionSkipSettlementLink = "credit_settlement_link_inconsistent"
)

var (
	ErrEvidenceRetentionBusy     = errors.New("settlement evidence retention is already running")
	ErrEvidenceRetentionDisabled = errors.New("settlement evidence retention was disabled during the run")
	// errEvidenceRetentionBudgetSpent stops deletion at a batch boundary once
	// the run's wall-clock budget is spent.
	errEvidenceRetentionBudgetSpent = errors.New("settlement evidence retention run budget spent")
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
	Enabled    bool
	ArchiveDir string
	// MinSettlementCycles is carried for configuration compatibility; it no
	// longer gates eligibility (SPEC-022 v0.4.5).
	MinSettlementCycles int
	CadenceDays         int
	// ReconcileHorizon is the nightly/startup reconcile reach: a credit
	// older than it is outside every reconcile window.
	ReconcileHorizon time.Duration
	// VerdictCloseGrace is the R-15.2 grace after verdict close.
	VerdictCloseGrace time.Duration
	BatchSize         int
	BatchPause        time.Duration
	// MaxRequestsPerArchive bounds one archive. A run writes, verifies, and
	// deletes archive after archive until nothing eligible remains, the scan
	// bound is reached, or RunBudget is spent.
	MaxRequestsPerArchive int
	// MaxScanRowsPerRun bounds the ledger credits one run walks.
	MaxScanRowsPerRun int
	// RunBudget is the run's wall-clock budget, checked between archives and
	// between delete batches.
	RunBudget                 time.Duration
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
		VerdictCloseGrace:         time.Duration(rc.VerdictCloseGraceHours) * time.Hour,
		BatchSize:                 rc.BatchSize,
		BatchPause:                time.Duration(rc.BatchPauseMS) * time.Millisecond,
		MaxRequestsPerArchive:     rc.MaxRequestsPerRun,
		MaxScanRowsPerRun:         rc.MaxScanRowsPerRun,
		RunBudget:                 time.Duration(rc.RunBudgetMinutes) * time.Minute,
		IncrementalVacuumPages:    rc.IncrementalVacuumPages,
		IncrementalVacuumMaxSteps: rc.IncrementalVacuumMaxSteps,
		ArchiveMinFreeBytes:       rc.ArchiveMinFreeBytes,
		ArchiveMinFreePercent:     rc.ArchiveMinFreePercent,
		OffhostVerifier:           CommandOffhostVerifier(rc.OffhostVerifyCommand, time.Duration(rc.OffhostVerifyTimeoutSeconds)*time.Second),
	}
}

// evidenceRetentionDefaultGrace is the R-15.2 grace when none is set.
const evidenceRetentionDefaultGrace = 48 * time.Hour

func (o EvidenceRetentionOptions) normalized() (EvidenceRetentionOptions, error) {
	if o.VerdictCloseGrace <= 0 {
		o.VerdictCloseGrace = evidenceRetentionDefaultGrace
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
	if o.MaxRequestsPerArchive < 1 {
		o.MaxRequestsPerArchive = 1
	}
	if o.MaxScanRowsPerRun < 1 {
		o.MaxScanRowsPerRun = 1
	}
	if o.RunBudget <= 0 {
		o.RunBudget = evidenceRetentionDefaultRunBudget
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
	Status             string `json:"status"`
	DryRun             bool   `json:"dry_run"`
	StartedAtUTC       string `json:"started_at_utc"`
	FinishedAtUTC      string `json:"finished_at_utc,omitempty"`
	CutoffWindowEndUTC string `json:"cutoff_window_end_utc,omitempty"`
	CreditAgeCutoffUTC string `json:"credit_age_cutoff_utc,omitempty"`
	ScanFromCreditID   int64  `json:"scan_from_credit_id"`
	ScanToCreditID     int64  `json:"scan_to_credit_id"`
	ScannedCredits     int64  `json:"scanned_credits"`
	ScanWrapped        bool   `json:"scan_wrapped"`
	// EligibleRequests sums the requests of every archive the run wrote or
	// resumed; a dry run reports the first archive's.
	EligibleRequests int                                    `json:"eligible_requests"`
	SkippedRequests  map[string]int                         `json:"skipped_requests"`
	Tables           map[string]EvidenceRetentionTableStats `json:"tables"`
	// ArchiveID and the other Archive* fields describe the run's last archive;
	// Archives counts the archives it deleted.
	ArchiveID     int64  `json:"archive_id,omitempty"`
	ArchiveFile   string `json:"archive_file,omitempty"`
	ArchiveSHA256 string `json:"archive_sha256,omitempty"`
	ArchiveBytes  int64  `json:"archive_bytes,omitempty"`
	// ArchiveFreeBytes is the free space of the archive filesystem before the
	// run's last new archive; ArchiveDiskBytes is that filesystem's size.
	ArchiveFreeBytes int64 `json:"archive_free_bytes,omitempty"`
	ArchiveDiskBytes int64 `json:"archive_disk_bytes,omitempty"`
	ResumedArchive   bool  `json:"resumed_archive,omitempty"`
	DeletedRequests  int   `json:"deleted_requests"`
	Archives         int   `json:"archives"`
	// StopReason says why the run ended: drained, run_budget, scan_bound, or
	// refused (Status names the refusal). Empty on error.
	StopReason string `json:"stop_reason,omitempty"`
	// BacklogDrained is true when the most recently completed scan lap,
	// persisted across runs, found no eligible request.
	BacklogDrained bool `json:"backlog_drained"`
	// BacklogCandidateCredits counts settled, unarchived credits above the
	// archived low watermark that are past both finality cutoffs, plus the
	// held requests at or below it: an upper bound of the remaining eligible
	// backlog. It does not reach zero after a drain: held requests and
	// requests kept hot by design (LastLapSkippedRequests) stay in it. -1
	// means it was not computed or did not finish.
	BacklogCandidateCredits int64 `json:"backlog_candidate_credits"`
	// HeldRequests is the size of the holds table: requests below the
	// watermark that may still become eligible, re-checked every lap.
	HeldRequests int64 `json:"held_requests"`
	// WatermarkCreditID is the archived low watermark after the run: every
	// credit at or below it is archived or kept hot for a permanent reason.
	WatermarkCreditID int64 `json:"watermark_credit_id"`
	// LapsCompleted counts completed scan laps over the database's life;
	// LapEligibleRequests counts the current lap's eligible requests so far.
	LapsCompleted       int64 `json:"laps_completed"`
	LapEligibleRequests int64 `json:"lap_eligible_requests"`
	// LastLap* describe the most recently completed lap (eligible -1: none).
	LastLapCompletedAtUTC   string         `json:"last_lap_completed_at_utc,omitempty"`
	LastLapEligibleRequests int64          `json:"last_lap_eligible_requests"`
	LastLapSkippedRequests  map[string]int `json:"last_lap_skipped_requests,omitempty"`
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
	// Skipped says why no incremental_vacuum step ran.
	Skipped string `json:"skipped,omitempty"`
}

// LastLapSkipSummary is the last completed lap's skip counts by reason,
// sorted, for logs: the expected non-zero floor of a drained backlog.
func (r EvidenceRetentionReport) LastLapSkipSummary() string {
	reasons := make([]string, 0, len(r.LastLapSkippedRequests))
	for reason := range r.LastLapSkippedRequests {
		reasons = append(reasons, reason)
	}
	sort.Strings(reasons)
	parts := make([]string, 0, len(reasons))
	for _, reason := range reasons {
		parts = append(parts, fmt.Sprintf("%s:%d", reason, r.LastLapSkippedRequests[reason]))
	}
	return strings.Join(parts, ",")
}

// AutoVacuumModes is the run's auto_vacuum mode per database file, for logs.
func (r EvidenceRetentionReport) AutoVacuumModes() string {
	parts := make([]string, 0, len(r.Vacuum))
	for _, v := range r.Vacuum {
		parts = append(parts, v.Database+"="+v.AutoVacuumMode)
	}
	return strings.Join(parts, ",")
}

type evidenceRetentionRuntime struct {
	mu         sync.Mutex
	settings   *EvidenceRetentionOptions
	lastReport *EvidenceRetentionReport
	// rollup holds the SPEC-022 R-15.11 ledger rollup settings; the nightly
	// job runs the rollup after retention.
	rollup *LedgerRollupOptions
	// mirrorWatermark gates the rollup on the stats billing mirror.
	mirrorWatermark LedgerRollupMirrorWatermark
}

// SetLedgerRollupOptions installs the effective ledger rollup settings.
func (s *Store) SetLedgerRollupOptions(opts LedgerRollupOptions) {
	if s == nil {
		return
	}
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	copied := opts
	s.evidenceRetention.rollup = &copied
}

func (s *Store) ledgerRollupOptions() (LedgerRollupOptions, bool) {
	s.evidenceRetention.mu.Lock()
	defer s.evidenceRetention.mu.Unlock()
	if s.evidenceRetention.rollup == nil {
		return LedgerRollupOptions{}, false
	}
	return *s.evidenceRetention.rollup, true
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
	if err != nil {
		return err
	}
	// #1979: the scan lap state and the archived low watermark. Added by
	// column so databases created by the first retention release migrate.
	add := []struct{ table, name, sql string }{
		{"settlement_evidence_retention_state", "archived_low_watermark_credit_id", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN archived_low_watermark_credit_id INTEGER NOT NULL DEFAULT 0 CHECK(archived_low_watermark_credit_id >= 0)`},
		{"settlement_evidence_retention_state", "lap_start_credit_id", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN lap_start_credit_id INTEGER NOT NULL DEFAULT -1`},
		{"settlement_evidence_retention_state", "lap_hold_credit_id", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN lap_hold_credit_id INTEGER NOT NULL DEFAULT 0 CHECK(lap_hold_credit_id >= 0)`},
		{"settlement_evidence_retention_state", "lap_eligible_requests", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN lap_eligible_requests INTEGER NOT NULL DEFAULT 0`},
		{"settlement_evidence_retention_state", "lap_skipped_json", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN lap_skipped_json TEXT NOT NULL DEFAULT '{}'`},
		{"settlement_evidence_retention_state", "laps_completed", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN laps_completed INTEGER NOT NULL DEFAULT 0`},
		{"settlement_evidence_retention_state", "last_lap_completed_at_utc", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN last_lap_completed_at_utc TEXT NOT NULL DEFAULT ''`},
		{"settlement_evidence_retention_state", "last_lap_eligible_requests", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN last_lap_eligible_requests INTEGER NOT NULL DEFAULT -1`},
		{"settlement_evidence_retention_state", "last_lap_skipped_json", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN last_lap_skipped_json TEXT NOT NULL DEFAULT '{}'`},
		{"settlement_evidence_retention_state", "lap_holds_cursor", `ALTER TABLE settlement_evidence_retention_state ADD COLUMN lap_holds_cursor INTEGER NOT NULL DEFAULT 0`},
		{"settlement_evidence_archives", "min_credit_id", `ALTER TABLE settlement_evidence_archives ADD COLUMN min_credit_id INTEGER NOT NULL DEFAULT 0 CHECK(min_credit_id >= 0)`},
		// #1793: the pool binding of the credit's attempt, so SPEC-043-R010
		// creator earnings keep counting it after its route snapshot leaves.
		{"settlement_evidence_archived_credits", "pool_id", `ALTER TABLE settlement_evidence_archived_credits ADD COLUMN pool_id TEXT NULL`},
	}
	if _, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS settlement_evidence_retention_holds (
    request_id TEXT PRIMARY KEY,
    credit_id INTEGER NOT NULL CHECK(credit_id > 0),
    reason TEXT NOT NULL,
    held_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_serh_credit ON settlement_evidence_retention_holds(credit_id);
-- SPEC-022 v0.4.5 R-15.6: a tombstoned credit's money columns are immutable
-- whether or not it settled; the archived reference copy is its
-- rederivation source.
CREATE TRIGGER IF NOT EXISTS trg_lrc_archived_money_immutable
BEFORE UPDATE OF prompt_tokens, completion_tokens, estimated_completion_tokens,
                 charged_prompt_tokens, provider_reported_prompt_tokens,
                 usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
                 cached_prompt_tokens,
                 global_multiplier_ppm, gross_credits, provider_share_bps,
                 provider_credits, fault_flag ON ledger_request_credits
WHEN EXISTS (
      SELECT 1 FROM settlement_evidence_archived_credits archived
       WHERE archived.request_credit_id = OLD.id
  )
  AND (
      COALESCE(OLD.prompt_tokens, -1) != COALESCE(NEW.prompt_tokens, -1)
      OR COALESCE(OLD.charged_prompt_tokens, -1) != COALESCE(NEW.charged_prompt_tokens, -1)
      OR COALESCE(OLD.provider_reported_prompt_tokens, -1) != COALESCE(NEW.provider_reported_prompt_tokens, -1)
      OR COALESCE(OLD.completion_tokens, -1) != COALESCE(NEW.completion_tokens, -1)
      OR COALESCE(OLD.estimated_completion_tokens, -1) != COALESCE(NEW.estimated_completion_tokens, -1)
      OR OLD.usage_source != NEW.usage_source
      OR OLD.prompt_rate_per_mtok != NEW.prompt_rate_per_mtok
      OR COALESCE(OLD.cached_prompt_tokens, -1) != COALESCE(NEW.cached_prompt_tokens, -1)
      OR OLD.completion_rate_per_mtok != NEW.completion_rate_per_mtok
      OR OLD.global_multiplier_ppm != NEW.global_multiplier_ppm
      OR OLD.gross_credits != NEW.gross_credits
      OR OLD.provider_share_bps != NEW.provider_share_bps
      OR OLD.provider_credits != NEW.provider_credits
      OR OLD.fault_flag != NEW.fault_flag
  )
BEGIN
    SELECT RAISE(ABORT, 'archived ledger_request_credits money fields are immutable');
END;`); err != nil {
		return err
	}
	for _, col := range add {
		exists, err := s.columnExists(ctx, col.table, col.name)
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

// evidenceRetentionCutoffs is the R-15.2 finality point T of one run: every
// credit of an eligible request was created, and every verdict closed,
// before it. windowEnd mirrors creditBefore for the report and the archive
// manifest's cutoff field.
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
		case c.quarantined:
			return false, retentionSkipQuarantined
		case c.resolutions > 0:
			return false, retentionSkipResolution
		case !c.payable:
			return false, retentionSkipNotPayable
		case c.tsUTC.IsZero() || !c.tsUTC.Before(cut.creditBefore):
			return false, retentionSkipInsideReconcile
		case c.settled != (c.settlementID != nil):
			return false, retentionSkipSettlementLink
		}
		// SPEC-022 v0.4.5: an unsettled credit leaves its evidence too; its
		// tombstone keeps it payable and settles it (R-15.6). A settled one
		// must point at a live payout.
		if !c.settled {
			continue
		}
		payout, ok := b.payouts[*c.settlementID]
		if !ok {
			return false, retentionSkipPayoutMissing
		}
		status, _ := payout.str("status")
		if status != "ready" && status != "consumed" {
			return false, retentionSkipPayoutVoided
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
		if !verdictClosedBefore(v, cut.creditBefore) {
			return false, retentionSkipVerdictGrace
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

// evidenceRetentionCutoffsAt computes the R-15.2 finality point T: the
// earlier of now minus the verdict-close grace and the start of the newest
// completed nightly reconcile, but never earlier than the reconcile horizon
// before now (past it no reconcile reads the credit).
func (s *Store) evidenceRetentionCutoffsAt(ctx context.Context, opts EvidenceRetentionOptions, now time.Time) (evidenceRetentionCutoffs, error) {
	grace := opts.VerdictCloseGrace
	if grace <= 0 {
		grace = evidenceRetentionDefaultGrace
	}
	reconciled := now.Add(-opts.ReconcileHorizon)
	var startedText sql.NullString
	if err := s.reader().QueryRowContext(ctx, `
SELECT MAX(started_at_utc) FROM ledger_reconciliation_runs
 WHERE run_type = 'nightly_reconcile' AND status = 'complete'`).Scan(&startedText); err != nil {
		return evidenceRetentionCutoffs{}, err
	}
	if startedText.Valid {
		if started, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(startedText.String)); err == nil && started.After(reconciled) {
			reconciled = started
		}
	}
	t := now.Add(-grace)
	if reconciled.Before(t) {
		t = reconciled
	}
	t = t.UTC()
	return evidenceRetentionCutoffs{windowEnd: t, windowEndSet: true, creditBefore: t}, nil
}

// verdictClosedBefore reports whether a closed verdict's close time, the
// later of its created_at_utc and updated_at_utc, is before t. An unreadable
// stamp is never before t.
func verdictClosedBefore(v archiveRow, t time.Time) bool {
	closedAt := time.Time{}
	for _, col := range []string{"created_at_utc", "updated_at_utc"} {
		text, ok := v.str(col)
		if !ok || strings.TrimSpace(text) == "" {
			if col == "created_at_utc" {
				return false
			}
			continue
		}
		parsed, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(text))
		if err != nil {
			return false
		}
		if parsed.After(closedAt) {
			closedAt = parsed
		}
	}
	return !closedAt.IsZero() && closedAt.Before(t)
}

// retentionPermanentSkips are skip reasons that keep a request hot for good:
// the watermark passes it and no hold is kept. A request misclassified as
// permanent only stays hot; it is never deleted early.
var retentionPermanentSkips = map[string]bool{
	retentionSkipNoCredit:        true,
	retentionSkipResolution:      true,
	retentionSkipRelayBlind:      true,
	retentionSkipFirstVerified:   true,
	retentionSkipAlreadyArchived: true,
}

// retentionFrontierSkips are reasons a request is simply too young: it sits
// near the end of the ledger, so it pins the watermark (the next lap re-reads
// it) instead of taking a row in the holds table.
var retentionFrontierSkips = map[string]bool{
	retentionSkipWindowTooRecent: true,
	retentionSkipInsideReconcile: true,
}

// retentionLapState is the persisted scan lap (#1979). A lap first re-checks
// the holds table (requests below the lap start that may still become
// eligible), then walks the ledger from the archived low watermark to its
// end, across runs. Every credit at or below the watermark is archived, kept
// hot for good, or named in the holds table. When a lap completes, the
// watermark moves to the end of the lap, or to just below the lowest
// too-young credit the lap met (the frontier pin), the lowest credit it
// selected, or the lowest credit of a pending archive.
type retentionLapState struct {
	cursor    int64
	watermark int64
	lapStart  int64 // -1: no lap started yet
	pin       int64 // lowest frontier credit of the lap (0: none)
	// holdsCursor: holds with credit_id in (holdsCursor, lapStart] are still
	// to be re-checked this lap; -1 once they all were.
	holdsCursor        int64
	lapEligible        int64
	lapSkipped         map[string]int
	lapsCompleted      int64
	lastLapCompletedAt string
	lastLapEligible    int64 // -1: no lap completed yet
	lastLapSkipped     map[string]int
}

func loadRetentionLapState(ctx context.Context, q evidenceQueryer) (retentionLapState, error) {
	st := retentionLapState{lapStart: -1, lastLapEligible: -1, lapSkipped: map[string]int{}, lastLapSkipped: map[string]int{}}
	var lapSkipped, lastSkipped string
	err := q.QueryRowContext(ctx, `
SELECT scan_cursor_credit_id, archived_low_watermark_credit_id, lap_start_credit_id, lap_hold_credit_id,
       lap_holds_cursor, lap_eligible_requests, lap_skipped_json, laps_completed, last_lap_completed_at_utc,
       last_lap_eligible_requests, last_lap_skipped_json
  FROM settlement_evidence_retention_state WHERE id = 1`).Scan(&st.cursor, &st.watermark, &st.lapStart, &st.pin,
		&st.holdsCursor, &st.lapEligible, &lapSkipped, &st.lapsCompleted, &st.lastLapCompletedAt, &st.lastLapEligible, &lastSkipped)
	if errors.Is(err, sql.ErrNoRows) {
		return st, nil
	}
	if err != nil {
		return st, err
	}
	_ = json.Unmarshal([]byte(lapSkipped), &st.lapSkipped)
	_ = json.Unmarshal([]byte(lastSkipped), &st.lastLapSkipped)
	if st.lapSkipped == nil {
		st.lapSkipped = map[string]int{}
	}
	if st.lastLapSkipped == nil {
		st.lastLapSkipped = map[string]int{}
	}
	return st, nil
}

func (s *Store) saveRetentionLapState(ctx context.Context, st retentionLapState) error {
	lapSkipped, err := json.Marshal(st.lapSkipped)
	if err != nil {
		return err
	}
	lastSkipped, err := json.Marshal(st.lastLapSkipped)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO settlement_evidence_retention_state (
    id, scan_cursor_credit_id, archived_low_watermark_credit_id, lap_start_credit_id, lap_hold_credit_id,
    lap_holds_cursor, lap_eligible_requests, lap_skipped_json, laps_completed, last_lap_completed_at_utc,
    last_lap_eligible_requests, last_lap_skipped_json, updated_at_utc
) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    scan_cursor_credit_id = excluded.scan_cursor_credit_id,
    archived_low_watermark_credit_id = excluded.archived_low_watermark_credit_id,
    lap_start_credit_id = excluded.lap_start_credit_id,
    lap_hold_credit_id = excluded.lap_hold_credit_id,
    lap_holds_cursor = excluded.lap_holds_cursor,
    lap_eligible_requests = excluded.lap_eligible_requests,
    lap_skipped_json = excluded.lap_skipped_json,
    laps_completed = excluded.laps_completed,
    last_lap_completed_at_utc = excluded.last_lap_completed_at_utc,
    last_lap_eligible_requests = excluded.last_lap_eligible_requests,
    last_lap_skipped_json = excluded.last_lap_skipped_json,
    updated_at_utc = excluded.updated_at_utc`,
		st.cursor, st.watermark, st.lapStart, st.pin, st.holdsCursor, st.lapEligible, string(lapSkipped), st.lapsCompleted,
		st.lastLapCompletedAt, st.lastLapEligible, string(lastSkipped), sqliteTimeText(s.nowUTC()))
	return err
}

// evidenceExecer is a database handle or a transaction connection.
type evidenceExecer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// lowerRetentionWatermark moves the watermark below creditID when an archive
// whose requests are not otherwise tracked failed. It also pins the current
// lap, so its completion cannot move the watermark past them again.
func lowerRetentionWatermark(ctx context.Context, e evidenceExecer, creditID int64, stamp string) error {
	if creditID < 1 {
		creditID = 1
	}
	_, err := e.ExecContext(ctx, `
UPDATE settlement_evidence_retention_state
   SET lap_hold_credit_id = CASE WHEN lap_hold_credit_id = 0 OR ? < lap_hold_credit_id THEN ? ELSE lap_hold_credit_id END,
       archived_low_watermark_credit_id = MIN(archived_low_watermark_credit_id, ?),
       updated_at_utc = ?
 WHERE id = 1`, creditID, creditID, creditID-1, stamp)
	return err
}

// retentionHold is one row of the holds table: a request below the watermark
// that may still become eligible, re-checked at the start of every lap.
type retentionHold struct {
	requestID string
	creditID  int64
	reason    string
}

// upsertRetentionHold records or refreshes a hold, keeping the lowest credit.
func upsertRetentionHold(ctx context.Context, e evidenceExecer, h retentionHold, stamp string) error {
	_, err := e.ExecContext(ctx, `
INSERT INTO settlement_evidence_retention_holds (request_id, credit_id, reason, held_at_utc)
VALUES (?, ?, ?, ?)
ON CONFLICT(request_id) DO UPDATE SET
    credit_id = MIN(credit_id, excluded.credit_id),
    reason = excluded.reason,
    held_at_utc = excluded.held_at_utc`, h.requestID, h.creditID, h.reason, stamp)
	return err
}

func deleteRetentionHold(ctx context.Context, e evidenceExecer, requestID string) error {
	_, err := e.ExecContext(ctx, `DELETE FROM settlement_evidence_retention_holds WHERE request_id = ?`, requestID)
	return err
}

func minCreditID(ids []int64) int64 {
	var m int64
	for _, id := range ids {
		if m == 0 || id < m {
			m = id
		}
	}
	return m
}

// retentionScanPass is the outcome of one selection pass.
type retentionScanPass struct {
	selected int
	from     int64
	// next is where the following pass resumes, unless the pass wrapped.
	next    int64
	wrapped bool
	// lastRead is the highest credit id the pass read.
	lastRead int64
	// minSelected is the lowest credit id of a request the ledger scan
	// emitted (held requests re-selected from the holds table keep their
	// hold row until deleted, so they do not count); pin is the lowest
	// frontier credit (0: none).
	minSelected int64
	pin         int64
	// holdsCursor is the holds re-check position after the pass.
	holdsCursor int64
	skipped     map[string]int
	// budgetSpent: the pass stopped early at the run deadline.
	budgetSpent bool
}

// selectRetentionCandidates selects one archive's worth of eligible
// requests and hands each bundle to emit as soon as it is evaluated (memory
// holds one request's evidence at a time). At a lap's start it first
// re-checks the holds table; then it walks ledger credits by primary key
// from the lap cursor, bounded by MaxScanRowsPerRun across the run (counted
// in report.ScannedCredits). A pass ends at the archive cap
// (MaxRequestsPerArchive), the scan bound, the deadline (checked per chunk;
// zero means none), or the end of the ledger (wrapped). With persist false
// (dry run) nothing is written.
func (s *Store) selectRetentionCandidates(ctx context.Context, opts EvidenceRetentionOptions, cut evidenceRetentionCutoffs, report *EvidenceRetentionReport, deadline time.Time, persist bool, emit func(requestEvidenceBundle) error) (retentionScanPass, error) {
	st, err := loadRetentionLapState(ctx, s.reader())
	if err != nil {
		return retentionScanPass{}, err
	}
	cursor, lapStart, holdsCursor := st.cursor, st.lapStart, st.holdsCursor
	if lapStart < 0 {
		cursor, lapStart, holdsCursor = st.watermark, st.watermark, 0
	}
	pass := retentionScanPass{from: cursor, next: cursor, holdsCursor: holdsCursor, skipped: map[string]int{}}
	stamp := sqliteTimeText(s.nowUTC())
	var upserts []retentionHold
	var deletes []string
	flush := func() error {
		if !persist || (len(upserts) == 0 && len(deletes) == 0) {
			upserts, deletes = nil, nil
			return nil
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer func() { _ = tx.Rollback() }()
		for _, h := range upserts {
			if err := upsertRetentionHold(ctx, tx, h, stamp); err != nil {
				return err
			}
		}
		for _, id := range deletes {
			if err := deleteRetentionHold(ctx, tx, id); err != nil {
				return err
			}
		}
		upserts, deletes = nil, nil
		return tx.Commit()
	}
	countSkip := func(reason string) {
		report.SkippedRequests[reason]++
		pass.skipped[reason]++
	}
	pinAt := func(id int64) {
		if pass.pin == 0 || id < pass.pin {
			pass.pin = id
		}
	}
	timeUp := func() bool {
		if !deadline.IsZero() && !s.nowUTC().Before(deadline) {
			pass.budgetSpent = true
			return true
		}
		return false
	}
	first := &providerFirstVerifiedVerdicts{q: s.reader(), cache: map[string]int64{}}
	journalDB := s.routeSnapshotJournalDB.Load()
	// evaluate collects one request and runs the R-15.2 predicate; ok means
	// it was emitted. With precheckFinality (a hold that only the deletion
	// re-check refused, because its settlement finality was still open) the
	// finality is read first, so a request that would be refused again is
	// neither re-archived nor counted as eligible.
	evaluate := func(requestID string, precheckFinality bool) (bool, string, error) {
		b, err := collectRequestEvidence(ctx, s.reader(), requestID)
		if err != nil {
			return false, "", err
		}
		if len(b.credits) == 0 {
			return false, retentionSkipNoCredit, nil
		}
		if archivedAny, err := s.anyCreditArchived(ctx, s.reader(), b); err != nil {
			return false, "", err
		} else if archivedAny {
			return false, retentionSkipAlreadyArchived, nil
		}
		if err := collectRouteJournal(ctx, journalDB, &b); err != nil {
			return false, "", err
		}
		firstVerified, err := first.forBundle(ctx, b)
		if err != nil {
			return false, "", err
		}
		if ok, reason := evaluateRetentionEligibility(b, cut, firstVerified, true); !ok {
			return false, reason, nil
		}
		if precheckFinality && persist {
			req := archivedRequest{RequestID: requestID, Rows: map[string][]archiveRow{
				"settlement_route_snapshots": b.evidence["settlement_route_snapshots"],
			}}
			if _, frozen, err := frozenRequestFinalityFunc(s, ctx, req, s.nowUTC().UnixMilli()); err != nil {
				return false, "", err
			} else if !frozen {
				return false, retentionSkipFinalityOpen, nil
			}
		}
		if err := emit(b); err != nil {
			return false, "", err
		}
		pass.selected++
		return true, "", nil
	}

	// Phase 1: re-check the holds at or below the lap start.
	for pass.holdsCursor >= 0 && pass.selected < opts.MaxRequestsPerArchive {
		if err := ctx.Err(); err != nil {
			return retentionScanPass{}, err
		}
		if timeUp() {
			break
		}
		holds, err := queryRetentionHolds(ctx, s.reader(), pass.holdsCursor, lapStart, evidenceRetentionScanChunk)
		if err != nil {
			return retentionScanPass{}, err
		}
		capped := false
		for _, h := range holds {
			if pass.selected >= opts.MaxRequestsPerArchive {
				capped = true
				break
			}
			ok, reason, err := evaluate(h.requestID, h.reason == retentionSkipFinalityOpen)
			if err != nil {
				return retentionScanPass{}, err
			}
			pass.holdsCursor = h.creditID
			switch {
			case ok:
				// The hold row stays until the delete transaction removes it.
			case retentionPermanentSkips[reason]:
				countSkip(reason)
				deletes = append(deletes, h.requestID)
			default:
				countSkip(reason)
				if reason != h.reason {
					upserts = append(upserts, retentionHold{requestID: h.requestID, creditID: h.creditID, reason: reason})
				}
			}
		}
		if err := flush(); err != nil {
			return retentionScanPass{}, err
		}
		if !capped && len(holds) < evidenceRetentionScanChunk {
			pass.holdsCursor = -1
		}
	}

	// Phase 2: walk the ledger from the lap cursor.
	seen := map[string]bool{}
	next := cursor
	for pass.holdsCursor < 0 && report.ScannedCredits < int64(opts.MaxScanRowsPerRun) && pass.selected < opts.MaxRequestsPerArchive {
		if err := ctx.Err(); err != nil {
			return retentionScanPass{}, err
		}
		if timeUp() {
			break
		}
		limit := evidenceRetentionScanChunk
		if remaining := int64(opts.MaxScanRowsPerRun) - report.ScannedCredits; remaining < int64(limit) {
			limit = int(remaining)
		}
		// A credit created at or after the finality point is pinned without
		// reading its bundle; a request already held below the lap start is
		// phase 1's.
		rows, err := s.reader().QueryContext(ctx, `
SELECT lrc.id, lrc.request_id, lrc.ts_utc,
       EXISTS (SELECT 1 FROM settlement_evidence_archived_credits a WHERE a.request_credit_id = lrc.id),
       COALESCE(h.credit_id <= ?, 0), COALESCE(h.reason, '')
  FROM ledger_request_credits lrc
  LEFT JOIN settlement_evidence_retention_holds h ON h.request_id = lrc.request_id
 WHERE lrc.id > ?
 ORDER BY lrc.id
 LIMIT ?`, lapStart, next, limit)
		if err != nil {
			return retentionScanPass{}, err
		}
		type candidate struct {
			requestID  string
			creditID   int64
			holdReason string
		}
		var candidates []candidate
		n := 0
		for rows.Next() {
			var id int64
			var requestID, ts, holdReason string
			var archived, heldBelow bool
			if err := rows.Scan(&id, &requestID, &ts, &archived, &heldBelow, &holdReason); err != nil {
				rows.Close()
				return retentionScanPass{}, err
			}
			n++
			next = id
			pass.lastRead = id
			if archived || heldBelow || seen[requestID] {
				continue
			}
			parsed, perr := time.Parse(time.RFC3339Nano, strings.TrimSpace(ts))
			switch {
			case perr != nil:
				// An unreadable timestamp is not "young"; hold it rather than
				// pin the watermark.
				seen[requestID] = true
				countSkip(retentionSkipInsideReconcile)
				upserts = append(upserts, retentionHold{requestID: requestID, creditID: id, reason: retentionSkipInsideReconcile})
				continue
			case !parsed.Before(cut.creditBefore):
				// Created at or after the finality point: the frontier.
				pinAt(id)
				continue
			}
			seen[requestID] = true
			candidates = append(candidates, candidate{requestID: requestID, creditID: id, holdReason: holdReason})
		}
		if err := rows.Close(); err != nil {
			return retentionScanPass{}, err
		}
		report.ScannedCredits += int64(n)
		capped := false
		for _, cand := range candidates {
			if pass.selected >= opts.MaxRequestsPerArchive {
				// Resume the next pass at the first candidate not evaluated.
				next = cand.creditID - 1
				capped = true
				break
			}
			ok, reason, err := evaluate(cand.requestID, cand.holdReason == retentionSkipFinalityOpen)
			if err != nil {
				return retentionScanPass{}, err
			}
			switch {
			case ok:
				if pass.minSelected == 0 || cand.creditID < pass.minSelected {
					pass.minSelected = cand.creditID
				}
			case retentionPermanentSkips[reason]:
				countSkip(reason)
			case retentionFrontierSkips[reason]:
				countSkip(reason)
				pinAt(cand.creditID)
			default:
				countSkip(reason)
				upserts = append(upserts, retentionHold{requestID: cand.requestID, creditID: cand.creditID, reason: reason})
			}
		}
		if err := flush(); err != nil {
			return retentionScanPass{}, err
		}
		if capped {
			break
		}
		if n < limit {
			pass.wrapped = true
			break
		}
	}
	pass.next = next
	return pass, nil
}

// queryRetentionHolds reads up to limit holds with credit_id in (after, upTo].
func queryRetentionHolds(ctx context.Context, q evidenceQueryer, after, upTo int64, limit int) ([]retentionHold, error) {
	rows, err := q.QueryContext(ctx, `
SELECT request_id, credit_id, reason FROM settlement_evidence_retention_holds
 WHERE credit_id > ? AND credit_id <= ?
 ORDER BY credit_id
 LIMIT ?`, after, upTo, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []retentionHold
	for rows.Next() {
		var h retentionHold
		if err := rows.Scan(&h.requestID, &h.creditID, &h.reason); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// saveRetentionPass folds one selection pass into the persisted lap. When the
// pass reached the end of the ledger, the lap completes: the watermark moves
// to the lap's end, kept below the frontier pin, the lowest credit the scan
// selected, and the lowest credit of any pending archive; the next lap
// starts there and re-checks the holds first. It returns the state after the
// pass and whether a lap completed.
func (s *Store) saveRetentionPass(ctx context.Context, pass retentionScanPass) (retentionLapState, bool, error) {
	st, err := loadRetentionLapState(ctx, s.db)
	if err != nil {
		return st, false, err
	}
	if st.lapStart < 0 {
		st.lapStart = st.watermark
	}
	st.holdsCursor = pass.holdsCursor
	if pass.pin > 0 && (st.pin == 0 || pass.pin < st.pin) {
		st.pin = pass.pin
	}
	st.lapEligible += int64(pass.selected)
	for reason, n := range pass.skipped {
		st.lapSkipped[reason] += n
	}
	if !pass.wrapped {
		st.cursor = pass.next
		return st, false, s.saveRetentionLapState(ctx, st)
	}
	w := max(pass.lastRead, st.cursor, st.lapStart)
	lower := func(credit int64) {
		if credit > 0 && credit-1 < w {
			w = credit - 1
		}
	}
	lower(st.pin)
	lower(pass.minSelected)
	var pendingMin sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `
SELECT MIN(min_credit_id) FROM settlement_evidence_archives
 WHERE status IN ('exported','offhost_verified') AND min_credit_id > 0`).Scan(&pendingMin); err != nil {
		return st, false, err
	}
	if pendingMin.Valid {
		lower(pendingMin.Int64)
	}
	st.watermark, st.cursor, st.lapStart, st.pin, st.holdsCursor = w, w, w, 0, 0
	st.lapsCompleted++
	st.lastLapCompletedAt = sqliteTimeText(s.nowUTC())
	st.lastLapEligible = st.lapEligible
	st.lastLapSkipped = st.lapSkipped
	st.lapEligible, st.lapSkipped = 0, map[string]int{}
	return st, true, s.saveRetentionLapState(ctx, st)
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

// DryRunEvidenceRetention reports what the next new archive would hold, per
// table, without writing anything (SPEC-022 R-15.8). A pending archive, which
// a run resumes first, is not included.
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
	pass, err := s.selectRetentionCandidates(ctx, opts, cut, &report, time.Time{}, false, func(b requestEvidenceBundle) error {
		addRetentionStats(&report, b)
		return nil
	})
	if err != nil {
		return report, err
	}
	report.ScanFromCreditID, report.ScanToCreditID, report.ScanWrapped = pass.from, pass.next, pass.wrapped
	report.EligibleRequests = pass.selected
	if err := s.fillRetentionLapReport(ctx, &report); err != nil {
		return report, err
	}
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

// fillRetentionLapReport copies the persisted lap state into the report.
func (s *Store) fillRetentionLapReport(ctx context.Context, report *EvidenceRetentionReport) error {
	st, err := loadRetentionLapState(ctx, s.reader())
	if err != nil {
		return err
	}
	report.WatermarkCreditID = st.watermark
	report.LapsCompleted = st.lapsCompleted
	report.LapEligibleRequests = st.lapEligible
	report.LastLapCompletedAtUTC = st.lastLapCompletedAt
	report.LastLapEligibleRequests = st.lastLapEligible
	if len(st.lastLapSkipped) > 0 {
		report.LastLapSkippedRequests = st.lastLapSkipped
	}
	report.BacklogDrained = st.lapsCompleted > 0 && st.lastLapEligible == 0
	return s.reader().QueryRowContext(ctx, `SELECT COUNT(*) FROM settlement_evidence_retention_holds`).Scan(&report.HeldRequests)
}

// RunEvidenceRetention drains settled evidence: it resumes or creates an
// archive, re-verifies it, confirms the off-host copy, deletes in short
// batches, and repeats with the next archive until a scan lap finds no
// eligible request, the scan bound is reached, a refusal stops it, or the
// run budget is spent. It then reclaims space with incremental vacuum.
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
	deadline := now.Add(opts.RunBudget)
	report = newEvidenceRetentionReport(false, now)
	report.BacklogCandidateCredits = -1
	defer func() {
		report.FinishedAtUTC = sqliteTimeText(s.nowUTC())
		if err != nil {
			report.Error = err.Error()
			// Status stays as the failure left it; Archives and
			// DeletedRequests count what the run deleted first.
			_ = s.fillRetentionLapReport(context.WithoutCancel(ctx), &report)
		}
		s.setLastEvidenceRetentionReport(report)
	}()
	pr := retentionRunProgress{firstPass: true}
	for report.StopReason == "" {
		if !s.nowUTC().Before(deadline) {
			report.StopReason = EvidenceRetentionStopBudget
			break
		}
		// A SIGHUP that disables retention stops the run between archives.
		if current, ok := s.evidenceRetentionOptions(); ok && !current.Enabled {
			return report, ErrEvidenceRetentionDisabled
		}
		if err := s.runEvidenceRetentionPass(ctx, opts, deadline, &report, &pr); err != nil {
			return report, err
		}
	}
	switch {
	case report.StopReason == EvidenceRetentionStopRefused:
		// Status already names the refusal; Archives and DeletedRequests
		// still count what the run deleted before it.
	case report.DeletedRequests > 0 || report.Archives > 0:
		report.Status = EvidenceRetentionStatusDeleted
	case report.StopReason == EvidenceRetentionStopBudget:
		report.Status = EvidenceRetentionStatusBudgetSpent
	default:
		report.Status = EvidenceRetentionStatusNothingEligible
	}
	if err := s.fillRetentionLapReport(ctx, &report); err != nil {
		return report, err
	}
	report.BacklogCandidateCredits = s.countRetentionBacklogCredits(ctx, opts, report.WatermarkCreditID)
	report.Vacuum = s.incrementalVacuumAll(ctx, opts)
	return report, nil
}

// retentionRunProgress is one run's pass bookkeeping.
type retentionRunProgress struct {
	firstPass bool
	lapDone   bool
}

// runEvidenceRetentionPass handles one archive: the pending one, or a new
// one selected from the ledger. It sets report.StopReason when the run must
// end.
func (s *Store) runEvidenceRetentionPass(ctx context.Context, opts EvidenceRetentionOptions, deadline time.Time, report *EvidenceRetentionReport, pr *retentionRunProgress) error {
	archive, resumed, err := s.pendingEvidenceArchive(ctx, opts)
	if err != nil {
		return err
	}
	if archive == nil {
		if report.ScannedCredits >= int64(opts.MaxScanRowsPerRun) {
			report.StopReason = EvidenceRetentionStopScanBound
			return nil
		}
		// A new archive needs room: refuse below the free-space floor rather
		// than fill the filesystem the coordinator may share.
		free, total, err := archiveFilesystemSpaceFunc(opts.ArchiveDir)
		if err != nil {
			return err
		}
		report.ArchiveFreeBytes, report.ArchiveDiskBytes = free, total
		if reason := archiveDiskBelowFloor(free, total, opts); reason != "" {
			report.Status = EvidenceRetentionStatusArchiveDiskLow
			report.StopReason = EvidenceRetentionStopRefused
			report.Error = reason
			return nil
		}
		now := s.nowUTC()
		cut, err := s.evidenceRetentionCutoffsAt(ctx, opts, now)
		if err != nil {
			return err
		}
		fillCutoffs(report, cut)
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
		scannedBefore := report.ScannedCredits
		pass, err := s.selectRetentionCandidates(ctx, opts, cut, report, deadline, true, func(b requestEvidenceBundle) error {
			if w == nil {
				created, err := newEvidenceArchiveWriter(opts.ArchiveDir, now, sqliteTimeText(cut.windowEnd))
				if err != nil {
					return err
				}
				created.setSpaceGuard(evidenceArchiveSpaceCheckBytes, spaceGuard)
				w = created
			}
			addRetentionStats(report, b)
			return w.writeRequest(b)
		})
		if err != nil {
			// The partial archive is removed and the lap state is not
			// advanced, so the next pass re-selects the same requests.
			w.abort()
			if errors.Is(err, errEvidenceArchiveDiskLow) {
				report.Status = EvidenceRetentionStatusArchiveDiskLow
				report.StopReason = EvidenceRetentionStopRefused
				report.Error = err.Error()
				return nil
			}
			return err
		}
		// The archive is recorded before the lap state moves past its
		// requests: a failure here leaves the lap where it was, so the next
		// pass re-selects them; a crash after it leaves a pending archive,
		// which the next run resumes and which keeps the watermark below it.
		if pass.selected > 0 {
			report.EligibleRequests += pass.selected
			archive, err = s.recordEvidenceArchive(ctx, w, pass.minSelected)
			if errors.Is(err, errEvidenceArchiveDiskLow) {
				// finish() removed the partial archive.
				report.Status = EvidenceRetentionStatusArchiveDiskLow
				report.StopReason = EvidenceRetentionStopRefused
				report.Error = err.Error()
				return nil
			}
			if err != nil {
				return err
			}
		}
		lap, lapDone, err := s.saveRetentionPass(ctx, pass)
		if err != nil {
			return err
		}
		if pr.firstPass {
			report.ScanFromCreditID = pass.from
			pr.firstPass = false
		}
		report.ScanToCreditID = lap.cursor
		report.ScanWrapped = report.ScanWrapped || lapDone
		pr.lapDone = lapDone
		if pass.selected == 0 {
			switch {
			case lapDone && lap.lastLapEligible == 0:
				report.StopReason = EvidenceRetentionStopDrained
			case lapDone:
				report.StopReason = EvidenceRetentionStopLapComplete
			case pass.budgetSpent:
				report.StopReason = EvidenceRetentionStopBudget
			case report.ScannedCredits >= int64(opts.MaxScanRowsPerRun):
				report.StopReason = EvidenceRetentionStopScanBound
			case report.ScannedCredits == scannedBefore && !pass.wrapped:
				// Defensive: a pass that neither scanned nor wrapped cannot
				// make progress, so the run never spins.
				report.StopReason = EvidenceRetentionStopScanBound
			}
			return nil
		}
	}
	report.ResumedArchive = report.ResumedArchive || resumed
	report.ArchiveID = archive.id
	report.ArchiveFile = archive.fileName
	report.ArchiveSHA256 = archive.manifest.SHA256
	report.ArchiveBytes = archive.manifest.SizeBytes
	verified, err := verifyEvidenceArchive(filepath.Join(opts.ArchiveDir, archive.fileName), archive.manifest)
	if err != nil {
		report.Status = EvidenceRetentionStatusArchiveInvalid
		// The failed archive's requests stay hot; a later lap re-selects them.
		return errors.Join(err, s.failEvidenceArchive(ctx, archive, err))
	}
	if resumed {
		report.EligibleRequests += verified.Manifest.RequestCount
	}
	// The local re-read above is the verification deletion requires. An
	// off-host verification command, when configured, is one more check
	// that must pass first.
	if archive.status != evidenceArchiveStatusOffhostVerified && opts.OffhostVerifier != nil {
		if verr := opts.OffhostVerifier(ctx, verified.Path, verified.Manifest.SHA256); verr != nil {
			report.Status = EvidenceRetentionStatusOffhostUnverified
			report.StopReason = EvidenceRetentionStopRefused
			report.Error = verr.Error()
			_ = s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusExported, verr.Error(), 0)
			return nil
		}
		if err := s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusOffhostVerified, "", 0); err != nil {
			return err
		}
	}
	deleted, err := s.deleteArchivedEvidence(ctx, opts, archive.id, verified, deadline, report)
	report.DeletedRequests += deleted
	if errors.Is(err, errEvidenceRetentionBudgetSpent) {
		// The archive stays pending; the next run resumes it.
		report.StopReason = EvidenceRetentionStopBudget
		return nil
	}
	if err != nil {
		if errors.Is(err, ErrEvidenceArchiveInvalid) {
			report.Status = EvidenceRetentionStatusArchiveInvalid
			return errors.Join(err, s.failEvidenceArchive(ctx, archive, err))
		}
		return err
	}
	if err := s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusDeleted, "", 0); err != nil {
		return err
	}
	report.Archives++
	if pr.lapDone {
		report.StopReason = EvidenceRetentionStopLapComplete
	}
	return nil
}

// failEvidenceArchive marks an archive failed and moves the watermark back
// below the requests its ledger scan selected (held requests in it keep
// their hold rows). Archives recorded before #1979 carry no credit id; the
// first lap after the upgrade starts at credit 0 anyway.
func (s *Store) failEvidenceArchive(ctx context.Context, archive *evidenceArchiveRecord, cause error) error {
	// The fallback must land even when the run's context was cancelled.
	ctx = context.WithoutCancel(ctx)
	err := s.updateEvidenceArchiveStatus(ctx, archive.id, evidenceArchiveStatusFailed, cause.Error(), 0)
	if archive.minCreditID > 0 {
		err = errors.Join(err, lowerRetentionWatermark(ctx, s.db, archive.minCreditID, sqliteTimeText(s.nowUTC())))
	}
	return err
}

// countRetentionBacklogCredits counts the held requests at or below the
// watermark and the unarchived ledger credits above it that were created
// before the finality point and are either unsettled and unquarantined or
// settled into a live payout: an upper bound of the eligible backlog. It
// reads fixed id ranges, so no statement walks far past its range, under its
// own timeout, and returns -1 when the count does not finish.
func (s *Store) countRetentionBacklogCredits(ctx context.Context, opts EvidenceRetentionOptions, watermark int64) int64 {
	ctx, cancel := context.WithTimeout(ctx, evidenceRetentionBacklogTimeout)
	defer cancel()
	cut, err := s.evidenceRetentionCutoffsAt(ctx, opts, s.nowUTC())
	if err != nil {
		return -1
	}
	var maxID sql.NullInt64
	if err := s.reader().QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
		return -1
	}
	// Held requests at or below the watermark are counted from the holds
	// table, so the count never walks the archived prefix.
	var count int64
	if err := s.reader().QueryRowContext(ctx, `SELECT COUNT(*) FROM settlement_evidence_retention_holds WHERE credit_id <= ?`, watermark).Scan(&count); err != nil {
		return -1
	}
	for lo := watermark; maxID.Valid && lo < maxID.Int64; lo += evidenceRetentionScanChunk {
		rows, err := s.reader().QueryContext(ctx, `
SELECT lrc.ts_utc
  FROM ledger_request_credits lrc
  LEFT JOIN ledger_payout_ready p ON p.id = lrc.settlement_id
 WHERE lrc.id > ? AND lrc.id <= ?
   AND lrc.quarantined = 0
   AND ((lrc.settled = 0 AND lrc.settlement_id IS NULL)
        OR (lrc.settled = 1 AND p.status IN ('ready','consumed')))
   AND NOT EXISTS (SELECT 1 FROM settlement_evidence_archived_credits a WHERE a.request_credit_id = lrc.id)`,
			lo, lo+evidenceRetentionScanChunk)
		if err != nil {
			return -1
		}
		for rows.Next() {
			var ts string
			if err := rows.Scan(&ts); err != nil {
				rows.Close()
				return -1
			}
			credited, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(ts))
			if err != nil || !credited.Before(cut.creditBefore) {
				continue
			}
			count++
		}
		if err := rows.Close(); err != nil {
			return -1
		}
	}
	return count
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
	// minCreditID is the archive's lowest ledger credit id (0: recorded
	// before #1979).
	minCreditID int64
}

// pendingEvidenceArchive returns the oldest archive that was exported but
// not yet deleted, so a refused or interrupted run resumes it instead of
// writing a duplicate.
func (s *Store) pendingEvidenceArchive(ctx context.Context, opts EvidenceRetentionOptions) (*evidenceArchiveRecord, bool, error) {
	var rec evidenceArchiveRecord
	var countsJSON string
	err := s.db.QueryRowContext(ctx, `
SELECT id, file_name, status, sha256, size_bytes, request_count, row_counts_json, cutoff_window_end_utc, created_at_utc, min_credit_id
  FROM settlement_evidence_archives
 WHERE status IN ('exported','offhost_verified')
 ORDER BY id
 LIMIT 1`).Scan(&rec.id, &rec.fileName, &rec.status, &rec.manifest.SHA256, &rec.manifest.SizeBytes, &rec.manifest.RequestCount, &countsJSON, &rec.manifest.CutoffWindowEndUTC, &rec.manifest.CreatedAtUTC, &rec.minCreditID)
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
func (s *Store) recordEvidenceArchive(ctx context.Context, w *evidenceArchiveWriter, minCreditID int64) (*evidenceArchiveRecord, error) {
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
    cutoff_window_end_utc, status, created_at_utc, updated_at_utc, min_credit_id
) VALUES (?, ?, ?, ?, ?, ?, 'exported', ?, ?, ?)`,
		manifest.ArchiveFile, manifest.SHA256, manifest.SizeBytes, manifest.RequestCount, string(countsJSON),
		manifest.CutoffWindowEndUTC, stamp, stamp, minCreditID)
	if err != nil {
		// Keep the durable file: it is harmless and the next run re-selects.
		return nil, fmt.Errorf("record archive %s: %w", filepath.Base(path), err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &evidenceArchiveRecord{id: id, fileName: manifest.ArchiveFile, status: evidenceArchiveStatusExported, manifest: manifest, minCreditID: minCreditID}, nil
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

// deleteArchivedEvidence deletes, batch by batch, only rows present in the
// verified archive. It re-reads the archive as a stream and holds one batch
// (batch_size requests, at most evidenceRetentionBatchBytes of archived
// payload) at a time; every re-read request must match the digest of the
// verified pass, so a file changed since verification deletes nothing. Each
// batch is one short BEGIN IMMEDIATE transaction that re-checks R-15.2 for
// every request; the run then pauses so the hot-path writer is never starved.
func (s *Store) deleteArchivedEvidence(ctx context.Context, opts EvidenceRetentionOptions, archiveID int64, archive verifiedEvidenceArchive, deadline time.Time, report *EvidenceRetentionReport) (int, error) {
	now := s.nowUTC()
	cut, err := s.evidenceRetentionCutoffsAt(ctx, opts, now)
	if err != nil {
		return 0, err
	}
	fillCutoffs(report, cut)
	journalDB := s.routeSnapshotJournalDB.Load()
	deleted := 0
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
		// The budget is checked at batch boundaries only; an archive cut
		// short stays pending and the next run resumes it.
		if !s.nowUTC().Before(deadline) {
			return errEvidenceRetentionBudgetSpent
		}
		// Pause before every batch but the run's first, across archives too.
		if report.DeleteBatches > 0 && opts.BatchPause > 0 {
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
			frozen, ok, err := frozenRequestFinalityFunc(s, ctx, req, s.nowUTC().UnixMilli())
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
		batch, batchBytes = nil, 0
		// Journal copies go after the main rows commit. Requests this archive
		// tombstoned in an earlier, interrupted run are in cleanup too, so the
		// journal step is retried until the archive is marked deleted.
		return deleteArchivedRouteJournalRows(ctx, journalDB, cleanup, report)
	}
	// Requests this archive already tombstoned (a resumed archive) need only
	// the journal step: they skip the delete transaction and the batch
	// pause, so a resumed run spends its budget on new deletions.
	var cleanupOnly []archivedRequest
	flushCleanup := func() error {
		if len(cleanupOnly) == 0 {
			return nil
		}
		err := deleteArchivedRouteJournalRows(ctx, journalDB, cleanupOnly, report)
		cleanupOnly = nil
		return err
	}
	err = streamEvidenceArchive(archive.Path, archive.Manifest, func(req archivedRequest) error {
		if want, ok := archive.Digests[req.RequestID]; !ok || want != req.Digest {
			return fmt.Errorf("%w: request %q changed since verification", ErrEvidenceArchiveInvalid, req.RequestID)
		}
		tombstoned, err := s.requestTombstonedByArchive(ctx, archiveID, req)
		if err != nil {
			return err
		}
		if tombstoned {
			cleanupOnly = append(cleanupOnly, req)
			if len(cleanupOnly) >= opts.BatchSize {
				return flushCleanup()
			}
			return nil
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
	if err := flushCleanup(); err != nil {
		return deleted, err
	}
	return deleted, runBatch()
}

// requestTombstonedByArchive reports whether every ledger credit of the
// request is the archived set and was tombstoned by this archive.
func (s *Store) requestTombstonedByArchive(ctx context.Context, archiveID int64, req archivedRequest) (bool, error) {
	if len(req.CreditIDs) == 0 {
		return false, nil
	}
	var hot, tombstoned int
	err := s.db.QueryRowContext(ctx, `
SELECT (SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?),
       (SELECT COUNT(*) FROM settlement_evidence_archived_credits WHERE request_id = ? AND archive_id = ?)`,
		req.RequestID, req.RequestID, archiveID).Scan(&hot, &tombstoned)
	if err != nil {
		return false, err
	}
	return hot == len(req.CreditIDs) && tombstoned == len(req.CreditIDs), nil
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
	floorRecorded, earlyFloorRecorded := false, false
	// A request this batch keeps hot for a reason that can clear goes to the
	// holds table, in the same transaction; a deleted one leaves it.
	held := func(req archivedRequest, reason string) error {
		report.SkippedRequests[reason]++
		if retentionPermanentSkips[reason] {
			return deleteRetentionHold(ctx, conn, req.RequestID)
		}
		return upsertRetentionHold(ctx, conn, retentionHold{requestID: req.RequestID, creditID: minCreditID(req.CreditIDs), reason: reason}, stamp)
	}
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
			} else if err := held(req, retentionSkipAlreadyArchived); err != nil {
				return nil, nil, err
			}
			continue
		}
		if !journalOK[req.RequestID] {
			if err := held(req, retentionSkipRouteJournal); err != nil {
				return nil, nil, err
			}
			continue
		}
		firstVerified, err := first.forBundle(ctx, b)
		if err != nil {
			return nil, nil, err
		}
		if ok, reason := evaluateRetentionEligibility(b, cut, firstVerified, false); !ok {
			if err := held(req, reason); err != nil {
				return nil, nil, err
			}
			continue
		}
		if !sameCredits(b, req) {
			if err := held(req, retentionSkipHotRowNotArchived); err != nil {
				return nil, nil, err
			}
			continue
		}
		if reason := hotRowsMatchArchive(b, req); reason != "" {
			if err := held(req, reason); err != nil {
				return nil, nil, err
			}
			continue
		}
		frozen, ok := finalities[req.RequestID]
		if !ok {
			if err := held(req, retentionSkipFinalityOpen); err != nil {
				return nil, nil, err
			}
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
		if !earlyFloorRecorded && requestHasUnsettledCredit(b) {
			// SPEC-022 v0.4.5 R-15.9: a credit tombstoned before it settled
			// settles and reconciles only through its tombstone, which a
			// contract-4 coordinator does not do; it commits with contract 5.
			if err := recordBillingCompatFloorExec(ctx, conn, billingCompatContractEarlyArchive); err != nil {
				return nil, nil, err
			}
			earlyFloorRecorded = true
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
INSERT INTO settlement_evidence_archived_credits (request_credit_id, request_id, archive_id, spec022_verified, archived_at_utc, pool_id)
VALUES (?, ?, ?, ?, ?, ?)`, c.id, req.RequestID, archiveID, boolInt(verified), stamp, archivedCreditPoolID(c, b.evidence["settlement_route_snapshots"])); err != nil {
				return nil, nil, err
			}
		}
		if err := deleteRetentionHold(ctx, conn, req.RequestID); err != nil {
			return nil, nil, err
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
// frozenRequestFinalityFunc is the finality freeze retention uses; tests
// replace it, as with archiveFilesystemSpaceFunc.
var frozenRequestFinalityFunc = (*Store).frozenRequestFinality

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

// archivedCreditPoolID is the pool binding creator earnings read for the
// credit: the pool_id of the first route snapshot (by id) of its attempt
// that carries one, or nil.
func archivedCreditPoolID(c retentionCredit, snapshots []archiveRow) any {
	var best int64 = -1
	var pool any
	for _, srs := range snapshots {
		a, _ := srs.int64("attempt_n")
		p, _ := srs.str("provider_id")
		id, _ := srs.int64("id")
		poolID, ok := srs.str("pool_id")
		if a != c.attemptN || p != c.providerID || !ok {
			continue
		}
		if best < 0 || id < best {
			best, pool = id, poolID
		}
	}
	return pool
}

func requestHasUnsettledCredit(b requestEvidenceBundle) bool {
	for _, c := range b.credits {
		if !c.settled {
			return true
		}
	}
	return false
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

// archiveRowsEqual compares two rows column by column; numbers compare by
// value (verifiedarchive.RowsEqual).
func archiveRowsEqual(a, b archiveRow) bool {
	return verifiedarchive.RowsEqual(a, b)
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
// full VACUUM; a database outside INCREMENTAL mode skips the step, says why
// in Skipped, and (for NONE) logs that it needs the one-time conversion.
func incrementalVacuum(ctx context.Context, db *sql.DB, name string, opts EvidenceRetentionOptions) EvidenceRetentionVacuumReport {
	r := EvidenceRetentionVacuumReport{Database: name}
	var mode int
	if err := db.QueryRowContext(ctx, `PRAGMA auto_vacuum`).Scan(&mode); err != nil {
		r.AutoVacuumMode = "unknown"
		r.Skipped = "auto_vacuum mode unreadable"
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
	switch mode {
	case 2:
	case 0:
		r.ConversionNeeds = true
		r.Skipped = "auto_vacuum=NONE: incremental_vacuum releases no pages; freed pages are reused, and the file shrinks only after the operator's one-time conversion (no full VACUUM is run automatically)"
		log.Printf("settlement evidence retention: database=%s auto_vacuum=none incremental_vacuum=skipped freelist_pages=%d: needs the one-time auto_vacuum=INCREMENTAL conversion; retention never runs a full VACUUM", name, r.FreelistBefore)
		return r
	case 1:
		r.Skipped = "auto_vacuum=FULL reclaims pages at every commit"
		return r
	default:
		r.Skipped = "auto_vacuum mode not recognized"
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

// evidenceRetentionLogLine is the nightly run's log line: progress, the
// remaining backlog, and each database's auto_vacuum mode.
func evidenceRetentionLogLine(report EvidenceRetentionReport) string {
	level := "info"
	if report.Status == EvidenceRetentionStatusArchiveDiskLow {
		level = "warn"
	}
	return fmt.Sprintf("settlement evidence retention: level=%s status=%s stop_reason=%s archives=%d eligible_requests=%d deleted_requests=%d delete_batches=%d scanned_credits=%d backlog_drained=%t backlog_candidate_credits=%d held_requests=%d watermark_credit_id=%d laps_completed=%d lap_eligible_requests=%d last_lap_eligible_requests=%d last_lap_skipped=%q auto_vacuum=%s archive_bytes=%d archive_free_bytes=%d archive_disk_bytes=%d reason=%q",
		level, report.Status, report.StopReason, report.Archives, report.EligibleRequests, report.DeletedRequests, report.DeleteBatches, report.ScannedCredits, report.BacklogDrained, report.BacklogCandidateCredits, report.HeldRequests, report.WatermarkCreditID, report.LapsCompleted, report.LapEligibleRequests, report.LastLapEligibleRequests, report.LastLapSkipSummary(), report.AutoVacuumModes(), report.ArchiveBytes, report.ArchiveFreeBytes, report.ArchiveDiskBytes, report.Error)
}

// StartEvidenceRetention runs retention daily at 03:00 UTC, away from the
// 00:00 nightly reconcile and the Monday 00:00 weekly settlement, and then
// the ledger rollup. It reads the installed options on each tick and skips
// whichever is disabled.
func (s *Store) StartEvidenceRetention(ctx context.Context, logf func(EvidenceRetentionReport, error), rollupLogf ...func(LedgerRollupReport, error)) {
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
			if opts, ok := s.evidenceRetentionOptions(); ok && opts.Enabled {
				report, err := s.RunEvidenceRetention(ctx, opts)
				log.Print(evidenceRetentionLogLine(report))
				if logf != nil {
					logf(report, err)
				}
			}
			if ropts, ok := s.ledgerRollupOptions(); ok && ropts.Enabled {
				report, err := s.RunLedgerRollup(ctx, ropts)
				for _, f := range rollupLogf {
					if f != nil {
						f(report, err)
					}
				}
			}
		}
	}()
}
