package main

import (
	"bytes"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

const mdaFormat = "apple-managed-device-attestation-acme-v1"

type stringList []string

func (l *stringList) String() string {
	return strings.Join(*l, ",")
}

func (l *stringList) Set(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("empty value")
	}
	*l = append(*l, value)
	return nil
}

type mdaArtifact struct {
	Format                    string   `json:"format,omitempty"`
	Token                     string   `json:"token,omitempty"`
	CertificateChain          []string `json:"certificate_chain,omitempty"`
	X5C                       []string `json:"x5c,omitempty"`
	CertificateSigningRequest string   `json:"certificate_signing_request,omitempty"`
	CSR                       string   `json:"csr,omitempty"`
}

type attestationEnvelope struct {
	Format                    string            `json:"format"`
	Token                     string            `json:"token"`
	Challenge                 string            `json:"challenge"`
	IssuedAt                  time.Time         `json:"issued_at"`
	ExpiresAt                 time.Time         `json:"expires_at"`
	ProviderID                string            `json:"provider_id"`
	BinaryVersion             string            `json:"binary_version"`
	Claimed                   map[string]any    `json:"claimed"`
	KeyBinding                map[string]string `json:"key_binding"`
	CertificateChain          []string          `json:"certificate_chain,omitempty"`
	CertificateSigningRequest string            `json:"certificate_signing_request,omitempty"`
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "tier2-mda-artifact: ERROR: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		printUsage(stderr)
		return fmt.Errorf("missing subcommand")
	}
	switch args[0] {
	case "make":
		return runMake(args[1:], stdout)
	case "check":
		return runCheck(args[1:], stdout)
	case "-h", "--help", "help":
		printUsage(stdout)
		return nil
	default:
		printUsage(stderr)
		return fmt.Errorf("unknown subcommand %q", args[0])
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, `usage:
  tier2-mda-artifact make --cert leaf.pem [--cert intermediate.pem] --csr request.csr --out mda.json [--token TOKEN] [--force]
  tier2-mda-artifact check --artifact mda.json [--root root.pem --challenge BASE64URL --provider-id ID --provider-ecdh-public-key KEY]

The make subcommand packages operator-provided Apple MDA certificate-chain and
CSR evidence into the JSON contract consumed by MACPROVIDER_TIER2_MDA_ARTIFACT_PATH.
The check subcommand always validates that provider artifact contract, and when
root/challenge/provider flags are supplied it also runs the coordinator's
Pillar-C verifier and requires an attested result.`)
}

