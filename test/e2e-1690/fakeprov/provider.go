package main

// Fake provider: HTTP inference endpoint + coordinator WS session. Ported from
// test/integration/harness_test.go (type fakeProvider, start, runWS,
// buildSettlementReceiptHeader, readyStateUpdate, ...) with *testing.T replaced
// by logging and the one-shot WS dial replaced by reconnect-forever.

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"golang.org/x/text/unicode/norm"
)

const snapshotManifestV1 = "macprovider.snapshot-manifest.v1"

type fakeProvider struct {
	providerID        string
	localProviderID   string
	providerToken     string
	wsURL             string
	endpointURL       string
	settlementEnabled bool
	catalogKey        string
	receiptPubkey     ed25519.PublicKey
	receiptPrivkey    ed25519.PrivateKey
	// #1690 loopback pool member (loopback.go)
	runtimeSource string
	admissionKey  ed25519.PrivateKey
	// refreshCatalog, when set, re-derives the catalog identity before every
	// WS connect (-catalog-from-coordinator).
	refreshCatalog func(context.Context) (catalogIdentity, error)
	// #1690 e2e: response shape. streamChunks content chunks of "tokI ",
	// chunkDelay between SSE events, nonStreamDelay before a non-streaming
	// response (lets a buyer disconnect mid-stream / before the body).
	streamChunks   int
	chunkDelay     time.Duration
	nonStreamDelay time.Duration

	mu         sync.Mutex
	id         catalogIdentity // model id/hash + catalog envelope advertised
	hits       int
	connected  bool
	assignedID string
}

func (p *fakeProvider) identity() catalogIdentity {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.id
}

func (p *fakeProvider) enableSettlementReceipts() error {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("generate fake settlement receipt key: %w", err)
	}
	p.settlementEnabled = true
	p.receiptPubkey = pub
	p.receiptPrivkey = priv
	return nil
}

const fakeCompletionBody = `{
  "id":"chatcmpl-fake-integration",
  "object":"chat.completion",
  "created":1780000000,
  "model":"llama-3.2-3b-instruct",
  "usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},
  "choices":[{"index":0,"message":{"role":"assistant","content":"hello from fake provider"},"finish_reason":"stop"}]
}`

type settlementMetadata struct {
	AccountScope               string `json:"account_scope"`
	RequestID                  string `json:"request_id"`
	AttemptN                   int64  `json:"attempt_n"`
	ProviderID                 string `json:"provider_id"`
	ProviderReceiptKeyID       string `json:"provider_receipt_key_id"`
	ModelID                    string `json:"model_id"`
	ExpectedCatalogModelHash   string `json:"expected_catalog_model_hash"`
	CatalogID                  string `json:"catalog_id"`
	CatalogBodyDigest          string `json:"catalog_body_digest"`
	RouteSnapshotDigest        string `json:"route_snapshot_digest"`
	RouteSnapshotPolicyVersion string `json:"route_snapshot_policy_version"`
	RouteSnapshotMode          string `json:"route_snapshot_mode"`
	PromptHash                 string `json:"prompt_hash"`
	OutputPrefixStartByte      int64  `json:"output_prefix_start_byte"`
	PendingDeadlineSeconds     int64  `json:"pending_deadline_seconds"`
}

func decodeSettlementMetadataHeader(header string) (settlementMetadata, bool, error) {
	header = strings.TrimSpace(header)
	if header == "" {
		return settlementMetadata{}, false, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(header)
	if err != nil {
		return settlementMetadata{}, false, fmt.Errorf("decode settlement metadata: %w", err)
	}
	var metadata settlementMetadata
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return settlementMetadata{}, false, fmt.Errorf("decode settlement metadata json: %w", err)
	}
	return metadata, true, nil
}

