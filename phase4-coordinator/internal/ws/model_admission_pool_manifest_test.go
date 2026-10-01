package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

const (
	testPoolA       = "QpsclmzwdJaWJTk3zowcXQ"
	testPoolB       = "AAAAAAAAAAAAAAAAAAAAAA"
	poolGGUFHash    = "6666666666666666666666666666666666666666666666666666666666666666"
	poolDigestV1    = "1111111111111111111111111111111111111111111111111111111111111111"
	poolDigestV2    = "2222222222222222222222222222222222222222222222222222222222222222"
	poolCreator     = "creator-a"
	poolProvider    = "provider-pool"
	poolModelGGUF   = "pool/" + testPoolA + "/creator-gguf"
	poolModelNative = "pool/" + testPoolA + "/creator-mlx"
)

// fakePoolModelSource is a mutable trust-pool registry view.
type fakePoolModelSource struct {
	mu        sync.Mutex
	snapshots map[string]trustpool.Snapshot
	revision  uint64
}

func (f *fakePoolModelSource) PoolIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var ids []string
	for id := range f.snapshots {
		ids = append(ids, id)
	}
	return ids
}

func (f *fakePoolModelSource) Snapshot(poolID string) trustpool.Snapshot {
	f.mu.Lock()
	defer f.mu.Unlock()
	if snap, ok := f.snapshots[poolID]; ok {
		return snap
	}
	return trustpool.Snapshot{PoolID: poolID, Members: map[string]bool{}}
}

func (f *fakePoolModelSource) Revision() uint64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.revision
}

func (f *fakePoolModelSource) set(snap trustpool.Snapshot) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.snapshots == nil {
		f.snapshots = map[string]trustpool.Snapshot{}
	}
	f.snapshots[snap.PoolID] = snap
	f.revision++
}

func ggufPoolEntry() poolmanifest.PoolModelEntry {
	return poolmanifest.PoolModelEntry{
		PoolModelID: poolModelGGUF, ArtifactHashAlgorithm: modelidentity.GGUFFileV1, ArtifactHash: poolGGUFHash,
		AllowedRuntimeSources: []string{"llamacpp_loopback"}, License: "Apache-2.0", PaidServingAttested: true,
		Pricing:         poolmanifest.PoolModelPricing{PromptRatePerMtok: 100, PromptCacheHitRatePerMtok: 10, CompletionRatePerMtok: 300},
		DisclosureClass: poolmanifest.PoolModelDisclosureClass, MaxContextTokens: 32768,
	}
}

func nativePoolEntry(hash string) poolmanifest.PoolModelEntry {
	return poolmanifest.PoolModelEntry{
		PoolModelID: poolModelNative, ArtifactHashAlgorithm: modelidentity.SnapshotManifestV1, ArtifactHash: hash,
		AllowedRuntimeSources: []string{"mlx_cache"}, License: "MIT", PaidServingAttested: true,
		Pricing:         poolmanifest.PoolModelPricing{PromptRatePerMtok: 50, PromptCacheHitRatePerMtok: 5, CompletionRatePerMtok: 150},
		DisclosureClass: poolmanifest.PoolModelDisclosureClass, MaxContextTokens: 8192,
	}
}

func poolSnapshot(poolID string, version uint64, digest string, entries ...poolmanifest.PoolModelEntry) trustpool.Snapshot {
	return trustpool.Snapshot{
		PoolID: poolID, Exists: true, Routeable: true, SettlementMode: "enforce", Generation: version,
		Members: map[string]bool{poolProvider: true}, CreatorAccountID: poolCreator, CreatorOwnedMembers: map[string]bool{poolProvider: true},
		RuntimeAllowlist: []string{"llamacpp_loopback"}, ModelEntries: entries, ManifestVersion: version, ManifestCoreDigest: digest,
	}
}

func wirePoolSource(f *bindingFixture) *fakePoolModelSource {
	source := &fakePoolModelSource{}
	bounds := &poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 1 << 30, MaxPromptCacheHitRatePerMtok: 1 << 30, MaxCompletionRatePerMtok: 1 << 30}
	f.server.SetPoolModelSource(source, func() *poolmanifest.PoolModelPricingBounds { return bounds })
	return source
}

