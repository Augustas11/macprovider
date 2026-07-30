package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeYAML(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return p
}

// TestLoadPayoutTuningOnlyAppliesOverlay locks the merge-audit
// 2026-07-30 convergent code+security HIGH closure: the payout SIGHUP
// loader must read the same effective base+overlay source as startup's
// LoadWithOverlay. The high-stakes case is overlay-sourced SPKI pins —
// empty pins validate, so a base-only reload would silently drop RPC
// certificate pinning on the payout money path.
func TestLoadPayoutTuningOnlyAppliesOverlay(t *testing.T) {
	pin1 := strings.Repeat("a", 64)
	pin2 := strings.Repeat("b", 64)
	base := writeYAML(t, "base.yaml", `
payout:
  tuning:
    run_interval: 6h
`)
	overlay := writeYAML(t, "overlay.yaml", `
payout:
  tuning:
    run_interval: 12h
    rpc_url_primary_pin_spki: `+pin1+`
    rpc_url_secondary_pin_spki: `+pin2+`
`)

	// Base-only read: overlay keys absent.
	tBase, err := LoadPayoutTuningOnly(base, "")
	if err != nil {
		t.Fatalf("LoadPayoutTuningOnly(base): %v", err)
	}
	if tBase.RunInterval != 6*time.Hour {
		t.Fatalf("base RunInterval=%v want 6h", tBase.RunInterval)
	}
	if tBase.RPCURLPrimaryPinSPKI != "" || tBase.RPCURLSecondaryPinSPKI != "" {
		t.Fatalf("base pins unexpectedly set: %q %q", tBase.RPCURLPrimaryPinSPKI, tBase.RPCURLSecondaryPinSPKI)
	}

	// Base+overlay read: overlay keys override, pins preserved.
	tEff, err := LoadPayoutTuningOnly(base, overlay)
	if err != nil {
		t.Fatalf("LoadPayoutTuningOnly(base, overlay): %v", err)
	}
	if tEff.RunInterval != 12*time.Hour {
		t.Fatalf("effective RunInterval=%v want 12h (overlay must override base)", tEff.RunInterval)
	}
	if tEff.RPCURLPrimaryPinSPKI != pin1 || tEff.RPCURLSecondaryPinSPKI != pin2 {
		t.Fatalf("overlay SPKI pins not preserved on reload path: %q %q", tEff.RPCURLPrimaryPinSPKI, tEff.RPCURLSecondaryPinSPKI)
	}
}

// TestLoadPayoutTuningOnlyMissingOverlayFails ensures a configured but
// unreadable overlay is a hard error (live value retained by caller),
// not a silent fall-back to base-only values.
func TestLoadPayoutTuningOnlyMissingOverlayFails(t *testing.T) {
	base := writeYAML(t, "base.yaml", `
payout:
  tuning:
    run_interval: 6h
`)
	if _, err := LoadPayoutTuningOnly(base, filepath.Join(t.TempDir(), "absent.yaml")); err == nil {
		t.Fatal("expected error for missing overlay file")
	}
}

// TestLoadForSIGHUPReloadExcludesPayout locks the merge-audit
// 2026-07-30 architect HIGH closure: the GENERAL SIGHUP reload path
// must not env-resolve or validate payout.security.*, and an invalid
// payout block on disk must not reject a tier2/billing reload
// (SPEC-016 v0.1.23 §6.5 tuning-only SIGHUP boundary).
func TestLoadForSIGHUPReloadExcludesPayout(t *testing.T) {
	t.Setenv("PAYOUT_RELOAD_TEST_OP_KEY", "0123456789abcdefABCDEFghijklmnop")
	os.Unsetenv("PAYOUT_RELOAD_TEST_UNSET_RPC")

	// payout.enabled=true with an env: sentinel whose variable is unset
	// AND a missing hot wallet — full Load must reject this; the
	// general-reload loader must not even look.
	// The payout block is hostile in BOTH ways the audits flagged:
	// a semantically-invalid env: sentinel (unset var, missing wallet)
	// AND a type-malformed scalar that would fail the typed Config
	// decode itself (merge-audit r2 convergent HIGH: the strip must
	// happen before typed unmarshal, not after).
	cfgPath := writeYAML(t, "coordinator.yaml", `
auth:
  operator_key: env:PAYOUT_RELOAD_TEST_OP_KEY
  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
payout:
  enabled: true
  security:
    rpc_url_primary: env:PAYOUT_RELOAD_TEST_UNSET_RPC
    cancel_max_tip_multiplier: not-a-float
payout:
  enabled: true
  security:
    cancel_max_tip_multiplier: also-not-a-float
`)

	if _, err := Load(cfgPath); err == nil {
		t.Fatal("full Load unexpectedly accepted invalid payout.security block (test premise broken)")
	}

	cfg, err := LoadForSIGHUPReload(cfgPath)
	if err != nil {
		t.Fatalf("LoadForSIGHUPReload must not couple to payout.* validity: %v", err)
	}
	if cfg.Payout.Enabled {
		t.Fatal("LoadForSIGHUPReload must reset payout namespace to defaults (enabled=false)")
	}
	if cfg.Payout.Security.RPCURLPrimary != "" {
		t.Fatalf("payout.security leaked through general reload loader: %q", cfg.Payout.Security.RPCURLPrimary)
	}
	if cfg.Auth.OperatorKey != "0123456789abcdefABCDEFghijklmnop" {
		t.Fatalf("non-payout namespaces must still resolve env: sentinels; got %q", cfg.Auth.OperatorKey)
	}
}

// TestLoadForSIGHUPReloadKeepsNonPayoutStrictness locks the merge-audit
// r3 code HIGH closure: stripping payout must not relax validation of
// any OTHER namespace. A map[string]interface{} round-trip would
// resolve an unquoted date-like scalar into time.Time and re-emit it
// RFC3339-normalized, letting the reload accept a deadline string that
// startup Load rejects. The node-level strip must keep such scalars
// byte-identical, so Load and LoadForSIGHUPReload agree.
func TestLoadForSIGHUPReloadKeepsNonPayoutStrictness(t *testing.T) {
	t.Setenv("PAYOUT_RELOAD_TEST_OP_KEY", "0123456789abcdefABCDEFghijklmnop")

	cfgPath := writeYAML(t, "coordinator.yaml", `
auth:
  operator_key: env:PAYOUT_RELOAD_TEST_OP_KEY
  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
tier2:
  model_hash_legacy_until: 2026-07-19
`)

	_, loadErr := Load(cfgPath)
	_, reloadErr := LoadForSIGHUPReload(cfgPath)
	if (loadErr == nil) != (reloadErr == nil) {
		t.Fatalf("Load and LoadForSIGHUPReload disagree on non-payout strictness: load=%v reload=%v", loadErr, reloadErr)
	}
	if loadErr == nil {
		t.Fatal("test premise broken: startup Load accepted bare-date model_hash_legacy_until")
	}
}
