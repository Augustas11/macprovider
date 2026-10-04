package relayblind

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
)

const (
	PrivacyClassV1                  = "operator_constrained_beta_v1"
	PrivacyAssurance                = "device_bound_self_attested_beta"
	PrivacyResponseEncryption       = "buyer_provider_aead_v1"
	PrivacyReservationVersion       = "privacy-class-reservation-v1"
	PrivacyResponseVersion          = "privacy-response-v1"
	PrivacyFinalVersion             = "privacy-response-final-v1"
	PrivacyPostureVersion           = "privacy-posture-v1"
	PrivacyPostureDomain            = "macprovider/spec049/posture/v1"
	PrivacyKeyAttestationVersion    = "privacy-key-attestation-v1"
	PrivacyKeyAttestationDomain     = "macprovider/spec049/key-attestation/v1"
	PrivacyResponseKeyLabel         = "macprovider/spec049/response/aead/v1"
	PrivacyResponseNoncePrefixLabel = "macprovider/spec049/response/nonce-prefix/v1"
	PrivacyFrameObject              = "macprovider.privacy_frame"
	PrivacyResponseObject           = "macprovider.privacy_response"
	PrivacyRuntimeSource            = "native_mlx"
	PrivacySEBackendFile            = "file"
	PrivacySEBackendKeychain        = "keychain"
	PrivacyFinalStatusComplete      = "complete"
	PrivacyFinalStatusError         = "error"
	PrivacyFinalStatusCancelled     = "cancelled"

	// MaxPrivacyKeyLifetimeSeconds is the SPEC-049-R008 privacy key window.
	MaxPrivacyKeyLifetimeSeconds int64 = 3600
	// MaxPrivacyKeyRecordDigests is the closed posture set size, also the
	// maximum advertised privacy key record count.
	MaxPrivacyKeyRecordDigests = 8
	// MaxPrivacyPostureResponseBytes is the encoded posture response cap.
	// A statement larger than the whole response cannot be valid.
	MaxPrivacyPostureResponseBytes = 8192
	// MaxPrivacyFramePlaintext bounds one frame. SPEC-049 §4.8 sets no frame
	// size; this matches the SPEC-041 encrypted request cap.
	MaxPrivacyFramePlaintext = MaxEncryptedRequestBytes
)

const (
	privacyGCMTagSize        = 16
	maxPrivacyFinalBytes     = 4096
	maxPrivacyKeyRecordBytes = 16 << 10
	privacyCodeCDHashLen     = 40
	privacyTeamIDLen         = 10
)

var ErrInvalidPrivacy = errors.New("relayblind: invalid privacy material")

type ResponseKeys struct {
	Key         [32]byte
	NoncePrefix [4]byte
}

// DeriveResponseKeys derives the response AEAD key and nonce prefix from the
// SPEC-041 transcript. aad is the envelope AAD, not a frame AAD.
func DeriveResponseKeys(shared, aad []byte) (ResponseKeys, error) {
	var zero [32]byte
	if len(shared) != len(zero) || subtle.ConstantTimeCompare(shared, zero[:]) == 1 {
		return ResponseKeys{}, fmt.Errorf("%w: all-zero X25519 shared secret", ErrInvalidEnvelope)
	}
	transcript := transcriptDigest(aad)
	key, err := hkdf.Key(sha256.New, shared, transcript[:], PrivacyResponseKeyLabel, len(zero))
	if err != nil {
		return ResponseKeys{}, err
	}
	prefix, err := hkdf.Key(sha256.New, shared, transcript[:], PrivacyResponseNoncePrefixLabel, len(ResponseKeys{}.NoncePrefix))
	if err != nil {
		return ResponseKeys{}, err
	}
	var out ResponseKeys
	copy(out.Key[:], key)
	copy(out.NoncePrefix[:], prefix)
	return out, nil
}

