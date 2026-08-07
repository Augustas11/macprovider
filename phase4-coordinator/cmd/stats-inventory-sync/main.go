package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
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
	// demotionBudget bounds the trust-demotion sweep on its OWN context, derived
	// from the parent rather than the shared run context (issue #582 FIX 5). A
	// blackholed trust DSN can exhaust the shared runTimeout during trust
	// reconciliation; demotion must still get to run so an API-revoked root is
	// not left effective forever. Total runtime stays bounded by
	// runTimeout + demotionBudget.
	demotionBudget = 10 * time.Second
)

// demotionContext derives an independent, bounded context for the trust
// demotion sweep (issue #582 FIX 5). context.WithoutCancel drops the parent's
// cancellation/deadline so a run context already exhausted by a blackholed
// trust DSN cannot starve demotion; WithTimeout then re-bounds it.
func demotionContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(parent), demotionBudget)
}

type inventory struct {
	Chips           map[string]chipProfile     `yaml:"chips"`
	Providers       map[string]providerProfile `yaml:"providers"`
	TrustedHardware trustedHardware            `yaml:"trusted_hardware"`
}

// trustedHardware distinguishes an ABSENT trusted_hardware section (Present=false
// → leave every hardware_verification_trust root untouched, the pre-#582 no-op)
// from an explicitly-written one — including an explicitly empty
// `trusted_hardware: {}` (Present=true, Entries empty → revoke every
// source='inventory' root). yaml.v3 only invokes UnmarshalYAML when the key is
// present in the document, so Present flips exactly when the operator writes the
// key, regardless of whether the value is a map, empty map, or null (issue #582
// FIX 2). A bare `map` field could not tell an absent section from `{}`.
type trustedHardware struct {
	Present bool
	Entries map[string][]trustedHardwareIdentity
}

