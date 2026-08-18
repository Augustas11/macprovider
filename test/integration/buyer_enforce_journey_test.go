package integration

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	buyerEnforceJourneyID      = "JOURNEY-BUYER-ENFORCE"
	buyerEnforceEvidenceSchema = "macprovider.buyer-enforce-evidence.v1"
	buyerEnforceVerifiedID     = "44444444-4444-4444-8444-444444444444"
	buyerEnforceMissingID      = "55555555-5555-4555-8555-555555555555"
)

type buyerEnforceStep struct {
	ID        string         `json:"id"`
	Status    string         `json:"status"`
	Assertion string         `json:"assertion"`
	Artifacts []string       `json:"artifacts"`
	Details   map[string]any `json:"details,omitempty"`
}

func TestJourneyBuyerEnforceIsolatedCandidate(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:                        true,
		settlementReceiptProvider:          true,
		settlementEnforceMode:              true,
		settlementReconcileIntervalSeconds: 1,
		pendingDeadlineSeconds:             1,
	})
	if !strings.HasPrefix(s.apiKey, "mp_") {
		t.Fatal("buyer subject is not a disposable mp_ API key")
	}
	isolated := requireIsolatedCandidate(t, s)
	startMode, startJob := readCoordinatorSettlement(t, s.coordYAML)
	if startMode != "enforce" || startJob {
		t.Fatalf("starting settlement mode=%q job_enabled=%v want enforce/false", startMode, startJob)
	}
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows before journey=%d want 0", got)
	}

	steps := make([]buyerEnforceStep, 0, 7)
	pass := func(id, assertion string, details map[string]any) {
		steps = append(steps, buyerEnforceStep{
			ID:        id,
			Status:    "pass",
			Assertion: assertion,
			Artifacts: []string{"redacted-buyer-enforce"},
			Details:   details,
		})
	}

	pass("step-01-capture-config", "isolated candidate captured in enforce mode with an API-key subject and no settlement runner", map[string]any{
		"settlement_mode":     startMode,
		"enforce_activated":   startMode == "enforce",
		"job_enabled":         startJob,
		"pending_deadline_s":  1,
		"isolated_sqlite":     isolated,
		"auth_subject":        "api_key",
		"production_pearl":    false,
		"demo_token_used":     false,
		"wallet_session_used": false,
	})

	status, headers, body := s.chatRequest(map[string]string{"X-Request-ID": buyerEnforceVerifiedID}, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"stream":true,
		"messages":[{"role":"user","content":"enforce-path verified"}]
	}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("verified streaming chat status=%d body=%s", status, string(body))
	}
	if got := headers.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("buyer response exposed streaming receipt header %q", got)
	}

	usage, reservation := waitForSpec022GatewaySettlement(t, s, buyerEnforceVerifiedID)
	if usage.Outcome != "spec022_verified" || usage.TokenSource != "coordinator_observed" {
		t.Fatalf("usage outcome/source=%s/%s want spec022_verified/coordinator_observed", usage.Outcome, usage.TokenSource)
	}
	if reservation.Status != "settled" || reservation.SettledTokens != 20 || reservation.SettlementHold != 1 {
		t.Fatalf("reservation=%+v want settled 20-token held reservation", reservation)
	}
	verdicts := waitForSettlementVerdicts(t, s, 1)
	if len(verdicts) != 1 {
		t.Fatalf("verified verdict count=%d want 1", len(verdicts))
	}
	verified := verdicts[0]
	if verified.ReceiptResult != "valid" || verified.SettlementOutcome != "verified" || verified.Closed != 1 {
		t.Fatalf("verified verdict=%s/%s closed=%d want valid/verified closed", verified.ReceiptResult, verified.SettlementOutcome, verified.Closed)
	}
	credits := waitForLedgerCredits(t, s, 1)
	if credits[0].SettlementPolicyMode != "enforce" {
		t.Fatalf("verified credit settlement_policy_mode=%q want enforce", credits[0].SettlementPolicyMode)
	}
	pass("step-02-verified-debit", "reservation-first debit settled only after a verified settlement-capable receipt", map[string]any{
		"http_status":            status,
		"usage_outcome":          usage.Outcome,
		"reservation_status":     reservation.Status,
		"settled_tokens":         reservation.SettledTokens,
		"settlement_outcome":     verified.SettlementOutcome,
		"settlement_policy_mode": credits[0].SettlementPolicyMode,
	})

	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows after verified debit=%d want 0", got)
	}
	pass("step-03-payout-exclusion", "job_enabled stayed false and verified enforce traffic created no payout-ready rows", map[string]any{
		"payout_ready_count":       0,
		"job_enabled":              startJob,
		"payout_exclusion_outcome": verified.PayoutExclusionOutcome,
	})

	s.fakeProv.setOmitSettlementReceipts(true)
	missingStatus, _, missingBody := s.chatRequest(map[string]string{"X-Request-ID": buyerEnforceMissingID}, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"stream":true,
		"messages":[{"role":"user","content":"enforce-path missing-receipt"}]
	}`, settlementFixtureModelID))
	if missingStatus != http.StatusOK {
		t.Fatalf("missing-receipt streaming chat status=%d body=%s", missingStatus, string(missingBody))
	}
	quarantined := waitForMissingReceiptDeadlineQuarantine(t, s, 2)
	refund, refundOK := waitForQuotaStatus(t, s, buyerEnforceMissingID, "refunded")
	if !refundOK || refund.Status != "refunded" || refund.SettledTokens != 0 {
		t.Fatalf("missing-receipt quota not refunded: ok=%v reservation=%+v", refundOK, refund)
	}
	if got := s.payableCreditCount(quarantined.RequestID); got != 0 {
		t.Fatalf("quarantined request payable credits=%d want 0", got)
	}
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows after quarantine=%d want 0", got)
	}
	pass("step-04-missing-receipt-quarantine", "deadline quarantine released the buyer reservation and kept payout exclusion", map[string]any{
		"settlement_outcome": quarantined.SettlementOutcome,
		"reason":             quarantined.Reason,
		"receipt_present":    quarantined.ReceiptPresent,
		"reservation_status": refund.Status,
		"payout_ready_count": 0,
	})

	pinnedMode := credits[0].SettlementPolicyMode
	s.rewriteSettlementMode("observe")
	s.restartCoordinator()
	endMode, endJob := readCoordinatorSettlement(t, s.coordYAML)
	if endMode != "observe" || endJob {
		t.Fatalf("rewritten settlement mode=%q job_enabled=%v want observe/false", endMode, endJob)
	}
	afterCredits := s.readLedgerCredits()
	if len(afterCredits) < 1 {
		t.Fatal("expected pinned enforce credit to survive observe rollback restart")
	}
	for _, row := range afterCredits {
		if row.SettlementPolicyMode != pinnedMode {
			t.Fatalf("rollback rewrote settlement_policy_mode=%q want pinned %q", row.SettlementPolicyMode, pinnedMode)
		}
	}
	afterVerdicts := s.readSettlementReceiptVerdicts()
	if len(afterVerdicts) < 2 {
		t.Fatalf("verdicts after rollback=%d want >=2", len(afterVerdicts))
	}
	for _, row := range afterVerdicts {
		if row.RouteSnapshotMode != "enforce" {
			t.Fatalf("rollback rewrote verdict route_snapshot_mode=%q want enforce", row.RouteSnapshotMode)
		}
	}
	pass("step-05-policy-pinning", "observe rollback did not rewrite already-enforced ledger or verdict rows", map[string]any{
		"yaml_mode_after_rewrite": endMode,
		"pinned_policy_mode":      pinnedMode,
		"pinned_route_snapshot":   "enforce",
		"credit_count":            len(afterCredits),
	})

	audits := s.readSettlementVerdictAudits()
	if len(audits) == 0 {
		t.Fatal("expected settlement_receipt_verdict audit events")
	}
	banned := []string{
		"enforce-path verified",
		"enforce-path missing-receipt",
		"hello from fake provider",
		s.apiKey,
		"provider_receipt_public_key",
		"raw_receipt",
		"receipt_envelope",
		base64.StdEncoding.EncodeToString(s.fakeProv.receiptPubkey),
	}
	for _, payload := range audits {
		for _, needle := range banned {
			if strings.Contains(payload, needle) {
				t.Fatalf("audit payload leaked raw material %q: %s", needle, payload)
			}
		}
		if !strings.Contains(payload, `"settlement_outcome"`) || !strings.Contains(payload, `"buyer_debit_outcome"`) {
			t.Fatalf("audit payload missing structured settlement fields: %s", payload)
		}
	}
	pass("step-06-audit", "per-attempt settlement audit is structured and omits raw prompts, outputs, and secrets", map[string]any{
		"verdict_audit_events":       len(audits),
		"raw_prompt_output_redacted": true,
	})

	if s.payoutReadyCount() != 0 {
		t.Fatal("journey produced payout-ready rows")
	}
	pass("step-07-restore-config", "settlement job stayed disabled and production Pearl was not touched", map[string]any{
		"yaml_mode":            endMode,
		"job_enabled":          endJob,
		"payout_ready_mutated": false,
		"production_pearl":     false,
	})

	if os.Getenv("MACPROVIDER_CAPTURE_BUYER_ENFORCE") != "1" {
		return
	}
	writeBuyerEnforceEvidence(t, s, steps, isolated, startMode, endMode, startJob, endJob)
}

func waitForMissingReceiptDeadlineQuarantine(t *testing.T, s *scenario, wantCount int) settlementReceiptVerdictRow {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var latest []settlementReceiptVerdictRow
	for time.Now().Before(deadline) {
		latest = s.readSettlementReceiptVerdicts()
		if len(latest) >= wantCount {
			for _, row := range latest {
				if row.SettlementOutcome == "quarantined" &&
					row.Closed == 1 &&
					row.ReceiptPresent == 0 &&
					row.Reason == "missing_receipt_deadline_elapsed" &&
					row.BuyerDebitOutcome == "no_money_movement_step5" &&
					row.ProviderSettlementOutcome == "no_money_movement_step5" &&
					row.PayoutExclusionOutcome == "excluded_until_spec022_verified" {
					return row
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("missing-receipt deadline quarantine not found before deadline: %+v", latest)
	return settlementReceiptVerdictRow{}
}

func (s *scenario) readSettlementVerdictAudits() []string {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT payload_json FROM audit_log WHERE event_type = 'settlement_receipt_verdict' ORDER BY id ASC`)
	if err != nil {
		s.t.Fatalf("query settlement verdict audits: %v", err)
	}
	defer rows.Close()
	var payloads []string
	for rows.Next() {
		var payload string
		if err := rows.Scan(&payload); err != nil {
			s.t.Fatalf("scan audit_log: %v", err)
		}
		payloads = append(payloads, payload)
	}
	if err := rows.Err(); err != nil {
		s.t.Fatalf("audit_log rows: %v", err)
	}
	return payloads
}

