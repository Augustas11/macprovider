// Package scenario defines the YAML schema for an internal e2e network
// scenario. Phase A is descriptive: ExpectedShape is free-text recorded
// into the artifact bundle for human triage, not asserted on. The only
// hard pass/fail at the scenario level is the 4 invariants in package
// invariants.
package scenario

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// SKUEconCoordinatorHost is the only host sku-econ mode may fetch from.
// SEC-M-1 (r1 security audit) — the runner's rate-card fetch trusts
// target.coordinator_url; without a validator, a scenario YAML could
// point at an attacker-controlled host. The Swift @LIVE path already
// pins this host; validateSKUEcon enforces the same pin on the Go side.
// Exported so the sku-econ runner can build fetch URLs from the same
// constant rather than concatenating the scenario-supplied field, per
// SEC-H-1 (r2 security audit) defense-in-depth.
const SKUEconCoordinatorHost = "coordinator.streamvc.live"

// envVarPattern matches `${VAR}` references for safe expansion at load
// time. Lets scenarios reference secrets like ${BUYER_TOKEN} without
// committing them. Unset vars expand to "" — Validate() then rejects
// any required field that's empty.
var envVarPattern = regexp.MustCompile(`\$\{([A-Z_][A-Z0-9_]*)\}`)

const (
	maxChargedDeliveredToleranceTokens int64 = 16
	maxCompletionTokenDelta            int64 = 16
	MaxBuyerCount                            = 1000
	MaxRequestsPerBuyer                      = 10000
	MaxTotalBuyerRequests                    = 100000
)

func expandEnv(input []byte) []byte {
	return envVarPattern.ReplaceAllFunc(input, func(match []byte) []byte {
		name := envVarPattern.FindSubmatch(match)[1]
		return []byte(os.Getenv(string(name)))
	})
}

// Scenario is the top-level YAML root.
type Scenario struct {
	Name        string `yaml:"name"`
	Mode        string `yaml:"mode"`
	Description string `yaml:"description"`

	// ExpectedShape is human-readable "what we're looking to learn" text.
	// Phase A: recorded only, not asserted. Phase B: triaged into the
	// routing-contract addendum, then becomes assertions in a future PR.
	ExpectedShape string `yaml:"expected_shape"`

	Target  Target   `yaml:"target"`
	Buyers  Buyers   `yaml:"buyers"`
	Prompts []Prompt `yaml:"prompts"`

	// Duration caps the scenario wall-clock. Buyers stop firing new
	// requests when elapsed >= Duration; in-flight requests are awaited.
	Duration time.Duration `yaml:"duration"`

	// SilentHangThreshold defines invariant I4: a stream that stays open
	// this long with zero bytes and no terminating error is a silent hang.
	SilentHangThreshold time.Duration `yaml:"silent_hang_threshold"`

	// ChargedDeliveredToleranceTokens allows scenarios with known tokenizer
	// drift to permit a small charged-vs-delivered delta. Default 0.
	ChargedDeliveredToleranceTokens int64 `yaml:"charged_delivered_tolerance_tokens"`

	// MaxCompletionTokenDelta, when >0, makes I1 fail if any matched
	// buyer/gateway success pair differs by more than this many completion
	// tokens in either direction. Default 0 preserves existing scenarios,
	// where gateway underbilling alone is treated as triage evidence.
	MaxCompletionTokenDelta int64 `yaml:"max_completion_token_delta"`

	// RequiredGatewayOutcome, when non-empty, makes I1 fail if any matched
	// buyer/gateway success pair has a different gateway outcome. Default
	// empty preserves existing scenarios where outcome details are triage
	// evidence only.
	RequiredGatewayOutcome string `yaml:"required_gateway_outcome"`

	// RequiredGatewayTokenSource, when non-empty, makes I1 fail if any
	// matched buyer/gateway success pair has a different gateway token
	// source. Default empty preserves old snapshots and legacy scenarios.
	RequiredGatewayTokenSource string `yaml:"required_gateway_token_source"`

	// RequestTimeout is a per-request hard cap. Default 120s if unset.
	RequestTimeout time.Duration `yaml:"request_timeout"`

	// ChaosEvents is a timeline of shell commands fired alongside the
	// buyer fleet. Used to script provider WS kills, restarts, network
	// throttles for chaos scenarios. Each command runs via /bin/sh -c;
	// stdout/stderr/exit are captured into run_meta.json.
	ChaosEvents []ChaosEvent `yaml:"chaos_events"`

	// Benchmark, when Enabled, runs the phase-B benchmark suite (B1-B6)
	// against this scenario's results. See docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md.
	Benchmark Benchmark `yaml:"benchmark"`

	HardwareMatrix     []HardwareMatrixRow `yaml:"hardware_matrix"`
	Invariants         []string            `yaml:"invariants"`
	BenchmarkSynthesis BenchmarkSynthesis  `yaml:"benchmark_synthesis"`
	Artifacts          []string            `yaml:"artifacts"`

	buyersRequestsPerBuyerSet bool
}

