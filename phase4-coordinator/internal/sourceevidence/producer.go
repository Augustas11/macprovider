package sourceevidence

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	defaultMaxScopes    = 100
	absoluteMaxScopes   = 1000
	maxRunIDBytes       = 128
	maxLookupIDBytes    = 128
	maxSafeIntegerInt64 = int64(9007199254740991)
	registrySchema      = "macprovider.source-evidence-key-registry.v1"
)

var (
	runIDRE      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	nonceRE      = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	lookupIDRE   = regexp.MustCompile(`^[ -~]{1,128}$`)
	requestIDRE  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	keyIDRE      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	instanceIDRE = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	roleRE       = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	domainRE     = regexp.MustCompile(`^[a-z][a-z0-9_.:-]{0,127}$`)
	utcMillisRE  = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)
	base64URLRE  = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
)

type Producer struct {
	store      *Store
	prov       FixedProvenance
	privateKey ed25519.PrivateKey
	maxScopes  int
}

type ExportRequest struct {
	SchemaVersion  string  `json:"schema_version"`
	RunID          string  `json:"run_id"`
	ChallengeNonce string  `json:"challenge_nonce"`
	Scopes         []Scope `json:"scopes"`
}

type ExportEnvelope struct {
	SchemaVersion string           `json:"schema_version"`
	Signed        map[string]any   `json:"signed"`
	Signatures    []map[string]any `json:"signatures"`
}

func NewProducer(store *Store, cfg Config, prov FixedProvenance) (*Producer, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if store == nil {
		return nil, ErrUnavailable
	}
	if err := prov.validate(); err != nil {
		return nil, err
	}
	if prov.Now == nil {
		prov.Now = func() time.Time { return time.Now().UTC() }
	}
	registry, err := loadStrictJSONFileBounded(prov.ReviewedRegistryPath, defaultMaxBodyBytes)
	if err != nil {
		return nil, fmt.Errorf("reviewed registry: %w", err)
	}
	registryBytes, err := canonicalBytes(registry)
	if err != nil {
		return nil, fmt.Errorf("reviewed registry canonical digest: %w", err)
	}
	registryDigest := "sha256:" + sha256Hex(registryBytes)
	if registryDigest != prov.RegistryDigest {
		return nil, fmt.Errorf("%w: registry digest mismatch", ErrProvenanceMissing)
	}
	key, err := loadEd25519PrivateKey(cfg.SigningPrivateKeyPath)
	if err != nil {
		return nil, err
	}
	if err := authorizeRegistryKey(registry, prov, key.Public().(ed25519.PublicKey)); err != nil {
		return nil, err
	}
	maxScopes := cfg.MaxScopes
	if maxScopes <= 0 {
		maxScopes = defaultMaxScopes
	}
	if maxScopes > absoluteMaxScopes {
		return nil, fmt.Errorf("source evidence max scopes must be <= %d", absoluteMaxScopes)
	}
	return &Producer{store: store, prov: prov, privateKey: key, maxScopes: maxScopes}, nil
}

