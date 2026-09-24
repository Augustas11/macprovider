// Command labtool builds the lab-only signed inputs for the #1690 M6
// Trusted Pool external-runtime rehearsal: a lab static-feed release
// (candidate catalog, demand rank, rate card, catalog-artifacts feed, and the
// matching compiled-in Swift inputs for a lab CLI build) and SPEC-042/043
// pool root and manifest events. Every key is a lab key generated here.
//
// It imports coordinator-internal packages, so it is built through a -overlay
// that places this file inside the phase4-coordinator module (see
// scripts/lab/1690-m6/rig.sh build). It never contacts a network.
package main

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: labtool static-release|pool-keygen|pool-root|pool-manifest [flags]")
	}
	var err error
	switch os.Args[1] {
	case "static-release":
		err = staticRelease(os.Args[2:])
	case "pool-keygen":
		err = poolKeygen(os.Args[2:])
	case "pool-root":
		err = poolRoot(os.Args[2:])
	case "pool-manifest":
		err = poolManifest(os.Args[2:])
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fail(err.Error())
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "labtool:", msg)
	os.Exit(1)
}

// ---- static-feed release ----

func loadOrCreateEd25519(path string) (ed25519.PrivateKey, error) {
	if raw, err := os.ReadFile(path); err == nil {
		seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, fmt.Errorf("%s is not a base64 ed25519 seed", path)
		}
		return ed25519.NewKeyFromSeed(seed), nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(priv.Seed())+"\n"), 0o600); err != nil {
		return nil, err
	}
	return priv, nil
}

type rateRow struct {
	CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	GlobalMultiplierPPM       int64 `json:"global_multiplier_ppm"`
	PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
	PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
	ProviderShareBPS          int64 `json:"provider_share_bps"`
}

// rateCardVersion mirrors the coordinator's recommendationRateCardVersion
// projection (phase4-coordinator/internal/buyer/rate_card.go).
func rateCardVersion(rows map[string]rateRow, usdPerMillion float64) string {
	keys := make([]string, 0, len(rows))
	for k := range rows {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	def := rows["default"]
	var b strings.Builder
	b.WriteString(`{"global_multiplier_ppm":` + strconv.FormatInt(def.GlobalMultiplierPPM, 10))
	b.WriteString(`,"provider_share_bps":` + strconv.FormatInt(def.ProviderShareBPS, 10))
	b.WriteString(`,"rows":{`)
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		ek, _ := json.Marshal(k)
		r := rows[k]
		b.Write(ek)
		b.WriteString(`:{"completion_rate_per_mtok":` + strconv.FormatInt(r.CompletionRatePerMtok, 10))
		b.WriteString(`,"global_multiplier_ppm":` + strconv.FormatInt(r.GlobalMultiplierPPM, 10))
		b.WriteString(`,"prompt_cache_hit_rate_per_mtok":` + strconv.FormatInt(r.PromptCacheHitRatePerMtok, 10))
		b.WriteString(`,"prompt_rate_per_mtok":` + strconv.FormatInt(r.PromptRatePerMtok, 10))
		b.WriteString(`,"provider_share_bps":` + strconv.FormatInt(r.ProviderShareBPS, 10))
		b.WriteByte('}')
	}
	b.WriteString(`},"usd_per_million_credits":` + strconv.FormatFloat(usdPerMillion, 'f', -1, 64) + `}`)
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

func writeSigned(dir, name string, body []byte, keyID string, priv ed25519.PrivateKey) error {
	if err := os.WriteFile(dir+"/"+name, body, 0o644); err != nil {
		return err
	}
	sig, err := json.Marshal(map[string]string{
		"key_id":    keyID,
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, body)),
	})
	if err != nil {
		return err
	}
	return os.WriteFile(dir+"/"+name+".sig", sig, 0o644)
}

