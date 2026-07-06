package scenario

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestValidateChargedDeliveredToleranceBounds(t *testing.T) {
	sc := validTestScenario()
	sc.ChargedDeliveredToleranceTokens = maxChargedDeliveredToleranceTokens
	if err := sc.Validate(); err != nil {
		t.Fatalf("max tolerance should validate: %v", err)
	}

	sc.ChargedDeliveredToleranceTokens = -1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must be >= 0") {
		t.Fatalf("negative tolerance err=%v, want >= 0 validation", err)
	}

	sc.ChargedDeliveredToleranceTokens = maxChargedDeliveredToleranceTokens + 1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must be <=") {
		t.Fatalf("oversized tolerance err=%v, want max validation", err)
	}
}

func TestValidateRequestsPerBuyerBounds(t *testing.T) {
	for _, value := range []int{-1, 0} {
		sc := validTestScenario()
		sc.Buyers.RequestsPerBuyer = value
		err := sc.Validate()
		if err == nil || !strings.Contains(err.Error(), "scenario test: requests_per_buyer must be >= 1, got") {
			t.Fatalf("requests_per_buyer=%d err=%v, want >= 1 validation", value, err)
		}
	}

	sc := validTestScenario()
	sc.Buyers.RequestsPerBuyer = 1
	if err := sc.Validate(); err != nil {
		t.Fatalf("requests_per_buyer=1 should validate: %v", err)
	}
}

func TestLoadRejectsExplicitZeroRequestsPerBuyer(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "zero.yaml")
	yaml := `
name: buyer
target:
  gateway_url: http://gateway.test
  buyer_token: token
buyers:
  count: 1
  requests_per_buyer: 0
prompts:
  - {model: m, user: hi}
duration: 1s
`
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write yaml: %v", err)
	}

	sc, err := Load(path)
	if err != nil {
		t.Fatalf("Load err=%v", err)
	}
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "requests_per_buyer must be >= 1") {
		t.Fatalf("Validate err=%v, want requests_per_buyer rejection", err)
	}
}

func TestLoadDefaultsOmittedRequestsPerBuyer(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "omitted.yaml")
	yaml := `
name: buyer
target:
  gateway_url: http://gateway.test
  buyer_token: token
buyers:
  count: 1
prompts:
  - {model: m, user: hi}
duration: 1s
`
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write yaml: %v", err)
	}

	sc, err := Load(path)
	if err != nil {
		t.Fatalf("Load err=%v", err)
	}
	if sc.Buyers.RequestsPerBuyer != 1 {
		t.Fatalf("requests_per_buyer=%d want default 1", sc.Buyers.RequestsPerBuyer)
	}
	if err := sc.Validate(); err != nil {
		t.Fatalf("Validate err=%v", err)
	}
}

func TestValidateBuyerFleetUpperBounds(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Scenario)
		wantIn string
	}{
		{"buyers.count", func(s *Scenario) { s.Buyers.Count = MaxBuyerCount + 1 }, "buyers.count must be <="},
		{"buyers.requests_per_buyer", func(s *Scenario) { s.Buyers.RequestsPerBuyer = MaxRequestsPerBuyer + 1 }, "buyers.requests_per_buyer must be <="},
		{"total requests", func(s *Scenario) {
			s.Buyers.Count = MaxBuyerCount
			s.Buyers.RequestsPerBuyer = MaxRequestsPerBuyer
		}, "buyers.count * buyers.requests_per_buyer must be <="},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := validTestScenario()
			tc.mutate(&sc)
			err := sc.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.wantIn) {
				t.Fatalf("err=%v want substring %q", err, tc.wantIn)
			}
		})
	}

	sc := validTestScenario()
	sc.Buyers.Count = MaxBuyerCount
	sc.Buyers.RequestsPerBuyer = MaxTotalBuyerRequests / MaxBuyerCount
	if err := sc.Validate(); err != nil {
		t.Fatalf("max bounded scenario should validate: %v", err)
	}
}

func TestValidateRejectsInvalidTimingFields(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Scenario)
		wantIn string
	}{
		{"request_timeout negative", func(s *Scenario) { s.RequestTimeout = -time.Second }, "request_timeout must be >= 0"},
		{"silent_hang_threshold negative", func(s *Scenario) { s.SilentHangThreshold = -time.Second }, "silent_hang_threshold must be >= 0"},
		{"duration negative", func(s *Scenario) { s.Duration = -time.Second }, "duration must be >= 0"},
		{"burst duration negative", func(s *Scenario) {
			s.Buyers.Pattern = "burst"
			s.Duration = -time.Second
		}, "duration must be >= 0"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := validTestScenario()
			tc.mutate(&sc)
			err := sc.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.wantIn) {
				t.Fatalf("err=%v want substring %q", err, tc.wantIn)
			}
		})
	}
}

