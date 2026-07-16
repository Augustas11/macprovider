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
	var grants, grantAudits int
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_grants WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&grants); err != nil {
		t.Fatal(err)
	}
	if err := first.db.QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE campaign = ? AND provider_id = ? AND event_kind = 'bonus' AND outcome = 'granted'`, policy.Campaign, providerID).Scan(&grantAudits); err != nil {
		t.Fatal(err)
	}
	if grants != 1 || grantAudits != 1 {
		t.Fatalf("grant rows=%d grant audits=%d", grants, grantAudits)
	}
	if _, err := first.db.Exec(`UPDATE referral_social_grants SET amount = amount + 1`); err == nil {
		t.Fatal("grant update unexpectedly succeeded")
	}
	if _, err := first.db.Exec(`DELETE FROM referral_social_grants`); err == nil {
		t.Fatal("grant delete unexpectedly succeeded")
	}
}

func TestReplacementRequiresQualificationAndPreservesEvidenceTime(t *testing.T) {
	store := openSocialStore(t)
	policy := socialReferralPolicy()
	policy.ProviderBaseUses = 3
	ctx := context.Background()
	now := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	providerID := "provider-replacement"
	qualified := qualifyProvider(t, store, policy, providerID, now)
	if _, _, err := store.IssueTokenWithReferral(ctx, "referred-before-replacement", "host-before", qualified.Code, policy); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeReferralIssuerAudited(ctx, policy.Campaign, qualified.IssuerID, true, "ops", "rotate", &ReferralRevokeExpectation{Redeemed: 1}, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	replacementPolicy := policy
	replacementPolicy.ProviderBaseUses = 1
	preview, err := store.ReplaceReferralIssuer(ctx, replacementPolicy, qualified.IssuerID, "", "", false, now.Add(2*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if preview.Redeemed != 1 || preview.Remaining != 2 {
		t.Fatalf("preview redeemed=%d remaining=%d", preview.Redeemed, preview.Remaining)
	}
	if _, err := store.ReplaceReferralIssuerExpected(ctx, replacementPolicy, qualified.IssuerID, "ops", "stale preview", &ReferralReplacementExpectation{
		ProviderID:          preview.ProviderID,
		OldBaseCapacity:     preview.OldBaseCapacity,
		OldBonusCapacity:    preview.OldBonusCapacity + 1,
		Redeemed:            preview.Redeemed,
		PendingSocialReview: preview.PendingSocialReview,
	}, true, now.Add(2*time.Minute)); !errors.Is(err, ErrReferralReplacementConflict) {
		t.Fatalf("stale replacement err=%v", err)
	}
	replacement, err := store.ReplaceReferralIssuerExpected(ctx, replacementPolicy, qualified.IssuerID, "ops", "rotate compromised link", &ReferralReplacementExpectation{
		ProviderID:          preview.ProviderID,
		OldBaseCapacity:     preview.OldBaseCapacity,
		OldBonusCapacity:    preview.OldBonusCapacity,
		Redeemed:            preview.Redeemed,
		PendingSocialReview: preview.PendingSocialReview,
	}, true, now.Add(2*time.Minute))
	if err != nil || !replacement.Applied || replacement.NewIssuerID == qualified.IssuerID {
		t.Fatalf("replacement=%+v err=%v", replacement, err)
	}
	var evidenceAt, firstServingAt string
	var replacementBase int
	if err := store.db.QueryRow(`SELECT evidence_at FROM referral_serving_qualifications WHERE campaign = ? AND provider_id = ?`, policy.Campaign, providerID).Scan(&evidenceAt); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT first_serving_at, base_capacity FROM referral_issuers WHERE issuer_id = ?`, replacement.NewIssuerID).Scan(&firstServingAt, &replacementBase); err != nil {
		t.Fatal(err)
	}
	if evidenceAt != firstServingAt || firstServingAt != timeText(now.Add(-time.Minute)) {
		t.Fatalf("evidence=%q first serving=%q", evidenceAt, firstServingAt)
	}
	if replacementBase != 3 || replacement.BaseCapacity != 3 {
		t.Fatalf("replacement base row=%d result=%d", replacementBase, replacement.BaseCapacity)
	}
	status, err := store.ProviderReferralStatus(ctx, replacementPolicy, providerID)
	if err != nil || status.Redemptions != 1 || status.Remaining != 2 {
		t.Fatalf("replacement status=%+v err=%v", status, err)
	}
	for i := 0; i < 2; i++ {
		id := fmt.Sprintf("referred-after-replacement-%d", i)
		if _, _, err := store.IssueTokenWithReferral(ctx, id, "host-"+id, replacement.NewCode, replacementPolicy); err != nil {
			t.Fatalf("redemption %d: %v", i, err)
		}
	}
	if _, _, err := store.IssueTokenWithReferral(ctx, "referred-over-capacity", "host-over-capacity", replacement.NewCode, replacementPolicy); !errors.Is(err, ErrReferralExhausted) {
		t.Fatalf("replacement capacity reset err=%v", err)
	}
	status, err = store.ProviderReferralStatus(ctx, replacementPolicy, providerID)
	if err != nil || status.Redemptions != 3 || status.Remaining != 0 {
		t.Fatalf("exhausted replacement status=%+v err=%v", status, err)
	}
	if _, err := store.ReplaceReferralIssuerExpected(ctx, replacementPolicy, qualified.IssuerID, "ops", "duplicate", &ReferralReplacementExpectation{
		ProviderID:          preview.ProviderID,
		OldBaseCapacity:     preview.OldBaseCapacity,
		OldBonusCapacity:    preview.OldBonusCapacity,
		Redeemed:            preview.Redeemed,
		PendingSocialReview: preview.PendingSocialReview,
	}, true, now.Add(3*time.Minute)); !errors.Is(err, ErrReferralInvalid) {
		t.Fatalf("repeat replacement err=%v", err)
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