func (t *trustedHardware) UnmarshalYAML(value *yaml.Node) error {
	t.Present = true
	// FIX 3(b) (issue #582): revoke-all is reserved for an EXPLICIT empty mapping
	// (`trusted_hardware: {}`). A bare `trusted_hardware:` (YAML null), a scalar,
	// or a sequence must not be silently treated as present-with-nil (which would
	// trigger revoke-all). Require a non-null mapping node.
	if value.Kind != yaml.MappingNode {
		return errors.New("trusted_hardware must be a mapping (use {} for explicit revoke-all)")
	}
	// FIX 3(a) (issue #582): yaml.Node.Decode does NOT inherit the outer
	// decoder's KnownFields(true), so a nested typo like `expires_att` under an
	// identity would be silently dropped — turning an intended temporary trust
	// into permanent trust. Re-decode the mapping through a strict decoder so
	// unknown nested keys are a hard error.
	raw, err := yaml.Marshal(value)
	if err != nil {
		return err
	}
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	dec.KnownFields(true)
	entries := map[string][]trustedHardwareIdentity{}
	if err := dec.Decode(&entries); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	t.Entries = entries
	return nil
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

type rowScanner interface {
	Scan(...any) error
}

type options struct {
	configPath   string
	dsn          string
	trustDSN     string
	requireChips string
	dryRun       bool
	stdout       io.Writer
}

func main() {
	var opts options
	flag.StringVar(&opts.configPath, "config", defaultConfigPath, "operator hardware inventory YAML")
	flag.StringVar(&opts.dsn, "dsn", "", "Postgres DSN; defaults to STATS_INVENTORY_DSN")
	flag.StringVar(&opts.trustDSN, "trust-dsn", "", "Postgres trust-root DSN; defaults to STATS_TRUST_INVENTORY_DSN")
	flag.StringVar(&opts.requireChips, "require-chips", "", "comma-separated chip_normalized values that must be present in the inventory YAML")
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
	if err := validateRequiredChips(inv, opts.requireChips); err != nil {
		return err
	}
	if opts.dryRun {
		fmt.Fprintf(out, "validated %d chip profiles, %d provider profiles, and %d trusted hardware identities\n",
			len(inv.Chips), len(inv.Providers), trustedHardwareCount(inv.TrustedHardware.Entries))
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
	// The trust DSN is required only when the YAML actually writes the
	// trusted_hardware section (present, populated or explicitly empty): an
	// explicitly-empty section revokes the last source='inventory' roots via
	// applyTrustInventory's scoped DELETE, which needs the trust-writer role. When
	// the section is OMITTED, trust reconciliation is skipped entirely so the trust
	// DSN is not needed (issue #582 FIX 2).
	if inv.TrustedHardware.Present && trustDSN == "" {
		return fmt.Errorf("trust postgres dsn is required via --trust-dsn or %s when trusted_hardware is set", trustDSNEnvName)
	}

	ctx, cancel := context.WithTimeout(parent, runTimeout)
	defer cancel()

	db, err := openPostgresDB(dsn, "inventory")
	if err != nil {
		return err
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
	queryRow := func(ctx context.Context, query string, args ...any) rowScanner {
		return db.QueryRowContext(ctx, query, args...)
	}
	demoteTrust := func(demotionCtx context.Context) error {
		return reconcileTrustDemotions(demotionCtx, db)
	}
	if err := finishCommittedInventory(parent, ctx, inv, trustDSN, queryRow, reconcileTrustInventory, demoteTrust); err != nil {
		return err
	}

	fmt.Fprintf(out, "upserted %d chip profiles, %d provider profiles, and %d trusted hardware identities\n",
		len(inv.Chips), len(inv.Providers), trustedHardwareCount(inv.TrustedHardware.Entries))
	return nil
}

func finishCommittedInventory(
	parent context.Context,
	ctx context.Context,
	inv inventory,
	trustDSN string,
	queryRow func(context.Context, string, ...any) rowScanner,
	reconcileTrust func(context.Context, string, inventory) error,
	demoteTrust func(context.Context) error,
) error {
	// Reconcile trust inventory ONLY when the trusted_hardware section is present
	// (issue #582 FIX 2). Omitted → skip reconciliation entirely (no DELETE, all
	// roots preserved — the pre-#582 no-op). Present (populated or explicitly
	// empty `{}`) → applyTrustInventory upserts the listed roots and its scoped
	// DELETE removes every other source='inventory' root, so an explicit empty
	// section revokes them all. operator_api roots are always untouched
	// (source-scoped). This runs before chip verification so a slow catalog read
	// cannot consume the shared run context and strand explicitly removed trust
	// roots.
	var trustErr error
	if inv.TrustedHardware.Present {
		trustErr = reconcileTrust(ctx, trustDSN, inv)
	}
	verifyErr := verifyInventoryApplied(ctx, queryRow, inv)

	// Demotions ALWAYS run, even if chip verification or the trust-inventory apply
	// above failed (issue #582 FIX 3): a broken catalog read or trust-writer DSN
	// must not strand an API-revoked root as verified. Attempt demotion against the
	// last-committed trust state and aggregate every error. An expired or revoked
	// operator_api trust root (or any stale non-authoritative verified profile —
	// cli_hello or app_register) is demoted independent of whether the YAML defines
	// trusted_hardware.
	//
	// FIX 5: demotion runs on its OWN budget derived from the parent, not the
	// shared run context. A blackholed trust DSN can exhaust `ctx` during trust
	// reconciliation above; without an independent context, demotion would run
	// with an already-cancelled context and execute no SQL, leaving a revoked
	// root effective forever.
	demotionCtx, demotionCancel := demotionContext(parent)
	defer demotionCancel()
	demoteErr := demoteTrust(demotionCtx)
	return errors.Join(verifyErr, trustErr, demoteErr)
}

// reconcileTrustInventory opens the trust-writer handle and applies the
// trusted_hardware section in its own transaction. Only called when the section
// is present (issue #582 FIX 2).
func reconcileTrustInventory(ctx context.Context, trustDSN string, inv inventory) error {
	trustDB, err := openPostgresDB(trustDSN, "trust inventory")
	if err != nil {
		return err
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
	committed := false
	defer func() {
		if !committed {
			_ = trustTX.Rollback()
		}
	}()
	if err := applyTrustInventory(ctx, trustTX, inv); err != nil {
		return err
	}
	if err := trustTX.Commit(); err != nil {
		return fmt.Errorf("commit trust inventory transaction: %w", err)
	}
	committed = true
	return nil
}

func openPostgresDB(dsn, name string) (*sql.DB, error) {
	dsn = strings.TrimSpace(dsn)
	if dsn == "" {
		return nil, fmt.Errorf("%s postgres dsn is required", name)
	}
	connector, err := pq.NewConnector(dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s postgres: invalid connection string (redacted)", name)
	}
	db := sql.OpenDB(connector)
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	return db, nil
}

// reconcileTrustDemotions runs the demotion sweep in its own transaction on the
// inventory-writer handle (issue #582 FIX 3).
func reconcileTrustDemotions(ctx context.Context, db *sql.DB) error {
	demotionTX, err := db.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin trust demotion transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = demotionTX.Rollback()
		}
	}()
	if err := applyTrustDemotions(ctx, demotionTX); err != nil {
		return err
	}
	if err := demotionTX.Commit(); err != nil {
		return fmt.Errorf("commit trust demotion transaction: %w", err)
	}
	committed = true
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
	// FIX 3(b) (issue #582): yaml.v3 does NOT invoke trustedHardware.UnmarshalYAML
	// for a null value node, so a bare `trusted_hardware:` (YAML null) would
	// silently decode as absent (Present=false) rather than as the reserved
	// explicit revoke-all. Inspect the document tree up front and reject a
	// present-but-non-mapping trusted_hardware (null/scalar/sequence); revoke-all
	// is reserved for an explicit `{}` mapping. Scalars/sequences are also caught
	// by UnmarshalYAML's own mapping check, but null must be caught here because
	// UnmarshalYAML never runs for it.
	if err := ensureTrustedHardwareMapping(raw); err != nil {
		return inventory{}, err
	}
	var inv inventory
	dec := yaml.NewDecoder(strings.NewReader(string(raw)))
	dec.KnownFields(true)
	if err := dec.Decode(&inv); err != nil {
		return inventory{}, fmt.Errorf("parse inventory config: %w", err)
	}
	return inv, nil
}

// ensureTrustedHardwareMapping rejects a present-but-non-mapping trusted_hardware
// value (null/scalar/sequence) at the document level (issue #582 FIX 3(b)). It
// returns nil on parse errors so the strict decode in loadInventory surfaces the
// richer message.
func ensureTrustedHardwareMapping(raw []byte) error {
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) == 0 {
		return nil
	}
	root := doc.Content[0]
	if root.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(root.Content); i += 2 {
		if root.Content[i].Value != "trusted_hardware" {
			continue
		}
		if root.Content[i+1].Kind != yaml.MappingNode {
			return errors.New("trusted_hardware must be a mapping (use {} for explicit revoke-all)")
		}
	}
	return nil
}

func validateInventory(inv inventory) error {
	if len(inv.Chips) == 0 {
		return errors.New("inventory must define at least one chip profile")
	}
	if len(inv.Providers) == 0 && !inv.TrustedHardware.Present {
		return errors.New("inventory must define at least one provider profile or a trusted_hardware section")
	}
	if inv.Providers != nil && len(inv.Providers) == 0 {
		return errors.New("providers must define at least one provider; omit the section to leave provider profiles untouched")
	}
	// trusted_hardware: an ABSENT section (Present=false) leaves every trust root
	// untouched; an explicitly-empty section (`trusted_hardware: {}`) is the
	// deliberate revoke-all-inventory-roots signal and is accepted (issue #582
	// FIX 2). Only malformed non-empty entries are rejected below.
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
	for providerID, identities := range inv.TrustedHardware.Entries {
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

func validateRequiredChips(inv inventory, required string) error {
	required = strings.TrimSpace(required)
	if required == "" {
		return nil
	}
	for _, raw := range strings.Split(required, ",") {
		key := normalizedChipKey(raw)
		if key == "" {
			return errors.New("required chip key is empty")
		}
		if _, ok := inv.Chips[key]; !ok {
			return fmt.Errorf("missing required chip profile %q in inventory YAML; add chips[%q] before retrying hardware trust approval", key, key)
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

func verifyInventoryApplied(ctx context.Context, queryRow func(context.Context, string, ...any) rowScanner, inv inventory) error {
	chipKeys := make([]string, 0, len(inv.Chips))
	for key := range inv.Chips {
		chipKeys = append(chipKeys, key)
	}
	sort.Strings(chipKeys)
	for _, key := range chipKeys {
		want := inv.Chips[key]
		var gotDisplay string
		var gotBandwidth int64
		var gotPower float64
		var gotGPU, gotCPU int
		err := queryRow(ctx, `
SELECT display_chip, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores
  FROM chip_hardware_profiles
 WHERE chip_normalized = $1`, key).Scan(&gotDisplay, &gotBandwidth, &gotPower, &gotGPU, &gotCPU)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("verify chip %q: missing from chip_hardware_profiles after inventory sync", key)
		}
		if err != nil {
			return fmt.Errorf("verify chip %q: %w", key, err)
		}
		if gotDisplay != strings.TrimSpace(want.DisplayChip) ||
			gotBandwidth != want.MemoryBandwidthGBPerS ||
			math.Abs(gotPower-want.NetworkPowerKW) > 1e-9 ||
			gotGPU != want.GPUCores ||
			gotCPU != want.CPUCores {
			return fmt.Errorf("verify chip %q: database row does not match inventory YAML", key)
		}
	}
	return nil
}

func applyTrustInventory(ctx context.Context, db execer, inv inventory) error {
	trustedKeys := make([]string, 0, trustedHardwareCount(inv.TrustedHardware.Entries))
	providerIDs := make([]string, 0, len(inv.TrustedHardware.Entries))
	for providerID := range inv.TrustedHardware.Entries {
		providerIDs = append(providerIDs, providerID)
	}
	sort.Strings(providerIDs)
	for _, providerID := range providerIDs {
		identities := append([]trustedHardwareIdentity(nil), inv.TrustedHardware.Entries[providerID]...)
		sort.Slice(identities, func(i, j int) bool {
			return identities[i].HardwareIdentityHash < identities[j].HardwareIdentityHash
		})
		for _, identity := range identities {
			expiresAt, err := parseOptionalExpiresAt(identity.ExpiresAt)
			if err != nil {
				return fmt.Errorf("parse trusted_hardware provider %q expires_at: %w", providerID, err)
			}
			trustedKeys = append(trustedKeys, trustKey(providerID, identity.HardwareIdentityHash))
			// The trust table PK is (provider_id, hardware_identity_hash, source)
			// (migration 019), so this ON CONFLICT target isolates the inventory row:
			// it can only ever match the existing source='inventory' row for the tuple
			// and never an operator_api row (which is an independent row). The former
			// WHERE hardware_verification_trust.source = 'inventory' DO UPDATE guard is
			// therefore redundant and removed — the 3-column conflict target already
			// guarantees the upsert touches only this authority's own row (issue #582).
			if _, err := db.ExecContext(ctx, `
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb,
    trusted_by, expires_at, notes, source
) VALUES (
    $1, $2, $3, $4, $5, $6, $7, 'inventory'
)
ON CONFLICT (provider_id, hardware_identity_hash, source) DO UPDATE
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
 WHERE source = 'inventory'
   AND NOT ((provider_id || chr(31) || hardware_identity_hash) = ANY($1))`,
		pq.Array(trustedKeys),
	); err != nil {
		return fmt.Errorf("delete removed trusted hardware identities: %w", err)
	}
	return nil
}

func applyTrustDemotions(ctx context.Context, db execer) error {
	// Step 1 — lock every candidate verified, non-authoritative profile row
	// FOR UPDATE (issue #582 FIX 3). The verifier's promoteJob upserts
	// provider_hardware_profiles (setting verified=TRUE) under a row lock, so this
	// lock BLOCKS until any in-flight promotion of a candidate row commits. Taking
	// the lock in a separate statement means step 2 runs under a fresh READ
	// COMMITTED snapshot that observes those committed promotions — without this,
	// step 2's NOT EXISTS could evaluate against a pre-promotion snapshot and
	// re-demote a profile the verifier just promoted.
	if _, err := db.ExecContext(ctx, `
SELECT provider_id
  FROM provider_hardware_profiles
 WHERE verified = TRUE
   AND source <> 'operator'
 FOR UPDATE`); err != nil {
		return fmt.Errorf("lock demotion candidate profiles: %w", err)
	}

	// Step 2 — demote EVERY verified profile whose active trusted-hardware root no
	// longer matches, across all non-authoritative sources (cli_hello AND
	// app_register), not just cli_hello. The only authoritative operator-set
	// source is 'operator' (rows the operator YAML asserts verified directly and
	// reconciles itself via applyInventory), so it is the sole exemption. Using
	// NOT 'operator' is fail-safe: any future non-authoritative source is demoted
	// by default when it lacks active trust. provider_hardware_profiles.source is
	// CHECK-constrained to ('app_register','cli_hello','operator') by migration 007.
	// The rows this statement re-reads are already locked from step 1, so it
	// serializes against the verifier's promoteJob profile UPDATE (issue #582).
	if _, err := db.ExecContext(ctx, `
UPDATE provider_hardware_profiles ph
   SET verified = FALSE
 WHERE ph.verified = TRUE
   AND ph.source <> 'operator'
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
