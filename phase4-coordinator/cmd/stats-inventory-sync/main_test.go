package main

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"strings"
	"testing"
)

type execCall struct {
	query string
	args  []any
}

type fakeExec struct {
	calls []execCall
}

func (f *fakeExec) ExecContext(_ context.Context, query string, args ...any) (sql.Result, error) {
	f.calls = append(f.calls, execCall{query: query, args: append([]any(nil), args...)})
	return fakeResult{}, nil
}

type fakeResult struct{}

func (fakeResult) LastInsertId() (int64, error) { return 0, nil }
func (fakeResult) RowsAffected() (int64, error) { return 1, nil }

const fixtureHardwareIdentityHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func validInventory() inventory {
	return inventory{
		Chips: map[string]chipProfile{
			"operator fixture chip": {
				DisplayChip:           "Operator Fixture",
				MemoryBandwidthGBPerS: 120,
				NetworkPowerKW:        0.035,
				GPUCores:              10,
				CPUCores:              10,
			},
		},
		Providers: map[string]providerProfile{
			"mac": {
				ChipNormalized:  "operator fixture chip",
				Chip:            "Operator Fixture",
				UnifiedMemoryGB: 32,
				Source:          "operator",
				Verified:        true,
			},
		},
		TrustedHardware: map[string][]trustedHardwareIdentity{
			"mac": {
				{
					HardwareIdentityHash: fixtureHardwareIdentityHash,
					ChipNormalized:       "operator fixture chip",
					UnifiedMemoryGB:      32,
					TrustedBy:            "operator",
				},
			},
		},
	}
}

func TestValidateInventoryAcceptsOperatorVerifiedProfiles(t *testing.T) {
	if err := validateInventory(validInventory()); err != nil {
		t.Fatalf("validateInventory() error = %v", err)
	}
}

func TestValidateInventoryRejectsUnknownProviderChip(t *testing.T) {
	inv := validInventory()
	p := inv.Providers["mac"]
	p.ChipNormalized = "missing"
	inv.Providers["mac"] = p

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "unknown chip_normalized") {
		t.Fatalf("validateInventory() error = %v, want unknown chip", err)
	}
}

func TestValidateInventoryAcceptsTrustedHardwareWithoutProviderProfiles(t *testing.T) {
	inv := validInventory()
	inv.Providers = nil

	if err := validateInventory(inv); err != nil {
		t.Fatalf("validateInventory() error = %v", err)
	}
}

func TestValidateInventoryRejectsEmptyProviderMap(t *testing.T) {
	inv := validInventory()
	inv.Providers = map[string]providerProfile{}

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "omit the section") {
		t.Fatalf("validateInventory() error = %v, want empty provider map error", err)
	}
}

func TestValidateInventoryRejectsEmptyTrustedHardwareMap(t *testing.T) {
	inv := validInventory()
	inv.TrustedHardware = map[string][]trustedHardwareIdentity{}

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "omit the section") {
		t.Fatalf("validateInventory() error = %v, want empty trust map error", err)
	}
}

func TestValidateInventoryRejectsUnknownTrustedHardwareChip(t *testing.T) {
	inv := validInventory()
	inv.TrustedHardware["mac"][0].ChipNormalized = "missing"

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "unknown chip_normalized") {
		t.Fatalf("validateInventory() error = %v, want unknown trusted chip", err)
	}
}

func TestValidateInventoryRejectsUnsafeTrustedHardwareHash(t *testing.T) {
	for name, hash := range map[string]string{
		"raw":       "raw-serial-123",
		"uppercase": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF",
		"space":     "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde ",
	} {
		t.Run(name, func(t *testing.T) {
			inv := validInventory()
			inv.TrustedHardware["mac"][0].HardwareIdentityHash = hash

			err := validateInventory(inv)
			if err == nil || !strings.Contains(err.Error(), "hardware_identity_hash") {
				t.Fatalf("validateInventory() error = %v, want hardware identity hash error", err)
			}
		})
	}
}

func TestValidateInventoryRejectsInvalidTrustedHardwareExpiry(t *testing.T) {
	inv := validInventory()
	inv.TrustedHardware["mac"][0].ExpiresAt = "tomorrow"

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "expires_at") {
		t.Fatalf("validateInventory() error = %v, want expires_at error", err)
	}
}

func TestValidateInventoryRejectsUnsafeChipKey(t *testing.T) {
	inv := validInventory()
	inv.Chips["Bad Key"] = inv.Chips["operator fixture chip"]
	delete(inv.Chips, "operator fixture chip")
	p := inv.Providers["mac"]
	p.ChipNormalized = "Bad Key"
	inv.Providers["mac"] = p

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "lowercase and space-normalized") {
		t.Fatalf("validateInventory() error = %v, want unsafe chip key", err)
	}
}

