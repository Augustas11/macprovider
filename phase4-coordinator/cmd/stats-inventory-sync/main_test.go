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
		TrustedHardware: trustedHardware{
			Present: true,
			Entries: map[string][]trustedHardwareIdentity{
				"mac": {
					{
						HardwareIdentityHash: fixtureHardwareIdentityHash,
						ChipNormalized:       "operator fixture chip",
						UnifiedMemoryGB:      32,
						TrustedBy:            "operator",
					},
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

func TestValidateInventoryAcceptsExplicitEmptyTrustedHardware(t *testing.T) {
	// An explicitly-empty trusted_hardware section (`trusted_hardware: {}`) is the
	// deliberate revoke-all-inventory-roots signal and must validate; only an
	// OMITTED section leaves roots untouched (issue #582 FIX 2).
	inv := validInventory()
	inv.TrustedHardware = trustedHardware{Present: true, Entries: map[string][]trustedHardwareIdentity{}}

	if err := validateInventory(inv); err != nil {
		t.Fatalf("validateInventory() error = %v, want explicit-empty trusted_hardware accepted", err)
	}
}

func TestValidateInventoryAcceptsOmittedTrustedHardware(t *testing.T) {
	// An omitted trusted_hardware section (Present=false) is a no-op that leaves
	// every trust root untouched; validation must accept it (issue #582 FIX 2).
	inv := validInventory()
	inv.TrustedHardware = trustedHardware{}

	if err := validateInventory(inv); err != nil {
		t.Fatalf("validateInventory() error = %v, want omitted trusted_hardware accepted", err)
	}
}

func TestValidateInventoryRejectsUnknownTrustedHardwareChip(t *testing.T) {
	inv := validInventory()
	inv.TrustedHardware.Entries["mac"][0].ChipNormalized = "missing"

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
			inv.TrustedHardware.Entries["mac"][0].HardwareIdentityHash = hash

			err := validateInventory(inv)
			if err == nil || !strings.Contains(err.Error(), "hardware_identity_hash") {
				t.Fatalf("validateInventory() error = %v, want hardware identity hash error", err)
			}
		})
	}
}

