package buyer

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"syscall"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
)

// modelCapabilities is the per-model capability object on /v1/models
// (SPEC-006 §21, #2107 D6). Each field is derived from the predicate the
// coordinator or provider enforces for that model:
//
//   - tools: the model family has a tool grammar (toolGrammarFamily, the
//     same predicate behind tools_unsupported_for_model).
//   - tool_choice: auto with tools, plus every mode (none, required, named)
//     a native provider declares for its exact loaded model
//     (providerSupportsToolSelection). Grammar-mask providers declare these
//     modes for every supported template family; older declarations stay bounded.
//   - tools and reasoning for a family an older provider did not parse need
//     a provider at toolGrammarProviderMinVersion or later.
//   - reasoning: the family's template always opens a reasoning block, so
//     responses carry reasoning_content and honour reasoning_effort.
//   - response_format: every native provider validates json_object and strict
//     json_schema output (SPEC-019).
//   - vision: at least one provider passes providerSupportsVision.
//   - context_length: the largest advertised max_context_tokens.
type modelCapabilities struct {
	Tools          bool     `json:"tools"`
	ToolChoice     []string `json:"tool_choice"`
	Reasoning      bool     `json:"reasoning"`
	ResponseFormat bool     `json:"response_format"`
	Vision         bool     `json:"vision"`
	ContextLength  int      `json:"context_length"`
}

// toolGrammarProviderMinVersion is the first provider CLI that parses every
// catalog tool grammar and splits reasoning (#2107). An older provider keeps
// only the families it already served, so the metadata never advertises what
// an eligible provider cannot do during a staged rollout.
const toolGrammarProviderMinVersion = "1.8.262"

// legacyToolFamily is the set an older provider already served with tools.
func legacyToolFamily(model string) bool {
	id := strings.ToLower(model)
	return strings.Contains(id, "qwen2.5") || strings.Contains(id, "qwen3") || strings.Contains(id, "llama-3.3") || strings.Contains(id, "gpt-oss")
}

// providerParsesToolGrammar is the provider-level tool predicate shared by
// capability derivation and request eligibility. A SPEC-051 shard group head
// refuses tools (shard_group_tools_unsupported), so it never counts.
func providerParsesToolGrammar(p pool.Provider) bool {
	if toolGrammarFamily(p.ModelID) == toolGrammarLFM2 {
		// LFM shipped after the generic grammar floor. Require the exact
		// loaded-model declaration, which old providers cannot advertise.
		return !p.ShardGroupHeadV1 &&
			providerSupportsToolSelection(p, &toolSelectionPolicy{mode: "required"}) &&
			providerSupportsToolSelection(p, &toolSelectionPolicy{mode: "named"})
	}
	return !p.ShardGroupHeadV1 && toolGrammarFamily(p.ModelID) != "" && (legacyToolFamily(p.ModelID) || providerServesToolGrammars(p))
}

// providerToolGrammarEligible reports whether a provider can serve a tool
// request: external runtimes keep their own tool handling, and a model with no
// catalog family keeps provider-side behavior (the provider refuses tools its
// template cannot express); a native provider of a catalog family must parse
// that family's grammar.
func providerToolGrammarEligible(p pool.Provider) bool {
	if p.ShardGroupHeadV1 {
		return false
	}
	return providerEngineClass(p) != engineClassNative || toolGrammarFamily(p.ModelID) == "" || providerParsesToolGrammar(p)
}

func toolGrammarEligibleProviders(providers []pool.Provider) []pool.Provider {
	eligible := make([]pool.Provider, 0, len(providers))
	for _, p := range providers {
		if providerToolGrammarEligible(p) {
			eligible = append(eligible, p)
		}
	}
	return eligible
}

func toolGrammarProviderUnavailableRouteError() *routeError {
	return &routeError{status: http.StatusServiceUnavailable, code: "tool_grammar_provider_unavailable", message: "No provider serving this model parses its tool-call grammar yet"}
}

func providerServesToolGrammars(p pool.Provider) bool {
	cmp, ok := versionfloor.Compare(p.BinaryVersion, toolGrammarProviderMinVersion)
	return ok && cmp >= 0
}

// reasoningFamily reports families whose chat template always reasons before
// answering (GLM-5 opens `<think>`; gpt-oss Harmony has an analysis channel;
// the DeepSeek-V4 encoder opens `<think>` unless reasoning_effort is none).
func reasoningFamily(model string) bool {
	id := strings.ToLower(model)
	return strings.Contains(id, "glm-5") || strings.Contains(id, "gpt-oss") || strings.Contains(id, "deepseek-v4")
}