func TestValidateAllowsDefaultTimingFields(t *testing.T) {
	sc := validTestScenario()
	sc.RequestTimeout = 0
	sc.SilentHangThreshold = 0
	if err := sc.Validate(); err != nil {
		t.Fatalf("zero timing fields should validate as defaults: %v", err)
	}
}

func TestValidateRejectsNegativeNumericFields(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Scenario)
		wantIn string
	}{
		{"buyers.count", func(s *Scenario) { s.Buyers.Count = -1 }, "buyers.count must be >= 1"},
		{"buyers.requests_per_buyer", func(s *Scenario) { s.Buyers.RequestsPerBuyer = -1 }, "requests_per_buyer must be >= 1"},
		{"buyers.initial_delay", func(s *Scenario) { s.Buyers.InitialDelay = -time.Second }, "buyers.initial_delay must be >= 0"},
		{"buyers.interval_ms", func(s *Scenario) { s.Buyers.IntervalMs = -1 }, "buyers.interval_ms must be >= 0"},
		{"buyers.inter_pair_idle_seconds", func(s *Scenario) { s.Buyers.InterPairIdleSeconds = -1 }, "buyers.inter_pair_idle_seconds must be >= 0"},
		{"prompts.max_tokens", func(s *Scenario) { s.Prompts[0].MaxTokens = -1 }, "prompts[0].max_tokens must be >= 0"},
		{"charged_delivered_tolerance_tokens", func(s *Scenario) { s.ChargedDeliveredToleranceTokens = -1 }, "charged_delivered_tolerance_tokens must be >= 0"},
		{"benchmark.provider_slots", func(s *Scenario) {
			s.Benchmark.Enabled = true
			s.Benchmark.Invariants = []string{"B1"}
			s.Benchmark.ProviderSlots = -1
		}, "benchmark.provider_slots must be >= 1"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := validTestScenario()
			tc.mutate(&sc)
			err := sc.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.wantIn) {
				t.Fatalf("err=%v want substring %q", err, tc.wantIn)
			}
		})
	}
}

func TestValidateSKUEconPinsCoordinatorURL(t *testing.T) {
	tpl := Scenario{
		Name: "sku",
		Mode: "sku-econ",
		Target: Target{
			CoordinatorURL: "https://coordinator.streamvc.live",
			CLIBin:         "/path/to/cli",
		},
		HardwareMatrix: []HardwareMatrixRow{
			{Label: "m4", Chip: "Apple M4", MemoryGB: 32, BandwidthTier: "C", Expected: "at_least_one_eligible_row"},
		},
		BenchmarkSynthesis: BenchmarkSynthesis{
			Mode:                  "warm_cache_synthetic",
			TPSMultiplierOfGate:   1.10,
			TTFTFractionOfCeiling: 0.85,
		},
	}

	if err := tpl.Validate(); err != nil {
		t.Fatalf("baseline sku-econ scenario should validate: %v", err)
	}

	deprecated := tpl
	deprecated.HardwareMatrix[0].Expected = "at_least_one_paid_row"
	if err := deprecated.Validate(); err == nil || !strings.Contains(err.Error(), "deprecated sku-econ vocabulary") {
		t.Fatalf("deprecated expected err=%v, want vocabulary rejection", err)
	}

	cases := []struct {
		name   string
		url    string
		wantIn string
	}{
		{"http scheme rejected", "http://coordinator.streamvc.live", "https scheme"},
		{"attacker host rejected", "https://evil.example.com", "coordinator.streamvc.live"},
		{"path-only wrong host rejected", "https://coordinator.streamvc.dev", "coordinator.streamvc.live"},
		{"userinfo rejected", "https://user:pass@coordinator.streamvc.live", "userinfo"},
		{"non-root path rejected", "https://coordinator.streamvc.live/admin", "empty or /"},
		{"deep path rejected", "https://coordinator.streamvc.live/attacker/v1", "empty or /"},
		{"query string rejected", "https://coordinator.streamvc.live/?evil=1", "query or fragment"},
		{"fragment rejected", "https://coordinator.streamvc.live/#evil", "query or fragment"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := tpl
			sc.Target.CoordinatorURL = tc.url
			err := sc.Validate()
			if err == nil {
				t.Fatalf("%q should be rejected", tc.url)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Fatalf("err=%q, want substring %q", err.Error(), tc.wantIn)
			}
		})
	}
}

