// Package catalog parses and verifies SPEC-008 / SPEC-015 v0.3 §M.3
// signed model catalogs. Pure-stdlib hand-translation of the
// coordinator's tier2 catalog parser at
// phase4-coordinator/internal/tier2/catalog.go — the verifier MUST
// NOT import the coordinator package per the v0.2 phase7-verify
// stdlib-only discipline.
package catalog

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
	"time"
)

// SPEC-015 §M.3.2 step 4 — catalog signature MUST be ed25519 and
// signature.alg MUST be the ASCII string "Ed25519" (capital E,
// matching scripts/sign-catalog.go:142-145 and the existing
// coordinator validator).
const signatureAlg = "Ed25519"

// SPEC-015 §M.3.2 step 5 — 60-second skew grace on expires_at.
const expiryGrace = 60 * time.Second

// SPEC-015 §M.3.2 step 3 — catalog sha256 fields MUST match this
// pattern (raw 64-char lowercase hex, no `sha256:` prefix per
// SPEC-011 R-3.3.1).
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ModelEntry mirrors scripts/sign-catalog.go modelEntry +
// phase4-coordinator/internal/tier2/catalog.go ModelEntry.
type ModelEntry struct {
	ArtifactKind string `json:"artifact_kind"`
	HashScope    string `json:"hash_scope"`
	ModelID      string `json:"model_id"`
	Notes        string `json:"notes,omitempty"`
	SHA256       string `json:"sha256"`
	Source       string `json:"source"`
}

// Signature mirrors scripts/sign-catalog.go signature.
type Signature struct {
	Alg   string `json:"alg"`
	KeyID string `json:"key_id"`
	Sig   string `json:"sig"`
}

// File is the on-the-wire signed catalog (parsed JSON shape).
type File struct {
	CatalogID string       `json:"catalog_id"`
	ExpiresAt string       `json:"expires_at"`
	IssuedAt  string       `json:"issued_at"`
	Models    []ModelEntry `json:"models"`
	Signature Signature    `json:"signature"`
	Version   int          `json:"version"`
}

// canonicalBody is the §M.3.2 step 4 canonical body — the File
// minus the Signature field, in the exact key order
// scripts/sign-catalog.go:42-49 produces:
// catalog_id, expires_at, issued_at, models, version.
type canonicalBody struct {
	CatalogID string       `json:"catalog_id"`
	ExpiresAt string       `json:"expires_at"`
	IssuedAt  string       `json:"issued_at"`
	Models    []ModelEntry `json:"models"`
	Version   int          `json:"version"`
}

// Catalog is the parsed + signature-verified catalog. Hold by value;
// it is immutable after Parse + Verify.
type Catalog struct {
	CatalogID string
	ExpiresAt time.Time
	IssuedAt  time.Time
	Models    map[string]ModelEntry
	// Raw retains the original bytes so the verifier can serve them
	// to a buyer or stamp them into a cache without re-marshalling
	// (which could re-order keys and re-break the signature).
	Raw []byte
	// KeyID is the informational fingerprint from signature.key_id.
	KeyID string
}

// Parse decodes the signed catalog bytes into a typed Catalog
// WITHOUT verifying the signature. Use Verify next.
func Parse(data []byte) (*Catalog, error) {
	if len(data) == 0 {
		return nil, errors.New("catalog: empty body")
	}
	f, err := decodeFile(data)
	if err != nil {
		return nil, fmt.Errorf("catalog: parse: %w", err)
	}
	if strings.TrimSpace(f.CatalogID) == "" {
		return nil, errors.New("catalog: catalog_id missing")
	}
	// Pin to v1 to mirror phase4-coordinator/internal/tier2/catalog.go:454-456.
	// SPEC-008 v0.3 / §M.3.2 step 3 — only catalog schema version 1
	// is supported; anything else MUST be rejected so the buyer-side
	// and coordinator-side accept-reject contracts stay equivalent.
	if f.Version != 1 {
		return nil, fmt.Errorf("catalog: version=%d unsupported (only 1 is accepted)", f.Version)
	}
	if len(f.Models) == 0 {
		return nil, errors.New("catalog: models list is empty")
	}
	expires, err := time.Parse(time.RFC3339, f.ExpiresAt)
	if err != nil {
		return nil, fmt.Errorf("catalog: expires_at not RFC3339: %w", err)
	}
	issued, err := time.Parse(time.RFC3339, f.IssuedAt)
	if err != nil {
		return nil, fmt.Errorf("catalog: issued_at not RFC3339: %w", err)
	}
	if !issued.Before(expires) {
		return nil, errors.New("catalog: issued_at >= expires_at")
	}
	models := make(map[string]ModelEntry, len(f.Models))
	for _, m := range f.Models {
		if strings.TrimSpace(m.ModelID) == "" {
			return nil, errors.New("catalog: model_id is empty")
		}
		if m.ArtifactKind != "mlx_weight_file" {
			return nil, fmt.Errorf("catalog: model %q artifact_kind must be mlx_weight_file", m.ModelID)
		}
		switch m.HashScope {
		case "primary_weight_file", "artifact_manifest", "coordinator_endorsed_incremental":
		default:
			return nil, fmt.Errorf("catalog: model %q hash_scope is unsupported", m.ModelID)
		}
		if strings.TrimSpace(m.Source) == "" {
			return nil, fmt.Errorf("catalog: model %q source is empty", m.ModelID)
		}
		if !hashPattern.MatchString(m.SHA256) {
			return nil, fmt.Errorf("catalog: model %q sha256=%q is not 64 lowercase hex", m.ModelID, m.SHA256)
		}
		key := modelKey(m.ModelID)
		if _, dup := models[key]; dup {
			return nil, fmt.Errorf("catalog: duplicate model_id %q after case-fold + trim", m.ModelID)
		}
		models[key] = m
	}
	// Mirror phase4-coordinator/internal/tier2/catalog.go:473-475:
	// signature.alg + signature.sig + signature.key_id are all
	// required non-empty at parse-time.
	if strings.TrimSpace(f.Signature.Alg) == "" {
		return nil, errors.New("catalog: signature.alg missing")
	}
	if strings.TrimSpace(f.Signature.KeyID) == "" {
		return nil, errors.New("catalog: signature.key_id missing")
	}
	if strings.TrimSpace(f.Signature.Sig) == "" {
		return nil, errors.New("catalog: signature.sig missing")
	}
	rawCopy := append([]byte(nil), data...)
	return &Catalog{
		CatalogID: f.CatalogID,
		ExpiresAt: expires,
		IssuedAt:  issued,
		Models:    models,
		Raw:       rawCopy,
		KeyID:     f.Signature.KeyID,
	}, nil
}

