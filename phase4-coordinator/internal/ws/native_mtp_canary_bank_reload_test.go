package ws

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// nativeMTPSignedReleaseBank returns the fixture bank re-labelled for
// releaseID and its static-feed detached signature.
func nativeMTPSignedReleaseBank(t *testing.T, priv ed25519.PrivateKey, keyID, releaseID string) ([]byte, []byte) {
	t.Helper()
	raw, _ := nativeMTPValidBankFixture(t)
	var obj map[string]any
	mustUnmarshalNativeMTP(t, raw, &obj)
	obj["release_id"] = releaseID
	raw = mustMarshalNativeMTP(t, obj)
	sig := mustMarshalNativeMTP(t, nativeMTPCanaryDetachedSignature{
		Alg:       "ed25519",
		KeyID:     keyID,
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw)),
	})
	return raw, sig
}

type nativeMTPBankReloadFixture struct {
	server     *Server
	registry   *pool.Registry
	provider   *pool.Provider
	priv       ed25519.PrivateKey
	keyID      string
	now        time.Time
	generation uint64
}

func newNativeMTPBankReloadFixture(t *testing.T, opts ...Option) *nativeMTPBankReloadFixture {
	t.Helper()
	_, binding := nativeMTPValidBankFixture(t)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := nativeMTPValidBankFixture(t)
	bank, err := ParseNativeMTPChallengeBank(raw, binding)
	if err != nil {
		t.Fatal(err)
	}
	record := bank.Entries[0]
	now := time.Date(2026, 9, 28, 1, 0, 0, 0, time.UTC)
	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID: "provider-a", AssignedID: "assigned-a",
		ModelID: record.ModelID, ModelHash: record.ModelHash,
		State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, MaxContextTokens: 4096,
	}
	clientConn, serverConn := net.Pipe()
	t.Cleanup(func() {
		_ = clientConn.Close()
		_ = serverConn.Close()
	})
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.NativeMTPCanary = config.NativeMTPCanaryConfig{
		Enabled:     true,
		SignerKeyID: binding.SignerKeyID,
		PublicKeys:  map[string]string{binding.SignerKeyID: base64.StdEncoding.EncodeToString(pub)},
		IntervalS:   900,
	}
	server := NewServer(cfg, registry, zerolog.Nop(), append([]Option{WithNow(func() time.Time { return now })}, opts...)...)
	return &nativeMTPBankReloadFixture{server: server, registry: registry, provider: provider, priv: priv, keyID: binding.SignerKeyID, now: now}
}

func releaseCatalog(releaseID string) *autotune.Catalog {
	sum := sha256.Sum256([]byte(releaseID))
	return &autotune.Catalog{Version: releaseID, SHA256: hex.EncodeToString(sum[:])}
}

// publish publishes the admission catalog of releaseID with the retained
// compatible-previous releases, as the reload's SetAutotuneCatalog does.
func (f *nativeMTPBankReloadFixture) publish(releaseID string, retained ...string) {
	compatible := make([]*autotune.Catalog, 0, len(retained))
	for _, id := range retained {
		compatible = append(compatible, releaseCatalog(id))
	}
	f.server.SetAutotuneCatalog(releaseCatalog(releaseID), compatible...)
}

// reload runs the release reload's bank step (verify, stage) and publishes
// the release with the retained compatible-previous releases.
func (f *nativeMTPBankReloadFixture) reload(t *testing.T, releaseID string, retained ...string) *NativeMTPChallengeBank {
	t.Helper()
	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, releaseID)
	stage, err := f.server.PrepareNativeMTPCanaryBankReload(releaseID, raw, sig)
	if err != nil {
		t.Fatalf("reload %s: %v", releaseID, err)
	}
	stage()
	f.publish(releaseID, retained...)
	if f.server.artifactIdentitySets.stagingEnabled() {
		f.server.PublishArtifactIdentitySetsWith(nil, false, nil)
	}
	return f.server.currentNativeMTPCanaryBank()
}

// reloadPlain reloads a release that carries no native-MTP admission set.
func (f *nativeMTPBankReloadFixture) reloadPlain(t *testing.T, releaseID string, retained ...string) {
	t.Helper()
	stage, err := f.server.PrepareNativeMTPCanaryBankReload(releaseID, nil, nil)
	if err != nil {
		t.Fatalf("reload %s: %v", releaseID, err)
	}
	stage()
	f.publish(releaseID, retained...)
}

