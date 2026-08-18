package billing

import (
	"context"
	"net/http"
	"testing"
)

func TestLookupBuyerReceiptOwnershipAndMissing(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertBuyerReceiptRequestLog(t, store, "acct_owner", "req_owned", "ext_owned")
	insertBuyerReceiptRequestLog(t, store, "acct_other", "req_other", "ext_other")

	view, status, err := store.LookupBuyerReceipt(context.Background(), "acct_owner", "ext_owned", false)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK {
		t.Fatalf("owner status=%d want 200", status)
	}
	if view.RequestID != "ext_owned" || view.Surface != "metadata" || !view.PendingQuarantinedVisible {
		t.Fatalf("view=%#v", view)
	}
	if view.Attempts == nil {
		t.Fatal("attempts must be a JSON array, not null")
	}

	_, status, err = store.LookupBuyerReceipt(context.Background(), "acct_other", "ext_owned", false)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusForbidden {
		t.Fatalf("stranger status=%d want 403", status)
	}

	_, status, err = store.LookupBuyerReceipt(context.Background(), "acct_owner", "missing-request", false)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusNotFound {
		t.Fatalf("missing status=%d want 404", status)
	}

	view, status, err = store.LookupBuyerReceipt(context.Background(), "", "ext_owned", true)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || view.RequestID != "ext_owned" {
		t.Fatalf("operator status=%d view=%#v", status, view)
	}
}

func insertBuyerReceiptRequestLog(t *testing.T, store *Store, accountID, requestID, externalRequestID string) {
	t.Helper()
	if _, err := store.db.Exec(`
INSERT INTO request_log (
    ts_utc, request_id, external_request_id, account_id, model,
    latency_ms, routing_ms, status, stream
) VALUES ('2026-01-01T00:00:00Z', ?, ?, ?, 'model-a', 1, 1, 200, 0)`,
		requestID, externalRequestID, accountID,
	); err != nil {
		t.Fatal(err)
	}
}
