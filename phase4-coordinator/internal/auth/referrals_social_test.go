package auth

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var testSocialShareURLHash = strings.Repeat("a", 64)

func socialReferralPolicy() ReferralPolicy {
	policy := coreReferralPolicy()
	policy.EnableSocialBonus = true
	policy.SocialBonusUses = 2
	policy.SocialBonusMaxGrants = 5
	policy.ChallengeTTL = 15 * time.Minute
	policy.SocialVerificationDwell = 30 * time.Minute
	return policy
}

func openSocialStoreAt(t *testing.T, path string) *Store {
	t.Helper()
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func openSocialStore(t *testing.T) *Store {
	t.Helper()
	return openSocialStoreAt(t, filepath.Join(t.TempDir(), "coordinator.db"))
}

func qualifyProvider(t *testing.T, store *Store, policy ReferralPolicy, providerID string, now time.Time) ProviderReferral {
	t.Helper()
	status, created, err := store.QualifyProviderReferral(context.Background(), policy, providerID, "settlement:"+providerID, now.Add(-time.Minute), now)
	if err != nil || !created {
		t.Fatalf("qualify status=%+v created=%t err=%v", status, created, err)
	}
	return status
}

func createPendingSocialVerification(t *testing.T, store *Store, policy ReferralPolicy, providerID, postID string, now time.Time) (ProviderReferral, SocialChallenge) {
	t.Helper()
	qualifyProvider(t, store, policy, providerID, now.Add(-time.Minute))
	challenge, err := store.CreateSocialChallenge(context.Background(), policy, providerID, now)
	if err != nil {
		t.Fatal(err)
	}
	status, err := store.CompleteSocialVerification(context.Background(), policy, providerID, challenge.Cleartext, postID, "456", testSocialShareURLHash, "x_api", now)
	if err != nil {
		t.Fatal(err)
	}
	return status, challenge
}

func TestQualificationIsAtomicIdempotentConcurrentAndDurable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator.db")
	first := openSocialStoreAt(t, path)
	second := openSocialStoreAt(t, path)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-qualified"

	locked, err := first.ProviderReferralStatus(context.Background(), policy, providerID)
	if !errors.Is(err, ErrReferralLocked) || locked.Code != "" {
		t.Fatalf("locked=%+v err=%v", locked, err)
	}

	type result struct {
		status  ProviderReferral
		created bool
		err     error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for i, store := range []*Store{first, second} {
		i, store := i, store
		go func() {
			<-start
			status, created, err := store.QualifyProviderReferral(context.Background(), policy, providerID, fmt.Sprintf("settlement-%d", i), now.Add(-time.Minute), now)
			results <- result{status, created, err}
		}()
	}
	close(start)
	createdCount := 0
	var issuerID string
	for range 2 {
		got := <-results
		if got.err != nil {
			t.Fatal(got.err)
		}
		if got.created {
			createdCount++
		}
		if issuerID == "" {
			issuerID = got.status.IssuerID
		} else if got.status.IssuerID != issuerID {
			t.Fatalf("issuer drift: %q != %q", got.status.IssuerID, issuerID)
		}
	}
	if createdCount != 1 {
		t.Fatalf("created count=%d, want 1", createdCount)
	}
	var qualificationRows, issuerRows, acceptedAudits, correctedAudits int
	var winningEvidence string
	if err := first.db.QueryRow(`SELECT COUNT(1), evidence_id FROM referral_serving_qualifications WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&qualificationRows, &winningEvidence); err != nil {
		t.Fatal(err)
	}
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_issuers WHERE campaign = ? AND issuer_id = ?`, policy.Campaign, issuerID).Scan(&issuerRows); err != nil {
		t.Fatal(err)
	}
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE event_kind = 'serving_qualified' AND outcome = 'accepted' AND provider_id = ?`, providerID).Scan(&acceptedAudits); err != nil {
		t.Fatal(err)
	}
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE event_kind = 'serving_qualified' AND outcome = 'corrected' AND provider_id = ?`, providerID).Scan(&correctedAudits); err != nil {
		t.Fatal(err)
	}
	if qualificationRows != 1 || issuerRows != 1 || acceptedAudits != 1 || correctedAudits > 1 || winningEvidence != "settlement-0" {
		t.Fatalf("qualification=%d issuer=%d accepted=%d corrected=%d evidence=%q", qualificationRows, issuerRows, acceptedAudits, correctedAudits, winningEvidence)
	}

	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openSocialStoreAt(t, path)
	status, created, err := reopened.QualifyProviderReferral(context.Background(), policy, providerID, "later-settlement", now, now.Add(time.Hour))
	if err != nil || created || status.IssuerID != issuerID {
		t.Fatalf("reopen retry status=%+v created=%t err=%v", status, created, err)
	}
	if _, _, err := reopened.QualifyProviderReferral(context.Background(), policy, "other-provider", winningEvidence, now, now.Add(time.Hour)); !errors.Is(err, ErrReferralQualificationConflict) {
		t.Fatalf("reused evidence err=%v", err)
	}
}

