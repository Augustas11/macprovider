package integration

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// warmMemberAutotuneKey is the signed autotune row a warm-set member serves.
const warmMemberAutotuneKey = "openai/gpt-oss-20b"

// signedAutotuneRow returns the HF model id and signed hash of one row of
// the committed autotune catalog.
func signedAutotuneRow(t *testing.T, key string) (string, string) {
	t.Helper()
	repoRoot, err := findRepoRoot()
	if err != nil {
		t.Fatalf("find repo root: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(repoRoot, "phase3-binary", "dist", "static", "autotune-candidates.json"))
	if err != nil {
		t.Fatalf("read autotune catalog: %v", err)
	}
	var catalog struct {
		Rows map[string]struct {
			ModelID     string `json:"model_id"`
			ModelSHA256 string `json:"model_sha256"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(raw, &catalog); err != nil {
		t.Fatalf("parse autotune catalog: %v", err)
	}
	row, ok := catalog.Rows[key]
	if !ok {
		t.Fatalf("autotune catalog has no row %s", key)
	}
	return row.ModelID, row.ModelSHA256
}

type warmPoolzRow struct {
	ProviderID      string `json:"provider_id"`
	ServedModel     string `json:"served_model"`
	Primary         *bool  `json:"primary"`
	WarmState       string `json:"warm_state"`
	State           string `json:"state"`
	SlotsTotal      int    `json:"slots_total"`
	SlotsFree       int    `json:"slots_free"`
	RoutingEligible bool   `json:"routing_eligible"`
	ModelHash       string `json:"model_hash"`
}

func (s *scenario) warmPoolzRows() []warmPoolzRow {
	s.t.Helper()
	req, _ := http.NewRequest(http.MethodGet, s.coordProvURL+"/poolz", nil)
	req.Header.Set("Authorization", "Bearer "+s.operatorKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		s.t.Fatalf("/poolz: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Pool []warmPoolzRow `json:"pool"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil || resp.StatusCode != http.StatusOK {
		s.t.Fatalf("/poolz status=%d err=%v", resp.StatusCode, err)
	}
	return body.Pool
}

func (s *scenario) warmPoolzRow(providerID, model string) (warmPoolzRow, bool) {
	for _, row := range s.warmPoolzRows() {
		if row.ProviderID == providerID && row.ServedModel == model {
			return row, true
		}
	}
	return warmPoolzRow{}, false
}

// waitForWarmEntry polls /poolz until want holds for the entry (or, with
// present false, until the entry is gone).
func (s *scenario) waitForWarmEntry(providerID, model string, present bool, want func(warmPoolzRow) bool) warmPoolzRow {
	s.t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		row, ok := s.warmPoolzRow(providerID, model)
		if ok == present && (!present || want(row)) {
			return row
		}
		time.Sleep(100 * time.Millisecond)
	}
	row, ok := s.warmPoolzRow(providerID, model)
	s.t.Fatalf("entry %s#%s present=%v row=%+v, want present=%v", providerID, model, ok, row, present)
	return warmPoolzRow{}
}

type warmRouteSnapshotRow struct {
	RequestID           string
	AttemptN            int
	ProviderID          string
	ModelID             string
	ReportedHash        string
	ExpectedHash        string
	ServedModelDispatch int
}

func (s *scenario) readWarmRouteSnapshots() []warmRouteSnapshotRow {
	s.t.Helper()
	db := s.openCoordDB()
	defer db.Close()
	rows, err := db.Query(`SELECT request_id, attempt_n, provider_id, model_id, provider_reported_model_hash, expected_catalog_model_hash, served_model_dispatch FROM settlement_route_snapshots ORDER BY id ASC`)
	if err != nil {
		s.t.Fatalf("query route snapshots: %v", err)
	}
	defer rows.Close()
	var out []warmRouteSnapshotRow
	for rows.Next() {
		var r warmRouteSnapshotRow
		if err := rows.Scan(&r.RequestID, &r.AttemptN, &r.ProviderID, &r.ModelID, &r.ReportedHash, &r.ExpectedHash, &r.ServedModelDispatch); err != nil {
			s.t.Fatalf("scan route snapshot: %v", err)
		}
		out = append(out, r)
	}
	return out
}

func waitForWarmRouteSnapshots(t *testing.T, s *scenario, want int) []warmRouteSnapshotRow {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var latest []warmRouteSnapshotRow
	for time.Now().Before(deadline) {
		if latest = s.readWarmRouteSnapshots(); len(latest) >= want {
			return latest
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("route snapshots=%d want %d", len(latest), want)
	return nil
}

// creditFor returns the ledger credit of one route snapshot's attempt.
func creditFor(t *testing.T, credits []ledgerCreditRow, snap warmRouteSnapshotRow) ledgerCreditRow {
	t.Helper()
	for _, c := range credits {
		if c.RequestID == snap.RequestID && c.AttemptN == snap.AttemptN && c.ProviderID == snap.ProviderID {
			return c
		}
	}
	t.Fatalf("no ledger credit for snapshot %+v", snap)
	return ledgerCreditRow{}
}

// SPEC-002-R011 / SPEC-001-R016 / SPEC-015 §M.2.4: one provider session
// keeps two warm models. Buyer requests for both, through gateway and
// coordinator, are each dispatched to their entry with served_model_id,
// on their own seats; each route snapshot, receipt verdict and ledger
// credit carries the serving member's model id and hash and is priced for
// that model. When the member is evicted before the coordinator has seen
// it, its model_not_loaded answer fails the request over to a second
// provider, and the next heartbeat drops the entry.
func TestJourneyWarmSetTwoModelsOneSession(t *testing.T) {
	memberModel, memberHash := signedAutotuneRow(t, warmMemberAutotuneKey)
	const warmID = "prov-warm"
	const fallbackID = "prov-warm-1"
	s := newScenario(t, scenarioOpts{
		seedAccount:                true,
		settlementReceiptProvider:  true,
		providerCount:              2,
		providerID:                 warmID,
		settlementCatalogExtraRows: []string{warmMemberAutotuneKey},
		providerSetup: func(fp *fakeProvider) {
			switch fp.providerID {
			case warmID:
				fp.warmMembers = []*fakeWarmMember{{modelID: memberModel, modelHash: memberHash, slots: 3, throughput: 20, state: "warm"}}
			case fallbackID:
				// A second provider on the same catalogued primary,
				// advertised slower so the primary requests stay on the
				// warm-set session, whose member is still loading until
				// the eviction step.
				fp.primaryThroughput = 1
				fp.warmMembers = []*fakeWarmMember{{modelID: memberModel, modelHash: memberHash, slots: 4, throughput: 5, state: "loading"}}
			}
		},
	})
	if len(s.settlementCatalogExtra) != 1 || s.settlementCatalogExtra[0].ModelID != memberModel {
		t.Fatalf("settlement catalog extra rows = %+v", s.settlementCatalogExtra)
	}
	warm, fallback := s.fakeProvs[0], s.fakeProvs[1]

	primaryRow := s.waitForWarmEntry(warmID, settlementFixtureModelID, true, func(r warmPoolzRow) bool { return r.RoutingEligible })
	memberRow := s.waitForWarmEntry(warmID, memberModel, true, func(r warmPoolzRow) bool { return r.RoutingEligible })
	// Seats are per entry: the member's three seats are its own, not the
	// primary's two.
	if primaryRow.Primary == nil || !*primaryRow.Primary || primaryRow.SlotsTotal != 2 || memberRow.Primary == nil || *memberRow.Primary ||
		memberRow.SlotsTotal != 3 || memberRow.SlotsFree != 3 || memberRow.WarmState != "warm" {
		t.Fatalf("warm entries primary=%+v member=%+v", primaryRow, memberRow)
	}
	if row, ok := s.warmPoolzRow(fallbackID, memberModel); !ok || row.RoutingEligible || row.WarmState != "loading" {
		t.Fatalf("fallback member before eviction = %+v ok=%v, want loading and not routable", row, ok)
	}

	chat := func(requestID, model string) {
		t.Helper()
		status, _, body := s.chatRequest(map[string]string{"X-Request-ID": requestID}, fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"warm set %s"}]}`, model, requestID))
		if status != http.StatusOK {
			t.Fatalf("chat %s for %s status=%d body=%s", requestID, model, status, body)
		}
	}
	chat("44444444-4444-4444-8444-444444444441", settlementFixtureModelID)
	chat("44444444-4444-4444-8444-444444444442", memberModel)
	if got := warm.ServedModels(); len(got) != 2 || got[0] != settlementFixtureModelID || got[1] != memberModel {
		t.Fatalf("warm provider served models = %v", got)
	}
	if fallback.Hits() != 0 {
		t.Fatalf("fallback served %d requests before the eviction", fallback.Hits())
	}

	snaps := waitForWarmRouteSnapshots(t, s, 2)
	wantHash := map[string]string{settlementFixtureModelID: s.modelHash, memberModel: memberHash}
	for _, snap := range snaps {
		if snap.ProviderID != warmID || snap.ReportedHash != wantHash[snap.ModelID] || snap.ExpectedHash != wantHash[snap.ModelID] || snap.ServedModelDispatch != 1 {
			t.Fatalf("route snapshot = %+v, want the serving member's model and hash, flagged as an entry dispatch", snap)
		}
	}
	if snaps[0].ModelID != settlementFixtureModelID || snaps[1].ModelID != memberModel {
		t.Fatalf("route snapshot models = %s, %s", snaps[0].ModelID, snaps[1].ModelID)
	}
	verdicts := waitForSettlementVerdicts(t, s, 2)
	if len(verdicts) < 2 {
		t.Fatalf("settlement verdicts=%d want 2", len(verdicts))
	}
	for _, v := range verdicts {
		var snap warmRouteSnapshotRow
		for _, candidate := range snaps {
			if candidate.RequestID == v.RequestID && candidate.AttemptN == int(v.AttemptN) {
				snap = candidate
			}
		}
		if v.ReceiptResult != "valid" || !v.ModelHash.Valid || v.ModelHash.String != wantHash[snap.ModelID] {
			t.Fatalf("verdict %+v for snapshot %+v, want a valid receipt naming the serving member's hash", v, snap)
		}
	}
	credits := waitForLedgerCredits(t, s, 2)
	primaryCredit, memberCredit := creditFor(t, credits, snaps[0]), creditFor(t, credits, snaps[1])
	if primaryCredit.PromptRatePerMtok == memberCredit.PromptRatePerMtok && primaryCredit.CompletionRatePerMtok == memberCredit.CompletionRatePerMtok {
		t.Fatalf("both models priced alike: primary=%+v member=%+v", primaryCredit, memberCredit)
	}
	if primaryCredit.PromptRatePerMtok != buyerPaidPathPromptRate || primaryCredit.CompletionRatePerMtok != buyerPaidPathCompletionRate {
		t.Fatalf("primary credit rates %d/%d, want the llama rate-card row", primaryCredit.PromptRatePerMtok, primaryCredit.CompletionRatePerMtok)
	}
	if memberCredit.PromptRatePerMtok != 50000 || memberCredit.CompletionRatePerMtok != 100000 {
		t.Fatalf("member credit rates %d/%d, want the %s rate-card row 50000/100000", memberCredit.PromptRatePerMtok, memberCredit.CompletionRatePerMtok, warmMemberAutotuneKey)
	}

	// Eviction: the warm provider drops the member before the coordinator
	// has seen a heartbeat without it, while the fallback's member warms.
	warm.setWarmMember(memberModel, func(m *fakeWarmMember) { m.notLoaded = true })
	fallback.setWarmMember(memberModel, func(m *fakeWarmMember) { m.state = "warm" })
	s.waitForWarmEntry(fallbackID, memberModel, true, func(r warmPoolzRow) bool { return r.RoutingEligible })
	chat("44444444-4444-4444-8444-444444444443", memberModel)
	warm.warmMu.Lock()
	evicted := warm.warmMembers[0].evicted
	warm.warmMu.Unlock()
	if !evicted {
		t.Fatal("the warm provider's member was never dispatched to: model_not_loaded failover not exercised")
	}
	if got := fallback.ServedModels(); len(got) != 1 || got[0] != memberModel {
		t.Fatalf("fallback served models = %v, want the failed-over member request", got)
	}
	if got := warm.ServedModels(); len(got) != 2 {
		t.Fatalf("warm provider served %v after eviction, want no new completion", got)
	}

	// The next heartbeat drops the member; its model stays served by the
	// fallback. The warm provider is left with a warm set of one, which is a
	// legacy session: one /poolz row without entry fields, still routed.
	s.waitForWarmEntry(warmID, memberModel, false, nil)
	s.waitForWarmEntry(warmID, "", true, func(r warmPoolzRow) bool { return r.RoutingEligible && r.Primary == nil })
	chat("44444444-4444-4444-8444-444444444444", memberModel)
	if got := fallback.ServedModels(); len(got) != 2 {
		t.Fatalf("fallback served models = %v, want the post-eviction request", got)
	}
	chat("44444444-4444-4444-8444-444444444445", settlementFixtureModelID)
	if got := warm.ServedModels(); len(got) != 3 || got[2] != "" {
		t.Fatalf("warm provider served models = %q, want its primary still routed without a served model", got)
	}

	snaps = waitForWarmRouteSnapshots(t, s, 5)
	credits = waitForLedgerCredits(t, s, 5)
	var fallbackSnaps int
	for _, snap := range snaps {
		if snap.ProviderID == warmID && snap.RequestID == "44444444-4444-4444-8444-444444444445" && snap.ServedModelDispatch != 0 {
			t.Fatalf("one-member route snapshot = %+v, want served_model_dispatch 0", snap)
		}
		if snap.ProviderID != fallbackID {
			continue
		}
		fallbackSnaps++
		if snap.ModelID != memberModel || snap.ReportedHash != memberHash || snap.ServedModelDispatch != 1 {
			t.Fatalf("fallback route snapshot = %+v", snap)
		}
		if c := creditFor(t, credits, snap); c.PromptRatePerMtok != 50000 || c.CompletionRatePerMtok != 100000 {
			t.Fatalf("fallback credit rates %d/%d, want the member's", c.PromptRatePerMtok, c.CompletionRatePerMtok)
		}
	}
	if fallbackSnaps != 2 {
		t.Fatalf("fallback route snapshots = %d, want 2", fallbackSnaps)
	}
}

// SPEC-002-R011: a new CLI with one model sends warm_models with only its
// primary entry. That warm set of one is a legacy session end to end: one
// /poolz row without entry fields, a dispatch without a served model, and a
// route snapshot that is not a served-model dispatch.
func TestJourneyWarmSetOfOneIsLegacy(t *testing.T) {
	const providerID = "prov-warm-one"
	s := newScenario(t, scenarioOpts{
		seedAccount:               true,
		settlementReceiptProvider: true,
		providerID:                providerID,
		providerSetup:             func(fp *fakeProvider) { fp.warmSetOfOne = true },
	})
	prov := s.fakeProvs[0]
	var row warmPoolzRow
	deadline := time.Now().Add(15 * time.Second)
	for {
		var rows []warmPoolzRow
		for _, r := range s.warmPoolzRows() {
			if r.ProviderID == providerID {
				rows = append(rows, r)
			}
		}
		if len(rows) == 1 && rows[0].RoutingEligible {
			row = rows[0]
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("one-member provider /poolz rows = %+v, want one routable row", rows)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if row.ServedModel != "" || row.Primary != nil || row.WarmState != "" {
		t.Fatalf("one-member /poolz row = %+v, want a legacy row without entry fields", row)
	}
	status, _, body := s.chatRequest(map[string]string{"X-Request-ID": "55555555-5555-4555-8555-555555555551"},
		fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":"warm set of one"}]}`, settlementFixtureModelID))
	if status != http.StatusOK {
		t.Fatalf("chat status=%d body=%s", status, body)
	}
	if got := prov.ServedModels(); len(got) != 1 || got[0] != "" {
		t.Fatalf("served-model headers = %q, want one request without a served model", got)
	}
	snaps := waitForWarmRouteSnapshots(t, s, 1)
	if snaps[0].ProviderID != providerID || snaps[0].ModelID != settlementFixtureModelID || snaps[0].ServedModelDispatch != 0 {
		t.Fatalf("route snapshot = %+v, want the legacy provider-wide snapshot (served_model_dispatch 0)", snaps[0])
	}
}
