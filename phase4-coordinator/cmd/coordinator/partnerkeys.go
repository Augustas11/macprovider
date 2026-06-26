package main

// SPEC-017 v0.1.8 Step 4.A — partner-key CLI.
//
// Invoked as:
//
//	coordinator partner-keys issue   --label X [--allowed-origin O ...] [--rpm N] [--created-by P] [--rotate-from ID]
//	coordinator partner-keys revoke  --id N --reason "..."
//	coordinator partner-keys list
//
// All three subcommands open the OPERATOR ADMIN DSN
// (`cfg.Stats.PartnerKeysAdminDSN`) — a separate Postgres role
// outside the four runtime roles per BUILD §C.3 / SPEC §5.4.1.
// The daemon process MUST NOT open this DSN (it owns
// INSERT/UPDATE/DELETE rights on `partner_keys` — handing those
// to a long-running HTTP listener is the explicit non-goal of
// the role-split).
//
// Security invariants enforced here (SECURITY-lane round-1
// scope):
//
//   - raw token escapes to stdout EXACTLY ONCE at issue time
//     and nowhere else; structured logs / stderr / error wraps
//     never carry the token, body, or hash;
//   - random source is `crypto/rand.Read` with error check;
//     no `math/rand` import in this file or `visibility.go`;
//   - --allowed-origin values are validated via the SAME
//     `stats.NormalizeOrigin` the request-path handler calls
//     (no parallel reimplementation — SECURITY lane H).

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/stats"

	_ "github.com/lib/pq"
)

// adminDSNEnv is the environment-variable override for the
// admin DSN. Per SPEC §5.4.1 + BUILD §C.3, the CLI MAY read the
// admin DSN from env at invocation time (the daemon-side YAML
// is the other authoritative source). Env takes priority over
// YAML so that operators can `export COORDINATOR_PARTNER_KEYS_ADMIN_DSN=...`
// in a one-off shell and not have to edit `coordinator.yaml`
// just to issue a key.
const adminDSNEnv = "COORDINATOR_PARTNER_KEYS_ADMIN_DSN"

// resolveAdminDSN picks the admin DSN per the documented
// priority order: --admin-dsn flag > env > YAML. Returns
// (dsn, source-tag, ok). `source-tag` is "flag" / "env" /
// "config-file" and is used in error messages so the operator
// knows which input to fix.
//
// When source is "config-file", the CLI loads the daemon YAML
// for the sole purpose of reading
// `cfg.Stats.PartnerKeysAdminDSN`. If the YAML fails Validate
// (e.g. auth.operator_key unset — daemon-side requirement that
// is irrelevant to the CLI), we fall through to a parse-only
// path that yamls into a Stats-only shape. This means an
// operator can ship a minimal `partnerkeys.yaml` containing
// just the `stats:` block to drive the CLI without holding the
// full daemon contract.
func resolveAdminDSN(flagDSN, configPath string) (string, string, error) {
	if s := strings.TrimSpace(flagDSN); s != "" {
		return s, "flag", nil
	}
	if s := strings.TrimSpace(os.Getenv(adminDSNEnv)); s != "" {
		return s, "env", nil
	}
	if strings.TrimSpace(configPath) == "" {
		return "", "", errors.New("no admin DSN: pass --admin-dsn, set " + adminDSNEnv + ", or --config <yaml>")
	}
	// Try full config Load first — happy path on a coordinator
	// host that already has a complete coordinator.yaml.
	if cfg, err := config.Load(configPath); err == nil {
		if cfg.Stats.PartnerKeysAdminDSN != "" {
			return cfg.Stats.PartnerKeysAdminDSN, "config-file", nil
		}
		return "", "", fmt.Errorf("stats.partner_keys_admin_dsn empty in %s", configPath)
	}
	// Fall back to parse-only — operator pointed --config at a
	// trimmed file that contains just the stats block.
	dsn, err := parseAdminDSNFromYAML(configPath)
	if err != nil {
		return "", "", fmt.Errorf("read admin DSN from %s: %w", configPath, err)
	}
	if dsn == "" {
		return "", "", fmt.Errorf("stats.partner_keys_admin_dsn empty in %s", configPath)
	}
	return dsn, "config-file", nil
}

