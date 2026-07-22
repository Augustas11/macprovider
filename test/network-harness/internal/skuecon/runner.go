package skuecon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/invariants"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

const skuEconCLIBinEnv = "HARNESS_SKU_ECON_CLI_BIN"
const allowScenarioCLIBinEnv = "HARNESS_SKU_ECON_ALLOW_SCENARIO_CLI_BIN"

type Runner struct {
	HTTPClient *http.Client
	Now        func() time.Time
	Stdout     func(string)
}

type Result struct {
	Rows       []TierResult
	Viability  map[string]ViabilityRow
	Invariants *invariants.Result
}

type TierResult struct {
	Label      string          `json:"label"`
	Tier       string          `json:"tier"`
	Expected   string          `json:"expected"`
	Outcome    string          `json:"outcome"`
	Viability  ViabilityRow    `json:"viability"`
	RawResult  json.RawMessage `json:"result"`
	Summary    string          `json:"summary"`
	ResultFile int             `json:"-"`
}

type ViabilityRow struct {
	EligibleRowCount int `json:"eligible_row_count"`
	TotalCandidates  int `json:"total_candidates"`
	// BestRow is the highest-scoring eligible candidate. nil when no
	// candidate passes eligibility.
	BestRow *BestRow `json:"best_row"`
	// BestByScore is included only when a higher-scoring candidate is NOT
	// eligible (blocked/gated). Surfaces when unblocking a runtime_status=blocked
	// model would change the viability picture.
	BestByScore     *BestRow `json:"best_by_score,omitempty"`
	Exempt          bool     `json:"exempt"`
	DeltaVsExpected string   `json:"delta_vs_expected"`
}

type BestRow struct {
	Model                    string  `json:"model"`
	PromptRateUSDPerMtok     float64 `json:"best_prompt_rate_usd_per_mtok"`
	CompletionRateUSDPerMtok float64 `json:"best_completion_rate_usd_per_mtok"`
	Eligible                 bool    `json:"eligible"`
	RawScore                 float64 `json:"raw_score,omitempty"`
}

type catalogSnapshot struct {
	Rows map[string]catalogRow `json:"rows"`
}

type catalogRow struct {
	ModelID          string    `json:"model_id"`
	ModelSHA256      string    `json:"model_sha256"`
	MinRAMGB         int       `json:"min_ram_gb"`
	MinBandwidthTier string    `json:"min_bandwidth_tier"`
	BenchGate        benchGate `json:"bench_gate"`
	RuntimeStatus    string    `json:"runtime_status"`
}

type benchGate struct {
	MinSustainedTPS float64 `json:"min_sustained_tps"`
	Max4KTTFTMS     int     `json:"max_4k_ttft_ms"`
}

type simulateResult struct {
	RecommendedModel string              `json:"recommended_model"`
	Candidates       []simulateCandidate `json:"candidates"`
	AllCandidates    []simulateCandidate `json:"all_candidates"`
}

type simulateCandidate struct {
	Model                             string  `json:"model"`
	Eligible                          bool    `json:"eligible"`
	PromptRateUSDPerMillionTokens     float64 `json:"prompt_rate_usd_per_million_tokens"`
	CompletionRateUSDPerMillionTokens float64 `json:"completion_rate_usd_per_million_tokens"`
	RawScore                          float64 `json:"raw_score"`
}