// Verify checks the catalog's ed25519 signature against pubkey, then
// asserts non-expiry per §M.3.2 step 5 (60-second skew grace).
// pubkey MUST be the 32-byte ed25519 public key produced by
// base64.RawURLEncoding decoding of the operator-published key per
// SPEC-008 §5.2.1 wire form.
//
// Returns nil on success, or one of the typed errors below.
func Verify(c *Catalog, pubkey ed25519.PublicKey, now time.Time) error {
	if c == nil {
		return errors.New("catalog: nil catalog")
	}
	if len(pubkey) != ed25519.PublicKeySize {
		return fmt.Errorf("catalog: pubkey length=%d, want %d", len(pubkey), ed25519.PublicKeySize)
	}

	// Reparse to recover the signature block (the typed Catalog
	// drops it).
	f, err := decodeFile(c.Raw)
	if err != nil {
		return fmt.Errorf("catalog: re-parse: %w", err)
	}

	if f.Signature.Alg != signatureAlg {
		return &ErrSignatureInvalid{
			Reason:      fmt.Sprintf("signature.alg=%q, want %q", f.Signature.Alg, signatureAlg),
			ObservedAlg: f.Signature.Alg,
		}
	}
	sig, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(f.Signature.Sig))
	if err != nil {
		return &ErrSignatureInvalid{
			Reason:      fmt.Sprintf("signature.sig base64url decode: %v", err),
			ObservedAlg: f.Signature.Alg,
		}
	}
	if len(sig) != ed25519.SignatureSize {
		return &ErrSignatureInvalid{
			Reason:      fmt.Sprintf("signature.sig length=%d, want %d", len(sig), ed25519.SignatureSize),
			ObservedAlg: f.Signature.Alg,
		}
	}

	body := canonicalBody{
		CatalogID: f.CatalogID,
		ExpiresAt: f.ExpiresAt,
		IssuedAt:  f.IssuedAt,
		Models:    f.Models,
		Version:   f.Version,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("catalog: canonical body marshal: %w", err)
	}
	if !ed25519.Verify(pubkey, canonical, sig) {
		return &ErrSignatureInvalid{
			Reason:      "ed25519.Verify returned false",
			ObservedAlg: f.Signature.Alg,
		}
	}

	if now.After(c.ExpiresAt.Add(expiryGrace)) {
		return &ErrExpired{
			CatalogID: c.CatalogID,
			ExpiresAt: c.ExpiresAt,
		}
	}
	return nil
}

// Lookup returns the catalog entry for modelID under the SPEC-015
// §M.3.2 step 6 canonical key (lowercase + trim — mirroring
// phase4-coordinator/internal/tier2/catalog.go:559-560
// catalogModelKey). Returns (entry, true) on hit, (zero, false) on
// miss.
func Lookup(c *Catalog, modelID string) (ModelEntry, bool) {
	if c == nil {
		return ModelEntry{}, false
	}
	entry, ok := c.Models[modelKey(modelID)]
	return entry, ok
}

func modelKey(modelID string) string {
	return strings.ToLower(strings.TrimSpace(modelID))
}

func decodeFile(data []byte) (File, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var f File
	if err := dec.Decode(&f); err != nil {
		return File{}, err
	}
	var extra struct{}
	if err := dec.Decode(&extra); err != io.EOF {
		return File{}, errors.New("catalog must contain a single JSON object")
	}
	return f, nil
}

// ErrSignatureInvalid is returned by Verify when the catalog's
// signature does not validate or the algorithm string is wrong.
//
// ObservedAlg carries the catalog's `signature.alg` value verbatim so
// SPEC-015 §M.3.2.1 `details.alg` can be populated by callers without
// re-parsing the catalog. Empty when not applicable (e.g. signature
// length / decode failures unrelated to the alg field).
type ErrSignatureInvalid struct {
	Reason      string
	ObservedAlg string
}

func (e *ErrSignatureInvalid) Error() string {
	return "catalog: signature invalid: " + e.Reason
}

// ErrExpired is returned by Verify when the catalog's `expires_at`
// is more than 60 seconds in the past relative to `now`.
type ErrExpired struct {
	CatalogID string
	ExpiresAt time.Time
}

func (e *ErrExpired) Error() string {
	return fmt.Sprintf("catalog: catalog %q expired at %s", e.CatalogID, e.ExpiresAt.Format(time.RFC3339))
}
