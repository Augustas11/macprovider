package integration

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// SPEC-050 MALIBU stake allowance across the real coordinator, gateway, and
// rewards Postgres: stake -> daily refresh -> plain and private requests
// spend the allowance first, then the paid quota, and the provider is paid
// for every request.

const (
	stakePGImage       = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"
	stakePGAdminPass   = "stake-admin-pw"
	stakePGWriterPass  = "stake-writer-pw"
	stakeGitHubUserID  = 4242
	stakeCreditsPerTok = 100 // credits per staked MALIBU per day
)

type stakePostgres struct {
	t         *testing.T
	container string
	adminDSN  string
	writerDSN string
}

// startStakePostgres runs a throwaway Postgres in Docker and applies the
// stats/rewards migrations with the coordinator's own stats-migrate command.
func startStakePostgres(t *testing.T) *stakePostgres {
	t.Helper()
	if _, err := exec.LookPath("docker"); err != nil || exec.Command("docker", "info").Run() != nil {
		if os.Getenv("CI") == "true" || os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatalf("Docker is required for the SPEC-050 rewards Postgres in CI")
		}
		t.Skip("Docker unavailable: the SPEC-050 journey needs the rewards Postgres")
	}
	name := "stake-allowance-pg-" + randHex(t, 6)
	out, err := exec.Command("docker", "run", "-d", "--rm", "--name", name,
		"-e", "POSTGRES_PASSWORD="+stakePGAdminPass, "-e", "POSTGRES_DB=stake",
		"-p", "127.0.0.1::5432", stakePGImage).CombinedOutput()
	if err != nil {
		t.Fatalf("docker run postgres: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("docker", "rm", "-f", name).Run() })
	pg := &stakePostgres{t: t, container: name}
	deadline := time.Now().Add(90 * time.Second)
	for {
		// TCP readiness: the image's init server listens on the socket only.
		if exec.Command("docker", "exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "stake").Run() == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("postgres did not become ready")
		}
		time.Sleep(500 * time.Millisecond)
	}
	portOut, err := exec.Command("docker", "port", name, "5432/tcp").Output()
	if err != nil {
		t.Fatalf("docker port: %v", err)
	}
	hostPort := strings.TrimSpace(strings.Split(string(portOut), "\n")[0])
	pg.adminDSN = fmt.Sprintf("postgres://postgres:%s@%s/stake?sslmode=disable", stakePGAdminPass, hostPort)
	pg.writerDSN = fmt.Sprintf("postgres://rewards_writer:%s@%s/stake?sslmode=disable", stakePGWriterPass, hostPort)
	if out, err := exec.Command(coordinatorBin, "stats-migrate", "--admin-dsn", pg.adminDSN).CombinedOutput(); err != nil {
		t.Fatalf("stats-migrate: %v\n%s", err, out)
	}
	pg.exec(fmt.Sprintf(`ALTER ROLE rewards_writer WITH LOGIN PASSWORD '%s'`, stakePGWriterPass))
	return pg
}

func (pg *stakePostgres) exec(statement string) string {
	pg.t.Helper()
	out, err := exec.Command("docker", "exec", pg.container, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "stake", "-At", "-c", statement).CombinedOutput()
	if err != nil {
		pg.t.Fatalf("psql %q: %v\n%s", statement, err, out)
	}
	return strings.TrimSpace(string(out))
}

// seedStake gives the provider withdrawable MALIBU and records a lock the
// account placed two days ago, so it is mature for today's refresh. It also
// links the account and its staking provider to the same GitHub identity.
// That owned Mac is distinct from the serving provider: buyer traffic must
// never route back to the buyer's own provider, regardless of funding source.
func seedStake(s *scenario, pg *stakePostgres, providerID string, lockedMALIBU int) {
	s.t.Helper()
	pg.exec(fmt.Sprintf(`INSERT INTO provider_rewards_ledger (provider_id, unix_ts, amount_malibu, withdrawal_hold_reason, reason, external_ref)
        VALUES ('%s', %d, 100, NULL, 'malibu_verified_useful_work_v0_2', 'seed:%s')`, providerID, time.Now().Unix(), providerID))
	pg.exec(fmt.Sprintf(`INSERT INTO malibu_stake_events (account_id, github_user_id, provider_id, event_type, amount_units, created_at, idempotency_key, request_digest)
        VALUES ('%s', %d, '%s', 'lock', %d, now() - interval '2 days', 'seed-lock', repeat('0', 64))`,
		s.accountID, stakeGitHubUserID, providerID, int64(lockedMALIBU)*100_000_000))
	coord, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatal(err)
	}
	defer coord.Close()
	for _, stmt := range []string{
		fmt.Sprintf(`INSERT OR IGNORE INTO github_identities (github_user_id, github_login) VALUES (%d, 'staker')`, stakeGitHubUserID),
		fmt.Sprintf(`INSERT INTO provider_ownership (provider_id, github_user_id) VALUES ('%s', %d)`, providerID, stakeGitHubUserID),
	} {
		if _, err := coord.Exec(stmt); err != nil {
			s.t.Fatalf("seed coordinator %q: %v", stmt, err)
		}
	}
	gw, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatal(err)
	}
	defer gw.Close()
	if _, err := gw.Exec(`INSERT INTO account_identities (account_id, provider, provider_user_id, created_at) VALUES (?, 'github', ?, ?)`,
		s.accountID, fmt.Sprint(stakeGitHubUserID), time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
		s.t.Fatalf("seed gateway identity: %v", err)
	}
}

