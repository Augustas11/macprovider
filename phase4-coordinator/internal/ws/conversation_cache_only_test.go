package ws

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

// SPEC-048-R009 (G7): the provider can tell a cache-only auto-prefix key from
// a sticky key only through this marker.
func TestConversationCacheOnlyContextFollowsItsKey(t *testing.T) {
	ctx := context.Background()
	if ConversationCacheOnlyFromContext(ctx) {
		t.Fatal("empty context marked cache-only")
	}
	sticky := ContextWithConversationKey(ctx, "conv:sticky")
	if ConversationCacheOnlyFromContext(sticky) {
		t.Fatal("sticky key marked cache-only")
	}
	cache := ContextWithConversationCacheOnlyKey(ctx, " conv:auto ")
	if got := ConversationKeyFromContext(cache); got != "conv:auto" {
		t.Fatalf("cache-only key = %q", got)
	}
	if !ConversationCacheOnlyFromContext(cache) {
		t.Fatal("auto-prefix key not marked cache-only")
	}
	if ConversationCacheOnlyFromContext(ContextWithConversationKey(cache, "conv:other")) {
		t.Fatal("marker survived a later sticky key")
	}
	if ConversationCacheOnlyFromContext(ContextWithConversationCacheOnlyKey(ctx, "  ")) {
		t.Fatal("blank key marked cache-only")
	}
}

func TestSealInferenceRequestCarriesConversationCacheOnly(t *testing.T) {
	provider := pool.Provider{ProviderID: "provider-a", AssignedID: "session-a"}
	clear := &providerSession{}
	for _, tc := range []struct {
		key       string
		cacheOnly bool
		want      bool
	}{
		{"conv:auto", true, true},
		{"conv:sticky", false, false},
		{"", true, false},
	} {
		raw, err := clear.sealInferenceRequestWithConversationCache(provider, "req-1", []byte(`{}`), false, nil, tc.key, tc.cacheOnly, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		var msg InferenceRequest
		if err := json.Unmarshal(raw, &msg); err != nil {
			t.Fatal(err)
		}
		if msg.ConversationCacheOnly != tc.want {
			t.Fatalf("key %q cacheOnly %v: wire marker %v", tc.key, tc.cacheOnly, msg.ConversationCacheOnly)
		}
		if !tc.want && bytes.Contains(raw, []byte(`"conversation_cache_only"`)) {
			t.Fatalf("false marker serialized: %s", raw)
		}
	}

	key := bytes.Repeat([]byte{0x11}, 32)
	nonce := []byte{1, 2, 3, 4}
	sealed := &providerSession{tier2: &pool.Tier2Session{
		C2PKey: key, P2CKey: key, C2PNonceBase: nonce, P2CNonceBase: nonce, KeyID: "kid-1",
	}}
	raw, err := sealed.sealInferenceRequestWithConversationCache(provider, "req-1", []byte(`{}`), false, nil, "conv:auto", true, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(`conversation_cache_only`)) {
		t.Fatal("marker leaked onto the outer encrypted request")
	}
	var outer encryptedInferenceRequest
	if err := json.Unmarshal(raw, &outer); err != nil {
		t.Fatal(err)
	}
	plain, err := tier2.OpenPillarBFrame(key, nonce, "kid-1", 0, tier2.AEADFrameAAD{
		Type: "inference_request", Direction: "c2p", RequestID: "req-1", Stream: false,
		ProviderID: provider.ProviderID, AssignedID: provider.AssignedID, Seq: 0,
	}, tier2.AEADEnvelope{Encrypted: true, Enc: outer.Enc})
	if err != nil {
		t.Fatal(err)
	}
	var decoded encryptedInferencePlaintext
	if err := json.Unmarshal(plain, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ConversationKey != "conv:auto" || !decoded.ConversationCacheOnly {
		t.Fatalf("sealed key %q cacheOnly %v", decoded.ConversationKey, decoded.ConversationCacheOnly)
	}
}
