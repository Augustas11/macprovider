package router

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"testing"
)

func TestVisionRegressionGatewayAccountingExcludesImageBytes(t *testing.T) {
	makeBody := func(payload string) []byte {
		return []byte(fmt.Sprintf(`{"model":"vision","messages":[{"role":"user","content":[{"type":"text","text":"first"},{"type":"image_url","image_url":{"url":"data:image/png;base64,%s"}},{"type":"text","text":"second"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,%s"}}]}]}`, payload, payload))
	}
	small := makeBody("AAAA")
	large := makeBody(strings.Repeat("A", 256*1024))
	original := bytes.Clone(large)
	projected, count := visionAccountingBody(large)
	if count != 2 || len(projected) > 512 || bytes.Contains(projected, []byte(strings.Repeat("A", 64))) {
		t.Fatalf("projection count=%d bytes=%d", count, len(projected))
	}
	if !bytes.Equal(original, large) {
		t.Fatal("accounting mutated the forwarded image body")
	}
	var decoded map[string]any
	if err := json.Unmarshal(projected, &decoded); err != nil {
		t.Fatal(err)
	}
	parts := decoded["messages"].([]any)[0].(map[string]any)["content"].([]any)
	if len(parts) != 4 || parts[0].(map[string]any)["text"] != "first" || parts[2].(map[string]any)["text"] != "second" {
		t.Fatal("accounting projection changed text/image order")
	}
	if estimatePromptTokens(small) != estimatePromptTokens(large) || promptCapTokens(small) != promptCapTokens(large) {
		t.Fatal("compressed image bytes changed token estimate")
	}
	if estimatePromptTokens(large) < 2*visionMediaTokenAllowance || promptCapTokens(large) < estimatePromptTokens(large)+promptHeadroomTokens {
		t.Fatal("visual allowance or reservation headroom missing")
	}
	text := []byte(" {\"model\":\"m\", \"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]} ")
	same, n := visionAccountingBody(text)
	if n != 0 || !bytes.Equal(same, text) || estimatePromptTokens(text) != int64(math.Ceil(float64(len(text))/4)) {
		t.Fatal("text accounting changed")
	}
	malformed := []byte(`{"messages":[{"role":"user","content":[{"type":"image_url","text":"must not vanish","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	same, n = visionAccountingBody(malformed)
	if n != 0 || !bytes.Equal(same, malformed) {
		t.Fatal("ambiguous part was granted image accounting")
	}
}

func TestVisionRegressionResponsesRejectMediaBeforeCoordinatorOrReservation(t *testing.T) {
	for name, content := range map[string]string{
		"image":        `[{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]`,
		"object":       `{"type":"input_image","image_url":"data:image/png;base64,AAAA"}`,
		"hidden":       `[{"type":"input_text","text":"question","image_url":{"url":"data:image/png;base64,AAAA"}}]`,
		"missing_type": `[{"text":"question"},{"image_url":{"url":"data:image/png;base64,AAAA"}}]`,
	} {
		t.Run(name, func(t *testing.T) {
			called := false
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				called = true
				return responseWithBody(http.StatusOK, nil, `{}`), nil
			})}
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, enableResponsesWithCoordinator, WithHTTPClient(client))
			account := "acct_vision_regression_" + name
			key := createAccountAndKey(t, store, cfg, account)
			body := fmt.Sprintf(`{"model":"vision","store":false,"input":[{"role":"user","content":%s}]}`, content)
			response := postResponses(t, h, key, body, nil)
			if response.Code != http.StatusBadRequest || called {
				t.Fatalf("status=%d coordinatorCalled=%v body=%s", response.Code, called, response.Body.String())
			}
			snapshot := gatewaySettlementSnapshot(t, dbPath, account)
			if snapshot.usageRows != 0 || snapshot.activeRows != 0 || snapshot.settledRows != 0 {
				t.Fatalf("unsupported media created settlement activity: %+v", snapshot)
			}
		})
	}
}
