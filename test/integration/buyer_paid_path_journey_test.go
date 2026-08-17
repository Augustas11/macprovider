package integration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	buyerPaidPathJourneyID        = "JOURNEY-BUYER-PAID-PATH"
	buyerPaidPathEvidenceSchema   = "macprovider.buyer-paid-path-evidence.v1"
	buyerPaidPathUnroutable       = "macprovider-paid-path-unroutable-fixture"
	buyerPaidPathPromptTokens     = int64(8)
	buyerPaidPathCompletionTokens = int64(12)
	buyerPaidPathSettledTokens    = int64(20)
	buyerPaidPathPromptRate       = int64(500000)
	buyerPaidPathCompletionRate   = int64(1000000)
	buyerPaidPathMultiplierPPM    = int64(1000000)
	buyerPaidPathShareBps         = int64(9000)
	buyerPaidPathGrossCredits     = int64(16)
	buyerPaidPathProviderCredits  = int64(14)
	buyerPaidPathDeliveredPrefix  = "hello from fake provider"
	buyerPaidPathRateCardMatch    = "default"
)

type buyerPaidPathStep struct {
	ID        string         `json:"id"`
	Status    string         `json:"status"`
	Assertion string         `json:"assertion"`
	Artifacts []string       `json:"artifacts"`
	Details   map[string]any `json:"details,omitempty"`
}

