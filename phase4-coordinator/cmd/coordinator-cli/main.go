package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "issue-token":
		err = issueToken(os.Args[2:])
	case "revoke-token":
		err = revokeToken(os.Args[2:])
	case "list-tokens":
		err = listTokens(os.Args[2:])
	case "revoke-and-kick":
		err = revokeAndKick(os.Args[2:])
	case "prune-tokens":
		err = pruneTokens(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func issueToken(args []string) error {
	fs := flag.NewFlagSet("issue-token", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	providerID := fs.String("provider-id", "", "stable provider_id this token may authenticate")
	providerName := fs.String("provider-name", "", "provider display name")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	record, token, err := store.IssueToken(context.Background(), *providerID, *providerName)
	if err != nil {
		return err
	}
	fmt.Printf("token=%s\n", token)
	fmt.Printf("token_prefix=%s\n", record.TokenPrefix)
	fmt.Printf("provider_id=%s\n", record.ProviderID)
	fmt.Printf("provider_name=%s\n", record.ProviderName)
	return nil
}

func revokeToken(args []string) error {
	fs := flag.NewFlagSet("revoke-token", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	prefix := fs.String("token-prefix", "", "token prefix printed at issuance")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	record, err := store.RevokeToken(context.Background(), *prefix)
	if err != nil {
		return err
	}
	fmt.Printf("revoked token_prefix=%s provider_name=%s\n", record.TokenPrefix, record.ProviderName)
	return nil
}

func listTokens(args []string) error {
	fs := flag.NewFlagSet("list-tokens", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	records, err := store.ListTokens(context.Background())
	if err != nil {
		return err
	}
	for _, record := range records {
		status := "active"
		if record.RevokedAt.Valid {
			status = "revoked"
		}
		lastUsed := ""
		if record.LastUsedAt.Valid {
			lastUsed = record.LastUsedAt.String
		}
		fmt.Printf("%d\t%s\t%s\t%s\t%s\t%s\t%s\n", record.ID, record.TokenPrefix, record.ProviderID, record.ProviderName, record.CreatedAt, status, lastUsed)
	}
	return nil
}

func revokeAndKick(args []string) error {
	fs := flag.NewFlagSet("revoke-and-kick", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	prefix := fs.String("token-prefix", "", "token prefix printed at issuance")
	adminURL := fs.String("admin-url", "", "coordinator operator base URL")
	operatorKey := fs.String("operator-key", "", "operator bearer token")
	providerID := fs.String("provider-id", "", "optional stable provider ID override for legacy tokens without provider_id")
	reason := fs.String("reason", "provider token revoked", "blacklist reason")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *adminURL == "" || *operatorKey == "" {
		return fmt.Errorf("revoke-and-kick requires --admin-url and --operator-key")
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	record, err := store.RevokeToken(context.Background(), *prefix)
	if err != nil {
		return err
	}
	targetProviderID := record.ProviderID
	if *providerID != "" {
		if targetProviderID != "" && *providerID != targetProviderID {
			return fmt.Errorf("token belongs to provider_id %s, refusing to kick %s", targetProviderID, *providerID)
		}
		targetProviderID = *providerID
	}
	if targetProviderID == "" {
		return fmt.Errorf("revoked token has no provider_id; pass --provider-id for legacy token")
	}
	if err := kickProvider(*adminURL, *operatorKey, targetProviderID, *reason); err != nil {
		return err
	}
	fmt.Printf("revoked token_prefix=%s provider_id=%s provider_name=%s kicked provider_id=%s\n", record.TokenPrefix, record.ProviderID, record.ProviderName, targetProviderID)
	return nil
}

func kickProvider(adminURL, operatorKey, providerID, reason string) error {
	body, err := json.Marshal(map[string]string{
		"provider_id": providerID,
		"reason":      reason,
	})
	if err != nil {
		return err
	}
	url := strings.TrimRight(adminURL, "/") + "/admin/blacklist"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("blacklist returned HTTP %d", resp.StatusCode)
	}
	return nil
}

// pruneTokens implements SPEC-003 v0.8 FR-C9.4 operator-side cleanup:
// remove tokens that were minted by the self-serve path but never used
// (last_used_at IS NULL) and are older than the supplied cutoff. This
// bounds the operational cost of multi-mint when binary-side persist
// fails repeatedly. Codex architect review on PR #44 flagged the
// missing prune story; this is the normative command operators use.
//
// The cutoff is parsed first as a duration (e.g. "168h"), falling back
// to an RFC3339 absolute timestamp (e.g. "2026-06-04T00:00:00Z"). Dry-
// run mode is the default; pass --apply to actually delete rows.
func pruneTokens(args []string) error {
	fs := flag.NewFlagSet("prune-tokens", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	olderThan := fs.String("older-than", "168h", "delete unused tokens older than this duration (e.g. 168h) or RFC3339 timestamp")
	apply := fs.Bool("apply", false, "actually delete rows (default is dry-run)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cutoff, err := resolvePruneCutoff(*olderThan)
	if err != nil {
		return fmt.Errorf("invalid --older-than %q: %w", *olderThan, err)
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	if !*apply {
		records, err := store.ListTokens(context.Background())
		if err != nil {
			return err
		}
		matched := 0
		cutoffStr := cutoff.UTC().Format("2006-01-02T15:04:05Z")
		for _, r := range records {
			if !r.LastUsedAt.Valid && !r.RevokedAt.Valid && r.CreatedAt < cutoffStr {
				matched++
			}
		}
		fmt.Printf("dry_run=true cutoff=%s would_prune=%d\n", cutoffStr, matched)
		fmt.Println("re-run with --apply to actually delete")
		return nil
	}
	pruned, err := store.PruneUnusedTokens(context.Background(), cutoff)
	if err != nil {
		return err
	}
	fmt.Printf("dry_run=false cutoff=%s pruned=%d\n", cutoff.UTC().Format("2006-01-02T15:04:05Z"), pruned)
	return nil
}

func resolvePruneCutoff(s string) (time.Time, error) {
	if d, err := time.ParseDuration(s); err == nil {
		return time.Now().UTC().Add(-d), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("expected duration (e.g. 168h) or RFC3339 timestamp")
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: coordinator-cli <issue-token|revoke-token|list-tokens|revoke-and-kick|prune-tokens> [flags]")
}
