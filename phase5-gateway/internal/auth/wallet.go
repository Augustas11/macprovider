package auth

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

const (
	WalletProofVersion     = "wallet-session-proof-v1"
	WalletRequestVersion   = "wallet-session-request-v1"
	WalletNamespaceEd25519 = "ed25519"
)

var (
	ErrWalletAlgorithmUnsupported = errors.New("wallet_algorithm_unsupported")
	ErrWalletSignatureInvalid     = errors.New("wallet_signature_invalid")
	ErrWalletSignatureStale       = errors.New("wallet_session_signature_stale")
	ErrWalletRequestIDInvalid     = errors.New("wallet_session_request_id_required")
	ErrWalletCanonicalInvalid     = errors.New("wallet_canonical_invalid")
)

type WalletProof struct {
	Version            string
	ChallengeID        string
	Audience           string
	AccountID          string
	WalletNamespace    string
	WalletPublicKey    string
	SessionPublicKey   string
	Nonce              string
	ExpiresAtUnix      int64
	PerRequestTokenCap int64
	TotalTokenCap      int64
	ModelAllowlist     []string
}

type WalletChallengeRequest struct {
	WalletNamespace    string
	WalletPublicKey    string
	SessionPublicKey   string
	ExpiresAtUnix      int64
	PerRequestTokenCap int64
	TotalTokenCap      int64
	ModelAllowlist     []string
}

type WalletRequestSignatureObject struct {
	Version               string
	SessionID             string
	Method                string
	CanonicalRoute        string
	RequestID             string
	RawBodySHA256         string
	SemanticHeadersSHA256 string
	TimestampUnix         int64
}

type WalletRegistrationRequest struct {
	Proof           WalletProof
	WalletSignature string
}

var unsignedIntegerJSON = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

func DecodeWalletProofJSON(raw []byte) (WalletProof, []byte, error) {
	if err := validateClosedJSON(raw, map[string]map[string]bool{
		"": {
			"version": true, "challenge_id": true, "aud": true, "account_id": true,
			"wallet_namespace": true, "wallet_public_key": true, "session_public_key": true,
			"nonce": true, "expires_at_unix": true, "per_request_token_cap": true,
			"total_token_cap": true, "model_allowlist": true,
		},
	}); err != nil {
		return WalletProof{}, nil, err
	}
	var decoded map[string]any
	if err := decodeJSONUseNumber(raw, &decoded); err != nil {
		return WalletProof{}, nil, fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
	}
	proof, err := walletProofFromMap(decoded)
	if err != nil {
		return WalletProof{}, nil, err
	}
	canonical, err := CanonicalWalletProofBytes(proof)
	if err != nil {
		return WalletProof{}, nil, err
	}
	return proof, canonical, nil
}

func DecodeWalletChallengeRequestJSON(raw []byte) (WalletChallengeRequest, error) {
	if err := validateClosedJSON(raw, map[string]map[string]bool{
		"": {
			"wallet_namespace": true, "wallet_public_key": true, "session_public_key": true,
			"expires_at_unix": true, "per_request_token_cap": true, "total_token_cap": true,
			"model_allowlist": true,
		},
	}); err != nil {
		return WalletChallengeRequest{}, err
	}
	var decoded map[string]any
	if err := decodeJSONUseNumber(raw, &decoded); err != nil {
		return WalletChallengeRequest{}, fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
	}
	req, err := walletChallengeRequestFromMap(decoded)
	if err != nil {
		return WalletChallengeRequest{}, err
	}
	if err := validateWalletChallengeRequest(req); err != nil {
		return WalletChallengeRequest{}, err
	}
	return req, nil
}