func (f *nativeMTPBankReloadFixture) offer(t *testing.T, bank *NativeMTPChallengeBank) bool {
	t.Helper()
	if bank == nil {
		t.Fatal("offer of a nil bank")
	}
	// Each offer carries a fresh target generation, so an earlier accepted
	// offer never reads as this one's admission.
	f.generation++
	generation := f.generation
	record := bank.Entries[0]
	tuple := NativeMTPRuntimeTuple{
		ModelID: record.ModelID, ModelHash: record.ModelHash, ModelHashAlgorithm: "sha256",
		ProviderRevision: "1.8.123", RuntimeRevision: "mlx-swift-lm-e874140",
		TokenizerDigest: record.TokenizerSHA256, ArtifactDigest: record.ArtifactSHA256,
		ManifestDigest: record.MTPManifestSHA256, SidecarDigest: strings.Repeat("8", 64),
		ProviderBinarySHA256: strings.Repeat("9", 64), RuntimeCDHash: strings.Repeat("a", 64),
		CacheNamespace: "native-mtp-test", StateDigest: record.ExpectedCommittedStateSHA256,
		ProposalDepth: int(record.FixedProposalDepth),
	}
	admission := strings.Repeat("8", 64)
	offer := NativeMTPTupleOffer{
		Type: "native_mtp_tuple_offer_v1", Version: 1,
		ProviderID: f.provider.ProviderID, AssignedID: f.provider.AssignedID, TargetGeneration: generation,
		ProviderRevision: tuple.ProviderRevision, RuntimeRevision: tuple.RuntimeRevision, RuntimeTuple: tuple,
		NativeMTPAdmissionTupleSHA256: admission, ServedSnapshotID: "snapshot-a",
		NativeMTPRuntimeTupleSHA256: nativeMTPRuntimeTupleIdentitySHA256(
			f.provider.ProviderID, f.provider.AssignedID, generation, admission, "snapshot-a"),
		SidecarDigest: tuple.SidecarDigest, ChallengeBankReleaseID: bank.ReleaseID,
		ChallengeBankSHA256: bank.RawSHA256, ChallengeCorpusSHA256: strings.Repeat("b", 64),
		SelftestProfile: "native_mtp_selftest_v1", SelftestPassDigest: strings.Repeat("c", 64),
		SelftestObservedAt: f.now.Format(time.RFC3339),
	}
	f.server.handleNativeMTPTupleOffer(f.provider.ProviderID, f.provider.AssignedID, mustMarshalNativeMTP(t, offer))
	snap, _ := f.registry.Resolve(f.provider.ProviderID, f.provider.AssignedID)
	return snap.NativeMTPCanary != nil && snap.NativeMTPCanary.TargetGeneration == generation &&
		snap.NativeMTPCanary.ChallengeBankSHA256 == bank.RawSHA256
}

// The incident shape: a release reload that moves the served catalog must
// move the canary bank with it, so a provider that restarts onto the new
// release and offers its bank is admitted without a coordinator restart.
func TestNativeMTPCanaryBankReloadsWithTheRelease(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	old := f.reload(t, "release-old")
	next := f.reload(t, "release-new", "release-old")
	if next.ReleaseID != "release-new" {
		t.Fatalf("current bank release %q", next.ReleaseID)
	}
	if !f.offer(t, next) {
		t.Fatal("offer bound to the new release's bank was not admitted")
	}
	// The bank of the retained compatible-previous release still binds: a
	// provider admitted on it cannot fetch another bank mid-session.
	if !f.offer(t, old) {
		t.Fatal("offer bound to the compatible-previous release's bank was not admitted")
	}
}

func TestNativeMTPCanaryPreviousBankBindsOnlyWhileItsReleaseIsAdmitted(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	old := f.reload(t, "release-old")
	f.reload(t, "release-new")
	// No compatible-previous release retained: the old bank is out.
	if f.offer(t, old) {
		t.Fatal("offer bound to a no-longer-admitted release's bank was admitted")
	}
	// A third release drops the oldest bank even if its release were retained.
	f.reload(t, "release-third", "release-old")
	if f.offer(t, old) {
		t.Fatal("offer bound to a bank two releases back was admitted")
	}
}