// runPartnerKeys is the subcommand dispatcher for
// `coordinator partner-keys <verb>`. Returns the process exit
// code (0 = success, 1 = runtime error, 2 = config / usage
// error).
func runPartnerKeys(args []string) int {
	if len(args) < 1 {
		partnerKeysUsage(os.Stderr)
		return 2
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "issue":
		return runPartnerKeysIssue(rest, os.Stdout, os.Stderr)
	case "revoke":
		return runPartnerKeysRevoke(rest, os.Stdout, os.Stderr)
	case "list":
		return runPartnerKeysList(rest, os.Stdout, os.Stderr)
	default:
		fmt.Fprintf(os.Stderr, "unknown partner-keys verb %q\n", verb)
		partnerKeysUsage(os.Stderr)
		return 2
	}
}

func partnerKeysUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: coordinator partner-keys <issue|revoke|list> [flags]")
	fmt.Fprintln(w, "  issue   --label TEXT [--allowed-origin URL ...] [--rpm INT] [--created-by TEXT] [--rotate-from ID]")
	fmt.Fprintln(w, "  revoke  --id INT --reason TEXT")
	fmt.Fprintln(w, "  list")
	fmt.Fprintln(w, "All verbs read --config (default coordinator.yaml) for stats.partner_keys_admin_dsn.")
}

// originsFlag is a flag.Value that supports `--allowed-origin`
// being passed multiple times, each value appended to the
// underlying slice. flag.String would only retain the last
// value passed.
type originsFlag struct{ values []string }

func (f *originsFlag) String() string     { return strings.Join(f.values, ",") }
func (f *originsFlag) Set(v string) error { f.values = append(f.values, v); return nil }