func (f *bindingFixture) registerPoolSession(t *testing.T, providerID, runtimeSource, algorithm, hash string) {
	t.Helper()
	entry := &pool.Provider{ProviderID: providerID, AssignedID: "s-" + providerID, ModelID: "creator-model", State: pool.StateReady,
		RuntimeSource: runtimeSource, ModelHash: hash, ModelHashAlgorithm: algorithm, HashStatus: pool.HashStatusUncatalogued,
		ReceiptPubkey: bytes.Repeat([]byte{9}, ed25519.PublicKeySize), SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1,
		LastHeartbeatAt: f.now, LastActivityAt: f.now}
	if _, ok, refusal := f.server.pool.RegisterAtDetailed(entry, nil, f.now); !ok {
		t.Fatalf("register pool session refused: %v", refusal)
	}
}

func (f *bindingFixture) reevaluate(providerID string) {
	f.server.reevaluatePoolManifestBindings(context.Background(), providerID)
}

// SPEC-047-R011: an unmatched GGUF offer from a creator-owned loopback member
// binds under the signed pool manifest actor to pool-scoped catalog_priced
// with the closed pool_binding object, the session binds to it, and the
// status discloses pool_attested_earning; never settlement_capable.
func TestPoolManifestBindAndSessionBinding(t *testing.T) {
	f := newBindingFixture(t)
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offer(t, poolProvider, "p", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	if offer.CatalogMatchState != modelAdmissionCatalogUnmatched || offer.IntakeModelKey != "artifact/"+modelidentity.GGUFFileV1+"/"+poolGGUFHash {
		t.Fatalf("offer = %+v", offer)
	}
	f.reevaluate(poolProvider)
	head := f.latest(t, poolProvider, offer.CandidateID)
	if head.State != "catalog_priced" || !head.PoolScoped() || head.ReasonCode != ModelAdmissionReasonPoolManifestBound ||
		head.Actor != PoolManifestActor(testPoolA, 1, poolDigestV1) || head.CatalogModelKey != "" ||
		head.PoolModelID != poolModelGGUF || head.ExpectedCatalogModelHash != poolGGUFHash || head.PoolProviderAccountID != poolCreator ||
		head.PoolPromptRatePerMtok != 100 || head.PoolCompletionRatePerMtok != 300 || head.PreviousState != modelAdmissionOfferSubmitted {
		t.Fatalf("pool bind head = %+v", head)
	}
	provider, _ := f.server.pool.Resolve(poolProvider, "")
	if provider.ModelAdmissionCandidateID != offer.CandidateID || provider.ModelAdmissionPoolModelID != poolModelGGUF ||
		provider.ModelAdmissionPoolID != testPoolA || provider.ModelAdmissionValidatedReleaseGeneration == 0 {
		t.Fatalf("session binding = %+v", provider)
	}
	status := f.server.modelAdmissionStatusResponseFromEvent(head, false)
	binding, ok := status["pool_binding"].(map[string]any)
	if !ok || binding["pool_model_id"] != poolModelGGUF || binding["manifest_core_digest"] != poolDigestV1 || len(binding) != 16 {
		t.Fatalf("pool_binding = %+v", status["pool_binding"])
	}
	if status["provider_guidance"].(map[string]any)["earning_path_class"] != "pool_attested_earning" {
		t.Fatalf("guidance = %+v", status["provider_guidance"])
	}
	if _, global := f.server.modelAdmissionStatusResponseFromEvent(offer, false)["pool_binding"]; global {
		t.Fatal("a global status carries pool_binding")
	}
	// Re-evaluation at the same generation appends nothing (idempotent).
	f.reevaluate(poolProvider)
	if again := f.latest(t, poolProvider, offer.CandidateID); again.CoordinatorEventID != head.CoordinatorEventID {
		t.Fatalf("re-evaluation at the active version appended %+v", again)
	}
	// A pool binding never reaches settlement_capable.
	promote := head
	promote.State = "settlement_capable"
	promote.Actor = "operator:alice"
	promote.ReasonCode = "operator_test"
	promote.RequestID, promote.Nonce = "operator_sc", "operator_sc_nonce"
	if _, _, err := f.server.modelAdmissions.CASAppendModelAdmissionDecision(context.Background(), promote, head.CoordinatorEventID); !errors.Is(err, errModelAdmissionReplayConflict) {
		t.Fatalf("pool head -> settlement_capable: err=%v", err)
	}
}

// An offer submitted before its entry existed binds once the entry lands
// (sweep), a new generation carrying the same entry rebinds, and the
// revocation reasons fire on positive evidence only.
func TestPoolManifestLateEntryRebindAndRevocations(t *testing.T) {
	f := newBindingFixture(t)
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1))
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offer(t, poolProvider, "q", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionOfferSubmitted {
		t.Fatalf("bound before the entry existed: %+v", head)
	}
	source.set(poolSnapshot(testPoolA, 2, poolDigestV2, ggufPoolEntry()))
	f.server.sweepPoolManifestBindings(context.Background())
	bound := f.latest(t, poolProvider, offer.CandidateID)
	if bound.State != "catalog_priced" || bound.PoolManifestVersion != 2 {
		t.Fatalf("late entry did not bind: %+v", bound)
	}
	// Rebind: a new version with the same entry (new price) appends the
	// catalog_priced -> catalog_priced self-edge.
	repriced := ggufPoolEntry()
	repriced.Pricing.CompletionRatePerMtok = 400
	source.set(poolSnapshot(testPoolA, 3, strings.Repeat("3", 64), repriced))
	f.reevaluate(poolProvider)
	rebound := f.latest(t, poolProvider, offer.CandidateID)
	if rebound.State != "catalog_priced" || rebound.PreviousState != "catalog_priced" || rebound.ReasonCode != ModelAdmissionReasonPoolManifestRebound ||
		rebound.PoolManifestVersion != 3 || rebound.PoolCompletionRatePerMtok != 400 || rebound.Actor != PoolManifestActor(testPoolA, 3, strings.Repeat("3", 64)) {
		t.Fatalf("rebind = %+v", rebound)
	}
	// An unrouteable view is not evidence: nothing is revoked.
	gone := poolSnapshot(testPoolA, 4, strings.Repeat("4", 64))
	gone.Routeable = false
	source.set(gone)
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.CoordinatorEventID != rebound.CoordinatorEventID {
		t.Fatalf("unrouteable view revoked the binding: %+v", head)
	}
	// Entry removal at the next accepted generation revokes it.
	source.set(poolSnapshot(testPoolA, 4, strings.Repeat("4", 64)))
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionRevoked || head.ReasonCode != ModelAdmissionRevokePoolEntryRevoked {
		t.Fatalf("entry removal = %+v", head)
	}
	provider, _ := f.server.pool.Resolve(poolProvider, "")
	if provider.ModelAdmissionCandidateID != "" {
		t.Fatalf("revoked binding still bound: %+v", provider)
	}
}