// Benchmark declares which B-invariants this scenario should evaluate
// and where to source pricing for B6 (earnings/hr). Enabled=false (or
// the whole block omitted) skips the benchmark suite.
type Benchmark struct {
	Enabled    bool     `yaml:"enabled"`
	Invariants []string `yaml:"invariants"`

	// PricingSource locates a tier-2 pricing manifest for B6. Two forms:
	//   * local path:     "/abs/path/to/tier2-catalog.json"
	//   * SSH host:path:  "pearl:/opt/macprovider/tier2-catalog.json"
	// Unset → B6 SKIP.
	PricingSource string `yaml:"pricing_source"`

	// ProviderSlots is the assumed per-provider concurrency cap used by
	// B5 (slot utilization). Defaults to 3 — the Pearl coordinator's
	// AccountConcurrency at the time this spec landed (PR #205).
	ProviderSlots int `yaml:"provider_slots"`

	// SustainedGateArmed arms B10 (sustained streaming-TPS retention) as a
	// blocking gate. When false (the default), B10 still measures and
	// reports retention, but a would-be FAIL is downgraded to WARN so an
	// UNCALIBRATED gate can never block a run. The B10 thresholds are
	// provisional (PASS >= 0.85 / WARN >= 0.70 / FAIL < 0.70) and must be
	// calibrated against a real lab soak before this flag is set true —
	// see docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md §3.5 and issue #584.
	SustainedGateArmed bool `yaml:"sustained_gate_armed"`
}

// ChaosEvent is one scheduled shell action. `At` is measured from
// scenario start (the moment buyer.Run begins). Late events whose `At`
// falls outside the scenario `Duration` are still executed, so a cleanup
// command like "restart the provider we just killed" reliably fires.
type ChaosEvent struct {
	At          time.Duration `yaml:"at"`
	Command     string        `yaml:"command"`
	Description string        `yaml:"description"`
}