func TestQualificationRejectsLegacyUnsourcedIssuer(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	_, err := store.db.Exec(`INSERT INTO referral_issuers (issuer_id, code_type, key_id, campaign, provider_id, base_capacity, bonus_capacity, created_at, first_serving_at) VALUES ('legacy', 'P', ?, ?, 'legacy-provider', 1, 0, ?, ?)`, policy.CurrentKeyID, policy.Campaign, timeText(now), timeText(now))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.QualifyProviderReferral(context.Background(), policy, "legacy-provider", "receipt-legacy", now, now); !errors.Is(err, ErrReferralQualificationConflict) {
		t.Fatalf("legacy qualification err=%v", err)
	}
	if _, err := store.ProviderReferralStatus(context.Background(), policy, "legacy-provider"); !errors.Is(err, ErrReferralLocked) {
		t.Fatalf("legacy status err=%v", err)
	}
}

func TestSocialSubmissionReplayRecoversExactResponse(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-replay"
	qualifyProvider(t, store, policy, providerID, now.Add(-time.Minute))
	challenge, err := store.CreateSocialChallenge(context.Background(), policy, providerID, now)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.CompleteSocialVerification(context.Background(), policy, providerID, challenge.Cleartext, "123", "456", testSocialShareURLHash, "x_api", now)
	if err != nil || first.SocialState != SocialStatePending {
		t.Fatalf("first=%+v err=%v", first, err)
	}
	replayed, err := store.CompleteSocialVerification(context.Background(), policy, providerID, challenge.Cleartext, "123", "456", testSocialShareURLHash, "x_api", now.Add(time.Second))
	if err != nil || replayed.IssuerID != first.IssuerID || replayed.SocialState != SocialStatePending {
		t.Fatalf("replayed=%+v err=%v", replayed, err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, providerID, challenge.Cleartext, "124", "456", testSocialShareURLHash, "x_api", now.Add(time.Second)); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("mismatched replay err=%v", err)
	}
	var accepted, replayEvents int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'submission' AND outcome = 'accepted'`, providerID).Scan(&accepted); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'submission' AND outcome = 'replayed'`, providerID).Scan(&replayEvents); err != nil {
		t.Fatal(err)
	}
	if accepted != 1 || replayEvents != 1 {
		t.Fatalf("accepted=%d replayed=%d", accepted, replayEvents)
	}
}

func TestDurableSocialRateLimitSurvivesReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator.db")
	store := openSocialStoreAt(t, path)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 7, 0, 0, time.UTC)
	for i := 0; i < 2; i++ {
		allowed, err := store.ConsumeSocialRateLimit(context.Background(), policy, "provider-rate", "verify", now, 15*time.Minute, 2)
		if err != nil || !allowed {
			t.Fatalf("attempt %d allowed=%t err=%v", i, allowed, err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openSocialStoreAt(t, path)
	allowed, err := reopened.ConsumeSocialRateLimit(context.Background(), policy, "provider-rate", "verify", now.Add(time.Minute), 15*time.Minute, 2)
	if err != nil || allowed {
		t.Fatalf("denial allowed=%t err=%v", allowed, err)
	}
	allowed, err = reopened.ConsumeSocialRateLimit(context.Background(), policy, "provider-rate", "verify", now.Add(15*time.Minute), 15*time.Minute, 2)
	if err != nil || !allowed {
		t.Fatalf("next window allowed=%t err=%v", allowed, err)
	}
	var denied int
	if err := reopened.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = 'provider-rate' AND event_kind = 'rate_limit' AND outcome = 'denied'`).Scan(&denied); err != nil {
		t.Fatal(err)
	}
	if denied != 1 {
		t.Fatalf("denied audit=%d", denied)
	}
}

func TestSocialAuditIsRedactedAndImmutable(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	rawChallenge := "never-persist-this-challenge"
	if err := store.RecordSocialAudit(context.Background(), policy, "provider-audit", rawChallenge, "123", "456", "external_check", "rejected", "author_mismatch", now); err != nil {
		t.Fatal(err)
	}
	var subject, reason string
	if err := store.db.QueryRow(`SELECT subject_hash, reason FROM referral_social_audit WHERE provider_id = 'provider-audit'`).Scan(&subject, &reason); err != nil {
		t.Fatal(err)
	}
	if subject == "" || strings.Contains(subject, rawChallenge) || reason != "author_mismatch" {
		t.Fatalf("subject=%q reason=%q", subject, reason)
	}
	if _, err := store.db.Exec(`UPDATE referral_social_audit SET outcome = 'forged'`); err == nil {
		t.Fatal("audit update unexpectedly succeeded")
	}
	if _, err := store.db.Exec(`DELETE FROM referral_social_audit`); err == nil {
		t.Fatal("audit delete unexpectedly succeeded")
	}
}

func TestTransientRecheckUsesDurableBackoffAndLeaseRecovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator.db")
	store := openSocialStoreAt(t, path)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	createPendingSocialVerification(t, store, policy, "provider-backoff", "111", now)
	mature := now.Add(policy.SocialVerificationDwell)
	var calls atomic.Int32
	transient := func(context.Context, string, string, string) error {
		calls.Add(1)
		return ErrSocialRecheckTransient
	}
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, mature, transient); err != nil || granted != 0 {
		t.Fatalf("transient granted=%d err=%v", granted, err)
	}
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, mature.Add(30*time.Second), transient); err != nil || granted != 0 || calls.Load() != 1 {
		t.Fatalf("backoff granted=%d calls=%d err=%v", granted, calls.Load(), err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened := openSocialStoreAt(t, path)
	if granted, err := reopened.PromoteMaturedSocialVerifications(context.Background(), policy, mature.Add(time.Minute), func(context.Context, string, string, string) error { calls.Add(1); return nil }); err != nil || granted != 1 {
		t.Fatalf("reopen grant=%d calls=%d err=%v", granted, calls.Load(), err)
	}

	createPendingSocialVerification(t, reopened, policy, "provider-lease", "222", now)
	claim, ok, err := reopened.claimSocialRecheck(context.Background(), policy, mature)
	if err != nil || !ok {
		t.Fatalf("claim=%+v ok=%t err=%v", claim, ok, err)
	}
	other := openSocialStoreAt(t, path)
	var leaseCalls atomic.Int32
	if granted, err := other.PromoteMaturedSocialVerifications(context.Background(), policy, mature.Add(time.Minute), func(context.Context, string, string, string) error { leaseCalls.Add(1); return nil }); err != nil || granted != 0 || leaseCalls.Load() != 0 {
		t.Fatalf("leased grant=%d calls=%d err=%v", granted, leaseCalls.Load(), err)
	}
	if granted, err := other.PromoteMaturedSocialVerifications(context.Background(), policy, mature.Add(socialRecheckLease), func(context.Context, string, string, string) error { leaseCalls.Add(1); return nil }); err != nil || granted != 1 || leaseCalls.Load() != 1 {
		t.Fatalf("lease recovery grant=%d calls=%d err=%v", granted, leaseCalls.Load(), err)
	}
}

func TestParallelPromotersGrantBonusExactlyOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator.db")
	first := openSocialStoreAt(t, path)
	second := openSocialStoreAt(t, path)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-parallel"
	createPendingSocialVerification(t, first, policy, providerID, "333", now)
	mature := now.Add(policy.SocialVerificationDwell)

	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	recheck := func(context.Context, string, string, string) error {
		once.Do(func() { close(entered) })
		<-release
		return nil
	}
	type result struct {
		granted int
		err     error
	}
	results := make(chan result, 2)
	go func() {
		granted, err := first.PromoteMaturedSocialVerifications(context.Background(), policy, mature, recheck)
		results <- result{granted, err}
	}()
	<-entered
	go func() {
		granted, err := second.PromoteMaturedSocialVerifications(context.Background(), policy, mature, func(context.Context, string, string, string) error { return nil })
		results <- result{granted, err}
	}()
	close(release)
	total := 0
	for range 2 {
		got := <-results
		if got.err != nil {
			t.Fatal(got.err)
		}
		total += got.granted
	}
	if total != 1 {
		t.Fatalf("total grants=%d", total)
	}
	status, err := first.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || status.BonusCapacity != policy.SocialBonusUses || status.SocialState != SocialStateMatured {
		t.Fatalf("status=%+v err=%v", status, err)
	}
	var grants, grantAudits, recheckAudits int
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_grants WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&grants); err != nil {
		t.Fatal(err)
	}
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE campaign = ? AND provider_id = ? AND event_kind = 'bonus' AND outcome = 'granted'`, policy.Campaign, providerID).Scan(&grantAudits); err != nil {
		t.Fatal(err)
	}
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE campaign = ? AND provider_id = ? AND event_kind = 'recheck' AND outcome = 'verified'`, policy.Campaign, providerID).Scan(&recheckAudits); err != nil {
		t.Fatal(err)
	}
	if grants != 1 || grantAudits != 1 || recheckAudits != 1 {
		t.Fatalf("grant rows=%d grant audits=%d recheck audits=%d", grants, grantAudits, recheckAudits)
	}
	if _, err := first.db.Exec(`UPDATE referral_social_grants SET amount = amount + 1`); err == nil {
		t.Fatal("grant update unexpectedly succeeded")
	}
	if _, err := first.db.Exec(`DELETE FROM referral_social_grants`); err == nil {
		t.Fatal("grant delete unexpectedly succeeded")
	}
}

func TestVerifiedProviderCanEarnRepeatedXPostBonuses(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-repeat"
	createPendingSocialVerification(t, store, policy, providerID, "444", now)

	firstMature := now.Add(policy.SocialVerificationDwell)
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, firstMature, func(context.Context, string, string, string) error { return nil }); err != nil || granted != 1 {
		t.Fatalf("first grant=%d err=%v", granted, err)
	}
	firstStatus, err := store.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || firstStatus.SocialState != SocialStateMatured || firstStatus.BonusCapacity != policy.SocialBonusUses {
		t.Fatalf("first status=%+v err=%v", firstStatus, err)
	}
	if firstStatus.SocialBonusGrantsRemaining != policy.SocialBonusMaxGrants-1 {
		t.Fatalf("first grants remaining=%d", firstStatus.SocialBonusGrantsRemaining)
	}

	secondChallenge, err := store.CreateSocialChallenge(context.Background(), policy, providerID, firstMature.Add(time.Minute))
	if err != nil {
		t.Fatalf("second challenge err=%v", err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, providerID, secondChallenge.Cleartext, "444", "456", strings.Repeat("b", 64), "x_api", firstMature.Add(2*time.Minute)); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("post reuse err=%v", err)
	}
	secondStatus, err := store.CompleteSocialVerification(context.Background(), policy, providerID, secondChallenge.Cleartext, "555", "456", strings.Repeat("b", 64), "x_api", firstMature.Add(3*time.Minute))
	if err != nil || secondStatus.SocialState != SocialStatePending {
		t.Fatalf("second submission status=%+v err=%v", secondStatus, err)
	}

	secondMature := firstMature.Add(3 * time.Minute).Add(policy.SocialVerificationDwell)
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, secondMature, func(context.Context, string, string, string) error { return nil }); err != nil || granted != 1 {
		t.Fatalf("second grant=%d err=%v", granted, err)
	}
	finalStatus, err := store.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || finalStatus.SocialState != SocialStateMatured || finalStatus.BonusCapacity != 2*policy.SocialBonusUses {
		t.Fatalf("final status=%+v err=%v", finalStatus, err)
	}
	if finalStatus.SocialBonusGrantsRemaining != policy.SocialBonusMaxGrants-2 {
		t.Fatalf("final grants remaining=%d", finalStatus.SocialBonusGrantsRemaining)
	}

	var grants, history int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_social_grants WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&grants); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_social_verification_history WHERE provider_id = ?`, providerID).Scan(&history); err != nil {
		t.Fatal(err)
	}
	if grants != 2 || history != 1 {
		t.Fatalf("grants=%d history=%d", grants, history)
	}
}

