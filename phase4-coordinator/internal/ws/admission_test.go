package ws

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestAdmissionManagerTiersRateLimitAndQuota(t *testing.T) {
	now := time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC)
	adm := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              10,
		ProvisionalQuotaPerHour:         2,
		ProvisionalTierWeight:           0.3,
	}, func() time.Time { return now })

	pinned, code, reason := adm.Admit(Hello{ProviderID: "m4-anon"}, true, 0)
	if pinned != pool.TierPinned || code != 0 || reason != "" {
		t.Fatalf("pinned admission = tier:%s code:%d reason:%q", pinned, code, reason)
	}

	hello := Hello{ProviderID: "new-1", Hostname: "host", ModelID: "model", BinaryVersion: "1.2.0"}
	tier, code, reason := adm.Admit(hello, false, 0)
	if tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("first provisional = tier:%s code:%d reason:%q", tier, code, reason)
	}

	_, code, _ = adm.Admit(Hello{ProviderID: "new-2"}, false, 0)
	if code != CloseProvisionalRateLimited {
		t.Fatalf("second provisional code = %d, want %d", code, CloseProvisionalRateLimited)
	}

	provider := pool.Provider{ProviderID: "new-1", Tier: pool.TierProvisional}
	if !adm.CheckQuota(provider) {
		t.Fatal("quota unexpectedly blocked first request")
	}
	if !adm.TryReserveRequest(provider) {
		t.Fatal("first reservation blocked")
	}
	if !adm.TryReserveRequest(provider) {
		t.Fatal("second reservation blocked")
	}
	if adm.TryReserveRequest(provider) {
		t.Fatal("quota allowed third reservation")
	}
	adm.RefundRequest(provider)
	if !adm.TryReserveRequest(provider) {
		t.Fatal("reservation after refund blocked")
	}

	if previous, ok := adm.Promote("new-1"); !ok || previous != "provisional" {
		t.Fatalf("promote previous=%q ok=%v", previous, ok)
	}
	adm.Reject("new-1", "test")
	if !adm.Rejected("new-1") {
		t.Fatal("provider not rejected")
	}
}
