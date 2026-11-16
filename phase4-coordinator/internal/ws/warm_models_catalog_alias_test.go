package ws_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-002-R011: an auth_request whose warm member names the primary's
// catalog row under the row's other name (and whose supported_models lists
// both names) is malformed: the warm set is dropped with one structured
// warning and the session authenticates as legacy under the model it sent.
func TestAuthV2WarmMemberNamingPrimaryCatalogRowProceedsAsLegacy(t *testing.T) {
	modelID := heartbeat()["model_id"].(string)
	catalog, err := autotune.ParseCatalog([]byte(`{"version":"alias-test","source":"operator_curated_autotune_candidate_catalog","rows":{"public-qwen":{"model_id":"` + modelID + `"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	logs := &lockedBuffer{}
	h := newProviderHarnessWithOptionsAndLogger(t, nil, []providerws.Option{providerws.WithAutotuneCatalog(catalog)}, zerolog.New(logs), func(cfg *config.Config) {
		cfg.Providers[0].EndpointURL = ""
	})
	defer h.HTTP.Close()
	conn, assignedID := dialAndAuthV2ProviderWithInitial(t, h, func(initial map[string]any) {
		initial["supported_models"] = []any{modelID, "public-qwen"}
		initial["warm_models"] = []any{warmModelsPrimaryEntry(), map[string]any{"model_id": "public-qwen", "state": "warm", "primary": false, "pinned": false, "slots_total": 1, "slots_free": 1}}
	})
	defer conn.Close()
	p, ok := h.Registry.Resolve("m4-anon", assignedID)
	if !ok || p.WarmModels != nil || p.ModelID != modelID {
		t.Fatalf("alias warm set kept: model=%s warm=%+v ok=%v", p.ModelID, p.WarmModels, ok)
	}
	if got := strings.Count(logs.String(), `"event":"handshake_warm_models_dropped"`); got != 1 || !strings.Contains(logs.String(), "names the same catalog model") {
		t.Fatalf("handshake_warm_models_dropped logged %d times: %s", got, logs.String())
	}
	if got := h.Registry.SanctionKey("public-qwen"); got != strings.ToLower(modelID) {
		t.Fatalf("row key sanction key = %q", got)
	}
}