func DecodeWalletRegistrationRequestJSON(raw []byte) (WalletRegistrationRequest, []byte, error) {
	if err := validateClosedJSON(raw, map[string]map[string]bool{
		"": {"proof": true, "wallet_signature": true},
		"proof": {
			"version": true, "challenge_id": true, "aud": true, "account_id": true,
			"wallet_namespace": true, "wallet_public_key": true, "session_public_key": true,
			"nonce": true, "expires_at_unix": true, "per_request_token_cap": true,
			"total_token_cap": true, "model_allowlist": true,
		},
	}); err != nil {
		return WalletRegistrationRequest{}, nil, err
	}
	var decoded map[string]any
	if err := decodeJSONUseNumber(raw, &decoded); err != nil {
		return WalletRegistrationRequest{}, nil, fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
	}
	proofMap, ok := decoded["proof"].(map[string]any)
	if !ok {
		return WalletRegistrationRequest{}, nil, ErrWalletCanonicalInvalid
	}
	proof, err := walletProofFromMap(proofMap)
	if err != nil {
		return WalletRegistrationRequest{}, nil, err
	}
	signature, ok := decoded["wallet_signature"].(string)
	if !ok || signature == "" {
		return WalletRegistrationRequest{}, nil, ErrWalletCanonicalInvalid
	}
	if _, err := DecodeBase64URLFixed(signature, ed25519.SignatureSize); err != nil {
		return WalletRegistrationRequest{}, nil, err
	}
	canonical, err := CanonicalWalletProofBytes(proof)
	if err != nil {
		return WalletRegistrationRequest{}, nil, err
	}
	return WalletRegistrationRequest{Proof: proof, WalletSignature: signature}, canonical, nil
}

func CanonicalWalletProofBytes(proof WalletProof) ([]byte, error) {
	if err := validateWalletProof(proof); err != nil {
		return nil, err
	}
	return canonicalJSON(walletProofJCS(proof))
}

func VerifyWalletProof(proof WalletProof, signature string) error {
	if proof.WalletNamespace != WalletNamespaceEd25519 {
		return ErrWalletAlgorithmUnsupported
	}
	publicKey, err := DecodeBase64URLFixed(proof.WalletPublicKey, ed25519.PublicKeySize)
	if err != nil {
		return fmt.Errorf("%w: wallet public key", ErrWalletSignatureInvalid)
	}
	sig, err := DecodeBase64URLFixed(signature, ed25519.SignatureSize)
	if err != nil {
		return fmt.Errorf("%w: signature", ErrWalletSignatureInvalid)
	}
	canonical, err := CanonicalWalletProofBytes(proof)
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(publicKey), canonical, sig) {
		return ErrWalletSignatureInvalid
	}
	return nil
}

func DecodeWalletRequestSignatureJSON(raw []byte) (WalletRequestSignatureObject, []byte, error) {
	if err := validateClosedJSON(raw, map[string]map[string]bool{
		"": {
			"version": true, "session_id": true, "method": true, "canonical_route": true,
			"request_id": true, "raw_body_sha256": true, "semantic_headers_sha256": true,
			"timestamp_unix": true,
		},
	}); err != nil {
		return WalletRequestSignatureObject{}, nil, err
	}
	var decoded map[string]any
	if err := decodeJSONUseNumber(raw, &decoded); err != nil {
		return WalletRequestSignatureObject{}, nil, fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
	}
	obj, err := walletRequestFromMap(decoded)
	if err != nil {
		return WalletRequestSignatureObject{}, nil, err
	}
	canonical, err := CanonicalWalletRequestBytes(obj)
	if err != nil {
		return WalletRequestSignatureObject{}, nil, err
	}
	return obj, canonical, nil
}

func NewWalletRequestSignatureObject(sessionID, method, canonicalRoute, requestID string, rawBody []byte, headers http.Header, timestampUnix int64) (WalletRequestSignatureObject, error) {
	bodyHash := sha256.Sum256(rawBody)
	headerHash, err := SemanticHeadersSHA256Base64URL(canonicalRoute, headers)
	if err != nil {
		return WalletRequestSignatureObject{}, err
	}
	return WalletRequestSignatureObject{
		Version:               WalletRequestVersion,
		SessionID:             sessionID,
		Method:                strings.ToUpper(method),
		CanonicalRoute:        canonicalRoute,
		RequestID:             requestID,
		RawBodySHA256:         base64.RawURLEncoding.EncodeToString(bodyHash[:]),
		SemanticHeadersSHA256: headerHash,
		TimestampUnix:         timestampUnix,
	}, nil
}