func (p *Producer) Export(ctx context.Context, req ExportRequest) (ExportEnvelope, error) {
	if p == nil || p.store == nil || len(p.privateKey) != ed25519.PrivateKeySize {
		return ExportEnvelope{}, ErrUnavailable
	}
	if err := validateExportRequest(req, p.maxScopes); err != nil {
		return ExportEnvelope{}, err
	}
	records := make([]map[string]any, 0, len(req.Scopes))
	requestScopes := make([]string, 0, len(req.Scopes))
	seen := make(map[string]struct{}, len(req.Scopes))
	generatedAt := p.prov.Now().UTC()
	resolvedRecords, err := p.store.ResolveClosedBatch(ctx, req.Scopes)
	if err != nil {
		return ExportEnvelope{}, fmt.Errorf("%w: %v", ErrScopeNotClosed, err)
	}
	for _, resolved := range resolvedRecords {
		if closedAt, err := time.Parse(time.RFC3339Nano, resolved.Closure.ClosedAtUTC); err != nil {
			return ExportEnvelope{}, fmt.Errorf("%w: closure timestamp", ErrScopeNotClosed)
		} else if closedAt.After(generatedAt) {
			return ExportEnvelope{}, fmt.Errorf("%w: closure after export generation", ErrScopeNotClosed)
		}
		commitment := resolved.Closure.RequestScopeCommitment
		if _, ok := seen[commitment]; ok {
			return ExportEnvelope{}, fmt.Errorf("%w: duplicate scope commitment", ErrInvalidRequest)
		}
		seen[commitment] = struct{}{}
		requestScopes = append(requestScopes, commitment)
		records = append(records, recordForResolved(resolved))
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i]["request_scope_commitment"].(string) < records[j]["request_scope_commitment"].(string)
	})
	sort.Strings(requestScopes)
	signed := map[string]any{
		"schema_version":  SignedSchema,
		"producer":        ProducerName,
		"role":            ProducerRole,
		"instance_id":     p.prov.InstanceID,
		"source_sha":      p.prov.SourceSHA,
		"export_id":       uuid.NewString(),
		"run_id":          req.RunID,
		"challenge_nonce": req.ChallengeNonce,
		"generated_at":    utcMillis(generatedAt),
		"request_scopes":  requestScopes,
		"snapshot":        snapshotFor(p.prov.RegistryDigest),
		"records":         records,
	}
	signedBytes, err := canonicalBytes(signed)
	if err != nil {
		return ExportEnvelope{}, err
	}
	signature := ed25519.Sign(p.privateKey, append([]byte(SignDomain+"\n"), signedBytes...))
	return ExportEnvelope{
		SchemaVersion: EnvelopeSchema,
		Signed:        signed,
		Signatures: []map[string]any{{
			"algorithm":     "ed25519",
			"key_id":        p.prov.KeyID,
			"signed_sha256": sha256Hex(signedBytes),
			"signature":     base64.RawURLEncoding.EncodeToString(signature),
		}},
	}, nil
}

func validateExportRequest(req ExportRequest, maxScopes int) error {
	if req.SchemaVersion != RequestSchema || !runIDRE.MatchString(req.RunID) || len(req.RunID) > maxRunIDBytes || !nonceRE.MatchString(req.ChallengeNonce) {
		return ErrInvalidRequest
	}
	if maxScopes <= 0 || maxScopes > absoluteMaxScopes {
		maxScopes = defaultMaxScopes
	}
	if len(req.Scopes) == 0 || len(req.Scopes) > maxScopes {
		return ErrInvalidRequest
	}
	seen := map[string]struct{}{}
	for _, scope := range req.Scopes {
		if !lookupIDRE.MatchString(scope.AccountID) || !lookupIDRE.MatchString(scope.ExternalRequestID) || !requestIDRE.MatchString(scope.RequiredInternalRequestID) {
			return ErrInvalidRequest
		}
		if scope.NotBeforeUnixMS < 0 || scope.NotBeforeUnixMS > maxSafeIntegerInt64 {
			return ErrInvalidRequest
		}
		key := scope.AccountID + "\x00" + scope.ExternalRequestID + "\x00" + scope.RequiredInternalRequestID
		if _, ok := seen[key]; ok {
			return ErrInvalidRequest
		}
		seen[key] = struct{}{}
	}
	return nil
}

