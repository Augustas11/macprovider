package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

const promptHashBasisCoordinatorV1 = "coordinator_prompt_canonical_v1"

func (b *billingRecorder) recordRouteSnapshot(providerBody []byte, provider pool.Provider) (*providerws.SettlementReceiptMetadata, error) {
	attemptN := b.routeSnapshotAttemptN
	b.routeSnapshotAttemptN++
	b.settlementAttemptN = 0
	b.hasSettlementAttemptN = false

	store, _, _ := b.server.billingState()
	if store == nil {
		return nil, nil
	}
	settlementCfg := store.SettlementConfig(config.Default().Settlement)
	routeMode := billing.VerifiedModelSettlementMode(settlementCfg)
	skipOrEnforceError := func(reason string) (*providerws.SettlementReceiptMetadata, error) {
		if routeMode == billing.RouteSnapshotModeEnforce {
			return nil, fmt.Errorf("verified model settlement enforce requires route snapshot: %s", reason)
		}
		return nil, nil
	}
	if len(provider.ReceiptPubkey) == 0 {
		return skipOrEnforceError("missing provider receipt key")
	}
	keyID, err := billing.ReceiptKeyID(provider.ReceiptPubkey)
	if err != nil {
		return skipOrEnforceError("invalid provider receipt key")
	}
	reportedHash := strings.TrimSpace(provider.ModelHash)
	if !isLowerHex64(reportedHash) {
		return skipOrEnforceError("invalid provider model hash")
	}
	material, ok := tier2.SnapshotMaterial(provider.ModelID, reportedHash)
	if !ok {
		return skipOrEnforceError("missing catalog material")
	}
	if material.HashStatus != pool.HashStatusVerified || material.ExpectedModelHash != reportedHash {
		return skipOrEnforceError("model hash not verified")
	}
	promptHash, err := coordinatorPromptHash(providerBody)
	if err != nil {
		return nil, err
	}
	sessionID := stringPtrOrNil(provider.AssignedID)
	pendingDeadline := settlementCfg.RecoveryGraceSeconds
	if pendingDeadline <= 0 {
		pendingDeadline = config.Default().Settlement.RecoveryGraceSeconds
	}
	snapshot := billing.RouteSnapshot{
		AccountScope:                      accountScopeForSettlement(b.accountID),
		RequestID:                         b.requestID,
		AttemptN:                          int64(attemptN),
		ProviderID:                        provider.ProviderID,
		ProviderSessionID:                 sessionID,
		ProviderGenerationID:              nil,
		PaidEntrypoint:                    "coordinator_buyer_v1_chat_completions",
		ProviderReceiptKeyID:              keyID,
		ProviderReceiptKeySource:          "auth_session",
		ModelID:                           provider.ModelID,
		ProviderReportedModelHash:         reportedHash,
		ExpectedCatalogModelHash:          material.ExpectedModelHash,
		CatalogID:                         material.CatalogID,
		CatalogBodyDigest:                 material.CatalogBodyDigest,
		CatalogSignatureKeyID:             material.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint: material.CatalogSignaturePubkeyFingerprint,
		CatalogExpiresAtUnixMS:            material.CatalogExpiresAt.UnixMilli(),
		Spec008HashStatus:                 string(material.HashStatus),
		RouteSnapshotPolicyVersion:        billing.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                 routeMode,
		RouteDecisionTSUnixMS:             b.state.routingDone.UnixMilli(),
		RequestStartTSUnixMS:              b.startedAt.UnixMilli(),
		PendingDeadlineSeconds:            int64(pendingDeadline),
		PromptHashBasis:                   promptHashBasisCoordinatorV1,
		PromptHash:                        promptHash,
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	digest, err := store.InsertRouteSnapshot(ctx, snapshot)
	if err != nil {
		return nil, err
	}
	b.settlementAttemptN = attemptN
	b.hasSettlementAttemptN = true
	b.settlementPolicyMode = snapshot.RouteSnapshotMode
	b.settlementPolicyVersion = snapshot.RouteSnapshotPolicyVersion
	return &providerws.SettlementReceiptMetadata{
		AccountScope:               snapshot.AccountScope,
		RequestID:                  snapshot.RequestID,
		AttemptN:                   snapshot.AttemptN,
		ProviderID:                 snapshot.ProviderID,
		ProviderReceiptKeyID:       snapshot.ProviderReceiptKeyID,
		ModelID:                    snapshot.ModelID,
		ExpectedCatalogModelHash:   snapshot.ExpectedCatalogModelHash,
		CatalogID:                  snapshot.CatalogID,
		CatalogBodyDigest:          snapshot.CatalogBodyDigest,
		RouteSnapshotDigest:        digest,
		RouteSnapshotPolicyVersion: snapshot.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:          snapshot.RouteSnapshotMode,
		PromptHash:                 snapshot.PromptHash,
		OutputPrefixStartByte:      b.outputCursorByte,
		PendingDeadlineSeconds:     snapshot.PendingDeadlineSeconds,
	}, nil
}

func isLowerHex64(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, ch := range value {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return false
		}
	}
	return true
}

