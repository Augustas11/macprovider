package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/lib/pq"
	"gopkg.in/yaml.v3"
)

const (
	defaultConfigPath = "/etc/macprovider-stats/stats-hardware-inventory.yaml"
	dsnEnvName        = "STATS_INVENTORY_DSN"
	trustDSNEnvName   = "STATS_TRUST_INVENTORY_DSN"
	runTimeout        = 15 * time.Second
)

type inventory struct {
	Chips           map[string]chipProfile               `yaml:"chips"`
	Providers       map[string]providerProfile           `yaml:"providers"`
	TrustedHardware map[string][]trustedHardwareIdentity `yaml:"trusted_hardware"`
}

type chipProfile struct {
	DisplayChip           string  `yaml:"display_chip"`
	MemoryBandwidthGBPerS int64   `yaml:"memory_bandwidth_gb_per_s"`
	NetworkPowerKW        float64 `yaml:"network_power_kw"`
	GPUCores              int     `yaml:"gpu_cores"`
	CPUCores              int     `yaml:"cpu_cores"`
}

type providerProfile struct {
	ChipNormalized  string `yaml:"chip_normalized"`
	Chip            string `yaml:"chip"`
	UnifiedMemoryGB int    `yaml:"unified_memory_gb"`
	MacOSVersion    string `yaml:"macos_version"`
	AppVersion      string `yaml:"app_version"`
	Verified        bool   `yaml:"verified"`
	Source          string `yaml:"source"`
}

type trustedHardwareIdentity struct {
	HardwareIdentityHash string `yaml:"hardware_identity_hash"`
	ChipNormalized       string `yaml:"chip_normalized"`
	UnifiedMemoryGB      int    `yaml:"unified_memory_gb"`
	TrustedBy            string `yaml:"trusted_by"`
	ExpiresAt            string `yaml:"expires_at"`
	Notes                string `yaml:"notes"`
}

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

type options struct {
	configPath string
	dsn        string
	trustDSN   string
	dryRun     bool
	stdout     io.Writer
}

func main() {
	var opts options
	flag.StringVar(&opts.configPath, "config", defaultConfigPath, "operator hardware inventory YAML")
	flag.StringVar(&opts.dsn, "dsn", "", "Postgres DSN; defaults to STATS_INVENTORY_DSN")
	flag.StringVar(&opts.trustDSN, "trust-dsn", "", "Postgres trust-root DSN; defaults to STATS_TRUST_INVENTORY_DSN")
	flag.BoolVar(&opts.dryRun, "dry-run", false, "validate config and print counts without writing")
	flag.Parse()
	opts.stdout = os.Stdout

	if err := run(context.Background(), opts); err != nil {
		fmt.Fprintf(os.Stderr, "stats-inventory-sync: %v\n", err)
		os.Exit(1)
	}
}