func recordForResolved(resolved ResolvedRecord) map[string]any {
	errorClass := "no_provider_advertised_requested_model"
	if resolved.Closure.TerminalKind == TerminalPoolUnavailable {
		errorClass = "pool_unavailable"
	}
	return map[string]any{
		"schema_version":           RecordSchema,
		"source":                   ProducerName,
		"record_kind":              "no_dispatch_terminal",
		"request_scope_commitment": resolved.Closure.RequestScopeCommitment,
		"projection_status":        StatusClosedTerminal,
		"terminal_kind":            resolved.Closure.TerminalKind,
		"privacy": map[string]any{
			"raw_account_id_emitted":               false,
			"raw_external_request_id_emitted":      false,
			"raw_internal_request_id_emitted":      false,
			"raw_rejected_model_emitted":           false,
			"request_log_model_blank_for_unserved": true,
		},
		"request_log_summary": map[string]any{
			"count":                1,
			"status":               resolved.LogStatus,
			"attempt_n":            resolved.AttemptN,
			"provider_assigned":    resolved.ProviderSet,
			"error_message_class":  errorClass,
			"terminal_kind_source": "coordinator_source_no_dispatch_closures.terminal_kind",
		},
		"settlement_absence": map[string]any{
			"fence":                       "sqlite_triggers_no_future_writes_v1",
			"ledger_request_credits":      resolved.Absence["ledger_request_credits"],
			"settlement_route_snapshots":  resolved.Absence["settlement_route_snapshots"],
			"settlement_attempt_outputs":  resolved.Absence["settlement_attempt_outputs"],
			"settlement_receipt_verdicts": resolved.Absence["settlement_receipt_verdicts"],
		},
		"closure": map[string]any{
			"schema_version":  "macprovider.coordinator-no-dispatch-closure.v1",
			"closed_at_utc":   utcMillis(mustParseSQLiteTime(resolved.Closure.ClosedAtUTC)),
			"closure_id_hmac": resolved.ClosureIDHMAC,
		},
	}
}

func snapshotFor(registryDigest string) map[string]any {
	return map[string]any{
		"schema_version":            SnapshotSchema,
		"producer_contract_version": ContractVersion,
		"registry_bundle_digest":    registryDigest,
		"closure_table_schema":      ClosureSchema,
		"db_fence_schema":           FenceSchema,
		"record_schema":             RecordSchema,
		"canonicalization":          Canonicalization,
		"scope_hmac":                ScopeHMAC,
	}
}

func loadEd25519PrivateKey(path string) (ed25519.PrivateKey, error) {
	raw, err := LoadSecretBytes(path)
	if err != nil {
		return nil, err
	}
	switch len(raw) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(raw), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(raw), nil
	default:
		return nil, fmt.Errorf("source evidence signing key must decode to 32-byte seed or 64-byte Ed25519 private key")
	}
}

func LoadSecretBytes(path string) ([]byte, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("source evidence secret path is required")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	trimmed := strings.TrimSpace(string(b))
	if trimmed == "" {
		return nil, fmt.Errorf("source evidence secret file is empty")
	}
	if decoded, err := base64.RawURLEncoding.DecodeString(trimmed); err == nil {
		return decoded, nil
	}
	if decoded, err := base64.StdEncoding.DecodeString(trimmed); err == nil {
		return decoded, nil
	}
	if decoded, err := hex.DecodeString(trimmed); err == nil {
		return decoded, nil
	}
	if base64URLRE.MatchString(trimmed) {
		if decoded, err := base64.URLEncoding.DecodeString(trimmed); err == nil {
			return decoded, nil
		}
	}
	return nil, fmt.Errorf("source evidence secret file is not base64url, base64, or hex")
}