// A current-bank match also needs release admission by the same snapshot:
// a bank whose release is neither live nor retained admits nothing.
func TestNativeMTPCanaryCurrentBankRequiresReleaseAdmission(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	current := f.reload(t, "release-old")
	if !f.offer(t, current) {
		t.Fatal("offer bound to the live release's bank was not admitted")
	}
	// The admission catalog moves on without a bank transition (no reload
	// staged one): the old current bank no longer admits.
	f.publish("release-other")
	if f.server.currentNativeMTPCanaryBank() != current {
		t.Fatal("a catalog publish without a staged transition moved the bank")
	}
	if f.offer(t, current) {
		t.Fatal("offer bound to a current bank whose release is not admitted was admitted")
	}
}

// A release without native-MTP feeds retires the old current bank: it moves
// to previous only while its release stays admitted, otherwise it is dropped.
func TestNativeMTPCanaryNoBankReleaseRetiresTheCurrentBank(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	old := f.reload(t, "release-old")
	f.reloadPlain(t, "release-plain", "release-old")
	set := f.server.nativeMTPCanaryBanks.Load()
	if set == nil || set.current != nil || set.previous != old {
		t.Fatalf("no-bank release with the old release retained: set=%+v", set)
	}
	if !f.offer(t, old) {
		t.Fatal("offer on the retained previous release's bank was not admitted")
	}
	f.reloadPlain(t, "release-plain-2")
	if set := f.server.nativeMTPCanaryBanks.Load(); set != nil {
		t.Fatalf("no-bank release without the old release retained kept a bank: %+v", set)
	}
	if f.offer(t, old) {
		t.Fatal("offer bound to an obsolete release's bank was admitted")
	}
}

// With release staging (production), the bank, the admission catalog and the
// served feed bytes move in ONE publication: before it, the new bank admits
// nothing and the old bank still does; by the time the served feed bytes are
// swapped, the canary already holds the new bank.
func TestNativeMTPCanaryBankPublishesWithTheCatalogAndServedFeeds(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t, WithReleaseStaging())
	old := f.reload(t, "release-old")
	if !f.offer(t, old) {
		t.Fatal("offer on the live release's bank was not admitted")
	}

	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, "release-new")
	stage, err := f.server.PrepareNativeMTPCanaryBankReload("release-new", raw, sig)
	if err != nil {
		t.Fatal(err)
	}
	stage()
	f.publish("release-new", "release-old")
	if got := f.server.currentNativeMTPCanaryBank(); got != old {
		t.Fatalf("the bank moved ahead of the release publication: %+v", got)
	}
	if got := f.server.CurrentAutotuneCatalog(); got == nil || got.Version != "release-old" {
		t.Fatalf("the catalog moved ahead of the release publication: %+v", got)
	}
	if !f.offer(t, old) {
		t.Fatal("old bank stopped admitting before the release publication")
	}
	var atFeedCommit *NativeMTPChallengeBank
	f.server.PublishArtifactIdentitySetsWith(nil, false, func() {
		atFeedCommit = f.server.nativeMTPCanaryBanks.Load().current
	})
	if atFeedCommit == nil || atFeedCommit.ReleaseID != "release-new" {
		t.Fatalf("served feed bytes committed before the canary held their bank: %+v", atFeedCommit)
	}
	if !f.offer(t, atFeedCommit) {
		t.Fatal("offer on the new release's bank was not admitted after publication")
	}
}

// A reload rejected after staging discards the staged bank transition: no
// later publication promotes it.
func TestNativeMTPCanaryDiscardedReloadNeverPromotesItsBank(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t, WithReleaseStaging())
	old := f.reload(t, "release-old")

	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, "release-new")
	stage, err := f.server.PrepareNativeMTPCanaryBankReload("release-new", raw, sig)
	if err != nil {
		t.Fatal(err)
	}
	stage()
	f.publish("release-new", "release-old")
	f.server.DiscardStagedRelease()
	f.server.PublishArtifactIdentitySetsWith(nil, false, nil)
	if got := f.server.currentNativeMTPCanaryBank(); got != old {
		t.Fatalf("a discarded reload's bank went live: %+v", got)
	}
	if got := f.server.CurrentAutotuneCatalog(); got == nil || got.Version != "release-old" {
		t.Fatalf("a discarded reload's catalog went live: %+v", got)
	}
}

