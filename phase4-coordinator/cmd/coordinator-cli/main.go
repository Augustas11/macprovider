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
	providerName := fs.String("provider-name", "", "provider display name")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	record, token, err := store.IssueToken(context.Background(), *providerName)
	if err != nil {
		return err
	}
	fmt.Printf("token=%s\n", token)
	fmt.Printf("token_prefix=%s\n", record.TokenPrefix)
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
		fmt.Printf("%d\t%s\t%s\t%s\t%s\t%s\n", record.ID, record.TokenPrefix, record.ProviderName, record.CreatedAt, status, lastUsed)
	}
	return nil
}

func revokeAndKick(args []string) error {
	fs := flag.NewFlagSet("revoke-and-kick", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	prefix := fs.String("token-prefix", "", "token prefix printed at issuance")
	adminURL := fs.String("admin-url", "", "coordinator operator base URL")
	operatorKey := fs.String("operator-key", "", "operator bearer token")
	providerID := fs.String("provider-id", "", "stable provider ID to blacklist")
	reason := fs.String("reason", "provider token revoked", "blacklist reason")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *adminURL == "" || *operatorKey == "" || *providerID == "" {
		return fmt.Errorf("revoke-and-kick requires --admin-url, --operator-key, and --provider-id")
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
	if err := kickProvider(*adminURL, *operatorKey, *providerID, *reason); err != nil {
		return err
	}
	fmt.Printf("revoked token_prefix=%s provider_name=%s kicked provider_id=%s\n", record.TokenPrefix, record.ProviderName, *providerID)
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

func usage() {
	fmt.Fprintln(os.Stderr, "usage: coordinator-cli <issue-token|revoke-token|list-tokens|revoke-and-kick> [flags]")
}
