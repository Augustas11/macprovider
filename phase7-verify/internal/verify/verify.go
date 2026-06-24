// Package verify orchestrates SPEC-015 receipt verification.
package verify

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/cache"
	"github.com/augstar/macprovider/phase7-verify/internal/canon"
	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
	"github.com/augstar/macprovider/phase7-verify/internal/resolver"
)

const (
	resultValid        = "valid"
	resultInvalid      = "invalid"
	resultInconclusive = "inconclusive"

	reasonValid                         = "signature_and_canonicalization_match"
	reasonSignatureFailed               = "signature_verify_failed"
	reasonPromptHashMismatch            = "prompt_hash_mismatch"
	reasonOutputHashMismatch            = "output_hash_mismatch"
	reasonPubkeyNotEndorsed             = "pubkey_not_endorsed"
	reasonPreviousKeyOutsideGraceWindow = "previous_key_outside_grace_window"
	// FORWARD-COMPAT v0.3+: reserved enum value. The v0.2 verifier does NOT emit this reason;
	// the Step 9 preflight that previously emitted it was removed because it falsely rejected
	// valid previous-key-in-grace receipts (see internal/verify/implementation-notes.md).
	// A future spec revision may define a narrower bundle-layer detection that distinguishes
	// intra-bundle identity drift. Do NOT delete this constant without a coordinated removal
	// from schemas/output.schema.json and a SPEC-015 enum deprecation note.
	reasonBundlePubkeyProviderMismatch  = "bundle_pubkey_provider_mismatch"
	reasonPubkeyUnresolvable            = "pubkey_unresolvable"
	reasonCacheStaleAndLiveUnreachable  = "cache_stale_and_live_unreachable"
	reasonProviderIDNotInPool           = "provider_id_not_in_pool"
	warningReasonProviderIDUnresolvable = "provider_id_unresolvable"

	// SPEC-015 v0.3 §M.3.2.1 — new reason enum values.
	reasonModelHashMismatch       = "model_hash_mismatch"
	reasonModelHashRequired       = "model_hash_required"
	reasonModelIDNotInCatalog     = "model_id_not_in_catalog"
	reasonCatalogSignatureInvalid = "catalog_signature_invalid"
	reasonCatalogUnreachable      = "catalog_unreachable"
	reasonCatalogExpired          = "catalog_expired"
	reasonCatalogFormatInvalid    = "catalog_format_invalid"
	reasonUnknownReceiptVersion   = "unknown_receipt_version"
	reasonExtraField              = "extra_field"
	reasonMissingField            = "missing_field"

	// SPEC-015 v0.3 §M.3.2.1 — new warning kinds.
	warningCatalogSkippedNullHash      = "catalog_skipped_null_hash"
	warningCatalogSkippedLegacyReceipt = "catalog_skipped_legacy_receipt"

	defaultCoordinatorHost = "coordinator.streamvc.live"
	clockSkewThreshold     = 24 * time.Hour
	graceWindowSlack       = 60 * time.Second
)

// VerifyInput is the set of buyer-held artifacts needed for verification.
// Either Header OR (TupleRaw + Signature) is sufficient (Step 7 will wire
// from CLI flags or bundle decoding).
type VerifyInput struct {
	Header             string         // X-MacProvider-Receipt header value (preferred input)
	TupleRaw           []byte         // decoded base64(JCS(tuple)); used only when Header is empty
	Signature          []byte         // decoded ed25519 signature; used only when Header is empty
	Request            map[string]any // raw OpenAI request body (for hash recomputation)
	Response           map[string]any // raw OpenAI completion response (for hash recomputation)
	ExplicitPromptHash []byte         // optional pre-computed --prompt-hash override (32 bytes)
	ExplicitOutputHash []byte         // optional pre-computed --output-hash override (32 bytes)
	ExplicitPubkey     []byte         // optional --pubkey override (32 bytes)
	ProviderID         string         // resolved provider_id (from CLI, bundle, or single-match cache)
}

