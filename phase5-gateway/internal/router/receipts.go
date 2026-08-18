package router

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
)

type buyerReceiptView struct {
	SchemaVersion             string `json:"schema_version"`
	RequestID                 string `json:"request_id"`
	Surface                   string `json:"surface"`
	PendingQuarantinedVisible bool   `json:"pending_quarantined_visible"`
	Attempts                  []any  `json:"attempts"`
}

func (s *Server) handleBuyerReceipt(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w.Header())
	w.Header().Add("Vary", "Authorization")
	w.Header().Add("Vary", "X-Api-Key")
	w.Header().Add("Vary", "X-Demo-Token")
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	requestID := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/v1/receipts/"))
	if requestID == "" || strings.Contains(requestID, "/") {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
		return
	}
	operator := operatorBearerAuthorized(r.Header, s.cfg.Coordinator.OperatorKey)
	accountID := ""
	if !operator {
		authn, ok := s.authenticateAny(w, r)
		if !ok {
			return
		}
		if authn.Demo {
			writeError(w, http.StatusForbidden, "permission_error", "demo_receipt_forbidden", "Demo tokens cannot retrieve receipts")
			return
		}
		switch {
		case authn.Bearer != nil:
			accountID = authn.Bearer.AccountID
		case authn.WalletSession != nil:
			accountID = authn.WalletSession.Session.AccountID
		default:
			writeError(w, http.StatusUnauthorized, "authentication_error", "missing_bearer_token", "Missing bearer token")
			return
		}
	}
	view, status, err := s.fetchCoordinatorBuyerReceipt(r, accountID, requestID, operator)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_receipt_error", "Could not load receipt")
		return
	}
	switch status {
	case http.StatusForbidden:
		writeError(w, http.StatusForbidden, "permission_error", "receipt_forbidden", "Receipt does not belong to this account")
	case http.StatusNotFound:
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
	case http.StatusOK:
		if containsForbiddenReceiptMaterial(view) {
			writeError(w, http.StatusBadGateway, "api_error", "coordinator_receipt_error", "Could not load receipt")
			return
		}
		writeJSON(w, http.StatusOK, view)
	default:
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_receipt_error", "Could not load receipt")
	}
}

func (s *Server) fetchCoordinatorBuyerReceipt(r *http.Request, accountID, requestID string, operator bool) (buyerReceiptView, int, error) {
	base := strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")
	if base == "" {
		return buyerReceiptView{}, 0, errCoordinatorURLMissing()
	}
	u, err := url.Parse(base + "/internal/settlement/receipts")
	if err != nil {
		return buyerReceiptView{}, 0, err
	}
	q := u.Query()
	q.Set("request_id", requestID)
	if operator {
		q.Set("operator", "1")
	} else {
		q.Set("account_id", accountID)
	}
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u.String(), nil)
	if err != nil {
		return buyerReceiptView{}, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	req.Header.Set("X-Request-ID", requestID)
	resp, err := s.client.Do(req)
	if err != nil {
		return buyerReceiptView{}, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusNotFound {
		return buyerReceiptView{}, resp.StatusCode, nil
	}
	if resp.StatusCode != http.StatusOK {
		return buyerReceiptView{}, resp.StatusCode, nil
	}
	var view buyerReceiptView
	if err := json.Unmarshal(body, &view); err != nil {
		return buyerReceiptView{}, 0, err
	}
	if view.Attempts == nil {
		view.Attempts = []any{}
	}
	return view, http.StatusOK, nil
}

func containsForbiddenReceiptMaterial(view buyerReceiptView) bool {
	raw, err := json.Marshal(view)
	if err != nil {
		return true
	}
	lower := strings.ToLower(string(raw))
	for _, needle := range []string{
		"raw_prompt", "raw_output", "x-macprovider-receipt",
		"bearer ", "begin private", "prompt_text", "output_text",
	} {
		if strings.Contains(lower, needle) {
			return true
		}
	}
	return false
}

type missingCoordinatorURL struct{}

func errCoordinatorURLMissing() error { return missingCoordinatorURL{} }
func (missingCoordinatorURL) Error() string {
	return "coordinator operator URL is not configured"
}