// DeriveBuyerResponseKeys derives response keys for this envelope. The buyer
// private key's public half must equal buyer_ephemeral_public_key.
func (e Envelope) DeriveBuyerResponseKeys(buyerPrivateKey, providerPublicKey []byte) (ResponseKeys, error) {
	privateKey, err := ecdh.X25519().NewPrivateKey(buyerPrivateKey)
	if err != nil {
		return ResponseKeys{}, fmt.Errorf("%w: buyer private key", ErrInvalidEnvelope)
	}
	if encodeBase64URL(privateKey.PublicKey().Bytes()) != e.BuyerEphemeralPublicKey {
		return ResponseKeys{}, fmt.Errorf("%w: ephemeral key mismatch", ErrInvalidEnvelope)
	}
	peer, err := ecdh.X25519().NewPublicKey(providerPublicKey)
	if err != nil {
		return ResponseKeys{}, fmt.Errorf("%w: provider public key", ErrInvalidEnvelope)
	}
	shared, err := privateKey.ECDH(peer)
	if err != nil {
		return ResponseKeys{}, fmt.Errorf("%w: invalid X25519 peer", ErrInvalidEnvelope)
	}
	aad, err := e.AAD()
	if err != nil {
		return ResponseKeys{}, err
	}
	return DeriveResponseKeys(shared, aad)
}

type PrivacyFrame struct {
	Object     string `json:"object"`
	Version    string `json:"version"`
	Seq        uint64 `json:"seq"`
	Final      bool   `json:"final"`
	Ciphertext string `json:"ciphertext"`
}

