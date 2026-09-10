package relayblind

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
	"time"
)

const (
	EnvelopeVersion         = "relay-blind-request-v1"
	ReservationVersion      = "relay-blind-reservation-v1"
	ConsumeVersion          = "relay-blind-consume-v1"
	StatusVersion           = "relay-blind-status-v1"
	PinVersion              = "relay-blind-pilot-pin-v1"
	ModeRequired            = "required"
	EndpointChatCompletions = "chat_completions"
	Algorithm               = "x25519-hkdf-sha256-a256gcm-v1"
	SignatureAlgorithm      = "ed25519"
	CachePolicyNoStore      = "no-store"
	FailoverPolicyDisabled  = "disabled"
	RetryDoNotResubmit      = "do_not_resubmit"

	MaxEncryptedRequestBytes = 1 << 20
	MaxIdentifierBytes       = 128
	MaxModelCount            = 16
	MaxKeyLifetime           = 24 * time.Hour
	MaxKeyFutureSkew         = 60 * time.Second
)

var (
	ErrInvalidJSON        = errors.New("relayblind: invalid closed JSON")
	ErrInvalidKeyRecord   = errors.New("relayblind: invalid key record")
	ErrInvalidPin         = errors.New("relayblind: invalid identity pin")
	ErrInvalidEnvelope    = errors.New("relayblind: invalid envelope")
	ErrInvalidReservation = errors.New("relayblind: invalid reservation")
	ErrInvalidConsume     = errors.New("relayblind: invalid consume response")
	ErrInvalidStatus      = errors.New("relayblind: invalid status message")
)

type KeyRecord struct {
	Algorithm                string   `json:"alg"`
	PublicKey                string   `json:"public_key"`
	IdentityFingerprint      string   `json:"identity_fingerprint"`
	Models                   []string `json:"models"`
	MaxEncryptedRequestBytes uint64   `json:"max_encrypted_request_bytes"`
	EndpointFamilies         []string `json:"endpoint_families"`
	SignatureAlgorithm       string   `json:"signature_algorithm"`
	NotBeforeUnix            int64    `json:"not_before_unix"`
	ExpiresAtUnix            int64    `json:"expires_at_unix"`
	KID                      string   `json:"kid"`
	KeyRecordDigest          string   `json:"key_record_digest"`
	Signature                string   `json:"signature"`
}

type IdentityPin struct {
	Version           string   `json:"version"`
	IdentityPublicKey string   `json:"identity_public_key"`
	Fingerprint       string   `json:"fingerprint"`
	Models            []string `json:"models"`
	EndpointFamilies  []string `json:"endpoint_families"`
	NotBeforeUnix     int64    `json:"not_before_unix"`
	ExpiresAtUnix     int64    `json:"expires_at_unix"`
	Revoked           bool     `json:"revoked"`
}

type Envelope struct {
	Version                 string `json:"version"`
	Mode                    string `json:"mode"`
	EndpointFamily          string `json:"endpoint_family"`
	Model                   string `json:"model"`
	ProviderModel           string `json:"provider_model"`
	Stream                  bool   `json:"stream"`
	RequestID               string `json:"request_id"`
	MaxOutputTokens         int64  `json:"max_output_tokens"`
	InputTokenUpperBound    int64  `json:"input_token_upper_bound"`
	ReservationTokenCap     int64  `json:"reservation_token_cap"`
	ProviderBinding         string `json:"provider_binding"`
	BuyerBinding            string `json:"buyer_binding"`
	KeyRecordDigest         string `json:"key_record_digest"`
	KID                     string `json:"kid"`
	BuyerEphemeralPublicKey string `json:"buyer_ephemeral_public_key"`
	RequestReplayNonce      string `json:"request_replay_nonce"`
	IssuedAtUnix            int64  `json:"issued_at_unix"`
	Algorithm               string `json:"algorithm"`
	Ciphertext              string `json:"ciphertext"`
	Tag                     string `json:"tag"`
}

type ReservationRequest struct {
	EndpointFamily        string `json:"endpoint_family"`
	Model                 string `json:"model"`
	Stream                bool   `json:"stream"`
	MaxOutputTokens       int64  `json:"max_output_tokens"`
	InputTokenUpperBound  int64  `json:"input_token_upper_bound"`
	EncryptedRequestBytes int64  `json:"encrypted_request_bytes"`
}

