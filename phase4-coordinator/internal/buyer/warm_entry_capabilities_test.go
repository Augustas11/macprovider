package buyer

import (
	"context"
	"fmt"
	"image/color"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// warmCapabilityProvider is single as a warm-set provider: primary model-a,
// and single's model, identity and declarations as a further member with
// single's seats and context.
func warmCapabilityProvider(single pool.Provider) pool.Provider {
	p := single
	p.ProviderID, p.AssignedID = "warm", "s-warm"
	p.EndpointURL = "https://warm.example"
	p.ModelID, p.ModelHash, p.ModelHashAlgorithm, p.WeightsManifestSHA256 = "model-a", "h-model-a", "", ""
	p.HashStatus = pool.HashStatusVerified
	p.ToolSelectionCapabilities, p.VisionRuntimeCapabilities = nil, nil
	p.SupportedModels = []string{"model-a", single.ModelID}
	// A further member reports a hash, so it verifies (verifyWarmHashes) and
	// the session is multi-model.
	memberHash := single.ModelHash
	if memberHash == "" {
		memberHash = "h-" + single.ModelID
	}
	p.WarmModels = []pool.WarmModel{
		{ModelID: "model-a", State: pool.WarmModelWarm, Primary: true, Pinned: true, SlotsTotal: p.SlotsTotal, SlotsFree: p.SlotsFree, MaxContextTokens: p.MaxContextTokens},
		{
			ModelID: single.ModelID, State: pool.WarmModelWarm, SlotsTotal: single.SlotsTotal, SlotsFree: single.SlotsFree,
			MaxContextTokens: single.MaxContextTokens, ModelHash: memberHash, ModelHashAlgorithm: single.ModelHashAlgorithm,
			WeightsManifestSHA256: single.WeightsManifestSHA256, ToolSelectionCapabilities: single.ToolSelectionCapabilities,
			VisionRuntimeCapabilities: single.VisionRuntimeCapabilities,
		},
	}
	return p
}

// sameRouteError is the refusal a buyer sees.
func sameRouteError(a, b *routeError) bool {
	return a != nil && b != nil && a.status == b.status && a.code == b.code && a.message == b.message
}

// SPEC-002-R011: a tool request for a warm member's model routes to a member
// that declares the model's tool grammar, and a member that does not is
// refused with exactly the error a single-model provider of that model gets.
func TestWarmEntryToolRequestFollowsTheMembersDeclaration(t *testing.T) {
	const model = "mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp"
	single := func(modes ...string) pool.Provider {
		p := poolProvider("single")
		p.ModelID = model
		p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{ModelID: model, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: modes}}
		return p
	}
	plain := chatRequest{Model: model, raw: []byte(`{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`)}
	tools := plain
	tools.multiTurnToolHistory, tools.declaresTools = true, true
	route := func(req chatRequest, providers ...pool.Provider) (pool.Provider, *routeError) {
		s, registry, _ := poolIsolationServer(t)
		verifyWarmHashes(registry)
		for i := range providers {
			registry.Register(&providers[i], nil)
		}
		return s.selectProviderExcluding(context.Background(), "rid", req, http.Header{}, nil, "2024-01-01", &forwardState{})
	}
	// The pool a warm provider of model-a and the member's model is: one
	// single-model provider of each.
	primaryOnly := poolProvider("primary-only")

	capable := warmCapabilityProvider(single("auto", "none", "required", "named"))
	for name, req := range map[string]chatRequest{"tools": tools, "plain": plain} {
		got, routeErr := route(req, capable)
		if routeErr != nil || got.ProviderID != "warm" || got.ServedModelID != model {
			t.Fatalf("%s request to a declaring member: provider %q served %q err %+v", name, got.ProviderID, got.ServedModelID, routeErr)
		}
	}

	for name, req := range map[string]chatRequest{"tools": tools, "plain": plain} {
		_, singleErr := route(req, single("auto", "none"), primaryOnly)
		_, memberErr := route(req, warmCapabilityProvider(single("auto", "none")))
		if singleErr == nil || !sameRouteError(singleErr, memberErr) {
			t.Fatalf("%s request: member refusal %+v, single-model refusal %+v", name, memberErr, singleErr)
		}
	}
	// Alone in the pool, the single-model provider's refusal is the grammar
	// code.
	if _, singleErr := route(plain, single("auto", "none")); singleErr == nil || singleErr.code != "tool_grammar_provider_unavailable" {
		t.Fatalf("single-model refusal %+v", singleErr)
	}
}

// SPEC-002-R011: an image request routes to a warm member whose own vision
// declaration matches the operator qualification for that member's model,
// seats and context, and a member without one is refused with exactly the
// error a single-model provider of that model gets.
func TestWarmEntryVisionRequestFollowsTheMembersDeclaration(t *testing.T) {
	url := visionRegressionImage(t, color.RGBA{R: 255, A: 255})
	req := visionRegressionRequest(t, visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q}}]`, url)))
	single, q := visionRegressionProvider()
	route := func(providers ...pool.Provider) (pool.Provider, *routeError) {
		registry := pool.NewRegistry(nil)
		verifyWarmHashes(registry)
		for i := range providers {
			registry.Register(&providers[i], nil)
		}
		server := NewServer(registry, zerolog.Nop(), time.Now().UTC())
		qualification := q
		qualification.ProviderID = providers[0].ProviderID
		server.visionQualifications = []config.VisionQualificationConfig{qualification}
		return server.selectProviderExcluding(context.Background(), "rid", req, http.Header{}, nil, "2026-01-01", &forwardState{})
	}

	got, routeErr := route(warmCapabilityProvider(single))
	if routeErr != nil || got.ProviderID != "warm" || got.ServedModelID != visionModelID {
		t.Fatalf("image request to a qualified member: provider %q served %q err %+v", got.ProviderID, got.ServedModelID, routeErr)
	}

	bare := single
	bare.VisionRuntimeCapabilities = nil
	_, singleErr := route(bare, versionFloorProvider("primary-only", "model-a", single.BinaryVersion))
	_, memberErr := route(warmCapabilityProvider(bare))
	if singleErr == nil || !sameRouteError(singleErr, memberErr) {
		t.Fatalf("member refusal %+v, single-model refusal %+v", memberErr, singleErr)
	}
}
