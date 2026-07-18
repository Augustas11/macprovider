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
)

var sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func ValidSHA256(value string) bool {
	return sha256Pattern.MatchString(strings.TrimSpace(value))
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
