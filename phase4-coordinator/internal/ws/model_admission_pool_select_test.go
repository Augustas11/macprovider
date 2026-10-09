package ws

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// offerRequesting appends an offer that names its pool entry the way the
// endpoint does (#1880 requested_pool_model_id).
func (f *bindingFixture) offerRequesting(t *testing.T, providerID, suffix, runtimeSource string, hashes map[string]string, requested string) ModelAdmissionEvent {
	t.Helper()
	event := ModelAdmissionEvent{
		ProviderID: providerID, CandidateID: "byom_" + strings.Repeat(suffix, 52), ServedModelRef: "ref-" + suffix,
		DiscoveryDigestSHA256: strings.Repeat("a", 64), EvaluationDigestSHA256: strings.Repeat("b", 64),
		RequestedDisclosureClass: "catalog_binding_requested", State: modelAdmissionOfferSubmitted, ReasonCode: "provider_offer_submitted",
		RequestID: "request_" + suffix, Nonce: "nonce_" + suffix, PayloadDigestSHA256: strings.Repeat(suffix, 64), SignatureDigestSHA256: strings.Repeat("d", 64), CreatedAt: f.now,
	}
	event = f.server.applyModelAdmissionOfferCatalogMatch(event, modelAdmissionOfferSubmitRequest{RuntimeSource: runtimeSource, ArtifactHashes: hashes, RequestedPoolModelID: requested})
	stored, replay, err := f.server.appendModelAdmissionEventInSection(context.Background(), providerID, func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		return f.server.modelAdmissions.AppendModelAdmissionOffer(ctx, event)
	})
	if err != nil || replay {
		t.Fatalf("offer %s: replay=%v err=%v", suffix, replay, err)
	}
	return stored
}

func twoPoolSource(f *bindingFixture) (*fakePoolModelSource, string) {
	source := wirePoolSource(f)
	source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
	other := ggufPoolEntry()
	other.PoolModelID = "pool/" + testPoolB + "/creator-gguf"
	source.set(poolSnapshot(testPoolB, 1, poolDigestV1, other))
	return source, other.PoolModelID
}

func statusWarnings(t *testing.T, f *bindingFixture, head ModelAdmissionEvent) []string {
	t.Helper()
	warnings, ok := f.server.modelAdmissionStatusResponseFromEvent(head, false)["warnings"].([]string)
	if !ok {
		t.Fatal("status warnings missing")
	}
	return warnings
}

// #1880: a member of two pools carrying the same artifact binds to the pool
// its offer names; without a name nothing binds and the status says
// pool_binding_ambiguous; a name that matches nothing says so too. The
// single-match bind is unchanged (TestPoolManifestBindAndSessionBinding).
func TestPoolManifestBindByRequestedPoolEntry(t *testing.T) {
	hashes := map[string]string{modelidentity.GGUFFileV1: poolGGUFHash}
	t.Run("named pool binds", func(t *testing.T) {
		f := newBindingFixture(t)
		_, poolBModel := twoPoolSource(f)
		f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
		offer := f.offerRequesting(t, poolProvider, "q", "llamacpp_loopback", hashes, poolBModel)
		f.reevaluate(poolProvider)
		head := f.latest(t, poolProvider, offer.CandidateID)
		if head.State != "catalog_priced" || !head.PoolScoped() || head.PoolID != testPoolB || head.PoolModelID != poolBModel ||
			head.Actor != PoolManifestActor(testPoolB, 1, poolDigestV1) {
			t.Fatalf("requested-pool bind = %+v", head)
		}
		if w := statusWarnings(t, f, head); len(w) != 0 {
			t.Fatalf("bound status warnings = %v", w)
		}
		provider, _ := f.server.pool.Resolve(poolProvider, "")
		if provider.ModelAdmissionPoolID != testPoolB || provider.ModelAdmissionPoolModelID != poolBModel {
			t.Fatalf("session binding = %+v", provider)
		}
	})
	t.Run("no name is ambiguous", func(t *testing.T) {
		f := newBindingFixture(t)
		twoPoolSource(f)
		f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
		offer := f.offerRequesting(t, poolProvider, "r", "llamacpp_loopback", hashes, "")
		f.reevaluate(poolProvider)
		head := f.latest(t, poolProvider, offer.CandidateID)
		if head.PoolScoped() {
			t.Fatalf("ambiguous offer bound: %+v", head)
		}
		if w := statusWarnings(t, f, head); len(w) != 1 || w[0] != ModelAdmissionWarningPoolBindingAmbiguous {
			t.Fatalf("ambiguous status warnings = %v", w)
		}
	})
	t.Run("named entry unmatched", func(t *testing.T) {
		f := newBindingFixture(t)
		twoPoolSource(f)
		f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
		offer := f.offerRequesting(t, poolProvider, "s", "llamacpp_loopback", hashes, "pool/"+testPoolA+"/other-slug")
		f.reevaluate(poolProvider)
		head := f.latest(t, poolProvider, offer.CandidateID)
		if head.PoolScoped() {
			t.Fatalf("unmatched named entry bound: %+v", head)
		}
		if w := statusWarnings(t, f, head); len(w) != 1 || w[0] != ModelAdmissionWarningPoolBindingRequestUnmatched {
			t.Fatalf("unmatched status warnings = %v", w)
		}
	})
	t.Run("single pool, no name, no warning", func(t *testing.T) {
		f := newBindingFixture(t)
		source := wirePoolSource(f)
		source.set(poolSnapshot(testPoolA, 1, poolDigestV1, ggufPoolEntry()))
		offer := f.offerRequesting(t, poolProvider, "u", "llamacpp_loopback", hashes, "")
		if w := statusWarnings(t, f, offer); len(w) != 0 {
			t.Fatalf("single-match warnings = %v", w)
		}
	})
}

