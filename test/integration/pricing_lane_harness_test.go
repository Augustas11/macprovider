package integration

// #1693 pricing lane, tier E1 harness (docs/testing/1693-pricing-lane-e2e-plan.md).
//
// A pricingLane is a scenario whose coordinator runs on a signed autotune
// release laid out like the deployed host (<root>/current/*.json + .sig),
// signed by a TEST keyring generated per test (never an operator key), with
// the applied-config record redirected to a temp file, and with the
// coordinator yaml written in the 2-space form the operator lane's
// `catalog-release.py splice-coordinator-rate-card` parses. Card A is the
// committed static rate card re-signed with the test key (so the served
// candidates / demand-rank bytes and the fake provider's catalog envelope are
// unchanged); card B is derived from it in the test.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	pricingTestKeyID      = "integration-pricing-test-key"
	pricingLlamaKey       = staticLlama32CandidateKey // "meta-llama/llama-3.2-3b-instruct"
	pricingZeroRateKey    = "qwen3-8b"
	pricingReloadDeadline = 30 * time.Second
)

// pricingCardRow is one signed rate-card row (SPEC-023 §3.3.1).
type pricingCardRow struct {
	CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	GlobalMultiplierPPM       int64 `json:"global_multiplier_ppm"`
	PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
	PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
	ProviderShareBPS          int64 `json:"provider_share_bps"`
}

type pricingCard struct {
	GeneratedAt          string                    `json:"generated_at"`
	PolicyVersion        string                    `json:"policy_version"`
	Rows                 map[string]pricingCardRow `json:"rows"`
	USDPerMillionCredits float64                   `json:"usd_per_million_credits"`
	Version              string                    `json:"version"`
}

// pricingEntry is one request-table row as the billing snapshot stores it.
type pricingEntry struct {
	Prompt     int64
	CacheHit   int64
	Completion int64
}

type pricingTable map[string]pricingEntry

func (c pricingCard) table() pricingTable {
	out := pricingTable{}
	for k, r := range c.Rows {
		out[k] = pricingEntry{Prompt: r.PromptRatePerMtok, CacheHit: r.PromptCacheHitRatePerMtok, Completion: r.CompletionRatePerMtok}
	}
	return out
}

func (a pricingTable) equal(b pricingTable) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

// resolve mirrors the §5.5 lookup order (exact, normalized, default) for the
// only model names this suite sends: the fixture's served id normalizes to
// the llama catalog key.
func (a pricingTable) resolve(model string) (string, pricingEntry) {
	if e, ok := a[model]; ok {
		return model, e
	}
	aliases := map[string]string{
		settlementFixtureModelID:           pricingLlamaKey,
		"llama-3.2-3b-instruct":            pricingLlamaKey,
		"llama-3.2-3b-instruct-free":       pricingLlamaKey,
		"meta-llama/llama-3.2-3b-instruct": pricingLlamaKey,
	}
	if k, ok := aliases[model]; ok {
		if e, ok := a[k]; ok {
			return k, e
		}
	}
	if e, ok := a["default"]; ok {
		return "default", e
	}
	return "", pricingEntry{}
}

