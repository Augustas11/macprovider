package integration

import (
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const ciWeightsManifest = "5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e"

// ciFakeScorer is the independent peer's view of an output: text the
// claimed model would generate scores near the generator, a substituted
// model's text far below.
func ciFakeScorer(output string) (int, int, float64) {
	if strings.Contains(output, "cheaper model") {
		return 100, 55, -160
	}
	return 100, 98, -18
}

type ciModelStatus struct {
	ModelID string `json:"model_id"`
	State   string `json:"state"`
	Reason  string `json:"reason"`
}

type ciStatus struct {
	Scoring *struct {
		Enabled bool            `json:"enabled"`
		Models  []ciModelStatus `json:"models"`
		Holds   []struct {
			Kind   string `json:"kind"`
			Status string `json:"status"`
		} `json:"holds"`
	} `json:"scoring"`
}

func (s *scenario) computeIntegrityStatus(providerID string) ciStatus {
	s.t.Helper()
	req, err := http.NewRequest(http.MethodGet, s.coordProvURL+"/admin/compute-integrity/"+providerID, nil)
	if err != nil {
		s.t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+s.operatorKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		s.t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		s.t.Fatalf("compute-integrity status %s: %d %s", providerID, resp.StatusCode, body)
	}
	var out ciStatus
	if err := json.Unmarshal(body, &out); err != nil {
		s.t.Fatalf("decode status: %v %s", err, body)
	}
	return out
}

func (st ciStatus) state() string {
	if st.Scoring == nil || len(st.Scoring.Models) == 0 {
		return ""
	}
	return st.Scoring.Models[0].State
}

// SPEC-036 §5A end to end through the real coordinator and gateway: four
// providers of four operators serve the same catalog artifact; one serves a
// substituted model. Verification requests travel the ordinary paid
// dispatch path and are scored by independent peers. The honest providers
// pass; the substituted one fails, leaves routing for that model, and its
// earnings for the affected window are held. No buyer is debited.
func TestComputeIntegrityScoringHonestPassesSubstitutedFails(t *testing.T) {
	var cheatID string
	index := 0
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
		providerCount:             4,
		coordinatorConfig: func(_ *scenario, cfg map[string]any) {
			cfg["compute_integrity"] = map[string]any{"scoring": map[string]any{
				"enabled":                     true,
				"base_interval_seconds":       2,
				"escalation_interval_seconds": 1,
				"max_in_flight":               8,
				"max_per_hour":                10000,
				"recovery_cooldown_seconds":   3600,
				"score_deadline_seconds":      10,
				"sweep_interval_seconds":      1,
				"corpus_path":                 ciPrivateCorpus(t),
			}}
		},
		providerSetup: func(fp *fakeProvider) {
			fp.weightsManifest = ciWeightsManifest
			fp.computeScore = ciFakeScorer
			if index == 1 {
				fp.outputText = "a cheaper model wrote this"
				cheatID = fp.providerID
			}
			index++
		},
	})
	var honestIDs []string
	for _, fp := range s.fakeProvs {
		if fp.providerID != cheatID {
			honestIDs = append(honestIDs, fp.providerID)
		}
	}

	deadline := time.Now().Add(150 * time.Second)
	for time.Now().Before(deadline) {
		done := s.computeIntegrityStatus(cheatID).state() == "failed"
		for _, id := range honestIDs {
			done = done && s.computeIntegrityStatus(id).state() == "passing"
		}
		if done {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	cheat := s.computeIntegrityStatus(cheatID)
	if cheat.state() != "failed" || cheat.Scoring.Models[0].Reason != "confirmed_failure" {
		t.Fatalf("substituted provider status = %+v", cheat.Scoring)
	}
	if len(cheat.Scoring.Holds) != 1 || cheat.Scoring.Holds[0].Kind != "failure" || cheat.Scoring.Holds[0].Status != "held" {
		t.Fatalf("substituted provider must have one held failure hold: %+v", cheat.Scoring.Holds)
	}
	for _, id := range honestIDs {
		st := s.computeIntegrityStatus(id)
		if st.state() != "passing" {
			t.Fatalf("honest provider %s state = %q", id, st.state())
		}
		if len(st.Scoring.Holds) != 0 {
			t.Fatalf("honest provider %s must have no holds: %+v", id, st.Scoring.Holds)
		}
	}

	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// Verification requests are ordinary paid attempts: each writes the same
	// ledger credit row a buyer request writes for the verified provider
	// (this harness's rate card prices the model at zero credits).
	var honestCredits int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id != ?`, cheatID).Scan(&honestCredits); err != nil {
		t.Fatal(err)
	}
	if honestCredits == 0 {
		t.Fatal("verification requests must write ledger credits for the verified providers")
	}
	var cipRequests int
	if err := db.QueryRow(`SELECT COUNT(*) FROM request_log WHERE account_id LIKE 'cip_%'`).Scan(&cipRequests); err != nil {
		t.Fatal(err)
	}
	if cipRequests == 0 {
		t.Fatal("verification requests must be logged under reserved accounts")
	}
	// The cheater's credits in the held window are not payable.
	var cheatPayable int
	if err := db.QueryRow(`SELECT COUNT(*) FROM spec022_payable_request_credits WHERE provider_id = ?`, cheatID).Scan(&cheatPayable); err != nil {
		t.Fatal(err)
	}
	var cheatCredits int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = ?`, cheatID).Scan(&cheatCredits); err != nil {
		t.Fatal(err)
	}
	if cheatCredits == 0 || cheatPayable >= cheatCredits {
		t.Fatalf("held credits must leave the payable view: credits=%d payable=%d", cheatCredits, cheatPayable)
	}
	// No buyer was debited: the gateway never saw a verification request.
	if _, found := s.readLatestUsageEvent(); found {
		t.Fatal("verification requests must not reach buyer billing")
	}

	// Buyer traffic for the model no longer reaches the substituted provider.
	var cheatProv *fakeProvider
	for _, fp := range s.fakeProvs {
		if fp.providerID == cheatID {
			cheatProv = fp
		}
	}
	before := cheatProv.Hits()
	for i := 0; i < 8; i++ {
		status, _, body := s.chatRequest(nil, `{"model":"llama-3.2-3b-instruct","max_tokens":16,"messages":[{"role":"user","content":"hello"}]}`)
		if status != http.StatusOK {
			t.Fatalf("buyer chat status=%d body=%s", status, body)
		}
	}
	if cheatProv.Hits() != before {
		t.Fatalf("suspended provider served %d buyer requests", cheatProv.Hits()-before)
	}
}

// ciPrivateCorpus writes a private corpus for the coordinator: scheduling
// requires one (SPEC-036 FR-20). The content is the checked-in generic corpus.
func ciPrivateCorpus(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "phase4-coordinator", "internal", "computeintegrity", "corpus", "generic_v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "private-corpus.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