func (p *fakeProvider) buildSettlementReceiptHeader(metadata settlementMetadata, content, finishReason string, promptTokens, completionTokens, terminalTSUnixMS int64) (string, error) {
	normalizedContent := norm.NFC.String(normalizeSpec015LineEndings(content))
	deliveredBytes := int64(len([]byte(normalizedContent)))
	outputPrefixEnd := metadata.OutputPrefixStartByte + deliveredBytes
	output := map[string]any{
		"content":                  normalizedContent,
		"finish_reason":            finishReason,
		"output_prefix_end_byte":   outputPrefixEnd,
		"output_prefix_start_byte": metadata.OutputPrefixStartByte,
		"terminal_state":           "normal_done",
		"tool_calls":               nil,
	}
	outputHash, _, err := spec015CanonicalSHA256Hex(output)
	if err != nil {
		return "", fmt.Errorf("canonical output hash: %w", err)
	}
	usage := map[string]any{
		"billable_input_tokens":  promptTokens,
		"billable_output_tokens": completionTokens,
		"delivered_output_bytes": deliveredBytes,
		"observed_input_tokens":  promptTokens,
		"observed_output_tokens": completionTokens,
	}
	tuple := map[string]any{
		"account_scope":                 metadata.AccountScope,
		"attempt_n":                     metadata.AttemptN,
		"catalog_body_digest":           metadata.CatalogBodyDigest,
		"catalog_id":                    metadata.CatalogID,
		"expected_catalog_model_hash":   metadata.ExpectedCatalogModelHash,
		"issued_at_unix_ms":             terminalTSUnixMS,
		"model_hash":                    p.identity().ModelHash,
		"model_id":                      metadata.ModelID,
		"output_hash":                   outputHash,
		"output_prefix_end_byte":        outputPrefixEnd,
		"output_prefix_start_byte":      metadata.OutputPrefixStartByte,
		"prompt_hash":                   metadata.PromptHash,
		"provider_id":                   metadata.ProviderID,
		"provider_receipt_key_id":       metadata.ProviderReceiptKeyID,
		"receipt_version":               "4",
		"request_id":                    metadata.RequestID,
		"route_snapshot_digest":         metadata.RouteSnapshotDigest,
		"route_snapshot_mode":           metadata.RouteSnapshotMode,
		"route_snapshot_policy_version": metadata.RouteSnapshotPolicyVersion,
		"signature_key_alg":             "Ed25519",
		"terminal_state":                "normal_done",
		"terminal_state_ts_unix_ms":     terminalTSUnixMS,
		"usage":                         usage,
	}
	canonical, err := spec015CanonicalJSON(tuple)
	if err != nil {
		return "", fmt.Errorf("canonical settlement tuple: %w", err)
	}
	signature := ed25519.Sign(p.receiptPrivkey, canonical)
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(signature), nil
}

func readyStateUpdate(modelID, modelHash string) map[string]any {
	msg := map[string]any{
		"type":  "state_update",
		"state": "ready",
		"metrics_snapshot": map[string]any{
			"model_id":                   modelID,
			"model_params_b":             3.0,
			"ram_gb":                     16,
			"max_context_tokens":         8192,
			"max_concurrency":            2,
			"slots_free":                 2,
			"slots_total":                2,
			"throughput_tps_estimate":    20.0,
			"requests_served_since_last": 0,
			"avg_latency_ms_since_last":  0.0,
			"throughput_tps_since_last":  0.0,
		},
	}
	addCanonicalModelIdentity(msg["metrics_snapshot"].(map[string]any), modelHash)
	return msg
}

func addCanonicalModelIdentity(msg map[string]any, modelHash string) {
	if modelHash == "" {
		return
	}
	msg["model_hash"] = modelHash
	msg["model_hash_algorithm"] = modelHashAlgorithm
}

func chatBodyRequestsStream(body []byte) bool {
	var envelope struct {
		Stream bool `json:"stream"`
	}
	return json.Unmarshal(body, &envelope) == nil && envelope.Stream
}

