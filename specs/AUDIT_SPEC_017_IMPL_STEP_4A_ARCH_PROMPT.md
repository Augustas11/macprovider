# AUDIT_SPEC_017_IMPL_STEP_4A — Architecture lane

Operator-paste prompt to audit the **Step 4.A IMPL code** (partner-key CLI
+ operator visibility-revert subcommand) under PR `Augustas11/macprovider#173`
from the architecture lens.

Audit target is the **Step 4.A implementation diff** layered on top of the
converged Step 3 (HEAD `2b27256` or later). SPEC-017 v0.1.8 is LOCKED;
`BUILD_SPEC_017_IMPL_PROMPT.md` is the controlling kickoff;
`specs/SPEC-017-IMPL-STEP_3-r8-convergence.md` is the Step 3 convergence
record.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred and
acknowledged in the convergence file.

Each round writes
`specs/SPEC-017-IMPL-STEP_4A-arch-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.A IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the ARCHITECTURE lens.

Step 4.A scope:
- `coordinator partner-keys issue` subcommand (§5.4.2 + §5.4.4 rotation)
- `coordinator partner-keys revoke` subcommand (§5.4.5)
- `coordinator partner-keys list` subcommand (§5.4.5 — never prints
  raw token; columns: id, label, prefix, created_at, revoked_at,
  last_used_at)
- `coordinator visibility revert` subcommand (§6.5 operator-only
  bucketed-revert path; MUST refuse mode='exact')
- The subcommand dispatcher addition in `cmd/coordinator/main.go`
  (or a dedicated sibling `cmd/` package — IMPL author's choice
  provided the SPEC's literal `coordinator partner-keys issue`
  invocation works).

Output: specs/SPEC-017-IMPL-STEP_4A-arch-rM-audit.md (round M;
fresh file per round, never append).

Severity model:
- CRITICAL — a CLI flow breaks a LOCKED SPEC invariant: token-
  hash algorithm wrong; raw token escapes to any log/journal/
  structured event; `created_by` populated as empty/NULL violating
  §5.4.1 NOT NULL; `rotated_from_id` ignored when --rotate-from
  is passed; visibility-revert writes mode='exact' or omits the
  audit row; CLI opens any of the four RUNTIME DSNs
  (stats_reader, stats_rollup, provider_portal, partner_keys_writer)
  for the INSERT/UPDATE instead of the dedicated admin DSN per
  BUILD §C.3 / SPEC §5.4.1.
- HIGH — would force a v0.2 fix-round within the first month or
  structurally misaligns Step 4.A with Step 1 schema or Step 3
  handler surface: `--burst` flag silently accepted; `--allowed-
  origin` validation skips RFC 6454 idempotency; default
  `--created-by` is empty/missing; subcommand dispatcher swallows
  daemon-mode flags or vice versa; list subcommand surfaces
  `token_hash` (any subset of bytes); operator DSN config is
  read but never reached at INSERT time.
- MEDIUM — two conforming Step 4.A sessions could resolve a
  CLI/DSN decision differently; missing structural guidance bleeds
  into Step 4.B/C audits.
- LOW — polish / quality / non-blocking.
- INFO — positive observations or evidence captured during
  verification.

Required reading (before writing findings):
- `specs/SPEC-017-network-stats-api.md` v0.1.8 sections
  5.4.1 (partner_keys schema), 5.4.2 (issue flow), 5.4.4 (rotation),
  5.4.5 (revoke + list), 6.5 (provider_visibility_audit), 6.6.2
  (partner-key disclosure obligation), 7.2.1 (role grants),
  7.2.4 (last_used_at default-off resolution).
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 2 Step 4.A
  (the entire "4.A Partner-key CLI lifecycle" block) plus §C.3
  CLI/admin DSN block at line ~184, plus the AC-to-step matrix.
- `specs/SPEC-017-IMPL-STEP_3-r8-convergence.md` (the
  cumulative Step 3 deliverables Step 4.A composes against).
- `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql`
  (the LOCKED `partner_keys` + `provider_visibility{,_audit}`
  table shapes).
- All ARCH r1..r(M-1) audit files for Step 4.A (close-out checks
  in §"Round-(M-1) Closure Checks").
- Step 4.A implementation diff: `git diff 2b27256..HEAD --
  phase4-coordinator/`. Focus on
  `cmd/coordinator/main.go` (subcommand dispatch),
  any new `cmd/coordinator/partner_keys*.go` /
  `cmd/coordinator/visibility*.go`, and
  `internal/stats/store/` admin-side helpers (if any).

Audit categories (sweep ALL — empty findings still record
evidence):

A. **CLI surface contract** — `coordinator partner-keys issue`
   accepts EXACTLY `--label`, `--allowed-origin` (repeatable),
   `--rpm`, `--created-by` (optional), `--rotate-from`. The
   `--burst` flag MUST be absent / produce a clear error (v0.1.8
   removed `rate_limit_burst`). Unknown flags rejected.
   `coordinator partner-keys revoke` accepts `--id` + `--reason`.
   `coordinator partner-keys list` outputs id/label/prefix/
   created_at/revoked_at/last_used_at columns only (never raw
   token, never `token_hash`). `coordinator visibility revert`
   accepts `--id` + `--reason` and REFUSES any flag that would
   set mode=exact (e.g. an `--exact` flag, or a `visibility exact`
   subcommand, MUST NOT exist OR MUST hard-reject with a clear
   error per BUILD §2 Step 4.C).

B. **Token-generation pipeline** — 32 cryptographically random
   bytes from the system CSPRNG (`crypto/rand.Read` — NOT
   `math/rand`); unpadded base64url per RFC 4648 §5
   (`base64.RawURLEncoding`); 43-char body; prefixed with `mpk_`
   → 47-char raw token; sha256(raw_utf8_bytes); `prefix` column
   populated with first 8 characters of raw token (always begins
   `mpk_`); `token_hash_alg = 'sha256'` literal stored.

C. **Database access posture** — Step 4.A's INSERT/UPDATE
   queries MUST be issued against the operator admin DSN
   (`cfg.Stats.PartnerKeysAdminDSN`), opened at subcommand
   invocation time only and NEVER from the running coordinator
   daemon process. The subcommand MUST NOT reuse any of:
   `stats_reader_dsn`, `stats_rollup_dsn`,
   `provider_portal_dsn`, `partner_keys.writer_dsn`. Connection
   closed on subcommand exit. Daemon process (long-running
   `coordinator` boot) MUST NOT open the admin DSN.

D. **§5.4.2 INSERT column set** — exactly: `token_hash`,
   `token_hash_alg`, `prefix`, `label`, `allowed_origins`,
   `rate_limit_rpm`, `created_by`, `rotated_from_id` (NULL
   unless --rotate-from). NO `rate_limit_burst` (v0.1.8 removed).
   `created_by TEXT NOT NULL` is satisfied by the default rule:
   `$USER@$(hostname)` from environment, or `"unknown@<hostname>"`
   if `$USER` is unset. Default MUST be non-empty so the literal
   AC-17 command `coordinator partner-keys issue --label X`
   (NO `--created-by`) passes.

E. **§5.4.4 rotation flow** — `coordinator partner-keys issue
   --rotate-from <existing_id>` INSERTs a new row with
   `rotated_from_id = <existing_id>` and leaves predecessor
   row `revoked_at = NULL` (operator decides overlap window).
   The CLI MUST NOT auto-revoke the predecessor and MUST NOT
   require --rotate-from to come with --reason or any other
   coupling flag.

F. **§5.4.3 rule 5 — `--allowed-origin` RFC 6454 idempotency
   validation** — the CLI MUST reject any `--allowed-origin`
   value that does not parse to its own normalized form
   (lowercase scheme; lowercase host; IDN→Punycode; default
   ports `:80`/`:443` stripped; trailing-slash / path / query
   / fragment treated as absent). Non-normalized value → exit
   non-zero, NO INSERT. Normalized value passes. The
   normalization rule MUST be the SAME function the Step 3
   handler uses (`normalizeOrigin` in `internal/stats/origin.go`)
   to guarantee CLI ↔ handler equivalence; a parallel
   reimplementation is a HIGH — two normalizations drift.

G. **`visibility revert` audit row** — UPDATE
   `provider_visibility SET mode='bucketed', updated_at=now()`
   AND INSERT into `provider_visibility_audit` with
   `actor_kind='operator'`, `actor_id` = a non-empty operator
   principal (same $USER@hostname rule as `created_by`), and
   `new_mode='bucketed'`. The CLI MUST hard-refuse any path
   that would write `new_mode='exact'` with `actor_kind=
   'operator'` (AC-20 CI assertion that this row count = 0).

H. **Log + redaction surface** — raw token MUST appear at
   exactly one location: stdout, exactly once, at issue-time.
   The CLI MUST NOT log the raw token to stderr, NOT to a
   structured log line, NOT to the audit table, NOT to journalctl,
   NOT in error paths. `token_hash` (the BYTEA) MUST NOT be
   printed in any non-error code path. `prefix` (8 chars
   beginning `mpk_`) MAY appear in `list` output and structured
   `stats_partner_key_issued` log lines per Step 4.C — that
   prefix is operator-permitted, but the random 43-char body
   substring MUST NOT.

I. **Test surface alignment** — AC-17 (the literal locked SPEC
   command `coordinator partner-keys issue --label X`) passes
   AND a journalctl-equivalent assertion proves the raw token
   does not appear. Explicit --created-by variant. RFC 6454
   idempotency 3-case test (canonical pass, mixed-case reject,
   :443 reject). Rotation overlap (key A active; key B with
   --rotate-from A active; both unlock partner projection;
   revoke A → A rejected, B still works). `revoke --id 99999`
   (non-existent) returns clean error, not a panic. Negative
   `--burst` flag test (the bare flag produces a clear error).

Validation steps (run before writing findings):
- `git diff --name-only 2b27256..HEAD -- phase4-coordinator/`
  to scope the Step 4.A delta.
- `go build ./...` from `phase4-coordinator/`.
- `go test ./cmd/coordinator/... ./internal/stats/...` (unit
  + any integration tags the IMPL added for the CLI).
- `go vet ./...`.
- `gofmt -l ./cmd/coordinator ./internal/stats`.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}'
  ./cmd/coordinator` to verify the CLI does NOT import
  `internal/stats/store` reader-only helpers in a way that
  would let an INSERT path leak through the read pool.
