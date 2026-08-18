package integration

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const (
	buyerCrashRecoveryJourneyID      = "JOURNEY-BUYER-CRASH-RECOVERY"
	buyerCrashRecoveryEvidenceSchema = "macprovider.buyer-crash-recovery-evidence.v1"
	crashRecoveryRequestID           = "crash-recovery-identity-fallback"
	crashRecoveryAssignedID          = "assigned-crash-recovery"
	crashRecoveryOrphanRequestID     = "crash-recovery-orphan-credit"
)

func TestJourneyBuyerCrashRecoveryIsolatedCandidate(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true})
	startMode, startJob := readCoordinatorSettlement(t, s.coordYAML)
	if startMode != "observe" || startJob {
		t.Fatalf("starting settlement mode=%q job_enabled=%v want observe/false", startMode, startJob)
	}
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows before journey=%d want 0", got)
	}
	scansBefore := s.startupScanCount()

	plantedAt := time.Now().UTC().Add(-2 * time.Minute)
	s.stopCoordinator()
	s.plantIdentityFallback(plantedAt)
	s.plantOrphanCredit(plantedAt)
	if got := s.creditCount(crashRecoveryRequestID, false); got != 0 {
		t.Fatalf("credits before recovery=%d want 0", got)
	}

	s.restartCoordinator()
	if got := s.creditCount(crashRecoveryRequestID, false); got != 1 {
		t.Fatalf("recovered credits=%d want 1", got)
	}
	if got := s.recoverySource(crashRecoveryRequestID); got != "startup_scan" {
		t.Fatalf("recovery_source=%q want startup_scan", got)
	}
	if got := s.startupScanCount(); got <= scansBefore {
		t.Fatalf("startup_scan runs=%d want > %d", got, scansBefore)
	}
	latest := s.latestStartupScan()
	if latest.Status != "complete" {
		t.Fatalf("latest startup_scan status=%q want complete", latest.Status)
	}
	if latest.MissingCreditRowsCreated < 1 {
		t.Fatalf("missing_credit_rows_created=%d want >=1", latest.MissingCreditRowsCreated)
	}
	if got := s.quarantinedCount(crashRecoveryOrphanRequestID, "missing_request_log"); got != 1 {
		t.Fatalf("orphan quarantined=%d want 1", got)
	}

	s.restartCoordinator()
	if got := s.creditCount(crashRecoveryRequestID, false); got != 1 {
		t.Fatalf("credits after rescan=%d want 1 (no double credit)", got)
	}
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows after journey=%d want 0", got)
	}
	endMode, endJob := readCoordinatorSettlement(t, s.coordYAML)
	if endMode != startMode || endJob != startJob || endMode != "observe" || endJob {
		t.Fatalf("settlement config drifted: start=%s/%v end=%s/%v", startMode, startJob, endMode, endJob)
	}

	if os.Getenv("MACPROVIDER_CAPTURE_BUYER_CRASH_RECOVERY") != "1" {
		return
	}
	writeBuyerCrashRecoveryEvidence(t, s, plantedAt, latest)
}

type startupScanRow struct {
	Status                      string
	MissingCreditRowsCreated    int64
	OrphanCreditRowsQuarantined int64
}

func (s *scenario) openCoordDB() *sql.DB {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	return db
}

func (s *scenario) plantIdentityFallback(ts time.Time) {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	var snapshotID int64
	if err := db.QueryRow(`SELECT id FROM ledger_config_snapshots ORDER BY id DESC LIMIT 1`).Scan(&snapshotID); err != nil {
		s.t.Fatalf("config snapshot: %v", err)
	}
	stamp := ts.UTC().Format(time.RFC3339Nano)
	if _, err := db.Exec(`
INSERT INTO request_log (
    ts_utc, request_id, external_request_id, account_id, model,
    provider_assigned_id, prompt_tokens, completion_tokens, latency_ms,
    routing_ms, status, stream, attempt_n
) VALUES (?, ?, ?, ?, ?, ?, 8, 12, 1, 1, 200, 0, 0)`,
		stamp, crashRecoveryRequestID, crashRecoveryRequestID, s.accountID,
		defaultFakeModelID, crashRecoveryAssignedID,
	); err != nil {
		s.t.Fatalf("insert request_log: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from,
    config_snapshot_id, provider_reported_prompt_tokens, created_at_utc
) VALUES (?, 0, ?, ?, 'pool_entry', ?, 8, ?)`,
		crashRecoveryRequestID, crashRecoveryAssignedID, s.providerID, snapshotID, stamp,
	); err != nil {
		s.t.Fatalf("insert identity snapshot: %v", err)
	}
}

func (s *scenario) plantOrphanCredit(ts time.Time) {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	stamp := ts.UTC().Format(time.RFC3339Nano)
	if _, err := db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc
) VALUES (?, 0, ?, 'assigned-orphan', ?, ?, 200, 0, 'provider_reported', 1, 1, 1000000, 1, 9000, 1, 'none', 'hot_path', ?)`,
		crashRecoveryOrphanRequestID, s.providerID, stamp, defaultFakeModelID, stamp,
	); err != nil {
		s.t.Fatalf("insert orphan credit: %v", err)
	}
}

