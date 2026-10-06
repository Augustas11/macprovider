package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// trustPoolManifestVerificationSchema names the verify-manifest output.
const trustPoolManifestVerificationSchema = "macprovider.trust-pool-manifest-verification.v2"

type trustPoolVerifiedEntry struct {
	PoolModelID               string   `json:"pool_model_id"`
	ArtifactHashAlgorithm     string   `json:"artifact_hash_algorithm"`
	ArtifactHash              string   `json:"artifact_hash"`
	AllowedRuntimeSources     []string `json:"allowed_runtime_sources"`
	License                   string   `json:"license"`
	PaidServingAttested       bool     `json:"paid_serving_attested"`
	PromptRatePerMtok         uint64   `json:"prompt_rate_per_mtok"`
	PromptCacheHitRatePerMtok uint64   `json:"prompt_cache_hit_rate_per_mtok"`
	CompletionRatePerMtok     uint64   `json:"completion_rate_per_mtok"`
	DisclosureClass           string   `json:"disclosure_class"`
	MaxContextTokens          uint64   `json:"max_context_tokens"`
}

type trustPoolVerifiedMember struct {
	ProviderAccountID string   `json:"provider_account_id"`
	RuntimeClasses    []string `json:"runtime_classes"`
}

type trustPoolVerifiedManifest struct {
	ManifestVersion      uint64 `json:"manifest_version"`
	ManifestCoreDigest   string `json:"manifest_core_digest"`
	ManifestTermsDigest  string `json:"manifest_terms_digest"`
	PrevManifestCoreHash string `json:"prev_manifest_core_hash"`
	// EventSHA256 is the sha256 of the supplied manifest_accepted event for
	// this version, or null when the version was proven from the newest
	// event's snapshot alone.
	EventSHA256      *string                   `json:"event_sha256"`
	NotBeforeUnix    uint64                    `json:"not_before_unix"`
	ExpiresAtUnix    uint64                    `json:"expires_at_unix"`
	Encoding         uint8                     `json:"encoding"`
	SettlementMode   string                    `json:"settlement_mode"`
	RuntimeAllowlist []string                  `json:"runtime_allowlist"`
	ModelEntries     []trustPoolVerifiedEntry  `json:"model_entries"`
	AttestedMembers  []trustPoolVerifiedMember `json:"attested_members"`
}

type trustPoolManifestVerification struct {
	Schema                         string                      `json:"schema"`
	PoolID                         string                      `json:"pool_id"`
	CreatorAccountID               string                      `json:"creator_account_id"`
	LaunchEnvironment              string                      `json:"launch_environment"`
	RootIssuerKeyID                string                      `json:"root_issuer_key_id"`
	RootIssuerPublicKeyFingerprint string                      `json:"root_issuer_public_key_fingerprint"`
	RootEventSHA256                string                      `json:"root_event_sha256"`
	NewestManifestVersion          uint64                      `json:"newest_manifest_version"`
	Manifests                      []trustPoolVerifiedManifest `json:"manifests"`
}

type repeatedPathFlag []string

func (r *repeatedPathFlag) String() string     { return strings.Join(*r, ",") }
func (r *repeatedPathFlag) Set(v string) error { *r = append(*r, v); return nil }

