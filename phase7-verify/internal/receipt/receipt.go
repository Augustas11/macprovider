// Package receipt parses and verifies SPEC-015 receipt headers.
package receipt

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
)

// Tuple is the seven-field signed payload from SPEC-015 section 3.1.
type Tuple struct {
	ModelID        string `json:"model_id"`
	PromptHash     string `json:"prompt_hash"`
	OutputHash     string `json:"output_hash"`
	ProviderPubkey string `json:"provider_pubkey"`
	TTFTms         int64  `json:"ttft_ms"`
	TokensOut      int64  `json:"tokens_out"`
	UnixTS         int64  `json:"unix_ts"`
}

// Parsed contains the decoded receipt header and the raw signed bytes.
type Parsed struct {
	Tuple       Tuple
	TupleRaw    []byte
	Signature   []byte
	HeaderValue string
}

var (
	ErrHeaderShape     = errors.New("header value does not contain exactly one '.' separator")
	ErrBase64Decode    = errors.New("base64 decode failed")
	ErrSigLength       = errors.New("signature is not exactly 64 bytes after decode")
	ErrPubkeyLength    = errors.New("pubkey is not exactly 32 bytes")
	ErrTupleJSON       = errors.New("tuple JSON parse failed or contains non-JCS bytes")
	ErrTupleMissingKey = errors.New("tuple missing required key")
	ErrTupleExtraKey   = errors.New("tuple contains unexpected extra key")
	ErrTupleWrongType  = errors.New("tuple field has wrong type")
	ErrSignatureFailed = errors.New("ed25519 signature verification failed")
)

var (
	promptHashPattern     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	providerPubkeyPattern = regexp.MustCompile(`^[A-Za-z0-9+/]{43}=$`)
	// base64SegmentPattern: pre-decode allowlist for header base64 segments.
	// Rejects CR/LF/whitespace/control characters that the stdlib base64 decoder
	// would silently strip. SPEC-015 §3.4 ("No whitespace, no other delimiters,
	// no trailing characters") forbids these. The tuple segment is variable
	// length but MUST be a multiple of 4 with correct padding placement;
	// validation is applied per-segment in validateBase64Segment.
	base64SegmentPattern = regexp.MustCompile(`^[A-Za-z0-9+/]*={0,2}$`)
	requiredTupleKeys    = []string{
		"model_id",
		"prompt_hash",
		"output_hash",
		"provider_pubkey",
		"ttft_ms",
		"tokens_out",
		"unix_ts",
	}
)

// Parse decodes a SPEC-015 X-MacProvider-Receipt header.
//
// The wire format is base64(JCS(tuple)) + "." + base64(signature). Parse
// validates the header shape, base64 envelopes, 64-byte signature length, and
// tuple JSON shape. It does not verify the signature.
func Parse(headerValue string) (Parsed, error) {
	dot := strings.IndexByte(headerValue, '.')
	if dot <= 0 || dot == len(headerValue)-1 {
		return Parsed{}, ErrHeaderShape
	}

	tuplePart := headerValue[:dot]
	sigPart := headerValue[dot+1:]
	if strings.IndexByte(sigPart, '.') >= 0 {
		return Parsed{}, ErrHeaderShape
	}

	// Pre-decode segment validation. The stdlib base64 decoder silently strips
	// CR and LF (and ignores other whitespace under some configurations); SPEC-015
	// §3.4 forbids ANY whitespace in the wire value, so we MUST reject those
	// bytes before they ever reach DecodeString.
	if err := validateBase64Segment(tuplePart); err != nil {
		return Parsed{}, fmt.Errorf("%w: tuple: %v", ErrBase64Decode, err)
	}
	// Signature segment must be exactly 88 chars (the base64-encoded length of
	// 64 raw bytes with standard padding). Reject other lengths early so we get
	// a clean ErrSigLength rather than a confusing decode failure.
	if len(sigPart) != ed25519SignatureBase64Len {
		return Parsed{}, fmt.Errorf("%w: signature segment length %d, want %d", ErrSigLength, len(sigPart), ed25519SignatureBase64Len)
	}
	if err := validateBase64Segment(sigPart); err != nil {
		return Parsed{}, fmt.Errorf("%w: signature: %v", ErrBase64Decode, err)
	}

	tupleRaw, err := base64.StdEncoding.DecodeString(tuplePart)
	if err != nil {
		return Parsed{}, fmt.Errorf("%w: tuple", ErrBase64Decode)
	}
	signature, err := base64.StdEncoding.DecodeString(sigPart)
	if err != nil {
		return Parsed{}, fmt.Errorf("%w: signature", ErrBase64Decode)
	}
	if len(signature) != ed25519.SignatureSize {
		return Parsed{}, fmt.Errorf("%w: got %d bytes", ErrSigLength, len(signature))
	}

	tuple, err := parseTuple(tupleRaw)
	if err != nil {
		return Parsed{}, err
	}

	return Parsed{
		Tuple:       tuple,
		TupleRaw:    tupleRaw,
		Signature:   signature,
		HeaderValue: headerValue,
	}, nil
}

