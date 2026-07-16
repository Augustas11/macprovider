package referralapi

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	_ "modernc.org/sqlite"
)

func openServingEvidenceDB(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "billing.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`
CREATE TABLE settlement_receipt_verdicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    received_at_unix_ms INTEGER NOT NULL,
    closed INTEGER NOT NULL,
    settlement_outcome TEXT NOT NULL,
    receipt_result TEXT NOT NULL
)`); err != nil {
		t.Fatal(err)
	}
	return path
}

func insertServingVerdict(t *testing.T, path, providerID string, when time.Time, closed bool, outcome, result string) int64 {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	closedValue := 0
	if closed {
		closedValue = 1
	}
	inserted, err := db.Exec(`INSERT INTO settlement_receipt_verdicts
        (provider_id, received_at_unix_ms, closed, settlement_outcome, receipt_result)
        VALUES (?, ?, ?, ?, ?)`, providerID, when.UnixMilli(), closedValue, outcome, result)
	if err != nil {
		t.Fatal(err)
	}
	id, err := inserted.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

type servingQualificationRecorder struct {
	mu       sync.Mutex
	seen     map[string]string
	servedAt map[string]time.Time
}

func (s *servingQualificationRecorder) QualifyProviderReferral(_ context.Context, _ auth.ReferralPolicy, providerID, evidenceID string, servedAt, _ time.Time) (auth.ProviderReferral, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.seen == nil {
		s.seen = make(map[string]string)
		s.servedAt = make(map[string]time.Time)
	}
	if _, ok := s.seen[providerID]; ok {
		return auth.ProviderReferral{}, false, nil
	}
	s.seen[providerID] = evidenceID
	s.servedAt[providerID] = servedAt
	return auth.ProviderReferral{}, true, nil
}

func TestServingReconcilerIsOnlyPathFromBuyerEvidenceToInvite(t *testing.T) {
	path := openServingEvidenceDB(t)
	now := time.Date(2026, 7, 16, 9, 0, 0, 0, time.UTC)
	insertServingVerdict(t, path, "provider-authoritative", now.Add(-time.Minute), true, "verified", "valid")
	store := openAdvocacyStore(t)
	policy := advocacyPolicy()

	locked, err := store.ProviderReferralStatus(context.Background(), policy, "provider-authoritative")
	if !errors.Is(err, auth.ErrReferralLocked) || locked.Code != "" || locked.FirstServingSeen {
		t.Fatalf("evidence without reconcile unlocked invite: status=%+v err=%v", locked, err)
	}
	var qualifications int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_serving_qualifications`).Scan(&qualifications); err != nil {
		t.Fatal(err)
	}
	if qualifications != 0 {
		t.Fatalf("pre-reconcile qualifications=%d", qualifications)
	}

	reconciler := ServingReconciler{
		Source: SQLiteServingEvidence{Path: path},
		Store:  store,
		Policy: policy,
		Now:    func() time.Time { return now },
	}
	created, err := reconciler.Reconcile(context.Background())
	if err != nil || created != 1 {
		t.Fatalf("created=%d err=%v", created, err)
	}
	status, err := store.ProviderReferralStatus(context.Background(), policy, "provider-authoritative")
	if err != nil || !status.FirstServingSeen || status.SocialState != auth.SocialStateEligible || status.Code == "" || status.BaseCapacity != 1 {
		t.Fatalf("qualified status=%+v err=%v", status, err)
	}
	if created, err := reconciler.Reconcile(context.Background()); err != nil || created != 0 {
		t.Fatalf("duplicate reconcile created=%d err=%v", created, err)
	}
	var qualificationRows, issuerRows, auditRows int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_serving_qualifications WHERE provider_id = ?`, "provider-authoritative").Scan(&qualificationRows); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_issuers WHERE provider_id = ?`, "provider-authoritative").Scan(&issuerRows); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'serving_qualified'`, "provider-authoritative").Scan(&auditRows); err != nil {
		t.Fatal(err)
	}
	if qualificationRows != 1 || issuerRows != 1 || auditRows != 1 {
		t.Fatalf("qualification=%d issuers=%d audit=%d", qualificationRows, issuerRows, auditRows)
	}
}

func TestServingReconcilerAcceptsOnlyEarliestClosedVerifiedValidEvidence(t *testing.T) {
	path := openServingEvidenceDB(t)
	base := time.Date(2026, 7, 16, 9, 0, 0, 0, time.UTC)
	insertServingVerdict(t, path, "provider-a", base.Add(5*time.Minute), true, "verified", "valid")
	wantID := insertServingVerdict(t, path, "provider-a", base, true, "verified", "valid")
	insertServingVerdict(t, path, "provider-pending", base, false, "verified", "valid")
	insertServingVerdict(t, path, "provider-quarantined", base, true, "quarantined", "valid")
	insertServingVerdict(t, path, "provider-invalid", base, true, "verified", "invalid")
	insertServingVerdict(t, path, "", base, true, "verified", "valid")

	store := &servingQualificationRecorder{}
	reconciler := ServingReconciler{Source: SQLiteServingEvidence{Path: path}, Store: store, BatchSize: 1}
	created, err := reconciler.Reconcile(context.Background())
	if err != nil || created != 1 {
		t.Fatalf("created=%d err=%v", created, err)
	}
	if got := store.servedAt["provider-a"]; !got.Equal(base) {
		t.Fatalf("served_at=%v want=%v", got, base)
	}
	if got := store.seen["provider-a"]; got != "settlement-verdict:"+strconv.FormatInt(wantID, 10) {
		t.Fatalf("evidence=%q", got)
	}
	if len(store.seen) != 1 {
		t.Fatalf("qualified=%v", store.seen)
	}
}

func TestServingReconcilerConcurrentDuplicateAndLateOutOfOrderEvidenceConverge(t *testing.T) {
	path := openServingEvidenceDB(t)
	base := time.Date(2026, 7, 16, 9, 0, 0, 0, time.UTC)
	insertServingVerdict(t, path, "provider-race", base.Add(5*time.Minute), true, "verified", "valid")
	winnerID := insertServingVerdict(t, path, "provider-race", base, true, "verified", "valid")
	store := openAdvocacyStore(t)
	reconciler := ServingReconciler{
		Source: SQLiteServingEvidence{Path: path},
		Store:  store,
		Policy: advocacyPolicy(),
		Now:    func() time.Time { return base.Add(10 * time.Minute) },
	}

	var wg sync.WaitGroup
	results := make(chan int, 2)
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			created, err := reconciler.Reconcile(context.Background())
			results <- created
			errs <- err
		}()
	}
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	total := 0
	for created := range results {
		total += created
	}
	if total != 1 {
		t.Fatalf("concurrent created total=%d", total)
	}

	var durableEvidence, durableAt string
	if err := store.DB().QueryRow(`SELECT evidence_id, evidence_at FROM referral_serving_qualifications WHERE provider_id = ?`, "provider-race").Scan(&durableEvidence, &durableAt); err != nil {
		t.Fatal(err)
	}
	wantEvidence := "settlement-verdict:" + strconv.FormatInt(winnerID, 10)
	if durableEvidence != wantEvidence || durableAt != base.Format(time.RFC3339) {
		t.Fatalf("durable evidence=%q at=%q want=%q at=%q", durableEvidence, durableAt, wantEvidence, base.Format(time.RFC3339))
	}

	// A receipt arriving late with an earlier timestamp corrects only the
	// durable evidence tuple; it does not issue another invite allocation.
	lateID := insertServingVerdict(t, path, "provider-race", base.Add(-time.Minute), true, "verified", "valid")
	if created, err := reconciler.Reconcile(context.Background()); err != nil || created != 0 {
		t.Fatalf("late evidence reconcile created=%d err=%v", created, err)
	}
	var afterEvidence, afterAt, firstServingAt string
	if err := store.DB().QueryRow(`