func (r Runner) Run(ctx context.Context, sc *scenario.Scenario, scenarioPath, outDir string) (*Result, error) {
	client := r.HTTPClient
	if client == nil {
		client = &http.Client{
			Timeout: 30 * time.Second,
			// Refuse redirects so a 3xx from the pinned coordinator
			// cannot forward the fetch to an attacker-controlled host.
			// ErrUseLastResponse tells net/http to return the 3xx as
			// the final response, which the non-2xx check below rejects.
			// SEC-H-1 (r3 security audit).
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		}
	}
	now := r.Now
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}

	// Build the rate-card URL from validated constants rather than
	// concatenating the scenario-supplied field. `validateSKUEcon` already
	// pins scheme+host+path+query+fragment+userinfo, but constructing the
	// URL here from the pinned host constant is defense-in-depth against
	// any future validator regression (SEC-H-1 r2 audit).
	rateCardURL := "https://" + scenario.SKUEconCoordinatorHost + "/v1/rate-card"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rateCardURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch rate-card: %w", err)
	}
	defer resp.Body.Close()
	rateCardBytes, err := readHTTPBody(resp)
	if err != nil {
		return nil, fmt.Errorf("fetch rate-card: %w", err)
	}
	if err := os.WriteFile(filepath.Join(outDir, "rate_card_snapshot.json"), rateCardBytes, 0o644); err != nil {
		return nil, fmt.Errorf("write rate_card_snapshot.json: %w", err)
	}

	cliBin, err := resolveCLIBin(sc.Target.CLIBin, scenarioPath)
	if err != nil {
		return nil, err
	}
	tempHome, err := os.MkdirTemp("", "skuecon-home-")
	if err != nil {
		return nil, fmt.Errorf("create sku-econ temp HOME: %w", err)
	}
	defer os.RemoveAll(tempHome)

	catalogBytes, err := dumpBakedSnapshot(ctx, cliBin, "catalog", tempHome)
	if err != nil {
		return nil, fmt.Errorf("dump baked catalog: %w", err)
	}
	demandBytes, err := dumpBakedSnapshot(ctx, cliBin, "demand-rank", tempHome)
	if err != nil {
		return nil, fmt.Errorf("dump baked demand-rank: %w", err)
	}
	var catalog catalogSnapshot
	if err := json.Unmarshal(catalogBytes, &catalog); err != nil {
		return nil, fmt.Errorf("decode catalog snapshot: %w", err)
	}
	catalogSHA := sha256Hex(catalogBytes)

	jsonl, err := os.Create(filepath.Join(outDir, "recommend_per_tier.jsonl"))
	if err != nil {
		return nil, fmt.Errorf("create recommend_per_tier.jsonl: %w", err)
	}
	defer jsonl.Close()

	rows := make([]TierResult, 0, len(sc.HardwareMatrix))
	viability := make(map[string]ViabilityRow, len(sc.HardwareMatrix))
	checks := make([]invariants.Check, 0, len(sc.HardwareMatrix))
	generatedAt := now().UTC().Format(time.RFC3339)

	for i, hw := range sc.HardwareMatrix {
		envelope, err := synthesizeEnvelope(sc, hw, catalog, catalogBytes, catalogSHA, rateCardBytes, demandBytes, generatedAt)
		if err != nil {
			return nil, fmt.Errorf("%s: synthesize envelope: %w", hw.Label, err)
		}
		raw, err := runCLI(ctx, cliBin, envelope, tempHome)
		if err != nil {
			return nil, fmt.Errorf("%s: recommend-simulate: %w", hw.Label, err)
		}
		var decoded simulateResult
		if err := json.Unmarshal(raw, &decoded); err != nil {
			return nil, fmt.Errorf("%s: decode recommend result: %w", hw.Label, err)
		}
		viabilityCandidates := decoded.Candidates
		if len(decoded.AllCandidates) > 0 {
			viabilityCandidates = decoded.AllCandidates
		}
		v := AggregateViability(viabilityCandidates, hw.Expected)
		outcome := ClassifyI5(hw.Expected, v.EligibleRowCount, decoded.RecommendedModel)
		line := map[string]any{
			"label":     hw.Label,
			"tier":      hw.BandwidthTier,
			"expected":  hw.Expected,
			"outcome":   outcome,
			"viability": v,
			"result":    json.RawMessage(raw),
		}
		if err := json.NewEncoder(jsonl).Encode(line); err != nil {
			return nil, fmt.Errorf("append recommend_per_tier.jsonl: %w", err)
		}
		viability[hw.Label] = v
		summary := SummaryLine(hw, viabilityCandidates, outcome)
		if r.Stdout != nil {
			r.Stdout(summary)
		} else {
			fmt.Println(summary)
		}
		rows = append(rows, TierResult{
			Label:      hw.Label,
			Tier:       hw.BandwidthTier,
			Expected:   hw.Expected,
			Outcome:    outcome,
			Viability:  v,
			RawResult:  append(json.RawMessage(nil), raw...),
			Summary:    summary,
			ResultFile: i + 1,
		})
		checks = append(checks, I5Check(hw, v.EligibleRowCount, outcome))
	}
	if err := writeJSON(filepath.Join(outDir, "earn_viability.json"), viability); err != nil {
		return nil, err
	}
	inv := &invariants.Result{Checks: checks}
	if err := writeJSON(filepath.Join(outDir, "invariants.json"), inv); err != nil {
		return nil, err
	}
	return &Result{Rows: rows, Viability: viability, Invariants: inv}, nil
}

