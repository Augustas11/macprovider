package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

const privacyQuarantineMaxSeconds = 86400 * 30

func privacyClassCommand(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("privacy-class requires status, disable, enable, quarantine, unquarantine, or revoke-app-attest-key")
	}
	switch args[0] {
	case "status", "disable", "enable", "quarantine", "unquarantine", "revoke-app-attest-key":
		return runPrivacyClass(args[0], args[1:], stdout)
	default:
		return errors.New("unknown privacy-class subcommand")
	}
}

func runPrivacyClass(action string, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("privacy-class "+action, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "coordinator config path")
	reason := fs.String("reason", "", "bounded operator reason")
	providerID := fs.String("provider", "", "provider id")
	seconds := fs.Int("seconds", 0, "quarantine duration in seconds")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*configPath) == "" {
		return errors.New("config is required")
	}
	store, retention, err := openPrivacyClassStore(*configPath)
	if err != nil {
		return err
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Now().UTC()
	switch action {
	case "status":
		return writePrivacyClassStatus(ctx, store, stdout, now)
	case "disable":
		if err := privacyCLIReason(*reason); err != nil {
			return err
		}
		if err := store.DisablePrivacyAndRejectPredispatch(ctx, strings.TrimSpace(*reason), now); err != nil {
			return err
		}
		return writePrivacyClassStatus(ctx, store, stdout, now)
	case "enable":
		if err := store.SetPrivacyDisabled(ctx, false, "enabled", now); err != nil {
			return err
		}
		return writePrivacyClassStatus(ctx, store, stdout, now)
	case "quarantine":
		if err := privacyCLIProviderID(*providerID); err != nil {
			return err
		}
		if err := privacyCLIReason(*reason); err != nil {
			return err
		}
		if *seconds < 1 || *seconds > privacyQuarantineMaxSeconds {
			return fmt.Errorf("seconds must be from 1 to %d", privacyQuarantineMaxSeconds)
		}
		if err := store.QuarantineAndRevokePrivacy(ctx, strings.TrimSpace(*providerID), strings.TrimSpace(*reason), now, time.Duration(*seconds)*time.Second, retention); err != nil {
			return err
		}
		return writePrivacyClassStatus(ctx, store, stdout, now)
	case "unquarantine":
		if err := privacyCLIProviderID(*providerID); err != nil {
			return err
		}
		if err := store.Unquarantine(ctx, strings.TrimSpace(*providerID)); err != nil {
			return err
		}
		return writePrivacyClassStatus(ctx, store, stdout, now)
	case "revoke-app-attest-key":
		// SPEC-049-R033: the stored reason is always operator_revoked; the
		// operator reason is required but not stored on the key row.
		if err := privacyCLIProviderID(*providerID); err != nil {
			return err
		}
		if err := privacyCLIReason(*reason); err != nil {
			return err
		}
		revoked, err := store.RevokeActiveAppAttestKey(ctx, strings.TrimSpace(*providerID), relayblind.ReasonOperatorRevoked, now)
		if err != nil {
			return err
		}
		if !revoked {
			return errors.New("provider has no active app attest key")
		}
		return writePrivacyClassStatus(ctx, store, stdout, now)
	default:
		return errors.New("unknown privacy-class subcommand")
	}
}

func openPrivacyClassStore(path string) (*relayblind.Store, time.Duration, error) {
	cfg, err := config.Load(path)
	if err != nil {
		return nil, 0, err
	}
	sqlitePath := strings.TrimSpace(cfg.RelayBlind.SQLitePath)
	if sqlitePath == "" {
		return nil, 0, errors.New("relay_blind.sqlite_path is required")
	}
	store, err := relayblind.OpenStore(sqlitePath)
	if err != nil {
		return nil, 0, err
	}
	return store, time.Duration(cfg.RelayBlind.ReplayRetentionSeconds) * time.Second, nil
}

func writePrivacyClassStatus(ctx context.Context, store *relayblind.Store, stdout io.Writer, now time.Time) error {
	control, err := store.PrivacyControl(ctx)
	if err != nil {
		return err
	}
	quarantines, err := store.ListPrivacyQuarantines(ctx, now)
	if err != nil {
		return err
	}
	disabled := 0
	if control.Disabled {
		disabled = 1
	}
	if _, err := fmt.Fprintf(stdout, "disabled=%d\nreason=%s\nupdated_at_unix=%d\nquarantine_count=%d\n", disabled, control.Reason, control.UpdatedAtUnix, len(quarantines)); err != nil {
		return err
	}
	for _, item := range quarantines {
		if _, err := fmt.Fprintf(stdout, "quarantine.provider_id=%s\nquarantine.reason=%s\nquarantine.quarantined_at_unix=%d\nquarantine.expires_at_unix=%d\n", item.ProviderID, item.Reason, item.QuarantinedAtUnix, item.ExpiresAtUnix); err != nil {
			return err
		}
	}
	// App Attest keys: public keyId, state, counter, and reason only.
	keys, err := store.ListAppAttestKeys(ctx)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(stdout, "app_attest_key_count=%d\n", len(keys)); err != nil {
		return err
	}
	for _, key := range keys {
		if _, err := fmt.Fprintf(stdout, "app_attest_key.provider_id=%s\napp_attest_key.key_id=%s\napp_attest_key.state=%s\napp_attest_key.last_counter=%d\napp_attest_key.revoked_reason=%s\n", key.ProviderID, key.KeyID, key.State, key.LastCounter, key.RevokedReason); err != nil {
			return err
		}
	}
	return nil
}

func privacyCLIReason(reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > 128 || !privacyCLIVisible(reason) {
		return errors.New("reason is required")
	}
	return nil
}

func privacyCLIProviderID(providerID string) error {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" || len(providerID) > 128 || !privacyCLIVisible(providerID) {
		return errors.New("provider id is required")
	}
	return nil
}

func privacyCLIVisible(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] < 0x20 || value[i] > 0x7e {
			return false
		}
	}
	return true
}