func staticRelease(args []string) error {
	fs := flag.NewFlagSet("static-release", flag.ExitOnError)
	outDir := fs.String("out-dir", "", "output directory")
	keyFile := fs.String("key-file", "", "lab static-feed ed25519 seed file (created when absent)")
	keyID := fs.String("key-id", "lab-1690-m6-static", "signer key id")
	release := fs.String("release", "", "release id (candidate/demand/artifact version)")
	generatedAt := fs.String("generated-at", "", "RFC3339 UTC release stamp")
	rowKey := fs.String("row-key", "", "catalog row key")
	mlxModelID := fs.String("mlx-model-id", "", "row model_id (MLX primary repo)")
	mlxRevision := fs.String("mlx-revision", "", "row model_revision")
	mlxSHA := fs.String("mlx-sha256", "", "row model_sha256 (MLX primary snapshot-manifest digest)")
	minRAM := fs.Int("min-ram-gb", 8, "row min_ram_gb")
	ggufSHA := fs.String("gguf-sha256", "", "GGUF file sha256 (macprovider.gguf-file.v1)")
	ggufSize := fs.Int64("gguf-size", 0, "GGUF size in bytes")
	ggufRepo := fs.String("gguf-repo", "", "GGUF Hugging Face repo")
	ggufRevision := fs.String("gguf-revision", "", "GGUF Hugging Face revision (40 hex)")
	ggufFile := fs.String("gguf-file", "", "GGUF repository-relative file_path")
	swiftOut := fs.String("swift-out", "", "path for the lab AutotuneCatalog.generated.swift")
	_ = fs.Parse(args)
	for name, v := range map[string]string{"out-dir": *outDir, "key-file": *keyFile, "release": *release, "generated-at": *generatedAt,
		"row-key": *rowKey, "mlx-model-id": *mlxModelID, "mlx-revision": *mlxRevision, "mlx-sha256": *mlxSHA,
		"gguf-sha256": *ggufSHA, "gguf-repo": *ggufRepo, "gguf-revision": *ggufRevision, "gguf-file": *ggufFile, "swift-out": *swiftOut} {
		if v == "" {
			return fmt.Errorf("--%s is required", name)
		}
	}
	priv, err := loadOrCreateEd25519(*keyFile)
	if err != nil {
		return err
	}
	pubB64 := base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
	const policy = "autotune-policy-v1"

	candidates := map[string]any{
		"generated_at":   *generatedAt,
		"policy_version": policy,
		"source":         "operator_curated_autotune_candidate_catalog",
		"version":        *release,
		"rows": map[string]any{*rowKey: map[string]any{
			"bench_gate": map[string]any{
				"max_4k_ttft_ms":    4500,
				"min_sustained_tps": 15,
				"provenance": map[string]any{
					"hardware": "M3 Ultra lab",
					"notes":    "lab-1690-m6 rehearsal row; not a production catalog row.",
					"source":   "measured_single_host",
				},
			},
			"min_bandwidth_tier": "C",
			"min_ram_gb":         *minRAM,
			"model_id":           *mlxModelID,
			"model_revision":     *mlxRevision,
			"model_sha256":       *mlxSHA,
			"notes":              "lab-1690-m6: MLX primary is a lab placeholder digest; the GGUF sibling is the served, verified artifact.",
			"runtime_status":     "recommendable",
		}},
	}
	demand := map[string]any{
		"cold_start_floor":     0.15,
		"diversification_band": 0.85,
		"generated_at":         *generatedAt,
		"policy_version":       policy,
		"source":               "openrouter_completion_token_rank_operator_curated",
		"version":              *release,
		"rows": map[string]any{*rowKey: map[string]any{
			"demand_weight": 0.5, "min_provider_target": 1, "rank": 1, "recommendable": true,
		}},
	}
	def := rateRow{CompletionRatePerMtok: 1000000, GlobalMultiplierPPM: 1000000, PromptCacheHitRatePerMtok: 125000, PromptRatePerMtok: 500000, ProviderShareBPS: 9000}
	rows := map[string]rateRow{"default": def, *rowKey: def}
	rateCard := map[string]any{
		"generated_at":            *generatedAt,
		"policy_version":          policy,
		"usd_per_million_credits": 1.0,
		"version":                 rateCardVersion(rows, 1.0),
		"rows":                    rows,
	}
	candBytes, err := json.Marshal(candidates)
	if err != nil {
		return err
	}
	demandBytes, err := json.Marshal(demand)
	if err != nil {
		return err
	}
	rateBytes, err := json.Marshal(rateCard)
	if err != nil {
		return err
	}
	candSum := sha256.Sum256(candBytes)
	verifiedAt := (*generatedAt)[:10]
	artifacts := map[string]any{
		"candidate_catalog_sha256": hex.EncodeToString(candSum[:]),
		"generated_at":             *generatedAt,
		"policy_version":           policy,
		"release_id":               *release,
		"version":                  *release,
		"source":                   "operator_curated_autotune_artifact_catalog",
		"models": map[string]any{*rowKey: map[string]any{
			"primary_artifact_id": "mlx-4bit",
			"rate_class":          "class-3b",
			"artifacts": map[string]any{
				"mlx-4bit": map[string]any{
					"runtime_format": "mlx_safetensors", "hash_algorithm": "macprovider.snapshot-manifest.v1", "hash": *mlxSHA,
					"quantization": "4bit", "size_bytes": 1, "min_ram_gb": *minRAM, "allowed_runtime_sources": []string{"mlx_cache"},
					"source_ref":          map[string]any{"kind": "huggingface_revision", "repo_id": *mlxModelID, "revision": *mlxRevision},
					"verification_status": "verified", "verified_at": verifiedAt,
				},
				"gguf-q4-k-m": map[string]any{
					"runtime_format": "gguf", "hash_algorithm": "macprovider.gguf-file.v1", "hash": *ggufSHA,
					"quantization": "q4_k_m", "size_bytes": *ggufSize, "min_ram_gb": *minRAM, "allowed_runtime_sources": []string{"llamacpp_loopback"},
					"source_ref":          map[string]any{"kind": "huggingface_revision", "repo_id": *ggufRepo, "revision": *ggufRevision, "file_path": *ggufFile},
					"verification_status": "verified", "verified_at": verifiedAt,
				},
			},
		}},
	}
	artBytes, err := json.Marshal(artifacts)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		return err
	}
	for name, body := range map[string][]byte{
		"autotune-candidates.json": candBytes, "demand-rank.json": demandBytes,
		"rate-card.json": rateBytes, "catalog-artifacts.json": artBytes,
	} {
		if err := writeSigned(*outDir, name, body, *keyID, priv); err != nil {
			return err
		}
	}
	if err := os.WriteFile(*outDir+"/static-public-key.base64", []byte(pubB64+"\n"), 0o644); err != nil {
		return err
	}
	for _, b := range [][]byte{candBytes, demandBytes, rateBytes} {
		if strings.Contains(string(b), `\`) || strings.Contains(string(b), `"""`) {
			return errors.New("feed bytes are not safe inside a Swift multi-line literal")
		}
	}
	swift := "// Generated by scripts/lab/1690-m6/labtool (LAB BUILD ONLY). DO NOT COMMIT.\n" +
		"import Foundation\n\nextension AutotuneStaticInputs {\n" +
		"    static let bakedDemandRankJSON = \"\"\"\n    " + string(demandBytes) + "\n    \"\"\"\n\n" +
		"    static let bakedCandidateCatalogJSON = \"\"\"\n    " + string(candBytes) + "\n    \"\"\"\n\n" +
		"    static let bakedRateCardJSON = \"\"\"\n    " + string(rateBytes) + "\n    \"\"\"\n\n" +
		"    static let generatedTrustedPublicKeys = [\n        \"" + *keyID + "\": \"" + pubB64 + "\",\n    ]\n\n" +
		"    static let bakedCatalogSignerKeyID: String? = \"" + *keyID + "\"\n\n" +
		"    static let bakedArtifactFeedBase64: String? = nil\n" +
		"    static let bakedArtifactFeedSignerKeyID: String? = nil\n}\n"
	if err := os.WriteFile(*swiftOut, []byte(swift), 0o644); err != nil {
		return err
	}
	fmt.Printf("candidate_catalog_sha256=%s\nrate_card_version=%s\npublic_key=%s\n", hex.EncodeToString(candSum[:]), rateCard["version"], pubB64)
	return nil
}

// ---- pool root and manifest ----

type poolKeys struct {
	RootP256PKCS8     string `json:"root_p256_pkcs8"`
	AuthoritySeed     string `json:"authority_ed25519_seed"`
	PolicySeed        string `json:"policy_ed25519_seed"`
	GenesisNonce      string `json:"genesis_nonce"`
	PoolID            string `json:"pool_id"`
	AuthorityKeyID    string `json:"authority_key_id"`
	PolicySignerKeyID string `json:"policy_signer_key_id"`
}

type loadedPoolKeys struct {
	root        *ecdsa.PrivateKey
	rootDER     []byte
	fingerprint string
	authority   ed25519.PrivateKey
	policy      ed25519.PrivateKey
	identity    poolmanifest.IdentityCore
	raw         poolKeys
}

func poolKeygen(args []string) error {
	fs := flag.NewFlagSet("pool-keygen", flag.ExitOnError)
	out := fs.String("out", "", "pool key file (0600)")
	_ = fs.Parse(args)
	if *out == "" {
		return errors.New("--out is required")
	}
	if _, err := os.Stat(*out); err == nil {
		return fmt.Errorf("%s already exists", *out)
	}
	root, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	pkcs8, err := x509.MarshalPKCS8PrivateKey(root)
	if err != nil {
		return err
	}
	_, authority, _ := ed25519.GenerateKey(rand.Reader)
	_, policy, _ := ed25519.GenerateKey(rand.Reader)
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	keys := poolKeys{
		RootP256PKCS8:     base64.StdEncoding.EncodeToString(pkcs8),
		AuthoritySeed:     base64.StdEncoding.EncodeToString(authority.Seed()),
		PolicySeed:        base64.StdEncoding.EncodeToString(policy.Seed()),
		GenesisNonce:      base64.StdEncoding.EncodeToString(nonce),
		AuthorityKeyID:    "lab-manifest-root-1",
		PolicySignerKeyID: "lab-policy-signer-1",
	}
	keys.PoolID, err = poolmanifest.IdentityCore{RootIssuerKeyID: keys.AuthorityKeyID, GenesisNonce: nonce}.PoolID()
	if err != nil {
		return err
	}
	raw, err := json.MarshalIndent(keys, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, raw, 0o600); err != nil {
		return err
	}
	fmt.Println(keys.PoolID)
	return nil
}

func loadPoolKeys(path string) (loadedPoolKeys, error) {
	var k poolKeys
	raw, err := os.ReadFile(path)
	if err != nil {
		return loadedPoolKeys{}, err
	}
	if err := json.Unmarshal(raw, &k); err != nil {
		return loadedPoolKeys{}, err
	}
	decode := func(s string) []byte { b, _ := base64.StdEncoding.DecodeString(s); return b }
	parsed, err := x509.ParsePKCS8PrivateKey(decode(k.RootP256PKCS8))
	if err != nil {
		return loadedPoolKeys{}, err
	}
	root, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return loadedPoolKeys{}, errors.New("root key is not ECDSA")
	}
	der, err := x509.MarshalPKIXPublicKey(&root.PublicKey)
	if err != nil {
		return loadedPoolKeys{}, err
	}
	fp, err := trustpool.RootIssuerPublicKeyFingerprint(trustpool.RootSignatureAlgorithmP256SHA256, der)
	if err != nil {
		return loadedPoolKeys{}, err
	}
	return loadedPoolKeys{
		root: root, rootDER: der, fingerprint: fp,
		authority: ed25519.NewKeyFromSeed(decode(k.AuthoritySeed)),
		policy:    ed25519.NewKeyFromSeed(decode(k.PolicySeed)),
		identity:  poolmanifest.IdentityCore{RootIssuerKeyID: k.AuthorityKeyID, GenesisNonce: decode(k.GenesisNonce)},
		raw:       k,
	}, nil
}

func signP256(key *ecdsa.PrivateKey, msg []byte) (string, error) {
	digest := sha256.Sum256(msg)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(sig), nil
}

func hexSHA(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func printEvent(e trustpool.DurableEvent) error {
	raw, err := json.Marshal(e)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

func poolRoot(args []string) error {
	fs := flag.NewFlagSet("pool-root", flag.ExitOnError)
	keysPath := fs.String("keys", "", "pool key file")
	op := fs.String("op", "", "operation id")
	creator := fs.String("creator", "", "creator account id")
	approval := fs.String("approval", "", "approval record id")
	approvalVersion := fs.String("approval-version", "", "current approval version")
	nonce := fs.String("nonce", "", "issued root registration nonce")
	nonceExpiry := fs.String("nonce-expiry", "", "issued nonce expiry (RFC3339)")
	_ = fs.Parse(args)
	k, err := loadPoolKeys(*keysPath)
	if err != nil {
		return err
	}
	e := trustpool.DurableEvent{
		OperationID:                        *op,
		TimestampUTC:                       time.Now().UTC(),
		EventType:                          trustpool.EventRootIssuerRegistered,
		PoolID:                             k.raw.PoolID,
		CreatorAccountID:                   *creator,
		ApprovalRecordID:                   *approval,
		CurrentApprovalVersion:             *approvalVersion,
		RootIssuerKeyID:                    "lab-root-key-1",
		RootIssuerPublicKeyDER:             base64.StdEncoding.EncodeToString(k.rootDER),
		RootIssuerPublicKeyFingerprint:     k.fingerprint,
		RootSignatureAlgorithm:             trustpool.RootSignatureAlgorithmP256SHA256,
		ManifestAuthorityRootKeyID:         k.raw.AuthorityKeyID,
		ManifestAuthorityRootPublicKey:     base64.StdEncoding.EncodeToString(k.authority.Public().(ed25519.PublicKey)),
		StructuredKeyCustodyDisclosureHash: hexSHA([]byte("lab-1690-m6 software custody (lab only)")),
		GenesisNonceDigest:                 hexSHA(k.identity.GenesisNonce),
		IntendedPoolDisplayNameHash:        hexSHA([]byte("lab-1690-m6 llama.cpp pool")),
		LaunchEnvironment:                  "candidate",
		RootRegistrationNonce:              *nonce,
		RootRegistrationNonceExpiry:        *nonceExpiry,
		RootRegistrationPurpose:            trustpool.RootRegistrationPurposeDefault,
		RootRegistrationEnvironment:        "candidate",
	}
	msg, err := trustpool.RootRegistrationSigningMessage(e)
	if err != nil {
		return err
	}
	if e.RootRegistrationSignature, err = signP256(k.root, msg); err != nil {
		return err
	}
	return printEvent(e)
}

func splitCSV(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

func poolManifest(args []string) error {
	fs := flag.NewFlagSet("pool-manifest", flag.ExitOnError)
	keysPath := fs.String("keys", "", "pool key file")
	op := fs.String("op", "", "operation id")
	prevPath := fs.String("prev", "", "previous manifest_accepted event JSON (extends its snapshot)")
	encoding := fs.Int("encoding", 2, "policy core encoding: 1 or 2")
	allowlist := fs.String("runtime-allowlist", "", "comma-separated runtime_allowlist (v2 only)")
	settlement := fs.String("settlement-mode", "enforce", "settlement mode")
	models := fs.String("models", "", "comma-separated model allowlist")
	minBinary := fs.String("min-binary-version", "1.8.33", "pool min binary version")
	window := fs.Uint64("window-seconds", 30*24*3600, "policy validity window; a successor starts when this one ends")
	_ = fs.Parse(args)
	k, err := loadPoolKeys(*keysPath)
	if err != nil {
		return err
	}
	now := uint64(time.Now().Unix())
	core := poolmanifest.PolicyCore{
		PoolID:               k.raw.PoolID,
		ManifestVersion:      1,
		PrevManifestCoreHash: poolmanifest.GenesisPrevHash(),
		SignerSetVersion:     1,
		ModelAllowlist:       splitCSV(*models),
		MinBinaryVersion:     *minBinary,
		MinAttestationTier:   "hardware",
		SettlementMode:       *settlement,
		SplitExecutionStatus: "declared_not_executed",
		RetentionPolicyID:    "standard",
		MinEligibleMembers:   1,
		PrivacyMode:          "none",
		MetadataVisible:      "standard",
		DowngradePolicy:      "reject",
		NotBeforeUnix:        now - 60,
		ExpiresAtUnix:        now + *window,
		Encoding:             uint8(*encoding),
	}
	if *encoding == int(poolmanifest.PolicyCoreEncodingV2) {
		core.RuntimeAllowlist = splitCSV(*allowlist)
	}
	var snapshot poolmanifest.ManifestSnapshot
	if *prevPath != "" {
		var prev trustpool.DurableEvent
		raw, err := os.ReadFile(*prevPath)
		if err != nil {
			return err
		}
		if err := json.Unmarshal(raw, &prev); err != nil {
			return err
		}
		snapRaw, err := base64.StdEncoding.DecodeString(prev.ManifestSnapshot)
		if err != nil {
			return err
		}
		if snapshot, err = poolmanifest.ParseManifestSnapshot(snapRaw); err != nil {
			return err
		}
		prevDigest, err := hex.DecodeString(prev.ManifestCoreDigest)
		if err != nil {
			return err
		}
		prevCore := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
		core.ManifestVersion = prev.ManifestVersion + 1
		core.PrevManifestCoreHash = prevDigest
		// The prior core's window must not overlap the new one.
		core.NotBeforeUnix = prevCore.ExpiresAtUnix
		core.ExpiresAtUnix = prevCore.ExpiresAtUnix + *window
	} else {
		entry := poolmanifest.AuthorityLogEntry{
			PoolID:                      k.raw.PoolID,
			SignerSetVersion:            1,
			PrevAuthorityLogEntryHash:   poolmanifest.GenesisPrevHash(),
			Keys:                        []poolmanifest.SignerKey{{KeyID: k.raw.PolicySignerKeyID, PublicKey: k.policy.Public().(ed25519.PublicKey)}},
			Threshold:                   1,
			NotBeforeUnix:               1,
			ExpiresAtUnix:               9999999999,
			AuthorizingSignerSetVersion: 0,
		}
		h, err := entry.EntryHash()
		if err != nil {
			return err
		}
		msg, err := poolmanifest.AuthorityLogEntrySigningMessage(h)
		if err != nil {
			return err
		}
		entry.Signatures = []poolmanifest.Signature{{KeyID: k.raw.AuthorityKeyID, Sig: ed25519.Sign(k.authority, msg)}}
		snapshot = poolmanifest.ManifestSnapshot{
			IdentityCore:  k.identity,
			RootIssuerKey: poolmanifest.SignerKey{KeyID: k.raw.AuthorityKeyID, PublicKey: k.authority.Public().(ed25519.PublicKey)},
			AuthorityLog:  []poolmanifest.AuthorityLogEntry{entry},
		}
	}
	digest, err := core.ManifestCoreDigest()
	if err != nil {
		return err
	}
	policyMsg, err := core.SigningMessage()
	if err != nil {
		return err
	}
	snapshot.Policies = append(snapshot.Policies, poolmanifest.AcceptedPolicyRecord{
		SignedCore: poolmanifest.SignedPolicyCore{
			Core:       core,
			Signatures: []poolmanifest.Signature{{KeyID: k.raw.PolicySignerKeyID, Sig: ed25519.Sign(k.policy, policyMsg)}},
		},
		AcceptedAtUnix: now,
	})
	snapRaw, err := snapshot.CanonicalBytes()
	if err != nil {
		return err
	}
	e := trustpool.DurableEvent{
		OperationID:                    *op,
		TimestampUTC:                   time.Now().UTC(),
		EventType:                      trustpool.EventManifestAccepted,
		PoolID:                         k.raw.PoolID,
		ManifestVersion:                core.ManifestVersion,
		ManifestCoreDigest:             hex.EncodeToString(digest),
		RootIssuerKeyID:                "lab-root-key-1",
		RootIssuerPublicKeyFingerprint: k.fingerprint,
		ManifestSnapshot:               base64.StdEncoding.EncodeToString(snapRaw),
	}
	msg, err := trustpool.ManifestAcceptanceSigningMessage(e)
	if err != nil {
		return err
	}
	if e.ManifestSignature, err = signP256(k.root, msg); err != nil {
		return err
	}
	return printEvent(e)
}
