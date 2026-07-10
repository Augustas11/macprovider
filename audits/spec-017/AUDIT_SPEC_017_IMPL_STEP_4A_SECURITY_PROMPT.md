# AUDIT_SPEC_017_IMPL_STEP_4A — Security lane

Operator-paste prompt to audit the **Step 4.A IMPL code** (partner-key CLI
+ operator visibility-revert subcommand) under PR `Augustas11/macprovider#173`
from the security / isolation / leak lens.

Audit target is the **Step 4.A implementation diff** layered on top of the
converged Step 3 (HEAD `2b27256` or later). SPEC-017 v0.1.8 is LOCKED;
`BUILD_SPEC_017_IMPL_PROMPT.md` is the controlling kickoff.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred and
acknowledged in the convergence file.

Each round writes
`specs/SPEC-017-IMPL-STEP_4A-security-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.A IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the SECURITY (isolation / leak / privilege) lens.

Step 4.A scope: see the ARCH-lane prompt — partner-key CLI +
operator visibility-revert subcommand.

Output: specs/SPEC-017-IMPL-STEP_4A-security-rM-audit.md (round
M; fresh file per round, never append).

Severity model:
- CRITICAL — the raw token (47 chars), the random 43-char
  body, or `token_hash` (any subset of bytes) escapes to a
  durable surface other than the legitimate one-time stdout
  print at issue time; the CLI opens or persists the admin
  DSN inside the daemon process; the CLI accepts an operator-
  driven escalation from `bucketed` → `exact` via any code
  path; the CLI logs the DSN connection string on an error
  path; the CLI's CSPRNG falls back to `math/rand` on any
  branch.
- HIGH — token-derived material flows into a structured-log
  field beyond the operator-permitted `prefix`; subcommand
  output is mistakenly TLS-redacted but `journalctl --user`
  would still show the raw token; rotation flow leaks the
  predecessor's `token_hash` into an audit trail; visibility
  revert audit row stores the operator principal in a way
  that exposes /etc/passwd-equivalent info beyond what the
  operator has consented to.
- MEDIUM — partial isolation gap: e.g. the subcommand binary
  is invoked under sudo but reads `$HOME/.coordinator/admin.yaml`
  with the wrong umask; missing assertion on the empty-
  envelope case; subcommand error paths surface enough
  context to enable a downstream operator to leak the token
  in a Slack paste.
- LOW — polish / quality / non-blocking.
- INFO — positive observations.

Required reading (same as ARCH lane), with added emphasis on:
- §5.4.3 timing-equivalence rule (CLI MUST validate
  --allowed-origin via the SAME normalization function the
  handler uses for request-time comparisons — diverging
  normalizations open a CLI-allows-but-handler-rejects bug,
  not a security leak per se but in the SECURITY lane's
  scope because it can trick the operator into thinking a
  partner key is provisioned when in fact every request
  401s).
- BUILD §C.3 admin-DSN isolation block.
- §7.4 redaction directive (Step 4.B nginx companion).

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Token-leak surface map** — enumerate every place the
   raw token / body / hash could appear: stdout, stderr,
   `*sql.DB` log layer (lib/pq's `errors.As`), structured-
   log emitter (zerolog), os.Args at fork-exec, environment
   variables, `os/exec.Cmd.Stdout`, `Cmd.Stderr`, the
   error-wrap chain, panic recovery handlers, the audit
   table (`provider_visibility_audit` MUST NOT carry partner-
   key material), the journalctl-equivalent test fixture.
   For each surface, evidence that the token does NOT appear
   (or the legitimate single-stdout-emission case).

B. **CSPRNG audit** — `crypto/rand.Read` import is present;
   `math/rand` is NOT imported in `cmd/coordinator/`
   partner-key files; `crypto/rand.Read`'s error is checked
   on every call (a NON-checked Read on macOS can return
   short reads under bizarre fork conditions, leaving
   uninitialized bytes that a Mac mini's CSPRNG state would
   make predictable across rapid issuance — implausible on
   prod Linux but cheap to assert).

C. **Admin DSN handling** — DSN string is opened from
   `cfg.Stats.PartnerKeysAdminDSN` (or env override) at
   subcommand invocation. The DSN string itself MUST NOT
   be logged on error paths (postgres DSNs commonly embed
   the password). The connection is `Close()`d in a defer
   at subcommand entry. The daemon process MUST NOT
   open this DSN (sweep `cmd/coordinator/main.go` daemon
   path and assert PartnerKeysAdminDSN is NOT touched on
   the boot path).

D. **No reuse of runtime DSNs** — the CLI MUST NOT fall
   back to `stats_reader_dsn`, `stats_rollup_dsn`,
   `provider_portal_dsn`, or `partner_keys.writer_dsn`
   under any branch. The admin DSN is mandatory; an
   empty admin DSN MUST exit with a clear error and
   exit code 2 (config error), NOT silently try a
   runtime DSN.

E. **Visibility revert privilege boundary** — `coordinator
   visibility revert` MUST NOT allow `--mode exact` /
   `--exact` / equivalent. The IMPL MUST hardcode
   `new_mode = 'bucketed'` in the INSERT statement (NOT
   parameterize the column value from a flag). AC-20 CI
   assertion catches `new_mode = 'exact' AND actor_kind =
   'operator'`. The IMPL MUST also reject a `--actor-kind
   provider` override — `actor_kind` is HARDCODED to
   `'operator'` for this CLI.

F. **`actor_id` PII / fingerprint surface** — the operator
   principal is `$USER@$(hostname)`. The CLI MUST NOT
   resolve `hostname` to an FQDN that leaks internal
   infrastructure (acceptable: `os.Hostname()`'s short
   name; flag: any code that calls `net.LookupCNAME`
   or similar). The `actor_id` value is durable in
   `provider_visibility_audit` — leaks here are operator-
   side disclosure, not catastrophic but auditable.

G. **Structured log emissions** — the CLI emits the
   structured events `stats_partner_key_issued` and
   `stats_partner_key_revoked` per Step 4.C, but those
   events MUST contain only id / label / prefix / created_by
   / rotated_from_id_or_null / revoked_at / revoked_reason
   / actor. The raw token MUST NOT appear. Step 4.A's
   structured-log emit is in scope here (Step 4.C handles
   the Prometheus side).

H. **RFC 6454 normalization parity** — the CLI MUST call
   the same `normalizeOrigin` (or equivalent) function the
   Step 3 handler uses. Evidence: import the
   `internal/stats` package's exported normalization
   helper, OR call a shared `internal/stats/origin`
   helper. If the CLI carries a parallel implementation,
   that is a HIGH (normalization drift) and a SECURITY
   concern because a partner key validated by the CLI
   but rejected by the handler is operator-confusing.

I. **Operator runbook redaction defaults** — the OPS.md
   recipes (Step 4.C) that show `coordinator partner-keys
   issue` invocations MUST NOT include real-looking
   `mpk_*` strings; placeholder `mpk_REDACTED_RAW_TOKEN`
   or `mpk_$(operator-pastes-here)` is the SECURITY-lane
   preference. Cross-step finding (4.A scope verifying
   that 4.C runbook is consistent).

J. **AC-15 (Step 4.A share)** — CLI journalctl scan.
   Spawn the CLI under `systemd-run --user` (or equivalent
   journalctl-readable wrapper in the test harness) and
   assert journalctl shows NO raw token, NO body
   substring, NO `token_hash`. The expected journalctl
   line shows label + prefix only.

Validation steps (same as ARCH/CODE lanes).

Output structure (same as ARCH/CODE lanes).

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
