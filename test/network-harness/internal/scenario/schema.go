// Package scenario defines the YAML schema for an internal e2e network
// scenario. Phase A is descriptive: ExpectedShape is free-text recorded
// into the artifact bundle for human triage, not asserted on. The only
// hard pass/fail at the scenario level is the 4 invariants in package
// invariants.
package scenario

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// envVarPattern matches `${VAR}` references for safe expansion at load
// time. Lets scenarios reference secrets like ${BUYER_TOKEN} without
// committing them. Unset vars expand to "" — Validate() then rejects
// any required field that's empty.
var envVarPattern = regexp.MustCompile(`\$\{([A-Z_][A-Z0-9_]*)\}`)

func expandEnv(input []byte) []byte {
	return envVarPattern.ReplaceAllFunc(input, func(match []byte) []byte {
		name := envVarPattern.FindSubmatch(match)[1]
		return []byte(os.Getenv(string(name)))
	})
}

// Scenario is the top-level YAML root.
type Scenario struct {
	Name        string `yaml:"name"`
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

	// RequestTimeout is a per-request hard cap. Default 120s if unset.
	RequestTimeout time.Duration `yaml:"request_timeout"`

	// ChaosEvents is a timeline of shell commands fired alongside the
	// buyer fleet. Used to script provider WS kills, restarts, network
	// throttles for chaos scenarios. Each command runs via /bin/sh -c;
	// stdout/stderr/exit are captured into run_meta.json.
	ChaosEvents []ChaosEvent `yaml:"chaos_events"`
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

	// CoordinatorDBPath + GatewayDBPath are filesystem paths to the
	// SQLite files holding request_log + usage_events. Required for
	// I1 (billing reconciliation). When unset, reconciliation is
	// skipped and I1 is marked skipped (not failed).
	CoordinatorDBPath string `yaml:"coordinator_db_path"`
	GatewayDBPath     string `yaml:"gateway_db_path"`

	// CoordinatorDBSSH + GatewayDBSSH enable I1 against a live remote
	// stack (Pearl). Form: "user@host:/absolute/path/to.db". When set,
	// the harness pulls a WAL-consistent snapshot via:
	//   ssh user@host "sqlite3 /path 'VACUUM INTO /tmp/snap.db'"
	//   scp user@host:/tmp/snap.db <local-tmp>
	//   ssh user@host "rm /tmp/snap.db"
	// then opens the local copy read-only. Set both or neither.
	CoordinatorDBSSH string `yaml:"coordinator_db_ssh"`
	GatewayDBSSH     string `yaml:"gateway_db_ssh"`

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

// Buyers describes the concurrent buyer fleet.
type Buyers struct {
	Count  int  `yaml:"count"`
	Stream bool `yaml:"stream"`

	// Pattern selects how requests are paced across the fleet.
	//   "constant"     — every buyer fires back-to-back, no inter-request delay
	//   "interval"     — every buyer waits IntervalMs between requests
	//   "ramp"         — buyers come online linearly across RampDuration
	//   "burst"        — all buyers fire one request at t=0, no follow-ups
	Pattern        string        `yaml:"pattern"`
	IntervalMs     int           `yaml:"interval_ms"`
	RampDuration   time.Duration `yaml:"ramp_duration"`
	RequestsPerBuyer int         `yaml:"requests_per_buyer"`
}

// Prompt is one item in the rotating prompt pool. Buyers pick by index
// modulo len(prompts) so the harness output is deterministic given the
// same scenario + buyer count.
type Prompt struct {
	Model    string `yaml:"model"`
	System   string `yaml:"system"`
	User     string `yaml:"user"`
	MaxTokens int   `yaml:"max_tokens"`
}

// Load reads and unmarshals a scenario YAML file.
func Load(path string) (*Scenario, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	b = expandEnv(b)
	var sc Scenario
	if err := yaml.Unmarshal(b, &sc); err != nil {
		return nil, fmt.Errorf("yaml: %w", err)
	}
	sc.applyDefaults()
	return &sc, nil
}

func (s *Scenario) applyDefaults() {
	if s.RequestTimeout == 0 {
		s.RequestTimeout = 120 * time.Second
	}
	if s.SilentHangThreshold == 0 {
		s.SilentHangThreshold = 30 * time.Second
	}
	if s.Buyers.Pattern == "" {
		s.Buyers.Pattern = "constant"
	}
	if s.Buyers.RequestsPerBuyer == 0 {
		s.Buyers.RequestsPerBuyer = 1
	}
}

// Validate returns a non-nil error if the scenario is missing required
// fields or has contradictory settings. Catches authoring mistakes
// before any request is fired.
func (s *Scenario) Validate() error {
	if strings.TrimSpace(s.Name) == "" {
		return fmt.Errorf("name is required")
	}
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
	if s.Target.CoordinatorDBSSH != "" && s.Target.CoordinatorDBPath != "" {
		return fmt.Errorf("target.coordinator_db_ssh and target.coordinator_db_path are mutually exclusive")
	}
	if s.Target.GatewayDBSSH != "" && s.Target.GatewayDBPath != "" {
		return fmt.Errorf("target.gateway_db_ssh and target.gateway_db_path are mutually exclusive")
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
	}
	switch s.Buyers.Pattern {
	case "constant", "interval", "ramp", "burst":
	default:
		return fmt.Errorf("buyers.pattern must be one of constant|interval|ramp|burst (got %q)", s.Buyers.Pattern)
	}
	if s.Buyers.Pattern == "interval" && s.Buyers.IntervalMs <= 0 {
		return fmt.Errorf("buyers.interval_ms must be > 0 when pattern=interval")
	}
	if s.Buyers.Pattern == "ramp" && s.Buyers.RampDuration <= 0 {
		return fmt.Errorf("buyers.ramp_duration must be > 0 when pattern=ramp")
	}
	if s.Duration <= 0 && s.Buyers.Pattern != "burst" {
		return fmt.Errorf("duration must be > 0 unless pattern=burst")
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