func ParsePrivacyFrame(raw []byte) (PrivacyFrame, error) {
	if len(raw) == 0 || len(raw) > maxPrivacyFrameJSON() {
		return PrivacyFrame{}, ErrInvalidPrivacy
	}
	var value PrivacyFrame
	if err := decodeClosed(raw, &value, []string{"object", "version", "seq", "final", "ciphertext"}); err != nil {
		return PrivacyFrame{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validateStructure(); err != nil {
		return PrivacyFrame{}, err
	}
	return value, nil
}

func (f PrivacyFrame) validateStructure() error {
	if f.Object != PrivacyFrameObject || f.Version != PrivacyResponseVersion || f.Seq >= 1<<32 {
		return fmt.Errorf("%w: frame", ErrInvalidPrivacy)
	}
	sealed, err := decodeBase64URL(f.Ciphertext)
	if err != nil || len(sealed) < privacyGCMTagSize || len(sealed) > MaxPrivacyFramePlaintext+privacyGCMTagSize {
		return fmt.Errorf("%w: frame ciphertext", ErrInvalidPrivacy)
	}
	return nil
}

func maxPrivacyFrameJSON() int {
	return (MaxPrivacyFramePlaintext+privacyGCMTagSize)*2 + 256
}

// relayPrivacyFrame is the relay-side frame check (SPEC-049-R015). It checks
// the closed outer shape and reads ciphertext only as base64url text, never
// decoding it. Buyers and providers use ParsePrivacyFrame.
func relayPrivacyFrame(raw []byte) (seq uint64, final bool, err error) {
	if len(raw) == 0 || len(raw) > maxPrivacyFrameJSON() {
		return 0, false, ErrInvalidPrivacy
	}
	var value PrivacyFrame
	if err := decodeClosed(raw, &value, []string{"object", "version", "seq", "final", "ciphertext"}); err != nil {
		return 0, false, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if value.Object != PrivacyFrameObject || value.Version != PrivacyResponseVersion || value.Seq >= 1<<32 {
		return 0, false, fmt.Errorf("%w: frame", ErrInvalidPrivacy)
	}
	if !relayCiphertextText(value.Ciphertext) {
		return 0, false, fmt.Errorf("%w: frame ciphertext", ErrInvalidPrivacy)
	}
	return value.Seq, value.Final, nil
}

// relayCiphertextText accepts exactly the texts ParsePrivacyFrame accepts:
// canonical unpadded base64url whose decoded length is inside the sealed
// frame bounds. The length follows from the text length, so nothing is
// decoded.
func relayCiphertextText(text string) bool {
	n := len(text)
	if n%4 == 1 {
		return false
	}
	sealedLen := n/4*3 + max(n%4-1, 0)
	if sealedLen < privacyGCMTagSize || sealedLen > MaxPrivacyFramePlaintext+privacyGCMTagSize {
		return false
	}
	var last int
	for i := 0; i < n; i++ {
		c := text[i]
		switch {
		case c >= 'A' && c <= 'Z':
			last = int(c - 'A')
		case c >= 'a' && c <= 'z':
			last = int(c-'a') + 26
		case c >= '0' && c <= '9':
			last = int(c-'0') + 52
		case c == '-':
			last = 62
		case c == '_':
			last = 63
		default:
			return false
		}
	}
	// A canonical encoding leaves the unused low bits of the last symbol zero.
	switch n % 4 {
	case 2:
		return last&0x0f == 0
	case 3:
		return last&0x03 == 0
	}
	return true
}

// ResponseAAD frames the SPEC-049 frame AAD. envelopeDigest and kid are the
// canonical base64url texts, not the decoded bytes.
func ResponseAAD(envelopeDigest, kid, requestID string, stream bool, seq uint64, final bool) []byte {
	var framed bytes.Buffer
	_ = writeFrame(&framed, []byte(PrivacyResponseVersion))
	_ = writeFrame(&framed, []byte(envelopeDigest))
	_ = writeFrame(&framed, []byte(kid))
	_ = writeFrame(&framed, []byte(requestID))
	writeBool(&framed, stream)
	writeU64(&framed, seq)
	writeBool(&framed, final)
	return framed.Bytes()
}

func SealFrame(keys ResponseKeys, envelopeDigest, kid, requestID string, stream bool, seq uint64, final bool, plaintext []byte) (PrivacyFrame, error) {
	if err := validateResponseContext(envelopeDigest, kid, requestID, seq); err != nil {
		return PrivacyFrame{}, err
	}
	if len(plaintext) > MaxPrivacyFramePlaintext {
		return PrivacyFrame{}, fmt.Errorf("%w: frame plaintext", ErrInvalidPrivacy)
	}
	aead, err := responseAEAD(keys)
	if err != nil {
		return PrivacyFrame{}, err
	}
	sealed := aead.Seal(nil, responseNonce(keys.NoncePrefix, seq), plaintext, ResponseAAD(envelopeDigest, kid, requestID, stream, seq, final))
	frame := PrivacyFrame{
		Object: PrivacyFrameObject, Version: PrivacyResponseVersion,
		Seq: seq, Final: final, Ciphertext: encodeBase64URL(sealed),
	}
	if err := frame.validateStructure(); err != nil {
		return PrivacyFrame{}, err
	}
	return frame, nil
}

func OpenFrame(keys ResponseKeys, envelopeDigest, kid, requestID string, stream bool, frame PrivacyFrame) ([]byte, error) {
	if err := validateResponseContext(envelopeDigest, kid, requestID, frame.Seq); err != nil {
		return nil, err
	}
	if err := frame.validateStructure(); err != nil {
		return nil, err
	}
	sealed, err := decodeBase64URL(frame.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("%w: frame ciphertext", ErrInvalidPrivacy)
	}
	aead, err := responseAEAD(keys)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, responseNonce(keys.NoncePrefix, frame.Seq), sealed, ResponseAAD(envelopeDigest, kid, requestID, stream, frame.Seq, frame.Final))
	if err != nil {
		return nil, fmt.Errorf("%w: frame authentication failed", ErrInvalidPrivacy)
	}
	return plaintext, nil
}

// ValidatePrivacyFrameSequence requires seq 0..n-1, exactly one final frame,
// and that final frame last. It does not decrypt.
func ValidatePrivacyFrameSequence(frames []PrivacyFrame) error {
	if len(frames) == 0 || uint64(len(frames)) >= 1<<32 {
		return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
	}
	finals := 0
	for i, frame := range frames {
		if err := frame.validateStructure(); err != nil {
			return err
		}
		if frame.Seq != uint64(i) {
			return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
		}
		if frame.Final {
			finals++
			if i != len(frames)-1 {
				return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
			}
		}
	}
	if finals != 1 {
		return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
	}
	return nil
}

// privacyUsageTokens is the only clear usage object a relay may forward.
type privacyUsageTokens struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	TotalTokens      int64 `json:"total_tokens"`
}

type privacyResponseBody struct {
	Object  string            `json:"object"`
	Version string            `json:"version"`
	Frames  []json.RawMessage `json:"frames"`
	Usage   json.RawMessage   `json:"usage"`
}

type privacyClearUsageChunk struct {
	Object  string          `json:"object"`
	Model   string          `json:"model"`
	Choices json.RawMessage `json:"choices"`
	Usage   json.RawMessage `json:"usage"`
}

// ValidatePrivacyResponseBody checks the closed non-stream privacy-response-v1
// envelope. It does not decode or decrypt ciphertext and does not rewrite the
// body.
func ValidatePrivacyResponseBody(raw []byte) error {
	var body privacyResponseBody
	if err := decodeClosed(raw, &body, []string{"object", "version", "frames", "usage"}); err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if body.Object != PrivacyResponseObject || body.Version != PrivacyResponseVersion {
		return fmt.Errorf("%w: privacy response", ErrInvalidPrivacy)
	}
	if len(body.Frames) == 0 {
		return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
	}
	for i, rawFrame := range body.Frames {
		seq, final, err := relayPrivacyFrame(rawFrame)
		if err != nil {
			return err
		}
		if seq != uint64(i) || final != (i == len(body.Frames)-1) {
			return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
		}
	}
	return validatePrivacyUsageObject(body.Usage)
}

func validatePrivacyUsageObject(raw []byte) error {
	var usage privacyUsageTokens
	if err := decodeClosed(raw, &usage, []string{"prompt_tokens", "completion_tokens", "total_tokens"}); err != nil {
		return fmt.Errorf("%w: usage", ErrInvalidPrivacy)
	}
	if usage.PromptTokens < 0 || usage.CompletionTokens < 0 || usage.TotalTokens < 0 {
		return fmt.Errorf("%w: usage", ErrInvalidPrivacy)
	}
	sum := usage.PromptTokens + usage.CompletionTokens
	if sum < usage.PromptTokens || sum != usage.TotalTokens {
		return fmt.Errorf("%w: usage", ErrInvalidPrivacy)
	}
	return nil
}

// validatePrivacyClearUsageChunk checks the closed clear usage chunk. Its
// model must be the reservation's canonical model.
func validatePrivacyClearUsageChunk(raw []byte, model string) error {
	var chunk privacyClearUsageChunk
	if err := decodeClosed(raw, &chunk, []string{"object", "model", "choices", "usage"}); err != nil {
		return fmt.Errorf("%w: usage chunk", ErrInvalidPrivacy)
	}
	if chunk.Object != "chat.completion.chunk" || !validModelID(chunk.Model) || chunk.Model != model || !bytes.Equal(bytes.TrimSpace(chunk.Choices), []byte("[]")) {
		return fmt.Errorf("%w: usage chunk", ErrInvalidPrivacy)
	}
	return validatePrivacyUsageObject(chunk.Usage)
}

// PrivacyStreamEvent is one accepted SSE data payload on a privacy stream.
type PrivacyStreamEvent int

const (
	PrivacyStreamFrame PrivacyStreamEvent = iota + 1
	PrivacyStreamUsage
	PrivacyStreamDone
)

// PrivacyStreamGate checks the SPEC-049 §4.8 stream shape one SSE data
// payload at a time. It does not decode, decrypt, or retain ciphertext.
type PrivacyStreamGate struct {
	// Model is the reservation's canonical model. The clear usage chunk must
	// carry exactly this model; an empty Model refuses every usage chunk.
	Model    string
	count    uint64
	sawFinal bool
	sawUsage bool
	sawDone  bool
}

// Observe accepts a privacy frame, the one clear usage chunk, or [DONE].
// Clear completion content and any other payload is refused.
func (g *PrivacyStreamGate) Observe(data string) (PrivacyStreamEvent, error) {
	if g == nil || g.sawDone {
		return 0, fmt.Errorf("%w: privacy stream", ErrInvalidPrivacy)
	}
	if data == "[DONE]" {
		if !g.sawUsage || !g.sawFinal || g.count == 0 {
			return 0, fmt.Errorf("%w: privacy stream", ErrInvalidPrivacy)
		}
		g.sawDone = true
		return PrivacyStreamDone, nil
	}
	if g.sawUsage {
		return 0, fmt.Errorf("%w: privacy stream", ErrInvalidPrivacy)
	}
	if seq, final, err := relayPrivacyFrame([]byte(data)); err == nil {
		if g.sawFinal || seq != g.count || g.count >= 1<<32 {
			return 0, fmt.Errorf("%w: privacy stream", ErrInvalidPrivacy)
		}
		g.count++
		g.sawFinal = final
		return PrivacyStreamFrame, nil
	}
	if !g.sawFinal || g.count == 0 {
		return 0, fmt.Errorf("%w: privacy stream", ErrInvalidPrivacy)
	}
	if err := validatePrivacyClearUsageChunk([]byte(data), g.Model); err != nil {
		return 0, err
	}
	g.sawUsage = true
	return PrivacyStreamUsage, nil
}

// Complete requires the final frame, the clear usage chunk, and [DONE].
func (g *PrivacyStreamGate) Complete() error {
	if g == nil || !g.sawDone {
		return fmt.Errorf("%w: privacy stream", ErrInvalidPrivacy)
	}
	return nil
}

func validateResponseContext(envelopeDigest, kid, requestID string, seq uint64) error {
	if _, err := decodeBase64URLFixed(envelopeDigest, sha256.Size); err != nil {
		return fmt.Errorf("%w: envelope digest", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(kid, 16); err != nil {
		return fmt.Errorf("%w: kid", ErrInvalidPrivacy)
	}
	if !visibleASCII(requestID, MaxIdentifierBytes) {
		return fmt.Errorf("%w: request id", ErrInvalidPrivacy)
	}
	if seq >= 1<<32 {
		return fmt.Errorf("%w: frame sequence", ErrInvalidPrivacy)
	}
	return nil
}

func responseAEAD(keys ResponseKeys) (cipher.AEAD, error) {
	block, err := aes.NewCipher(keys.Key[:])
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return aead, nil
}

func responseNonce(prefix [4]byte, seq uint64) []byte {
	var nonce [12]byte
	copy(nonce[:4], prefix[:])
	binary.BigEndian.PutUint64(nonce[4:], seq)
	return nonce[:]
}

func writeBool(dst *bytes.Buffer, value bool) {
	if value {
		writeU64(dst, 1)
		return
	}
	writeU64(dst, 0)
}

type PrivacyFinal struct {
	Version          string `json:"version"`
	Status           string `json:"status"`
	PromptTokens     int64  `json:"prompt_tokens"`
	CompletionTokens int64  `json:"completion_tokens"`
}

func (f PrivacyFinal) Marshal() ([]byte, error) {
	if err := f.validate(); err != nil {
		return nil, err
	}
	return json.Marshal(f)
}

func ParsePrivacyFinal(raw []byte) (PrivacyFinal, error) {
	if len(raw) == 0 || len(raw) > maxPrivacyFinalBytes {
		return PrivacyFinal{}, ErrInvalidPrivacy
	}
	var value PrivacyFinal
	if err := decodeClosed(raw, &value, []string{"version", "status", "prompt_tokens", "completion_tokens"}); err != nil {
		return PrivacyFinal{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validate(); err != nil {
		return PrivacyFinal{}, err
	}
	return value, nil
}

func (f PrivacyFinal) validate() error {
	if f.Version != PrivacyFinalVersion {
		return fmt.Errorf("%w: final version", ErrInvalidPrivacy)
	}
	switch f.Status {
	case PrivacyFinalStatusComplete, PrivacyFinalStatusError, PrivacyFinalStatusCancelled:
	default:
		return fmt.Errorf("%w: final status", ErrInvalidPrivacy)
	}
	if f.PromptTokens < 0 || f.CompletionTokens < 0 {
		return fmt.Errorf("%w: final usage", ErrInvalidPrivacy)
	}
	return nil
}

type PrivacyKeyAttestation struct {
	Version         string `json:"version"`
	KeyRecordDigest string `json:"key_record_digest"`
	PrivacyClass    string `json:"privacy_class"`
	Assurance       string `json:"assurance"`
	BinaryVersion   string `json:"binary_version"`
	CodeCDHash      string `json:"code_cdhash"`
	NotBeforeUnix   int64  `json:"not_before_unix"`
	ExpiresAtUnix   int64  `json:"expires_at_unix"`
}

// Framing is the length-prefixed domain string followed by the attestation
// fields. Strings are SPEC-041 strings; times are i64.
func (a PrivacyKeyAttestation) Framing() ([]byte, error) {
	if err := a.validate(); err != nil {
		return nil, err
	}
	var framed bytes.Buffer
	for _, value := range []string{PrivacyKeyAttestationDomain, a.Version, a.KeyRecordDigest, a.PrivacyClass, a.Assurance, a.BinaryVersion, a.CodeCDHash} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	writeI64(&framed, a.NotBeforeUnix)
	writeI64(&framed, a.ExpiresAtUnix)
	return framed.Bytes(), nil
}

// Verify checks the attestation signature and its binding to record and pin.
// It does not apply the pin or record wall-clock window; callers with a clock
// also call IdentityPin.Verify and KeyRecord.Verify.
func (a PrivacyKeyAttestation) Verify(pin IdentityPin, signatureB64 string, record KeyRecord) error {
	if err := a.validate(); err != nil {
		return err
	}
	if err := record.validateStructure(); err != nil {
		return err
	}
	if a.KeyRecordDigest != record.KeyRecordDigest || a.NotBeforeUnix != record.NotBeforeUnix || a.ExpiresAtUnix != record.ExpiresAtUnix {
		return fmt.Errorf("%w: key attestation binding", ErrInvalidPrivacy)
	}
	if err := pin.validateStructure(); err != nil {
		return err
	}
	if pin.Revoked {
		return fmt.Errorf("%w: identity pin revoked", ErrInvalidPrivacy)
	}
	if subtle.ConstantTimeCompare([]byte(record.IdentityFingerprint), []byte(pin.Fingerprint)) != 1 {
		return fmt.Errorf("%w: identity fingerprint", ErrInvalidPrivacy)
	}
	for _, model := range record.Models {
		if !contains(pin.Models, model) {
			return fmt.Errorf("%w: model outside pin scope", ErrInvalidPrivacy)
		}
	}
	if !contains(pin.EndpointFamilies, EndpointChatCompletions) {
		return fmt.Errorf("%w: endpoint outside pin scope", ErrInvalidPrivacy)
	}
	pub, _ := decodeBase64URLFixed(pin.IdentityPublicKey, ed25519.PublicKeySize)
	signed, err := record.SignedFraming()
	if err != nil {
		return err
	}
	recordSig, err := decodeBase64URLFixed(record.Signature, ed25519.SignatureSize)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(pub), signed, recordSig) {
		return fmt.Errorf("%w: key record signature", ErrInvalidPrivacy)
	}
	attestationSig, err := decodeBase64URLFixed(signatureB64, ed25519.SignatureSize)
	if err != nil {
		return fmt.Errorf("%w: key attestation signature", ErrInvalidPrivacy)
	}
	framing, err := a.Framing()
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), framing, attestationSig) {
		return fmt.Errorf("%w: key attestation signature", ErrInvalidPrivacy)
	}
	return nil
}

func (a PrivacyKeyAttestation) validate() error {
	if a.Version != PrivacyKeyAttestationVersion || a.PrivacyClass != PrivacyClassV1 || a.Assurance != PrivacyAssurance {
		return fmt.Errorf("%w: key attestation", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(a.KeyRecordDigest, sha256.Size); err != nil {
		return fmt.Errorf("%w: key attestation digest", ErrInvalidPrivacy)
	}
	if !visibleASCII(a.BinaryVersion, MaxIdentifierBytes) || !validCDHash(a.CodeCDHash) {
		return fmt.Errorf("%w: key attestation code identity", ErrInvalidPrivacy)
	}
	if a.NotBeforeUnix < 0 || a.ExpiresAtUnix <= a.NotBeforeUnix || a.ExpiresAtUnix-a.NotBeforeUnix > MaxPrivacyKeyLifetimeSeconds {
		return fmt.Errorf("%w: key attestation lifetime", ErrInvalidPrivacy)
	}
	return nil
}

type PrivacyKeyRecord struct {
	KeyRecord   KeyRecord             `json:"key_record"`
	Attestation PrivacyKeyAttestation `json:"privacy_key_attestation"`
	Signature   string                `json:"signature"`
}

func ParsePrivacyKeyRecord(raw []byte) (PrivacyKeyRecord, error) {
	if len(raw) == 0 || len(raw) > maxPrivacyKeyRecordBytes {
		return PrivacyKeyRecord{}, ErrInvalidPrivacy
	}
	var value PrivacyKeyRecord
	if err := decodeClosed(raw, &value, []string{"key_record", "privacy_key_attestation", "signature"}); err != nil {
		return PrivacyKeyRecord{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.KeyRecord.validateStructure(); err != nil {
		return PrivacyKeyRecord{}, err
	}
	if err := value.Attestation.validate(); err != nil {
		return PrivacyKeyRecord{}, err
	}
	if value.Attestation.KeyRecordDigest != value.KeyRecord.KeyRecordDigest || value.Attestation.NotBeforeUnix != value.KeyRecord.NotBeforeUnix || value.Attestation.ExpiresAtUnix != value.KeyRecord.ExpiresAtUnix {
		return PrivacyKeyRecord{}, fmt.Errorf("%w: key attestation binding", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(value.Signature, ed25519.SignatureSize); err != nil {
		return PrivacyKeyRecord{}, fmt.Errorf("%w: key attestation signature", ErrInvalidPrivacy)
	}
	return value, nil
}

type PostureStatement struct {
	Version                 string   `json:"version"`
	PrivacyClass            string   `json:"privacy_class"`
	ProviderID              string   `json:"provider_id"`
	AssignedSession         string   `json:"assigned_session"`
	Nonce                   string   `json:"nonce"`
	Sequence                uint64   `json:"sequence"`
	IssuedAtUnix            int64    `json:"issued_at_unix"`
	BinaryVersion           string   `json:"binary_version"`
	CodeCDHash              string   `json:"code_cdhash"`
	TeamID                  string   `json:"team_id"`
	SigningIdentifier       string   `json:"signing_identifier"`
	HardenedRuntime         bool     `json:"hardened_runtime"`
	LibraryValidation       bool     `json:"library_validation"`
	GetTaskAllow            bool     `json:"get_task_allow"`
	CSDebugged              bool     `json:"cs_debugged"`
	PTraced                 bool     `json:"p_traced"`
	PTDenyAttachApplied     bool     `json:"pt_deny_attach_applied"`
	CoreDumpsDisabled       bool     `json:"core_dumps_disabled"`
	SIPEnabled              bool     `json:"sip_enabled"`
	RuntimeSource           string   `json:"runtime_source"`
	DiagnosticEnvClear      bool     `json:"diagnostic_env_clear"`
	KVDiskTierDisabled      bool     `json:"kv_disk_tier_disabled"`
	SEKeyBackend            string   `json:"se_key_backend"`
	PrivacyKeyRecordDigests []string `json:"privacy_key_record_digests"`
}

// Framing is the length-prefixed posture domain followed by §4.3 fields.
// The digest set must already be strictly ascending; it is not sorted here.
// Boolean policy in SPEC-049-R006 is not applied: a signed failing posture
// has to stay parseable so the coordinator can quarantine it.
func (s PostureStatement) Framing() ([]byte, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	nonce, err := decodeBase64URLFixed(s.Nonce, 32)
	if err != nil {
		return nil, err
	}
	var framed bytes.Buffer
	for _, value := range []string{PrivacyPostureDomain, s.Version, s.PrivacyClass, s.ProviderID, s.AssignedSession} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	if err := writeFrame(&framed, nonce); err != nil {
		return nil, err
	}
	writeU64(&framed, s.Sequence)
	writeI64(&framed, s.IssuedAtUnix)
	for _, value := range []string{s.BinaryVersion, s.CodeCDHash, s.TeamID, s.SigningIdentifier} {
		if err := writeFrame(&framed, []byte(value)); err != nil {
			return nil, err
		}
	}
	for _, value := range []bool{s.HardenedRuntime, s.LibraryValidation, s.GetTaskAllow, s.CSDebugged, s.PTraced, s.PTDenyAttachApplied, s.CoreDumpsDisabled, s.SIPEnabled} {
		writeBool(&framed, value)
	}
	if err := writeFrame(&framed, []byte(s.RuntimeSource)); err != nil {
		return nil, err
	}
	writeBool(&framed, s.DiagnosticEnvClear)
	writeBool(&framed, s.KVDiskTierDisabled)
	if err := writeFrame(&framed, []byte(s.SEKeyBackend)); err != nil {
		return nil, err
	}
	if err := writeArray(&framed, s.PrivacyKeyRecordDigests); err != nil {
		return nil, err
	}
	return framed.Bytes(), nil
}

func ParsePostureStatement(raw []byte) (PostureStatement, error) {
	if len(raw) == 0 || len(raw) > MaxPrivacyPostureResponseBytes {
		return PostureStatement{}, ErrInvalidPrivacy
	}
	var value PostureStatement
	fields := []string{
		"version", "privacy_class", "provider_id", "assigned_session", "nonce", "sequence", "issued_at_unix",
		"binary_version", "code_cdhash", "team_id", "signing_identifier", "hardened_runtime", "library_validation",
		"get_task_allow", "cs_debugged", "p_traced", "pt_deny_attach_applied", "core_dumps_disabled", "sip_enabled",
		"runtime_source", "diagnostic_env_clear", "kv_disk_tier_disabled", "se_key_backend", "privacy_key_record_digests",
	}
	if err := decodeClosed(raw, &value, fields); err != nil {
		return PostureStatement{}, fmt.Errorf("%w: %v", ErrInvalidPrivacy, err)
	}
	if err := value.validate(); err != nil {
		return PostureStatement{}, err
	}
	return value, nil
}

func (s PostureStatement) validate() error {
	if s.Version != PrivacyPostureVersion || s.PrivacyClass != PrivacyClassV1 || s.RuntimeSource != PrivacyRuntimeSource {
		return fmt.Errorf("%w: posture identity", ErrInvalidPrivacy)
	}
	if !visibleASCII(s.ProviderID, MaxIdentifierBytes) || !visibleASCII(s.AssignedSession, MaxIdentifierBytes) {
		return fmt.Errorf("%w: posture session", ErrInvalidPrivacy)
	}
	if _, err := decodeBase64URLFixed(s.Nonce, 32); err != nil {
		return fmt.Errorf("%w: posture nonce", ErrInvalidPrivacy)
	}
	if !visibleASCII(s.BinaryVersion, MaxIdentifierBytes) || !validCDHash(s.CodeCDHash) || !validTeamID(s.TeamID) || !visibleASCII(s.SigningIdentifier, MaxIdentifierBytes) {
		return fmt.Errorf("%w: posture code identity", ErrInvalidPrivacy)
	}
	if s.SEKeyBackend != PrivacySEBackendFile && s.SEKeyBackend != PrivacySEBackendKeychain {
		return fmt.Errorf("%w: posture key backend", ErrInvalidPrivacy)
	}
	return validPrivacyDigestSet(s.PrivacyKeyRecordDigests)
}

func validPrivacyDigestSet(values []string) error {
	if len(values) > MaxPrivacyKeyRecordDigests {
		return fmt.Errorf("%w: privacy key digest set", ErrInvalidPrivacy)
	}
	for i, value := range values {
		if _, err := decodeBase64URLFixed(value, sha256.Size); err != nil {
			return fmt.Errorf("%w: privacy key digest", ErrInvalidPrivacy)
		}
		if i > 0 && values[i] <= values[i-1] {
			return fmt.Errorf("%w: privacy key digest set", ErrInvalidPrivacy)
		}
	}
	return nil
}

func validCDHash(value string) bool {
	if len(value) != privacyCodeCDHashLen {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func validTeamID(value string) bool {
	if len(value) != privacyTeamIDLen {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func (r ReservationResponse) privacyExtensionPresent() bool {
	return r.PrivacyClass != "" || r.PrivacyAssurance != "" || r.PrivacyKeyAttestation != nil || r.PrivacyKeyAttestationSignature != "" || r.PrivacyPostureVerifiedAtUnix != 0
}

func (r ReservationResponse) validatePrivacyExtension() error {
	if r.PrivacyClass != PrivacyClassV1 || r.PrivacyAssurance != PrivacyAssurance || r.PrivacyKeyAttestation == nil || r.PrivacyPostureVerifiedAtUnix <= 0 {
		return ErrInvalidReservation
	}
	if _, err := decodeBase64URLFixed(r.PrivacyKeyAttestationSignature, ed25519.SignatureSize); err != nil {
		return ErrInvalidReservation
	}
	attestation := *r.PrivacyKeyAttestation
	if err := attestation.validate(); err != nil {
		return ErrInvalidReservation
	}
	if attestation.KeyRecordDigest != r.KeyRecordDigest || attestation.KeyRecordDigest != r.KeyRecord.KeyRecordDigest || attestation.NotBeforeUnix != r.KeyRecord.NotBeforeUnix || attestation.ExpiresAtUnix != r.KeyRecord.ExpiresAtUnix {
		return ErrInvalidReservation
	}
	return nil
}