func runMake(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("make", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var certFiles stringList
	fs.Var(&certFiles, "cert", "leaf/intermediate certificate file; repeat in leaf-first order")
	csrPath := fs.String("csr", "", "certificate signing request file")
	outPath := fs.String("out", "", "output artifact JSON path")
	format := fs.String("format", mdaFormat, "attestation artifact format")
	token := fs.String("token", "", "optional base64url-unpadded token value")
	tokenFile := fs.String("token-file", "", "optional file containing a base64url-unpadded token value")
	force := fs.Bool("force", false, "overwrite output path")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			printUsage(stdout)
			return nil
		}
		return err
	}
	if len(certFiles) == 0 {
		return fmt.Errorf("make requires at least one --cert")
	}
	if strings.TrimSpace(*csrPath) == "" {
		return fmt.Errorf("make requires --csr")
	}
	if strings.TrimSpace(*outPath) == "" {
		return fmt.Errorf("make requires --out")
	}
	if strings.TrimSpace(*format) != mdaFormat {
		return fmt.Errorf("unsupported format %q", *format)
	}
	tokenValue, err := readTokenValue(*token, *tokenFile)
	if err != nil {
		return err
	}
	if tokenValue != "" {
		if _, err := base64.RawURLEncoding.DecodeString(tokenValue); err != nil {
			return fmt.Errorf("token must be base64url-unpadded: %w", err)
		}
	}

	var chain []string
	for _, certPath := range certFiles {
		entries, err := readCertificateEvidenceFile(certPath)
		if err != nil {
			return err
		}
		chain = append(chain, entries...)
	}
	csr, err := readCSREvidenceFile(*csrPath)
	if err != nil {
		return err
	}
	artifact := mdaArtifact{
		Format:                    mdaFormat,
		Token:                     tokenValue,
		CertificateChain:          chain,
		CertificateSigningRequest: csr,
	}
	body, err := json.MarshalIndent(artifact, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')
	if !*force {
		if _, err := os.Stat(*outPath); err == nil {
			return fmt.Errorf("output already exists: %s", *outPath)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Dir(*outPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(*outPath, body, 0o600); err != nil {
		return err
	}
	return writeJSON(stdout, map[string]any{
		"artifact":                 *outPath,
		"format":                   mdaFormat,
		"certificate_chain_count":  len(chain),
		"has_token":                tokenValue != "",
		"has_certificate_csr":      true,
		"provider_artifact_format": "MACPROVIDER_TIER2_MDA_ARTIFACT_PATH",
	})
}

func runCheck(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var rootFiles stringList
	artifactPath := fs.String("artifact", "", "MDA artifact JSON path")
	fs.Var(&rootFiles, "root", "trusted root certificate file; repeat when needed")
	challenge := fs.String("challenge", "", "base64url-unpadded coordinator challenge")
	providerID := fs.String("provider-id", "provider-a", "provider id used for full verification")
	providerECDH := fs.String("provider-ecdh-public-key", "", "base64url provider ECDH public key used for full verification")
	binaryVersion := fs.String("binary-version", "1.2.6", "provider binary version claim")
	modelID := fs.String("model-id", "", "optional model id claim")
	modelHash := fs.String("model-hash", "", "optional lowercase SHA-256 model hash claim")
	ramGB := fs.Int("ram-gb", 16, "RAM GB claim")
	nowText := fs.String("now", "", "RFC3339 verification time; defaults to current UTC")
	maxAge := fs.Int("max-age-seconds", 600, "attestation max age seconds")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			printUsage(stdout)
			return nil
		}
		return err
	}
	if strings.TrimSpace(*artifactPath) == "" {
		return fmt.Errorf("check requires --artifact")
	}
	if *maxAge <= 0 {
		return fmt.Errorf("--max-age-seconds must be > 0")
	}
	if *ramGB <= 0 {
		return fmt.Errorf("--ram-gb must be > 0")
	}
	now := time.Now().UTC()
	if strings.TrimSpace(*nowText) != "" {
		parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(*nowText))
		if err != nil {
			return fmt.Errorf("parse --now: %w", err)
		}
		now = parsed.UTC()
	}
	artifact, err := loadArtifact(*artifactPath)
	if err != nil {
		return err
	}
	chain, err := validateArtifactCertificateChain(artifact)
	if err != nil {
		return err
	}
	csr, err := validateArtifactCSR(artifact)
	if err != nil {
		return err
	}
	if csr != nil {
		if err := csr.CheckSignature(); err != nil {
			return fmt.Errorf("certificate_signing_request signature invalid: %w", err)
		}
	}
	token := strings.TrimSpace(artifact.Token)
	if token != "" {
		if _, err := base64.RawURLEncoding.DecodeString(token); err != nil {
			return fmt.Errorf("artifact token must be base64url-unpadded: %w", err)
		}
	}

	summary := map[string]any{
		"artifact":                *artifactPath,
		"contract_valid":          true,
		"format":                  artifactFormat(artifact),
		"certificate_chain_count": len(chain),
		"has_token":               token != "",
		"has_certificate_csr":     csr != nil,
		"coordinator_verified":    false,
	}

	if len(rootFiles) > 0 || strings.TrimSpace(*challenge) != "" || strings.TrimSpace(*providerECDH) != "" {
		if len(rootFiles) == 0 {
			return fmt.Errorf("full verification requires at least one --root")
		}
		if strings.TrimSpace(*challenge) == "" {
			return fmt.Errorf("full verification requires --challenge")
		}
		if strings.TrimSpace(*providerECDH) == "" {
			return fmt.Errorf("full verification requires --provider-ecdh-public-key")
		}
		status, err := verifyWithCoordinator(artifact, rootFiles, *challenge, *providerID, *providerECDH, *binaryVersion, *modelID, *modelHash, *ramGB, *maxAge, now)
		if err != nil {
			return err
		}
		summary["coordinator_verified"] = true
		summary["attestation_status"] = string(status)
		if status != pool.AttestationStatusAttested {
			return fmt.Errorf("coordinator verifier returned %q, want %q", status, pool.AttestationStatusAttested)
		}
	}
	return writeJSON(stdout, summary)
}

