package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"gopkg.in/yaml.v3"
)

// autotuneReleaseValidationOptions are the pricing-lane extensions of
// --validate-autotune-release (SPEC-023-R018).
type autotuneReleaseValidationOptions struct {
	// ExpectBaseEquivalent is the live base config path. The --config
	// candidate must equal it as a YAML node tree everywhere except the
	// value of rewards.rate_card, and the candidate's own rewards.rate_card
	// must be the release's signed rows.
	ExpectBaseEquivalent string
	// ResolveModelNames is a JSON array of model names. Each is resolved with
	// RateFor against the live table (ExpectBaseEquivalent + --config-overlay)
	// and the candidate effective table.
	ResolveModelNames string
}

// maxResolveModelNamesBytes bounds the --resolve-model-names input.
const maxResolveModelNamesBytes = 16 << 20

type autotuneModelResolution struct {
	Name string               `json:"name"`
	Old  autotuneResolvedRate `json:"old"`
	New  autotuneResolvedRate `json:"new"`
}

// autotuneResolvedRate is the rate-card row RateFor bills a name at. RowKey
// is "" when the table has neither a matching row nor "default".
type autotuneResolvedRate struct {
	RowKey                       string `json:"row_key"`
	PromptCreditsPerMtok         int64  `json:"prompt_credits_per_mtok"`
	PromptCacheHitCreditsPerMtok int64  `json:"prompt_cache_hit_credits_per_mtok"`
	CompletionCreditsPerMtok     int64  `json:"completion_credits_per_mtok"`
}

func resolvedRate(table map[string]config.RateCardEntry, name string) autotuneResolvedRate {
	key, entry := billing.RateKeyFor(table, name)
	return autotuneResolvedRate{
		RowKey:                       key,
		PromptCreditsPerMtok:         entry.PromptCreditsPerMtok,
		PromptCacheHitCreditsPerMtok: entry.EffectivePromptCacheHitCreditsPerMtok(),
		CompletionCreditsPerMtok:     entry.CompletionCreditsPerMtok,
	}
}

// validatePricingRelease runs the pricing-lane checks for a candidate whose
// effective config (cfg) already passed runtime rate-card parity against feeds.
func validatePricingRelease(r *autotuneReleaseValidation, opts autotuneReleaseValidationOptions, configPath, configOverlay string, cfg config.Config, feeds buyer.AutotuneFeeds) {
	fail := func(format string, args ...any) { r.Errors = append(r.Errors, fmt.Sprintf(format, args...)) }
	if opts.ExpectBaseEquivalent != "" {
		live, err := loadSingleYAMLDocument(opts.ExpectBaseEquivalent)
		if err != nil {
			fail("expect-base-equivalent: live base: %v", err)
			return
		}
		candidate, err := loadSingleYAMLDocument(configPath)
		if err != nil {
			fail("expect-base-equivalent: candidate: %v", err)
			return
		}
		if path, same := yamlTreesEquivalentExceptRateCard(live, candidate); !same {
			fail("base_not_equivalent: %s", path)
		}
		rows, err := candidateRateCardRows(candidate)
		if err != nil {
			fail("candidate_rate_card_not_release_rows: %v", err)
		} else {
			own := cfg
			own.Rewards.RateCard = rows
			if err := validateAutotuneRuntimeEconomics(feeds, own); err != nil {
				fail("candidate_rate_card_not_release_rows: %v", err)
			}
		}
	}
	if opts.ResolveModelNames != "" {
		if opts.ExpectBaseEquivalent == "" {
			fail("resolve-model-names: requires --expect-base-equivalent (the live table)")
			return
		}
		names, err := readModelNames(opts.ResolveModelNames)
		if err != nil {
			fail("resolve-model-names: %v", err)
			return
		}
		liveCfg, _, err := config.LoadForSIGHUPReloadWithOverlayDigests(opts.ExpectBaseEquivalent, configOverlay)
		if err != nil {
			fail("resolve-model-names: live config: %v", err)
			return
		}
		for _, name := range names {
			r.ModelResolutions = append(r.ModelResolutions, autotuneModelResolution{
				Name: name,
				Old:  resolvedRate(liveCfg.Rewards.RateCard, name),
				New:  resolvedRate(cfg.Rewards.RateCard, name),
			})
		}
	}
}

