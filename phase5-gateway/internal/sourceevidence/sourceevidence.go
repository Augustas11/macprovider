// Package sourceevidence implements the gateway side of SPEC-006 §5.4.3.3:
// the private-keyed refusal intent commitment, the caller-recomputable
// intent binding, and the §5.4.3.1 signed export envelope with producer
// `gateway` and role `refusal_intent`. It mirrors the coordinator producer's
// fail-closed provenance rules (§5.4.3.2); the two Go modules share no code.
package sourceevidence

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"runtime/debug"
	"sort"
	"strings"
	"time"
)

const (
	EnvelopeSchema       = "macprovider.source-authenticated-export-envelope.v1"
	SignedSchema         = "macprovider.source-authenticated-export.v1"
	SignDomain           = "macprovider.source-authenticated-export.v1"
	RequestSchema        = "macprovider.gateway-source-export-request.v1"
	SnapshotSchema       = "macprovider.gateway-source-snapshot.v1"
	RecordSchema         = "macprovider.gateway-refusal-record.v1"
	ContractVersion      = "gateway-refusal-intent-v1"
	RecordTableSchema    = "gateway_refusal_records.v1"
	Canonicalization     = "ascii-jcs-subset-v1"
	IntentHMAC           = "hmac-sha256-length-prefixed-v1"
	ScopeBinding         = "sha256-run-nonce-length-prefixed-v1"
	ProducerName         = "gateway"
	ProducerRole         = "refusal_intent"
	registrySchema       = "macprovider.source-evidence-key-registry.v1"
	intentDomain         = "macprovider.gateway-refusal-intent.v1\n"
	bindingDomain        = "macprovider.gateway-refusal-intent-binding.v1\n"
	maxRegistryBytes     = 2 << 20
	maxStrictJSONDepth   = 64
	DefaultMaxScopes     = 100
	AbsoluteMaxScopes    = 1000
	DefaultMaxBodyBytes  = 1 << 20
	maxSecretFileBytes   = 4096
	registryMillisLayout = "2006-01-02T15:04:05.000Z"
)

var (
	ErrDisabled          = errors.New("source evidence disabled")
	ErrProvenanceMissing = errors.New("source evidence provenance missing")

	hex40RE      = regexp.MustCompile(`^[0-9a-f]{40}$`)
	hex64RE      = regexp.MustCompile(`^[0-9a-f]{64}$`)
	keyIDRE      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	instanceIDRE = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	roleRE       = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	domainRE     = regexp.MustCompile(`^[a-z][a-z0-9_.:-]{0,127}$`)
	utcMillisRE  = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)
	base64URLRE  = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
)

// Intent is the caller-held request intent a refusal record commits to.
type Intent struct {
	AccountID         string `json:"account_id"`
	ExternalRequestID string `json:"external_request_id"`
	Model             string `json:"model"`
	PoolSelect        string `json:"pool_select"`
	EngineSelect      string `json:"engine_select"`
}

func (i Intent) parts() []string {
	return []string{i.AccountID, i.ExternalRequestID, i.Model, i.PoolSelect, i.EngineSelect}
}

// IntentCommitment is the stored private-keyed commitment.
func IntentCommitment(key []byte, in Intent) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(intentDomain))
	writeLengthPrefixed(mac, in.parts()...)
	return hex.EncodeToString(mac.Sum(nil))
}

// IntentBinding is the challenge-bound binding a caller holding the intent
// recomputes; it is the exported request_scope_commitment.
func IntentBinding(runID, nonce string, in Intent) string {
	h := sha256.New()
	h.Write([]byte(bindingDomain))
	writeLengthPrefixed(h, append([]string{runID, nonce}, in.parts()...)...)
	return hex.EncodeToString(h.Sum(nil))
}

func writeLengthPrefixed(w io.Writer, parts ...string) {
	var lenbuf [4]byte
	for _, part := range parts {
		binary.BigEndian.PutUint32(lenbuf[:], uint32(len(part)))
		_, _ = w.Write(lenbuf[:])
		_, _ = w.Write([]byte(part))
	}
}

