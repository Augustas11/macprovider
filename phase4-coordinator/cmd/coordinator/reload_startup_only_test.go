package main

import (
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

func reloadBaselineFor(t *testing.T, cfg config.Config) (string, config.Config) {
	t.Helper()
	path := writeReloadConfig(t, cfg)
	_, digests, err := config.LoadWithOverlayDigests(path, "")
	if err != nil {
		t.Fatalf("boot load: %v", err)
	}
	baseline, err := sighupReloadBaseline(path, "", digests)
	if err != nil {
		t.Fatalf("baseline: %v", err)
	}
	return path, baseline
}

func reloadCandidate(t *testing.T, cfg config.Config) config.Config {
	t.Helper()
	next, _, err := config.LoadForSIGHUPReloadWithOverlayDigests(writeReloadConfig(t, cfg), "")
	if err != nil {
		t.Fatalf("reload load: %v", err)
	}
	return next
}

func TestStartupOnlyConfigDrift(t *testing.T) {
	startup, _, _, _ := reloadTestServers(config.Default())
	_, baseline := reloadBaselineFor(t, startup)

	if got := startupOnlyConfigDrift(baseline, reloadCandidate(t, startup)); len(got) != 0 {
		t.Fatalf("unchanged file reports startup-only drift %v", got)
	}

	reloadable := startup
	reloadable.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.99"
	reloadable.Coordinator.CompatibilitySet = config.CompatibilitySetConfig{
		TargetID:   "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		RevokedIDs: []string{"Augustas11/macprovider:v1.8.1@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
	}
	reloadable.Routing.MinProviderThroughputTPS = 12
	reloadable.Billing.CeilingRestatementEnabled = !startup.Billing.CeilingRestatementEnabled
	reloadable.Storage.RequestLogRetentionDays = startup.Storage.RequestLogRetentionDays + 1
	if got := startupOnlyConfigDrift(baseline, reloadCandidate(t, reloadable)); len(got) != 0 {
		t.Fatalf("reloadable edits report startup-only drift %v", got)
	}

	for _, tc := range []struct {
		name string
		edit func(*config.Config)
		want []string
	}{
		{"auth", func(c *config.Config) { c.Auth.OperatorKey = "ZYXWVUTSRQPONMLKJIHGFEDCBA987654" }, []string{"auth"}},
		{"onboarding", func(c *config.Config) { c.Onboarding.PostgresDSN = "postgres://onboarding.invalid/db" }, []string{"onboarding"}},
		{"listen", func(c *config.Config) { c.Listen.ProviderPort = c.Listen.ProviderPort + 1 }, []string{"listen"}},
		{"storage", func(c *config.Config) { c.Storage.DBPath = c.Storage.DBPath + ".other" }, []string{"storage"}},
		{"auth and onboarding", func(c *config.Config) {
			c.Auth.GatewayServiceToken = "0000000000000000aaaaaaaaaaaaaaaa"
			c.Onboarding.PostgresDSN = "postgres://onboarding.invalid/db"
		}, []string{"auth", "onboarding"}},
	} {
		next := startup
		tc.edit(&next)
		if got := startupOnlyConfigDrift(baseline, reloadCandidate(t, next)); !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("%s: drift = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestSIGHUPReloadBaselineRejectsChangedBytes(t *testing.T) {
	startup, _, _, _ := reloadTestServers(config.Default())
	path := writeReloadConfig(t, startup)
	if _, err := sighupReloadBaseline(path, "", config.SourceDigests{ConfigSHA256: "not-the-boot-bytes"}); err == nil {
		t.Fatal("baseline accepted bytes boot did not apply")
	}
}

// A reload that also changes a startup-only section applies nothing, so the
// sighup applied event (whole-file proof for the ops gates) is never logged.
func TestReloadCoordinatorConfigRejectsStartupOnlySectionChange(t *testing.T) {
	defer tier2.ResetForTest()
	startup := config.Default()
	startup.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.12"
	startup, _, wsServer, buyerServer := reloadTestServers(startup)
	_, baseline := reloadBaselineFor(t, startup)
	reloadStartupOnlyBaseline.Store(&baseline)
	defer reloadStartupOnlyBaseline.Store(nil)
	server := httptest.NewServer(wsServer.Handler())
	defer server.Close()

	next := startup
	next.CoordinatorAdvertisedVersion.LatestBinaryVersion = "1.8.20"
	next.Auth.OperatorKey = "ZYXWVUTSRQPONMLKJIHGFEDCBA987654"
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil, nil, nil)
	if got := fetchReloadCompatibilityHealth(t, server.URL).RecommendedBinaryVersion; got != "1.8.12" {
		t.Fatalf("reload with an auth change applied latest_binary_version %q", got)
	}

	next.Auth.OperatorKey = startup.Auth.OperatorKey
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil, nil, nil)
	if got := fetchReloadCompatibilityHealth(t, server.URL).RecommendedBinaryVersion; got != "1.8.20" {
		t.Fatalf("reload without startup-only changes did not apply: %q", got)
	}
}
