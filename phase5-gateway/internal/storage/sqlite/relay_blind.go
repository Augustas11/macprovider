package sqlite

import (
	"fmt"
	"reflect"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

const relayBlindSelectColumns = `requested_privacy_mode, effective_privacy_outcome,
	relay_blind_envelope_digest, relay_blind_key_record_digest, relay_blind_kid,
	relay_blind_provider_binding_digest, input_token_upper_bound, max_output_tokens`

func relayBlindArgs(metadata *storage.RelayBlindMetadata) []any {
	if metadata == nil {
		return []any{"", "", "", "", "", "", int64(0), int64(0)}
	}
	return []any{
		metadata.RequestedPrivacyMode, metadata.EffectivePrivacyOutcome,
		metadata.EnvelopeDigest, metadata.KeyRecordDigest, metadata.KID,
		metadata.ProviderBindingDigest, metadata.InputTokenUpperBound, metadata.MaxOutputTokens,
	}
}

func relayBlindFromValues(requested, effective, envelope, keyRecord, kid, providerBinding string, inputCap, outputCap int64) *storage.RelayBlindMetadata {
	if requested == "" && effective == "" && envelope == "" && keyRecord == "" && kid == "" && providerBinding == "" && inputCap == 0 && outputCap == 0 {
		return nil
	}
	return &storage.RelayBlindMetadata{
		RequestedPrivacyMode: requested, EffectivePrivacyOutcome: effective,
		EnvelopeDigest: envelope, KeyRecordDigest: keyRecord, KID: kid,
		ProviderBindingDigest: providerBinding, InputTokenUpperBound: inputCap, MaxOutputTokens: outputCap,
	}
}

func relayBlindMetadataEqual(a, b *storage.RelayBlindMetadata) bool {
	return reflect.DeepEqual(a, b)
}

func validateRelayBlind(metadata *storage.RelayBlindMetadata) error {
	if metadata == nil {
		return nil
	}
	if metadata.InputTokenUpperBound < 0 || metadata.MaxOutputTokens < 0 {
		return fmt.Errorf("relay-blind token caps must be non-negative")
	}
	if metadata.RequestedPrivacyMode != "relay_blind_required" || (metadata.EffectivePrivacyOutcome != "relay_blind_satisfied" && metadata.EffectivePrivacyOutcome != "relay_blind_unavailable") ||
		metadata.EnvelopeDigest == "" || metadata.KeyRecordDigest == "" || metadata.KID == "" ||
		metadata.ProviderBindingDigest == "" {
		return fmt.Errorf("relay-blind metadata is incomplete")
	}
	return nil
}

func resolveRelayBlind(stored, supplied *storage.RelayBlindMetadata) (*storage.RelayBlindMetadata, error) {
	if stored == nil {
		if supplied != nil {
			return nil, fmt.Errorf("relay-blind metadata conflicts with plaintext reservation")
		}
		return nil, nil
	}
	if supplied == nil {
		copy := *stored
		return &copy, nil
	}
	if err := validateRelayBlind(supplied); err != nil {
		return nil, err
	}
	if stored.RequestedPrivacyMode != supplied.RequestedPrivacyMode ||
		stored.EnvelopeDigest != supplied.EnvelopeDigest ||
		stored.KeyRecordDigest != supplied.KeyRecordDigest ||
		stored.KID != supplied.KID ||
		stored.ProviderBindingDigest != supplied.ProviderBindingDigest ||
		stored.InputTokenUpperBound != supplied.InputTokenUpperBound ||
		stored.MaxOutputTokens != supplied.MaxOutputTokens {
		return nil, fmt.Errorf("relay-blind settlement metadata conflicts with reservation")
	}
	resolved := *stored
	switch {
	case supplied.EffectivePrivacyOutcome == stored.EffectivePrivacyOutcome:
	case stored.EffectivePrivacyOutcome == "" && supplied.EffectivePrivacyOutcome != "":
		resolved.EffectivePrivacyOutcome = supplied.EffectivePrivacyOutcome
	case stored.EffectivePrivacyOutcome == "relay_blind_unavailable" && supplied.EffectivePrivacyOutcome == "relay_blind_satisfied":
		resolved.EffectivePrivacyOutcome = supplied.EffectivePrivacyOutcome
	default:
		return nil, fmt.Errorf("relay-blind effective outcome conflicts with reservation")
	}
	return &resolved, nil
}

func clampRelayBlindTokens(prompt, completion int64, metadata *storage.RelayBlindMetadata) (int64, int64) {
	if metadata == nil {
		return prompt, completion
	}
	if metadata.InputTokenUpperBound >= 0 && prompt > metadata.InputTokenUpperBound {
		prompt = metadata.InputTokenUpperBound
	}
	if metadata.MaxOutputTokens >= 0 && completion > metadata.MaxOutputTokens {
		completion = metadata.MaxOutputTokens
	}
	return prompt, completion
}