func stakeCoordinatorConfig(pg *stakePostgres) func(*scenario, map[string]any) {
	return func(_ *scenario, cfg map[string]any) {
		cfg["malibu_emission"] = map[string]any{"writer_dsn": pg.writerDSN}
		cfg["stake_allowance"] = map[string]any{
			"daily_budget_credits":          5_000_000,
			"credits_per_malibu":            stakeCreditsPerTok,
			"per_account_daily_cap_credits": 250_000,
			"min_stake_age_hours":           24,
		}
	}
}

type allowanceSplit struct {
	funding          string
	gross, allowance int64
	paid             int64
}

func (s *scenario) allowanceSplit(externalRequestID string) (allowanceSplit, bool) {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatal(err)
	}
	defer db.Close()
	var sp allowanceSplit
	err = db.QueryRow(`SELECT funding, SUM(gross_credits), SUM(allowance_credits), SUM(paid_credits) FROM allowance_request_splits
        WHERE account_id = ? AND external_request_id = ? GROUP BY funding`, s.accountID, externalRequestID).Scan(&sp.funding, &sp.gross, &sp.allowance, &sp.paid)
	if err == sql.ErrNoRows {
		return sp, false
	}
	if err != nil {
		s.t.Fatal(err)
	}
	return sp, true
}

func (s *scenario) providerCreditsFor(externalRequestID string) int64 {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.coordinatorDB)
	if err != nil {
		s.t.Fatal(err)
	}
	defer db.Close()
	var credits int64
	if err := db.QueryRow(`SELECT COALESCE(SUM(provider_credits), 0) FROM ledger_request_credits
        WHERE request_id IN (SELECT request_id FROM request_log WHERE account_id = ? AND external_request_id = ?)`,
		s.accountID, externalRequestID).Scan(&credits); err != nil {
		s.t.Fatal(err)
	}
	return credits
}

func (s *scenario) quotaFundingSource(requestID string) string {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatal(err)
	}
	defer db.Close()
	var source string
	if err := db.QueryRow(`SELECT funding_source FROM quota_reservations WHERE account_id = ? AND request_id = ?`, s.accountID, requestID).Scan(&source); err != nil {
		s.t.Fatalf("quota funding source for %s: %v", requestID, err)
	}
	return source
}

func (s *scenario) paidQuotaUsed() int64 {
	s.t.Helper()
	db, err := sql.Open("sqlite", s.gatewayDB)
	if err != nil {
		s.t.Fatal(err)
	}
	defer db.Close()
	var used int64
	if err := db.QueryRow(`SELECT COALESCE(SUM(total_tokens), 0) FROM usage_events ue WHERE account_id = ?
        AND NOT EXISTS (SELECT 1 FROM quota_reservations qr WHERE qr.account_id = ue.account_id AND qr.request_id = ue.request_id AND qr.funding_source = 'allowance')`,
		s.accountID).Scan(&used); err != nil {
		s.t.Fatal(err)
	}
	return used
}

func (s *scenario) stakeView() map[string]any {
	s.t.Helper()
	status, _, body := s.jsonRequest(http.MethodGet, "/v1/stake", map[string]string{"Authorization": "Bearer " + s.apiKey}, "")
	if status != http.StatusOK {
		s.t.Fatalf("GET /v1/stake status %d body %s", status, body)
	}
	var view map[string]any
	if err := json.Unmarshal(body, &view); err != nil {
		s.t.Fatal(err)
	}
	return view
}