// Target identifies the running stack the harness fires against. The
// harness does NOT spawn coordinator/gateway — that's the caller's job
// (test/integration/ helpers, deploy scripts, or a live Pearl stack).
type Target struct {
	GatewayURL     string `yaml:"gateway_url"`
	CoordinatorURL string `yaml:"coordinator_url"`

	CLIBin string `yaml:"cli_bin"`

	// CoordinatorDBPath + GatewayDBPath are filesystem paths to the
	// SQLite files holding request_log + usage_events. Required for
	// I1 (billing reconciliation). When unset, reconciliation is
	// skipped and I1 is marked skipped (not failed).
	CoordinatorDBPath string `yaml:"coordinator_db_path"`
	GatewayDBPath     string `yaml:"gateway_db_path"`

	// CoordinatorDBSSH + GatewayDBSSH enable I1 against a live remote
	// stack (Pearl). Form: "user@host:/absolute/path/to.db". When set,
	// the harness pulls a WAL-consistent snapshot via:
	//   ssh user@host "[sudo -u DBSudoUser] sqlite3 /path 'VACUUM INTO /tmp/snap.db'"
	//   scp user@host:/tmp/snap.db <local-tmp>
	//   ssh user@host "rm /tmp/snap.db"
	// then opens the local copy read-only. Set both or neither.
	CoordinatorDBSSH string `yaml:"coordinator_db_ssh"`
	GatewayDBSSH     string `yaml:"gateway_db_ssh"`

	// DBSudoUser, when set, wraps the remote sqlite3 invocation in
	// `sudo -u <DBSudoUser>`. Required on Pearl where the SQLite files
	// are owned by the `macprovider` service user, not root.
	DBSudoUser string `yaml:"db_sudo_user"`

	// BuyerToken is the bearer token sent in Authorization header.
	// Either BuyerToken or DemoIdentity must be set.
	BuyerToken string `yaml:"buyer_token"`

	// DemoIdentity, when set, is sent via the gateway's demo path
	// (no bearer). Mutually exclusive with BuyerToken.
	DemoIdentity string `yaml:"demo_identity"`

	// OperatorToken authenticates against /admin/explorer/* introspection
	// endpoints when the harness pre-flights provider visibility.
	OperatorToken string `yaml:"operator_token"`
}

type HardwareMatrixRow struct {
	Label         string `yaml:"label"`
	Chip          string `yaml:"chip"`
	MemoryGB      int    `yaml:"memoryGB"`
	BandwidthTier string `yaml:"bandwidthTier"`
	Expected      string `yaml:"expected"`
}

type BenchmarkSynthesis struct {
	Mode                  string  `yaml:"mode"`
	TPSMultiplierOfGate   float64 `yaml:"tps_multiplier_of_gate"`
	TTFTFractionOfCeiling float64 `yaml:"ttft_fraction_of_ceiling"`
}

// Buyers describes the concurrent buyer fleet.
type Buyers struct {
	Count  int  `yaml:"count"`
	Stream bool `yaml:"stream"`

	// Pattern selects how requests are paced across the fleet.
	//   "constant"          — every buyer fires back-to-back, no inter-request delay
	//   "interval"          — every buyer waits IntervalMs between requests
	//   "ramp"              — buyers come online linearly across RampDuration
	//   "burst"             — all buyers fire one request at t=0, no follow-ups
	//   "cold_warm_pairs"   — per-buyer (idle, cold, warm) pairs for scenario 08;
	//                         each pair sleeps InterPairIdleSeconds, fires one
	//                         "cold" request, then immediately fires one "warm"
	//                         request. RequestsPerBuyer MUST be even (= 2 × pairs).
	Pattern          string        `yaml:"pattern"`
	InitialDelay     time.Duration `yaml:"initial_delay"`
	IntervalMs       int           `yaml:"interval_ms"`
	RampDuration     time.Duration `yaml:"ramp_duration"`
	RequestsPerBuyer int           `yaml:"requests_per_buyer"`

	// InterPairIdleSeconds is the sleep before each (cold, warm) pair
	// under pattern=cold_warm_pairs. Required when that pattern is set.
	// 60s matches the spec §4.2 reference design — long enough for the
	// provider to drop in-flight state but short enough for 10 pairs to
	// fit in ~15min wall-clock.
	InterPairIdleSeconds int `yaml:"inter_pair_idle_seconds"`

	// StickyConversationKey is a printf-style template with a single %d
	// verb for the buyer index. When set, each buyer sends
	//
	//   X-MacProvider-Conversation: <expanded-template>
	//
	// on every request, activating SPEC-004 Pillar A sticky affinity —
	// the gateway HMAC-derives the internal key and forwards to coord
	// as X-MacProvider-Internal-Conv. Coord routes by that key when
	// its routing.sticky_enabled flag is true. Requires both:
	//
	//   1. gateway routing.sticky_enabled: true + auth.key_hash_secret set
	//   2. coordinator routing.sticky_enabled: true
	//
	// Empty string (default) leaves the header off — pre-existing
	// scenarios behave exactly as before. Non-sticky scenarios should
	// keep this empty so their B4/B5 numbers stay comparable to prior
	// baselines.
	//
	// Example: "harness-buyer-%d" → buyer 0 sends
	// "X-MacProvider-Conversation: harness-buyer-0" on every request.
	StickyConversationKey string `yaml:"sticky_conversation_key"`
}

