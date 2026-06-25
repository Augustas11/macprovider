package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type manifestFile struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type artifactManifest struct {
	Files []manifestFile `json:"files"`
}

type catalogEntry struct {
	ArtifactKind string `json:"artifact_kind"`
	HashScope    string `json:"hash_scope"`
	MinRAMGB     int    `json:"min_ram_gb,omitempty"`
	ModelID      string `json:"model_id"`
	SHA256       string `json:"sha256"`
	Source       string `json:"source"`
}

func main() {
	modelID := flag.String("model-id", "", "model id for the catalog entry, e.g. mlx-community/Qwen2.5-7B-Instruct-4bit")
	minRAMGB := flag.Int("min-ram-gb", 0, "override minimum RAM GB for the catalog entry; default derives from safetensors bytes")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "usage: go run scripts/hash-model-weights.go [-model-id MODEL] [-min-ram-gb N] SNAPSHOT_DIR\n")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}

	snapshotDir := flag.Arg(0)
	resolvedModelID := strings.TrimSpace(*modelID)
	if resolvedModelID == "" {
		resolvedModelID = deriveModelID(snapshotDir)
	}
	if resolvedModelID == "" {
		exitf("model id not provided and could not be derived from %q", snapshotDir)
	}
	if *minRAMGB < 0 {
		exitf("-min-ram-gb must be non-negative")
	}

	hash, totalBytes, err := artifactManifestHash(snapshotDir)
	if err != nil {
		exitf("%v", err)
	}
	resolvedMinRAMGB := *minRAMGB
	if resolvedMinRAMGB == 0 {
		resolvedMinRAMGB = ramFloorForArtifactBytes(totalBytes)
	}

	entry := catalogEntry{
		ArtifactKind: "mlx_weight_file",
		HashScope:    "artifact_manifest",
		MinRAMGB:     resolvedMinRAMGB,
		ModelID:      resolvedModelID,
		SHA256:       hash,
		Source:       "operator-curated",
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(entry); err != nil {
		exitf("encode catalog entry: %v", err)
	}
}

func artifactManifestHash(snapshotDir string) (string, int64, error) {
	entries, err := os.ReadDir(snapshotDir)
	if err != nil {
		return "", 0, fmt.Errorf("read snapshot directory: %w", err)
	}

	files := make([]manifestFile, 0)
	var totalBytes int64
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".safetensors" {
			continue
		}
		path := filepath.Join(snapshotDir, entry.Name())
		info, err := os.Stat(path)
		if err != nil {
			return "", 0, fmt.Errorf("stat %s: %w", path, err)
		}
		hash, err := fileSHA256(path)
		if err != nil {
			return "", 0, err
		}
		files = append(files, manifestFile{
			Name:   entry.Name(),
			SHA256: hash,
			Size:   info.Size(),
		})
		totalBytes += info.Size()
	}
	sort.Slice(files, func(i, j int) bool {
		return files[i].Name < files[j].Name
	})
	if len(files) == 0 {
		return "", 0, fmt.Errorf("no .safetensors files found in %s", snapshotDir)
	}

	canonical, err := json.Marshal(artifactManifest{Files: files})
	if err != nil {
		return "", 0, fmt.Errorf("encode artifact manifest: %w", err)
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), totalBytes, nil
}

func ramFloorForArtifactBytes(totalBytes int64) int {
	const gib = int64(1024 * 1024 * 1024)
	weightGB := int((totalBytes + gib - 1) / gib)
	switch {
	case weightGB <= 2:
		return 8
	case weightGB <= 3:
		return 12
	case weightGB <= 5:
		return 16
	case weightGB <= 9:
		return 24
	case weightGB <= 20:
		return 32
	case weightGB <= 38:
		return 48
	default:
		return 64
	}
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func deriveModelID(snapshotDir string) string {
	parts := strings.Split(filepath.ToSlash(filepath.Clean(snapshotDir)), "/")
	for _, part := range parts {
		if !strings.HasPrefix(part, "models--") {
			continue
		}
		repo := strings.TrimPrefix(part, "models--")
		repoParts := strings.SplitN(repo, "--", 2)
		if len(repoParts) == 2 && repoParts[0] != "" && repoParts[1] != "" {
			return repoParts[0] + "/" + repoParts[1]
		}
	}
	return ""
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "hash-model-weights: "+format+"\n", args...)
	os.Exit(1)
}