func TestSocialChallengeStopsAtProviderGrantCap(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	policy.SocialBonusMaxGrants = 2
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-cap"
	qualifyProvider(t, store, policy, providerID, now.Add(-time.Minute))

	for i, postID := range []string{"601", "602"} {
		challenge, err := store.CreateSocialChallenge(context.Background(), policy, providerID, now.Add(time.Duration(i)*time.Hour))
		if err != nil {
			t.Fatalf("challenge %d err=%v", i, err)
		}
		if _, err := store.CompleteSocialVerification(context.Background(), policy, providerID, challenge.Cleartext, postID, "456", testSocialShareURLHash, "x_api", now.Add(time.Duration(i)*time.Hour+time.Minute)); err != nil {
			t.Fatalf("complete %d err=%v", i, err)
		}
		if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(time.Duration(i)*time.Hour+time.Minute).Add(policy.SocialVerificationDwell), func(context.Context, string, string, string) error { return nil }); err != nil || granted != 1 {
			t.Fatalf("promote %d granted=%d err=%v", i, granted, err)
		}
	}

	status, err := store.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || status.SocialBonusGrantsRemaining != 0 || status.BonusCapacity != 2*policy.SocialBonusUses {
		t.Fatalf("status=%+v err=%v", status, err)
	}
	if _, err := store.CreateSocialChallenge(context.Background(), policy, providerID, now.Add(3*time.Hour)); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("cap challenge err=%v", err)
	}
}

