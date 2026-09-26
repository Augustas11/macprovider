package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

type validatorVerdict struct {
	OK               bool     `json:"ok"`
	Errors           []string `json:"errors"`
	ModelResolutions []struct {
		Name string `json:"name"`
		Old  struct {
			RowKey     string `json:"row_key"`
			Prompt     int64  `json:"prompt_credits_per_mtok"`
			CacheHit   int64  `json:"prompt_cache_hit_credits_per_mtok"`
			Completion int64  `json:"completion_credits_per_mtok"`
		} `json:"old"`
		New struct {
			RowKey     string `json:"row_key"`
			Prompt     int64  `json:"prompt_credits_per_mtok"`
			CacheHit   int64  `json:"prompt_cache_hit_credits_per_mtok"`
			Completion int64  `json:"completion_credits_per_mtok"`
		} `json:"new"`
	} `json:"model_resolutions"`
	RateTableSHA256      string `json:"rate_table_sha256"`
	SignedRateCardSHA256 string `json:"signed_rate_card_sha256"`
}

// J7 — the validator seam: the real coordinator binary's
// --validate-autotune-release --expect-base-equivalent over yaml variants
// accepts exactly the variants whose only semantic difference from the live
// base is rewards.rate_card, and only when those rows are the release's.
func TestPricingLaneJ7ValidatorSeam(t *testing.T) {
	requireBins(t)
	tempDir := t.TempDir()
	s := &scenario{
		t:             t,
		tempDir:       tempDir,
		coordinatorDB: filepath.Join(tempDir, "coordinator.db"),
		coordYAML:     filepath.Join(tempDir, "coordinator.yaml"),
		operatorKey:   strongHexSecret(t),
		serviceToken:  strongHexSecret(t),
		providerID:    "prov-" + randHex(t, 4),
	}
	lane, _ := preparePricingFiles(t, s, allocatePort(t), allocatePort(t), []map[string]any{{
		"provider_id": s.providerID, "display_name": "fake-pricing-0", "endpoint_url": "http://127.0.0.1:1",
	}})
	live := s.coordYAML
	liveRaw, err := os.ReadFile(live)
	if err != nil {
		t.Fatal(err)
	}
	cardB, cardBRaw := lane.cardB()

	// The candidate release directory: current feeds, card B, Tier-2 catalog
	// under the configured basename.
	release := filepath.Join(tempDir, "release-candidate")
	if err := os.MkdirAll(release, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"autotune-candidates.json", "demand-rank.json"} {
		for _, suffix := range []string{"", ".sig"} {
			raw, err := os.ReadFile(filepath.Join(lane.currentDir, name+suffix))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(release, name+suffix), raw, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	lane.keys.writeSignedAtomic(t, filepath.Join(release, "rate-card.json"), cardBRaw)
	tier2Raw, err := os.ReadFile(filepath.Join(tempDir, "settlement-catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(release, "settlement-catalog.json"), tier2Raw, 0o600); err != nil {
		t.Fatal(err)
	}

	spliced := lane.spliceYAML(live, rateCardBlock(cardB))
	write := func(name string, raw []byte) string {
		path := filepath.Join(tempDir, name)
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	replaceOnce := func(raw []byte, old, new string) []byte {
		if !bytes.Contains(raw, []byte(old)) {
			t.Fatalf("variant anchor %q not in yaml", old)
		}
		return bytes.Replace(raw, []byte(old), []byte(new), 1)
	}
	validate := func(candidate string, extra ...string) (validatorVerdict, int, string) {
		args := append([]string{"-config", candidate, "-validate-autotune-release", release, "-expect-base-equivalent", live}, extra...)
		cmd := exec.CommandContext(context.Background(), coordinatorBin, args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		err := cmd.Run()
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else if err != nil {
			t.Fatalf("run validator: %v", err)
		}
		var v validatorVerdict
		if jerr := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &v); jerr != nil && code != 2 {
			t.Fatalf("validator output not one JSON line (exit %d): %q stderr=%s", code, stdout.String(), stderr.String())
		}
		return v, code, stdout.String()
	}

	// Rewrites of the rewards.rate_card block alone (rows equal card B).
	reformattedB := func() []byte {
		var b bytes.Buffer
		b.WriteString("  rate_card:\n")
		// Reverse key order, quoted keys, reversed field order, a comment.
		keys := make([]string, 0, len(cardB.Rows))
		for k := range cardB.Rows {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i := len(keys) - 1; i >= 0; i-- {
			r := cardB.Rows[keys[i]]
			fmt.Fprintf(&b, "    %q: # reviewed\n", keys[i])
			fmt.Fprintf(&b, "      prompt_credits_per_mtok: %d\n", r.PromptRatePerMtok)
			fmt.Fprintf(&b, "      prompt_cache_hit_credits_per_mtok: %d\n", r.PromptCacheHitRatePerMtok)
			fmt.Fprintf(&b, "      completion_credits_per_mtok: %d\n", r.CompletionRatePerMtok)
		}
		return b.Bytes()
	}
	cardC, _ := lane.deriveCard(func(rows map[string]pricingCardRow) {
		r := rows[pricingLlamaKey]
		r.PromptRatePerMtok, r.PromptCacheHitRatePerMtok, r.CompletionRatePerMtok = 99999, 99999, 99999
		rows[pricingLlamaKey] = r
	})

	type variant struct {
		name       string
		yaml       []byte
		overlay    []byte
		wantOK     bool
		wantErrSub string
	}
	variants := []variant{
		{name: "rate_card_only_splice", yaml: spliced, wantOK: true},
		{name: "rate_card_only_reformatted_rows", yaml: lane.spliceYAML(live, reformattedB()), wantOK: true},
		{name: "comment_only_outside_rate_card", yaml: append([]byte("# operator note: pricing change reviewed\n"), replaceOnce(spliced, "request_timeout_s: 60\n", "request_timeout_s: 60 # unchanged\n")...), wantOK: true},
		{name: "other_key_value_change", yaml: replaceOnce(spliced, "request_timeout_s: 60\n", "request_timeout_s: 61\n"), wantErrSub: "base_not_equivalent: routing.request_timeout_s"},
		{name: "explicit_tag_same_value", yaml: replaceOnce(spliced, "request_timeout_s: 60\n", "request_timeout_s: !!int 60\n"), wantErrSub: "base_not_equivalent"},
		{name: "quoting_style_same_value", yaml: replaceOnce(spliced, "level: info\n", "level: \"info\"\n"), wantErrSub: "base_not_equivalent"},
		{name: "key_order_swap", yaml: replaceOnce(spliced, "  buyer_port: ", "  zz_placeholder: "), wantErrSub: ""}, // replaced below
		{name: "rewards_global_change", yaml: replaceOnce(spliced, "provider_share: 0.9\n", "provider_share: 0.91\n"), wantErrSub: ""},
		{name: "rate_card_not_release_rows", yaml: lane.spliceYAML(live, rateCardBlock(cardC)), wantErrSub: "candidate_rate_card_not_release_rows"},
		{name: "no_change_against_card_B", yaml: liveRaw, wantErrSub: "autotune runtime economics"},
		{name: "overlay_shadows_changed_row", yaml: spliced, overlay: []byte(fmt.Sprintf("rewards:\n  rate_card:\n    %s:\n      prompt_credits_per_mtok: %d\n      prompt_cache_hit_credits_per_mtok: %d\n      completion_credits_per_mtok: %d\n",
			pricingLlamaKey, lane.cardA.Rows[pricingLlamaKey].PromptRatePerMtok, lane.cardA.Rows[pricingLlamaKey].PromptCacheHitRatePerMtok, lane.cardA.Rows[pricingLlamaKey].CompletionRatePerMtok)), wantErrSub: "autotune runtime economics"},
	}
	// Key order: swap the first two keys of `listen:` (bind_address, buyer_port).
	{
		idx := strings.Index(string(spliced), "listen:\n")
		if idx < 0 {
			t.Fatal("no listen block")
		}
		lines := strings.SplitAfter(string(spliced[idx:]), "\n")
		swapped := lines[0] + lines[2] + lines[1] + strings.Join(lines[3:], "")
		variants[6].yaml = append(append([]byte{}, spliced[:idx]...), []byte(swapped)...)
		variants[6].wantErrSub = "base_not_equivalent: listen"
	}
	variants[7].wantErrSub = "base_not_equivalent: rewards.provider_share"

	for _, v := range variants {
		t.Run(v.name, func(t *testing.T) {
			candidate := write("candidate-"+v.name+".yaml", v.yaml)
			var extra []string
			if v.overlay != nil {
				extra = append(extra, "-config-overlay", write("overlay-"+v.name+".yaml", v.overlay))
			}
			verdict, code, out := validate(candidate, extra...)
			if v.wantOK {
				if !verdict.OK || code != 0 {
					t.Fatalf("want accept, got exit %d: %s", code, out)
				}
				if verdict.SignedRateCardSHA256 != sha256HexBytes(cardBRaw) {
					t.Errorf("verdict signed_rate_card_sha256=%s want card B", verdict.SignedRateCardSHA256)
				}
				return
			}
			if verdict.OK || code == 0 {
				t.Fatalf("want reject (%s), got accept: %s", v.wantErrSub, out)
			}
			found := false
			for _, e := range verdict.Errors {
				if strings.Contains(e, v.wantErrSub) {
					found = true
				}
			}
			if !found {
				t.Errorf("errors %q lack %q", verdict.Errors, v.wantErrSub)
			}
		})
	}

	t.Run("resolve_model_names_odd_names", func(t *testing.T) {
		names := []string{
			"", "default", "DEFAULT", settlementFixtureModelID, "META-LLAMA/Llama-3.2-3B-Instruct",
			"  meta-llama/llama-3.2-3b-instruct  ", "llama-3.2-3b-instruct-free", pricingZeroRateKey,
			"unknown-vendor/unknown-model", "ünïcödé-model", "a\u202eb", "../../etc/passwd", pricingLlamaKey, pricingLlamaKey,
		}
		raw, _ := json.Marshal(names)
		namesPath := write("names.json", raw)
		verdict, code, out := validate(write("candidate-resolve.yaml", spliced), "-resolve-model-names", namesPath)
		if !verdict.OK || code != 0 {
			t.Fatalf("resolution run rejected: %s", out)
		}
		tableA, tableB := lane.cardA.table(), cardB.table()
		// Expected row per name under the §5.5 lookup (exact, normalized, default).
		expectRow := map[string]string{
			"":                                     "default",
			"default":                              "default",
			"DEFAULT":                              "default",
			settlementFixtureModelID:               pricingLlamaKey,
			"META-LLAMA/Llama-3.2-3B-Instruct":     pricingLlamaKey,
			"  meta-llama/llama-3.2-3b-instruct  ": pricingLlamaKey,
			"llama-3.2-3b-instruct-free":           pricingLlamaKey,
			pricingZeroRateKey:                     pricingZeroRateKey,
			"unknown-vendor/unknown-model":         "default",
			"ünïcödé-model":                        "default",
			"a\u202eb":                             "default",
			"../../etc/passwd":                     "default",
			pricingLlamaKey:                        pricingLlamaKey,
		}
		if len(verdict.ModelResolutions) != len(expectRow) {
			t.Errorf("model_resolutions has %d entries, want %d (deduplicated): %s", len(verdict.ModelResolutions), len(expectRow), out)
		}
		for _, r := range verdict.ModelResolutions {
			want, ok := expectRow[r.Name]
			if !ok {
				t.Errorf("unexpected resolution name %q", r.Name)
				continue
			}
			if r.Old.RowKey != want || r.New.RowKey != want {
				t.Errorf("%q resolved old=%q new=%q want %q", r.Name, r.Old.RowKey, r.New.RowKey, want)
				continue
			}
			a, b := tableA[want], tableB[want]
			if r.Old.Prompt != a.Prompt || r.Old.CacheHit != a.CacheHit || r.Old.Completion != a.Completion {
				t.Errorf("%q old=%+v want table A row %+v", r.Name, r.Old, a)
			}
			if r.New.Prompt != b.Prompt || r.New.CacheHit != b.CacheHit || r.New.Completion != b.Completion {
				t.Errorf("%q new=%+v want table B row %+v", r.Name, r.New, b)
			}
		}
	})

	t.Run("resolve_model_names_requires_expect_base", func(t *testing.T) {
		cmd := exec.Command(coordinatorBin, "-config", live, "-validate-autotune-release", release, "-resolve-model-names", write("n2.json", []byte(`["x"]`)))
		out, err := cmd.CombinedOutput()
		ee, ok := err.(*exec.ExitError)
		if !ok || ee.ExitCode() != 2 {
			t.Fatalf("want exit 2, got %v: %s", err, out)
		}
	})
}
