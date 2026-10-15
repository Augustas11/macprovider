package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"

	"github.com/augstar/macprovider-coordinator/internal/audit"
)

// auditLogArchive verifies a SPEC-002 R-7.10.2 closed period audit archive.
// It reads only the archive file and its manifest; it never opens a database.
//
//	coordinator-cli audit-log-archive verify --archive <file>
func auditLogArchive(args []string, stdout io.Writer) error {
	if len(args) < 1 || args[0] != "verify" {
		return fmt.Errorf("usage: audit-log-archive verify --archive <file>")
	}
	fs := flag.NewFlagSet("audit-log-archive verify", flag.ContinueOnError)
	archive := fs.String("archive", "", "path to an audit-log-*.jsonl.gz archive (manifest beside it)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *archive == "" {
		return fmt.Errorf("--archive is required")
	}
	manifest, err := audit.VerifyArchiveFile(*archive)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(manifest)
}
