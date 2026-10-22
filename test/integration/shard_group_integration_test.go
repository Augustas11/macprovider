package integration

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// SPEC-051-R016 across the real coordinator and gateway: a provider session
// that advertised shard_member_v1 on the v2 auth flow is admitted and ready
// but never receives buyer traffic; every request goes to the ordinary
// provider.
func TestShardMemberSessionNeverServesBuyerTraffic(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:            true,
		providerCount:          2,
		receiptEnabledProvider: true,
		coordinatorConfig: func(_ *scenario, cfg map[string]any) {
			cfg["routing"].(map[string]any)["tiebreak_randomize"] = true
		},
		providerSetup: func(fp *fakeProvider) {
			if strings.HasSuffix(fp.providerID, "-1") {
				fp.shardMemberV1 = true
			}
		},
	})
	if len(s.fakeProvs) != 2 {
		t.Fatalf("want 2 fake providers, got %d", len(s.fakeProvs))
	}
	var member, plain *fakeProvider
	for _, fp := range s.fakeProvs {
		if fp.shardMemberV1 {
			member = fp
		} else {
			plain = fp
		}
	}
	if member == nil || plain == nil {
		t.Fatal("scenario did not create one member and one plain provider")
	}
	body := `{"model":"llama-3.2-3b-instruct","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`
	for i := 0; i < 12; i++ {
		status, _, respBody := s.chatRequest(map[string]string{"X-Request-ID": fmt.Sprintf("51515151-5151-4515-8515-%012d", i)}, body)
		if status != http.StatusOK {
			t.Fatalf("chat %d status=%d body=%s", i, status, respBody)
		}
	}
	if member.Hits() != 0 {
		t.Fatalf("member session served %d requests", member.Hits())
	}
	if plain.Hits() < 12 {
		t.Fatalf("plain provider served %d of 12 requests", plain.Hits())
	}
}