func TestStakeAllowancePlainRequestsSpendAllowanceFirst(t *testing.T) {
	requireBins(t)
	pg := startStakePostgres(t)
	providerID := "prov-stake-" + randHex(t, 4)
	s := newScenario(t, scenarioOpts{
		seedAccount:       true,
		providerID:        providerID,
		coordinatorConfig: stakeCoordinatorConfig(pg),
		beforeCoordinator: func(s *scenario) { seedStake(s, pg, providerID+"-owned", 2) },
	})
	defer s.shutdown()

	// Stake: the lock API through the gateway (it earns from a later day;
	// the seeded lock earns today) and the account view after refresh.
	status, _, body := s.jsonRequest(http.MethodPost, "/v1/stake/lock", map[string]string{
		"Authorization": "Bearer " + s.apiKey, "Idempotency-Key": "lock-journey", "Content-Type": "application/json",
	}, `{"amount_malibu":"10"}`)
	if status != http.StatusOK || !strings.Contains(string(body), `"event_type":"lock"`) {
		t.Fatalf("lock status %d body %s", status, body)
	}
	view := s.stakeView()
	if view["staked_malibu"] != "12.00000000" || view["allowance_credits"] != float64(2*stakeCreditsPerTok) || view["overage_enabled"] != true {
		t.Fatalf("stake view after refresh %v", view)
	}
	if wallets, ok := view["linked_wallets"].([]any); !ok || wallets == nil {
		t.Fatalf("linked_wallets missing: %v", view)
	}

	// Plain requests: allowance first, then the paid quota once the
	// allowance cannot cover a request's bound.
	var allowanceSpent int64
	sawAllowance, sawPaid := false, false
	for i := 0; i < 20 && !sawPaid; i++ {
		requestID := fmt.Sprintf("00000000-0000-4000-8000-%012d", i+1)
		usedBefore := s.paidQuotaUsed()
		status, _, body := s.chatRequest(map[string]string{"Authorization": "Bearer " + s.apiKey, "X-Request-ID": requestID},
			fmt.Sprintf(`{"model":%q,"max_tokens":64,"messages":[{"role":"user","content":"hello %d"}]}`, defaultFakeModelID, i))
		if status != http.StatusOK {
			t.Fatalf("request %d status %d body %s", i, status, body)
		}
		split, ok := s.allowanceSplit(requestID)
		if !ok {
			t.Fatalf("request %d has no allowance split row", i)
		}
		if credits := s.providerCreditsFor(requestID); credits <= 0 {
			t.Fatalf("request %d provider credits %d: the provider must be paid", i, credits)
		}
		switch split.funding {
		case "allowance":
			if sawPaid {
				t.Fatalf("request %d used the allowance after a paid request", i)
			}
			sawAllowance = true
			allowanceSpent += split.allowance
			if split.allowance != split.gross || split.paid != 0 || s.quotaFundingSource(requestID) != "allowance" {
				t.Fatalf("request %d allowance split %+v", i, split)
			}
			if used := s.paidQuotaUsed(); used != usedBefore {
				t.Fatalf("request %d drew the paid quota (%d -> %d)", i, usedBefore, used)
			}
		case "paid":
			sawPaid = true
			if split.paid != split.gross || split.allowance != 0 || s.quotaFundingSource(requestID) != "quota" {
				t.Fatalf("request %d paid split %+v", i, split)
			}
			if used := s.paidQuotaUsed(); used <= usedBefore {
				t.Fatalf("request %d paid request did not draw the paid quota", i)
			}
		}
	}
	if !sawAllowance || !sawPaid {
		t.Fatalf("allowance first then paid: sawAllowance=%v sawPaid=%v", sawAllowance, sawPaid)
	}
	view = s.stakeView()
	if view["allowance_spent_credits"] != float64(allowanceSpent) {
		t.Fatalf("allowance_spent_credits %v, want %d", view["allowance_spent_credits"], allowanceSpent)
	}

	// Overage off: a request the allowance cannot cover is refused and
	// nothing is charged or dispatched.
	status, _, body = s.jsonRequest(http.MethodPost, "/v1/stake/overage", map[string]string{
		"Authorization": "Bearer " + s.apiKey, "Content-Type": "application/json",
	}, `{"enabled":false}`)
	if status != http.StatusOK {
		t.Fatalf("overage status %d body %s", status, body)
	}
	usedBefore := s.paidQuotaUsed()
	status, _, body = s.chatRequest(map[string]string{"Authorization": "Bearer " + s.apiKey, "X-Request-ID": "00000000-0000-4000-8000-999999999999"},
		fmt.Sprintf(`{"model":%q,"max_tokens":64,"messages":[{"role":"user","content":"refused"}]}`, defaultFakeModelID))
	if status != http.StatusTooManyRequests || !strings.Contains(string(body), "allowance_exhausted") {
		t.Fatalf("overage-off status %d body %s", status, body)
	}
	if used := s.paidQuotaUsed(); used != usedBefore {
		t.Fatalf("refused request charged the paid quota (%d -> %d)", usedBefore, used)
	}

	// The seeded MALIBU is locked: the stake is netted out of withdrawable.
	if locked := pg.exec(fmt.Sprintf(`SELECT SUM(amount_units) FROM malibu_stake_events WHERE provider_id = '%s'`, providerID)); locked != "1200000000" {
		t.Fatalf("locked units %s", locked)
	}
}