func (s *scenario) creditCount(requestID string, quarantined bool) int {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	flag := 0
	if quarantined {
		flag = 1
	}
	var count int
	if err := db.QueryRow(`
SELECT COUNT(*) FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = ?`, requestID, flag).Scan(&count); err != nil {
		s.t.Fatalf("credit count: %v", err)
	}
	return count
}

func (s *scenario) recoverySource(requestID string) string {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	var source string
	if err := db.QueryRow(`
SELECT recovery_source FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 0`, requestID).Scan(&source); err != nil {
		s.t.Fatalf("recovery_source: %v", err)
	}
	return source
}

func (s *scenario) quarantinedCount(requestID, reason string) int {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	var count int
	if err := db.QueryRow(`
SELECT COUNT(*) FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = ?`, requestID, reason).Scan(&count); err != nil {
		s.t.Fatalf("quarantine count: %v", err)
	}
	return count
}

func (s *scenario) startupScanCount() int {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type = 'startup_scan'`).Scan(&count); err != nil {
		s.t.Fatalf("startup_scan count: %v", err)
	}
	return count
}

func (s *scenario) latestStartupScan() startupScanRow {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	var row startupScanRow
	if err := db.QueryRow(`
SELECT status, missing_credit_rows_created, orphan_credit_rows_quarantined
  FROM ledger_reconciliation_runs
 WHERE run_type = 'startup_scan'
 ORDER BY id DESC LIMIT 1`).Scan(&row.Status, &row.MissingCreditRowsCreated, &row.OrphanCreditRowsQuarantined); err != nil {
		s.t.Fatalf("latest startup_scan: %v", err)
	}
	return row
}

func writeBuyerCrashRecoveryEvidence(t *testing.T, s *scenario, plantedAt time.Time, scan startupScanRow) {
	t.Helper()
	root, err := findRepoRoot()
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	commit := gitHEAD(t, root)
	captured := time.Now().UTC().Truncate(time.Second)
	runID := "buyer-crash-recovery-" + captured.Format("20060102T150405Z")
	artifactRel := filepath.ToSlash(filepath.Join("journeys", "evidence", runID+".redacted.json"))
	evidence := map[string]any{
		"schema_version":  buyerCrashRecoveryEvidenceSchema,
		"journey_id":      buyerCrashRecoveryJourneyID,
		"run_id":          runID,
		"captured_at":     captured.Format("2006-01-02T15:04:05Z"),
		"requirement_ids": []string{"SPEC-005-R003"},
		"repository":      map[string]string{"name": "Augustas11/macprovider", "commit": commit},
		"observations": map[string]any{
			"settlement_mode":                "observe",
			"job_enabled":                    false,
			"payout_ready_mutated":           false,
			"identity_fallback_recovered":    true,
			"orphan_quarantined":             true,
			"idempotent_rescan":              true,
			"recovery_source":                "startup_scan",
			"planted_at":                     plantedAt.UTC().Format(time.RFC3339Nano),
			"missing_credit_rows_created":    scan.MissingCreditRowsCreated,
			"orphan_credit_rows_quarantined": scan.OrphanCreditRowsQuarantined,
		},
	}
	raw, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, artifactRel), append(raw, '\n'), 0o644); err != nil {
		t.Fatalf("write evidence: %v", err)
	}
	t.Logf("wrote %s", artifactRel)
}
