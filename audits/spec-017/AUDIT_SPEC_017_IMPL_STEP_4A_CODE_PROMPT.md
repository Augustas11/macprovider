# AUDIT_SPEC_017_IMPL_STEP_4A — Code lane

Operator-paste prompt to audit the **Step 4.A IMPL code** (partner-key CLI
+ operator visibility-revert subcommand) under PR `Augustas11/macprovider#173`
from the implementation-correctness lens.

Audit target is the **Step 4.A implementation diff** layered on top of the
converged Step 3 (HEAD `2b27256` or later). SPEC-017 v0.1.8 is LOCKED;
`BUILD_SPEC_017_IMPL_PROMPT.md` is the controlling kickoff;
`specs/SPEC-017-IMPL-STEP_3-r8-convergence.md` is the Step 3 convergence
record.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred and
acknowledged in the convergence file.

Each round writes
`specs/SPEC-017-IMPL-STEP_4A-code-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.A IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the IMPLEMENTATION-CORRECTNESS (CODE) lens.

Step 4.A scope: see the ARCH-lane prompt for the full scope
recital — `coordinator partner-keys {issue,revoke,list}` +
`coordinator visibility revert` subcommands.

Output: specs/SPEC-017-IMPL-STEP_4A-code-rM-audit.md (round M;
fresh file per round, never append).

Severity model:
- CRITICAL — a defect that would cause an AC failure on the
  locked SPEC harness, a CLI panic on benign operator input,
  a wrong SQL column write (missing/swapped/extra columns),
  a missing transaction boundary on the issue flow that could
  leave a token printed-but-not-INSERTed (or INSERTed-but-not-
  printed), or a token leak on any error path.
- HIGH — flag parsing bug, off-by-one in token length / prefix
  slice, lib mismatch (e.g. `base64.StdEncoding` instead of
  `base64.RawURLEncoding`), wrong sha256 input (raw bytes vs
  hex-encoded), `rotated_from_id` written as 0 instead of NULL
  when --rotate-from absent, `created_by` default falls through
  to empty string, `prefix` slice indexes by byte vs rune (raw
  token is ASCII so equivalent, but a UTF-8 slice surface
  inviting future bugs is still HIGH), error wrapping that
  exposes the raw token in the error string.
- MEDIUM — non-essential CLI ergonomics gap (no usage on
  unknown subcommand), incomplete close on the admin DSN,
  partial test coverage for one of the locked AC variants.
- LOW — polish / quality / non-blocking.
- INFO — positive observations or evidence captured.

Required reading (same as ARCH lane).

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Subcommand dispatch** — `os.Args` parsing distinguishes
   `coordinator <flags>` (daemon mode) from `coordinator
   partner-keys issue [...]` and `coordinator visibility
   revert [...]` (CLI mode) without false-positives or
   false-negatives. `--version` and `--config` continue to
   work for daemon mode. Unknown subcommand prints usage to
   stderr + exits non-zero (NOT silent fall-through to
   daemon mode).

B. **`flag.NewFlagSet` per subcommand** — each subcommand
   uses its own FlagSet with `flag.ExitOnError` (or
   `flag.ContinueOnError` + explicit handling), so a typo
   in `--label` doesn't leak the daemon's `-config` flag.
   Repeatable `--allowed-origin` uses a `flag.Value` type
   or `flag.Var` with explicit append semantics — NOT
   `flag.String` (which would only retain the last value).

C. **CSPRNG usage** — `crypto/rand.Read([]byte, 32)` with
   explicit error check (`crypto/rand.Read` returns
   `(n, err)`; checking err is mandatory — `math/rand` would
   pass a depguard sweep but is a CRITICAL leak).

D. **base64url encoding** — `base64.RawURLEncoding.EncodeToString`
   on the 32 random bytes produces a 43-char string with no
   padding. The IMPL MUST NOT use `base64.URLEncoding`
   (padded) or `base64.StdEncoding`. A test assertion
   `len(body) == 43 && /^[A-Za-z0-9_-]{43}$/` MUST pass.

E. **Token assembly + sha256** — raw token = "mpk_" + body
   (47 chars). `sha256.Sum256([]byte(rawToken))` — input is
   the UTF-8 bytes of the literal raw token string, NOT the
   raw 32-byte random source, NOT the hex-encoded form.
   `prefix` column = `rawToken[:8]` (always `"mpk_" + body[:4]`).

F. **INSERT statement** — exact column list per §5.4.1 v0.1.8
   (no `rate_limit_burst`). `created_by` defaults to a
   non-empty principal when --created-by absent: prefer
   `$USER@$(hostname)`; if `$USER` unset, `"unknown@<hostname>"`;
   if `os.Hostname()` errors, `"unknown@unknown"`. INSERT
   uses a single `*sql.DB.ExecContext` (or QueryRowContext +
   RETURNING) on a connection from the admin DSN. On INSERT
   error, the raw token MUST NOT be printed and the error
   MUST NOT include the raw token / body / hash.

G. **Print exactly once on success** — `fmt.Println(rawToken)`
   (or equivalent) AFTER the INSERT succeeds. NOT before.
   If the INSERT succeeds but the print fails, that is
   acceptable — the operator can run `partner-keys list`
   to discover the inserted row's id+prefix and revoke it.
   If the print happens before the INSERT, the operator
   may deliver an unbound token to the partner — CRITICAL.

H. **Rotation path** — `--rotate-from <id>` populates the
   `rotated_from_id` column with the parsed BIGINT. The CLI
   MUST verify the row exists BEFORE inserting (a clean
   error message is better than a foreign-key violation
   bubbling up). The CLI MUST NOT auto-revoke the predecessor.

I. **Revoke + list** — `revoke --id 99999` (non-existent)
   returns a CLEAN error with exit code 1, NOT a panic.
   Revoke writes `revoked_at = now()` AND `revoked_reason =
   <text>` in a single UPDATE. List query returns id, label,
   prefix, created_at, revoked_at, last_used_at — and
   nothing else; `token_hash` MUST NOT be in the SELECT
   column list (even if redacted before print — it would
   land in the connection-pool buffer + driver logs).

J. **Visibility revert** — UPDATE
   `provider_visibility SET mode='bucketed', updated_at=now()
   WHERE provider_id=$1`. INSERT into `provider_visibility_audit`
   with old_mode (looked up via the same transaction; SELECT
   FOR UPDATE the old row), new_mode='bucketed',
   actor_kind='operator', actor_id=<operator-principal>,
   changed_at=now(). The CLI MUST refuse a `--mode exact` /
   `--exact` flag (preferably the flag doesn't exist; if
   present for symmetry, MUST hard-reject with a clear error).

K. **Operator DSN open + close** — opened with
   `sql.Open("postgres", dsn)` (depguard preamble allows
   `lib/pq` per Step 1; pgx would require a SPEC v0.2 round).
   `db.Close()` is deferred at subcommand entry. The DSN
   string MUST NOT be logged on error paths.

L. **Error wrapping hygiene** — `fmt.Errorf("...: %w", err)`
   patterns MUST NOT include the raw token in the format
   string. Test assertion: feed an INSERT-failure-injected
   admin DSN and assert the resulting stderr contains
   neither the raw token nor the random 43-char body
   substring.

M. **Tests** — TableTest of CLI invocations using
   `exec.Command(coordinatorBinary, ...)` against a
   testcontainers-go Postgres + admin DSN. Capture stdout,
   stderr, and (where the IMPL emits structured logs to a
   file) the structured-log file. Assert:
   1. AC-17 literal command: exactly one 47-char token
      starting `mpk_`, body `^[A-Za-z0-9_-]{43}$`, row in
      partner_keys with non-empty `created_by`.
   2. Explicit `--created-by ops@example.com`: row's
      created_by is exactly that.
   3. RFC 6454 idempotency 3 cases.
   4. Rotation overlap: A+B both work; revoke A → A
      rejected, B works.
   5. `revoke --id 99999`: clean exit 1, no panic.
   6. `--burst 100`: clean exit non-zero with a
      "unknown flag --burst" or equivalent.
   7. Stdout/stderr scan: raw token does NOT appear
      ANYWHERE except the single print at issue time;
      `token_hash` does NOT appear; the 43-char random
      body substring does NOT appear in stderr.

Validation steps (same as ARCH lane).

Output structure (one document per round, fresh file):

```
# SPEC-017 IMPL Step 4.A — Code Audit Round M

Branch: `impl/spec-017-step-1`
HEAD audited: `<sha>` (`<commit subject>`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: CODE
Prior rounds checked:
- specs/SPEC-017-IMPL-STEP_4A-code-r1-audit.md  (...)

Verdict: <READY TO LOCK | NOT READY TO LOCK> —
0 CRITICAL + N HIGH + M MEDIUM + L LOW + I INFO

## Validation evidence
- <list of commands run + outcomes>

## Category Verdicts
A. ...
...
M. ...

## Findings
### CRITICAL / HIGH / MEDIUM / LOW / INFO
... (same shape as ARCH lane)

## Round-(M-1) Closure Checks
- ...

## Final Verdict
READY TO LOCK: YES/NO
Blocking count: CRITICAL/HIGH/MEDIUM/LOW/INFO
```

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