func TestPoolManifestRevocationReasons(t *testing.T) {
	for name, tc := range map[string]struct {
		mutate func(*trustpool.Snapshot)
		want   string
	}{
		"membership removed": {func(s *trustpool.Snapshot) { s.Members = map[string]bool{"someone-else": true} }, ModelAdmissionRevokePoolMembershipRevoked},
		"rolled back version": {func(s *trustpool.Snapshot) {
			s.ManifestVersion, s.ManifestCoreDigest = 0, ""
			*s = poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
		}, ModelAdmissionRevokePoolHistoryInvalid},
		"digest changed at the same version": {func(s *trustpool.Snapshot) { s.ManifestCoreDigest = strings.Repeat("9", 64) }, ModelAdmissionRevokePoolHistoryInvalid},
		"runtime dropped from the entry": {func(s *trustpool.Snapshot) {
			entry := ggufPoolEntry()
			entry.AllowedRuntimeSources = []string{"ollama_loopback"}
			s.ModelEntries = []poolmanifest.PoolModelEntry{entry}
			s.ManifestVersion, s.ManifestCoreDigest = 3, strings.Repeat("3", 64)
		}, ModelAdmissionRevokePoolEntryRevoked},
		"delegated member, no attestation": {func(s *trustpool.Snapshot) { s.CreatorOwnedMembers = map[string]bool{} }, ModelAdmissionRevokePoolMembershipRevoked},
	} {
		t.Run(name, func(t *testing.T) {
			f := newBindingFixture(t)
			source := wirePoolSource(f)
			source.set(poolSnapshot(testPoolA, 2, poolDigestV2, ggufPoolEntry()))
			f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
			offer := f.offer(t, poolProvider, "r", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
			f.reevaluate(poolProvider)
			if head := f.latest(t, poolProvider, offer.CandidateID); head.State != "catalog_priced" {
				t.Fatalf("not bound: %+v", head)
			}
			snap := poolSnapshot(testPoolA, 2, poolDigestV2, ggufPoolEntry())
			tc.mutate(&snap)
			source.set(snap)
			f.reevaluate(poolProvider)
			if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionRevoked || head.ReasonCode != tc.want {
				t.Fatalf("head = %+v, want revoked %s", head, tc.want)
			}
		})
	}
}

// SPEC-042-R016: a delegated member binds only through a creator
// attestation naming its recorded owner account for the runtime class.
func TestPoolManifestAttestedMemberBinds(t *testing.T) {
	f := newBindingFixture(t)
	source := wirePoolSource(f)
	snap := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
	snap.CreatorOwnedMembers = map[string]bool{}
	snap.MemberOwnerAccounts = map[string]string{poolProvider: "acct-member"}
	source.set(snap)
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offer(t, poolProvider, "s", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionOfferSubmitted {
		t.Fatalf("unattested delegated member bound: %+v", head)
	}
	snap.AttestedMembers = []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member", RuntimeClasses: []string{"llamacpp_loopback"}}}
	source.set(snap)
	f.reevaluate(poolProvider)
	head := f.latest(t, poolProvider, offer.CandidateID)
	if head.State != "catalog_priced" || head.PoolProviderAccountID != "acct-member" {
		t.Fatalf("attested member bind = %+v", head)
	}
	// Removing the attestation revokes it.
	snap.AttestedMembers = nil
	source.set(snap)
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionRevoked || head.ReasonCode != ModelAdmissionRevokePoolMembershipRevoked {
		t.Fatalf("attestation removal = %+v", head)
	}
}

// Cardinality, format mismatch, and catalog precedence keep an offer unbound.
func TestPoolManifestNoBindCases(t *testing.T) {
	t.Run("two pools match", func(t *testing.T) {
		f := newBindingFixture(t)
		source := wirePoolSource(f)
		source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
		other := ggufPoolEntry()
		other.PoolModelID = "pool/" + testPoolB + "/creator-gguf"
		source.set(poolSnapshot(testPoolB, 1, poolDigestV1, other))
		f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
		offer := f.offer(t, poolProvider, "t", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
		f.reevaluate(poolProvider)
		if head := f.latest(t, poolProvider, offer.CandidateID); head.PoolScoped() {
			t.Fatalf("multi-pool offer bound: %+v", head)
		}
	})
	t.Run("gguf entry, native offer", func(t *testing.T) {
		f := newBindingFixture(t)
		source := wirePoolSource(f)
		source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
		f.registerPoolSession(t, poolProvider, "mlx_cache", modelidentity.SnapshotManifestV1, poolGGUFHash)
		offer := f.offer(t, poolProvider, "u", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: poolGGUFHash})
		f.reevaluate(poolProvider)
		if head := f.latest(t, poolProvider, offer.CandidateID); head.PoolScoped() {
			t.Fatalf("native offer bound to a GGUF entry: %+v", head)
		}
	})
	t.Run("recommendable catalog pair", func(t *testing.T) {
		f := newBindingFixture(t)
		source := wirePoolSource(f)
		source.set(poolSnapshot(testPoolA, 1, poolDigestV1, nativePoolEntry(bindingOtherHash)))
		f.registerPoolSession(t, poolProvider, "mlx_cache", modelidentity.SnapshotManifestV1, bindingOtherHash)
		offer := f.offer(t, poolProvider, "v", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingOtherHash})
		f.reevaluate(poolProvider)
		if head := f.latest(t, poolProvider, offer.CandidateID); head.PoolScoped() {
			t.Fatalf("catalog-priceable pair bound to a pool: %+v", head)
		}
	})
}

// SPEC-042-R015 precedence: a listed match binds and is recorded as
// observed_catalog_model_key; promotion to recommendable supersedes it; a
// blocked row revokes it as entry revoked. Native mlx_cache binds a
// snapshot-manifest entry.
func TestPoolManifestCatalogPrecedence(t *testing.T) {
	for name, tc := range map[string]struct {
		later string
		want  string
	}{
		"promoted to recommendable": {"recommendable", ModelAdmissionRevokePoolCatalogSuperseded},
		"blocked later":             {"blocked", ModelAdmissionRevokePoolEntryRevoked},
	} {
		t.Run(name, func(t *testing.T) {
			f := newBindingFixture(t)
			poolHash := strings.Repeat("7", 64)
			listed := bindingCatalog(t, "release-2", "listed", poolHash)
			f.publish(listed, map[string]*artifactidentity.Index{listed.SHA256: bindingIndex(t, listed, strings.Repeat("a", 64), f.now, nil)})
			source := wirePoolSource(f)
			source.set(poolSnapshot(testPoolA, 1, poolDigestV1, nativePoolEntry(poolHash)))
			f.registerPoolSession(t, poolProvider, "mlx_cache", modelidentity.SnapshotManifestV1, poolHash)
			offer := f.offer(t, poolProvider, "w", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: poolHash})
			f.reevaluate(poolProvider)
			head := f.latest(t, poolProvider, offer.CandidateID)
			if head.State != "catalog_priced" || !head.PoolScoped() || head.PoolObservedCatalogModelKey != "small" || head.CatalogModelKey != "" {
				t.Fatalf("listed-match native bind = %+v", head)
			}
			later := bindingCatalog(t, "release-3", tc.later, poolHash)
			f.publish(later, map[string]*artifactidentity.Index{later.SHA256: bindingIndex(t, later, strings.Repeat("a", 64), f.now, nil)})
			f.reevaluate(poolProvider)
			if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionRevoked || head.ReasonCode != tc.want {
				t.Fatalf("after %s: head = %+v, want revoked %s", tc.later, head, tc.want)
			}
		})
	}
}

