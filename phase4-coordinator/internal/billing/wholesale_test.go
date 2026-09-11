package billing

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestGenerateWholesaleStatementPaidVersusFreeSKU(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	store.SetWholesalePricing(RewardsConfig{
		GlobalMultiplier: 1,
		ProviderShare:    0.90,
		RateCard: map[string]RateCardEntry{
			"meta-llama/llama-3.2-3b-instruct": {PromptCreditsPerMtok: 13500, CompletionCreditsPerMtok: 27000},
		},
	}, 1.0)

	paidModel := "mlx-community/Llama-3.2-3B-Instruct-4bit"
	freeModel := "mlx-community/Llama-3.2-3B-Instruct-4bit-free"
	if !IsWholesaleFreeSKU(freeModel) || IsWholesaleFreeSKU(paidModel) {
		t.Fatalf("IsWholesaleFreeSKU paid=%v free=%v", IsWholesaleFreeSKU(paidModel), IsWholesaleFreeSKU(freeModel))
	}

	prompt, completion := int64(1000), int64(2000)
	ts := time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC)
	account := "acct_openrouter"
	for i, model := range []string{paidModel, freeModel} {
		row := requestlog.Row{
			TSUtc: ts, RequestID: "req-wholesale-" + model, AccountID: account, Model: model,
			PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
		}
		row.RequestID = "req-wholesale-" + strings.ReplaceAll(model, "/", "-") + "-" + itoa(int64(i))
		if err := reqStore.Insert(context.Background(), row); err != nil {
			t.Fatal(err)
		}
	}

	paidBilled := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone,
		RateFor(store.wholesaleRewards.RateCard, paidModel), ParseMultiplierPPM(1), ParseShareBps(0.90))
	if paidBilled.ProviderCredits <= 0 || paidBilled.GrossCredits <= 0 {
		t.Fatalf("paid ComputeCredits=%+v", paidBilled)
	}
	freeBilled := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone,
		RateFor(store.wholesaleRewards.RateCard, freeModel), ParseMultiplierPPM(1), ParseShareBps(0.90))
	if freeBilled.ProviderCredits != paidBilled.ProviderCredits {
		t.Fatalf("free SKU must still earn provider credits: free=%d paid=%d", freeBilled.ProviderCredits, paidBilled.ProviderCredits)
	}

	stmt, err := store.GenerateWholesaleStatement(context.Background(), account, "2026-09", false)
	if err != nil {
		t.Fatalf("GenerateWholesaleStatement: %v", err)
	}
	if stmt.WholesaleStatementID == "" || strings.Contains(stmt.WholesaleStatementID, "invoice") {
		t.Fatalf("wholesale_statement_id=%q", stmt.WholesaleStatementID)
	}
	if stmt.Period != "2026-09" || stmt.AccountID != account || stmt.Status != wholesaleStatementDraft {
		t.Fatalf("stmt=%+v", stmt)
	}
	if len(stmt.LineItems) != 2 {
		t.Fatalf("line items=%d %+v", len(stmt.LineItems), stmt.LineItems)
	}
	var sawPaid, sawFree bool
	for _, item := range stmt.LineItems {
		switch item.Model {
		case paidModel:
			sawPaid = true
			if item.IsFree || item.USDMicro <= 0 || item.GrossCredits != paidBilled.GrossCredits {
				t.Fatalf("paid item=%+v billed=%+v", item, paidBilled)
			}
		case freeModel:
			sawFree = true
			if !item.IsFree || item.USDMicro != 0 || item.USD != "0" || item.GrossCredits != freeBilled.GrossCredits {
				t.Fatalf("free item must be $0 with credits recorded: %+v", item)
			}
		}
	}
	if !sawPaid || !sawFree {
		t.Fatalf("missing SKU rows: %+v", stmt.LineItems)
	}
	if stmt.USDMicro != creditsToUSDMicro(paidBilled.GrossCredits, 1) {
		t.Fatalf("statement usd_micro=%d want paid-only %d", stmt.USDMicro, creditsToUSDMicro(paidBilled.GrossCredits, 1))
	}
}

func TestWholesaleStatementAdminExport(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	store.SetWholesalePricing(testRewards(), 1.0)
	prompt, completion := int64(100), int64(50)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC), RequestID: "req-admin-ws",
		AccountID: "acct_or", Model: "model-a", PromptTokens: &prompt, CompletionTokens: &completion,
		Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	h := store.Handlers("operator", fakeTokens{}, true, 60)

	body, _ := json.Marshal(map[string]any{"account_id": "acct_or", "period": "2026-09"})
	req := httptest.NewRequest(http.MethodPost, wholesaleStatementsPath, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("POST status=%d body=%s", w.Code, w.Body.String())
	}
	var created WholesaleStatement
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.WholesaleStatementID == "" || created.USDMicro <= 0 {
		t.Fatalf("created=%+v", created)
	}
	raw, _ := json.Marshal(created)
	if bytes.Contains(raw, []byte("invoice_id")) || bytes.Contains(raw, []byte("buyer_invoice")) {
		t.Fatalf("response leaked forbidden identifier: %s", raw)
	}

	listReq := httptest.NewRequest(http.MethodGet, wholesaleStatementsPath+"?account_id=acct_or&period=2026-09", nil)
	listReq.Header.Set("Authorization", "Bearer operator")
	listW := httptest.NewRecorder()
	h.ServeHTTP(listW, listReq)
	if listW.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", listW.Code, listW.Body.String())
	}

	csvReq := httptest.NewRequest(http.MethodGet, wholesaleStatementsPath+"/"+created.WholesaleStatementID+"?format=csv", nil)
	csvReq.Header.Set("Authorization", "Bearer operator")
	csvW := httptest.NewRecorder()
	h.ServeHTTP(csvW, csvReq)
	if csvW.Code != http.StatusOK {
		t.Fatalf("csv status=%d body=%s", csvW.Code, csvW.Body.String())
	}
	if ct := csvW.Header().Get("Content-Type"); !strings.Contains(ct, "text/csv") {
		t.Fatalf("csv content-type=%q", ct)
	}
	if !strings.Contains(csvW.Body.String(), "wholesale_statement_id") || strings.Contains(csvW.Body.String(), "invoice_id") {
		t.Fatalf("csv=%s", csvW.Body.String())
	}

	if _, err := store.db.Exec(`UPDATE wholesale_period_statements SET status='issued' WHERE wholesale_statement_id=?`, created.WholesaleStatementID); err != nil {
		t.Fatal(err)
	}
	replay := httptest.NewRequest(http.MethodPost, wholesaleStatementsPath, bytes.NewReader(body))
	replay.Header.Set("Authorization", "Bearer operator")
	replayW := httptest.NewRecorder()
	h.ServeHTTP(replayW, replay)
	if replayW.Code != http.StatusConflict {
		t.Fatalf("issued replay status=%d want 409 body=%s", replayW.Code, replayW.Body.String())
	}
}