// VerifyOpts threads through resolver options + system clock.
type VerifyOpts struct {
	Offline         bool         // --offline
	Quiet           bool         // --quiet (warnings still recorded, JSON only)
	CoordinatorHost string       // configured coordinator host
	Cache           *cache.Cache // injected cache (nil -> use default)
	Now             func() time.Time
	HTTPClient      *http.Client // injectable for tests

	// SPEC-015 v0.3 §M.3 — catalog-check options. Enabled is true
	// when all four flag-mode preconditions hold (catalog + pubkey
	// both supplied, mutual-exclusion respected, --offline check
	// passed). Path / URL describe how to resolve catalog bytes;
	// Pubkey / PubkeyURL describe how to resolve the pubkey.
	Catalog CatalogOpts
	// SPEC-015 v0.3 §M.3.1.2 — fail-closed flag on null model_hash.
	RequireModelHash bool
}

// CatalogOpts is the resolved catalog-check configuration. Exactly
// one of (Path, URL) is non-empty when Enabled; exactly one of
// (Pubkey != nil, PubkeyURL != "") when Enabled.
type CatalogOpts struct {
	Enabled   bool
	Path      string
	URL       string
	Pubkey    []byte // 32-byte raw ed25519 public key (already decoded)
	PubkeyURL string
}

// Result is one verification outcome, mirroring SPEC-015 section 10.4.2.
type Result struct {
	Result          string    `json:"result"`
	Reason          string    `json:"reason"`
	ProviderID      string    `json:"provider_id,omitempty"`
	ModelID         string    `json:"model_id,omitempty"`
	SignedAt        int64     `json:"signed_at,omitempty"`
	TrustSource     string    `json:"trust_source"`
	CoordinatorHost string    `json:"coordinator_host,omitempty"`
	Details         *Details  `json:"details,omitempty"`
	Warnings        []Warning `json:"warnings,omitempty"`
	// SPEC-015 v0.3 §M.3.2.1 — tri-state. true = catalog check ran
	// and hash matched; false = catalog check ran and mismatched
	// (or --require-model-hash with null hash); nil = catalog check
	// did NOT run (no catalog flags / null hash / legacy receipt /
	// unknown receipt_version / catalog fetch failure).
	ModelHashVerified *bool `json:"model_hash_verified"`
	// ReceiptVersion is "1" for v0.1/v0.2 legacy or "3" for v0.3.
	// Emitted on every output for diagnostic clarity.
	ReceiptVersion string `json:"receipt_version,omitempty"`
}

type Details struct {
	Field    string         `json:"field"`
	Computed string         `json:"computed,omitempty"`
	Receipt  string         `json:"receipt,omitempty"`
	Extra    map[string]any `json:"extra,omitempty"`

	// SPEC-015 v0.3 §M.3.2.1 — named top-level fields for the v0.3
	// reason-specific details contract. Empty strings are omitted
	// by the CLI JSON renderer to avoid emitting noise on
	// non-v0.3 reasons.
	Expected       string `json:"expected,omitempty"`         // model_hash_mismatch
	Actual         string `json:"actual,omitempty"`           // model_hash_mismatch
	PolicyFlag     string `json:"policy_flag,omitempty"`      // model_hash_required
	ModelID        string `json:"model_id,omitempty"`         // model_id_not_in_catalog
	CatalogID      string `json:"catalog_id,omitempty"`       // catalog_expired
	ExpiresAt      string `json:"expires_at,omitempty"`       // catalog_expired (RFC3339)
	ReceiptVersion string `json:"receipt_version,omitempty"`  // unknown_receipt_version
	Cause          string `json:"cause,omitempty"`            // catalog_format_invalid / catalog_signature_invalid
	URL            string `json:"url,omitempty"`              // catalog_unreachable
	Alg            string `json:"alg,omitempty"`              // catalog_signature_invalid (observed alg)
}

// Warning re-exports resolver.Warning shape for symmetry; verify adds
// clock_skew because resolver does not have receipt unix_ts in scope.
type Warning struct {
	Kind   string         `json:"kind"`
	Fields map[string]any `json:"fields,omitempty"`
}