// pricingCardVersion is the SPEC-023 rate-card projection hash (the feed's
// `version`), the same canonical form validateRateCardFeed recomputes.
func pricingCardVersion(rows map[string]pricingCardRow, shareBPS, multiplierPPM int64, usd float64) string {
	keys := make([]string, 0, len(rows))
	for k := range rows {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(`{"global_multiplier_ppm":`)
	b.WriteString(strconv.FormatInt(multiplierPPM, 10))
	b.WriteString(`,"provider_share_bps":`)
	b.WriteString(strconv.FormatInt(shareBPS, 10))
	b.WriteString(`,"rows":{`)
	for i, key := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		encodedKey, _ := json.Marshal(key)
		row := rows[key]
		b.Write(encodedKey)
		fmt.Fprintf(&b, `:{"completion_rate_per_mtok":%d,"global_multiplier_ppm":%d,"prompt_cache_hit_rate_per_mtok":%d,"prompt_rate_per_mtok":%d,"provider_share_bps":%d}`,
			row.CompletionRatePerMtok, row.GlobalMultiplierPPM, row.PromptCacheHitRatePerMtok, row.PromptRatePerMtok, row.ProviderShareBPS)
	}
	b.WriteString(`},"usd_per_million_credits":`)
	b.WriteString(strconv.FormatFloat(usd, 'f', -1, 64))
	b.WriteByte('}')
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

func sha256HexBytes(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// pricingKeyring is the per-test feed signer.
type pricingKeyring struct {
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
}

func newPricingKeyring(t *testing.T) pricingKeyring {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate test feed key: %v", err)
	}
	return pricingKeyring{pub: pub, priv: priv}
}

func (k pricingKeyring) sidecar(t *testing.T, raw []byte) []byte {
	t.Helper()
	out, err := json.Marshal(map[string]string{
		"key_id":    pricingTestKeyID,
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(k.priv, raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func (k pricingKeyring) verify(body, sig []byte) bool {
	var side struct {
		KeyID     string `json:"key_id"`
		Signature string `json:"signature"`
	}
	if json.Unmarshal(sig, &side) != nil || side.KeyID != pricingTestKeyID {
		return false
	}
	raw, err := base64.StdEncoding.DecodeString(side.Signature)
	if err != nil {
		return false
	}
	return ed25519.Verify(k.pub, body, raw)
}

// writeSignedAtomic installs raw + its sidecar via rename, sidecar first,
// so a concurrent reader sees either the old or the new file (the lane swaps
// `current` as a whole; the reload reads both after the SIGHUP anyway).
func (k pricingKeyring) writeSignedAtomic(t *testing.T, path string, raw []byte) {
	t.Helper()
	writeFileAtomic(t, path+".sig", k.sidecar(t, raw))
	writeFileAtomic(t, path, raw)
}

func writeFileAtomic(t *testing.T, path string, raw []byte) {
	t.Helper()
	tmp := path + ".tmp-install"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		t.Fatalf("write %s: %v", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatalf("rename %s: %v", path, err)
	}
}

type pricingLaneOpts struct {
	providerCount      int
	raceCoordinator    bool
	gatewayConcurrency int
	extraAccounts      int
}

type pricingLane struct {
	*scenario
	keys       pricingKeyring
	liveRoot   string // <tmp>/autotune (the release root)
	currentDir string // <tmp>/autotune/current
	statePath  string // applied-config record
	coordBin   string
	cardARaw   []byte
	cardA      pricingCard
	catalog    settlementCatalogFixture
	extraKeys  []pricingAccount
	repoRoot   string
}

type pricingAccount struct {
	accountID string
	apiKey    string
}

// preparePricingFiles writes the signed release (test keyring), the Tier-2
// catalog and the 2-space coordinator yaml, without starting anything. J7
// uses it alone; newPricingLane builds on it.
func preparePricingFiles(t *testing.T, s *scenario, buyerPort, provPort int, providerCfgs []map[string]any) (*pricingLane, settlementCatalogFixture) {
	t.Helper()
	repoRoot, err := findRepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	lane := &pricingLane{scenario: s, keys: newPricingKeyring(t), repoRoot: repoRoot}
	lane.liveRoot = filepath.Join(s.tempDir, "autotune")
	lane.currentDir = filepath.Join(lane.liveRoot, "current")
	lane.statePath = filepath.Join(s.tempDir, "run", "coordinator-applied-config.json")
	if err := os.MkdirAll(lane.currentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	catalog := s.writeSettlementCatalogFixture()
	for _, name := range []string{"autotune-candidates.json", "demand-rank.json", "rate-card.json"} {
		raw, err := os.ReadFile(filepath.Join(repoRoot, "phase3-binary", "dist", "static", name))
		if err != nil {
			t.Fatalf("read static %s: %v", name, err)
		}
		lane.keys.writeSignedAtomic(t, filepath.Join(lane.currentDir, name), raw)
		if name == "rate-card.json" {
			lane.cardARaw = raw
		}
	}
	if err := json.Unmarshal(lane.cardARaw, &lane.cardA); err != nil {
		t.Fatalf("parse card A: %v", err)
	}
	def := lane.cardA.Rows["default"]
	if got := pricingCardVersion(lane.cardA.Rows, def.ProviderShareBPS, def.GlobalMultiplierPPM, lane.cardA.USDPerMillionCredits); got != lane.cardA.Version {
		t.Fatalf("test canonical rate-card version %s != static card version %s (harness projection drifted from validateRateCardFeed)", got, lane.cardA.Version)
	}
	catalog.rateCardPath = filepath.Join(lane.currentDir, "rate-card.json")
	catalog.rateCardSigPath = catalog.rateCardPath + ".sig"
	catalog.demandRankPath = filepath.Join(lane.currentDir, "demand-rank.json")
	catalog.demandRankSigPath = catalog.demandRankPath + ".sig"
	catalog.autotuneCatalogPath = filepath.Join(lane.currentDir, "autotune-candidates.json")
	catalog.autotuneCatalogSigPath = catalog.autotuneCatalogPath + ".sig"
	lane.catalog = catalog

	s.writeCoordinatorYAML(buyerPort, provPort, false, s.serviceToken, providerCfgs, catalog, false, 0, false, nil)
	raw, err := os.ReadFile(s.coordYAML)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	autotune := cfg["autotune"].(map[string]any)
	autotune["public_keys"] = map[string]string{pricingTestKeyID: base64.StdEncoding.EncodeToString(lane.keys.pub)}
	writeYAML2(t, s.coordYAML, cfg)
	return lane, catalog
}

// writeYAML2 writes cfg with 2-space indentation: the shape of the deployed
// coordinator.yaml that the lane's rewards-block parser requires.
func writeYAML2(t *testing.T, path string, cfg any) {
	t.Helper()
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(cfg); err != nil {
		t.Fatalf("encode yaml: %v", err)
	}
	_ = enc.Close()
	writeFileAtomic(t, path, buf.Bytes())
}

func newPricingLane(t *testing.T, opts pricingLaneOpts) *pricingLane {
	t.Helper()
	requireBins(t)
	if opts.providerCount == 0 {
		opts.providerCount = 1
	}
	tempDir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	s := &scenario{
		t:             t,
		tempDir:       tempDir,
		coordinatorDB: filepath.Join(tempDir, "coordinator.db"),
		gatewayDB:     filepath.Join(tempDir, "gateway.db"),
		coordYAML:     filepath.Join(tempDir, "coordinator.yaml"),
		gatewayYAML:   filepath.Join(tempDir, "gateway.yaml"),
		operatorKey:   strongHexSecret(t),
		serviceToken:  strongHexSecret(t),
		keyHashSecret: randHex(t, 32),
		demoSecret:    randHex(t, 32),
		accountID:     "acct_" + randHex(t, 8),
		providerID:    "prov-" + randHex(t, 4),
		rootCtx:       ctx,
		cancelAll:     cancel,
		coordLogBuf:   newLogBuffer(),
	}
	t.Cleanup(s.shutdown)
	buyerPort, provPort, gwPort := allocatePort(t), allocatePort(t), allocatePort(t)
	s.coordBuyerURL = fmt.Sprintf("http://127.0.0.1:%d", buyerPort)
	s.coordProvURL = fmt.Sprintf("http://127.0.0.1:%d", provPort)
	s.gatewayBaseURL = fmt.Sprintf("http://127.0.0.1:%d", gwPort)
	type slot struct {
		id   string
		port int
	}
	slots := make([]slot, opts.providerCount)
	providerCfgs := make([]map[string]any, opts.providerCount)
	for i := range slots {
		id := s.providerID
		if i > 0 {
			id = fmt.Sprintf("%s-%d", s.providerID, i)
		}
		slots[i] = slot{id: id, port: allocatePort(t)}
		providerCfgs[i] = map[string]any{
			"provider_id":  id,
			"display_name": fmt.Sprintf("fake-pricing-%d", i),
			"endpoint_url": fmt.Sprintf("http://127.0.0.1:%d", slots[i].port),
		}
	}
	lane, catalog := preparePricingFiles(t, s, buyerPort, provPort, providerCfgs)
	s.modelHash = catalog.modelHash
	s.rateCardSHA256 = sha256HexBytes(lane.cardARaw)
	s.rateCardVersion = lane.cardA.Version
	s.autotuneCatalogVersion = catalog.autotuneCatalogVersion
	s.autotuneCatalogSHA256 = catalog.autotuneCatalogSHA256
	s.settlementCatalogID = catalog.catalogID
	s.settlementCatalogKeyID = catalog.catalogKeyID

	lane.coordBin = coordinatorBin
	if opts.raceCoordinator {
		lane.coordBin = raceCoordinatorBinary(t)
	}

	s.writeGatewayYAML(gwPort, false, s.serviceToken, 0, false)
	if opts.gatewayConcurrency > 0 {
		raw, err := os.ReadFile(s.gatewayYAML)
		if err != nil {
			t.Fatal(err)
		}
		var gw map[string]any
		if err := yaml.Unmarshal(raw, &gw); err != nil {
			t.Fatal(err)
		}
		quotas := gw["quotas"].(map[string]any)
		quotas["account_concurrency"] = opts.gatewayConcurrency
		quotas["account_daily_tokens"] = 100000000
		writeYAML2(t, s.gatewayYAML, gw)
	}
	s.apiKey = s.seedGatewayAccountAndKey()
	for i := 0; i < opts.extraAccounts; i++ {
		lane.extraKeys = append(lane.extraKeys, lane.seedExtraAccount())
	}

	tokens := make([]string, len(slots))
	for i, sl := range slots {
		tokens[i] = s.issueProviderToken(sl.id, fmt.Sprintf("fake-pricing-%d", i))
	}
	s.providerToken = tokens[0]

	lane.startCoordinator()
	s.waitForHealth(s.coordBuyerURL + "/healthz")
	s.waitForHealth(s.coordProvURL + "/healthz")
	for i, sl := range slots {
		fp := newFakeProvider(t, sl.id, sl.port, s.coordProvURL, tokens[i])
		fp.enableSettlementReceipts(catalog)
		fp.catalogSignerKeyID = pricingTestKeyID
		fp.start(ctx)
		s.fakeProvs = append(s.fakeProvs, fp)
		s.waitForProviderReady(sl.id)
	}
	s.fakeProv = s.fakeProvs[0]
	s.startGateway(ctx)
	s.waitForHealth(s.gatewayBaseURL + "/healthz")
	lane.waitAppliedSource("boot")
	return lane
}

// seedExtraAccount inserts another active account + API key into the
// already-migrated gateway DB (same HMAC scheme as seedGatewayAccountAndKey).
func (p *pricingLane) seedExtraAccount() pricingAccount {
	t := p.t
	t.Helper()
	db, err := sql.Open("sqlite", p.gatewayDB)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	accountID := "acct_" + randHex(t, 8)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.Exec(`INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)`, accountID, now); err != nil {
		t.Fatalf("seed extra account: %v", err)
	}
	fullKey := "mp_" + base64.RawURLEncoding.EncodeToString([]byte(randHex(t, 16)))
	hash := hmacSHA256([]byte(p.keyHashSecret), []byte(fullKey))
	if _, err := db.Exec(`INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)`,
		"key_"+randHex(t, 16), accountID, hash, fullKey[:12], now); err != nil {
		t.Fatalf("seed extra api key: %v", err)
	}
	return pricingAccount{accountID: accountID, apiKey: fullKey}
}

var (
	raceCoordinatorOnce sync.Once
	raceCoordinatorPath string
	raceCoordinatorErr  error
)

// raceCoordinatorBinary builds the coordinator with -race (cgo) next to the
// TestMain binaries, once per process.
func raceCoordinatorBinary(t *testing.T) string {
	t.Helper()
	raceCoordinatorOnce.Do(func() {
		repoRoot, err := findRepoRoot()
		if err != nil {
			raceCoordinatorErr = err
			return
		}
		raceCoordinatorPath = filepath.Join(filepath.Dir(coordinatorBin), "coordinator-race")
		cmd := exec.Command("go", "build", "-race", "-o", raceCoordinatorPath, "./cmd/coordinator")
		cmd.Dir = filepath.Join(repoRoot, "phase4-coordinator")
		cmd.Env = append(os.Environ(), "CGO_ENABLED=1")
		out, err := cmd.CombinedOutput()
		if err != nil {
			raceCoordinatorErr = fmt.Errorf("go build -race coordinator: %v\n%s", err, out)
		}
	})
	if raceCoordinatorErr != nil {
		t.Fatalf("%v", raceCoordinatorErr)
	}
	return raceCoordinatorPath
}

func (p *pricingLane) startCoordinator() {
	t := p.t
	t.Helper()
	ctx, cancel := context.WithCancel(p.rootCtx)
	p.coordCancel = cancel
	cmd := exec.CommandContext(ctx, p.coordBin, "-config", p.coordYAML, "-applied-config-state", p.statePath)
	cmd.Env = append(os.Environ(), "GORACE=halt_on_error=0")
	p.streamLogs(cmd, "coord")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start coordinator: %v", err)
	}
	p.coordCmd = cmd
	p.procWG.Add(1)
	go func() {
		defer p.procWG.Done()
		_ = cmd.Wait()
	}()
}

// appliedRecord is the coordinator-applied-config.v1 state file.
type appliedRecord struct {
	Schema               string `json:"schema"`
	ConfigSHA256         string `json:"config_sha256"`
	OverlaySHA256        string `json:"overlay_sha256"`
	LoadedAt             string `json:"loaded_at"`
	Source               string `json:"source"`
	RateTableSHA256      string `json:"rate_table_sha256"`
	SignedRateCardSHA256 string `json:"signed_rate_card_sha256"`
	AutotuneReleaseID    string `json:"autotune_release_id"`
	BillingSnapshotID    int64  `json:"billing_snapshot_id"`
	raw                  []byte
}

func (p *pricingLane) applied() appliedRecord {
	p.t.Helper()
	raw, err := os.ReadFile(p.statePath)
	if err != nil {
		p.t.Fatalf("read applied-config record: %v", err)
	}
	var rec appliedRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		p.t.Fatalf("parse applied-config record %s: %v", raw, err)
	}
	rec.raw = raw
	return rec
}

func (p *pricingLane) waitAppliedSource(source string) appliedRecord {
	p.t.Helper()
	deadline := time.Now().Add(pricingReloadDeadline)
	for time.Now().Before(deadline) {
		if raw, err := os.ReadFile(p.statePath); err == nil {
			var rec appliedRecord
			if json.Unmarshal(raw, &rec) == nil && rec.Source == source {
				rec.raw = raw
				return rec
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	p.t.Fatalf("applied-config record never reached source=%s", source)
	return appliedRecord{}
}

// sighup sends SIGHUP and waits for its outcome: success = the applied
// record is rewritten (new loaded_at, source=sighup); failure = one of
// rejectMarkers is logged after the signal. It returns the log lines the
// reload produced and whether it succeeded.
func (p *pricingLane) sighup(rejectMarkers ...string) (bool, []string) {
	t := p.t
	t.Helper()
	before := p.applied()
	mark := len(p.coordLogBuf.snapshot())
	if err := p.coordCmd.Process.Signal(syscall.SIGHUP); err != nil {
		t.Fatalf("SIGHUP: %v", err)
	}
	deadline := time.Now().Add(pricingReloadDeadline)
	for time.Now().Before(deadline) {
		lines := p.coordLogBuf.snapshot()[mark:]
		for _, line := range lines {
			for _, m := range rejectMarkers {
				if strings.Contains(line, m) {
					// Give any follow-on line of the same reload a moment.
					time.Sleep(200 * time.Millisecond)
					return false, p.coordLogBuf.snapshot()[mark:]
				}
			}
		}
		if raw, err := os.ReadFile(p.statePath); err == nil && !bytes.Equal(raw, before.raw) {
			return true, p.coordLogBuf.snapshot()[mark:]
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("SIGHUP outcome not observed within %s; logs since signal:\n%s", pricingReloadDeadline, strings.Join(p.coordLogBuf.snapshot()[mark:], "\n"))
	return false, nil
}

// rejectMarkersAll are every reload-rejection log message of
// reloadCoordinatorConfig.
var rejectMarkersAll = []string{
	"tier2 config reload rejected",
	"autotune runtime economics reload rejected",
	"billing config reload rejected",
	"proof_of_weights config reload rejected",
	"trusted pools creator admin config reload rejected",
}

func (p *pricingLane) coordGET(path string) (int, http.Header, []byte) {
	return rawGET(p.t, p.coordBuyerURL+path, "")
}

func (p *pricingLane) gatewayGET(path string) (int, http.Header, []byte) {
	return rawGET(p.t, p.gatewayBaseURL+path, "")
}

func rawGET(t *testing.T, url, bearer string) (int, http.Header, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, body
}

// deriveCard returns a re-versioned copy of card A with `mutate` applied.
func (p *pricingLane) deriveCard(mutate func(rows map[string]pricingCardRow)) (pricingCard, []byte) {
	rows := make(map[string]pricingCardRow, len(p.cardA.Rows))
	for k, v := range p.cardA.Rows {
		rows[k] = v
	}
	mutate(rows)
	def := rows["default"]
	card := pricingCard{
		GeneratedAt:          p.cardA.GeneratedAt,
		PolicyVersion:        p.cardA.PolicyVersion,
		Rows:                 rows,
		USDPerMillionCredits: p.cardA.USDPerMillionCredits,
	}
	card.Version = pricingCardVersion(rows, def.ProviderShareBPS, def.GlobalMultiplierPPM, card.USDPerMillionCredits)
	raw, err := json.Marshal(card)
	if err != nil {
		p.t.Fatal(err)
	}
	return card, raw
}

// cardB is the J1 candidate: the llama row moves up 50%, the qwen3-8b row
// goes to zero (a zero-rate row in force for J8), everything else unchanged.
func (p *pricingLane) cardB() (pricingCard, []byte) {
	return p.deriveCard(func(rows map[string]pricingCardRow) {
		r := rows[pricingLlamaKey]
		r.PromptRatePerMtok, r.PromptCacheHitRatePerMtok, r.CompletionRatePerMtok = 20250, 5062, 40500
		rows[pricingLlamaKey] = r
		z := rows[pricingZeroRateKey]
		z.PromptRatePerMtok, z.PromptCacheHitRatePerMtok, z.CompletionRatePerMtok = 0, 0, 0
		rows[pricingZeroRateKey] = z
	})
}

// rateCardBlock renders the reviewed `rewards.rate_card` block (L1 bytes) for
// a card: 2-space child indent, rows sorted, the three credit fields.
func rateCardBlock(card pricingCard) []byte {
	keys := make([]string, 0, len(card.Rows))
	for k := range card.Rows {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	b.WriteString("  rate_card:\n")
	for _, k := range keys {
		r := card.Rows[k]
		fmt.Fprintf(&b, "    %s:\n", k)
		fmt.Fprintf(&b, "      completion_credits_per_mtok: %d\n", r.CompletionRatePerMtok)
		fmt.Fprintf(&b, "      prompt_cache_hit_credits_per_mtok: %d\n", r.PromptCacheHitRatePerMtok)
		fmt.Fprintf(&b, "      prompt_credits_per_mtok: %d\n", r.PromptRatePerMtok)
	}
	return b.Bytes()
}

// spliceYAML runs the real lane tool: live yaml + reviewed block -> output.
func (p *pricingLane) spliceYAML(liveYAML string, block []byte) []byte {
	t := p.t
	t.Helper()
	dir := t.TempDir()
	blockPath := filepath.Join(dir, "block.yaml")
	outPath := filepath.Join(dir, "spliced.yaml")
	if err := os.WriteFile(blockPath, block, 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("python3", filepath.Join(p.repoRoot, "scripts", "catalog-release.py"), "splice-coordinator-rate-card",
		"--live-config", liveYAML, "--block", blockPath, "--output", outPath)
	cmd.Env = append(os.Environ(), "PYTHONDONTWRITEBYTECODE=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("splice-coordinator-rate-card: %v\n%s", err, out)
	}
	t.Logf("splice-coordinator-rate-card: %s", strings.TrimSpace(string(out)))
	raw, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// installPricing performs the lane's forward install for (yaml, card): the
// spliced yaml first, then the signed card into `current` (SPEC-005-R013 I4
// mixed-interval order). No SIGHUP.
func (p *pricingLane) installPricing(yamlRaw, cardRaw []byte) {
	p.t.Helper()
	writeFileAtomic(p.t, p.coordYAML, yamlRaw)
	p.keys.writeSignedAtomic(p.t, filepath.Join(p.currentDir, "rate-card.json"), cardRaw)
}

// ---- ledger oracles -------------------------------------------------------

type pricedCredit struct {
	ID             int64
	RequestID      string
	AttemptN       int64
	Model          string
	PromptRate     int64
	CompletionRate int64
	MultiplierPPM  int64
	ShareBps       int64
	SnapshotID     sql.NullInt64
	SnapshotJSON   sql.NullString
	SnapMultiplier sql.NullInt64
	SnapShare      sql.NullInt64
}

func (p *pricingLane) openCoordDB() *sql.DB {
	p.t.Helper()
	db, err := sql.Open("sqlite", "file:"+p.coordinatorDB+"?_pragma=busy_timeout(10000)")
	if err != nil {
		p.t.Fatal(err)
	}
	return db
}

func (p *pricingLane) pricedCredits() []pricedCredit {
	t := p.t
	t.Helper()
	db := p.openCoordDB()
	defer db.Close()
	rows, err := db.Query(`
SELECT c.id, c.request_id, c.attempt_n, c.model,
       c.prompt_rate_per_mtok, c.completion_rate_per_mtok, c.global_multiplier_ppm, c.provider_share_bps,
       i.config_snapshot_id, s.rate_card_json, s.global_multiplier_ppm, s.provider_share_bps
  FROM ledger_request_credits c
  LEFT JOIN ledger_provider_identity_snapshots i
         ON i.request_id = c.request_id AND i.attempt_n = c.attempt_n
        AND (c.provider_assigned_id IS NULL OR i.provider_assigned_id = c.provider_assigned_id)
  LEFT JOIN ledger_config_snapshots s ON s.id = i.config_snapshot_id
 ORDER BY c.id`)
	if err != nil {
		t.Fatalf("query priced credits: %v", err)
	}
	defer rows.Close()
	var out []pricedCredit
	seen := map[int64]bool{}
	for rows.Next() {
		var r pricedCredit
		if err := rows.Scan(&r.ID, &r.RequestID, &r.AttemptN, &r.Model, &r.PromptRate, &r.CompletionRate, &r.MultiplierPPM, &r.ShareBps,
			&r.SnapshotID, &r.SnapshotJSON, &r.SnapMultiplier, &r.SnapShare); err != nil {
			t.Fatal(err)
		}
		if seen[r.ID] {
			t.Fatalf("O1: ledger_request_credits id=%d links more than one provider identity row", r.ID)
		}
		seen[r.ID] = true
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

type configSnapshot struct {
	ID          int64
	EffectiveAt string
	Table       pricingTable
	RawJSON     string
}

func parseSnapshotTable(t *testing.T, raw string) pricingTable {
	t.Helper()
	var rows map[string]struct {
		Prompt     int64 `json:"prompt_rate_per_mtok"`
		CacheHit   int64 `json:"prompt_cache_hit_rate_per_mtok"`
		Completion int64 `json:"completion_rate_per_mtok"`
	}
	if err := json.Unmarshal([]byte(raw), &rows); err != nil {
		t.Fatalf("parse rate_card_json %q: %v", raw, err)
	}
	out := pricingTable{}
	for k, r := range rows {
		out[k] = pricingEntry{Prompt: r.Prompt, CacheHit: r.CacheHit, Completion: r.Completion}
	}
	return out
}

func (p *pricingLane) snapshots() []configSnapshot {
	t := p.t
	t.Helper()
	db := p.openCoordDB()
	defer db.Close()
	rows, err := db.Query(`SELECT id, effective_at_utc, rate_card_json FROM ledger_config_snapshots ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []configSnapshot
	for rows.Next() {
		var s configSnapshot
		if err := rows.Scan(&s.ID, &s.EffectiveAt, &s.RawJSON); err != nil {
			t.Fatal(err)
		}
		s.Table = parseSnapshotTable(t, s.RawJSON)
		out = append(out, s)
	}
	return out
}

// labelTable names a table among the reviewed ones ("" = none of them).
func labelTable(tab pricingTable, reviewed map[string]pricingTable) string {
	names := make([]string, 0, len(reviewed))
	for n := range reviewed {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		if reviewed[n].equal(tab) {
			return n
		}
	}
	return ""
}

// assertO1 checks SPEC-005-R013 I1 over every ledger row: linked snapshot
// present, its table one of the reviewed tables, and the row's persisted
// rates / multiplier / share equal that table's resolution. Returns each
// row's table label keyed by ledger id.
func (p *pricingLane) assertO1(reviewed map[string]pricingTable) map[int64]string {
	t := p.t
	t.Helper()
	labels := map[int64]string{}
	for _, c := range p.pricedCredits() {
		if !c.SnapshotID.Valid || !c.SnapshotJSON.Valid {
			t.Errorf("O1: credit id=%d request=%s attempt=%d has no linked config snapshot", c.ID, c.RequestID, c.AttemptN)
			continue
		}
		tab := parseSnapshotTable(t, c.SnapshotJSON.String)
		label := labelTable(tab, reviewed)
		if label == "" {
			t.Errorf("O1: credit id=%d links snapshot %d whose table is not a reviewed table: %s", c.ID, c.SnapshotID.Int64, c.SnapshotJSON.String)
			continue
		}
		key, want := tab.resolve(c.Model)
		if c.PromptRate != want.Prompt || c.CompletionRate != want.Completion {
			t.Errorf("O1: credit id=%d model=%q priced prompt=%d completion=%d but linked snapshot %d (table %s, row %q) says prompt=%d completion=%d",
				c.ID, c.Model, c.PromptRate, c.CompletionRate, c.SnapshotID.Int64, label, key, want.Prompt, want.Completion)
		}
		if c.MultiplierPPM != c.SnapMultiplier.Int64 || c.ShareBps != c.SnapShare.Int64 {
			t.Errorf("O1: credit id=%d multiplier/share %d/%d != snapshot %d's %d/%d", c.ID, c.MultiplierPPM, c.ShareBps, c.SnapshotID.Int64, c.SnapMultiplier.Int64, c.SnapShare.Int64)
		}
		labels[c.ID] = label
	}
	return labels
}

// assertO6 checks served == on-disk == applied record, and that the served
// card is correctly signed by the test keyring.
func (p *pricingLane) assertO6(wantCard []byte) appliedRecord {
	t := p.t
	t.Helper()
	status, _, served := p.coordGET("/v1/rate-card")
	if status != http.StatusOK {
		t.Fatalf("O6: coordinator /v1/rate-card status=%d", status)
	}
	sigStatus, _, sig := p.coordGET("/v1/rate-card.sig")
	if sigStatus != http.StatusOK {
		t.Fatalf("O6: coordinator /v1/rate-card.sig status=%d", sigStatus)
	}
	disk, err := os.ReadFile(filepath.Join(p.currentDir, "rate-card.json"))
	if err != nil {
		t.Fatal(err)
	}
	rec := p.applied()
	if !bytes.Equal(served, disk) {
		t.Errorf("O6: served /v1/rate-card (sha %s) != current/rate-card.json (sha %s)", sha256HexBytes(served), sha256HexBytes(disk))
	}
	if !bytes.Equal(served, wantCard) {
		t.Errorf("O6: served card sha %s != expected card sha %s", sha256HexBytes(served), sha256HexBytes(wantCard))
	}
	if rec.SignedRateCardSHA256 != sha256HexBytes(served) {
		t.Errorf("O6: applied record signed_rate_card_sha256=%s != served sha %s", rec.SignedRateCardSHA256, sha256HexBytes(served))
	}
	if !p.keys.verify(served, sig) {
		t.Errorf("O6: served /v1/rate-card.sig does not verify the served body under the test key")
	}
	return rec
}

// assertAppliedTable checks the record's rate_table_sha256 / snapshot id
// point at the snapshot row that holds `want`.
func (p *pricingLane) assertAppliedTable(rec appliedRecord, want pricingTable, label string) {
	t := p.t
	t.Helper()
	for _, s := range p.snapshots() {
		if s.ID != rec.BillingSnapshotID {
			continue
		}
		if !s.Table.equal(want) {
			t.Errorf("applied record billing_snapshot_id=%d holds a table other than %s", rec.BillingSnapshotID, label)
		}
		if got := sha256HexBytes([]byte(s.RawJSON)); got != rec.RateTableSHA256 {
			t.Errorf("applied record rate_table_sha256=%s != sha256(snapshot %d rate_card_json)=%s", rec.RateTableSHA256, s.ID, got)
		}
		return
	}
	t.Errorf("applied record billing_snapshot_id=%d not found in ledger_config_snapshots", rec.BillingSnapshotID)
}

// assertO5 checks the on-disk pair: base yaml rewards.rate_card rows equal
// the current signed card rows, and no pricing-transaction leftovers.
func (p *pricingLane) assertO5() {
	t := p.t
	t.Helper()
	raw, err := os.ReadFile(p.coordYAML)
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		Rewards struct {
			RateCard map[string]struct {
				Prompt     int64  `yaml:"prompt_credits_per_mtok"`
				CacheHit   *int64 `yaml:"prompt_cache_hit_credits_per_mtok"`
				Completion int64  `yaml:"completion_credits_per_mtok"`
			} `yaml:"rate_card"`
		} `yaml:"rewards"`
	}
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	yamlTable := pricingTable{}
	for k, r := range cfg.Rewards.RateCard {
		cache := r.Prompt
		if r.CacheHit != nil {
			cache = *r.CacheHit
		}
		yamlTable[k] = pricingEntry{Prompt: r.Prompt, CacheHit: cache, Completion: r.Completion}
	}
	cardRaw, err := os.ReadFile(filepath.Join(p.currentDir, "rate-card.json"))
	if err != nil {
		t.Fatal(err)
	}
	var card pricingCard
	if err := json.Unmarshal(cardRaw, &card); err != nil {
		t.Fatal(err)
	}
	if !yamlTable.equal(card.table()) {
		t.Errorf("O5: on-disk yaml rewards.rate_card != current/rate-card.json rows")
	}
	matches, _ := filepath.Glob(filepath.Join(p.liveRoot, ".pricing-txn*"))
	more, _ := filepath.Glob(filepath.Join(p.tempDir, ".pricing-txn*"))
	if len(matches)+len(more) > 0 {
		t.Errorf("O5: pricing transaction leftovers: %v %v", matches, more)
	}
}

// ---- buyer traffic ---------------------------------------------------------

func (p *pricingLane) chatAs(apiKey, requestID string, stream bool) (int, []byte) {
	t := p.t
	t.Helper()
	body := fmt.Sprintf(`{"model":%q,"max_tokens":32,"stream":%t,"messages":[{"role":"user","content":"pricing lane %s"}]}`,
		settlementFixtureModelID, stream, requestID)
	req, err := http.NewRequest(http.MethodPost, p.gatewayBaseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Request-ID", requestID)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func newUUID(t *testing.T) string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// paidRequests sends n requests (alternating non-stream / stream) as apiKey
// and waits until each has a ledger credit. Returns the coordinator request
// ids.
func (p *pricingLane) paidRequests(apiKey string, n int) []string {
	t := p.t
	t.Helper()
	var ids []string
	for i := 0; i < n; i++ {
		ext := newUUID(t)
		status, body := p.chatAs(apiKey, ext, i%2 == 1)
		if status != http.StatusOK {
			t.Fatalf("paid request %d status=%d body=%s", i, status, body)
		}
		ids = append(ids, p.waitCreditFor(ext, 15*time.Second))
	}
	return ids
}

// waitCreditFor maps a gateway X-Request-ID to its coordinator request_id
// (request_log.external_request_id) and waits for its ledger credit row.
func (p *pricingLane) waitCreditFor(externalID string, timeout time.Duration) string {
	t := p.t
	t.Helper()
	db := p.openCoordDB()
	defer db.Close()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var rid string
		err := db.QueryRow(`
SELECT c.request_id FROM request_log r
  JOIN ledger_request_credits c ON c.request_id = r.request_id
 WHERE r.external_request_id = ? OR r.request_id = ?
 LIMIT 1`, externalID, externalID).Scan(&rid)
		if err == nil {
			return rid
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("no ledger credit for external request %s within %s", externalID, timeout)
	return ""
}

// creditRatesFor returns the persisted prompt/completion rates of the
// coordinator request's ledger row(s).
func (p *pricingLane) creditRatesFor(requestID string) []pricingEntry {
	t := p.t
	t.Helper()
	db := p.openCoordDB()
	defer db.Close()
	rows, err := db.Query(`SELECT prompt_rate_per_mtok, completion_rate_per_mtok FROM ledger_request_credits WHERE request_id = ?`, requestID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []pricingEntry
	for rows.Next() {
		var e pricingEntry
		if err := rows.Scan(&e.Prompt, &e.Completion); err != nil {
			t.Fatal(err)
		}
		out = append(out, e)
	}
	return out
}

// requestLogAccounts returns the distinct request_log.account_id values.
func (p *pricingLane) requestLogAccount(requestID string) string {
	t := p.t
	t.Helper()
	db := p.openCoordDB()
	defer db.Close()
	var acct sql.NullString
	if err := db.QueryRow(`SELECT account_id FROM request_log WHERE request_id = ? LIMIT 1`, requestID).Scan(&acct); err != nil {
		t.Fatalf("request_log account for %s: %v", requestID, err)
	}
	return acct.String
}

// ---- wholesale -----------------------------------------------------------

type wholesaleStatement struct {
	status int
	raw    []byte
	stmt   map[string]any
}

func (p *pricingLane) generateWholesale(accountID string) wholesaleStatement {
	t := p.t
	t.Helper()
	period := time.Now().UTC().Format("2006-01")
	body, _ := json.Marshal(map[string]any{"account_id": accountID, "period": period})
	req, err := http.NewRequest(http.MethodPost, p.coordProvURL+"/admin/ledger/wholesale-statements", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+p.operatorKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("wholesale POST: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := wholesaleStatement{status: resp.StatusCode, raw: raw}
	_ = json.Unmarshal(raw, &out.stmt)
	return out
}

// comparable strips generated_at_utc, the only field a regeneration may
// change for the same rows.
func (w wholesaleStatement) comparable(t *testing.T) string {
	t.Helper()
	m := map[string]any{}
	for k, v := range w.stmt {
		if k == "generated_at_utc" {
			continue
		}
		m[k] = v
	}
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func (w wholesaleStatement) line(t *testing.T, model string) map[string]any {
	t.Helper()
	items, _ := w.stmt["line_items"].([]any)
	for _, it := range items {
		m, _ := it.(map[string]any)
		if m["model"] == model {
			return m
		}
	}
	t.Fatalf("statement has no line for model %q: %s", model, w.raw)
	return nil
}

func jsonInt(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case json.Number:
		i, _ := n.Int64()
		return i
	}
	return -1
}

// listGross is the SPEC-005 §11.7 list-price gross for one generation group.
func listGross(prompt, completion int64, e pricingEntry) int64 {
	num := prompt*e.Prompt + completion*e.Completion // fits for test magnitudes
	q, r := num/1_000_000, num%1_000_000
	switch {
	case 2*r > 1_000_000:
		q++
	case 2*r == 1_000_000 && q%2 == 1:
		q++
	}
	return q
}

func hmacSHA256(key, msg []byte) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(msg)
	return mac.Sum(nil)
}