func TestNativeMTPCanaryBankReloadRejectsUnverifiedBankAndKeepsThePriorBank(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	prior := f.reload(t, "release-old")

	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, "release-new")
	if _, err := f.server.PrepareNativeMTPCanaryBankReload("release-other", raw, sig); err == nil || !strings.Contains(err.Error(), "release_id") {
		t.Fatalf("cross-release bank err=%v", err)
	}
	tampered := append([]byte(nil), raw...)
	tampered[len(tampered)-2] = ' '
	if _, err := f.server.PrepareNativeMTPCanaryBankReload("release-new", tampered, sig); err == nil || !strings.Contains(err.Error(), "signature verification failed") {
		t.Fatalf("tampered bank err=%v", err)
	}
	_, otherPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, forged := nativeMTPSignedReleaseBank(t, otherPriv, f.keyID, "release-new")
	if _, err := f.server.PrepareNativeMTPCanaryBankReload("release-new", raw, forged); err == nil {
		t.Fatal("bank signed by an untrusted key verified")
	}
	if got := f.server.currentNativeMTPCanaryBank(); got != prior {
		t.Fatalf("a refused reload replaced the canary bank: %+v", got)
	}
}

func TestNativeMTPCanaryBankReloadOfTheSameBankKeepsThePreviousBank(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	old := f.reload(t, "release-old")
	next := f.reload(t, "release-new", "release-old")
	if again := f.reload(t, "release-new", "release-old"); again != next {
		t.Fatal("reloading the same bank replaced the current bank")
	}
	set := f.server.nativeMTPCanaryBanks.Load()
	if set.previous != old {
		t.Fatal("reloading the same bank dropped the previous bank")
	}
}

func TestNativeMTPCanaryBankReloadIsANoOpWithTheCanaryDisabled(t *testing.T) {
	// Build the server with the canary disabled from the start: the canary
	// loop reads the config concurrently, so the test must not flip it live.
	f := newNativeMTPBankReloadFixture(t, func(s *Server) { s.cfg.Pool.NativeMTPCanary.Enabled = false })
	stage, err := f.server.PrepareNativeMTPCanaryBankReload("release-x", []byte("{}"), []byte("{}"))
	if err != nil {
		t.Fatalf("disabled canary: %v", err)
	}
	stage()
	f.publish("release-x", "release-old")
	if f.server.currentNativeMTPCanaryBank() != nil {
		t.Fatal("a disabled canary installed a bank")
	}
	if err := ValidateNativeMTPCanaryReleaseBank(f.server.cfg.Pool.NativeMTPCanary, "release-x", []byte("{}"), []byte("{}")); err != nil {
		t.Fatalf("offline validation with the canary disabled: %v", err)
	}
}

// Activation tooling reads the canary bank release and digest from /healthz
// to prove the bank moved with the release instead of scheduling a restart.
func TestHealthzReportsTheNativeMTPCanaryBankReleaseAndDigest(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	read := func() map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		f.server.handleHealthz(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return body
	}
	body := read()
	if body["native_mtp_canary_bank_reloads"] != true {
		t.Fatalf("healthz reload signal=%v", body["native_mtp_canary_bank_reloads"])
	}
	if _, ok := body["native_mtp_canary_bank_release_id"]; ok {
		t.Fatalf("healthz names a bank before one is loaded: %v", body)
	}
	if _, ok := body["native_mtp_canary_bank_sha256"]; ok {
		t.Fatalf("healthz names a bank digest before one is loaded: %v", body)
	}
	raw, _ := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, "release-new")
	f.reload(t, "release-new")
	body = read()
	if got := body["native_mtp_canary_bank_release_id"]; got != "release-new" {
		t.Fatalf("healthz canary bank release=%v", got)
	}
	sum := sha256.Sum256(raw)
	if got := body["native_mtp_canary_bank_sha256"]; got != hex.EncodeToString(sum[:]) {
		t.Fatalf("healthz canary bank sha256=%v want sha256 of the served bank bytes", got)
	}
}

// ---- boot binding (SPEC-031-R033): the boot bank comes from the served feed
// snapshot, never from an unbound file.

func (f *nativeMTPBankReloadFixture) bootServer(t *testing.T, mutate func(*config.NativeMTPCanaryConfig), opts ...Option) *Server {
	t.Helper()
	cfg := config.Default()
	cfg.Pool.NativeMTPCanary = f.server.cfg.Pool.NativeMTPCanary
	if mutate != nil {
		mutate(&cfg.Pool.NativeMTPCanary)
	}
	return NewServer(cfg, f.registry, zerolog.Nop(), append([]Option{WithNow(func() time.Time { return f.now })}, opts...)...)
}

func (f *nativeMTPBankReloadFixture) served(t *testing.T, releaseID string) NativeMTPCanaryServedBank {
	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, releaseID)
	return NativeMTPCanaryServedBank{ReleaseID: releaseID, BankJSON: raw, BankSig: sig}
}

