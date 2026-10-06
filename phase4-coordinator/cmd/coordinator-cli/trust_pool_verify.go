package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// trustPoolManifestVerificationSchema names the verify-manifest output.
const trustPoolManifestVerificationSchema = "macprovider.trust-pool-manifest-verification.v1"

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
	ManifestVersion      uint64                    `json:"manifest_version"`
	ManifestCoreDigest   string                    `json:"manifest_core_digest"`
	ManifestTermsDigest  string                    `json:"manifest_terms_digest"`
	PrevManifestCoreHash string                    `json:"prev_manifest_core_hash"`
	EventSHA256          string                    `json:"event_sha256"`
	NotBeforeUnix        uint64                    `json:"not_before_unix"`
	ExpiresAtUnix        uint64                    `json:"expires_at_unix"`
	Encoding             uint8                     `json:"encoding"`
	SettlementMode       string                    `json:"settlement_mode"`
	RuntimeAllowlist     []string                  `json:"runtime_allowlist"`
	ModelEntries         []trustPoolVerifiedEntry  `json:"model_entries"`
	AttestedMembers      []trustPoolVerifiedMember `json:"attested_members"`
}

type trustPoolManifestVerification struct {
	Schema                         string                      `json:"schema"`
	PoolID                         string                      `json:"pool_id"`
	CreatorAccountID               string                      `json:"creator_account_id"`
	LaunchEnvironment              string                      `json:"launch_environment"`
	RootIssuerKeyID                string                      `json:"root_issuer_key_id"`
	RootIssuerPublicKeyFingerprint string                      `json:"root_issuer_public_key_fingerprint"`
	RootEventSHA256                string                      `json:"root_event_sha256"`
	Manifests                      []trustPoolVerifiedManifest `json:"manifests"`
}

type repeatedPathFlag []string

func (r *repeatedPathFlag) String() string     { return strings.Join(*r, ",") }
func (r *repeatedPathFlag) Set(v string) error { *r = append(*r, v); return nil }

// trustPoolAdminVerifyManifest is a read-only, offline check of captured
// signed pool events: the root registration's proof of possession, each
// manifest_accepted event's root signature and snapshot (the same verifier the
// durable store replays with), each core's SPEC-042-R001/R015/R016 acceptance
// grammar, and that every given manifest is the same core the newest given
// snapshot carries at that version (one chain). It prints the decoded cores.
func trustPoolAdminVerifyManifest(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("trust-pool-admin verify-manifest", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	rootPath := fs.String("root", "", "root_issuer_registered event JSON (sign-root --out)")
	var manifestPaths repeatedPathFlag
	fs.Var(&manifestPaths, "manifest", "manifest_accepted event JSON (sign-manifest --out); repeat for each version")
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
	out := trustPoolManifestVerification{
		Schema:                         trustPoolManifestVerificationSchema,
		PoolID:                         root.PoolID,
		CreatorAccountID:               root.CreatorAccountID,
		LaunchEnvironment:              root.LaunchEnvironment,
		RootIssuerKeyID:                root.RootIssuerKeyID,
		RootIssuerPublicKeyFingerprint: root.RootIssuerPublicKeyFingerprint,
		RootEventSHA256:                rootSHA,
	}
	var newest trustpool.DurableEvent
	seen := map[uint64]bool{}
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
		prev, core, err := trustpool.VerifyManifestAcceptedEvent(e, issuer)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if err := core.ValidateAcceptance(); err != nil {
			return fmt.Errorf("%s: core acceptance grammar: %w", path, err)
		}
		if seen[e.ManifestVersion] {
			return fmt.Errorf("%s: manifest version %d given twice", path, e.ManifestVersion)
		}
		seen[e.ManifestVersion] = true
		terms, err := core.PolicyTermsDigest()
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		entries, err := core.PoolModelEntries()
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		members, err := core.PoolAttestedMembers()
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		m := trustPoolVerifiedManifest{
			ManifestVersion:      e.ManifestVersion,
			ManifestCoreDigest:   e.ManifestCoreDigest,
			ManifestTermsDigest:  hex.EncodeToString(terms),
			PrevManifestCoreHash: prev,
			EventSHA256:          sum,
			NotBeforeUnix:        core.NotBeforeUnix,
			ExpiresAtUnix:        core.ExpiresAtUnix,
			Encoding:             core.Encoding,
			SettlementMode:       core.SettlementMode,
			RuntimeAllowlist:     append([]string{}, core.RuntimeAllowlist...),
			ModelEntries:         []trustPoolVerifiedEntry{},
			AttestedMembers:      []trustPoolVerifiedMember{},
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
		if e.ManifestVersion > newest.ManifestVersion {
			newest = e
		}
	}
	sort.Slice(out.Manifests, func(i, j int) bool { return out.Manifests[i].ManifestVersion < out.Manifests[j].ManifestVersion })
	// One chain: the newest given snapshot carries every accepted core, so
	// each given manifest must be the core it holds at that version.
	raw, err := base64.StdEncoding.Strict().DecodeString(newest.ManifestSnapshot)
	if err != nil {
		return fmt.Errorf("newest manifest snapshot: %w", err)
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		return fmt.Errorf("newest manifest snapshot: %w", err)
	}
	chain := map[uint64]string{}
	for _, record := range snapshot.Policies {
		digest, err := record.SignedCore.Core.ManifestCoreDigest()
		if err != nil {
			return fmt.Errorf("newest manifest snapshot: %w", err)
		}
		chain[record.SignedCore.Core.ManifestVersion] = hex.EncodeToString(digest)
	}
	for _, m := range out.Manifests {
		if chain[m.ManifestVersion] != m.ManifestCoreDigest {
			return fmt.Errorf("manifest version %d is not the core the newest snapshot holds at that version", m.ManifestVersion)
		}
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

func readVerifyEvent(path string) (trustpool.DurableEvent, string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return trustpool.DurableEvent{}, "", err
	}
	var e trustpool.DurableEvent
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&e); err != nil {
		return trustpool.DurableEvent{}, "", fmt.Errorf("%s: %w", path, err)
	}
	if dec.More() {
		return trustpool.DurableEvent{}, "", fmt.Errorf("%s: more than one JSON value", path)
	}
	sum := sha256.Sum256(raw)
	return e, hex.EncodeToString(sum[:]), nil
}