func (r Result) MarshalJSON() ([]byte, error) {
	type resultJSON struct {
		Result            string    `json:"result"`
		Reason            string    `json:"reason"`
		ProviderID        *string   `json:"provider_id"`
		ModelID           string    `json:"model_id,omitempty"`
		SignedAt          int64     `json:"signed_at,omitempty"`
		TrustSource       string    `json:"trust_source"`
		CoordinatorHost   string    `json:"coordinator_host,omitempty"`
		ModelHashVerified *bool     `json:"model_hash_verified"`
		ReceiptVersion    string    `json:"receipt_version,omitempty"`
		Details           *Details  `json:"details,omitempty"`
		Warnings          []Warning `json:"warnings,omitempty"`
	}
	out := resultJSON{
		Result:            r.Result,
		Reason:            r.Reason,
		ModelID:           r.ModelID,
		SignedAt:          r.SignedAt,
		TrustSource:       r.TrustSource,
		CoordinatorHost:   r.CoordinatorHost,
		ModelHashVerified: r.ModelHashVerified,
		ReceiptVersion:    r.ReceiptVersion,
		Details:           r.Details,
		Warnings:          r.Warnings,
	}
	if r.ProviderID != "" {
		out.ProviderID = &r.ProviderID
	}
	return json.Marshal(out)
}

func (w Warning) MarshalJSON() ([]byte, error) {
	out := make(map[string]any, len(w.Fields)+1)
	out["kind"] = w.Kind
	for key, value := range w.Fields {
		out[key] = value
	}
	return json.Marshal(out)
}

// InputFormatError marks receipt/bundle data that the verifier cannot parse.
// Step 7 maps this class to exit 65.
type InputFormatError struct {
	Err error
}

func (e *InputFormatError) Error() string {
	return "input format error: " + e.Err.Error()
}

func (e *InputFormatError) Unwrap() error {
	return e.Err
}

// UsageError marks malformed invocation-level input. Step 7 maps this class
// to exit 64.
type UsageError struct {
	Err error
}

func (e *UsageError) Error() string {
	return "usage error: " + e.Err.Error()
}

func (e *UsageError) Unwrap() error {
	return e.Err
}

