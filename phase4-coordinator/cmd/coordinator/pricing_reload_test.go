package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
	"gopkg.in/yaml.v3"
)

// SPEC-005-R013 / SPEC-023-R018 coordinator side of the pricing lane: the
// reload transition table, the applied-config pricing fields, and the
// validator's pricing extensions.

func pricingRewards(prompt, completion int64) config.RewardsConfig {
	return coordinatorParityRewards(map[string]config.RateCardEntry{
		"default":  coordinatorParityEntry(100, 100, 200),
		"qwen3-8b": coordinatorParityEntry(prompt, prompt, completion),
	})
}

type pricingReloadHarness struct {
	liveRoot  string
	startup   config.Config
	ws        *providerws.Server
	buyer     *buyer.Server
	store     *billing.Store
	db        *sql.DB
	statePath string
}

// newPricingReloadHarness boots a coordinator on a signed release whose rate
// card is `rewards`, the way main() does: parity, boot snapshot, served feeds,
// applied-config record.
func newPricingReloadHarness(t *testing.T, rewards config.RewardsConfig) *pricingReloadHarness {
	t.Helper()
	h := &pricingReloadHarness{liveRoot: t.TempDir(), statePath: useAppliedConfigStatePath(t)}
	_, _, tier2Pub := writeValidatorRelease(t, filepath.Join(h.liveRoot, "current"), "release-live", reloadTestHash)
	cfg := validatorConfig(h.liveRoot, tier2Pub)
	cfg.Rewards = rewards
	h.writeRateCard(t, rewards)
	h.startup, _, h.ws, h.buyer = reloadTestServers(cfg)
	if err := tier2.Configure(h.startup.Tier2, zerolog.Nop()); err != nil {
		t.Fatalf("startup Configure: %v", err)
	}
	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	h.db = reqLog.DB()
	if h.store, err = billing.NewStore(h.db); err != nil {
		t.Fatal(err)
	}
	feeds, err := buyer.LoadAutotuneFeeds(h.startup.AutotuneFeeds)
	if err != nil {
		t.Fatal(err)
	}
	if err := validateAutotuneRuntimeEconomics(feeds, h.startup); err != nil {
		t.Fatal(err)
	}
	bootID, err := h.store.InsertConfigSnapshot(context.Background(), rewards, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	h.buyer.PublishEconomics(rewards, bootID, h.startup.Stats.Rollup.UsdPerMillionCredits, &feeds)
	configPath := writeReloadConfig(t, h.startup)
	_, digests, err := config.LoadWithOverlayDigests(configPath, "")
	if err != nil {
		t.Fatal(err)
	}
	recordAppliedConfig(zerolog.Nop(), "boot", configPath, "", digests, time.Now().UTC(), h.buyer.AppliedEconomics())
	return h
}

func (h *pricingReloadHarness) writeRateCard(t *testing.T, rewards config.RewardsConfig) []byte {
	t.Helper()
	raw := coordinatorParityFeeds(t, rewards, 1.0).RateCardJSON
	writeValidatorSigned(t, filepath.Join(h.liveRoot, "current", "rate-card.json"), raw)
	return raw
}

func (h *pricingReloadHarness) reload(t *testing.T, rewards config.RewardsConfig) string {
	t.Helper()
	cfg := h.startup
	cfg.Rewards = rewards
	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, cfg), "", h.startup.Tier2, zerolog.New(&logs), h.ws, h.buyer, nil, nil, nil, h.store)
	return logs.String()
}

func (h *pricingReloadHarness) snapshotRows(t *testing.T, table string) int {
	t.Helper()
	var n int
	if err := h.db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func (h *pricingReloadHarness) servedRateCard(t *testing.T) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card", nil)
	rr := httptest.NewRecorder()
	h.buyer.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("rate card status=%d", rr.Code)
	}
	return rr.Body.String()
}

type pricingState struct {
	record    []byte
	economics buyer.AppliedEconomics
	card      string
}

func (h *pricingReloadHarness) state(t *testing.T) pricingState {
	t.Helper()
	raw, err := os.ReadFile(h.statePath)
	if err != nil {
		t.Fatal(err)
	}
	return pricingState{record: raw, economics: h.buyer.AppliedEconomics(), card: h.servedRateCard(t)}
}

