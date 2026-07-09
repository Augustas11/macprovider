package autotune

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

const candidateCatalogSource = "operator_curated_autotune_candidate_catalog"

type BenchGate struct {
	MinSustainedTPS float64 `json:"min_sustained_tps"`
	Max4KTTFTMS     int     `json:"max_4k_ttft_ms"`
}

type Row struct {
	ModelID          string    `json:"model_id"`
	ModelRevision    string    `json:"model_revision,omitempty"`
	ModelSHA256      string    `json:"model_sha256,omitempty"`
	MinRAMGB         int       `json:"min_ram_gb"`
	MinBandwidthTier string    `json:"min_bandwidth_tier"`
	BenchGate        BenchGate `json:"bench_gate"`
	RuntimeStatus    string    `json:"runtime_status"`
}

type Catalog struct {
	Version    string
	SHA256     string
	RawJSON    []byte
	rowsByKey  map[string]Row
	keysByModel map[string][]string
}

func ParseCatalog(rawJSON []byte) (*Catalog, error) {
	if len(rawJSON) == 0 {
		return nil, fmt.Errorf("autotune candidate catalog is empty")
	}
	var envelope struct {
		Version string          `json:"version"`
		Source  string          `json:"source"`
		Rows    map[string]Row  `json:"rows"`
	}
	if err := json.Unmarshal(rawJSON, &envelope); err != nil {
		return nil, fmt.Errorf("parse autotune candidate catalog: %w", err)
	}
	if envelope.Source != candidateCatalogSource {
		return nil, fmt.Errorf("autotune candidate catalog source must be %q", candidateCatalogSource)
	}
	if strings.TrimSpace(envelope.Version) == "" {
		return nil, fmt.Errorf("autotune candidate catalog version is required")
	}
	if len(envelope.Rows) == 0 {
		return nil, fmt.Errorf("autotune candidate catalog rows are required")
	}
	sum := sha256.Sum256(rawJSON)
	keysByModel := make(map[string][]string, len(envelope.Rows))
	for key, row := range envelope.Rows {
		key = strings.TrimSpace(key)
		if key == "" {
			return nil, fmt.Errorf("autotune candidate catalog row key is required")
		}
		if strings.TrimSpace(row.ModelID) == "" {
			return nil, fmt.Errorf("autotune candidate catalog row %q model_id is required", key)
		}
		if row.MinRAMGB < 0 {
			return nil, fmt.Errorf("autotune candidate catalog row %q min_ram_gb must be >= 0", key)
		}
		if math.IsNaN(row.BenchGate.MinSustainedTPS) || math.IsInf(row.BenchGate.MinSustainedTPS, 0) || row.BenchGate.MinSustainedTPS < 0 {
			return nil, fmt.Errorf("autotune candidate catalog row %q min_sustained_tps is invalid", key)
		}
		if row.BenchGate.Max4KTTFTMS < 0 {
			return nil, fmt.Errorf("autotune candidate catalog row %q max_4k_ttft_ms must be >= 0", key)
		}
		normalizedModelID := normalizeModelID(row.ModelID)
		keysByModel[normalizedModelID] = append(keysByModel[normalizedModelID], key)
	}
	return &Catalog{
		Version:     envelope.Version,
		SHA256:      hex.EncodeToString(sum[:]),
		RawJSON:     append([]byte(nil), rawJSON...),
		rowsByKey:   envelope.Rows,
		keysByModel: keysByModel,
	}, nil
}

func (c *Catalog) Row(key string) (Row, bool) {
	if c == nil {
		return Row{}, false
	}
	row, ok := c.rowsByKey[key]
	return row, ok
}

func (c *Catalog) HighestClaimedTier(modelID string) (key string, row Row, ok bool) {
	if c == nil {
		return "", Row{}, false
	}
	normalized := normalizeModelID(modelID)
	if row, ok := c.rowsByKey[normalized]; ok {
		return normalized, row, true
	}
	keys := c.keysByModel[normalized]
	if len(keys) == 0 {
		return "", Row{}, false
	}
	bestKey := keys[0]
	bestRow := c.rowsByKey[bestKey]
	for _, candidateKey := range keys[1:] {
		candidate := c.rowsByKey[candidateKey]
		if candidate.MinRAMGB > bestRow.MinRAMGB {
			bestKey = candidateKey
			bestRow = candidate
		}
	}
	return bestKey, bestRow, true
}

func normalizeModelID(modelID string) string {
	return strings.ToLower(strings.TrimSpace(modelID))
}
