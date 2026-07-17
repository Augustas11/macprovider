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
	operationID := fs.String("operation-id", "", "caller-generated UUID idempotency key (required with --apply)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	setReferralUsage(fs, "create-seed-referral", "coordinator-cli create-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 100 --apply --operation-id 11111111-1111-4111-8111-111111111111 --actor ops@malibu --reason 'open cohort'")
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
	expiry, err := parseReferralExpiry(*expiresAt)
	if err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.CreateSeedReferralAudited(
		context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, expiry,
		*apply, referralAdminOperation(*operationID, *actor, *reason, ""), time.Now().UTC(),
	)
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
	if result.ExpectedState != "" {
		if _, err = fmt.Fprintf(stdout, "expected_state=%s\n", result.ExpectedState); err != nil {
			return err
		}
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
	operationID := fs.String("operation-id", "", "caller-generated UUID idempotency key (required with --apply)")
	expectState := fs.String("expect-state", "", "opaque expected-state digest from dry-run (required with --apply)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	setReferralUsage(fs, "adjust-seed-referral", "coordinator-cli adjust-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 250 --apply --operation-id 22222222-2222-4222-8222-222222222222 --expect-state <dry-run-digest> --actor ops@malibu --reason 'expand cohort'")
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
	result, err := store.AdjustSeedReferral(
		context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, *apply,
		referralAdminOperation(*operationID, *actor, *reason, *expectState), time.Now().UTC(),
	)
	if errors.Is(err, auth.ErrReferralCapacityBelowUsed) {
		return fmt.Errorf("refusing to set capacity below redeemed uses for seed %s", strings.TrimSpace(*seedID))
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
	_, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nseed_id=%s\ncurrent_capacity=%d\ncurrent_bonus_capacity=%d\nnew_capacity=%d\nredeemed=%d\nresulting_remaining=%d\nexpected_state=%s\n",
		mode, policy.Campaign, result.SeedID, result.CurrentCapacity, result.CurrentBonusCapacity,
		result.NewCapacity, result.Redeemed, result.ResultingRemaining, result.ExpectedState)
	return err
}

func revokeReferral(args []string, stdout io.Writer) error {
	fs := newReferralFlagSet("revoke-referral")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	issuerID := fs.String("issuer-id", "", "seed or provider invite issuer identifier")
	apply := fs.Bool("apply", false, "apply the revocation (default is a dry-run preview)")
	operationID := fs.String("operation-id", "", "caller-generated UUID idempotency key (required with --apply)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	expectState := fs.String("expect-state", "", "opaque expected-state digest from dry-run (required with --apply)")
	setReferralUsage(fs, "revoke-referral", "coordinator-cli revoke-referral --db coordinator.db --campaign prebeta --issuer-id launch --apply --operation-id 33333333-3333-4333-8333-333333333333 --expect-state <dry-run-digest> --actor ops@malibu --reason 'abuse report'")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if *apply && (strings.TrimSpace(*actor) == "" || strings.TrimSpace(*reason) == "") {
		return fmt.Errorf("--actor and --reason are required with --apply")
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.RevokeReferralIssuerAudited(
		context.Background(), *campaign, *issuerID, *apply,
		referralAdminOperation(*operationID, *actor, *reason, *expectState), time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	mode := "dry-run"
	if result.Applied {
		mode = "applied"
	} else if result.Recovered {
		mode = "recovered"
	}
	_, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nissuer_id=%s\ncode_type=%s\nprovider_id=%s\nbase_capacity=%d\nbonus_capacity=%d\nredeemed=%d\nremaining_capacity=%d\nexpected_state=%s\n",
		mode, result.Campaign, result.IssuerID, result.CodeType, result.ProviderID,
		result.BaseCapacity, result.BonusCapacity, result.Redeemed,
		result.RemainingCapacity, result.ExpectedState)
	return err
}

func replaceSeedReferral(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := newReferralFlagSet("replace-seed-referral")
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	keyID := fs.String("key-id", "", "HMAC key identifier")
	secretEnv := fs.String("secret-env", "", "environment variable containing the HMAC secret")
	oldSeedID := fs.String("old-seed-id", "", "active seed issuer to retire")
	newSeedID := fs.String("new-seed-id", "", "new seed issuer identifier")
	maxUses := fs.Int("max-uses", 1, "maximum successful registrations for the replacement")
	expiresAt := fs.String("expires-at", "", "optional RFC3339 expiry for the replacement")
	apply := fs.Bool("apply", false, "apply the atomic replacement (default is dry-run preview)")
	operationID := fs.String("operation-id", "", "caller-generated UUID idempotency key (required with --apply)")
	expectState := fs.String("expect-state", "", "opaque expected-state digest from dry-run (required with --apply)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	setReferralUsage(fs, "replace-seed-referral", "coordinator-cli replace-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --old-seed-id launch --new-seed-id launch2 --max-uses 100 --apply --operation-id 44444444-4444-4444-8444-444444444444 --expect-state <dry-run-digest> --actor ops@malibu --reason 'rotate invite'")
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
	expiry, err := parseReferralExpiry(*expiresAt)
	if err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.ReplaceSeedReferralAudited(
		context.Background(), policy, *oldSeedID, *newSeedID, *maxUses, expiry,
		*apply, referralAdminOperation(*operationID, *actor, *reason, *expectState), time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	mode := "dry-run"
	if result.Applied {
		mode = "applied"
	} else if result.Recovered {
		mode = "recovered"
	}
	if _, err := fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nold_seed_id=%s\nnew_seed_id=%s\nold_base_capacity=%d\nold_bonus_capacity=%d\nold_redeemed=%d\nold_remaining_capacity=%d\nnew_max_uses=%d\nexpected_state=%s\n",
		mode, result.Campaign, result.OldSeedID, result.NewSeedID,
		result.OldBaseCapacity, result.OldBonusCapacity, result.OldRedeemed,
		result.OldRemainingCapacity, result.NewMaxUses, result.ExpectedState); err != nil {
		return err
	}
	if result.Applied || result.Recovered {
		_, err = fmt.Fprintf(stdout, "referral_code=%s\n", result.Code)
	}
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

func referralAdminOperation(operationID, actor, reason, expectedState string) auth.ReferralAdminOperation {
	return auth.ReferralAdminOperation{
		OperationID:   strings.TrimSpace(operationID),
		Actor:         strings.TrimSpace(actor),
		UnixUID:       os.Geteuid(),
		Reason:        strings.TrimSpace(reason),
		ExpectedState: strings.TrimSpace(expectedState),
	}
}

func parseReferralExpiry(raw string) (*time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return nil, fmt.Errorf("--expires-at must be RFC3339: %w", err)
	}
	parsed = parsed.UTC()
	return &parsed, nil
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
