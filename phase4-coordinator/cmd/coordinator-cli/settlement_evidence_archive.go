package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// settlementEvidenceArchive is the SPEC-022 R-15.7 operator tool. It reads
// only the archive file and its manifest; it never opens a database.
//
//	coordinator-cli settlement-evidence-archive verify   --archive <file>
//	coordinator-cli settlement-evidence-archive rederive --archive <file> --credit-id <id>
func settlementEvidenceArchive(args []string, stdout io.Writer) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: settlement-evidence-archive verify|rederive --archive <file> [--credit-id <id>]")
	}
	fs := flag.NewFlagSet("settlement-evidence-archive "+args[0], flag.ContinueOnError)
	archive := fs.String("archive", "", "path to a settlement-evidence-*.jsonl.gz archive (manifest beside it)")
	creditID := fs.Int64("credit-id", 0, "ledger_request_credits.id to rederive")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *archive == "" {
		return fmt.Errorf("--archive is required")
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	switch args[0] {
	case "verify":
		manifest, err := billing.VerifyEvidenceArchiveFile(*archive)
		if err != nil {
			return err
		}
		return enc.Encode(manifest)
	case "rederive":
		if *creditID <= 0 {
			return fmt.Errorf("--credit-id must be positive")
		}
		result, err := billing.RederiveArchivedCredit(*archive, *creditID)
		if err != nil {
			return err
		}
		if err := enc.Encode(result); err != nil {
			return err
		}
		if !result.Matches {
			return fmt.Errorf("rederived credit %d does not match the archived ledger credit", *creditID)
		}
		return nil
	default:
		return fmt.Errorf("unknown settlement-evidence-archive action %q", args[0])
	}
}
