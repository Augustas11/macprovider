package ws

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// aliasCatalog is a signed-catalog shape whose rows map row key to model_id,
// so each row is reachable under both names.
func aliasCatalog(t *testing.T, rows map[string]string) *autotune.Catalog {
	t.Helper()
	parts := make([]string, 0, len(rows))
	for key, modelID := range rows {
		parts = append(parts, `"`+key+`":{"model_id":"`+modelID+`"}`)
	}
	catalog, err := autotune.ParseCatalog([]byte(`{"version":"alias-test","source":"operator_curated_autotune_candidate_catalog","rows":{` + strings.Join(parts, ",") + `}}`))
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func installAliasCatalog(s *Server, current *autotune.Catalog, compatible map[string]*autotune.Catalog) {
	s.autotuneCatalogMu.Lock()
	defer s.autotuneCatalogMu.Unlock()
	s.autotuneCatalog = current
	s.autotuneCompatibleCatalogs = compatible
}

// The registry's sanction resolver is wired by NewServer: both names of a
// row resolve to the row's model_id, a retained compatible release resolves
// its own rows, and an id no row carries falls back to its ModelKey.
func TestCatalogSanctionIdentityResolvesEveryRowName(t *testing.T) {
	server, registry, _, _ := warmHeartbeatServer(t)
	previous := aliasCatalog(t, map[string]string{"old-public": "org/old-model"})
	installAliasCatalog(server, aliasCatalog(t, map[string]string{"public-ci": "model-ci"}), map[string]*autotune.Catalog{"prev": previous})
	for name, want := range map[string]string{
		"public-ci":     "model-ci",
		"Model-CI":      "model-ci",
		"old-public":    "org/old-model",
		"org/old-model": "org/old-model",
		"BYOM/Local":    "byom/local",
	} {
		if got := registry.SanctionKey(name); got != want {
			t.Fatalf("SanctionKey(%q) = %q, want %q", name, got, want)
		}
	}
}

// SPEC-036 FR-20/FR-25: a provider that switches its model id from the
// row's model_id to its row key (and back) keeps one scoring key, its due
// time and its suspension.
func TestComputeScoringCatalogAliasKeepsKeyDueAndSuspension(t *testing.T) {
	h, respell := newFoldingScoringHarness(t)
	installAliasCatalog(h.server, aliasCatalog(t, map[string]string{"public-ci": scoringModel}), nil)
	h.engine.sweep(context.Background(), h.now())
	key := computeScoringKey{"a", scoringModel}
	h.engine.mu.Lock()
	due, ok := h.engine.nextDue[key]
	h.engine.mu.Unlock()
	if !ok {
		t.Fatal("setup: key a not scheduled")
	}
	h.registry.SetComputeIntegritySuspended("a", scoringModel, true)
	for i, name := range []string{"public-ci", "PUBLIC-CI", scoringModel, "public-ci"} {
		respell(name)
		h.advance(time.Minute)
		h.engine.sweep(context.Background(), h.now())
		if keys := h.keysOf("a"); len(keys) != 1 {
			t.Fatalf("name %d (%s): keys %v, want one", i, name, keys)
		}
		h.engine.mu.Lock()
		got := h.engine.nextDue[key]
		h.engine.mu.Unlock()
		if !got.Equal(due) {
			t.Fatalf("name %s moved the due time %v -> %v", name, due, got)
		}
		if p, _ := h.registry.Resolve("a", "as-a"); !p.ComputeIntegritySuspended || p.RoutingEligible() {
			t.Fatalf("name %s escaped the suspension", name)
		}
	}
	// A scorer serving the row under its other name is in the same pool.
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	if c := h.engine.candidate(pool.Provider{ProviderID: "a", ModelID: "public-ci"}); c.ModelKey != scoringModel {
		t.Fatalf("scorer cohort key = %q, want %q", c.ModelKey, scoringModel)
	}
}

// A state stored under the row key before this rule restores onto the row's
// one key, and an adverse state still wins.
func TestComputeScoringRestoreFoldsCatalogAliases(t *testing.T) {
	h, _ := newFoldingScoringHarness(t)
	installAliasCatalog(h.server, aliasCatalog(t, map[string]string{"public-ci": scoringModel}), nil)
	ctx := context.Background()
	now := h.now()
	failed := computeintegrity.NewKeyState("a", "public-ci", now)
	failed.State = computeintegrity.VerificationFailed
	failed.FailedAt = now
	if err := h.engine.deps.Store.UpsertKeyState(ctx, failed, now); err != nil {
		t.Fatal(err)
	}
	if err := h.engine.deps.Store.UpsertKeyState(ctx, computeintegrity.NewKeyState("a", scoringModel, now), now); err != nil {
		t.Fatal(err)
	}
	e := h.restartScoring()
	e.mu.Lock()
	st := e.states[computeScoringKey{"a", scoringModel}]
	e.mu.Unlock()
	if st == nil || st.State != computeintegrity.VerificationFailed {
		t.Fatalf("restored state = %+v, want the failed row-key row", st)
	}
	if p, _ := h.registry.Resolve("a", "as-a"); !p.ComputeIntegritySuspended {
		t.Fatal("restored failure under the row key does not suspend the model_id session")
	}
}

// SPEC-002-R011: one catalog row is one member. A heartbeat warm set with two
// entries naming one row, or a session whose supported_models names one row
// twice, takes the bad-warm_models path: the previous set stays and the rest
// of the heartbeat applies.
func TestHeartbeatWarmModelsNamingOneCatalogRowTwiceRejected(t *testing.T) {
	for name, tc := range map[string]struct {
		mutate func(map[string]any)
		reason string
	}{
		"member and member": {func(map[string]any) {}, "names the same catalog model"},
		"supported_models": {func(p map[string]any) {
			p["warm_models"] = p["warm_models"].([]any)[:2]
		}, "supported_models names one catalog model twice"},
	} {
		server, registry, logs, at := warmHeartbeatServer(t)
		// model-c is another name (row key) of the row whose model_id is
		// model-b.
		installAliasCatalog(server, aliasCatalog(t, map[string]string{"model-c": "model-b"}), nil)
		payload := warmModelsHeartbeat()
		tc.mutate(payload)
		server.handleHeartbeat(nil, "p1", "s1", heartbeatPayload(t, payload))
		session, _ := registry.Resolve("p1", "s1")
		if !session.LastHeartbeatAt.After(at) || session.SlotsFree != 3 {
			t.Fatalf("%s: heartbeat not applied", name)
		}
		if len(session.WarmModels) != 2 || session.WarmModels[1].ModelID != "model-b" {
			t.Fatalf("%s: previous warm set not kept: %+v", name, session.WarmModels)
		}
		if !strings.Contains(logs.String(), `"event":"heartbeat_warm_models_rejected"`) || !strings.Contains(logs.String(), tc.reason) {
			t.Fatalf("%s: logs = %s", name, logs.String())
		}
	}
}

// Primary and member naming one row through its two names is rejected; a
// warm set of one is never affected, whatever supported_models declares; ids
// no row carries keep today's rule.
func TestWarmModelsSameCatalogRow(t *testing.T) {
	server, _, _, _ := warmHeartbeatServer(t)
	installAliasCatalog(server, aliasCatalog(t, map[string]string{"public-a": "model-a"}), nil)
	primary := pool.WarmModel{ModelID: "model-a", Primary: true}
	if err := server.warmModelsSameCatalogRow([]pool.WarmModel{primary, {ModelID: "public-a"}}, nil); err == nil {
		t.Fatal("member naming the primary's row accepted")
	}
	if err := server.warmModelsSameCatalogRow([]pool.WarmModel{primary}, []string{"model-a", "public-a"}); err != nil {
		t.Fatalf("warm set of one rejected: %v", err)
	}
	if err := server.warmModelsSameCatalogRow(nil, []string{"model-a", "public-a"}); err != nil {
		t.Fatalf("no warm set rejected: %v", err)
	}
	if err := server.warmModelsSameCatalogRow([]pool.WarmModel{{ModelID: "byom-x", Primary: true}, {ModelID: "byom-y"}}, []string{"byom-x", "byom-y"}); err != nil {
		t.Fatalf("distinct uncatalogued ids rejected: %v", err)
	}
}

// A legacy single-model session reporting either name of its row is
// accepted unchanged: the heartbeat applies with the name it sent.
func TestLegacySessionUnderEitherCatalogNameUnchanged(t *testing.T) {
	for _, name := range []string{"model-a", "public-a"} {
		server, registry, logs, _ := warmHeartbeatServer(t)
		installAliasCatalog(server, aliasCatalog(t, map[string]string{"public-a": "model-a"}), nil)
		payload := warmModelsHeartbeat()
		delete(payload, "warm_models")
		payload["model_id"] = name
		server.handleHeartbeat(nil, "p1", "s1", heartbeatPayload(t, payload))
		session, _ := registry.Resolve("p1", "s1")
		if session.ModelID != name || session.WarmModels != nil || session.SlotsFree != 3 {
			t.Fatalf("%s: model=%s warm=%+v slots_free=%d", name, session.ModelID, session.WarmModels, session.SlotsFree)
		}
		if strings.Contains(logs.String(), "warm_models_rejected") {
			t.Fatalf("%s: rejected: %s", name, logs.String())
		}
		if registry.SanctionKey(session.ModelID) != "model-a" {
			t.Fatalf("%s: sanction key %q", name, registry.SanctionKey(session.ModelID))
		}
	}
}