func run(parent context.Context, opts options) error {
	out := opts.stdout
	if out == nil {
		out = io.Discard
	}
	inv, err := loadInventory(opts.configPath)
	if err != nil {
		return err
	}
	if err := validateInventory(inv); err != nil {
		return err
	}
	if opts.dryRun {
		fmt.Fprintf(out, "validated %d chip profiles, %d provider profiles, and %d trusted hardware identities\n",
			len(inv.Chips), len(inv.Providers), trustedHardwareCount(inv.TrustedHardware))
		return nil
	}

	dsn := strings.TrimSpace(opts.dsn)
	if dsn == "" {
		dsn = strings.TrimSpace(os.Getenv(dsnEnvName))
	}
	if dsn == "" {
		return fmt.Errorf("postgres dsn is required via --dsn or %s", dsnEnvName)
	}
	trustDSN := strings.TrimSpace(opts.trustDSN)
	if trustDSN == "" {
		trustDSN = strings.TrimSpace(os.Getenv(trustDSNEnvName))
	}
	if trustedHardwareCount(inv.TrustedHardware) > 0 && trustDSN == "" {
		return fmt.Errorf("trust postgres dsn is required via --trust-dsn or %s when trusted_hardware is present", trustDSNEnvName)
	}

	ctx, cancel := context.WithTimeout(parent, runTimeout)
	defer cancel()

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return fmt.Errorf("open postgres: %w", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)

	tx, err := db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin inventory transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	if err := applyInventory(ctx, tx, inv); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit inventory transaction: %w", err)
	}
	committed = true

	if trustedHardwareCount(inv.TrustedHardware) > 0 {
		trustDB, err := sql.Open("postgres", trustDSN)
		if err != nil {
			return fmt.Errorf("open trust postgres: %w", err)
		}
		defer trustDB.Close()
		trustDB.SetMaxOpenConns(1)
		trustDB.SetMaxIdleConns(1)
		trustDB.SetConnMaxLifetime(5 * time.Minute)
		trustDB.SetConnMaxIdleTime(time.Minute)

		trustTX, err := trustDB.BeginTx(ctx, &sql.TxOptions{})
		if err != nil {
			return fmt.Errorf("begin trust inventory transaction: %w", err)
		}
		trustCommitted := false
		defer func() {
			if !trustCommitted {
				_ = trustTX.Rollback()
			}
		}()
		if err := applyTrustInventory(ctx, trustTX, inv); err != nil {
			return err
		}
		if err := trustTX.Commit(); err != nil {
			return fmt.Errorf("commit trust inventory transaction: %w", err)
		}
		trustCommitted = true

		demotionTX, err := db.BeginTx(ctx, &sql.TxOptions{})
		if err != nil {
			return fmt.Errorf("begin trust demotion transaction: %w", err)
		}
		demotionCommitted := false
		defer func() {
			if !demotionCommitted {
				_ = demotionTX.Rollback()
			}
		}()
		if err := applyTrustDemotions(ctx, demotionTX); err != nil {
			return err
		}
		if err := demotionTX.Commit(); err != nil {
			return fmt.Errorf("commit trust demotion transaction: %w", err)
		}
		demotionCommitted = true
	}

	fmt.Fprintf(out, "upserted %d chip profiles, %d provider profiles, and %d trusted hardware identities\n",
		len(inv.Chips), len(inv.Providers), trustedHardwareCount(inv.TrustedHardware))
	return nil
}

func loadInventory(path string) (inventory, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return inventory{}, errors.New("config path is required")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return inventory{}, fmt.Errorf("read inventory config: %w", err)
	}
	var inv inventory
	dec := yaml.NewDecoder(strings.NewReader(string(raw)))
	dec.KnownFields(true)
	if err := dec.Decode(&inv); err != nil {
		return inventory{}, fmt.Errorf("parse inventory config: %w", err)
	}
	return inv, nil
}