// Prompt is one item in the rotating prompt pool. Buyers pick by index
// modulo len(prompts) so the harness output is deterministic given the
// same scenario + buyer count.
type Prompt struct {
	Model     string `yaml:"model"`
	System    string `yaml:"system"`
	User      string `yaml:"user"`
	MaxTokens int    `yaml:"max_tokens"`
}

// ProbeMode reads path and returns the resolved scenario mode WITHOUT
// performing environment-variable expansion. Used by cmd/harness/mode
// to gate secret handling in run-scenario.sh; expanding ${VAR} at probe
// time would let a raced or attacker-supplied scenario interpolate
// parent-shell secrets into any accepted field (and into validation
// error output), which SEC-M-1 (r3 security audit) flagged as a leak
// vector separate from the CLI-child env sanitizer. This function is
// intentionally minimal — it decodes only the top-level `mode` scalar
// and NEVER calls expandEnv.
func ProbeMode(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if envVarPattern.Match(b) {
		var rawMode struct {
			Mode string `yaml:"mode"`
		}
		if err := yaml.Unmarshal(b, &rawMode); err != nil {
			return "", fmt.Errorf("yaml: %w", err)
		}
		if envVarPattern.MatchString(rawMode.Mode) {
			return "", fmt.Errorf("mode must not contain ${VAR} placeholders")
		}
	}
	var probe struct {
		Mode string `yaml:"mode"`
	}
	if err := yaml.Unmarshal(b, &probe); err != nil {
		return "", fmt.Errorf("yaml: %w", err)
	}
	if probe.Mode == "" {
		return "buyer-fleet", nil
	}
	return probe.Mode, nil
}

// Load reads and unmarshals a scenario YAML file.
func Load(path string) (*Scenario, error) {
	return load(path, true)
}

// LoadNoEnv reads a scenario without expanding ${VAR} placeholders. sku-econ
// scenarios do not need secrets; leaving expansion disabled prevents a scenario
// from copying parent-shell credentials into artifact fields.
func LoadNoEnv(path string) (*Scenario, error) {
	return load(path, false)
}

func load(path string, expand bool) (*Scenario, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if expand {
		b = expandEnv(b)
	}
	var sc Scenario
	if err := yaml.Unmarshal(b, &sc); err != nil {
		return nil, fmt.Errorf("yaml: %w", err)
	}
	sc.buyersRequestsPerBuyerSet = yamlMapPathHasKey(b, "buyers", "requests_per_buyer")
	if !expand && sc.Mode == "sku-econ" && envVarPattern.Match(b) {
		return nil, fmt.Errorf("sku-econ scenarios must not contain ${VAR} placeholders")
	}
	sc.applyDefaults()
	return &sc, nil
}

