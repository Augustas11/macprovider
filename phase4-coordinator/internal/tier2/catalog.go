package tier2

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
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

// ParsedCatalog is the verified, validated form of a tier-2 catalog file —
// the in-memory shape of one signed JSON object on disk. It is returned by
// ParseCatalog / LoadCatalog and held inside a *Catalog after Configure.
// (Previously named Catalog; renamed M3-8d so the per-coordinator state
// container could take that name. The on-disk format is unchanged.)
type ParsedCatalog struct {
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
	active     *ParsedCatalog
}

// Catalog is the per-coordinator tier-2 model-hash verification state. It
// holds whatever ParsedCatalog (if any) is currently active plus the
// bookkeeping needed to distinguish "never configured", "configured-and-
// loaded", and "configured-but-load-failed". All accessors are RLocked;
// Configure / ConfigureStrict take the write lock. M3-8d (audit TEST-4)
// promoted the previous file-scoped `var global` into this type so tests
// can construct independent instances and run in parallel and so SIGHUP
// reload can be a pointer swap rather than an in-place mutation.
type Catalog struct {
	mu sync.RWMutex
	st state
}

// NewCatalog returns an empty Catalog (configured=false, no active catalog).
// Tests construct independent instances; production code typically calls
// Default() to share the package singleton.
func NewCatalog() *Catalog {
	return &Catalog{}
}

// FixedPoolHeartbeatVerifier returns a pool.RegistryOption that wires c's
// VerifyProviderHash as the registry's HeartbeatHashVerifier. Lives in
// tier2 (not pool) because pool cannot import tier2 without a cycle.
// Equivalent to pool.WithHeartbeatHashVerifier(c.VerifyProviderHash).
//
// Semantics: this captures the *Catalog pointer eagerly. SIGHUP reload swaps
// the package-singleton via ConfigureDefaultStrict, but a verifier wired
// against an explicit *Catalog instance keeps pointing at that instance even
// after a global swap. Correct for tests passing isolated catalogs; for
// production callers that want late-binding to the current singleton, capture
// tier2.Default() per invocation rather than passing it once.
func FixedPoolHeartbeatVerifier(c *Catalog) pool.RegistryOption {
	return pool.WithHeartbeatHashVerifier(c.VerifyProviderHash)
}

var (
	defaultCatalog atomic.Pointer[Catalog]

	nowUTC = func() time.Time { return time.Now().UTC() }
)

func init() {
	defaultCatalog.Store(NewCatalog())
}

// Default returns the package-singleton Catalog. Production wiring (main.go,
// ws.Server default option, buyer.Server) reads through this so legacy call
// sites that have not been threaded with an explicit *Catalog continue to
// work. The pointer can be swapped atomically by SIGHUP reload via
// ConfigureDefaultStrict below.
func Default() *Catalog {
	return defaultCatalog.Load()
}

// setDefault atomically swaps the package-singleton Catalog. Unexported on
// purpose (M3-8d audit MEDIUM): a generic exported pointer-swap on a
// security-sensitive path (model-hash verification) is protected only by
// convention — any future caller could install an empty or stale catalog
// and bypass reload validation. Production code must go through
// ConfigureDefaultStrict, which builds + validates + swaps internally.
// nil is rejected (leaves the previous singleton unchanged).
func setDefault(c *Catalog) {
	if c == nil {
		return
	}
	defaultCatalog.Store(c)
}

// setDefaultForTest is for tier2 package tests only; do not use from
// production code. Same behavior as setDefault, but its name makes the
// test-only intent explicit at every call site.
func setDefaultForTest(c *Catalog) {
	setDefault(c)
}

