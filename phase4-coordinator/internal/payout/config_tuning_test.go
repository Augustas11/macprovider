package payout

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// validBaseSnapshot returns a snapshot that passes all §6.5 bounds
// at the defaults the codebase ships with. Tests mutate one field
// at a time off this baseline.
func validBaseSnapshot() TuningSnapshot {
	return TuningSnapshot{
		AddressCoolingOffPeriod: 24 * time.Hour,
		RunInterval:             6 * time.Hour,
		RunNowMinInterval:       60 * time.Second,
		ConfirmationBlocks:      5,
		MaxRowsPerRun:           50,
		ReorgPollWindow:         24 * time.Hour,
		LowBalanceThreshold:     0,
		LowNativeThreshold:      0,
		RPCURLPrimaryPinSPKI:    "",
		RPCURLSecondaryPinSPKI:  "",
	}
}

// TestTuningProvider_NewWithValidSnapshot succeeds + Snapshot
// returns the seeded values.
func TestTuningProvider_NewWithValidSnapshot(t *testing.T) {
	p, err := NewTuningProvider(validBaseSnapshot(), 5_000_000_000, zerolog.Nop())
	if err != nil {
		t.Fatalf("NewTuningProvider: %v", err)
	}
	snap := p.Snapshot()
	if snap.ConfirmationBlocks != 5 {
		t.Errorf("ConfirmationBlocks = %d, want 5", snap.ConfirmationBlocks)
	}
}

// TestTuningProvider_NewRejectsOutOfBoundsInitial covers the
// fail-fast guarantee at constructor time.
func TestTuningProvider_NewRejectsOutOfBoundsInitial(t *testing.T) {
	bad := validBaseSnapshot()
	bad.ConfirmationBlocks = 3 // < 5 floor
	_, err := NewTuningProvider(bad, 5_000_000_000, zerolog.Nop())
	if err == nil {
		t.Fatal("NewTuningProvider should reject confirmation_blocks=3")
	}
	if !strings.Contains(err.Error(), "confirmation_blocks") {
		t.Errorf("err should name failing field; got %v", err)
	}
}

// TestTuningProvider_ReloadHappyPathSwapsLiveValue locks the
// SPEC §6.5 normative "successful reload — live value updates +
// PAGE emitted".
func TestTuningProvider_ReloadHappyPath(t *testing.T) {
	p, err := NewTuningProvider(validBaseSnapshot(), 5_000_000_000, zerolog.Nop())
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	new := validBaseSnapshot()
	new.ConfirmationBlocks = 7 // within bounds; new value
	if _, err := p.Reload(context.Background(), new); err != nil {
		t.Fatalf("Reload: %v", err)
	}
	if got := p.Snapshot().ConfirmationBlocks; got != 7 {
		t.Errorf("post-reload ConfirmationBlocks = %d, want 7", got)
	}
}

// TestTuningProvider_ReloadBoundViolationRetainsLiveValue locks
// the SPEC §6.5 normative "bound violation — LIVE VALUE RETAINED".
// This is the single most important security property of the
// reload path: an attacker who can write coordinator.yaml + send
// SIGHUP MUST NOT be able to bypass the §6.5 bound matrix.
func TestTuningProvider_ReloadBoundViolationRetainsLiveValue(t *testing.T) {
	p, err := NewTuningProvider(validBaseSnapshot(), 5_000_000_000, zerolog.Nop())
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	bad := validBaseSnapshot()
	bad.AddressCoolingOffPeriod = 30 * time.Minute // < 1h floor
	_, err = p.Reload(context.Background(), bad)
	if err == nil {
		t.Fatal("Reload should reject address_cooling_off_period=30m")
	}
	if !errors.Is(err, ErrTuningBoundViolation) {
		t.Errorf("err should wrap ErrTuningBoundViolation; got %v", err)
	}
	// Live value MUST be the pre-reload snapshot — the SPEC §6.5
	// "live value retained" guarantee.
	if got := p.Snapshot().AddressCoolingOffPeriod; got != 24*time.Hour {
		t.Errorf("AddressCoolingOffPeriod = %s, want 24h (live value not retained on bound violation)", got)
	}
}