func TestFailedVerificationArchivesAndCannotReusePost(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-retry"
	_, firstChallenge := createPendingSocialVerification(t, store, policy, providerID, "444", now)
	if granted, err := store.PromoteMaturedSocialVerifications(context.Background(), policy, now.Add(policy.SocialVerificationDwell), func(context.Context, string, string, string) error { return errors.New("post removed") }); err != nil || granted != 0 {
		t.Fatalf("terminal grant=%d err=%v", granted, err)
	}
	retry, err := store.CreateSocialChallenge(context.Background(), policy, providerID, now.Add(policy.SocialVerificationDwell+time.Minute))
	if err != nil || retry.Cleartext == firstChallenge.Cleartext {
		t.Fatalf("retry=%+v err=%v", retry, err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, providerID, retry.Cleartext, "444", "456", strings.Repeat("b", 64), "x_api", now.Add(policy.SocialVerificationDwell+2*time.Minute)); !errors.Is(err, ErrSocialChallenge) {
		t.Fatalf("post reuse err=%v", err)
	}
	if _, err := store.CompleteSocialVerification(context.Background(), policy, providerID, retry.Cleartext, "555", "456", strings.Repeat("b", 64), "x_api", now.Add(policy.SocialVerificationDwell+2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	var history int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM referral_social_verification_history WHERE provider_id = ?`, providerID).Scan(&history); err != nil {
		t.Fatal(err)
	}
	if history != 1 {
		t.Fatalf("history=%d", history)
	}
}