// ConfigureDefaultStrict builds a fresh *Catalog, runs ConfigureStrict
// against cfg, enforces the require_hash_verified post-condition, and only
// then atomically swaps the new catalog into the package singleton. On any
// failure it returns the error without touching the existing default —
// same SIGHUP-rejection semantics as ConfigureStrict on an explicit
// *Catalog, but with the build + validate + swap encapsulated so callers
// cannot install an unvalidated catalog by skipping a step.
//
// M3-8d fixup (codex MED): this replaces the previously-exported
// SetDefault(*Catalog) shim. SetDefault was a generic atomic pointer-swap
// on a security-sensitive path (model-hash verification), protected only
// by convention — any future caller could install an empty or stale
// catalog and bypass reload validation. The swap is now an
// implementation detail of this function plus setDefaultForTest.
//
// Returns the newly-installed *Catalog on success for callers that want a
// handle to it (e.g. for an immediate Active() / Configured() probe).
func ConfigureDefaultStrict(cfg config.Tier2Config, logger zerolog.Logger) (*Catalog, error) {
	next := NewCatalog()
	if err := next.ConfigureStrict(cfg, logger); err != nil {
		return nil, err
	}
	if cfg.RequireHashVerified && !next.Active() {
		if next.Configured() {
			return nil, fmt.Errorf("tier2 config reload rejected: require_hash_verified requires an active (non-expired) catalog; the current catalog has expired or failed to load")
		}
		return nil, fmt.Errorf("tier2 config reload rejected: require_hash_verified requires a configured catalog")
	}
	setDefault(next)
	return next, nil
}

// Configure loads and activates a signed catalog on c. Preserves the previous
// active catalog if reload fails AND RequireHashVerified is off — matches the
// pre-M3-8d semantic that an operator pushing a malformed catalog over a
// known-good one does not silently disable verification.
func (c *Catalog) Configure(cfg config.Tier2Config, logger zerolog.Logger) error {
	if strings.TrimSpace(cfg.CatalogPath) == "" {
		c.mu.Lock()
		c.st = state{}
		c.mu.Unlock()
		if cfg.RequireHashVerified {
			return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog")
		}
		return nil
	}
	parsed, err := LoadCatalog(cfg.CatalogPath, cfg.CatalogPublicKey, logger)
	c.mu.Lock()
	c.st.configured = true
	c.st.loadFailed = err != nil
	if err == nil {
		c.st.active = parsed
	}
	c.mu.Unlock()
	if err != nil && cfg.RequireHashVerified {
		return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog: %w", err)
	}
	return nil
}

// ConfigureStrict is the SIGHUP-reload variant: it never preserves a stale
// catalog on parse/signature failure. A failing reload returns an error and
// leaves c's prior state untouched.
func (c *Catalog) ConfigureStrict(cfg config.Tier2Config, logger zerolog.Logger) error {
	if strings.TrimSpace(cfg.CatalogPath) == "" {
		if cfg.RequireHashVerified {
			return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog")
		}
		c.mu.Lock()
		c.st = state{}
		c.mu.Unlock()
		return nil
	}
	parsed, err := LoadCatalog(cfg.CatalogPath, cfg.CatalogPublicKey, logger)
	if err != nil {
		return fmt.Errorf("tier2 catalog reload rejected: %w", err)
	}
	c.mu.Lock()
	c.st = state{configured: true, active: parsed}
	c.mu.Unlock()
	return nil
}

// Active reports whether c currently has a non-expired ParsedCatalog loaded.
func (c *Catalog) Active() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return activeParsedLocked(c.st) != nil
}

// Configured reports whether Configure has ever been called with a non-empty
// CatalogPath on c, regardless of load outcome.
func (c *Catalog) Configured() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.st.configured
}

// LoadFailed reports whether the most recent Configure attempt failed to load
// or verify the catalog file.
func (c *Catalog) LoadFailed() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.st.loadFailed
}

// CatalogUnavailable returns true when c was configured but the catalog is
// not currently usable (load failed, or expired since load).
func (c *Catalog) CatalogUnavailable() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return catalogUnavailableLocked(c.st)
}

// Catalogued reports whether modelID is present in c's active catalog.
func (c *Catalog) Catalogued(modelID string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	parsed := activeParsedLocked(c.st)
	if parsed == nil {
		return false
	}
	_, ok := parsed.Models[catalogModelKey(modelID)]
	return ok
}

