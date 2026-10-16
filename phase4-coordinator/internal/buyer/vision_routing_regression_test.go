package buyer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func visionRegressionImage(t *testing.T, c color.RGBA) string {
	t.Helper()
	im := image.NewRGBA(image.Rect(0, 0, 1, 1))
	im.SetRGBA(0, 0, c)
	var data bytes.Buffer
	if err := png.Encode(&data, im); err != nil {
		t.Fatal(err)
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(data.Bytes())
}

func visionRegressionBody(model, content string) []byte {
	return []byte(fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"user","content":%s}]}`, model, content))
}

func visionRegressionRequest(t *testing.T, body []byte) chatRequest {
	t.Helper()
	req, status, code, message, _ := validateChatRequestDetailed(body)
	if status != 0 {
		t.Fatalf("validate status=%d code=%s message=%s", status, code, message)
	}
	return req
}

func TestVisionRegressionNormalizationAndReceiptPreserveImageMeaning(t *testing.T) {
	red := visionRegressionImage(t, color.RGBA{R: 255, A: 255})
	blue := visionRegressionImage(t, color.RGBA{B: 255, A: 255})
	body := []byte(fmt.Sprintf(`{"model":%q,"max_tokens":32,"messages":[{"role":"system","content":[{"type":"text","text":"describe "},{"type":"text","text":"precisely"}]},{"role":"user","content":[{"type":"text","text":"prior "},{"type":"text","text":"turn"}]},{"role":"assistant","content":"Ready"},{"role":"user","content":[{"type":"text","text":"first"},{"type":"image_url","image_url":{"url":%q}},{"type":"text","text":"second"},{"type":"image_url","image_url":{"url":%q}}]}]}`, visionModelID, red, blue))
	req := visionRegressionRequest(t, body)
	if !req.hasVision || !bytes.Equal(req.raw, body) {
		t.Fatal("media admission changed ordered parts or other text-array messages")
	}
	before, err := coordinatorPromptHash(body)
	if err != nil {
		t.Fatal(err)
	}
	after, err := coordinatorPromptHash(req.raw)
	if err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Fatal("normalization changed receipt-bound prompt")
	}
	changed := bytes.Replace(body, []byte(red), []byte(blue), 1)
	swapped := bytes.ReplaceAll(bytes.ReplaceAll(bytes.ReplaceAll(body, []byte(red), []byte("swap-placeholder")), []byte(blue), []byte(red)), []byte("swap-placeholder"), []byte(blue))
	for name, variant := range map[string][]byte{"image": changed, "order": swapped} {
		digest, err := coordinatorPromptHash(visionRegressionRequest(t, variant).raw)
		if err != nil {
			t.Fatal(err)
		}
		if digest == before {
			t.Fatalf("receipt failed to bind changed %s", name)
		}
	}
	imageOnly := visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q}}]`, red))
	if !visionRegressionRequest(t, imageOnly).hasVision {
		t.Fatal("image-only user turn lost media capability")
	}
	text := visionRegressionRequest(t, visionRegressionBody("text-model", `[{"type":"text","text":"first"},{"type":"text","text":"second"}]`))
	if text.hasVision || string(text.Messages[0].Content) != `"firstsecond"` {
		t.Fatal("legacy text-array normalization changed")
	}
}

func TestVisionRegressionAmbiguousShapesRejectBeforeRouting(t *testing.T) {
	url := visionRegressionImage(t, color.RGBA{R: 255, A: 255})
	imagePart := fmt.Sprintf(`{"type":"image_url","image_url":{"url":%q}}`, url)
	cases := map[string][]byte{
		"hidden_image":      visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"text","text":"question","image_url":{"url":%q}}]`, url)),
		"hidden_text":       visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q},"text":"lost"}]`, url)),
		"nested_unknown":    visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q,"text":"lost"}}]`, url)),
		"duplicate_url":     visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q,"url":%q}}]`, url, url)),
		"duplicate_content": []byte(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":[%s],"content":"hidden"}]}`, visionModelID, imagePart)),
		"duplicate_type":    visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","type":"text","image_url":{"url":%q},"text":"hidden"}]`, url)),
		"remote":            visionRegressionBody(visionModelID, `[{"type":"image_url","image_url":{"url":"http://127.0.0.1/private"}}]`),
	}
	for _, role := range []string{"system", "assistant", "tool", "User"} {
		cases[role] = []byte(fmt.Sprintf(`{"model":%q,"messages":[{"role":%q,"content":[%s]}]}`, visionModelID, role, imagePart))
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			_, status, _, _, _ := validateChatRequestDetailed(body)
			if status != http.StatusBadRequest {
				t.Fatalf("status=%d want400", status)
			}
		})
	}
}