func readTokenValue(token, tokenFile string) (string, error) {
	token = strings.TrimSpace(token)
	tokenFile = strings.TrimSpace(tokenFile)
	if token != "" && tokenFile != "" {
		return "", fmt.Errorf("--token and --token-file are mutually exclusive")
	}
	if tokenFile == "" {
		return token, nil
	}
	body, err := os.ReadFile(tokenFile)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(body)), nil
}

func loadArtifact(path string) (mdaArtifact, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return mdaArtifact{}, err
	}
	var artifact mdaArtifact
	if err := json.Unmarshal(body, &artifact); err != nil {
		return mdaArtifact{}, fmt.Errorf("parse artifact JSON: %w", err)
	}
	if artifactFormat(artifact) != mdaFormat {
		return mdaArtifact{}, fmt.Errorf("unsupported artifact format %q", artifactFormat(artifact))
	}
	return artifact, nil
}

func artifactFormat(artifact mdaArtifact) string {
	format := strings.TrimSpace(artifact.Format)
	if format == "" {
		return mdaFormat
	}
	return format
}

func readCertificateEvidenceFile(path string) ([]string, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if blocks := pemCertificateBlocks(body); len(blocks) > 0 {
		entries := make([]string, 0, len(blocks))
		for _, block := range blocks {
			if _, err := x509.ParseCertificate(block.Bytes); err != nil {
				return nil, fmt.Errorf("parse certificate %s: %w", path, err)
			}
			entries = append(entries, strings.TrimSpace(string(pem.EncodeToMemory(block))))
		}
		return entries, nil
	}
	cert, raw, err := parseCertificateBytes(body)
	if err != nil {
		return nil, fmt.Errorf("parse certificate %s: %w", path, err)
	}
	if cert == nil {
		return nil, fmt.Errorf("parse certificate %s: empty certificate", path)
	}
	return []string{base64.StdEncoding.EncodeToString(raw)}, nil
}