func AggregateViability(candidates []simulateCandidate, expected string) ViabilityRow {
	row := ViabilityRow{
		TotalCandidates: len(candidates),
		Exempt:          expected == "donor_only_by_ram",
	}
	var bestByScore *BestRow
	var bestEligible *BestRow
	for _, c := range candidates {
		snap := candidateSnapshot(c)
		if bestByScore == nil || c.RawScore > bestByScore.RawScore {
			bestByScore = snap
		}
		if c.Eligible {
			row.EligibleRowCount++
			if bestEligible == nil || c.RawScore > bestEligible.RawScore {
				bestEligible = snap
			}
		}
	}
	row.BestRow = bestEligible
	if bestByScore != nil && (bestEligible == nil || bestByScore.Model != bestEligible.Model) {
		row.BestByScore = bestByScore
	}
	switch {
	case expected == "donor_only_by_ram":
		row.DeltaVsExpected = "exempt"
	case expected == "at_least_one_eligible_row" && row.EligibleRowCount > 0:
		row.DeltaVsExpected = "meets_expected"
	default:
		row.DeltaVsExpected = "record_would_fail_phase_c"
	}
	return row
}

func candidateSnapshot(c simulateCandidate) *BestRow {
	return &BestRow{
		Model:                    c.Model,
		PromptRateUSDPerMtok:     c.PromptRateUSDPerMillionTokens,
		CompletionRateUSDPerMtok: c.CompletionRateUSDPerMillionTokens,
		Eligible:                 c.Eligible,
		RawScore:                 c.RawScore,
	}
}

func ClassifyI5(expected string, eligibleRowCount int, recommendedModel string) string {
	switch expected {
	case "donor_only_by_ram":
		if eligibleRowCount == 0 {
			return "pass"
		}
		return "record"
	case "at_least_one_eligible_row":
		if eligibleRowCount >= 1 && recommendedModel != "" {
			return "pass"
		}
		if eligibleRowCount == 0 {
			return "record"
		}
		return "fail"
	default:
		return "fail"
	}
}

func I5Check(row scenario.HardwareMatrixRow, eligibleRowCount int, outcome string) invariants.Check {
	passed := outcome != "fail"
	return invariants.Check{
		ID:            "I5",
		Title:         "SKU earn viability gate",
		Passed:        passed,
		Status:        outcome,
		Detail:        fmt.Sprintf("%s Tier-%s expected=%s eligible_row_count=%d", row.Label, row.BandwidthTier, row.Expected, eligibleRowCount),
		EvidenceCount: eligibleRowCount,
	}
}

func SummaryLine(row scenario.HardwareMatrixRow, candidates []simulateCandidate, outcome string) string {
	v := AggregateViability(candidates, row.Expected)
	suffix := strings.ToUpper(outcome)
	if row.Expected == "donor_only_by_ram" && v.EligibleRowCount == 0 {
		return fmt.Sprintf("[sku-econ] %s Tier-%s  eligible=0/%d  no catalog fit                 <- %s",
			row.Label, row.BandwidthTier, v.TotalCandidates, suffix)
	}
	rate := "-"
	if v.BestRow != nil {
		rate = fmt.Sprintf("$%.3f/M", v.BestRow.CompletionRateUSDPerMtok)
	}
	return fmt.Sprintf("[sku-econ] %s Tier-%s  eligible=%d/%d  best_completion_rate=%s  <- %s",
		row.Label, row.BandwidthTier, v.EligibleRowCount, v.TotalCandidates, rate, suffix)
}