func accountScopeForSettlement(accountID string) string {
	return billing.AccountScopeForSettlement(accountID)
}

func stringPtrOrNil(value string) *string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	v := value
	return &v
}

func writeRouteSnapshotError(w http.ResponseWriter, rec *billingRecorder, err error) {
	rec.server.log.Warn().Err(err).Str("request_id", rec.requestID).Msg("route snapshot insert failed before provider dispatch")
	rec.logBuyerFailure(http.StatusInternalServerError, "Could not durably record route snapshot")
	writeError(w, http.StatusInternalServerError, "route_snapshot_failed", "Could not durably record route snapshot")
}

func (b *billingRecorder) ingestSettlementReceipt(provider pool.Provider, header string) error {
	header = normalizeReceiptHeaderValue(header)
	if len(provider.ReceiptPubkey) == 0 || !b.hasSettlementAttemptN {
		return nil
	}
	store, _, _ := b.server.billingState()
	if store == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	identity := billing.SettlementReceiptIdentity{
		AccountScope: accountScopeForSettlement(b.accountID),
		RequestID:    b.requestID,
		AttemptN:     int64(b.settlementAttemptN),
		ProviderID:   provider.ProviderID,
	}
	if header == "" {
		_, err := store.RecordMissingSettlementReceipt(ctx, billing.SettlementReceiptMissingInput{
			SettlementReceiptIdentity: identity,
		})
		if err != nil {
			b.server.log.Warn().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("missing settlement receipt recording failed")
		}
		return err
	}
	_, err := store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: identity,
		Header:                    header,
		ProviderReceiptPubkey:     provider.ReceiptPubkey,
	})
	if err != nil {
		b.server.log.Warn().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("settlement receipt ingestion failed")
	}
	return err
}

func coordinatorPromptHash(raw json.RawMessage) (string, error) {
	value, err := canonicalPromptObject(raw)
	if err != nil {
		return "", err
	}
	digest, _, err := billing.CanonicalSHA256Hex(value)
	return digest, err
}

func canonicalPromptObject(raw json.RawMessage) (map[string]any, error) {
	root, err := decodeJSONObject(raw)
	if err != nil {
		return nil, err
	}
	messages, err := canonicalMessages(root["messages"])
	if err != nil {
		return nil, err
	}
	tools, err := canonicalTools(root["tools"])
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"model":             root["model"],
		"messages":          messages,
		"tools":             tools,
		"temperature":       jcsOrNull(root["temperature"]),
		"top_p":             jcsOrNull(root["top_p"]),
		"max_tokens":        jcsOrNull(root["max_tokens"]),
		"stop":              jcsOrNull(root["stop"]),
		"seed":              jcsOrNull(root["seed"]),
		"response_format":   jcsOrNull(root["response_format"]),
		"tool_choice":       jcsOrNull(root["tool_choice"]),
		"presence_penalty":  jcsOrNull(root["presence_penalty"]),
		"frequency_penalty": jcsOrNull(root["frequency_penalty"]),
		"logit_bias":        jcsOrNull(root["logit_bias"]),
		"logprobs":          jcsOrNull(root["logprobs"]),
		"top_logprobs":      jcsOrNull(root["top_logprobs"]),
		"n":                 jcsOrNull(root["n"]),
	}, nil
}