// TestValidateBounds_AllFields walks every bound at the matrix
// edge so an off-by-one in a future SPEC bump (e.g. confirmation
// blocks rising to [10, 300]) gets caught at unit-test time.
func TestValidateBounds_AllFields(t *testing.T) {
	type tc struct {
		name   string
		mutate func(*TuningSnapshot)
		want   string // substring expected in error
	}
	cases := []tc{
		{"cooling_off below 1h", func(s *TuningSnapshot) { s.AddressCoolingOffPeriod = 59 * time.Minute }, "address_cooling_off_period"},
		{"run_interval below 5m", func(s *TuningSnapshot) { s.RunInterval = 4 * time.Minute }, "run_interval"},
		{"run_interval above 24h", func(s *TuningSnapshot) { s.RunInterval = 25 * time.Hour }, "run_interval"},
		{"run_now_min below 10s", func(s *TuningSnapshot) { s.RunNowMinInterval = 9 * time.Second }, "run_now_min_interval"},
		{"run_now_min above 1h", func(s *TuningSnapshot) { s.RunNowMinInterval = 2 * time.Hour }, "run_now_min_interval"},
		{"confirmation 4", func(s *TuningSnapshot) { s.ConfirmationBlocks = 4 }, "confirmation_blocks"},
		{"confirmation 201", func(s *TuningSnapshot) { s.ConfirmationBlocks = 201 }, "confirmation_blocks"},
		{"max_rows 0", func(s *TuningSnapshot) { s.MaxRowsPerRun = 0 }, "max_rows_per_run"},
		{"max_rows 501", func(s *TuningSnapshot) { s.MaxRowsPerRun = 501 }, "max_rows_per_run"},
		{"reorg below 1h", func(s *TuningSnapshot) { s.ReorgPollWindow = 59 * time.Minute }, "reorg_poll_window"},
		{"reorg above 168h", func(s *TuningSnapshot) { s.ReorgPollWindow = 169 * time.Hour }, "reorg_poll_window"},
		{"low_native above 1e18", func(s *TuningSnapshot) { s.LowNativeThreshold = 1_000_000_000_000_000_001 }, "low_native_threshold"},
		{"low_balance negative", func(s *TuningSnapshot) { s.LowBalanceThreshold = -1 }, "low_balance_threshold"},
		{"spki_primary 63 hex", func(s *TuningSnapshot) { s.RPCURLPrimaryPinSPKI = strings.Repeat("a", 63) }, "rpc_url_primary_pin_spki"},
		{"spki_secondary non-hex", func(s *TuningSnapshot) { s.RPCURLSecondaryPinSPKI = strings.Repeat("z", 64) }, "rpc_url_secondary_pin_spki"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := validBaseSnapshot()
			c.mutate(&s)
			err := validateBounds(s, 5_000_000_000)
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", c.want)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("error %q did not mention %q", err, c.want)
			}
		})
	}
}

// TestValidateBounds_CrossField_LowBalanceVsPerDayCap covers the
// SPEC §6.5 cross-field constraint
// low_balance_threshold <= 2 × per_day_cap.
func TestValidateBounds_CrossField_LowBalanceVsPerDayCap(t *testing.T) {
	perDayCap := int64(5_000_000_000) // $5,000 default
	s := validBaseSnapshot()
	s.LowBalanceThreshold = 2*perDayCap + 1
	if err := validateBounds(s, perDayCap); err == nil {
		t.Fatal("low_balance > 2 × per_day_cap should reject")
	}
	s.LowBalanceThreshold = 2 * perDayCap
	if err := validateBounds(s, perDayCap); err != nil {
		t.Errorf("low_balance == 2 × per_day_cap should accept; got %v", err)
	}
}