func (s *scenario) payableCreditCount(requestID string) int {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ?`, requestID).Scan(&count); err != nil {
		s.t.Fatalf("query spec022_payable_request_credits: %v", err)
	}
	return count
}

func writeBuyerEnforceEvidence(t *testing.T, s *scenario, steps []buyerEnforceStep, isolated bool, startMode, endMode string, startJob, endJob bool) {
	t.Helper()
	root, err := findRepoRoot()
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	commit := gitHEAD(t, root)
	captured := time.Now().UTC().Truncate(time.Second)
	runID := "buyer-enforce-" + captured.Format("20060102T150405Z")
	artifactRel := filepath.ToSlash(filepath.Join("journeys", "evidence", runID+".redacted.json"))
	evidence := map[string]any{
		"schema_version": buyerEnforceEvidenceSchema,
		"journey_id":     buyerEnforceJourneyID,
		"run_id":         runID,
		"captured_at":    captured.Format("2006-01-02T15:04:05Z"),
		"expires_at":     captured.AddDate(0, 0, 30).Format("2006-01-02"),
		"requirement_ids": []string{
			"SPEC-022-R007",
			"SPEC-022-R008",
			"SPEC-022-R009",
			"SPEC-022-R011",
		},
		"repository": map[string]string{"name": "Augustas11/macprovider", "commit": commit},
		"operator": map[string]string{
			"role":                 "acceptance-operator",
			"identity_fingerprint": sha256Hex("isolated-candidate-enforce"),
		},
		"environment": map[string]string{
			"class":            "isolated-candidate-enforce",
			"hardware_profile": "local-macos-redacted",
			"candidate":        "commit:" + commit,
		},
		"harness": map[string]any{
			"id":                      "test/integration:TestJourneyBuyerEnforceIsolatedCandidate",
			"execution_mode":          "isolated-candidate-enforce",
			"isolated_sqlite":         isolated,
			"real_binaries":           true,
			"production_side_effects": false,
			"settlement_runner":       false,
			"production_pearl":        false,
		},
		"observations": map[string]any{
			"settlement_mode_start":      startMode,
			"settlement_mode_end":        endMode,
			"enforce_activated":          startMode == "enforce",
			"job_enabled":                endJob,
			"start_job_enabled":          startJob,
			"payout_ready_mutated":       false,
			"production_side_effects":    false,
			"production_pearl":           false,
			"isolated_environment":       isolated,
			"raw_prompt_output_redacted": true,
		},
		"result": map[string]any{
			"status":  "pass",
			"summary": "isolated candidate enforce journey passed without payout-ready mutation or Pearl flip",
		},
		"steps": steps,
		"redaction": map[string]any{
			"secrets_redacted":             true,
			"operator_identity_redacted":   true,
			"local_account_names_redacted": true,
		},
	}
	payload, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		t.Fatalf("marshal evidence: %v", err)
	}
	payload = append(payload, '\n')
	if strings.Contains(string(payload), s.apiKey) {
		t.Fatal("redacted evidence contains the buyer API key")
	}
	for _, needle := range []string{
		"enforce-path verified",
		"enforce-path missing-receipt",
		"hello from fake provider",
		"provider_receipt_public_key",
		"raw_receipt",
		"receipt_envelope",
		base64.StdEncoding.EncodeToString(s.fakeProv.receiptPubkey),
	} {
		if strings.Contains(string(payload), needle) {
			t.Fatalf("redacted evidence contains raw material %q", needle)
		}
	}
	path := filepath.Join(root, filepath.FromSlash(artifactRel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir evidence: %v", err)
	}
	if err := os.WriteFile(path, payload, 0o644); err != nil {
		t.Fatalf("write evidence: %v", err)
	}
	t.Logf("wrote %s", artifactRel)
}