func TestNativeMTPCanaryBootBankIsBoundToTheServedFeed(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	live := f.served(t, "release-live")
	dir := t.TempDir()
	path := filepath.Join(dir, "bank.json")
	if err := os.WriteFile(path, live.BankJSON, 0o600); err != nil {
		t.Fatal(err)
	}
	withPath := func(c *config.NativeMTPCanaryConfig) { c.ChallengeBankPath = path }

	s := f.bootServer(t, withPath, WithAutotuneCatalog(releaseCatalog("release-live")), WithNativeMTPCanaryServedBanks(live, nil))
	if got := s.currentNativeMTPCanaryBank(); got == nil || got.ReleaseID != "release-live" {
		t.Fatalf("served bank not installed at boot: %+v", got)
	}

	// No served snapshot bound: the canary holds no bank.
	if s := f.bootServer(t, withPath, WithAutotuneCatalog(releaseCatalog("release-live"))); s.nativeMTPCanaryBanks.Load() != nil {
		t.Fatal("canary loaded a bank with no served feed snapshot bound")
	}
	// The configured file is not the served bank bytes (a stale bank).
	stale := f.served(t, "release-stale")
	if err := os.WriteFile(filepath.Join(dir, "stale.json"), stale.BankJSON, 0o600); err != nil {
		t.Fatal(err)
	}
	if s := f.bootServer(t, func(c *config.NativeMTPCanaryConfig) { c.ChallengeBankPath = filepath.Join(dir, "stale.json") },
		WithAutotuneCatalog(releaseCatalog("release-live")), WithNativeMTPCanaryServedBanks(live, nil)); s.nativeMTPCanaryBanks.Load() != nil {
		t.Fatal("canary trusted a bank whose configured bytes differ from the served bank")
	}
	// The served bank names another release.
	mislabelled := live
	mislabelled.ReleaseID = "release-other"
	if s := f.bootServer(t, nil, WithAutotuneCatalog(releaseCatalog("release-live")), WithNativeMTPCanaryServedBanks(mislabelled, nil)); s.nativeMTPCanaryBanks.Load() != nil {
		t.Fatal("canary trusted a served bank whose release_id differs from the served release")
	}
	// The canary disabled: no bank, no failure.
	if s := f.bootServer(t, func(c *config.NativeMTPCanaryConfig) { c.Enabled = false }, WithNativeMTPCanaryServedBanks(live, nil)); s.nativeMTPCanaryBanks.Load() != nil {
		t.Fatal("a disabled canary loaded a bank")
	}
}

// After a coordinator restart the canary rebuilds the bank of a retained
// compatible-previous release, so its providers keep binding.
func TestNativeMTPCanaryRestartRebuildsTheRetainedPreviousBank(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	live := f.served(t, "release-live")
	previous := f.served(t, "release-old")
	s := f.bootServer(t, nil,
		WithAutotuneCatalog(releaseCatalog("release-live"), releaseCatalog("release-old")),
		WithNativeMTPCanaryServedBanks(live, []NativeMTPCanaryServedBank{previous}))
	set := s.nativeMTPCanaryBanks.Load()
	if set == nil || set.current == nil || set.previous == nil || set.previous.ReleaseID != "release-old" {
		t.Fatalf("restart did not rebuild the retained previous bank: %+v", set)
	}
	f.server = s
	if !f.offer(t, set.previous) {
		t.Fatal("offer on the retained previous release's bank was rejected after a restart")
	}
	// A previous bank whose release is not retained is not rebuilt.
	s = f.bootServer(t, nil,
		WithAutotuneCatalog(releaseCatalog("release-live")),
		WithNativeMTPCanaryServedBanks(live, []NativeMTPCanaryServedBank{previous}))
	if set := s.nativeMTPCanaryBanks.Load(); set == nil || set.previous != nil {
		t.Fatalf("restart rebuilt a bank of a release that is not retained: %+v", set)
	}
}

// ---- round-2 interleavings