type ReservationResponse struct {
	Version                  string    `json:"version"`
	ProviderBinding          string    `json:"provider_binding"`
	BuyerBinding             string    `json:"buyer_binding"`
	KeyRecordDigest          string    `json:"key_record_digest"`
	KeyRecord                KeyRecord `json:"key_record"`
	KID                      string    `json:"kid"`
	EndpointFamily           string    `json:"endpoint_family"`
	Model                    string    `json:"model"`
	ProviderModel            string    `json:"provider_model"`
	Stream                   bool      `json:"stream"`
	MaxEncryptedRequestBytes uint64    `json:"max_encrypted_request_bytes"`
	MaxOutputTokens          int64     `json:"max_output_tokens"`
	InputTokenUpperBound     int64     `json:"input_token_upper_bound"`
	ReservationTokenCap      int64     `json:"reservation_token_cap"`
	ExpiresAtUnix            int64     `json:"expires_at_unix"`
	CachePolicy              string    `json:"cache_policy"`
	FailoverPolicy           string    `json:"failover_policy"`
}

type ConsumeResponse struct {
	Version                string `json:"version"`
	ProviderBinding        string `json:"provider_binding"`
	BuyerBinding           string `json:"buyer_binding"`
	EnvelopeDigest         string `json:"envelope_digest"`
	ExecutionAuthorization string `json:"execution_authorization"`
	ConsumedAtUnix         int64  `json:"consumed_at_unix"`
	ExpiresAtUnix          int64  `json:"expires_at_unix"`
}

type StatusRequest struct {
	ProviderBindingDigest string `json:"provider_binding_digest"`
	EnvelopeDigest        string `json:"envelope_digest"`
}

type StatusResponse struct {
	Version                 string `json:"version"`
	State                   string `json:"state"`
	InternalRequestID       string `json:"internal_request_id"`
	Validated               bool   `json:"validated"`
	InputTokens             *int64 `json:"input_tokens"`
	CompletionTokens        *int64 `json:"completion_tokens"`
	EffectivePrivacyOutcome string `json:"effective_privacy_outcome"`
	RetryAction             string `json:"retry_action"`
}

func ParseKeyRecord(raw []byte) (KeyRecord, error) {
	var value KeyRecord
	if err := decodeClosed(raw, &value, []string{"alg", "public_key", "identity_fingerprint", "models", "max_encrypted_request_bytes", "endpoint_families", "signature_algorithm", "not_before_unix", "expires_at_unix", "kid", "key_record_digest", "signature"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidKeyRecord, err)
	}
	if err := value.validateStructure(); err != nil {
		return value, err
	}
	return value, nil
}

func ParseIdentityPin(raw []byte) (IdentityPin, error) {
	var value IdentityPin
	if err := decodeClosed(raw, &value, []string{"version", "identity_public_key", "fingerprint", "models", "endpoint_families", "not_before_unix", "expires_at_unix", "revoked"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidPin, err)
	}
	if err := value.validateStructure(); err != nil {
		return value, err
	}
	return value, nil
}

func ParseEnvelope(raw []byte) (Envelope, error) {
	var value Envelope
	if err := decodeClosed(raw, &value, []string{"version", "mode", "endpoint_family", "model", "provider_model", "stream", "request_id", "max_output_tokens", "input_token_upper_bound", "reservation_token_cap", "provider_binding", "buyer_binding", "key_record_digest", "kid", "buyer_ephemeral_public_key", "request_replay_nonce", "issued_at_unix", "algorithm", "ciphertext", "tag"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidEnvelope, err)
	}
	if err := value.validateStructure(true); err != nil {
		return value, err
	}
	return value, nil
}

func ParseReservationRequest(raw []byte) (ReservationRequest, error) {
	var value ReservationRequest
	if err := decodeClosed(raw, &value, []string{"endpoint_family", "model", "stream", "max_output_tokens", "input_token_upper_bound", "encrypted_request_bytes"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidReservation, err)
	}
	if err := value.Validate(); err != nil {
		return value, err
	}
	return value, nil
}

func ParseReservationResponse(raw []byte) (ReservationResponse, error) {
	var value ReservationResponse
	if err := decodeClosed(raw, &value, []string{"version", "provider_binding", "buyer_binding", "key_record_digest", "key_record", "kid", "endpoint_family", "model", "provider_model", "stream", "max_encrypted_request_bytes", "max_output_tokens", "input_token_upper_bound", "reservation_token_cap", "expires_at_unix", "cache_policy", "failover_policy"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidReservation, err)
	}
	if err := value.Validate(); err != nil {
		return value, err
	}
	return value, nil
}

func ParseConsumeResponse(raw []byte) (ConsumeResponse, error) {
	var value ConsumeResponse
	if err := decodeClosed(raw, &value, []string{"version", "provider_binding", "buyer_binding", "envelope_digest", "execution_authorization", "consumed_at_unix", "expires_at_unix"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidConsume, err)
	}
	if err := value.Validate(); err != nil {
		return value, err
	}
	return value, nil
}

func ParseStatusRequest(raw []byte) (StatusRequest, error) {
	var value StatusRequest
	if err := decodeClosed(raw, &value, []string{"provider_binding_digest", "envelope_digest"}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidStatus, err)
	}
	if err := value.Validate(); err != nil {
		return value, err
	}
	return value, nil
}

