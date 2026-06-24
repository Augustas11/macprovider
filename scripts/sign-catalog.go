package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type signature struct {
	Alg   string `json:"alg"`
	KeyID string `json:"key_id"`
	Sig   string `json:"sig"`
}

type modelEntry struct {
	ArtifactKind string `json:"artifact_kind"`
	HashScope    string `json:"hash_scope"`
	ModelID      string `json:"model_id"`
	MinRAMGB     *int   `json:"min_ram_gb,omitempty"`
	Notes        string `json:"notes,omitempty"`
	SHA256       string `json:"sha256"`
	Source       string `json:"source"`
}

type signedCatalog struct {
	CatalogID string       `json:"catalog_id"`
	ExpiresAt string       `json:"expires_at"`
	IssuedAt  string       `json:"issued_at"`
	Models    []modelEntry `json:"models"`
	Signature signature    `json:"signature"`
	Version   int          `json:"version"`
}

type canonicalBody struct {
	CatalogID string       `json:"catalog_id"`
	ExpiresAt string       `json:"expires_at"`
	IssuedAt  string       `json:"issued_at"`
	Models    []modelEntry `json:"models"`
	Version   int          `json:"version"`
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "keygen":
		runKeygen(os.Args[2:])
	case "sign":
		runSign(os.Args[2:])
	case "verify":
		runVerify(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
}

func runKeygen(args []string) {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	publicOut := fs.String("public-out", "catalog-signing-key.pub", "public key output path")
	privateOut := fs.String("private-out", "catalog-signing-key.priv", "private key output path")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "usage: go run scripts/sign-catalog.go keygen [-public-out PATH] [-private-out PATH]\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		exitf("%v", err)
	}
	if fs.NArg() != 0 {
		fs.Usage()
		os.Exit(2)
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		exitf("generate keypair: %v", err)
	}
	if err := os.WriteFile(*publicOut, []byte(base64.RawURLEncoding.EncodeToString(pub)+"\n"), 0o644); err != nil {
		exitf("write public key: %v", err)
	}
	if err := os.WriteFile(*privateOut, []byte(base64.RawURLEncoding.EncodeToString(priv)+"\n"), 0o600); err != nil {
		exitf("write private key: %v", err)
	}
	if err := os.Chmod(*privateOut, 0o600); err != nil {
		exitf("chmod private key: %v", err)
	}
	fmt.Fprintf(os.Stderr, "wrote %s and %s\n", *publicOut, *privateOut)
}

func runSign(args []string) {
	fs := flag.NewFlagSet("sign", flag.ExitOnError)
	privateKeyPath := fs.String("key", "catalog-signing-key.priv", "base64url-unpadded Ed25519 private key path")
	keyID := fs.String("key-id", "catalog-key-2026q2", "catalog signature key id")
	outPath := fs.String("out", "-", "signed catalog output path, or - for stdout")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "usage: go run scripts/sign-catalog.go sign [-key PATH] [-key-id ID] [-out PATH] UNSIGNED_CATALOG_JSON\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		exitf("%v", err)
	}
	if fs.NArg() != 1 {
		fs.Usage()
		os.Exit(2)
	}

	privateKey, err := readPrivateKey(*privateKeyPath)
	if err != nil {
		exitf("%v", err)
	}
	raw, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		exitf("read unsigned catalog: %v", err)
	}
	catalog, err := decodeCatalog(raw)
	if err != nil {
		exitf("%v", err)
	}
	if err := validateCatalogBody(catalog); err != nil {
		exitf("%v", err)
	}
	if strings.TrimSpace(*keyID) == "" {
		exitf("key-id must not be empty")
	}

	canonicalJSON, err := canonicalCatalogJSON(catalog)
	if err != nil {
		exitf("canonicalize catalog body: %v", err)
	}
	catalog.Signature = signature{
		Alg:   "Ed25519",
		KeyID: strings.TrimSpace(*keyID),
		Sig:   base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, canonicalJSON)),
	}

	signed, err := json.MarshalIndent(catalog, "", "  ")
	if err != nil {
		exitf("encode signed catalog: %v", err)
	}
	signed = append(signed, '\n')
	if *outPath == "-" {
		if _, err := os.Stdout.Write(signed); err != nil {
			exitf("write signed catalog: %v", err)
		}
		return
	}
	if err := os.WriteFile(*outPath, signed, 0o644); err != nil {
		exitf("write signed catalog: %v", err)
	}
}

func runVerify(args []string) {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	publicKeyPath := fs.String("public-key", "catalog-signing-key.pub", "base64url-unpadded Ed25519 public key path")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "usage: go run scripts/sign-catalog.go verify [-public-key PATH] SIGNED_CATALOG_JSON\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		exitf("%v", err)
	}
	if fs.NArg() != 1 {
		fs.Usage()
		os.Exit(2)
	}

	publicKey, err := readPublicKey(*publicKeyPath)
	if err != nil {
		exitf("%v", err)
	}
	raw, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		exitf("read signed catalog: %v", err)
	}
	catalog, err := decodeCatalog(raw)
	if err != nil {
		exitf("%v", err)
	}
	if err := validateCatalogBody(catalog); err != nil {
		exitf("%v", err)
	}
	signatureBytes, err := validateCatalogSignature(catalog.Signature)
	if err != nil {
		exitf("%v", err)
	}
	canonicalJSON, err := canonicalCatalogJSON(catalog)
	if err != nil {
		exitf("canonicalize catalog body: %v", err)
	}
	if !ed25519.Verify(publicKey, canonicalJSON, signatureBytes) {
		exitf("signature verification failed")
	}
	fmt.Printf("catalog verified: catalog_id=%s model_count=%d key_id=%s\n", catalog.CatalogID, len(catalog.Models), catalog.Signature.KeyID)
}

