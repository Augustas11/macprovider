package tier2

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Signature struct {
	Alg   string `json:"alg"`
	KeyID string `json:"key_id"`
	Sig   string `json:"sig"`
}

type ModelEntry struct {
	ArtifactKind string `json:"artifact_kind"`
	HashScope    string `json:"hash_scope"`
	ModelID      string `json:"model_id"`
	Notes        string `json:"notes,omitempty"`
	SHA256       string `json:"sha256"`
	Source       string `json:"source"`
}

type Catalog struct {
	CatalogID string
	ExpiresAt time.Time
	Models    map[string]ModelEntry
}

type HashCounts struct {
	Verified     int
	Uncatalogued int
	Mismatch     int
	Invalid      int
}

type providerEvidence struct {
	ProviderID   string
	AssignedID   string
	ModelID      string
	ReportedHash string
}

type catalogFile struct {
	CatalogID string       `json:"catalog_id"`
	ExpiresAt string       `json:"expires_at"`
	IssuedAt  string       `json:"issued_at"`
	Models    []ModelEntry `json:"models"`
	Signature Signature    `json:"signature"`
	Version   int          `json:"version"`
}

type canonicalBody struct {
	CatalogID string       `json:"catalog_id"`
	ExpiresAt string       `json:"expires_at"`
	IssuedAt  string       `json:"issued_at"`
	Models    []ModelEntry `json:"models"`
	Version   int          `json:"version"`
}

type state struct {
	configured bool
	loadFailed bool
	active     *Catalog
}

var global = struct {
	mu sync.RWMutex
	st state
}{}

func Configure(cfg config.Tier2Config, logger zerolog.Logger) error {
	if strings.TrimSpace(cfg.CatalogPath) == "" {
		global.mu.Lock()
		global.st = state{}
		global.mu.Unlock()
		if cfg.RequireHashVerified {
			return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog")
		}
		return nil
	}
	catalog, err := LoadCatalog(cfg.CatalogPath, cfg.CatalogPublicKey, logger)
	global.mu.Lock()
	global.st.configured = true
	global.st.loadFailed = err != nil
	if err == nil {
		global.st.active = catalog
	} else {
		global.st.active = nil
	}
	global.mu.Unlock()
	if err != nil && cfg.RequireHashVerified {
		return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog: %w", err)
	}
	return nil
}

func ResetForTest() {
	global.mu.Lock()
	global.st = state{}
	global.mu.Unlock()
}

func LoadCatalog(path, publicKey string, logger zerolog.Logger) (*Catalog, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		logCatalogEvent(logger, "catalog_load_failed", "MAJOR", "", "reject", "read_failed")
		return nil, err
	}
	catalog, err := ParseCatalog(raw, publicKey)
	if err != nil {
		event := "catalog_load_failed"
		reason := "parse_failed"
		if isSignatureError(err) {
			event = "catalog_signature_invalid"
			reason = "signature_invalid"
		}
		logCatalogEvent(logger, event, "MAJOR", catalogIDFromRaw(raw), "reject", reason)
		return nil, err
	}
	return catalog, nil
}

func ParseCatalog(raw []byte, publicKey string) (*Catalog, error) {
	var file catalogFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, err
	}
	if file.Version != 1 {
		return nil, fmt.Errorf("unsupported catalog version %d", file.Version)
	}
	if file.Signature.Alg != "Ed25519" {
		return nil, signatureError("unsupported catalog signature algorithm")
	}
	pub, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(publicKey))
	if err != nil {
		return nil, signatureError("invalid catalog public key")
	}
	if len(pub) != ed25519.PublicKeySize {
		return nil, signatureError("invalid catalog public key length")
	}
	sig, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(file.Signature.Sig))
	if err != nil {
		return nil, signatureError("invalid catalog signature encoding")
	}
	if len(sig) != ed25519.SignatureSize {
		return nil, signatureError("invalid catalog signature length")
	}
	body := canonicalBody{
		CatalogID: file.CatalogID,
		ExpiresAt: file.ExpiresAt,
		IssuedAt:  file.IssuedAt,
		Models:    file.Models,
		Version:   file.Version,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), canonical, sig) {
		return nil, signatureError("catalog signature invalid")
	}
	expiresAt, err := time.Parse(time.RFC3339, file.ExpiresAt)
	if err != nil {
		return nil, fmt.Errorf("invalid expires_at: %w", err)
	}
	if !time.Now().UTC().Before(expiresAt) {
		return nil, fmt.Errorf("catalog expired")
	}
	models := make(map[string]ModelEntry, len(file.Models))
	for _, model := range file.Models {
		if model.ModelID == "" {
			return nil, fmt.Errorf("catalog model_id must not be empty")
		}
		if !hashPattern.MatchString(model.SHA256) {
			return nil, fmt.Errorf("catalog sha256 for %q must be 64 lowercase hex chars", model.ModelID)
		}
		model.SHA256 = strings.ToLower(model.SHA256)
		models[model.ModelID] = model
	}
	return &Catalog{CatalogID: file.CatalogID, ExpiresAt: expiresAt, Models: models}, nil
}

func Active() bool {
	global.mu.RLock()
	defer global.mu.RUnlock()
	return global.st.active != nil
}

func Configured() bool {
	global.mu.RLock()
	defer global.mu.RUnlock()
	return global.st.configured
}

func LoadFailed() bool {
	global.mu.RLock()
	defer global.mu.RUnlock()
	return global.st.loadFailed
}

func Catalogued(modelID string) bool {
	global.mu.RLock()
	defer global.mu.RUnlock()
	if global.st.active == nil {
		return false
	}
	_, ok := global.st.active.Models[modelID]
	return ok
}