// runPartnerKeysIssue implements `coordinator partner-keys issue`.
//
// Flow (SPEC §5.4.2):
//
//  1. Validate flags (incl. RFC 6454 idempotency on --allowed-origin).
//  2. Generate 32 CSPRNG bytes → base64url(43) → "mpk_"+body.
//  3. Hash with sha256(raw_utf8_bytes).
//  4. If --rotate-from passed, verify predecessor row exists.
//  5. INSERT new row with all SPEC-locked columns (NO
//     the per-key burst column dropped in v0.1.8).
//  6. ONLY after the INSERT succeeds, print the raw token to
//     the operator OUT-OF-BAND sink (stdout when invoked from
//     a TTY; --token-out FILE when stdout is journal-captured
//     per round-1 SECURITY H1).
//
// The "print after INSERT" ordering is load-bearing — printing
// before the INSERT would let an operator deliver an unbound
// token to a partner if the INSERT then failed.
func runPartnerKeysIssue(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("partner-keys issue", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config (read for stats.partner_keys_admin_dsn)")
	adminDSNFlag := fs.String("admin-dsn", "", "operator admin DSN (overrides --config and "+adminDSNEnv+")")
	label := fs.String("label", "", "human-readable label (required)")
	rpm := fs.Int("rpm", 600, "rate_limit_rpm")
	createdBy := fs.String("created-by", "", "operator principal (defaults to $USER@hostname)")
	rotateFrom := fs.Int64("rotate-from", 0, "predecessor partner_keys.id (rotation flow)")
	tokenOut := fs.String("token-out", "", "write the raw mpk_* token to this file path with mode 0600 instead of stdout (mandatory when stdout is captured by systemd-journal — round-1 SECURITY H1)")
	var origins originsFlag
	fs.Var(&origins, "allowed-origin", "RFC 6454 allowed Origin (repeatable)")
	if err := fs.Parse(args); err != nil {
		// flag.ContinueOnError already printed the error to fs.SetOutput.
		return 2
	}
	if *label == "" {
		fmt.Fprintln(stderr, "partner-keys issue: --label is required")
		return 2
	}
	if *rpm <= 0 {
		fmt.Fprintln(stderr, "partner-keys issue: --rpm must be positive")
		return 2
	}

	// SECURITY H: validate each --allowed-origin via the SAME
	// normalizer the handler uses. A non-canonical value MUST be
	// rejected with a clear error and NO row inserted (idempotency
	// check — the same value re-issued by an operator next quarter
	// against the same key set MUST canonicalize to itself).
	canonicalOrigins := make([]string, 0, len(origins.values))
	for _, raw := range origins.values {
		norm, ok := stats.NormalizeOrigin(raw)
		if !ok {
			fmt.Fprintf(stderr, "partner-keys issue: --allowed-origin %q is malformed (not a valid http/https Origin)\n", raw)
			return 2
		}
		if norm != raw {
			fmt.Fprintf(stderr, "partner-keys issue: --allowed-origin %q is not canonical (RFC 6454 lowercase scheme/host, IDN→Punycode, strip default ports, no path/query/fragment/trailing-slash); re-run with %q\n", raw, norm)
			return 2
		}
		canonicalOrigins = append(canonicalOrigins, norm)
	}

	dsn, _, err := resolveAdminDSN(*adminDSNFlag, *configPath)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys issue: %v\n", err)
		return 2
	}
	principal := resolvePrincipal(*createdBy)

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		// lib/pq's sql.Open does not contact the server; the
		// admin DSN string is NOT included in this error string
		// (Open returns format errors, not connection errors).
		fmt.Fprintf(stderr, "partner-keys issue: open admin db: %v\n", err)
		return 1
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if *rotateFrom > 0 {
		var exists bool
		err := db.QueryRowContext(ctx,
			`SELECT EXISTS (SELECT 1 FROM partner_keys WHERE id = $1)`,
			*rotateFrom,
		).Scan(&exists)
		if err != nil {
			fmt.Fprintf(stderr, "partner-keys issue: rotate-from lookup: %v\n", err)
			return 1
		}
		if !exists {
			fmt.Fprintf(stderr, "partner-keys issue: --rotate-from %d does not exist\n", *rotateFrom)
			return 2
		}
	}

	rawToken, tokenHash, err := generatePartnerToken()
	if err != nil {
		// Defensive: if CSPRNG fails the IMPL aborts WITHOUT
		// printing anything that could be a partial token. The
		// error string MUST NOT carry the partial bytes.
		fmt.Fprintln(stderr, "partner-keys issue: token generation failed (CSPRNG error)")
		return 1
	}

	var rotatedFrom sql.NullInt64
	if *rotateFrom > 0 {
		rotatedFrom = sql.NullInt64{Int64: *rotateFrom, Valid: true}
	}

	const insertQ = `
INSERT INTO partner_keys (
    label, token_hash, token_hash_alg, prefix,
    allowed_origins, rate_limit_rpm, created_by, rotated_from_id
) VALUES ($1, $2, 'sha256', $3, $4, $5, $6, $7)
RETURNING id, created_at`

	prefix := rawToken[:8]
	var id int64
	var createdAt time.Time
	err = db.QueryRowContext(ctx, insertQ,
		*label,
		tokenHash[:],
		prefix,
		pqStringArrayLiteral(canonicalOrigins),
		*rpm,
		principal,
		rotatedFrom,
	).Scan(&id, &createdAt)
	if err != nil {
		// The raw token NEVER appears in this error path. The
		// hash bytes don't appear either — wrapping `err` from
		// lib/pq surfaces the SQL constraint text, not the
		// parameters.
		fmt.Fprintf(stderr, "partner-keys issue: insert failed: %v\n", err)
		return 1
	}

	// Step 4.C — locked §8.5 event for a successful issuance.
	// Fields per BUILD §2 Step 4.C: partner_keys.id, label,
	// created_by, rotated_from_id_or_null. NEVER the raw token,
	// 43-char body, token_hash bytes, OR the `prefix` substring
	// (round-1 ARCH H2 / SECURITY H1 — prefix is operator-
	// permitted in §5.4.5 list output but is OUTSIDE the
	// narrower structured-event taxonomy). The event lands on
	// stderr-bound zerolog so it survives JOURNAL_STREAM-aware
	// stdout suppression (operator still gets the audit trail).
	emitPartnerKeyEvent(stderr, "stats_partner_key_issued", map[string]any{
		"id":              id,
		"label":           *label,
		"created_by":      principal,
		"rotated_from_id": nullInt64String(rotatedFrom),
	})

	// Print metadata first (operator-facing diagnostic). The
	// metadata is journal-safe — contains only label / id /
	// prefix / created_by / rotated_from_id / created_at.
	fmt.Fprintf(stdout, "id=%d label=%s prefix=%s created_by=%s rotated_from_id=%s created_at=%s\n",
		id, *label, prefix, principal, nullInt64String(rotatedFrom), createdAt.UTC().Format(time.RFC3339))

	// Round-1 SECURITY H1: if stdout is captured by systemd-
	// journal (JOURNAL_STREAM env set by systemd-run / systemd
	// service units), printing the raw token to stdout would
	// turn the one-time secret into a durable journal entry.
	// In that case the IMPL refuses to print to stdout and
	// requires --token-out FILE (file is opened O_CREAT|O_EXCL,
	// mode 0600).
	if *tokenOut != "" {
		if err := writeTokenFile(*tokenOut, rawToken); err != nil {
			fmt.Fprintf(stderr, "partner-keys issue: write token file: %v\n", err)
			// The row IS already inserted — we tell the operator
			// to revoke it before retrying so a leaked-but-unused
			// row doesn't accumulate.
			fmt.Fprintf(stderr, "partner-keys issue: token file write failed AFTER INSERT; the row id=%d is now orphaned. Revoke it with `coordinator partner-keys revoke --id %d --reason \"file-write-failed\"` before re-issuing.\n", id, id)
			return 1
		}
		fmt.Fprintf(stdout, "token written to %s (mode 0600)\n", *tokenOut)
		return 0
	}
	if os.Getenv("JOURNAL_STREAM") != "" {
		fmt.Fprintln(stderr, "partner-keys issue: refusing to print raw token to stdout because JOURNAL_STREAM is set (systemd-journal would capture the token into a durable log).")
		fmt.Fprintln(stderr, "Re-run with --token-out /path/to/secret.token (0600) to write the token to an operator-owned file instead.")
		fmt.Fprintf(stderr, "partner-keys issue: row id=%d was INSERTed but the raw token was suppressed. Revoke with `coordinator partner-keys revoke --id %d --reason \"journal-stream-suppressed\"` and re-issue from an interactive shell or with --token-out.\n", id, id)
		return 1
	}
	fmt.Fprintln(stdout, rawToken)
	return 0
}