func ParseStatusResponse(raw []byte) (StatusResponse, error) {
	var value StatusResponse
	fields := []string{"version", "state", "internal_request_id", "validated", "input_tokens", "completion_tokens", "effective_privacy_outcome", "retry_action"}
	if err := decodeClosedAllowNull(raw, &value, fields, map[string]bool{"input_tokens": true, "completion_tokens": true}); err != nil {
		return value, fmt.Errorf("%w: %v", ErrInvalidStatus, err)
	}
	if err := value.Validate(); err != nil {
		return value, err
	}
	return value, nil
}

func (r ReservationRequest) Validate() error {
	if r.EndpointFamily != EndpointChatCompletions || !validModelID(r.Model) || r.MaxOutputTokens <= 0 || r.InputTokenUpperBound <= 0 || r.EncryptedRequestBytes <= 0 || r.EncryptedRequestBytes > MaxEncryptedRequestBytes {
		return ErrInvalidReservation
	}
	_, err := checkedTokenCap(r.InputTokenUpperBound, r.MaxOutputTokens)
	return err
}

func (r ReservationResponse) Validate() error {
	if r.Version != ReservationVersion || r.EndpointFamily != EndpointChatCompletions || !validModelID(r.Model) || !validModelID(r.ProviderModel) || r.KID != r.KeyRecord.KID || r.KeyRecordDigest != r.KeyRecord.KeyRecordDigest || r.MaxEncryptedRequestBytes == 0 || r.MaxEncryptedRequestBytes > r.KeyRecord.MaxEncryptedRequestBytes || r.ExpiresAtUnix <= 0 || r.CachePolicy != CachePolicyNoStore || r.FailoverPolicy != FailoverPolicyDisabled {
		return ErrInvalidReservation
	}
	if _, err := decodeBase64URLFixed(r.ProviderBinding, 32); err != nil {
		return ErrInvalidReservation
	}
	if _, err := decodeBase64URLFixed(r.BuyerBinding, 32); err != nil {
		return ErrInvalidReservation
	}
	if _, err := decodeBase64URLFixed(r.KeyRecordDigest, 32); err != nil {
		return ErrInvalidReservation
	}
	cap, err := checkedTokenCap(r.InputTokenUpperBound, r.MaxOutputTokens)
	if err != nil || cap != r.ReservationTokenCap {
		return ErrInvalidReservation
	}
	if err := r.KeyRecord.validateStructure(); err != nil {
		return ErrInvalidReservation
	}
	if len(r.KeyRecord.Models) != 1 || r.KeyRecord.Models[0] != r.Model || !contains(r.KeyRecord.EndpointFamilies, r.EndpointFamily) || r.ExpiresAtUnix > r.KeyRecord.ExpiresAtUnix {
		return ErrInvalidReservation
	}
	return nil
}

func (r ConsumeResponse) Validate() error {
	if r.Version != ConsumeVersion || r.ConsumedAtUnix < 0 || r.ExpiresAtUnix <= r.ConsumedAtUnix || !visibleASCII(r.ExecutionAuthorization, 512) {
		return ErrInvalidConsume
	}
	for _, value := range []string{r.ProviderBinding, r.BuyerBinding, r.EnvelopeDigest} {
		if _, err := decodeBase64URLFixed(value, 32); err != nil {
			return ErrInvalidConsume
		}
	}
	return nil
}

func (r StatusRequest) Validate() error {
	if _, err := decodeBase64URLFixed(r.ProviderBindingDigest, sha256.Size); err != nil {
		return ErrInvalidStatus
	}
	if _, err := decodeBase64URLFixed(r.EnvelopeDigest, sha256.Size); err != nil {
		return ErrInvalidStatus
	}
	return nil
}

func (r StatusResponse) Validate() error {
	if r.Version != StatusVersion || r.RetryAction != RetryDoNotResubmit || (r.InternalRequestID != "" && !visibleASCII(r.InternalRequestID, MaxIdentifierBytes)) {
		return ErrInvalidStatus
	}
	switch r.State {
	case "reserved", "consumed_predispatch", "dispatched", "terminal", "rejected", "unknown_postdispatch":
	default:
		return ErrInvalidStatus
	}
	if r.EffectivePrivacyOutcome != "relay_blind_unavailable" && r.EffectivePrivacyOutcome != "relay_blind_satisfied" {
		return ErrInvalidStatus
	}
	if r.EffectivePrivacyOutcome == "relay_blind_satisfied" && !r.Validated {
		return ErrInvalidStatus
	}
	if (r.InputTokens != nil) != r.Validated || r.InputTokens != nil && *r.InputTokens < 0 {
		return ErrInvalidStatus
	}
	terminal := r.State == "terminal"
	if (r.CompletionTokens != nil) != terminal || r.CompletionTokens != nil && *r.CompletionTokens < 0 {
		return ErrInvalidStatus
	}
	return nil
}