// Verify runs the SPEC-015 section 10.0 algorithm and returns exactly one
// tri-state Result, or a typed error for caller/format failures that occur
// before the receipt can be evaluated.
func Verify(input VerifyInput, opts VerifyOpts) (Result, error) {
	now := time.Now
	if opts.Now != nil {
		now = opts.Now
	}

	parsed, err := parseInput(input)
	if err != nil {
		// SPEC-015 §M.0 / §M.3.2.1 — v0.3 strict-shape parse failures
		// (extra/missing tuple keys) MUST be reported as JSON
		// `invalid` with the named reason, not as exit-65 input format
		// errors. The receipt parser distinguishes these via typed
		// sentinel errors.
		if r, ok := shapeErrorToInvalidResult(err); ok {
			return r, nil
		}
		return Result{}, err
	}
	// SPEC-015 §M.1.4 — forward-compat: a v0.3 verifier reading an
	// unknown receipt_version MUST NOT canonicalize / signature-check.
	// Report inconclusive: unknown_receipt_version, exit code 2,
	// `details.receipt_version` populated.
	if rv := parsed.Tuple.ReceiptVersion; rv != "" && rv != "3" {
		f := (*bool)(nil)
		return Result{
			Result:            resultInconclusive,
			Reason:            reasonUnknownReceiptVersion,
			TrustSource:       string(resolver.SourceNone),
			ReceiptVersion:    rv,
			ModelHashVerified: f,
			Details: &Details{
				Field:          "receipt_version",
				ReceiptVersion: rv,
			},
		}, nil
	}
	base := Result{
		ProviderID: input.ProviderID,
		ModelID:    parsed.Tuple.ModelID,
		SignedAt:   parsed.Tuple.UnixTS,
	}

	cacheForResolve, err := resolveCache(opts.Cache)
	if err != nil {
		return Result{}, err
	}
	root, err := resolver.Resolve(input.ProviderID, input.ExplicitPubkey, resolver.ResolveOpts{
		Offline:         opts.Offline,
		Quiet:           opts.Quiet,
		CoordinatorHost: opts.CoordinatorHost,
		Cache:           cacheForResolve,
		Now:             now,
		HTTPClient:      opts.HTTPClient,
	})
	base.Warnings = convertWarnings(root.Warnings)
	base.TrustSource = string(root.TrustSource)
	base.CoordinatorHost = resultCoordinatorHost(root)
	if errors.Is(err, resolver.ErrProviderNotInPool) {
		return inconclusive(base, reasonProviderIDNotInPool), nil
	}
	if err != nil {
		return Result{}, err
	}
	if root.TrustSource == resolver.SourceNone {
		reason := sourceNoneReason(input.ProviderID, opts, cacheForResolve, root.Warnings, now())
		if reason == reasonCacheStaleAndLiveUnreachable {
			base.CoordinatorHost = normalizedCoordinatorHost(opts.CoordinatorHost)
		}
		return inconclusive(base, reason), nil
	}

	trustedPubkey, invalidResult := trustedVerificationKey(parsed, root)
	if invalidResult != nil {
		invalidResult.ProviderID = base.ProviderID
		invalidResult.ModelID = base.ModelID
		invalidResult.SignedAt = base.SignedAt
		invalidResult.TrustSource = base.TrustSource
		invalidResult.CoordinatorHost = base.CoordinatorHost
		invalidResult.Warnings = base.Warnings
		return *invalidResult, nil
	}

	if err := receipt.Verify(parsed, trustedPubkey); err != nil {
		if errors.Is(err, receipt.ErrSignatureFailed) || errors.Is(err, receipt.ErrPubkeyLength) {
			return invalid(base, reasonSignatureFailed, Details{Field: "signature", Receipt: base64.StdEncoding.EncodeToString(parsed.Signature)}), nil
		}
		return Result{}, err
	}

	promptHash, err := computedPromptHash(input)
	if err != nil {
		return Result{}, err
	}
	computedPrompt := hex.EncodeToString(promptHash)
	if computedPrompt != parsed.Tuple.PromptHash {
		return invalid(base, reasonPromptHashMismatch, Details{
			Field:    "prompt_hash",
			Computed: computedPrompt,
			Receipt:  parsed.Tuple.PromptHash,
		}), nil
	}

	outputHash, err := computedOutputHash(input)
	if err != nil {
		return Result{}, err
	}
	computedOutput := hex.EncodeToString(outputHash)
	if computedOutput != parsed.Tuple.OutputHash {
		return invalid(base, reasonOutputHashMismatch, Details{
			Field:    "output_hash",
			Computed: computedOutput,
			Receipt:  parsed.Tuple.OutputHash,
		}), nil
	}

	base.Warnings = append(base.Warnings, clockSkewWarning(parsed.Tuple.UnixTS, now())...)

	// SPEC-015 §M.0 — emit receipt_version for diagnostic clarity.
	// Legacy v0.1/v0.2 receipts are tagged "1" (per §M.1.1 the
	// verifier treats absent receipt_version as the implicit v0.1
	// shape).
	if parsed.Tuple.ReceiptVersion != "" {
		base.ReceiptVersion = parsed.Tuple.ReceiptVersion
	} else {
		base.ReceiptVersion = "1"
	}

	// SPEC-015 §M.3 — catalog-check + §M.1.1 back-compat warning +
	// §M.3.1.2 --require-model-hash policy gate. The catalog-check
	// short-circuits on a wrong hash, missing model_id, expired
	// catalog, fetch failure, etc., per §M.3.2 steps 1-8.
	catalogVerdict := applyCatalogCheck(parsed, opts, now())
	base.Warnings = append(base.Warnings, catalogVerdict.Warnings...)
	base.ModelHashVerified = catalogVerdict.ModelHashVerified
	if catalogVerdict.Result != "" {
		// Catalog short-circuited the result (invalid /
		// inconclusive). Propagate the verdict + details.
		base.Result = catalogVerdict.Result
		base.Reason = catalogVerdict.Reason
		base.Details = catalogVerdict.Details
		return base, nil
	}

	base.Result = resultValid
	base.Reason = reasonValid
	return base, nil
}

func computedPromptHash(input VerifyInput) ([]byte, error) {
	if len(input.ExplicitPromptHash) > 0 {
		if len(input.ExplicitPromptHash) != 32 {
			return nil, &UsageError{Err: fmt.Errorf("explicit prompt hash must be 32 bytes, got %d", len(input.ExplicitPromptHash))}
		}
		return cloneBytes(input.ExplicitPromptHash), nil
	}
	_, promptHash, err := canon.CanonicalPrompt(input.Request)
	if err != nil {
		return nil, &UsageError{Err: fmt.Errorf("canonicalize request: %w", err)}
	}
	return promptHash[:], nil
}