func VerifyProviderHash(modelID, reportedHash string) pool.HashStatus {
	global.mu.RLock()
	st := global.st
	global.mu.RUnlock()
	if st.active == nil {
		if st.configured && st.loadFailed {
			return pool.HashStatusCatalogUnavailable
		}
		return pool.HashStatusUncatalogued
	}
	model, ok := st.active.Models[modelID]
	if !ok || strings.TrimSpace(reportedHash) == "" {
		return pool.HashStatusUncatalogued
	}
	reported := strings.TrimSpace(reportedHash)
	if !hashPattern.MatchString(reported) {
		return pool.HashStatusInvalid
	}
	reported = strings.ToLower(reported)
	if strings.EqualFold(reported, model.SHA256) {
		return pool.HashStatusVerified
	}
	return pool.HashStatusMismatch
}

func ExpectedHashPrefix(modelID string) string {
	global.mu.RLock()
	defer global.mu.RUnlock()
	if global.st.active == nil {
		return ""
	}
	model, ok := global.st.active.Models[modelID]
	if !ok {
		return ""
	}
	return hashPrefix(model.SHA256)
}

func CatalogID() string {
	global.mu.RLock()
	defer global.mu.RUnlock()
	if global.st.active == nil {
		return ""
	}
	return global.st.active.CatalogID
}

func CountsForProviders(modelID string, providers []pool.Provider) HashCounts {
	var counts HashCounts
	for _, provider := range providers {
		if !strings.EqualFold(provider.ModelID, modelID) {
			continue
		}
		switch normalizedStatus(provider.HashStatus) {
		case pool.HashStatusVerified:
			counts.Verified++
		case pool.HashStatusMismatch:
			counts.Mismatch++
		case pool.HashStatusInvalid:
			counts.Invalid++
		default:
			counts.Uncatalogued++
		}
	}
	return counts
}

func LogProviderHashStatus(logger zerolog.Logger, providerID, assignedID, modelID, reportedHash string, status pool.HashStatus) {
	event, severity, decision, reason, ok := providerHashEvent(status)
	if !ok {
		return
	}
	logProviderEvent(logger, event, severity, providerEvidence{
		ProviderID: providerID, AssignedID: assignedID, ModelID: modelID, ReportedHash: reportedHash,
	}, decision, reason)
}

func LogHashRequiredProviderExcluded(logger zerolog.Logger, providerID, assignedID, modelID, reportedHash string, status pool.HashStatus) {
	logProviderEvent(logger, "hash_required_provider_excluded", "MAJOR", providerEvidence{
		ProviderID: providerID, AssignedID: assignedID, ModelID: modelID, ReportedHash: reportedHash,
	}, "exclude", string(status))
}

func IsHashPredicateFailure(status pool.HashStatus, requireHashVerified bool) bool {
	status = normalizedStatus(status)
	if status == pool.HashStatusMismatch || status == pool.HashStatusInvalid {
		return true
	}
	return requireHashVerified && status != pool.HashStatusVerified
}

func normalizedStatus(status pool.HashStatus) pool.HashStatus {
	if status == "" {
		return pool.HashStatusUncatalogued
	}
	return status
}

func providerHashEvent(status pool.HashStatus) (event, severity, decision, reason string, ok bool) {
	switch status {
	case pool.HashStatusVerified:
		return "model_hash_verified", "INFO", "allow", "hash_match", true
	case pool.HashStatusMismatch:
		return "model_hash_mismatch", "MAJOR", "exclude", "hash_mismatch", true
	case pool.HashStatusInvalid:
		return "model_hash_invalid", "MAJOR", "exclude", "hash_invalid", true
	default:
		return "", "", "", "", false
	}
}

func logProviderEvent(logger zerolog.Logger, event, severity string, evidence providerEvidence, decision, reason string) {
	logger.WithLevel(levelForSeverity(severity)).
		Str("event", event).
		Str("category", "T2.A").
		Str("severity", severity).
		Str("provider_id", evidence.ProviderID).
		Str("assigned_id", evidence.AssignedID).
		Str("model_id", evidence.ModelID).
		Str("reported_hash_prefix", hashPrefix(evidence.ReportedHash)).
		Str("expected_hash_prefix", ExpectedHashPrefix(evidence.ModelID)).
		Str("catalog_id", CatalogID()).
		Str("decision", decision).
		Str("reason", reason).
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 model hash event")
}

func logCatalogEvent(logger zerolog.Logger, event, severity, catalogID, decision, reason string) {
	logger.WithLevel(levelForSeverity(severity)).
		Str("event", event).
		Str("category", "T2.A").
		Str("severity", severity).
		Str("provider_id", "").
		Str("assigned_id", "").
		Str("model_id", "").
		Str("reported_hash_prefix", "").
		Str("expected_hash_prefix", "").
		Str("catalog_id", catalogID).
		Str("decision", decision).
		Str("reason", reason).
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 catalog event")
}

func levelForSeverity(severity string) zerolog.Level {
	switch severity {
	case "INFO":
		return zerolog.InfoLevel
	case "MAJOR":
		return zerolog.ErrorLevel
	default:
		return zerolog.WarnLevel
	}
}

func hashPrefix(hash string) string {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if len(hash) < 8 {
		return ""
	}
	prefix := hash[:8]
	for _, ch := range prefix {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return ""
		}
	}
	return prefix
}

func catalogIDFromRaw(raw []byte) string {
	var header struct {
		CatalogID string `json:"catalog_id"`
	}
	if err := json.Unmarshal(raw, &header); err != nil {
		return ""
	}
	return header.CatalogID
}

type signatureError string

func (e signatureError) Error() string { return string(e) }

func isSignatureError(err error) bool {
	_, ok := err.(signatureError)
	return ok
}