func (s *Scenario) applyDefaults() {
	if s.Mode == "" {
		s.Mode = "buyer-fleet"
	}
	if s.RequestTimeout == 0 {
		s.RequestTimeout = 120 * time.Second
	}
	if s.SilentHangThreshold == 0 {
		s.SilentHangThreshold = 30 * time.Second
	}
	if s.Buyers.Pattern == "" {
		s.Buyers.Pattern = "constant"
	}
	if s.Buyers.RequestsPerBuyer == 0 && !s.buyersRequestsPerBuyerSet {
		s.Buyers.RequestsPerBuyer = 1
	}
	if s.Benchmark.Enabled && s.Benchmark.ProviderSlots == 0 {
		s.Benchmark.ProviderSlots = 3
	}
	if s.Mode == "sku-econ" {
		if s.BenchmarkSynthesis.Mode == "" {
			s.BenchmarkSynthesis.Mode = "warm_cache_synthetic"
		}
		if s.BenchmarkSynthesis.TPSMultiplierOfGate == 0 {
			s.BenchmarkSynthesis.TPSMultiplierOfGate = 1.10
		}
		if s.BenchmarkSynthesis.TTFTFractionOfCeiling == 0 {
			s.BenchmarkSynthesis.TTFTFractionOfCeiling = 0.85
		}
	}
}

func yamlMapPathHasKey(b []byte, path ...string) bool {
	var root yaml.Node
	if err := yaml.Unmarshal(b, &root); err != nil || len(root.Content) == 0 {
		return false
	}
	node := root.Content[0]
	for _, key := range path {
		if node.Kind != yaml.MappingNode {
			return false
		}
		var next *yaml.Node
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == key {
				next = node.Content[i+1]
				break
			}
		}
		if next == nil {
			return false
		}
		node = next
	}
	return true
}

// Validate returns a non-nil error if the scenario is missing required
// fields or has contradictory settings. Catches authoring mistakes
// before any request is fired.
func (s *Scenario) Validate() error {
	if strings.TrimSpace(s.Name) == "" {
		return fmt.Errorf("name is required")
	}
	mode := s.Mode
	if mode == "" {
		mode = "buyer-fleet"
	}
	switch mode {
	case "buyer-fleet":
		return s.validateBuyerFleet()
	case "sku-econ":
		return s.validateSKUEcon()
	default:
		return fmt.Errorf("mode must be one of buyer-fleet|sku-econ (got %q)", s.Mode)
	}
}

