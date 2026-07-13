package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
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
	case "revoke-bootstrap-identity":
		err = revokeBootstrapIdentity(os.Args[2:])
	case "list-bootstrap-identities":
		err = listBootstrapIdentities(os.Args[2:])
	case "list-tokens":
		err = listTokens(os.Args[2:])
	case "revoke-and-kick":
		err = revokeAndKick(os.Args[2:])
	case "prune-tokens":
		err = pruneTokens(os.Args[2:])
	case "list-pair-ot-mints":
		err = listPairOTMints(os.Args[2:])
	case "pre-flip-audit":
		err = preFlipAudit(os.Args[2:])
	case "create-seed-referral":
		err = createSeedReferral(os.Args[2:], os.Getenv, os.Stdout)
	case "adjust-seed-referral":
		err = adjustSeedReferral(os.Args[2:], os.Getenv, os.Stdout)
	case "replace-referral-issuer":
		err = replaceReferralIssuer(os.Args[2:], os.Getenv, os.Stdout)
	case "revoke-referral":
		err = revokeReferral(os.Args[2:], os.Stdout)
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

func revokeBootstrapIdentity(args []string) error {
	fs := flag.NewFlagSet("revoke-bootstrap-identity", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	providerID := fs.String("provider-id", "", "installer-generated provider ID to tombstone")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.RevokeBootstrapIdentity(context.Background(), *providerID); err != nil {
		return err
	}
	fmt.Printf("revoked bootstrap_identity provider_id=%s\n", *providerID)
	return nil
}

func listBootstrapIdentities(args []string) error {
	fs := flag.NewFlagSet("list-bootstrap-identities", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	state := fs.String("state", "all", "filter: all|unconfirmed-live|unconfirmed-expired|confirmed|operator-revoked")
	identityRetention := fs.Duration("identity-retention", 7*24*time.Hour, "post-token recovery retention used to show collection horizon; must match coordinator config")
	if err := fs.Parse(args); err != nil {
		return err
	}
	validState := map[string]bool{
		"all": true, "unconfirmed-live": true, "unconfirmed-expired": true,
		"confirmed": true, "operator-revoked": true,
	}
	if !validState[*state] {
		return fmt.Errorf("invalid --state %q", *state)
	}
	if *identityRetention <= 0 {
		return fmt.Errorf("--identity-retention must be positive")
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	records, err := store.ListBootstrapIdentities(context.Background())
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	matched := 0
	for _, record := range records {
		recordState := bootstrapIdentityState(record, now)
		if *state != "all" && *state != recordState {
			continue
		}
		fmt.Printf(
			"provider_id=%s state=%s age_s=%s expires_in_s=%s collect_in_s=%s created_at=%s expires_at=%s confirmed_at=%s operator_revoked_at=%s\n",
			record.ProviderID,
			recordState,
			ageSeconds(record.CreatedAt, now),
			expiresInSeconds(record.ExpiresAt, now),
			collectInSeconds(record, now, *identityRetention),
			record.CreatedAt,
			nullString(record.ExpiresAt),
			nullString(record.ConfirmedAt),
			nullString(record.OperatorRevokedAt),
		)
		matched++
	}
	fmt.Printf("count=%d\n", matched)
	return nil
}

func ageSeconds(createdAt string, now time.Time) string {
	created, err := time.Parse(time.RFC3339, createdAt)
	if err != nil {
		return "unknown"
	}
	seconds := int64(now.Sub(created).Seconds())
	if seconds < 0 {
		seconds = 0
	}
	return fmt.Sprintf("%d", seconds)
}

func expiresInSeconds(expiresAt sql.NullString, now time.Time) string {
	if !expiresAt.Valid {
		return "-"
	}
	expires, err := time.Parse(time.RFC3339, expiresAt.String)
	if err != nil {
		return "unknown"
	}
	return fmt.Sprintf("%d", int64(expires.Sub(now).Seconds()))
}

func collectInSeconds(record auth.BootstrapIdentityRecord, now time.Time, retention time.Duration) string {
	if record.ConfirmedAt.Valid || record.OperatorRevokedAt.Valid || !record.ExpiresAt.Valid {
		return "-"
	}
	expires, err := time.Parse(time.RFC3339, record.ExpiresAt.String)
	if err != nil {
		return "unknown"
	}
	return fmt.Sprintf("%d", int64(expires.Add(retention).Sub(now).Seconds()))
}

func bootstrapIdentityState(record auth.BootstrapIdentityRecord, now time.Time) string {
	if record.OperatorRevokedAt.Valid {
		return "operator-revoked"
	}
	if record.ConfirmedAt.Valid {
		return "confirmed"
	}
	if record.ExpiresAt.Valid {
		if expiresAt, err := time.Parse(time.RFC3339, record.ExpiresAt.String); err == nil && expiresAt.After(now) {
			return "unconfirmed-live"
		}
	}
	return "unconfirmed-expired"
}

func nullString(value sql.NullString) string {
	if value.Valid {
		return value.String
	}
	return "-"
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
// retire credentials that were minted by the self-serve path but never used
// (last_used_at IS NULL) and are older than the supplied cutoff. This
// bounds the operational cost of multi-mint when binary-side persist
// fails repeatedly. Codex architect review on PR #44 flagged the
// missing prune story; this is the normative command operators use.
//
// The cutoff is parsed first as a duration (e.g. "168h"), falling back
// to an RFC3339 absolute timestamp (e.g. "2026-06-04T00:00:00Z"). Dry-
// run mode is the default; pass --apply to retire matching credentials.
func pruneTokens(args []string) error {
	fs := flag.NewFlagSet("prune-tokens", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	olderThan := fs.String("older-than", "168h", "retire unused tokens older than this duration (e.g. 168h) or RFC3339 timestamp")
	apply := fs.Bool("apply", false, "actually retire credentials (default is dry-run)")
	force := fs.Bool("force", false, "allow cutoffs younger than 24h (DANGEROUS: may invalidate tokens of providers in their first settling window before they have reconnected with Bearer)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cutoff, err := resolvePruneCutoff(*olderThan)
	if err != nil {
		return fmt.Errorf("invalid --older-than %q: %w", *olderThan, err)
	}
	// SPEC-003 v0.8.2 FR-C9.4 operator-safety guard. The codex security
	// re-audit on PR #44 (MINOR-2) flagged that a self-minted token is
	// `last_used_at IS NULL` until the binary reconnects with Bearer
	// (which happens AFTER persist completes and is several seconds out
	// in the operational worst case). A confused operator running
	// `--apply --older-than 0s` during the settling window would invalidate
	// the active first-session provider's only token, bricking it under
	// the new TOFU regime. Refuse cutoffs younger than 24h unless
	// --force is passed explicitly.
	minAge := 24 * time.Hour
	now := time.Now().UTC()
	if cutoff.After(now.Add(-minAge)) && !*force {
		return fmt.Errorf(
			"refusing to prune with cutoff %s (younger than 24h ago at %s); a self-minted token does not become last_used_at-non-NULL until the binary reconnects with Bearer, which can take several seconds. Pass --force to override at the risk of bricking providers mid-onboarding",
			cutoff.UTC().Format(time.RFC3339),
			now.Format(time.RFC3339),
		)
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	cutoffStr := cutoff.UTC().Format("2006-01-02T15:04:05Z")
	if !*apply {
		records, err := store.ListTokens(context.Background())
		if err != nil {
			return err
		}
		matched := 0
		// Build a friendly dry-run summary that surfaces the candidates
		// so the operator can sanity-check before --apply. The semantic
		// trap is "last_used_at NULL" not actually meaning "stale";
		// surfacing token_prefix + provider_id + age helps the operator
		// notice that they would be pruning a provider that connected
		// 3 minutes ago and has not yet earned a bearer.
		fmt.Printf("dry_run=true cutoff=%s\n", cutoffStr)
		for _, r := range records {
			if !r.LastUsedAt.Valid && !r.RevokedAt.Valid && r.CreatedAt < cutoffStr {
				fmt.Printf("  candidate token_prefix=%s provider_id=%s created_at=%s last_used_at=NULL\n", r.TokenPrefix, r.ProviderID, r.CreatedAt)
				matched++
			}
		}
		fmt.Printf("would_retire=%d\n", matched)
		fmt.Println("NOTE: last_used_at=NULL means the binary has never authenticated with this token via Bearer. Verify each candidate is genuinely stale (not a provider currently in its self-mint -> persist -> reconnect window) before --apply.")
		fmt.Println("re-run with --apply to retire these credentials")
		return nil
	}
	retired, err := store.PruneUnusedTokens(context.Background(), cutoff)
	if err != nil {
		return err
	}
	fmt.Printf("dry_run=false cutoff=%s retired=%d\n", cutoffStr, retired)
	return nil
}

func listPairOTMints(args []string) error {
	fs := flag.NewFlagSet("list-pair-ot-mints", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	providerID := fs.String("provider-id", "", "optional provider_id filter")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	rows, err := store.ListPairOTMintLog(context.Background(), *providerID)
	if err != nil {
		return err
	}
	for _, row := range rows {
		sourceIP := ""
		if row.SourceIP.Valid {
			sourceIP = row.SourceIP.String
		}
		userAgent := ""
		if row.UserAgent.Valid {
			userAgent = row.UserAgent.String
		}
		fmt.Printf("%d\t%s\t%d\t%s\t%s\t%s\n", row.ID, row.ProviderID, row.Outcome, row.TS, sourceIP, userAgent)
	}
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

// preFlipAudit is the SPEC-003 FR-C9.4 executable runbook gate (#82 item 3).
// Operators MUST run this before flipping RequireProviderTokens=true to ensure
// every active provider_tokens row has a `last_used_at` no older than
// --max-last-used-age. A row with last_used_at IS NULL is ALWAYS treated as
// stale — it means no provider has ever authenticated with Bearer using that
// token, so flipping the flag would brick that provider.
//
// Exit codes:
//
//	0 — no stale active rows; safe to flip RequireProviderTokens=true
//	1 — at least one stale active row; refuse to flip
//	2 — usage / flag error (handled by flag.ExitOnError)
//	*  other I/O failure (DB open / read), error printed to stderr
//
// Output format is human-readable by default; pass --json for machine-readable.
// The full report is printed to stdout in both modes regardless of result, so
// operators can pipe to deploy-pipeline gates.
func preFlipAudit(args []string) error {
	stale, err := preFlipAuditRun(args, os.Stdout)
	if err != nil {
		return err
	}
	if stale {
		os.Exit(1)
	}
	return nil
}

// preFlipAuditRun is the testable core. Returns stale=true when any active
// row failed the freshness check; the caller maps that to exit 1.
func preFlipAuditRun(args []string, stdout io.Writer) (stale bool, err error) {
	fs := flag.NewFlagSet("pre-flip-audit", flag.ExitOnError)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	maxAge := fs.Duration("max-last-used-age", 24*time.Hour, "maximum allowed last_used_at age; rows older (or NULL) are stale")
	jsonOut := fs.Bool("json", false, "emit machine-readable JSON instead of text")
	if err := fs.Parse(args); err != nil {
		return false, err
	}
	if *maxAge <= 0 {
		return false, fmt.Errorf("--max-last-used-age must be positive, got %s", *maxAge)
	}
	// Fail closed if the operator points at a non-existent DB path.
	// auth.OpenStore would otherwise create an empty SQLite file and the
	// audit would silently return safe_to_flip=true on a typo'd path.
	// The deploy gate must NEVER pass on phantom evidence.
	if _, err := os.Stat(*dbPath); err != nil {
		if os.IsNotExist(err) {
			return false, fmt.Errorf("coordinator DB %q does not exist; refusing to create an empty file for a deploy gate", *dbPath)
		}
		return false, fmt.Errorf("stat coordinator DB %q: %w", *dbPath, err)
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return false, err
	}
	defer store.Close()
	records, err := store.ListTokens(context.Background())
	if err != nil {
		return false, err
	}
	// Parse each non-NULL last_used_at with the canonical layout
	// auth/tokens.go nowString() writes. Failing closed on a parse
	// error is a defense-in-depth check: production writes go through
	// nowString(), but a corrupted or out-of-band write would otherwise
	// pass the lex comparison silently.
	const canonicalTimeLayout = "2006-01-02T15:04:05Z"
	now := time.Now().UTC()
	cutoff := now.Add(-*maxAge)
	cutoffStr := cutoff.Format(canonicalTimeLayout)

	type offender struct {
		TokenPrefix  string  `json:"token_prefix"`
		ProviderID   string  `json:"provider_id"`
		ProviderName string  `json:"provider_name"`
		CreatedAt    string  `json:"created_at"`
		LastUsedAt   *string `json:"last_used_at"`
		Reason       string  `json:"reason"`
	}
	offenders := []offender{}
	activeCount := 0
	for _, r := range records {
		if r.RevokedAt.Valid {
			continue
		}
		activeCount++
		if !r.LastUsedAt.Valid {
			offenders = append(offenders, offender{
				TokenPrefix:  r.TokenPrefix,
				ProviderID:   r.ProviderID,
				ProviderName: r.ProviderName,
				CreatedAt:    r.CreatedAt,
				LastUsedAt:   nil,
				Reason:       "last_used_at IS NULL (provider never authenticated with Bearer)",
			})
			continue
		}
		// Strict-layout parse — any deviation from the canonical UTC
		// RFC3339Z second-precision shape is treated as stale (fail
		// closed). Production writes ALWAYS use this layout; a deviant
		// row is either corruption or an out-of-band write and the
		// deploy gate must not pass on it.
		//
		// Round-trip check: Go's time.Parse with the "...05Z" layout
		// permits fractional seconds (e.g. "...05.123Z") even though
		// the layout omits them — see Go's time/format.go. So
		// time.Parse succeeding is NECESSARY but NOT SUFFICIENT for
		// canonical. We round-trip the parsed time back through Format
		// with the same layout and require byte-identical equality
		// to the stored string.
		parsed, parseErr := time.Parse(canonicalTimeLayout, r.LastUsedAt.String)
		canonicalRoundTrip := parseErr == nil && parsed.UTC().Format(canonicalTimeLayout) == r.LastUsedAt.String
		if !canonicalRoundTrip {
			v := r.LastUsedAt.String
			reason := ""
			if parseErr != nil {
				reason = fmt.Sprintf("last_used_at %q is not canonical RFC3339Z second-precision UTC (parse error: %v); refusing to admit a non-canonical row", v, parseErr)
			} else {
				reason = fmt.Sprintf("last_used_at %q is not canonical RFC3339Z second-precision UTC (round-trip mismatch with %q); refusing to admit a non-canonical row", v, parsed.UTC().Format(canonicalTimeLayout))
			}
			offenders = append(offenders, offender{
				TokenPrefix:  r.TokenPrefix,
				ProviderID:   r.ProviderID,
				ProviderName: r.ProviderName,
				CreatedAt:    r.CreatedAt,
				LastUsedAt:   &v,
				Reason:       reason,
			})
			continue
		}
		if parsed.Before(cutoff) {
			v := r.LastUsedAt.String
			offenders = append(offenders, offender{
				TokenPrefix:  r.TokenPrefix,
				ProviderID:   r.ProviderID,
				ProviderName: r.ProviderName,
				CreatedAt:    r.CreatedAt,
				LastUsedAt:   &v,
				Reason:       fmt.Sprintf("last_used_at %s older than cutoff %s", v, cutoffStr),
			})
		}
	}

	if *jsonOut {
		out := struct {
			Cutoff       string     `json:"cutoff"`
			MaxAge       string     `json:"max_last_used_age"`
			ActiveTokens int        `json:"active_tokens"`
			StaleCount   int        `json:"stale_count"`
			Offenders    []offender `json:"offenders"`
			SafeToFlip   bool       `json:"safe_to_flip"`
		}{cutoffStr, maxAge.String(), activeCount, len(offenders), offenders, len(offenders) == 0}
		b, mErr := json.MarshalIndent(out, "", "  ")
		if mErr != nil {
			return false, mErr
		}
		fmt.Fprintln(stdout, string(b))
	} else {
		fmt.Fprintf(stdout, "pre-flip-audit cutoff=%s max_age=%s active_tokens=%d stale=%d\n", cutoffStr, maxAge.String(), activeCount, len(offenders))
		for _, o := range offenders {
			lu := "NULL"
			if o.LastUsedAt != nil {
				lu = *o.LastUsedAt
			}
			fmt.Fprintf(stdout, "  STALE token_prefix=%s provider_id=%s provider_name=%q created_at=%s last_used_at=%s reason=%q\n",
				o.TokenPrefix, o.ProviderID, o.ProviderName, o.CreatedAt, lu, o.Reason)
		}
		if len(offenders) == 0 {
			fmt.Fprintln(stdout, "safe_to_flip=true (no stale active rows)")
		} else {
			fmt.Fprintf(stdout, "safe_to_flip=false (%d stale active rows; do NOT flip RequireProviderTokens=true until each is reconnected or revoked)\n", len(offenders))
		}
	}

	return len(offenders) > 0, nil
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: coordinator-cli <issue-token|revoke-token|revoke-bootstrap-identity|list-bootstrap-identities|list-tokens|revoke-and-kick|prune-tokens|list-pair-ot-mints|pre-flip-audit|create-seed-referral|adjust-seed-referral|replace-referral-issuer|revoke-referral> [flags]")
}

func createSeedReferral(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := flag.NewFlagSet("create-seed-referral", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	keyID := fs.String("key-id", "", "HMAC key identifier")
	secretEnv := fs.String("secret-env", "", "environment variable containing the HMAC secret")
	seedID := fs.String("seed-id", "", "opaque seed issuer identifier")
	maxUses := fs.Int("max-uses", 1, "maximum successful registrations")
	expiresAt := fs.String("expires-at", "", "optional RFC3339 expiry")
	fs.Usage = referralUsage(fs, "create-seed-referral",
		"coordinator-cli create-seed-referral --db coordinator.db --campaign prebeta \\\n"+
			"    --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 100")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 || strings.TrimSpace(*secretEnv) == "" {
		return fmt.Errorf("--secret-env is required; referral HMAC secrets are not accepted on argv")
	}
	secret := getenv(strings.TrimSpace(*secretEnv))
	if len(secret) < 32 {
		return fmt.Errorf("referral HMAC secret from %s must be at least 32 bytes", *secretEnv)
	}
	policy := auth.ReferralPolicy{
		Campaign:         strings.TrimSpace(*campaign),
		PolicyVersion:    "v1",
		CurrentKeyID:     strings.TrimSpace(*keyID),
		HMACKeys:         map[string]string{strings.TrimSpace(*keyID): secret},
		ProviderBaseUses: 1,
		SocialBonusUses:  1,
		ChallengeTTL:     15 * time.Minute,
	}
	if err := policy.Validate(); err != nil {
		return err
	}
	var expiry *time.Time
	if strings.TrimSpace(*expiresAt) != "" {
		parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(*expiresAt))
		if err != nil {
			return fmt.Errorf("--expires-at must be RFC3339: %w", err)
		}
		parsed = parsed.UTC()
		expiry = &parsed
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	code, err := store.CreateSeedReferral(context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, expiry)
	if errors.Is(err, auth.ErrReferralSeedExists) {
		return fmt.Errorf("seed %s already exists; use adjust-seed-referral to change its capacity", strings.TrimSpace(*seedID))
	}
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "referral_code=%s\ncampaign=%s\nseed_id=%s\nmax_uses=%d\nstatus=created\n", code, policy.Campaign, strings.TrimSpace(*seedID), *maxUses)
	return err
}

func adjustSeedReferral(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := flag.NewFlagSet("adjust-seed-referral", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	keyID := fs.String("key-id", "", "HMAC key identifier")
	secretEnv := fs.String("secret-env", "", "environment variable containing the HMAC secret")
	seedID := fs.String("seed-id", "", "opaque seed issuer identifier")
	maxUses := fs.Int("max-uses", -1, "new maximum successful registrations")
	apply := fs.Bool("apply", false, "apply the change (default is dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	fs.Usage = referralUsage(fs, "adjust-seed-referral",
		"coordinator-cli adjust-seed-referral --db coordinator.db --campaign prebeta \\\n"+
			"    --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 250 \\\n"+
			"    --apply --actor ops@malibu --reason 'expand launch cohort'")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 || strings.TrimSpace(*secretEnv) == "" {
		return fmt.Errorf("--secret-env is required; referral HMAC secrets are not accepted on argv")
	}
	if *maxUses < 0 {
		return fmt.Errorf("--max-uses is required and must be >= 0")
	}
	secret := getenv(strings.TrimSpace(*secretEnv))
	if len(secret) < 32 {
		return fmt.Errorf("referral HMAC secret from %s must be at least 32 bytes", *secretEnv)
	}
	policy := auth.ReferralPolicy{
		Campaign:         strings.TrimSpace(*campaign),
		PolicyVersion:    "v1",
		CurrentKeyID:     strings.TrimSpace(*keyID),
		HMACKeys:         map[string]string{strings.TrimSpace(*keyID): secret},
		ProviderBaseUses: 1,
		SocialBonusUses:  1,
		ChallengeTTL:     15 * time.Minute,
	}
	if err := policy.Validate(); err != nil {
		return err
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	preview, err := store.AdjustSeedReferral(context.Background(), policy, strings.TrimSpace(*seedID), *maxUses, *apply, strings.TrimSpace(*actor), strings.TrimSpace(*reason), time.Now().UTC())
	if errors.Is(err, auth.ErrReferralCapacityBelowUsed) {
		return fmt.Errorf("refusing to set capacity below redeemed+reserved uses for seed %s", strings.TrimSpace(*seedID))
	}
	if err != nil {
		return err
	}
	mode := "dry-run"
	if preview.Applied {
		mode = "applied"
	}
	_, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nseed_id=%s\ncurrent_capacity=%d\nnew_capacity=%d\nredeemed=%d\nreserved=%d\nresulting_remaining=%d\n",
		mode, policy.Campaign, preview.SeedID, preview.CurrentCapacity, preview.NewCapacity, preview.Redeemed, preview.Reserved, preview.ResultingRemaining)
	return err
}

func replaceReferralIssuer(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := flag.NewFlagSet("replace-referral-issuer", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	// FIX-570 PROD-H4/ADV-M3: the successor's signing key and capacity are taken
	// from the coordinator's AUTHORITATIVE resolved config, not from operator flags.
	// The command no longer verifies its result against its own ad-hoc policy (which
	// always reported verified=true); it compares the operator-stated key/capacity
	// against the deployed policy, rejects any mismatch, and validates the generated
	// code under the DEPLOYED policy.
	configPath := fs.String("config", "", "path to the coordinator YAML config (authoritative referral policy; required)")
	campaign := fs.String("campaign", "", "referral campaign identifier (must match the deployed campaign)")
	keyID := fs.String("key-id", "", "expected HMAC key identifier (must match the deployed current_key_id)")
	secretEnv := fs.String("secret-env", "", "environment variable containing the expected HMAC secret (must match the deployed secret)")
	issuerID := fs.String("issuer-id", "", "revoked provider issuer identifier to replace")
	baseUses := fs.Int("base-uses", 0, "expected successor base capacity (must match the deployed provider_base_uses; required, must be > 0)")
	apply := fs.Bool("apply", false, "apply the replacement (default is a rollback-safe dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	fs.Usage = referralUsage(fs, "replace-referral-issuer",
		"coordinator-cli replace-referral-issuer --db coordinator.db --config coordinator.yaml \\\n"+
			"    --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET \\\n"+
			"    --issuer-id <revoked-issuer> --base-uses 3 \\\n"+
			"    --apply --actor ops@malibu --reason 'issuer key rotation'")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 || strings.TrimSpace(*secretEnv) == "" {
		return fmt.Errorf("--secret-env is required; referral HMAC secrets are not accepted on argv")
	}
	if strings.TrimSpace(*configPath) == "" {
		return fmt.Errorf("--config is required; the successor policy is loaded from the coordinator's authoritative config")
	}
	if *apply && (strings.TrimSpace(*actor) == "" || strings.TrimSpace(*reason) == "") {
		return fmt.Errorf("--actor and --reason are required with --apply")
	}
	if *baseUses <= 0 {
		return fmt.Errorf("--base-uses is required and must be > 0")
	}
	cfg, err := config.Load(strings.TrimSpace(*configPath))
	if err != nil {
		return fmt.Errorf("load coordinator config: %w", err)
	}
	if !cfg.Referrals.RequireForRegistration && !cfg.Referrals.EnableSocialInviteBonus {
		return fmt.Errorf("the deployed config has no active referral policy; refusing to replace an issuer")
	}
	// Build the DEPLOYED (authoritative) policy exactly as the coordinator does.
	deployed := auth.ReferralPolicy{
		RequireForRegistration: cfg.Referrals.RequireForRegistration,
		EnableSocialBonus:      cfg.Referrals.EnableSocialInviteBonus,
		Campaign:               cfg.Referrals.Campaign,
		PolicyVersion:          cfg.Referrals.PolicyVersion,
		CurrentKeyID:           cfg.Referrals.CurrentKeyID,
		HMACKeys:               cfg.Referrals.HMACKeys,
		ProviderBaseUses:       cfg.Referrals.ProviderBaseUses,
		SocialBonusUses:        cfg.Referrals.SocialBonusUses,
		ChallengeTTL:           time.Duration(cfg.Referrals.ChallengeTTLS) * time.Second,
	}
	if err := deployed.Validate(); err != nil {
		return fmt.Errorf("deployed referral policy is invalid: %w", err)
	}
	// Reject any mismatch between the operator's stated intent and the deployed
	// policy — signing-key identity, signing secret, campaign, and capacity — BEFORE
	// mutating anything.
	if strings.TrimSpace(*campaign) != deployed.Campaign {
		return fmt.Errorf("campaign mismatch: --campaign=%q but deployed campaign=%q", strings.TrimSpace(*campaign), deployed.Campaign)
	}
	if strings.TrimSpace(*keyID) != deployed.CurrentKeyID {
		return fmt.Errorf("signing key mismatch: --key-id=%q but deployed current_key_id=%q", strings.TrimSpace(*keyID), deployed.CurrentKeyID)
	}
	secret := getenv(strings.TrimSpace(*secretEnv))
	if deployedSecret := deployed.HMACKeys[deployed.CurrentKeyID]; secret != deployedSecret {
		return fmt.Errorf("signing secret mismatch: %s does not match the deployed secret for key %q", strings.TrimSpace(*secretEnv), deployed.CurrentKeyID)
	}
	if *baseUses != deployed.ProviderBaseUses {
		return fmt.Errorf("capacity mismatch: --base-uses=%d but deployed provider_base_uses=%d", *baseUses, deployed.ProviderBaseUses)
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	replacement, err := store.ReplaceReferralIssuer(context.Background(), deployed, strings.TrimSpace(*issuerID), strings.TrimSpace(*actor), strings.TrimSpace(*reason), *apply, time.Now().UTC())
	if err != nil {
		return err
	}
	if !replacement.Applied {
		_, err = fmt.Fprintf(stdout, "mode=dry-run campaign=%s provider_id=%s old_issuer_id=%s key_id=%s old_base_capacity=%d proposed_base_capacity=%d old_bonus_capacity=%d proposed_bonus_capacity=%d pending_social_review=%t\n",
			deployed.Campaign, replacement.ProviderID, replacement.OldIssuerID, replacement.KeyID,
			replacement.OldBaseCapacity, replacement.BaseCapacity, replacement.OldBonusCapacity, replacement.BonusCapacity, replacement.PendingSocialReview)
		return err
	}
	// Validate the generated code under the DEPLOYED policy (not an ad-hoc one) so a
	// wrong key/secret cannot report success on an unusable successor code.
	if _, verifyErr := store.ValidateReferral(context.Background(), deployed, replacement.NewCode, time.Now().UTC()); verifyErr != nil {
		return fmt.Errorf("successor code failed verification under the DEPLOYED policy: %w", verifyErr)
	}
	_, err = fmt.Fprintf(stdout, "mode=applied campaign=%s provider_id=%s old_issuer_id=%s new_issuer_id=%s new_referral_code=%s base_capacity=%d bonus_capacity=%d pending_social_review=%t verified=true\n",
		deployed.Campaign, replacement.ProviderID, replacement.OldIssuerID, replacement.NewIssuerID, replacement.NewCode, replacement.BaseCapacity, replacement.BonusCapacity, replacement.PendingSocialReview)
	return err
}

func revokeReferral(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("revoke-referral", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
	campaign := fs.String("campaign", "", "referral campaign identifier")
	issuerID := fs.String("issuer-id", "", "seed or provider invite issuer identifier")
	// FIX-570 M6: revoke is now audited. --apply gates the mutation; without it the
	// command previews the target so an operator can confirm before revoking.
	apply := fs.Bool("apply", false, "apply the revocation (default is a dry-run preview)")
	actor := fs.String("actor", "", "operator identity recorded in the audit log (required with --apply)")
	reason := fs.String("reason", "", "reason recorded in the audit log (required with --apply)")
	// FIX-570 M5(prod): revoking a seed can invalidate every circulated link, so
	// --apply requires confirming the blast-radius counts shown by the dry-run.
	expectRedeemed := fs.Int("expect-redeemed", -1, "expected redemption count from the dry-run preview (required with --apply)")
	expectReservations := fs.Int("expect-reservations", -1, "expected live-reservation count from the dry-run preview (required with --apply)")
	fs.Usage = referralUsage(fs, "revoke-referral",
		"coordinator-cli revoke-referral --db coordinator.db --campaign prebeta \\\n"+
			"    --issuer-id <issuer> --apply --actor ops@malibu --reason 'abuse report #42' \\\n"+
			"    --expect-redeemed 3 --expect-reservations 0")
	if err := fs.Parse(args); err != nil {
		return referralParseError(err)
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	if *apply && (strings.TrimSpace(*actor) == "" || strings.TrimSpace(*reason) == "") {
		return fmt.Errorf("--actor and --reason are required with --apply")
	}
	var expect *auth.ReferralRevokeExpectation
	if *apply {
		if *expectRedeemed < 0 || *expectReservations < 0 {
			return fmt.Errorf("--expect-redeemed and --expect-reservations are required with --apply (run the dry-run first and pass the shown counts)")
		}
		expect = &auth.ReferralRevokeExpectation{Redeemed: *expectRedeemed, LiveReservations: *expectReservations}
	}
	store, err := auth.OpenStore(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	result, err := store.RevokeReferralIssuerAudited(context.Background(), *campaign, *issuerID, *apply, strings.TrimSpace(*actor), strings.TrimSpace(*reason), expect, time.Now().UTC())
	if err != nil {
		return err
	}
	mode := "dry-run"
	if result.Applied {
		mode = "applied"
	}
	_, err = fmt.Fprintf(stdout, "mode=%s\ncampaign=%s\nissuer_id=%s\ncode_type=%s\nprovider_id=%s\nredeemed=%d\nlive_reservations=%d\nremaining_capacity=%d\n",
		mode, result.Campaign, result.IssuerID, result.CodeType, result.ProviderID, result.Redeemed, result.LiveReservations, result.RemainingCapacity)
	return err
}

// referralUsage returns a flag.Usage that restores per-subcommand help (the
// referral subcommands discard flag output to control error formatting, which
// otherwise suppresses -h). FIX-570 L1-product.
func referralUsage(fs *flag.FlagSet, name, example string) func() {
	return func() {
		fmt.Fprintf(os.Stderr, "usage: coordinator-cli %s [flags]\n\nflags:\n", name)
		fs.SetOutput(os.Stderr)
		fs.PrintDefaults()
		fs.SetOutput(io.Discard)
		fmt.Fprintf(os.Stderr, "\nexample:\n  %s\n", example)
	}
}

// referralParseError prints usage on -h (flag.ErrHelp) and exits cleanly, while
// surfacing genuine parse errors. FIX-570 L1-product.
func referralParseError(err error) error {
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	return err
}