func canonicalMessages(value any) ([]any, error) {
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("messages must be array")
	}
	out := make([]any, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("message must be object")
		}
		role, ok := obj["role"].(string)
		if !ok {
			return nil, fmt.Errorf("message role must be string")
		}
		content, err := canonicalContent(obj["content"])
		if err != nil {
			return nil, err
		}
		toolCalls, err := canonicalToolCalls(obj["tool_calls"])
		if err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"role":         role,
			"content":      content,
			"name":         jcsOrNull(obj["name"]),
			"tool_call_id": jcsOrNull(obj["tool_call_id"]),
			"tool_calls":   toolCalls,
		})
	}
	return out, nil
}

func canonicalContent(value any) (any, error) {
	switch x := value.(type) {
	case nil:
		return nil, nil
	case string:
		return normalizeLineEndings(x), nil
	case []any:
		out := make([]any, 0, len(x))
		for _, item := range x {
			part, err := canonicalContentPart(item)
			if err != nil {
				return nil, err
			}
			out = append(out, part)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported message content")
	}
}

func canonicalContentPart(value any) (map[string]any, error) {
	obj, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("content part must be object")
	}
	typ, ok := obj["type"].(string)
	if !ok {
		return nil, fmt.Errorf("content part type must be string")
	}
	switch typ {
	case "text":
		text, ok := obj["text"].(string)
		if !ok {
			return nil, fmt.Errorf("text content must be string")
		}
		return map[string]any{"type": "text", "text": normalizeLineEndings(text)}, nil
	case "image_url":
		imageURL, ok := obj["image_url"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("image_url must be object")
		}
		url, ok := imageURL["url"].(string)
		if !ok {
			return nil, fmt.Errorf("image_url.url must be string")
		}
		return map[string]any{
			"type": "image_url",
			"image_url": map[string]any{
				"url":    url,
				"detail": jcsOrNull(imageURL["detail"]),
			},
		}, nil
	case "input_audio":
		audio, ok := obj["input_audio"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("input_audio must be object")
		}
		data, dataOK := audio["data"].(string)
		format, formatOK := audio["format"].(string)
		if !dataOK || !formatOK {
			return nil, fmt.Errorf("input_audio data and format must be strings")
		}
		return map[string]any{
			"type": "input_audio",
			"input_audio": map[string]any{
				"data":   data,
				"format": format,
			},
		}, nil
	default:
		return nil, fmt.Errorf("unsupported content part type %q", typ)
	}
}

func canonicalTools(value any) (any, error) {
	if value == nil {
		return nil, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("tools must be array")
	}
	out := make([]any, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("tool must be object")
		}
		function, ok := obj["function"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("tool.function must be object")
		}
		name, ok := function["name"].(string)
		if !ok {
			return nil, fmt.Errorf("tool.function.name must be string")
		}
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        name,
				"description": jcsOrNull(function["description"]),
				"parameters":  jcsOrNull(function["parameters"]),
			},
		})
	}
	return out, nil
}

func canonicalToolCalls(value any) (any, error) {
	if value == nil {
		return nil, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("tool_calls must be array")
	}
	out := make([]any, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("tool_call must be object")
		}
		id, idOK := obj["id"].(string)
		function, fnOK := obj["function"].(map[string]any)
		if !idOK || !fnOK {
			return nil, fmt.Errorf("tool_call id and function are required")
		}
		name, nameOK := function["name"].(string)
		arguments, argsOK := function["arguments"].(string)
		if !nameOK || !argsOK {
			return nil, fmt.Errorf("tool_call function name and arguments are required")
		}
		out = append(out, map[string]any{
			"id":   id,
			"type": "function",
			"function": map[string]any{
				"name":      name,
				"arguments": billing.RawJSONString(arguments),
			},
		})
	}
	return out, nil
}

func decodeJSONObject(raw json.RawMessage) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return nil, err
	}
	obj, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("request must be object")
	}
	return obj, nil
}

func jcsOrNull(value any) any {
	if value == nil {
		return nil
	}
	return value
}

func normalizeLineEndings(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	return strings.ReplaceAll(value, "\r", "\n")
}