func mergeModelCapabilities(current *modelCapabilities, p pool.Provider, vision bool) *modelCapabilities {
	caps := current
	if caps == nil {
		caps = &modelCapabilities{}
	}
	if providerParsesToolGrammar(p) {
		caps.Tools = true
		modes := map[string]bool{"auto": true}
		for _, mode := range caps.ToolChoice {
			modes[mode] = true
		}
		for _, mode := range []string{"none", "required", "named"} {
			if providerSupportsToolSelection(p, &toolSelectionPolicy{mode: mode}) {
				modes[mode] = true
			}
		}
		caps.ToolChoice = caps.ToolChoice[:0]
		for _, mode := range []string{"auto", "none", "required", "named"} {
			if modes[mode] {
				caps.ToolChoice = append(caps.ToolChoice, mode)
			}
		}
	}
	if reasoningFamily(p.ModelID) && (strings.Contains(strings.ToLower(p.ModelID), "gpt-oss") || providerServesToolGrammars(p)) {
		caps.Reasoning = true
	}
	// A shard group head refuses response_format
	// (shard_group_response_format_unsupported).
	if (p.RuntimeSource == "" || p.RuntimeSource == engineClassNative) && !p.ShardGroupHeadV1 {
		caps.ResponseFormat = true
	}
	if vision {
		caps.Vision = true
	}
	if p.MaxContextTokens > caps.ContextLength {
		caps.ContextLength = p.MaxContextTokens
	}
	return caps
}

// finishModelCapabilities derives the OpenRouter-style supported_parameters
// list from the capability object.
func finishModelCapabilities(entry *modelEntry) {
	caps := entry.Capabilities
	if caps == nil {
		return
	}
	if caps.ToolChoice == nil {
		caps.ToolChoice = []string{}
	}
	params := []string{"max_tokens", "temperature", "top_p", "stop", "seed", "frequency_penalty", "presence_penalty"}
	if caps.Tools {
		params = append(params, "tools", "tool_choice", "parallel_tool_calls")
	}
	if caps.Reasoning {
		params = append(params, "reasoning_effort")
	}
	if caps.ResponseFormat {
		params = append(params, "response_format")
	}
	sort.Strings(params)
	entry.SupportedParameters = params
}

// buyerUXCapabilities is the capability set a model's buyer-UX conformance
// record allows (scripts/buyer_ux_conformance.py capabilities_from_checks).
type buyerUXCapabilities struct {
	Tools          bool     `json:"tools"`
	ToolChoice     []string `json:"tool_choice"`
	Reasoning      bool     `json:"reasoning"`
	ResponseFormat bool     `json:"response_format"`
}

// buyerUXConformanceMaxBytes bounds the record file read; the checked-in file
// is a few KiB per model.
const buyerUXConformanceMaxBytes = 4 << 20

// buyerUXOwedCapabilities is what a model promoted with its record owed may
// advertise until the record lands (SPEC-023 §16.11 rule 4): the base set
// only. Tools, tool_choice, reasoning and response_format all need a passing
// record; vision and context_length are not conformance capabilities.
var buyerUXOwedCapabilities = buyerUXCapabilities{ToolChoice: []string{}}

// LoadBuyerUXConformance reads the record file and returns the allowed
// capabilities keyed by served model id. An empty path means no records.
func LoadBuyerUXConformance(path string) (map[string]buyerUXCapabilities, error) {
	records, _, err := loadBuyerUXConformance(path)
	return records, err
}

