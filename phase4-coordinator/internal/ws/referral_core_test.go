package ws

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestReferralCloseReasonPreservesLifecycleToken(t *testing.T) {
	cases := map[error]string{
		auth.ErrReferralInvalid:   "referral_invalid",
		auth.ErrReferralExpired:   "referral_expired",
		auth.ErrReferralRevoked:   "referral_revoked",
		auth.ErrReferralExhausted: "referral_exhausted",
		auth.ErrReferralConflict:  "referral_invalid",
	}
	for err, want := range cases {
		if got := referralCloseReason(err); got != want {
			t.Fatalf("referralCloseReason(%v)=%q want=%q", err, got, want)
		}
	}
}

func TestAdmissionReservationIsNotDurableUntilCredentialCommit(t *testing.T) {
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := NewSQLiteAdmissionStore(db)
	if err != nil {
		t.Fatal(err)
	}
	manager := NewAdmissionManager(config.AdmissionConfig{
		ProvisionalAdmissionRatePerHour: 1,
		ProvisionalPoolMax:              1,
	}, func() time.Time { return now })
	manager.SetPersistence(store, func(err error) { t.Fatalf("persist admission: %v", err) })
	failedHello := Hello{ProviderID: "provider-a", Hostname: "host-a", ModelID: "model", BinaryVersion: "1.2.0"}
	if tier, code, reason := manager.ReserveAdmission(failedHello, false, 0); tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("reserve tier=%s code=%d reason=%q", tier, code, reason)
	}
	if records := manager.Records(nil); len(records) != 0 {
		t.Fatalf("reservation created durable records: %+v", records)
	}

	committedHello := Hello{ProviderID: "provider-b", Hostname: "host-b", ModelID: "model", BinaryVersion: "1.2.0"}
	if _, code, _ := manager.ReserveAdmission(committedHello, false, 0); code != CloseProvisionalPoolFull {
		t.Fatalf("reserve while credential pending code=%d, want %d", code, CloseProvisionalPoolFull)
	}
	manager.ReleasePendingProvisional()
	if records := manager.Records(nil); len(records) != 0 {
		t.Fatalf("failed credential reservation created durable records: %+v", records)
	}
	if tier, code, reason := manager.ReserveAdmission(committedHello, false, 0); tier != pool.TierProvisional || code != 0 || reason != "" {
		t.Fatalf("reserve after failure release tier=%s code=%d reason=%q", tier, code, reason)
	}
	if tier := manager.CommitReservedAdmission(committedHello, false); tier != pool.TierProvisional {
		t.Fatalf("commit tier=%s", tier)
	}
	if records := manager.Records(nil); len(records) != 1 || records[0].ProviderID != committedHello.ProviderID {
		t.Fatalf("committed records=%+v", records)
	}
	manager.ReleasePendingProvisional()
}