func validateInventory(inv inventory) error {
	if len(inv.Chips) == 0 {
		return errors.New("inventory must define at least one chip profile")
	}
	if len(inv.Providers) == 0 && len(inv.TrustedHardware) == 0 {
		return errors.New("inventory must define at least one provider profile or trusted hardware identity")
	}
	if inv.Providers != nil && len(inv.Providers) == 0 {
		return errors.New("providers must define at least one provider; omit the section to leave provider profiles untouched")
	}
	if inv.TrustedHardware != nil && len(inv.TrustedHardware) == 0 {
		return errors.New("trusted_hardware must define at least one provider; omit the section to leave trust roots untouched")
	}
	for key, chip := range inv.Chips {
		if err := validateChipKey(key); err != nil {
			return err
		}
		if strings.TrimSpace(chip.DisplayChip) == "" {
			return fmt.Errorf("chip %q display_chip is required", key)
		}
		if chip.MemoryBandwidthGBPerS < 0 {
			return fmt.Errorf("chip %q memory_bandwidth_gb_per_s must be >= 0", key)
		}
		if chip.NetworkPowerKW < 0 {
			return fmt.Errorf("chip %q network_power_kw must be >= 0", key)
		}
		if chip.GPUCores < 0 {
			return fmt.Errorf("chip %q gpu_cores must be >= 0", key)
		}
		if chip.CPUCores < 0 {
			return fmt.Errorf("chip %q cpu_cores must be >= 0", key)
		}
	}
	for providerID, provider := range inv.Providers {
		if err := validateProviderID(providerID); err != nil {
			return err
		}
		if _, ok := inv.Chips[provider.ChipNormalized]; !ok {
			return fmt.Errorf("provider %q references unknown chip_normalized %q", providerID, provider.ChipNormalized)
		}
		if strings.TrimSpace(provider.Chip) == "" {
			return fmt.Errorf("provider %q chip is required", providerID)
		}
		if provider.UnifiedMemoryGB < 0 || provider.UnifiedMemoryGB > 4096 {
			return fmt.Errorf("provider %q unified_memory_gb must be between 0 and 4096", providerID)
		}
		source := normalizedSource(provider.Source)
		if source != "operator" {
			return fmt.Errorf("provider %q source must be operator", providerID)
		}
	}
	for providerID, identities := range inv.TrustedHardware {
		if err := validateProviderID(providerID); err != nil {
			return err
		}
		if len(identities) == 0 {
			return fmt.Errorf("trusted_hardware provider %q must define at least one identity", providerID)
		}
		seen := map[string]bool{}
		for _, identity := range identities {
			if err := validateHardwareIdentityHash(identity.HardwareIdentityHash); err != nil {
				return fmt.Errorf("trusted_hardware provider %q: %w", providerID, err)
			}
			if seen[identity.HardwareIdentityHash] {
				return fmt.Errorf("trusted_hardware provider %q duplicates hardware_identity_hash %q", providerID, identity.HardwareIdentityHash)
			}
			seen[identity.HardwareIdentityHash] = true
			if _, ok := inv.Chips[identity.ChipNormalized]; !ok {
				return fmt.Errorf("trusted_hardware provider %q references unknown chip_normalized %q", providerID, identity.ChipNormalized)
			}
			if identity.UnifiedMemoryGB < 0 || identity.UnifiedMemoryGB > 4096 {
				return fmt.Errorf("trusted_hardware provider %q unified_memory_gb must be between 0 and 4096", providerID)
			}
			if _, err := parseOptionalExpiresAt(identity.ExpiresAt); err != nil {
				return fmt.Errorf("trusted_hardware provider %q expires_at: %w", providerID, err)
			}
			if err := validateTrustedBy(normalizedTrustedBy(identity.TrustedBy)); err != nil {
				return fmt.Errorf("trusted_hardware provider %q trusted_by: %w", providerID, err)
			}
			if len(identity.Notes) > 1000 {
				return fmt.Errorf("trusted_hardware provider %q notes must be <= 1000 bytes", providerID)
			}
			if containsControl(identity.Notes) {
				return fmt.Errorf("trusted_hardware provider %q notes must not contain control characters", providerID)
			}
		}
	}
	return nil
}

func validateChipKey(key string) error {
	if strings.TrimSpace(key) == "" {
		return errors.New("chip key is required")
	}
	if len(key) > 120 {
		return fmt.Errorf("chip key %q is too long", key)
	}
	if normalizedChipKey(key) != key {
		return fmt.Errorf("chip key %q must be lowercase and space-normalized", key)
	}
	for _, r := range key {
		if unicode.IsControl(r) {
			return fmt.Errorf("chip key %q must not contain control characters", key)
		}
	}
	return nil
}

func normalizedChipKey(chip string) string {
	chip = strings.ToLower(strings.TrimSpace(chip))
	return strings.Join(strings.Fields(chip), " ")
}

func validateProviderID(providerID string) error {
	if strings.TrimSpace(providerID) == "" {
		return errors.New("provider id is required")
	}
	if len(providerID) > 160 {
		return fmt.Errorf("provider id %q is too long", providerID)
	}
	for _, r := range providerID {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return fmt.Errorf("provider id %q must not contain whitespace or control characters", providerID)
		}
	}
	return nil
}

func validateHardwareIdentityHash(hash string) error {
	if strings.TrimSpace(hash) == "" {
		return errors.New("hardware_identity_hash is required")
	}
	if len(hash) != 64 {
		return errors.New("hardware_identity_hash must be a lowercase 64-character sha256 hex digest")
	}
	for _, r := range hash {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return errors.New("hardware_identity_hash must be a lowercase 64-character sha256 hex digest")
		}
	}
	return nil
}

func validateTrustedBy(trustedBy string) error {
	if strings.TrimSpace(trustedBy) == "" {
		return errors.New("trusted_by is required")
	}
	if len(trustedBy) > 120 {
		return errors.New("trusted_by must be <= 120 bytes")
	}
	if containsControl(trustedBy) {
		return errors.New("trusted_by must not contain control characters")
	}
	return nil
}

