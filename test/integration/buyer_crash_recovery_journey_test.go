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

type buyerCrashRecoveryStep struct {
	ID        string         `json:"id"`
	Status    string         `json:"status"`
	Assertion string         `json:"assertion"`
	Artifacts []string       `json:"artifacts"`
	Details   map[string]any `json:"details,omitempty"`
}

func TestJourneyBuyerCrashRecoveryIsolatedCandidate(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true, settlementJobEnabled: true})
	startMode, startJob := readCoordinatorSettlement(t, s.coordYAML)
	if startMode != "observe" || !startJob {
		t.Fatalf("starting settlement mode=%q job_enabled=%v want observe/true", startMode, startJob)
	}
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows before journey=%d want 0", got)
	}
	scansBefore := s.startupScanCount()

	steps := make([]buyerCrashRecoveryStep, 0, 8)
	pass := func(id, assertion string, details map[string]any) {
		steps = append(steps, buyerCrashRecoveryStep{
			ID:        id,
			Status:    "pass",
			Assertion: assertion,
			Artifacts: []string{"redacted-buyer-crash-recovery"},
			Details:   details,
		})
	}
	pass("step-01-capture-config", "isolated candidate captured in observe mode with settlement startup recovery enabled", map[string]any{
		"settlement_mode": startMode,
		"job_enabled":     startJob,
		"isolated_sqlite": true,
	})

	plantedAt := time.Now().UTC().Add(-2 * time.Minute)
	s.stopCoordinator()
	pass("step-02-stop-coordinator", "coordinator process stopped against the same isolated SQLite file", map[string]any{
		"coordinator_stopped": true,
	})
	s.plantIdentityFallback(plantedAt)
	if got := s.creditCount(crashRecoveryRequestID, false); got != 0 {
		t.Fatalf("credits before recovery=%d want 0", got)
	}
	pass("step-03-plant-identity-fallback", "identity-fallback request_log and provider snapshot planted with no credit row", map[string]any{
		"request_id":   crashRecoveryRequestID,
		"credit_count": 0,
	})
	s.plantOrphanCredit(plantedAt)
	pass("step-04-plant-orphan-credit", "orphan ledger_request_credits row planted without matching request_log", map[string]any{
		"orphan_request_id": crashRecoveryOrphanRequestID,
	})

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
	pass("step-05-startup-scan-recover", "startup_scan recovered exactly one non-quarantined credit for the planted request", map[string]any{
		"recovery_source":             "startup_scan",
		"recovered_credits":           1,
		"missing_credit_rows_created": latest.MissingCreditRowsCreated,
		"startup_scan_status":         latest.Status,
	})
	if got := s.quarantinedCount(crashRecoveryOrphanRequestID, "missing_request_log"); got != 1 {
		t.Fatalf("orphan quarantined=%d want 1", got)
	}
	pass("step-06-orphan-quarantine", "planted orphan credit was quarantined missing_request_log", map[string]any{
		"orphan_quarantined": 1,
		"quarantine_reason":  "missing_request_log",
	})

	s.restartCoordinator()
	if got := s.creditCount(crashRecoveryRequestID, false); got != 1 {
		t.Fatalf("credits after rescan=%d want 1 (no double credit)", got)
	}
	pass("step-07-idempotent-rescan", "second startup scan did not double-credit the recovered request", map[string]any{
		"credits_after_rescan": 1,
	})
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows after journey=%d want 0", got)
	}
	endMode, endJob := readCoordinatorSettlement(t, s.coordYAML)
	if endMode != startMode || endJob != startJob || endMode != "observe" || !endJob {
		t.Fatalf("settlement config drifted: start=%s/%v end=%s/%v", startMode, startJob, endMode, endJob)
	}
	pass("step-08-no-payout", "settlement startup recovery stayed enabled and no payout-ready rows were created", map[string]any{
		"payout_ready_count": 0,
		"job_enabled":        endJob,
		"settlement_mode":    endMode,
	})

	if os.Getenv("MACPROVIDER_CAPTURE_BUYER_CRASH_RECOVERY") != "1" {
		return
	}
	writeBuyerCrashRecoveryEvidence(t, s, steps, plantedAt, latest, startMode, endMode, startJob, endJob)
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

func writeBuyerCrashRecoveryEvidence(t *testing.T, s *scenario, steps []buyerCrashRecoveryStep, plantedAt time.Time, scan startupScanRow, startMode, endMode string, startJob, endJob bool) {
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
		"expires_at":      captured.AddDate(0, 0, 30).Format("2006-01-02"),
		"requirement_ids": []string{"SPEC-005-R003"},
		"repository":      map[string]string{"name": "Augustas11/macprovider", "commit": commit},
		"operator": map[string]string{
			"role":                 "acceptance-operator",
			"identity_fingerprint": sha256Hex("isolated-candidate-crash-recovery"),
		},
		"environment": map[string]string{
			"class":            "isolated-candidate-crash-recovery",
			"hardware_profile": "local-macos-redacted",
			"candidate":        "commit:" + commit,
		},
		"harness": map[string]any{
			"id":                      "test/integration:TestJourneyBuyerCrashRecoveryIsolatedCandidate",
			"execution_mode":          "isolated-candidate-crash-recovery",
			"isolated_sqlite":         true,
			"real_binaries":           true,
			"production_side_effects": false,
			"settlement_runner":       false,
		},
		"observations": map[string]any{
			"settlement_mode":                endMode,
			"job_enabled":                    endJob,
			"payout_ready_mutated":           false,
			"production_side_effects":        false,
			"isolated_environment":           true,
			"identity_fallback_recovered":    true,
			"orphan_quarantined":             true,
			"idempotent_rescan":              true,
			"recovery_source":                "startup_scan",
			"production_pearl":               false,
			"planted_at":                     plantedAt.UTC().Format(time.RFC3339Nano),
			"missing_credit_rows_created":    scan.MissingCreditRowsCreated,
			"orphan_credit_rows_quarantined": scan.OrphanCreditRowsQuarantined,
			"start_mode":                     startMode,
			"start_job_enabled":              startJob,
		},
		"result": map[string]any{
			"status":  "pass",
			"summary": "isolated candidate crash-recovery journey recovered identity-fallback credits without double credit or payout-ready mutation",
		},
		"steps": steps,
		"redaction": map[string]any{
			"secrets_redacted":             true,
			"operator_identity_redacted":   true,
			"local_account_names_redacted": true,
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
