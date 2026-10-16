package buyer

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLtiAAAAABJRU5ErkJggg=="

func TestValidateVisionContentPreservesImageOnlyAndMixedOrder(t *testing.T) {
	content := fmt.Sprintf(`[{"type":"text","text":"first"},{"type":"image_url","image_url":{"url":"data:image/png;base64,%s","detail":"auto"}},{"type":"text","text":"last"}]`, onePixelPNG)
	hasVision, status, code, message := validateVisionContent([]chatMessage{{Role: "user", Content: []byte(content)}})
	if !hasVision || status != 0 || code != "" || message != "" {
		t.Fatalf("mixed input = (%v,%d,%q,%q), want accepted vision", hasVision, status, code, message)
	}
	imageOnly := fmt.Sprintf(`[{"type":"image_url","image_url":{"url":"data:image/png;base64,%s"}}]`, onePixelPNG)
	hasVision, status, code, message = validateVisionContent([]chatMessage{{Role: "user", Content: []byte(imageOnly)}})
	if !hasVision || status != 0 || code != "" || message != "" {
		t.Fatalf("image-only input = (%v,%d,%q,%q), want accepted vision", hasVision, status, code, message)
	}
}

func TestValidateVisionContentRejectsNonCanonicalAndDuplicateMedia(t *testing.T) {
	for _, content := range []string{
		`[{"type":"image_url","image_url":{"url":"https://example.invalid/a.png"}}]`,
		fmt.Sprintf(`[{"type":"image_url","image_url":{"url":"data:image/png;base64,%s\n"}}]`, onePixelPNG),
		fmt.Sprintf(`[{"type":"image_url","image_url":{"url":"data:image/png;base64,%s","url":"data:image/png;base64,%s"}}]`, onePixelPNG, onePixelPNG),
	} {
		if _, status, _, _ := validateVisionContent([]chatMessage{{Role: "user", Content: []byte(content)}}); status == 0 {
			t.Fatalf("content unexpectedly accepted: %s", content)
		}
	}
}

func TestProviderSupportsVisionRequiresEntireQualifiedTuple(t *testing.T) {
	q := config.VisionQualificationConfig{
		ProviderID: "provider-1", BinaryVersion: "1.2.3", HardwareChip: "Apple M2 Ultra", RAMGB: 64, MaxContextTokens: 32768, MaxConcurrency: 1,
		ModelID: visionModelID, ModelHash: "model-hash", ModelHashAlgorithm: "sha256", WeightsManifestSHA256: "weights",
		ProcessorDigest: "processor", Runtime: engineClassNative, RuntimeRevision: "runtime-revision", MediaProfile: visionMediaProfile, QualificationDigest: "evidence",
	}
	p := pool.Provider{
		ProviderID: q.ProviderID, BinaryVersion: q.BinaryVersion, RAMGB: q.RAMGB, MaxContextTokens: q.MaxContextTokens, MaxConcurrency: q.MaxConcurrency,
		ModelID: q.ModelID, ModelHash: q.ModelHash, ModelHashAlgorithm: q.ModelHashAlgorithm, WeightsManifestSHA256: q.WeightsManifestSHA256, RuntimeSource: engineClassNative, HardwareCapacity: &pool.ProviderHardwareCapacity{Chip: q.HardwareChip},
		VisionRuntimeCapabilities: []pool.VisionRuntimeCapability{{ModelID: q.ModelID, ModelHash: q.ModelHash, ModelHashAlgorithm: q.ModelHashAlgorithm, WeightsManifestSHA256: q.WeightsManifestSHA256, ProcessorDigest: q.ProcessorDigest, Runtime: q.Runtime, RuntimeRevision: q.RuntimeRevision, MediaProfile: q.MediaProfile}},
	}
	if !providerSupportsVision(p, []config.VisionQualificationConfig{q}) {
		t.Fatal("fully qualified provider was rejected")
	}
	p.MaxConcurrency++
	if providerSupportsVision(p, []config.VisionQualificationConfig{q}) {
		t.Fatal("capacity-mismatched provider was accepted")
	}
}

func TestDispatchBodyForProviderCheckedKeepsTextSelectionSnapshot(t *testing.T) {
	var server *Server // Text dispatch must not consult live pool state.
	req := chatRequest{Model: "buyer-model", raw: []byte(`{"model":"buyer-model","messages":[{"role":"user","content":"hello"}]}`)}
	body, err := server.dispatchBodyForProviderChecked(req, pool.Provider{ModelID: "selected-model"})
	if err != nil || !bytes.Contains(body, []byte(`"model":"selected-model"`)) {
		t.Fatalf("text dispatch body = %s, err = %v", body, err)
	}
}
