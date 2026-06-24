package verify

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	catalogcache "github.com/augstar/macprovider/phase7-verify/internal/cache/catalog"
	"github.com/augstar/macprovider/phase7-verify/internal/catalog"
	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
)

// catalogVerdict captures the outcome of the §M.3 catalog-check
// pipeline. Empty Result means "no terminal verdict — keep going
// with the valid path."
type catalogVerdict struct {
	Result            string
	Reason            string
	Details           *Details
	Warnings          []Warning
	ModelHashVerified *bool
}

// applyCatalogCheck implements §M.3.1.1 / §M.3.1.2 / §M.3.2 / §M.2.3 /
// §M.1.1 verifier logic. Called AFTER signature + prompt + output
// hashes pass; runs the catalog branches and the
// --require-model-hash policy gate.
func applyCatalogCheck(parsed receipt.Parsed, opts VerifyOpts, now time.Time) catalogVerdict {
	v := catalogVerdict{}
	t := parsed.Tuple
	isLegacy := t.ReceiptVersion == ""

	// SPEC-015 §M.1.1 — v0.3 verifier reading a legacy v0.1/v0.2
	// receipt MUST skip the catalog check entirely. Surface the
	// `catalog_skipped_legacy_receipt` warning when catalog flags
	// WERE supplied.
	if isLegacy {
		if opts.Catalog.Enabled {
			v.Warnings = append(v.Warnings, Warning{Kind: warningCatalogSkippedLegacyReceipt})
		}
		// §M.3.1.2 — --require-model-hash on a legacy receipt
		// MUST report invalid: model_hash_required (the legacy
		// receipt has no hash to attest).
		if opts.RequireModelHash {
			f := false
			v.ModelHashVerified = &f
			v.Result = resultInvalid
			v.Reason = reasonModelHashRequired
			v.Details = &Details{Field: "model_hash", PolicyFlag: "require-model-hash"}
			return v
		}
		return v
	}

	// SPEC-015 §M.0 — v0.3 receipt. The §M.1.4 unknown-version
	// path is handled upstream in Verify (before this function
	// runs), so by the time we get here t.ReceiptVersion == "3".

	// Null-hash branch (§M.2.3).
	if t.ModelHashNull {
		// §M.3.1.2 fail-closed.
		if opts.RequireModelHash {
			f := false
			v.ModelHashVerified = &f
			v.Result = resultInvalid
			v.Reason = reasonModelHashRequired
			v.Details = &Details{Field: "model_hash", PolicyFlag: "require-model-hash"}
			return v
		}
		if opts.Catalog.Enabled {
			v.Warnings = append(v.Warnings, Warning{Kind: warningCatalogSkippedNullHash})
		}
		// model_hash_verified stays nil (catalog did not run).
		return v
	}

	// Non-null hash + no catalog flags → §10.6 v0.2 trust boundary
	// preserved (model_hash_verified=nil).
	if !opts.Catalog.Enabled {
		return v
	}

	// SPEC-015 §M.3.2 — 8-step algorithm.
	// First resolve the catalog pubkey (cheap: file or HTTP GET +
	// JSON decode). We need it before consulting the cache because
	// pubkey rotation invalidates cached catalog bytes.
	pubkey, fetchErr := resolveCatalogPubkey(opts.Catalog, opts.Offline, opts.HTTPClient)
	if fetchErr != nil {
		v.Result = resultInconclusive
		v.Reason = reasonCatalogUnreachable
		v.Details = &Details{Field: "catalog_pubkey_url", URL: opts.Catalog.PubkeyURL, Cause: fetchErr.Error()}
		return v
	}
	pubkeyB64 := catalogcache.EncodePubkeyForCache(pubkey)

	// SPEC-015 §M.3.4 — cache catalog bytes (URL mode only) keyed
	// by catalog URL + bound to current pubkey. Cache miss on
	// rotation. File-mode (--catalog <path>) skips the cache.
	catalogBytes, fromCache := tryCachedCatalogBytes(opts.Catalog, pubkeyB64, now)
	if catalogBytes == nil {
		catalogBytes, fetchErr = resolveCatalogBytes(opts.Catalog, opts.Offline, opts.HTTPClient, opts.Now)
		if fetchErr != nil {
			v.Result = resultInconclusive
			v.Reason = reasonCatalogUnreachable
			v.Details = &Details{Field: "catalog_url", URL: opts.Catalog.URL, Cause: fetchErr.Error()}
			return v
		}
	}
	_ = fromCache

	// Parse + Verify (signature + expiry). If the bytes came from
	// the cache they were already parse+verify-clean at write time;
	// re-running here costs ~100µs and protects against a corrupted
	// cache file regardless.
	c, parseErr := catalog.Parse(catalogBytes)
	if parseErr != nil {
		v.Result = resultInvalid
		v.Reason = reasonCatalogFormatInvalid
		v.Details = &Details{Field: "catalog", Cause: parseErr.Error()}
		return v
	}
	if verifyErr := catalog.Verify(c, pubkey, now); verifyErr != nil {
		var sigErr *catalog.ErrSignatureInvalid
		var expErr *catalog.ErrExpired
		switch {
		case errors.As(verifyErr, &sigErr):
			v.Result = resultInvalid
			v.Reason = reasonCatalogSignatureInvalid
			v.Details = &Details{Field: "signature", Cause: sigErr.Reason, Alg: sigErr.ObservedAlg}
		case errors.As(verifyErr, &expErr):
			v.Result = resultInconclusive
			v.Reason = reasonCatalogExpired
			v.Details = &Details{
				Field:     "expires_at",
				CatalogID: expErr.CatalogID,
				ExpiresAt: expErr.ExpiresAt.UTC().Format(time.RFC3339),
			}
		default:
			v.Result = resultInvalid
			v.Reason = reasonCatalogSignatureInvalid
			v.Details = &Details{Field: "signature", Cause: verifyErr.Error()}
		}
		return v
	}

	// §M.3.2 step 6 — case-folded model lookup.
	entry, ok := catalog.Lookup(c, t.ModelID)
	if !ok {
		v.Result = resultInconclusive
		v.Reason = reasonModelIDNotInCatalog
		v.Details = &Details{Field: "model_id", ModelID: t.ModelID}
		return v
	}

	// §M.3.2 step 7 — hash comparison (case-sensitive; both sides
	// lowercase by their respective spec).
	if t.ModelHash != entry.SHA256 {
		f := false
		v.ModelHashVerified = &f
		v.Result = resultInvalid
		v.Reason = reasonModelHashMismatch
		v.Details = &Details{
			Field:    "model_hash",
			Expected: entry.SHA256,
			Actual:   t.ModelHash,
		}
		return v
	}

	// §M.3.2 step 8 — verified. Persist to cache so subsequent
	// runs (within §M.3.4 TTL band) skip the network fetch.
	if !fromCache && opts.Catalog.URL != "" {
		store, errStore := catalogcache.New()
		if errStore == nil && store != nil {
			_, _, _ = store.Put(opts.Catalog.URL, catalogBytes, pubkeyB64, c.ExpiresAt, now)
		}
	}
	tr := true
	v.ModelHashVerified = &tr
	return v
}