func CanonicalWalletRequestBytes(obj WalletRequestSignatureObject) ([]byte, error) {
	if err := validateWalletRequest(obj); err != nil {
		return nil, err
	}
	return canonicalJSON(walletRequestJCS(obj))
}

func VerifyWalletRequestSignature(obj WalletRequestSignatureObject, signature string, sessionPublicKey []byte, now time.Time, maxAge, maxFutureSkew time.Duration) error {
	if err := ValidateWalletRequestFreshness(obj.TimestampUnix, now, maxAge, maxFutureSkew); err != nil {
		return err
	}
	if len(sessionPublicKey) != ed25519.PublicKeySize {
		return ErrWalletSignatureInvalid
	}
	sig, err := DecodeBase64URLFixed(signature, ed25519.SignatureSize)
	if err != nil {
		return fmt.Errorf("%w: signature", ErrWalletSignatureInvalid)
	}
	canonical, err := CanonicalWalletRequestBytes(obj)
	if err != nil {
		return err
	}
	if !ed25519.Verify(ed25519.PublicKey(sessionPublicKey), canonical, sig) {
		return ErrWalletSignatureInvalid
	}
	return nil
}

func ValidateWalletRequestFreshness(timestampUnix int64, now time.Time, maxAge, maxFutureSkew time.Duration) error {
	if timestampUnix < 0 || maxAge < 0 || maxFutureSkew < 0 {
		return ErrWalletSignatureStale
	}
	ts := time.Unix(timestampUnix, 0).UTC()
	now = now.UTC()
	if ts.Before(now.Add(-maxAge)) || ts.After(now.Add(maxFutureSkew)) {
		return ErrWalletSignatureStale
	}
	return nil
}

func ValidateUUIDv4RequestID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i := 0; i < len(id); i++ {
		ch := id[i]
		switch i {
		case 8, 13, 18, 23:
			if ch != '-' {
				return false
			}
		default:
			if !isLowerHex(ch) {
				return false
			}
		}
	}
	return id[14] == '4' && (id[19] == '8' || id[19] == '9' || id[19] == 'a' || id[19] == 'b')
}

func DecodeBase64URL(value string) ([]byte, error) {
	if value == "" || strings.Contains(value, "=") {
		return nil, ErrWalletCanonicalInvalid
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return nil, ErrWalletCanonicalInvalid
	}
	if base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, ErrWalletCanonicalInvalid
	}
	return decoded, nil
}

func DecodeBase64URLFixed(value string, size int) ([]byte, error) {
	decoded, err := DecodeBase64URL(value)
	if err != nil {
		return nil, err
	}
	if len(decoded) != size {
		return nil, ErrWalletCanonicalInvalid
	}
	return decoded, nil
}

func WalletFingerprint(secret []byte, walletNamespace, walletPublicKey string) (string, error) {
	if len(secret) == 0 || walletNamespace == "" {
		return "", ErrWalletCanonicalInvalid
	}
	if _, err := DecodeBase64URLFixed(walletPublicKey, ed25519.PublicKeySize); err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(walletNamespace))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(walletPublicKey))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func SemanticHeadersBytes(canonicalRoute string, header http.Header) ([]byte, error) {
	names, ok := semanticHeaderProfiles[canonicalRoute]
	if !ok {
		return nil, ErrWalletCanonicalInvalid
	}
	var b strings.Builder
	for _, name := range names {
		values := header.Values(name)
		if len(values) == 0 {
			continue
		}
		if len(values) != 1 {
			return nil, ErrWalletCanonicalInvalid
		}
		b.WriteString(name)
		b.WriteByte(':')
		b.WriteString(strings.Trim(values[0], " \t"))
		b.WriteByte('\n')
	}
	return []byte(b.String()), nil
}