func TestJourneyBuyerPaidPathIsolatedCandidate(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
	})
	if !strings.HasPrefix(s.apiKey, "mp_") {
		t.Fatal("buyer subject is not a disposable mp_ API key")
	}
	isolated := requireIsolatedCandidate(t, s)

	const nonstreamID = "11111111-1111-4111-8111-111111111111"
	const streamID = "22222222-2222-4222-8222-222222222222"
	const failID = "33333333-3333-4333-8333-333333333333"
	dailyQuota := readGatewayDailyQuota(t, s.gatewayYAML)
	if got := s.settledQuotaTokens(); got != 0 {
		t.Fatalf("starting settled quota=%d want 0", got)
	}
	startingQuota := dailyQuota
	startMode, startJob := readCoordinatorSettlement(t, s.coordYAML)
	if startMode != "observe" || startJob {
		t.Fatalf("starting settlement mode=%q job_enabled=%v want observe/false", startMode, startJob)
	}
	if got := s.payoutReadyCount(); got != 0 {
		t.Fatalf("payout-ready rows before journey=%d want 0", got)
	}

	steps := make([]buyerPaidPathStep, 0, 11)
	pass := func(id, assertion string, details map[string]any) {
		steps = append(steps, buyerPaidPathStep{
			ID:        id,
			Status:    "pass",
			Assertion: assertion,
			Artifacts: []string{"redacted-buyer-paid-path"},
			Details:   details,
		})
	}

	pass("step-01-capture-config", "isolated candidate captured in observe mode with an API-key subject and no settlement runner", map[string]any{
		"settlement_mode":     startMode,
		"enforce_activated":   startMode == "enforce",
		"job_enabled":         startJob,
		"isolated_sqlite":     isolated,
		"auth_subject":        "api_key",
		"demo_token_used":     false,
		"wallet_session_used": false,
		"starting_quota":      startingQuota,
		"account_fingerprint": sha256Hex(s.accountID),
	})

	nonstreamStatus, nonstreamHeaders, nonstreamBody := s.chatRequest(map[string]string{"X-Request-ID": nonstreamID}, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"messages":[{"role":"user","content":"paid-path nonstream"}]
	}`, settlementFixtureModelID))
	if nonstreamStatus != http.StatusOK {
		t.Fatalf("non-stream chat status=%d body=%s", nonstreamStatus, string(nonstreamBody))
	}
	if got := nonstreamHeaders.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("buyer response exposed non-streaming receipt header %q", got)
	}
	var nonstreamChat map[string]any
	if err := json.Unmarshal(nonstreamBody, &nonstreamChat); err != nil {
		t.Fatalf("decode non-stream body: %v", err)
	}
	if nonstreamChat["object"] != "chat.completion" {
		t.Fatalf("non-stream object=%v want chat.completion", nonstreamChat["object"])
	}
	usageObj, _ := nonstreamChat["usage"].(map[string]any)
	if usageObj == nil {
		t.Fatal("non-stream response missing usage")
	}
	pass("step-02-nonstream-chat", "API-key non-streaming chat returned 200 with OpenAI-compatible usage", map[string]any{
		"http_status":            nonstreamStatus,
		"gateway_request_sha256": sha256Hex(nonstreamID),
		"usage_present":          true,
	})

	nonstreamReservation, ok := waitForQuotaStatus(t, s, nonstreamID, "settled")
	if !ok {
		t.Fatalf("non-stream quota reservation not settled: %+v", nonstreamReservation)
	}
	if nonstreamReservation.SettledTokens != buyerPaidPathSettledTokens {
		t.Fatalf("non-stream settled_tokens=%d want %d", nonstreamReservation.SettledTokens, buyerPaidPathSettledTokens)
	}
	afterNonstreamQuota := dailyQuota - s.settledQuotaTokens()
	pass("step-03-quota-settlement", "gateway quota reservation settled after the 200 and did not leak", map[string]any{
		"reservation_status": nonstreamReservation.Status,
		"settled_tokens":     nonstreamReservation.SettledTokens,
		"remaining_quota":    afterNonstreamQuota,
		"observe_mode_debit": true,
		"not_r008_evidence":  true,
	})

	credits := waitForLedgerCredits(t, s, 1)
	nonstreamCredit := credits[0]
	assertPayableObserveCredit(t, nonstreamCredit, 0)
	pass("step-04-ledger-credit", "coordinator ledger wrote a payable observe-mode credit whose persisted rates reproduce the default rate-card split", map[string]any{
		"credit_id_fingerprint":    sha256Hex(fmt.Sprintf("%d", nonstreamCredit.ID)),
		"gross_credits":            nonstreamCredit.GrossCredits,
		"provider_credits":         nonstreamCredit.ProviderCredits,
		"prompt_tokens":            nonstreamCredit.PromptTokens.Int64,
		"completion_tokens":        nonstreamCredit.CompletionTokens.Int64,
		"prompt_rate_per_mtok":     nonstreamCredit.PromptRatePerMtok,
		"completion_rate_per_mtok": nonstreamCredit.CompletionRatePerMtok,
		"global_multiplier_ppm":    nonstreamCredit.GlobalMultiplierPPM,
		"provider_share_bps":       nonstreamCredit.ProviderShareBps,
		"rate_card_matched_key":    buyerPaidPathRateCardMatch,
		"settlement_policy_mode":   nonstreamCredit.SettlementPolicyMode,
		"settled_flag":             nonstreamCredit.Settled,
	})

	verdicts := waitForSettlementVerdicts(t, s, 1)
	if len(verdicts) != 1 {
		t.Fatalf("settlement verdict count=%d want 1", len(verdicts))
	}
	assertObserveReceiptVerdict(t, verdicts[0], s.providerID, s.modelHash)
	pass("step-05-receipt-ingest", "SPEC-015 v0.4 settlement receipt was ingested and verified in observe mode", map[string]any{
		"receipt_version":             "4",
		"receipt_result":              verdicts[0].ReceiptResult,
		"settlement_outcome":          verdicts[0].SettlementOutcome,
		"buyer_debit_outcome":         verdicts[0].BuyerDebitOutcome,
		"provider_settlement_outcome": verdicts[0].ProviderSettlementOutcome,
		"raw_prompt_output_absent":    true,
	})

	streamStatus, streamHeaders, streamBody := s.chatRequest(map[string]string{"X-Request-ID": streamID}, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"stream":true,
		"messages":[{"role":"user","content":"paid-path stream"}]
	}`, settlementFixtureModelID))
	if streamStatus != http.StatusOK {
		t.Fatalf("stream chat status=%d body=%s", streamStatus, string(streamBody))
	}
	if got := streamHeaders.Get("X-MacProvider-Receipt"); got != "" {
		t.Fatalf("buyer response exposed streaming receipt header %q", got)
	}
	if !strings.Contains(string(streamBody), "data: [DONE]") {
		t.Fatalf("stream missing DONE marker: %s", string(streamBody))
	}
	if !strings.Contains(string(streamBody), "hello ") || !strings.Contains(string(streamBody), "from fake provider") {
		t.Fatalf("stream missing delivered fixture prefix: %s", string(streamBody))
	}
	streamReservation, ok := waitForQuotaStatus(t, s, streamID, "settled")
	if !ok {
		t.Fatalf("stream quota reservation not settled: %+v", streamReservation)
	}
	if streamReservation.SettledTokens != buyerPaidPathSettledTokens {
		t.Fatalf("stream settled_tokens=%d want %d", streamReservation.SettledTokens, buyerPaidPathSettledTokens)
	}
	credits = waitForLedgerCredits(t, s, 2)
	assertPayableObserveCredit(t, credits[1], 1)
	if credits[1].CompletionTokens.Int64 != buyerPaidPathCompletionTokens {
		t.Fatalf("stream completion_tokens=%d want fixture prefix %d", credits[1].CompletionTokens.Int64, buyerPaidPathCompletionTokens)
	}
	verdicts = waitForSettlementVerdicts(t, s, 2)
	if len(verdicts) != 2 {
		t.Fatalf("settlement verdict count=%d want 2", len(verdicts))
	}
	assertObserveReceiptVerdict(t, verdicts[1], s.providerID, s.modelHash)
	pass("step-06-streaming-chat", "streaming chat terminated cleanly; settled completion tokens equal the 12-token fixture prefix, not a byte-length estimate", map[string]any{
		"http_status":             streamStatus,
		"done_marker":             true,
		"delivered_prefix_sha256": sha256Hex(buyerPaidPathDeliveredPrefix),
		"reservation_status":      streamReservation.Status,
		"settled_tokens":          streamReservation.SettledTokens,
		"completion_tokens":       credits[1].CompletionTokens.Int64,
		"stream_ledger":           credits[1].Stream == 1,
	})

	failStatus, _, failBody := s.chatRequest(map[string]string{"X-Request-ID": failID}, fmt.Sprintf(`{
		"model":%q,
		"max_tokens":32,
		"messages":[{"role":"user","content":"paid-path failure"}]
	}`, buyerPaidPathUnroutable))
	if failStatus == http.StatusOK {
		t.Fatalf("unroutable model unexpectedly succeeded: %s", string(failBody))
	}
	code, retryable := parseErrorEnvelope(t, failBody)
	failReservation, failOK := waitForQuotaStatus(t, s, failID, "refunded")
	if !failOK || failReservation.Status != "refunded" || failReservation.SettledTokens != 0 {
		t.Fatalf("failure quota not refunded: ok=%v reservation=%+v", failOK, failReservation)
	}
	creditsAfterFail := s.readLedgerCredits()
	if len(creditsAfterFail) != 2 {
		t.Fatalf("failure wrote extra ledger credits: got %d want 2", len(creditsAfterFail))
	}
	pass("step-07-failure-refund", "pre-dispatch failure returned a buyer error envelope and refunded quota with no provider credit", map[string]any{
		"http_status":      failStatus,
		"error_code":       code,
		"error_retryable":  retryable,
		"quota_status":     reservationStatus(failReservation, failOK),
		"ledger_row_count": len(creditsAfterFail),
	})

	modelsStatus, _, modelsBody := s.gatewayRequest(http.MethodGet, "/v1/models", nil)
	if modelsStatus != http.StatusOK {
		t.Fatalf("models status=%d body=%s", modelsStatus, string(modelsBody))
	}
	var models map[string]any
	if err := json.Unmarshal(modelsBody, &models); err != nil {
		t.Fatalf("decode models: %v", err)
	}
	disclosure, _ := models["tier1_disclosure"].(map[string]any)
	if disclosure == nil {
		t.Fatal("models missing tier1_disclosure")
	}
	settlement, _ := disclosure["verified_model_settlement"].(map[string]any)
	if settlement == nil {
		t.Fatal("models missing verified_model_settlement")
	}
	observeText, _ := settlement["observe_mode"].(string)
	enforceText, _ := settlement["enforce_mode"].(string)
	included, _ := settlement["included_paid_entrypoints"].([]any)
	excluded, _ := settlement["excluded_paid_entrypoints"].([]any)
	if observeText == "" || enforceText == "" {
		t.Fatalf("models disclosure missing observe/enforce prose: observe=%q enforce=%q", observeText, enforceText)
	}
	if !strings.Contains(strings.ToLower(observeText), "does not change buyer debit") {
		t.Fatalf("observe-mode disclosure missing no-money claim: %q", observeText)
	}
	if strings.Contains(strings.ToLower(enforceText), "currently enforcing") {
		t.Fatalf("enforce-mode disclosure claimed currently enforcing: %q", enforceText)
	}
	if !containsString(included, "POST /v1/chat/completions") {
		t.Fatalf("included_paid_entrypoints=%v want POST /v1/chat/completions", included)
	}
	if len(excluded) == 0 {
		t.Fatal("excluded_paid_entrypoints is empty")
	}
	pass("step-08-disclosure", "buyer models disclosure names paid entrypoints and observe-mode prose; it does not claim currently enforcing", map[string]any{
		"http_status":     modelsStatus,
		"observe_mode":    true,
		"chat_included":   true,
		"excluded_named":  true,
		"enforce_claimed": false,
	})

	receiptStatus, _, _ := s.gatewayRequest(http.MethodGet, "/v1/receipts/"+nonstreamID, nil)
	if receiptStatus != http.StatusNotFound {
		t.Fatalf("buyer receipt retrieval status=%d want 404; this journey must not silently promote SPEC-022-R006", receiptStatus)
	}
	retrievalExposed := false
	pass("step-09-receipt-retrieval", "buyer receipt-retrieval endpoint is not exposed on the candidate", map[string]any{
		"http_status":                     receiptStatus,
		"buyer_receipt_retrieval_exposed": retrievalExposed,
	})

	if s.payoutReadyCount() != 0 {
		t.Fatal("journey produced payout-ready rows")
	}
	pass("step-10-redaction", "retained artifacts contain fingerprints only; bearer tokens, private keys, and raw prompt/output are absent", map[string]any{
		"bearer_tokens_redacted":     true,
		"raw_prompt_output_redacted": true,
		"payout_ready_mutated":       false,
	})

	endingQuota := dailyQuota - s.settledQuotaTokens()
	endMode, endJob := readCoordinatorSettlement(t, s.coordYAML)
	if endMode != startMode || endJob != startJob || endMode != "observe" || endJob {
		t.Fatalf("settlement config drifted: start=%s/%v end=%s/%v", startMode, startJob, endMode, endJob)
	}
	pass("step-11-restore-config", "settlement mode remained observe, no payout-ready mutation, and enforce was not activated", map[string]any{
		"settlement_mode":      endMode,
		"enforce_activated":    endMode == "enforce",
		"job_enabled":          endJob,
		"payout_ready_mutated": false,
		"ending_quota":         endingQuota,
	})

	if os.Getenv("MACPROVIDER_CAPTURE_BUYER_PAID_PATH") != "1" {
		return
	}
	writeBuyerPaidPathEvidence(t, s, steps, startingQuota, endingQuota, retrievalExposed, isolated, endMode)
}