- `grep -rn "rate_limit_burst" phase4-coordinator/` MUST return
  zero hits in non-test, non-migration paths (v0.1.8 removed
  the column).

Output structure (one document per round, fresh file):

```
# SPEC-017 IMPL Step 4.A — Architecture Audit Round M

Branch: `impl/spec-017-step-1`
HEAD audited: `<sha>` (`<commit subject>`)
Diff base: Step 3 converged tip `2b27256`
Auditor lane: ARCHITECTURE
Prior rounds checked:
- specs/SPEC-017-IMPL-STEP_4A-arch-r1-audit.md  (... etc.)

Verdict: <READY TO LOCK | NOT READY TO LOCK> —
0 CRITICAL + N HIGH + M MEDIUM + L LOW + I INFO

## Validation evidence
- <list of commands run + outcomes>

## Category Verdicts
A. ...: PASS / FAIL — <one-sentence summary>
B. ...
...
I. ...

## Findings
### CRITICAL
1. <file:line>
   - Evidence: <code or diff snippet>
   - Why: <which locked invariant / SPEC § / BUILD § is violated
     and the failure mode>
   - Fix: <minimal SPEC-conforming patch shape>

### HIGH
...

### MEDIUM
...

### LOW
...

### INFO
- ...

## Round-(M-1) Closure Checks
- <each prior finding's status: closed (with new file:line
  evidence) or still open (re-raise as the SAME severity)>

## Final Verdict
READY TO LOCK: YES/NO
Blocking count: CRITICAL/HIGH/MEDIUM/LOW/INFO
```

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
