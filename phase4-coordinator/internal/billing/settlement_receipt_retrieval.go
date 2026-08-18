package billing

import (
	"context"
	"fmt"
	"net/http"
	"strings"
)

const buyerReceiptViewSchema = "macprovider.buyer-receipt-view.v1"

// BuyerReceiptView is the metadata-only buyer retrieval payload (SPEC-022-R006).
// It MUST NOT include raw prompts, raw outputs, signed wire envelopes, or keys.
type BuyerReceiptView struct {
	SchemaVersion             string                    `json:"schema_version"`
	RequestID                 string                    `json:"request_id"`
	Surface                   string                    `json:"surface"`
	PendingQuarantinedVisible bool                      `json:"pending_quarantined_visible"`
	Attempts                  []BuyerReceiptAttemptView `json:"attempts"`
}

type BuyerReceiptAttemptView struct {
	AttemptN                      int64  `json:"attempt_n"`
	SettlementOutcome             string `json:"settlement_outcome"`
	ReceiptResult                 string `json:"receipt_result"`
	Reason                        string `json:"reason,omitempty"`
	Closed                        bool   `json:"closed"`
	TerminalState                 string `json:"terminal_state,omitempty"`
	TerminalStateTSUnixMS         int64  `json:"terminal_state_ts_unix_ms,omitempty"`
	PendingDeadlineUnixMS         int64  `json:"pending_deadline_unix_ms,omitempty"`
	PromptHash                    string `json:"prompt_hash,omitempty"`
	OutputHash                    string `json:"output_hash,omitempty"`
	UsageDigest                   string `json:"usage_digest,omitempty"`
	RouteSnapshotDigest           string `json:"route_snapshot_digest,omitempty"`
	CatalogID                     string `json:"catalog_id,omitempty"`
	ModelID                       string `json:"model_id,omitempty"`
	ModelHash                     string `json:"model_hash,omitempty"`
	ProviderReceiptKeyFingerprint string `json:"provider_receipt_key_fingerprint,omitempty"`
	ReceiptProfile                string `json:"receipt_profile,omitempty"`
}

// LookupBuyerReceipt returns a metadata view for an owning buyer or operator.
// HTTP status is 200, 403 (authenticated non-owner), or 404 (unknown id).
func (s *Store) LookupBuyerReceipt(ctx context.Context, accountID, requestID string, operator bool) (BuyerReceiptView, int, error) {
	requestID = strings.TrimSpace(requestID)
	accountID = strings.TrimSpace(accountID)
	if requestID == "" {
		return BuyerReceiptView{}, http.StatusNotFound, nil
	}
	if !operator && accountID == "" {
		return BuyerReceiptView{}, http.StatusNotFound, nil
	}
	owners, err := s.receiptRequestOwners(ctx, requestID)
	if err != nil {
		return BuyerReceiptView{}, 0, err
	}
	if len(owners) == 0 {
		return BuyerReceiptView{}, http.StatusNotFound, nil
	}
	authorizedAccount := ""
	if operator {
		authorizedAccount = owners[0]
	} else {
		for _, owner := range owners {
			if owner == accountID {
				authorizedAccount = owner
				break
			}
		}
		if authorizedAccount == "" {
			return BuyerReceiptView{}, http.StatusForbidden, nil
		}
	}
	internalIDs, err := s.requestIDsForExternalRequest(ctx, authorizedAccount, requestID, 0)
	if err != nil {
		return BuyerReceiptView{}, 0, err
	}
	seen := map[string]bool{}
	var ids []string
	for _, id := range append([]string{requestID}, internalIDs...) {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
	}
	view := BuyerReceiptView{
		SchemaVersion:             buyerReceiptViewSchema,
		RequestID:                 requestID,
		Surface:                   "metadata",
		PendingQuarantinedVisible: true,
		Attempts:                  []BuyerReceiptAttemptView{},
	}
	accountScope := AccountScopeForSettlement(authorizedAccount)
	for _, id := range ids {
		rows, err := s.requestSettlementVerdicts(ctx, accountScope, id)
		if err != nil {
			return BuyerReceiptView{}, 0, err
		}
		for _, row := range rows {
			authz, found, err := s.GetSettlementReceiptAuthorization(ctx, SettlementReceiptIdentity{
				AccountScope: accountScope,
				RequestID:    id,
				AttemptN:     row.attemptN,
				ProviderID:   row.providerID,
			})
			if err != nil {
				return BuyerReceiptView{}, 0, fmt.Errorf("receipt authorization: %w", err)
			}
			if !found {
				continue
			}
			view.Attempts = append(view.Attempts, buyerReceiptAttemptFromAuthorization(authz))
		}
	}
	return view, http.StatusOK, nil
}

func (s *Store) receiptRequestOwners(ctx context.Context, requestID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT account_id
  FROM request_log
 WHERE account_id IS NOT NULL AND account_id != ''
   AND (request_id = ? OR external_request_id = ?)
 GROUP BY account_id
 ORDER BY MIN(id) ASC`, requestID, requestID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var owners []string
	for rows.Next() {
		var accountID string
		if err := rows.Scan(&accountID); err != nil {
			return nil, err
		}
		owners = append(owners, accountID)
	}
	return owners, rows.Err()
}

func buyerReceiptAttemptFromAuthorization(authz SettlementReceiptAuthorization) BuyerReceiptAttemptView {
	return BuyerReceiptAttemptView{
		AttemptN:                      authz.AttemptN,
		SettlementOutcome:             authz.SettlementOutcome,
		ReceiptResult:                 authz.ReceiptResult,
		Reason:                        authz.Reason,
		Closed:                        authz.Closed,
		TerminalState:                 authz.TerminalState,
		TerminalStateTSUnixMS:         authz.TerminalStateTSUnixMS,
		PendingDeadlineUnixMS:         authz.PendingDeadlineUnixMS,
		PromptHash:                    authz.PromptHash,
		OutputHash:                    authz.OutputHash,
		UsageDigest:                   authz.UsageDigest,
		RouteSnapshotDigest:           authz.RouteSnapshotDigest,
		CatalogID:                     authz.CatalogID,
		ModelID:                       authz.ModelID,
		ModelHash:                     authz.ModelHash,
		ProviderReceiptKeyFingerprint: authz.ProviderReceiptKeyFingerprint,
		ReceiptProfile:                authz.ReceiptProfile,
	}
}
