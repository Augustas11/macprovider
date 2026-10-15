package buyer

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

var errVisionCapacityUnavailable = errors.New("vision_capacity_unavailable")

const (
	visionModelID             = "mlx-community/Qwen2-VL-2B-Instruct-4bit"
	visionMediaProfile        = "qwen2vl-inline-v1"
	visionMaxImages           = 2
	visionMaxEncodedBytes     = 1 << 20
	visionMaxAggregateBytes   = 2 << 20
	visionMaxAxisPixels       = 2048
	visionMaxAggregatePixels  = 4_194_304
	visionMediaTokenAllowance = 1024
)

func visionAccountingBody(raw json.RawMessage) (json.RawMessage, int) {
	var body map[string]any
	if json.Unmarshal(raw, &body) != nil {
		return raw, 0
	}
	count := 0
	messages, _ := body["messages"].([]any)
	for _, message := range messages {
		m, _ := message.(map[string]any)
		parts, _ := m["content"].([]any)
		for _, part := range parts {
			p, _ := part.(map[string]any)
			if p["type"] == "image_url" {
				count++
				p["image_url"] = map[string]any{"url": "[inline-image]"}
			}
		}
	}
	if count == 0 {
		return raw, 0
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return raw, 0
	}
	return encoded, count
}

func visionCapacityUnavailableRouteError() *routeError {
	return &routeError{status: 503, code: "vision_capacity_unavailable", message: "No qualified provider currently serves image input for the requested model"}
}

func (s *Server) providerSupportsVision(p pool.Provider) bool {
	s.routingMu.RLock()
	qualifications := append([]config.VisionQualificationConfig(nil), s.visionQualifications...)
	s.routingMu.RUnlock()
	return providerSupportsVision(p, qualifications)
}

// validateVisionContent accepts only the deliberately small first media
// surface: ordered text and data: PNG/JPEG image_url parts in user messages.
// It decodes enough to bound allocation before a native runtime sees the data.
func validateVisionContent(messages []chatMessage) (bool, int, string, string) {
	count, totalBytes, totalPixels := 0, 0, 0
	hasVision := false
	for _, message := range messages {
		if message.Role != "user" || len(bytes.TrimSpace(message.Content)) == 0 || bytes.TrimSpace(message.Content)[0] != '[' {
			continue
		}
		if duplicateJSONMember(message.Content) {
			return false, 400, "invalid_image_input", "image input must not contain duplicate JSON fields"
		}
		var parts []struct {
			Type     string `json:"type"`
			Text     any    `json:"text"`
			ImageURL *struct {
				URL    string `json:"url"`
				Detail any    `json:"detail"`
			} `json:"image_url"`
		}
		if err := json.Unmarshal(message.Content, &parts); err != nil {
			return false, 400, "unsupported_content_shape", "structured content arrays are invalid"
		}
		for _, part := range parts {
			if part.Type != "image_url" {
				continue
			}
			hasVision = true
			if part.ImageURL == nil || strings.TrimSpace(part.ImageURL.URL) == "" {
				return false, 400, "invalid_image_input", "image_url.url is required"
			}
			if part.ImageURL.Detail != nil {
				detail, ok := part.ImageURL.Detail.(string)
				if !ok || detail != "auto" {
					return false, 400, "invalid_image_input", "image_url.detail must be omitted or auto"
				}
			}
			if count >= visionMaxImages {
				return false, 413, "image_input_too_large", "image input exceeds the supported image count"
			}
			data, mime, err := inlineImageData(part.ImageURL.URL)
			if err != nil {
				return false, 400, "invalid_image_input", err.Error()
			}
			count++
			totalBytes += len(data)
			if count > visionMaxImages || totalBytes > visionMaxAggregateBytes {
				return false, 413, "image_input_too_large", "image input exceeds the supported aggregate limit"
			}
			cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
			if err != nil || format != mime || cfg.Width < 1 || cfg.Height < 1 || (format == "png" && !safePNG(data)) {
				return false, 400, "invalid_image_input", "image input must be a valid PNG or JPEG"
			}
			if cfg.Width > visionMaxAxisPixels || cfg.Height > visionMaxAxisPixels || cfg.Width > visionMaxAggregatePixels/cfg.Height {
				return false, 413, "image_input_too_large", "image dimensions exceed the supported limit"
			}
			totalPixels += cfg.Width * cfg.Height
			if totalPixels > visionMaxAggregatePixels {
				return false, 413, "image_input_too_large", "image pixels exceed the supported aggregate limit"
			}
		}
	}
	return hasVision, 0, "", ""
}

func duplicateJSONMember(raw []byte) bool {
	dec := json.NewDecoder(bytes.NewReader(raw))
	first, err := dec.Token()
	if err != nil {
		return true
	}
	if duplicateJSONValue(dec, first) {
		return true
	}
	_, err = dec.Token()
	return err != io.EOF
}