func SemanticHeadersSHA256Base64URL(canonicalRoute string, header http.Header) (string, error) {
	canonical, err := SemanticHeadersBytes(canonicalRoute, header)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canonical)
	return base64.RawURLEncoding.EncodeToString(sum[:]), nil
}

var semanticHeaderProfiles = map[string][]string{
	"/v1/chat/completions":                     {"accept", "idempotency-key", "x-macprovider-conversation", "x-macprovider-retry"},
	"/v1/responses":                            {"accept", "idempotency-key", "x-macprovider-conversation", "x-macprovider-retry"},
	"/v1/messages":                             {"accept", "anthropic-beta", "anthropic-version", "idempotency-key", "x-macprovider-conversation", "x-macprovider-retry"},
	"/v1/relay-blind/route-reservations":       {"accept", "idempotency-key"},
	"/v1/models":                               {},
	"/auth/wallet-sessions/{session_id}":       {},
	"/auth/wallet-sessions/{session_id}/usage": {},
}

func walletProofFromMap(m map[string]any) (WalletProof, error) {
	models, err := stringArrayField(m, "model_allowlist")
	if err != nil {
		return WalletProof{}, err
	}
	return WalletProof{
		Version:            stringField(m, "version"),
		ChallengeID:        stringField(m, "challenge_id"),
		Audience:           stringField(m, "aud"),
		AccountID:          stringField(m, "account_id"),
		WalletNamespace:    stringField(m, "wallet_namespace"),
		WalletPublicKey:    stringField(m, "wallet_public_key"),
		SessionPublicKey:   stringField(m, "session_public_key"),
		Nonce:              stringField(m, "nonce"),
		ExpiresAtUnix:      integerField(m, "expires_at_unix"),
		PerRequestTokenCap: integerField(m, "per_request_token_cap"),
		TotalTokenCap:      integerField(m, "total_token_cap"),
		ModelAllowlist:     models,
	}, err
}

func walletChallengeRequestFromMap(m map[string]any) (WalletChallengeRequest, error) {
	models, err := stringArrayField(m, "model_allowlist")
	if err != nil {
		return WalletChallengeRequest{}, err
	}
	return WalletChallengeRequest{
		WalletNamespace:    stringField(m, "wallet_namespace"),
		WalletPublicKey:    stringField(m, "wallet_public_key"),
		SessionPublicKey:   stringField(m, "session_public_key"),
		ExpiresAtUnix:      integerField(m, "expires_at_unix"),
		PerRequestTokenCap: integerField(m, "per_request_token_cap"),
		TotalTokenCap:      integerField(m, "total_token_cap"),
		ModelAllowlist:     models,
	}, nil
}

func walletRequestFromMap(m map[string]any) (WalletRequestSignatureObject, error) {
	return WalletRequestSignatureObject{
		Version:               stringField(m, "version"),
		SessionID:             stringField(m, "session_id"),
		Method:                stringField(m, "method"),
		CanonicalRoute:        stringField(m, "canonical_route"),
		RequestID:             stringField(m, "request_id"),
		RawBodySHA256:         stringField(m, "raw_body_sha256"),
		SemanticHeadersSHA256: stringField(m, "semantic_headers_sha256"),
		TimestampUnix:         integerField(m, "timestamp_unix"),
	}, nil
}

func validateWalletProof(proof WalletProof) error {
	if proof.Version != WalletProofVersion {
		return ErrWalletCanonicalInvalid
	}
	if proof.WalletNamespace != WalletNamespaceEd25519 {
		return ErrWalletAlgorithmUnsupported
	}
	if proof.ChallengeID == "" || proof.Audience == "" || proof.AccountID == "" || proof.Nonce == "" {
		return ErrWalletCanonicalInvalid
	}
	if proof.ExpiresAtUnix < 0 || proof.PerRequestTokenCap <= 0 || proof.TotalTokenCap <= 0 || proof.PerRequestTokenCap > proof.TotalTokenCap {
		return ErrWalletCanonicalInvalid
	}
	if _, err := DecodeBase64URLFixed(proof.WalletPublicKey, ed25519.PublicKeySize); err != nil {
		return err
	}
	if _, err := DecodeBase64URLFixed(proof.SessionPublicKey, ed25519.PublicKeySize); err != nil {
		return err
	}
	if _, err := DecodeBase64URL(proof.Nonce); err != nil {
		return err
	}
	if len(proof.ModelAllowlist) == 0 {
		return ErrWalletCanonicalInvalid
	}
	for _, model := range proof.ModelAllowlist {
		if model == "" {
			return ErrWalletCanonicalInvalid
		}
	}
	return nil
}