func decodeCatalog(raw []byte) (signedCatalog, error) {
	var catalog signedCatalog
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&catalog); err != nil {
		return signedCatalog{}, fmt.Errorf("parse catalog: %w", err)
	}
	var extra struct{}
	if err := decoder.Decode(&extra); err != io.EOF {
		return signedCatalog{}, fmt.Errorf("catalog must contain a single JSON object")
	}
	if len(catalog.Models) == 0 {
		return signedCatalog{}, fmt.Errorf("catalog models must not be empty")
	}
	if catalog.Version != 1 {
		return signedCatalog{}, fmt.Errorf("catalog version must be 1")
	}
	if strings.TrimSpace(catalog.CatalogID) == "" {
		return signedCatalog{}, fmt.Errorf("catalog_id must not be empty")
	}
	return catalog, nil
}

func validateCatalogBody(catalog signedCatalog) error {
	if strings.TrimSpace(catalog.IssuedAt) == "" {
		return fmt.Errorf("issued_at must not be empty")
	}
	issuedAt, err := time.Parse(time.RFC3339, catalog.IssuedAt)
	if err != nil {
		return fmt.Errorf("invalid issued_at: %w", err)
	}
	if strings.TrimSpace(catalog.ExpiresAt) == "" {
		return fmt.Errorf("expires_at must not be empty")
	}
	expiresAt, err := time.Parse(time.RFC3339, catalog.ExpiresAt)
	if err != nil {
		return fmt.Errorf("invalid expires_at: %w", err)
	}
	if !issuedAt.Before(expiresAt) {
		return fmt.Errorf("issued_at must be before expires_at")
	}
	if !time.Now().UTC().Before(expiresAt) {
		return fmt.Errorf("catalog expired")
	}

	models := make(map[string]struct{}, len(catalog.Models))
	for _, model := range catalog.Models {
		modelID := catalogModelKey(model.ModelID)
		if modelID == "" {
			return fmt.Errorf("catalog model_id must not be empty")
		}
		if _, exists := models[modelID]; exists {
			return fmt.Errorf("duplicate catalog model_id %q", model.ModelID)
		}
		models[modelID] = struct{}{}
		if model.ArtifactKind != "mlx_weight_file" {
			return fmt.Errorf("catalog artifact_kind for %q must be mlx_weight_file", model.ModelID)
		}
		switch model.HashScope {
		case "primary_weight_file", "artifact_manifest", "coordinator_endorsed_incremental":
		default:
			return fmt.Errorf("catalog hash_scope for %q is unsupported", model.ModelID)
		}
		if strings.TrimSpace(model.Source) == "" {
			return fmt.Errorf("catalog source for %q must not be empty", model.ModelID)
		}
		if model.MinRAMGB != nil && *model.MinRAMGB < 1 {
			return fmt.Errorf("catalog min_ram_gb for %q must be positive", model.ModelID)
		}
		if !hashPattern.MatchString(model.SHA256) {
			return fmt.Errorf("catalog sha256 for %q must be 64 lowercase hex chars", model.ModelID)
		}
	}
	return nil
}

func validateCatalogSignature(sig signature) ([]byte, error) {
	if sig.Alg != "Ed25519" {
		return nil, fmt.Errorf("signature alg must be Ed25519")
	}
	if strings.TrimSpace(sig.KeyID) == "" {
		return nil, fmt.Errorf("signature key_id must not be empty")
	}
	if strings.TrimSpace(sig.Sig) == "" {
		return nil, fmt.Errorf("signature sig must not be empty")
	}
	signatureBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(sig.Sig))
	if err != nil {
		return nil, fmt.Errorf("decode signature: %w", err)
	}
	if len(signatureBytes) != ed25519.SignatureSize {
		return nil, fmt.Errorf("invalid signature length %d", len(signatureBytes))
	}
	return signatureBytes, nil
}

func catalogModelKey(modelID string) string {
	return strings.ToLower(strings.TrimSpace(modelID))
}

func canonicalCatalogJSON(catalog signedCatalog) ([]byte, error) {
	canonical := canonicalBody{
		CatalogID: catalog.CatalogID,
		ExpiresAt: catalog.ExpiresAt,
		IssuedAt:  catalog.IssuedAt,
		Models:    catalog.Models,
		Version:   catalog.Version,
	}
	return json.Marshal(canonical)
}

func readPublicKey(path string) (ed25519.PublicKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read public key: %w", err)
	}
	keyBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil {
		return nil, fmt.Errorf("decode public key: %w", err)
	}
	if len(keyBytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid public key length %d", len(keyBytes))
	}
	return ed25519.PublicKey(keyBytes), nil
}

func readPrivateKey(path string) (ed25519.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read private key: %w", err)
	}
	keyBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil {
		return nil, fmt.Errorf("decode private key: %w", err)
	}
	switch len(keyBytes) {
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(keyBytes), nil
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(keyBytes), nil
	default:
		return nil, fmt.Errorf("invalid private key length %d", len(keyBytes))
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  go run scripts/sign-catalog.go keygen [-public-out PATH] [-private-out PATH]")
	fmt.Fprintln(os.Stderr, "  go run scripts/sign-catalog.go sign [-key PATH] [-key-id ID] [-out PATH] UNSIGNED_CATALOG_JSON")
	fmt.Fprintln(os.Stderr, "  go run scripts/sign-catalog.go verify [-public-key PATH] SIGNED_CATALOG_JSON")
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "sign-catalog: "+format+"\n", args...)
	os.Exit(1)
}
