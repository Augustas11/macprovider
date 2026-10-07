package sourceevidence

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
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
)

var (
	runIDRE      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	nonceRE      = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	lookupIDRE   = regexp.MustCompile(`^[ -~]{1,128}$`)
	requestIDRE  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	keyIDRE      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	instanceIDRE = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
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
	registry, err := loadJSONFileBounded(prov.ReviewedRegistryPath, defaultMaxBodyBytes)
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
	for _, scope := range req.Scopes {
		resolved, err := p.store.ResolveClosed(ctx, scope)
		if err != nil {
			return ExportEnvelope{}, fmt.Errorf("%w: %v", ErrScopeNotClosed, err)
		}
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

type reviewedRegistry struct {
	SchemaVersion string                `json:"schema_version"`
	Keys          []reviewedRegistryKey `json:"keys"`
}

type reviewedRegistryKey struct {
	KeyID                     string                    `json:"key_id"`
	Algorithm                 string                    `json:"algorithm"`
	PublicKey                 string                    `json:"public_key"`
	Producer                  string                    `json:"producer"`
	InstanceID                string                    `json:"instance_id"`
	PermittedRoles            []string                  `json:"permitted_roles"`
	PermittedDomains          []string                  `json:"permitted_domains"`
	NotBefore                 string                    `json:"not_before"`
	NotAfter                  string                    `json:"not_after"`
	RevokedAt                 *string                   `json:"revoked_at"`
	ReviewedSourceConstraints reviewedSourceConstraints `json:"reviewed_source_constraints"`
}

type reviewedSourceConstraints struct {
	SourceSHAAllowlist []string `json:"source_sha_allowlist"`
}

func authorizeRegistryKey(registry any, prov FixedProvenance, publicKey ed25519.PublicKey) error {
	b, err := json.Marshal(registry)
	if err != nil {
		return err
	}
	var parsed reviewedRegistry
	if err := json.Unmarshal(b, &parsed); err != nil {
		return err
	}
	var selected *reviewedRegistryKey
	seen := map[string]struct{}{}
	for i := range parsed.Keys {
		key := &parsed.Keys[i]
		if !keyIDRE.MatchString(key.KeyID) {
			return fmt.Errorf("%w: invalid registry key id", ErrProvenanceMissing)
		}
		if _, ok := seen[key.KeyID]; ok {
			return fmt.Errorf("%w: duplicate registry key id", ErrProvenanceMissing)
		}
		seen[key.KeyID] = struct{}{}
		if key.KeyID == prov.KeyID {
			selected = key
		}
	}
	if selected == nil {
		return fmt.Errorf("%w: key id not in registry", ErrProvenanceMissing)
	}
	if selected.Algorithm != "ed25519" || selected.Producer != ProducerName || selected.InstanceID != prov.InstanceID || !instanceIDRE.MatchString(selected.InstanceID) {
		return fmt.Errorf("%w: key identity not authorized", ErrProvenanceMissing)
	}
	pub, err := base64.RawURLEncoding.DecodeString(selected.PublicKey)
	if err != nil || !ed25519.PublicKey(pub).Equal(publicKey) {
		return fmt.Errorf("%w: key public material mismatch", ErrProvenanceMissing)
	}
	if !contains(selected.PermittedRoles, ProducerRole) || !contains(selected.PermittedDomains, SignDomain) || !contains(selected.ReviewedSourceConstraints.SourceSHAAllowlist, prov.SourceSHA) {
		return fmt.Errorf("%w: key constraints do not authorize producer", ErrProvenanceMissing)
	}
	now := prov.Now().UTC()
	notBefore, err := time.Parse(time.RFC3339, selected.NotBefore)
	if err != nil {
		notBefore, err = time.Parse("2006-01-02T15:04:05.000Z", selected.NotBefore)
	}
	if err != nil {
		return fmt.Errorf("%w: key not_before invalid", ErrProvenanceMissing)
	}
	notAfter, err := time.Parse(time.RFC3339, selected.NotAfter)
	if err != nil {
		notAfter, err = time.Parse("2006-01-02T15:04:05.000Z", selected.NotAfter)
	}
	if err != nil {
		return fmt.Errorf("%w: key not_after invalid", ErrProvenanceMissing)
	}
	if now.Before(notBefore) || !now.Before(notAfter) {
		return fmt.Errorf("%w: selected key inactive", ErrProvenanceMissing)
	}
	if selected.RevokedAt != nil && strings.TrimSpace(*selected.RevokedAt) != "" {
		revokedAt, err := time.Parse(time.RFC3339, *selected.RevokedAt)
		if err != nil {
			revokedAt, err = time.Parse("2006-01-02T15:04:05.000Z", *selected.RevokedAt)
		}
		if err != nil || !now.Before(revokedAt) {
			return fmt.Errorf("%w: selected key revoked", ErrProvenanceMissing)
		}
	}
	return nil
}

func loadJSONFileBounded(path string, maxBytes int64) (any, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("path is required")
	}
	if maxBytes <= 0 {
		maxBytes = defaultMaxBodyBytes
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, maxBytes+1))
	dec.UseNumber()
	var out any
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	if dec.InputOffset() > maxBytes {
		return nil, fmt.Errorf("json file too large")
	}
	if err := validateCanonical(out); err != nil {
		return nil, err
	}
	return out, nil
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