func containsControl(value string) bool {
	for _, r := range value {
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}

func normalizedSource(source string) string {
	source = strings.TrimSpace(source)
	if source == "" {
		return "operator"
	}
	return source
}

func normalizedTrustedBy(trustedBy string) string {
	trustedBy = strings.TrimSpace(trustedBy)
	if trustedBy == "" {
		return "operator"
	}
	return trustedBy
}

func parseOptionalExpiresAt(raw string) (any, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return nil, fmt.Errorf("must be RFC3339: %w", err)
	}
	return parsed.UTC(), nil
}

func trustedHardwareCount(trusted map[string][]trustedHardwareIdentity) int {
	var count int
	for _, identities := range trusted {
		count += len(identities)
	}
	return count
}

func applyInventory(ctx context.Context, db execer, inv inventory) error {
	chipKeys := make([]string, 0, len(inv.Chips))
	for key := range inv.Chips {
		chipKeys = append(chipKeys, key)
	}
	sort.Strings(chipKeys)
	for _, key := range chipKeys {
		chip := inv.Chips[key]
		if _, err := db.ExecContext(ctx, `
INSERT INTO chip_hardware_profiles (
    chip_normalized, display_chip, memory_bandwidth_gb_per_s,
    network_power_kw, gpu_cores, cpu_cores, updated_at
) VALUES (
    $1, $2, $3, $4, $5, $6, now()
)
ON CONFLICT (chip_normalized) DO UPDATE
   SET display_chip = EXCLUDED.display_chip,
       memory_bandwidth_gb_per_s = EXCLUDED.memory_bandwidth_gb_per_s,
       network_power_kw = EXCLUDED.network_power_kw,
       gpu_cores = EXCLUDED.gpu_cores,
       cpu_cores = EXCLUDED.cpu_cores,
       updated_at = now()`,
			key,
			strings.TrimSpace(chip.DisplayChip),
			chip.MemoryBandwidthGBPerS,
			chip.NetworkPowerKW,
			chip.GPUCores,
			chip.CPUCores,
		); err != nil {
			return fmt.Errorf("upsert chip %q: %w", key, err)
		}
	}

	if inv.Providers != nil {
		providerIDs := make([]string, 0, len(inv.Providers))
		for providerID := range inv.Providers {
			providerIDs = append(providerIDs, providerID)
		}
		sort.Strings(providerIDs)
		for _, providerID := range providerIDs {
			provider := inv.Providers[providerID]
			if _, err := db.ExecContext(ctx, `
INSERT INTO provider_hardware_profiles (
    provider_id, chip, chip_normalized, unified_memory_gb,
    macos_version, app_version, source, verified, last_reported_at
) VALUES (
    $1, $2, $3, $4, $5, $6, $7, $8, now()
)
ON CONFLICT (provider_id) DO UPDATE
   SET chip = EXCLUDED.chip,
       chip_normalized = EXCLUDED.chip_normalized,
       unified_memory_gb = EXCLUDED.unified_memory_gb,
       macos_version = EXCLUDED.macos_version,
       app_version = EXCLUDED.app_version,
       source = EXCLUDED.source,
       verified = EXCLUDED.verified,
       last_reported_at = EXCLUDED.last_reported_at`,
				providerID,
				strings.TrimSpace(provider.Chip),
				provider.ChipNormalized,
				provider.UnifiedMemoryGB,
				strings.TrimSpace(provider.MacOSVersion),
				strings.TrimSpace(provider.AppVersion),
				normalizedSource(provider.Source),
				provider.Verified,
			); err != nil {
				return fmt.Errorf("upsert provider %q: %w", providerID, err)
			}
		}

		if _, err := db.ExecContext(ctx, `
UPDATE provider_hardware_profiles
   SET verified = FALSE,
       last_reported_at = now()
 WHERE verified = TRUE
   AND source = 'operator'
   AND NOT (provider_id = ANY($1))`,
			pq.Array(providerIDs),
		); err != nil {
			return fmt.Errorf("unverify removed operator providers: %w", err)
		}
	}

	if _, err := db.ExecContext(ctx, `
DELETE FROM chip_hardware_profiles
 WHERE NOT (chip_normalized = ANY($1))`,
		pq.Array(chipKeys),
	); err != nil {
		return fmt.Errorf("delete removed chip profiles: %w", err)
	}
	return nil
}