// Session drift of a pool binding revokes it with pool_manifest_binding_drift.
func TestPoolManifestSessionDrift(t *testing.T) {
	f := newBindingFixture(t)
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offer(t, poolProvider, "x", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	f.reevaluate(poolProvider)
	head := f.latest(t, poolProvider, offer.CandidateID)
	drifted, _ := f.server.pool.Resolve(poolProvider, "")
	drifted.ModelHash = strings.Repeat("8", 64)
	if reason, drift := sessionDriftReason(drifted, head); !drift || reason != ModelAdmissionRevokePoolBindingDrift {
		t.Fatalf("drift = %q %v", reason, drift)
	}
	f.server.withProviderSection(poolProvider, func(section *providerSection) {
		f.server.evaluateSessionDriftLocked(context.Background(), drifted, []string{offer.CandidateID}, section)
	})
	if after := f.latest(t, poolProvider, offer.CandidateID); after.State != modelAdmissionRevoked || after.ReasonCode != ModelAdmissionRevokePoolBindingDrift {
		t.Fatalf("drift revocation = %+v", after)
	}
}

// SPEC-032-R004: only a member's exact native pair of a current entry
// listing mlx_cache is exempted at hello.
func TestNativePoolEntryHelloExemption(t *testing.T) {
	f := newBindingFixture(t)
	poolHash := strings.Repeat("7", 64)
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, nativePoolEntry(poolHash), ggufPoolEntry()))
	if pool, ok := f.server.poolEntryForSession(poolProvider, "mlx_cache", modelidentity.SnapshotManifestV1, poolHash); !ok || pool != testPoolA {
		t.Fatalf("member native entry not exempted: %q %v", pool, ok)
	}
	for name, args := range map[string][3]string{
		"non-member":     {"stranger", modelidentity.SnapshotManifestV1, poolHash},
		"gguf pair":      {poolProvider, modelidentity.GGUFFileV1, poolGGUFHash},
		"unknown hash":   {poolProvider, modelidentity.SnapshotManifestV1, strings.Repeat("e", 64)},
		"catalog priced": {poolProvider, modelidentity.SnapshotManifestV1, bindingOtherHash},
	} {
		if _, ok := f.server.poolEntryForSession(args[0], "", args[1], args[2]); ok {
			t.Errorf("%s: exempted", name)
		}
	}
}

