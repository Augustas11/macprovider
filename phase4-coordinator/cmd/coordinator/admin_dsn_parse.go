package main

// parseAdminDSNFromYAML reads just the
// `stats.partner_keys_admin_dsn` field from a YAML file,
// bypassing full daemon-side `config.Validate()` (which requires
// auth.operator_key etc. that the operator running the CLI
// might not have set in a trimmed admin-only file).
//
// The CLI accepts EITHER a full coordinator.yaml OR a minimal:
//
//	stats:
//	  partner_keys_admin_dsn: "postgres://..."
//
// The strict-yaml parse rejects malformed input cleanly so an
// operator typo doesn't silently fall through to "empty DSN".

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// parseAdminDSNFromYAML returns the value of
// `stats.partner_keys_admin_dsn`. Returns "" if the field is
// absent or empty; the caller treats both as "operator has not
// configured the DSN" and surfaces the appropriate error.
func parseAdminDSNFromYAML(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var trimmed struct {
		Stats struct {
			PartnerKeysAdminDSN string `yaml:"partner_keys_admin_dsn"`
		} `yaml:"stats"`
	}
	if err := yaml.Unmarshal(b, &trimmed); err != nil {
		return "", fmt.Errorf("yaml parse: %w", err)
	}
	if trimmed.Stats.PartnerKeysAdminDSN == "" {
		return "", errors.New("stats.partner_keys_admin_dsn missing")
	}
	return trimmed.Stats.PartnerKeysAdminDSN, nil
}

// parseProductionSignoffPathFromYAML reads
// `stats.partner_keys.production_signoff_path` from the same
// coordinator YAML the admin DSN comes from.
//
// Final adversarial audit (ARCH r3 + CODE r3 CRITICAL closure):
// the sign-off gate moved from opt-in CLI flag to config-driven
// so a wrapper-script that forgets a flag cannot bypass. The
// coordinator config is the source of truth for "is this
// coordinator production"; the deployed config carries this
// path when (and only when) the deploy is production. Returns
// "" if absent.
func parseProductionSignoffPathFromYAML(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var trimmed struct {
		Stats struct {
			PartnerKeys struct {
				ProductionSignoffPath string `yaml:"production_signoff_path"`
			} `yaml:"partner_keys"`
		} `yaml:"stats"`
	}
	if err := yaml.Unmarshal(b, &trimmed); err != nil {
		return "", fmt.Errorf("yaml parse: %w", err)
	}
	return strings.TrimSpace(trimmed.Stats.PartnerKeys.ProductionSignoffPath), nil
}