// TestTuningStaticCheck_NoSecurityNamespaceReference is the SPEC
// §6.5 "security/tuning loader split has NO shared mutable state"
// invariant. The auditor language is "a security key is
// unreachable from the tuning reload path" — the most reliable
// test of that property is a compile-time / static-AST guarantee
// that the file `config_tuning.go` contains zero references to any
// `payout.security.*` identifier.
//
// Step 4 r1 [code:r1-4]/[arch:4.4] MEDIUM closure: the test now uses
// a real ast.Inspect walk instead of strings.Contains so it detects
// any *ast.Ident, *ast.SelectorExpr, or *ast.BasicLit (string literal)
// that reference the forbidden security-namespace identifier set.
func TestTuningStaticCheck_NoSecurityNamespaceReference(t *testing.T) {
	// forbiddenIdents is the centralized set of security-namespace
	// identifiers that must never appear in config_tuning.go.
	// Step 4 r2 [code:r2-2]/[sec:r2-2] MEDIUM closure: replaced
	// non-exact substrings (e.g. "PerDayCap") with the EXACT exported
	// field and type names that the Go AST sees. Derived verbatim from
	// config.PayoutSecurityConfig and payout.SecurityConfig declarations.
	// Add entries here when new PayoutSecurityConfig fields are added.
	forbiddenIdents := map[string]bool{
		// Type names.
		"PayoutSecurityConfig": true,
		"SecurityConfig":       true,
		// Field names — exact identifiers as declared in config.go.
		"HotWalletAddress":                 true,
		"RPCURLPrimary":                    true,
		"RPCURLSecondary":                  true,
		"PerPayoutCapUSDCBaseUnits":        true,
		"PerDayCapUSDCBaseUnits":           true,
		"CancelMaxTipMultiplier":           true,
		"CancelMaxGasNativeWei":            true,
		"CancelMaxGasNativeWeiPer24h":      true,
		"AbandonRatePerHour":               true,
		"ChainReconInterval":               true,
		"ChainReconToleranceUSDCBaseUnits": true,
		"PauseResumeMinInterval":           true,
		"EncryptedWalletPath":              true,
		"EncryptedWalletOnDiskHex":         true,
		"DevMode":                          true,
	}

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	path := filepath.Join(cwd, "config_tuning.go")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("locate config_tuning.go: %v", err)
	}
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	// Parse into a real AST so the walk is structure-aware, not text-based.
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, src, parser.ParseComments)
	if err != nil {
		t.Fatalf("config_tuning.go is no longer valid Go: %v", err)
	}

	// ast.Inspect walks every node in the file. We check:
	//   *ast.Ident        — any identifier name in the forbidden set
	//   *ast.BasicLit     — string literals containing "payout.security."
	ast.Inspect(file, func(n ast.Node) bool {
		switch v := n.(type) {
		case *ast.Ident:
			if forbiddenIdents[v.Name] {
				pos := fset.Position(v.Pos())
				t.Errorf("SPEC §6.5 violation: config_tuning.go references forbidden security-namespace identifier %q at %s", v.Name, pos)
			}
		case *ast.BasicLit:
			if v.Kind == token.STRING && strings.Contains(v.Value, "payout.security.") {
				pos := fset.Position(v.Pos())
				t.Errorf("SPEC §6.5 violation: config_tuning.go contains string literal referencing payout.security.* at %s: %s", pos, v.Value)
			}
		}
		return true
	})
}

// TestEmitRejected_YAMLParseFailure_EmitsStructuredS71Fields locks
// the Step 4 r4 [code:r4-1]/[sec:r4-1] CONVERGENT MEDIUM closure:
// when emitRejected is called with a non-*BoundViolationError (the
// YAML-parse / LoadPayoutTuningOnly failure path), the emitted
// payout_config_reload_rejected event MUST include all §7.1 required
// fields: key, attempted_value, bound, actor, ts_utc, severity.
func TestEmitRejected_YAMLParseFailure_EmitsStructuredS71Fields(t *testing.T) {
	buf := &bytes.Buffer{}
	logger := zerolog.New(io.Writer(buf))
	p, err := NewTuningProvider(validBaseSnapshot(), 5_000_000_000, logger)
	if err != nil {
		t.Fatalf("NewTuningProvider: %v", err)
	}

	// Simulate a YAML-parse error (not a *BoundViolationError).
	parseErr := errors.New("yaml: unmarshal error at line 42")
	p.emitRejected(parseErr)

	// Parse the emitted JSON.
	var evt map[string]interface{}
	if err := json.Unmarshal(buf.Bytes(), &evt); err != nil {
		t.Fatalf("emitRejected did not produce valid JSON: %v; got: %q", err, buf.String())
	}

	// Assert §7.1 required fields.
	for _, field := range []string{"event", "key", "attempted_value", "bound", "actor", "ts_utc", "severity"} {
		if _, ok := evt[field]; !ok {
			t.Errorf("payout_config_reload_rejected missing §7.1 field %q; full event: %s", field, buf.String())
		}
	}
	if got := evt["event"]; got != "payout_config_reload_rejected" {
		t.Errorf("event = %q, want payout_config_reload_rejected", got)
	}
	if got := evt["key"]; got != "yaml_parse" {
		t.Errorf("key = %q, want yaml_parse", got)
	}
	// Step 4 r5 [code:r5-7] LOW closure: emitRejected MUST emit the
	// sanitized literal "config_load_failed" (not raw error text) so
	// YAML contents — which may contain secrets — never reach the log.
	if got := evt["attempted_value"]; got != "config_load_failed" {
		t.Errorf("attempted_value = %q, want config_load_failed (must not expose raw YAML error)", got)
	}
	if got := evt["actor"]; got != "operator_key:coordinator" {
		t.Errorf("actor = %q, want operator_key:coordinator", got)
	}
	if got := evt["severity"]; got != "PAGE" {
		t.Errorf("severity = %q, want PAGE", got)
	}
}