func (h *pricingReloadHarness) assertUnchanged(t *testing.T, before pricingState, rows int, what string) {
	t.Helper()
	after := h.state(t)
	if !bytes.Equal(after.record, before.record) {
		t.Fatalf("%s rewrote the applied-config record:\nbefore=%s\nafter=%s", what, before.record, after.record)
	}
	if after.economics != before.economics || after.card != before.card {
		t.Fatalf("%s published pricing: before=%+v after=%+v", what, before.economics, after.economics)
	}
	if got := h.snapshotRows(t, "ledger_config_snapshots"); got != rows {
		t.Fatalf("%s wrote %d snapshot rows, want 0", what, got-rows)
	}
}

func TestPricingReloadTransitionTable(t *testing.T) {
	defer tier2.ResetForTest()
	a := pricingRewards(13500, 27000)
	h := newPricingReloadHarness(t, a)
	boot := readAppliedConfigRecord(t, h.statePath)
	wantA, _ := billing.RateTableDigest(a)
	if boot.Source != "boot" || boot.RateTableSHA256 != wantA || boot.SignedRateCardSHA256 != sha256Hex(coordinatorParityFeeds(t, a, 1.0).RateCardJSON) ||
		boot.AutotuneReleaseID != "release-live" || boot.BillingSnapshotID == 0 || boot.Schema != appliedConfigSchema {
		t.Fatalf("boot record=%+v", boot)
	}
	b := pricingRewards(20000, 40000)
	c := pricingRewards(30000, 60000)

	// Row 1: the feed reload fails (prior feeds kept) while the table changed
	// ⇒ parity against the retained card rejects; nothing written or published.
	before, rows := h.state(t), h.snapshotRows(t, "ledger_config_snapshots")
	cardB := h.writeRateCard(t, b)
	if err := os.WriteFile(filepath.Join(h.liveRoot, "current", "rate-card.json.sig"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if logs := h.reload(t, b); !strings.Contains(logs, "autotune runtime economics reload rejected") {
		t.Fatalf("feed-load failure + table change was not a parity rejection: %s", logs)
	}
	h.assertUnchanged(t, before, rows, "feed-load failure")

	// Row 2: reject before billing (parity: table C against signed card B).
	h.writeRateCard(t, b)
	if logs := h.reload(t, c); !strings.Contains(logs, "autotune runtime economics reload rejected") {
		t.Fatalf("parity mismatch not rejected: %s", logs)
	}
	h.assertUnchanged(t, before, rows, "parity rejection")

	// Row 3: the billing txn fails after the Tier-2 setters ran ⇒ 0 rows, the
	// table and served card unchanged.
	if _, err := h.db.Exec(`ALTER TABLE ledger_config_snapshots RENAME TO ledger_config_snapshots_offline`); err != nil {
		t.Fatal(err)
	}
	if logs := h.reload(t, b); !strings.Contains(logs, "billing config reload rejected") {
		t.Fatalf("billing txn failure not logged: %s", logs)
	}
	if _, err := h.db.Exec(`ALTER TABLE ledger_config_snapshots_offline RENAME TO ledger_config_snapshots`); err != nil {
		t.Fatal(err)
	}
	h.assertUnchanged(t, before, rows, "billing txn failure")

	// Row 4: success ⇒ exactly one row; table and card switch together; the
	// record carries the committed snapshot and the served card.
	h.reload(t, b)
	if got := h.snapshotRows(t, "ledger_config_snapshots"); got != rows+1 {
		t.Fatalf("successful reload wrote %d snapshot rows, want 1", got-rows)
	}
	rec := readAppliedConfigRecord(t, h.statePath)
	wantB, _ := billing.RateTableDigest(b)
	var storedID int64
	var storedJSON string
	if err := h.db.QueryRow(`SELECT id, rate_card_json FROM ledger_config_snapshots ORDER BY id DESC LIMIT 1`).Scan(&storedID, &storedJSON); err != nil {
		t.Fatal(err)
	}
	if rec.Source != "sighup" || rec.RateTableSHA256 != wantB || rec.RateTableSHA256 != sha256Hex([]byte(storedJSON)) ||
		rec.SignedRateCardSHA256 != sha256Hex(cardB) || rec.BillingSnapshotID != storedID || rec.BillingSnapshotID <= boot.BillingSnapshotID ||
		rec.AutotuneReleaseID != "release-live" || rec.Schema != appliedConfigSchema {
		t.Fatalf("success record=%+v want table %s card %s snapshot %d", rec, wantB, sha256Hex(cardB), storedID)
	}
	if h.servedRateCard(t) != string(cardB) {
		t.Fatal("served card did not switch with the table")
	}

	// Rollback: the prior pair applied again ⇒ one more row, prior digests.
	h.writeRateCard(t, a)
	h.reload(t, a)
	back := readAppliedConfigRecord(t, h.statePath)
	if back.RateTableSHA256 != boot.RateTableSHA256 || back.SignedRateCardSHA256 != boot.SignedRateCardSHA256 || back.BillingSnapshotID <= rec.BillingSnapshotID {
		t.Fatalf("rollback record=%+v boot=%+v", back, boot)
	}
	if got := h.snapshotRows(t, "ledger_config_snapshots"); got != rows+2 {
		t.Fatalf("snapshot rows after rollback=%d want %d", got, rows+2)
	}
}

// A reload that keeps the served feeds (no feed paths change) records the
// card still served, not an empty one.
func TestPricingReloadRecordKeepsServedCardWhenFeedsAreRetained(t *testing.T) {
	defer tier2.ResetForTest()
	a := pricingRewards(13500, 27000)
	h := newPricingReloadHarness(t, a)
	boot := readAppliedConfigRecord(t, h.statePath)
	// Break the feed load; the table is unchanged, so parity against the
	// retained card passes and the reload applies.
	if err := os.WriteFile(filepath.Join(h.liveRoot, "current", "rate-card.json.sig"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.reload(t, a)
	rec := readAppliedConfigRecord(t, h.statePath)
	if rec.Source != "sighup" || rec.SignedRateCardSHA256 != boot.SignedRateCardSHA256 || rec.SignedRateCardSHA256 == "" || rec.BillingSnapshotID <= boot.BillingSnapshotID {
		t.Fatalf("record=%+v boot=%+v", rec, boot)
	}
}

// ---- validator: rate_table_sha256 / signed_rate_card_sha256

func TestValidateAutotuneReleaseReportsPricingDigests(t *testing.T) {
	defer tier2.ResetForTest()
	base := t.TempDir()
	dir := filepath.Join(base, "candidate")
	_, _, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadTestHash)
	cfg := validatorConfig(filepath.Join(base, "live"), tier2Pub)
	got := validateAutotuneRelease(writeReloadConfig(t, cfg), "", dir, "", zerolog.Nop())
	if !got.OK {
		t.Fatalf("validator=%+v", got)
	}
	card, err := os.ReadFile(filepath.Join(dir, "rate-card.json"))
	if err != nil {
		t.Fatal(err)
	}
	want, _ := billing.RateTableDigest(cfg.Rewards)
	if got.RateTableSHA256 != want || got.SignedRateCardSHA256 != sha256Hex(card) {
		t.Fatalf("digests=%s/%s want %s/%s", got.RateTableSHA256, got.SignedRateCardSHA256, want, sha256Hex(card))
	}
	if got.ModelResolutions == nil || len(got.ModelResolutions) != 0 {
		t.Fatalf("model_resolutions=%v want []", got.ModelResolutions)
	}
}

// ---- validator: --expect-base-equivalent and --resolve-model-names

type pricingValidatorFixture struct {
	dir, liveBase, candidate string
	live, next               config.Config
}

// newPricingValidatorFixture: the live base prices A; the candidate is the
// live base with only its rate_card (and comments) changed to the release's
// rows B.
func newPricingValidatorFixture(t *testing.T) pricingValidatorFixture {
	t.Helper()
	base := t.TempDir()
	f := pricingValidatorFixture{dir: filepath.Join(base, "candidate")}
	_, _, tier2Pub := writeValidatorRelease(t, f.dir, "release-next", reloadTestHash)
	f.live = validatorConfig(filepath.Join(base, "live"), tier2Pub)
	f.live.Rewards = pricingRewards(13500, 27000)
	f.next = f.live
	f.next.Rewards = pricingRewards(20000, 40000)
	f.next.Rewards.RateCard["meta-llama/llama-3.2-3b-instruct"] = coordinatorParityEntry(5000, 5000, 9000)
	writeValidatorSigned(t, filepath.Join(f.dir, "rate-card.json"), coordinatorParityFeeds(t, f.next.Rewards, 1.0).RateCardJSON)
	f.liveBase = writeReloadConfig(t, f.live)
	raw, err := yaml.Marshal(f.next)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.Replace(string(raw), "    rate_card:\n", "    rate_card:\n        # corrected 2026-09 (#1693): provenance lives inside the block\n", 1)
	f.candidate = filepath.Join(base, "candidate.yaml")
	if err := os.WriteFile(f.candidate, []byte("# candidate\n"+text), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestValidateAutotuneReleaseExpectBaseEquivalentAcceptsRateCardOnlyDiff(t *testing.T) {
	defer tier2.ResetForTest()
	f := newPricingValidatorFixture(t)
	got := validateAutotuneRelease(f.candidate, "", f.dir, "", zerolog.Nop(), autotuneReleaseValidationOptions{ExpectBaseEquivalent: f.liveBase})
	if !got.OK {
		t.Fatalf("rate-card-only diff rejected: %+v", got)
	}
	raw, _ := os.ReadFile(f.candidate)
	if got.ConfigSHA256 != sha256Hex(raw) {
		t.Fatalf("config_sha256=%s want candidate %s", got.ConfigSHA256, sha256Hex(raw))
	}
	if want, _ := billing.RateTableDigest(f.next.Rewards); got.RateTableSHA256 != want {
		t.Fatalf("rate_table_sha256=%s want %s", got.RateTableSHA256, want)
	}
}

func TestValidateAutotuneReleaseExpectBaseEquivalentRejectsOtherChanges(t *testing.T) {
	defer tier2.ResetForTest()
	f := newPricingValidatorFixture(t)
	raw, err := os.ReadFile(f.candidate)
	if err != nil {
		t.Fatal(err)
	}
	mutated := strings.Replace(string(raw), "    global_multiplier: 1\n", "    global_multiplier: 1.0\n", 1)
	if mutated == string(raw) {
		t.Fatalf("fixture lacks rewards.global_multiplier line:\n%s", raw)
	}
	path := filepath.Join(t.TempDir(), "mutated.yaml")
	if err := os.WriteFile(path, []byte(mutated), 0o600); err != nil {
		t.Fatal(err)
	}
	got := validateAutotuneRelease(path, "", f.dir, "", zerolog.Nop(), autotuneReleaseValidationOptions{ExpectBaseEquivalent: f.liveBase})
	assertValidatorError(t, got, "base_not_equivalent: rewards.global_multiplier")
}

// The candidate's own rate_card must be the release rows; an overlay that
// patches the effective table into parity does not make it so.
func TestValidateAutotuneReleaseExpectBaseEquivalentRequiresCandidateRowsEqualRelease(t *testing.T) {
	defer tier2.ResetForTest()
	f := newPricingValidatorFixture(t)
	stale := f.next
	stale.Rewards = pricingRewards(20000, 40000)
	stale.Rewards.RateCard["meta-llama/llama-3.2-3b-instruct"] = coordinatorParityEntry(5001, 5000, 9000)
	candidate := writeReloadConfig(t, stale)
	overlay := writeReloadOverlay(t, "rewards:\n  rate_card:\n    meta-llama/llama-3.2-3b-instruct:\n      prompt_credits_per_mtok: 5000\n      prompt_cache_hit_credits_per_mtok: 5000\n      completion_credits_per_mtok: 9000\n")
	plain := validateAutotuneRelease(candidate, overlay, f.dir, "", zerolog.Nop())
	if !plain.OK {
		t.Fatalf("precondition: overlay-patched effective table passes parity: %+v", plain)
	}
	got := validateAutotuneRelease(candidate, overlay, f.dir, "", zerolog.Nop(), autotuneReleaseValidationOptions{ExpectBaseEquivalent: f.liveBase})
	assertValidatorError(t, got, "candidate_rate_card_not_release_rows")
}

func TestValidateAutotuneReleaseResolvesModelNamesAgainstLiveAndCandidate(t *testing.T) {
	defer tier2.ResetForTest()
	f := newPricingValidatorFixture(t)
	names := filepath.Join(t.TempDir(), "names.json")
	if err := os.WriteFile(names, []byte(`["mlx-community/Qwen3-8B-4bit","mlx-community/Llama-3.2-3B-Instruct-4bit","bad\u0000name","mlx-community/Qwen3-8B-4bit"]`), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	code := runValidateAutotuneRelease(&out, f.candidate, "", f.dir, "", autotuneReleaseValidationOptions{ExpectBaseEquivalent: f.liveBase, ResolveModelNames: names})
	if code != 0 {
		t.Fatalf("exit=%d output=%s", code, out.String())
	}
	var got autotuneReleaseValidation
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	want := []autotuneModelResolution{
		{Name: "bad\x00name", Old: autotuneResolvedRate{"default", 100, 100, 200}, New: autotuneResolvedRate{"default", 100, 100, 200}},
		{Name: "mlx-community/Llama-3.2-3B-Instruct-4bit", Old: autotuneResolvedRate{"default", 100, 100, 200}, New: autotuneResolvedRate{"meta-llama/llama-3.2-3b-instruct", 5000, 5000, 9000}},
		{Name: "mlx-community/Qwen3-8B-4bit", Old: autotuneResolvedRate{"qwen3-8b", 13500, 13500, 27000}, New: autotuneResolvedRate{"qwen3-8b", 20000, 20000, 40000}},
	}
	if len(got.ModelResolutions) != len(want) {
		t.Fatalf("model_resolutions=%+v want %+v", got.ModelResolutions, want)
	}
	for i := range want {
		if got.ModelResolutions[i] != want[i] {
			t.Fatalf("model_resolutions[%d]=%+v want %+v", i, got.ModelResolutions[i], want[i])
		}
	}
	if !strings.Contains(out.String(), `"name":"bad\u0000name"`) {
		t.Fatalf("control character not escaped in JSON: %s", out.String())
	}
	noBase := validateAutotuneRelease(f.candidate, "", f.dir, "", zerolog.Nop(), autotuneReleaseValidationOptions{ResolveModelNames: names})
	assertValidatorError(t, noBase, "requires --expect-base-equivalent")
}

func TestYAMLTreesEquivalentExceptRateCardMatrix(t *testing.T) {
	const live = `# live
stats:
  rollup:
    usd_per_million_credits: 1
rewards:
  global_multiplier: 1 # inline
  provider_share: 0.9
  rate_card:
    default:
      prompt_credits_per_mtok: 1
tier2:
  catalog_path: /opt/a
  list: [a, b]
  rate_card: x
`
	parse := func(t *testing.T, text string) *yaml.Node {
		t.Helper()
		var doc yaml.Node
		if err := yaml.Unmarshal([]byte(text), &doc); err != nil {
			t.Fatal(err)
		}
		return &doc
	}
	for _, tc := range []struct {
		name, candidate, wantPath string
	}{
		{"rate card and comments only", strings.Replace(strings.Replace(live, "prompt_credits_per_mtok: 1", "prompt_credits_per_mtok: 2\n      completion_credits_per_mtok: 3\n    # added row\n    qwen3-8b:\n      prompt_credits_per_mtok: 9", 1), "# live", "# changed header", 1) + "# trailing\n", ""},
		{"value change", strings.Replace(live, "provider_share: 0.9", "provider_share: 0.8", 1), "rewards.provider_share"},
		{"tag change", strings.Replace(live, "catalog_path: /opt/a", "catalog_path: !!str /opt/a", 1), "tier2.catalog_path"},
		{"style change", strings.Replace(live, "catalog_path: /opt/a", `catalog_path: "/opt/a"`, 1), "tier2.catalog_path"},
		{"flow to block", strings.Replace(live, "list: [a, b]", "list:\n    - a\n    - b", 1), "tier2.list"},
		{"key order", strings.Replace(live, "  global_multiplier: 1 # inline\n  provider_share: 0.9\n", "  provider_share: 0.9\n  global_multiplier: 1 # inline\n", 1), "rewards.global_multiplier"},
		{"added key", live + "extra: true\n", "(root)"},
		{"rate_card removed", strings.Replace(live, "  rate_card:\n    default:\n      prompt_credits_per_mtok: 1\n", "", 1), "rewards"},
		{"rate_card outside rewards is compared", strings.Replace(live, "rate_card: x", "rate_card: y", 1), "tier2.rate_card"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path, same := yamlTreesEquivalentExceptRateCard(parse(t, live), parse(t, tc.candidate))
			if tc.wantPath == "" {
				if !same {
					t.Fatalf("rejected at %s", path)
				}
				return
			}
			if same || path != tc.wantPath {
				t.Fatalf("path=%q same=%v want %q", path, same, tc.wantPath)
			}
		})
	}
}

func TestLoadSingleYAMLDocumentRejectsMultiDocument(t *testing.T) {
	path := filepath.Join(t.TempDir(), "multi.yaml")
	if err := os.WriteFile(path, []byte("a: 1\n---\nb: 2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadSingleYAMLDocument(path); err == nil {
		t.Fatal("multi-document YAML accepted")
	}
}
