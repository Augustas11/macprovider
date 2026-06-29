package benchmark

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
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
	ModelID                string  `json:"model"`
	PromptPricePer1k       float64 `json:"price_per_1k_prompt_tokens"`
	CompletionPricePer1k   float64 `json:"price_per_1k_completion_tokens"`
}

// rawCatalogEntry is the JSON-side mirror. Kept separate so we can grow
// the manifest schema (e.g. tier identifiers, hash fields) without
// forcing pricing math to know about them.
type rawCatalogEntry struct {
	Model                string  `json:"model"`
	ModelID              string  `json:"model_id"`
	PromptPer1k          float64 `json:"price_per_1k_prompt_tokens"`
	CompletionPer1k      float64 `json:"price_per_1k_completion_tokens"`
	PromptPer1kAlt       float64 `json:"prompt_per_1k"`
	CompletionPer1kAlt   float64 `json:"completion_per_1k"`
}

// LoadPricing reads a tier-2 pricing manifest from a local path or
// from an "host:/path" SSH spec. Returns nil + error on hard failures
// (cannot read, file invalid); returns a partial Pricing with Notes
// when entries were skipped but at least one was loaded.
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
		return nil, fmt.Errorf("read pricing manifest %q: %w", source, err)
	}
	return parsePricing(source, data)
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
// and token counts. Unknown models contribute zero and are recorded in
// UnknownModels so B6 verdict detail can call them out.
func (p *Pricing) EarningsFor(model string, promptTokens, completionTokens int64) float64 {
	if p == nil || model == "" {
		return 0
	}
	mp, ok := p.ByModel[model]
	if !ok {
		p.UnknownModels[model]++
		return 0
	}
	return float64(promptTokens)*mp.PromptPricePer1k/1000.0 +
		float64(completionTokens)*mp.CompletionPricePer1k/1000.0
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
