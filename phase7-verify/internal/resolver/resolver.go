// Package resolver resolves SPEC-015 receipt verification trust roots.
package resolver

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/cache"
	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
	"github.com/augstar/macprovider/phase7-verify/internal/version"
)

const defaultCoordinatorHost = "coordinator.streamvc.live"

// Source describes which trust-root source Resolve selected.
type Source string

const (
	SourceExplicit Source = "explicit_pubkey"
	SourceCache    Source = "cache"
	SourceLive     Source = "live"
	SourceNone     Source = "none"
)

type ResolverResponse = cache.ResolverResponse
type PreviousKeyResponse = cache.PreviousKeyResponse

// ResolvedRoot is the trusted pubkey and metadata selected by Resolve.
type ResolvedRoot struct {
	Pubkey          []byte
	PubkeyPrev      *PreviousKeyResponse
	TrustSource     Source
	CoordinatorHost string
	Warnings        []Warning
}

// Warning is one SPEC-015 §10.4.2 warning record.
type Warning struct {
	Kind   string
	Fields map[string]any
}

type ResolveOpts struct {
	Offline         bool
	Quiet           bool
	CoordinatorHost string
	Cache           *cache.Cache
	Now             func() time.Time
	HTTPClient      *http.Client
}

var (
	ErrProviderNotInPool  = errors.New("provider not in pool")
	ErrInsecureScheme     = errors.New("coordinator URL must use https")
	ErrInvalidProviderID  = errors.New("invalid provider_id")
	ErrInvalidCoordinator = errors.New("invalid coordinator host")
	ErrRedirectOffHost    = errors.New("redirect target is outside configured coordinator host")
	// ErrRedirectOffPath fires when a same-host redirect points to a different
	// path, query, or fragment than the original GET /v1/receipt-keys/<provider_id>
	// request. SPEC-015 §10.5 bounds the verifier to that exact URL; same-host
	// redirects to /poolz, /telemetry, /analytics, etc. would otherwise be silently
	// followed by net/http after the first response.
	ErrRedirectOffPath    = errors.New("redirect target path differs from the original receipt-keys request")
	ErrFetchFailed        = errors.New("receipt key fetch failed")
)

var providerIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

type coordinatorTarget struct {
	url  *url.URL
	host string
}

type wireResponse struct {
	ProviderID        string        `json:"provider_id"`
	ReceiptPubkey     string        `json:"receipt_pubkey"`
	ReceiptPubkeyPrev *wirePrevious `json:"receipt_pubkey_prev"`
	FetchedAt         string        `json:"fetched_at"`
}

type wirePrevious struct {
	Pubkey    string `json:"pubkey"`
	RotatedAt string `json:"rotated_at"`
	ExpiresAt string `json:"expires_at"`
}