// FixedProvenance is producer-owned reviewed release identity. It is never a
// request or reloadable-config selector.
type FixedProvenance struct {
	InstanceID           string
	SourceSHA            string
	KeyID                string
	ReviewedRegistryPath string
	RegistryDigest       string
	Now                  func() time.Time
}

func (p FixedProvenance) validate() error {
	if strings.TrimSpace(p.InstanceID) == "" || strings.TrimSpace(p.KeyID) == "" || strings.TrimSpace(p.ReviewedRegistryPath) == "" {
		return ErrProvenanceMissing
	}
	if !hex40RE.MatchString(p.SourceSHA) {
		return fmt.Errorf("%w: immutable source sha missing", ErrProvenanceMissing)
	}
	if !strings.HasPrefix(p.RegistryDigest, "sha256:") || !hex64RE.MatchString(strings.TrimPrefix(p.RegistryDigest, "sha256:")) {
		return fmt.Errorf("%w: reviewed registry digest missing", ErrProvenanceMissing)
	}
	return nil
}

// DefaultFixedProvenance deliberately has no production pins. Enabling the
// export without reviewed release wiring fails closed.
func DefaultFixedProvenance() FixedProvenance {
	return FixedProvenance{SourceSHA: cleanVCSRevision()}
}

func cleanVCSRevision() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return ""
	}
	var revision string
	clean := true
	for _, setting := range info.Settings {
		switch setting.Key {
		case "vcs.revision":
			revision = setting.Value
		case "vcs.modified":
			clean = setting.Value != "true"
		}
	}
	if !clean || !hex40RE.MatchString(revision) {
		return ""
	}
	return revision
}

// Signer signs gateway refusal-intent exports under reviewed provenance.
type Signer struct {
	prov       FixedProvenance
	privateKey ed25519.PrivateKey
}

// NewSigner loads the reviewed registry, checks its digest against the
// fixed provenance, and authorizes the signing key for producer `gateway`,
// role `refusal_intent`, the instance and the source SHA.
func NewSigner(signingKeyPath string, prov FixedProvenance) (*Signer, error) {
	if err := prov.validate(); err != nil {
		return nil, err
	}
	if prov.Now == nil {
		prov.Now = func() time.Time { return time.Now().UTC() }
	}
	raw, err := readBounded(prov.ReviewedRegistryPath, maxRegistryBytes)
	if err != nil {
		return nil, fmt.Errorf("reviewed registry: %w", err)
	}
	registry, err := decodeStrictJSON(raw)
	if err != nil {
		return nil, fmt.Errorf("reviewed registry: %w", err)
	}
	canonical, err := CanonicalBytes(registry)
	if err != nil {
		return nil, fmt.Errorf("reviewed registry canonical digest: %w", err)
	}
	if "sha256:"+sha256Hex(canonical) != prov.RegistryDigest {
		return nil, fmt.Errorf("%w: registry digest mismatch", ErrProvenanceMissing)
	}
	seed, err := LoadSecretBytes(signingKeyPath)
	if err != nil {
		return nil, err
	}
	var key ed25519.PrivateKey
	switch len(seed) {
	case ed25519.SeedSize:
		key = ed25519.NewKeyFromSeed(seed)
	case ed25519.PrivateKeySize:
		key = ed25519.PrivateKey(seed)
	default:
		return nil, fmt.Errorf("source evidence signing key must decode to a 32-byte seed or 64-byte Ed25519 private key")
	}
	if err := authorizeRegistryKey(registry, prov, key.Public().(ed25519.PublicKey)); err != nil {
		return nil, err
	}
	return &Signer{prov: prov, privateKey: key}, nil
}

// Now is the signer's provenance clock.
func (s *Signer) Now() time.Time { return s.prov.Now().UTC() }