func computedOutputHash(input VerifyInput) ([]byte, error) {
	if len(input.ExplicitOutputHash) > 0 {
		if len(input.ExplicitOutputHash) != 32 {
			return nil, &UsageError{Err: fmt.Errorf("explicit output hash must be 32 bytes, got %d", len(input.ExplicitOutputHash))}
		}
		return cloneBytes(input.ExplicitOutputHash), nil
	}
	_, outputHash, err := canon.CanonicalOutput(input.Response)
	if err != nil {
		return nil, &UsageError{Err: fmt.Errorf("canonicalize response: %w", err)}
	}
	return outputHash[:], nil
}

// shapeErrorToInvalidResult maps tuple-shape parse errors to a JSON
// `invalid` result with the §M.3.2.1 reason enum. Returns (Result,
// true) if the err is shape-shape (extra/missing key); (Result,
// false) otherwise (caller should propagate the error).
func shapeErrorToInvalidResult(err error) (Result, bool) {
	if err == nil {
		return Result{}, false
	}
	var ifErr *InputFormatError
	if !errors.As(err, &ifErr) {
		return Result{}, false
	}
	inner := ifErr.Err
	switch {
	case errors.Is(inner, receipt.ErrTupleExtraKey):
		return Result{
			Result:      resultInvalid,
			Reason:      reasonExtraField,
			TrustSource: string(resolver.SourceNone),
			Details:     &Details{Field: extractTupleErrorField(inner)},
		}, true
	case errors.Is(inner, receipt.ErrTupleMissingKey):
		return Result{
			Result:      resultInvalid,
			Reason:      reasonMissingField,
			TrustSource: string(resolver.SourceNone),
			Details:     &Details{Field: extractTupleErrorField(inner)},
		}, true
	}
	return Result{}, false
}

func extractTupleErrorField(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if idx := strings.LastIndex(s, ": "); idx >= 0 {
		return s[idx+2:]
	}
	return ""
}

func parseInput(input VerifyInput) (receipt.Parsed, error) {
	if input.Header != "" {
		parsed, err := receipt.Parse(input.Header)
		if err != nil {
			return receipt.Parsed{}, &InputFormatError{Err: err}
		}
		return parsed, nil
	}
	if len(input.TupleRaw) == 0 || len(input.Signature) == 0 {
		return receipt.Parsed{}, &UsageError{Err: errors.New("receipt header or tuple/signature is required")}
	}
	header := base64.StdEncoding.EncodeToString(input.TupleRaw) + "." + base64.StdEncoding.EncodeToString(input.Signature)
	parsed, err := receipt.Parse(header)
	if err != nil {
		return receipt.Parsed{}, &InputFormatError{Err: err}
	}
	return parsed, nil
}

func resolveCache(injected *cache.Cache) (*cache.Cache, error) {
	if injected != nil {
		return injected, nil
	}
	c, err := cache.Open("")
	if err != nil {
		return nil, &UsageError{Err: fmt.Errorf("open default cache: %w", err)}
	}
	return c, nil
}