// Resolve implements SPEC-015 §10.2 explicit/cache/live trust-root resolution.
func Resolve(providerID string, explicitPubkey []byte, opts ResolveOpts) (ResolvedRoot, error) {
	target, err := normalizeCoordinator(opts.CoordinatorHost)
	if err != nil {
		return ResolvedRoot{}, err
	}
	now := time.Now
	if opts.Now != nil {
		now = opts.Now
	}
	warnings := coordinatorWarnings(target.host)

	if len(explicitPubkey) > 0 && len(explicitPubkey) != 32 {
		return ResolvedRoot{}, fmt.Errorf("%w: got %d bytes", receipt.ErrPubkeyLength, len(explicitPubkey))
	}

	if len(explicitPubkey) > 0 {
		root := ResolvedRoot{
			Pubkey:      cloneBytes(explicitPubkey),
			TrustSource: SourceExplicit,
			Warnings:    append([]Warning(nil), warnings...),
		}
		if opts.Offline {
			root.Warnings = append(root.Warnings, liveCheckSkipped("offline_flag"))
			return root, nil
		}
		if providerID == "" {
			root.Warnings = append(root.Warnings, liveCheckSkipped("provider_id_unresolvable"))
			return root, nil
		}
		if err := validateProviderID(providerID); err != nil {
			return root, err
		}
		live, err := fetchLive(providerID, target, opts.HTTPClient)
		if err != nil {
			root.Warnings = append(root.Warnings, liveCheckSkipped("network_unreachable"))
			return root, nil
		}
		if opts.Cache != nil {
			if err := opts.Cache.Put(target.host, providerID, live); err != nil {
				return root, err
			}
		}
		if !bytes.Equal(live.ReceiptPubkey, explicitPubkey) {
			root.Warnings = append(root.Warnings, Warning{
				Kind: "explicit_vs_live_divergence",
				Fields: map[string]any{
					"live_pubkey":      base64.StdEncoding.EncodeToString(live.ReceiptPubkey),
					"coordinator_host": target.host,
				},
			})
		}
		return root, nil
	}

	if providerID == "" {
		root := ResolvedRoot{TrustSource: SourceNone, Warnings: append([]Warning(nil), warnings...)}
		if opts.Offline {
			root.Warnings = append(root.Warnings, liveCheckSkipped("offline_flag"))
		} else {
			root.Warnings = append(root.Warnings, liveCheckSkipped("provider_id_unresolvable"))
		}
		return root, nil
	}
	if err := validateProviderID(providerID); err != nil {
		return ResolvedRoot{}, err
	}

	fresh, _, err := freshestCacheEntries(opts.Cache, target.host, providerID, now().UTC())
	if err != nil {
		return ResolvedRoot{}, err
	}
	if fresh != nil {
		return rootFromCache(fresh, warnings), nil
	}
	if opts.Offline {
		root := ResolvedRoot{TrustSource: SourceNone, Warnings: append([]Warning(nil), warnings...)}
		root.Warnings = append(root.Warnings, liveCheckSkipped("offline_flag"))
		return root, nil
	}

	live, err := fetchLive(providerID, target, opts.HTTPClient)
	if err != nil {
		root := ResolvedRoot{TrustSource: SourceNone, Warnings: append([]Warning(nil), warnings...)}
		if errors.Is(err, ErrProviderNotInPool) {
			return root, err
		}
		root.Warnings = append(root.Warnings, liveCheckSkipped("network_unreachable"))
		return root, nil
	}
	if opts.Cache != nil {
		if err := opts.Cache.Put(target.host, providerID, live); err != nil {
			return ResolvedRoot{}, err
		}
	}
	return ResolvedRoot{
		Pubkey:          cloneBytes(live.ReceiptPubkey),
		PubkeyPrev:      clonePrevious(live.ReceiptPubkeyPrev),
		TrustSource:     SourceLive,
		CoordinatorHost: target.host,
		Warnings:        warnings,
	}, nil
}

func freshestCacheEntries(c *cache.Cache, coordinatorHost, providerID string, now time.Time) (fresh *cache.Entry, stale *cache.Entry, err error) {
	if c == nil {
		return nil, nil, nil
	}
	entries, err := c.LookupByProviderID(coordinatorHost, providerID)
	if err != nil {
		return nil, nil, err
	}
	for _, entry := range entries {
		if now.Sub(entry.FetchedAt.UTC()) <= cache.TTL {
			if fresh == nil || entry.FetchedAt.After(fresh.FetchedAt) {
				fresh = entry
			}
			continue
		}
		if stale == nil || entry.FetchedAt.After(stale.FetchedAt) {
			stale = entry
		}
	}
	return fresh, stale, nil
}

func rootFromCache(entry *cache.Entry, warnings []Warning) ResolvedRoot {
	return ResolvedRoot{
		Pubkey:          cloneBytes(entry.ReceiptPubkey),
		PubkeyPrev:      previousFromCache(entry.ReceiptPubkeyPrev),
		TrustSource:     SourceCache,
		CoordinatorHost: entry.CoordinatorHost,
		Warnings:        append([]Warning(nil), warnings...),
	}
}

