package verifiedarchive

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// FilesystemSpace creates the archive directory if needed and returns the
// free bytes available to the coordinator and the total size of its
// filesystem.
func FilesystemSpace(dir string) (free, total int64, err error) {
	if strings.TrimSpace(dir) == "" || !filepath.IsAbs(dir) {
		return 0, 0, fmt.Errorf("archive directory must be an absolute path")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return 0, 0, fmt.Errorf("create archive dir: %w", err)
	}
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, 0, fmt.Errorf("statfs archive dir: %w", err)
	}
	bsize := uint64(st.Bsize) //nolint:gosec,unconvert // int64 on linux, uint32 on darwin; never negative
	return clampInt64(uint64(st.Bavail) * bsize), clampInt64(uint64(st.Blocks) * bsize), nil
}

func clampInt64(v uint64) int64 {
	if v > 1<<62 {
		return 1 << 62
	}
	return int64(v)
}

// BelowFloor returns why free space is under the floor (minFreeBytes, or
// minFreePercent of the filesystem; zero disables a bound), or "" when a new
// archive may be written.
func BelowFloor(free, total, minFreeBytes int64, minFreePercent int) string {
	if minFreeBytes > 0 && free < minFreeBytes {
		return fmt.Sprintf("archive filesystem has %d bytes free, below archive_min_free_bytes %d", free, minFreeBytes)
	}
	if minFreePercent > 0 && total > 0 && free < total/100*int64(minFreePercent) {
		return fmt.Sprintf("archive filesystem has %d of %d bytes free, below archive_min_free_percent %d", free, total, minFreePercent)
	}
	return ""
}
