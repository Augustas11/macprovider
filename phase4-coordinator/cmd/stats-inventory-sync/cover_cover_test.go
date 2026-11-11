package main

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
)

// failNthExec fails the Nth (1-based) ExecContext call.
type failNthExec struct {
	n     int
	calls int
}

func (f *failNthExec) ExecContext(context.Context, string, ...any) (sql.Result, error) {
	f.calls++
	if f.calls == f.n {
		return nil, errors.New("boom")
	}
	return fakeResult{}, nil
}

func TestValidateInventoryBranchRejections(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*inventory)
		want   string
	}{
		{"no chips", func(i *inventory) { i.Chips = nil }, "at least one chip"},
		{"no providers nor trust", func(i *inventory) { i.Providers = nil; i.TrustedHardware = trustedHardware{} }, "at least one provider profile"},
		{"blank display chip", func(i *inventory) {
			c := i.Chips["operator fixture chip"]
			c.DisplayChip = "  "
			i.Chips["operator fixture chip"] = c
		}, "display_chip is required"},
		{"negative bandwidth", func(i *inventory) {
			c := i.Chips["operator fixture chip"]
			c.MemoryBandwidthGBPerS = -1
			i.Chips["operator fixture chip"] = c
		}, "memory_bandwidth_gb_per_s"},
		{"negative power", func(i *inventory) {
			c := i.Chips["operator fixture chip"]
			c.NetworkPowerKW = -1
			i.Chips["operator fixture chip"] = c
		}, "network_power_kw"},
		{"negative gpu", func(i *inventory) {
			c := i.Chips["operator fixture chip"]
			c.GPUCores = -1
			i.Chips["operator fixture chip"] = c
		}, "gpu_cores"},
		{"negative cpu", func(i *inventory) {
			c := i.Chips["operator fixture chip"]
			c.CPUCores = -1
			i.Chips["operator fixture chip"] = c
		}, "cpu_cores"},
		{"blank provider chip", func(i *inventory) {
			p := i.Providers["mac"]
			p.Chip = ""
			i.Providers["mac"] = p
		}, "chip is required"},
		{"provider memory too big", func(i *inventory) {
			p := i.Providers["mac"]
			p.UnifiedMemoryGB = 4097
			i.Providers["mac"] = p
		}, "between 0 and 4096"},
		{"provider id with space", func(i *inventory) {
			i.Providers["bad id"] = i.Providers["mac"]
		}, "whitespace"},
		{"trusted provider id too long", func(i *inventory) {
			i.TrustedHardware.Entries[strings.Repeat("a", 161)] = i.TrustedHardware.Entries["mac"]
		}, "too long"},
		{"trusted provider no identities", func(i *inventory) {
			i.TrustedHardware.Entries["mac"] = nil
		}, "at least one identity"},
		{"duplicate hash", func(i *inventory) {
			e := i.TrustedHardware.Entries["mac"]
			i.TrustedHardware.Entries["mac"] = append(e, e[0])
		}, "duplicates"},
		{"trust memory out of range", func(i *inventory) {
			i.TrustedHardware.Entries["mac"][0].UnifiedMemoryGB = -1
		}, "between 0 and 4096"},
		{"trusted_by too long", func(i *inventory) {
			i.TrustedHardware.Entries["mac"][0].TrustedBy = strings.Repeat("x", 121)
		}, "trusted_by must be <= 120"},
		{"trusted_by control", func(i *inventory) {
			i.TrustedHardware.Entries["mac"][0].TrustedBy = "a\x01b"
		}, "trusted_by must not contain control"},
		{"notes too long", func(i *inventory) {
			i.TrustedHardware.Entries["mac"][0].Notes = strings.Repeat("n", 1001)
		}, "notes must be <= 1000"},
		{"notes control", func(i *inventory) {
			i.TrustedHardware.Entries["mac"][0].Notes = "a\x00b"
		}, "notes must not contain control"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			inv := validInventory()
			tc.mutate(&inv)
			err := validateInventory(inv)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want containing %q", err, tc.want)
			}
		})
	}
}

func TestValidateChipKeyAndHashHelpers(t *testing.T) {
	if err := validateChipKey("  "); err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("blank key: %v", err)
	}
	if err := validateChipKey(strings.Repeat("a", 121)); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("long key: %v", err)
	}
	if err := validateChipKey("Apple M2"); err == nil || !strings.Contains(err.Error(), "lowercase") {
		t.Fatalf("uppercase key: %v", err)
	}
	if err := validateHardwareIdentityHash(" "); err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("blank hash: %v", err)
	}
	if err := validateHardwareIdentityHash(strings.Repeat("A", 64)); err == nil {
		t.Fatal("uppercase hash accepted")
	}
	if err := validateHardwareIdentityHash(strings.Repeat("g", 64)); err == nil {
		t.Fatal("non-hex hash accepted")
	}
	if err := validateHardwareIdentityHash(strings.Repeat("a", 64)); err != nil {
		t.Fatalf("valid hash: %v", err)
	}
	if err := validateTrustedBy(""); err == nil {
		t.Fatal("blank trusted_by accepted")
	}
	if got := normalizedSource("  "); got != "operator" {
		t.Fatalf("normalizedSource blank = %q", got)
	}
	if got := normalizedSource(" other "); got != "other" {
		t.Fatalf("normalizedSource = %q", got)
	}
	if got := normalizedTrustedBy("  "); got != "operator" {
		t.Fatalf("normalizedTrustedBy blank = %q", got)
	}
	if got := normalizedTrustedBy(" alice "); got != "alice" {
		t.Fatalf("normalizedTrustedBy = %q", got)
	}
}