// writeTokenFile writes the raw token to the named path with
// O_CREAT|O_EXCL|O_WRONLY + mode 0600 so an existing file at
// the same path is NOT clobbered (the operator gets a clean
// EEXIST error). The trailing newline matches the stdout
// shape for easy `cat`-paste.
func writeTokenFile(path, raw string) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.WriteString(raw + "\n"); err != nil {
		return err
	}
	return f.Sync()
}

// runPartnerKeysRevoke implements `coordinator partner-keys
// revoke --id N --reason TEXT`.
func runPartnerKeysRevoke(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("partner-keys revoke", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config")
	adminDSNFlag := fs.String("admin-dsn", "", "operator admin DSN (overrides --config and "+adminDSNEnv+")")
	id := fs.Int64("id", 0, "partner_keys.id to revoke")
	reason := fs.String("reason", "", "revocation reason (required, recorded in revoked_reason)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *id <= 0 {
		fmt.Fprintln(stderr, "partner-keys revoke: --id must be > 0")
		return 2
	}
	if *reason == "" {
		fmt.Fprintln(stderr, "partner-keys revoke: --reason is required")
		return 2
	}
	dsn, _, err := resolveAdminDSN(*adminDSNFlag, *configPath)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys revoke: %v\n", err)
		return 2
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys revoke: open admin db: %v\n", err)
		return 1
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Idempotent revoke: setting revoked_at on an already-revoked
	// row would overwrite the existing timestamp. Refuse if
	// revoked_at IS NOT NULL — surface a clean message so the
	// operator knows the prior reason isn't being clobbered.
	res, err := db.ExecContext(ctx,
		`UPDATE partner_keys
		    SET revoked_at = now(), revoked_reason = $1
		  WHERE id = $2 AND revoked_at IS NULL`,
		*reason, *id,
	)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys revoke: update: %v\n", err)
		return 1
	}
	n, err := res.RowsAffected()
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys revoke: rows affected: %v\n", err)
		return 1
	}
	if n == 0 {
		// Distinguish "no row" from "already revoked" with a
		// follow-up SELECT — cheap and the diagnostic is
		// noticeably better.
		var alreadyRevoked sql.NullTime
		err := db.QueryRowContext(ctx,
			`SELECT revoked_at FROM partner_keys WHERE id = $1`, *id,
		).Scan(&alreadyRevoked)
		if errors.Is(err, sql.ErrNoRows) {
			fmt.Fprintf(stderr, "partner-keys revoke: no row with id=%d\n", *id)
			return 1
		}
		if err != nil {
			fmt.Fprintf(stderr, "partner-keys revoke: status lookup: %v\n", err)
			return 1
		}
		if alreadyRevoked.Valid {
			fmt.Fprintf(stderr, "partner-keys revoke: id=%d was already revoked at %s\n",
				*id, alreadyRevoked.Time.UTC().Format(time.RFC3339))
			return 1
		}
		fmt.Fprintf(stderr, "partner-keys revoke: id=%d UPDATE matched 0 rows for an unknown reason\n", *id)
		return 1
	}
	// Step 4.C — locked §8.5 event for a successful revoke.
	// Fields per BUILD §2 Step 4.C: partner_keys.id, reason, actor.
	actor := resolvePrincipal("")
	emitPartnerKeyEvent(stderr, "stats_partner_key_revoked", map[string]any{
		"id":     *id,
		"reason": *reason,
		"actor":  actor,
	})

	fmt.Fprintf(stdout, "revoked id=%d reason=%s\n", *id, *reason)
	return 0
}

