package ws

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
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
	server   *Server
	registry *pool.Registry
	provider *pool.Provider
	priv     ed25519.PrivateKey
	keyID    string
	now      time.Time
}

func newNativeMTPBankReloadFixture(t *testing.T) *nativeMTPBankReloadFixture {
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
	server := NewServer(cfg, registry, zerolog.Nop(), WithNow(func() time.Time { return now }))
	return &nativeMTPBankReloadFixture{server: server, registry: registry, provider: provider, priv: priv, keyID: binding.SignerKeyID, now: now}
}

// reload runs the release reload's bank step: verify, then commit.
func (f *nativeMTPBankReloadFixture) reload(t *testing.T, releaseID string) *NativeMTPChallengeBank {
	t.Helper()
	raw, sig := nativeMTPSignedReleaseBank(t, f.priv, f.keyID, releaseID)
	commit, err := f.server.PrepareNativeMTPCanaryBankReload(releaseID, raw, sig)
	if err != nil {
		t.Fatalf("reload %s: %v", releaseID, err)
	}
	commit()
	return f.server.currentNativeMTPCanaryBank()
}

func (f *nativeMTPBankReloadFixture) offer(t *testing.T, bank *NativeMTPChallengeBank) bool {
	t.Helper()
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
		ProviderID: f.provider.ProviderID, AssignedID: f.provider.AssignedID, TargetGeneration: 7,
		ProviderRevision: tuple.ProviderRevision, RuntimeRevision: tuple.RuntimeRevision, RuntimeTuple: tuple,
		NativeMTPAdmissionTupleSHA256: admission, ServedSnapshotID: "snapshot-a",
		NativeMTPRuntimeTupleSHA256: nativeMTPRuntimeTupleIdentitySHA256(
			f.provider.ProviderID, f.provider.AssignedID, 7, admission, "snapshot-a"),
		SidecarDigest: tuple.SidecarDigest, ChallengeBankReleaseID: bank.ReleaseID,
		ChallengeBankSHA256: bank.RawSHA256, ChallengeCorpusSHA256: strings.Repeat("b", 64),
		SelftestProfile: "native_mtp_selftest_v1", SelftestPassDigest: strings.Repeat("c", 64),
		SelftestObservedAt: f.now.Format(time.RFC3339),
	}
	f.server.handleNativeMTPTupleOffer(f.provider.ProviderID, f.provider.AssignedID, mustMarshalNativeMTP(t, offer))
	snap, _ := f.registry.Resolve(f.provider.ProviderID, f.provider.AssignedID)
	return snap.NativeMTPCanary != nil && snap.NativeMTPCanary.ChallengeBankSHA256 == bank.RawSHA256
}

// The incident shape: a release reload that moves the served catalog must
// move the canary bank with it, so a provider that restarts onto the new
// release and offers its bank is admitted without a coordinator restart.
func TestNativeMTPCanaryBankReloadsWithTheRelease(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	old := f.reload(t, "release-old")
	f.server.SetAutotuneCatalog(&autotune.Catalog{Version: "release-old", SHA256: strings.Repeat("1", 64)})

	next := f.reload(t, "release-new")
	f.server.SetAutotuneCatalog(
		&autotune.Catalog{Version: "release-new", SHA256: strings.Repeat("2", 64)},
		&autotune.Catalog{Version: "release-old", SHA256: strings.Repeat("1", 64)},
	)
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
	f.server.SetAutotuneCatalog(&autotune.Catalog{Version: "release-new", SHA256: strings.Repeat("2", 64)})
	if f.offer(t, old) {
		t.Fatal("offer bound to a no-longer-admitted release's bank was admitted")
	}
	// A third release drops the oldest bank even if its release were retained.
	f.reload(t, "release-third")
	f.server.SetAutotuneCatalog(
		&autotune.Catalog{Version: "release-third", SHA256: strings.Repeat("3", 64)},
		&autotune.Catalog{Version: "release-old", SHA256: strings.Repeat("1", 64)},
	)
	if f.offer(t, old) {
		t.Fatal("offer bound to a bank two releases back was admitted")
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
	next := f.reload(t, "release-new")
	if again := f.reload(t, "release-new"); again != next {
		t.Fatal("reloading the same bank replaced the current bank")
	}
	set := f.server.nativeMTPCanaryBanks.Load()
	if set.previous != old {
		t.Fatal("reloading the same bank dropped the previous bank")
	}
}

func TestNativeMTPCanaryBankReloadIsANoOpWithoutCanaryOrNativeSet(t *testing.T) {
	f := newNativeMTPBankReloadFixture(t)
	prior := f.reload(t, "release-old")
	commit, err := f.server.PrepareNativeMTPCanaryBankReload("release-plain", nil, nil)
	if err != nil {
		t.Fatalf("release without a native set: %v", err)
	}
	commit()
	if f.server.currentNativeMTPCanaryBank() != prior {
		t.Fatal("a release without a native-MTP set replaced the canary bank")
	}

	f.server.cfg.Pool.NativeMTPCanary.Enabled = false
	commit, err = f.server.PrepareNativeMTPCanaryBankReload("release-x", []byte("{}"), []byte("{}"))
	if err != nil {
		t.Fatalf("disabled canary: %v", err)
	}
	commit()
	if f.server.currentNativeMTPCanaryBank() != prior {
		t.Fatal("a disabled canary replaced its bank")
	}
	if err := ValidateNativeMTPCanaryReleaseBank(f.server.cfg.Pool.NativeMTPCanary, "release-x", []byte("{}"), []byte("{}")); err != nil {
		t.Fatalf("offline validation with the canary disabled: %v", err)
	}
}