func TestStakeAllowancePrivateRequestSpendsAllowanceFirst(t *testing.T) {
	requireBins(t)
	if runtime.GOOS != "darwin" {
		t.Skip("real Swift InferenceRelay fixture requires macOS")
	}
	if _, err := exec.LookPath("swift"); err != nil {
		t.Skip("Swift toolchain unavailable")
	}
	pg := startStakePostgres(t)
	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	stateDir = resolved
	fixture := startSwiftRelayFixture(t, stateDir, defaultFakeModelID)
	providerID := "prov-stake-relay-" + randHex(t, 4)
	s := newScenario(t, scenarioOpts{
		seedAccount:                  true,
		providerID:                   providerID,
		externalWebSocketProvider:    true,
		gatewayRelayBlindEnabled:     true,
		coordinatorRelayBlindEnabled: true,
		relayBlindIdentityPublicKeys: map[string]string{providerID: fixture.descriptor.IdentityPublicKey},
		coordinatorConfig:            stakeCoordinatorConfig(pg),
		beforeCoordinator:            func(s *scenario) { seedStake(s, pg, providerID+"-owned", 1) },
	})
	defer s.shutdown()
	disconnect := connectSwiftRelayProvider(t, s.rootCtx, s, fixture)
	defer disconnect()
	s.waitForProviderReady(providerID)

	pinPath := filepath.Join(stateDir, "buyer-pin.json")
	pinRaw, err := json.Marshal(map[string]any{
		"version":             "relay-blind-pilot-pin-v1",
		"identity_public_key": fixture.descriptor.IdentityPublicKey,
		"fingerprint":         fixture.descriptor.KeyRecord["identity_fingerprint"],
		"models":              []string{defaultFakeModelID},
		"endpoint_families":   []string{"chat_completions"},
		"not_before_unix":     fixture.descriptor.KeyRecord["not_before_unix"],
		"expires_at_unix":     fixture.descriptor.KeyRecord["expires_at_unix"],
		"revoked":             false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pinPath, pinRaw, 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(relayBlindClientBin, "--base-url", s.gatewayBaseURL, "--identity-pin", pinPath,
		"--model", defaultFakeModelID, "--max-output-tokens", "32", "--input-token-upper-bound", "64", "--input", "-")
	cmd.Env = append(os.Environ(), "MACPROVIDER_API_KEY="+s.apiKey)
	cmd.Stdin = strings.NewReader(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"private"}],"max_tokens":32}`, defaultFakeModelID))
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("relay-blind client: %v\nstdout=%s\nstderr=%s", err, stdout.String(), stderr.String())
	}
	usage, ok := s.readLatestUsageEvent()
	if !ok {
		t.Fatal("missing gateway usage event")
	}
	if source := s.quotaFundingSource(usage.RequestID); source != "allowance" {
		t.Fatalf("private request funding_source=%s, want allowance", source)
	}
	split, ok := s.allowanceSplit(usage.RequestID)
	if !ok || split.funding != "allowance" || split.allowance != split.gross || split.gross <= 0 || split.paid != 0 {
		t.Fatalf("private request split %+v found=%v", split, ok)
	}
	if credits := s.providerCreditsFor(usage.RequestID); credits <= 0 {
		t.Fatalf("private request provider credits %d: the provider must be paid", credits)
	}
	if used := s.paidQuotaUsed(); used != 0 {
		t.Fatalf("private allowance request drew the paid quota: %d", used)
	}
}