SELECT q.evidence_id, q.evidence_at, i.first_serving_at
  FROM referral_serving_qualifications q
  JOIN referral_issuers i ON i.issuer_id = q.issuer_id
 WHERE q.provider_id = ?`, "provider-race").Scan(&afterEvidence, &afterAt, &firstServingAt); err != nil {
		t.Fatal(err)
	}
	wantLateEvidence := "settlement-verdict:" + strconv.FormatInt(lateID, 10)
	wantLateAt := base.Add(-time.Minute).Format(time.RFC3339)
	if afterEvidence != wantLateEvidence || afterAt != wantLateAt || firstServingAt != wantLateAt {
		t.Fatalf("corrected evidence=%q at=%q first=%q want=%q at=%q", afterEvidence, afterAt, firstServingAt, wantLateEvidence, wantLateAt)
	}
	var issuerRows, correctionAudits int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_issuers WHERE provider_id = ?`, "provider-race").Scan(&issuerRows); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'serving_qualified' AND outcome = 'corrected'`, "provider-race").Scan(&correctionAudits); err != nil {
		t.Fatal(err)
	}
	if issuerRows != 1 || correctionAudits != 1 {
		t.Fatalf("issuer rows=%d correction audits=%d", issuerRows, correctionAudits)
	}
}