func TestValidateInventoryRejectsInvalidTrustedHardwareExpiry(t *testing.T) {
	inv := validInventory()
	inv.TrustedHardware.Entries["mac"][0].ExpiresAt = "tomorrow"

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
	inv.TrustedHardware.Entries["mac"][0].ChipNormalized = "apple m4 max"

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

func TestApplyTrustInventoryScopesUpsertAndDeleteToInventorySource(t *testing.T) {
	inv := validInventory()
	db := &fakeExec{}
	if err := applyTrustInventory(context.Background(), db, inv); err != nil {
		t.Fatalf("applyTrustInventory() error = %v", err)
	}
	if len(db.calls) != 2 {
		t.Fatalf("applyTrustInventory() calls = %d, want 2", len(db.calls))
	}
	// The upsert tags rows as inventory-sourced so operator_api rows written by
	// the durable approval path are never mistaken for sync-managed rows.
	if !strings.Contains(db.calls[0].query, "'inventory'") {
		t.Fatalf("upsert query = %q, want inventory source tag", db.calls[0].query)
	}
	// The trust table PK is (provider_id, hardware_identity_hash, source), so the
	// upsert conflict target is 3-column and touches ONLY the inventory row; an
	// operator_api row is an independent row it can never conflict with. The former
	// WHERE source='inventory' DO UPDATE guard is redundant and removed (issue #582).
	if !strings.Contains(db.calls[0].query, "ON CONFLICT (provider_id, hardware_identity_hash, source) DO UPDATE") {
		t.Fatalf("upsert query = %q, want 3-column ON CONFLICT target", db.calls[0].query)
	}
	if strings.Contains(db.calls[0].query, "WHERE hardware_verification_trust.source = 'inventory'") {
		t.Fatalf("upsert query = %q, redundant source-scoped DO UPDATE guard must be removed", db.calls[0].query)
	}
	// The reconciling DELETE must only touch inventory rows so an operator_api
	// trust root survives a sync run that omits it from the YAML (issue #582).
	if !strings.Contains(db.calls[1].query, "source = 'inventory'") {
		t.Fatalf("delete query = %q, want inventory-scoped reconciliation", db.calls[1].query)
	}
}

func TestApplyTrustDemotionsLocksCandidatesBeforeReEvaluating(t *testing.T) {
	// FIX 3: demotion must lock candidate rows FOR UPDATE in a first statement so
	// the re-evaluation runs under a fresh snapshot and cannot re-demote a profile
	// the verifier's promoteJob just committed.
	db := &fakeExec{}
	if err := applyTrustDemotions(context.Background(), db); err != nil {
		t.Fatalf("applyTrustDemotions() error = %v", err)
	}
	if len(db.calls) != 2 {
		t.Fatalf("applyTrustDemotions() calls = %d, want 2 (lock then update)", len(db.calls))
	}
	if !strings.Contains(db.calls[0].query, "FOR UPDATE") {
		t.Fatalf("first query = %q, want candidate row lock (FOR UPDATE)", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "FROM provider_hardware_profiles") ||
		!strings.Contains(db.calls[0].query, "source <> 'operator'") {
		t.Fatalf("first query = %q, want verified non-operator candidate lock", db.calls[0].query)
	}
	if strings.Contains(db.calls[0].query, "UPDATE provider_hardware_profiles") {
		t.Fatalf("first query = %q, lock statement must not be the UPDATE", db.calls[0].query)
	}
}

func TestApplyTrustDemotionsDemotesExpiredTrustRegardlessOfSource(t *testing.T) {
	db := &fakeExec{}
	if err := applyTrustDemotions(context.Background(), db); err != nil {
		t.Fatalf("applyTrustDemotions() error = %v", err)
	}
	if len(db.calls) != 2 {
		t.Fatalf("applyTrustDemotions() calls = %d, want 2", len(db.calls))
	}
	// The trust-root join must NOT filter on source, so a verified profile backed
	// only by an expired operator_api root is demoted just like an expired
	// inventory root — its expires_at fails the active-trust predicate (#582).
	if strings.Contains(db.calls[1].query, "t.source") {
		t.Fatalf("query = %q, demotion trust join must be source-agnostic to catch expired operator_api roots", db.calls[1].query)
	}
	if !strings.Contains(db.calls[1].query, "t.expires_at IS NULL OR t.expires_at > now()") {
		t.Fatalf("query = %q, want expired trust roots excluded from active-trust proof", db.calls[1].query)
	}
}

func TestApplyTrustDemotionsDemotesNonAuthoritativeProfilesWithoutActiveTrust(t *testing.T) {
	db := &fakeExec{}
	if err := applyTrustDemotions(context.Background(), db); err != nil {
		t.Fatalf("applyTrustDemotions() error = %v", err)
	}
	if len(db.calls) != 2 {
		t.Fatalf("applyTrustDemotions() calls = %d, want 2", len(db.calls))
	}
	if !strings.Contains(db.calls[1].query, "UPDATE provider_hardware_profiles") {
		t.Fatalf("query = %q, want provider profile demotion", db.calls[1].query)
	}
	if strings.Contains(db.calls[1].query, "last_reported_at = now()") {
		t.Fatalf("query = %q, demotion must preserve evidence timestamp", db.calls[1].query)
	}
	// Every non-authoritative verified source (cli_hello AND app_register) must be
	// demotable, so the predicate must exempt only the authoritative operator
	// source rather than restricting to a single source.
	if !strings.Contains(db.calls[1].query, "ph.source <> 'operator'") {
		t.Fatalf("query = %q, want non-authoritative-source demotion (NOT operator)", db.calls[1].query)
	}
	if strings.Contains(db.calls[1].query, "ph.source = 'cli_hello'") {
		t.Fatalf("query = %q, must not restrict demotion to cli_hello (app_register verified profiles must also demote)", db.calls[1].query)
	}
	if !strings.Contains(db.calls[1].query, "hardware_verification_jobs") {
		t.Fatalf("query = %q, want verified job evidence check", db.calls[1].query)
	}
	if !strings.Contains(db.calls[1].query, "hardware_verification_trust") {
		t.Fatalf("query = %q, want active trust-root check", db.calls[1].query)
	}
	if !strings.Contains(db.calls[1].query, "j.evidence #>> '{hardware,hardware_identity_hash}'") {
		t.Fatalf("query = %q, want exact hardware identity hash proof", db.calls[1].query)
	}
	if !strings.Contains(db.calls[1].query, "t.expires_at IS NULL OR t.expires_at > now()") {
		t.Fatalf("query = %q, want expired trust roots excluded", db.calls[1].query)
	}
	// The authoritative operator source (rows the operator YAML asserts verified
	// directly) must never be demoted by the trust-based reconciliation.
	if strings.Contains(db.calls[1].query, "ph.source = 'operator'") {
		t.Fatalf("query = %q, must not demote authoritative operator inventory rows", db.calls[1].query)
	}
}

func TestApplyTrustInventoryRevokesAllInventoryRootsWhenEmptied(t *testing.T) {
	// An explicitly-empty trusted_hardware section still runs the
	// source='inventory' scoped DELETE so the last inventory root is revoked.
	// operator_api roots are untouched because the DELETE is scoped to
	// source='inventory' (issue #582 FIX 2).
	inv := validInventory()
	inv.TrustedHardware = trustedHardware{Present: true, Entries: nil}
	db := &fakeExec{}
	if err := applyTrustInventory(context.Background(), db, inv); err != nil {
		t.Fatalf("applyTrustInventory() error = %v", err)
	}
	if len(db.calls) != 1 {
		t.Fatalf("applyTrustInventory() calls = %d, want 1 (scoped DELETE only)", len(db.calls))
	}
	if !strings.Contains(db.calls[0].query, "DELETE FROM hardware_verification_trust") {
		t.Fatalf("query = %q, want inventory reconciliation DELETE", db.calls[0].query)
	}
	if !strings.Contains(db.calls[0].query, "source = 'inventory'") {
		t.Fatalf("query = %q, want DELETE scoped to inventory source (operator_api preserved)", db.calls[0].query)
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

func TestLoadInventoryDetectsTrustedHardwarePresence(t *testing.T) {
	base := `
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
`
	t.Run("omitted", func(t *testing.T) {
		inv, err := loadInventory(writeTempConfig(t, base))
		if err != nil {
			t.Fatalf("loadInventory() error = %v", err)
		}
		if inv.TrustedHardware.Present {
			t.Fatal("omitted trusted_hardware must decode Present=false (no-op, roots untouched)")
		}
	})
	t.Run("explicit_empty", func(t *testing.T) {
		inv, err := loadInventory(writeTempConfig(t, base+"trusted_hardware: {}\n"))
		if err != nil {
			t.Fatalf("loadInventory() error = %v", err)
		}
		if !inv.TrustedHardware.Present {
			t.Fatal("explicit empty trusted_hardware must decode Present=true (revoke-all signal)")
		}
		if len(inv.TrustedHardware.Entries) != 0 {
			t.Fatalf("explicit empty trusted_hardware must decode zero entries, got %d", len(inv.TrustedHardware.Entries))
		}
	})
	t.Run("populated", func(t *testing.T) {
		inv, err := loadInventory(writeTempConfig(t, base+`trusted_hardware:
  mac:
    - hardware_identity_hash: `+fixtureHardwareIdentityHash+`
      chip_normalized: operator fixture chip
      unified_memory_gb: 32
      trusted_by: operator
`))
		if err != nil {
			t.Fatalf("loadInventory() error = %v", err)
		}
		if !inv.TrustedHardware.Present || len(inv.TrustedHardware.Entries) != 1 {
			t.Fatalf("populated trusted_hardware must decode Present=true with 1 entry, got present=%t entries=%d", inv.TrustedHardware.Present, len(inv.TrustedHardware.Entries))
		}
	})
}

func TestLoadInventoryRejectsUnknownTrustedHardwareIdentityField(t *testing.T) {
	// FIX 3(a) (issue #582): yaml.Node.Decode does not inherit the outer
	// KnownFields(true), so a nested typo like expires_att would be silently
	// dropped — turning intended temporary trust into permanent trust. The strict
	// nested decode must make it a hard error.
	base := `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
    memory_bandwidth_gb_per_s: 120
    network_power_kw: 0.035
    gpu_cores: 10
    cpu_cores: 10
`
	_, err := loadInventory(writeTempConfig(t, base+`trusted_hardware:
  mac:
    - hardware_identity_hash: `+fixtureHardwareIdentityHash+`
      chip_normalized: operator fixture chip
      unified_memory_gb: 32
      trusted_by: operator
      expires_att: 2999-01-01T00:00:00Z
`))
	if err == nil || !strings.Contains(err.Error(), "expires_att") {
		t.Fatalf("loadInventory() error = %v, want nested unknown-field (expires_att) error", err)
	}
}

func TestLoadInventoryRejectsNullTrustedHardware(t *testing.T) {
	// FIX 3(b) (issue #582): a bare `trusted_hardware:` (YAML null) must be
	// rejected. Revoke-all is reserved for an EXPLICIT `{}`; a null must not
	// silently decode as present-with-nil and trigger revoke-all.
	base := `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
    memory_bandwidth_gb_per_s: 120
    network_power_kw: 0.035
    gpu_cores: 10
    cpu_cores: 10
`
	for _, tc := range []struct {
		name string
		tail string
	}{
		{"null", "trusted_hardware:\n"},
		{"scalar", "trusted_hardware: nope\n"},
		{"sequence", "trusted_hardware:\n  - nope\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := loadInventory(writeTempConfig(t, base+tc.tail))
			if err == nil || !strings.Contains(err.Error(), "trusted_hardware must be a mapping") {
				t.Fatalf("loadInventory() error = %v, want non-mapping trusted_hardware rejected", err)
			}
		})
	}
}

func TestLoadInventoryAcceptsExplicitEmptyTrustedHardwareAsRevokeAll(t *testing.T) {
	// FIX 3(b): an explicit empty mapping is the ONLY accepted revoke-all signal.
	base := `
chips:
  operator fixture chip:
    display_chip: Operator Fixture
    memory_bandwidth_gb_per_s: 120
    network_power_kw: 0.035
    gpu_cores: 10
    cpu_cores: 10
`
	inv, err := loadInventory(writeTempConfig(t, base+"trusted_hardware: {}\n"))
	if err != nil {
		t.Fatalf("loadInventory() error = %v, want explicit-empty accepted", err)
	}
	if !inv.TrustedHardware.Present || len(inv.TrustedHardware.Entries) != 0 {
		t.Fatalf("explicit empty must decode Present=true with zero entries, got present=%t entries=%d",
			inv.TrustedHardware.Present, len(inv.TrustedHardware.Entries))
	}
}

func TestDemotionContextSurvivesCancelledParent(t *testing.T) {
	// FIX 5 (issue #582): demotion must run even when the shared run context is
	// already cancelled/timed out (e.g. a blackholed trust DSN exhausted it), so
	// an API-revoked root is not left effective forever. demotionContext derives
	// an independent, bounded context via context.WithoutCancel so a cancelled
	// parent cannot starve it.
	parent, cancel := context.WithCancel(context.Background())
	cancel() // parent already cancelled, mirroring an exhausted run budget
	dctx, dcancel := demotionContext(parent)
	defer dcancel()
	if err := dctx.Err(); err != nil {
		t.Fatalf("demotion context must be live despite a cancelled parent, got err=%v", err)
	}
	if _, ok := dctx.Deadline(); !ok {
		t.Fatal("demotion context must carry its own bounded deadline")
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