func synthesizeEnvelope(
	sc *scenario.Scenario,
	row scenario.HardwareMatrixRow,
	catalog catalogSnapshot,
	catalogBytes []byte,
	catalogSHA string,
	rateCardBytes []byte,
	demandBytes []byte,
	generatedAt string,
) ([]byte, error) {
	benchmarks := map[string]any{}
	for modelKey, catalogRow := range catalog.Rows {
		tps := catalogRow.BenchGate.MinSustainedTPS * sc.BenchmarkSynthesis.TPSMultiplierOfGate
		if tps <= 0 {
			tps = 1
		}
		ttft := int(math.Ceil(float64(catalogRow.BenchGate.Max4KTTFTMS) * sc.BenchmarkSynthesis.TTFTFractionOfCeiling))
		if ttft <= 0 {
			ttft = 1
		}
		benchmarks[modelKey] = map[string]any{
			"model_key":                 modelKey,
			"sustained_tps":             tps,
			"ttft_ms":                   ttft,
			"swap_detected":             false,
			"thermal_throttle_detected": false,
			"artifact_sha256":           catalogRow.ModelSHA256,
			"model_artifact_path":       "/tmp/skuecon/" + row.Label + "/" + strings.ReplaceAll(modelKey, "/", "_"),
			"benchmark_id":              "sku-econ-" + row.Label + "-" + strings.ReplaceAll(modelKey, "/", "_"),
			"generated_at":              generatedAt,
			"candidate_catalog_sha256":  catalogSHA,
			"binary_version":            "sku-econ-sim",
			"model_id":                  catalogRow.ModelID,
			"hardware_identity_hash":    "sim-" + row.Label,
		}
	}
	envelope := map[string]any{
		"hardware": map[string]any{
			"machine":              row.Label,
			"chip":                 row.Chip,
			"memoryGB":             row.MemoryGB,
			"bandwidthTier":        row.BandwidthTier,
			"osVersion":            "sku-econ-sim",
			"binaryVersion":        "sku-econ-sim",
			"diversificationID":    "sim-" + row.Label,
			"hardwareIdentityHash": "sim-" + row.Label,
		},
		"rateCard":               json.RawMessage(rateCardBytes),
		"candidateCatalog":       json.RawMessage(catalogBytes),
		"candidateCatalogSHA256": catalogSHA,
		"demandRank":             json.RawMessage(demandBytes),
		"benchmarks":             benchmarks,
		"warnings":               []string{},
		"generatedAt":            generatedAt,
		"donorMode":              false,
	}
	return json.Marshal(envelope)
}

func runCLI(ctx context.Context, cliBin string, envelope []byte, home string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, cliBin, "autotune", "recommend-simulate")
	cmd.Stdin = bytes.NewReader(envelope)
	cmd.Env = sanitizedEnv(home)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg != "" {
			return nil, fmt.Errorf("%w: %s", err, msg)
		}
		return nil, err
	}
	return bytes.TrimSpace(stdout.Bytes()), nil
}

func dumpBakedSnapshot(ctx context.Context, cliBin, kind, home string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, cliBin, "autotune", "dump-baked-snapshot", "--kind", kind)
	cmd.Env = sanitizedEnv(home)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg != "" {
			return nil, fmt.Errorf("%w: %s", err, msg)
		}
		return nil, err
	}
	return bytes.TrimSpace(stdout.Bytes()), nil
}

// sanitizedEnv returns a minimal environment for CLI child processes.
// recommend-simulate and dump-baked-snapshot are pure — they only need
// PATH (dynamic linker) and HOME (Foundation's cache dirs on macOS).
// Buyer/operator/demo tokens, GH tokens, and other credentials are
// dropped so a misconfigured scenario or swapped cli_bin cannot
// exfiltrate secrets from the parent env. SEC-H-1 (r1 security audit).
func sanitizedEnv(home string) []string {
	env := make([]string, 0, 2)
	if v := os.Getenv("PATH"); v != "" {
		env = append(env, "PATH="+v)
	}
	if home != "" {
		env = append(env, "HOME="+home)
	}
	return env
}

func readHTTPBody(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	body := new(bytes.Buffer)
	if _, err := body.ReadFrom(resp.Body); err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(body.String()))
	}
	return body.Bytes(), nil
}

func resolveLocalPath(pathValue, scenarioPath string) string {
	if filepath.IsAbs(pathValue) {
		return pathValue
	}
	candidates := []string{
		pathValue,
		filepath.Join(filepath.Dir(scenarioPath), pathValue),
		filepath.Join(filepath.Dir(scenarioPath), "..", pathValue),
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return pathValue
}

func resolveCLIBin(pathValue, scenarioPath string) (string, error) {
	if pinned := os.Getenv(skuEconCLIBinEnv); pinned != "" {
		resolved := resolveLocalPath(pinned, scenarioPath)
		if err := requireExecutable(resolved); err != nil {
			return "", fmt.Errorf("%s: %w", skuEconCLIBinEnv, err)
		}
		return resolved, nil
	}
	if os.Getenv(allowScenarioCLIBinEnv) != "1" {
		return "", fmt.Errorf("target.cli_bin is trusted code; set %s to pin the packaged CLI or %s=1 to opt into scenario-controlled cli_bin", skuEconCLIBinEnv, allowScenarioCLIBinEnv)
	}
	resolved := resolveLocalPath(pathValue, scenarioPath)
	if err := requireExecutable(resolved); err != nil {
		return "", fmt.Errorf("target.cli_bin: %w", err)
	}
	return resolved, nil
}

func requireExecutable(pathValue string) error {
	info, err := os.Stat(pathValue)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("%s is a directory", pathValue)
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("%s is not executable", pathValue)
	}
	return nil
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func writeJSON(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