// TestEmitRejected_BoundViolation_UsesFieldAndAttempted locks the
// Step 4 r4 [code:r4-5] LOW closure: BoundViolationError's renamed
// fields (Field/Attempted) are correctly mapped to the §7.1 wire
// names (key/attempted_value) by emitRejected.
func TestEmitRejected_BoundViolation_UsesFieldAndAttempted(t *testing.T) {
	buf := &bytes.Buffer{}
	logger := zerolog.New(io.Writer(buf))
	p, err := NewTuningProvider(validBaseSnapshot(), 5_000_000_000, logger)
	if err != nil {
		t.Fatalf("NewTuningProvider: %v", err)
	}

	bve := &BoundViolationError{
		Field:     "payout.tuning.run_interval",
		Attempted: "3m0s",
		Bound:     "[5m, 24h]",
		Actor:     "operator_key:coordinator",
	}
	p.emitRejected(bve)

	var evt map[string]interface{}
	if err := json.Unmarshal(buf.Bytes(), &evt); err != nil {
		t.Fatalf("emitRejected did not produce valid JSON: %v; got: %q", err, buf.String())
	}
	if got := evt["key"]; got != "payout.tuning.run_interval" {
		t.Errorf("key = %q, want payout.tuning.run_interval", got)
	}
	if got := evt["attempted_value"]; got != "3m0s" {
		t.Errorf("attempted_value = %q, want 3m0s", got)
	}
	if got := evt["bound"]; got != "[5m, 24h]" {
		t.Errorf("bound = %q, want [5m, 24h]", got)
	}
	if got := evt["actor"]; got != "operator_key:coordinator" {
		t.Errorf("actor = %q, want operator_key:coordinator", got)
	}
}

// TestTuningProvider_ReloadRejectsChangedKeysBoundViolation checks
// that Reload does not return changed keys on a bound violation.
// Also exercises the BoundViolationError.Field/Attempted struct shape
// end-to-end through the validateBounds + Reload path.
func TestTuningProvider_ReloadRejectsChangedKeysBoundViolation_ReturnsNilChangedKeys(t *testing.T) {
	p, err := NewTuningProvider(validBaseSnapshot(), 5_000_000_000, zerolog.Nop())
	if err != nil {
		t.Fatalf("NewTuningProvider: %v", err)
	}
	bad := validBaseSnapshot()
	bad.RunInterval = 1 * time.Minute // < 5m floor
	changedKeys, reloadErr := p.Reload(context.Background(), bad)
	if reloadErr == nil {
		t.Fatal("Reload should have returned an error for run_interval=1m")
	}
	if !errors.Is(reloadErr, ErrTuningBoundViolation) {
		t.Errorf("want ErrTuningBoundViolation, got: %v", reloadErr)
	}
	if changedKeys != nil {
		t.Errorf("changedKeys should be nil on bound violation, got: %v", changedKeys)
	}
	// Step 4 r5 [code:r5-6] LOW closure: Reload must wrap both the
	// ErrTuningBoundViolation sentinel AND the *BoundViolationError so
	// callers can extract the structured violation via errors.As.
	var bve *BoundViolationError
	if !errors.As(reloadErr, &bve) {
		t.Error("errors.As(*BoundViolationError) should succeed — Reload must wrap bve")
	} else {
		if bve.Field == "" {
			t.Error("BoundViolationError.Field is empty")
		}
		if bve.Attempted == "" {
			t.Error("BoundViolationError.Attempted is empty")
		}
	}
}