// VerifyProviderHash implements the SPEC-008 v0.3 §5.5 five-state enum
// against c's current active catalog. Behavior identical to the pre-M3-8d
// package-level function — same inputs, same outputs.
func (c *Catalog) VerifyProviderHash(modelID, reportedHash string) pool.HashStatus {
	c.mu.RLock()
	st := c.st
	c.mu.RUnlock()
	parsed := activeParsedLocked(st)
	if parsed == nil {
		if catalogUnavailableLocked(st) {
			return pool.HashStatusCatalogUnavailable
		}
		return pool.HashStatusUncatalogued
	}
	model, ok := parsed.Models[catalogModelKey(modelID)]
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

// ExpectedHashPrefix returns the 8-hex-char prefix of the catalog hash for
// modelID, or "" when not catalogued. Used in audit-log enrichment.
func (c *Catalog) ExpectedHashPrefix(modelID string) string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	parsed := activeParsedLocked(c.st)
	if parsed == nil {
		return ""
	}
	model, ok := parsed.Models[catalogModelKey(modelID)]
	if !ok {
		return ""
	}
	return hashPrefix(model.SHA256)
}

// CatalogID returns the active catalog's ID, or "" if no active catalog.
func (c *Catalog) CatalogID() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	parsed := activeParsedLocked(c.st)
	if parsed == nil {
		return ""
	}
	return parsed.CatalogID
}

// --- Package-level shims (legacy API; route to Default()) -------------------
//
// Pre-M3-8d code, including buyer.Server, cmd/coordinator/main.go, and tests
// that have not been migrated to explicit *Catalog DI, calls these. They are
// thin wrappers around the package-singleton; both styles compose because the
// shims share the same Catalog with anything wired via ws.WithCatalog(Default()).

func Configure(cfg config.Tier2Config, logger zerolog.Logger) error {
	return Default().Configure(cfg, logger)
}

func ConfigureStrict(cfg config.Tier2Config, logger zerolog.Logger) error {
	return Default().ConfigureStrict(cfg, logger)
}

func Active() bool                                                  { return Default().Active() }
func Configured() bool                                              { return Default().Configured() }
func LoadFailed() bool                                              { return Default().LoadFailed() }
func CatalogUnavailable() bool                                      { return Default().CatalogUnavailable() }
func Catalogued(modelID string) bool                                { return Default().Catalogued(modelID) }
func VerifyProviderHash(modelID, reportedHash string) pool.HashStatus {
	return Default().VerifyProviderHash(modelID, reportedHash)
}
func ExpectedHashPrefix(modelID string) string { return Default().ExpectedHashPrefix(modelID) }
func CatalogID() string                        { return Default().CatalogID() }

// ResetForTest swaps in a fresh package-singleton Catalog and restores nowUTC.
//
// Deprecated: prefer constructing a local *Catalog via NewCatalog() and
// passing it to dependent constructors via ws.WithCatalog. Retained for
// legacy tests (cmd/coordinator/main_test.go, internal/buyer/server_test.go)
// that still drive the package-level shim API.
func ResetForTest() {
	defaultCatalog.Store(NewCatalog())
	nowUTC = func() time.Time { return time.Now().UTC() }
}

// --- Stateless helpers (no Catalog state) -----------------------------------

func ConfigActive(cfg config.Tier2Config) bool {
	return ModelHashActive(cfg) ||
		cfg.RequireEncryptedLeg ||
		cfg.RequireAttestation ||
		BehavioralSafetyActive(cfg)
}

func ModelHashActive(cfg config.Tier2Config) bool {
	return cfg.ObserveEnabled ||
		strings.TrimSpace(cfg.CatalogPath) != "" ||
		cfg.RequireHashVerified
}

func PhaseForConfig(cfg config.Tier2Config) any {
	return PhaseForConfigWithModelHashEvidence(cfg, false)
}