func validateWalletChallengeRequest(req WalletChallengeRequest) error {
	if req.WalletNamespace != WalletNamespaceEd25519 {
		return ErrWalletAlgorithmUnsupported
	}
	if req.ExpiresAtUnix < 0 || req.PerRequestTokenCap <= 0 || req.TotalTokenCap <= 0 || req.PerRequestTokenCap > req.TotalTokenCap {
		return ErrWalletCanonicalInvalid
	}
	if _, err := DecodeBase64URLFixed(req.WalletPublicKey, ed25519.PublicKeySize); err != nil {
		return err
	}
	if _, err := DecodeBase64URLFixed(req.SessionPublicKey, ed25519.PublicKeySize); err != nil {
		return err
	}
	if len(req.ModelAllowlist) == 0 {
		return ErrWalletCanonicalInvalid
	}
	for _, model := range req.ModelAllowlist {
		if model == "" {
			return ErrWalletCanonicalInvalid
		}
	}
	return nil
}

func validateWalletRequest(obj WalletRequestSignatureObject) error {
	if obj.Version != WalletRequestVersion || obj.SessionID == "" || obj.Method == "" {
		return ErrWalletCanonicalInvalid
	}
	if _, ok := semanticHeaderProfiles[obj.CanonicalRoute]; !ok {
		return ErrWalletCanonicalInvalid
	}
	if !ValidateUUIDv4RequestID(obj.RequestID) {
		return ErrWalletRequestIDInvalid
	}
	if _, err := DecodeBase64URLFixed(obj.RawBodySHA256, sha256.Size); err != nil {
		return err
	}
	if _, err := DecodeBase64URLFixed(obj.SemanticHeadersSHA256, sha256.Size); err != nil {
		return err
	}
	if obj.TimestampUnix < 0 {
		return ErrWalletCanonicalInvalid
	}
	return nil
}

func walletProofJCS(proof WalletProof) map[string]any {
	return map[string]any{
		"version": proof.Version, "challenge_id": proof.ChallengeID, "aud": proof.Audience,
		"account_id": proof.AccountID, "wallet_namespace": proof.WalletNamespace,
		"wallet_public_key": proof.WalletPublicKey, "session_public_key": proof.SessionPublicKey,
		"nonce": proof.Nonce, "expires_at_unix": proof.ExpiresAtUnix,
		"per_request_token_cap": proof.PerRequestTokenCap, "total_token_cap": proof.TotalTokenCap,
		"model_allowlist": stringsToAny(proof.ModelAllowlist),
	}
}

func walletRequestJCS(obj WalletRequestSignatureObject) map[string]any {
	return map[string]any{
		"version": obj.Version, "session_id": obj.SessionID, "method": obj.Method,
		"canonical_route": obj.CanonicalRoute, "request_id": obj.RequestID,
		"raw_body_sha256": obj.RawBodySHA256, "semantic_headers_sha256": obj.SemanticHeadersSHA256,
		"timestamp_unix": obj.TimestampUnix,
	}
}