func TestHashDerivedIntakeKey(t *testing.T) {
	hash := strings.Repeat("a", 64)
	for name, tc := range map[string]struct {
		runtime string
		hashes  map[string]string
		want    string
	}{
		"gguf loopback":   {"llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: hash}, "artifact/" + modelidentity.GGUFFileV1 + "/" + hash},
		"native snapshot": {"mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: hash, modelidentity.GGUFFileV1: hash}, "artifact/" + modelidentity.SnapshotManifestV1 + "/" + hash},
		"no compatible":   {"mlx_cache", map[string]string{modelidentity.GGUFFileV1: hash}, ""},
		"malformed":       {"llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: "ABC"}, ""},
		"openai adapter":  {"openai_compatible_loopback", map[string]string{modelidentity.GGUFFileV1: hash}, ""},
	} {
		if got := hashDerivedModelAdmissionIntakeKey(tc.runtime, tc.hashes); got != tc.want {
			t.Errorf("%s: key=%q want %q", name, got, tc.want)
		}
	}
}

// The SQLite store persists and reads back the closed pool_binding columns
// and the offered pairs.
func TestSQLiteModelAdmissionStorePoolBindingColumns(t *testing.T) {
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "ma.sqlite")))
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := NewSQLiteModelAdmissionStore(db)
	if err != nil {
		t.Fatal(err)
	}
	f := newBindingFixture(t)
	f.server.modelAdmissions = store
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offer(t, poolProvider, "y", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	if offer.OfferedArtifactHashes[modelidentity.GGUFFileV1] != poolGGUFHash {
		t.Fatalf("offered pairs not persisted: %+v", offer)
	}
	f.reevaluate(poolProvider)
	head := f.latest(t, poolProvider, offer.CandidateID)
	if head.State != "catalog_priced" || head.PoolModelID != poolModelGGUF || head.PoolManifestVersion != 1 ||
		head.PoolMaxContextTokens != 32768 || head.PoolPromptCacheHitRatePerMtok != 10 || head.Actor != PoolManifestActor(testPoolA, 1, poolDigestV1) {
		t.Fatalf("sqlite pool head = %+v", head)
	}
}

// activationPoolModelSource reports generation activations like the
// trust-pool registry does (#1816 F3).
type activationPoolModelSource struct {
	fakePoolModelSource
	hookMu sync.Mutex
	hook   func()
}

func (a *activationPoolModelSource) SetManifestActivationHook(fn func()) {
	a.hookMu.Lock()
	defer a.hookMu.Unlock()
	a.hook = fn
}

func (a *activationPoolModelSource) activate(snap trustpool.Snapshot) {
	// A time-based activation changes the active core without a new
	// durable revision.
	a.mu.Lock()
	a.snapshots[snap.PoolID] = snap
	a.mu.Unlock()
	a.hookMu.Lock()
	hook := a.hook
	a.hookMu.Unlock()
	if hook != nil {
		hook()
	}
}

// #1816 F3: the binding sweep runs at activation time, not only on its
// timer, so the rebind is recorded well inside one sweep interval.
func TestPoolManifestSweepKickedAtActivation(t *testing.T) {
	f := newBindingFixture(t)
	source := &activationPoolModelSource{}
	bounds := &poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 1 << 30, MaxPromptCacheHitRatePerMtok: 1 << 30, MaxCompletionRatePerMtok: 1 << 30}
	f.server.SetPoolModelSource(source, func() *poolmanifest.PoolModelPricingBounds { return bounds })
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offer(t, poolProvider, "k", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	f.reevaluate(poolProvider)
	if head := f.latest(t, poolProvider, offer.CandidateID); head.PoolManifestVersion != 1 {
		t.Fatalf("bind = %+v", head)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		f.server.RunPoolManifestBindingSweep(ctx)
	}()
	source.activate(poolSnapshot(testPoolA, 2, poolDigestV2, ggufPoolEntry()))
	deadline := time.Now().Add(poolManifestBindingSweepInterval / 2)
	for {
		if head := f.latest(t, poolProvider, offer.CandidateID); head.PoolManifestVersion == 2 && head.ReasonCode == ModelAdmissionReasonPoolManifestRebound {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("rebind not recorded within %s of activation", poolManifestBindingSweepInterval/2)
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
}

// Freeze audit R1 (#1816) CODE M4 / ARCHITECTURE M4: status claims
// pool_attested_earning only while the current pool predicate holds. Every
// invalidation below is applied without running the sweep, so the head is
// still the pool-scoped catalog_priced event.
func TestPoolScopedStatusEarningReevaluatesCurrentPredicate(t *testing.T) {
	earning := func(f *bindingFixture, head ModelAdmissionEvent) string {
		status := f.server.modelAdmissionStatusResponseFromEvent(head, false)
		return status["provider_guidance"].(map[string]any)["earning_path_class"].(string)
	}
	for name, invalidate := range map[string]func(*fakePoolModelSource, *bindingFixture){
		"entry removed": func(s *fakePoolModelSource, _ *bindingFixture) { s.set(poolSnapshot(testPoolA, 2, poolDigestV2)) },
		"pool not routeable": func(s *fakePoolModelSource, _ *bindingFixture) {
			v := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
			v.Routeable = false
			s.set(v)
		},
		"member removed": func(s *fakePoolModelSource, _ *bindingFixture) {
			v := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
			v.Members = map[string]bool{}
			s.set(v)
		},
		"no longer creator-owned, unattested": func(s *fakePoolModelSource, _ *bindingFixture) {
			v := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
			v.CreatorOwnedMembers = map[string]bool{}
			v.MemberOwnerAccounts = map[string]string{poolProvider: "acct-member"}
			s.set(v)
		},
		"runtime off allowlist": func(s *fakePoolModelSource, _ *bindingFixture) {
			v := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
			v.RuntimeAllowlist = nil
			s.set(v)
		},
		"bounds removed": func(s *fakePoolModelSource, f *bindingFixture) {
			f.server.SetPoolModelSource(s, func() *poolmanifest.PoolModelPricingBounds { return nil })
		},
		"bounds tightened below the entry": func(s *fakePoolModelSource, f *bindingFixture) {
			f.server.SetPoolModelSource(s, func() *poolmanifest.PoolModelPricingBounds {
				return &poolmanifest.PoolModelPricingBounds{MaxPromptRatePerMtok: 1, MaxPromptCacheHitRatePerMtok: 1, MaxCompletionRatePerMtok: 1}
			})
		},
		"pool wiring off": func(_ *fakePoolModelSource, f *bindingFixture) { f.server.SetPoolModelSource(nil, nil) },
	} {
		t.Run(name, func(t *testing.T) {
			f := newBindingFixture(t)
			source := wirePoolSource(f)
			source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
			f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
			offer := f.offer(t, poolProvider, "q", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
			f.reevaluate(poolProvider)
			bound := f.latest(t, poolProvider, offer.CandidateID)
			if bound.State != "catalog_priced" || !bound.PoolScoped() {
				t.Fatalf("bind = %+v", bound)
			}
			if got := earning(f, bound); got != "pool_attested_earning" {
				t.Fatalf("current binding earning_path_class = %q", got)
			}
			invalidate(source, f)
			if got := earning(f, bound); got == "pool_attested_earning" {
				t.Fatalf("stale binding still reports pool_attested_earning")
			}
		})
	}
}

// Freeze audit R1 (#1816) SECURITY H4: a GGUF (non-primary) artifact of a
// blocked row is kept as a deny pair, so a pool binding to it is revoked when
// the row becomes blocked, acceptance rejects it, and the hello exemption
// refuses it, even when the feed is too stale to authorize identities.
func TestPoolManifestBlockedArtifactFeedPairDenies(t *testing.T) {
	for name, feedAge := range map[string]time.Duration{"fresh feed": 0, "stale feed": 30 * 24 * time.Hour} {
		t.Run(name, func(t *testing.T) {
			f := newBindingFixture(t)
			source := wirePoolSource(f)
			source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
			f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
			offer := f.offer(t, poolProvider, "blk", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
			f.reevaluate(poolProvider)
			if head := f.latest(t, poolProvider, offer.CandidateID); head.State != "catalog_priced" || !head.PoolScoped() {
				t.Fatalf("uncatalogued GGUF bind = %+v", head)
			}
			blocked := bindingCatalog(t, "release-blocked", "blocked", strings.Repeat("6", 64))
			index, err := artifactidentity.NewWithBlocked(artifactidentity.Provenance{
				FeedSHA256: strings.Repeat("a", 64), SignerKeyID: "k1", ReleaseID: blocked.Version, CandidateCatalogSHA256: blocked.SHA256,
				FeedGeneratedAt: f.now.Add(-time.Hour - feedAge),
			}, nil, []artifactidentity.Member{{ModelKey: "small", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: poolGGUFHash}})
			if err != nil {
				t.Fatal(err)
			}
			f.publish(blocked, map[string]*artifactidentity.Index{blocked.SHA256: index})
			if !f.server.ArtifactPairInCatalog(modelidentity.GGUFFileV1, poolGGUFHash, []string{"llamacpp_loopback"}) {
				t.Fatal("acceptance does not reject a blocked artifact-feed pair")
			}
			if _, ok := f.server.poolEntryForSession(poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash); ok {
				t.Fatal("hello exemption granted to a blocked artifact-feed pair")
			}
			f.reevaluate(poolProvider)
			if head := f.latest(t, poolProvider, offer.CandidateID); head.State != modelAdmissionRevoked || head.ReasonCode != ModelAdmissionRevokePoolEntryRevoked {
				t.Fatalf("blocked artifact-feed pair binding = %+v, want revoked %s", head, ModelAdmissionRevokePoolEntryRevoked)
			}
		})
	}
}

// countingModelAdmissionStore counts the listings and appends a sweep makes.
type countingModelAdmissionStore struct {
	ModelAdmissionStore
	perProvider, inStates, appends atomic.Int32
}

func (s *countingModelAdmissionStore) LatestModelAdmissionStatusesForProvider(ctx context.Context, providerID string) ([]ModelAdmissionEvent, error) {
	s.perProvider.Add(1)
	return s.ModelAdmissionStore.LatestModelAdmissionStatusesForProvider(ctx, providerID)
}

func (s *countingModelAdmissionStore) LatestModelAdmissionStatusesInStates(ctx context.Context, states []string) ([]ModelAdmissionEvent, error) {
	s.inStates.Add(1)
	return s.ModelAdmissionStore.LatestModelAdmissionStatusesInStates(ctx, states)
}

func (s *countingModelAdmissionStore) AppendModelAdmissionDecision(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	s.appends.Add(1)
	return s.ModelAdmissionStore.AppendModelAdmissionDecision(ctx, event)
}

// #1816 VM acceptance A-8: after a restart, a bound member whose session is
// gone is skipped, never re-appended, and costs one per-provider listing per
// sweep; an online member of the same pool keeps its binding and session.
func TestPoolManifestSweepOfflineMemberIsCheap(t *testing.T) {
	const offline = "provider-offline"
	f := newBindingFixture(t)
	source := wirePoolSource(f)
	snap := poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry())
	snap.Members[offline] = true
	snap.CreatorOwnedMembers[offline] = true
	source.set(snap)
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	f.registerPoolSession(t, offline, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	online := f.offer(t, poolProvider, "t", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	gone := f.offer(t, offline, "u", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash})
	f.server.sweepPoolManifestBindings(context.Background())
	onlineHead := f.latest(t, poolProvider, online.CandidateID)
	goneHead := f.latest(t, offline, gone.CandidateID)
	if onlineHead.State != "catalog_priced" || goneHead.State != "catalog_priced" {
		t.Fatalf("both members should bind first: %+v / %+v", onlineHead, goneHead)
	}
	// The offline member's session ends (as across a coordinator restart).
	p, _ := f.server.pool.Resolve(offline, "")
	if !f.server.pool.RemoveIfSession(offline, p.AssignedID) {
		t.Fatal("remove offline session")
	}
	counting := &countingModelAdmissionStore{ModelAdmissionStore: f.server.modelAdmissions}
	f.server.modelAdmissions = counting
	const sweeps = 5
	for i := 0; i < sweeps; i++ {
		f.server.sweepPoolManifestBindings(context.Background())
	}
	if n := counting.appends.Load(); n != 0 {
		t.Fatalf("%d sweeps appended %d decisions in steady state", sweeps, n)
	}
	if in, per := counting.inStates.Load(), counting.perProvider.Load(); in != sweeps || per > 2*sweeps {
		t.Fatalf("%d sweeps listed %d times globally and %d per provider, want %d and at most %d", sweeps, in, per, sweeps, 2*sweeps)
	}
	if head := f.latest(t, offline, gone.CandidateID); head.CoordinatorEventID != goneHead.CoordinatorEventID {
		t.Fatalf("offline member's binding changed: %+v", head)
	}
	if head := f.latest(t, poolProvider, online.CandidateID); head.CoordinatorEventID != onlineHead.CoordinatorEventID {
		t.Fatalf("online member's binding changed: %+v", head)
	}
	if provider, ok := f.server.pool.Resolve(poolProvider, ""); !ok || provider.ModelAdmissionCandidateID != online.CandidateID || provider.ModelAdmissionPoolModelID != poolModelGGUF {
		t.Fatalf("online member's session binding = %+v", provider)
	}
}