// emitPartnerKeyEvent writes a JSON-shaped structured event line
// to the operator-facing log sink (stderr) without dragging in
// zerolog (the CLI subcommands shouldn't pay zerolog import cost
// + interface ceremony for two emit sites). The minimal line is
// `{"event":"...","ts":"<RFC3339>",...}` so log shippers can
// pattern-match the same way they do for daemon-side events.
//
// Field set must NEVER contain the raw token, 43-char body, or
// token_hash bytes — see partnerkeys.go callers for the closed
// per-event field map.
func emitPartnerKeyEvent(w io.Writer, event string, fields map[string]any) {
	fields["event"] = event
	fields["ts"] = time.Now().UTC().Format(time.RFC3339Nano)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(fields)
}

// runPartnerKeysList implements `coordinator partner-keys
// list`. The SELECT column list is pinned to the locked
// §5.4.5 set: id, label, prefix, created_at, revoked_at,
// last_used_at. `token_hash` MUST stay out (driver/pool log
// risk); `rotated_from_id` is intentionally absent too
// (round-1 ARCH/CODE M1 — extra column outside the locked
// list surface; rotation lineage is surfaced at issue time
// in the metadata line, NOT in `list`).
func runPartnerKeysList(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("partner-keys list", flag.ContinueOnError)
	fs.SetOutput(stderr)
	configPath := fs.String("config", "coordinator.yaml", "path to coordinator YAML config")
	adminDSNFlag := fs.String("admin-dsn", "", "operator admin DSN (overrides --config and "+adminDSNEnv+")")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	dsn, _, err := resolveAdminDSN(*adminDSNFlag, *configPath)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys list: %v\n", err)
		return 2
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys list: open admin db: %v\n", err)
		return 1
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := db.QueryContext(ctx, `
SELECT id, label, prefix, created_at, revoked_at, last_used_at
  FROM partner_keys
 ORDER BY id`)
	if err != nil {
		fmt.Fprintf(stderr, "partner-keys list: query: %v\n", err)
		return 1
	}
	defer rows.Close()
	fmt.Fprintln(stdout, "id\tlabel\tprefix\tcreated_at\trevoked_at\tlast_used_at")
	for rows.Next() {
		var (
			id         int64
			label      string
			prefix     string
			createdAt  time.Time
			revokedAt  sql.NullTime
			lastUsedAt sql.NullTime
		)
		if err := rows.Scan(&id, &label, &prefix, &createdAt, &revokedAt, &lastUsedAt); err != nil {
			fmt.Fprintf(stderr, "partner-keys list: scan: %v\n", err)
			return 1
		}
		fmt.Fprintf(stdout, "%d\t%s\t%s\t%s\t%s\t%s\n",
			id, label, prefix,
			createdAt.UTC().Format(time.RFC3339),
			nullTimeString(revokedAt),
			nullTimeString(lastUsedAt),
		)
	}
	if err := rows.Err(); err != nil {
		fmt.Fprintf(stderr, "partner-keys list: iterate: %v\n", err)
		return 1
	}
	return 0
}

