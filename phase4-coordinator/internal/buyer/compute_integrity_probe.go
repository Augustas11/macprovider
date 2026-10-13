package buyer

// SPEC-036 FR-20: verification requests travel the ordinary paid dispatch
// path. The coordinator calls its own /v1/chat/completions handler in
// process with the same gateway context the gateway sends: service-token
// bearer, an account, the effective output budget, an auto-prefix
// conversation-cache key and the gateway's capability headers. The request
// is pinned to the verified provider with X-MacProvider-Provider, which the
// provider never sees. No buyer is debited (buyer debit happens only in the
// gateway); the provider is credited and settled exactly as for buyer
// traffic. The request is pinned to the verified provider session with
// X-MacProvider-Session, which the provider never sees, so the output scored
// is the output of the session that was selected.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/google/uuid"
)

// ComputeIntegrityAccountPrefix marks FR-20 verification accounts.
const ComputeIntegrityAccountPrefix = "cip_"

const maxComputeIntegrityProbeResponseBytes = 1 << 20

// ComputeIntegrityProbeResult is the verified provider's answer.
type ComputeIntegrityProbeResult struct {
	OutputText    string
	ReasoningText string
	Complete      bool
}

type probeResponseWriter struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (w *probeResponseWriter) Header() http.Header { return w.header }

func (w *probeResponseWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}

func (w *probeResponseWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if w.body.Len()+len(p) > maxComputeIntegrityProbeResponseBytes {
		return 0, errors.New("compute-integrity probe response too large")
	}
	return w.body.Write(p)
}

func (w *probeResponseWriter) Flush() {}

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// DispatchComputeIntegrityProbe sends one verification request to one
// provider session through the ordinary chat-completions handler.
func (s *Server) DispatchComputeIntegrityProbe(ctx context.Context, assignedID string, body []byte, maxTokens int) (ComputeIntegrityProbeResult, error) {
	if strings.TrimSpace(s.gatewayServiceToken) == "" {
		return ComputeIntegrityProbeResult{}, errors.New("compute-integrity probe: gateway service token is not configured")
	}
	if assignedID == "" || len(body) == 0 || maxTokens <= 0 {
		return ComputeIntegrityProbeResult{}, errors.New("compute-integrity probe: invalid request")
	}
	accountSuffix, err := randomToken(16)
	if err != nil {
		return ComputeIntegrityProbeResult{}, err
	}
	convKey := make([]byte, 32)
	if _, err := rand.Read(convKey); err != nil {
		return ComputeIntegrityProbeResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return ComputeIntegrityProbeResult{}, err
	}
	req.RemoteAddr = "127.0.0.1:0"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.gatewayServiceToken)
	req.Header.Set("X-MacProvider-Account", ComputeIntegrityAccountPrefix+accountSuffix)
	req.Header.Set("X-Request-ID", uuid.NewString())
	req.Header.Set(settlementTrailersCapabilityHeader, "1")
	req.Header.Set(routeSnapshotV2CapabilityHeader, "1")
	req.Header.Set(capacityShed429CapabilityHeader, "1")
	req.Header.Set(effectiveMaxOutputTokensHeader, strconv.Itoa(maxTokens))
	req.Header.Set("X-MacProvider-Internal-Conv-Cache", "conv:"+base64.RawURLEncoding.EncodeToString(convKey))
	req.Header.Set("X-MacProvider-Session", assignedID)

	w := &probeResponseWriter{header: http.Header{}}
	s.Handler().ServeHTTP(w, req)
	if w.status != http.StatusOK {
		return ComputeIntegrityProbeResult{}, fmt.Errorf("compute-integrity probe: status %d", w.status)
	}
	return parseComputeIntegrityProbeBody(w.body.Bytes())
}

func parseComputeIntegrityProbeBody(raw []byte) (ComputeIntegrityProbeResult, error) {
	var resp struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      struct {
				Content          *string `json:"content"`
				ReasoningContent *string `json:"reasoning_content"`
				Reasoning        *string `json:"reasoning"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return ComputeIntegrityProbeResult{}, fmt.Errorf("compute-integrity probe: %w", err)
	}
	if len(resp.Choices) != 1 {
		return ComputeIntegrityProbeResult{}, errors.New("compute-integrity probe: expected one choice")
	}
	choice := resp.Choices[0]
	out := ComputeIntegrityProbeResult{Complete: choice.FinishReason == "stop" || choice.FinishReason == "length"}
	if choice.Message.Content != nil {
		out.OutputText = *choice.Message.Content
	}
	switch {
	case choice.Message.ReasoningContent != nil:
		out.ReasoningText = *choice.Message.ReasoningContent
	case choice.Message.Reasoning != nil:
		out.ReasoningText = *choice.Message.Reasoning
	}
	return out, nil
}
