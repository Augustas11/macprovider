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
	runTimeout        = 15 * time.Second
)

type inventory struct {
	Chips     map[string]chipProfile     `yaml:"chips"`
	Providers map[string]providerProfile `yaml:"providers"`
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

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

type options struct {
	configPath string
	dsn        string
	dryRun     bool
	stdout     io.Writer
}

func main() {
	var opts options
	flag.StringVar(&opts.configPath, "config", defaultConfigPath, "operator hardware inventory YAML")
	flag.StringVar(&opts.dsn, "dsn", "", "Postgres DSN; defaults to STATS_INVENTORY_DSN")
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
		fmt.Fprintf(out, "validated %d chip profiles and %d provider profiles\n", len(inv.Chips), len(inv.Providers))
		return nil
	}

	dsn := strings.TrimSpace(opts.dsn)
	if dsn == "" {
		dsn = strings.TrimSpace(os.Getenv(dsnEnvName))
	}
	if dsn == "" {
		return fmt.Errorf("postgres dsn is required via --dsn or %s", dsnEnvName)
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
	fmt.Fprintf(out, "upserted %d chip profiles and %d provider profiles\n", len(inv.Chips), len(inv.Providers))
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
	if len(inv.Providers) == 0 {
		return errors.New("inventory must define at least one provider profile")
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

func normalizedSource(source string) string {
	source = strings.TrimSpace(source)
	if source == "" {
		return "operator"
	}
	return source
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
   AND NOT (provider_id = ANY($1))`,
		pq.Array(providerIDs),
	); err != nil {
		return fmt.Errorf("unverify removed operator providers: %w", err)
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