// trustPoolAdminVerifyManifest is a read-only, offline check of captured
// signed pool events. It verifies the root registration's proof of
// possession and each supplied manifest_accepted event with the durable
// store's own verifier (root signature, snapshot, timeless replay of every
// accepted policy). The newest supplied event's snapshot carries the whole
// accepted history, so the output lists every version 1..newest, each core
// checked against the SPEC-042-R001/R015/R016 acceptance grammar and chained
// to its predecessor; a supplied older event must be the core that history
// holds at its version.
func trustPoolAdminVerifyManifest(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("trust-pool-admin verify-manifest", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	rootPath := fs.String("root", "", "root_issuer_registered event JSON (sign-root --out)")
	var manifestPaths repeatedPathFlag
	fs.Var(&manifestPaths, "manifest", "manifest_accepted event JSON (sign-manifest --out); the newest is required, older ones are optional")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 || strings.TrimSpace(*rootPath) == "" || len(manifestPaths) == 0 {
		return fmt.Errorf("verify-manifest needs --root, at least one --manifest, and no positional arguments")
	}
	root, rootSHA, err := readVerifyEvent(*rootPath)
	if err != nil {
		return err
	}
	if root.EventType != trustpool.EventRootIssuerRegistered {
		return fmt.Errorf("--root: want a %s event", trustpool.EventRootIssuerRegistered)
	}
	if err := trustpool.VerifyRootIssuerRegistrationEvent(root); err != nil {
		return fmt.Errorf("--root: %w", err)
	}
	issuer := trustpool.ReconstructedRootIssuer{
		KeyID:                           root.RootIssuerKeyID,
		PublicKeyDER:                    root.RootIssuerPublicKeyDER,
		PublicKeyFingerprint:            root.RootIssuerPublicKeyFingerprint,
		SignatureAlgorithm:              root.RootSignatureAlgorithm,
		CurrentApprovalVersion:          root.CurrentApprovalVersion,
		ManifestAuthorityRootKeyID:      root.ManifestAuthorityRootKeyID,
		ManifestAuthorityRootPublicKey:  root.ManifestAuthorityRootPublicKey,
		StructuredCustodyDisclosureHash: root.StructuredKeyCustodyDisclosureHash,
		GenesisNonceDigest:              root.GenesisNonceDigest,
		IntendedPoolDisplayNameHash:     root.IntendedPoolDisplayNameHash,
		LaunchEnvironment:               root.LaunchEnvironment,
		RegistrationNonce:               root.RootRegistrationNonce,
		RegistrationNonceExpiry:         root.RootRegistrationNonceExpiry,
	}
	supplied := map[uint64]string{}
	suppliedDigest := map[uint64]string{}
	var newest trustpool.DurableEvent
	for _, path := range manifestPaths {
		e, sum, err := readVerifyEvent(path)
		if err != nil {
			return err
		}
		if e.EventType != trustpool.EventManifestAccepted {
			return fmt.Errorf("%s: want a %s event", path, trustpool.EventManifestAccepted)
		}
		if e.PoolID != root.PoolID || e.RootIssuerKeyID != root.RootIssuerKeyID {
			return fmt.Errorf("%s: pool or root issuer differs from --root", path)
		}
		if _, _, err := trustpool.VerifyManifestAcceptedEvent(e, issuer); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if _, dup := supplied[e.ManifestVersion]; dup {
			return fmt.Errorf("%s: manifest version %d given twice", path, e.ManifestVersion)
		}
		supplied[e.ManifestVersion] = sum
		suppliedDigest[e.ManifestVersion] = e.ManifestCoreDigest
		if e.ManifestVersion > newest.ManifestVersion {
			newest = e
		}
	}
	raw, err := base64.StdEncoding.Strict().DecodeString(newest.ManifestSnapshot)
	if err != nil {
		return fmt.Errorf("newest manifest snapshot: %w", err)
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		return fmt.Errorf("newest manifest snapshot: %w", err)
	}
	out := trustPoolManifestVerification{
		Schema:                         trustPoolManifestVerificationSchema,
		PoolID:                         root.PoolID,
		CreatorAccountID:               root.CreatorAccountID,
		LaunchEnvironment:              root.LaunchEnvironment,
		RootIssuerKeyID:                root.RootIssuerKeyID,
		RootIssuerPublicKeyFingerprint: root.RootIssuerPublicKeyFingerprint,
		RootEventSHA256:                rootSHA,
		NewestManifestVersion:          newest.ManifestVersion,
	}
	prevDigest := strings.Repeat("0", 64)
	for index, record := range snapshot.Policies {
		core := record.SignedCore.Core
		version := uint64(index + 1)
		if core.ManifestVersion != version {
			return fmt.Errorf("newest snapshot: accepted history is not contiguous at version %d", version)
		}
		if hex.EncodeToString(core.PrevManifestCoreHash) != prevDigest {
			return fmt.Errorf("newest snapshot: version %d does not chain to its predecessor", version)
		}
		if err := core.ValidateAcceptance(); err != nil {
			return fmt.Errorf("newest snapshot version %d: core acceptance grammar: %w", version, err)
		}
		digestBytes, err := core.ManifestCoreDigest()
		if err != nil {
			return fmt.Errorf("newest snapshot version %d: %w", version, err)
		}
		digest := hex.EncodeToString(digestBytes)
		if want, ok := suppliedDigest[version]; ok && want != digest {
			return fmt.Errorf("manifest version %d is not the core the newest snapshot holds at that version", version)
		}
		terms, err := core.PolicyTermsDigest()
		if err != nil {
			return fmt.Errorf("newest snapshot version %d: %w", version, err)
		}
		entries, err := core.PoolModelEntries()
		if err != nil {
			return fmt.Errorf("newest snapshot version %d: %w", version, err)
		}
		members, err := core.PoolAttestedMembers()
		if err != nil {
			return fmt.Errorf("newest snapshot version %d: %w", version, err)
		}
		m := trustPoolVerifiedManifest{
			ManifestVersion:      version,
			ManifestCoreDigest:   digest,
			ManifestTermsDigest:  hex.EncodeToString(terms),
			PrevManifestCoreHash: prevDigest,
			NotBeforeUnix:        core.NotBeforeUnix,
			ExpiresAtUnix:        core.ExpiresAtUnix,
			Encoding:             core.Encoding,
			SettlementMode:       core.SettlementMode,
			RuntimeAllowlist:     append([]string{}, core.RuntimeAllowlist...),
			ModelEntries:         []trustPoolVerifiedEntry{},
			AttestedMembers:      []trustPoolVerifiedMember{},
		}
		if sum, ok := supplied[version]; ok {
			s := sum
			m.EventSHA256 = &s
		}
		for _, entry := range entries {
			m.ModelEntries = append(m.ModelEntries, trustPoolVerifiedEntry{
				PoolModelID: entry.PoolModelID, ArtifactHashAlgorithm: entry.ArtifactHashAlgorithm, ArtifactHash: entry.ArtifactHash,
				AllowedRuntimeSources: append([]string{}, entry.AllowedRuntimeSources...), License: entry.License,
				PaidServingAttested: entry.PaidServingAttested, PromptRatePerMtok: entry.Pricing.PromptRatePerMtok,
				PromptCacheHitRatePerMtok: entry.Pricing.PromptCacheHitRatePerMtok, CompletionRatePerMtok: entry.Pricing.CompletionRatePerMtok,
				DisclosureClass: entry.DisclosureClass, MaxContextTokens: entry.MaxContextTokens,
			})
		}
		for _, member := range members {
			m.AttestedMembers = append(m.AttestedMembers, trustPoolVerifiedMember{
				ProviderAccountID: member.ProviderAccountID, RuntimeClasses: append([]string{}, member.RuntimeClasses...),
			})
		}
		out.Manifests = append(out.Manifests, m)
		prevDigest = digest
	}
	if uint64(len(out.Manifests)) != newest.ManifestVersion {
		return fmt.Errorf("newest snapshot must hold every accepted version 1..%d", newest.ManifestVersion)
	}
	for version := range supplied {
		if version > newest.ManifestVersion || version == 0 {
			return fmt.Errorf("manifest version %d is outside the verified history", version)
		}
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

// trustPoolAdminVerifyRouteSnapshot is a read-only recomputation of captured
// SPEC-022 route snapshots: each file is one settlement_route_snapshots
// route_snapshot_json value (the digest preimage), decoded strictly into the
// coordinator's RouteSnapshot, validated, and digested with the coordinator's
// own canonicalization. It prints the recomputed digests in input order.
func trustPoolAdminVerifyRouteSnapshot(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("trust-pool-admin verify-route-snapshot", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var paths repeatedPathFlag
	fs.Var(&paths, "snapshot", "route_snapshot_json of one attempt; repeat")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 || len(paths) == 0 {
		return fmt.Errorf("verify-route-snapshot needs at least one --snapshot and no positional arguments")
	}
	type result struct {
		RouteSnapshotDigest string `json:"route_snapshot_digest"`
	}
	results := make([]result, 0, len(paths))
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := rejectDuplicateJSONKeys(raw); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		var snapshot billing.RouteSnapshot
		if err := decodeStrictJSON(raw, &snapshot); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		digest, _, err := snapshot.Digest()
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		// The captured value must be exactly the preimage the digest covers.
		var captured, rebuilt any
		rendered, err := json.Marshal(snapshot.Value())
		if err != nil {
			return err
		}
		if err := json.Unmarshal(raw, &captured); err != nil {
			return err
		}
		if err := json.Unmarshal(rendered, &rebuilt); err != nil {
			return err
		}
		if !reflect.DeepEqual(captured, rebuilt) {
			return fmt.Errorf("%s: route_snapshot_json is not the canonical preimage of its fields", path)
		}
		results = append(results, result{RouteSnapshotDigest: digest})
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(results)
}

func readVerifyEvent(path string) (trustpool.DurableEvent, string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return trustpool.DurableEvent{}, "", err
	}
	if err := rejectDuplicateJSONKeys(raw); err != nil {
		return trustpool.DurableEvent{}, "", fmt.Errorf("%s: %w", path, err)
	}
	var e trustpool.DurableEvent
	if err := decodeStrictJSON(raw, &e); err != nil {
		return trustpool.DurableEvent{}, "", fmt.Errorf("%s: %w", path, err)
	}
	sum := sha256.Sum256(raw)
	return e, hex.EncodeToString(sum[:]), nil
}

// decodeStrictJSON decodes exactly one JSON value with no unknown fields and
// nothing after it.
func decodeStrictJSON(raw []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return fmt.Errorf("trailing data after the JSON value")
	}
	return nil
}

// rejectDuplicateJSONKeys fails on any object that repeats a key, at any
// depth: encoding/json keeps the last value silently.
func rejectDuplicateJSONKeys(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var walk func() error
	walk = func() error {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		delim, ok := tok.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return err
				}
				key, _ := keyTok.(string)
				if seen[key] {
					return fmt.Errorf("duplicate JSON object key %q", key)
				}
				seen[key] = true
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = dec.Token()
			return err
		case '[':
			for dec.More() {
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = dec.Token()
			return err
		}
		return nil
	}
	return walk()
}
