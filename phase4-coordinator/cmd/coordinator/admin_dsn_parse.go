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
