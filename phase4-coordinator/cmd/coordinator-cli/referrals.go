package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func createSeedReferral(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := newReferralFlagSet("create-seed-referral")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	keyID := fs.String("key-id", "", "HMAC key identifier")
	secretEnv := fs.String("secret-env", "", "environment variable containing the HMAC secret")
	seedID := fs.String("seed-id", "", "opaque seed issuer identifier")
	maxUses := fs.Int("max-uses", 1, "maximum successful registrations")
	expiresAt := fs.String("expires-at", "", "optional RFC3339 expiry")
	apply := fs.Bool("apply", false, "create the seed (default is dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	setReferralUsage(fs, "create-seed-referral", "coordinator-cli create-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 100 --apply --actor ops@malibu --reason 'open cohort'")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	policy, err := referralCLIPolicy(*campaign, *keyID, *secretEnv, getenv)
	if err != nil {
		return err
	}
	var expiry *time.Time
	if raw := strings.TrimSpace(*expiresAt); raw != "" {
		parsed, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			return fmt.Errorf("--expires-at must be RFC3339: %w", err)
		}
		parsed = parsed.UTC()
		expiry = &parsed
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.CreateSeedReferralAudited(context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, expiry, *apply, strings.TrimSpace(*actor), strings.TrimSpace(*reason), time.Now().UTC())
	if errors.Is(err, auth.ErrReferralSeedExists) {
		return fmt.Errorf("seed %s already exists; use adjust-seed-referral to change its capacity", strings.TrimSpace(*seedID))
	}
	if err != nil {
		return err
	}
	mode := "dry-run"
	if result.Applied {
		mode = "applied"
	} else if result.Recovered {
		mode = "recovered"
	}
	if _, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nseed_id=%s\nmax_uses=%d\n", mode, policy.Campaign, result.SeedID, result.MaxUses); err != nil {
		return err
	}
	if result.Applied || result.Recovered {
		_, err = fmt.Fprintf(stdout, "referral_code=%s\n", result.Code)
	}
	return err
}

func adjustSeedReferral(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := newReferralFlagSet("adjust-seed-referral")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	keyID := fs.String("key-id", "", "HMAC key identifier")
	secretEnv := fs.String("secret-env", "", "environment variable containing the HMAC secret")
	seedID := fs.String("seed-id", "", "opaque seed issuer identifier")
	maxUses := fs.Int("max-uses", -1, "new maximum successful registrations")
	apply := fs.Bool("apply", false, "apply the change (default is dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	setReferralUsage(fs, "adjust-seed-referral", "coordinator-cli adjust-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 250 --apply --actor ops@malibu --reason 'expand cohort'")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if *maxUses < 0 {
		return fmt.Errorf("--max-uses is required and must be >= 0")
	}
	policy, err := referralCLIPolicy(*campaign, *keyID, *secretEnv, getenv)
	if err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.AdjustSeedReferral(context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, *apply, strings.TrimSpace(*actor), strings.TrimSpace(*reason), time.Now().UTC())
	if errors.Is(err, auth.ErrReferralCapacityBelowUsed) {
		return fmt.Errorf("refusing to set capacity below redeemed uses for seed %s", strings.TrimSpace(*seedID))
	}
	if err != nil {
		return err
	}
	mode := "dry-run"
	if result.Applied {
		mode = "applied"
	}
	_, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nseed_id=%s\ncurrent_capacity=%d\nnew_capacity=%d\nredeemed=%d\nresulting_remaining=%d\n",
		mode, policy.Campaign, result.SeedID, result.CurrentCapacity, result.NewCapacity, result.Redeemed, result.ResultingRemaining)
	return err
}

