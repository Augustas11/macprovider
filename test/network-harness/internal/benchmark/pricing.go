package benchmark

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Pricing is a tier-2 pricing manifest loaded for B6 (earnings/hr).
// The on-disk schema is the operator-facing tier2-catalog.json at
// /opt/macprovider/tier2-catalog.json on Pearl. v0.1 expects an array
// of entries with model + per-1k token prices; unknown shapes are
// reported via Notes rather than failing the run.
type Pricing struct {
	// Source is the path or "host:path" the manifest came from. Echoed
	// into benchmark_summary.json for traceability.
	Source string

	// ByModel is the normalized lookup: model id → per-1k token prices.
	ByModel map[string]ModelPrice

	// UnknownModels is filled by EarningsFor when a request hits a model
	// not in the manifest. Triage may use this to spot stale pricing.
	UnknownModels map[string]int

	// Notes accumulates structural surprises (extra fields, malformed
	// entries) the loader skipped over.
	Notes []string
}

// ModelPrice is the per-1000-token cost of one tier-2 model. USD.
type ModelPrice struct {
	ModelID              string  `json:"model"`
	PromptPricePer1k     float64 `json:"price_per_1k_prompt_tokens"`
	CompletionPricePer1k float64 `json:"price_per_1k_completion_tokens"`
}

// rawCatalogEntry is the JSON-side mirror. Kept separate so we can grow
// the manifest schema (e.g. tier identifiers, hash fields) without
// forcing pricing math to know about them.
type rawCatalogEntry struct {
	Model              string  `json:"model"`
	ModelID            string  `json:"model_id"`
	PromptPer1k        float64 `json:"price_per_1k_prompt_tokens"`
	CompletionPer1k    float64 `json:"price_per_1k_completion_tokens"`
	PromptPer1kAlt     float64 `json:"prompt_per_1k"`
	CompletionPer1kAlt float64 `json:"completion_per_1k"`
}

// LoadPricing reads a tier-2 pricing manifest from a local path or
// from an "host:/path" SSH spec. Returns nil + error on hard failures
// (cannot read, file invalid); returns a partial Pricing with Notes
// when entries were skipped but at least one was loaded.
//
// Two source formats are supported, distinguished by file extension:
//
//   - *.json  → manifest file with per-1k USD rates (array, {models:[...]},
//     or {model_id:{...}} shape).
//   - *.yaml  → coordinator config file. The loader parses rewards.rate_card,
//   - *.yml      rewards.global_multiplier, rewards.provider_share, and
//     stats.rollup.usd_per_million_credits, then derives provider-
//     net USD/1k rates per the credits → USD formula. This is the
//     recommended form for production runs — pricing tracks
//     whatever the coordinator is actually settling against,
//     eliminating drift from a parallel JSON manifest (issue #223).
func LoadPricing(source string) (*Pricing, error) {
	if source == "" {
		return nil, fmt.Errorf("empty pricing source")
	}
	var data []byte
	var err error
	if strings.Contains(source, ":") && !strings.HasPrefix(source, "/") {
		data, err = fetchSSH(source)
	} else {
		data, err = os.ReadFile(source)
	}
	if err != nil {
		return nil, fmt.Errorf("read pricing source %q: %w", source, err)
	}
	switch strings.ToLower(filepath.Ext(stripSSHPath(source))) {
	case ".yaml", ".yml":
		return parseCoordConfig(source, data)
	default:
		return parsePricing(source, data)
	}
}

// stripSSHPath returns the path component of a "host:/path" SSH spec,
// or the source unchanged when it's already a local path. Used to
// extension-sniff the remote file's name.
func stripSSHPath(source string) string {
	if strings.Contains(source, ":") && !strings.HasPrefix(source, "/") {
		if idx := strings.Index(source, ":"); idx >= 0 {
			return source[idx+1:]
		}
	}
	return source
}