func duplicateJSONValue(dec *json.Decoder, token json.Token) bool {
	delim, ok := token.(json.Delim)
	if !ok {
		return false
	}
	switch delim {
	case '{':
		seen := map[string]struct{}{}
		for dec.More() {
			key, err := dec.Token()
			if err != nil {
				return true
			}
			name, ok := key.(string)
			if !ok {
				return true
			}
			if _, exists := seen[name]; exists {
				return true
			}
			seen[name] = struct{}{}
			value, err := dec.Token()
			if err != nil || duplicateJSONValue(dec, value) {
				return true
			}
		}
		_, err := dec.Token()
		return err != nil
	case '[':
		for dec.More() {
			value, err := dec.Token()
			if err != nil || duplicateJSONValue(dec, value) {
				return true
			}
		}
		_, err := dec.Token()
		return err != nil
	default:
		return true
	}
}

func inlineImageData(url string) ([]byte, string, error) {
	const pngPrefix = "data:image/png;base64,"
	const jpegPrefix = "data:image/jpeg;base64,"
	var encoded, mime string
	switch {
	case strings.HasPrefix(url, pngPrefix):
		encoded = strings.TrimPrefix(url, pngPrefix)
		mime = "png"
	case strings.HasPrefix(url, jpegPrefix):
		encoded = strings.TrimPrefix(url, jpegPrefix)
		mime = "jpeg"
	default:
		return nil, "", fmt.Errorf("only inline PNG and JPEG data URLs are supported")
	}
	if encoded == "" || len(encoded) > base64.StdEncoding.EncodedLen(visionMaxEncodedBytes) {
		return nil, "", fmt.Errorf("inline image exceeds the supported encoded limit")
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(data) == 0 || len(data) > visionMaxEncodedBytes || base64.StdEncoding.EncodeToString(data) != encoded {
		return nil, "", fmt.Errorf("inline image must be valid canonical base64 within the supported limit")
	}
	return data, mime, nil
}

func safePNG(data []byte) bool {
	if len(data) < 8 || !bytes.Equal(data[:8], []byte{137, 80, 78, 71, 13, 10, 26, 10}) {
		return false
	}
	seenIHDR := false
	for offset := 8; offset+12 <= len(data); {
		length := int(binary.BigEndian.Uint32(data[offset : offset+4]))
		if length < 0 || offset+12+length > len(data) {
			return false
		}
		kind := string(data[offset+4 : offset+8])
		switch kind {
		case "IHDR":
			if seenIHDR || offset != 8 || length != 13 {
				return false
			}
			seenIHDR = true
		case "acTL", "iCCP", "zTXt", "iTXt":
			return false
		case "IEND":
			return seenIHDR && length == 0 && offset+12 == len(data)
		}
		offset += 12 + length
	}
	return false
}

func providerSupportsVision(p pool.Provider, qualifications []config.VisionQualificationConfig) bool {
	if providerEngineClass(p) != engineClassNative {
		return false
	}
	if p.HardwareCapacity == nil || p.HardwareCapacity.Chip == "" {
		return false
	}
	for _, q := range qualifications {
		for _, cap := range p.VisionRuntimeCapabilities {
			if q.ModelID == visionModelID && q.MediaProfile == visionMediaProfile && q.Runtime == engineClassNative &&
				q.ProviderID == p.ProviderID && q.BinaryVersion == p.BinaryVersion && q.HardwareChip == p.HardwareCapacity.Chip &&
				q.RAMGB == p.RAMGB && q.MaxContextTokens == p.MaxContextTokens && q.MaxConcurrency == p.MaxConcurrency &&
				q.ModelID == p.ModelID && q.ModelHash == p.ModelHash &&
				q.ModelHashAlgorithm == p.ModelHashAlgorithm && q.WeightsManifestSHA256 == p.WeightsManifestSHA256 &&
				q.ModelID == cap.ModelID && q.ModelHash == cap.ModelHash && q.ModelHashAlgorithm == cap.ModelHashAlgorithm &&
				q.WeightsManifestSHA256 == cap.WeightsManifestSHA256 && q.ProcessorDigest == cap.ProcessorDigest &&
				q.Runtime == cap.Runtime && q.RuntimeRevision == cap.RuntimeRevision && q.MediaProfile == cap.MediaProfile &&
				q.QualificationDigest != "" {
				return true
			}
		}
	}
	return false
}

func sameVisionProviderIdentity(a, b pool.Provider) bool {
	if a.HardwareCapacity == nil || b.HardwareCapacity == nil || a.HardwareCapacity.Chip != b.HardwareCapacity.Chip {
		return false
	}
	return a.ProviderID == b.ProviderID && a.AssignedID == b.AssignedID &&
		a.BinaryVersion == b.BinaryVersion && a.RAMGB == b.RAMGB &&
		a.MaxContextTokens == b.MaxContextTokens && a.MaxConcurrency == b.MaxConcurrency &&
		a.ModelID == b.ModelID && a.ModelHash == b.ModelHash &&
		a.ModelHashAlgorithm == b.ModelHashAlgorithm &&
		a.WeightsManifestSHA256 == b.WeightsManifestSHA256 &&
		a.RuntimeSource == b.RuntimeSource
}