func revokeReferral(args []string, stdout io.Writer) error {
	fs := newReferralFlagSet("revoke-referral")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	issuerID := fs.String("issuer-id", "", "seed or provider invite issuer identifier")
	apply := fs.Bool("apply", false, "apply the revocation (default is a dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	expectRedeemed := fs.Int("expect-redeemed", -1, "expected redemption count from the dry-run (required with --apply)")
	setReferralUsage(fs, "revoke-referral", "coordinator-cli revoke-referral --db coordinator.db --campaign prebeta --issuer-id launch --apply --actor ops@malibu --reason 'abuse report' --expect-redeemed 3")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if *apply && (strings.TrimSpace(*actor) == "" || strings.TrimSpace(*reason) == "") {
		return fmt.Errorf("--actor and --reason are required with --apply")
	}
	var expect *auth.ReferralRevokeExpectation
	if *apply {
		if *expectRedeemed < 0 {
			return fmt.Errorf("--expect-redeemed is required with --apply (run the dry-run first)")
		}
		expect = &auth.ReferralRevokeExpectation{Redeemed: *expectRedeemed}
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.RevokeReferralIssuerAudited(context.Background(), *campaign, *issuerID, *apply, strings.TrimSpace(*actor), strings.TrimSpace(*reason), expect, time.Now().UTC())
	if err != nil {
		return err
	}
	mode := "dry-run"
	if result.Applied {
		mode = "applied"
	}
	_, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nissuer_id=%s\ncode_type=%s\nprovider_id=%s\nredeemed=%d\nremaining_capacity=%d\n",
		mode, result.Campaign, result.IssuerID, result.CodeType, result.ProviderID, result.Redeemed, result.RemainingCapacity)
	return err
}

func replaceProviderReferral(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := newReferralFlagSet("replace-provider-referral")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	keyID := fs.String("key-id", "", "HMAC key identifier for the replacement code")
	secretEnv := fs.String("secret-env", "", "environment variable containing the HMAC secret")
	issuerID := fs.String("issuer-id", "", "revoked provider invite issuer identifier")
	apply := fs.Bool("apply", false, "replace the issuer (default is a dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	expectProviderID := fs.String("expect-provider-id", "", "provider ID from the dry-run (required with --apply)")
	expectBaseCapacity := fs.Int("expect-base-capacity", -1, "current base capacity from the dry-run (required with --apply)")
	expectBonusCapacity := fs.Int("expect-bonus-capacity", -1, "current bonus capacity from the dry-run (required with --apply)")
	expectRedeemed := fs.Int("expect-redeemed", -1, "carried and current redemptions from the dry-run (required with --apply)")
	expectPendingSocial := fs.String("expect-pending-social-review", "", "pending social review state from the dry-run: true or false (required with --apply)")
	setReferralUsage(fs, "replace-provider-referral", "coordinator-cli replace-provider-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --issuer-id oldissuer --apply --actor ops@malibu --reason 'rotate compromised link' --expect-provider-id provider-123 --expect-base-capacity 1 --expect-bonus-capacity 0 --expect-redeemed 0 --expect-pending-social-review=false")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	actorValue := strings.TrimSpace(*actor)
	reasonValue := strings.TrimSpace(*reason)
	providerExpectation := strings.TrimSpace(*expectProviderID)
	var pendingExpectation bool
	if *apply {
		if actorValue == "" || reasonValue == "" {
			return fmt.Errorf("--actor and --reason are required with --apply")
		}
		if providerExpectation == "" || *expectBaseCapacity < 0 || *expectBonusCapacity < 0 || *expectRedeemed < 0 || strings.TrimSpace(*expectPendingSocial) == "" {
			return fmt.Errorf("--expect-provider-id, --expect-base-capacity, --expect-bonus-capacity, --expect-redeemed, and --expect-pending-social-review are required with --apply (run the dry-run first)")
		}
		parsed, err := parseExpectedBool("--expect-pending-social-review", *expectPendingSocial)
		if err != nil {
			return err
		}
		pendingExpectation = parsed
	}

	policy, err := referralCLIPolicy(*campaign, *keyID, *secretEnv, getenv)
	if err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()

	// Always re-read the durable state immediately before an apply. The
	// expectation flags bind the operator's earlier preview to this run; the
	// store then performs its own revoked-issuer CAS inside the transaction.
	preview, err := store.ReplaceReferralIssuer(context.Background(), policy, strings.TrimSpace(*issuerID), "", "", false, time.Now().UTC())
	if err != nil {
		return err
	}
	if !*apply {
		_, err = fmt.Fprintf(stdout, "mode=dry-run\ncampaign=%s\nprovider_id=%s\nold_issuer_id=%s\ncurrent_base_capacity=%d\ncurrent_bonus_capacity=%d\nredeemed=%d\nremaining=%d\npending_social_review=%t\nreplacement_base_capacity=%d\n",
			policy.Campaign, preview.ProviderID, preview.OldIssuerID, preview.OldBaseCapacity, preview.OldBonusCapacity, preview.Redeemed, preview.Remaining, preview.PendingSocialReview, preview.BaseCapacity)
		return err
	}
	if providerExpectation != preview.ProviderID || *expectBaseCapacity != preview.OldBaseCapacity || *expectBonusCapacity != preview.OldBonusCapacity || *expectRedeemed != preview.Redeemed || pendingExpectation != preview.PendingSocialReview {
		return fmt.Errorf("replacement snapshot drift: expected provider_id=%s base_capacity=%d bonus_capacity=%d redeemed=%d pending_social_review=%t but live provider_id=%s base_capacity=%d bonus_capacity=%d redeemed=%d pending_social_review=%t; re-run the dry-run",
			providerExpectation, *expectBaseCapacity, *expectBonusCapacity, *expectRedeemed, pendingExpectation,
			preview.ProviderID, preview.OldBaseCapacity, preview.OldBonusCapacity, preview.Redeemed, preview.PendingSocialReview)
	}
	result, err := store.ReplaceReferralIssuerExpected(
		context.Background(), policy, preview.OldIssuerID, actorValue, reasonValue,
		&auth.ReferralReplacementExpectation{
			ProviderID:          providerExpectation,
			OldBaseCapacity:     *expectBaseCapacity,
			OldBonusCapacity:    *expectBonusCapacity,
			Redeemed:            *expectRedeemed,
			PendingSocialReview: pendingExpectation,
		},
		true, time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	if !result.Applied || result.NewIssuerID == "" || result.NewCode == "" {
		return fmt.Errorf("replacement did not produce a new issuer and referral code")
	}
	_, err = fmt.Fprintf(stdout, "mode=applied\nprovider_id=%s\nold_issuer_id=%s\nnew_issuer_id=%s\nnew_referral_code=%s\n",
		result.ProviderID, result.OldIssuerID, result.NewIssuerID, result.NewCode)
	return err
}

func parseExpectedBool(name, value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, fmt.Errorf("%s must be true or false", name)
	}
}

func referralCLIPolicy(campaign, keyID, secretEnv string, getenv func(string) string) (auth.ReferralPolicy, error) {
	secretEnv = strings.TrimSpace(secretEnv)
	if secretEnv == "" {
		return auth.ReferralPolicy{}, fmt.Errorf("--secret-env is required; referral HMAC secrets are not accepted on argv")
	}
	secret := getenv(secretEnv)
	if len(secret) < 32 {
		return auth.ReferralPolicy{}, fmt.Errorf("referral HMAC secret from %s must be at least 32 bytes", secretEnv)
	}
	keyID = strings.TrimSpace(keyID)
	policy := auth.ReferralPolicy{
		Campaign:         strings.TrimSpace(campaign),
		PolicyVersion:    "v1",
		CurrentKeyID:     keyID,
		HMACKeys:         map[string]string{keyID: secret},
		ProviderBaseUses: 1,
	}
	if err := policy.Validate(); err != nil {
		return auth.ReferralPolicy{}, err
	}
	return policy, nil
}

func newReferralFlagSet(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

func setReferralUsage(fs *flag.FlagSet, name, example string) {
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: coordinator-cli %s [flags]\n\nflags:\n", name)
		fs.SetOutput(os.Stderr)
		fs.PrintDefaults()
		fs.SetOutput(io.Discard)
		fmt.Fprintf(os.Stderr, "\nexample:\n  %s\n", example)
	}
}

func referralParseError(err error) error {
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	return err
}