// Sign builds and signs the §5.4.3.1 envelope. Records must already be the
// closed gateway projection; they are sorted by request_scope_commitment.
func (s *Signer) Sign(runID, nonce string, generatedAt time.Time, records []map[string]any) (map[string]any, error) {
	sort.Slice(records, func(i, j int) bool {
		return records[i]["request_scope_commitment"].(string) < records[j]["request_scope_commitment"].(string)
	})
	scopes := make([]string, 0, len(records))
	for i, rec := range records {
		scope := rec["request_scope_commitment"].(string)
		if i > 0 && scope == scopes[i-1] {
			return nil, fmt.Errorf("duplicate request scope")
		}
		scopes = append(scopes, scope)
	}
	signed := map[string]any{
		"schema_version":  SignedSchema,
		"producer":        ProducerName,
		"role":            ProducerRole,
		"instance_id":     s.prov.InstanceID,
		"source_sha":      s.prov.SourceSHA,
		"export_id":       newUUIDv4(),
		"run_id":          runID,
		"challenge_nonce": nonce,
		"generated_at":    UTCMillis(generatedAt),
		"request_scopes":  scopes,
		"snapshot": map[string]any{
			"schema_version":            SnapshotSchema,
			"producer_contract_version": ContractVersion,
			"registry_bundle_digest":    s.prov.RegistryDigest,
			"record_table_schema":       RecordTableSchema,
			"record_schema":             RecordSchema,
			"canonicalization":          Canonicalization,
			"intent_hmac":               IntentHMAC,
			"scope_binding":             ScopeBinding,
		},
		"records": records,
	}
	signedBytes, err := CanonicalBytes(signed)
	if err != nil {
		return nil, err
	}
	signature := ed25519.Sign(s.privateKey, append([]byte(SignDomain+"\n"), signedBytes...))
	return map[string]any{
		"schema_version": EnvelopeSchema,
		"signed":         signed,
		"signatures": []map[string]any{{
			"algorithm":     "ed25519",
			"key_id":        s.prov.KeyID,
			"signed_sha256": sha256Hex(signedBytes),
			"signature":     base64.RawURLEncoding.EncodeToString(signature),
		}},
	}, nil
}

// UTCMillis formats a timestamp in the envelope's UTC millisecond form.
func UTCMillis(t time.Time) string { return t.UTC().Format(registryMillisLayout) }

// CanonicalBytes is the restricted ASCII JCS subset of §5.4.3.1: compact,
// sorted keys, no HTML escaping, non-negative safe integers, printable ASCII
// strings, no floats.
func CanonicalBytes(v any) ([]byte, error) {
	if err := validateCanonical(v, 0); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

func validateCanonical(v any, depth int) error {
	if depth > maxStrictJSONDepth {
		return fmt.Errorf("canonical JSON nesting exceeds safe depth")
	}
	switch x := v.(type) {
	case nil, bool:
		return nil
	case string:
		return asciiString(x, 4096)
	case int:
		return safeInt(int64(x))
	case int64:
		return safeInt(x)
	case json.Number:
		n, err := x.Int64()
		if err != nil || x.String() != fmt.Sprint(n) {
			return fmt.Errorf("canonical JSON admits only integers")
		}
		return safeInt(n)
	case []string:
		for _, s := range x {
			if err := asciiString(s, 4096); err != nil {
				return err
			}
		}
		return nil
	case []any:
		for _, item := range x {
			if err := validateCanonical(item, depth+1); err != nil {
				return err
			}
		}
		return nil
	case []map[string]any:
		for _, item := range x {
			if err := validateCanonical(item, depth+1); err != nil {
				return err
			}
		}
		return nil
	case map[string]any:
		for key, item := range x {
			if err := asciiString(key, 128); err != nil {
				return err
			}
			if err := validateCanonical(item, depth+1); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("canonical JSON value type %T is not admitted", v)
	}
}

func asciiString(s string, max int) error {
	if len(s) > max {
		return fmt.Errorf("canonical JSON string exceeds %d bytes", max)
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return fmt.Errorf("canonical JSON strings must be printable ASCII")
		}
	}
	return nil
}

func safeInt(n int64) error {
	if n < 0 || n > 9007199254740991 {
		return fmt.Errorf("canonical JSON integers must be in 0..2^53-1")
	}
	return nil
}

// decodeStrictJSON rejects duplicate keys, trailing values and floats.
func decodeStrictJSON(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := strictValue(dec, 0)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing JSON value")
	}
	return v, nil
}