// attachSession stores a live provider session for the fixture provider and
// returns a reader of the frames the coordinator sends it.
func (f *nativeMTPBankReloadFixture) attachSession(t *testing.T) func() NativeMTPTupleDisable {
	t.Helper()
	clientConn, serverConn := net.Pipe()
	t.Cleanup(func() {
		_ = clientConn.Close()
		_ = serverConn.Close()
	})
	session := newProviderSession(f.provider.ProviderID, f.provider.AssignedID, serverConn, 16, time.Second)
	f.server.sessions.Store(sessionKey(f.provider.ProviderID, f.provider.AssignedID), session)
	go session.runWriter()
	return func() NativeMTPTupleDisable {
		t.Helper()
		if err := clientConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		raw, err := wsutil.ReadServerText(clientConn)
		if err != nil {
			t.Fatalf("no frame from the coordinator: %v", err)
		}
		disable, _, err := ParseNativeMTPTupleDisable(raw)
		if err != nil {
			t.Fatalf("parse disable: %v raw=%s", err, string(raw))
		}
		return disable
	}
}

func (f *nativeMTPBankReloadFixture) verifiedBank(t *testing.T, releaseID string) *NativeMTPChallengeBank {
	t.Helper()
	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, releaseID)
	bank, err := verifyNativeMTPCanaryReleaseBank(f.server.cfg.Pool.NativeMTPCanary, releaseID, raw, sig)
	if err != nil || bank == nil {
		t.Fatalf("verify %s: %v", releaseID, err)
	}
	return bank
}

// A release publication that retires the matched bank between the offer's
// bank check and its store wins: the offer is not admitted and the provider
// is told bank_mismatch.
func TestNativeMTPCanaryOfferRacingAPublicationIsNotAdmitted(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	read := f.attachSession(t)
	old := f.reload(t, "release-old")
	f.server.nativeMTPOfferCommitHook = func() {
		f.server.nativeMTPOfferCommitHook = nil
		f.reloadPlain(t, "release-plain")
	}
	if f.offer(t, old) {
		t.Fatal("an offer whose bank a racing publication retired was admitted")
	}
	if disable := read(); disable.Reason != "bank_mismatch" {
		t.Fatalf("racing publication disable=%+v, want bank_mismatch", disable)
	}
	// Without the race the same offer is admitted against a live bank.
	again := f.reload(t, "release-old")
	if !f.offer(t, again) {
		t.Fatal("offer on the live release's bank was not admitted")
	}
}

// An enabled canary with no bank answers an offer with bank_mismatch, so the
// provider parks; once a reload installs the bank, the same session's
// re-offer is admitted.
func TestNativeMTPCanaryWithoutABankAnswersBankMismatchThenAdmitsAfterReload(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	read := f.attachSession(t)
	if f.server.nativeMTPCanaryBanks.Load() != nil {
		t.Fatal("fixture canary starts with a bank")
	}
	bank := f.verifiedBank(t, "release-new")
	if f.offer(t, bank) {
		t.Fatal("a canary without a bank admitted an offer")
	}
	if disable := read(); disable.Reason != "bank_mismatch" {
		t.Fatalf("no-bank canary disable=%+v, want bank_mismatch", disable)
	}
	reloaded := f.reload(t, "release-new")
	if !f.offer(t, reloaded) {
		t.Fatal("the same session's re-offer after the bank reload was not admitted")
	}
}

// Boot: a served bank that fails verification leaves the canary with no
// bank at all; a valid retained previous bank is not installed in its place.
// Only an intentionally bankless current release keeps the previous bank.
func TestNativeMTPCanaryBootInvalidCurrentBankInstallsNoPreviousBank(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	previous := f.served(t, "release-old")
	invalid := f.served(t, "release-live")
	invalid.BankJSON = append([]byte(nil), invalid.BankJSON...)
	invalid.BankJSON[len(invalid.BankJSON)-2] = ' '
	catalogs := WithAutotuneCatalog(releaseCatalog("release-live"), releaseCatalog("release-old"))
	if s := f.bootServer(t, nil, catalogs, WithNativeMTPCanaryServedBanks(invalid, []NativeMTPCanaryServedBank{previous})); s.nativeMTPCanaryBanks.Load() != nil {
		t.Fatalf("an invalid current bank fell back to the previous bank: %+v", s.nativeMTPCanaryBanks.Load())
	}
	bankless := NativeMTPCanaryServedBank{ReleaseID: "release-live"}
	s := f.bootServer(t, nil, catalogs, WithNativeMTPCanaryServedBanks(bankless, []NativeMTPCanaryServedBank{previous}))
	if set := s.nativeMTPCanaryBanks.Load(); set == nil || set.current != nil || set.previous == nil || set.previous.ReleaseID != "release-old" {
		t.Fatalf("a bankless current release did not keep its retained previous bank: %+v", set)
	}
}