// #1880: a session whose pair is an entry of two pools it belongs to is
// admitted pool-only (lowest pool id reported); the binding picks the pool.
func TestPoolEntryForSessionTwoPools(t *testing.T) {
	f := newBindingFixture(t)
	twoPoolSource(f)
	if poolID, ok := f.server.poolEntryForSession(poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash); !ok || poolID != testPoolB {
		t.Fatalf("two-pool session = %q %v, want %s", poolID, ok, testPoolB)
	}
}

// #1880: requested_pool_model_id is signed only when present (offers without
// it keep their canonical bytes), must be a pool model id, and persists.
func TestRequestedPoolModelIDWire(t *testing.T) {
	var body modelAdmissionOfferSubmitRequest
	if _, present := body.canonicalMap()["requested_pool_model_id"]; present {
		t.Fatal("absent requested_pool_model_id entered the signed preimage")
	}
	body.RequestedPoolModelID = poolModelGGUF
	if body.canonicalMap()["requested_pool_model_id"] != poolModelGGUF {
		t.Fatal("requested_pool_model_id not signed")
	}
	f := newBindingFixture(t)
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
	f.server.modelAdmissions = store
	_, poolBModel := twoPoolSource(f)
	f.registerPoolSession(t, poolProvider, "llamacpp_loopback", modelidentity.GGUFFileV1, poolGGUFHash)
	offer := f.offerRequesting(t, poolProvider, "v", "llamacpp_loopback", map[string]string{modelidentity.GGUFFileV1: poolGGUFHash}, poolBModel)
	if offer.RequestedPoolModelID != poolBModel {
		t.Fatalf("sqlite offer requested = %q", offer.RequestedPoolModelID)
	}
	f.reevaluate(poolProvider)
	head := f.latest(t, poolProvider, offer.CandidateID)
	if head.PoolID != testPoolB || head.RequestedPoolModelID != poolBModel {
		t.Fatalf("sqlite bound head = %+v", head)
	}
	repeat := offer
	if !modelAdmissionOfferRepeatsHead(head, repeat) {
		t.Fatal("identical requested offer is not a repeat of its bound head")
	}
	repeat.RequestedPoolModelID = ""
	if !modelAdmissionOfferRepeatsHead(head, repeat) {
		t.Fatal("unnamed re-offer is not a repeat of a bound head")
	}
	repeat.RequestedPoolModelID = poolModelGGUF
	if modelAdmissionOfferRepeatsHead(head, repeat) {
		t.Fatal("re-offer naming another pool repeats the bound head")
	}
}