// Verify checks parsed.TupleRaw against parsed.Signature using pubkey.
//
// The tuple bytes are forwarded exactly as decoded from the header. They are
// not re-canonicalized, because the provider signed the canonicalizer output
// bytes and verification must preserve that byte identity.
func Verify(parsed Parsed, pubkey []byte) error {
	if len(pubkey) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: got %d bytes", ErrPubkeyLength, len(pubkey))
	}
	if len(parsed.Signature) != ed25519.SignatureSize {
		return ErrSignatureFailed
	}
	if !ed25519.Verify(ed25519.PublicKey(pubkey), parsed.TupleRaw, parsed.Signature) {
		return ErrSignatureFailed
	}
	return nil
}

// ParsePubkey decodes a standard padded base64 ed25519 public key.
func ParsePubkey(b64 string) ([]byte, error) {
	pubkey, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("%w: pubkey", ErrBase64Decode)
	}
	if len(pubkey) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: got %d bytes", ErrPubkeyLength, len(pubkey))
	}
	return pubkey, nil
}

func parseTuple(raw []byte) (Tuple, error) {
	if len(raw) == 0 || !bytes.Equal(raw, bytes.TrimSpace(raw)) {
		return Tuple{}, ErrTupleJSON
	}

	fields, err := decodeTopLevelObject(raw)
	if err != nil {
		return Tuple{}, err
	}
	if len(fields) != len(requiredTupleKeys) {
		for key := range fields {
			if !isRequiredTupleKey(key) {
				return Tuple{}, fmt.Errorf("%w: %s", ErrTupleExtraKey, key)
			}
		}
		for _, key := range requiredTupleKeys {
			if _, ok := fields[key]; !ok {
				return Tuple{}, fmt.Errorf("%w: %s", ErrTupleMissingKey, key)
			}
		}
	}
	for key := range fields {
		if !isRequiredTupleKey(key) {
			return Tuple{}, fmt.Errorf("%w: %s", ErrTupleExtraKey, key)
		}
	}
	for _, key := range requiredTupleKeys {
		if _, ok := fields[key]; !ok {
			return Tuple{}, fmt.Errorf("%w: %s", ErrTupleMissingKey, key)
		}
	}

	var tuple Tuple
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	if err := decoder.Decode(&tuple); err != nil {
		return Tuple{}, fmt.Errorf("%w: %v", ErrTupleWrongType, err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return Tuple{}, ErrTupleJSON
	}
	if err := validateTuple(tuple); err != nil {
		return Tuple{}, err
	}
	return tuple, nil
}

func decodeTopLevelObject(raw []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()

	token, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrTupleJSON, err)
	}
	delim, ok := token.(json.Delim)
	if !ok || delim != '{' {
		return nil, ErrTupleJSON
	}

	fields := make(map[string]json.RawMessage, len(requiredTupleKeys))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrTupleJSON, err)
		}
		key, ok := token.(string)
		if !ok {
			return nil, ErrTupleJSON
		}
		if _, exists := fields[key]; exists {
			return nil, fmt.Errorf("%w: duplicate key %s", ErrTupleJSON, key)
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrTupleJSON, err)
		}
		fields[key] = value
	}

	token, err = decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrTupleJSON, err)
	}
	delim, ok = token.(json.Delim)
	if !ok || delim != '}' {
		return nil, ErrTupleJSON
	}

	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, ErrTupleJSON
	}
	return fields, nil
}