// generatePartnerToken returns ("mpk_<body43>", sha256(raw_utf8))
// per SPEC §5.4.2 token-generation pipeline.
//
// 32 CSPRNG bytes → base64url(no pad) → 43 chars → prepended
// with "mpk_" → 47 chars total.
//
// Both return values are sensitive; callers MUST NOT log either.
func generatePartnerToken() (string, [32]byte, error) {
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", [32]byte{}, err
	}
	body := base64.RawURLEncoding.EncodeToString(random[:])
	if len(body) != 43 {
		// base64.RawURLEncoding of 32 bytes is mathematically
		// exactly 43 chars (ceil(32*4/3) = 43). A different
		// length means the standard library returned something
		// unexpected — bail rather than emit a non-conforming
		// token.
		return "", [32]byte{}, errors.New("base64 length invariant violated")
	}
	raw := "mpk_" + body
	hash := sha256.Sum256([]byte(raw))
	return raw, hash, nil
}

// resolvePrincipal returns the `created_by` / `actor_id` value
// per the §5.4.2 default rule:
//   - --created-by explicit non-empty → use as-is;
//   - else $USER@$(hostname);
//   - else "unknown@<hostname>";
//   - else "unknown@unknown".
//
// AC-17 requires `created_by` to be NOT NULL and non-empty.
//
// Round-1 ARCH M2: deliberately NO os/user.Current fallback —
// the locked SPEC §5.4.2 rule is "$USER unset → 'unknown'";
// adding a third behavior would introduce environment-dependent
// drift (e.g. UID lookups via NSS) that the audit-loop SHOULD
// NOT have to ratify.
func resolvePrincipal(explicit string) string {
	if strings.TrimSpace(explicit) != "" {
		return strings.TrimSpace(explicit)
	}
	userPart := "unknown"
	if u := strings.TrimSpace(os.Getenv("USER")); u != "" {
		userPart = u
	}
	hostPart := "unknown"
	if h, err := os.Hostname(); err == nil && strings.TrimSpace(h) != "" {
		hostPart = strings.TrimSpace(h)
	}
	return userPart + "@" + hostPart
}

// pqStringArrayLiteral marshals a Go string slice into a
// Postgres `text[]` array literal. We deliberately do NOT
// import `github.com/lib/pq.Array` because the same module
// version is already pinned by `internal/stats/store/pqarray.go`
// and we want a single, audit-trivial encoding helper local to
// the CLI (no driver-level surprises on operator-supplied
// strings — origins are pre-validated by NormalizeOrigin which
// rejects every char that would need escaping here).
//
// For Step 4.A, since origins are already restricted to
// `^[a-z0-9.-]+(:[0-9]+)?` (RFC 6454 ASCII serialization), no
// escaping is required — but the function is defensive
// regardless: a double-quote or backslash would be properly
// escaped.
func pqStringArrayLiteral(values []string) string {
	if len(values) == 0 {
		return "{}"
	}
	var b strings.Builder
	b.WriteByte('{')
	for i, v := range values {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('"')
		for _, r := range v {
			switch r {
			case '"', '\\':
				b.WriteByte('\\')
			}
			b.WriteRune(r)
		}
		b.WriteByte('"')
	}
	b.WriteByte('}')
	return b.String()
}

func nullTimeString(n sql.NullTime) string {
	if !n.Valid {
		return ""
	}
	return n.Time.UTC().Format(time.RFC3339)
}

func nullInt64String(n sql.NullInt64) string {
	if !n.Valid {
		return ""
	}
	return fmt.Sprintf("%d", n.Int64)
}