func PhaseForConfigWithModelHashEvidence(cfg config.Tier2Config, observedModelHash bool) any {
	pillarA := strings.TrimSpace(cfg.CatalogPath) != "" ||
		cfg.RequireHashVerified ||
		(cfg.ObserveEnabled && observedModelHash)
	pillarBC := cfg.RequireEncryptedLeg || cfg.RequireAttestation
	pillarD := BehavioralSafetyActive(cfg)
	switch {
	case pillarD && pillarBC:
		return 3
	case pillarD:
		return "mixed"
	case pillarBC:
		return 2
	case pillarA:
		return 1
	default:
		return 0
	}
}

// --- LoadCatalog / ParseCatalog ---------------------------------------------

func LoadCatalog(path, publicKey string, logger zerolog.Logger) (*ParsedCatalog, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		logCatalogEvent(logger, "catalog_load_failed", "MAJOR", "", "reject", "read_failed")
		return nil, err
	}
	parsed, err := ParseCatalog(raw, publicKey)
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
	logCatalogLoaded(logger, parsed)
	return parsed, nil
}

func ParseCatalog(raw []byte, publicKey string) (*ParsedCatalog, error) {
	var file catalogFile
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&file); err != nil {
		return nil, err
	}
	var extra struct{}
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, fmt.Errorf("catalog must contain a single JSON object")
	}
	if file.Version != 1 {
		return nil, fmt.Errorf("unsupported catalog version %d", file.Version)
	}
	if strings.TrimSpace(file.CatalogID) == "" {
		return nil, fmt.Errorf("catalog_id must not be empty")
	}
	if strings.TrimSpace(file.IssuedAt) == "" {
		return nil, fmt.Errorf("issued_at must not be empty")
	}
	issuedAt, err := time.Parse(time.RFC3339, file.IssuedAt)
	if err != nil {
		return nil, fmt.Errorf("invalid issued_at: %w", err)
	}
	if len(file.Models) == 0 {
		return nil, fmt.Errorf("catalog models must not be empty")
	}
	if file.Signature.Alg != "Ed25519" {
		return nil, signatureError("unsupported catalog signature algorithm")
	}
	if strings.TrimSpace(file.Signature.KeyID) == "" {
		return nil, signatureError("catalog signature key_id must not be empty")
	}
	if strings.TrimSpace(file.Signature.Sig) == "" {
		return nil, signatureError("catalog signature sig must not be empty")
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
	if !issuedAt.Before(expiresAt) {
		return nil, fmt.Errorf("issued_at must be before expires_at")
	}
	if !nowUTC().Before(expiresAt) {
		return nil, fmt.Errorf("catalog expired")
	}
	models := make(map[string]ModelEntry, len(file.Models))
	for _, model := range file.Models {
		modelID := catalogModelKey(model.ModelID)
		if modelID == "" {
			return nil, fmt.Errorf("catalog model_id must not be empty")
		}
		if _, exists := models[modelID]; exists {
			return nil, fmt.Errorf("duplicate catalog model_id %q", model.ModelID)
		}
		if model.ArtifactKind != "mlx_weight_file" {
			return nil, fmt.Errorf("catalog artifact_kind for %q must be mlx_weight_file", model.ModelID)
		}
		switch model.HashScope {
		case "primary_weight_file", "artifact_manifest", "coordinator_endorsed_incremental":
		default:
			return nil, fmt.Errorf("catalog hash_scope for %q is unsupported", model.ModelID)
		}
		if strings.TrimSpace(model.Source) == "" {
			return nil, fmt.Errorf("catalog source for %q must not be empty", model.ModelID)
		}
		if !hashPattern.MatchString(model.SHA256) {
			return nil, fmt.Errorf("catalog sha256 for %q must be 64 lowercase hex chars", model.ModelID)
		}
		model.SHA256 = strings.ToLower(model.SHA256)
		models[modelID] = model
	}
	return &ParsedCatalog{CatalogID: file.CatalogID, ExpiresAt: expiresAt, Models: models}, nil
}

