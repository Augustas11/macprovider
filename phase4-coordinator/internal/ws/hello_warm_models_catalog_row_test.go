package ws_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-002-R011: a v1 hello whose warm set names one catalog row twice, as
// the row's model_id and as its row key, takes the bad-warm_models path: the
// warm set is dropped with one structured warning and the session proceeds
// single-model on the hello's model. A hello declares no supported_models, so
// its decode already drops any second member; the same-row check behind it
// is a second guard on the same path.
func TestHelloWarmModelsNamingOneCatalogRowTwiceDropped(t *testing.T) {
	logs := &lockedBuffer{}
	h := newProviderHarnessWithOptionsAndLogger(t, nil, nil, zerolog.New(logs))
	defer h.HTTP.Close()
	catalog, err := autotune.ParseCatalog([]byte(`{"version":"hello-alias","source":"operator_curated_autotune_candidate_catalog","rows":{"public-qwen":{"model_id":"mlx-community/Qwen2.5-7B-Instruct-4bit"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	h.Provider.SetAutotuneCatalog(catalog)
	if got := h.Registry.SanctionKey("public-qwen"); got != "mlx-community/qwen2.5-7b-instruct-4bit" {
		t.Fatalf("setup: row key resolves to %q", got)
	}

	conn, _, _, err := gobwas.Dial(context.Background(), wsURL(h.HTTP.URL))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	hello := validHello("m4-anon")
	hello["warm_models"] = []any{
		warmModelsPrimaryEntry(),
		map[string]any{"model_id": "public-qwen", "state": "warm", "primary": false, "pinned": false, "slots_total": 1, "slots_free": 1},
	}
	if err := wsutil.WriteClientText(conn, mustJSON(hello)); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read ack: %v", err)
	}
	var ack providerws.HelloAck
	if err := json.Unmarshal(payload, &ack); err != nil || ack.Type != "hello_ack" || ack.AssignedID == "" {
		t.Fatalf("ack = %s err=%v", payload, err)
	}
	p, ok := h.Registry.Resolve("m4-anon", ack.AssignedID)
	if !ok || p.WarmModels != nil || p.ModelID != "mlx-community/Qwen2.5-7B-Instruct-4bit" {
		t.Fatalf("session = model %q warm %+v ok=%v, want single-model without a warm set", p.ModelID, p.WarmModels, ok)
	}
	if got := strings.Count(logs.String(), `"event":"handshake_warm_models_dropped"`); got != 1 {
		t.Fatalf("handshake_warm_models_dropped logged %d times, want 1: %s", got, logs.String())
	}
}