func authorizeRegistryKey(registry any, prov FixedProvenance, publicKey ed25519.PublicKey) error {
	root, ok := registry.(map[string]any)
	if !ok {
		return fmt.Errorf("%w: registry root must be object", ErrProvenanceMissing)
	}
	if err := requireExactKeys(root, []string{"schema_version", "keys"}, "registry"); err != nil {
		return err
	}
	if root["schema_version"] != registrySchema {
		return fmt.Errorf("%w: registry schema mismatch", ErrProvenanceMissing)
	}
	keys, ok := root["keys"].([]any)
	if !ok || len(keys) == 0 {
		return fmt.Errorf("%w: registry keys missing", ErrProvenanceMissing)
	}
	var selected map[string]any
	seen := map[string]struct{}{}
	for i, raw := range keys {
		key, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("%w: registry key row must be object", ErrProvenanceMissing)
		}
		if err := validateReviewedRegistryRow(key, i); err != nil {
			return err
		}
		keyID := key["key_id"].(string)
		if _, ok := seen[keyID]; ok {
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
	if selected["algorithm"] != "ed25519" || selected["producer"] != ProducerName || selected["instance_id"] != prov.InstanceID {
		return fmt.Errorf("%w: key identity not authorized", ErrProvenanceMissing)
	}
	pub, err := decodeRegistryPublicKey(selected["public_key"].(string))
	if err != nil || !ed25519.PublicKey(pub).Equal(publicKey) {
		return fmt.Errorf("%w: key public material mismatch", ErrProvenanceMissing)
	}
	roles := stringArray(selected["permitted_roles"])
	domains := stringArray(selected["permitted_domains"])
	constraints := selected["reviewed_source_constraints"].(map[string]any)
	shas := stringArray(constraints["source_sha_allowlist"])
	if !contains(roles, ProducerRole) || !contains(domains, SignDomain) || !contains(shas, prov.SourceSHA) {
		return fmt.Errorf("%w: key constraints do not authorize producer", ErrProvenanceMissing)
	}
	now := prov.Now().UTC()
	notBefore, err := parseRegistryMillis(selected["not_before"].(string))
	if err != nil {
		return fmt.Errorf("%w: key not_before invalid", ErrProvenanceMissing)
	}
	notAfter, err := parseRegistryMillis(selected["not_after"].(string))
	if err != nil {
		return fmt.Errorf("%w: key not_after invalid", ErrProvenanceMissing)
	}
	if !notBefore.Before(notAfter) || now.Before(notBefore) || !now.Before(notAfter) {
		return fmt.Errorf("%w: selected key inactive", ErrProvenanceMissing)
	}
	if revokedRaw := selected["revoked_at"]; revokedRaw != nil {
		revokedAt, err := parseRegistryMillis(revokedRaw.(string))
		if err != nil || !now.Before(revokedAt) {
			return fmt.Errorf("%w: selected key revoked", ErrProvenanceMissing)
		}
	}
	return nil
}

func validateReviewedRegistryRow(key map[string]any, index int) error {
	path := fmt.Sprintf("registry.keys[%d]", index)
	if err := requireExactKeys(key, []string{"key_id", "algorithm", "public_key", "producer", "instance_id", "permitted_roles", "permitted_domains", "not_before", "not_after", "revoked_at", "reviewed_source_constraints"}, path); err != nil {
		return err
	}
	if s, ok := key["key_id"].(string); !ok || !keyIDRE.MatchString(s) {
		return fmt.Errorf("%w: invalid registry key id", ErrProvenanceMissing)
	}
	if key["algorithm"] != "ed25519" {
		return fmt.Errorf("%w: registry algorithm must be ed25519", ErrProvenanceMissing)
	}
	if pub, ok := key["public_key"].(string); !ok {
		return fmt.Errorf("%w: registry public key invalid", ErrProvenanceMissing)
	} else if _, err := decodeRegistryPublicKey(pub); err != nil {
		return fmt.Errorf("%w: registry public key invalid", ErrProvenanceMissing)
	}
	if s, ok := key["producer"].(string); !ok || (s != "gateway" && s != "coordinator") {
		return fmt.Errorf("%w: registry producer invalid", ErrProvenanceMissing)
	}
	if s, ok := key["instance_id"].(string); !ok || !instanceIDRE.MatchString(s) {
		return fmt.Errorf("%w: registry instance id invalid", ErrProvenanceMissing)
	}
	if err := validateUniqueStringArray(key["permitted_roles"], roleRE, 16, path+".permitted_roles"); err != nil {
		return err
	}
	if err := validateUniqueStringArray(key["permitted_domains"], domainRE, 16, path+".permitted_domains"); err != nil {
		return err
	}
	notBefore, ok := key["not_before"].(string)
	if !ok {
		return fmt.Errorf("%w: registry not_before invalid", ErrProvenanceMissing)
	}
	notAfter, ok := key["not_after"].(string)
	if !ok {
		return fmt.Errorf("%w: registry not_after invalid", ErrProvenanceMissing)
	}
	start, err := parseRegistryMillis(notBefore)
	if err != nil {
		return fmt.Errorf("%w: registry not_before invalid", ErrProvenanceMissing)
	}
	end, err := parseRegistryMillis(notAfter)
	if err != nil || !start.Before(end) {
		return fmt.Errorf("%w: registry validity window invalid", ErrProvenanceMissing)
	}
	if revoked := key["revoked_at"]; revoked != nil {
		s, ok := revoked.(string)
		if !ok {
			return fmt.Errorf("%w: registry revoked_at invalid", ErrProvenanceMissing)
		}
		if _, err := parseRegistryMillis(s); err != nil {
			return fmt.Errorf("%w: registry revoked_at invalid", ErrProvenanceMissing)
		}
	}
	constraints, ok := key["reviewed_source_constraints"].(map[string]any)
	if !ok {
		return fmt.Errorf("%w: registry constraints invalid", ErrProvenanceMissing)
	}
	if err := requireExactKeys(constraints, []string{"source_sha_allowlist", "notes"}, path+".reviewed_source_constraints"); err != nil {
		return err
	}
	if err := validateUniqueStringArray(constraints["source_sha_allowlist"], hex40RE, 64, path+".reviewed_source_constraints.source_sha_allowlist"); err != nil {
		return err
	}
	if notes, ok := constraints["notes"].(string); !ok || len(notes) == 0 || len(notes) > 512 || strings.TrimSpace(notes) != notes {
		return fmt.Errorf("%w: registry notes invalid", ErrProvenanceMissing)
	}
	return nil
}

func requireExactKeys(obj map[string]any, allowed []string, path string) error {
	allowedSet := map[string]struct{}{}
	for _, key := range allowed {
		allowedSet[key] = struct{}{}
		if _, ok := obj[key]; !ok {
			return fmt.Errorf("%w: %s missing %s", ErrProvenanceMissing, path, key)
		}
	}
	for key := range obj {
		if _, ok := allowedSet[key]; !ok {
			return fmt.Errorf("%w: %s unknown %s", ErrProvenanceMissing, path, key)
		}
	}
	return nil
}

func validateUniqueStringArray(raw any, pattern *regexp.Regexp, maxItems int, path string) error {
	values, ok := raw.([]any)
	if !ok || len(values) == 0 || len(values) > maxItems {
		return fmt.Errorf("%w: %s invalid", ErrProvenanceMissing, path)
	}
	seen := map[string]struct{}{}
	for _, item := range values {
		s, ok := item.(string)
		if !ok || !pattern.MatchString(s) {
			return fmt.Errorf("%w: %s invalid", ErrProvenanceMissing, path)
		}
		if _, ok := seen[s]; ok {
			return fmt.Errorf("%w: %s duplicate", ErrProvenanceMissing, path)
		}
		seen[s] = struct{}{}
	}
	return nil
}

func stringArray(raw any) []string {
	values, _ := raw.([]any)
	out := make([]string, 0, len(values))
	for _, item := range values {
		out = append(out, item.(string))
	}
	return out
}

func decodeRegistryPublicKey(value string) ([]byte, error) {
	if strings.Contains(value, "=") || !base64URLRE.MatchString(value) {
		return nil, fmt.Errorf("invalid base64url")
	}
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(raw) != ed25519.PublicKeySize || base64.RawURLEncoding.EncodeToString(raw) != value {
		return nil, fmt.Errorf("invalid base64url public key")
	}
	return raw, nil
}

func parseRegistryMillis(value string) (time.Time, error) {
	if !utcMillisRE.MatchString(value) {
		return time.Time{}, fmt.Errorf("timestamp must be UTC milliseconds")
	}
	return time.Parse("2006-01-02T15:04:05.000Z", value)
}

func loadJSONFileBounded(path string, maxBytes int64) (any, error) {
	return loadStrictJSONFileBounded(path, maxBytes)
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func contains(values []string, target string) bool {
	for _, v := range values {
		if v == target {
			return true
		}
	}
	return false
}

func mustParseSQLiteTime(v string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, v)
	if err != nil {
		return time.Time{}
	}
	return t
}
