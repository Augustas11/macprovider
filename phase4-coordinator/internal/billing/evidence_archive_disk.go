package billing

import (
	"errors"

	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

// evidenceArchiveSpaceCheckBytes is how much compressed archive output
// reaches the file between free-space re-reads (the archive writer checks
// before every step, including while it flushes).
// Tests lower it and replace archiveFilesystemSpaceFunc.
var evidenceArchiveSpaceCheckBytes int64 = 4 << 20

var archiveFilesystemSpaceFunc = verifiedarchive.FilesystemSpace

// errEvidenceArchiveDiskLow stops an export that reached the free-space floor.
var errEvidenceArchiveDiskLow = errors.New("archive filesystem below its free-space floor")

// archiveDiskBelowFloor returns why free space is under the configured floor,
// or "" when a new archive may be written.
func archiveDiskBelowFloor(free, total int64, opts EvidenceRetentionOptions) string {
	return verifiedarchive.BelowFloor(free, total, opts.ArchiveMinFreeBytes, opts.ArchiveMinFreePercent)
}