func strictValue(dec *json.Decoder, depth int) (any, error) {
	if depth > maxStrictJSONDepth {
		return nil, fmt.Errorf("JSON nesting exceeds safe depth")
	}
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			out := map[string]any{}
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key := keyTok.(string)
				if _, dup := out[key]; dup {
					return nil, fmt.Errorf("duplicate JSON key")
				}
				val, err := strictValue(dec, depth+1)
				if err != nil {
					return nil, err
				}
				out[key] = val
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return out, nil
		case '[':
			out := []any{}
			for dec.More() {
				val, err := strictValue(dec, depth+1)
				if err != nil {
					return nil, err
				}
				out = append(out, val)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return out, nil
		}
		return nil, fmt.Errorf("unexpected JSON delimiter")
	case json.Number:
		if _, err := t.Int64(); err != nil {
			return nil, fmt.Errorf("JSON numbers must be integers")
		}
		return t, nil
	default:
		return t, nil
	}
}

func authorizeRegistryKey(registry any, prov FixedProvenance, publicKey ed25519.PublicKey) error {
	root, ok := registry.(map[string]any)
	if !ok || len(root) != 2 || root["schema_version"] != registrySchema {
		return fmt.Errorf("%w: registry schema mismatch", ErrProvenanceMissing)
	}
	keys, ok := root["keys"].([]any)
	if !ok || len(keys) == 0 {
		return fmt.Errorf("%w: registry keys missing", ErrProvenanceMissing)
	}
	var selected map[string]any
	seen := map[string]struct{}{}
	for _, raw := range keys {
		key, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("%w: registry key row must be object", ErrProvenanceMissing)
		}
		if err := validateRegistryRow(key); err != nil {
			return err
		}
		keyID := key["key_id"].(string)
		if _, dup := seen[keyID]; dup {
			return fmt.Errorf("%w: duplicate registry key id", ErrProvenanceMissing)
		}
		seen[keyID] = struct{}{}
		if keyID == prov.KeyID {
			selected = key
		}
	}
	if selected == nil {
		return fmt.Errorf("%w: key id not in registry", ErrProvenanceMissing)
	}
	if selected["producer"] != ProducerName || selected["instance_id"] != prov.InstanceID {
		return fmt.Errorf("%w: key identity not authorized", ErrProvenanceMissing)
	}
	pub, err := decodeRegistryPublicKey(selected["public_key"].(string))
	if err != nil || !ed25519.PublicKey(pub).Equal(publicKey) {
		return fmt.Errorf("%w: key public material mismatch", ErrProvenanceMissing)
	}
	constraints := selected["reviewed_source_constraints"].(map[string]any)
	if !contains(selected["permitted_roles"], ProducerRole) || !contains(selected["permitted_domains"], SignDomain) ||
		!contains(constraints["source_sha_allowlist"], prov.SourceSHA) {
		return fmt.Errorf("%w: key constraints do not authorize producer", ErrProvenanceMissing)
	}
	now := prov.Now().UTC()
	notBefore, _ := time.Parse(registryMillisLayout, selected["not_before"].(string))
	notAfter, _ := time.Parse(registryMillisLayout, selected["not_after"].(string))
	if now.Before(notBefore) || !now.Before(notAfter) {
		return fmt.Errorf("%w: selected key inactive", ErrProvenanceMissing)
	}
	if revoked, ok := selected["revoked_at"].(string); ok {
		revokedAt, _ := time.Parse(registryMillisLayout, revoked)
		if !now.Before(revokedAt) {
			return fmt.Errorf("%w: selected key revoked", ErrProvenanceMissing)
		}
	}
	return nil
}