func readCSREvidenceFile(path string) (string, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if block, _ := pem.Decode(bytes.TrimSpace(body)); block != nil {
		if block.Type != "CERTIFICATE REQUEST" && block.Type != "NEW CERTIFICATE REQUEST" {
			return "", fmt.Errorf("unexpected CSR PEM block type %q", block.Type)
		}
		csr, err := x509.ParseCertificateRequest(block.Bytes)
		if err != nil {
			return "", fmt.Errorf("parse CSR %s: %w", path, err)
		}
		if err := csr.CheckSignature(); err != nil {
			return "", fmt.Errorf("CSR signature invalid %s: %w", path, err)
		}
		return strings.TrimSpace(string(pem.EncodeToMemory(block))), nil
	}
	csr, raw, err := parseCSRBytes(body)
	if err != nil {
		return "", fmt.Errorf("parse CSR %s: %w", path, err)
	}
	if err := csr.CheckSignature(); err != nil {
		return "", fmt.Errorf("CSR signature invalid %s: %w", path, err)
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

func pemCertificateBlocks(body []byte) []*pem.Block {
	var blocks []*pem.Block
	remaining := bytes.TrimSpace(body)
	for {
		block, rest := pem.Decode(remaining)
		if block == nil {
			break
		}
		if block.Type == "CERTIFICATE" {
			blocks = append(blocks, block)
		}
		remaining = rest
	}
	return blocks
}

func parseCertificateBytes(body []byte) (*x509.Certificate, []byte, error) {
	if cert, err := x509.ParseCertificate(bytes.TrimSpace(body)); err == nil {
		return cert, bytes.TrimSpace(body), nil
	}
	rawText := strings.TrimSpace(string(body))
	for _, enc := range base64Encodings() {
		decoded, err := enc.DecodeString(rawText)
		if err == nil {
			cert, certErr := x509.ParseCertificate(decoded)
			if certErr == nil {
				return cert, decoded, nil
			}
		}
	}
	return nil, nil, fmt.Errorf("not PEM, DER, or base64 DER certificate")
}

func parseCSRBytes(body []byte) (*x509.CertificateRequest, []byte, error) {
	if csr, err := x509.ParseCertificateRequest(bytes.TrimSpace(body)); err == nil {
		return csr, bytes.TrimSpace(body), nil
	}
	rawText := strings.TrimSpace(string(body))
	for _, enc := range base64Encodings() {
		decoded, err := enc.DecodeString(rawText)
		if err == nil {
			csr, csrErr := x509.ParseCertificateRequest(decoded)
			if csrErr == nil {
				return csr, decoded, nil
			}
		}
	}
	return nil, nil, fmt.Errorf("not PEM, DER, or base64 DER CSR")
}

func base64Encodings() []*base64.Encoding {
	return []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
}

func validateArtifactCertificateChain(artifact mdaArtifact) ([]*x509.Certificate, error) {
	values := append([]string{}, artifact.CertificateChain...)
	values = append(values, artifact.X5C...)
	if len(values) == 0 {
		return nil, fmt.Errorf("artifact is missing certificate_chain/x5c")
	}
	certs := make([]*x509.Certificate, 0, len(values))
	for i, value := range values {
		cert, err := parseEncodedCertificate(value)
		if err != nil {
			return nil, fmt.Errorf("certificate_chain[%d]: %w", i, err)
		}
		certs = append(certs, cert)
	}
	return certs, nil
}

func validateArtifactCSR(artifact mdaArtifact) (*x509.CertificateRequest, error) {
	value := strings.TrimSpace(artifact.CertificateSigningRequest)
	if value == "" {
		value = strings.TrimSpace(artifact.CSR)
	}
	if value == "" {
		return nil, fmt.Errorf("artifact is missing certificate_signing_request/csr")
	}
	csr, err := parseEncodedCSR(value)
	if err != nil {
		return nil, err
	}
	return csr, nil
}

func parseEncodedCertificate(value string) (*x509.Certificate, error) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return nil, fmt.Errorf("empty certificate")
	}
	if block, _ := pem.Decode([]byte(raw)); block != nil {
		if block.Type != "CERTIFICATE" {
			return nil, fmt.Errorf("unexpected PEM block type %q", block.Type)
		}
		return x509.ParseCertificate(block.Bytes)
	}
	for _, enc := range base64Encodings() {
		decoded, err := enc.DecodeString(raw)
		if err == nil {
			return x509.ParseCertificate(decoded)
		}
	}
	return nil, fmt.Errorf("certificate is not PEM or base64 DER")
}

func parseEncodedCSR(value string) (*x509.CertificateRequest, error) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return nil, fmt.Errorf("empty csr")
	}
	if block, _ := pem.Decode([]byte(raw)); block != nil {
		if block.Type != "CERTIFICATE REQUEST" && block.Type != "NEW CERTIFICATE REQUEST" {
			return nil, fmt.Errorf("unexpected PEM block type %q", block.Type)
		}
		return x509.ParseCertificateRequest(block.Bytes)
	}
	for _, enc := range base64Encodings() {
		decoded, err := enc.DecodeString(raw)
		if err == nil {
			return x509.ParseCertificateRequest(decoded)
		}
	}
	return nil, fmt.Errorf("csr is not PEM or base64 DER")
}