func (s *Scenario) validateBuyerFleet() error {
	if s.Target.GatewayURL == "" {
		return fmt.Errorf("target.gateway_url is required")
	}
	if s.Target.BuyerToken == "" && s.Target.DemoIdentity == "" {
		return fmt.Errorf("target requires either buyer_token or demo_identity")
	}
	if s.Target.BuyerToken != "" && s.Target.DemoIdentity != "" {
		return fmt.Errorf("target.buyer_token and target.demo_identity are mutually exclusive")
	}
	if (s.Target.CoordinatorDBSSH != "") != (s.Target.GatewayDBSSH != "") {
		return fmt.Errorf("target.coordinator_db_ssh and target.gateway_db_ssh must be set together")
	}
	if s.ChargedDeliveredToleranceTokens < 0 {
		return fmt.Errorf("charged_delivered_tolerance_tokens must be >= 0")
	}
	if s.ChargedDeliveredToleranceTokens > maxChargedDeliveredToleranceTokens {
		return fmt.Errorf("charged_delivered_tolerance_tokens must be <= %d", maxChargedDeliveredToleranceTokens)
	}
	if s.MaxCompletionTokenDelta < 0 {
		return fmt.Errorf("max_completion_token_delta must be >= 0")
	}
	if s.MaxCompletionTokenDelta > maxCompletionTokenDelta {
		return fmt.Errorf("max_completion_token_delta must be <= %d", maxCompletionTokenDelta)
	}
	if s.RequiredGatewayOutcome != strings.TrimSpace(s.RequiredGatewayOutcome) {
		return fmt.Errorf("required_gateway_outcome must not have leading or trailing whitespace")
	}
	if s.RequiredGatewayTokenSource != strings.TrimSpace(s.RequiredGatewayTokenSource) {
		return fmt.Errorf("required_gateway_token_source must not have leading or trailing whitespace")
	}
	if s.Target.CoordinatorDBSSH != "" && s.Target.CoordinatorDBPath != "" {
		return fmt.Errorf("target.coordinator_db_ssh and target.coordinator_db_path are mutually exclusive")
	}
	if s.Target.GatewayDBSSH != "" && s.Target.GatewayDBPath != "" {
		return fmt.Errorf("target.gateway_db_ssh and target.gateway_db_path are mutually exclusive")
	}
	if s.RequestTimeout < 0 {
		return fmt.Errorf("request_timeout must be >= 0")
	}
	if s.SilentHangThreshold < 0 {
		return fmt.Errorf("silent_hang_threshold must be >= 0")
	}
	if s.Duration < 0 {
		return fmt.Errorf("duration must be >= 0")
	}
	for i, c := range s.ChaosEvents {
		if c.Command == "" {
			return fmt.Errorf("chaos_events[%d].command is required", i)
		}
		if c.At < 0 {
			return fmt.Errorf("chaos_events[%d].at must be >= 0", i)
		}
	}
	if s.Buyers.Count < 1 {
		return fmt.Errorf("buyers.count must be >= 1")
	}
	if s.Buyers.Count > MaxBuyerCount {
		return fmt.Errorf("buyers.count must be <= %d", MaxBuyerCount)
	}
	if s.Buyers.RequestsPerBuyer < 1 {
		return fmt.Errorf("scenario %s: requests_per_buyer must be >= 1, got %d", s.Name, s.Buyers.RequestsPerBuyer)
	}
	if s.Buyers.RequestsPerBuyer > MaxRequestsPerBuyer {
		return fmt.Errorf("buyers.requests_per_buyer must be <= %d", MaxRequestsPerBuyer)
	}
	if s.Buyers.Count > MaxTotalBuyerRequests/s.Buyers.RequestsPerBuyer {
		return fmt.Errorf("buyers.count * buyers.requests_per_buyer must be <= %d", MaxTotalBuyerRequests)
	}
	if s.Buyers.InitialDelay < 0 {
		return fmt.Errorf("buyers.initial_delay must be >= 0")
	}
	if s.Buyers.IntervalMs < 0 {
		return fmt.Errorf("buyers.interval_ms must be >= 0")
	}
	if s.Buyers.InterPairIdleSeconds < 0 {
		return fmt.Errorf("buyers.inter_pair_idle_seconds must be >= 0")
	}
	if len(s.Prompts) == 0 {
		return fmt.Errorf("at least one prompt is required")
	}
	for i, p := range s.Prompts {
		if p.Model == "" {
			return fmt.Errorf("prompts[%d].model is required", i)
		}
		if p.User == "" {
			return fmt.Errorf("prompts[%d].user is required", i)
		}
		if p.MaxTokens < 0 {
			return fmt.Errorf("prompts[%d].max_tokens must be >= 0", i)
		}
	}
	switch s.Buyers.Pattern {
	case "constant", "interval", "ramp", "burst", "cold_warm_pairs":
	default:
		return fmt.Errorf("buyers.pattern must be one of constant|interval|ramp|burst|cold_warm_pairs (got %q)", s.Buyers.Pattern)
	}
	if s.Buyers.Pattern == "interval" && s.Buyers.IntervalMs <= 0 {
		return fmt.Errorf("buyers.interval_ms must be > 0 when pattern=interval")
	}
	if s.Buyers.Pattern == "ramp" && s.Buyers.RampDuration <= 0 {
		return fmt.Errorf("buyers.ramp_duration must be > 0 when pattern=ramp")
	}
	if s.Buyers.Pattern == "cold_warm_pairs" {
		if s.Buyers.InterPairIdleSeconds <= 0 {
			return fmt.Errorf("buyers.inter_pair_idle_seconds must be > 0 when pattern=cold_warm_pairs")
		}
		if s.Buyers.RequestsPerBuyer < 2 || s.Buyers.RequestsPerBuyer%2 != 0 {
			return fmt.Errorf("buyers.requests_per_buyer must be an even number ≥ 2 when pattern=cold_warm_pairs (got %d)", s.Buyers.RequestsPerBuyer)
		}
	}
	if s.Duration == 0 && s.Buyers.Pattern != "burst" {
		return fmt.Errorf("duration must be > 0 unless pattern=burst")
	}
	if s.Benchmark.Enabled {
		if len(s.Benchmark.Invariants) == 0 {
			return fmt.Errorf("benchmark.invariants must list at least one B-ID when benchmark.enabled=true")
		}
		// B8/B9 are reserved by RESEARCH_236 (sticky cache-reuse); B10 is
		// RESEARCH_235's sustained-TPS retention. B10 skips that range to
		// avoid colliding regardless of PR merge order.
		known := map[string]bool{"B1": true, "B2": true, "B3": true, "B4": true, "B5": true, "B6": true, "B7": true, "B10": true}
		for _, id := range s.Benchmark.Invariants {
			if !known[id] {
				return fmt.Errorf("benchmark.invariants: unknown id %q (known: B1-B7, B10)", id)
			}
		}
		if s.Benchmark.ProviderSlots < 1 {
			return fmt.Errorf("benchmark.provider_slots must be >= 1")
		}
	}
	// LAB-ONLY enforcement for B10 (sustained-load soak) — applied regardless
	// of Benchmark.Enabled, because the sustained buyer load still runs even
	// when benchmark scoring is off. A 45–60 min soak degrades and disconnects
	// the single prod mac — that IS #584. Both targets must be lab addresses
	// (loopback/private/localhost); a public host such as prod is rejected, and
	// hostname-normalization tricks cannot slip past a positive allowlist.
	if s.BenchmarkHasB10() {
		for _, pair := range []struct{ field, raw string }{
			{"target.gateway_url", s.Target.GatewayURL},
			{"target.coordinator_url", s.Target.CoordinatorURL},
		} {
			if err := validateLabOnlyHost(pair.field, pair.raw); err != nil {
				return err
			}
		}
	}
	return nil
}