func validateRegistryRow(key map[string]any) error {
	fields := []string{"key_id", "algorithm", "public_key", "producer", "instance_id", "permitted_roles", "permitted_domains",
		"not_before", "not_after", "revoked_at", "reviewed_source_constraints"}
	if len(key) != len(fields) {
		return fmt.Errorf("%w: registry key row fields", ErrProvenanceMissing)
	}
	for _, f := range fields {
		if _, ok := key[f]; !ok {
			return fmt.Errorf("%w: registry key row fields", ErrProvenanceMissing)
		}
	}
	bad := func(what string) error { return fmt.Errorf("%w: registry %s invalid", ErrProvenanceMissing, what) }
	if s, ok := key["key_id"].(string); !ok || !keyIDRE.MatchString(s) {
		return bad("key id")
	}
	if key["algorithm"] != "ed25519" {
		return bad("algorithm")
	}
	if s, ok := key["public_key"].(string); !ok {
		return bad("public key")
	} else if _, err := decodeRegistryPublicKey(s); err != nil {
		return bad("public key")
	}
	if s, ok := key["producer"].(string); !ok || (s != "gateway" && s != "coordinator") {
		return bad("producer")
	}
	if s, ok := key["instance_id"].(string); !ok || !instanceIDRE.MatchString(s) {
		return bad("instance id")
	}
	if !uniqueStrings(key["permitted_roles"], roleRE, 16) {
		return bad("permitted roles")
	}
	if !uniqueStrings(key["permitted_domains"], domainRE, 16) {
		return bad("permitted domains")
	}
	start, err1 := parseMillis(key["not_before"])
	end, err2 := parseMillis(key["not_after"])
	if err1 != nil || err2 != nil || !start.Before(end) {
		return bad("validity window")
	}
	if revoked := key["revoked_at"]; revoked != nil {
		if _, err := parseMillis(revoked); err != nil {
			return bad("revoked_at")
		}
	}
	constraints, ok := key["reviewed_source_constraints"].(map[string]any)
	if !ok || len(constraints) != 2 || !uniqueStrings(constraints["source_sha_allowlist"], hex40RE, 64) {
		return bad("source constraints")
	}
	if notes, ok := constraints["notes"].(string); !ok || notes == "" || len(notes) > 512 || strings.TrimSpace(notes) != notes {
		return bad("source constraint notes")
	}
	return nil
}

func parseMillis(v any) (time.Time, error) {
	s, ok := v.(string)
	if !ok || !utcMillisRE.MatchString(s) {
		return time.Time{}, fmt.Errorf("timestamp must be UTC milliseconds")
	}
	return time.Parse(registryMillisLayout, s)
}

func uniqueStrings(raw any, pattern *regexp.Regexp, maxItems int) bool {
	values, ok := raw.([]any)
	if !ok || len(values) == 0 || len(values) > maxItems {
		return false
	}
	seen := map[string]struct{}{}
	for _, item := range values {
		s, ok := item.(string)
		if !ok || !pattern.MatchString(s) {
			return false
		}
		if _, dup := seen[s]; dup {
			return false
		}
		seen[s] = struct{}{}
	}
	return true
}

func contains(raw any, target string) bool {
	values, _ := raw.([]any)
	for _, v := range values {
		if v == target {
			return true
		}
	}
	return false
}

func decodeRegistryPublicKey(value string) ([]byte, error) {
	if !base64URLRE.MatchString(value) {
		return nil, fmt.Errorf("invalid base64url")
	}
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid base64url public key")
	}
	return raw, nil
}

// LoadSecretBytes reads a secret file holding hex or base64(url) bytes.
func LoadSecretBytes(path string) ([]byte, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("source evidence secret path is required")
	}
	b, err := readBounded(path, maxSecretFileBytes)
	if err != nil {
		return nil, err
	}
	trimmed := strings.TrimSpace(string(b))
	if trimmed == "" {
		return nil, fmt.Errorf("source evidence secret file is empty")
	}
	if len(trimmed)%2 == 0 && strings.Trim(trimmed, "0123456789abcdefABCDEF") == "" {
		if decoded, err := hex.DecodeString(trimmed); err == nil {
			return decoded, nil
		}
	}
	for _, enc := range []*base64.Encoding{base64.RawURLEncoding, base64.StdEncoding, base64.URLEncoding} {
		if decoded, err := enc.DecodeString(trimmed); err == nil {
			return decoded, nil
		}
	}
	return nil, fmt.Errorf("source evidence secret file is not hex or base64")
}

func readBounded(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("file exceeds %d bytes", max)
	}
	return data, nil
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func newUUIDv4() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