func activeParsedLocked(st state) *ParsedCatalog {
	if st.active == nil || !nowUTC().Before(st.active.ExpiresAt) {
		return nil
	}
	return st.active
}

// catalogUnavailableLocked returns true when a catalog was configured but is
// not currently usable (load failed or expired).
func catalogUnavailableLocked(st state) bool {
	return st.configured && activeParsedLocked(st) == nil && (st.loadFailed || st.active != nil)
}

func catalogModelKey(modelID string) string {
	return strings.ToLower(strings.TrimSpace(modelID))
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
	}, decision, reason, "tier2.catalog_path")
}

func LogHashRequiredProviderExcluded(logger zerolog.Logger, providerID, assignedID, modelID, reportedHash string, status pool.HashStatus) {
	logProviderEvent(logger, "hash_required_provider_excluded", "MAJOR", providerEvidence{
		ProviderID: providerID, AssignedID: assignedID, ModelID: modelID, ReportedHash: reportedHash,
	}, "exclude", string(status), "tier2.require_hash_verified")
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
	case pool.HashStatusUncatalogued:
		if Active() {
			return "model_hash_uncatalogued", "WARN", "allow", "not_catalogued", true
		}
	case pool.HashStatusMismatch:
		return "model_hash_mismatch", "MAJOR", "exclude", "hash_mismatch", true
	case pool.HashStatusInvalid:
		return "model_hash_invalid", "MAJOR", "exclude", "hash_invalid", true
	}
	return "", "", "", "", false
}

func logProviderEvent(logger zerolog.Logger, event, severity string, evidence providerEvidence, decision, reason, configFlag string) {
	logger.WithLevel(levelForSeverity(severity)).
		Str("event", event).
		Str("category", "T2.A").
		Str("severity", severity).
		Str("request_id", "").
		Str("provider_id", evidence.ProviderID).
		Str("assigned_id", evidence.AssignedID).
		Str("model_id", evidence.ModelID).
		Int("tier2_phase", 1).
		Str("pillar", "A").
		Str("reported_hash_prefix", hashPrefix(evidence.ReportedHash)).
		Str("expected_hash_prefix", ExpectedHashPrefix(evidence.ModelID)).
		Str("catalog_id", CatalogID()).
		Str("decision", decision).
		Str("reason", reason).
		Str("config_flag", configFlag).
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 model hash event")
}

func logCatalogEvent(logger zerolog.Logger, event, severity, catalogID, decision, reason string) {
	logger.WithLevel(levelForSeverity(severity)).
		Str("event", event).
		Str("category", "T2.A").
		Str("severity", severity).
		Str("request_id", "").
		Str("provider_id", "").
		Str("assigned_id", "").
		Str("model_id", "").
		Int("tier2_phase", 1).
		Str("pillar", "A").
		Str("reported_hash_prefix", "").
		Str("expected_hash_prefix", "").
		Str("catalog_id", catalogID).
		Str("decision", decision).
		Str("reason", reason).
		Str("config_flag", "tier2.catalog_path").
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 catalog event")
}

func logCatalogLoaded(logger zerolog.Logger, parsed *ParsedCatalog) {
	if parsed == nil {
		return
	}
	logger.Info().
		Str("event", "catalog_loaded").
		Str("category", "T2.A").
		Str("severity", "INFO").
		Str("request_id", "").
		Str("provider_id", "").
		Str("assigned_id", "").
		Str("model_id", "").
		Int("tier2_phase", 1).
		Str("pillar", "A").
		Str("reported_hash_prefix", "").
		Str("expected_hash_prefix", "").
		Str("catalog_id", parsed.CatalogID).
		Int("model_count", len(parsed.Models)).
		Time("expires_at", parsed.ExpiresAt).
		Str("decision", "allow").
		Str("reason", "catalog_loaded").
		Str("config_flag", "tier2.catalog_path").
		Str("ts", time.Now().UTC().Format(time.RFC3339Nano)).
		Msg("tier2 catalog loaded")
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
