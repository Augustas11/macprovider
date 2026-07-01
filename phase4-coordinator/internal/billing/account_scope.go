package billing

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func AccountScopeForSettlement(accountID string) string {
	accountID = strings.TrimSpace(accountID)
	if accountID == "" {
		return "legacy_direct"
	}
	sum := sha256.Sum256([]byte("spec015-account-scope-v1:" + accountID))
	return "acct_sha256:" + hex.EncodeToString(sum[:])
}

func SettlementAccountScopeHash(accountScope string) string {
	sum := sha256.Sum256([]byte("settlement_receipt_account_scope_v1:" + accountScope))
	return hex.EncodeToString(sum[:])
}

func SettlementAccountScopeHashForAccountID(accountID string) string {
	return SettlementAccountScopeHash(AccountScopeForSettlement(accountID))
}

func VerifiedModelSettlementMode(cfg config.SettlementConfig) string {
	switch strings.TrimSpace(cfg.VerifiedModelSettlementMode) {
	case RouteSnapshotModeObserve:
		return RouteSnapshotModeObserve
	default:
		return RouteSnapshotModeEnforce
	}
}