func parsePricing(source string, data []byte) (*Pricing, error) {
	p := &Pricing{
		Source:        source,
		ByModel:       map[string]ModelPrice{},
		UnknownModels: map[string]int{},
	}

	// Try array shape first: [{model, price_per_1k_*}, ...].
	var arr []rawCatalogEntry
	if err := json.Unmarshal(data, &arr); err == nil && len(arr) > 0 {
		for i, e := range arr {
			id, mp, ok := normalizeEntry(e)
			if !ok {
				p.Notes = append(p.Notes, fmt.Sprintf("entry %d: missing model or zero prices, skipped", i))
				continue
			}
			p.ByModel[id] = mp
		}
		if len(p.ByModel) == 0 {
			return nil, fmt.Errorf("pricing manifest %q parsed as array but yielded no usable entries", source)
		}
		return p, nil
	}

	// Try object-shape wrapper: {"models": [...]}.
	var wrapped struct {
		Models []rawCatalogEntry `json:"models"`
	}
	if err := json.Unmarshal(data, &wrapped); err == nil && len(wrapped.Models) > 0 {
		for i, e := range wrapped.Models {
			id, mp, ok := normalizeEntry(e)
			if !ok {
				p.Notes = append(p.Notes, fmt.Sprintf("models[%d]: missing model or zero prices, skipped", i))
				continue
			}
			p.ByModel[id] = mp
		}
		if len(p.ByModel) == 0 {
			return nil, fmt.Errorf("pricing manifest %q parsed as {models:[...]} but yielded no usable entries", source)
		}
		return p, nil
	}

	// Try map shape: {"model-id": {price_per_1k_*}, ...}.
	var m map[string]rawCatalogEntry
	if err := json.Unmarshal(data, &m); err == nil && len(m) > 0 {
		for k, e := range m {
			e.Model = k
			id, mp, ok := normalizeEntry(e)
			if !ok {
				p.Notes = append(p.Notes, fmt.Sprintf("%s: missing model or zero prices, skipped", k))
				continue
			}
			p.ByModel[id] = mp
		}
		if len(p.ByModel) == 0 {
			return nil, fmt.Errorf("pricing manifest %q parsed as map but yielded no usable entries", source)
		}
		return p, nil
	}

	return nil, fmt.Errorf("pricing manifest %q: unrecognized JSON shape", source)
}

func normalizeEntry(e rawCatalogEntry) (string, ModelPrice, bool) {
	id := e.Model
	if id == "" {
		id = e.ModelID
	}
	if id == "" {
		return "", ModelPrice{}, false
	}
	prompt := e.PromptPer1k
	if prompt == 0 {
		prompt = e.PromptPer1kAlt
	}
	completion := e.CompletionPer1k
	if completion == 0 {
		completion = e.CompletionPer1kAlt
	}
	if prompt == 0 && completion == 0 {
		return "", ModelPrice{}, false
	}
	return id, ModelPrice{
		ModelID:              id,
		PromptPricePer1k:     prompt,
		CompletionPricePer1k: completion,
	}, true
}

// EarningsFor returns the USD earnings for one request given the model
// and token counts. Falls back to the "default" entry (matching coord's
// RateFor in billing/formula.go) when the specific model isn't priced.
// Unknown models that don't match the default either contribute zero
// and are recorded in UnknownModels so B6 verdict detail can call them out.
func (p *Pricing) EarningsFor(model string, promptTokens, completionTokens int64) float64 {
	if p == nil || model == "" {
		return 0
	}
	mp, ok := p.ByModel[model]
	if !ok {
		if def, hasDefault := p.defaultEntry(); hasDefault {
			mp = def
		} else {
			p.UnknownModels[model]++
			return 0
		}
	}
	return float64(promptTokens)*mp.PromptPricePer1k/1000.0 +
		float64(completionTokens)*mp.CompletionPricePer1k/1000.0
}

// coordYAML is the minimal subset of coordinator.yaml the pricing
// loader needs. Fields not declared here are silently ignored by the
// YAML decoder — full forward compatibility with future coord-config
// growth.
type coordYAML struct {
	Rewards struct {
		GlobalMultiplier float64                       `yaml:"global_multiplier"`
		ProviderShare    float64                       `yaml:"provider_share"`
		RateCard         map[string]coordRateCardEntry `yaml:"rate_card"`
	} `yaml:"rewards"`
	Stats struct {
		Rollup struct {
			UsdPerMillionCredits float64 `yaml:"usd_per_million_credits"`
		} `yaml:"rollup"`
	} `yaml:"stats"`
}

type coordRateCardEntry struct {
	PromptCreditsPerMtok     int64 `yaml:"prompt_credits_per_mtok"`
	CompletionCreditsPerMtok int64 `yaml:"completion_credits_per_mtok"`
}