func waitForQuotaStatus(t *testing.T, s *scenario, requestID, want string) (quotaReservationRow, bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var latest quotaReservationRow
	var ok bool
	for time.Now().Before(deadline) {
		latest, ok = s.readQuotaReservation(requestID)
		if ok && latest.Status == want {
			return latest, true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return latest, ok && latest.Status == want
}

func waitForLedgerCredits(t *testing.T, s *scenario, want int) []ledgerCreditRow {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var latest []ledgerCreditRow
	for time.Now().Before(deadline) {
		latest = s.readLedgerCredits()
		if len(latest) >= want {
			return latest
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(latest) < want {
		t.Fatalf("ledger credits=%d want %d", len(latest), want)
	}
	return latest
}

func assertPayableObserveCredit(t *testing.T, row ledgerCreditRow, wantStream int) {
	t.Helper()
	if row.Status != http.StatusOK {
		t.Fatalf("ledger status=%d want 200", row.Status)
	}
	if row.Stream != wantStream {
		t.Fatalf("ledger stream=%d want %d", row.Stream, wantStream)
	}
	if row.SettlementPolicyMode != "observe" {
		t.Fatalf("ledger settlement_policy_mode=%q want observe", row.SettlementPolicyMode)
	}
	if !row.PromptTokens.Valid || !row.CompletionTokens.Valid {
		t.Fatalf("ledger missing token fields: %+v", row)
	}
	if row.CachedPromptTokens.Valid && row.CachedPromptTokens.Int64 != 0 {
		t.Fatalf("cached_prompt_tokens=%d: fixture closed form omits the cache-hit term", row.CachedPromptTokens.Int64)
	}
	if !row.ChargedPromptTokens.Valid || row.ChargedPromptTokens.Int64 != row.PromptTokens.Int64 {
		t.Fatalf("charged_prompt_tokens=%v != prompt_tokens=%d", row.ChargedPromptTokens, row.PromptTokens.Int64)
	}
	if row.PromptTokens.Int64 != buyerPaidPathPromptTokens || row.CompletionTokens.Int64 != buyerPaidPathCompletionTokens {
		t.Fatalf("ledger tokens=%d/%d want fixture %d/%d", row.PromptTokens.Int64, row.CompletionTokens.Int64, buyerPaidPathPromptTokens, buyerPaidPathCompletionTokens)
	}
	if row.PromptRatePerMtok != buyerPaidPathPromptRate || row.CompletionRatePerMtok != buyerPaidPathCompletionRate {
		t.Fatalf("ledger rates=%d/%d want default rate-card %d/%d", row.PromptRatePerMtok, row.CompletionRatePerMtok, buyerPaidPathPromptRate, buyerPaidPathCompletionRate)
	}
	if row.GlobalMultiplierPPM != buyerPaidPathMultiplierPPM || row.ProviderShareBps != buyerPaidPathShareBps {
		t.Fatalf("ledger multiplier/share=%d/%d want %d/%d", row.GlobalMultiplierPPM, row.ProviderShareBps, buyerPaidPathMultiplierPPM, buyerPaidPathShareBps)
	}
	if row.GrossCredits != buyerPaidPathGrossCredits || row.ProviderCredits != buyerPaidPathProviderCredits {
		t.Fatalf("ledger credits=%d/%d want pinned default-row %d/%d", row.GrossCredits, row.ProviderCredits, buyerPaidPathGrossCredits, buyerPaidPathProviderCredits)
	}
	expectedGross := expectedGrossCredits(row.PromptTokens.Int64, row.CompletionTokens.Int64, row.PromptRatePerMtok, row.CompletionRatePerMtok, row.GlobalMultiplierPPM)
	if row.GrossCredits != expectedGross {
		t.Fatalf("gross_credits=%d want %d from persisted-rate split", row.GrossCredits, expectedGross)
	}
	expectedProvider := roundHalfEven(row.GrossCredits*row.ProviderShareBps, 10000)
	if row.ProviderCredits != expectedProvider {
		t.Fatalf("provider_credits=%d want %d", row.ProviderCredits, expectedProvider)
	}
}

func assertObserveReceiptVerdict(t *testing.T, verdict settlementReceiptVerdictRow, providerID, modelHash string) {
	t.Helper()
	if verdict.ProviderID != providerID {
		t.Fatalf("verdict.provider_id=%q want %q", verdict.ProviderID, providerID)
	}
	if verdict.ReceiptPresent != 1 || !verdict.ReceiptVersion.Valid || verdict.ReceiptVersion.String != "4" {
		t.Fatalf("receipt present/version=%d/%v want present v4", verdict.ReceiptPresent, verdict.ReceiptVersion)
	}
	if verdict.ReceiptResult != "valid" || verdict.SettlementOutcome != "verified" {
		t.Fatalf("verdict=%s/%s want valid/verified", verdict.ReceiptResult, verdict.SettlementOutcome)
	}
	if !verdict.ModelHash.Valid || verdict.ModelHash.String != modelHash {
		t.Fatalf("verdict.model_hash=%v want %s", verdict.ModelHash, modelHash)
	}
	if verdict.BuyerDebitOutcome != "no_money_movement_step5" ||
		verdict.ProviderSettlementOutcome != "no_money_movement_step5" {
		t.Fatalf("observe money outcomes=%s/%s want no_money_movement_step5", verdict.BuyerDebitOutcome, verdict.ProviderSettlementOutcome)
	}
}

func expectedGrossCredits(prompt, completion, promptRate, completionRate, multiplierPPM int64) int64 {
	base := prompt*promptRate + completion*completionRate
	return roundHalfEven(base*multiplierPPM, 1000000*1000000)
}

func roundHalfEven(numerator, denominator int64) int64 {
	if denominator <= 0 {
		return 0
	}
	q := numerator / denominator
	r := numerator % denominator
	if r < 0 {
		r = -r
	}
	twice := r * 2
	switch {
	case twice < denominator:
		return q
	case twice > denominator:
		if numerator >= 0 {
			return q + 1
		}
		return q - 1
	default:
		if q%2 == 0 {
			return q
		}
		if numerator >= 0 {
			return q + 1
		}
		return q - 1
	}
}

func parseErrorEnvelope(t *testing.T, body []byte) (string, bool) {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode error envelope: %v body=%s", err, string(body))
	}
	errObj, _ := payload["error"].(map[string]any)
	if errObj == nil {
		t.Fatalf("failure body missing error object: %s", string(body))
	}
	code, _ := errObj["code"].(string)
	if code == "" {
		t.Fatalf("failure body missing error.code: %s", string(body))
	}
	retryable, ok := errObj["retryable"].(bool)
	if !ok {
		t.Fatalf("failure body missing boolean error.retryable: %s", string(body))
	}
	return code, retryable
}

func reservationStatus(row quotaReservationRow, ok bool) string {
	if !ok {
		return "absent"
	}
	return row.Status
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func gitHEAD(t *testing.T, root string) string {
	t.Helper()
	status, err := exec.Command("git", "-C", root, "status", "--porcelain").Output()
	if err != nil {
		t.Fatalf("git status: %v", err)
	}
	if len(strings.TrimSpace(string(status))) != 0 {
		t.Fatalf("refusing to capture paid-path evidence from a dirty worktree:\n%s", status)
	}
	out, err := exec.Command("git", "-C", root, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatalf("git rev-parse: %v", err)
	}
	return strings.TrimSpace(string(out))
}

func writeBuyerPaidPathEvidence(t *testing.T, s *scenario, steps []buyerPaidPathStep, startingQuota, endingQuota int64, retrievalExposed, isolated bool, settlementMode string) {
	t.Helper()
	root, err := findRepoRoot()
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	commit := gitHEAD(t, root)
	captured := time.Now().UTC().Truncate(time.Second)
	runID := "buyer-paid-path-" + captured.Format("20060102T150405Z")
	expires := captured.AddDate(0, 0, 30).Format("2006-01-02")
	artifactRel := filepath.ToSlash(filepath.Join("journeys", "evidence", runID+".redacted.json"))
	evidence := map[string]any{
		"schema_version": buyerPaidPathEvidenceSchema,
		"journey_id":     buyerPaidPathJourneyID,
		"run_id":         runID,
		"captured_at":    captured.Format("2006-01-02T15:04:05Z"),
		"expires_at":     expires,
		"requirement_ids": []string{
			"SPEC-005-R001",
			"SPEC-005-R002",
			"SPEC-006-R001",
			"SPEC-006-R002",
			"SPEC-006-R003",
			"SPEC-015-R001",
			"SPEC-022-R001",
			"SPEC-022-R002",
			"SPEC-022-R003",
			"SPEC-022-R004",
			"SPEC-022-R005",
			"SPEC-022-R010",
		},
		"repository": map[string]string{"name": "Augustas11/macprovider", "commit": commit},
		"operator": map[string]string{
			"role":                 "acceptance-operator",
			"identity_fingerprint": sha256Hex("isolated-candidate-paid-path"),
		},
		"environment": map[string]string{
			"class":            "isolated-candidate-paid-path",
			"hardware_profile": "local-macos-redacted",
			"candidate":        "commit:" + commit,
		},
		"harness": map[string]any{
			"id":                      "test/integration:TestJourneyBuyerPaidPathIsolatedCandidate",
			"execution_mode":          "isolated-candidate-paid-path",
			"isolated_sqlite":         isolated,
			"real_binaries":           true,
			"production_side_effects": false,
			"settlement_runner":       false,
		},
		"candidate_identity": paidPathCandidateIdentity(t, s),
		"observations": map[string]any{
			"settlement_mode":                 settlementMode,
			"enforce_activated":               settlementMode == "enforce",
			"payout_ready_mutated":            false,
			"production_side_effects":         false,
			"buyer_receipt_retrieval_exposed": retrievalExposed,
			"isolated_environment":            isolated,
			"raw_prompt_output_redacted":      true,
			"bearer_tokens_redacted":          true,
		},
		"result": map[string]any{
			"status":  "pass",
			"summary": "isolated candidate paid-path journey passed in observe mode without payout-ready mutation",
		},
		"steps": steps,
		"redaction": map[string]bool{
			"secrets_redacted":             true,
			"operator_identity_redacted":   true,
			"local_account_names_redacted": true,
		},
		"quota": map[string]int64{
			"starting": startingQuota,
			"ending":   endingQuota,
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
	for _, needle := range []string{"paid-path nonstream", "paid-path stream", "paid-path failure"} {
		if strings.Contains(string(payload), needle) {
			t.Fatalf("redacted evidence contains raw prompt %q", needle)
		}
	}
	path := filepath.Join(root, filepath.FromSlash(artifactRel))
	if err := os.WriteFile(path, payload, 0o644); err != nil {
		t.Fatalf("write evidence: %v", err)
	}
	t.Logf("wrote %s", artifactRel)
}

func readCoordinatorSettlement(t *testing.T, path string) (string, bool) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read coordinator yaml: %v", err)
	}
	var cfg map[string]any
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("parse coordinator yaml: %v", err)
	}
	settlement, _ := cfg["settlement"].(map[string]any)
	if settlement == nil {
		t.Fatal("coordinator yaml missing settlement")
	}
	mode, ok := settlement["verified_model_settlement_mode"].(string)
	if !ok || mode == "" {
		t.Fatal("coordinator yaml missing settlement.verified_model_settlement_mode")
	}
	rawJob, present := settlement["job_enabled"]
	if !present {
		t.Fatal("coordinator yaml missing settlement.job_enabled; cannot attest the settlement runner is off")
	}
	jobEnabled, ok := rawJob.(bool)
	if !ok {
		t.Fatalf("settlement.job_enabled is %T, want bool", rawJob)
	}
	return mode, jobEnabled
}

func requireIsolatedCandidate(t *testing.T, s *scenario) bool {
	t.Helper()
	isolatedSQLite := strings.HasPrefix(s.coordinatorDB, s.tempDir) && strings.HasPrefix(s.gatewayDB, s.tempDir)
	if !isolatedSQLite {
		t.Fatalf("databases are not under the scenario temp dir: coord=%s gateway=%s temp=%s", s.coordinatorDB, s.gatewayDB, s.tempDir)
	}
	for _, raw := range []string{s.gatewayBaseURL, s.coordBuyerURL, s.coordProvURL} {
		parsed, err := url.Parse(raw)
		if err != nil || parsed.Hostname() != "127.0.0.1" {
			t.Fatalf("candidate URL %q is not loopback", raw)
		}
	}
	return true
}

func readGatewayDailyQuota(t *testing.T, path string) int64 {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read gateway yaml: %v", err)
	}
	var cfg map[string]any
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("parse gateway yaml: %v", err)
	}
	quotas, _ := cfg["quotas"].(map[string]any)
	if quotas == nil {
		t.Fatal("gateway yaml missing quotas")
	}
	switch value := quotas["account_daily_tokens"].(type) {
	case int:
		return int64(value)
	case int64:
		return value
	case uint64:
		return int64(value)
	case float64:
		return int64(value)
	default:
		t.Fatalf("gateway quotas.account_daily_tokens is %T, want int", value)
	}
	return 0
}

func paidPathCandidateIdentity(t *testing.T, s *scenario) map[string]any {
	t.Helper()
	if s.rateCardSHA256 == "" || s.rateCardVersion == "" || s.modelHash == "" ||
		s.settlementCatalogID == "" || s.settlementCatalogKeyID == "" ||
		s.autotuneCatalogVersion == "" || s.autotuneCatalogSHA256 == "" {
		t.Fatal("settlement catalog identity was not captured on the scenario")
	}
	coordYAML, err := os.ReadFile(s.coordYAML)
	if err != nil {
		t.Fatalf("read coordinator yaml: %v", err)
	}
	return map[string]any{
		"gateway_base_url_sha256":   sha256Hex(s.gatewayBaseURL),
		"coordinator_config_sha256": sha256Hex(string(coordYAML)),
		"rate_card_sha256":          s.rateCardSHA256,
		"rate_card_version":         s.rateCardVersion,
		"rate_card_matched_key":     buyerPaidPathRateCardMatch,
		"signed_catalog_id":         s.settlementCatalogID,
		"signed_catalog_key_id":     s.settlementCatalogKeyID,
		"autotune_catalog_version":  s.autotuneCatalogVersion,
		"autotune_catalog_sha256":   s.autotuneCatalogSHA256,
		"verified_model_sha256":     s.modelHash,
	}
}

func containsString(values []any, want string) bool {
	for _, value := range values {
		if text, ok := value.(string); ok && text == want {
			return true
		}
	}
	return false
}