// loadBuyerUXConformance also returns the SHA-256 of the exact bytes it
// parsed, which /healthz reports so activation tooling can prove the
// installed file is the one in force.
func loadBuyerUXConformance(path string) (map[string]buyerUXCapabilities, string, error) {
	if strings.TrimSpace(path) == "" {
		return nil, "", nil
	}
	// O_NONBLOCK so a FIFO or device at the path cannot block boot or a
	// SIGHUP reload; only a regular file is read.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()
	if info, err := f.Stat(); err != nil {
		return nil, "", err
	} else if !info.Mode().IsRegular() {
		return nil, "", fmt.Errorf("buyer-ux conformance: %s is not a regular file", path)
	}
	raw, err := io.ReadAll(io.LimitReader(f, buyerUXConformanceMaxBytes+1))
	if err != nil {
		return nil, "", err
	}
	if len(raw) > buyerUXConformanceMaxBytes {
		return nil, "", fmt.Errorf("buyer-ux conformance: %s is larger than %d bytes", path, buyerUXConformanceMaxBytes)
	}
	var doc struct {
		SchemaVersion string `json:"schema_version"`
		Records       map[string]struct {
			Model        string               `json:"model"`
			Capabilities *buyerUXCapabilities `json:"capabilities"`
		} `json:"records"`
		// Owed names, per catalog key, the served model of a first promotion
		// whose record is still owed (SPEC-023 §16.11 rule 4).
		Owed map[string]*struct {
			Model string `json:"model"`
		} `json:"owed"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, "", err
	}
	if doc.SchemaVersion != "macprovider.buyer-ux-conformance.v1" {
		return nil, "", fmt.Errorf("buyer-ux conformance: unsupported schema_version %q", doc.SchemaVersion)
	}
	// A missing or null records object is malformed, never "no records":
	// accepting it would clear the masks in force.
	if doc.Records == nil {
		return nil, "", fmt.Errorf("buyer-ux conformance: records object is missing")
	}
	out := make(map[string]buyerUXCapabilities, len(doc.Records)+len(doc.Owed))
	for key, record := range doc.Records {
		if record.Capabilities == nil || strings.TrimSpace(record.Model) == "" {
			return nil, "", fmt.Errorf("buyer-ux conformance: record %q needs model and capabilities", key)
		}
		out[strings.ToLower(record.Model)] = *record.Capabilities
	}
	// An owed model advertises the base set until a record for that model
	// lands; a record, passing or not, always decides. Each masked model
	// counts toward the models /healthz reports, which is how activation
	// tooling tells a runtime that applies owed entries from one that
	// ignores them.
	for key, entry := range doc.Owed {
		if entry == nil || strings.TrimSpace(entry.Model) == "" {
			return nil, "", fmt.Errorf("buyer-ux conformance: owed %q needs a model", key)
		}
		model := strings.ToLower(entry.Model)
		if _, recorded := out[model]; recorded {
			continue
		}
		out[model] = buyerUXOwedCapabilities
	}
	sum := sha256.Sum256(raw)
	return out, hex.EncodeToString(sum[:]), nil
}

// SetBuyerUXConformance installs the conformance records.
func (s *Server) SetBuyerUXConformance(records map[string]buyerUXCapabilities) {
	s.routingMu.Lock()
	s.buyerUXConformance = records
	s.routingMu.Unlock()
}

// ReloadBuyerUXConformance applies routing.buyer_ux_conformance_path, at boot
// and on every SIGHUP (SPEC-023 §16.11). An empty path clears the records. A
// file that cannot be read or parsed is an error and changes nothing: the
// records already in force stay (at boot there are none, so every model keeps
// its derived set). changed reports whether the applied file differs from the
// one in force before.
func (s *Server) ReloadBuyerUXConformance(path string) (changed bool, err error) {
	records, digest, err := loadBuyerUXConformance(path)
	if err != nil {
		return false, err
	}
	s.routingMu.Lock()
	defer s.routingMu.Unlock()
	changed = digest != s.buyerUXConformanceSHA256
	s.buyerUXConformance = records
	s.buyerUXConformanceSHA256 = digest
	return changed, nil
}

// BuyerUXConformanceStatus is the SHA-256 of the record file in force (empty
// when none is) and the number of models whose capabilities it caps: every
// recorded model plus every owed model it masks to the base set (SPEC-023
// §16.11 rule 4), for /healthz.
func (s *Server) BuyerUXConformanceStatus() (string, int) {
	s.routingMu.RLock()
	defer s.routingMu.RUnlock()
	return s.buyerUXConformanceSHA256, len(s.buyerUXConformance)
}

// applyBuyerUXConformance removes every capability the model's conformance
// record failed; a model without a record keeps the derived set.
func (s *Server) applyBuyerUXConformance(entry *modelEntry) {
	if entry.Capabilities == nil {
		return
	}
	s.routingMu.RLock()
	record, ok := s.buyerUXConformance[strings.ToLower(entry.ID)]
	s.routingMu.RUnlock()
	if !ok {
		return
	}
	caps := entry.Capabilities
	caps.Tools = caps.Tools && record.Tools
	caps.Reasoning = caps.Reasoning && record.Reasoning
	caps.ResponseFormat = caps.ResponseFormat && record.ResponseFormat
	allowed := map[string]bool{}
	for _, mode := range record.ToolChoice {
		allowed[mode] = true
	}
	modes := []string{}
	if caps.Tools {
		for _, mode := range caps.ToolChoice {
			if allowed[mode] {
				modes = append(modes, mode)
			}
		}
	}
	caps.ToolChoice = modes
}