func applyTrustInventory(ctx context.Context, db execer, inv inventory) error {
	trustedKeys := make([]string, 0, trustedHardwareCount(inv.TrustedHardware))
	providerIDs := make([]string, 0, len(inv.TrustedHardware))
	for providerID := range inv.TrustedHardware {
		providerIDs = append(providerIDs, providerID)
	}
	sort.Strings(providerIDs)
	for _, providerID := range providerIDs {
		identities := append([]trustedHardwareIdentity(nil), inv.TrustedHardware[providerID]...)
		sort.Slice(identities, func(i, j int) bool {
			return identities[i].HardwareIdentityHash < identities[j].HardwareIdentityHash
		})
		for _, identity := range identities {
			expiresAt, err := parseOptionalExpiresAt(identity.ExpiresAt)
			if err != nil {
				return fmt.Errorf("parse trusted_hardware provider %q expires_at: %w", providerID, err)
			}
			trustedKeys = append(trustedKeys, trustKey(providerID, identity.HardwareIdentityHash))
			if _, err := db.ExecContext(ctx, `
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb,
    trusted_by, expires_at, notes
) VALUES (
    $1, $2, $3, $4, $5, $6, $7
)
ON CONFLICT (provider_id, hardware_identity_hash) DO UPDATE
   SET chip_normalized = EXCLUDED.chip_normalized,
       unified_memory_gb = EXCLUDED.unified_memory_gb,
       trusted_by = EXCLUDED.trusted_by,
       trusted_at = CASE
           WHEN hardware_verification_trust.chip_normalized IS DISTINCT FROM EXCLUDED.chip_normalized
             OR hardware_verification_trust.unified_memory_gb IS DISTINCT FROM EXCLUDED.unified_memory_gb
             OR hardware_verification_trust.trusted_by IS DISTINCT FROM EXCLUDED.trusted_by
             OR hardware_verification_trust.expires_at IS DISTINCT FROM EXCLUDED.expires_at
             OR hardware_verification_trust.notes IS DISTINCT FROM EXCLUDED.notes
           THEN now()
           ELSE hardware_verification_trust.trusted_at
       END,
       expires_at = EXCLUDED.expires_at,
       notes = EXCLUDED.notes`,
				providerID,
				identity.HardwareIdentityHash,
				identity.ChipNormalized,
				identity.UnifiedMemoryGB,
				normalizedTrustedBy(identity.TrustedBy),
				expiresAt,
				strings.TrimSpace(identity.Notes),
			); err != nil {
				return fmt.Errorf("upsert trusted hardware identity for provider %q: %w", providerID, err)
			}
		}
	}
	if _, err := db.ExecContext(ctx, `
DELETE FROM hardware_verification_trust
 WHERE NOT ((provider_id || chr(31) || hardware_identity_hash) = ANY($1))`,
		pq.Array(trustedKeys),
	); err != nil {
		return fmt.Errorf("delete removed trusted hardware identities: %w", err)
	}
	return nil
}

func applyTrustDemotions(ctx context.Context, db execer) error {
	if _, err := db.ExecContext(ctx, `
UPDATE provider_hardware_profiles ph
   SET verified = FALSE
 WHERE ph.verified = TRUE
   AND ph.source = 'cli_hello'
   AND NOT EXISTS (
       SELECT 1
         FROM hardware_verification_jobs j
         JOIN hardware_verification_trust t
           ON t.provider_id = j.provider_id
          AND t.hardware_identity_hash = j.evidence #>> '{hardware,hardware_identity_hash}'
          AND t.chip_normalized = j.chip_normalized
          AND t.unified_memory_gb = j.unified_memory_gb
          AND (t.expires_at IS NULL OR t.expires_at > now())
        WHERE j.status = 'verified'
          AND j.provider_id = ph.provider_id
          AND j.chip_normalized = ph.chip_normalized
          AND j.unified_memory_gb = ph.unified_memory_gb
          AND j.os_version = ph.macos_version
          AND j.binary_version = ph.app_version
          AND j.generated_at = ph.last_reported_at
   )`); err != nil {
		return fmt.Errorf("demote provider profiles without active trusted hardware identities: %w", err)
	}
	return nil
}

func trustKey(providerID, hardwareIdentityHash string) string {
	return providerID + string(rune(31)) + hardwareIdentityHash
}
