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

	if err := validateInventory(inv); err != nil {
		t.Fatalf("validateInventory() error = %v", err)
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
	if strings.Contains(db.calls[2].query, "source = 'operator'") {
		t.Fatalf("third query = %q, reconciliation must cover all trusted providers", db.calls[2].query)
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
`)
	var out bytes.Buffer
	if err := run(context.Background(), options{configPath: path, dryRun: true, stdout: &out}); err != nil {
		t.Fatalf("run(dry-run) error = %v", err)
	}
	if got := out.String(); !strings.Contains(got, "validated 1 chip profiles and 1 provider profiles") {
		t.Fatalf("dry-run output = %q", got)
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