func TestValidateInventoryAcceptsOnboardingNormalizedChipKey(t *testing.T) {
	inv := validInventory()
	chip := inv.Chips["operator fixture chip"]
	delete(inv.Chips, "operator fixture chip")
	chip.DisplayChip = "Apple M4 Max"
	inv.Chips["apple m4 max"] = chip
	p := inv.Providers["mac"]
	p.Chip = "Apple M4 Max"
	p.ChipNormalized = "apple m4 max"
	inv.Providers["mac"] = p
	inv.TrustedHardware["mac"][0].ChipNormalized = "apple m4 max"

	if err := validateInventory(inv); err != nil {
		t.Fatalf("validateInventory() error = %v", err)
	}
}

func TestApplyInventorySkipsProviderReconciliationWhenProvidersOmitted(t *testing.T) {
	inv := validInventory()
	inv.Providers = nil
	db := &fakeExec{}
	if err := applyInventory(context.Background(), db, inv); err != nil {
		t.Fatalf("applyInventory() error = %v", err)
	}
	for _, call := range db.calls {
		if strings.Contains(call.query, "provider_hardware_profiles") {
			t.Fatalf("query = %q, provider reconciliation must be skipped when providers section is omitted", call.query)
		}
	}
}

func TestApplyTrustInventoryReconcilesTrustedHardware(t *testing.T) {
	inv := validInventory()
	db := &fakeExec{}
	if err := applyTrustInventory(context.Background(), db, inv); err != nil {
		t.Fatalf("applyTrustInventory() error = %v", err)
	}
	if len(db.calls) != 2 {
		t.Fatalf("applyTrustInventory() calls = %d, want 2", len(db.calls))
	}
	if !strings.Contains(db.calls[0].query, "INSERT INTO hardware_verification_trust") {
		t.Fatalf("first query = %q, want trusted hardware upsert", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "ELSE hardware_verification_trust.trusted_at") {
		t.Fatalf("first query = %q, want unchanged trusted_at preservation", db.calls[0].query)
	}
	if got := db.calls[0].args[1]; got != fixtureHardwareIdentityHash {
		t.Fatalf("hardware identity hash arg = %v, want fixture hash", got)
	}
	if !strings.Contains(db.calls[1].query, "DELETE FROM hardware_verification_trust") {
		t.Fatalf("second query = %q, want trust deletion reconciliation", db.calls[1].query)
	}
	if !strings.Contains(db.calls[1].query, "hardware_identity_hash") {
		t.Fatalf("second query = %q, want authoritative trust identity list", db.calls[1].query)
	}
}

func TestApplyTrustDemotionsOnlyDemotesCLIProfilesWithoutActiveTrust(t *testing.T) {
	db := &fakeExec{}
	if err := applyTrustDemotions(context.Background(), db); err != nil {
		t.Fatalf("applyTrustDemotions() error = %v", err)
	}
	if len(db.calls) != 1 {
		t.Fatalf("applyTrustDemotions() calls = %d, want 1", len(db.calls))
	}
	if !strings.Contains(db.calls[0].query, "UPDATE provider_hardware_profiles") {
		t.Fatalf("query = %q, want provider profile demotion", db.calls[0].query)
	}
	if strings.Contains(db.calls[0].query, "last_reported_at = now()") {
		t.Fatalf("query = %q, demotion must preserve evidence timestamp", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "source = 'cli_hello'") {
		t.Fatalf("query = %q, want cli_hello-only demotion", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "hardware_verification_jobs") {
		t.Fatalf("query = %q, want verified job evidence check", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "hardware_verification_trust") {
		t.Fatalf("query = %q, want active trust-root check", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "j.evidence #>> '{hardware,hardware_identity_hash}'") {
		t.Fatalf("query = %q, want exact hardware identity hash proof", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "t.expires_at IS NULL OR t.expires_at > now()") {
		t.Fatalf("query = %q, want expired trust roots excluded", db.calls[0].query)
	}
	if strings.Contains(db.calls[0].query, "source = 'operator'") {
		t.Fatalf("query = %q, must not demote manual operator inventory rows", db.calls[0].query)
	}
}

func TestValidateInventoryRejectsNegativeCapacity(t *testing.T) {
	inv := validInventory()
	chip := inv.Chips["operator fixture chip"]
	chip.MemoryBandwidthGBPerS = -1
	inv.Chips["operator fixture chip"] = chip

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "memory_bandwidth_gb_per_s") {
		t.Fatalf("validateInventory() error = %v, want negative capacity", err)
	}
}

func TestValidateInventoryRejectsProviderMemoryOutOfRange(t *testing.T) {
	inv := validInventory()
	p := inv.Providers["mac"]
	p.UnifiedMemoryGB = 4097
	inv.Providers["mac"] = p

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "unified_memory_gb") {
		t.Fatalf("validateInventory() error = %v, want memory range error", err)
	}
}

func TestValidateInventoryRejectsNonOperatorSource(t *testing.T) {
	inv := validInventory()
	p := inv.Providers["mac"]
	p.Source = "app_register"
	inv.Providers["mac"] = p

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "source must be operator") {
		t.Fatalf("validateInventory() error = %v, want operator source error", err)
	}
}

func TestValidateInventoryRejectsEmptyProviderID(t *testing.T) {
	inv := validInventory()
	inv.Providers[""] = inv.Providers["mac"]
	delete(inv.Providers, "mac")

	err := validateInventory(inv)
	if err == nil || !strings.Contains(err.Error(), "provider id is required") {
		t.Fatalf("validateInventory() error = %v, want provider id error", err)
	}
}

func TestApplyInventoryUpsertsChipsBeforeProviders(t *testing.T) {
	inv := validInventory()
	db := &fakeExec{}
	if err := applyInventory(context.Background(), db, inv); err != nil {
		t.Fatalf("applyInventory() error = %v", err)
	}
	if len(db.calls) != 4 {
		t.Fatalf("applyInventory() calls = %d, want 4", len(db.calls))
	}
	if !strings.Contains(db.calls[0].query, "INSERT INTO chip_hardware_profiles") {
		t.Fatalf("first query = %q, want chip upsert", db.calls[0].query)
	}
	if !strings.Contains(db.calls[1].query, "INSERT INTO provider_hardware_profiles") {
		t.Fatalf("second query = %q, want provider upsert", db.calls[1].query)
	}
	if got := db.calls[1].args[7]; got != true {
		t.Fatalf("provider verified arg = %v, want true", got)
	}
}

func TestApplyInventoryReconcilesRemovedOperatorRows(t *testing.T) {
	inv := validInventory()
	db := &fakeExec{}
	if err := applyInventory(context.Background(), db, inv); err != nil {
		t.Fatalf("applyInventory() error = %v", err)
	}
	if !strings.Contains(db.calls[2].query, "SET verified = FALSE") {
		t.Fatalf("third query = %q, want unverify removed providers", db.calls[2].query)
	}
	if !strings.Contains(db.calls[2].query, "source = 'operator'") {
		t.Fatalf("third query = %q, provider-map reconciliation must only cover operator rows", db.calls[2].query)
	}
	if !strings.Contains(db.calls[2].query, "NOT (provider_id = ANY($1))") {
		t.Fatalf("third query = %q, want authoritative provider list", db.calls[2].query)
	}
	if !strings.Contains(db.calls[3].query, "DELETE FROM chip_hardware_profiles") {
		t.Fatalf("fourth query = %q, want chip deletion reconciliation", db.calls[3].query)
	}
	if !strings.Contains(db.calls[3].query, "NOT (chip_normalized = ANY($1))") {
		t.Fatalf("fourth query = %q, want authoritative chip list", db.calls[3].query)
	}
}

func TestLoadInventoryKnownFields(t *testing.T) {
	path := writeTempConfig(t, `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
    memory_bandwidth_gb_per_s: 120
    network_power_kw: 0.035
    gpu_cores: 10
    cpu_cores: 10
providers:
  mac:
    chip_normalized: operator fixture chip
    chip: Operator Fixture
    unified_memory_gb: 32
    source: operator
    verified: true
    unexpected: nope
`)

	_, err := loadInventory(path)
	if err == nil || !strings.Contains(err.Error(), "field unexpected not found") {
		t.Fatalf("loadInventory() error = %v, want known fields error", err)
	}
}

func TestRunDryRunValidatesWithoutDSN(t *testing.T) {
	path := writeTempConfig(t, `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
    memory_bandwidth_gb_per_s: 120
    network_power_kw: 0.035
    gpu_cores: 10
    cpu_cores: 10
providers:
  mac:
    chip_normalized: operator fixture chip
    chip: Operator Fixture
    unified_memory_gb: 32
    source: operator
    verified: true
trusted_hardware:
  mac:
    - hardware_identity_hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
      chip_normalized: operator fixture chip
      unified_memory_gb: 32
      trusted_by: operator
`)
	var out bytes.Buffer
	if err := run(context.Background(), options{configPath: path, dryRun: true, stdout: &out}); err != nil {
		t.Fatalf("run(dry-run) error = %v", err)
	}
	if got := out.String(); !strings.Contains(got, "validated 1 chip profiles, 1 provider profiles, and 1 trusted hardware identities") {
		t.Fatalf("dry-run output = %q", got)
	}
}

func TestRunRequiresTrustDSNWhenTrustedHardwarePresent(t *testing.T) {
	path := writeTempConfig(t, `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
    memory_bandwidth_gb_per_s: 120
    network_power_kw: 0.035
    gpu_cores: 10
    cpu_cores: 10
trusted_hardware:
  mac:
    - hardware_identity_hash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
      chip_normalized: operator fixture chip
      unified_memory_gb: 32
      trusted_by: operator
`)
	err := run(context.Background(), options{
		configPath: path,
		dsn:        "postgres://inventory-writer",
		stdout:     &bytes.Buffer{},
	})
	if err == nil || !strings.Contains(err.Error(), "trust postgres dsn is required") {
		t.Fatalf("run() error = %v, want trust dsn error", err)
	}
}

func writeTempConfig(t *testing.T, body string) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "inventory-*.yaml")
	if err != nil {
		t.Fatalf("CreateTemp: %v", err)
	}
	if _, err := f.WriteString(strings.TrimLeft(body, "\n")); err != nil {
		t.Fatalf("WriteString: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	return f.Name()
}