func trustedVerificationKey(parsed receipt.Parsed, root resolver.ResolvedRoot) ([]byte, *Result) {
	if root.TrustSource == resolver.SourceExplicit {
		return cloneBytes(root.Pubkey), nil
	}

	receiptPubkey, err := receipt.ParsePubkey(parsed.Tuple.ProviderPubkey)
	if err != nil {
		return nil, &Result{
			Result: resultInvalid,
			Reason: reasonPubkeyNotEndorsed,
			Details: &Details{
				Field:   "pubkey",
				Receipt: parsed.Tuple.ProviderPubkey,
			},
		}
	}
	if bytes.Equal(receiptPubkey, root.Pubkey) {
		return cloneBytes(root.Pubkey), nil
	}
	if root.PubkeyPrev != nil && bytes.Equal(receiptPubkey, root.PubkeyPrev.Pubkey) {
		if !insideGraceWindow(parsed.Tuple.UnixTS, root.PubkeyPrev) {
			return nil, &Result{
				Result: resultInvalid,
				Reason: reasonPreviousKeyOutsideGraceWindow,
				Details: &Details{
					Field:   "grace_window",
					Receipt: parsed.Tuple.ProviderPubkey,
					Extra: map[string]any{
						"unix_ts":    parsed.Tuple.UnixTS,
						"rotated_at": root.PubkeyPrev.RotatedAt.Unix(),
						"expires_at": root.PubkeyPrev.ExpiresAt.Unix(),
					},
				},
			}
		}
		return cloneBytes(root.PubkeyPrev.Pubkey), nil
	}
	return nil, &Result{
		Result: resultInvalid,
		Reason: reasonPubkeyNotEndorsed,
		Details: &Details{
			Field:    "pubkey",
			Computed: base64.StdEncoding.EncodeToString(root.Pubkey),
			Receipt:  parsed.Tuple.ProviderPubkey,
		},
	}
}

func insideGraceWindow(unixTS int64, prev *resolver.PreviousKeyResponse) bool {
	lower := prev.RotatedAt.Add(-graceWindowSlack).Unix()
	upper := prev.ExpiresAt.Unix()
	return unixTS >= lower && unixTS <= upper
}

func invalid(base Result, reason string, details Details) Result {
	base.Result = resultInvalid
	base.Reason = reason
	base.Details = &details
	return base
}

func inconclusive(base Result, reason string) Result {
	base.Result = resultInconclusive
	base.Reason = reason
	base.TrustSource = string(resolver.SourceNone)
	return base
}

func resultCoordinatorHost(root resolver.ResolvedRoot) string {
	if root.TrustSource == resolver.SourceCache || root.TrustSource == resolver.SourceLive {
		return root.CoordinatorHost
	}
	return ""
}

func sourceNoneReason(providerID string, opts VerifyOpts, c *cache.Cache, warnings []resolver.Warning, now time.Time) string {
	for _, warning := range warnings {
		if warning.Kind != "live_check_skipped" {
			continue
		}
		reason, _ := warning.Fields["reason"].(string)
		switch reason {
		case warningReasonProviderIDUnresolvable:
			return reasonPubkeyUnresolvable
		case "network_unreachable":
			if hasStaleCacheEntry(c, normalizedCoordinatorHost(opts.CoordinatorHost), providerID, now) {
				return reasonCacheStaleAndLiveUnreachable
			}
			return reasonPubkeyUnresolvable
		}
	}
	return reasonPubkeyUnresolvable
}

func hasStaleCacheEntry(c *cache.Cache, coordinatorHost, providerID string, now time.Time) bool {
	if c == nil || providerID == "" {
		return false
	}
	entries, err := c.LookupByProviderID(coordinatorHost, providerID)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if now.UTC().Sub(entry.FetchedAt.UTC()) > cache.TTL {
			return true
		}
	}
	return false
}

func normalizedCoordinatorHost(raw string) string {
	if raw == "" {
		return defaultCoordinatorHost
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return raw
	}
	return parsed.Host
}

func convertWarnings(in []resolver.Warning) []Warning {
	if len(in) == 0 {
		return nil
	}
	out := make([]Warning, 0, len(in))
	for _, warning := range in {
		out = append(out, Warning{
			Kind:   warning.Kind,
			Fields: cloneFields(warning.Fields),
		})
	}
	return out
}

func clockSkewWarning(unixTS int64, systemTime time.Time) []Warning {
	delta := unixTS - systemTime.Unix()
	if delta < 0 {
		delta = -delta
	}
	if delta <= int64(clockSkewThreshold/time.Second) {
		return nil
	}
	return []Warning{{
		Kind: "clock_skew",
		Fields: map[string]any{
			"unix_ts":       unixTS,
			"system_time":   systemTime.Unix(),
			"delta_seconds": delta,
		},
	}}
}

func cloneFields(in map[string]any) map[string]any {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]any, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func cloneBytes(in []byte) []byte {
	if in == nil {
		return nil
	}
	out := make([]byte, len(in))
	copy(out, in)
	return out
}