func decodeJSONUseNumber(raw []byte, out any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(out); err != nil {
		return err
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}

func stringField(m map[string]any, name string) string {
	v, _ := m[name].(string)
	return v
}

func integerField(m map[string]any, name string) int64 {
	n, ok := m[name].(json.Number)
	if !ok {
		return -1
	}
	if !unsignedIntegerJSON.MatchString(n.String()) {
		return -1
	}
	v, err := strconv.ParseInt(n.String(), 10, 64)
	if err != nil {
		return -1
	}
	return v
}

func stringArrayField(m map[string]any, name string) ([]string, error) {
	raw, ok := m[name].([]any)
	if !ok {
		return nil, ErrWalletCanonicalInvalid
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		value, ok := item.(string)
		if !ok {
			return nil, ErrWalletCanonicalInvalid
		}
		out = append(out, value)
	}
	return out, nil
}

func stringsToAny(in []string) []any {
	out := make([]any, 0, len(in))
	for _, value := range in {
		out = append(out, value)
	}
	return out
}

func validateClosedJSON(raw []byte, allowedByPath map[string]map[string]bool) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := walkJSONValue(dec, "", allowedByPath); err != nil {
		return err
	}
	err := dec.Decode(&struct{}{})
	if err == nil {
		return fmt.Errorf("%w: trailing JSON", ErrWalletCanonicalInvalid)
	}
	if err != io.EOF {
		return fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
	}
	return nil
}

func walkJSONValue(dec *json.Decoder, path string, allowedByPath map[string]map[string]bool) error {
	tok, err := dec.Token()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		if n, ok := tok.(json.Number); ok && !unsignedIntegerJSON.MatchString(n.String()) {
			return fmt.Errorf("%w: invalid number", ErrWalletCanonicalInvalid)
		}
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		allowed := allowedByPath[path]
		for dec.More() {
			keyTok, err := dec.Token()
			if err != nil {
				return fmt.Errorf("%w: %v", ErrWalletCanonicalInvalid, err)
			}
			key, ok := keyTok.(string)
			if !ok {
				return ErrWalletCanonicalInvalid
			}
			if seen[key] {
				return fmt.Errorf("%w: duplicate field", ErrWalletCanonicalInvalid)
			}
			seen[key] = true
			if allowed != nil && !allowed[key] {
				return fmt.Errorf("%w: unknown field", ErrWalletCanonicalInvalid)
			}
			child := key
			if path != "" {
				child = path + "." + key
			}
			if err := walkJSONValue(dec, child, allowedByPath); err != nil {
				return err
			}
		}
		end, err := dec.Token()
		if err != nil || end != json.Delim('}') {
			return ErrWalletCanonicalInvalid
		}
	case '[':
		for dec.More() {
			if err := walkJSONValue(dec, path+"[]", allowedByPath); err != nil {
				return err
			}
		}
		end, err := dec.Token()
		if err != nil || end != json.Delim(']') {
			return ErrWalletCanonicalInvalid
		}
	default:
		return ErrWalletCanonicalInvalid
	}
	return nil
}

func canonicalJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeJCS(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func writeJCS(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case string:
		b.WriteString(escapeJCSString(x))
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case int64:
		if x < 0 {
			return ErrWalletCanonicalInvalid
		}
		b.WriteString(strconv.FormatInt(x, 10))
	case []any:
		b.WriteByte('[')
		for i, item := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeJCS(b, item); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for key := range x {
			keys = append(keys, key)
		}
		sort.Slice(keys, func(i, j int) bool { return utf16Less(keys[i], keys[j]) })
		b.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(escapeJCSString(key))
			b.WriteByte(':')
			if err := writeJCS(b, x[key]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		return fmt.Errorf("%w: unsupported JCS value %T", ErrWalletCanonicalInvalid, v)
	}
	return nil
}

func escapeJCSString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r >= 0 && r <= 0x1f {
				b.WriteString(`\u00`)
				b.WriteString(hex.EncodeToString([]byte{byte(r)}))
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func utf16Less(a, b string) bool {
	aa := utf16.Encode([]rune(a))
	bb := utf16.Encode([]rune(b))
	for i := 0; i < len(aa) && i < len(bb); i++ {
		if aa[i] != bb[i] {
			return aa[i] < bb[i]
		}
	}
	return len(aa) < len(bb)
}

func isLowerHex(ch byte) bool {
	return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
}
