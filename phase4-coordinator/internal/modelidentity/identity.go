package modelidentity

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

const (
	SnapshotManifestV1    = "macprovider.snapshot-manifest.v1"
	SafetensorsManifestV1 = "macprovider.safetensors-manifest.v1"
	// GGUFFileV1 is the SPEC-010 v1.7 R002/R007(a) canonical wire pair for a
	// GGUF artifact: the lowercase SHA-256 of the complete GGUF file bytes,
	// computed by the CLI over the bytes it holds — never a digest a runtime
	// reports about itself.
	GGUFFileV1 = "macprovider.gguf-file.v1"
)

// CanonicalAlgorithm reports whether `algorithm` is a SPEC-010-R002 canonical
// model-identity wire pair. An unknown algorithm is rejected, never guessed.
func CanonicalAlgorithm(algorithm string) bool {
	switch algorithm {
	case SnapshotManifestV1, GGUFFileV1:
		return true
	}
	return false
}

var sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func ValidSHA256(value string) bool {
	return sha256Pattern.MatchString(value)
}

func LegacyMissingAlgorithmAllowed(until string, now time.Time) bool {
	deadline, err := ParseLegacyDeadline(until)
	return err == nil && !deadline.IsZero() && now.Before(deadline)
}

func ParseLegacyDeadline(raw string) (time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}, nil
	}
	deadline, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("must be RFC3339: %w", err)
	}
	return deadline.UTC(), nil
}
