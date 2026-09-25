# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T08:33:42.971Z

## Original task

# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff origin/main...HEAD`.

## The change
- **What was wrong.** The full Pearl deploy (`phase4-coordinator/dist/deploy-pearl-vps.sh`)
  and `dist/stats-billing-mirror.service` pointed the stats billing mirror at
  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
  (`ledger_request_credits`) lives in `coordinator.db`, the configured
  `db_path` on Pearl.
- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
  deploy's initial mirror run failed with `no such table` and rolled back a
  catalog deploy.
- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
  - the unit (`ConditionPathExists`, `ExecStart`, the `ReadOnlyPaths` for the
    DB, WAL and SHM);
  - the deploy's ACL snapshot, ACL grant and start guard;
  - `billingmirror.DefaultSQLitePath`;
  - the flag help;
  - the wiring tests.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE

Check:
- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
- The tests.

## Final prompt

# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff origin/main...HEAD`.

## The change
- **What was wrong.** The full Pearl deploy (`phase4-coordinator/dist/deploy-pearl-vps.sh`)
  and `dist/stats-billing-mirror.service` pointed the stats billing mirror at
  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
  (`ledger_request_credits`) lives in `coordinator.db`, the configured
  `db_path` on Pearl.
- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
  deploy's initial mirror run failed with `no such table` and rolled back a
  catalog deploy.
- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
  - the unit (`ConditionPathExists`, `ExecStart`, the `ReadOnlyPaths` for the
    DB, WAL and SHM);
  - the deploy's ACL snapshot, ACL grant and start guard;
  - `billingmirror.DefaultSQLitePath`;
  - the flag help;
  - the wiring tests.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE

Check:
- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
- The tests.

## Raw output

```text
CODE audit result: 1 HIGH finding.

HIGH — [stats-billing-mirror.service:28](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/stats-billing-mirror.service:28)

`coordinator.db` is correctly used by `ExecStart` and `ReadOnlyPaths`, but the unit still declares `InaccessiblePaths=-/var/lib/macprovider/coordinator.db`. The service namespace can therefore hide the database, causing the initial mirror run to fail and the deploy to roll back.

Fix: remove that `InaccessiblePaths` entry and add a wiring test asserting it is absent.

No other C/H/M findings. ACL snapshots/grants and rollback restoration cover `coordinator.db`, WAL, and SHM. `ReadOnlyDSN` uses `mode=ro`, `query_only`, and a bounded busy timeout.

Existing relevant tests passed, including mirror, SQLite utility, stats packages, deploy wiring, static-feed access, and recovery tests. `origin/main...HEAD` was empty because both refs point to `c6c326927`.

VERDICT: FAIL (0/1/0)


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-mirror-dbpath
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d7af-fd94-75d0-b2c8-425946439e74
--------
user
# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff origin/main...HEAD`.

## The change
- **What was wrong.** The full Pearl deploy (`phase4-coordinator/dist/deploy-pearl-vps.sh`)
  and `dist/stats-billing-mirror.service` pointed the stats billing mirror at
  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
  (`ledger_request_credits`) lives in `coordinator.db`, the configured
  `db_path` on Pearl.
- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
  deploy's initial mirror run failed with `no such table` and rolled back a
  catalog deploy.
- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
  - the unit (`ConditionPathExists`, `ExecStart`, the `ReadOnlyPaths` for the
    DB, WAL and SHM);
  - the deploy's ACL snapshot, ACL grant and start guard;
  - `billingmirror.DefaultSQLitePath`;
  - the flag help;
  - the wiring tests.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE

Check:
- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
- The tests.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: failed to parse hooks config /Users/augstar/.codex/hooks.json: unknown field `state`, expected `description` or `hooks` at line 2 column 9
codex
I’m auditing `origin/main...HEAD` as a read-only CODE lane. I’ll trace every legacy path and ACL rollback path, verify SQLite read-only wiring and WAL/SHM protections, then run only the repository’s existing relevant tests before issuing the required verdict.
exec
/bin/bash -lc "sed -n '1,240p' /Users/augstar/.codex/skills/code-review/SKILL.md && printf '\\n---STATUS---\\n' && git status -sb && printf '\\n---DIFFSTAT---\\n' && git diff --stat origin/main...HEAD" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
---
name: code-review
description: "[OMX] Run a comprehensive code review"
---

# Code Review Skill

Conduct a thorough code review for quality, security, and maintainability with severity-rated feedback.

## When to Use

This skill activates when:
- User requests "review this code", "code review"
- Before merging a pull request
- After implementing a major feature
- User wants quality assessment

## GPT-5.5 Guidance Alignment

- Default to outcome-first progress and completion reporting: state the target result, evidence, validation status, and stop condition before adding process detail.
- Treat newer user task updates as local overrides for the active workflow branch while preserving earlier non-conflicting constraints.
- If correctness depends on additional inspection, retrieval, execution, or verification, keep using the relevant tools until the review is grounded; stop once enough evidence exists.
- Continue through clear, low-risk, reversible next steps automatically; ask only when the next step is materially branching, destructive, credentialed, external-production, or preference-dependent.

Delegates to the `code-reviewer` and `architect` agents in parallel for a two-lane review:

1. **Identify Changes**
   - Run `git diff` to find changed files
   - Determine scope of review (specific files or entire PR)

2. **Launch Parallel Review Lanes**
   - **`code-reviewer` lane** - owns spec compliance, security, code quality, performance, and maintainability findings
   - **`architect` lane** - owns the devil's-advocate / design-tradeoff perspective
   - Both lanes run in parallel and produce distinct outputs before final synthesis

3. **Review Categories**
   - **Security** - Hardcoded secrets, injection risks, XSS, CSRF
   - **Code Quality** - Function size, complexity, nesting depth
   - **Performance** - Algorithm efficiency, N+1 queries, caching
   - **Best Practices** - Naming, documentation, error handling
   - **Maintainability** - Duplication, coupling, testability

4. **Severity Rating**
   - **CRITICAL** - Security vulnerability (must fix before merge)
   - **HIGH** - Bug or major code smell (should fix before merge)
   - **MEDIUM** - Minor issue (fix when possible)
   - **LOW** - Style/suggestion (consider fixing)

5. **Architectural Status Contract**
   - **CLEAR** - No unresolved architectural blocker was found
   - **WATCH** - Non-blocking design/tradeoff concern that must appear in the final synthesis
   - **BLOCK** - Unresolved design concern that prevents a merge-ready verdict

6. **Specific Recommendations**
   - File:line locations for each issue
   - Concrete fix suggestions
   - Code examples where applicable

7. **Final Synthesis**
   - Combine the `code-reviewer` recommendation and the architect status into one final verdict
   - Deterministic merge gating rules:
     - If architect status is **BLOCK**, final recommendation is **REQUEST CHANGES**
     - Else if `code-reviewer` recommendation is **REQUEST CHANGES**, final recommendation is **REQUEST CHANGES**
     - Else if architect status is **WATCH**, final recommendation is **COMMENT**
     - Else final recommendation follows the `code-reviewer` lane
   - The final report must make architect blockers impossible to miss

## Agent Delegation

```
delegate(
  role="code-reviewer",
  tier="THOROUGH",
  prompt="CODE REVIEW TASK

Review code changes for quality, security, and maintainability.

This is the code/spec/security lane. Do not absorb architectural ownership.

Scope: [git diff or specific files]

Review Checklist:
- Security vulnerabilities (OWASP Top 10)
- Code quality (complexity, duplication)
- Performance issues (N+1, inefficient algorithms)
- Best practices (naming, documentation, error handling)
- Maintainability (coupling, testability)

Output: Code review report with:
- Files reviewed count
- Issues by severity (CRITICAL, HIGH, MEDIUM, LOW)
- Specific file:line locations
- Fix recommendations
- Approval recommendation (APPROVE / REQUEST CHANGES / COMMENT)"
)

delegate(
  role="architect",
  tier="THOROUGH",
  prompt="ARCHITECTURE / DEVIL'S-ADVOCATE REVIEW TASK

Review the same code changes from the architecture/tradeoff perspective.

Scope: [git diff or specific files]

Focus:
- System boundaries and interfaces
- Hidden coupling or long-term maintainability risks
- Tradeoff tension the main reviewer might miss
- Strongest counterargument against approving as-is

Output:
- Architectural Status: CLEAR / WATCH / BLOCK
- File:line evidence for each concern
- Concrete tradeoff or design recommendation"
)

Run both lanes in parallel, then synthesize them with the deterministic rules above.
```

## External Model Consultation (Preferred)

The code-reviewer agent SHOULD consult Codex for cross-validation.

### Protocol
1. **Form your OWN review FIRST** - Complete the review independently
2. **Consult for validation** - Cross-check findings with Codex
3. **Critically evaluate** - Never blindly adopt external findings
4. **Graceful fallback** - Never block if tools unavailable

### When to Consult
- Security-sensitive code changes
- Complex architectural patterns
- Unfamiliar codebases or languages
- High-stakes production code

### When to Skip
- Simple refactoring
- Well-understood patterns
- Time-critical reviews
- Small, isolated changes

### Tool Usage
Prefer native `code-reviewer` agent consultation or CLI-backed `ask_codex` surfaces when available. Optional MCP compatibility ask tools may be used only when already enabled. If consultation tools are unavailable, fall back to the `code-reviewer` agent.

**Note:** Codex calls can take up to 1 hour. Consider the review timeline before consulting.

## Output Format

```
CODE REVIEW REPORT
==================

Files Reviewed: 8
Total Issues: 12
Architectural Status: WATCH

CRITICAL (0)
-----------
(none)

HIGH (0)
--------
(none)

MEDIUM (7)
----------
1. src/api/auth.ts:42
   Issue: Email normalization logic is duplicated instead of reusing the shared helper
   Risk: Validation rules can drift between authentication paths
   Fix: Route both paths through the shared normalization helper

2. src/components/UserProfile.tsx:89
   Issue: Derived permissions are recalculated on every render
   Risk: Avoidable work during profile refreshes
   Fix: Memoize the derived permissions list or compute it upstream

3. src/utils/validation.ts:15
   Issue: Form-layer and server-layer validation messages are defined separately
   Risk: User-facing validation guidance can become inconsistent
   Fix: Share one validation message helper across both call sites

LOW (5)
-------
...

ARCHITECTURE WATCHLIST
----------------------
- src/review/orchestrator.ts:88
  Concern: Review result synthesis relies on implicit ordering rather than an explicit blocker contract
  Status: WATCH
  Recommendation: Define deterministic merge gating before expanding reviewers

SYNTHESIS
---------
- code-reviewer recommendation: COMMENT
- architect status: WATCH
- final recommendation: COMMENT

RECOMMENDATION: COMMENT

Address any WATCH concerns before treating the change as merge-ready.
```

## Review Checklist

The `code-reviewer` lane checks:

### Security
- [ ] No hardcoded secrets (API keys, passwords, tokens)
- [ ] All user inputs sanitized
- [ ] SQL/NoSQL injection prevention
- [ ] XSS prevention (escaped outputs)
- [ ] CSRF protection on state-changing operations
- [ ] Authentication/authorization properly enforced

### Code Quality
- [ ] Functions < 50 lines (guideline)
- [ ] Cyclomatic complexity < 10
- [ ] No deeply nested code (> 4 levels)
- [ ] No duplicate logic (DRY principle)
- [ ] Clear, descriptive naming

### Performance
- [ ] No N+1 query patterns
- [ ] Appropriate caching where applicable
- [ ] Efficient algorithms (avoid O(n²) when O(n) possible)
- [ ] No unnecessary re-renders (React/Vue)

### Best Practices
- [ ] Error handling present and appropriate
- [ ] Logging at appropriate levels
- [ ] Documentation for public APIs
- [ ] Tests for critical paths
- [ ] No commented-out code

## Architect Lane Checklist

The `architect` lane checks:


---STATUS---
## fix/stats-mirror-coordinator-db...origin/fix/stats-mirror-coordinator-db
?? audits/2026-09-25-stats-mirror-db-path/

---DIFFSTAT---
 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)