// ed25519SignatureBase64Len is the exact length of a 64-byte ed25519 signature
// encoded as standard padded base64. SPEC-015 §3.4 pins the wire signature
// segment to this exact length; reject anything else early.
const ed25519SignatureBase64Len = 88

// validateBase64Segment rejects any byte outside the standard base64 alphabet
// plus padding. SPEC-015 §3.4 forbids whitespace; the stdlib base64 decoder
// silently strips CR and LF, so we MUST pre-validate to enforce the spec
// invariant. Also requires the total length to be a positive multiple of 4
// (canonical padding placement).
func validateBase64Segment(segment string) error {
	if len(segment) == 0 {
		return fmt.Errorf("segment empty")
	}
	if len(segment)%4 != 0 {
		return fmt.Errorf("segment length %d is not a multiple of 4", len(segment))
	}
	if !base64SegmentPattern.MatchString(segment) {
		// Identify which byte is offending so the error message is actionable.
		for i, b := range []byte(segment) {
			switch {
			case b >= 'A' && b <= 'Z':
			case b >= 'a' && b <= 'z':
			case b >= '0' && b <= '9':
			case b == '+' || b == '/':
			case b == '=':
				// '=' is only valid in the trailing padding; the overall
				// pattern enforces "any A-Za-z0-9+/ then 0-2 trailing ="
				// so a mid-segment '=' fails here too.
				return fmt.Errorf("invalid '=' at byte %d (not trailing padding)", i)
			default:
				return fmt.Errorf("invalid base64 byte 0x%02x at offset %d", b, i)
			}
		}
		// Pattern didn't match but the byte-wise scan found no specific issue —
		// likely a padding-placement violation.
		return fmt.Errorf("base64 padding placement invalid")
	}
	return nil
}

// isASCII reports whether s contains only ASCII bytes (0x00-0x7F).
// SPEC-015 §3.1 requires model_id to be ASCII-only and verifiers MUST reject
// any receipt whose model_id contains a non-ASCII byte.
func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

func validateTuple(tuple Tuple) error {
	if tuple.ModelID == "" {
		return fmt.Errorf("%w: model_id (empty)", ErrTupleWrongType)
	}
	if !isASCII(tuple.ModelID) {
		// SPEC-015 §3.1: model_id is ASCII-only; verifier MUST reject
		// any tuple whose model_id contains a non-ASCII byte.
		return fmt.Errorf("%w: model_id contains non-ASCII byte", ErrTupleWrongType)
	}
	if !promptHashPattern.MatchString(tuple.PromptHash) {
		return fmt.Errorf("%w: prompt_hash", ErrTupleWrongType)
	}
	if !promptHashPattern.MatchString(tuple.OutputHash) {
		return fmt.Errorf("%w: output_hash", ErrTupleWrongType)
	}
	if !providerPubkeyPattern.MatchString(tuple.ProviderPubkey) {
		return fmt.Errorf("%w: provider_pubkey", ErrTupleWrongType)
	}
	if _, err := ParsePubkey(tuple.ProviderPubkey); err != nil {
		return fmt.Errorf("%w: provider_pubkey", ErrTupleWrongType)
	}
	if tuple.TTFTms < 0 {
		return fmt.Errorf("%w: ttft_ms", ErrTupleWrongType)
	}
	if tuple.TokensOut < 0 {
		return fmt.Errorf("%w: tokens_out", ErrTupleWrongType)
	}
	if tuple.UnixTS < 0 {
		return fmt.Errorf("%w: unix_ts", ErrTupleWrongType)
	}
	return nil
}

func isRequiredTupleKey(key string) bool {
	for _, required := range requiredTupleKeys {
		if key == required {
			return true
		}
	}
	return false
}
