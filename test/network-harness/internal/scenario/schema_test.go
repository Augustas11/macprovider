package scenario

import (
	"os"
	"path/filepath"
	"sort"
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

func TestValidateMaxCompletionTokenDeltaBounds(t *testing.T) {
	sc := validTestScenario()
	sc.MaxCompletionTokenDelta = maxCompletionTokenDelta
	if err := sc.Validate(); err != nil {
		t.Fatalf("max completion-token delta should validate: %v", err)
	}

	sc.MaxCompletionTokenDelta = -1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must be >= 0") {
		t.Fatalf("negative max completion-token delta err=%v, want >= 0 validation", err)
	}

	sc.MaxCompletionTokenDelta = maxCompletionTokenDelta + 1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must be <=") {
		t.Fatalf("oversized max completion-token delta err=%v, want max validation", err)
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
		{"max_completion_token_delta", func(s *Scenario) { s.MaxCompletionTokenDelta = -1 }, "max_completion_token_delta must be >= 0"},
		{"required_gateway_outcome whitespace", func(s *Scenario) { s.RequiredGatewayOutcome = " ok" }, "required_gateway_outcome must not have leading or trailing whitespace"},
		{"required_gateway_token_source whitespace", func(s *Scenario) { s.RequiredGatewayTokenSource = "provider_reported " }, "required_gateway_token_source must not have leading or trailing whitespace"},
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
			CoordinatorURL: "https://coordinator.malibu.tech",
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
		{"http scheme rejected", "http://coordinator.malibu.tech", "https scheme"},
		{"attacker host rejected", "https://evil.example.com", "coordinator.malibu.tech"},
		{"path-only wrong host rejected", "https://coordinator.malibu.invalid", "coordinator.malibu.tech"},
		{"userinfo rejected", "https://user:pass@coordinator.malibu.tech", "userinfo"},
		{"non-root path rejected", "https://coordinator.malibu.tech/admin", "empty or /"},
		{"deep path rejected", "https://coordinator.malibu.tech/attacker/v1", "empty or /"},
		{"query string rejected", "https://coordinator.malibu.tech/?evil=1", "query or fragment"},
		{"fragment rejected", "https://coordinator.malibu.tech/#evil", "query or fragment"},
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
  coordinator_url: https://coordinator.malibu.tech
  cli_bin: /tmp/malibu-cli
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

func TestCommittedScenariosValidate(t *testing.T) {
	t.Setenv("BUYER_TOKEN", "test-buyer-token")
	// 15_thermal_soak.yaml targets ${LAB_GATEWAY_URL}/${LAB_COORDINATOR_URL},
	// intentionally unset at runtime so a bare soak run fails validation
	// rather than firing at a default (LAB PROVIDER ONLY — #584). Supply
	// placeholders here so the structural-validity check still covers it.
	t.Setenv("LAB_GATEWAY_URL", "http://127.0.0.1:18080")
	t.Setenv("LAB_COORDINATOR_URL", "http://127.0.0.1:19090")

	paths, err := filepath.Glob(filepath.Join("..", "..", "scenarios", "*.yaml"))
	if err != nil {
		t.Fatalf("glob scenarios: %v", err)
	}
	if len(paths) == 0 {
		t.Fatal("no committed scenario files found")
	}
	sort.Strings(paths)

	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			mode, err := ProbeMode(path)
			if err != nil {
				t.Fatalf("ProbeMode err=%v", err)
			}
			var sc *Scenario
			if mode == "sku-econ" {
				sc, err = LoadNoEnv(path)
			} else {
				sc, err = Load(path)
			}
			if err != nil {
				t.Fatalf("Load err=%v", err)
			}
			if err := sc.Validate(); err != nil {
				t.Fatalf("Validate err=%v", err)
			}
		})
	}
}

func TestB10_LabOnly_RejectsProdHost(t *testing.T) {
	mk := func(gw, coord string) *Scenario {
		s := validTestScenario()
		s.Target.GatewayURL = gw
		s.Target.CoordinatorURL = coord
		s.Benchmark = Benchmark{Enabled: true, Invariants: []string{"B1", "B10"}, ProviderSlots: 3}
		return &s
	}
	cases := []struct {
		name    string
		gw      string
		coord   string
		wantErr bool
	}{
		{"loopback ok", "http://127.0.0.1:18080", "http://127.0.0.1:19090", false},
		{"localhost ok", "http://localhost:18080", "http://localhost:19090", false},
		{"private LAN ok", "http://192.168.1.20:18080", "http://10.0.0.5:19090", false},
		{"ipv6 loopback ok", "http://[::1]:18080", "http://[::1]:19090", false},
		{"prod gateway rejected", "https://api.malibu.tech", "http://127.0.0.1:19090", true},
		{"prod coordinator rejected", "http://127.0.0.1:18080", "https://coordinator.malibu.tech", true},
		{"prod subdomain rejected", "https://foo.malibu.tech", "http://127.0.0.1:19090", true},
		{"apex prod rejected", "https://malibu.tech", "http://127.0.0.1:19090", true},
		// Bypass variants the R1 denylist missed (R2 HIGH):
		{"trailing-dot prod rejected", "https://api.malibu.tech./", "http://127.0.0.1:19090", true},
		{"uppercase prod rejected", "https://API.MALIBU.TECH", "http://127.0.0.1:19090", true},
		{"fullwidth-dot prod rejected", "https://api．malibu．tech", "http://127.0.0.1:19090", true},
		{"ideographic-dot prod rejected", "https://api。malibu。tech", "http://127.0.0.1:19090", true},
		// Any public host (not just prod) is rejected — positive allowlist.
		{"arbitrary public host rejected", "https://example.com", "http://127.0.0.1:19090", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := mk(tc.gw, tc.coord).Validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("Validate err=%v, wantErr=%v", err, tc.wantErr)
			}
		})
	}
	// The guard applies even when benchmark.enabled=false — the sustained
	// buyer load runs regardless of scoring (R2 HIGH).
	t.Run("disabled benchmark still guards B10", func(t *testing.T) {
		s := mk("https://api.malibu.tech", "http://127.0.0.1:19090")
		s.Benchmark.Enabled = false
		if err := s.Validate(); err == nil {
			t.Fatal("B10 + benchmark.enabled=false + prod host must still be rejected")
		}
	})
	// A non-B10 scenario may still target prod (the other scenarios do).
	t.Run("non-B10 may target prod", func(t *testing.T) {
		s := validTestScenario()
		s.Target.GatewayURL = "https://api.malibu.tech"
		s.Benchmark = Benchmark{Enabled: true, Invariants: []string{"B1", "B2"}, ProviderSlots: 3}
		if err := s.Validate(); err != nil {
			t.Fatalf("non-B10 scenario must still allow prod host, got %v", err)
		}
	})
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