codex
I’m using the repository’s code-review workflow for an independent second pass, bounded to the requested CODE checklist and existing tests only. I’ll continue the primary source trace in parallel and reconcile only evidence-backed findings.
collab: SpawnAgent
exec
/bin/bash -lc "git diff --find-renames --unified=80 origin/main...HEAD -- phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go && printf '\\n---ALL REPO PATH REFERENCES---\\n' && rg -n --hidden --glob '"'!**/.git/**'"' 'request-log\\.sqlite|coordinator\\.db|ReadOnlyDSN|DefaultSQLitePath|ledger_request_credits' ." in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 133ms:
./scripts/revenue_benchmark/README.md:39:  --coordinator-db coordinator.db --gateway-db gateway.db \
./scripts/revenue_benchmark/README.md:40:  [--route-journal-db coordinator.db.route-snapshots] [--now 2026-09-24T12:00:00Z]
./phase4-coordinator/internal/rewards/projection.go:166:          FROM ledger_request_credits lrc
./scripts/h1-undercredit-probe.sh:9:# Production ledger: /var/lib/macprovider/coordinator.db on coordinator.malibu.tech
./scripts/h1-undercredit-probe.sh:15:#   sqlite3 /var/lib/macprovider/coordinator.db ".backup /tmp/coord-snap.db"
./scripts/h1-undercredit-probe.sh:62:  FROM ledger_request_credits
./phase4-coordinator/internal/trustpool/spec043_creator_mvp_journey_test.go:810:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/rewards/useful_work.go:56:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:106:CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:134:		if _, err := db.ExecContext(ctx, `INSERT INTO ledger_request_credits VALUES ($1, $2, $3, $4, $5, $6)`, row.provider, row.at, row.verified, row.mode, row.quarantined, row.credits); err != nil {
./phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:167:	if _, err := db.ExecContext(ctx, "ALTER TABLE ledger_request_credits ADD COLUMN rewards_excluded BOOLEAN"); err != nil {
./phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:171:		if _, err := db.ExecContext(ctx, `INSERT INTO ledger_request_credits VALUES ($1, $2, TRUE, 'enforce', FALSE, 7, TRUE)`, provider, now.Add(-time.Minute)); err != nil {
./phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:182:		if _, err := db.ExecContext(ctx, "UPDATE ledger_request_credits SET rewards_excluded = $1 WHERE provider_id = 'provider-excluded'", flag); err != nil {
./phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:141:	authStore, err := auth.OpenStore(filepath.Join(dir, "coordinator.db"))
./phase4-coordinator/internal/rewards/emission_integration_test.go:843:        CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/rewards/emission_integration_test.go:854:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
./phase4-coordinator/internal/rewards/emission_integration_test.go:879:        INSERT INTO ledger_request_credits
./phase4-coordinator/internal/rewards/emission_integration_test.go:980:        CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/rewards/emission_integration_test.go:991:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
./phase4-coordinator/internal/rewards/emission_integration_test.go:1003:        INSERT INTO ledger_request_credits
./phase4-coordinator/internal/rewards/emission_integration_test.go:1010:        INSERT INTO ledger_request_credits
./phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:27:	dbPath := filepath.Join(dir, "coordinator.db")
./phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:123:	dbPath := filepath.Join(dir, "coordinator.db")
./phase4-coordinator/internal/ws/admin_onboarding_test.go:56:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/coordinator.yaml.example:223:  db_path: "coordinator.db"
./phase4-coordinator/internal/rewards/wallet_mirror.go:24:	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:10:CREATE TABLE IF NOT EXISTS ledger_request_credits (
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:33:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS sqlite_lrc_id BIGINT;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:34:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS request_id TEXT;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:35:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS attempt_n INTEGER;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:36:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_id TEXT;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:37:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS ts_utc TIMESTAMPTZ;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:38:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS created_at_utc TIMESTAMPTZ DEFAULT now();
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:39:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS updated_at_utc TIMESTAMPTZ;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:40:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS prompt_tokens BIGINT;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:41:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS completion_tokens BIGINT;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:42:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS estimated_completion_tokens BIGINT;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:43:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS usage_source TEXT DEFAULT 'provider_reported';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:44:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_credits BIGINT DEFAULT 0;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:45:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS fault_flag TEXT DEFAULT 'none';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:46:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS quarantined BOOLEAN DEFAULT FALSE;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:47:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS settlement_policy_mode TEXT DEFAULT 'legacy';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:48:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS spec022_verified BOOLEAN DEFAULT FALSE;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:49:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS requested_privacy_mode TEXT DEFAULT 'none';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:50:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS effective_privacy_outcome TEXT DEFAULT 'plaintext';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:51:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS positive_verification_excluded BOOLEAN DEFAULT FALSE;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:52:ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS rewards_excluded BOOLEAN DEFAULT FALSE;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:54:UPDATE ledger_request_credits SET settlement_policy_mode = 'legacy' WHERE settlement_policy_mode IS NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:55:UPDATE ledger_request_credits SET spec022_verified = FALSE WHERE spec022_verified IS NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:56:UPDATE ledger_request_credits SET requested_privacy_mode = 'none' WHERE requested_privacy_mode IS NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:57:UPDATE ledger_request_credits SET effective_privacy_outcome = 'plaintext' WHERE effective_privacy_outcome IS NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:58:UPDATE ledger_request_credits SET positive_verification_excluded = FALSE WHERE positive_verification_excluded IS NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:59:UPDATE ledger_request_credits SET rewards_excluded = FALSE WHERE rewards_excluded IS NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:61:ALTER TABLE ledger_request_credits ALTER COLUMN requested_privacy_mode SET DEFAULT 'none';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:62:ALTER TABLE ledger_request_credits ALTER COLUMN requested_privacy_mode SET NOT NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:63:ALTER TABLE ledger_request_credits ALTER COLUMN effective_privacy_outcome SET DEFAULT 'plaintext';
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:64:ALTER TABLE ledger_request_credits ALTER COLUMN effective_privacy_outcome SET NOT NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:65:ALTER TABLE ledger_request_credits ALTER COLUMN positive_verification_excluded SET DEFAULT FALSE;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:66:ALTER TABLE ledger_request_credits ALTER COLUMN positive_verification_excluded SET NOT NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:67:ALTER TABLE ledger_request_credits ALTER COLUMN rewards_excluded SET DEFAULT FALSE;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:68:ALTER TABLE ledger_request_credits ALTER COLUMN rewards_excluded SET NOT NULL;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:73:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_attempt_nonnegative CHECK (attempt_n >= 0);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:76:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_prompt_tokens_nonnegative CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:79:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_completion_tokens_nonnegative CHECK (completion_tokens IS NULL OR completion_tokens >= 0);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:82:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_estimated_completion_tokens_nonnegative CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:85:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_usage_source_enum CHECK (usage_source IN ('provider_reported','byte_estimated','null_error'));
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:88:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_provider_credits_nonnegative CHECK (provider_credits >= 0);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:91:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_fault_flag_enum CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error'));
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:94:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_settlement_policy_mode_enum CHECK (settlement_policy_mode IN ('legacy','observe','enforce'));
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:97:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_not_null CHECK (spec022_verified IS NOT NULL);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:100:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_enforce_check CHECK (spec022_verified = FALSE OR settlement_policy_mode = 'enforce');
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:104:CREATE UNIQUE INDEX IF NOT EXISTS idx_lrc_mirror_unique_attempt ON ledger_request_credits(request_id, attempt_n, provider_id);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:105:CREATE INDEX IF NOT EXISTS idx_lrc_mirror_provider_ts ON ledger_request_credits(provider_id, ts_utc);
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:243:      FROM ledger_request_credits
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:249:    INSERT INTO ledger_request_credits (
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:299:        GRANT SELECT ON ledger_request_credits TO stats_rollup;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:303:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
./phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:308:REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
./phase4-coordinator/dist/stats-hardware-verifier.service:25:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
./scripts/tests/test_classify_benchmark_evidence.py:26:            CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY, request_id TEXT,
./scripts/tests/test_classify_benchmark_evidence.py:57:        for table in ("request_log", "ledger_request_credits", "settlement_route_snapshots",
./scripts/tests/test_classify_benchmark_evidence.py:64:        self.coord.execute("INSERT INTO ledger_request_credits VALUES (1, 'internal', 0, 'provider', 'assigned', 5, NULL, 0, 'enforce', ?)", (receipt_scope,))
./scripts/tests/test_classify_benchmark_evidence.py:79:        self.coord.execute("UPDATE ledger_request_credits SET provider_credits=0")
./scripts/tests/test_classify_benchmark_evidence.py:83:        self.coord.execute("UPDATE ledger_request_credits SET quarantined=1, provider_credits=0, quarantine_reason='ambiguous_cache'")
./scripts/tests/test_classify_benchmark_evidence.py:90:        self.coord.execute("INSERT INTO ledger_request_credits VALUES (2, 'internal', 0, 'other-provider', 'assigned', 5, NULL, 0, 'enforce', ?)", (receipt_scope,))
./scripts/tests/test_classify_benchmark_evidence.py:136:        self.coord.execute("UPDATE ledger_request_credits SET quarantine_reason='route_snapshot_store_pressure'")
./phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go:427:	if err := db.QueryRowContext(ctx, `SELECT spec022_verified FROM ledger_request_credits WHERE request_id=$1`, in.requestID).Scan(&got); err != nil {
./phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go:481:  FROM ledger_request_credits
./phase4-coordinator/dist/payout-runbook.md:273:   sqlite3 /var/lib/macprovider/coordinator.db \
./phase4-coordinator/dist/payout-runbook.md:420:sqlite3 /var/lib/macprovider/coordinator.db \
./phase4-coordinator/internal/rewards/unlock.go:183:	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
./phase4-coordinator/dist/coordinator-sqlite-relief.sh:9:  echo "usage: coordinator-sqlite-relief.sh [coordinator.db]" >&2
./phase4-coordinator/dist/coordinator-sqlite-relief.sh:42:     'ledger_request_credits',
./phase4-coordinator/internal/ws/model_admission_probe_test.go:531:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/coordinator.yaml:243:  db_path: "/var/lib/macprovider/coordinator.db"
./phase4-coordinator/internal/auth/tokens_test.go:38:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:64:	store, err := auth.OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:80:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:96:	path := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:181:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:217:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:252:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:307:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:345:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:394:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:457:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:499:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:518:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:537:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:563:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:584:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:627:				store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:664:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:711:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:754:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:774:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:792:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:832:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:858:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:944:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:964:		dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:997:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:1034:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:1071:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:1105:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:1249:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:1285:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:1347:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:1390:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:1406:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:1458:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/tokens_test.go:1526:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/tokens_test.go:1589:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:42:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:113:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:163:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:188:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:251:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:324:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:365:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:418:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:479:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:541:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:620:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:712:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:763:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:813:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/provider_token_self_serve_test.go:876:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:17:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:52:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/coordinator-archive-rotate.sh:2:# coordinator-archive-rotate.sh — coordinator.db archive-rotate scaffold (#1226).
./phase4-coordinator/dist/coordinator-archive-rotate.sh:15:#   COORDINATOR_DB_PATH                  default: /var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/coordinator-archive-rotate.sh:34:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
./phase4-coordinator/dist/coordinator-archive-rotate.sh:274:  log "DRY_RUN=1 coordinator.db size=${size}B"
./phase4-coordinator/dist/coordinator-archive-rotate.sh:280:    ledger_request_credits ledger_provider_earnings ledger_operator_credits ledger_payout_ready \
./scripts/tests/fixtures/byom_journeys/admission/run-manifest.json:213:      "ledger_request_credits": 0,
./phase4-coordinator/internal/auth/portal_sessions_test.go:19:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/portal_sessions_test.go:32:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/portal_sessions_test.go:68:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/portal_sessions_test.go:88:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/portal_sessions_test.go:109:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_social_test.go:39:	return openSocialStoreAt(t, filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_social_test.go:66:	path := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/referrals_social_test.go:194:	path := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/referrals_social_test.go:249:	path := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/referrals_social_test.go:290:	path := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/referrals_admin_test.go:28:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:45:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:75:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:96:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:114:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:132:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:152:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:189:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:257:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:290:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:316:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:387:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:411:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/referrals_core_test.go:459:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
./phase4-coordinator/internal/auth/admission_recovery_atomic_test.go:16:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/onboarding_funnel_test.go:14:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/auth/onboarding_funnel_test.go:135:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/auth_github_test.go:678:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:3833:specs/SPEC-016-payout-pipeline.md:506:`ledger_request_credits.settlement_id → ledger_payout_ready.id`;
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:3886:specs/SPEC-016-payout-pipeline.md:4494:     `ledger_request_credits`. There is no `settlement_id`
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4742:specs/SPEC-005-billing.md:710:  `ledger_request_credits` and the existing linked `ledger_operator_credits` row (`settlement_receipts.go`).
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4879:specs/SPEC-005-billing.md:3055:**Expected:** The POST returns HTTP 200, writes `resolution_kind='force_credit'`, sets `force_credit_matures_at_utc = created_at_utc + billing.force_credit_settlement_hold_seconds`, sets `correction_deadline_at_utc` at INSERT time, and emits `ledger_quarantine_force_credit`. Before maturity the row is absent from `spec022_payable_request_credits`. After maturity, if force-credit remains the latest resolution, the row appears in `spec022_payable_request_credits` while the base `ledger_request_credits.quarantined` marker remains 1. **Force-credit MUST NOT recompute credits:** the re-admitted row's `gross_credits`/`provider_credits` equal the stored values unchanged (zero for a hot-path/receipt cache-quarantine row; the pre-existing non-zero value for a recovery-flagged row — §2.7).
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4880:specs/SPEC-005-billing.md:3061:**Verification:** Drive the four cache-quarantine write shapes: (a) hot-path `ambiguous_cache` first-write; (b) §7.5b receipt-time quarantine on a previously `quarantined=0` row; (c) recovery `quarantineExistingLedgerForRequestAttemptTx` on a pre-existing non-zero-credit row; (d) recovery `insertQuarantineTx` when **no** ledger row exists. Inspect `ledger_request_credits` and `ledger_operator_credits`.
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4886:specs/SPEC-005-billing.md:3385:#### `ledger_request_credits.usage_source`
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4891:specs/SPEC-005-billing.md:3465:#### `ledger_request_credits.settlement_id`
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4892:specs/SPEC-005-billing.md:3489:#### `ledger_request_credits.settlement_account_scope_hash`
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4895:specs/SPEC-005-billing.md:3497:#### `ledger_request_credits.settlement_policy_mode`
./audits/2026-09-25-cb-perf/RESULT_SECURITY_R2.md:4898:specs/SPEC-005-billing.md:3505:#### `ledger_request_credits.settlement_policy_version`
./phase4-coordinator/internal/auth/spec014_pairing_test.go:111:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/auth/spec014_pairing_test.go:141:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:20:DB="$TMP/coordinator.db"
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:40:CREATE TABLE ledger_request_credits (
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:104:INSERT INTO ledger_request_credits(request_id, attempt_n, provider_id, ts_utc, settled, settlement_id, created_at_utc)
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:148:grep -q "DRY_RUN=1 coordinator.db size=" "$TMP/dry.err" || fail "dry-run size report missing"
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:424:printf 'live-parent-marker\n' >"$LIVE_DIR/coordinator.db"
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:426:COORDINATOR_DB_PATH="$LIVE_DIR/coordinator.db" \
./phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:433:[ "$(cat "$LIVE_DIR/coordinator.db")" = "live-parent-marker" ] || fail "directory restore mutated live coordinator.db"
./phase4-coordinator/internal/referralapi/advocacy_test.go:72:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh:16:DB="$TMP/coordinator.db"
./phase4-coordinator/internal/referralapi/serving.go:50:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(s.Path))
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:85:grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credits' "$BOOTSTRAP_SQL" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:86:  fail "bootstrap SQL must create ledger_request_credits"
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:102:grep -qF 'GRANT SELECT ON ledger_request_credits TO stats_rollup' "$BOOTSTRAP_SQL" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:104:grep -qF 'GRANT SELECT ON ledger_request_credits TO rewards_writer' "$BOOTSTRAP_SQL" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:106:grep -qF 'REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer' "$BOOTSTRAP_SQL" ||
./phase4-coordinator/internal/ws/model_admission_disablement_test.go:23:			authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/model_admission_disablement_test.go:120:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/model_admission_intake_test.go:279:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/config/config.go:717:	// SPEC-005 v0.3 stores `ledger_request_credits.provider_credits`
./phase4-coordinator/internal/config/config.go:1600:			DBPath:                   "coordinator.db",
./phase4-coordinator/dist/monitor/macprovider-monitor.service:20:# macprovider-owned so the daemon can write coordinator.db; the
./phase4-coordinator/dist/stats-billing-mirror.service:7:ConditionPathExists=/var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/stats-billing-mirror.service:14:ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
./phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
./phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
./phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/coordinator-archive-restore.sh:10:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
./phase4-coordinator/dist/coordinator-archive-restore.sh:182:PRIMARY_TMP="$TMP_DIR/coordinator.db"
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:353:	tokenStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:504:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:537:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:613:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:659:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:714:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:802:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:891:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:954:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:1214:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/autotune_hello_gate_test.go:1334:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
./phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
./phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
./phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
./phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
./phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
./phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
./phase4-coordinator/internal/ws/referral_core_test.go:31:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/canary_store_test.go:14:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:373:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:407:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:436:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:482:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:547:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:634:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:679:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:717:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:922:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/ws/admission_test.go:968:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/dist/coordinator.yaml.example:151:  db_path: "/var/lib/macprovider/coordinator.db"
./phase4-coordinator/dist/coordinator.yaml.example:380:  # sqlite_payout_db_path: "/var/lib/macprovider/coordinator.db"
./audits/spec-002/SPEC-002-v1-5-1-audit.md:67:- New `sqliteutil.ReadOnlyDSN` (mode=ro + query_only=ON; no WAL/synchronous pragmas).
./phase4-coordinator/tools/spec032canary/main.go:297:	r.sqliteDB = filepath.Join(r.runRoot, "state", "coordinator.db")
./phase4-coordinator/internal/stats/integration_test.go:16://           `SELECT 1 FROM ledger_request_credits LIMIT 1`.
./phase4-coordinator/internal/stats/integration_test.go:30:// `ledger_request_credits` AS IF it existed in the OLTP cluster
./phase4-coordinator/internal/stats/integration_test.go:222:        CREATE TABLE IF NOT EXISTS ledger_request_credits      (id BIGSERIAL PRIMARY KEY);
./phase4-coordinator/internal/stats/integration_test.go:543:	// "at least one" is the floor but ledger_request_credits is
./phase4-coordinator/internal/stats/integration_test.go:546:		"ledger_request_credits",
./phase4-coordinator/internal/stats/rollup/daily.go:53:          FROM ledger_request_credits lrc
./audits/2026-09-22/fix-1578.diff:112:+	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/stats/rollup_integration_test.go:71:// fresh here. Ordering matters: drop ledger_request_credits
./phase4-coordinator/internal/stats/rollup_integration_test.go:83:DROP TABLE IF EXISTS ledger_request_credits CASCADE;
./phase4-coordinator/internal/stats/rollup_integration_test.go:85:CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/stats/rollup_integration_test.go:125:        GRANT SELECT ON ledger_request_credits TO stats_rollup;
./phase4-coordinator/internal/stats/rollup_integration_test.go:174:        INSERT INTO ledger_request_credits
./phase4-coordinator/internal/stats/rollup_integration_test.go:974:        INSERT INTO ledger_request_credits (request_id, attempt_n, provider_id, ts_utc,
./phase4-coordinator/internal/stats/rollup_integration_test.go:1641:        INSERT INTO ledger_request_credits
./phase4-coordinator/internal/stats/rollup_integration_test.go:1680:		`UPDATE ledger_request_credits SET completion_tokens = 11, updated_at_utc = $1 WHERE request_id = 'req-upd-1'`,
./audits/spec-005/SPEC-005-r1-audit.md:139:  reconciliation summaries outside `ledger_request_credits`.
./audits/spec-005/AUDIT_ARC_3_NESTED_QUERIES_SECURITY_R2_PROMPT.md:51:  (`ledger_request_credits` + a grouped subquery on
./phase4-coordinator/internal/stats/rollup/timeseries.go:37:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/rollup/timeseries.go:125:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/rollup/incremental.go:235:             SELECT 1 FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/rollup/incremental.go:277:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:9:ALTER TABLE IF EXISTS ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:15:    IF to_regclass('public.ledger_request_credits') IS NOT NULL THEN
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:16:        UPDATE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:20:        UPDATE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:25:            ALTER TABLE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:30:            ALTER TABLE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:35:            ALTER TABLE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:40:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:97:      FROM ledger_request_credits
./phase4-coordinator/internal/stats/migrations/022_malibu_useful_work_rewards.up.sql:103:    INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/stats/rollup/late_events.go:72:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/rollup/leaderboard.go:284:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/rollup/overview.go:129:// requests from `ledger_request_credits` since the rollup-start
./phase4-coordinator/internal/stats/rollup/overview.go:130:// boundary. `ledger_request_credits.ts_utc` is a Postgres-shape
./phase4-coordinator/internal/stats/rollup/overview.go:152:          FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:196:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:201:	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:246:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:253:CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:272:  FROM ledger_request_credits
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:285:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:310:	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:317:CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/stats/billingmirror/mirror_test.go:333:INSERT INTO ledger_request_credits (
./audits/spec-005/SPEC-005-v0-4-r1-audit.md:66:  `ledger_request_credits`. Only `SQLITE_CONSTRAINT_UNIQUE` on
./audits/spec-005/SPEC-005-v0-4-r1-audit.md:146:  `resolution_kind` column on `ledger_request_credits`): the
./phase4-coordinator/internal/stats/billingmirror/mirror.go:22:	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
./phase4-coordinator/internal/stats/billingmirror/mirror.go:214:		opts.SQLitePath = DefaultSQLitePath
./phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
./phase4-coordinator/internal/stats/billingmirror/mirror.go:285:	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
./phase4-coordinator/internal/stats/billingmirror/mirror.go:286:		return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
./phase4-coordinator/internal/stats/billingmirror/mirror.go:312:	hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
./phase4-coordinator/internal/stats/billingmirror/mirror.go:320:	hasRequestedPrivacyMode, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "requested_privacy_mode")
./phase4-coordinator/internal/stats/billingmirror/mirror.go:324:	hasEffectivePrivacyOutcome, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "effective_privacy_outcome")
./phase4-coordinator/internal/stats/billingmirror/mirror.go:328:	hasPositiveVerificationExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "positive_verification_excluded")
./phase4-coordinator/internal/stats/billingmirror/mirror.go:332:	hasRewardsExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "rewards_excluded")
./phase4-coordinator/internal/stats/billingmirror/mirror.go:387:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/billingmirror/mirror.go:430:		return nil, fmt.Errorf("select ledger_request_credits: %w", err)
./phase4-coordinator/internal/stats/billingmirror/mirror.go:447:			return nil, fmt.Errorf("scan ledger_request_credits: %w", err)
./phase4-coordinator/internal/stats/billingmirror/mirror.go:468:		return nil, fmt.Errorf("iterate ledger_request_credits: %w", err)
./phase4-coordinator/internal/stats/billingmirror/mirror.go:698:	`CREATE TABLE IF NOT EXISTS ledger_request_credits (
./phase4-coordinator/internal/stats/billingmirror/mirror.go:721:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS sqlite_lrc_id BIGINT`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:722:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS request_id TEXT`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:723:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS attempt_n INTEGER`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:724:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_id TEXT`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:725:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS ts_utc TIMESTAMPTZ`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:726:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS created_at_utc TIMESTAMPTZ DEFAULT now()`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:727:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS updated_at_utc TIMESTAMPTZ`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:728:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS prompt_tokens BIGINT`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:729:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS completion_tokens BIGINT`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:730:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS estimated_completion_tokens BIGINT`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:731:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS usage_source TEXT DEFAULT 'provider_reported'`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:732:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_credits BIGINT DEFAULT 0`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:733:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS fault_flag TEXT DEFAULT 'none'`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:734:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS quarantined BOOLEAN DEFAULT FALSE`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:735:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS settlement_policy_mode TEXT DEFAULT 'legacy'`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:736:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS spec022_verified BOOLEAN DEFAULT FALSE`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:737:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS requested_privacy_mode TEXT DEFAULT 'none'`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:738:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS effective_privacy_outcome TEXT DEFAULT 'plaintext'`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:739:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS positive_verification_excluded BOOLEAN DEFAULT FALSE`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:740:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS rewards_excluded BOOLEAN DEFAULT FALSE`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:741:	`UPDATE ledger_request_credits SET settlement_policy_mode = 'legacy' WHERE settlement_policy_mode IS NULL`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:742:	`UPDATE ledger_request_credits SET spec022_verified = FALSE WHERE spec022_verified IS NULL`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:743:	`UPDATE ledger_request_credits SET requested_privacy_mode = 'none' WHERE requested_privacy_mode IS NULL`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:744:	`UPDATE ledger_request_credits SET effective_privacy_outcome = 'plaintext' WHERE effective_privacy_outcome IS NULL`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:745:	`UPDATE ledger_request_credits SET positive_verification_excluded = FALSE WHERE positive_verification_excluded IS NULL`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:746:	`UPDATE ledger_request_credits SET rewards_excluded = FALSE WHERE rewards_excluded IS NULL`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:750:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_attempt_nonnegative CHECK (attempt_n >= 0);
./phase4-coordinator/internal/stats/billingmirror/mirror.go:753:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_prompt_tokens_nonnegative CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0);
./phase4-coordinator/internal/stats/billingmirror/mirror.go:756:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_completion_tokens_nonnegative CHECK (completion_tokens IS NULL OR completion_tokens >= 0);
./phase4-coordinator/internal/stats/billingmirror/mirror.go:759:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_estimated_completion_tokens_nonnegative CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0);
./phase4-coordinator/internal/stats/billingmirror/mirror.go:762:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_usage_source_enum CHECK (usage_source IN ('provider_reported','byte_estimated','null_error'));
./phase4-coordinator/internal/stats/billingmirror/mirror.go:765:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_provider_credits_nonnegative CHECK (provider_credits >= 0);
./phase4-coordinator/internal/stats/billingmirror/mirror.go:768:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_fault_flag_enum CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error'));
./phase4-coordinator/internal/stats/billingmirror/mirror.go:771:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_settlement_policy_mode_enum CHECK (settlement_policy_mode IN ('legacy','observe','enforce'));
./phase4-coordinator/internal/stats/billingmirror/mirror.go:774:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_not_null CHECK (spec022_verified IS NOT NULL);
./phase4-coordinator/internal/stats/billingmirror/mirror.go:777:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_enforce_check CHECK (spec022_verified = FALSE OR settlement_policy_mode = 'enforce');
./phase4-coordinator/internal/stats/billingmirror/mirror.go:780:	`CREATE UNIQUE INDEX IF NOT EXISTS idx_lrc_mirror_unique_attempt ON ledger_request_credits(request_id, attempt_n, provider_id)`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:781:	`CREATE INDEX IF NOT EXISTS idx_lrc_mirror_provider_ts ON ledger_request_credits(provider_id, ts_utc)`,
./phase4-coordinator/internal/stats/billingmirror/mirror.go:912:      FROM ledger_request_credits
./phase4-coordinator/internal/stats/billingmirror/mirror.go:918:    INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/stats/billingmirror/mirror.go:964:        GRANT SELECT ON ledger_request_credits TO stats_rollup;
./phase4-coordinator/internal/stats/billingmirror/mirror.go:968:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
./phase4-coordinator/internal/stats/billingmirror/mirror.go:1001:        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
./audits/spec-005/AUDIT_ARC_3_NESTED_QUERIES_CODE_R2_PROMPT.md:47:  ledger_payout_ready but not in ledger_request_credits (the outer
./phase4-coordinator/internal/billing/route_snapshot_test.go:240:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:284:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:328:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:401:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:484:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:532:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:581:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/billing/route_snapshot_test.go:634:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/route_snapshot_test.go:1494:	if err := reqLog.DB().QueryRow(`SELECT quarantine_reason, settlement_policy_mode, settlement_policy_version FROM ledger_request_credits WHERE status = 200 LIMIT 1`).Scan(&gapReason, &policyMode, &policyVersion); err != nil {
./phase4-coordinator/internal/buyer/route_snapshot_test.go:1577:	if err := reqLog.DB().QueryRow(`SELECT quarantine_reason, settlement_policy_mode, settlement_policy_version FROM ledger_request_credits WHERE status = 200 LIMIT 1`).Scan(&gapReason, &policyMode, &policyVersion); err != nil {
./phase4-coordinator/internal/buyer/route_snapshot_test.go:2089:	rows, err := db.Query(`SELECT settlement_policy_mode FROM ledger_request_credits ORDER BY attempt_n ASC`)
./phase4-coordinator/internal/buyer/route_snapshot_test.go:2149:	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits`).Scan(&count); err != nil {
./phase4-coordinator/internal/billing/payout.go:65:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/payout.go:75:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/payout.go:90:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/payout.go:102:            WHERE payable.id = ledger_request_credits.id
./audits/2026-06-10/findings-raw.json:33:     "role": "Money path. formula.go: integer credit math, ppm/bps fixed point, RoundHalfEven banker's rounding (54-81), overflow-checked mul/add, fault flags zero credits. hotpath.go WriteHotPath: BEGIN IMMEDIATE transaction inserting request_log row + ledger_request_credits + ledger_operator_credits + identity snapshot atomically; ambiguous attempt_n rows are quarantined with zeroed credits (55-89). store.go: full ledger schema with CHECK constraints and a trigger making payout status terminal (121-126). settlement.go RunSettlement: quarantine inconsistent rows, aggregate unsettled credits per provider over min-payout threshold into ledger_payout_ready, mark settled in same tx. endpoints.go: /admin/ledger/* (operator key) and /providers/{id}/earnings (provider token + rate limit)."
./audits/2026-06-10/findings-raw.json:657:   "what": "phase4-coordinator and phase5-gateway are separate Go modules (go.mod: macprovider-coordinator vs macprovider-gateway) with zero code sharing \u2014 only a doc comment in the gateway references the coordinator (store.go:73). Each reimplements: a SQLite DSN-pragma helper that is byte-for-byte identical except the function name (coordinator sqliteutil/dsn.go:8-23 WithPragmas vs gateway storage/sqlite/dsn.go:8-23 sqliteDSN \u2014 same four pragmas, same separator logic), a hashed-secret auth store, an operator-bearer constant-time check, and an operator explorer (read-only SQLite queries + JSON API). The billing concepts, by contrast, are genuinely DIFFERENT domains \u2014 coordinator owns the provider-payout ledger (ledger_request_credits/operator_credits/payout_ready, billing/store.go:44-159) while the gateway owns buyer-side quota reservations \u2014 so that is correct separation, not duplication.",
./audits/2026-06-10/findings-raw.json:672:    "reasoning": "All three citations check out. phase4-coordinator/internal/sqliteutil/dsn.go:8-23 and phase5-gateway/internal/storage/sqlite/dsn.go:8-23 are byte-for-byte identical in logic (same four pragmas, same separator check, same url.Values encoding). The operator-bearer constant-time compare is also duplicated verbatim (coordinator auth/tokens.go:41-54 vs gateway router/server.go:2076-2089). No go.work file exists \u2014 the modules are fully isolated with no shared dependency. The store.go:73 reference correctly points to a doc comment cross-referencing the coordinator, not actual sharing. The billing-domain distinction (ledger_request_credits/payout_ready in coordinator vs buyer quota in gateway) is correctly characterized as intentionally separate. Low severity is correctly calibrated: the only real risk is a missed pragma patch in one service during a production incident, which is unlikely at N=3/2-person scale but worth naming as conscious debt."
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:55:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:140:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:185:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:188:	if got := scalar(t, store.db, `SELECT COUNT(DISTINCT settlement_id) FROM ledger_request_credits WHERE request_id = ? AND settlement_id IS NOT NULL`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:224:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits+100 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:276:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:286:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:361:	if got := scalar(t, store.db, `SELECT cached_prompt_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != cached {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:364:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:443:	if got := scalar(t, store.db, `SELECT cached_prompt_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != cached {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:505:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:582:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'invalid_cached_prompt_tokens'`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:633:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ? AND stream = 1`, input.RequestID); got != receiptBoundCredits.ProviderCredits+100 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:679:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:689:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND stream = 1 AND settled = 1`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:757:			if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ? AND stream = 1`, input.RequestID); got != receiptBoundCredits.ProviderCredits+100 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:806:			if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:817:			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND stream = 1 AND settled = 1`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:853:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != 0 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:895:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:898:	if got := scalar(t, store.db, `SELECT prompt_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != prompt {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:901:	if got := scalar(t, store.db, `SELECT completion_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != completion {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:990:			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 0 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1082:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1161:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1194:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1200:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != 500 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1204:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1211:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1248:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1256:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ? AND settled = 0 AND settlement_id IS NULL`, input.RequestID); got != 500 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1285:				if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settlement_id = ? WHERE request_id = ?`, payoutID, input.RequestID); err != nil {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1295:				if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settled = 1, settlement_id = ? WHERE request_id = ?`, payoutID, input.RequestID); err != nil {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1329:				if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 0 AND settlement_id IS NULL`, input.RequestID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1333:				if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1356:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1374:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1416:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settlement_policy_mode='legacy' WHERE request_id=?`, first.RequestID); err == nil {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1429:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, first.RequestID, payoutID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1432:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, second.RequestID, payoutID); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1488:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id IN (?, ?) AND settled = 1 AND settlement_id = ?`, first.RequestID, second.RequestID, payoutID); got != 2 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1541:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=? AND settlement_policy_mode='enforce' AND settlement_account_scope_hash=?`, input.RequestID, SettlementAccountScopeHash(input.AccountScope)); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1594:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=? AND settlement_policy_mode='legacy' AND settlement_account_scope_hash=?`, input.RequestID, SettlementAccountScopeHashForAccountID("ledger-buyer")); got != 1 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1597:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=? AND settlement_account_scope_hash=?`, input.RequestID, SettlementAccountScopeHash(input.RouteSnapshot.AccountScope)); got != 0 {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1610:CREATE TABLE ledger_request_credits (
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1651:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1669:	if _, err := db.Exec(`UPDATE ledger_request_credits SET settlement_policy_mode='legacy' WHERE request_id='valid'`); err == nil {
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1717:	INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1731:	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`, input.RequestID, input.AttemptN, input.ProviderID)
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1772:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1798:	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`, input.RequestID, input.AttemptN, input.ProviderID)
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1839:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/billing/spec022_money_gate_test.go:1867:	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`, input.RequestID, input.AttemptN, input.ProviderID)
./phase4-coordinator/internal/billing/settlement_output.go:266:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/endpoints.go:549:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/endpoints.go:700:SELECT COUNT(*) FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/endpoints.go:704:		"fault_count":                       h.sum(ctx, `SELECT COUNT(*) FROM ledger_request_credits WHERE fault_flag != 'none'`),
./phase4-coordinator/internal/billing/endpoints.go:760:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/endpoints.go:875:SELECT COUNT(*) FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/endpoints.go:1073:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/endpoints.go:1143:	if h.sum(r.Context(), `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=?`, providerID) == 0 {
./phase4-coordinator/internal/billing/endpoints.go:1189:		"fault_count":            h.sum(r.Context(), `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=? AND fault_flag != 'none'`+rangeSQL, faultArgs...),
./phase4-coordinator/internal/billing/store.go:128:CREATE TABLE IF NOT EXISTS ledger_request_credits (
./phase4-coordinator/internal/billing/store.go:170:CREATE INDEX IF NOT EXISTS idx_lrc_provider_ts ON ledger_request_credits(provider_id, ts_utc);
./phase4-coordinator/internal/billing/store.go:171:CREATE INDEX IF NOT EXISTS idx_lrc_unsettled ON ledger_request_credits(provider_id, settled, ts_utc);
./phase4-coordinator/internal/billing/store.go:172:CREATE INDEX IF NOT EXISTS idx_lrc_request ON ledger_request_credits(request_id);
./phase4-coordinator/internal/billing/store.go:173:CREATE INDEX IF NOT EXISTS idx_lrc_quarantine ON ledger_request_credits(quarantined, ts_utc);
./phase4-coordinator/internal/billing/store.go:174:CREATE INDEX IF NOT EXISTS idx_lrc_fault ON ledger_request_credits(provider_id, fault_flag, ts_utc);
./phase4-coordinator/internal/billing/store.go:178:    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
./phase4-coordinator/internal/billing/store.go:483:    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
./phase4-coordinator/internal/billing/store.go:630:	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_request_credits)`)
./phase4-coordinator/internal/billing/store.go:653:		{"settlement_account_scope_hash", `ALTER TABLE ledger_request_credits ADD COLUMN settlement_account_scope_hash TEXT NULL`},
./phase4-coordinator/internal/billing/store.go:654:		{"settlement_policy_mode", `ALTER TABLE ledger_request_credits ADD COLUMN settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy'`},
./phase4-coordinator/internal/billing/store.go:655:		{"settlement_policy_version", `ALTER TABLE ledger_request_credits ADD COLUMN settlement_policy_version TEXT NULL`},
./phase4-coordinator/internal/billing/store.go:656:		{"requested_privacy_mode", `ALTER TABLE ledger_request_credits ADD COLUMN requested_privacy_mode TEXT NOT NULL DEFAULT 'none'`},
./phase4-coordinator/internal/billing/store.go:657:		{"effective_privacy_outcome", `ALTER TABLE ledger_request_credits ADD COLUMN effective_privacy_outcome TEXT NOT NULL DEFAULT 'plaintext'`},
./phase4-coordinator/internal/billing/store.go:658:		{"positive_verification_excluded", `ALTER TABLE ledger_request_credits ADD COLUMN positive_verification_excluded INTEGER NOT NULL DEFAULT 0 CHECK(positive_verification_excluded IN (0,1))`},
./phase4-coordinator/internal/billing/store.go:659:		{"rewards_excluded", `ALTER TABLE ledger_request_credits ADD COLUMN rewards_excluded INTEGER NOT NULL DEFAULT 0 CHECK(rewards_excluded IN (0,1))`},
./phase4-coordinator/internal/billing/store.go:713:    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
./phase4-coordinator/internal/billing/store.go:877:	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_request_credits)`)
./phase4-coordinator/internal/billing/store.go:899:ALTER TABLE ledger_request_credits
./phase4-coordinator/internal/billing/store.go:905:	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(ledger_request_credits)`)
./phase4-coordinator/internal/billing/store.go:925:		if _, err := s.db.ExecContext(ctx, `ALTER TABLE ledger_request_credits ADD COLUMN charged_prompt_tokens INTEGER NULL CHECK(charged_prompt_tokens IS NULL OR charged_prompt_tokens >= 0)`); err != nil {
./phase4-coordinator/internal/billing/store.go:929:	if _, err := s.db.ExecContext(ctx, `UPDATE ledger_request_credits SET charged_prompt_tokens = prompt_tokens WHERE charged_prompt_tokens IS NULL AND prompt_tokens IS NOT NULL`); err != nil {
./phase4-coordinator/internal/billing/store.go:933:		if _, err := s.db.ExecContext(ctx, `ALTER TABLE ledger_request_credits ADD COLUMN provider_reported_prompt_tokens INTEGER NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0)`); err != nil {
./phase4-coordinator/internal/billing/store.go:937:	if _, err := s.db.ExecContext(ctx, `UPDATE ledger_request_credits SET provider_reported_prompt_tokens = prompt_tokens WHERE provider_reported_prompt_tokens IS NULL AND prompt_tokens IS NOT NULL`); err != nil {
./phase4-coordinator/internal/billing/store.go:949:		{"ledger_request_credits", "ts_utc"},
./phase4-coordinator/internal/billing/store.go:950:		{"ledger_request_credits", "created_at_utc"},
./phase4-coordinator/internal/billing/store.go:951:		{"ledger_request_credits", "updated_at_utc"},
./phase4-coordinator/internal/billing/store.go:1102:BEFORE INSERT ON ledger_request_credits
./phase4-coordinator/internal/billing/store.go:1113:    SELECT RAISE(ABORT, 'invalid ledger_request_credits settlement policy');
./phase4-coordinator/internal/billing/store.go:1116:BEFORE UPDATE OF settlement_account_scope_hash, settlement_policy_mode, settlement_policy_version ON ledger_request_credits
./phase4-coordinator/internal/billing/store.go:1127:    SELECT RAISE(ABORT, 'invalid ledger_request_credits settlement policy');
./phase4-coordinator/internal/billing/store.go:1130:BEFORE UPDATE OF settlement_account_scope_hash, settlement_policy_mode, settlement_policy_version ON ledger_request_credits
./phase4-coordinator/internal/billing/store.go:1135:    SELECT RAISE(ABORT, 'ledger_request_credits settlement policy is immutable');
./phase4-coordinator/internal/billing/store.go:1145:                 provider_credits, fault_flag ON ledger_request_credits
./phase4-coordinator/internal/billing/store.go:1164:    SELECT RAISE(ABORT, 'settled ledger_request_credits money fields are immutable');
./phase4-coordinator/internal/billing/store.go:1167:BEFORE UPDATE OF settled, settlement_id ON ledger_request_credits
./phase4-coordinator/internal/billing/store.go:1174:    SELECT RAISE(ABORT, 'settled ledger_request_credits settlement link is immutable');
./phase4-coordinator/internal/billing/store.go:1182:CREATE INDEX IF NOT EXISTS idx_lrc_spec022_payable ON ledger_request_credits(
./phase4-coordinator/internal/billing/store.go:1198:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:8:ALTER TABLE IF EXISTS ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:16:    IF to_regclass('public.ledger_request_credits') IS NOT NULL THEN
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:17:        UPDATE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:20:        UPDATE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:23:        UPDATE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:26:        UPDATE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:30:        ALTER TABLE ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:87:      FROM ledger_request_credits
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:93:    INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:168:        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
./phase4-coordinator/internal/billing/settlement_finality.go:470:	  JOIN ledger_request_credits lrc
./phase4-coordinator/internal/billing/endpoints_test.go:804:// providers per account so the ledger_request_credits UNIQUE
./phase4-coordinator/internal/billing/endpoints_test.go:1399:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/buyer/server_test.go:101:	store, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/buyer/server_test.go:3002:	if err := db.QueryRow(`SELECT usage_source, quarantined, quarantine_reason FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).Scan(&usageSource, &quarantined, &reason); err != nil {
./phase4-coordinator/internal/buyer/server_test.go:3113:FROM ledger_request_credits
./phase4-coordinator/internal/buyer/server_test.go:7291:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/server_test.go:7511:	if err := db.QueryRow(`SELECT gross_credits, provider_credits, fault_flag FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).Scan(&gross, &provider, &fault); err != nil {
./phase4-coordinator/internal/buyer/server_test.go:7538:FROM ledger_request_credits
./phase4-coordinator/internal/billing/nested_query_regression_test.go:83:// over ledger_request_credits + per-row h.sum(...) on
./phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql:24:-- `SELECT 1 FROM ledger_request_credits LIMIT 1`. The test harness
./phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql:33:        'ledger_request_credits',
./phase4-coordinator/internal/billing/hotpath.go:74:SELECT 1 FROM ledger_request_credits
./phase4-coordinator/internal/billing/hotpath.go:407:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/billing/store_test.go:26:		"ledger_request_credits",
./phase4-coordinator/internal/billing/store_test.go:51:	if !columnExists(t, db, "ledger_request_credits", "cached_prompt_tokens") {
./phase4-coordinator/internal/billing/store_test.go:52:		t.Fatalf("missing ledger_request_credits.cached_prompt_tokens")
./phase4-coordinator/internal/billing/store_test.go:60:	if columnExists(t, db, "ledger_request_credits", "prompt_cache_hit_rate_per_mtok") {
./phase4-coordinator/internal/billing/store_test.go:61:		t.Fatalf("ledger_request_credits.prompt_cache_hit_rate_per_mtok must not be persisted")
./phase4-coordinator/internal/billing/store_test.go:119:	id := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id='legacy-resolution-row'`)
./phase4-coordinator/internal/billing/store_test.go:120:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason='legacy' WHERE id=?`, id); err != nil {
./phase4-coordinator/internal/billing/store_test.go:128:    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
./phase4-coordinator/internal/billing/store_test.go:178:BEFORE UPDATE OF gross_credits, provider_credits ON ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:195:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:203:	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = 'settled-money-upgrade' AND settled = 0 AND settlement_id IS NULL`); got != 500 {
./phase4-coordinator/internal/billing/store_test.go:213:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:226:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:299:	for _, table := range []string{"request_log", "ledger_request_credits", "ledger_operator_credits", "ledger_provider_identity_snapshots"} {
./phase4-coordinator/internal/billing/store_test.go:305:	if err := store.db.QueryRow(`SELECT id FROM ledger_request_credits`).Scan(&reqCreditID); err != nil {
./phase4-coordinator/internal/billing/store_test.go:329:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:351:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:418:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:429:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1`, row.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:498:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:518:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET ts_utc = ? WHERE request_id = ?`, row.TSUtc.Format(time.RFC3339Nano), row.RequestID); err != nil {
./phase4-coordinator/internal/billing/store_test.go:524:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:561:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_cache' AND gross_credits = 0`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:577:	wantGross := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, baselineRow.RequestID)
./phase4-coordinator/internal/billing/store_test.go:589:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND cached_prompt_tokens IS NULL AND gross_credits = ?`, row.RequestID, wantGross); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:627:	for _, table := range []string{"ledger_request_credits", "ledger_operator_credits", "ledger_provider_identity_snapshots"} {
./phase4-coordinator/internal/billing/store_test.go:644:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:651:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND provider_id = ? AND quarantined = 0`, row.RequestID, input.ProviderID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:657:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:751:	if err := store.db.QueryRow(`SELECT cached_prompt_tokens, gross_credits FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0`, row.RequestID).Scan(&gotCached, &gross); err != nil {
./phase4-coordinator/internal/billing/store_test.go:793:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:832:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:854:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_cache' AND gross_credits = 0`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:881:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:900:	if err := store.db.QueryRow(`SELECT gross_credits, provider_credits, gross_credits-provider_credits, usage_source FROM ledger_request_credits`).Scan(&gross, &provider, &operator, &usage); err != nil {
./phase4-coordinator/internal/billing/store_test.go:931:	if _, err := store.db.Exec(`DELETE FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); err != nil {
./phase4-coordinator/internal/billing/store_test.go:956:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1 AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:999:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1003:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0`, row.RequestID); got != 2 {
./phase4-coordinator/internal/billing/store_test.go:1043:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1066:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1 AND quarantined = 0`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1092:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1 AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1141:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 2 AND quarantined = 1`, row.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1144:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 2 AND quarantined = 0`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1179:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1202:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'missing-identity' AND quarantined = 1 AND quarantine_reason = 'missing_provider_identity'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1217:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'orphan-in' AND quarantined = 1`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1220:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'orphan-out' AND quarantined = 1`); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1233:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'orphan-provider' AND quarantined = 1 AND quarantine_reason = 'missing_request_log'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1242:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settled = 1, settlement_id = 99 WHERE request_id = 'settled-orphan'`); err != nil {
./phase4-coordinator/internal/billing/store_test.go:1249:	if got := scalar(t, store.db, `SELECT quarantined FROM ledger_request_credits WHERE request_id = 'settled-orphan'`); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1268:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'shared-request' AND provider_id = 'bogus-provider' AND quarantined = 1 AND quarantine_reason = 'missing_request_log'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1294:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-usage' AND quarantined = 1 AND quarantine_reason = 'invalid_usage_tokens'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1321:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-existing' AND provider_id = 'provider-a' AND quarantined = 1 AND quarantine_reason = 'invalid_usage_tokens'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1324:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-existing'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1327:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-existing' AND provider_id LIKE '__unresolved__%'`); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1350:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settled = 1, settlement_id = 99 WHERE request_id = 'settled-invalid'`); err != nil {
./phase4-coordinator/internal/billing/store_test.go:1357:	if got := scalar(t, store.db, `SELECT quarantined FROM ledger_request_credits WHERE request_id = 'settled-invalid'`); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1360:	if got := scalar(t, store.db, `SELECT settled FROM ledger_request_credits WHERE request_id = 'settled-invalid'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1381:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'bad-ts' AND quarantined = 1 AND quarantine_reason = 'unparseable_ts_utc'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1401:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'split-mismatch' AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1426:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND fault_flag = ? AND gross_credits = 0 AND provider_credits = 0`, row.RequestID, FaultBreakerQualifying); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1429:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1567:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND gross_credits = 4 AND provider_credits = 4`, route.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1570:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantine_reason = 'reconciliation_mismatch'`, route.RequestID); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:1618:	if got := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); got != 54 {
./phase4-coordinator/internal/billing/store_test.go:1621:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1628:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND quarantine_reason IS NULL`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1631:	if got := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); got != 54 {
./phase4-coordinator/internal/billing/store_test.go:1679:	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
./phase4-coordinator/internal/billing/store_test.go:1681:	UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:1703:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1755:	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
./phase4-coordinator/internal/billing/store_test.go:1757:	UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:1788:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1840:	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
./phase4-coordinator/internal/billing/store_test.go:1842:	UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:1864:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1916:	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
./phase4-coordinator/internal/billing/store_test.go:1918:	UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:1940:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1954:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:1966:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'contract-mismatch' AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1989:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'missing-snapshot-existing' AND quarantined = 1 AND quarantine_reason = 'missing_config_snapshot'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:1992:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'missing-snapshot-existing'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2018:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'recover-failover' AND attempt_n = 1 AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2071:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'recover-third' AND attempt_n = 2 AND quarantined = 1`); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:2074:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'recover-third' AND attempt_n = 2 AND quarantined = 0`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2087:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settled = 1, settlement_id = 42 WHERE request_id = ?`, row.RequestID); err != nil {
./phase4-coordinator/internal/billing/store_test.go:2090:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET gross_credits = gross_credits + 1 WHERE request_id = ?`, row.RequestID); err == nil {
./phase4-coordinator/internal/billing/store_test.go:2097:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'settled-mismatch' AND quarantined = 1`); got != 0 {
./phase4-coordinator/internal/billing/store_test.go:2132:	if got := scalar(t, store.db, `SELECT COUNT(DISTINCT settlement_id) FROM ledger_request_credits WHERE settlement_id IS NOT NULL`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2155:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND settled = 1`); got != 2 {
./phase4-coordinator/internal/billing/store_test.go:2201:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND settled = 0`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2210:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settlement_id = 123 WHERE provider_id = 'provider-a'`); err != nil {
./phase4-coordinator/internal/billing/store_test.go:2220:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND quarantined = 1 AND quarantine_reason = 'conflicting_settlement_id'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2236:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND quarantined = 1 AND quarantine_reason = 'operator_split_mismatch'`); got != 1 {
./phase4-coordinator/internal/billing/store_test.go:2454:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/store_test.go:2478:INSERT INTO ledger_request_credits (
./phase4-coordinator/internal/billing/store_test.go:2493:	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND provider_id = ?`, requestID, providerID)
./phase4-coordinator/internal/billing/quarantine_test.go:50:// insertQuarantinedCredit seeds a ledger_request_credits row with
./phase4-coordinator/internal/billing/quarantine_test.go:56:	id := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, requestID)
./phase4-coordinator/internal/billing/quarantine_test.go:57:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason=? WHERE id=?`, "test_quarantine", id); err != nil {
./phase4-coordinator/internal/billing/quarantine_test.go:213:	if got := scalar(t, store.db, `SELECT quarantined FROM ledger_request_credits WHERE id=?`, id); got != 1 {
./phase4-coordinator/internal/billing/quarantine_test.go:321:	nonQuarantinedID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id=?`, requestID)
./phase4-coordinator/internal/billing/quarantine_test.go:648:	id := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id='force-credit-after-payout'`)
./phase4-coordinator/internal/billing/quarantine_test.go:649:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason='manual review' WHERE id=?`, id); err != nil {
./phase4-coordinator/internal/billing/quarantine_test.go:671:	if got := scalar(t, store.db, `SELECT settled FROM ledger_request_credits WHERE id=?`, id); got != 0 {
./phase4-coordinator/internal/billing/quarantine_test.go:681:	if got := scalar(t, store.db, `SELECT settlement_id FROM ledger_request_credits WHERE id=?`, id); got == payoutID {
./phase4-coordinator/internal/billing/quarantine_test.go:721:		if _, err := store.db.Exec(`UPDATE ledger_request_credits SET ts_utc=? WHERE id=?`, ts, id); err != nil {
./phase4-coordinator/internal/billing/quarantine_test.go:1008:	if err := store.db.QueryRow(`SELECT request_id FROM ledger_request_credits WHERE id = ?`, id).Scan(&requestID); err != nil {
./phase4-coordinator/internal/billing/quarantine_test.go:1013:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/quarantine_test.go:1278:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1 WHERE request_id=?`, openReq); err != nil {
./phase4-coordinator/internal/billing/quarantine_test.go:1284:	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1 WHERE request_id=?`, voidedReq); err != nil {
./phase4-coordinator/internal/billing/quarantine_test.go:1288:	if err := store.db.QueryRow(`SELECT id FROM ledger_request_credits WHERE request_id=?`, voidedReq).Scan(&voidedID); err != nil {
./phase4-coordinator/internal/billing/recovery.go:68:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/recovery.go:82:          AND lpis.attempt_n = ledger_request_credits.attempt_n
./phase4-coordinator/internal/billing/recovery.go:83:          AND lpis.provider_id = ledger_request_credits.provider_id
./phase4-coordinator/internal/billing/recovery.go:84:        WHERE rl.request_id = ledger_request_credits.request_id
./phase4-coordinator/internal/billing/recovery.go:95:          ), 0) = ledger_request_credits.attempt_n
./phase4-coordinator/internal/billing/recovery.go:469:INSERT OR IGNORE INTO ledger_request_credits (
./phase4-coordinator/internal/billing/recovery.go:506:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/recovery.go:588:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/recovery.go:603:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/recovery.go:722:      FROM ledger_request_credits
./phase4-coordinator/internal/billing/recovery.go:744:UPDATE ledger_request_credits
./scripts/tests/test_revenue_benchmark_calculator.py:25:CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY, request_id TEXT, attempt_n INTEGER,
./scripts/tests/test_revenue_benchmark_calculator.py:84:            "INSERT INTO ledger_request_credits(request_id, attempt_n, provider_id, provider_assigned_id, model,"
./scripts/tests/test_revenue_benchmark_calculator.py:246:        self.coord.execute("INSERT INTO ledger_request_credits(request_id, attempt_n, provider_id, provider_assigned_id, model,"
./scripts/tests/test_revenue_benchmark_calculator.py:254:                           " settlement_account_scope_hash FROM ledger_request_credits WHERE request_id='int-0-00'")
./scripts/tests/test_revenue_benchmark_calculator.py:262:        self.coord.execute("UPDATE ledger_request_credits SET completion_tokens=completion_tokens+1 WHERE request_id='int-0-00'")
./scripts/tests/test_revenue_benchmark_calculator.py:293:        self.coord.execute("UPDATE ledger_request_credits SET provider_share_bps=7000,"
./scripts/tests/test_revenue_benchmark_calculator.py:299:        self.coord.execute("UPDATE ledger_request_credits SET model='other/model' WHERE request_id='int-0-00'")
./scripts/tests/test_revenue_benchmark_calculator.py:307:        self.coord.execute("UPDATE ledger_request_credits SET provider_id='prov-other' WHERE request_id='int-0-01'")
./scripts/tests/test_revenue_benchmark_calculator.py:313:        self.coord.execute("UPDATE ledger_request_credits SET usage_source='byte_estimated' WHERE request_id='int-0-02'")
./scripts/tests/test_revenue_benchmark_calculator.py:404:            coord_path, gateway_path = Path(tmp, "coordinator.db"), Path(tmp, "gateway.db")
./phase4-coordinator/internal/billing/settlement_receipts_test.go:52:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 0 {
./phase4-coordinator/internal/billing/settlement_receipts_test.go:53:		t.Fatalf("ledger_request_credits rows=%d want 0; Step 5 must not create buyer debit/provider credit", got)
./phase4-coordinator/internal/billing/settlement_receipts_test.go:311:	UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/settlement_receipts_test.go:341:  FROM ledger_request_credits
./phase4-coordinator/internal/billing/settlement_output_test.go:355:	if err := store.db.QueryRow(`SELECT quarantine_reason FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 0`, input.RequestID).Scan(&attempt0); err != nil {
./phase4-coordinator/internal/billing/settlement_output_test.go:358:	if err := store.db.QueryRow(`SELECT quarantine_reason FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1`, input.RequestID).Scan(&attempt1); err != nil {
./phase4-coordinator/internal/billing/settlement_finality_security_test.go:43:				ledgerRows := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`)
./phase4-coordinator/internal/billing/settlement_finality_security_test.go:59:				if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != ledgerRows {
./phase4-coordinator/internal/billing/spec015_v04_acceptance_test.go:519:	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 0 {
./phase4-coordinator/internal/billing/spec015_v04_acceptance_test.go:520:		t.Fatalf("ledger_request_credits rows=%d want 0 before SPEC-022", got)
./phase4-coordinator/internal/billing/quarantine.go:172:	// ledger_request_credits, NOT on ledger_quarantine_resolutions.
./phase4-coordinator/internal/billing/quarantine.go:181:  FROM ledger_request_credits WHERE id = ?`, requestCreditID)
./phase4-coordinator/internal/billing/quarantine.go:191:		writeValidationError(w, "not_quarantined", "ledger_request_credits row is not quarantined")
./phase4-coordinator/internal/billing/settlement.go:33:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/settlement.go:47:UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/settlement.go:59:            WHERE request_credit_id = ledger_request_credits.id
./phase4-coordinator/internal/billing/settlement.go:64:            WHERE request_credit_id = ledger_request_credits.id
./phase4-coordinator/internal/billing/settlement.go:83:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/settlement.go:166:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/settlement.go:223:UPDATE ledger_request_credits
./scripts/tests/test_byom_journey_evidence.py:1020:            manifest["observations"]["money_path_zero_rows"]["ledger_request_credits"] = 1
./phase4-coordinator/internal/billing/payout_ready.go:359:	// run and does NOT write ledger_request_credits.
./phase4-coordinator/internal/billing/settlement_receipts.go:336:  FROM ledger_request_credits lrc
./phase4-coordinator/internal/billing/settlement_receipts.go:479:		UPDATE ledger_request_credits
./phase4-coordinator/internal/billing/settlement_receipts.go:519:UPDATE ledger_request_credits
./phase4-coordinator/internal/buyer/settlement_unsettled_leg_test.go:25:	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/buyer/billing_recorder_test.go:43:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/billing_recorder_test.go:113:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/billing_recorder_test.go:170:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/billing_recorder_test.go:249:			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/seam_h4_test.go:47:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/buyer/seam_h4_test.go:402:	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE status = 200 AND provider_credits > 0`).Scan(&credits); err != nil {
./phase4-coordinator/internal/buyer/seam_h4_test.go:417:	if err := db.QueryRow(`SELECT quarantined, quarantine_reason FROM ledger_request_credits`).Scan(&quarantined, &reason); err != nil {
./phase4-coordinator/internal/buyer/seam_h4_test.go:457:	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE quarantine_reason = 'settlement_attempt_output_missing'`).Scan(&marked); err != nil {
./phase4-coordinator/internal/buyer/seam_h4_test.go:493:	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE status = 200 AND provider_credits > 0`).Scan(&credits); err != nil {
./phase4-coordinator/internal/buyer/seam_h4_test.go:525:	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits`).Scan(&credits); err != nil {
./audits/2026-09-25-stats-mirror-db-path/SECURITY.md:4:- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
./audits/2026-09-25-stats-mirror-db-path/SECURITY.md:5:- Is there any write path to `coordinator.db` from the mirror?
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:14:  (`ledger_request_credits`) lives in `coordinator.db`, the configured
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:19:- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:23:  - `billingmirror.DefaultSQLitePath`;
./audits/2026-09-25-stats-mirror-db-path/CODE.md:4:- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
./audits/2026-09-25-stats-mirror-db-path/CODE.md:5:- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
./audits/2026-09-25-stats-mirror-db-path/CODE.md:6:- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:14:  (`ledger_request_credits`) lives in `coordinator.db`, the configured
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:19:- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:23:  - `billingmirror.DefaultSQLitePath`;
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:35:- Whether another environment relies on `request-log.sqlite`.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:14:  (`ledger_request_credits`) lives in `coordinator.db`, the configured
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:19:- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:23:  - `billingmirror.DefaultSQLitePath`;
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:34:- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:35:- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:36:- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:14:  (`ledger_request_credits`) lives in `coordinator.db`, the configured
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:19:- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:23:  - `billingmirror.DefaultSQLitePath`;
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:34:- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:35:- Is there any write path to `coordinator.db` from the mirror?
./audits/2026-09-25-stats-mirror-db-path/ARCHITECT.md:5:- Whether another environment relies on `request-log.sqlite`.
./audits/spec-017/SPEC-017-IMPL-STEP_2-security-r1-audit.md:38:- `aggregateWorkPerProvider` correctly joins `ledger_request_credits` to `provider_tokens` before emitting a provider id (`phase4-coordinator/internal/stats/rollup/leaderboard.go:174-188`).
./audits/spec-017/SPEC-017-IMPL-STEP_2-security-r1-audit.md:41:- The existing trust-source integration test covers an unauthenticated `ledger_request_credits` row (`rollup_integration_test.go:581-619`) but does not seed a `provider_rewards_ledger` row for a provider absent from `provider_tokens`.
./audits/2026-06-03/findings-raw.json:1756:        "description": "On the money path, if WriteHotPath fails (e.g. SQLITE_BUSY per finding #2, or any tx error), the code logs a warning and falls back to WriteRequestLogWithIdentity (server.go:888-896), which writes the request_log row + identity snapshot but NOT the ledger_request_credits/operator_credits rows. Provider credit then exists only implicitly in request_log until StartNightlyReconcile/StartStartupScan re-derives it via RecoverLedger. Real-money credit creation is best-effort on the hot path; the system can run up to ~24h under-credited, recovered only if request_log row, identity snapshot, and a matching config snapshot all survive and resolve unambiguously \u2014 ambiguous/identity-missing rows are quarantined instead.",
./audits/2026-06-03/findings-raw.json:1760:        "evidence": "CONFIRMED end-to-end. buyer/server.go:887-896: WriteHotPath error -> Warn log -> WriteRequestLogWithIdentity fallback with NO retry/backoff between them (grep for retry/backoff in hotpath.go and the billing call site found none). WriteRequestLogWithIdentity (hotpath.go:145-172) inserts only the request_log row + ledger_provider_identity_snapshots \u2014 it never calls insertRequestCreditTx/insertOperatorCreditTx, so ledger_request_credits/operator_credits are genuinely absent, exactly as claimed. Recovery is the only backstop: StartNightlyReconcile (recovery.go:288-310) fires once at the next midnight UTC (next = time.Date(...Day()+1...), line 293), and crucially DISCARDS the RecoverLedger error with `_ =` (line 306) \u2014 a failed nightly run is not retried until the following midnight, ~24h later, confirming the no-retry-until-next-cycle claim. RecoverLedger's deferred failure handler writes a status='failed' run row (recovery.go:25-46) but performs no recovery. The quarantine paths are all real: missing_provider_identity / ambiguous_attempt_n (recovery.go:142-150), missing_config_snapshot (152-171), and ambiguous_attempt_n for attemptN>1 (201-219, 233-239) \u2014 quarantined rows are NOT credited. StartupScan (recovery.go:282-285) bounds its window to StartupReconcileWindowHours, so rows older than the window/grace are not re-scanned, confirming the survival caveat. The system genuinely creates provider credit best-effort on the hot path with an eventually-consistent (and silently-failable) safety net. The author correctly frames this as by-design-but-risky; the medium rating is justified because under-crediting is recoverable in the common case yet has real silent-failure and quarantine-stranding modes with no alarming. Medium upheld.",
./audits/2026-06-03/findings-raw.json:2015:        "evidence": "CONFIRMED as an architectural/resilience observation. main.go:85-142 wires one wsServer + one buyerServer + one billingStore in a single process; settlement and reconcile run as in-process goroutines (main.go:132-133). The ledger is a single embedded SQLite file (config.go:293-294 default 'coordinator.db'); hotpath.go:37,151 use BEGIN IMMEDIATE single-writer transactions and store.go enforces journal_mode=WAL (requestlog/store.go:56, billing/store.go:37-41). A repo-wide grep for Litestream/replica/failover/backup found ZERO replication or failover machinery; the only matches are WAL/busy_timeout/BEGIN IMMEDIATE, all single-node primitives. The recent commit c1cfc97 adds fast-fail timeouts explicitly for 'coordinator restart', confirming restart is a live operational event. True single point of failure with no HA path; this is a known-posture/design observation rather than a discrete code defect, but the money-system blast radius justifies medium. Severity upheld.",
./audits/spec-017/SPEC-017-IMPL-STEP_2-code-r4-audit.md:35:   - Evidence: `detectLateEvents` inserts any work row with `EXTRACT(EPOCH FROM lrc.ts_utc) < cutoff` and inside the window (`late_events.go:60-77`), and any rewards row with `prl.unix_ts < cutoff` (`late_events.go:82-99`). It does not filter by an arrival/update watermark such as `ledger_request_credits.created_at_utc` / `updated_at_utc` from SPEC-005 (`phase4-coordinator/internal/billing/store.go:71-72`), nor does it receive the prior `last_ok_at`. The test only inserts the T-60h row after bootstrap (`rollup_integration_test.go:1089-1094`), so it misses ordinary historical T-60h rows that were already included by a full recompute.
./audits/spec-017/SPEC-017-IMPL-STEP_1-code-r1-audit.md:91:Minimal fix: during smoke, assert `SELECT current_user` equals the expected role for each pool and run role-specific deny probes that must return SQLSTATE `42501` rather than success or relation-missing. At minimum, cover `stats_reader` denied on `ledger_request_credits`, `provider_portal` denied on a `stats_*` table, and `stats_rollup` denied on `partner_keys` / `provider_visibility_audit`. Add a real-Postgres integration test that exercises `stats.Open`, not just direct `sql.Open` calls.
./audits/2026-06-03/ARCHITECTURE_AUDIT.md:101:- **What/Description:** If `WriteHotPath` fails (e.g. `SQLITE_BUSY` per the two-pools finding, or any tx error), the code logs a warning and falls back to `WriteRequestLogWithIdentity`, which writes the request_log row + identity snapshot but **not** `ledger_request_credits`/`operator_credits`. Provider credit then exists only implicitly in request_log until `StartNightlyReconcile`/`StartStartupScan` re-derives it via `RecoverLedger`. Real-money credit creation is best-effort on the hot path; the system can run ~24h under-credited, recovered only if the request_log row, identity snapshot, and config snapshot all survive and resolve unambiguously — ambiguous/identity-missing rows are quarantined.
./audits/2026-06-03/ARCHITECTURE_AUDIT.md:133:- **Evidence:** `main.go:85-142` wires one wsServer + one buyerServer + one billingStore in a single process; settlement and reconcile run as in-process goroutines (`:132-133`). The ledger is a single embedded SQLite file (`config.go:293-294`, default `coordinator.db`); `hotpath.go:37,151` use `BEGIN IMMEDIATE`, and WAL is enforced (`requestlog/store.go:56`, `billing/store.go:37-41`). A repo-wide grep for `Litestream`/`replica`/`failover`/`backup` found zero replication/failover machinery — only WAL/busy_timeout/BEGIN IMMEDIATE single-node primitives. Commit `c1cfc97` confirms restart is a live operational event. A design/posture observation rather than a discrete code defect, but the money-system blast radius justifies medium.
./audits/2026-09-16/byom-slice7-e2e-handoff.md:129:   launchd `live.malibu.provider`), `sqlite3 $RIG/coordinator.db "DELETE FROM model_admission_events; DELETE FROM model_admission_pending_decisions;"`,
./audits/2026-09-16/byom-slice7-e2e-handoff.md:136:   `$RIG/secrets.env`: `MACPROVIDER_JOURNEY_OPERATOR_A/B`, `MACPROVIDER_JOURNEY_LEDGER_DSN=sqlite:$RIG/coordinator.db`,
./audits/spec-017/SPEC-017-r4-audit.md:50:    **Finding:** §7.2.2 now concretely grants rollup SELECT on `provider_tokens`, `sessions`, `session_events`, `billing_ledger`, and `request_log`, and says the exact source names are pinned by locked dependencies. `provider_tokens` and `request_log` have locked homes, but `billing_ledger`, `sessions`, and `session_events` are not locked source tables in SPEC-002 v1.4 or SPEC-005 v0.3. SPEC-005's locked ledger tables are `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`, `ledger_config_snapshots`, and `ledger_provider_identity_snapshots`. AC-9 then tests denial on `billing_ledger`, so a relation-not-found result could be confused with a permission-isolation pass while the real locked ledger tables remain untested.
./audits/spec-017/SPEC-017-r4-audit.md:54:    **Suggested fix:** Enumerate the actual locked source tables required by the rollup, or explicitly mark the rollup-source grant list as implementation-authored and non-normative until BUILD_SPEC_017. Update AC-9 to assert denial on at least one real locked SPEC-005 ledger table, such as `ledger_request_credits`.
./phase4-coordinator/internal/requestlog/store.go:130:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(dbPath))
./audits/spec-017/SPEC-017-r5-audit.md:82:- R4 M2 closed as to locked-dependency table drift: §7.2.2 leaves OLTP source reads to IMPL-time enumeration, and AC-9 now uses real SPEC-005 v0.3 tables (`ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`).
./phase4-coordinator/internal/requestlog/store_test.go:379:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/requestlog/store_test.go:540:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
./audits/misc/AUDIT_ISS_168_R3_SECURITY_PROMPT.md:22:  `UPDATE ledger_request_credits SET quarantined=0` SQL" — closes
./phase4-coordinator/internal/audit/store_test.go:16:	if got, want := DefaultDBPath(filepath.Join("var", "lib", "macprovider", "coordinator.db")), filepath.Join("var", "lib", "macprovider", "coordinator-audit.db"); got != want {
./phase4-coordinator/internal/audit/store_test.go:19:	if got := DefaultDBPath("coordinator.db"); got != "coordinator-audit.db" {
./phase4-coordinator/internal/audit/store_test.go:86:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
./phase4-coordinator/internal/audit/store_test.go:244:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
./phase4-coordinator/internal/audit/store_test.go:533:	store, err := OpenStore(t.TempDir() + "/coordinator.db")
./audits/spec-017/SPEC-017-IMPL-STEP_1-arch-r1-audit.md:68:**Fix:** Extend `smoke` to run role-specific SQL: assert `current_user` equals the expected role for each pool, assert the three required roles are distinct, and include one positive and one deny-list query per role. For example, `stats_reader` should SELECT an allowed stats table and fail permission-denied on `ledger_request_credits`; `provider_portal` should fail on `stats_overview_current`; `stats_rollup` should fail on `partner_keys`.
./audits/spec024-final/claude-adversarial-41d800b-20260702T130931Z.md:25:- **N2 — Ledger does not persist `prompt_cache_hit_rate_per_mtok`.** `ledger_request_credits` stores `prompt_rate_per_mtok` / `completion_rate_per_mtok` but not the cache-hit rate actually applied (hotpath.go:296–304; schema store.go:57–90). This is **spec-compliant** — SPEC-024 §4 mandates "exactly one column" (`cached_prompt_tokens`) — and the effective rate remains recoverable by joining `ledger_config_snapshots.rate_card_json` or back-solving from `gross_credits`. Noted only as an auditability observation.
./audits/misc/AUDIT_ISS_197_R4_CODE_PROMPT.md:20:   read-only open. R4 added `sqliteutil.ReadOnlyDSN` that opens with
./audits/misc/AUDIT_ISS_197_R4_CODE_PROMPT.md:36:- `ReadOnlyDSN` — does `mode=ro` actually prevent the journal-mode
./audits/spec-017/SPEC-017-IMPL-PROMPT-code-r7-audit.md:124:- Verified SPEC-005 v0.3 contains the AC-9 ledger tables named by the prompt: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
./audits/spec-017/SPEC-017-IMPL-PROMPT-code-r6-audit.md:42:  `ledger_request_credits`, `ledger_operator_credits`,
./phase4-coordinator/internal/sqliteutil/dsn.go:56:// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
./phase4-coordinator/internal/sqliteutil/dsn.go:63:func ReadOnlyDSN(path string) string {
./audits/spec-017/SPEC-017-IMPL-STEP_1-arch-r2-audit.md:11:No architecture findings. The SPEC-017-owned grant migration keeps `stats_reader`, `stats_rollup`, and `provider_portal` inside the locked §7.2 inventory, skips `partner_keys_writer` by default, and does not grant TRUNCATE / ALTER / DROP. The IMPL-authored OLTP grant list matches the current local dependency specs: SPEC-002 v1.4.0 `provider_tokens` and SPEC-005 v0.3 `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`.
./audits/misc/ARC_3_NESTED_QUERIES_CODE_r2_audit.md:16:- The grouped LEFT JOIN preserves the previous pending_payout_credits shape. Providers in ledger_request_credits with no ready ledger_payout_ready row get COALESCE(..., 0); providers that exist only in ledger_payout_ready are not listed, matching origin/main because the outer listing is ledger_request_credits.
./audits/misc/ARC_3_NESTED_QUERIES_CODE_r2_audit.md:17:- The payout aggregation handles both ledger directions correctly for endpoint semantics: ledger_request_credits-only providers remain listed with zero pending payout, and payout-only providers remain excluded from the provider ledger listing.
./audits/spec-017/AUDIT_SPEC_017_IMPL_STEP_1_ARCH_PROMPT.md:223:     `SELECT 1 FROM ledger_request_credits LIMIT 1` (NOT
./audits/spec-017/AUDIT_SPEC_017_IMPL_STEP_1_ARCH_PROMPT.md:225:     `ledger_request_credits`, `ledger_operator_credits`,
./audits/spec-017/AUDIT_SPEC_017_IMPL_STEP_1_CODE_PROMPT.md:186:     `SELECT 1 FROM ledger_request_credits LIMIT 1` (and at
./audits/_prompts/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:158:     `ledger_request_credits`; no `settlement_id` linkage
./audits/spec-017/SPEC-017-IMPL-PROMPT-code-r11-audit.md:79:- Verified SPEC-005 v0.3 ledger denial targets exist: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
./audits/spec-017/SPEC-017-IMPL-PROMPT-code-r10-audit.md:56:- Verified SPEC-005 ledger denial targets exist: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
./audits/spec-017/SPEC-017-IMPL-STEP_1-code-r4-audit.md:51:- AC-9: `stats_reader` denied on `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`, and `provider_tokens`, asserting permission denied and rejecting relation-missing errors.
./audits/spec-017/SPEC-017-IMPL-PROMPT-code-r9-audit.md:83:- Verified SPEC-005 v0.3 line 3 and table inventory: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs` exist in §4.3-§4.6 and are valid AC-9 denial targets.
./audits/spec-017/SPEC-017-IMPL-PROMPT-code-r8-audit.md:85:- Verified SPEC-005 v0.3 contains `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
./audits/_prompts/BUILD_SPEC_PREFIX_CACHE_BILLING_PROMPT.md:36:One paragraph, roughly: "SPEC-024 specifies the billing treatment for provider-reported prefix-cache reuse on sticky-affinity conversations (SPEC-004 §FR-SR-*). It defines a provider-reported `cached_prompt_tokens` field on the coordinator-provider usage report (SPEC-002), a new `cached_prompt_tokens` column on `ledger_request_credits` (SPEC-005), an additive rate-card row `prompt_cache_hit_rate_per_mtok`, an updated billing formula that credits the cached fraction at the discounted rate, and a mirror field in the buyer-visible OpenAI-shape usage object (SPEC-006)."
./audits/_prompts/BUILD_SPEC_PREFIX_CACHE_BILLING_PROMPT.md:58:Add exactly one column to `ledger_request_credits`:
./audits/misc/ARC_3_NESTED_QUERIES_ARCHITECT_audit.md:7:      Evidence: phase4-coordinator/internal/billing/endpoints.go:147 builds the per-provider aggregate from `ledger_request_credits`, but phase4-coordinator/internal/billing/endpoints.go:198 still runs one `h.sum(...)` per provider for `ledger_payout_ready`; phase4-coordinator/internal/billing/store.go:100 and phase4-coordinator/internal/billing/store.go:119 show `ledger_payout_ready` has the provider/status shape needed for a grouped join or CTE.
./audits/2026-08-05/ROOT_CAUSE_prompt-token-reconciliation-freeze.md:14:`request_log.prompt_tokens = ledger_request_credits.prompt_tokens =
./audits/2026-08-05/ROOT_CAUSE_prompt-token-reconciliation-freeze.md:154:mutation. The operator must approve the exact `ledger_request_credits.id` list
./audits/misc/AUDIT_ISS_168_R3_CODE_PROMPT.md:21:  execute direct `UPDATE ledger_request_credits SET quarantined=0`
./docs/runbooks/byom-journey-evidence.md:242:ledger_request_credits       payout_attempts            request_log
./audits/_prompts/BUILD_SPEC_014_PROMPT.md:439:        `ledger_request_credits` data. Same disposition as C.3:
./audits/misc/ARC_3_NESTED_QUERIES_SECURITY_r2_audit.md:3:  L1: PASS — the provider aggregate and ready-payout aggregate are read by one SQLite SELECT; under WAL this is one read snapshot, so concurrent writes cannot produce a mixed buyer-visible view across `ledger_request_credits` and `ledger_payout_ready`.
./audits/misc/AUDIT_ISS_169_R1_ARCH_PROMPT.md:21:  the right shape vs. e.g. extending `ledger_request_credits` with a
./audits/_prompts/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md:235:The current implementation writes `ledger_request_credits` and
./docs/research/RESEARCH_744_BUYER_TTFT_CEILING_CALIBRATION.md:4:Host: Pearl `coordinator.db` (read-only sqlite3)  
./docs/research/RESEARCH_744_BUYER_TTFT_CEILING_CALIBRATION.md:21:   `/var/lib/macprovider/coordinator.db`, `gateway.db`, and Postgres
./audits/_prompts/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md:337:   successful provider attempt writes the `ledger_request_credits`
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:79:`ledger_request_credits` immediately; the weekly job reads the prior
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:118:`ledger_request_credits`). At or above threshold, the weekly job emits
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:129:`ledger_request_credits` row stores `provider_share_bps` as an
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:157:An advisory `overshoot_flag` column on `ledger_request_credits` MAY
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:193:  `ledger_request_credits` row is written. (Distinct from the
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:205:`request_log`, `ledger_request_credits`, and `ledger_operator_credits`
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:213:no matching `ledger_request_credits` row, and write a recovery row
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:215:the same scan across the prior 7 days. Any `ledger_request_credits`
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:227:`ledger_request_credits` MUST be keyed by `(request_id, attempt_n,
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:262:- `ledger_request_credits` MUST write a row for every request that
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:369:**8. Append-only with one exception.** `ledger_request_credits` is
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:506:   `ledger_request_credits`, `ledger_operator_credits`,
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:617:      `ledger_request_credits` rows with distinct (attempt_n,
./audits/_prompts/BUILD_SPEC_005_PROMPT.md:631:    - AC-SPLIT: every `ledger_request_credits` row has
./audits/_prompts/FIX_SPEC_005_V0_2_PROMPT.md:252:**Audit location:** § 4.3 (CHECK constraint on `ledger_request_credits.usage_source`), § 6.2.
./audits/_prompts/FIX_SPEC_005_V0_2_PROMPT.md:258:while § 6.2 explicitly states no `ledger_request_credits` row is written
./audits/_prompts/FIX_SPEC_005_V0_2_PROMPT.md:269:  zero ledger rows of any kind (no `ledger_request_credits`, no
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:179:- `ledger_request_credits`: `UNIQUE(request_id, attempt_n, provider_id)`
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:265:// (ledger_request_credits + ledger_operator_credits +
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:323:   b. Insert into `ledger_request_credits` (all fields from § 4.3).
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:325:      referencing the new ledger_request_credits.id.
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:345:// creditable but have no matching ledger_request_credits row.
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:368:AND status != 503 AND NOT already in ledger_request_credits for this
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:377:// RunSettlement scans unsettled ledger_request_credits rows per
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:382://   UPDATE ledger_request_credits SET settled=1, settlement_id=<id>
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:451:SUM(gross_credits) FROM ledger_request_credits WHERE quarantined=0`.
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:455:Quarantined count: `SELECT COUNT(*) FROM ledger_request_credits WHERE
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:457:Fault count: `SELECT COUNT(*) FROM ledger_request_credits WHERE
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:479:models_served (DISTINCT model from ledger_request_credits), rate_card
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:600:ledger_request_credits, ledger_operator_credits, and
./audits/_prompts/BUILD_SPEC_005_IMPL_PROMPT.md:613:verify exactly one ledger_request_credits row exists after both calls.
./audits/_prompts/BUILD_SPEC_024_PREFIX_CACHE_BILLING_IMPL_PROMPT.md:60:- `ledger_request_credits` gains one additive nullable insert-only
./audits/_prompts/BUILD_SPEC_024_PREFIX_CACHE_BILLING_IMPL_PROMPT.md:146:1. Add `cached_prompt_tokens INTEGER NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens))` to `ledger_request_credits`.
./audits/_prompts/BUILD_SPEC_003_PROMPT.md:241:  - Persistence: provisional admissions written to coordinator.db
./audits/_prompts/BUILD_SPEC_017_IMPL_PROMPT.md:164:  - PLUS IMPL-authored SELECT grants on the locked SPEC-002 + SPEC-005 OLTP source tables (the SPEC-005 v0.3 ledger tables defined in §4.3-§4.8 — typically `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs` — plus `provider_tokens` from SPEC-002 §7). SPEC-005 §10 covers crash recovery and reconciliation, not table definitions. Re-verify the dependency-line-3 versions at IMPL time per §1 prereq 3.
./audits/_prompts/BUILD_SPEC_017_IMPL_PROMPT.md:190:- Integration (AC-9, mapped here from the AC matrix below): `stats_reader` returns permission-denied on `SELECT 1 FROM ledger_request_credits LIMIT 1` (NOT "relation does not exist"). Verify against at least one of `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs` (the locked SPEC-005 v0.3 tables, re-verified at IMPL time).

exec
/bin/bash -lc "printf '%s\\n' '---CHANGED FILES---'; git diff --name-status origin/main...HEAD; printf '%s\\n' '---DIFF---'; git diff --unified=25 origin/main...HEAD -- phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go; printf '%s\\n' '---CURRENT LEGACY PATHS IN PRODUCT/TEST SOURCES---'; rg -n --glob '"'!audits/**'"' --glob '"'!journeys/**'"' --glob '"'!docs/**'"' --glob '"'!specs/**'"' 'request-log\\.sqlite' phase4-coordinator scripts test specs .github 2>/dev/null || true; printf '%s\\n' '---CURRENT COORDINATOR PATHS IN MIRROR/DEPLOY SURFACES---'; rg -n 'coordinator\\.db|ReadOnlyPaths|ReadOnlyDSN|DefaultSQLitePath|acl|ACL|rollback|restore' phase4-coordinator/cmd/stats-billing-mirror phase4-coordinator/internal/stats/billingmirror phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 110ms:
---CURRENT LEGACY PATHS IN PRODUCT/TEST SOURCES---
phase4-coordinator/cmd/coordinator/main_test.go:64:	reqLogStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:196:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:246:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:310:	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
---CURRENT COORDINATOR PATHS IN MIRROR/DEPLOY SURFACES---
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:45:  fail "deploy script must grant narrow SQLite file ACL"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:46:grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:47:  fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:90:grep -q 'restore_regular had-coordinator coordinator' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:91:  fail "catalog rollback must restore the previous coordinator binary"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:93:grep -q 'restore_regular had-config coordinator.yaml' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:94:  fail "catalog rollback must restore the previous coordinator config"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:96:  grep -q 'restore_regular had-overlay coordinator.pearl-overlays.yaml' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:97:  fail "catalog rollback must restore the previous coordinator overlay"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:100:  fail "catalog rollback must preserve overlay dated backup collisions"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:103:  fail "deploy must arm rollback before replacing live coordinator files"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:105:grep -q '_rollback_stage=.*stage' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:106:  fail "deploy must construct rollback state outside the published snapshot path"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:108:grep -q 'touch.*_rollback_stage/complete' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:109:  fail "deploy must mark a fully constructed rollback snapshot"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:111:grep -q 'mv.*_rollback_stage.*_rollback' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:112:  fail "deploy must atomically publish the complete rollback snapshot"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:114:grep -q 'restore_link_or_file had-service-unit macprovider-coordinator.service' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:115:  fail "coordinator rollback must restore the previous systemd unit"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:118:  fail "coordinator rollback must remove a newly staged uncommitted release"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:120:grep -q 'restore_link_or_file had-wants-link' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:121:  fail "coordinator rollback must preserve exact service enablement or masking state"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:124:  fail "coordinator rollback must preserve its durable recovery guard"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:127:  fail "coordinator rollback must preserve the prior catalog bridge state"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:129:grep -q 'had-tier2-catalog' "$DEPLOY_SH" && grep -q 'restore_regular had-tier2-catalog' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:130:  fail "coordinator rollback must preserve the exact Tier-2 signed catalog"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:132:grep -q 'had-coordinator-cli' "$DEPLOY_SH" && grep -q 'restore_regular had-coordinator-cli' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:133:  fail "coordinator rollback must preserve the matching operator CLI"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:140:    fail "coordinator rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:148:    fail "nginx rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:152:  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:153:  fail "request-log ACL changes must be captured and restored"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:156:  fail "rollback must validate and activate the restored nginx graph"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:161:commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:222:grep -q 'CRITICAL: coordinator deploy rollback failed' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:223:  fail "deploy must report rollback failure distinctly"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:564:  fail "catalog runbook must prefetch without mutation and document bounded emergency rollback"
phase4-coordinator/dist/stats-billing-mirror.service:7:ConditionPathExists=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:14:ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:312:    echo "           M0-5 instrumentation (PR #18) and the rollback gate is bypassed." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:320:    echo "       (deployed binary does not match the exact local release tag — rollback before commit)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1076:# Issue #582 (MEDIUM #6) — stats-inventory-sync restore-on-failure state.
phase4-coordinator/dist/deploy-pearl-vps.sh:1083:# by the EXIT trap through _sidecar_restore_on_abort.
phase4-coordinator/dist/deploy-pearl-vps.sh:1088:#   own rollback deliberately leaves the sidecar stopped — the sidecar is LEFT
phase4-coordinator/dist/deploy-pearl-vps.sh:1093:_sidecar_restore_on_abort() {
phase4-coordinator/dist/deploy-pearl-vps.sh:1098:  # rollback owns sidecar restoration and DELIBERATELY leaves it stopped pending
phase4-coordinator/dist/deploy-pearl-vps.sh:1101:    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — the armed rollback leaves the old 2-column sidecar stopped against the migrated 3-column schema; see coordinator-deploy-recover runbook)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1137:    echo "coordinator deploy: stats-inventory-sync restored to its pre-deploy state (safe early abort — schema/binary parity never crossed)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1139:    echo "coordinator deploy: WARNING could not restore stats-inventory-sync after early abort; verify its enabled/active state manually" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1196:        test ! -d /opt/macprovider/.coordinator-deploy-rollback
phase4-coordinator/dist/deploy-pearl-vps.sh:1199:        echo "coordinator deploy rollback completed" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1202:        echo "CRITICAL: coordinator deploy rollback failed; snapshot preserved at /opt/macprovider/.coordinator-deploy-rollback" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1207:  _sidecar_restore_on_abort "$_deploy_rc"
phase4-coordinator/dist/deploy-pearl-vps.sh:1217:# race rollback against a still-running mutation SSH session.
phase4-coordinator/dist/deploy-pearl-vps.sh:1322:# config drift checks or a new rollback baseline.
phase4-coordinator/dist/deploy-pearl-vps.sh:1323:if $SSH 'test -d /opt/macprovider/.coordinator-deploy-rollback'; then
phase4-coordinator/dist/deploy-pearl-vps.sh:1326:    echo "aborting deploy: rollback snapshot exists but recovery helper is missing" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1327:    echo "  Preserve /opt/macprovider/.coordinator-deploy-rollback and recover it manually." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1867:    echo "  Use the reviewed enforcement or rollback transaction for that state transition." >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:2077:# rollback transaction is armed, so its inactive state is what the step-4
phase4-coordinator/dist/deploy-pearl-vps.sh:2078:# snapshot records: a rollback restores the pre-019 binary but deliberately
phase4-coordinator/dist/deploy-pearl-vps.sh:2081:# Issue #582 (MEDIUM #6) — ARM the restore-on-failure path BEFORE quiescing:
phase4-coordinator/dist/deploy-pearl-vps.sh:2083:# the sidecar's prior enable/active state so a safe early abort can restore it,
phase4-coordinator/dist/deploy-pearl-vps.sh:2267:    # binary against a migrated schema. (The restore path itself is also safe: it
phase4-coordinator/dist/deploy-pearl-vps.sh:3031:log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
phase4-coordinator/dist/deploy-pearl-vps.sh:3034:# in that case the EXIT trap restores every release artifact touched after this
phase4-coordinator/dist/deploy-pearl-vps.sh:3036:# nginx files, request-log ACLs, config, and catalog pointers.
phase4-coordinator/dist/deploy-pearl-vps.sh:3040:  _rollback=/opt/macprovider/.coordinator-deploy-rollback
phase4-coordinator/dist/deploy-pearl-vps.sh:3041:  _rollback_stage=\$_rollback.stage.\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh:3043:  if [ -e \"\$_rollback\" ] || [ -L \"\$_rollback\" ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3048:  rm -rf \"\$_rollback_stage\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3049:  mkdir \"\$_rollback_stage\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3050:  trap 'rm -rf \"\$_rollback_stage\"' EXIT HUP INT TERM
phase4-coordinator/dist/deploy-pearl-vps.sh:3051:  chown root:root \"\$_rollback_stage\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3052:  chmod 0700 \"\$_rollback_stage\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3059:        echo \"unsafe rollback source: \$_source\" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:3062:      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3063:      touch \"\$_rollback_stage/\$_marker\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3068:      touch \"\$_rollback_stage/\$2\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3071:  snapshot_acl() {
phase4-coordinator/dist/deploy-pearl-vps.sh:3076:      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3077:      touch \"\$_rollback_stage/\$_marker\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3082:    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3083:    touch \"\$_rollback_stage/had-coordinator\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3087:  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3091:  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3097:    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3098:    touch \"\$_rollback_stage/had-config\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3105:    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3106:    touch \"\$_rollback_stage/had-tier2-catalog\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3109:    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3110:    touch \"\$_rollback_stage/had-service-unit\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3139:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3146:    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3147:    touch \"\$_rollback_stage/had-wants-link\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3150:    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3151:    touch \"\$_rollback_stage/had-recovery-helper\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3154:    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3155:    touch \"\$_rollback_stage/had-recovery-unit\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3158:    cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3159:    touch \"\$_rollback_stage/had-watchdog-unit\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3162:    cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3163:    touch \"\$_rollback_stage/had-guard-dropin\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3170:  printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3172:    cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3173:    touch \"\$_rollback_stage/had-previous-target\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3176:    touch \"\$_rollback_stage/release-was-absent\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3178:  printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3180:    touch \"\$_rollback_stage/service-was-active\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3182:  touch \"\$_rollback_stage/complete\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3183:  mv \"\$_rollback_stage\" \"\$_rollback\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3189:# create non-rollbackable database effects before the catalog canary passes.
phase4-coordinator/dist/deploy-pearl-vps.sh:3584:  # SQLite ledger files via file ACLs below.
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3631:    # can appear while the old coordinator is still running; granting an ACL
phase4-coordinator/dist/deploy-pearl-vps.sh:3632:    # to a newly appeared, unsnapshotted file would make exact rollback
phase4-coordinator/dist/deploy-pearl-vps.sh:3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3639:    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh:4103:  # apply; the immutable release staged above stays for forensics/rollback.
phase4-coordinator/dist/deploy-pearl-vps.sh:4184:  touch /opt/macprovider/.coordinator-deploy-rollback/restart-attempted
phase4-coordinator/dist/deploy-pearl-vps.sh:4224:# mismatched versions are fatal while rollback is still armed; otherwise a clean
phase4-coordinator/dist/deploy-pearl-vps.sh:4226:# See audits/2026-06-10/ROLLBACK_PROCEDURE.md for the rollback path.
phase4-coordinator/dist/deploy-pearl-vps.sh:4867:  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4869:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4882:  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4884:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh:4886:    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
phase4-coordinator/dist/deploy-pearl-vps.sh:4911:  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-timer-was-active ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4913:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-service-was-active ] || systemctl start stats-hardware-verifier.service
phase4-coordinator/dist/deploy-pearl-vps.sh:4918:  touch /opt/macprovider/.coordinator-deploy-rollback/committed
phase4-coordinator/cmd/stats-billing-mirror/main.go:14:	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
phase4-coordinator/internal/stats/billingmirror/mirror.go:22:	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/stats/billingmirror/mirror.go:214:		opts.SQLitePath = DefaultSQLitePath
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))

exec
/bin/bash -lc 'git rev-parse --verify origin/main; git rev-parse --verify HEAD; git log --oneline --decorate -8; git diff --stat origin/main...HEAD; git diff --name-only origin/main...HEAD; git show --stat --oneline --decorate HEAD' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 81ms:
c6c326927 (HEAD -> fix/stats-mirror-coordinator-db, tag: v1.8.197, origin/main, origin/fix/stats-mirror-coordinator-db, origin/HEAD, main) Point the stats billing mirror at the coordinator DB that holds the ledger
 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)

codex
The requested range currently resolves to an empty diff because both `origin/main` and `HEAD` point at `c6c326927`; the review commit is nevertheless present as `HEAD` and its parent is `1148185e7`. I’m auditing the effective change via `HEAD^..HEAD` and will call out this ref-state fact in the evidence.
exec
/bin/bash -lc 'git diff --find-renames --unified=30 HEAD''^ HEAD -- phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
diff --git a/phase4-coordinator/cmd/stats-billing-mirror/main.go b/phase4-coordinator/cmd/stats-billing-mirror/main.go
index 210cdaa4e..47f95fabf 100644
--- a/phase4-coordinator/cmd/stats-billing-mirror/main.go
+++ b/phase4-coordinator/cmd/stats-billing-mirror/main.go
@@ -1,29 +1,29 @@
 package main
 
 import (
 	"context"
 	"flag"
 	"fmt"
 	"os"
 
 	"github.com/augstar/macprovider-coordinator/internal/stats/billingmirror"
 )
 
 func main() {
 	var opts billingmirror.Options
-	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/request-log.sqlite")
+	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
 	flag.StringVar(&opts.PostgresDSN, "dsn", "", "Postgres DSN; defaults to STATS_BILLING_MIRROR_DSN")
 	flag.IntVar(&opts.BatchSize, "batch-size", billingmirror.DefaultBatchSize, "maximum request-credit rows to fetch per batch")
 	flag.Int64Var(&opts.OverlapRows, "overlap-rows", billingmirror.DefaultOverlapRows, "number of recent SQLite row IDs to re-read every run")
 	flag.IntVar(&opts.SweepRows, "sweep-rows", 0, "historical primary-key sweep rows to refresh per run; defaults to batch-size")
 	flag.IntVar(&opts.MaxBatches, "max-batches", 5, "maximum new-row batches to process per run")
 	flag.BoolVar(&opts.EnsureSchema, "ensure-schema", true, "create/upgrade the narrow Postgres mirror schema before syncing")
 	flag.BoolVar(&opts.DryRun, "dry-run", false, "read SQLite and print counts without writing Postgres")
 	flag.Parse()
 	opts.Stdout = os.Stdout
 
 	if _, err := billingmirror.Run(context.Background(), opts); err != nil {
 		fmt.Fprintf(os.Stderr, "stats-billing-mirror: %v\n", err)
 		os.Exit(1)
 	}
 }
diff --git a/phase4-coordinator/dist/deploy-pearl-vps.sh b/phase4-coordinator/dist/deploy-pearl-vps.sh
index 3f00b577b..8bc28cb76 100755
--- a/phase4-coordinator/dist/deploy-pearl-vps.sh
+++ b/phase4-coordinator/dist/deploy-pearl-vps.sh
@@ -3111,63 +3111,63 @@ $SSH "set -e
   fi
   snapshot_node /etc/systemd/system/stats-inventory-sync.service stats-inventory-sync.service had-stats-inventory-service
   snapshot_node /etc/systemd/system/stats-inventory-sync.timer stats-inventory-sync.timer had-stats-inventory-timer
   snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
   snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
   snapshot_node /etc/systemd/system/stats-hardware-verifier.service stats-hardware-verifier.service had-stats-hardware-service
   snapshot_node /etc/systemd/system/stats-hardware-verifier.timer stats-hardware-verifier.timer had-stats-hardware-timer
   snapshot_node /etc/systemd/system/timers.target.wants/stats-inventory-sync.timer stats-inventory-sync.wants had-stats-inventory-wants
   snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
   snapshot_node /etc/systemd/system/timers.target.wants/stats-hardware-verifier.timer stats-hardware-verifier.wants had-stats-hardware-wants
   snapshot_active stats-inventory-sync.timer stats-inventory-timer-was-active
   snapshot_active stats-inventory-sync.service stats-inventory-service-was-active
   snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
   snapshot_active stats-billing-mirror.service stats-billing-service-was-active
   snapshot_active stats-hardware-verifier.timer stats-hardware-timer-was-active
   snapshot_active stats-hardware-verifier.service stats-hardware-service-was-active
 
   snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
   snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
   snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
   snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
   snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
   snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
   snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
   snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
   snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
   snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
 
   if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
     snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
   fi
   if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
     cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
     touch \"\$_rollback_stage/had-wants-link\"
   fi
   if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
     cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
     touch \"\$_rollback_stage/had-recovery-helper\"
   fi
   if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
     cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
     touch \"\$_rollback_stage/had-recovery-unit\"
   fi
   if [ -e /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ]; then
     cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
     touch \"\$_rollback_stage/had-watchdog-unit\"
   fi
   if [ -e /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ] || [ -L /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ]; then
     cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
     touch \"\$_rollback_stage/had-guard-dropin\"
   fi
   _catalog_target=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
   case \"\$_catalog_target\" in
     ''|releases/*) ;;
     *) echo \"invalid existing autotune current target: \$_catalog_target\" >&2; exit 1 ;;
   esac
   printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
   if [ -f /opt/macprovider/autotune/.previous-target ]; then
     cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
     touch \"\$_rollback_stage/had-previous-target\"
@@ -3605,64 +3605,64 @@ $SSH "set -e
   else
     echo '  preserving live /opt/macprovider/coordinator.yaml'
   fi
   if [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
     install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
   elif [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
     install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
   fi
   install -d -o root -g macprovider -m 0750 /etc/macprovider
   if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ] && [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
     echo 'refusing unsafe coordinator overlay path: /etc/macprovider/coordinator.pearl-overlays.yaml' >&2
     exit 1
   fi
   if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
     printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
     install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
   fi
   install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
   install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
   install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
   install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
   install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
   install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
   install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
   if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
     # Mutate only objects captured at the transaction boundary. WAL/SHM files
     # can appear while the old coordinator is still running; granting an ACL
     # to a newly appeared, unsnapshotted file would make exact rollback
     # impossible.
     [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
-    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
-  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
+    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
+    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
+    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
+  elif [ -f /var/lib/macprovider/coordinator.db ]; then
     echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
   fi
   # Stage the complete immutable catalog release. Activation happens only
   # after the late connected-provider safeguard immediately before restart.
   _autotune_root=/opt/macprovider/autotune
   _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
   _autotune_lock=\$_autotune_release.lock
   _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
   install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
   if ! mkdir \$_autotune_lock; then
     echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
     exit 1
   fi
   trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
   rm -rf \$_autotune_stage
   install -d -o root -g macprovider -m 0750 \$_autotune_stage
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
   install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
   python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
   sync
   if [ -e \$_autotune_release ]; then
     if ! diff -qr \$_autotune_stage \$_autotune_release >/dev/null; then
       echo 'catalog release envelope $AUTOTUNE_RELEASE_DIR_NAME already exists with different bytes' >&2
@@ -4843,61 +4843,61 @@ $SSH 'set -e
       systemctl disable --now stats-inventory-sync.timer
       systemctl stop stats-inventory-sync.service
       assert_stats_inventory_quiescent
       touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
       echo "stats inventory timer remains disabled: pre-existing schema/binary parity marker requires a matching sidecar promotion"
       ;;
     absent) ;;
     *)
       echo "aborting deploy: invalid stats-inventory parity state at final activation" >&2
       exit 13
       ;;
   esac
   if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
     systemctl enable --now stats-inventory-sync.timer
     if ! systemctl start stats-inventory-sync.service; then
       systemctl disable --now stats-inventory-sync.timer
       systemctl stop stats-inventory-sync.service
       assert_stats_inventory_quiescent
       echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
       journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
     else
       rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
       systemctl is-active stats-inventory-sync.timer
     fi
   elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
     systemctl start stats-inventory-sync.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
   elif [ "$_parity_required" = absent ]; then
     echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
   fi
-  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
+  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
     systemctl enable --now stats-billing-mirror.timer
     if ! systemctl start stats-billing-mirror.service; then
       systemctl disable --now stats-billing-mirror.timer
       echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
       journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
       exit 13
     fi
     systemctl is-active stats-billing-mirror.timer
   elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
     systemctl start stats-billing-mirror.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
   else
     echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
   fi
   if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
     systemctl enable --now stats-hardware-verifier.timer
     # FIX 7 (issue #582): when hardware-trust approval is enabled (both onboarding
     # trust DSNs configured), the verifier is the only thing that promotes an
     # approved waiting_trust job to verified. A failed INITIAL run must fail the
     # deploy (fatal) rather than be a warning, or operators could commit approvals
     # against a coordinator whose verifier never runs. When approval is NOT enabled
     # the initial run stays best-effort (warn), matching prior behavior.
     hardware_trust_approval_enabled=0
     if [ -r /etc/macprovider/coordinator.env ] \
        && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_REQUEST_DSN=" /etc/macprovider/coordinator.env \
        && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_APPROVE_DSN=" /etc/macprovider/coordinator.env; then
       hardware_trust_approval_enabled=1
     fi
     if ! systemctl start stats-hardware-verifier.service; then
       journalctl -u stats-hardware-verifier.service -n 30 --no-pager || true
diff --git a/phase4-coordinator/dist/stats-billing-mirror.service b/phase4-coordinator/dist/stats-billing-mirror.service
index 056cf4f47..0fbb75a51 100644
--- a/phase4-coordinator/dist/stats-billing-mirror.service
+++ b/phase4-coordinator/dist/stats-billing-mirror.service
@@ -1,28 +1,28 @@
 [Unit]
 Description=MacProvider stats billing mirror
 Documentation=https://github.com/augstar/macprovider-poc
 Wants=network-online.target
 After=network-online.target
 ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
-ConditionPathExists=/var/lib/macprovider/request-log.sqlite
+ConditionPathExists=/var/lib/macprovider/coordinator.db
 
 [Service]
 Type=oneshot
 User=macprovider-stats
 Group=macprovider-stats
 EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
-ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false
+ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
 Nice=10
 IOSchedulingClass=best-effort
 IOSchedulingPriority=7
 NoNewPrivileges=true
 PrivateDevices=true
 PrivateTmp=true
 ProtectHome=true
 ProtectSystem=strict
-ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite
-ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-wal
-ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-shm
+ReadOnlyPaths=/var/lib/macprovider/coordinator.db
+ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
+ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
 InaccessiblePaths=/etc/macprovider
 InaccessiblePaths=-/opt/macprovider/coordinator.yaml
 InaccessiblePaths=-/var/lib/macprovider/coordinator.db
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index 292e99c4c..4ac03a779 100755
--- a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
+++ b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
@@ -121,61 +121,61 @@ grep -q 'restore_link_or_file had-wants-link' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve exact service enablement or masking state"
 
 grep -q 'had-recovery-helper' "$DEPLOY_SH" && grep -q 'had-recovery-helper' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve its durable recovery guard"
 
 grep -q 'had-previous-target' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve the prior catalog bridge state"
 
 grep -q 'had-tier2-catalog' "$DEPLOY_SH" && grep -q 'restore_regular had-tier2-catalog' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve the exact Tier-2 signed catalog"
 
 grep -q 'had-coordinator-cli' "$DEPLOY_SH" && grep -q 'restore_regular had-coordinator-cli' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve the matching operator CLI"
 
 for marker in had-stats-inventory-binary had-stats-billing-binary had-stats-hardware-binary \
   had-stats-inventory-service had-stats-inventory-timer \
   had-stats-billing-service had-stats-billing-timer \
   had-stats-hardware-service had-stats-hardware-timer; do
   grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
     fail "coordinator rollback coverage missing for $marker"
 done
 
 for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
   had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
   had-nginx-stats-proxy-partner had-nginx-coordinator-site \
   had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
   grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
     fail "nginx rollback coverage missing for $marker"
 done
 
-grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
+grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
   grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
   fail "request-log ACL changes must be captured and restored"
 
 grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
   fail "rollback must validate and activate the restored nginx graph"
 
 freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 [ -n "$freeze_line" ] && [ -n "$binary_install_line" ] && [ "$freeze_line" -lt "$binary_install_line" ] ||
   fail "stats sidecars must freeze before transaction binaries are replaced"
 [ -n "$sidecar_activate_line" ] && [ -n "$commit_line" ] && [ "$sidecar_activate_line" -lt "$commit_line" ] ||
   fail "stats sidecars must reactivate only as the final pre-commit mutation"
 
 grep -q 'flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" ||
   fail "deploy must hold a controller-lifetime remote lock"
 
 grep -q 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" &&
   grep -q 'unsafe global Pearl deployment lock' "$DEPLOY_SH" ||
   fail "direct deploy and signed updater must share one validated global mutation lock"
 
 grep -q 'cmp -s \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" &&
   ! grep -q 'install -o root -g macprovider -m 0750 \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" ||
   fail "direct catalog deploy must not replace one half of the signed coordinator/gateway pair"
 
 grep -qF 'tier2_require_hash_verified()' "$DEPLOY_SH" &&
   grep -qF 'tracked-config deploy cannot change tier2.require_hash_verified' "$DEPLOY_SH" &&
   grep -qF 'if [ "$CONFIG_MODE" = "apply-tracked" ]; then' "$DEPLOY_SH" ||
   fail "tracked-config deploy must hard-block every Tier-2 enforcement state transition"
diff --git a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
index 9a2075ab5..8d8816853 100755
--- a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
+++ b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
@@ -14,90 +14,90 @@ BOOTSTRAP_SQL="$DIST_DIR/stats-billing-mirror-bootstrap.sql"
 MIGRATION_SQL="$DIST_DIR/../internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql"
 MIRROR_GO="$DIST_DIR/../internal/stats/billingmirror/mirror.go"
 
 fail() {
   echo "FAIL: $*" >&2
   exit 1
 }
 
 for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL" "$MIGRATION_SQL" "$MIRROR_GO"; do
   [ -f "$f" ] || fail "missing required file: $f"
 done
 
 grep -qF 'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror binary variable"
 grep -qF 'STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror service variable"
 grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror timer variable"
 grep -qF '$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror binary upload"
 grep -qF 'for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY"' "$DEPLOY_SH" ||
   fail "deploy preflight must require billing mirror binary"
 grep -qF '"$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER"' "$DEPLOY_SH" ||
   fail "deploy preflight must require billing mirror unit files"
 grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror service upload"
 grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror timer upload"
 grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror binary install"
-grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" ||
+grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
   fail "deploy script must grant narrow SQLite file ACL"
 grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
   fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
-grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats' "$DEPLOY_SH" ||
+grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
   fail "deploy script must only enable mirror when stats user can read sqlite source"
 grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror service install"
 grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror timer install"
-grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ]' "$DEPLOY_SH" ||
+grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
   fail "deploy script must only enable timer when env and SQLite source exist"
 grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
   fail "deploy script must disable the billing mirror timer after a failed initial run"
 grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
   fail "deploy script must fail closed when the configured billing mirror cannot run"
 
 grep -qxF 'User=macprovider-stats' "$SERVICE" ||
   fail "billing mirror must run as dedicated stats user"
 grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
   fail "billing mirror must run with dedicated stats group"
 grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
   fail "billing mirror service must be opt-in on env file"
-grep -qxF 'ConditionPathExists=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
+grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
   fail "billing mirror service must require the SQLite source"
 grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
   fail "billing mirror service must read isolated env file"
-grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false' "$SERVICE" ||
+grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
   fail "billing mirror service must execute from deploy path"
-grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
+grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
   fail "billing mirror service must read only the SQLite source"
 grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
   fail "billing mirror service must not access coordinator secrets"
 grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||
   fail "billing mirror timer must run frequently enough for public stats"
 grep -qF 'stats_billing_mirror_writer' "$ENV_EXAMPLE" ||
   fail "env example must document dedicated writer role"
 grep -qF 'STATS_BILLING_MIRROR_DSN=' "$ENV_EXAMPLE" ||
   fail "env example must define the expected DSN variable"
 grep -qF 'runs with --ensure-schema=false' "$ENV_EXAMPLE" ||
   fail "env example must document bootstrap-before-service contract"
 grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credits' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must create ledger_request_credits"
 grep -qF 'settlement_policy_mode TEXT' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must carry settlement policy mode column"
 grep -qF 'spec022_verified BOOLEAN' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must carry SPEC-022 verified column"
 grep -qF 'lrc_mirror_spec022_verified_enforce_check' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must constrain SPEC-022 verified rows to enforce mode"
 grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credit_spec022_verified_audit' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must create SPEC-022 verified audit table"
 if grep -qF "PASSWORD 'REPLACE_ME'" "$BOOTSTRAP_SQL"; then
   fail "bootstrap SQL must not create a known default password"
 fi
 grep -qF 'RAISE EXCEPTION' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must fail if writer role is missing"
 grep -qF 'CREATE TABLE IF NOT EXISTS provider_tokens' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must create provider_tokens"
 grep -qF 'GRANT SELECT ON ledger_request_credits TO stats_rollup' "$BOOTSTRAP_SQL" ||
   fail "bootstrap SQL must grant rollup read access"
diff --git a/phase4-coordinator/internal/stats/billingmirror/mirror.go b/phase4-coordinator/internal/stats/billingmirror/mirror.go
index 5cc0c9506..1caffe167 100644
--- a/phase4-coordinator/internal/stats/billingmirror/mirror.go
+++ b/phase4-coordinator/internal/stats/billingmirror/mirror.go
@@ -1,52 +1,52 @@
 package billingmirror
 
 import (
 	"context"
 	"crypto/sha256"
 	"database/sql"
 	"encoding/hex"
 	"errors"
 	"fmt"
 	"io"
 	"os"
 	"sort"
 	"strings"
 	"time"
 
 	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
 	_ "github.com/lib/pq"
 	_ "modernc.org/sqlite"
 )
 
 const (
-	DefaultSQLitePath  = "/var/lib/macprovider/request-log.sqlite"
+	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
 	DefaultBatchSize   = 5000
 	DefaultOverlapRows = 1000
 	DefaultRunTimeout  = 25 * time.Second
 
 	StateSource = "sqlite-ledger-request-credits"
 )
 
 type Options struct {
 	SQLitePath   string
 	PostgresDSN  string
 	BatchSize    int
 	OverlapRows  int64
 	SweepRows    int
 	MaxBatches   int
 	EnsureSchema bool
 	DryRun       bool
 	Stdout       io.Writer
 }
 
 type Result struct {
 	RequestRowsRead     int
 	RequestRowsUpserted int
 	ProviderRowsRead    int
 	ProviderRowsEnsured int
 	LastRequestID       int64
 	SweepAfterID        int64
 	SourceMaxID         int64
 	PendingRequestRows  int64
 	DryRun              bool
 }

exec
/bin/bash -lc "printf '%s\\n' '---MIRROR RUN/READ PATH---'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '180,300p'; printf '%s\\n' '---SQLITE READ-ONLY HELPER---'; nl -ba phase4-coordinator/internal/sqliteutil/dsn.go | sed -n '1,130p'; printf '%s\\n' '---MIRROR TESTS---'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror_test.go | sed -n '1,380p'; printf '%s\\n' '---DEPLOY SNAPSHOT/ACL SECTION---'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3030,3200p'; printf '%s\\n' '---RECOVERY ACL SECTION---'; rg -n -C 12 'restore_acl|had-request-log-(db|wal|shm)-acl|request-log\\.sqlite' phase4-coordinator/dist/coordinator-deploy-recover phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/test/*.sh" in /Users/augstar/macprovider-mirror-dbpath
 exited 2 in 0ms:
---MIRROR RUN/READ PATH---
   180		if err != nil {
   181			return Result{}, err
   182		}
   183		result := Result{
   184			RequestRowsRead:  len(rows),
   185			ProviderRowsRead: len(providers),
   186			DryRun:           opts.DryRun,
   187			LastRequestID:    nextLastRequestID,
   188			SweepAfterID:     nextSweepAfterID,
   189			SourceMaxID:      maxSourceID,
   190		}
   191		if maxSourceID > result.LastRequestID {
   192			result.PendingRequestRows = maxSourceID - result.LastRequestID
   193		}
   194		if opts.DryRun {
   195			fmt.Fprintf(out, "would upsert %d request credit rows and ensure %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsRead, result.ProviderRowsRead, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
   196			return result, nil
   197		}
   198	
   199		if err := Apply(ctx, pg, rows, providers, State{LastRequestID: result.LastRequestID, SweepAfterID: result.SweepAfterID}); err != nil {
   200			return Result{}, err
   201		}
   202		result.RequestRowsUpserted = len(rows)
   203		result.ProviderRowsEnsured = len(providers)
   204		fmt.Fprintf(out, "upserted %d request credit rows and ensured %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsUpserted, result.ProviderRowsEnsured, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
   205		return result, nil
   206	}
   207	
   208	func normalizeOptions(opts Options) Options {
   209		opts.SQLitePath = strings.TrimSpace(opts.SQLitePath)
   210		if opts.SQLitePath == "" {
   211			opts.SQLitePath = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_SQLITE"))
   212		}
   213		if opts.SQLitePath == "" {
   214			opts.SQLitePath = DefaultSQLitePath
   215		}
   216		opts.PostgresDSN = strings.TrimSpace(opts.PostgresDSN)
   217		if opts.PostgresDSN == "" {
   218			opts.PostgresDSN = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_DSN"))
   219		}
   220		if opts.BatchSize <= 0 {
   221			opts.BatchSize = DefaultBatchSize
   222		}
   223		if opts.BatchSize > 50000 {
   224			opts.BatchSize = 50000
   225		}
   226		if opts.MaxBatches <= 0 {
   227			opts.MaxBatches = 5
   228		}
   229		if opts.MaxBatches > 20 {
   230			opts.MaxBatches = 20
   231		}
   232		if opts.OverlapRows < 0 {
   233			opts.OverlapRows = 0
   234		}
   235		if opts.OverlapRows == 0 {
   236			opts.OverlapRows = DefaultOverlapRows
   237		}
   238		if opts.OverlapRows > int64(opts.BatchSize) {
   239			opts.OverlapRows = int64(opts.BatchSize)
   240		}
   241		if opts.SweepRows < 0 {
   242			opts.SweepRows = 0
   243		}
   244		if opts.SweepRows == 0 {
   245			opts.SweepRows = opts.BatchSize
   246		}
   247		if opts.SweepRows > opts.BatchSize {
   248			opts.SweepRows = opts.BatchSize
   249		}
   250		return opts
   251	}
   252	
   253	func OpenSQLite(path string) (*sql.DB, error) {
   254		db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
   255		if err != nil {
   256			return nil, fmt.Errorf("open sqlite: %w", err)
   257		}
   258		db.SetMaxOpenConns(1)
   259		db.SetMaxIdleConns(1)
   260		return db, nil
   261	}
   262	
   263	func OpenPostgres(dsn string) (*sql.DB, error) {
   264		db, err := sql.Open("postgres", dsn)
   265		if err != nil {
   266			return nil, fmt.Errorf("open postgres: %w", err)
   267		}
   268		db.SetMaxOpenConns(1)
   269		db.SetMaxIdleConns(1)
   270		db.SetConnMaxLifetime(5 * time.Minute)
   271		db.SetConnMaxIdleTime(time.Minute)
   272		return db, nil
   273	}
   274	
   275	func FetchRequestCredits(ctx context.Context, db *sql.DB, startID int64, limit int) ([]RequestCredit, error) {
   276		caps, err := detectRequestCreditSourceCapabilities(ctx, db)
   277		if err != nil {
   278			return nil, err
   279		}
   280		return scanRequestCredits(ctx, db, requestCreditsQuery(caps, false), startID, limit)
   281	}
   282	
   283	func FetchMaxRequestCreditID(ctx context.Context, db *sql.DB) (int64, error) {
   284		var maxID sql.NullInt64
   285		if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
   286			return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
   287		}
   288		if !maxID.Valid {
   289			return 0, nil
   290		}
   291		return maxID.Int64, nil
   292	}
   293	
   294	func FetchRequestCreditsThrough(ctx context.Context, db *sql.DB, startID, endID int64, limit int) ([]RequestCredit, error) {
   295		caps, err := detectRequestCreditSourceCapabilities(ctx, db)
   296		if err != nil {
   297			return nil, err
   298		}
   299		return scanRequestCredits(ctx, db, requestCreditsQuery(caps, true), startID, endID, limit)
   300	}
---SQLITE READ-ONLY HELPER---
     1	package sqliteutil
     2	
     3	import (
     4		"net/url"
     5		"strings"
     6	)
     7	
     8	// WithPragmas builds a modernc.org/sqlite DSN with the project's standard
     9	// pragma set (busy_timeout, foreign_keys, WAL, synchronous=FULL).
    10	//
    11	// ARCH-5: this helper deliberately mirrors the gateway SQLite DSN shape while
    12	// remaining coordinator-owned. The duplication is intentional — coordinator
    13	// and gateway are deployed as independent Go modules, and introducing a shared
    14	// library would re-couple them on every DSN tweak. See audits/2026-06-10/
    15	// REPO_AUDIT.md (ARCH-5) for the conscious-debt reasoning.
    16	//
    17	// SPEC-016 §3.1 requires synchronous=FULL on every connection
    18	// touching provider_payout_addresses or payout_attempts. Because
    19	// the coordinator shares one *sql.DB handle across requestlog,
    20	// billing, audit, and payout (SPEC-016 §4.8a / §4.8b same-DB
    21	// pins make the shared handle structurally necessary), the DSN
    22	// is the only place to set the per-connection pragma. The prior
    23	// value was NORMAL; the change carries a non-trivial write-
    24	// throughput cost on every billing/requestlog INSERT, and is
    25	// called out explicitly in SPEC-016 IMPL Step 1 audit prompt.
    26	func WithPragmas(path string) string {
    27		values := url.Values{}
    28		for _, pragma := range []string{
    29			"busy_timeout=5000",
    30			"foreign_keys=1",
    31			"journal_mode(WAL)",
    32			"synchronous(FULL)",
    33		} {
    34			values.Add("_pragma", pragma)
    35		}
    36		separator := "?"
    37		if strings.Contains(path, "?") {
    38			separator = "&"
    39		}
    40		return path + separator + values.Encode()
    41	}
    42	
    43	// WithManualWALCheckpointPragmas disables SQLite's autocheckpoint for a DB
    44	// handle whose owner starts an explicit off-hot-path checkpoint loop.
    45	func WithManualWALCheckpointPragmas(path string) string {
    46		base := WithPragmas(path)
    47		values := url.Values{}
    48		values.Add("_pragma", "wal_autocheckpoint(0)")
    49		separator := "?"
    50		if strings.Contains(base, "?") {
    51			separator = "&"
    52		}
    53		return base + separator + values.Encode()
    54	}
    55	
    56	// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
    57	// Opens with mode=ro and applies PRAGMA query_only=ON at connection
    58	// init via a pragma — no journal_mode toggle, no synchronous toggle,
    59	// no writable connection. SPEC-002 v1.5.1 R-2 / issue #197 R3 code:
    60	// used by `coordinator migrate-indexes --check` so the read-only
    61	// introspection never persists journal-mode metadata or runs ALTER
    62	// TABLE on a legacy DB.
    63	func ReadOnlyDSN(path string) string {
    64		values := url.Values{}
    65		values.Set("mode", "ro")
    66		for _, pragma := range []string{
    67			"busy_timeout=5000",
    68			"query_only(true)",
    69		} {
    70			values.Add("_pragma", pragma)
    71		}
    72		separator := "?"
    73		if strings.Contains(path, "?") {
    74			separator = "&"
    75		}
    76		return path + separator + values.Encode()
    77	}
---MIRROR TESTS---
     1	package billingmirror
     2	
     3	import (
     4		"bytes"
     5		"context"
     6		"database/sql"
     7		"os"
     8		"path/filepath"
     9		"strings"
    10		"testing"
    11	
    12		_ "modernc.org/sqlite"
    13	)
    14	
    15	func TestRunDryRunReadsSQLiteWithoutPostgresDSN(t *testing.T) {
    16		dbPath := seedSQLite(t)
    17		var out bytes.Buffer
    18		res, err := Run(context.Background(), Options{
    19			SQLitePath:  dbPath,
    20			DryRun:      true,
    21			BatchSize:   10,
    22			OverlapRows: 1,
    23			SweepRows:   1,
    24			Stdout:      &out,
    25		})
    26		if err != nil {
    27			t.Fatalf("Run(dry-run) error = %v", err)
    28		}
    29		if res.RequestRowsRead != 2 {
    30			t.Fatalf("RequestRowsRead = %d, want 2", res.RequestRowsRead)
    31		}
    32		if res.ProviderRowsRead != 1 {
    33			t.Fatalf("ProviderRowsRead = %d, want 1", res.ProviderRowsRead)
    34		}
    35		if res.LastRequestID != 2 {
    36			t.Fatalf("LastRequestID = %d, want 2", res.LastRequestID)
    37		}
    38		if got := out.String(); !strings.Contains(got, "would upsert 2 request credit rows and ensure 1 provider identities") {
    39			t.Fatalf("dry-run output = %q", got)
    40		}
    41	}
    42	
    43	func TestFetchRequestCreditsParsesEffectiveStatsColumns(t *testing.T) {
    44		dbPath := seedSQLite(t)
    45		db, err := OpenSQLite(dbPath)
    46		if err != nil {
    47			t.Fatalf("OpenSQLite() error = %v", err)
    48		}
    49		defer db.Close()
    50	
    51		rows, err := FetchRequestCredits(context.Background(), db, 0, 10)
    52		if err != nil {
    53			t.Fatalf("FetchRequestCredits() error = %v", err)
    54		}
    55		if len(rows) != 2 {
    56			t.Fatalf("len(rows) = %d, want 2", len(rows))
    57		}
    58		first := rows[0]
    59		if first.RequestID != "req-1" || first.AttemptN != 0 || first.ProviderID != "provider-a" {
    60			t.Fatalf("first identity = %#v", first)
    61		}
    62		if !first.PromptTokens.Valid || first.PromptTokens.Int64 != 100 {
    63			t.Fatalf("prompt tokens = %#v, want 100", first.PromptTokens)
    64		}
    65		if !first.CompletionTokens.Valid || first.CompletionTokens.Int64 != 200 {
    66			t.Fatalf("completion tokens = %#v, want 200", first.CompletionTokens)
    67		}
    68		if first.Quarantined {
    69			t.Fatal("first.Quarantined = true, want false")
    70		}
    71		if first.SettlementPolicyMode != "enforce" {
    72			t.Fatalf("first settlement policy = %q, want enforce", first.SettlementPolicyMode)
    73		}
    74		if !first.Spec022Verified {
    75			t.Fatal("first.Spec022Verified = false, want true")
    76		}
    77		second := rows[1]
    78		if second.UsageSource != "byte_estimated" {
    79			t.Fatalf("second usage source = %q, want byte_estimated", second.UsageSource)
    80		}
    81		if second.CompletionTokens.Valid {
    82			t.Fatalf("second completion tokens = %#v, want NULL", second.CompletionTokens)
    83		}
    84		if !second.EstimatedCompletionTokens.Valid || second.EstimatedCompletionTokens.Int64 != 44 {
    85			t.Fatalf("second estimated completion = %#v, want 44", second.EstimatedCompletionTokens)
    86		}
    87		if !second.Quarantined {
    88			t.Fatal("second.Quarantined = false, want true")
    89		}
    90		if second.Spec022Verified {
    91			t.Fatal("second.Spec022Verified = true, want false")
    92		}
    93	}
    94	
    95	func TestFetchRequestCreditsSupportsLegacySourceSchema(t *testing.T) {
    96		dbPath := seedLegacySQLite(t)
    97		db, err := OpenSQLite(dbPath)
    98		if err != nil {
    99			t.Fatalf("OpenSQLite() error = %v", err)
   100		}
   101		defer db.Close()
   102	
   103		rows, err := FetchRequestCredits(context.Background(), db, 0, 10)
   104		if err != nil {
   105			t.Fatalf("FetchRequestCredits() error = %v", err)
   106		}
   107		if len(rows) != 1 {
   108			t.Fatalf("len(rows) = %d, want 1", len(rows))
   109		}
   110		if got := rows[0].SettlementPolicyMode; got != "legacy" {
   111			t.Fatalf("SettlementPolicyMode = %q, want legacy", got)
   112		}
   113		if rows[0].Spec022Verified {
   114			t.Fatal("Spec022Verified = true, want false for legacy source schema")
   115		}
   116	}
   117	
   118	func TestFetchMaxRequestCreditID(t *testing.T) {
   119		dbPath := seedSQLite(t)
   120		db, err := OpenSQLite(dbPath)
   121		if err != nil {
   122			t.Fatalf("OpenSQLite() error = %v", err)
   123		}
   124		defer db.Close()
   125	
   126		maxID, err := FetchMaxRequestCreditID(context.Background(), db)
   127		if err != nil {
   128			t.Fatalf("FetchMaxRequestCreditID() error = %v", err)
   129		}
   130		if maxID != 2 {
   131			t.Fatalf("maxID = %d, want 2", maxID)
   132		}
   133	}
   134	
   135	func TestFetchRequestCreditsThroughReplaysOnlyBoundedOverlap(t *testing.T) {
   136		dbPath := seedSQLite(t)
   137		db, err := OpenSQLite(dbPath)
   138		if err != nil {
   139			t.Fatalf("OpenSQLite() error = %v", err)
   140		}
   141		defer db.Close()
   142	
   143		rows, err := FetchRequestCreditsThrough(context.Background(), db, 0, 1, 10)
   144		if err != nil {
   145			t.Fatalf("FetchRequestCreditsThrough() error = %v", err)
   146		}
   147		if len(rows) != 1 {
   148			t.Fatalf("len(rows) = %d, want 1", len(rows))
   149		}
   150		if rows[0].SQLiteID != 1 {
   151			t.Fatalf("SQLiteID = %d, want 1", rows[0].SQLiteID)
   152		}
   153	}
   154	
   155	func TestMaxSQLiteIDOnlyUsesSequentialNewRows(t *testing.T) {
   156		newRows := []RequestCredit{{SQLiteID: 11}, {SQLiteID: 12}}
   157		recentReplay := []RequestCredit{{SQLiteID: 99}}
   158		next := maxSQLiteID(newRows, 10)
   159		if next != 12 {
   160			t.Fatalf("next = %d, want 12", next)
   161		}
   162		if got := maxSQLiteID(recentReplay, next); got != 99 {
   163			t.Fatalf("sanity max = %d, want 99", got)
   164		}
   165		// Run intentionally calls maxSQLiteID before merging recentReplay so a
   166		// recently updated high-ID row cannot skip unfetched IDs 13..98.
   167	}
   168	
   169	func TestFetchProviderIdentitiesDoesNotRequireTokenHashes(t *testing.T) {
   170		dbPath := seedSQLite(t)
   171		db, err := OpenSQLite(dbPath)
   172		if err != nil {
   173			t.Fatalf("OpenSQLite() error = %v", err)
   174		}
   175		defer db.Close()
   176	
   177		providers, err := FetchProviderIdentities(context.Background(), db)
   178		if err != nil {
   179			t.Fatalf("FetchProviderIdentities() error = %v", err)
   180		}
   181		if len(providers) != 1 {
   182			t.Fatalf("len(providers) = %d, want 1", len(providers))
   183		}
   184		if providers[0].ProviderID != "provider-a" {
   185			t.Fatalf("provider id = %q, want provider-a", providers[0].ProviderID)
   186		}
   187		if providers[0].ProviderName != "Provider A" {
   188			t.Fatalf("provider name = %q, want Provider A", providers[0].ProviderName)
   189		}
   190		if !providers[0].LastUsedAt.Valid {
   191			t.Fatal("LastUsedAt.Valid = false, want true")
   192		}
   193	}
   194	
   195	func TestFetchProviderIdentitiesFailsWhenTrustSourceMissing(t *testing.T) {
   196		path := filepath.Join(t.TempDir(), "request-log.sqlite")
   197		db, err := sql.Open("sqlite", path)
   198		if err != nil {
   199			t.Fatalf("open sqlite: %v", err)
   200		}
   201		if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
   202			t.Fatalf("seed sqlite: %v", err)
   203		}
   204		if err := db.Close(); err != nil {
   205			t.Fatalf("close sqlite: %v", err)
   206		}
   207		source, err := OpenSQLite(path)
   208		if err != nil {
   209			t.Fatalf("OpenSQLite() error = %v", err)
   210		}
   211		defer source.Close()
   212		_, err = FetchProviderIdentities(context.Background(), source)
   213		if err == nil || !strings.Contains(err.Error(), "provider_tokens") {
   214			t.Fatalf("FetchProviderIdentities() error = %v, want provider_tokens failure", err)
   215		}
   216	}
   217	
   218	func TestMergeRequestCreditsDeduplicatesNaturalKey(t *testing.T) {
   219		old := RequestCredit{SQLiteID: 10, RequestID: "req", AttemptN: 0, ProviderID: "p", ProviderCredits: 1}
   220		updated := old
   221		updated.ProviderCredits = 2
   222		rows := mergeRequestCredits([]RequestCredit{old}, []RequestCredit{updated})
   223		if len(rows) != 1 {
   224			t.Fatalf("len(rows) = %d, want 1", len(rows))
   225		}
   226		if rows[0].ProviderCredits != 2 {
   227			t.Fatalf("ProviderCredits = %d, want updated value 2", rows[0].ProviderCredits)
   228		}
   229	}
   230	
   231	func TestSyntheticTokenHashDoesNotExposeProviderID(t *testing.T) {
   232		got := syntheticTokenHash("provider-secret")
   233		if !strings.HasPrefix(got, "stats-mirror-sha256:") {
   234			t.Fatalf("hash = %q, want stats mirror prefix", got)
   235		}
   236		if strings.Contains(got, "provider-secret") {
   237			t.Fatalf("hash exposes provider id: %q", got)
   238		}
   239		if got != syntheticTokenHash("provider-secret") {
   240			t.Fatal("syntheticTokenHash is not deterministic")
   241		}
   242	}
   243	
   244	func seedSQLite(t *testing.T) string {
   245		t.Helper()
   246		path := filepath.Join(t.TempDir(), "request-log.sqlite")
   247		db, err := sql.Open("sqlite", path)
   248		if err != nil {
   249			t.Fatalf("open sqlite seed db: %v", err)
   250		}
   251		defer db.Close()
   252		if _, err := db.Exec(`
   253	CREATE TABLE ledger_request_credits (
   254	    id INTEGER PRIMARY KEY AUTOINCREMENT,
   255	    request_id TEXT NOT NULL,
   256	    attempt_n INTEGER NOT NULL,
   257	    provider_id TEXT NOT NULL,
   258	    ts_utc TEXT NOT NULL,
   259	    created_at_utc TEXT NOT NULL,
   260	    updated_at_utc TEXT NULL,
   261	    prompt_tokens INTEGER NULL,
   262	    completion_tokens INTEGER NULL,
   263	    estimated_completion_tokens INTEGER NULL,
   264	    usage_source TEXT NOT NULL,
   265	    provider_credits INTEGER NOT NULL,
   266	    fault_flag TEXT NOT NULL,
   267	    quarantined INTEGER NOT NULL,
   268	    settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy'
   269	);
   270	CREATE VIEW spec022_payable_request_credits AS
   271	SELECT *
   272	  FROM ledger_request_credits
   273	 WHERE quarantined = 0
   274	   AND settlement_policy_mode = 'enforce';
   275	CREATE TABLE provider_tokens (
   276	    id INTEGER PRIMARY KEY AUTOINCREMENT,
   277	    token_hash TEXT NOT NULL UNIQUE,
   278	    token_prefix TEXT NOT NULL,
   279	    provider_id TEXT NOT NULL DEFAULT '',
   280	    provider_name TEXT NOT NULL,
   281	    created_at TEXT NOT NULL,
   282	    revoked_at TEXT DEFAULT NULL,
   283	    last_used_at TEXT DEFAULT NULL
   284	);
   285	INSERT INTO ledger_request_credits (
   286	    request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
   287	    prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
   288	    provider_credits, fault_flag, quarantined, settlement_policy_mode
   289	) VALUES
   290	    ('req-1', 0, 'provider-a', '2026-07-05T08:59:00Z', '2026-07-05T08:59:01Z', NULL,
   291	     100, 200, NULL, 'provider_reported', 300, 'none', 0, 'enforce'),
   292	    ('req-2', 0, 'provider-a', '2026-07-05T09:01:00Z', '2026-07-05T09:01:01Z', '2026-07-05T09:02:00Z',
   293	     33, NULL, 44, 'byte_estimated', 0, 'none', 1, 'enforce');
   294	INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
   295	VALUES ('hash-a', 'hash-a', 'provider-a', 'Provider A', '2026-07-05T08:00:00Z', '2026-07-05T09:00:00Z');
   296	`); err != nil {
   297			t.Fatalf("seed sqlite: %v", err)
   298		}
   299		if err := db.Close(); err != nil {
   300			t.Fatalf("close sqlite seed db: %v", err)
   301		}
   302		if _, err := os.Stat(path); err != nil {
   303			t.Fatalf("stat seed sqlite: %v", err)
   304		}
   305		return path
   306	}
   307	
   308	func seedLegacySQLite(t *testing.T) string {
   309		t.Helper()
   310		path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
   311		db, err := sql.Open("sqlite", path)
   312		if err != nil {
   313			t.Fatalf("open legacy sqlite seed db: %v", err)
   314		}
   315		defer db.Close()
   316		if _, err := db.Exec(`
   317	CREATE TABLE ledger_request_credits (
   318	    id INTEGER PRIMARY KEY AUTOINCREMENT,
   319	    request_id TEXT NOT NULL,
   320	    attempt_n INTEGER NOT NULL,
   321	    provider_id TEXT NOT NULL,
   322	    ts_utc TEXT NOT NULL,
   323	    created_at_utc TEXT NOT NULL,
   324	    updated_at_utc TEXT NULL,
   325	    prompt_tokens INTEGER NULL,
   326	    completion_tokens INTEGER NULL,
   327	    estimated_completion_tokens INTEGER NULL,
   328	    usage_source TEXT NOT NULL,
   329	    provider_credits INTEGER NOT NULL,
   330	    fault_flag TEXT NOT NULL,
   331	    quarantined INTEGER NOT NULL
   332	);
   333	INSERT INTO ledger_request_credits (
   334	    request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
   335	    prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
   336	    provider_credits, fault_flag, quarantined
   337	) VALUES (
   338	    'legacy-req', 0, 'provider-legacy', '2026-07-05T08:59:00Z', '2026-07-05T08:59:01Z', NULL,
   339	    10, 20, NULL, 'provider_reported', 30, 'none', 0
   340	);
   341	`); err != nil {
   342			t.Fatalf("seed legacy sqlite: %v", err)
   343		}
   344		if err := db.Close(); err != nil {
   345			t.Fatalf("close legacy sqlite seed db: %v", err)
   346		}
   347		if _, err := os.Stat(path); err != nil {
   348			t.Fatalf("stat legacy seed sqlite: %v", err)
   349		}
   350		return path
   351	}
---DEPLOY SNAPSHOT/ACL SECTION---
  3030	BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
  3031	log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
  3032	# Arm one coordinator release transaction before replacing any live file. The
  3033	# late connected-provider safeguard can still refuse the restart after upload;
  3034	# in that case the EXIT trap restores every release artifact touched after this
  3035	# boundary: coordinator/CLI/sidecar binaries, unit files and enablement links,
  3036	# nginx files, request-log ACLs, config, and catalog pointers.
  3037	$SSH "set -e
  3038	  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  3039	  flock -s 8
  3040	  _rollback=/opt/macprovider/.coordinator-deploy-rollback
  3041	  _rollback_stage=\$_rollback.stage.\$\$
  3042	  umask 077
  3043	  if [ -e \"\$_rollback\" ] || [ -L \"\$_rollback\" ]; then
  3044	    echo 'coordinator deploy transaction already exists; refusing to overwrite it' >&2
  3045	    exit 1
  3046	  fi
  3047	  $(_tier2_migration_gate_remote_script)
  3048	  rm -rf \"\$_rollback_stage\"
  3049	  mkdir \"\$_rollback_stage\"
  3050	  trap 'rm -rf \"\$_rollback_stage\"' EXIT HUP INT TERM
  3051	  chown root:root \"\$_rollback_stage\"
  3052	  chmod 0700 \"\$_rollback_stage\"
  3053	  snapshot_node() {
  3054	    _source=\"\$1\"
  3055	    _snapshot=\"\$2\"
  3056	    _marker=\"\$3\"
  3057	    if [ -e \"\$_source\" ] || [ -L \"\$_source\" ]; then
  3058	      if [ ! -f \"\$_source\" ] && [ ! -L \"\$_source\" ]; then
  3059	        echo \"unsafe rollback source: \$_source\" >&2
  3060	        exit 1
  3061	      fi
  3062	      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
  3063	      touch \"\$_rollback_stage/\$_marker\"
  3064	    fi
  3065	  }
  3066	  snapshot_active() {
  3067	    if systemctl is-active --quiet \"\$1\"; then
  3068	      touch \"\$_rollback_stage/\$2\"
  3069	    fi
  3070	  }
  3071	  snapshot_acl() {
  3072	    _source=\"\$1\"
  3073	    _snapshot=\"\$2\"
  3074	    _marker=\"\$3\"
  3075	    if [ -e \"\$_source\" ]; then
  3076	      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
  3077	      touch \"\$_rollback_stage/\$_marker\"
  3078	    fi
  3079	  }
  3080	  snapshot_node /opt/macprovider/coordinator.prev coordinator.prev had-coordinator-prev
  3081	  if [ -x /opt/macprovider/coordinator ]; then
  3082	    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
  3083	    touch \"\$_rollback_stage/had-coordinator\"
  3084	  fi
  3085	  snapshot_node /opt/macprovider/coordinator-cli coordinator-cli had-coordinator-cli
  3086	  snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
  3087	  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
  3088	  snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
  3089	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
  3090	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
  3091	  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
  3092	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
  3093	  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
  3094	  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
  3095	  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
  3096	  if [ -f /opt/macprovider/coordinator.yaml ]; then
  3097	    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
  3098	    touch \"\$_rollback_stage/had-config\"
  3099	  fi
  3100	  if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
  3101	    echo 'unsafe existing Tier-2 catalog path' >&2
  3102	    exit 1
  3103	  fi
  3104	  if [ -f /opt/macprovider/tier2-catalog.json ]; then
  3105	    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
  3106	    touch \"\$_rollback_stage/had-tier2-catalog\"
  3107	  fi
  3108	  if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
  3109	    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
  3110	    touch \"\$_rollback_stage/had-service-unit\"
  3111	  fi
  3112	  snapshot_node /etc/systemd/system/stats-inventory-sync.service stats-inventory-sync.service had-stats-inventory-service
  3113	  snapshot_node /etc/systemd/system/stats-inventory-sync.timer stats-inventory-sync.timer had-stats-inventory-timer
  3114	  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
  3115	  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
  3116	  snapshot_node /etc/systemd/system/stats-hardware-verifier.service stats-hardware-verifier.service had-stats-hardware-service
  3117	  snapshot_node /etc/systemd/system/stats-hardware-verifier.timer stats-hardware-verifier.timer had-stats-hardware-timer
  3118	  snapshot_node /etc/systemd/system/timers.target.wants/stats-inventory-sync.timer stats-inventory-sync.wants had-stats-inventory-wants
  3119	  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
  3120	  snapshot_node /etc/systemd/system/timers.target.wants/stats-hardware-verifier.timer stats-hardware-verifier.wants had-stats-hardware-wants
  3121	  snapshot_active stats-inventory-sync.timer stats-inventory-timer-was-active
  3122	  snapshot_active stats-inventory-sync.service stats-inventory-service-was-active
  3123	  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
  3124	  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
  3125	  snapshot_active stats-hardware-verifier.timer stats-hardware-timer-was-active
  3126	  snapshot_active stats-hardware-verifier.service stats-hardware-service-was-active
  3127	
  3128	  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
  3129	  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
  3130	  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
  3131	  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
  3132	  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
  3133	  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
  3134	  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
  3135	  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
  3136	  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
  3137	  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
  3138	
  3139	  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
  3140	    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
  3141	    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
  3142	    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
  3143	    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
  3144	  fi
  3145	  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
  3146	    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
  3147	    touch \"\$_rollback_stage/had-wants-link\"
  3148	  fi
  3149	  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
  3150	    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
  3151	    touch \"\$_rollback_stage/had-recovery-helper\"
  3152	  fi
  3153	  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
  3154	    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
  3155	    touch \"\$_rollback_stage/had-recovery-unit\"
  3156	  fi
  3157	  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ]; then
  3158	    cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
  3159	    touch \"\$_rollback_stage/had-watchdog-unit\"
  3160	  fi
  3161	  if [ -e /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ] || [ -L /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ]; then
  3162	    cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
  3163	    touch \"\$_rollback_stage/had-guard-dropin\"
  3164	  fi
  3165	  _catalog_target=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
  3166	  case \"\$_catalog_target\" in
  3167	    ''|releases/*) ;;
  3168	    *) echo \"invalid existing autotune current target: \$_catalog_target\" >&2; exit 1 ;;
  3169	  esac
  3170	  printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
  3171	  if [ -f /opt/macprovider/autotune/.previous-target ]; then
  3172	    cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
  3173	    touch \"\$_rollback_stage/had-previous-target\"
  3174	  fi
  3175	  if [ ! -d /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME ]; then
  3176	    touch \"\$_rollback_stage/release-was-absent\"
  3177	  fi
  3178	  printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
  3179	  if systemctl is-active --quiet macprovider-coordinator; then
  3180	    touch \"\$_rollback_stage/service-was-active\"
  3181	  fi
  3182	  touch \"\$_rollback_stage/complete\"
  3183	  mv \"\$_rollback_stage\" \"\$_rollback\"
  3184	  trap - EXIT HUP INT TERM"
  3185	COORDINATOR_DEPLOY_ARMED=1
  3186	
  3187	# Freeze sidecar execution for the release window. Their binaries and units are
  3188	# transaction-owned, so allowing an old timer to fire after replacement could
  3189	# create non-rollbackable database effects before the catalog canary passes.
  3190	# NOTE: stats-inventory-sync is deliberately NOT in this loop — it is quiesced
  3191	# earlier (before the onboarding migration preflight) because migration 019
  3192	# makes the old inventory binary incompatible with the migrated schema, so it
  3193	# must be down before the migration is exercised, not merely before install.
  3194	$SSH 'set -eu
  3195	  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  3196	  flock -s 8
  3197	  for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
  3198	    load_state=$(systemctl show -p LoadState --value "$unit")
  3199	    [ "$load_state" = not-found ] && continue
  3200	    systemctl stop "$unit"
---RECOVERY ACL SECTION---
rg: phase4-coordinator/dist/coordinator-deploy-recover: No such file or directory (os error 2)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-140-    fail "coordinator rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-141-done
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-142-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-143-for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-144-  had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-145-  had-nginx-stats-proxy-partner had-nginx-coordinator-site \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-146-  had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-147-  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-148-    fail "nginx rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-149-done
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-150-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-151-grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:152:  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-153-  fail "request-log ACL changes must be captured and restored"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-154-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-155-grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-156-  fail "rollback must validate and activate the restored nginx graph"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-157-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-158-freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-159-binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-160-sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-161-commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-162-[ -n "$freeze_line" ] && [ -n "$binary_install_line" ] && [ "$freeze_line" -lt "$binary_install_line" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-163-  fail "stats sidecars must freeze before transaction binaries are replaced"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-164-[ -n "$sidecar_activate_line" ] && [ -n "$commit_line" ] && [ "$sidecar_activate_line" -lt "$commit_line" ] ||
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3129-  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
phase4-coordinator/dist/deploy-pearl-vps.sh-3130-  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
phase4-coordinator/dist/deploy-pearl-vps.sh-3131-  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
phase4-coordinator/dist/deploy-pearl-vps.sh-3132-  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
phase4-coordinator/dist/deploy-pearl-vps.sh-3133-  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3134-  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3135-  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3136-  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3137-  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
phase4-coordinator/dist/deploy-pearl-vps.sh-3138-
phase4-coordinator/dist/deploy-pearl-vps.sh-3139-  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3140-    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh-3144-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3145-  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3146-    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3147-    touch \"\$_rollback_stage/had-wants-link\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3148-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3149-  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3150-    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3151-    touch \"\$_rollback_stage/had-recovery-helper\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3152-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3153-  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3154-    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3155-    touch \"\$_rollback_stage/had-recovery-unit\"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3617-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3618-  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3619-    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3620-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3621-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3622-  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3623-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3624-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-3625-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3626-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-3627-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3628-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3630-    # Mutate only objects captured at the transaction boundary. WAL/SHM files
phase4-coordinator/dist/deploy-pearl-vps.sh-3631-    # can appear while the old coordinator is still running; granting an ACL
phase4-coordinator/dist/deploy-pearl-vps.sh-3632-    # to a newly appeared, unsnapshotted file would make exact rollback
phase4-coordinator/dist/deploy-pearl-vps.sh-3633-    # impossible.
phase4-coordinator/dist/deploy-pearl-vps.sh-3634-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh-3635-    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh-3638-  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3639-    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh-3640-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3641-  # Stage the complete immutable catalog release. Activation happens only
phase4-coordinator/dist/deploy-pearl-vps.sh-3642-  # after the late connected-provider safeguard immediately before restart.
phase4-coordinator/dist/deploy-pearl-vps.sh-3643-  _autotune_root=/opt/macprovider/autotune
phase4-coordinator/dist/deploy-pearl-vps.sh-3644-  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
phase4-coordinator/dist/deploy-pearl-vps.sh-3645-  _autotune_lock=\$_autotune_release.lock
phase4-coordinator/dist/deploy-pearl-vps.sh-3646-  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh-3647-  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
phase4-coordinator/dist/deploy-pearl-vps.sh-3648-  if ! mkdir \$_autotune_lock; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3649-    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
--
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-163-  touch "$ROLLBACK/stats-inventory-timer-was-active" "$ROLLBACK/stats-billing-service-was-active"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-164-  for nginx_file in stats-shared.conf stats-security-headers.conf cors-429.conf stats-proxy-public.conf stats-proxy-partner.conf; do
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-165-    printf 'old-%s' "$nginx_file" >"$ROLLBACK/$nginx_file"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-166-  done
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-167-  printf old-coordinator-site >"$ROLLBACK/nginx-coordinator.site"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-168-  printf old-stats-site >"$ROLLBACK/nginx-stats.site"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-169-  ln -s ../sites-available/coordinator.malibu.tech "$ROLLBACK/nginx-coordinator.enabled"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-170-  touch "$ROLLBACK/had-nginx-stats-shared" "$ROLLBACK/had-nginx-stats-security-headers" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-171-    "$ROLLBACK/had-nginx-stats-cors-429" "$ROLLBACK/had-nginx-stats-proxy-public" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-172-    "$ROLLBACK/had-nginx-stats-proxy-partner" "$ROLLBACK/had-nginx-coordinator-site" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-173-    "$ROLLBACK/had-nginx-stats-site" "$ROLLBACK/had-nginx-coordinator-enabled"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-174-  printf '# acl fixture\n' >"$ROLLBACK/request-log-db.acl"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:175:  touch "$ROLLBACK/had-request-log-db-acl"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-176-  printf releases/old >"$ROLLBACK/catalog-current-target"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-177-  # #1688: autotune_window.py writes a multi-line window; recovery must restore it byte-exact.
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-178-  printf 'releases/older\nreleases/oldest\n' >"$ROLLBACK/catalog-previous-target"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-179-  touch "$ROLLBACK/had-previous-target" "$ROLLBACK/release-was-absent"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-180-  printf new >"$ROLLBACK/release-id"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-181-  touch "$ROLLBACK/restart-attempted" "$ROLLBACK/service-was-active"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-182-  touch "$ROLLBACK/complete"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-183-
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-184-  printf new-binary >"$ROOT/coordinator"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-185-  printf new-cli >"$ROOT/coordinator-cli"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-186-  printf new-coordinator-prev >"$ROOT/coordinator.prev"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-187-	  printf new-config-prev >"$ROOT/coordinator.yaml.prev"

exec
/bin/bash -lc "sed -n '1,70p' phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh; rg -n -C 15 'restore_acl' phase4-coordinator/dist scripts .github test --glob '"'!**/audits/**'"' || true; rg -n 'coordinator-deploy-recover' phase4-coordinator/dist | head -30; find phase4-coordinator -type f -name '*recover*' -o -name '*recovery*' | sort | head -50" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
RECOVER_SH="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
WATCHDOG_UNIT="$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-watchdog.service"
CATALOG_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/catalog-release-provider-upgrade.md"
PEARL_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/pearl-release-updater.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"
bash -n "$RECOVER_SH"
[ -f "$WATCHDOG_UNIT" ] || fail "remote deploy watchdog unit is missing"

grep -q '_autotune_release=\\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" ||
  fail "deploy must stage a content-addressed immutable catalog envelope"

grep -q 'AUTOTUNE_RELEASE_CONTENT_SHA256=' "$DEPLOY_SH" &&
  grep -q 'trusted-keys.json' "$DEPLOY_SH" &&
  grep -q 'asset_digest = hashlib.sha256(path.read_bytes()).hexdigest()' "$DEPLOY_SH" ||
  fail "deploy must content-address catalog envelopes by the full catalog asset set"

grep -q 'install .*tier2-catalog.json \\$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" &&
  grep -q 'verify-directory --directory \\$_autotune_stage --tier2-public-key-file' "$DEPLOY_SH" ||
  fail "deploy must stage and authenticate Tier-2 inside the release envelope"

grep -q 'CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"' "$DEPLOY_SH" ||
  fail "deploy must accept only the release-bound Tier-2 current path"

grep -q 'never.*writes Tier-2 through the current symlink' "$DEPLOY_SH" &&
  grep -q 'root-owned immutable release directories' "$DEPLOY_SH" ||
  fail "deploy must explain root-owned immutable staging and pointer activation"

activation_line=$(grep -nF 'ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
stage_tier2_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
legacy_remove_line=$(grep -nF 'rm -f /opt/macprovider/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
restart_line=$(grep -nF 'systemctl restart macprovider-coordinator' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$stage_tier2_line" ] && [ -n "$activation_line" ] &&
  [ "$stage_tier2_line" -lt "$activation_line" ] ||
  fail "Tier-2 must be staged in the immutable release before current activation"
[ -n "$legacy_remove_line" ] && [ -n "$restart_line" ] &&
  [ "$activation_line" -lt "$legacy_remove_line" ] && [ "$legacy_remove_line" -lt "$restart_line" ] ||
  fail "deploy must remove the independent Tier-2 bridge after current activation and before coordinator restart"

if grep -Eq 'install .* /opt/macprovider/tier2-catalog\.json|install .* \$CATALOG_REMOTE_PATH_CANONICAL' "$DEPLOY_SH"; then
  fail "successful deploy must not install Tier-2 through the independent path or current symlink"
fi

grep -q '_tier2_migration_gate_remote_script()' "$DEPLOY_SH" &&
  grep -q 'legacy Tier-2 catalog bytes differ from active autotune/current release' "$DEPLOY_SH" ||
  fail "deploy must preflight legacy Tier-2 bridge byte equality before mutation"
grep -q 'ROOT = "/opt/macprovider"' "$DEPLOY_SH" &&
  ! grep -q 'MACPROVIDER_ROOT' "$DEPLOY_SH" &&
  grep -q 'O_NOFOLLOW' "$DEPLOY_SH" &&
  grep -q 'dir_fd=' "$DEPLOY_SH" &&
  grep -q 'info.st_nlink != 1' "$DEPLOY_SH" ||
  fail "Tier-2 migration gate must be fixed-root and no-follow/dirfd hardened"
grep -q 'unsafe transient autotune/current.next exists before deploy activation' "$DEPLOY_SH" &&
  grep -q 'unsafe autotune/.previous-target contents before Tier-2 migration' "$DEPLOY_SH" ||
  fail "Tier-2 migration gate must reject unsafe current.next and .previous-target state"
# #1688: scripts/autotune_window.py is the single .previous-target writer
# (no-follow O_EXCL temp + atomic rename live there); deploy logs the plan and
# applies it against the target it just read, before the current swap.
window_plan='python3 -I $DEPLOY_TMP/scripts/autotune_window.py plan --root \"\$_catalog_root\" --incoming releases/$AUTOTUNE_RELEASE_DIR_NAME'
window_apply='python3 -I $DEPLOY_TMP/scripts/autotune_window.py apply --root \"\$_catalog_root\" --incoming releases/$AUTOTUNE_RELEASE_DIR_NAME --expect-current \"\$_previous\"'
phase4-coordinator/dist/coordinator-deploy-recover.sh-120-
phase4-coordinator/dist/coordinator-deploy-recover.sh-121-restore_link_or_file() {
phase4-coordinator/dist/coordinator-deploy-recover.sh-122-  marker=$1
phase4-coordinator/dist/coordinator-deploy-recover.sh-123-  snapshot=$2
phase4-coordinator/dist/coordinator-deploy-recover.sh-124-  destination=$3
phase4-coordinator/dist/coordinator-deploy-recover.sh-125-  rm -f "$destination"
phase4-coordinator/dist/coordinator-deploy-recover.sh-126-  if [ -f "$ROLLBACK/$marker" ]; then
phase4-coordinator/dist/coordinator-deploy-recover.sh-127-    [ -e "$ROLLBACK/$snapshot" ] || [ -L "$ROLLBACK/$snapshot" ] || {
phase4-coordinator/dist/coordinator-deploy-recover.sh-128-      echo "rollback snapshot missing $snapshot" >&2
phase4-coordinator/dist/coordinator-deploy-recover.sh-129-      exit 1
phase4-coordinator/dist/coordinator-deploy-recover.sh-130-    }
phase4-coordinator/dist/coordinator-deploy-recover.sh-131-    cp -a "$ROLLBACK/$snapshot" "$destination"
phase4-coordinator/dist/coordinator-deploy-recover.sh-132-  fi
phase4-coordinator/dist/coordinator-deploy-recover.sh-133-}
phase4-coordinator/dist/coordinator-deploy-recover.sh-134-
phase4-coordinator/dist/coordinator-deploy-recover.sh:135:restore_acl() {
phase4-coordinator/dist/coordinator-deploy-recover.sh-136-  marker=$1
phase4-coordinator/dist/coordinator-deploy-recover.sh-137-  snapshot=$2
phase4-coordinator/dist/coordinator-deploy-recover.sh-138-  if [ -f "$ROLLBACK/$marker" ]; then
phase4-coordinator/dist/coordinator-deploy-recover.sh-139-    [ -f "$ROLLBACK/$snapshot" ] || {
phase4-coordinator/dist/coordinator-deploy-recover.sh-140-      echo "rollback snapshot missing $snapshot" >&2
phase4-coordinator/dist/coordinator-deploy-recover.sh-141-      exit 1
phase4-coordinator/dist/coordinator-deploy-recover.sh-142-    }
phase4-coordinator/dist/coordinator-deploy-recover.sh-143-    "$SETFACL" --restore="$ROLLBACK/$snapshot"
phase4-coordinator/dist/coordinator-deploy-recover.sh-144-  fi
phase4-coordinator/dist/coordinator-deploy-recover.sh-145-}
phase4-coordinator/dist/coordinator-deploy-recover.sh-146-
phase4-coordinator/dist/coordinator-deploy-recover.sh-147-restore_active_state() {
phase4-coordinator/dist/coordinator-deploy-recover.sh-148-  unit_name=$1
phase4-coordinator/dist/coordinator-deploy-recover.sh-149-  active_marker=$2
phase4-coordinator/dist/coordinator-deploy-recover.sh-150-  if [ -f "$ROLLBACK/$active_marker" ]; then
--
phase4-coordinator/dist/coordinator-deploy-recover.sh-214-restore_link_or_file had-stats-inventory-wants stats-inventory-sync.wants "$TIMERS_WANTS/stats-inventory-sync.timer"
phase4-coordinator/dist/coordinator-deploy-recover.sh-215-restore_link_or_file had-stats-billing-wants stats-billing-mirror.wants "$TIMERS_WANTS/stats-billing-mirror.timer"
phase4-coordinator/dist/coordinator-deploy-recover.sh-216-restore_link_or_file had-stats-hardware-wants stats-hardware-verifier.wants "$TIMERS_WANTS/stats-hardware-verifier.timer"
phase4-coordinator/dist/coordinator-deploy-recover.sh-217-
phase4-coordinator/dist/coordinator-deploy-recover.sh-218-restore_link_or_file had-nginx-stats-shared stats-shared.conf "$NGINX_ROOT/conf.d/stats-shared.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-219-restore_link_or_file had-nginx-stats-security-headers stats-security-headers.conf "$NGINX_ROOT/conf.d/stats-security-headers.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-220-restore_link_or_file had-nginx-stats-cors-429 cors-429.conf "$NGINX_ROOT/conf.d/cors-429.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-221-restore_link_or_file had-nginx-stats-proxy-public stats-proxy-public.conf "$NGINX_ROOT/conf.d/stats-proxy-public.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-222-restore_link_or_file had-nginx-stats-proxy-partner stats-proxy-partner.conf "$NGINX_ROOT/conf.d/stats-proxy-partner.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-223-restore_link_or_file had-nginx-coordinator-site nginx-coordinator.site "$NGINX_ROOT/sites-available/coordinator.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-224-restore_link_or_file had-nginx-stats-site nginx-stats.site "$NGINX_ROOT/sites-available/stats.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-225-restore_link_or_file had-nginx-coordinator-enabled nginx-coordinator.enabled "$NGINX_ROOT/sites-enabled/coordinator.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-226-restore_link_or_file had-nginx-stats-enabled nginx-stats.enabled "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-227-restore_link_or_file had-nginx-coordinator-full nginx-coordinator.full "$NGINX_ROOT/sites-available/coordinator.malibu.tech.full"
phase4-coordinator/dist/coordinator-deploy-recover.sh-228-
phase4-coordinator/dist/coordinator-deploy-recover.sh:229:restore_acl had-request-log-dir-acl request-log-dir.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:230:restore_acl had-request-log-db-acl request-log-db.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:231:restore_acl had-request-log-wal-acl request-log-wal.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:232:restore_acl had-request-log-shm-acl request-log-shm.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh-233-
phase4-coordinator/dist/coordinator-deploy-recover.sh-234-previous=$(cat "$ROLLBACK/catalog-current-target" 2>/dev/null || true)
phase4-coordinator/dist/coordinator-deploy-recover.sh-235-case "$previous" in
phase4-coordinator/dist/coordinator-deploy-recover.sh-236-  releases/*)
phase4-coordinator/dist/coordinator-deploy-recover.sh-237-    mkdir -p "$CATALOG_ROOT"
phase4-coordinator/dist/coordinator-deploy-recover.sh-238-    if [ -e "$CATALOG_ROOT/current" ] && [ ! -L "$CATALOG_ROOT/current" ]; then
phase4-coordinator/dist/coordinator-deploy-recover.sh-239-      echo "unsafe non-symlink catalog current path" >&2
phase4-coordinator/dist/coordinator-deploy-recover.sh-240-      exit 1
phase4-coordinator/dist/coordinator-deploy-recover.sh-241-    fi
phase4-coordinator/dist/coordinator-deploy-recover.sh-242-    ln -sfn "$previous" "$CATALOG_ROOT/current"
phase4-coordinator/dist/coordinator-deploy-recover.sh-243-    ;;
phase4-coordinator/dist/coordinator-deploy-recover.sh-244-  '') rm -f "$CATALOG_ROOT/current" ;;
phase4-coordinator/dist/coordinator-deploy-recover.sh-245-  *) echo "invalid rollback catalog target: $previous" >&2; exit 1 ;;
phase4-coordinator/dist/coordinator-deploy-recover.sh-246-esac
phase4-coordinator/dist/coordinator-deploy-recover.sh-247-
--
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-137-  had-stats-billing-service had-stats-billing-timer \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-138-  had-stats-hardware-service had-stats-hardware-timer; do
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-139-  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-140-    fail "coordinator rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-141-done
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-142-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-143-for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-144-  had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-145-  had-nginx-stats-proxy-partner had-nginx-coordinator-site \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-146-  had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-147-  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-148-    fail "nginx rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-149-done
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-150-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-151-grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:152:  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-153-  fail "request-log ACL changes must be captured and restored"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-154-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-155-grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-156-  fail "rollback must validate and activate the restored nginx graph"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-157-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-158-freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-159-binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-160-sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-161-commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-162-[ -n "$freeze_line" ] && [ -n "$binary_install_line" ] && [ "$freeze_line" -lt "$binary_install_line" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-163-  fail "stats sidecars must freeze before transaction binaries are replaced"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-164-[ -n "$sidecar_activate_line" ] && [ -n "$commit_line" ] && [ "$sidecar_activate_line" -lt "$commit_line" ] ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-165-  fail "stats sidecars must reactivate only as the final pre-commit mutation"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-166-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-167-grep -q 'flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" ||
phase4-coordinator/dist/coordinator-deploy-recover.sh:24:RECOVERY_HELPER="$ROOT/coordinator-deploy-recover"
phase4-coordinator/dist/coordinator-deploy-recover.sh:25:RECOVERY_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-recovery.service"
phase4-coordinator/dist/coordinator-deploy-recover.sh:261:restore_link_or_file had-recovery-unit macprovider-coordinator-deploy-recovery.service "$RECOVERY_UNIT"
phase4-coordinator/dist/coordinator-deploy-recover.sh:312:restore_link_or_file had-recovery-helper coordinator-deploy-recover "$RECOVERY_HELPER"
phase4-coordinator/dist/deploy-pearl-vps.sh:634:DEPLOY_RECOVER="$PINNED_DIST_DIR/coordinator-deploy-recover.sh"
phase4-coordinator/dist/deploy-pearl-vps.sh:636:DEPLOY_RECOVERY_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-recovery.service"
phase4-coordinator/dist/deploy-pearl-vps.sh:1099:  # schema/binary parity (see coordinator-deploy-recover.sh). Do not fight it.
phase4-coordinator/dist/deploy-pearl-vps.sh:1101:    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — the armed rollback leaves the old 2-column sidecar stopped against the migrated 3-column schema; see coordinator-deploy-recover runbook)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1108:    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — migration 019 applied but the new 3-column sidecar binary was not installed; see coordinator-deploy-recover runbook)" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:1325:  if ! $SSH 'test -x /opt/macprovider/coordinator-deploy-recover'; then
phase4-coordinator/dist/deploy-pearl-vps.sh:1330:  $SSH /opt/macprovider/coordinator-deploy-recover --recover-under-global || {
phase4-coordinator/dist/deploy-pearl-vps.sh:1728:$SCP "$DEPLOY_RECOVER" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/coordinator-deploy-recover"
phase4-coordinator/dist/deploy-pearl-vps.sh:1730:$SCP "$DEPLOY_RECOVERY_SERVICE" "$VPS_USER@$VPS_HOST:$RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-recovery.service"
phase4-coordinator/dist/deploy-pearl-vps.sh:1736:shasum -a 256 "$DEPLOY_RECOVER" | awk '{ print $1 "  coordinator-deploy-recover" }' >> "$RECOVERY_INPUT_MANIFEST_TMP"
phase4-coordinator/dist/deploy-pearl-vps.sh:1738:shasum -a 256 "$DEPLOY_RECOVERY_SERVICE" | awk '{ print $1 "  macprovider-coordinator-deploy-recovery.service" }' >> "$RECOVERY_INPUT_MANIFEST_TMP"
phase4-coordinator/dist/deploy-pearl-vps.sh:1744:  _helper_next=/opt/macprovider/coordinator-deploy-recover.next.\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh:1745:  _unit_next=/etc/systemd/system/macprovider-coordinator-deploy-recovery.service.next.\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh:1750:  install -o root -g root -m 0750 $RECOVERY_DEPLOY_TMP/coordinator-deploy-recover \"\$_helper_next\"
phase4-coordinator/dist/deploy-pearl-vps.sh:1751:  mv -Tf \"\$_helper_next\" /opt/macprovider/coordinator-deploy-recover
phase4-coordinator/dist/deploy-pearl-vps.sh:1752:  install -o root -g root -m 0644 $RECOVERY_DEPLOY_TMP/macprovider-coordinator-deploy-recovery.service \"\$_unit_next\"
phase4-coordinator/dist/deploy-pearl-vps.sh:1753:  mv -Tf \"\$_unit_next\" /etc/systemd/system/macprovider-coordinator-deploy-recovery.service
phase4-coordinator/dist/deploy-pearl-vps.sh:2079:# leaves the sidecar stopped (see coordinator-deploy-recover.sh) so the old
phase4-coordinator/dist/deploy-pearl-vps.sh:3149:  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3150:    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3153:  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3154:    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh:4919:  /opt/macprovider/coordinator-deploy-recover --recover-under-global
phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-guard.conf:2:Requires=macprovider-coordinator-deploy-recovery.service
phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-guard.conf:3:After=macprovider-coordinator-deploy-recovery.service
phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-watchdog.service:7:ExecStart=/opt/macprovider/coordinator-deploy-recover --recover
phase4-coordinator/dist/coordinator-deploy-recover.sh
phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-recovery.service
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh
phase4-coordinator/internal/auth/admission_recovery.go
phase4-coordinator/internal/auth/admission_recovery_atomic_test.go
phase4-coordinator/internal/billing/recovery.go
phase4-coordinator/internal/buyer/cache_recovery_internal_test.go
phase4-coordinator/internal/buyer/qwen_xml_tool_recover.go
phase4-coordinator/internal/buyer/qwen_xml_tool_recover_test.go
phase4-coordinator/internal/buyer/settlement_receipt_recovery.go
phase4-coordinator/internal/buyer/settlement_receipt_recovery_test.go
phase4-coordinator/internal/payout/runner_recovery_only_test.go
phase4-coordinator/scripts/test-degraded-recovery.sh

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/coordinator-deploy-recover.sh | sed -n '1,260p'; printf '%s\\n' '---RECOVERY TEST ACL ASSERTIONS---'; rg -n -C 8 'acl|request-log|setfacl|restore' phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
     1	#!/bin/sh
     2	set -eu
     3	
     4	ROOT=${MACPROVIDER_ROOT:-/opt/macprovider}
     5	STATS_ROOT=${MACPROVIDER_STATS_ROOT:-/opt/macprovider-stats}
     6	SYSTEMD_ROOT=${MACPROVIDER_SYSTEMD_ROOT:-/etc/systemd/system}
     7	NGINX_ROOT=${MACPROVIDER_NGINX_ROOT:-/etc/nginx}
     8	ETC_MACPROVIDER_ROOT=${MACPROVIDER_ETC_ROOT:-/etc/macprovider}
     9	SYSTEMCTL=${MACPROVIDER_SYSTEMCTL:-systemctl}
    10	FLOCK=${MACPROVIDER_FLOCK:-flock}
    11	PYTHON=${MACPROVIDER_PYTHON:-python3}
    12	SETFACL=${MACPROVIDER_SETFACL:-setfacl}
    13	NGINX=${MACPROVIDER_NGINX:-nginx}
    14	GLOBAL_LOCK_FILE=${MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE:-/run/lock/macprovider-pearl-updater.lock}
    15	LOCK_FILE=${MACPROVIDER_DEPLOY_LOCK_FILE:-/opt/macprovider/.coordinator-deploy.lock}
    16	OPERATION_LOCK_FILE=${MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE:-/opt/macprovider/.coordinator-deploy-operation.lock}
    17	LOCK_REQUIRED_UID=${MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID:-0}
    18	LOCK_REQUIRED_GID=${MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID:-0}
    19	ROLLBACK="$ROOT/.coordinator-deploy-rollback"
    20	CATALOG_ROOT="$ROOT/autotune"
    21	UNIT="$SYSTEMD_ROOT/macprovider-coordinator.service"
    22	WANTS_LINK="$SYSTEMD_ROOT/multi-user.target.wants/macprovider-coordinator.service"
    23	TIMERS_WANTS="$SYSTEMD_ROOT/timers.target.wants"
    24	RECOVERY_HELPER="$ROOT/coordinator-deploy-recover"
    25	RECOVERY_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-recovery.service"
    26	WATCHDOG_UNIT="$SYSTEMD_ROOT/macprovider-coordinator-deploy-watchdog.service"
    27	GUARD_DROPIN="$SYSTEMD_ROOT/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf"
    28	TIER2_CATALOG="$ROOT/tier2-catalog.json"
    29	OVERLAY="$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml"
    30	MODE=${1:---recover}
    31	
    32	case "$MODE" in
    33	  --recover|--recover-under-global|--pre-start) ;;
    34	  *) echo "usage: $0 [--recover|--recover-under-global|--pre-start]" >&2; exit 2 ;;
    35	esac
    36	
    37	validate_global_lock() {
    38	  "$PYTHON" - "$GLOBAL_LOCK_FILE" "$LOCK_REQUIRED_UID" "$LOCK_REQUIRED_GID" <<'PY'
    39	import os
    40	import stat
    41	import sys
    42	
    43	path = sys.argv[1]
    44	required_uid = int(sys.argv[2])
    45	required_gid = int(sys.argv[3])
    46	nofollow = getattr(os, "O_NOFOLLOW", 0)
    47	try:
    48	    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | nofollow, 0o600)
    49	except OSError as exc:
    50	    raise SystemExit(f"cannot safely open global Pearl deployment lock: {exc}") from exc
    51	try:
    52	    info = os.fstat(descriptor)
    53	    if (
    54	        not stat.S_ISREG(info.st_mode)
    55	        or info.st_uid != required_uid
    56	        or info.st_gid != required_gid
    57	        or stat.S_IMODE(info.st_mode) != 0o600
    58	        or info.st_nlink != 1
    59	    ):
    60	        raise SystemExit("unsafe global Pearl deployment lock")
    61	finally:
    62	    os.close(descriptor)
    63	PY
    64	}
    65	
    66	# An active deploy holds LOCK_FILE for its full lifetime. Its deliberate
    67	# restart may consume the pending files. Any later boot/restart sees the lock
    68	# free and restores the last committed release before ExecStart runs. Lock
    69	# ordering is global Pearl mutation lock, deploy lease, operation barrier. This
    70	# is the same order used by direct deploy and prevents abandoned recovery from
    71	# racing the signed updater after the controller lease disappears.
    72	validate_global_lock
    73	if [ "$MODE" = "--pre-start" ]; then
    74	  exec 7>"$GLOBAL_LOCK_FILE"
    75	  if ! $FLOCK -n 7; then
    76	    exit 0
    77	  fi
    78	  exec 9>"$LOCK_FILE"
    79	  if ! $FLOCK -n 9; then
    80	    exit 0
    81	  fi
    82	  exec 8>"$OPERATION_LOCK_FILE"
    83	  $FLOCK 8
    84	elif [ "$MODE" = "--recover" ]; then
    85	  exec 7>"$GLOBAL_LOCK_FILE"
    86	  $FLOCK 7
    87	  exec 9>"$LOCK_FILE"
    88	  $FLOCK 9
    89	  exec 8>"$OPERATION_LOCK_FILE"
    90	  $FLOCK 8
    91	fi
    92	
    93	[ -d "$ROLLBACK" ] || exit 0
    94	[ ! -L "$ROLLBACK" ] || { echo "unsafe coordinator rollback symlink" >&2; exit 1; }
    95	[ -f "$ROLLBACK/complete" ] || {
    96	  echo "incomplete coordinator rollback snapshot; preserving it for manual recovery" >&2
    97	  exit 1
    98	}
    99	
   100	if [ -f "$ROLLBACK/committed" ]; then
   101	  rm -rf "$ROLLBACK"
   102	  exit 0
   103	fi
   104	
   105	restore_regular() {
   106	  marker=$1
   107	  snapshot=$2
   108	  destination=$3
   109	  if [ -f "$ROLLBACK/$marker" ]; then
   110	    [ -f "$ROLLBACK/$snapshot" ] || {
   111	      echo "rollback snapshot missing $snapshot" >&2
   112	      exit 1
   113	    }
   114	    rm -f "$destination"
   115	    cp -p "$ROLLBACK/$snapshot" "$destination"
   116	  else
   117	    rm -f "$destination"
   118	  fi
   119	}
   120	
   121	restore_link_or_file() {
   122	  marker=$1
   123	  snapshot=$2
   124	  destination=$3
   125	  rm -f "$destination"
   126	  if [ -f "$ROLLBACK/$marker" ]; then
   127	    [ -e "$ROLLBACK/$snapshot" ] || [ -L "$ROLLBACK/$snapshot" ] || {
   128	      echo "rollback snapshot missing $snapshot" >&2
   129	      exit 1
   130	    }
   131	    cp -a "$ROLLBACK/$snapshot" "$destination"
   132	  fi
   133	}
   134	
   135	restore_acl() {
   136	  marker=$1
   137	  snapshot=$2
   138	  if [ -f "$ROLLBACK/$marker" ]; then
   139	    [ -f "$ROLLBACK/$snapshot" ] || {
   140	      echo "rollback snapshot missing $snapshot" >&2
   141	      exit 1
   142	    }
   143	    "$SETFACL" --restore="$ROLLBACK/$snapshot"
   144	  fi
   145	}
   146	
   147	restore_active_state() {
   148	  unit_name=$1
   149	  active_marker=$2
   150	  if [ -f "$ROLLBACK/$active_marker" ]; then
   151	    "$SYSTEMCTL" start "$unit_name"
   152	  else
   153	    "$SYSTEMCTL" stop "$unit_name" 2>/dev/null || true
   154	    if "$SYSTEMCTL" is-active --quiet "$unit_name"; then
   155	      echo "$unit_name remained active after rollback stop" >&2
   156	      exit 1
   157	    fi
   158	  fi
   159	}
   160	
   161	# Stop sidecar scheduling before replacing its units and executables. This
   162	# prevents a timer firing against a half-restored release.
   163	for rollback_unit in \
   164	  stats-inventory-sync.timer stats-inventory-sync.service \
   165	  stats-billing-mirror.timer stats-billing-mirror.service \
   166	  stats-hardware-verifier.timer stats-hardware-verifier.service; do
   167	  load_state=$("$SYSTEMCTL" show -p LoadState --value "$rollback_unit")
   168	  [ "$load_state" = "not-found" ] && continue
   169	  "$SYSTEMCTL" stop "$rollback_unit"
   170	  active_state=$("$SYSTEMCTL" show -p ActiveState --value "$rollback_unit")
   171	  case "$active_state" in
   172	    inactive|failed) ;;
   173	    *) echo "$rollback_unit did not stop before rollback: state=$active_state" >&2; exit 1 ;;
   174	  esac
   175	done
   176	
   177	restore_regular had-coordinator coordinator "$ROOT/coordinator"
   178	restore_regular had-coordinator-cli coordinator-cli "$ROOT/coordinator-cli"
   179	restore_regular had-coordinator-prev coordinator.prev "$ROOT/coordinator.prev"
   180	restore_regular had-config coordinator.yaml "$ROOT/coordinator.yaml"
   181	restore_regular had-config-prev coordinator.yaml.prev "$ROOT/coordinator.yaml.prev"
   182	config_backup_name=$(cat "$ROLLBACK/config-backup-name" 2>/dev/null || true)
   183	case "$config_backup_name" in
   184	  coordinator.yaml.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
   185	    restore_regular had-config-dated-backup coordinator-dated-backup "$ROOT/$config_backup_name"
   186	    ;;
   187		  *) echo "invalid rollback config backup name: $config_backup_name" >&2; exit 1 ;;
   188	esac
   189	mkdir -p "$ETC_MACPROVIDER_ROOT"
   190	restore_regular had-overlay coordinator.pearl-overlays.yaml "$OVERLAY"
   191	restore_regular had-overlay-prev coordinator.pearl-overlays.yaml.prev "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev"
   192	if [ -f "$ROLLBACK/overlay-config-backup-name" ]; then
   193	  overlay_config_backup_name=$(cat "$ROLLBACK/overlay-config-backup-name" 2>/dev/null || true)
   194	  case "$overlay_config_backup_name" in
   195	    coordinator.pearl-overlays.yaml.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
   196	      restore_regular had-overlay-dated-backup coordinator-overlay-dated-backup "$ETC_MACPROVIDER_ROOT/$overlay_config_backup_name"
   197	      ;;
   198	    *) echo "invalid rollback overlay backup name: $overlay_config_backup_name" >&2; exit 1 ;;
   199	  esac
   200	fi
   201	restore_regular had-tier2-catalog tier2-catalog.json "$TIER2_CATALOG"
   202	restore_regular had-stats-inventory-binary stats-inventory-sync "$STATS_ROOT/stats-inventory-sync"
   203	restore_regular had-stats-billing-binary stats-billing-mirror "$STATS_ROOT/stats-billing-mirror"
   204	restore_regular had-stats-hardware-binary stats-hardware-verifier "$STATS_ROOT/stats-hardware-verifier"
   205	restore_link_or_file had-service-unit macprovider-coordinator.service "$UNIT"
   206	restore_link_or_file had-wants-link macprovider-coordinator.wants "$WANTS_LINK"
   207	
   208	restore_link_or_file had-stats-inventory-service stats-inventory-sync.service "$SYSTEMD_ROOT/stats-inventory-sync.service"
   209	restore_link_or_file had-stats-inventory-timer stats-inventory-sync.timer "$SYSTEMD_ROOT/stats-inventory-sync.timer"
   210	restore_link_or_file had-stats-billing-service stats-billing-mirror.service "$SYSTEMD_ROOT/stats-billing-mirror.service"
   211	restore_link_or_file had-stats-billing-timer stats-billing-mirror.timer "$SYSTEMD_ROOT/stats-billing-mirror.timer"
   212	restore_link_or_file had-stats-hardware-service stats-hardware-verifier.service "$SYSTEMD_ROOT/stats-hardware-verifier.service"
   213	restore_link_or_file had-stats-hardware-timer stats-hardware-verifier.timer "$SYSTEMD_ROOT/stats-hardware-verifier.timer"
   214	restore_link_or_file had-stats-inventory-wants stats-inventory-sync.wants "$TIMERS_WANTS/stats-inventory-sync.timer"
   215	restore_link_or_file had-stats-billing-wants stats-billing-mirror.wants "$TIMERS_WANTS/stats-billing-mirror.timer"
   216	restore_link_or_file had-stats-hardware-wants stats-hardware-verifier.wants "$TIMERS_WANTS/stats-hardware-verifier.timer"
   217	
   218	restore_link_or_file had-nginx-stats-shared stats-shared.conf "$NGINX_ROOT/conf.d/stats-shared.conf"
   219	restore_link_or_file had-nginx-stats-security-headers stats-security-headers.conf "$NGINX_ROOT/conf.d/stats-security-headers.conf"
   220	restore_link_or_file had-nginx-stats-cors-429 cors-429.conf "$NGINX_ROOT/conf.d/cors-429.conf"
   221	restore_link_or_file had-nginx-stats-proxy-public stats-proxy-public.conf "$NGINX_ROOT/conf.d/stats-proxy-public.conf"
   222	restore_link_or_file had-nginx-stats-proxy-partner stats-proxy-partner.conf "$NGINX_ROOT/conf.d/stats-proxy-partner.conf"
   223	restore_link_or_file had-nginx-coordinator-site nginx-coordinator.site "$NGINX_ROOT/sites-available/coordinator.malibu.tech"
   224	restore_link_or_file had-nginx-stats-site nginx-stats.site "$NGINX_ROOT/sites-available/stats.malibu.tech"
   225	restore_link_or_file had-nginx-coordinator-enabled nginx-coordinator.enabled "$NGINX_ROOT/sites-enabled/coordinator.malibu.tech"
   226	restore_link_or_file had-nginx-stats-enabled nginx-stats.enabled "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
   227	restore_link_or_file had-nginx-coordinator-full nginx-coordinator.full "$NGINX_ROOT/sites-available/coordinator.malibu.tech.full"
   228	
   229	restore_acl had-request-log-dir-acl request-log-dir.acl
   230	restore_acl had-request-log-db-acl request-log-db.acl
   231	restore_acl had-request-log-wal-acl request-log-wal.acl
   232	restore_acl had-request-log-shm-acl request-log-shm.acl
   233	
   234	previous=$(cat "$ROLLBACK/catalog-current-target" 2>/dev/null || true)
   235	case "$previous" in
   236	  releases/*)
   237	    mkdir -p "$CATALOG_ROOT"
   238	    if [ -e "$CATALOG_ROOT/current" ] && [ ! -L "$CATALOG_ROOT/current" ]; then
   239	      echo "unsafe non-symlink catalog current path" >&2
   240	      exit 1
   241	    fi
   242	    ln -sfn "$previous" "$CATALOG_ROOT/current"
   243	    ;;
   244	  '') rm -f "$CATALOG_ROOT/current" ;;
   245	  *) echo "invalid rollback catalog target: $previous" >&2; exit 1 ;;
   246	esac
   247	
   248	restore_regular had-previous-target catalog-previous-target "$CATALOG_ROOT/.previous-target"
   249	
   250	if [ -f "$ROLLBACK/release-was-absent" ]; then
   251	  release_id=$(cat "$ROLLBACK/release-id")
   252	  case "$release_id" in
   253	    ''|*[!A-Za-z0-9._-]*) echo "invalid rollback release ID" >&2; exit 1 ;;
   254	  esac
   255	  rm -rf "$CATALOG_ROOT/releases/$release_id"
   256	fi
   257	
   258	# Restore the guard definition before daemon-reload. The helper itself is
   259	# restored last so this running process cannot lose its executable before all
   260	# service and catalog recovery work succeeds.
---RECOVERY TEST ACL ASSERTIONS---
13-
14-ROOT="$TMP/opt/macprovider"
15-STATS_ROOT="$TMP/opt/macprovider-stats"
16-SYSTEMD="$TMP/etc/systemd/system"
17-NGINX_ROOT="$TMP/etc/nginx"
18-ETC_MACPROVIDER_ROOT="$TMP/etc/macprovider"
19-ROLLBACK="$ROOT/.coordinator-deploy-rollback"
20-SYSTEMCTL_LOG="$TMP/systemctl.log"
21:SETFACL_LOG="$TMP/setfacl.log"
22-mkdir -p "$ROOT/autotune/releases/new" "$STATS_ROOT" \
23-  "$SYSTEMD/multi-user.target.wants" "$SYSTEMD/timers.target.wants" \
24-  "$NGINX_ROOT/conf.d" "$NGINX_ROOT/sites-available" "$NGINX_ROOT/sites-enabled" \
25-  "$ETC_MACPROVIDER_ROOT" "$TMP/bin"
26-
27-cat >"$TMP/bin/systemctl" <<'SH'
28-#!/bin/sh
29-printf '%s\n' "$*" >> "$MACPROVIDER_SYSTEMCTL_LOG"
--
60-#!/bin/sh
61-if [ "${1:-}" = "-n" ]; then
62-  exit 0
63-fi
64-while [ -f "$MACPROVIDER_OPERATION_BLOCK_SENTINEL" ]; do
65-  sleep 0.05
66-done
67-SH
68:cat >"$TMP/bin/setfacl" <<'SH'
69-#!/bin/sh
70-printf '%s\n' "$*" >> "$MACPROVIDER_SETFACL_LOG"
71-SH
72-cat >"$TMP/bin/nginx" <<'SH'
73-#!/bin/sh
74-[ "${1:-}" = -t ]
75-[ "${MACPROVIDER_NGINX_FAIL:-0}" != 1 ]
76-SH
77-chmod +x "$TMP/bin/systemctl" "$TMP/bin/flock-free" "$TMP/bin/flock-busy" \
78:  "$TMP/bin/flock-operation-blocked" "$TMP/bin/setfacl" "$TMP/bin/nginx"
79-
80-run_recover() {
81-  MACPROVIDER_ROOT="$ROOT" \
82-  MACPROVIDER_STATS_ROOT="$STATS_ROOT" \
83-	  MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
84-	  MACPROVIDER_NGINX_ROOT="$NGINX_ROOT" \
85-	  MACPROVIDER_ETC_ROOT="$ETC_MACPROVIDER_ROOT" \
86-	  MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
87-  MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
88-  MACPROVIDER_SYSTEMCTL_FAIL_STOP="${MACPROVIDER_SYSTEMCTL_FAIL_STOP:-0}" \
89-  MACPROVIDER_FLOCK="${MACPROVIDER_FLOCK_OVERRIDE:-$TMP/bin/flock-free}" \
90:  MACPROVIDER_SETFACL="$TMP/bin/setfacl" \
91-  MACPROVIDER_SETFACL_LOG="$SETFACL_LOG" \
92-  MACPROVIDER_NGINX="$TMP/bin/nginx" \
93-  MACPROVIDER_NGINX_FAIL="${MACPROVIDER_NGINX_FAIL:-0}" \
94-  MACPROVIDER_OPERATION_BLOCK_SENTINEL="${MACPROVIDER_OPERATION_BLOCK_SENTINEL:-}" \
95-  MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global-deploy.lock" \
96-  MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
97-  MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
98-  MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
--
166-  done
167-  printf old-coordinator-site >"$ROLLBACK/nginx-coordinator.site"
168-  printf old-stats-site >"$ROLLBACK/nginx-stats.site"
169-  ln -s ../sites-available/coordinator.malibu.tech "$ROLLBACK/nginx-coordinator.enabled"
170-  touch "$ROLLBACK/had-nginx-stats-shared" "$ROLLBACK/had-nginx-stats-security-headers" \
171-    "$ROLLBACK/had-nginx-stats-cors-429" "$ROLLBACK/had-nginx-stats-proxy-public" \
172-    "$ROLLBACK/had-nginx-stats-proxy-partner" "$ROLLBACK/had-nginx-coordinator-site" \
173-    "$ROLLBACK/had-nginx-stats-site" "$ROLLBACK/had-nginx-coordinator-enabled"
174:  printf '# acl fixture\n' >"$ROLLBACK/request-log-db.acl"
175:  touch "$ROLLBACK/had-request-log-db-acl"
176-  printf releases/old >"$ROLLBACK/catalog-current-target"
177:  # #1688: autotune_window.py writes a multi-line window; recovery must restore it byte-exact.
178-  printf 'releases/older\nreleases/oldest\n' >"$ROLLBACK/catalog-previous-target"
179-  touch "$ROLLBACK/had-previous-target" "$ROLLBACK/release-was-absent"
180-  printf new >"$ROLLBACK/release-id"
181-  touch "$ROLLBACK/restart-attempted" "$ROLLBACK/service-was-active"
182-  touch "$ROLLBACK/complete"
183-
184-  printf new-binary >"$ROOT/coordinator"
185-  printf new-cli >"$ROOT/coordinator-cli"
--
213-  ln -sfn releases/new "$ROOT/autotune/current"
214-  printf releases/new >"$ROOT/autotune/.previous-target"
215-  : >"$SYSTEMCTL_LOG"
216-  : >"$SETFACL_LOG"
217-}
218-
219-seed_transaction
220-run_recover
221:[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "binary was not restored"
222:[ "$(cat "$ROOT/coordinator.yaml")" = old-config ] || fail "config was not restored"
223:[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] || fail "Tier-2 catalog was not restored"
224:[ "$(cat "$ROOT/coordinator-cli")" = old-cli ] || fail "coordinator CLI was not restored"
225:[ "$(cat "$ROOT/coordinator.prev")" = old-coordinator-prev ] || fail "coordinator convenience backup was not restored"
226:[ "$(cat "$ROOT/coordinator.yaml.prev")" = old-config-prev ] || fail "config convenience backup was not restored"
227:[ "$(cat "$ROOT/coordinator.yaml.bak-20260711T120000Z")" = old-dated-backup ] || fail "dated config backup collision was not restored"
228:[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml")" = old-overlay ] || fail "overlay was not restored"
229:[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev")" = old-overlay-prev ] || fail "overlay convenience backup was not restored"
230:[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.bak-20260711T120000Z")" = old-overlay-dated-backup ] || fail "dated overlay backup collision was not restored"
231:[ "$(cat "$STATS_ROOT/stats-inventory-sync")" = old-stats-inventory-sync ] || fail "stats inventory binary was not restored"
232:[ "$(cat "$STATS_ROOT/stats-billing-mirror")" = old-stats-billing-mirror ] || fail "stats billing binary was not restored"
233:[ "$(cat "$STATS_ROOT/stats-hardware-verifier")" = old-stats-hardware-verifier ] || fail "stats hardware binary was not restored"
234:[ "$(readlink "$SYSTEMD/macprovider-coordinator.service")" = /dev/null ] || fail "masked unit was not restored"
235:[ "$(readlink "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service")" = ../macprovider-coordinator.service ] || fail "enablement link was not restored"
236:[ "$(cat "$SYSTEMD/macprovider-coordinator-deploy-watchdog.service")" = old-watchdog-unit ] || fail "deploy watchdog unit was not restored"
237:[ "$(cat "$SYSTEMD/stats-inventory-sync.timer")" = old-stats-inventory-sync.timer ] || fail "stats timer unit was not restored"
238:[ -L "$SYSTEMD/timers.target.wants/stats-inventory-sync.timer" ] || fail "prior stats timer enablement was not restored"
239-[ ! -e "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" ] || fail "new stats timer enablement was not removed"
240:[ "$(cat "$NGINX_ROOT/conf.d/stats-shared.conf")" = old-stats-shared.conf ] || fail "nginx snippet was not restored"
241:[ "$(cat "$NGINX_ROOT/sites-available/coordinator.malibu.tech")" = old-coordinator-site ] || fail "coordinator nginx site was not restored"
242-[ ! -e "$NGINX_ROOT/sites-enabled/stats.malibu.tech" ] || fail "new stats nginx enablement was not removed"
243:grep -qx -- "--restore=$ROLLBACK/request-log-db.acl" "$SETFACL_LOG" || fail "request-log ACL was not restored"
244:[ "$(readlink "$ROOT/autotune/current")" = releases/old ] || fail "catalog current was not restored"
245-[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] &&
246-  [ "$(readlink "$ROOT/autotune/current")" = releases/old ] ||
247:  fail "legacy Tier-2 bridge and current pointer were not restored together"
248:[ "$(cat "$ROOT/autotune/.previous-target")" = "$(printf 'releases/older\nreleases/oldest')" ] || fail "catalog previous target was not restored"
249-[ ! -d "$ROOT/autotune/releases/new" ] || fail "new release was not removed"
250-[ ! -e "$ROLLBACK" ] || fail "successful recovery did not remove its snapshot"
251-grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "recovery did not reload systemd"
252:grep -qx 'restart macprovider-coordinator' "$SYSTEMCTL_LOG" || fail "recovery did not restore active service state"
253:grep -qx 'start stats-inventory-sync.timer' "$SYSTEMCTL_LOG" || fail "active stats timer state was not restored"
254:grep -qx 'start stats-billing-mirror.service' "$SYSTEMCTL_LOG" || fail "active stats service state was not restored"
255:grep -qx 'try-reload-or-restart nginx' "$SYSTEMCTL_LOG" || fail "restored nginx graph was not reloaded"
256-
257-seed_transaction
258-rm -f "$ROLLBACK/macprovider-coordinator.wants" "$ROLLBACK/had-wants-link"
259-run_recover
260-[ ! -e "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" ] &&
261-  [ ! -L "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" ] ||
262:  fail "disabled service state was not restored"
263-
264-seed_transaction
265-rm -f "$ROLLBACK/tier2-catalog.json" "$ROLLBACK/had-tier2-catalog"
266-run_recover
267-[ ! -e "$ROOT/tier2-catalog.json" ] || fail "previously absent Tier-2 catalog was not removed"
268:[ "$(readlink "$ROOT/autotune/current")" = releases/old ] || fail "current pointer was not restored when legacy Tier-2 was absent"
269-
270-seed_transaction
271-rm -f "$ROLLBACK/coordinator"
272-if run_recover >/dev/null 2>&1; then
273-  fail "incomplete rollback snapshot was accepted"
274-fi
275-[ -d "$ROLLBACK" ] || fail "failed rollback did not preserve its snapshot"
276-
--
285-rm -f "$ROLLBACK/service-was-active"
286-if MACPROVIDER_SYSTEMCTL_FAIL_STOP=1 run_recover >/dev/null 2>&1; then
287-  fail "failed service stop was accepted"
288-fi
289-[ -d "$ROLLBACK" ] || fail "failed service stop did not preserve its snapshot"
290-
291-seed_transaction
292-if MACPROVIDER_NGINX_FAIL=1 run_recover >/dev/null 2>&1; then
293:  fail "invalid restored nginx graph was accepted"
294-fi
295-[ -d "$ROLLBACK" ] || fail "nginx validation failure did not preserve its snapshot"
296-
297-seed_transaction
298-touch "$ROLLBACK/committed"
299-run_recover
300-[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "committed cleanup rolled back live files"
301-[ ! -e "$ROLLBACK" ] || fail "committed cleanup did not remove its snapshot"
--
304-seed_transaction
305-MACPROVIDER_ROOT="$ROOT" \
306-MACPROVIDER_STATS_ROOT="$STATS_ROOT" \
307-MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
308-MACPROVIDER_NGINX_ROOT="$NGINX_ROOT" \
309-MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
310-MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
311-MACPROVIDER_FLOCK="$TMP/bin/flock-busy" \
312:MACPROVIDER_SETFACL="$TMP/bin/setfacl" \
313-MACPROVIDER_SETFACL_LOG="$SETFACL_LOG" \
314-MACPROVIDER_NGINX="$TMP/bin/nginx" \
315-MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global-deploy.lock" \
316-MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
317-MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
318-MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
319-MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(id -g)" \
320-  "$RECOVER" --pre-start
321-[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "active deploy pre-start was rolled back"
322-[ -d "$ROLLBACK" ] || fail "active deploy snapshot was consumed"
323-
324-run_recover --pre-start
325:[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "orphaned pre-start transaction was not restored"
326-[ ! -e "$ROLLBACK" ] || fail "orphaned pre-start snapshot was not removed"
327:grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "pre-start recovery did not reload the restored unit"
328-! grep -Eq '^(restart|stop) macprovider-coordinator$' "$SYSTEMCTL_LOG" || fail "pre-start recovery recursively changed coordinator service state"
329-
330-seed_transaction
331-OPERATION_BLOCK_SENTINEL="$TMP/operation-blocked"
332-touch "$OPERATION_BLOCK_SENTINEL"
333-MACPROVIDER_FLOCK_OVERRIDE="$TMP/bin/flock-operation-blocked" \
334-MACPROVIDER_OPERATION_BLOCK_SENTINEL="$OPERATION_BLOCK_SENTINEL" \
335-  run_recover --pre-start &
--
338-kill -0 "$blocked_recover_pid" 2>/dev/null || fail "pre-start recovery did not wait for the operation barrier"
339-[ "$(cat "$ROOT/coordinator")" = new-binary ] || fail "pre-start recovery mutated files before the operation barrier cleared"
340-rm -f "$OPERATION_BLOCK_SENTINEL"
341-wait "$blocked_recover_pid"
342-[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "pre-start recovery did not run after the operation barrier cleared"
343-
344-seed_transaction
345-MACPROVIDER_FLOCK_OVERRIDE="$TMP/bin/flock-busy" run_recover --recover-under-global
346:[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "caller-held global recovery did not restore the transaction"
347-[ ! -e "$ROLLBACK" ] || fail "caller-held global recovery did not remove the snapshot"
348-
349-# The watchdog starts before direct deploy publishes its rollback snapshot. It
350:# must wait behind the global lease, then observe and restore the snapshot that
351-# appears while the controller still owns that lease.
352-rm -rf "$ROLLBACK"
353-GLOBAL_BLOCK_SENTINEL="$TMP/global-blocked"
354-touch "$GLOBAL_BLOCK_SENTINEL"
355-MACPROVIDER_FLOCK_OVERRIDE="$TMP/bin/flock-operation-blocked" \
356-MACPROVIDER_OPERATION_BLOCK_SENTINEL="$GLOBAL_BLOCK_SENTINEL" \
357-  run_recover --recover &
358-watchdog_pid=$!
359-sleep 0.15
360-kill -0 "$watchdog_pid" 2>/dev/null || fail "watchdog exited before the controller published rollback state"
361-seed_transaction
362-rm -f "$GLOBAL_BLOCK_SENTINEL"
363-wait "$watchdog_pid"
364:[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "watchdog did not restore the snapshot published behind its lease"
365:[ ! -e "$ROLLBACK" ] || fail "watchdog did not consume the restored snapshot"
366-
367-echo "PASS: coordinator deploy recovery is durable and state-exact"

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3060,3090p'; printf '%s\\n' '---MIRROR OPEN/RUN START---'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '70,210p'; printf '%s\\n' '---SQLITE READONLY USAGES/TESTS---'; rg -n -C 5 'ReadOnlyDSN|query_only|OpenSQLite|SetMaxOpenConns|journal_mode|busy_timeout' phase4-coordinator/internal phase5-gateway/internal --glob '*.go' --glob '*_test.go' | head -300" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
  3060	        exit 1
  3061	      fi
  3062	      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
  3063	      touch \"\$_rollback_stage/\$_marker\"
  3064	    fi
  3065	  }
  3066	  snapshot_active() {
  3067	    if systemctl is-active --quiet \"\$1\"; then
  3068	      touch \"\$_rollback_stage/\$2\"
  3069	    fi
  3070	  }
  3071	  snapshot_acl() {
  3072	    _source=\"\$1\"
  3073	    _snapshot=\"\$2\"
  3074	    _marker=\"\$3\"
  3075	    if [ -e \"\$_source\" ]; then
  3076	      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
  3077	      touch \"\$_rollback_stage/\$_marker\"
  3078	    fi
  3079	  }
  3080	  snapshot_node /opt/macprovider/coordinator.prev coordinator.prev had-coordinator-prev
  3081	  if [ -x /opt/macprovider/coordinator ]; then
  3082	    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
  3083	    touch \"\$_rollback_stage/had-coordinator\"
  3084	  fi
  3085	  snapshot_node /opt/macprovider/coordinator-cli coordinator-cli had-coordinator-cli
  3086	  snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
  3087	  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
  3088	  snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
  3089	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
  3090	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
---MIRROR OPEN/RUN START---
    70		Spec022Verified              bool
    71		RequestedPrivacyMode         string
    72		EffectivePrivacyOutcome      string
    73		PositiveVerificationExcluded bool
    74		RewardsExcluded              bool
    75	}
    76	
    77	type ProviderIdentity struct {
    78		ProviderID   string
    79		ProviderName string
    80		CreatedAt    time.Time
    81		LastUsedAt   sql.NullTime
    82	}
    83	
    84	type State struct {
    85		LastRequestID int64
    86		SweepAfterID  int64
    87	}
    88	
    89	func Run(parent context.Context, opts Options) (Result, error) {
    90		opts = normalizeOptions(opts)
    91		out := opts.Stdout
    92		if out == nil {
    93			out = io.Discard
    94		}
    95		if opts.SQLitePath == "" {
    96			return Result{}, errors.New("sqlite path is required")
    97		}
    98		if opts.PostgresDSN == "" && !opts.DryRun {
    99			return Result{}, errors.New("postgres dsn is required")
   100		}
   101	
   102		ctx, cancel := context.WithTimeout(parent, DefaultRunTimeout)
   103		defer cancel()
   104	
   105		source, err := OpenSQLite(opts.SQLitePath)
   106		if err != nil {
   107			return Result{}, err
   108		}
   109		defer source.Close()
   110	
   111		var pg *sql.DB
   112		var state State
   113		if !opts.DryRun {
   114			pg, err = OpenPostgres(opts.PostgresDSN)
   115			if err != nil {
   116				return Result{}, err
   117			}
   118			defer pg.Close()
   119			if opts.EnsureSchema {
   120				if err := EnsureSchema(ctx, pg); err != nil {
   121					return Result{}, err
   122				}
   123			}
   124			state, err = LoadState(ctx, pg)
   125			if err != nil {
   126				return Result{}, err
   127			}
   128		}
   129	
   130		maxSourceID, err := FetchMaxRequestCreditID(ctx, source)
   131		if err != nil {
   132			return Result{}, err
   133		}
   134		newRows := make([]RequestCredit, 0, opts.BatchSize)
   135		newCursor := state.LastRequestID
   136		for batch := 0; batch < opts.MaxBatches; batch++ {
   137			batchRows, err := FetchRequestCredits(ctx, source, newCursor, opts.BatchSize)
   138			if err != nil {
   139				return Result{}, err
   140			}
   141			if len(batchRows) == 0 {
   142				break
   143			}
   144			newRows = append(newRows, batchRows...)
   145			newCursor = maxSQLiteID(batchRows, newCursor)
   146			if len(batchRows) < opts.BatchSize {
   147				break
   148			}
   149		}
   150		nextLastRequestID := maxSQLiteID(newRows, state.LastRequestID)
   151		rows := newRows
   152		if state.LastRequestID > 0 && opts.OverlapRows > 0 {
   153			startID := state.LastRequestID - opts.OverlapRows
   154			if startID < 0 {
   155				startID = 0
   156			}
   157			overlapRows, err := FetchRequestCreditsThrough(ctx, source, startID, state.LastRequestID, minInt(opts.BatchSize, int(opts.OverlapRows)))
   158			if err != nil {
   159				return Result{}, err
   160			}
   161			rows = mergeRequestCredits(overlapRows, rows)
   162		}
   163		nextSweepAfterID := state.SweepAfterID
   164		if opts.SweepRows > 0 && maxSourceID > 0 {
   165			sweepStart := state.SweepAfterID
   166			if sweepStart >= maxSourceID {
   167				sweepStart = 0
   168			}
   169			sweepRows, err := FetchRequestCreditsThrough(ctx, source, sweepStart, maxSourceID, opts.SweepRows)
   170			if err != nil {
   171				return Result{}, err
   172			}
   173			rows = mergeRequestCredits(rows, sweepRows)
   174			nextSweepAfterID = maxSQLiteID(sweepRows, sweepStart)
   175			if nextSweepAfterID >= maxSourceID {
   176				nextSweepAfterID = 0
   177			}
   178		}
   179		providers, err := FetchProviderIdentities(ctx, source)
   180		if err != nil {
   181			return Result{}, err
   182		}
   183		result := Result{
   184			RequestRowsRead:  len(rows),
   185			ProviderRowsRead: len(providers),
   186			DryRun:           opts.DryRun,
   187			LastRequestID:    nextLastRequestID,
   188			SweepAfterID:     nextSweepAfterID,
   189			SourceMaxID:      maxSourceID,
   190		}
   191		if maxSourceID > result.LastRequestID {
   192			result.PendingRequestRows = maxSourceID - result.LastRequestID
   193		}
   194		if opts.DryRun {
   195			fmt.Fprintf(out, "would upsert %d request credit rows and ensure %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsRead, result.ProviderRowsRead, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
   196			return result, nil
   197		}
   198	
   199		if err := Apply(ctx, pg, rows, providers, State{LastRequestID: result.LastRequestID, SweepAfterID: result.SweepAfterID}); err != nil {
   200			return Result{}, err
   201		}
   202		result.RequestRowsUpserted = len(rows)
   203		result.ProviderRowsEnsured = len(providers)
   204		fmt.Fprintf(out, "upserted %d request credit rows and ensured %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsUpserted, result.ProviderRowsEnsured, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
   205		return result, nil
   206	}
   207	
   208	func normalizeOptions(opts Options) Options {
   209		opts.SQLitePath = strings.TrimSpace(opts.SQLitePath)
   210		if opts.SQLitePath == "" {
---SQLITE READONLY USAGES/TESTS---
phase4-coordinator/internal/buyer/route_snapshot_test.go-1441-	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1442-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/buyer/route_snapshot_test.go-1443-	if err != nil {
phase4-coordinator/internal/buyer/route_snapshot_test.go-1444-		t.Fatalf("open dedicated route snapshot db: %v", err)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1445-	}
phase4-coordinator/internal/buyer/route_snapshot_test.go:1446:	routeSnapshotDB.SetMaxOpenConns(1)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1447-	routeSnapshotDB.SetMaxIdleConns(1)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1448-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/buyer/route_snapshot_test.go-1449-	billingStore.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1450-	heldRouteSnapshotConn, err := routeSnapshotDB.Conn(context.Background())
phase4-coordinator/internal/buyer/route_snapshot_test.go-1451-	if err != nil {
--
phase4-coordinator/internal/buyer/route_snapshot_test.go-1524-	setSettlementModeForTest(billingStore, billing.RouteSnapshotModeEnforce)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1525-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/buyer/route_snapshot_test.go-1526-	if err != nil {
phase4-coordinator/internal/buyer/route_snapshot_test.go-1527-		t.Fatalf("open dedicated route snapshot db: %v", err)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1528-	}
phase4-coordinator/internal/buyer/route_snapshot_test.go:1529:	routeSnapshotDB.SetMaxOpenConns(1)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1530-	routeSnapshotDB.SetMaxIdleConns(1)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1531-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/buyer/route_snapshot_test.go-1532-	billingStore.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/buyer/route_snapshot_test.go-1533-	heldRouteSnapshotConn, err := routeSnapshotDB.Conn(context.Background())
phase4-coordinator/internal/buyer/route_snapshot_test.go-1534-	if err != nil {
--
phase4-coordinator/internal/ws/messages_test.go-88-	}
phase4-coordinator/internal/ws/messages_test.go-89-}
phase4-coordinator/internal/ws/messages_test.go-90-
phase4-coordinator/internal/ws/messages_test.go-91-func TestHandleDiagnosticStatusRequiresAssignedSession(t *testing.T) {
phase4-coordinator/internal/ws/messages_test.go-92-	// Open through the production constructor: it caps the pool at one
phase4-coordinator/internal/ws/messages_test.go:93:	// connection and sets busy_timeout/WAL. A raw sql.Open here let the
phase4-coordinator/internal/ws/messages_test.go-94-	// background event worker and the polling reader race on separate
phase4-coordinator/internal/ws/messages_test.go-95-	// pooled connections with no busy timeout, surfacing transient
phase4-coordinator/internal/ws/messages_test.go-96-	// SQLITE_BUSY under CI load.
phase4-coordinator/internal/ws/messages_test.go-97-	store, err := providerevents.Open(filepath.Join(t.TempDir(), "events.db"))
phase4-coordinator/internal/ws/messages_test.go-98-	if err != nil {
--
phase4-coordinator/internal/billing/route_snapshot_test.go-263-
phase4-coordinator/internal/billing/route_snapshot_test.go-264-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-265-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-266-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-267-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:268:	routeSnapshotDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-269-	routeSnapshotDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-270-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-271-	store.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-272-
phase4-coordinator/internal/billing/route_snapshot_test.go-273-	snapshot := testRouteSnapshot()
--
phase4-coordinator/internal/billing/route_snapshot_test.go-294-
phase4-coordinator/internal/billing/route_snapshot_test.go-295-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-296-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-297-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-298-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:299:	routeSnapshotDB.SetMaxOpenConns(4)
phase4-coordinator/internal/billing/route_snapshot_test.go-300-	routeSnapshotDB.SetMaxIdleConns(4)
phase4-coordinator/internal/billing/route_snapshot_test.go-301-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-302-	store.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-303-
phase4-coordinator/internal/billing/route_snapshot_test.go-304-	var heldRouteSnapshotConns []*sql.Conn
--
phase4-coordinator/internal/billing/route_snapshot_test.go-337-	}
phase4-coordinator/internal/billing/route_snapshot_test.go-338-	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go-339-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-340-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-341-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:342:	journalDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-343-	journalDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-344-	t.Cleanup(func() { _ = journalDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-345-	store.SetRouteSnapshotJournalDB(journalDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-346-	if err := store.InitRouteSnapshotJournal(context.Background()); err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-347-		t.Fatal(err)
--
phase4-coordinator/internal/billing/route_snapshot_test.go-349-
phase4-coordinator/internal/billing/route_snapshot_test.go-350-	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-351-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-352-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-353-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:354:	lockDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-355-	lockDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-356-	t.Cleanup(func() { _ = lockDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-357-	lockConn, err := lockDB.Conn(context.Background())
phase4-coordinator/internal/billing/route_snapshot_test.go-358-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-359-		t.Fatal(err)
--
phase4-coordinator/internal/billing/route_snapshot_test.go-411-
phase4-coordinator/internal/billing/route_snapshot_test.go-412-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-413-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-414-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-415-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:416:	routeSnapshotDB.SetMaxOpenConns(4)
phase4-coordinator/internal/billing/route_snapshot_test.go-417-	routeSnapshotDB.SetMaxIdleConns(4)
phase4-coordinator/internal/billing/route_snapshot_test.go-418-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-419-	store.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-420-
phase4-coordinator/internal/billing/route_snapshot_test.go-421-	snapshot := testRouteSnapshot()
--
phase4-coordinator/internal/billing/route_snapshot_test.go-429-
phase4-coordinator/internal/billing/route_snapshot_test.go-430-	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go-431-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-432-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-433-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:434:	journalDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-435-	journalDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-436-	t.Cleanup(func() { _ = journalDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-437-	store.SetRouteSnapshotJournalDB(journalDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-438-	if err := store.InitRouteSnapshotJournal(context.Background()); err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-439-		t.Fatal(err)
--
phase4-coordinator/internal/billing/route_snapshot_test.go-450-
phase4-coordinator/internal/billing/route_snapshot_test.go-451-	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-452-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-453-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-454-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:455:	lockDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-456-	lockDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-457-	t.Cleanup(func() { _ = lockDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-458-	lockConn, err := lockDB.Conn(context.Background())
phase4-coordinator/internal/billing/route_snapshot_test.go-459-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-460-		t.Fatal(err)
--
phase4-coordinator/internal/billing/route_snapshot_test.go-500-
phase4-coordinator/internal/billing/route_snapshot_test.go-501-	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go-502-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-503-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-504-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:505:	journalDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-506-	journalDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-507-	t.Cleanup(func() { _ = journalDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-508-	store.SetRouteSnapshotJournalDB(journalDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-509-	if err := store.InitRouteSnapshotJournal(context.Background()); err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-510-		t.Fatal(err)
--
phase4-coordinator/internal/billing/route_snapshot_test.go-541-	}
phase4-coordinator/internal/billing/route_snapshot_test.go-542-	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go-543-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-544-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-545-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:546:	journalDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-547-	journalDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-548-	t.Cleanup(func() { _ = journalDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-549-	store.SetRouteSnapshotJournalDB(journalDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-550-	store.SetRouteSnapshotBusyTimeout(50 * time.Millisecond)
phase4-coordinator/internal/billing/route_snapshot_test.go-551-	if err := store.InitRouteSnapshotJournal(context.Background()); err != nil {
--
phase4-coordinator/internal/billing/route_snapshot_test.go-590-	}
phase4-coordinator/internal/billing/route_snapshot_test.go-591-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-592-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-593-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-594-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:595:	routeSnapshotDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-596-	routeSnapshotDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-597-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-598-	store.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-599-	store.SetRouteSnapshotBusyTimeout(10 * time.Millisecond)
phase4-coordinator/internal/billing/route_snapshot_test.go-600-
phase4-coordinator/internal/billing/route_snapshot_test.go-601-	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-602-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-603-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-604-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:605:	lockDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-606-	lockDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-607-	t.Cleanup(func() { _ = lockDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-608-	lockConn, err := lockDB.Conn(context.Background())
phase4-coordinator/internal/billing/route_snapshot_test.go-609-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-610-		t.Fatal(err)
--
phase4-coordinator/internal/billing/route_snapshot_test.go-643-	}
phase4-coordinator/internal/billing/route_snapshot_test.go-644-	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-645-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-646-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-647-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:648:	routeSnapshotDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-649-	routeSnapshotDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-650-	t.Cleanup(func() { _ = routeSnapshotDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-651-	store.SetRouteSnapshotDB(routeSnapshotDB)
phase4-coordinator/internal/billing/route_snapshot_test.go-652-	store.SetRouteSnapshotBusyTimeout(10 * time.Millisecond)
phase4-coordinator/internal/billing/route_snapshot_test.go-653-
phase4-coordinator/internal/billing/route_snapshot_test.go-654-	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go-655-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-656-		t.Fatal(err)
phase4-coordinator/internal/billing/route_snapshot_test.go-657-	}
phase4-coordinator/internal/billing/route_snapshot_test.go:658:	lockDB.SetMaxOpenConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-659-	lockDB.SetMaxIdleConns(1)
phase4-coordinator/internal/billing/route_snapshot_test.go-660-	t.Cleanup(func() { _ = lockDB.Close() })
phase4-coordinator/internal/billing/route_snapshot_test.go-661-	lockConn, err := lockDB.Conn(context.Background())
phase4-coordinator/internal/billing/route_snapshot_test.go-662-	if err != nil {
phase4-coordinator/internal/billing/route_snapshot_test.go-663-		t.Fatal(err)
--
phase4-coordinator/internal/buyer/server_test.go-7307-	t.Helper()
phase4-coordinator/internal/buyer/server_test.go-7308-	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "trustpool.sqlite")))
phase4-coordinator/internal/buyer/server_test.go-7309-	if err != nil {
phase4-coordinator/internal/buyer/server_test.go-7310-		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/buyer/server_test.go-7311-	}
phase4-coordinator/internal/buyer/server_test.go:7312:	db.SetMaxOpenConns(1)
phase4-coordinator/internal/buyer/server_test.go-7313-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/buyer/server_test.go-7314-	t.Cleanup(func() { _ = db.Close() })
phase4-coordinator/internal/buyer/server_test.go-7315-	store, err := trustpool.NewStore(db)
phase4-coordinator/internal/buyer/server_test.go-7316-	if err != nil {
phase4-coordinator/internal/buyer/server_test.go-7317-		t.Fatalf("NewStore: %v", err)
--
phase5-gateway/internal/storage/sqlite/dsn.go-4-	"net/url"
phase5-gateway/internal/storage/sqlite/dsn.go-5-	"strings"
phase5-gateway/internal/storage/sqlite/dsn.go-6-)
phase5-gateway/internal/storage/sqlite/dsn.go-7-
phase5-gateway/internal/storage/sqlite/dsn.go-8-// sqliteDSN builds a modernc.org/sqlite DSN with the project's standard
phase5-gateway/internal/storage/sqlite/dsn.go:9:// pragma set (busy_timeout, foreign_keys, WAL, synchronous=NORMAL).
phase5-gateway/internal/storage/sqlite/dsn.go-10-//
phase5-gateway/internal/storage/sqlite/dsn.go-11-// ARCH-5: this helper is byte-identical to phase4-coordinator/internal/
phase5-gateway/internal/storage/sqlite/dsn.go-12-// sqliteutil/dsn.go::WithPragmas. The duplication is intentional — gateway
phase5-gateway/internal/storage/sqlite/dsn.go-13-// and coordinator are deployed as independent Go modules, and introducing a
phase5-gateway/internal/storage/sqlite/dsn.go-14-// shared library would re-couple them on every DSN tweak. See audits/
phase5-gateway/internal/storage/sqlite/dsn.go-15-// 2026-06-10/REPO_AUDIT.md (ARCH-5) for the conscious-debt reasoning.
phase5-gateway/internal/storage/sqlite/dsn.go-16-func sqliteDSN(path string) string {
phase5-gateway/internal/storage/sqlite/dsn.go-17-	values := url.Values{}
phase5-gateway/internal/storage/sqlite/dsn.go-18-	for _, pragma := range []string{
phase5-gateway/internal/storage/sqlite/dsn.go:19:		"busy_timeout=5000",
phase5-gateway/internal/storage/sqlite/dsn.go-20-		"foreign_keys=1",
phase5-gateway/internal/storage/sqlite/dsn.go:21:		"journal_mode(WAL)",
phase5-gateway/internal/storage/sqlite/dsn.go-22-		"synchronous(NORMAL)",
phase5-gateway/internal/storage/sqlite/dsn.go-23-	} {
phase5-gateway/internal/storage/sqlite/dsn.go-24-		values.Add("_pragma", pragma)
phase5-gateway/internal/storage/sqlite/dsn.go-25-	}
phase5-gateway/internal/storage/sqlite/dsn.go-26-	separator := "?"
--
phase5-gateway/internal/storage/sqlite/dsn.go-28-		separator = "&"
phase5-gateway/internal/storage/sqlite/dsn.go-29-	}
phase5-gateway/internal/storage/sqlite/dsn.go-30-	return path + separator + values.Encode()
phase5-gateway/internal/storage/sqlite/dsn.go-31-}
phase5-gateway/internal/storage/sqlite/dsn.go-32-
phase5-gateway/internal/storage/sqlite/dsn.go:33:// sqliteReadOnlyDSN returns a read-only DSN for the same file in WAL mode.
phase5-gateway/internal/storage/sqlite/dsn.go-34-// Used by Open's `OpenReadOnly` counterpart (M2-4 / PERF-4) so the gateway
phase5-gateway/internal/storage/sqlite/dsn.go-35-// can route GET-only handlers (explorer, usage) through a separate handle
phase5-gateway/internal/storage/sqlite/dsn.go-36-// with a larger conn cap, while the primary handle stays capped at 1 to
phase5-gateway/internal/storage/sqlite/dsn.go-37-// serialize `BEGIN IMMEDIATE` writes.
phase5-gateway/internal/storage/sqlite/dsn.go-38-//
phase5-gateway/internal/storage/sqlite/dsn.go-39-// modernc.org/sqlite parses the standard `mode=ro` URI parameter for
phase5-gateway/internal/storage/sqlite/dsn.go:40:// open-time read-only intent. We also assert `query_only=1` as a
phase5-gateway/internal/storage/sqlite/dsn.go-41-// per-connection pragma so every connection in the pool is locked into
phase5-gateway/internal/storage/sqlite/dsn.go-42-// read mode at the SQLite engine level (defense in depth against an
phase5-gateway/internal/storage/sqlite/dsn.go-43-// accidental write routed through readStore()).
phase5-gateway/internal/storage/sqlite/dsn.go:44:func sqliteReadOnlyDSN(path string) string {
phase5-gateway/internal/storage/sqlite/dsn.go-45-	values := url.Values{}
phase5-gateway/internal/storage/sqlite/dsn.go-46-	values.Add("mode", "ro")
phase5-gateway/internal/storage/sqlite/dsn.go-47-	for _, pragma := range []string{
phase5-gateway/internal/storage/sqlite/dsn.go:48:		"busy_timeout=5000",
phase5-gateway/internal/storage/sqlite/dsn.go-49-		"foreign_keys=1",
phase5-gateway/internal/storage/sqlite/dsn.go:50:		// journal_mode is set by the primary writer; the read handle
phase5-gateway/internal/storage/sqlite/dsn.go-51-		// follows. synchronous pinned to NORMAL for parity.
phase5-gateway/internal/storage/sqlite/dsn.go-52-		"synchronous(NORMAL)",
phase5-gateway/internal/storage/sqlite/dsn.go:53:		"query_only(1)",
phase5-gateway/internal/storage/sqlite/dsn.go-54-	} {
phase5-gateway/internal/storage/sqlite/dsn.go-55-		values.Add("_pragma", pragma)
phase5-gateway/internal/storage/sqlite/dsn.go-56-	}
phase5-gateway/internal/storage/sqlite/dsn.go-57-	separator := "?"
phase5-gateway/internal/storage/sqlite/dsn.go-58-	if strings.Contains(path, "?") {
--
phase4-coordinator/internal/onboarding/store_pg.go-95-	connector, err := pq.NewConnector(dsn)
phase4-coordinator/internal/onboarding/store_pg.go-96-	if err != nil {
phase4-coordinator/internal/onboarding/store_pg.go-97-		return nil, fmt.Errorf("open %s postgres: invalid connection string (redacted)", name)
phase4-coordinator/internal/onboarding/store_pg.go-98-	}
phase4-coordinator/internal/onboarding/store_pg.go-99-	db := sql.OpenDB(connector)
phase4-coordinator/internal/onboarding/store_pg.go:100:	db.SetMaxOpenConns(8)
phase4-coordinator/internal/onboarding/store_pg.go-101-	db.SetMaxIdleConns(4)
phase4-coordinator/internal/onboarding/store_pg.go-102-	db.SetConnMaxLifetime(30 * time.Minute)
phase4-coordinator/internal/onboarding/store_pg.go-103-	db.SetConnMaxIdleTime(5 * time.Minute)
phase4-coordinator/internal/onboarding/store_pg.go-104-	return db, nil
phase4-coordinator/internal/onboarding/store_pg.go-105-}
--
phase4-coordinator/internal/billing/store.go-116-	return s.db
phase4-coordinator/internal/billing/store.go-117-}
phase4-coordinator/internal/billing/store.go-118-
phase4-coordinator/internal/billing/store.go-119-func (s *Store) migrate(ctx context.Context) error {
phase4-coordinator/internal/billing/store.go-120-	var mode string
phase4-coordinator/internal/billing/store.go:121:	if err := s.db.QueryRowContext(ctx, `PRAGMA journal_mode=WAL`).Scan(&mode); err != nil {
phase4-coordinator/internal/billing/store.go-122-		return err
phase4-coordinator/internal/billing/store.go-123-	}
phase4-coordinator/internal/billing/store.go-124-	if !strings.EqualFold(mode, "wal") {
phase4-coordinator/internal/billing/store.go:125:		return fmt.Errorf("sqlite journal_mode must be WAL, got %s", mode)
phase4-coordinator/internal/billing/store.go-126-	}
phase4-coordinator/internal/billing/store.go-127-	if _, err := s.db.ExecContext(ctx, `
phase4-coordinator/internal/billing/store.go-128-CREATE TABLE IF NOT EXISTS ledger_request_credits (
phase4-coordinator/internal/billing/store.go-129-    id INTEGER PRIMARY KEY AUTOINCREMENT,
phase4-coordinator/internal/billing/store.go-130-    request_id TEXT NOT NULL,
--
phase5-gateway/internal/storage/sqlite/store.go-38-	}
phase5-gateway/internal/storage/sqlite/store.go-39-	db, err := sql.Open("sqlite", sqliteDSN(path))
phase5-gateway/internal/storage/sqlite/store.go-40-	if err != nil {
phase5-gateway/internal/storage/sqlite/store.go-41-		return nil, err
phase5-gateway/internal/storage/sqlite/store.go-42-	}
phase5-gateway/internal/storage/sqlite/store.go:43:	db.SetMaxOpenConns(1)
phase5-gateway/internal/storage/sqlite/store.go-44-	db.SetMaxIdleConns(1)
phase5-gateway/internal/storage/sqlite/store.go:45:	if _, err := db.ExecContext(ctx, "PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;"); err != nil {
phase5-gateway/internal/storage/sqlite/store.go-46-		_ = db.Close()
phase5-gateway/internal/storage/sqlite/store.go-47-		return nil, err
phase5-gateway/internal/storage/sqlite/store.go-48-	}
phase5-gateway/internal/storage/sqlite/store.go-49-	store := &Store{db: db}
phase5-gateway/internal/storage/sqlite/store.go-50-	if err := store.Migrate(ctx); err != nil {
--
phase5-gateway/internal/storage/sqlite/store.go-67-// running Migrate(): the read-only DSN cannot create or evolve schema.
phase5-gateway/internal/storage/sqlite/store.go-68-func OpenReadOnly(ctx context.Context, path string) (*Store, error) {

exec
/bin/bash -lc "rg -n --glob '*_test.go' 'ReadOnlyDSN|query_only|read.only|OpenReadOnly|ReadOnlyPaths|DefaultSQLitePath|stats-billing-mirror|coordinator\\.db' phase4-coordinator/internal phase4-coordinator/cmd phase4-coordinator/dist/test | head -300; printf '%s\\n' '---SQLITE UTIL TEST FILES---'; find phase4-coordinator/internal/sqliteutil -maxdepth 2 -type f -print -exec sed -n '1,220p' {} \\;" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/internal/audit/store_test.go:16:	if got, want := DefaultDBPath(filepath.Join("var", "lib", "macprovider", "coordinator.db")), filepath.Join("var", "lib", "macprovider", "coordinator-audit.db"); got != want {
phase4-coordinator/internal/audit/store_test.go:19:	if got := DefaultDBPath("coordinator.db"); got != "coordinator-audit.db" {
phase4-coordinator/internal/audit/store_test.go:86:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/audit/store_test.go:244:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/audit/store_test.go:533:	store, err := OpenStore(t.TempDir() + "/coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:69:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:132:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:155:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:41:	store, err := OpenMDAStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:57:	store, err := OpenMDAStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:374:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:517:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:584:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:942:	store, err := OpenMDAStore(filepath.Join(dir, "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:25:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/identity_migration_test.go:123:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:221:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/explorer/handlers_test.go:984:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:46:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:62:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:80:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:100:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:120:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:140:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:151:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:226:			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:244:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:274:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:379:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:540:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/cmd/coordinator-cli/referrals_test.go:15:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/referrals_test.go:99:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/rewards/wallet_status_test.go:72:		t.Fatalf("validation calls readOnly=%d marked=%d, want read-only only", tokens.readOnly, tokens.marked)
phase4-coordinator/cmd/coordinator-cli/onboarding_test.go:16:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/referralapi/advocacy_test.go:72:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1781:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1840:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1895:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1932:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2316:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2588:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admin_onboarding_test.go:56:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:38:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:43:	record, bearer, err := store.IssueToken(ctx, "provider-read-only", "dashboard polling")
phase4-coordinator/internal/auth/tokens_test.go:48:	if err != nil || !valid || providerID != "provider-read-only" {
phase4-coordinator/internal/auth/tokens_test.go:56:		t.Fatalf("read-only validation refreshed last_used_at=%v", row.LastUsedAt)
phase4-coordinator/internal/auth/tokens_test.go:64:	store, err := auth.OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:80:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:96:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:181:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:217:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:252:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:307:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:345:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:394:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:457:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:499:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:518:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:537:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:563:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:584:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:627:				store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:664:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:711:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:754:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:774:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:792:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:832:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:858:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:944:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:964:		dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:997:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1011:		t.Fatalf("read-only expired validation provider=%q valid=%v err=%v", providerID, valid, err)
phase4-coordinator/internal/auth/tokens_test.go:1028:		t.Fatalf("expired read-only validation state revoked=%v last_used=%v confirmed=%v", revokedAt, lastUsedAt, confirmedAt)
phase4-coordinator/internal/auth/tokens_test.go:1034:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1071:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1105:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1249:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1285:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1347:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1390:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1406:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1458:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1526:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1589:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:186:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:399:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:433:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:617:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:842:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:912:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:954:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1030:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1069:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1109:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/model_admission_test.go:1227:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1313:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1372:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1491:		db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1537:		db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1551:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1665:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/canary_store_test.go:14:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:45:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:75:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:96:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:114:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:132:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:152:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:189:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:257:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:290:		store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:316:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:387:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:411:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_core_test.go:459:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:17:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:52:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_r008_test.go:220:// writer side. This protects buyer routing when its read-only store saw the
phase4-coordinator/internal/ws/admission_canary_harness_test.go:214:		t.Fatal("read-only endpoint mutated proof-of-weights config")
phase4-coordinator/internal/ws/admission_canary_harness_test.go:221:		t.Fatalf("read-only endpoint mutated admission flags: %+v", snap)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:4:// MUST be read-only — running the daemon's migrate() inside --check
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:27:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:111:		t.Errorf("--check mutated schema: external_request_id column present after read-only invocation")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:114:		t.Errorf("--check mutated schema: account_id column present after read-only invocation")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:123:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/auth/admission_recovery_atomic_test.go:16:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_probe_test.go:531:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:19:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:32:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:68:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:88:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:109:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/cmd/coordinator/main_test.go:1477:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/onboarding_funnel_test.go:14:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/onboarding_funnel_test.go:135:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:373:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:407:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:436:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:482:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:547:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:634:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:679:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:717:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:922:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:968:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:42:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:113:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:163:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:188:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:251:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:324:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:365:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:418:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:479:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:541:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:620:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:712:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:763:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:813:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:876:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_decision_store_test.go:25:			db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/spec014_pairing_test.go:111:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/spec014_pairing_test.go:141:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_social_test.go:39:	return openSocialStoreAt(t, filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_social_test.go:66:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_social_test.go:194:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_social_test.go:249:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_social_test.go:290:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_admin_test.go:28:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/compute_integrity_status_test.go:213:		t.Fatalf("read-only validation calls=%d, want 1", tokens.readOnlyCalls)
phase4-coordinator/internal/trustpool/spec043_creator_mvp_journey_test.go:810:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:240:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:284:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:328:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:401:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:484:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:532:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:581:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:634:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/model_admission_disablement_test.go:23:			authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_disablement_test.go:120:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_operator_test.go:392:	// authority without read-only validation, or one that errors, refuses
phase4-coordinator/internal/ws/model_admission_operator_test.go:395:		"no read-only validation": noReadOnlyProviderTokens{},
phase4-coordinator/internal/ws/model_admission_operator_test.go:479:// noReadOnlyProviderTokens is a token authority without read-only validation.
phase4-coordinator/internal/ws/auth_github_test.go:678:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:141:	authStore, err := auth.OpenStore(filepath.Join(dir, "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_intake_test.go:279:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:353:	tokenStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:504:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:537:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:613:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:659:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:714:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:802:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:891:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:954:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:1214:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:1334:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/referral_core_test.go:31:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/stats/integration_test.go:2109:// provider_onboarding read-only anti-fraud boundary against the real grants.
phase4-coordinator/internal/buyer/server_test.go:101:	store, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/buyer/server_test.go:7291:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/settlement_unsettled_leg_test.go:25:	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/stats/migrations/migrations_test.go:734:		// FIX 4 (round-6): rollback also revokes the read-only trust SELECT that the
phase4-coordinator/internal/buyer/billing_recorder_test.go:43:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:113:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:170:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:249:			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/seam_h4_test.go:47:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
---SQLITE UTIL TEST FILES---
phase4-coordinator/internal/sqliteutil/wal_test.go
package sqliteutil

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func openManualCheckpointDB(t *testing.T) (dbPath string, db *sql.DB) {
	t.Helper()
	dbPath = filepath.Join(t.TempDir(), "checkpoint.db")
	db, err := sql.Open("sqlite", WithManualWALCheckpointPragmas(dbPath))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a'), ('b'), ('c')`); err != nil {
		t.Fatalf("insert: %v", err)
	}
	return dbPath, db
}

func TestRunWALCheckpointModeTruncateShrinksWAL(t *testing.T) {
	dbPath, db := openManualCheckpointDB(t)
	if size := WALFileSize(dbPath); size == 0 {
		t.Fatal("WAL size before TRUNCATE = 0, want growth from inserts")
	}

	observer := &testObserver{}
	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, WALCheckpointTruncate)
	if err != nil {
		t.Fatalf("TRUNCATE checkpoint: %v", err)
	}
	if result.Busy != 0 {
		t.Fatalf("TRUNCATE busy=%d want 0", result.Busy)
	}
	assertWALObservations(t, observer)
	if size := WALFileSize(dbPath); size != 0 {
		t.Fatalf("WAL size after TRUNCATE=%d want 0", size)
	}
}

func TestRunWALCheckpointModePassiveIsValid(t *testing.T) {
	dbPath, db := openManualCheckpointDB(t)
	observer := &testObserver{}
	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, WALCheckpointPassive)
	if err != nil {
		t.Fatalf("PASSIVE checkpoint: %v", err)
	}
	if result.LogPages < 0 || result.CheckpointedPages < 0 {
		t.Fatalf("PASSIVE result = %+v, want non-negative pages", result)
	}
	assertWALObservations(t, observer)
	if _, err := os.Stat(dbPath); err != nil {
		t.Fatalf("db missing after PASSIVE: %v", err)
	}
}

func TestRunWALCheckpointModeRejectsInvalidMode(t *testing.T) {
	_, db := openManualCheckpointDB(t)
	for _, mode := range []WALCheckpointMode{
		"RESTART",
		"TRUNCATE); DROP TABLE t; --",
	} {
		observer := &testObserver{}
		result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, mode)
		if err == nil {
			t.Fatalf("mode %q returned nil error", mode)
		}
		if !strings.Contains(err.Error(), "unsupported wal checkpoint mode") {
			t.Fatalf("mode %q error = %v, want unsupported", mode, err)
		}
		if result != (WALCheckpointResult{}) {
			t.Fatalf("mode %q result = %+v, want zero value", mode, result)
		}
		if len(observer.events) != 0 {
			t.Fatalf("mode %q emitted observations: %+v", mode, observer.events)
		}
	}
	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('still-there')`); err != nil {
		t.Fatalf("table t should still exist after rejected mode: %v", err)
	}
}

func TestWALFileSizeMissingIsZero(t *testing.T) {
	if got := WALFileSize(filepath.Join(t.TempDir(), "missing.db")); got != 0 {
		t.Fatalf("WALFileSize(missing)=%d want 0", got)
	}
}

func TestSetBusyTimeout(t *testing.T) {
	_, db := openManualCheckpointDB(t)
	if err := SetBusyTimeout(context.Background(), db, 15*time.Second); err != nil {
		t.Fatalf("SetBusyTimeout: %v", err)
	}
	var ms int64
	if err := db.QueryRow(`PRAGMA busy_timeout`).Scan(&ms); err != nil {
		t.Fatalf("PRAGMA busy_timeout: %v", err)
	}
	if ms != 15000 {
		t.Fatalf("busy_timeout=%d want 15000", ms)
	}
}

func TestSetBusyTimeoutBoundsTruncateWaitAgainstReader(t *testing.T) {
	dbPath, db := openManualCheckpointDB(t)
	reader, err := sql.Open("sqlite", WithPragmas(dbPath))
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	tx, err := reader.Begin()
	if err != nil {
		t.Fatalf("begin reader tx: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback() })
	rows, err := tx.Query(`SELECT v FROM t`)
	if err != nil {
		t.Fatalf("reader select: %v", err)
	}
	t.Cleanup(func() { _ = rows.Close() })
	if !rows.Next() {
		t.Fatal("reader select returned no rows")
	}

	if err := SetBusyTimeout(context.Background(), db, 50*time.Millisecond); err != nil {
		t.Fatalf("SetBusyTimeout: %v", err)
	}
	started := time.Now()
	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", nil, WALCheckpointTruncate)
	elapsed := time.Since(started)
	if err != nil {
		t.Fatalf("TRUNCATE with held reader: %v", err)
	}
	if result.Busy == 0 {
		t.Fatal("TRUNCATE busy=0 with held reader, want busy!=0")
	}
	if elapsed > time.Second {
		t.Fatalf("TRUNCATE waited %s, want ~50ms busy_timeout not the 5s DSN default", elapsed)
	}
}

func assertWALObservations(t *testing.T, observer *testObserver) {
	t.Helper()
	assertObserved(t, observer.events, observedEvent{kind: "wal:busy", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:log", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:checkpointed", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal_duration", component: "wal_checkpoint", outcome: "success"})
}
phase4-coordinator/internal/sqliteutil/transact.go
package sqliteutil

import (
	"context"
	"database/sql"
	"time"
)

// Observer receives closed-set SQLite timing observations from money-path
// stores. Implementations must keep labels bounded; component values are
// call-site constants, and outcome is "success" or "error".
type Observer interface {
	ObserveSQLiteConnectionWait(component, outcome string, duration time.Duration)
	ObserveSQLiteTransactionDuration(component, outcome string, duration time.Duration)
}

// Transact reserves a single *sql.Conn from db, issues BEGIN IMMEDIATE to
// take the SQLite write lock deterministically, invokes fn with the
// reserved connection, and then COMMITs on nil error or ROLLBACKs on
// non-nil error (or panic).
//
// The ROLLBACK is issued with context.Background(), never the caller's
// ctx, so cancellation of the request context after a partial write does
// not leave the transaction dangling.
//
// The callback receives the reserved *sql.Conn and MUST issue all
// subsequent statements against it — SQLite transactions are bound to a
// single connection, and running a statement on a different conn from the
// pool while a BEGIN IMMEDIATE is in flight would deadlock against the
// write lock this call is holding.
//
// This helper replaces the hand-rolled
//
//	conn, _ := s.db.Conn(ctx); defer conn.Close()
//	conn.ExecContext(ctx, "BEGIN IMMEDIATE")
//	committed := false
//	defer func() { if !committed { _, _ = conn.ExecContext(context.Background(), "ROLLBACK") } }()
//	... work ...
//	conn.ExecContext(ctx, "COMMIT"); committed = true
//
// pattern used across money-path stores (billing, auth token issuance,
// requestlog, receipts). Semantics are byte-equivalent to that pattern;
// see phase4-coordinator/internal/sqliteutil/transact_test.go for the
// invariant coverage.
func Transact(ctx context.Context, db *sql.DB, fn func(context.Context, *sql.Conn) error) (err error) {
	return TransactObserved(ctx, db, "", nil, fn)
}

// TransactObserved is Transact with optional timing observation for the
// sql.DB connection wait and full BEGIN IMMEDIATE..COMMIT/ROLLBACK duration.
func TransactObserved(ctx context.Context, db *sql.DB, component string, observer Observer, fn func(context.Context, *sql.Conn) error) (err error) {
	connWaitStarted := time.Now()
	conn, cerr := db.Conn(ctx)
	observeConnectionWait(observer, component, cerr, time.Since(connWaitStarted))
	if cerr != nil {
		return cerr
	}
	defer conn.Close()

	txStarted := time.Now()
	txErr := true
	defer func() {
		if err == nil && !txErr {
			observeTransactionDuration(observer, component, nil, time.Since(txStarted))
			return
		}
		observeTransactionDuration(observer, component, err, time.Since(txStarted))
	}()

	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	if err := fn(ctx, conn); err != nil {
		return err
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	txErr = false
	return nil
}

func observeConnectionWait(observer Observer, component string, err error, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteConnectionWait(component, sqliteOutcome(err), duration)
}

func observeTransactionDuration(observer Observer, component string, err error, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteTransactionDuration(component, sqliteOutcome(err), duration)
}

func sqliteOutcome(err error) string {
	if err != nil {
		return "error"
	}
	return "success"
}
phase4-coordinator/internal/sqliteutil/wal.go
package sqliteutil

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"time"
)

// WALCheckpointMode is a closed set of SQLite wal_checkpoint modes used by
// the money checkpointer. SQL is selected by switch, never by interpolating
// caller strings. RESTART is intentionally omitted: it waits on readers and
// is forbidden on the live soak path.
type WALCheckpointMode string

const (
	WALCheckpointPassive  WALCheckpointMode = "PASSIVE"
	WALCheckpointTruncate WALCheckpointMode = "TRUNCATE"
)

// WALCheckpointResult is the busy/log/checkpointed triple from
// PRAGMA wal_checkpoint.
type WALCheckpointResult struct {
	Busy              int64
	LogPages          int64
	CheckpointedPages int64
}

// WALObserver receives closed-set WAL checkpoint page observations.
type WALObserver interface {
	ObserveSQLiteWALCheckpoint(component, pageClass, outcome string, pages int64)
	ObserveSQLiteWALCheckpointDuration(component, outcome string, duration time.Duration)
}

func walCheckpointSQL(mode WALCheckpointMode) (string, error) {
	switch mode {
	case WALCheckpointPassive:
		return `PRAGMA wal_checkpoint(PASSIVE)`, nil
	case WALCheckpointTruncate:
		return `PRAGMA wal_checkpoint(TRUNCATE)`, nil
	default:
		return "", fmt.Errorf("sqliteutil: unsupported wal checkpoint mode %q", mode)
	}
}

// RunWALCheckpointMode runs a bounded checkpoint in a closed-set mode and
// observes the busy/log/checkpointed page counts. Callers should provide an
// off-hot-path *sql.DB so disabling wal_autocheckpoint does not move
// checkpoint work onto request or billing pools.
func RunWALCheckpointMode(ctx context.Context, db *sql.DB, component string, observer WALObserver, mode WALCheckpointMode) (WALCheckpointResult, error) {
	query, err := walCheckpointSQL(mode)
	if err != nil {
		return WALCheckpointResult{}, err
	}
	var result WALCheckpointResult
	started := time.Now()
	err = db.QueryRowContext(ctx, query).Scan(&result.Busy, &result.LogPages, &result.CheckpointedPages)
	outcome := sqliteOutcome(err)
	observeWALCheckpointDuration(observer, component, outcome, time.Since(started))
	observeWALCheckpoint(observer, component, "busy", outcome, result.Busy)
	observeWALCheckpoint(observer, component, "log", outcome, result.LogPages)
	observeWALCheckpoint(observer, component, "checkpointed", outcome, result.CheckpointedPages)
	return result, err
}

// RunWALCheckpoint runs a bounded TRUNCATE checkpoint on the supplied SQLite
// handle and observes the busy/log/checkpointed page counts.
func RunWALCheckpoint(ctx context.Context, db *sql.DB, component string, observer WALObserver) error {
	_, err := RunWALCheckpointMode(ctx, db, component, observer, WALCheckpointTruncate)
	return err
}

// WALFileSize returns the size of dbPath's sidecar WAL file, or 0 if the
// file is missing or unreadable.
func WALFileSize(dbPath string) int64 {
	info, err := os.Stat(dbPath + "-wal")
	if err != nil {
		return 0
	}
	return info.Size()
}

const maxBusyTimeout = 5 * time.Minute

// SetBusyTimeout sets PRAGMA busy_timeout on db to timeout, clamped to
// [1ms, 5m]. The duration is converted to a decimal integer; it is not
// interpolated as a SQL keyword or identifier.
func SetBusyTimeout(ctx context.Context, db *sql.DB, timeout time.Duration) error {
	if db == nil {
		return fmt.Errorf("sqliteutil: nil db")
	}
	if timeout > maxBusyTimeout {
		timeout = maxBusyTimeout
	}
	ms := timeout.Milliseconds()
	if ms < 1 {
		ms = 1
	}
	_, err := db.ExecContext(ctx, "PRAGMA busy_timeout = "+strconv.FormatInt(ms, 10))
	return err
}

func observeWALCheckpoint(observer WALObserver, component, pageClass, outcome string, pages int64) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteWALCheckpoint(component, pageClass, outcome, pages)
}

func observeWALCheckpointDuration(observer WALObserver, component, outcome string, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteWALCheckpointDuration(component, outcome, duration)
}
phase4-coordinator/internal/sqliteutil/transact_test.go
package sqliteutil

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

type observedEvent struct {
	kind      string
	component string
	outcome   string
}

type testObserver struct {
	events []observedEvent
}

func (o *testObserver) ObserveSQLiteConnectionWait(component, outcome string, _ time.Duration) {
	o.events = append(o.events, observedEvent{kind: "conn", component: component, outcome: outcome})
}

func (o *testObserver) ObserveSQLiteTransactionDuration(component, outcome string, _ time.Duration) {
	o.events = append(o.events, observedEvent{kind: "tx", component: component, outcome: outcome})
}

func (o *testObserver) ObserveSQLiteWALCheckpoint(component, pageClass, outcome string, _ int64) {
	o.events = append(o.events, observedEvent{kind: "wal:" + pageClass, component: component, outcome: outcome})
}

func (o *testObserver) ObserveSQLiteWALCheckpointDuration(component, outcome string, _ time.Duration) {
	o.events = append(o.events, observedEvent{kind: "wal_duration", component: component, outcome: outcome})
}

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	return db
}

func rowCount(t *testing.T, db *sql.DB) int {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM t`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	return n
}

func TestTransactCommitsOnNilError(t *testing.T) {
	db := openTestDB(t)
	err := Transact(context.Background(), db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a'), ('b')`); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatalf("Transact returned err: %v", err)
	}
	if n := rowCount(t, db); n != 2 {
		t.Fatalf("row count after commit = %d, want 2", n)
	}
}

func TestTransactRollsBackOnError(t *testing.T) {
	db := openTestDB(t)
	sentinel := errors.New("callback rejected")
	err := Transact(context.Background(), db, func(ctx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a')`); err != nil {
			return err
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("Transact returned %v, want sentinel", err)
	}
	if n := rowCount(t, db); n != 0 {
		t.Fatalf("row count after rollback = %d, want 0", n)
	}
}

// TestTransactRollbackUsesBackgroundContext verifies the load-bearing
// invariant that ROLLBACK is issued with context.Background(), not the
// caller's ctx: a caller who cancels their ctx after a partial write must
// not leave the SQLite write lock held.
func TestTransactRollbackUsesBackgroundContext(t *testing.T) {
	db := openTestDB(t)
	ctx, cancel := context.WithCancel(context.Background())
	sentinel := errors.New("aborting after partial write")
	err := Transact(ctx, db, func(innerCtx context.Context, conn *sql.Conn) error {
		if _, err := conn.ExecContext(innerCtx, `INSERT INTO t (v) VALUES ('a')`); err != nil {
			return err
		}
		// Simulate a caller cancelling before the callback returns.
		// If the helper used innerCtx for ROLLBACK, the rollback exec
		// would fail with context.Canceled and the tx would leak. Our
		// invariant is that ROLLBACK runs on context.Background().
		cancel()
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("Transact returned %v, want sentinel", err)
	}
	// Prove the tx was fully unwound: a fresh BEGIN IMMEDIATE on a
	// separate conn must succeed immediately. If the previous tx
	// held the writer lock the busy_timeout would fire (or with our
	// pool of 1, this would deadlock).
	if err := Transact(context.Background(), db, func(c context.Context, conn *sql.Conn) error {
		_, err := conn.ExecContext(c, `INSERT INTO t (v) VALUES ('b')`)
		return err
	}); err != nil {
		t.Fatalf("follow-up Transact after cancelled-caller rollback: %v", err)
	}
	if n := rowCount(t, db); n != 1 {
		t.Fatalf("row count = %d, want 1 (only the follow-up commit)", n)
	}
}

func TestTransactBeginError(t *testing.T) {
	db := openTestDB(t)
	_ = db.Close() // force db.Conn to fail
	err := Transact(context.Background(), db, func(ctx context.Context, conn *sql.Conn) error {
		t.Fatal("callback should not run when db is closed")
		return nil
	})
	if err == nil {
		t.Fatal("Transact returned nil on closed db, want error")
	}
}

func TestTransactObservedEmitsConnectionWaitAndTransactionOutcome(t *testing.T) {
	db := openTestDB(t)
	observer := &testObserver{}

	err := TransactObserved(context.Background(), db, "billing_hot_path", observer, func(ctx context.Context, conn *sql.Conn) error {
		_, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a')`)
		return err
	})
	if err != nil {
		t.Fatalf("TransactObserved success path returned err: %v", err)
	}

	sentinel := errors.New("callback rejected")
	err = TransactObserved(context.Background(), db, "billing_hot_path", observer, func(context.Context, *sql.Conn) error {
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("TransactObserved returned %v, want sentinel", err)
	}

	assertObserved(t, observer.events, observedEvent{kind: "conn", component: "billing_hot_path", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "tx", component: "billing_hot_path", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "tx", component: "billing_hot_path", outcome: "error"})
}

func TestRunWALCheckpointEmitsPageClasses(t *testing.T) {
	dbPath := t.TempDir() + "/checkpoint.db"
	db, err := sql.Open("sqlite", WithManualWALCheckpointPragmas(dbPath))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a')`); err != nil {
		t.Fatalf("insert: %v", err)
	}

	observer := &testObserver{}
	if err := RunWALCheckpoint(context.Background(), db, "wal_checkpoint", observer); err != nil {
		t.Fatalf("RunWALCheckpoint returned err: %v", err)
	}

	assertObserved(t, observer.events, observedEvent{kind: "wal:busy", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:log", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal:checkpointed", component: "wal_checkpoint", outcome: "success"})
	assertObserved(t, observer.events, observedEvent{kind: "wal_duration", component: "wal_checkpoint", outcome: "success"})
	if info, err := os.Stat(dbPath + "-wal"); err == nil && info.Size() != 0 {
		t.Fatalf("WAL size after TRUNCATE checkpoint=%d want 0", info.Size())
	}
}

func assertObserved(t *testing.T, events []observedEvent, want observedEvent) {
	t.Helper()
	for _, got := range events {
		if got == want {
			return
		}
	}
	t.Fatalf("missing observation %+v in %+v", want, events)
}
phase4-coordinator/internal/sqliteutil/dsn.go
package sqliteutil

import (
	"net/url"
	"strings"
)

// WithPragmas builds a modernc.org/sqlite DSN with the project's standard
// pragma set (busy_timeout, foreign_keys, WAL, synchronous=FULL).
//
// ARCH-5: this helper deliberately mirrors the gateway SQLite DSN shape while
// remaining coordinator-owned. The duplication is intentional — coordinator
// and gateway are deployed as independent Go modules, and introducing a shared
// library would re-couple them on every DSN tweak. See audits/2026-06-10/
// REPO_AUDIT.md (ARCH-5) for the conscious-debt reasoning.
//
// SPEC-016 §3.1 requires synchronous=FULL on every connection
// touching provider_payout_addresses or payout_attempts. Because
// the coordinator shares one *sql.DB handle across requestlog,
// billing, audit, and payout (SPEC-016 §4.8a / §4.8b same-DB
// pins make the shared handle structurally necessary), the DSN
// is the only place to set the per-connection pragma. The prior
// value was NORMAL; the change carries a non-trivial write-
// throughput cost on every billing/requestlog INSERT, and is
// called out explicitly in SPEC-016 IMPL Step 1 audit prompt.
func WithPragmas(path string) string {
	values := url.Values{}
	for _, pragma := range []string{
		"busy_timeout=5000",
		"foreign_keys=1",
		"journal_mode(WAL)",
		"synchronous(FULL)",
	} {
		values.Add("_pragma", pragma)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + values.Encode()
}

// WithManualWALCheckpointPragmas disables SQLite's autocheckpoint for a DB
// handle whose owner starts an explicit off-hot-path checkpoint loop.
func WithManualWALCheckpointPragmas(path string) string {
	base := WithPragmas(path)
	values := url.Values{}
	values.Add("_pragma", "wal_autocheckpoint(0)")
	separator := "?"
	if strings.Contains(base, "?") {
		separator = "&"
	}
	return base + separator + values.Encode()
}

// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
// Opens with mode=ro and applies PRAGMA query_only=ON at connection
// init via a pragma — no journal_mode toggle, no synchronous toggle,
// no writable connection. SPEC-002 v1.5.1 R-2 / issue #197 R3 code:
// used by `coordinator migrate-indexes --check` so the read-only
// introspection never persists journal-mode metadata or runs ALTER
// TABLE on a legacy DB.
func ReadOnlyDSN(path string) string {
	values := url.Values{}
	values.Set("mode", "ro")
	for _, pragma := range []string{
		"busy_timeout=5000",
		"query_only(true)",
	} {
		values.Add("_pragma", pragma)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + values.Encode()
}

codex
Source tracing confirms the production path now points to `coordinator.db`, the deploy snapshots/grants its `-wal`/`-shm`, and recovery restores ACL snapshots by the paths embedded in those snapshots. `OpenSQLite` already uses the shared strict `ReadOnlyDSN` (`mode=ro`, `query_only`, 5s busy timeout, no journal-mode pragma), with a one-connection pool. I’m now running the existing mirror/deploy/recovery tests that exercise these surfaces.
exec
/bin/bash -lc 'go test ./internal/stats/billingmirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash dist/test/coordinator_deploy_recovery.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 368ms:
ok: stats billing mirror deploy wiring

 succeeded in 431ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	(cached)

 succeeded in 3206ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.MDCXNWXVcZ: line 1: 88120 Alarm clock: 14         python3 -c '
import os
import signal
import sys

timeout_s = int(sys.argv[1])
if timeout_s < 1:
    raise SystemExit("deadline must be at least one second")
signal.alarm(timeout_s)
os.execvp(sys.argv[2], sys.argv[2:])
' "$timeout_s" "$@"
PASS: deploy autotune feed access guards present

 succeeded in 11077ms:
PASS: coordinator deploy recovery is durable and state-exact

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/stats-billing-mirror.service | sed -n '1,40p'; printf '%s\\n' '---COORDINATOR QUIESCE/ACL ORDER---'; rg -n -C 8 'systemctl (stop|restart) macprovider-coordinator|setfacl -m u:macprovider-stats|snapshot_acl|stats-billing-mirror' phase4-coordinator/dist/deploy-pearl-vps.sh | head -260; printf '%s\\n' '---CHANGED COMMIT METADATA---'; git show -s --format=fuller HEAD" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
     1	[Unit]
     2	Description=MacProvider stats billing mirror
     3	Documentation=https://github.com/augstar/macprovider-poc
     4	Wants=network-online.target
     5	After=network-online.target
     6	ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
     7	ConditionPathExists=/var/lib/macprovider/coordinator.db
     8	
     9	[Service]
    10	Type=oneshot
    11	User=macprovider-stats
    12	Group=macprovider-stats
    13	EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
    14	ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
    15	Nice=10
    16	IOSchedulingClass=best-effort
    17	IOSchedulingPriority=7
    18	NoNewPrivileges=true
    19	PrivateDevices=true
    20	PrivateTmp=true
    21	ProtectHome=true
    22	ProtectSystem=strict
    23	ReadOnlyPaths=/var/lib/macprovider/coordinator.db
    24	ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
    25	ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
    26	InaccessiblePaths=/etc/macprovider
    27	InaccessiblePaths=-/opt/macprovider/coordinator.yaml
    28	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
---COORDINATOR QUIESCE/ACL ORDER---
621-if [ "${STATS_DOMAIN:-stats.malibu.tech}" != "stats.malibu.tech" ]; then
622-  echo "aborting deploy: STATS_DOMAIN override (${STATS_DOMAIN}) does not match the baked-in vhost template" >&2
623-  exit 1
624-fi
625-
626-BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-linux-amd64"
627-CLI_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-cli-linux-amd64"
628-STATS_INVENTORY_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-inventory-sync-linux-amd64"
629:STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"
630-STATS_HARDWARE_VERIFIER_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-hardware-verifier-linux-amd64"
631-CONFIG="$PINNED_DIST_DIR/coordinator.yaml"
632-DEPLOY_CONFIG="$CONFIG"
633-SERVICE="$PINNED_DIST_DIR/macprovider-coordinator.service"
634-DEPLOY_RECOVER="$PINNED_DIST_DIR/coordinator-deploy-recover.sh"
635-DEPLOY_GUARD="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-guard.conf"
636-DEPLOY_RECOVERY_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-recovery.service"
637-DEPLOY_WATCHDOG_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-watchdog.service"
638-STATS_INVENTORY_SERVICE="$PINNED_DIST_DIR/stats-inventory-sync.service"
639-STATS_INVENTORY_TIMER="$PINNED_DIST_DIR/stats-inventory-sync.timer"
640:STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"
641:STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"
642-STATS_HARDWARE_VERIFIER_SERVICE="$PINNED_DIST_DIR/stats-hardware-verifier.service"
643-STATS_HARDWARE_VERIFIER_TIMER="$PINNED_DIST_DIR/stats-hardware-verifier.timer"
644-NGINX_SITE="$PINNED_DIST_DIR/nginx-coordinator.malibu.tech.conf"
645-TCP_SYSCTL="$PINNED_DIST_DIR/sysctl.d/99-macprovider-tcp.conf"
646-TCP_BBR_MODULES_LOAD="$PINNED_DIST_DIR/modules-load.d/tcp_bbr.conf"
647-# SPEC-017 v0.1.8 Step 4.B — additional nginx artifacts the
648-# coordinator vhost depends on:
649-#   - stats-shared.conf is the http-context snippet declaring the
--
1986-  fi
1987-  if [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
1988-    chown root:root /etc/macprovider-stats/stats-inventory-sync.env
1989-    chmod 0600 /etc/macprovider-stats/stats-inventory-sync.env
1990-    echo "  enforced stats inventory env perms: root:root 0600"
1991-  else
1992-    echo "  /etc/macprovider-stats/stats-inventory-sync.env not yet present; stats inventory timer remains opt-in"
1993-  fi
1994:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ]; then
1995:    chown root:root /etc/macprovider-stats/stats-billing-mirror.env
1996:    chmod 0600 /etc/macprovider-stats/stats-billing-mirror.env
1997-    echo "  enforced stats billing mirror env perms: root:root 0600"
1998-  else
1999:    echo "  /etc/macprovider-stats/stats-billing-mirror.env not yet present; stats billing mirror timer remains opt-in"
2000-  fi
2001-  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
2002-    chown root:root /etc/macprovider-stats/stats-hardware-verifier.env
2003-    chmod 0600 /etc/macprovider-stats/stats-hardware-verifier.env
2004-    echo "  enforced stats hardware verifier env perms: root:root 0600"
2005-  else
2006-    echo "  /etc/macprovider-stats/stats-hardware-verifier.env not yet present; stats hardware verifier timer remains opt-in"
2007-  fi
--
3063-      touch \"\$_rollback_stage/\$_marker\"
3064-    fi
3065-  }
3066-  snapshot_active() {
3067-    if systemctl is-active --quiet \"\$1\"; then
3068-      touch \"\$_rollback_stage/\$2\"
3069-    fi
3070-  }
3071:  snapshot_acl() {
3072-    _source=\"\$1\"
3073-    _snapshot=\"\$2\"
3074-    _marker=\"\$3\"
3075-    if [ -e \"\$_source\" ]; then
3076-      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
3077-      touch \"\$_rollback_stage/\$_marker\"
3078-    fi
3079-  }
--
3086-  snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
3087-  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
3088-  snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
3089-  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
3090-  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
3091-  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
3092-  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
3093-  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
3094:  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
3095-  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
3096-  if [ -f /opt/macprovider/coordinator.yaml ]; then
3097-    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
3098-    touch \"\$_rollback_stage/had-config\"
3099-  fi
3100-  if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
3101-    echo 'unsafe existing Tier-2 catalog path' >&2
3102-    exit 1
--
3106-    touch \"\$_rollback_stage/had-tier2-catalog\"
3107-  fi
3108-  if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
3109-    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
3110-    touch \"\$_rollback_stage/had-service-unit\"
3111-  fi
3112-  snapshot_node /etc/systemd/system/stats-inventory-sync.service stats-inventory-sync.service had-stats-inventory-service
3113-  snapshot_node /etc/systemd/system/stats-inventory-sync.timer stats-inventory-sync.timer had-stats-inventory-timer
3114:  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
3115:  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
3116-  snapshot_node /etc/systemd/system/stats-hardware-verifier.service stats-hardware-verifier.service had-stats-hardware-service
3117-  snapshot_node /etc/systemd/system/stats-hardware-verifier.timer stats-hardware-verifier.timer had-stats-hardware-timer
3118-  snapshot_node /etc/systemd/system/timers.target.wants/stats-inventory-sync.timer stats-inventory-sync.wants had-stats-inventory-wants
3119:  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
3120-  snapshot_node /etc/systemd/system/timers.target.wants/stats-hardware-verifier.timer stats-hardware-verifier.wants had-stats-hardware-wants
3121-  snapshot_active stats-inventory-sync.timer stats-inventory-timer-was-active
3122-  snapshot_active stats-inventory-sync.service stats-inventory-service-was-active
3123:  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
3124:  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
3125-  snapshot_active stats-hardware-verifier.timer stats-hardware-timer-was-active
3126-  snapshot_active stats-hardware-verifier.service stats-hardware-service-was-active
3127-
3128-  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
3129-  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
3130-  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
3131-  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
3132-  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
3133-  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
3134-  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
3135-  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
3136-  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
3137-  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
3138-
3139-  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
3144-  fi
3145-  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
3146-    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
3147-    touch \"\$_rollback_stage/had-wants-link\"
3148-  fi
3149-  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
3150-    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
3151-    touch \"\$_rollback_stage/had-recovery-helper\"
--
3189-# create non-rollbackable database effects before the catalog canary passes.
3190-# NOTE: stats-inventory-sync is deliberately NOT in this loop — it is quiesced
3191-# earlier (before the onboarding migration preflight) because migration 019
3192-# makes the old inventory binary incompatible with the migrated schema, so it
3193-# must be down before the migration is exercised, not merely before install.
3194-$SSH 'set -eu
3195-  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
3196-  flock -s 8
3197:  for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
3198-    load_state=$(systemctl show -p LoadState --value "$unit")
3199-    [ "$load_state" = not-found ] && continue
3200-    systemctl stop "$unit"
3201-    active_state=$(systemctl show -p ActiveState --value "$unit")
3202-    case "$active_state" in
3203-      inactive|failed) ;;
3204-      *) echo "sidecar unit did not stop: $unit state=$active_state" >&2; exit 1 ;;
3205-    esac
--
3233-}
3234-_append_deploy_input_digest() {
3235-  local source_path="$1" remote_name="$2"
3236-  shasum -a 256 "$source_path" | awk -v name="$remote_name" '{ print $1 "  " name }' >> "$DEPLOY_INPUT_MANIFEST_TMP"
3237-}
3238-_append_deploy_input_digest "$BINARY" "coordinator-linux-amd64"
3239-_append_deploy_input_digest "$CLI_BINARY" "coordinator-cli-linux-amd64"
3240-_append_deploy_input_digest "$STATS_INVENTORY_BINARY" "stats-inventory-sync-linux-amd64"
3241:_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
3242-_append_deploy_input_digest "$STATS_HARDWARE_VERIFIER_BINARY" "stats-hardware-verifier-linux-amd64"
3243-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
3244-  _append_deploy_input_digest "$CONFIG" "coordinator.yaml"
3245-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
3246-  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
3247-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
3248-  _append_deploy_input_digest "$C2_TIMER_MIGRATED_CONFIG_TMP" "coordinator.c2-timer-migration.yaml"
3249-fi
--
3251-  _append_deploy_input_digest "$RATE_CARD_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.rate-card-migration.yaml"
3252-elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
3253-  _append_deploy_input_digest "$C2_TIMER_MIGRATED_OVERLAY_TMP" "coordinator.pearl-overlays.c2-timer-migration.yaml"
3254-fi
3255-for _deploy_input in \
3256-  "$SERVICE=macprovider-coordinator.service" \
3257-  "$STATS_INVENTORY_SERVICE=stats-inventory-sync.service" \
3258-  "$STATS_INVENTORY_TIMER=stats-inventory-sync.timer" \
3259:  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
3260:  "$STATS_BILLING_MIRROR_TIMER=stats-billing-mirror.timer" \
3261-  "$STATS_HARDWARE_VERIFIER_SERVICE=stats-hardware-verifier.service" \
3262-  "$STATS_HARDWARE_VERIFIER_TIMER=stats-hardware-verifier.timer" \
3263-  "$NGINX_SITE=nginx-coordinator-full.conf" \
3264-  "$NGINX_STATS_SHARED=nginx-stats-shared.conf" \
3265-  "$NGINX_STATS_SECHEADERS=nginx-stats-security-headers.conf" \
3266-  "$NGINX_STATS_CORS_429=nginx-stats-cors-429.conf" \
3267-  "$NGINX_STATS_PROXY_PUBLIC=nginx-stats-proxy-public.conf" \
3268-  "$NGINX_STATS_PROXY_PARTNER=nginx-stats-proxy-partner.conf" \
--
3291-  _append_deploy_input_digest "$TMP_CATALOG_PUBKEY" "tier2-catalog.pub"
3292-else
3293-  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
3294-fi
3295-
3296-$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
3297-$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
3298-$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
3299:$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
3300-$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
3301-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
3302-  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
3303-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
3304-  $SCP "$RATE_CARD_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.rate-card-migration.yaml"
3305-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
3306-  $SCP "$C2_TIMER_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.c2-timer-migration.yaml"
3307-else
--
3310-if [ "${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
3311-  $SCP "$RATE_CARD_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml"
3312-elif [ "${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}" = "1" ]; then
3313-  $SCP "$C2_TIMER_MIGRATED_OVERLAY_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml"
3314-fi
3315-$SCP "$SERVICE"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-coordinator.service"
3316-$SCP "$STATS_INVENTORY_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.service"
3317-$SCP "$STATS_INVENTORY_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.timer"
3318:$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"
3319:$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"
3320-$SCP "$STATS_HARDWARE_VERIFIER_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier.service"
3321-$SCP "$STATS_HARDWARE_VERIFIER_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier.timer"
3322-$SCP "$NGINX_SITE"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-coordinator-full.conf"
3323-# SPEC-017 v0.1.8 Step 4.B artifacts (snippet must land at
3324-# /etc/nginx/conf.d/ so the http-context declarations are visible
3325-# to BOTH the coordinator vhost (for /v1/stats/* allow-through)
3326-# and the stats vhost. Installation step below is wired BEFORE
3327-# the coordinator vhost full-TLS install so `nginx -t` does not
--
3574-    echo "refusing stats-inventory sidecar install: invalid pre-quiesce parity state" >&2
3575-    exit 1
3576-  elif [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
3577-       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
3578-    echo "refusing stats-inventory sidecar replacement from direct deploy: install the signed matching stats sidecar release first" >&2
3579-    exit 1
3580-  fi
3581-  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
3582:  # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
3583-  # dedicated macprovider-stats identity and gets read access only to the
3584-  # SQLite ledger files via file ACLs below.
3585:  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
3586:     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
3587:    echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
3588-    exit 1
3589-  fi
3590:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
3591-  # stats-hardware-verifier is an out-of-band stats sidecar. It promotes
3592-  # queued autotune evidence after conservative verification.
3593-  if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
3594-     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
3595-    echo "refusing stats-hardware-verifier replacement from direct deploy: install the signed matching stats sidecar release first" >&2
3596-    exit 1
3597-  fi
3598-  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
--
3617-  fi
3618-  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
3619-    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
3620-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
3621-  fi
3622-  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
---CHANGED COMMIT METADATA---
commit c6c3269276f3494cd7ee52ba2b5eae35daa24d6e
Author:     Augustas11 <augstar@gmail.com>
AuthorDate: Fri Sep 25 16:29:47 2026 +0800
Commit:     Augustas11 <augstar@gmail.com>
CommitDate: Fri Sep 25 16:29:47 2026 +0800

    Point the stats billing mirror at the coordinator DB that holds the ledger
    
    The unit and deploy-pearl-vps.sh read /var/lib/macprovider/request-log.sqlite,
    but the coordinator's billing ledger (ledger_request_credits) lives in its
    configured db_path, /var/lib/macprovider/coordinator.db. On Pearl the
    request-log path is an empty file, so the deploy's initial mirror run failed
    with 'no such table: ledger_request_credits' and rolled back the v1.8.196
    catalog deploy. The unit, the deploy's ACL snapshot/grant and start guard,
    the mirror default and the wiring tests now use coordinator.db, which is
    what Pearl's hand-maintained unit already reads.
    
    Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>

exec
/bin/bash -lc "man systemd.exec 2>/dev/null | col -b | rg -n -C 8 'InaccessiblePaths=|ReadOnlyPaths=|If the same path' | head -120 || true; rg -n -C 4 'InaccessiblePaths=-/var/lib/macprovider/coordinator.db|ReadOnlyPaths=/var/lib/macprovider/coordinator.db' . --glob '"'!audits/**'"' --glob '"'!journeys/**'"' --glob '"'!docs/**'"'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 172ms:
./phase4-coordinator/dist/stats-billing-mirror.service-19-PrivateDevices=true
./phase4-coordinator/dist/stats-billing-mirror.service-20-PrivateTmp=true
./phase4-coordinator/dist/stats-billing-mirror.service-21-ProtectHome=true
./phase4-coordinator/dist/stats-billing-mirror.service-22-ProtectSystem=strict
./phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/stats-billing-mirror.service-24-ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
./phase4-coordinator/dist/stats-billing-mirror.service-25-ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
./phase4-coordinator/dist/stats-billing-mirror.service-26-InaccessiblePaths=/etc/macprovider
./phase4-coordinator/dist/stats-billing-mirror.service-27-InaccessiblePaths=-/opt/macprovider/coordinator.yaml
./phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
--
./phase4-coordinator/dist/stats-hardware-verifier.service-21-ProtectHome=true
./phase4-coordinator/dist/stats-hardware-verifier.service-22-ReadWritePaths=/tmp
./phase4-coordinator/dist/stats-hardware-verifier.service-23-InaccessiblePaths=/etc/macprovider
./phase4-coordinator/dist/stats-hardware-verifier.service-24-InaccessiblePaths=-/opt/macprovider/coordinator.yaml
./phase4-coordinator/dist/stats-hardware-verifier.service:25:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
./phase4-coordinator/dist/stats-hardware-verifier.service-26-
./phase4-coordinator/dist/stats-hardware-verifier.service-27-[Install]
./phase4-coordinator/dist/stats-hardware-verifier.service-28-WantedBy=multi-user.target
--
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-69-grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-70-  fail "billing mirror service must read isolated env file"
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-71-grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-72-  fail "billing mirror service must execute from deploy path"
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-74-  fail "billing mirror service must read only the SQLite source"
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-75-grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-76-  fail "billing mirror service must not access coordinator secrets"
./phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-77-grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||

exec
/bin/bash -lc "git blame -L 20,30 HEAD -- phase4-coordinator/dist/stats-billing-mirror.service; printf '%s\\n' '---ORIGIN SERVICE---'; git show HEAD"'^:phase4-coordinator/dist/stats-billing-mirror.service | nl -ba | sed -n '"'18,32p'; printf '%s\\n' '---OTHER SERVICE PATTERN---'; nl -ba phase4-coordinator/dist/stats-hardware-verifier.service | sed -n '1,35p'; nl -ba phase4-coordinator/dist/stats-inventory-sync.service | sed -n '1,35p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
^51746ca05 (Augustas11 2026-09-20 16:26:41 +0800 20) PrivateTmp=true
^51746ca05 (Augustas11 2026-09-20 16:26:41 +0800 21) ProtectHome=true
^51746ca05 (Augustas11 2026-09-20 16:26:41 +0800 22) ProtectSystem=strict
c6c3269276 (Augustas11 2026-09-25 16:29:47 +0800 23) ReadOnlyPaths=/var/lib/macprovider/coordinator.db
c6c3269276 (Augustas11 2026-09-25 16:29:47 +0800 24) ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
c6c3269276 (Augustas11 2026-09-25 16:29:47 +0800 25) ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
^51746ca05 (Augustas11 2026-09-20 16:26:41 +0800 26) InaccessiblePaths=/etc/macprovider
^51746ca05 (Augustas11 2026-09-20 16:26:41 +0800 27) InaccessiblePaths=-/opt/macprovider/coordinator.yaml
^51746ca05 (Augustas11 2026-09-20 16:26:41 +0800 28) InaccessiblePaths=-/var/lib/macprovider/coordinator.db
---ORIGIN SERVICE---
    18	NoNewPrivileges=true
    19	PrivateDevices=true
    20	PrivateTmp=true
    21	ProtectHome=true
    22	ProtectSystem=strict
    23	ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite
    24	ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-wal
    25	ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-shm
    26	InaccessiblePaths=/etc/macprovider
    27	InaccessiblePaths=-/opt/macprovider/coordinator.yaml
    28	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
---OTHER SERVICE PATTERN---
     1	[Unit]
     2	Description=MacProvider stats hardware evidence verifier
     3	Documentation=https://github.com/augstar/macprovider-poc
     4	After=network-online.target postgresql.service
     5	Wants=network-online.target
     6	ConditionPathExists=/etc/macprovider-stats/stats-hardware-verifier.env
     7	
     8	[Service]
     9	Type=oneshot
    10	User=macprovider-stats
    11	Group=macprovider-stats
    12	EnvironmentFile=/etc/macprovider-stats/stats-hardware-verifier.env
    13	ExecStart=/opt/macprovider-stats/stats-hardware-verifier
    14	Nice=10
    15	IOSchedulingClass=best-effort
    16	IOSchedulingPriority=7
    17	NoNewPrivileges=true
    18	PrivateDevices=true
    19	PrivateTmp=true
    20	ProtectSystem=strict
    21	ProtectHome=true
    22	ReadWritePaths=/tmp
    23	InaccessiblePaths=/etc/macprovider
    24	InaccessiblePaths=-/opt/macprovider/coordinator.yaml
    25	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
    26	
    27	[Install]
    28	WantedBy=multi-user.target
     1	[Unit]
     2	Description=MacProvider stats hardware inventory sync
     3	Documentation=https://github.com/augstar/macprovider-poc
     4	Wants=network-online.target
     5	After=network-online.target
     6	ConditionPathExists=/etc/macprovider-stats/stats-hardware-inventory.yaml
     7	
     8	[Service]
     9	Type=oneshot
    10	User=macprovider-stats
    11	Group=macprovider-stats
    12	EnvironmentFile=-/etc/macprovider-stats/stats-inventory-sync.env
    13	ExecStart=/opt/macprovider-stats/stats-inventory-sync --config /etc/macprovider-stats/stats-hardware-inventory.yaml
    14	Nice=10
    15	IOSchedulingClass=best-effort
    16	IOSchedulingPriority=7
    17	NoNewPrivileges=true
    18	PrivateDevices=true
    19	PrivateTmp=true
    20	ProtectHome=true
    21	ProtectSystem=strict
    22	ReadOnlyPaths=/etc/macprovider-stats

codex
The review found one concrete blocker in the unit: it now grants read-only access to `coordinator.db` but still declares that same path under `InaccessiblePaths`. That masks the source inside the service namespace, so the mirror cannot open it; the current wiring test misses this because it checks `ReadOnlyPaths` without rejecting the contradictory mask. I’m doing the final targeted test pass and checking for any additional C/H/M issue before reporting.
exec
/bin/bash -lc 'go test ./internal/sqliteutil' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'go test ./internal/stats/...' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 267ms:
ok  	github.com/augstar/macprovider-coordinator/internal/sqliteutil	(cached)

 succeeded in 4281ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats	2.409s
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	(cached)
ok  	github.com/augstar/macprovider-coordinator/internal/stats/hardware	(cached)
ok  	github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify	(cached)
ok  	github.com/augstar/macprovider-coordinator/internal/stats/metrics	(cached)
ok  	github.com/augstar/macprovider-coordinator/internal/stats/migrations	(cached)
ok  	github.com/augstar/macprovider-coordinator/internal/stats/poolsnapshot	(cached)
?   	github.com/augstar/macprovider-coordinator/internal/stats/prewarm	[no test files]
ok  	github.com/augstar/macprovider-coordinator/internal/stats/rollup	(cached)
?   	github.com/augstar/macprovider-coordinator/internal/stats/store	[no test files]

collab: Wait
collab: Wait
collab: Wait
codex
Targeted verification is green for the mirror, SQLite utility, all stats packages, deploy wiring, static-feed access, and recovery tests. No additional concrete C/H/M issue is apparent in the path/ACL trace; I’m collecting the independent review result, then I’ll close with the single blocker and exact evidence.
collab: Wait
collab: CloseAgent
codex
CODE audit result: 1 HIGH finding.

HIGH — [stats-billing-mirror.service:28](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/stats-billing-mirror.service:28)

`coordinator.db` is correctly used by `ExecStart` and `ReadOnlyPaths`, but the unit still declares `InaccessiblePaths=-/var/lib/macprovider/coordinator.db`. The service namespace can therefore hide the database, causing the initial mirror run to fail and the deploy to roll back.

Fix: remove that `InaccessiblePaths` entry and add a wiring test asserting it is absent.

No other C/H/M findings. ACL snapshots/grants and rollback restoration cover `coordinator.db`, WAL, and SHM. `ReadOnlyDSN` uses `mode=ro`, `query_only`, and a bounded busy timeout.

Existing relevant tests passed, including mirror, SQLite utility, stats packages, deploy wiring, static-feed access, and recovery tests. `origin/main...HEAD` was empty because both refs point to `c6c326927`.

VERDICT: FAIL (0/1/0)
tokens used
142 562

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
