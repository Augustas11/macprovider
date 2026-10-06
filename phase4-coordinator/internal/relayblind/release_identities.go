package relayblind

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// SPEC-049-R027 release-derived approval. The bounds and field rules mirror
// SPEC-025 §6.2.1 and scripts/provider-code-identity.py.
const (
	maxReleaseIdentityFiles     = 256
	maxReleaseIdentityFileBytes = 1 << 20
	releaseSigningIdentifier    = "live.malibu.provider.cli"
)

var (
	releaseIdentityAsset   = regexp.MustCompile(`^macprovider-cli-v[0-9]+\.[0-9]+\.[0-9]+-darwin-arm64\.tar\.gz$`)
	releaseIdentityVersion = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	releaseIdentityHex40   = regexp.MustCompile(`^[0-9a-f]{40}$`)
	releaseIdentityHex64   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	releaseIdentityTeam    = regexp.MustCompile(`^[A-Z0-9]{10}$`)
)

// ParseReleaseSigningPublicKey parses the PEM SubjectPublicKeyInfo P-256 key
// that signs pearl-release.json.
func ParseReleaseSigningPublicKey(raw []byte) (*ecdsa.PublicKey, error) {
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "PUBLIC KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("relayblind: release signing key must be one PEM PUBLIC KEY block")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("relayblind: release signing key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("relayblind: release signing key must be P-256")
	}
	return key, nil
}

// LoadReleaseCodeIdentities reads every <name>.json with a sibling
// <name>.json.sig in dir, verifies the DER ECDSA-P256-SHA256 signature over
// the exact file bytes, and returns one approved identity per verified
// provider_code_identity. Rejected files are returned by name only.
func LoadReleaseCodeIdentities(dir string, key *ecdsa.PublicKey) ([]config.ApprovedCodeIdentity, []string, error) {
	if key == nil {
		return nil, nil, errors.New("relayblind: release signing key is required")
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, nil, fmt.Errorf("relayblind: release identity directory %q is unavailable", dir)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, fmt.Errorf("relayblind: read release identity directory: %w", err)
	}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasSuffix(name, ".json") && !strings.HasPrefix(name, ".") {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	if len(names) > maxReleaseIdentityFiles {
		return nil, nil, fmt.Errorf("relayblind: release identity directory holds more than %d metadata files", maxReleaseIdentityFiles)
	}
	var identities []config.ApprovedCodeIdentity
	var rejected []string
	seen := make(map[config.ApprovedCodeIdentity]struct{})
	for _, name := range names {
		identity, err := loadReleaseCodeIdentity(filepath.Join(dir, name), key)
		if err != nil {
			rejected = append(rejected, name)
			continue
		}
		if _, dup := seen[identity]; dup {
			continue
		}
		seen[identity] = struct{}{}
		identities = append(identities, identity)
	}
	return identities, rejected, nil
}

func readReleaseIdentityFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxReleaseIdentityFileBytes {
		return nil, errors.New("not a bounded regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, errors.New("file changed")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxReleaseIdentityFileBytes+1))
	if err != nil || len(raw) > maxReleaseIdentityFileBytes {
		return nil, errors.New("file too large")
	}
	return raw, nil
}

func loadReleaseCodeIdentity(path string, key *ecdsa.PublicKey) (config.ApprovedCodeIdentity, error) {
	payload, err := readReleaseIdentityFile(path)
	if err != nil {
		return config.ApprovedCodeIdentity{}, err
	}
	signature, err := readReleaseIdentityFile(path + ".sig")
	if err != nil {
		return config.ApprovedCodeIdentity{}, err
	}
	digest := sha256.Sum256(payload)
	if !ecdsa.VerifyASN1(key, digest[:], signature) {
		return config.ApprovedCodeIdentity{}, errors.New("signature")
	}
	return parseReleaseCodeIdentity(payload)
}

// parseReleaseCodeIdentity extracts SPEC-025 §6.2.1 provider_code_identity
// from verified pearl-release.json bytes. Other metadata fields are ignored.
func parseReleaseCodeIdentity(payload []byte) (config.ApprovedCodeIdentity, error) {
	if err := rejectDuplicateJSONKeys(payload); err != nil {
		return config.ApprovedCodeIdentity{}, err
	}
	var metadata map[string]json.RawMessage
	if err := json.Unmarshal(payload, &metadata); err != nil {
		return config.ApprovedCodeIdentity{}, err
	}
	raw, ok := metadata["provider_code_identity"]
	if !ok {
		return config.ApprovedCodeIdentity{}, errors.New("no provider_code_identity")
	}
	var identity struct {
		Asset             string            `json:"asset"`
		Member            string            `json:"member"`
		BinaryVersion     string            `json:"binary_version"`
		BinarySHA256      string            `json:"binary_sha256"`
		TeamID            string            `json:"team_id"`
		SigningIdentifier string            `json:"signing_identifier"`
		Slices            []json.RawMessage `json:"slices"`
	}
	if err := decodeClosed(raw, &identity, []string{"asset", "member", "binary_version", "binary_sha256", "team_id", "signing_identifier", "slices"}); err != nil {
		return config.ApprovedCodeIdentity{}, err
	}
	if !releaseIdentityAsset.MatchString(identity.Asset) || identity.Member != "macprovider-cli" ||
		!releaseIdentityVersion.MatchString(identity.BinaryVersion) || identity.Asset != "macprovider-cli-v"+identity.BinaryVersion+"-darwin-arm64.tar.gz" ||
		!releaseIdentityHex64.MatchString(identity.BinarySHA256) || !releaseIdentityTeam.MatchString(identity.TeamID) ||
		identity.SigningIdentifier != releaseSigningIdentifier || len(identity.Slices) != 1 {
		return config.ApprovedCodeIdentity{}, errors.New("provider_code_identity fields")
	}
	var slice struct {
		Arch       string `json:"arch"`
		CodeCDHash string `json:"code_cdhash"`
	}
	if err := decodeClosed(identity.Slices[0], &slice, []string{"arch", "code_cdhash"}); err != nil {
		return config.ApprovedCodeIdentity{}, err
	}
	if slice.Arch != "arm64" || !releaseIdentityHex40.MatchString(slice.CodeCDHash) {
		return config.ApprovedCodeIdentity{}, errors.New("provider_code_identity slice")
	}
	return config.ApprovedCodeIdentity{
		TeamID:            identity.TeamID,
		SigningIdentifier: identity.SigningIdentifier,
		CDHash:            slice.CodeCDHash,
		BinaryVersion:     identity.BinaryVersion,
	}, nil
}
