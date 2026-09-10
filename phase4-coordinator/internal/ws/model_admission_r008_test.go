package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// R008: a decision that started as a release reader must complete even when
// a publisher queues behind it (no nested release read lock, no
// release-then-registry acquisition), and the publisher then lands.
func TestModelAdmissionDecisionCompletesWithQueuedPublisher(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	s.newUUID = uuid.NewString
	c := operatorClient{t: t, s: s}
	f.registerSession(t, "p1", "s1", "model-a", true)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})

	published := make(chan struct{})
	var once sync.Once
	s.artifactIdentitySets.onReadLocked = func() {
		once.Do(func() {
			// The reader holds the release lock; a publisher queues behind it.
			go func() {
				f.publish(bindingCatalog(t, "release-queued", "recommendable", bindingRowHash), nil)
				close(published)
			}()
			time.Sleep(100 * time.Millisecond)
		})
	}
	done := make(chan struct{})
	var code int
	var body map[string]any
	go func() {
		code, body = c.do(http.MethodPost, "/admin/model-admission/decisions", "alice-secret", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_ok", offer.CoordinatorEventID, "k1"))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("decision deadlocked against a queued publisher")
	}
	if code != http.StatusOK {
		t.Fatalf("decision under a queued publisher: %d %v", code, body)
	}
	select {
	case <-published:
	case <-time.After(5 * time.Second):
		t.Fatal("publisher never landed after the reader finished")
	}
	s.artifactIdentitySets.onReadLocked = nil
	// The decision evaluated under the OLD generation; the sweep that ran on
	// publication re-validated the surviving candidate under the new one.
	stored := f.latest(t, "p1", offer.CandidateID)
	if stored.State != "catalog_priced" || stored.EvaluatedReleaseGeneration >= s.ReleaseGeneration() {
		t.Fatalf("decision generation: %+v (current %d)", stored, s.ReleaseGeneration())
	}
	if p, _ := s.pool.Resolve("p1", ""); p.ModelAdmissionValidatedReleaseGeneration != s.ReleaseGeneration() {
		t.Fatalf("sweep must re-stamp the binding: %d vs %d", p.ModelAdmissionValidatedReleaseGeneration, s.ReleaseGeneration())
	}
}

// R008: two concurrent first-seen requests with one idempotency key resolve
// as one append plus one replay, never stale_head.
func TestModelAdmissionConcurrentFirstSeenDecisionsWithOneKey(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	s.cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	s.newUUID = uuid.NewString
	c := operatorClient{t: t, s: s}
	f.registerSession(t, "p1", "s1", "model-a", true)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	var wg sync.WaitGroup
	results := make([]map[string]any, 2)
	codes := make([]int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i], results[i] = c.do(http.MethodPost, "/admin/model-admission/decisions", "alice-secret", decisionRequest("p1", offer.CandidateID, "catalog_priced", "operator_ok", offer.CoordinatorEventID, "same-key"))
		}(i)
	}
	wg.Wait()
	replays := 0
	for i := range results {
		if codes[i] != http.StatusOK {
			t.Fatalf("request %d: %d %v", i, codes[i], results[i])
		}
		if results[i]["replayed"] == true {
			replays++
		}
	}
	if replays != 1 || results[0]["coordinator_event_id"] != results[1]["coordinator_event_id"] {
		t.Fatalf("expected one append + one replay of the same event: %v %v", results[0], results[1])
	}
	events, _ := s.modelAdmissions.LatestModelAdmissionStatusesForProvider(context.Background(), "p1")
	if len(events) != 1 || events[0].State != "catalog_priced" {
		t.Fatalf("exactly one decision must exist: %+v", events)
	}
}