func TestParseOptionalExpiresAt(t *testing.T) {
	v, err := parseOptionalExpiresAt("  ")
	if err != nil || v != nil {
		t.Fatalf("blank = %v, %v", v, err)
	}
	v, err = parseOptionalExpiresAt("2030-01-02T03:04:05+02:00")
	if err != nil {
		t.Fatal(err)
	}
	if got := v.(interface{ String() string }).String(); !strings.HasPrefix(got, "2030-01-02 01:04:05 +0000 UTC") {
		t.Fatalf("not normalized to UTC: %s", got)
	}
	if _, err := parseOptionalExpiresAt("tomorrow"); err == nil || !strings.Contains(err.Error(), "RFC3339") {
		t.Fatalf("bad time: %v", err)
	}
}

func TestLoadInventoryErrors(t *testing.T) {
	if _, err := loadInventory("  "); err == nil || !strings.Contains(err.Error(), "config path is required") {
		t.Fatalf("empty path: %v", err)
	}
	if _, err := loadInventory(t.TempDir() + "/missing.yaml"); err == nil || !strings.Contains(err.Error(), "read inventory config") {
		t.Fatalf("missing file: %v", err)
	}
	if _, err := loadInventory(writeTempConfig(t, "chips: [\n")); err == nil || !strings.Contains(err.Error(), "parse inventory config") {
		t.Fatalf("bad yaml: %v", err)
	}
	if _, err := loadInventory(writeTempConfig(t, "bogus_field: 1\n")); err == nil || !strings.Contains(err.Error(), "parse inventory config") {
		t.Fatalf("unknown field: %v", err)
	}
	for _, body := range []string{"trusted_hardware: [a]\n", "trusted_hardware: scalar\n"} {
		_, err := loadInventory(writeTempConfig(t, body))
		if err == nil || !strings.Contains(err.Error(), "must be a mapping") {
			t.Fatalf("%q: %v", body, err)
		}
	}
}

func TestEnsureTrustedHardwareMappingIgnoresNonMappingRoots(t *testing.T) {
	for _, raw := range []string{"", "- a\n- b\n", "[unterminated"} {
		if err := ensureTrustedHardwareMapping([]byte(raw)); err != nil {
			t.Fatalf("%q: %v", raw, err)
		}
	}
	if err := ensureTrustedHardwareMapping([]byte("trusted_hardware:\n")); err == nil {
		t.Fatal("null trusted_hardware accepted")
	}
}

func TestRunValidationAndDSNErrors(t *testing.T) {
	good := writeTempConfig(t, `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
providers:
  mac:
    chip_normalized: operator fixture chip
    chip: Operator Fixture
    unified_memory_gb: 32
`)
	t.Setenv(dsnEnvName, "")
	t.Setenv(trustDSNEnvName, "")
	if err := run(context.Background(), options{configPath: t.TempDir() + "/nope.yaml"}); err == nil || !strings.Contains(err.Error(), "nope.yaml") {
		t.Fatalf("missing config: %v", err)
	}
	err := run(context.Background(), options{configPath: good, requireChips: "other chip", dryRun: true})
	if err == nil || !strings.Contains(err.Error(), "other chip") {
		t.Fatalf("missing required chip: %v", err)
	}
	bad := writeTempConfig(t, "chips: {}\nproviders:\n  mac: {chip_normalized: x, chip: y}\n")
	if err := run(context.Background(), options{configPath: bad, dryRun: true}); err == nil || !strings.Contains(err.Error(), "at least one chip") {
		t.Fatalf("invalid inventory: %v", err)
	}
	err = run(context.Background(), options{configPath: good})
	if err == nil || !strings.Contains(err.Error(), "via --dsn or") {
		t.Fatalf("no dsn: %v", err)
	}
	var out strings.Builder
	if err := run(context.Background(), options{configPath: good, dryRun: true, stdout: &out}); err != nil {
		t.Fatal(err)
	}
	if want := "validated 1 chip profiles, 1 provider profiles, and 0 trusted hardware identities\n"; out.String() != want {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
}

func TestApplyTrustDemotionsPropagatesStepErrors(t *testing.T) {
	if err := applyTrustDemotions(context.Background(), &failNthExec{n: 1}); err == nil || !strings.Contains(err.Error(), "lock demotion candidate profiles") {
		t.Fatalf("step 1: %v", err)
	}
	if err := applyTrustDemotions(context.Background(), &failNthExec{n: 2}); err == nil || !strings.Contains(err.Error(), "demote provider profiles") {
		t.Fatalf("step 2: %v", err)
	}
}

func TestApplyTrustInventoryErrorPaths(t *testing.T) {
	inv := validInventory()
	if err := applyTrustInventory(context.Background(), &failNthExec{n: 1}, inv); err == nil || !strings.Contains(err.Error(), "upsert trusted hardware identity") {
		t.Fatalf("upsert: %v", err)
	}
	if err := applyTrustInventory(context.Background(), &failNthExec{n: 2}, inv); err == nil || !strings.Contains(err.Error(), "delete removed trusted hardware") {
		t.Fatalf("delete: %v", err)
	}
	inv.TrustedHardware.Entries["mac"][0].ExpiresAt = "garbage"
	f := &fakeExec{}
	if err := applyTrustInventory(context.Background(), f, inv); err == nil || !strings.Contains(err.Error(), "expires_at") {
		t.Fatalf("expires: %v", err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("wrote despite invalid expiry: %d calls", len(f.calls))
	}
}