func (r ReservationResponse) MatchesRequest(request ReservationRequest) error {
	if err := request.Validate(); err != nil {
		return err
	}
	if r.EndpointFamily != request.EndpointFamily || r.Model != request.Model || r.Stream != request.Stream || r.MaxOutputTokens != request.MaxOutputTokens || r.InputTokenUpperBound != request.InputTokenUpperBound || r.MaxEncryptedRequestBytes < uint64(request.EncryptedRequestBytes) {
		return ErrInvalidReservation
	}
	return nil
}

func checkedTokenCap(input, output int64) (int64, error) {
	const max = int64(math.MaxInt32)
	if input <= 0 || output <= 0 || input > max || output > max || input > max-output {
		return 0, ErrInvalidReservation
	}
	return input + output, nil
}

func validModelID(value string) bool {
	if !visibleASCII(value, MaxIdentifierBytes) {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.ContainsRune("_-./:", rune(c)) {
			continue
		}
		return false
	}
	return true
}

func visibleASCII(value string, max int) bool {
	if value == "" || len(value) > max || value != strings.TrimSpace(value) {
		return false
	}
	for i := 0; i < len(value); i++ {
		if value[i] < 0x21 || value[i] > 0x7e {
			return false
		}
	}
	return true
}

func validSortedModels(values []string) bool {
	if len(values) == 0 || len(values) > MaxModelCount || !sort.StringsAreSorted(values) {
		return false
	}
	for i, value := range values {
		if !validModelID(value) || (i > 0 && value == values[i-1]) {
			return false
		}
	}
	return true
}

func validEndpointFamilies(values []string) bool {
	return len(values) == 1 && values[0] == EndpointChatCompletions
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func decodeClosed(raw []byte, dst any, fields []string) error {
	return decodeClosedAllowNull(raw, dst, fields, nil)
}

func decodeClosedAllowNull(raw []byte, dst any, fields []string, nullable map[string]bool) error {
	if len(raw) == 0 {
		return ErrInvalidJSON
	}
	if err := rejectDuplicateJSONKeys(raw); err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return ErrInvalidJSON
	}
	want := make(map[string]struct{}, len(fields))
	for _, field := range fields {
		want[field] = struct{}{}
	}
	seen := make(map[string]struct{}, len(fields))
	for dec.More() {
		tok, err = dec.Token()
		if err != nil {
			return ErrInvalidJSON
		}
		name, ok := tok.(string)
		if !ok {
			return ErrInvalidJSON
		}
		if _, ok := want[name]; !ok {
			return fmt.Errorf("%w: unknown field %q", ErrInvalidJSON, name)
		}
		if _, ok := seen[name]; ok {
			return fmt.Errorf("%w: duplicate field %q", ErrInvalidJSON, name)
		}
		seen[name] = struct{}{}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) && !nullable[name] {
			return ErrInvalidJSON
		}
	}
	if _, err := dec.Token(); err != nil {
		return ErrInvalidJSON
	}
	if len(seen) != len(want) {
		return ErrInvalidJSON
	}
	if tok, err := dec.Token(); err != io.EOF || tok != nil {
		return ErrInvalidJSON
	}
	dec = json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return ErrInvalidJSON
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalidJSON
	}
	return nil
}

func rejectDuplicateJSONKeys(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := scanJSONValue(dec); err != nil {
		return err
	}
	if tok, err := dec.Token(); err != io.EOF || tok != nil {
		return ErrInvalidJSON
	}
	return nil
}

func scanJSONValue(dec *json.Decoder) error {
	tok, err := dec.Token()
	if err != nil {
		return ErrInvalidJSON
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := make(map[string]struct{})
		for dec.More() {
			nameToken, err := dec.Token()
			if err != nil {
				return ErrInvalidJSON
			}
			name, ok := nameToken.(string)
			if !ok {
				return ErrInvalidJSON
			}
			if _, exists := seen[name]; exists {
				return fmt.Errorf("%w: duplicate field %q", ErrInvalidJSON, name)
			}
			seen[name] = struct{}{}
			if err := scanJSONValue(dec); err != nil {
				return err
			}
		}
		if end, err := dec.Token(); err != nil || end != json.Delim('}') {
			return ErrInvalidJSON
		}
	case '[':
		for dec.More() {
			if err := scanJSONValue(dec); err != nil {
				return err
			}
		}
		if end, err := dec.Token(); err != nil || end != json.Delim(']') {
			return ErrInvalidJSON
		}
	default:
		return ErrInvalidJSON
	}
	return nil
}