// parseCoordConfig converts coordinator.yaml into a Pricing manifest.
//
// Provider-net USD per 1k tokens is derived as:
//
//	usd_per_1k = credits_per_mtok / 1e6 × 1000           // credits per 1k tokens
//	           × global_multiplier
//	           × provider_share
//	           × usd_per_million_credits / 1e6           // credits → USD
//	          = credits_per_mtok × multiplier × share × usd_per_million_credits / 1e9
//
// The math mirrors `billing/formula.go` (gross credits) + `stats/rollup`
// (credits → USD). When yaml omits a field, the canonical coord defaults
// from `phase4-coordinator/internal/config/config.go:528-537` apply,
// so the manifest matches what coord would actually settle against.
//
// When the yaml has no `rate_card` map at all, the loader synthesizes a
// single "default" entry from coord's default credits-per-Mtok values.
// The result Notes the synthesis so triage can see this happened.
func parseCoordConfig(source string, data []byte) (*Pricing, error) {
	var cfg coordYAML
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("coord config %q: yaml parse: %w", source, err)
	}

	p := &Pricing{
		Source:        source,
		ByModel:       map[string]ModelPrice{},
		UnknownModels: map[string]int{},
	}

	// Apply coord defaults to any unset fields. See
	// phase4-coordinator/internal/config/config.go Default() (~line 528).
	multiplier := cfg.Rewards.GlobalMultiplier
	if multiplier == 0 {
		multiplier = 1.0
		p.Notes = append(p.Notes, "rewards.global_multiplier unset; applying coord default 1.0")
	}
	share := cfg.Rewards.ProviderShare
	if share == 0 {
		share = 0.90
		p.Notes = append(p.Notes, "rewards.provider_share unset; applying coord default 0.90")
	}
	usdPerMcredit := cfg.Stats.Rollup.UsdPerMillionCredits
	if usdPerMcredit == 0 {
		usdPerMcredit = 1.0
		p.Notes = append(p.Notes, "stats.rollup.usd_per_million_credits unset; applying coord default 1.0")
	}

	rateCard := cfg.Rewards.RateCard
	if len(rateCard) == 0 {
		rateCard = map[string]coordRateCardEntry{
			"default": {
				PromptCreditsPerMtok:     500_000,
				CompletionCreditsPerMtok: 1_000_000,
			},
		}
		p.Notes = append(p.Notes,
			"rewards.rate_card unset; applying coord default {500k prompt / 1M completion credits per Mtok}")
	}

	const creditsToUSDDenom = 1e9 // credits-per-Mtok × multiplier × share × usd-per-Mcredit / 1e9 = USD per 1k tokens
	for model, entry := range rateCard {
		if entry.PromptCreditsPerMtok == 0 && entry.CompletionCreditsPerMtok == 0 {
			p.Notes = append(p.Notes, fmt.Sprintf("rate_card[%q]: both credits-per-mtok are zero, skipped", model))
			continue
		}
		prompt := float64(entry.PromptCreditsPerMtok) * multiplier * share * usdPerMcredit / creditsToUSDDenom
		completion := float64(entry.CompletionCreditsPerMtok) * multiplier * share * usdPerMcredit / creditsToUSDDenom
		p.ByModel[model] = ModelPrice{
			ModelID:              model,
			PromptPricePer1k:     prompt,
			CompletionPricePer1k: completion,
		}
	}

	if len(p.ByModel) == 0 {
		return nil, fmt.Errorf("coord config %q: no usable rate_card entries after derivation", source)
	}
	return p, nil
}

// EarningsForUnknownModelDefault returns the per-1k USD price the
// loader applies for a model not explicitly listed in the rate_card,
// using the "default" entry if present. This mirrors coord's RateFor
// fallback behavior (phase4-coordinator/internal/billing/formula.go:34)
// so unknown-to-the-manifest models in benchmark results still earn
// the correct USD instead of contributing zero.
func (p *Pricing) defaultEntry() (ModelPrice, bool) {
	if p == nil {
		return ModelPrice{}, false
	}
	mp, ok := p.ByModel["default"]
	return mp, ok
}

// fetchSSH reads a remote file via `ssh host cat /path`. Mirrors the
// reconcile.sshCat helper but emits to a buffer rather than disk —
// the pricing manifest is small enough for in-memory parsing.
func fetchSSH(spec string) ([]byte, error) {
	colon := strings.Index(spec, ":")
	if colon < 0 {
		return nil, fmt.Errorf("ssh spec must be host:/path (got %q)", spec)
	}
	host := spec[:colon]
	remote := spec[colon+1:]
	if host == "" || remote == "" {
		return nil, fmt.Errorf("ssh spec missing host or path: %q", spec)
	}
	cmd := exec.Command("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, fmt.Sprintf("cat %q", remote))
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ssh fetch failed: %w (stderr: %s)", err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}
