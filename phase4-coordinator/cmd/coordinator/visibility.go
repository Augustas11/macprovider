package main

// SPEC-017 v0.1.8 Step 4.C operator-runbook subcommand:
//
//	coordinator visibility revert --id <provider_id> --reason "<text>"
//
// Sets provider_visibility.mode = 'bucketed' AND inserts a
// provider_visibility_audit row with actor_kind = 'operator'.
//
// SECURITY-lane CRITICAL boundary: this CLI MUST hard-refuse
// any path that would write `new_mode='exact'` with
// `actor_kind='operator'`. The bucketed→exact direction is
// reserved exclusively for the SPEC-014 v0.9 provider-
// authenticated portal flow. AC-20 CI assertion catches any
// `new_mode='exact' AND actor_kind='operator'` row.
//
// The IMPL therefore (a) hardcodes 'bucketed' into the
// UPDATE and INSERT (not parameterized from a flag), (b)
// does NOT expose any `--mode` / `--exact` flag, and (c)
// also has no `visibility exact` verb dispatched anywhere.
import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

func runVisibility(args []string) int {
	if len(args) < 1 {
		visibilityUsage(os.Stderr)
		return 2
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "revert":
		return runVisibilityRevert(rest, os.Stdout, os.Stderr)
	case "exact":
		// Spelled-out hard refusal so an operator who reaches
		// for the "obvious" inverse verb gets a clear redirect
		// to the portal flow, NOT a silent fall-through to
		// usage().
		fmt.Fprintln(os.Stderr, "visibility exact: not supported via operator CLI; bucketed → exact is the SPEC-014 v0.9 provider-authenticated portal flow")
		return 2
	default:
		fmt.Fprintf(os.Stderr, "unknown visibility verb %q\n", verb)
		visibilityUsage(os.Stderr)
		return 2
	}
}

func visibilityUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: coordinator visibility revert --id <provider_id> --reason TEXT")
}

// runVisibilityRevert UPDATEs provider_visibility.mode to
// 'bucketed' and INSERTs the audit row.
//
// Both writes happen inside a single transaction to keep the
// audit row's `old_mode` consistent with the row that actually
// got rewritten (no race where someone else flips the row
// between SELECT and UPDATE).
func runVisibilityRevert(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("visibility revert", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config")
	adminDSNFlag := fs.String("admin-dsn", "", "operator admin DSN (overrides --config and "+adminDSNEnv+")")
	providerID := fs.String("id", "", "provider_id to revert (required)")
	reason := fs.String("reason", "", "revert reason (required)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if strings.TrimSpace(*providerID) == "" {
		fmt.Fprintln(stderr, "visibility revert: --id is required")
		return 2
	}
	if strings.TrimSpace(*reason) == "" {
		fmt.Fprintln(stderr, "visibility revert: --reason is required")
		return 2
	}
	dsn, _, err := resolveAdminDSN(*adminDSNFlag, *configPath)
	if err != nil {
		fmt.Fprintf(stderr, "visibility revert: %v\n", err)
		return 2
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		fmt.Fprintf(stderr, "visibility revert: open admin db: %v\n", err)
		return 1
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		fmt.Fprintf(stderr, "visibility revert: begin: %v\n", err)
		return 1
	}
	defer tx.Rollback()

	var oldMode string
	err = tx.QueryRowContext(ctx,
		`SELECT mode FROM provider_visibility WHERE provider_id = $1 FOR UPDATE`,
		*providerID,
	).Scan(&oldMode)
	if errors.Is(err, sql.ErrNoRows) {
		// First-write semantics: if no row exists, the effective
		// mode is the column DEFAULT ('bucketed'). A "revert to
		// bucketed" on a non-existent row is a no-op + clean
		// error rather than a quietly-created row.
		fmt.Fprintf(stderr, "visibility revert: no provider_visibility row for id=%s (effective default is already 'bucketed')\n", *providerID)
		return 1
	}
	if err != nil {
		fmt.Fprintf(stderr, "visibility revert: lookup: %v\n", err)
		return 1
	}
	if oldMode == "bucketed" {
		// Surface as clean error: operator likely expected the
		// row was 'exact'. The audit row would still be
		// honest, but emitting it would clutter the audit log
		// with no-ops.
		fmt.Fprintf(stderr, "visibility revert: id=%s is already 'bucketed' (nothing to revert)\n", *providerID)
		return 1
	}

	// The literal 'bucketed' below is the SECURITY boundary —
	// hardcoded, NOT a flag-derived parameter. Reviewer note: a
	// future feature request to "let the operator pass --mode"
	// MUST be rejected; AC-20 depends on this.
	if _, err := tx.ExecContext(ctx,
		`UPDATE provider_visibility
		    SET mode = 'bucketed', updated_at = now()
		  WHERE provider_id = $1`,
		*providerID,
	); err != nil {
		fmt.Fprintf(stderr, "visibility revert: update: %v\n", err)
		return 1
	}

	actor := resolvePrincipal("")
	// `actor_kind` is hardcoded to 'operator' below — the column
	// is the AC-20 invariant axis (new_mode='exact' AND
	// actor_kind='operator' MUST = 0 ∀ rows).
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO provider_visibility_audit (
			provider_id, old_mode, new_mode, actor_kind, actor_id
		) VALUES ($1, $2, 'bucketed', 'operator', $3)`,
		*providerID, oldMode, actor,
	); err != nil {
		fmt.Fprintf(stderr, "visibility revert: audit insert: %v\n", err)
		return 1
	}

	if err := tx.Commit(); err != nil {
		fmt.Fprintf(stderr, "visibility revert: commit: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "reverted provider_id=%s old_mode=%s new_mode=bucketed actor=%s reason=%s\n",
		*providerID, oldMode, actor, *reason)
	return 0
}