func fetchLive(providerID string, target coordinatorTarget, client *http.Client) (ResolverResponse, error) {
	if err := validateProviderID(providerID); err != nil {
		return ResolverResponse{}, err
	}
	endpoint := *target.url
	endpoint.Path = "/v1/receipt-keys/" + providerID
	endpoint.RawQuery = ""
	endpoint.Fragment = ""

	httpClient := configuredClient(client, target.host, endpoint.Path)
	req, err := http.NewRequest(http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return ResolverResponse{}, err
	}
	req.Header.Set("User-Agent", "macprovider-verify/"+version.BinaryVersion)

	resp, err := httpClient.Do(req)
	if err != nil {
		// Off-host and off-path redirects both surface as fetch failures —
		// the URL net/http wrapping unwraps either sentinel via errors.Is.
		if errors.Is(err, ErrRedirectOffHost) || errors.Is(err, ErrRedirectOffPath) || errors.Is(err, ErrInsecureScheme) {
			return ResolverResponse{}, fmt.Errorf("%w: %v", ErrFetchFailed, err)
		}
		return ResolverResponse{}, fmt.Errorf("%w: %v", ErrFetchFailed, err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusOK:
		return decodeResponse(resp.Body)
	case resp.StatusCode == http.StatusNotFound:
		io.Copy(io.Discard, resp.Body)
		return ResolverResponse{}, ErrProviderNotInPool
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500:
		io.Copy(io.Discard, resp.Body)
		return ResolverResponse{}, fmt.Errorf("%w: status %d", ErrFetchFailed, resp.StatusCode)
	default:
		io.Copy(io.Discard, resp.Body)
		return ResolverResponse{}, fmt.Errorf("%w: status %d", ErrFetchFailed, resp.StatusCode)
	}
}

func decodeResponse(body io.Reader) (ResolverResponse, error) {
	var wire wireResponse
	decoder := json.NewDecoder(body)
	if err := decoder.Decode(&wire); err != nil {
		return ResolverResponse{}, fmt.Errorf("%w: decode response: %v", ErrFetchFailed, err)
	}
	pubkey, err := receipt.ParsePubkey(wire.ReceiptPubkey)
	if err != nil {
		return ResolverResponse{}, fmt.Errorf("%w: %v", ErrFetchFailed, err)
	}
	fetchedAt, err := time.Parse(time.RFC3339, wire.FetchedAt)
	if err != nil {
		return ResolverResponse{}, fmt.Errorf("%w: fetched_at: %v", ErrFetchFailed, err)
	}
	resp := ResolverResponse{
		ProviderID:    wire.ProviderID,
		ReceiptPubkey: pubkey,
		FetchedAt:     fetchedAt.UTC(),
	}
	if wire.ReceiptPubkeyPrev != nil {
		prev, err := decodePrevious(wire.ReceiptPubkeyPrev)
		if err != nil {
			return ResolverResponse{}, err
		}
		resp.ReceiptPubkeyPrev = prev
	}
	return resp, nil
}

func decodePrevious(wire *wirePrevious) (*PreviousKeyResponse, error) {
	pubkey, err := receipt.ParsePubkey(wire.Pubkey)
	if err != nil {
		return nil, fmt.Errorf("%w: previous pubkey: %v", ErrFetchFailed, err)
	}
	rotatedAt, err := time.Parse(time.RFC3339, wire.RotatedAt)
	if err != nil {
		return nil, fmt.Errorf("%w: rotated_at: %v", ErrFetchFailed, err)
	}
	expiresAt, err := time.Parse(time.RFC3339, wire.ExpiresAt)
	if err != nil {
		return nil, fmt.Errorf("%w: expires_at: %v", ErrFetchFailed, err)
	}
	return &PreviousKeyResponse{
		Pubkey:    pubkey,
		RotatedAt: rotatedAt.UTC(),
		ExpiresAt: expiresAt.UTC(),
	}, nil
}

// maxFetchTimeout is the hard SPEC-015 §10.5 budget: 5 seconds connect+read.
// configuredClient ALWAYS clamps the effective client.Timeout to this value
// regardless of any injected client's defaults — Step 6/CLI/test callers cannot
// weaken the network discipline by passing a more permissive client.
const maxFetchTimeout = 5 * time.Second

// configuredClient returns an http.Client with the SPEC-015 §10.5 network
// discipline applied: 5s timeout (hard cap, never relaxed), and a custom
// CheckRedirect that constrains redirects to the EXACT same-host + same-path
// request (no escape to /poolz, /telemetry, etc.).
//
// requestPath MUST be the original request path (e.g. "/v1/receipt-keys/m1-anon").
// Same-host redirects to ANY other path are rejected as ErrRedirectOffHost
// (semantically off-the-allowed-surface, even if the host is unchanged).
func configuredClient(client *http.Client, coordinatorHost, requestPath string) *http.Client {
	var configured http.Client
	if client != nil {
		configured = *client
	}
	// MAJOR fix round-1 audit: clamp to the §10.5 5-second budget unconditionally.
	// An injected client with Timeout = 30s would otherwise let Step 6/CLI silently
	// extend the network surface beyond spec.
	if configured.Timeout == 0 || configured.Timeout > maxFetchTimeout {
		configured.Timeout = maxFetchTimeout
	}
	configured.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" {
			return ErrInsecureScheme
		}
		if !strings.EqualFold(req.URL.Host, coordinatorHost) {
			return ErrRedirectOffHost
		}
		// MAJOR fix round-1 audit: same-host redirects MUST also preserve the
		// request path. SPEC-015 §10.5 says "no network call beyond
		// /v1/receipt-keys/<provider_id>" — a coordinator (malicious, or
		// misconfigured) redirecting to /poolz, /telemetry, /analytics, etc.
		// would otherwise be silently followed by net/http.
		if req.URL.Path != requestPath {
			return ErrRedirectOffPath
		}
		// Also reject redirects that smuggle a query string or fragment —
		// neither was in the original GET and both are out-of-spec.
		if req.URL.RawQuery != "" || req.URL.Fragment != "" {
			return ErrRedirectOffPath
		}
		return nil
	}
	return &configured
}