// readModelNames reads a JSON array of strings and returns it sorted and
// de-duplicated, so the resolution list is deterministic.
func readModelNames(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, maxResolveModelNamesBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxResolveModelNamesBytes {
		return nil, fmt.Errorf("exceeds %d bytes", maxResolveModelNamesBytes)
	}
	var names []string
	if err := json.Unmarshal(raw, &names); err != nil {
		return nil, fmt.Errorf("want a JSON array of strings: %w", err)
	}
	sort.Strings(names)
	out := names[:0]
	for i, name := range names {
		if i > 0 && name == names[i-1] {
			continue
		}
		out = append(out, name)
	}
	return out, nil
}

func loadSingleYAMLDocument(path string) (*yaml.Node, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil {
		return nil, err
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		return nil, errors.New("want exactly one YAML document")
	}
	return &doc, nil
}

// yamlTreesEquivalentExceptRateCard compares two parsed documents node by
// node — Kind, Tag, Value, Style, Anchor and mapping key order significant;
// comments and positions ignored — skipping only the value node of the
// top-level rewards.rate_card key. It returns the first differing path.
func yamlTreesEquivalentExceptRateCard(a, b *yaml.Node) (string, bool) {
	return yamlNodesEquivalent(a, b, "", 0)
}

func yamlNodesEquivalent(a, b *yaml.Node, path string, depth int) (string, bool) {
	where := path
	if where == "" {
		where = "(root)"
	}
	if a.Kind != b.Kind || a.Tag != b.Tag || a.Value != b.Value || a.Style != b.Style || a.Anchor != b.Anchor || len(a.Content) != len(b.Content) {
		return where, false
	}
	switch a.Kind {
	case yaml.DocumentNode:
		for i := range a.Content {
			if p, ok := yamlNodesEquivalent(a.Content[i], b.Content[i], path, depth); !ok {
				return p, false
			}
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(a.Content); i += 2 {
			key := a.Content[i].Value
			child := key
			if path != "" {
				child = path + "." + key
			}
			if p, ok := yamlNodesEquivalent(a.Content[i], b.Content[i], child, depth+1); !ok {
				return p, false
			}
			if depth == 1 && child == "rewards.rate_card" {
				continue
			}
			if p, ok := yamlNodesEquivalent(a.Content[i+1], b.Content[i+1], child, depth+1); !ok {
				return p, false
			}
		}
	case yaml.SequenceNode:
		for i := range a.Content {
			if p, ok := yamlNodesEquivalent(a.Content[i], b.Content[i], path+"["+strconv.Itoa(i)+"]", depth+1); !ok {
				return p, false
			}
		}
	}
	return "", true
}

// candidateRateCardRows decodes the candidate document's own
// rewards.rate_card (not the overlay-merged view).
func candidateRateCardRows(doc *yaml.Node) (map[string]config.RateCardEntry, error) {
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("candidate is not a YAML mapping document")
	}
	rewards := yamlMappingValue(doc.Content[0], "rewards")
	if rewards == nil || rewards.Kind != yaml.MappingNode {
		return nil, errors.New("candidate has no rewards mapping")
	}
	card := yamlMappingValue(rewards, "rate_card")
	if card == nil {
		return nil, errors.New("candidate has no rewards.rate_card")
	}
	var rows map[string]config.RateCardEntry
	if err := card.Decode(&rows); err != nil {
		return nil, err
	}
	return rows, nil
}

func yamlMappingValue(mapping *yaml.Node, key string) *yaml.Node {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1]
		}
	}
	return nil
}