// benchmarkHasB10 reports whether the scenario declares the B10 sustained-load
// soak invariant. Checked regardless of Benchmark.Enabled — the sustained buyer
// load hits gateway_url even when benchmark scoring is turned off.
func (s *Scenario) BenchmarkHasB10() bool {
	for _, id := range s.Benchmark.Invariants {
		if id == "B10" {
			return true
		}
	}
	return false
}

// LabHostAllowed reports whether host is an acceptable LAB target for a B10
// soak. This is a POSITIVE allowlist (loopback / private / link-local /
// "localhost") rather than a production denylist — a denylist of prod hostnames
// is inherently bypassable by trailing-root-dot FQDNs, IDNA/full-width Unicode
// separators, or case tricks, all of which Go's network stack still resolves to
// the same public host. Only addresses the operator physically controls on a
// private network can pass, so a soak can never reach prod (#584). host is a
// bare hostname (url.Hostname()); it is canonicalized (lowercased, trailing dot
// trimmed) before the check.
func LabHostAllowed(host string) bool {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if host == "" {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// Any non-IP hostname (prod, a cloud host, a public FQDN) is rejected:
		// a lab stack is reached by loopback/LAN IP or "localhost".
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

// validateLabOnlyHost fails validation unless raw is empty or targets a lab
// address (see LabHostAllowed). Empty raw is allowed here — the caller's
// separate empty-gateway check governs that.
func validateLabOnlyHost(field, raw string) error {
	if raw == "" {
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("%s is not a valid URL: %w", field, err)
	}
	if !LabHostAllowed(u.Hostname()) {
		return fmt.Errorf("%s host %q is not a lab address — B10 (thermal soak) is LAB-ONLY; only loopback/private/link-local IPs or \"localhost\" are allowed, because a sustained soak degrades and disconnects a real provider (#584). Use a lab stack (a public host such as prod is rejected)", field, u.Hostname())
	}
	return nil
}

func (s *Scenario) validateSKUEcon() error {
	if s.Target.CoordinatorURL == "" {
		return fmt.Errorf("target.coordinator_url is required")
	}
	u, err := url.Parse(s.Target.CoordinatorURL)
	if err != nil {
		return fmt.Errorf("target.coordinator_url is not a valid URL: %w", err)
	}
	if u.Scheme != "https" {
		return fmt.Errorf("target.coordinator_url must use https scheme (got %q)", u.Scheme)
	}
	if u.Host != SKUEconCoordinatorHost {
		return fmt.Errorf("target.coordinator_url host must be %s (got %q)", SKUEconCoordinatorHost, u.Host)
	}
	if u.User != nil {
		// SEC-H-1 (r2 security audit): userinfo in the URL causes Go's
		// http client to emit `Authorization: Basic <base64>` on every
		// request. That would send credentials to the public-read
		// /v1/rate-card endpoint, violating the "no auth on rate-card"
		// invariant.
		return fmt.Errorf("target.coordinator_url must not carry userinfo (would add Authorization header)")
	}
	if u.Path != "" && u.Path != "/" {
		// SEC-H-1 / CODE-M-1 (r2 audit): a scenario-supplied path would
		// be concatenated with `/v1/rate-card`, so `https://coordinator.streamvc.live/admin`
		// would fetch `/admin/v1/rate-card`. Path must be empty or root.
		return fmt.Errorf("target.coordinator_url must have empty or / path (got %q)", u.Path)
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("target.coordinator_url must not carry query or fragment")
	}
	if s.Target.CLIBin == "" {
		return fmt.Errorf("target.cli_bin is required")
	}
	if len(s.HardwareMatrix) == 0 {
		return fmt.Errorf("hardware_matrix must list at least one row")
	}
	for i, row := range s.HardwareMatrix {
		if row.Label == "" {
			return fmt.Errorf("hardware_matrix[%d].label is required", i)
		}
		if row.Chip == "" {
			return fmt.Errorf("hardware_matrix[%d].chip is required", i)
		}
		if row.MemoryGB <= 0 {
			return fmt.Errorf("hardware_matrix[%d].memoryGB must be > 0", i)
		}
		switch row.BandwidthTier {
		case "S", "A", "B", "C", "unknown":
		default:
			return fmt.Errorf("hardware_matrix[%d].bandwidthTier must be one of S|A|B|C|unknown", i)
		}
		switch row.Expected {
		case "at_least_one_eligible_row", "donor_only_by_ram":
		case "at_least_one_paid_row", "at_least_one_earning_row", "donor_only_by_design":
			return fmt.Errorf("hardware_matrix[%d].expected uses deprecated sku-econ vocabulary %q; use at_least_one_eligible_row or donor_only_by_ram (rate-card v4 pivot)", i, row.Expected)
		default:
			return fmt.Errorf("hardware_matrix[%d].expected must be at_least_one_eligible_row or donor_only_by_ram", i)
		}
	}
	if s.BenchmarkSynthesis.Mode != "warm_cache_synthetic" {
		return fmt.Errorf("benchmark_synthesis.mode must be warm_cache_synthetic")
	}
	if s.BenchmarkSynthesis.TPSMultiplierOfGate <= 0 {
		return fmt.Errorf("benchmark_synthesis.tps_multiplier_of_gate must be > 0")
	}
	if s.BenchmarkSynthesis.TTFTFractionOfCeiling <= 0 {
		return fmt.Errorf("benchmark_synthesis.ttft_fraction_of_ceiling must be > 0")
	}
	return nil
}

// PromptFor picks the prompt for a given (buyer_index, request_index).
// Round-robins across the prompt pool so a 5-buyer scenario over 3
// prompts spreads the load evenly.
func (s *Scenario) PromptFor(buyerIdx, reqIdx int) Prompt {
	n := len(s.Prompts)
	if n == 0 {
		return Prompt{}
	}
	return s.Prompts[(buyerIdx+reqIdx)%n]
}