func TestProbeModeReadsResolvedModeWithoutEnvExpansion(t *testing.T) {
	// A tampered scenario should never be able to interpolate parent-shell
	// secrets during the mode probe. SEC-M-1 (r3 security audit).
	t.Setenv("BUYER_TOKEN", "should-not-leak-into-yaml")

	cases := []struct {
		name  string
		yaml  string
		want  string
		errIn string
	}{
		{name: "plain scalar", yaml: "mode: sku-econ\n", want: "sku-econ"},
		{name: "single-quoted", yaml: "mode: 'sku-econ'\n", want: "sku-econ"},
		{name: "double-quoted", yaml: `mode: "sku-econ"` + "\n", want: "sku-econ"},
		{name: "yaml anchor", yaml: "mode: &m sku-econ\n", want: "sku-econ"},
		{name: "extra whitespace", yaml: "mode:    sku-econ\n", want: "sku-econ"},
		{name: "missing key defaults", yaml: "name: nomode\n", want: "buyer-fleet"},
		{name: "buyer-fleet explicit", yaml: "mode: buyer-fleet\n", want: "buyer-fleet"},
		{name: "mode placeholder rejected", yaml: "mode: \"${MODE}\"\n", errIn: "mode must not contain"},
	}

	dir := t.TempDir()
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, tc.name+".yaml")
			if err := os.WriteFile(path, []byte(tc.yaml), 0o600); err != nil {
				t.Fatalf("write yaml: %v", err)
			}
			got, err := ProbeMode(path)
			if tc.errIn != "" {
				if err == nil || !strings.Contains(err.Error(), tc.errIn) {
					t.Fatalf("err=%v want substring %q", err, tc.errIn)
				}
				return
			}
			if err != nil {
				t.Fatalf("ProbeMode err: %v", err)
			}
			if got != tc.want {
				t.Fatalf("ProbeMode = %q, want %q", got, tc.want)
			}
		})
	}

	// Env expansion MUST NOT occur — a scenario with ${BUYER_TOKEN} in a
	// non-mode field must leave the placeholder untouched and still parse
	// mode correctly. Load would expand it; ProbeMode must not.
	t.Run("no env expansion", func(t *testing.T) {
		yaml := "mode: sku-econ\nname: \"${BUYER_TOKEN}\"\n"
		path := filepath.Join(dir, "envexpand.yaml")
		if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
			t.Fatalf("write yaml: %v", err)
		}
		got, err := ProbeMode(path)
		if err != nil {
			t.Fatalf("ProbeMode err: %v", err)
		}
		if got != "sku-econ" {
			t.Fatalf("mode=%q want sku-econ", got)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("re-read: %v", err)
		}
		if !strings.Contains(string(raw), "${BUYER_TOKEN}") {
			t.Fatalf("expected placeholder preserved in source, got: %s", raw)
		}
		if strings.Contains(string(raw), "should-not-leak-into-yaml") {
			t.Fatalf("secret already substituted into source (impossible unless test setup wrong)")
		}
	})
}

func TestLoadNoEnvRejectsSKUEconPlaceholders(t *testing.T) {
	t.Setenv("GH_TOKEN", "should-not-leak")
	dir := t.TempDir()
	path := filepath.Join(dir, "sku.yaml")
	yaml := `
name: "${GH_TOKEN}"
mode: sku-econ
target:
  coordinator_url: https://coordinator.streamvc.live
  cli_bin: /tmp/macprovider-cli
hardware_matrix:
  - {label: m4, chip: "Apple M4", memoryGB: 32, bandwidthTier: C, expected: at_least_one_eligible_row}
benchmark_synthesis:
  mode: warm_cache_synthetic
  tps_multiplier_of_gate: 1.10
  ttft_fraction_of_ceiling: 0.85
`
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write yaml: %v", err)
	}

	_, err := LoadNoEnv(path)
	if err == nil || !strings.Contains(err.Error(), "must not contain ${VAR}") {
		t.Fatalf("LoadNoEnv err=%v, want placeholder rejection", err)
	}
}

func TestLoadStillExpandsBuyerFleetPlaceholders(t *testing.T) {
	t.Setenv("BUYER_TOKEN", "expanded-token")
	dir := t.TempDir()
	path := filepath.Join(dir, "buyer.yaml")
	yaml := `
name: buyer
target:
  gateway_url: http://gateway.test
  buyer_token: "${BUYER_TOKEN}"
buyers:
  count: 1
  requests_per_buyer: 1
prompts:
  - {model: m, user: hi}
duration: 1s
`
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write yaml: %v", err)
	}

	sc, err := Load(path)
	if err != nil {
		t.Fatalf("Load err: %v", err)
	}
	if sc.Target.BuyerToken != "expanded-token" {
		t.Fatalf("buyer token=%q, want expanded-token", sc.Target.BuyerToken)
	}
}

func validTestScenario() Scenario {
	return Scenario{
		Name:                "test",
		Duration:            time.Second,
		RequestTimeout:      time.Second,
		SilentHangThreshold: time.Second,
		Target: Target{
			GatewayURL:     "http://gateway.test",
			BuyerToken:     "token",
			CoordinatorURL: "http://coordinator.test",
		},
		Buyers: Buyers{
			Count:            1,
			RequestsPerBuyer: 1,
			Pattern:          "constant",
		},
		Prompts: []Prompt{{Model: "model-a", User: "hello"}},
	}
}