func TestVisionRegressionUnsupportedModelAndToolsRejectBeforeDispatch(t *testing.T) {
	url := visionRegressionImage(t, color.RGBA{R: 255, A: 255})
	content := fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q}}]`, url)
	for name, body := range map[string][]byte{
		"model": visionRegressionBody("text-only-model", content),
		"tools": []byte(strings.TrimSuffix(string(visionRegressionBody(visionModelID, content)), "}") + `,"tools":` + toolSelectionTools + `}`),
	} {
		t.Run(name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			provider, _ := visionRegressionProvider()
			provider.VisionRuntimeCapabilities = nil
			registry.Register(&provider, nil)
			server := NewServer(registry, zerolog.Nop(), time.Now().UTC())
			rr := httptest.NewRecorder()
			server.handleChatCompletions(rr, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body)))
			if rr.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			var response struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response.Error.Code != "unsupported_media" && response.Error.Code != "unsupported_content_shape" {
				t.Fatalf("unexpected rejection %q", response.Error.Code)
			}
		})
	}
}

func visionRegressionProvider() (pool.Provider, config.VisionQualificationConfig) {
	p := versionFloorProvider("vision-regression", visionModelID, "999.0.0")
	p.RuntimeSource = engineClassNative
	p.RAMGB = 64
	p.HardwareCapacity = &pool.ProviderHardwareCapacity{Chip: "test-chip"}
	p.ModelHash = "model-hash"
	p.ModelHashAlgorithm = "sha256"
	p.WeightsManifestSHA256 = "weights"
	q := config.VisionQualificationConfig{ProviderID: p.ProviderID, BinaryVersion: p.BinaryVersion, RAMGB: p.RAMGB, MaxContextTokens: p.MaxContextTokens, MaxConcurrency: p.MaxConcurrency, ModelID: p.ModelID, ModelHash: p.ModelHash, ModelHashAlgorithm: p.ModelHashAlgorithm, WeightsManifestSHA256: p.WeightsManifestSHA256, ProcessorDigest: "processor", Runtime: engineClassNative, RuntimeRevision: "revision", MediaProfile: visionMediaProfile, QualificationDigest: "evidence"}
	q.HardwareChip = p.HardwareCapacity.Chip
	p.VisionRuntimeCapabilities = []pool.VisionRuntimeCapability{{ModelID: q.ModelID, ModelHash: q.ModelHash, ModelHashAlgorithm: q.ModelHashAlgorithm, WeightsManifestSHA256: q.WeightsManifestSHA256, ProcessorDigest: q.ProcessorDigest, Runtime: q.Runtime, RuntimeRevision: q.RuntimeRevision, MediaProfile: q.MediaProfile}}
	return p, q
}

func TestVisionRegressionDispatchRechecksWithdrawalAndReconnect(t *testing.T) {
	url := visionRegressionImage(t, color.RGBA{R: 255, A: 255})
	req := visionRegressionRequest(t, visionRegressionBody(visionModelID, fmt.Sprintf(`[{"type":"image_url","image_url":{"url":%q}}]`, url)))
	for _, scenario := range []string{"withdrawal", "replacement", "reconnect"} {
		t.Run(scenario, func(t *testing.T) {
			p, q := visionRegressionProvider()
			registry := pool.NewRegistry(nil)
			registry.Register(&p, nil)
			server := NewServer(registry, zerolog.Nop(), time.Now().UTC())
			server.visionQualifications = []config.VisionQualificationConfig{q}
			if body, err := server.dispatchBodyForProviderChecked(req, p); err != nil || !bytes.Equal(body, req.raw) {
				t.Fatalf("qualified dispatch err=%v", err)
			}
			changed := p
			switch scenario {
			case "withdrawal":
				changed.VisionRuntimeCapabilities = nil
			case "replacement":
				changed.ModelHash = "different"
			case "reconnect":
				changed.AssignedID = "replacement-session"
				changed.VisionRuntimeCapabilities = nil
			}
			if _, registered := registry.Register(&changed, nil); !registered {
				t.Fatal("replacement registration refused")
			}
			if _, err := server.dispatchBodyForProviderChecked(req, p); err == nil {
				t.Fatal("stale selected tuple dispatched after capability changed")
			}
			waiter, ok := server.slotQueue.enter(p.ProviderID)
			if !ok {
				t.Fatal("queue entry refused")
			}
			defer server.slotQueue.leave(waiter)
			if _, status := server.pollQueuedProvider(waiter, p.ModelID, nil, 100, &forwardState{hasVision: true}); status != queuedProviderTerminal {
				t.Fatalf("queue status=%v", status)
			}
			for _, header := range []string{"", "X-MacProvider-Provider", "X-MacProvider-Session"} {
				h := http.Header{}
				if header != "" {
					value := changed.ProviderID
					if header == "X-MacProvider-Session" {
						value = changed.AssignedID
					}
					h.Set(header, value)
				}
				if _, err := server.selectProviderExcluding(context.Background(), "vision-reject", req, h, nil, "2026-01-01", &forwardState{}); err == nil {
					t.Fatalf("incompatible capacity selected with header %s", header)
				}
			}
		})
	}
}