// inferenceHandler is the harness start() mux: /v1/chat/completions
// (streaming + non-streaming), /v1/models, /healthz.
func (p *fakeProvider) inferenceHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		requestBody, _ := io.ReadAll(r.Body)
		settlementMetadata, hasSettlementMetadata, err := decodeSettlementMetadataHeader(r.Header.Get("X-MacProvider-Settlement-Metadata"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		p.mu.Lock()
		p.hits++
		hits := p.hits
		p.mu.Unlock()
		stream := chatBodyRequestsStream(requestBody)
		logf("chat completion #%d stream=%t settlement_metadata=%t request_id=%s", hits, stream, hasSettlementMetadata, settlementMetadata.RequestID)
		n := p.streamChunks
		if n < 1 {
			n = 3
		}
		pieces := make([]string, n)
		for i := range pieces {
			pieces[i] = fmt.Sprintf("tok%d ", i)
		}
		content := strings.Join(pieces, "")
		const promptTokens = 8
		completionTokens := int64(n)
		if stream {
			w.Header().Set("Content-Type", "text/event-stream")
			var receiptMeta *settlementMeta
			if p.settlementEnabled && hasSettlementMetadata {
				receiptMeta = &settlementMetadata
				w.Header().Add("Trailer", "X-MacProvider-Receipt")
				w.Header().Add("Trailer", "X-MacProvider-Receipt-Terminal-State-TS-Unix-MS")
			}
			w.WriteHeader(http.StatusOK)
			fl, _ := w.(http.Flusher)
			emit := func(line string) bool {
				if _, err := w.Write([]byte(line)); err != nil {
					return false
				}
				if fl != nil {
					fl.Flush()
				}
				return true
			}
			for i, piece := range pieces {
				if i > 0 && p.chunkDelay > 0 {
					select {
					case <-r.Context().Done():
						logf("stream request_id=%s: caller went away after %d/%d chunks", settlementMetadata.RequestID, i, n)
						return
					case <-time.After(p.chunkDelay):
					}
				}
				chunk, _ := json.Marshal(map[string]any{"id": "chatcmpl-fake-e2e", "object": "chat.completion.chunk", "created": 1780000000, "model": "llama-3.2-3b-instruct",
					"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"content": piece}, "finish_reason": nil}}})
				if !emit("data: " + string(chunk) + "\n\n") {
					logf("stream request_id=%s: write failed after %d/%d chunks", settlementMetadata.RequestID, i, n)
					return
				}
			}
			emit("data: {\"id\":\"chatcmpl-fake-e2e\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n")
			emit(fmt.Sprintf("data: {\"id\":\"chatcmpl-fake-e2e\",\"object\":\"chat.completion.chunk\",\"created\":1780000000,\"model\":\"llama-3.2-3b-instruct\",\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d,\"total_tokens\":%d},\"choices\":[]}\n\n", promptTokens, completionTokens, promptTokens+completionTokens))
			emit("data: [DONE]\n\n")
			if receiptMeta != nil {
				terminalTS := time.Now().UTC().UnixMilli()
				receipt, err := p.buildSettlementReceiptHeader(*receiptMeta, content, "stop", promptTokens, completionTokens, terminalTS)
				if err != nil {
					logf("receipt build failed: %v", err)
					return
				}
				w.Header().Set("X-MacProvider-Receipt", receipt)
				w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", strconv.FormatInt(terminalTS, 10))
			}
			return
		}
		if p.nonStreamDelay > 0 {
			select {
			case <-r.Context().Done():
				logf("non-stream request_id=%s: caller went away during delay", settlementMetadata.RequestID)
				return
			case <-time.After(p.nonStreamDelay):
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-MacProvider-Completion-Tokens", strconv.FormatInt(completionTokens, 10))
		if p.settlementEnabled && hasSettlementMetadata {
			terminalTS := time.Now().UTC().UnixMilli()
			receipt, err := p.buildSettlementReceiptHeader(settlementMetadata, content, "stop", promptTokens, completionTokens, terminalTS)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("X-MacProvider-Receipt", receipt)
			w.Header().Set("X-MacProvider-Receipt-Terminal-State-TS-Unix-MS", strconv.FormatInt(terminalTS, 10))
		}
		body, _ := json.Marshal(map[string]any{"id": "chatcmpl-fake-e2e", "object": "chat.completion", "created": 1780000000, "model": "llama-3.2-3b-instruct",
			"usage":   map[string]any{"prompt_tokens": promptTokens, "completion_tokens": completionTokens, "total_tokens": promptTokens + completionTokens},
			"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "content": content}, "finish_reason": "stop"}}})
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"object":"list","data":[{"id":"llama-3.2-3b-instruct","object":"model"}]}`))
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	return mux
}

// statusHandler serves the local /v1/status subset that
// ops/pearl-updater/catalog-canary-proof.py checks (field names match the
// real CLI, phase3-binary/Sources/macprovider-cli/HTTPServer.swift).
func (p *fakeProvider) statusHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/status", func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		connected, assignedID, hits, id := p.connected, p.assignedID, p.hits, p.id
		p.mu.Unlock()
		networkState := "connecting"
		if connected {
			networkState = "buyer_serving"
		}
		var session any
		if assignedID != "" {
			session = assignedID
		}
		body := map[string]any{
			"provider_id":    p.localProviderID,
			"status":         "ready",
			"network_state":  networkState,
			"model":          p.catalogKey,
			"model_loaded":   true,
			"model_hash":     id.ModelHash,
			"requests_total": hits,
			"coordinator": map[string]any{
				"connected": connected,
				"session":   session,
			},
			"catalog": map[string]any{
				"release_id":     id.ReleaseID,
				"policy_version": id.PolicyVersion,
				"digest":         id.CandidatesSHA,
				"signer_key_id":  id.SignerKeyID,
				"row_identity":   id.RowIdentity,
				"catalog_key":    p.catalogKey,
				"model_id":       id.ModelID,
				"source":         "coordinator",
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(body)
	})
	return mux
}

func (p *fakeProvider) setSession(connected bool, assignedID string) {
	p.mu.Lock()
	p.connected = connected
	p.assignedID = assignedID
	p.mu.Unlock()
}

// runWSForever reconnects with 1s..10s backoff until ctx is cancelled. The
// backoff resets after a session that was accepted.
func (p *fakeProvider) runWSForever(ctx context.Context) {
	backoff := time.Second
	for attempt := 1; ctx.Err() == nil; attempt++ {
		accepted, err := p.session(ctx, attempt)
		p.setSession(false, "")
		if ctx.Err() != nil {
			return
		}
		if accepted {
			backoff = time.Second
		}
		logf("ws drop (attempt %d, accepted=%t): %v; reconnecting in %s", attempt, accepted, err, backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if !accepted {
			backoff *= 2
			if backoff > 10*time.Second {
				backoff = 10 * time.Second
			}
		}
	}
}

// session is one WS connection: handshake then heartbeat until it drops.
func (p *fakeProvider) session(ctx context.Context, attempt int) (bool, error) {
	header := http.Header{}
	if p.providerToken != "" {
		header.Set("Authorization", "Bearer "+p.providerToken)
	}
	dialer := gobwas.Dialer{
		Timeout: 5 * time.Second,
		Header:  gobwas.HandshakeHeaderHTTP(header),
	}
	if p.refreshCatalog != nil {
		id, err := p.refreshCatalog(ctx)
		if err != nil {
			return false, fmt.Errorf("catalog refresh from coordinator: %w", err)
		}
		p.mu.Lock()
		changed := p.id != id
		p.id = id
		p.mu.Unlock()
		if changed {
			logf("catalog identity from coordinator: release_id=%s policy=%s sha=%s signer=%s row_identity=%s model_id=%s model_hash=%s",
				id.ReleaseID, id.PolicyVersion, id.CandidatesSHA, id.SignerKeyID, id.RowIdentity, id.ModelID, id.ModelHash)
		}
	}
	id := p.identity()
	logf("ws connect attempt %d -> %s", attempt, p.wsURL)
	conn, _, _, err := dialer.Dial(ctx, p.wsURL)
	if err != nil {
		return false, fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()
	// Unblock reads/writes when the process is asked to stop.
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	// Handshake frames must arrive promptly; heartbeats run without deadline.
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	var assignedID string
	if p.settlementEnabled {
		assignedID, err = p.handshakeV2(conn, id)
	} else {
		assignedID, err = p.handshakeV1(conn, id)
	}
	if err != nil {
		return false, err
	}
	_ = conn.SetDeadline(time.Time{})
	p.setSession(true, assignedID)
	logf("ws accepted provider_id=%s assigned_id=%s", p.providerID, assignedID)

	hbTick := time.NewTicker(1 * time.Second)
	defer hbTick.Stop()
	readDone := make(chan error, 1)
	go func() {
		for {
			if _, _, err := wsutil.ReadServerData(conn); err != nil {
				readDone <- err
				return
			}
			// Frames are dropped, as in the harness: in endpoint_url mode the
			// coordinator forwards inference over HTTP, not the WS.
		}
	}()
	beats := 0
	for {
		select {
		case <-ctx.Done():
			return true, ctx.Err()
		case err := <-readDone:
			return true, fmt.Errorf("read: %w", err)
		case <-hbTick.C:
			hb := map[string]any{
				"type":                       "heartbeat",
				"status":                     "ready",
				"model_id":                   id.ModelID,
				"model_params_b":             3.0,
				"ram_gb":                     16,
				"max_context_tokens":         8192,
				"max_concurrency":            2,
				"slots_free":                 2,
				"slots_total":                2,
				"throughput_tps_estimate":    20.0,
				"requests_served_since_last": 0,
				"avg_latency_ms_since_last":  0.0,
				"throughput_tps_since_last":  0.0,
			}
			addCanonicalModelIdentity(hb, id.ModelHash)
			if err := writeJSONFrame(conn, hb); err != nil {
				return true, fmt.Errorf("heartbeat write: %w", err)
			}
			beats++
			if beats == 1 || beats%60 == 0 {
				logf("heartbeat #%d sent (assigned_id=%s)", beats, assignedID)
			}
		}
	}
}

func addCatalogIdentity(msg map[string]any, id catalogIdentity) {
	if id.ReleaseID == "" {
		return
	}
	msg["catalog_release_id"] = id.ReleaseID
	msg["catalog_policy_version"] = id.PolicyVersion
	msg["catalog_candidate_sha256"] = id.CandidatesSHA
	msg["catalog_signer_key_id"] = id.SignerKeyID
	msg["catalog_row_identity"] = id.RowIdentity
}

// handshakeV2 is the harness v2 auth_request initial/proof exchange. The
// assigned id comes from auth_response.assigned_id (ws/messages.go
// AuthResponse), falling back to auth_challenge.assigned_id.
func (p *fakeProvider) handshakeV2(conn net.Conn, id catalogIdentity) (string, error) {
	providerECDH := make([]byte, 32)
	if _, err := rand.Read(providerECDH); err != nil {
		return "", fmt.Errorf("provider ecdh key: %w", err)
	}
	initial := map[string]any{
		"type":                        "auth_request",
		"version":                     2,
		"stage":                       "initial",
		"provider_id":                 p.providerID,
		"hostname":                    "fake-provider",
		"model_id":                    id.ModelID,
		"model_params_b":              3.0,
		"ram_gb":                      16,
		"max_context_tokens":          8192,
		"max_concurrency":             2,
		"throughput_tps_estimate":     20.0,
		"binary_version":              advertisedBinaryVersion(),
		"endpoint_url":                p.endpointURL,
		"provider_ecdh_public_key":    base64.RawURLEncoding.EncodeToString(providerECDH),
		"provider_receipt_public_key": base64.StdEncoding.EncodeToString(p.receiptPubkey),
		"supported_models":            []string{id.ModelID},
		"publishes_supported_models":  true,
		"tier2_capabilities":          map[string]any{"encrypted_leg": true, "attestation": false, "aead_suites": []string{"A256GCM"}},
	}
	addCanonicalModelIdentity(initial, id.ModelHash)
	addCatalogIdentity(initial, id)
	if p.runtimeSource != "" {
		initial["runtime_source"] = p.runtimeSource
		// SPEC-042-R010 provider half: a pool member advertises pool support.
		initial["tier2_capabilities"].(map[string]any)["trusted_pool_v1"] = true
	}
	if p.admissionKey != nil {
		initial["provider_admission_public_key"] = base64.StdEncoding.EncodeToString(p.admissionKey.Public().(ed25519.PublicKey))
	}
	initialRaw, err := json.Marshal(initial)
	if err != nil {
		return "", err
	}
	if err := wsutil.WriteClientText(conn, initialRaw); err != nil {
		return "", fmt.Errorf("auth initial write: %w", err)
	}
	challengePayload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		return "", fmt.Errorf("read auth_challenge: %w", err)
	}
	var challenge struct {
		Type          string `json:"type"`
		AuthAttemptID string `json:"auth_attempt_id"`
		AssignedID    string `json:"assigned_id"`
	}
	if err := json.Unmarshal(challengePayload, &challenge); err != nil {
		return "", fmt.Errorf("decode auth_challenge: %w", err)
	}
	if challenge.AuthAttemptID == "" {
		return "", fmt.Errorf("expected auth_challenge, got %s", truncate(challengePayload))
	}
	proof := map[string]any{
		"type":                       "auth_request",
		"version":                    2,
		"stage":                      "proof",
		"auth_attempt_id":            challenge.AuthAttemptID,
		"provider_id":                p.providerID,
		"attestation_token":          nil,
		"supported_models":           []string{id.ModelID},
		"publishes_supported_models": true,
	}
	if p.admissionKey != nil {
		transcript, err := transcriptSHA256(initialRaw)
		if err != nil {
			return "", fmt.Errorf("auth transcript: %w", err)
		}
		sig, err := identitySignature(p.admissionKey, challenge.AuthAttemptID, p.providerID, advertisedBinaryVersion(), initial["provider_ecdh_public_key"].(string), transcript)
		if err != nil {
			return "", fmt.Errorf("identity signature: %w", err)
		}
		proof["identity_signature"] = sig
		proof["identity_signature_transcript_sha256"] = transcript
	}
	if err := writeJSONFrame(conn, proof); err != nil {
		return "", fmt.Errorf("auth proof write: %w", err)
	}
	responsePayload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		return "", fmt.Errorf("read auth_response: %w", err)
	}
	var response struct {
		Status     string `json:"status"`
		AssignedID string `json:"assigned_id"`
	}
	if err := json.Unmarshal(responsePayload, &response); err != nil || response.Status != "accepted" {
		return "", fmt.Errorf("auth_response not accepted: %s (err=%v)", truncate(responsePayload), err)
	}
	logf("auth_response: %s", truncate(responsePayload))
	if err := writeJSONFrame(conn, readyStateUpdate(id.ModelID, id.ModelHash)); err != nil {
		return "", fmt.Errorf("state_update write: %w", err)
	}
	logf("state_update ready sent")
	if response.AssignedID == "" {
		response.AssignedID = challenge.AssignedID
	}
	return response.AssignedID, nil
}

// handshakeV1 is the harness legacy hello path (no settlement receipts). The
// catalog envelope is also accepted on hello (ws/messages.go:663), so it is
// sent when configured.
func (p *fakeProvider) handshakeV1(conn net.Conn, id catalogIdentity) (string, error) {
	hello := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             p.providerID,
		"hostname":                "fake-provider",
		"model_id":                id.ModelID,
		"model_params_b":          3.0,
		"ram_gb":                  16,
		"max_context_tokens":      8192,
		"max_concurrency":         2,
		"throughput_tps_estimate": 20.0,
		"binary_version":          advertisedBinaryVersion(),
		"attestation":             nil,
		"endpoint_url":            p.endpointURL,
	}
	addCatalogIdentity(hello, id)
	if err := writeJSONFrame(conn, hello); err != nil {
		return "", fmt.Errorf("hello write: %w", err)
	}
	payload, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		return "", fmt.Errorf("read hello_ack: %w", err)
	}
	var ack struct {
		Type       string `json:"type"`
		AssignedID string `json:"assigned_id"`
	}
	if err := json.Unmarshal(payload, &ack); err != nil || ack.Type != "hello_ack" {
		return "", fmt.Errorf("expected hello_ack, got %s (err=%v)", truncate(payload), err)
	}
	return ack.AssignedID, nil
}

func writeJSONFrame(conn net.Conn, payload map[string]any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	// Client side of the handshake: frames must be masked.
	return wsutil.WriteClientText(conn, b)
}

func truncate(b []byte) string {
	if len(b) > 512 {
		return string(b[:512]) + "..."
	}
	return string(b)
}

// advertisedBinaryVersion is the CLI version the stand-in claims. The
// production coordinator config pins required_binary_version (1.8.33), so the
// harness's "1.6.0-fake" is closed 4004 version_unsupported against a
// Pearl-shaped config. FAKEPROV_BINARY_VERSION overrides.
func advertisedBinaryVersion() string {
	if v := os.Getenv("FAKEPROV_BINARY_VERSION"); v != "" {
		return v
	}
	return "1.8.123"
}

// settlementMeta aliases the metadata type where a local variable shadows it.
type settlementMeta = settlementMetadata
