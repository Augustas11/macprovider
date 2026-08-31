package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
)

func listOnboarding(args []string) error {
	fs := flag.NewFlagSet("list-onboarding", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	eventsDBPath := fs.String("events-db", "", "path to provider_connection_events.db; defaults to the sibling of --db; omitted when the file is absent")
	state := fs.String("state", "all", "filter: all|pending|confirmed|live|failed_expired|failed_revoked; live stays empty without a connected coordinator session, use GET /admin/onboarding")
	if err := fs.Parse(args); err != nil {
		return err
	}
	filter := strings.TrimSpace(*state)
	if filter != "all" && !auth.ValidOnboardingState(filter) {
		return fmt.Errorf("invalid --state %q", filter)
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	ctx := context.Background()
	records, err := store.ListOnboardingAttempts(ctx)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	eventsStore, err := openOnboardingEventsStore(*dbPath, *eventsDBPath)
	if err != nil {
		return err
	}
	if eventsStore != nil {
		defer eventsStore.Close()
	}

	all := make([]auth.OnboardingAttempt, 0, len(records))
	for _, record := range records {
		if providerevents.LooksLikeCredential(record.ProviderID) {
			continue
		}
		presence, err := onboardingPresenceFromEvents(ctx, eventsStore, record.ProviderID)
		if err != nil {
			return err
		}
		all = append(all, auth.OverlayPresence(auth.AssembleOnboardingAttempt(record, now), presence, now, record))
	}
	summary := auth.SummarizeOnboardingAttempts(all)
	matched := 0
	for _, attempt := range all {
		if filter != "all" && attempt.State != filter {
			continue
		}
		fmt.Printf(
			"provider_id=%s state=%s presence=%s redeemed_at=%s confirmed_at=%s expires_at=%s last_heartbeat_at=%s last_seen_at=%s last_event_kind=%s last_failure_reason=%s campaign=%s issuer_id=%s\n",
			attempt.ProviderID,
			attempt.State,
			dashIfEmpty(attempt.Presence),
			dashIfEmpty(attempt.RedeemedAt),
			dashIfEmpty(attempt.ConfirmedAt),
			dashIfEmpty(attempt.ExpiresAt),
			dashIfEmpty(attempt.LastHeartbeatAt),
			dashIfEmpty(attempt.LastSeenAt),
			dashIfEmpty(attempt.LastEventKind),
			dashIfEmpty(attempt.LastFailureReason),
			dashIfEmpty(attempt.Campaign),
			dashIfEmpty(attempt.IssuerID),
		)
		matched++
	}
	fmt.Printf(
		"count=%d pending=%d confirmed=%d live=%d failed_expired=%d failed_revoked=%d\n",
		matched, summary.Pending, summary.Confirmed, summary.Live, summary.FailedExpired, summary.FailedRevoked,
	)
	return nil
}

func openOnboardingEventsStore(authDBPath, eventsDBPath string) (*providerevents.SQLiteStore, error) {
	path := strings.TrimSpace(eventsDBPath)
	if path == "" {
		path = providerevents.DefaultDBPath(authDBPath)
	}
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return providerevents.Open(path)
}

func onboardingPresenceFromEvents(ctx context.Context, store *providerevents.SQLiteStore, providerID string) (auth.OnboardingPresence, error) {
	if store == nil {
		return auth.OnboardingPresence{}, nil
	}
	presence := auth.OnboardingPresence{}
	snap, found, err := store.GetLastKnown(ctx, providerID)
	if err != nil {
		return auth.OnboardingPresence{}, err
	}
	if found {
		if !snap.LastSeenAt.IsZero() {
			presence.LastSeenAt = snap.LastSeenAt.UTC().Format(time.RFC3339)
		}
		if snap.LastHeartbeatAt != nil && !snap.LastHeartbeatAt.IsZero() {
			presence.LastHeartbeatAt = snap.LastHeartbeatAt.UTC().Format(time.RFC3339)
		}
	}
	ev, ok, err := store.LatestEventProvider(ctx, providerID)
	if err != nil {
		return auth.OnboardingPresence{}, err
	}
	if ok {
		presence.LastEventKind = ev.Kind
		presence.LastEventOutcome = ev.Outcome
		presence.LastEventAt = ev.OccurredAt.UTC().Format(time.RFC3339)
		presence.LastFailureReason = ev.FailureReason
		if presence.LastSeenAt == "" && !ev.OccurredAt.IsZero() {
			presence.LastSeenAt = ev.OccurredAt.UTC().Format(time.RFC3339)
		}
	}
	return presence, nil
}

func dashIfEmpty(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}
