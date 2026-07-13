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
	"github.com/augstar/macprovider-coordinator/internal/config"
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
	setReferralUsage(fs, "create-seed-referral", "coordinator-cli create-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 100")
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
	code, err := store.CreateSeedReferral(context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, expiry)
	if errors.Is(err, auth.ErrReferralSeedExists) {
		return fmt.Errorf("seed %s already exists; use adjust-seed-referral to change its capacity", strings.TrimSpace(*seedID))
	}
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "referral_code=%s\ncampaign=%s\nseed_id=%s\nmax_uses=%d\nstatus=created\n", code, policy.Campaign, strings.TrimSpace(*seedID), *maxUses)
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

func replaceReferralIssuer(args []string, stdout io.Writer) error {
	fs := newReferralFlagSet("replace-referral-issuer")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	configPath := fs.String("config", "", "path to authoritative coordinator YAML config")
	campaign := fs.String("campaign", "", "expected deployed referral campaign")
	keyID := fs.String("key-id", "", "expected deployed current HMAC key identifier")
	issuerID := fs.String("issuer-id", "", "revoked provider issuer identifier")
	baseUses := fs.Int("base-uses", 0, "expected deployed provider base capacity")
	apply := fs.Bool("apply", false, "apply the replacement (default is dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	setReferralUsage(fs, "replace-referral-issuer", "coordinator-cli replace-referral-issuer --db coordinator.db --config coordinator.yaml --campaign prebeta --key-id k1 --issuer-id <revoked-issuer> --base-uses 1 --apply --actor ops@malibu --reason 'rotate compromised link'")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if strings.TrimSpace(*configPath) == "" {
		return fmt.Errorf("--config is required; replacement policy is loaded from coordinator config")
	}
	if *baseUses <= 0 {
		return fmt.Errorf("--base-uses is required and must be > 0")
	}
	if *apply && (strings.TrimSpace(*actor) == "" || strings.TrimSpace(*reason) == "") {
		return fmt.Errorf("--actor and --reason are required with --apply")
	}
	cfg, err := config.Load(strings.TrimSpace(*configPath))
	if err != nil {
		return fmt.Errorf("load coordinator config: %w", err)
	}
	if !cfg.Referrals.RequireForRegistration && !cfg.Referrals.EnableSocialInviteBonus {
		return fmt.Errorf("deployed config has no active referral policy")
	}
	policy := auth.ReferralPolicy{
		RequireForRegistration: cfg.Referrals.RequireForRegistration,
		EnableSocialBonus:      cfg.Referrals.EnableSocialInviteBonus,
		Campaign:               cfg.Referrals.Campaign,
		PolicyVersion:          cfg.Referrals.PolicyVersion,
		CurrentKeyID:           cfg.Referrals.CurrentKeyID,
		HMACKeys:               cfg.Referrals.HMACKeys,
		ProviderBaseUses:       cfg.Referrals.ProviderBaseUses,
		SocialBonusUses:        cfg.Referrals.SocialBonusUses,
		ChallengeTTL:           time.Duration(cfg.Referrals.ChallengeTTLS) * time.Second,
	}
	if err := policy.Validate(); err != nil {
		return fmt.Errorf("deployed referral policy is invalid: %w", err)
	}
	if strings.TrimSpace(*campaign) != policy.Campaign {
		return fmt.Errorf("campaign mismatch: expected %q, deployed %q", strings.TrimSpace(*campaign), policy.Campaign)
	}
	if strings.TrimSpace(*keyID) != policy.CurrentKeyID {
		return fmt.Errorf("key mismatch: expected %q, deployed %q", strings.TrimSpace(*keyID), policy.CurrentKeyID)
	}
	if *baseUses != policy.ProviderBaseUses {
		return fmt.Errorf("capacity mismatch: expected %d, deployed %d", *baseUses, policy.ProviderBaseUses)
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	replacement, err := store.ReplaceReferralIssuer(
		context.Background(), policy, strings.TrimSpace(*issuerID), strings.TrimSpace(*actor),
		strings.TrimSpace(*reason), *apply, time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	if !replacement.Applied {
		_, err = fmt.Fprintf(stdout, "mode=dry-run\ncampaign=%s\nprovider_id=%s\nold_issuer_id=%s\nkey_id=%s\nold_base_capacity=%d\nproposed_base_capacity=%d\nold_bonus_capacity=%d\nproposed_bonus_capacity=%d\npending_social=%t\n",
			policy.Campaign, replacement.ProviderID, replacement.OldIssuerID, replacement.KeyID,
			replacement.OldBaseCapacity, replacement.BaseCapacity, replacement.OldBonusCapacity,
			replacement.BonusCapacity, replacement.PendingSocialReview)
		return err
	}
	if _, err := store.ValidateReferral(context.Background(), policy, replacement.NewCode, time.Now().UTC()); err != nil {
		return fmt.Errorf("successor code failed validation under deployed policy: %w", err)
	}
	_, err = fmt.Fprintf(stdout, "mode=applied\ncampaign=%s\nprovider_id=%s\nold_issuer_id=%s\nnew_issuer_id=%s\nnew_referral_code=%s\nbase_capacity=%d\nbonus_capacity=%d\npending_social=%t\nverified=true\n",
		policy.Campaign, replacement.ProviderID, replacement.OldIssuerID, replacement.NewIssuerID,
		replacement.NewCode, replacement.BaseCapacity, replacement.BonusCapacity, replacement.PendingSocialReview)
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