func verifyWithCoordinator(artifact mdaArtifact, rootFiles []string, challenge, providerID, providerECDH, binaryVersion, modelID, modelHash string, ramGB, maxAge int, now time.Time) (pool.AttestationStatus, error) {
	challenge = strings.TrimSpace(challenge)
	challengeBytes, err := base64.RawURLEncoding.DecodeString(challenge)
	if err != nil {
		return "", fmt.Errorf("challenge must be base64url-unpadded: %w", err)
	}
	if len(challengeBytes) != 32 {
		return "", fmt.Errorf("challenge must decode to 32 bytes, got %d", len(challengeBytes))
	}
	providerECDHBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(providerECDH))
	if err != nil {
		return "", fmt.Errorf("provider ECDH public key must be base64url-unpadded: %w", err)
	}
	if len(providerECDHBytes) != 32 {
		return "", fmt.Errorf("provider ECDH public key must decode to 32 bytes, got %d", len(providerECDHBytes))
	}
	rootValues, err := readRootValues(rootFiles)
	if err != nil {
		return "", err
	}
	cfg := config.Default().Tier2
	cfg.RequireAttestation = true
	cfg.AttestationRoots = rootValues
	cfg.AttestationMaxAgeS = maxAge
	issuedAt := now.Add(-1 * time.Second)
	tokenValue := strings.TrimSpace(artifact.Token)
	if tokenValue == "" {
		tokenValue = challenge
	}
	claimed := map[string]any{
		"hardware_family": "apple_silicon",
		"ram_gb":          ramGB,
		"model_id":        modelID,
	}
	if strings.TrimSpace(modelHash) != "" {
		claimed["model_hash"] = strings.TrimSpace(modelHash)
	}
	envelope := attestationEnvelope{
		Format:        mdaFormat,
		Token:         tokenValue,
		Challenge:     challenge,
		IssuedAt:      issuedAt,
		ExpiresAt:     issuedAt.Add(time.Duration(maxAge) * time.Second),
		ProviderID:    providerID,
		BinaryVersion: binaryVersion,
		Claimed:       claimed,
		KeyBinding: map[string]string{
			"provider_ecdh_public_key": strings.TrimSpace(providerECDH),
		},
		CertificateChain:          artifact.CertificateChain,
		CertificateSigningRequest: artifact.CertificateSigningRequest,
	}
	if len(envelope.CertificateChain) == 0 {
		envelope.CertificateChain = artifact.X5C
	}
	if strings.TrimSpace(envelope.CertificateSigningRequest) == "" {
		envelope.CertificateSigningRequest = artifact.CSR
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		return "", err
	}
	status := tier2.VerifyAttestationToken(raw, cfg, challengeBytes, providerID, strings.TrimSpace(providerECDH), now, zerolog.Nop())
	return status, nil
}

func readRootValues(paths []string) ([]string, error) {
	values := make([]string, 0, len(paths))
	for _, path := range paths {
		body, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		if blocks := pemCertificateBlocks(body); len(blocks) > 0 {
			for _, block := range blocks {
				if _, err := x509.ParseCertificate(block.Bytes); err != nil {
					return nil, fmt.Errorf("parse root certificate %s: %w", path, err)
				}
				values = append(values, strings.TrimSpace(string(pem.EncodeToMemory(block))))
			}
			continue
		}
		cert, raw, err := parseCertificateBytes(body)
		if err != nil {
			return nil, fmt.Errorf("parse root certificate %s: %w", path, err)
		}
		if cert == nil {
			return nil, fmt.Errorf("parse root certificate %s: empty certificate", path)
		}
		values = append(values, base64.StdEncoding.EncodeToString(raw))
	}
	return values, nil
}

func writeJSON(w io.Writer, value any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}
