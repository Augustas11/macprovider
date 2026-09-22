package integration

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

type benchmarkEvidenceResult struct {
	Classification        string   `json:"classification"`
	Missing               []string `json:"missing"`
	Pending               []string `json:"pending"`
	GatewayUsageTokens    int64    `json:"gateway_usage_tokens"`
	GatewaySettledTokens  int64    `json:"gateway_settled_tokens"`
	GatewaySettlementHold int64    `json:"gateway_settlement_hold"`
}

func TestBuyerEvidenceClassifierPendingVerdictEndToEnd(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
		settlementEnforceMode:     true,
		pendingDeadlineSeconds:    60,
	})
	s.fakeProv.setOmitSettlementReceipts(true)
	const requestID = "16800000-0000-4000-8000-000000000003"
	status, _, body := s.chatRequest(map[string]string{"X-Request-ID": requestID},
		fmt.Sprintf(`{"model":%q,"max_tokens":32,"stream":false,"messages":[{"role":"user","content":"pending verdict"}]}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("pending buyer status=%d body=%s", status, body)
	}
	result := classifyBenchmarkEvidenceE2E(t, s, requestID)
	if result.Classification != "pending" {
		t.Fatalf("pending request classified %q missing=%v pending=%v", result.Classification, result.Missing, result.Pending)
	}
}

func classifyBenchmarkEvidenceE2E(t *testing.T, s *scenario, requestID string) benchmarkEvidenceResult {
	t.Helper()
	cmd := exec.Command("python3", filepath.Join("..", "..", "scripts", "classify_benchmark_evidence.py"),
		"--coordinator-db", s.coordinatorDB,
		"--gateway-db", s.gatewayDB,
		"--route-journal-db", s.coordinatorDB+".route-snapshots",
		"--account-id", s.accountID,
		"--request-id", requestID)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("classify benchmark evidence: %v: %s", err, output)
	}
	var result benchmarkEvidenceResult
	if err := json.Unmarshal(output, &result); err != nil {
		t.Fatalf("decode benchmark evidence: %v: %s", err, output)
	}
	return result
}

func TestBuyerEvidenceClassifierCompleteEndToEnd(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:                        true,
		settlementReceiptProvider:          true,
		settlementEnforceMode:              true,
		settlementReconcileIntervalSeconds: 1,
	})
	const completeID = "16800000-0000-4000-8000-000000000001"
	status, _, body := s.chatRequest(map[string]string{"X-Request-ID": completeID},
		fmt.Sprintf(`{"model":%q,"max_tokens":32,"stream":false,"messages":[{"role":"user","content":"evidence complete"}]}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("complete buyer status=%d body=%s", status, body)
	}
	waitForSpec022GatewaySettlement(t, s, completeID)
	waitForSettlementVerdicts(t, s, 1)
	deadline := time.Now().Add(20 * time.Second)
	for {
		result := classifyBenchmarkEvidenceE2E(t, s, completeID)
		if result.Classification == "complete" {
			return
		}
		if result.Classification == "incomplete" || time.Now().After(deadline) {
			t.Fatalf("complete request classified %q missing=%v pending=%v gateway_usage_tokens=%d gateway_settled_tokens=%d gateway_settlement_hold=%d", result.Classification, result.Missing, result.Pending, result.GatewayUsageTokens, result.GatewaySettledTokens, result.GatewaySettlementHold)
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func TestBuyerEvidenceClassifierPressureEndToEnd(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
		settlementEnforceMode:     true,
	})
	journal, err := sql.Open("sqlite", s.coordinatorDB+".route-snapshots")
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	conn, err := journal.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(context.Background(), "BEGIN IMMEDIATE"); err != nil {
		t.Fatal(err)
	}
	defer conn.ExecContext(context.Background(), "ROLLBACK")
	const pressureID = "16800000-0000-4000-8000-000000000002"
	status, _, body := s.chatRequest(map[string]string{"X-Request-ID": pressureID},
		fmt.Sprintf(`{"model":%q,"max_tokens":32,"stream":false,"messages":[{"role":"user","content":"evidence pressure"}]}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("pressure buyer status=%d body=%s", status, body)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		result := classifyBenchmarkEvidenceE2E(t, s, pressureID)
		if result.Classification == "incomplete" {
			for _, reason := range result.Missing {
				if reason == "route_snapshot_store_pressure" {
					return
				}
			}
			t.Fatalf("pressure request incomplete without route pressure marker: %v", result.Missing)
		}
		if time.Now().After(deadline) {
			t.Fatalf("pressure request classified %q, want incomplete marker", result.Classification)
		}
		time.Sleep(100 * time.Millisecond)
	}
}