func normalizeCoordinator(raw string) (coordinatorTarget, error) {
	if raw == "" {
		raw = defaultCoordinatorHost
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return coordinatorTarget{}, fmt.Errorf("parse coordinator: %w", err)
	}
	if parsed.Scheme != "https" {
		return coordinatorTarget{}, ErrInsecureScheme
	}
	if parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return coordinatorTarget{}, ErrInvalidCoordinator
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	if parsed.Path != "" {
		return coordinatorTarget{}, ErrInvalidCoordinator
	}
	return coordinatorTarget{url: parsed, host: parsed.Host}, nil
}

func validateProviderID(providerID string) error {
	if !providerIDPattern.MatchString(providerID) {
		return fmt.Errorf("%w: %q", ErrInvalidProviderID, providerID)
	}
	return nil
}

func coordinatorWarnings(coordinatorHost string) []Warning {
	if coordinatorHost == defaultCoordinatorHost {
		return nil
	}
	return []Warning{{
		Kind: "non_default_coordinator",
		Fields: map[string]any{
			"coordinator_host": coordinatorHost,
		},
	}}
}

func liveCheckSkipped(reason string) Warning {
	return Warning{
		Kind: "live_check_skipped",
		Fields: map[string]any{
			"reason": reason,
		},
	}
}

func previousFromCache(prev *cache.PreviousKey) *PreviousKeyResponse {
	if prev == nil {
		return nil
	}
	return &PreviousKeyResponse{
		Pubkey:    cloneBytes(prev.Pubkey),
		RotatedAt: prev.RotatedAt,
		ExpiresAt: prev.ExpiresAt,
	}
}

func clonePrevious(prev *PreviousKeyResponse) *PreviousKeyResponse {
	if prev == nil {
		return nil
	}
	return &PreviousKeyResponse{
		Pubkey:    cloneBytes(prev.Pubkey),
		RotatedAt: prev.RotatedAt,
		ExpiresAt: prev.ExpiresAt,
	}
}

func cloneBytes(in []byte) []byte {
	if in == nil {
		return nil
	}
	out := make([]byte, len(in))
	copy(out, in)
	return out
}