// R008: the route-time compare-and-insert fails closed when an append lands
// between the compare and the insert (the immutable snapshot stands,
// nothing is dispatched), and when the binding generation moved.
func TestModelAdmissionRouteCompareAndInsertFailsClosedOnConcurrentAppend(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerSession(t, "p1", "s1", "model-a", true)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	priced := f.decide(t, offer, "catalog_priced")
	settled := f.decide(t, priced, "settlement_capable")
	p, _ := s.pool.Resolve("p1", "")
	expect := ModelAdmissionRouteExpectation{ProviderID: "p1", CandidateID: settled.CandidateID, CoordinatorEventID: settled.CoordinatorEventID, BindingGeneration: p.ModelAdmissionBindingGeneration, SessionEpoch: p.ModelAdmissionSessionEpoch}
	inserted := 0
	if err := s.CompareAndInsertModelAdmissionRouteSnapshot(context.Background(), expect, func() error { inserted++; return nil }); err != nil {
		t.Fatalf("clean compare-and-insert: %v", err)
	}
	// An append racing the insert: revocation appended by the store while
	// the insert runs (the section is not held by the route path).
	err := s.CompareAndInsertModelAdmissionRouteSnapshot(context.Background(), expect, func() error {
		inserted++
		revocation := modelAdmissionCoordinatorDecisionFromCurrent(settled, modelAdmissionRevoked, "runtime_identity_drift", "test", "race", f.now)
		if _, err := s.modelAdmissions.AppendModelAdmissionDecision(context.Background(), revocation); err != nil {
			t.Fatalf("racing revocation: %v", err)
		}
		return nil
	})
	if !errors.Is(err, ErrModelAdmissionRouteStale) || inserted != 2 {
		t.Fatalf("racing append must fail the attempt closed after the insert: err=%v inserted=%d", err, inserted)
	}
	// A binding generation that moved since evaluation fails before insert.
	f.registerSession(t, "p2", "s2", "model-a", true)
	offer2 := f.offer(t, "p2", "b", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	settled2 := f.decide(t, f.decide(t, offer2, "catalog_priced"), "settlement_capable")
	p2, _ := s.pool.Resolve("p2", "")
	stale := ModelAdmissionRouteExpectation{ProviderID: "p2", CandidateID: settled2.CandidateID, CoordinatorEventID: settled2.CoordinatorEventID, BindingGeneration: p2.ModelAdmissionBindingGeneration - 1, SessionEpoch: p2.ModelAdmissionSessionEpoch}
	inserted = 0
	if err := s.CompareAndInsertModelAdmissionRouteSnapshot(context.Background(), stale, func() error { inserted++; return nil }); !errors.Is(err, ErrModelAdmissionRouteStale) || inserted != 0 {
		t.Fatalf("stale binding generation must fail before insert: err=%v inserted=%d", err, inserted)
	}
	// A second candidate for the same row appended while the first is
	// routable: the binding generation moves, the in-flight attempt fails.
	current := ModelAdmissionRouteExpectation{ProviderID: "p2", CandidateID: settled2.CandidateID, CoordinatorEventID: settled2.CoordinatorEventID, BindingGeneration: p2.ModelAdmissionBindingGeneration, SessionEpoch: p2.ModelAdmissionSessionEpoch}
	f.offer(t, "p2", "c", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	if err := s.CompareAndInsertModelAdmissionRouteSnapshot(context.Background(), current, func() error { inserted++; return nil }); !errors.Is(err, ErrModelAdmissionRouteStale) || inserted != 0 {
		t.Fatalf("offer for candidate B must fail the in-flight attempt for A: err=%v", err)
	}
}

// R008: same-model identity drift observed by the registry between a route
// attempt's evaluation and its compare-and-insert — before the drift path
// appended anything — fails the attempt closed through the session epoch.
func TestModelAdmissionRouteCompareAndInsertFailsClosedOnSessionIdentityDrift(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerSession(t, "p1", "s1", "model-a", true)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	settled := f.decide(t, f.decide(t, offer, "catalog_priced"), "settlement_capable")
	p, _ := s.pool.Resolve("p1", "")
	expect := ModelAdmissionRouteExpectation{ProviderID: "p1", CandidateID: settled.CandidateID, CoordinatorEventID: settled.CoordinatorEventID, BindingGeneration: p.ModelAdmissionBindingGeneration, SessionEpoch: p.ModelAdmissionSessionEpoch}
	// The registry applies a same-model heartbeat with another hash (no
	// binding mutation, no append yet).
	result := s.pool.ApplyHeartbeatDetailed("p1", "s1", pool.HeartbeatUpdate{Status: pool.StateReady, ModelID: "model-a", ModelHash: strings.Repeat("f", 64), ModelHashPresent: true,
		ModelHashAlgorithm: modelidentity.SnapshotManifestV1, ModelHashAlgorithmPresent: true, ExpectedModelHash: bindingRowHash,
		MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: f.now.Add(time.Minute)})
	if !result.OK || result.Provider.ModelAdmissionSessionEpoch == p.ModelAdmissionSessionEpoch || result.Provider.ModelAdmissionCandidateID != settled.CandidateID {
		t.Fatalf("identity change must advance the epoch and leave the binding: %+v", result.Provider)
	}
	inserted := 0
	if err := s.CompareAndInsertModelAdmissionRouteSnapshot(context.Background(), expect, func() error { inserted++; return nil }); !errors.Is(err, ErrModelAdmissionRouteStale) || inserted != 0 {
		t.Fatalf("drifted identity must fail before insert: err=%v inserted=%d", err, inserted)
	}
	// A heartbeat that changes nothing keeps the epoch.
	before := result.Provider.ModelAdmissionSessionEpoch
	again := s.pool.ApplyHeartbeatDetailed("p1", "s1", pool.HeartbeatUpdate{Status: pool.StateReady, ModelID: "model-a", ModelHash: strings.Repeat("f", 64), ModelHashPresent: true,
		ModelHashAlgorithm: modelidentity.SnapshotManifestV1, ModelHashAlgorithmPresent: true, ExpectedModelHash: bindingRowHash,
		MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: f.now.Add(2 * time.Minute)})
	if again.Provider.ModelAdmissionSessionEpoch != before {
		t.Fatal("an unchanged identity must not advance the epoch")
	}
}

// R003(ii): row recommendability is evaluated before member runtime-source
// policy — a listed row whose member also lost the source answers
// catalog_row_not_recommendable (sweep: catalog_row_ineligible).
func TestModelAdmissionPreconditionOrderRowBeforeRuntimeSource(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerGGUFSession(t, "p1", "s1")
	feedOffer := f.offer(t, "p1", "g", "ollama_loopback", map[string]string{modelidentity.GGUFFileV1: f.gguf})
	priced := f.decide(t, feedOffer, "catalog_priced")
	// New release: row listed AND the gguf member no longer allows ollama_loopback.
	listed := bindingCatalog(t, "release-listed", "listed", bindingRowHash)
	members := bindingMembers(f.gguf, "")
	members[1].AllowedRuntimeSources = "llamacpp_loopback"
	s.withReleaseRead(func() {
		set := bindingIndex(t, listed, strings.Repeat("e", 64), f.now, members)
		saved := s.artifactIdentitySets.sets
		s.artifactIdentitySets.sets = map[string]*artifactidentity.Index{listed.SHA256: set}
		defer func() { s.artifactIdentitySets.sets = saved }()
		if eval := s.evaluateCatalogPreconditionsLocked(priced, listed); eval.decisionCode != "catalog_row_not_recommendable" || eval.driftReason != "catalog_row_ineligible" {
			t.Fatalf("row eligibility must precede runtime-source policy: %+v", eval)
		}
		recommendable := bindingCatalog(t, "release-rec", "recommendable", bindingRowHash)
		s.artifactIdentitySets.sets = map[string]*artifactidentity.Index{recommendable.SHA256: bindingIndex(t, recommendable, strings.Repeat("e", 64), f.now, members)}
		if eval := s.evaluateCatalogPreconditionsLocked(priced, recommendable); eval.decisionCode != "runtime_source_not_allowed" || eval.driftReason != "catalog_runtime_source_disallowed" {
			t.Fatalf("runtime-source policy after row eligibility: %+v", eval)
		}
	})
}

// R008 / SPEC-010-R004 v1.8: a session on a retained compatible-previous
// release settles only when that release carries the SAME row tuple; a
// re-stamp (same content) keeps settling, a changed row digest does not.
func TestModelAdmissionSettlementRequiresSessionReleaseRowTuple(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	// Session admitted on release-1 (kept as compatible-previous).
	f.registerSession(t, "p1", "s1", "model-a", true)
	// Re-stamp: same content, new release id; the session still settles.
	restamped := bindingCatalog(t, "release-2", "recommendable", bindingRowHash)
	f.publish(restamped, map[string]*artifactidentity.Index{
		restamped.SHA256: bindingIndex(t, restamped, strings.Repeat("e", 64), f.now, bindingMembers(f.gguf, "")),
		f.catalog.SHA256: f.index,
	}, f.catalog)
	offer := f.offer(t, "p1", "a", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: bindingRowHash})
	priced := f.decide(t, offer, "catalog_priced")
	provider, _ := s.pool.Resolve("p1", "")
	if provider.CatalogReleaseID != "release-1" {
		t.Fatalf("session must stay on its own release: %q", provider.CatalogReleaseID)
	}
	s.withReleaseRead(func() {
		cur, comp := s.autotuneCatalogSnapshot()
		if _, _, ok := s.settlementSessionMemberLocked(priced, provider, cur, comp); !ok {
			t.Fatal("re-stamp with the same row tuple must keep the session settlement-eligible")
		}
	})
	// Content change: release-3 changes the row digest; a fresh offer under
	// release-3 matches the new digest, but a session whose own release
	// (release-1, retained) carries the old tuple must not bind.
	changedHash := strings.Repeat("1", 64)
	changed := bindingCatalog(t, "release-3", "recommendable", changedHash)
	f.publish(changed, nil, f.catalog)
	f.registerSession(t, "p2", "s2", "model-a", true)
	p2, _ := s.pool.Resolve("p2", "")
	p2entry := p2
	p2entry.AssignedID = "s2b"
	p2entry.CatalogReleaseID = "release-1"
	p2entry.CandidateCatalogSHA256 = f.catalog.SHA256
	if _, ok, _ := s.pool.RegisterAtDetailed(&p2entry, nil, f.now); !ok {
		t.Fatal("register p2 on release-1")
	}
	offer2 := f.offer(t, "p2", "b", "mlx_cache", map[string]string{modelidentity.SnapshotManifestV1: changedHash})
	if offer2.CatalogMatchState != "catalog_matched" || offer2.CatalogRowModelSHA256 != changedHash {
		t.Fatalf("offer under release-3: %+v", offer2)
	}
	session, _ := s.pool.Resolve("p2", "")
	s.withReleaseRead(func() {
		cur, comp := s.autotuneCatalogSnapshot()
		if _, _, ok := s.settlementSessionMemberLocked(offer2, session, cur, comp); ok {
			t.Fatal("a session whose own release carries another row digest must not bind for settlement")
		}
	})
}

// R008: feed freshness gates the feed path at match and decision time, and a
// GGUF (loopback) member never binds for settlement until the runtime path
// reports the source.
func TestModelAdmissionStaleFeedAndRuntimeSourceAtDecisionTime(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerSession(t, "p1", "s1", "model-a", true)
	feedOffer := f.offer(t, "p1", "g", "ollama_loopback", map[string]string{modelidentity.GGUFFileV1: f.gguf})
	if feedOffer.CatalogMatchState != "catalog_matched" {
		t.Fatalf("fresh feed must match: %+v", feedOffer)
	}
	priced := f.decide(t, feedOffer, "catalog_priced")
	// A GGUF-pinned session presents a loopback source the coordinator cannot
	// verify: never bound for settlement (R003(iv) until R007(e)).
	entry := &pool.Provider{ProviderID: "p1", AssignedID: "s1b", ModelID: "model-a", State: pool.StateReady,
		ModelHash: f.gguf, ModelHashAlgorithm: modelidentity.GGUFFileV1, ExpectedModelHash: bindingRowHash, HashStatus: pool.HashStatusVerified,
		ArtifactIdentity:       &artifactidentity.Binding{Member: artifactidentity.Member{ModelKey: "small", ModelID: "model-a", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: f.gguf, RuntimeStatus: "recommendable", AllowedRuntimeSources: "llamacpp_loopback,ollama_loopback"}},
		CandidateCatalogSHA256: f.catalog.SHA256, CatalogAdmissionMode: "current", CatalogReleaseID: f.catalog.Version,
		ReceiptPubkey: bytes.Repeat([]byte{9}, ed25519.PublicKeySize), SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1, LastHeartbeatAt: f.now, LastActivityAt: f.now}
	if _, ok, _ := s.pool.RegisterAtDetailed(entry, nil, f.now); !ok {
		t.Fatal("register")
	}
	s.withProviderSection("p1", func(section *providerSection) {
		s.refreshModelAdmissionBindingLocked(context.Background(), "p1", section)
	})
	provider, _ := s.pool.Resolve("p1", "")
	if provider.ModelAdmissionCandidateID != priced.CandidateID {
		t.Fatalf("session must be bound to the feed candidate: %q", provider.ModelAdmissionCandidateID)
	}
	s.withReleaseRead(func() {
		cur, comp := s.autotuneCatalogSnapshot()
		if _, _, ok := s.settlementSessionMemberLocked(priced, provider, cur, comp); ok {
			t.Fatal("a loopback-sourced GGUF member must not bind for settlement before the runtime path exists")
		}
	})
	// The feed goes stale (15 days): the feed path resolves nothing at match
	// time and the recorded feed member is catalog_match_stale at decision time.
	stale := f.now.Add(15 * 24 * time.Hour)
	s.now = func() time.Time { return stale }
	staleOffer := f.offer(t, "p1", "h", "ollama_loopback", map[string]string{modelidentity.GGUFFileV1: f.gguf})
	if staleOffer.CatalogMatchState != "unmatched" || staleOffer.CatalogMatchReason != "no_artifact_match" {
		t.Fatalf("stale feed must resolve nothing on the feed path: %+v", staleOffer)
	}
	s.withReleaseRead(func() {
		cur, _ := s.autotuneCatalogSnapshot()
		if eval := s.evaluateCatalogPreconditionsLocked(priced, cur); eval.decisionCode != "catalog_match_stale" || eval.driftReason != "catalog_artifact_feed_changed" {
			t.Fatalf("stale feed at decision time: %+v", eval)
		}
	})
}

// R008 / R006(a) "refresh": publication re-verifies every session BEFORE
// the sweep — a feed-member session whose own release's identity set is no
// longer retained loses hash_verified, its epoch advances (an in-flight
// route attempt fails closed) and the bound decided candidate is revoked
// with runtime_identity_drift.
func TestModelAdmissionPublicationRefreshesSessionsBeforeSweep(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerGGUFSession(t, "p1", "s1")
	feedOffer := f.offer(t, "p1", "g", "ollama_loopback", map[string]string{modelidentity.GGUFFileV1: f.gguf})
	priced := f.decide(t, feedOffer, "catalog_priced")
	before, _ := s.pool.Resolve("p1", "")
	if before.HashStatus != pool.HashStatusVerified || before.ModelAdmissionCandidateID != priced.CandidateID {
		t.Fatalf("fixture: %+v", before)
	}
	expect := ModelAdmissionRouteExpectation{ProviderID: "p1", CandidateID: priced.CandidateID, CoordinatorEventID: priced.CoordinatorEventID, BindingGeneration: before.ModelAdmissionBindingGeneration, SessionEpoch: before.ModelAdmissionSessionEpoch}
	// Re-stamp that keeps the content but drops release-1's identity set
	// (release-1 catalog is still retained as compatible-previous).
	restamped := bindingCatalog(t, "release-2", "recommendable", bindingRowHash)
	f.publish(restamped, map[string]*artifactidentity.Index{
		restamped.SHA256: bindingIndex(t, restamped, strings.Repeat("e", 64), f.now, bindingMembers(f.gguf, "")),
	}, f.catalog)
	after, _ := s.pool.Resolve("p1", "")
	if after.HashStatus == pool.HashStatusVerified || after.ModelAdmissionSessionEpoch == before.ModelAdmissionSessionEpoch {
		t.Fatalf("refresh must re-verify the session and advance its epoch: %+v", after)
	}
	if latest := f.latest(t, "p1", priced.CandidateID); latest.State != modelAdmissionRevoked || latest.ReasonCode != "runtime_identity_drift" {
		t.Fatalf("sweep after refresh must revoke the no-longer-verified session's candidate: %+v", latest)
	}
	inserted := 0
	if err := s.CompareAndInsertModelAdmissionRouteSnapshot(context.Background(), expect, func() error { inserted++; return nil }); !errors.Is(err, ErrModelAdmissionRouteStale) || inserted != 0 {
		t.Fatalf("in-flight attempt must fail closed: err=%v inserted=%d", err, inserted)
	}
}

// A heartbeat that changes only the served model id (same reported pair)
// advances the session epoch; the served feed bytes are committed after the
// internal release inside the same publication hold.
func TestModelAdmissionEpochOnModelIDChangeAndFeedCommitOrder(t *testing.T) {
	f := newBindingFixture(t)
	s := f.server
	f.registerSession(t, "p1", "s1", "model-a", true)
	before, _ := s.pool.Resolve("p1", "")
	result := s.pool.ApplyHeartbeatDetailed("p1", "s1", pool.HeartbeatUpdate{Status: pool.StateReady, ModelID: "model-b", ModelHash: bindingRowHash, ModelHashPresent: true,
		ModelHashAlgorithm: modelidentity.SnapshotManifestV1, ModelHashAlgorithmPresent: true, ExpectedModelHash: bindingRowHash,
		MaxContextTokens: 8192, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, At: f.now.Add(time.Minute)})
	if !result.OK || !result.ModelIDChanged || result.Provider.ModelAdmissionSessionEpoch == before.ModelAdmissionSessionEpoch {
		t.Fatalf("model-id-only change must advance the epoch: %+v", result.Provider)
	}
	next := bindingCatalog(t, "release-commit", "recommendable", bindingRowHash)
	s.SetAutotuneCatalog(next)
	generationBefore := s.ReleaseGeneration()
	committed := false
	s.PublishArtifactIdentitySetsWith(nil, false, func() {
		committed = true
		if s.artifactIdentitySets.gen != generationBefore+1 || s.autotuneCatalog != next {
			t.Fatal("feed bytes must be committed after the internal release inside the hold")
		}
	})
	if !committed {
		t.Fatal("commit must run")
	}
}