// tryCachedCatalogBytes returns the cached catalog bytes for the
// given URL when the §M.3.4 cache holds a non-stale, pubkey-matched
// entry. Returns (nil, false) on miss (caller falls back to a
// network fetch).
func tryCachedCatalogBytes(co CatalogOpts, pubkeyB64 string, now time.Time) ([]byte, bool) {
	if co.URL == "" {
		return nil, false
	}
	store, err := catalogcache.New()
	if err != nil || store == nil {
		return nil, false
	}
	entry, hit, err := store.Get(co.URL, pubkeyB64, now)
	if err != nil || !hit || entry == nil {
		return nil, false
	}
	return append([]byte(nil), entry.CatalogBytes...), true
}

// resolveCatalogBytes returns the catalog file bytes from --catalog
// (local file) OR --catalog-url (HTTP GET, gated by --offline).
func resolveCatalogBytes(co CatalogOpts, offline bool, client *http.Client, now func() time.Time) ([]byte, error) {
	if co.Path != "" {
		return os.ReadFile(co.Path)
	}
	if co.URL == "" {
		return nil, errors.New("catalog source not configured")
	}
	if offline {
		return nil, errors.New("catalog URL fetch blocked by --offline")
	}
	c := client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := c.Get(co.URL)
	if err != nil {
		return nil, fmt.Errorf("catalog url fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("catalog url status=%d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// resolveCatalogPubkey returns the 32-byte ed25519 catalog pubkey
// from --catalog-pubkey (pre-decoded) OR --catalog-pubkey-url
// (HTTP GET returning {"pubkey":"<43-char base64url>","alg":"Ed25519"}).
func resolveCatalogPubkey(co CatalogOpts, offline bool, client *http.Client) (ed25519.PublicKey, error) {
	if len(co.Pubkey) > 0 {
		return ed25519.PublicKey(co.Pubkey), nil
	}
	if co.PubkeyURL == "" {
		return nil, errors.New("catalog pubkey source not configured")
	}
	if offline {
		return nil, errors.New("catalog pubkey URL fetch blocked by --offline")
	}
	c := client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := c.Get(co.PubkeyURL)
	if err != nil {
		return nil, fmt.Errorf("catalog pubkey url fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("catalog pubkey url status=%d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read catalog pubkey body: %w", err)
	}
	return decodeCatalogPubkeyResponse(body)
}

func decodeCatalogPubkeyResponse(body []byte) (ed25519.PublicKey, error) {
	// Reuse stdlib JSON via a local anonymous struct.
	var pkResp struct {
		Pubkey string `json:"pubkey"`
		Alg    string `json:"alg"`
	}
	if err := jsonUnmarshal(body, &pkResp); err != nil {
		return nil, fmt.Errorf("decode catalog pubkey JSON: %w", err)
	}
	if pkResp.Alg != catalogPubkeyAlg {
		return nil, fmt.Errorf("catalog pubkey alg=%q, want %q", pkResp.Alg, catalogPubkeyAlg)
	}
	raw, err := decodeRawURLBase64(strings.TrimSpace(pkResp.Pubkey))
	if err != nil {
		return nil, fmt.Errorf("decode catalog pubkey base64url: %w", err)
	}
	if len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("catalog pubkey length=%d, want %d", len(raw), ed25519.PublicKeySize)
	}
	return ed25519.PublicKey(raw), nil
}
