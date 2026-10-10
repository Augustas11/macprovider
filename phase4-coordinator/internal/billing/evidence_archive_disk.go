package billing

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// evidenceArchiveSpaceCheckBytes is how much compressed archive output an
// export writes between free-space re-reads. The writer buffers at most a
// few MiB more before it reaches the file, far below any useful floor.
// Tests lower it and replace archiveFilesystemSpaceFunc.
var evidenceArchiveSpaceCheckBytes int64 = 4 << 20

var archiveFilesystemSpaceFunc = archiveFilesystemSpace

// errEvidenceArchiveDiskLow stops an export that reached the free-space floor.
var errEvidenceArchiveDiskLow = errors.New("archive filesystem below its free-space floor")

// archiveFilesystemSpace creates the archive directory if needed and returns
// the free bytes available to the coordinator and the total size of its
// filesystem.
func archiveFilesystemSpace(dir string) (free, total int64, err error) {
	if strings.TrimSpace(dir) == "" || !filepath.IsAbs(dir) {
		return 0, 0, fmt.Errorf("settlement evidence archive_dir must be an absolute path")
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

// archiveDiskBelowFloor returns why free space is under the configured floor,
// or "" when a new archive may be written.
func archiveDiskBelowFloor(free, total int64, opts EvidenceRetentionOptions) string {
	if opts.ArchiveMinFreeBytes > 0 && free < opts.ArchiveMinFreeBytes {
		return fmt.Sprintf("archive filesystem has %d bytes free, below archive_min_free_bytes %d", free, opts.ArchiveMinFreeBytes)
	}
	if opts.ArchiveMinFreePercent > 0 && total > 0 && free < total/100*int64(opts.ArchiveMinFreePercent) {
		return fmt.Sprintf("archive filesystem has %d of %d bytes free, below archive_min_free_percent %d", free, total, opts.ArchiveMinFreePercent)
	}
	return ""
}
