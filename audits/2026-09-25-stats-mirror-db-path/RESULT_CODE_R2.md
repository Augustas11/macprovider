# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T08:47:18.267Z

## Original task

# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff 1148185e..ee061fc3` (c6c32692 plus the R1 fix ee061fc3), now on main.

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

## Round 2
R1, all three lanes: one HIGH. `InaccessiblePaths=-/var/lib/macprovider/coordinator.db` hid the new source DB. `ee061fc3` removes that entry and adds a wiring assertion that the `--sqlite` source is never inaccessible. On Pearl, systemd-run with the fixed property set mirrors 6000 rows, and the old set fails with `unable to open database file`. Verify the fix and re-check the lane.
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
`fix/stats-mirror-coordinator-db`. Review `git diff 1148185e..ee061fc3` (c6c32692 plus the R1 fix ee061fc3), now on main.

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

## Round 2
R1, all three lanes: one HIGH. `InaccessiblePaths=-/var/lib/macprovider/coordinator.db` hid the new source DB. `ee061fc3` removes that entry and adds a wiring assertion that the `--sqlite` source is never inaccessible. On Pearl, systemd-run with the fixed property set mirrors 6000 rows, and the old set fails with `unable to open database file`. Verify the fix and re-check the lane.
## Lane: CODE

Check:
- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
- The tests.

## Raw output

```text
CODE lane review completed for `1148185e..ee061fc3`.

No CRITICAL, HIGH, or MEDIUM findings.

Verified:

- All production paths use `coordinator.db`, including ACL snapshots/grants and start guards.
- Rollback ACL restoration remains covered via `coordinator-deploy-recover.sh:229-232`.
- WAL/SHM read-only paths are present in `stats-billing-mirror.service:23-25`.
- The source DB is no longer inaccessible (`stats-billing-mirror.service:26-27`).
- Mirror access uses `ReadOnlyDSN` with `mode=ro`, `query_only`, and busy timeout (`mirror.go:253-260`).
- Existing wiring, rollback, Go tests, and `git diff --check` passed.

Counts: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

VERDICT: PASS


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-mirror-dbpath
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d7bb-c49a-7513-a397-6966c15073aa
--------
user
# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff 1148185e..ee061fc3` (c6c32692 plus the R1 fix ee061fc3), now on main.

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

## Round 2
R1, all three lanes: one HIGH. `InaccessiblePaths=-/var/lib/macprovider/coordinator.db` hid the new source DB. `ee061fc3` removes that entry and adds a wiring assertion that the `--sqlite` source is never inaccessible. On Pearl, systemd-run with the fixed property set mirrors 6000 rows, and the old set fails with `unable to open database file`. Verify the fix and re-check the lane.
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
I’ll audit the specified diff as the CODE lane, tracing every former `request-log.sqlite` path through deploy rollback/ACL logic, service sandboxing, read-only SQLite wiring, and existing tests. I’ll run only repository tests that exercise this change, then report evidence-backed findings with exact file:line references and the required verdict.
exec
/bin/bash -lc "sed -n '1,240p' /Users/augstar/.codex/skills/code-review/SKILL.md && printf '\\n--- status ---\\n' && git status --short --branch && printf '\\n--- diff stat ---\\n' && git diff --stat 1148185e..ee061fc3" in /Users/augstar/macprovider-mirror-dbpath
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


--- status ---
## fix/stats-mirror-coordinator-db...origin/fix/stats-mirror-coordinator-db [ahead 1]
?? audits/2026-09-25-stats-mirror-db-path/

--- diff stat ---
 phase4-coordinator/cmd/stats-billing-mirror/main.go  |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh          | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service | 11 +++++------
 .../test/check_deploy_static_feed_access.test.sh     |  2 +-
 .../test/check_stats_billing_mirror_deploy_test.sh   | 20 ++++++++++++++------
 .../internal/stats/billingmirror/mirror.go           |  2 +-
 6 files changed, 30 insertions(+), 23 deletions(-)

codex
The repository is clean apart from a pre-existing untracked audit directory, and the reviewed range changes six tracked files. I’m keeping this to the requested CODE lane; I’ll use an independent code-review pass as a cross-check while I inspect the diff and call sites locally. No files will be modified.
2026-09-25T08:43:48.025045Z ERROR codex_core::tools::router: error=Full-history forked agents inherit the parent agent type; omit agent_type, or spawn without a full-history fork.
collab: SpawnAgent
collab: SpawnAgent
exec
/bin/bash -lc "rg -n --hidden --glob '"'!audits/**'"' --glob '"'!*'"\\.git/**' 'request-log\\.sqlite|coordinator\\.db|ReadOnlyDSN|DefaultSQLitePath|stats-billing-mirror' phase4-coordinator phase5-gateway scripts test specs | head -n 500" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
test/network-harness/scenarios/02_capacity_contention.yaml:39:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
phase4-coordinator/scripts/build-linux.sh:9:#   dist/stats-billing-mirror-linux-amd64
phase4-coordinator/scripts/build-linux.sh:155:BILLING_MIRROR_OUT="$SOURCE_DIR/dist/stats-billing-mirror-linux-amd64"
phase4-coordinator/scripts/build-linux.sh:156:(cd "$BUILD_WORK_DIR" && GOENV=off GOFLAGS='' GOWORK=off GOOS=linux GOARCH=amd64 go build -o "$BILLING_MIRROR_OUT" ./cmd/stats-billing-mirror)
test/network-harness/scenarios/smoke.yaml:35:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/06_cold_start_race.yaml:39:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/08_cold_warm_compare.yaml:34:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/13_dense_token_count_regression.yaml:33:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/10_provider_session_economics.yaml:31:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/smoke_qwen25_coder_32b.yaml:28:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/smoke_gpt_oss_20b.yaml:28:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/smoke_llama_31_8b.yaml:29:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/01_happy_path_concurrent.yaml:37:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/09_streaming_ttft_distribution.yaml:45:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/12_moe_mid_stream_projection.yaml:43:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/14_sparse_provider_reported_tokens.yaml:39:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/07_sustained_throughput.yaml:54:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/04_wrong_model.yaml:34:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/smoke_qwen3_coder_30b_a3b.yaml:28:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/05_mid_stream_drop.yaml:47:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/15_thermal_soak.yaml:78:  # coordinator_db_path: /path/to/lab/coordinator.db
test/network-harness/scenarios/03_sticky_multi_turn.yaml:36:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/network-harness/scenarios/16_sticky_cache_reuse.yaml:100:  coordinator_db_ssh: pearl:/var/lib/macprovider/coordinator.db
test/e2e/aead-rekey-oneshot/test_aead_rekey_oneshot.py:683:            f"""listen:\n  bind_address: 127.0.0.1\n  buyer_port: 18443\n  provider_port: 18444\ncoordinator:\n  require_gateway_context: true\nrouting:\n  max_retries: 0\nstorage:\n  db_path: {root / 'coordinator.db'}\ntier2:\n  require_encrypted_leg: true\n  encrypted_leg_rekey_after_requests: 10000\n  encrypted_leg_rekey_after_seconds: 3600\n""",
test/e2e/aead-rekey-oneshot/test_aead_rekey_oneshot.py:749:            db = Path(temp_text) / "coordinator.db"
phase4-coordinator/internal/ws/identity_migration_test.go:25:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/identity_migration_test.go:123:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:221:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
scripts/revenue_benchmark/README.md:39:  --coordinator-db coordinator.db --gateway-db gateway.db \
scripts/revenue_benchmark/README.md:40:  [--route-journal-db coordinator.db.route-snapshots] [--now 2026-09-24T12:00:00Z]
phase4-coordinator/internal/ws/server_test.go:1781:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1840:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1895:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1932:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2316:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2588:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
specs/SPEC-002-coordinator.md:2170:SQLite file: `coordinator.db` (configurable via `--db-path`). Daily
specs/SPEC-002-coordinator.md:4950:  db_path: "coordinator.db"
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
scripts/h1-undercredit-probe.sh:9:# Production ledger: /var/lib/macprovider/coordinator.db on coordinator.malibu.tech
scripts/h1-undercredit-probe.sh:15:#   sqlite3 /var/lib/macprovider/coordinator.db ".backup /tmp/coord-snap.db"
phase4-coordinator/internal/ws/model_admission_decision_store_test.go:25:			db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
test/network-harness/internal/benchmark/pricing_coord_config_test.go:145:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:141:	authStore, err := auth.OpenStore(filepath.Join(dir, "coordinator.db"))
phase4-coordinator/internal/ws/admin_onboarding_test.go:56:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
scripts/tests/test_revenue_benchmark_calculator.py:404:            coord_path, gateway_path = Path(tmp, "coordinator.db"), Path(tmp, "gateway.db")
phase4-coordinator/internal/ws/model_admission_probe_test.go:531:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
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
phase4-coordinator/internal/ws/auth_github_test.go:678:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
scripts/verify-pearl-runtime-release.sh:107:  stats-billing-mirror-linux-amd64
scripts/verify-pearl-runtime-release.sh:214:    "stats_billing_mirror": "stats-billing-mirror-linux-amd64",
scripts/verify-pearl-runtime-release.sh:230:            "cut a Pearl runtime release that signs stats-inventory-sync, stats-billing-mirror, "
scripts/enforce-tier2-hash.sh:475:    for unit in macprovider-coordinator.service macprovider-gateway.service canary-buyer.service macprovider-archive-rotate.service stats-billing-mirror.service; do
scripts/test-pearl-runtime-release.sh:111:for sidecar in ("stats-inventory-sync", "stats-billing-mirror", "stats-hardware-verifier"):
scripts/test-pearl-runtime-release.sh:113:    if "for sidecar in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do" not in build:
scripts/test-pearl-runtime-release.sh:159:    printf '%s\n' stats-billing-mirror > "$directory/stats-billing-mirror-linux-amd64"
scripts/test-pearl-runtime-release.sh:539:deploy_assets=(coordinator-linux-amd64 coordinator-cli-linux-amd64 stats-inventory-sync-linux-amd64 stats-billing-mirror-linux-amd64 stats-hardware-verifier-linux-amd64)
scripts/test-pearl-runtime-release.sh:579:printf '%s\n' stray > "$work/release-sidecars-stray/stats-billing-mirror-linux-amd64"
scripts/test-pearl-runtime-release.sh:586:grep -q 'release carries stats sidecar asset(s) pearl-release.json does not bind: stats-billing-mirror-linux-amd64' \
scripts/verify-pearl-go-binaries.py:21:    "stats-billing-mirror-linux-amd64": "github.com/augstar/macprovider-coordinator/cmd/stats-billing-mirror",
scripts/verify-pearl-go-binaries.py:36:        "stats-billing-mirror-linux-amd64",
scripts/verify-pearl-go-binaries.py:174:        valid.replace("/cmd/coordinator\n", "/cmd/stats-billing-mirror\n", 1),
scripts/verify-pearl-go-binaries.py:200:            " optionally followed by stats-inventory-sync, stats-billing-mirror, and stats-hardware-verifier",
phase4-coordinator/internal/ws/model_admission_disablement_test.go:23:			authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_disablement_test.go:120:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_intake_test.go:279:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
test/integration/harness_test.go:349:		coordinatorDB: filepath.Join(tempDir, "coordinator.db"),
phase5-gateway/internal/storage/sqlite/dsn.go:33:// sqliteReadOnlyDSN returns a read-only DSN for the same file in WAL mode.
phase5-gateway/internal/storage/sqlite/dsn.go:44:func sqliteReadOnlyDSN(path string) string {
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
phase4-coordinator/internal/audit/store_test.go:16:	if got, want := DefaultDBPath(filepath.Join("var", "lib", "macprovider", "coordinator.db")), filepath.Join("var", "lib", "macprovider", "coordinator-audit.db"); got != want {
phase4-coordinator/internal/audit/store_test.go:19:	if got := DefaultDBPath("coordinator.db"); got != "coordinator-audit.db" {
phase4-coordinator/internal/audit/store_test.go:86:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/audit/store_test.go:244:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/audit/store_test.go:533:	store, err := OpenStore(t.TempDir() + "/coordinator.db")
phase4-coordinator/internal/ws/referral_core_test.go:31:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/canary_store_test.go:14:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/referralapi/advocacy_test.go:72:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
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
phase4-coordinator/internal/referralapi/serving.go:50:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(s.Path))
test/integration/spec_014_v0_2_pairing/harness_test.go:104:	dbPath := filepath.Join(dir, "coordinator.db")
test/integration/spec_014_v0_2_pairing/harness_test.go:147:	writeCoordinatorConfigWithoutGitHubValues(t, cfgPath, filepath.Join(dir, "coordinator.db"), allocatePort(t), allocatePort(t))
phase4-coordinator/internal/sqliteutil/dsn.go:56:// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
phase4-coordinator/internal/sqliteutil/dsn.go:63:func ReadOnlyDSN(path string) string {
phase5-gateway/internal/storage/sqlite/store.go:72:	db, err := sql.Open("sqlite", sqliteReadOnlyDSN(path))
phase4-coordinator/internal/mdm/device_binding_test.go:41:	store, err := OpenMDAStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:57:	store, err := OpenMDAStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:374:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:517:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:584:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:942:	store, err := OpenMDAStore(filepath.Join(dir, "coordinator.db"))
phase4-coordinator/internal/config/config.go:1600:			DBPath:                   "coordinator.db",
phase4-coordinator/internal/buyer/server_test.go:101:	store, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/buyer/server_test.go:7291:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/explorer/handlers_test.go:984:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/rewards/wallet_mirror.go:24:	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
phase4-coordinator/internal/trustpool/spec043_creator_mvp_journey_test.go:810:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/rewards/unlock.go:183:	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
phase4-coordinator/internal/auth/tokens_test.go:38:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
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
phase4-coordinator/internal/buyer/billing_recorder_test.go:43:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:113:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:170:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:249:			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:17:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:52:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/billing/route_snapshot_test.go:240:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:284:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:328:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:401:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:484:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:532:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:581:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:634:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/portal_sessions_test.go:19:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:32:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:68:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:88:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:109:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_social_test.go:39:	return openSocialStoreAt(t, filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/referrals_social_test.go:66:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_social_test.go:194:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_social_test.go:249:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_social_test.go:290:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/referrals_admin_test.go:28:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:5:--   /etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/internal/buyer/settlement_unsettled_leg_test.go:25:	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/payout-runbook.md:273:   sqlite3 /var/lib/macprovider/coordinator.db \
phase4-coordinator/dist/payout-runbook.md:420:sqlite3 /var/lib/macprovider/coordinator.db \
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
phase4-coordinator/internal/auth/admission_recovery_atomic_test.go:16:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/coordinator-sqlite-relief.sh:9:  echo "usage: coordinator-sqlite-relief.sh [coordinator.db]" >&2
phase4-coordinator/internal/auth/onboarding_funnel_test.go:14:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/onboarding_funnel_test.go:135:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/coordinator.yaml:243:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator-deploy-recover.sh:165:  stats-billing-mirror.timer stats-billing-mirror.service \
phase4-coordinator/dist/coordinator-deploy-recover.sh:203:restore_regular had-stats-billing-binary stats-billing-mirror "$STATS_ROOT/stats-billing-mirror"
phase4-coordinator/dist/coordinator-deploy-recover.sh:210:restore_link_or_file had-stats-billing-service stats-billing-mirror.service "$SYSTEMD_ROOT/stats-billing-mirror.service"
phase4-coordinator/dist/coordinator-deploy-recover.sh:211:restore_link_or_file had-stats-billing-timer stats-billing-mirror.timer "$SYSTEMD_ROOT/stats-billing-mirror.timer"
phase4-coordinator/dist/coordinator-deploy-recover.sh:215:restore_link_or_file had-stats-billing-wants stats-billing-mirror.wants "$TIMERS_WANTS/stats-billing-mirror.timer"
phase4-coordinator/dist/coordinator-deploy-recover.sh:284:  restore_active_state stats-billing-mirror.timer stats-billing-timer-was-active
phase4-coordinator/dist/coordinator-deploy-recover.sh:285:  restore_active_state stats-billing-mirror.service stats-billing-service-was-active
phase4-coordinator/internal/auth/spec014_pairing_test.go:111:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/spec014_pairing_test.go:141:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/coordinator-archive-rotate.sh:2:# coordinator-archive-rotate.sh — coordinator.db archive-rotate scaffold (#1226).
phase4-coordinator/dist/coordinator-archive-rotate.sh:15:#   COORDINATOR_DB_PATH                  default: /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/coordinator-archive-rotate.sh:34:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-rotate.sh:274:  log "DRY_RUN=1 coordinator.db size=${size}B"
phase4-coordinator/dist/stats-billing-mirror.env.example:1:# Environment for stats-billing-mirror.service.
phase4-coordinator/dist/stats-billing-mirror.env.example:9:# Apply stats-billing-mirror-bootstrap.sql as a database owner/admin before
phase4-coordinator/dist/stats-billing-mirror.env.example:15:#   /etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/internal/buyer/seam_h4_test.go:47:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/dist/stats-hardware-verifier.service:25:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:114:    "$STATS_ROOT/stats-inventory-sync" "$STATS_ROOT/stats-billing-mirror" "$STATS_ROOT/stats-hardware-verifier" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:116:    "$SYSTEMD/stats-billing-mirror.service" "$SYSTEMD/stats-billing-mirror.timer" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:119:    "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:143:  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:154:    stats-billing-mirror.service stats-billing-mirror.timer \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:196:  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:200:    stats-billing-mirror.service stats-billing-mirror.timer \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:205:  ln -s ../stats-billing-mirror.timer "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:232:[ "$(cat "$STATS_ROOT/stats-billing-mirror")" = old-stats-billing-mirror ] || fail "stats billing binary was not restored"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:239:[ ! -e "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" ] || fail "new stats timer enablement was not removed"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:254:grep -qx 'start stats-billing-mirror.service' "$SYSTEMCTL_LOG" || fail "active stats service state was not restored"
phase4-coordinator/dist/test/check_stats_inventory_deploy_test.sh:753:  in_block && /^  if \[ -f \/etc\/macprovider-stats\/stats-billing-mirror\.env / { exit }
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/dist/monitor/macprovider-monitor.service:20:# macprovider-owned so the daemon can write coordinator.db; the
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:20:DB="$TMP/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:148:grep -q "DRY_RUN=1 coordinator.db size=" "$TMP/dry.err" || fail "dry-run size report missing"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:424:printf 'live-parent-marker\n' >"$LIVE_DIR/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:426:COORDINATOR_DB_PATH="$LIVE_DIR/coordinator.db" \
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:433:[ "$(cat "$LIVE_DIR/coordinator.db")" = "live-parent-marker" ] || fail "directory restore mutated live coordinator.db"
phase4-coordinator/dist/stats-billing-mirror.service:6:ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/stats-billing-mirror.service:7:ConditionPathExists=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:13:EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/stats-billing-mirror.service:14:ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh:66:grep -qF 'refusing stats-billing-mirror replacement from direct deploy' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh:67:  fail "deploy must not replace stats-billing-mirror from ignored local artifacts"
phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh:94:  'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' \
phase4-coordinator/dist/coordinator-archive-restore.sh:10:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-restore.sh:182:PRIMARY_TMP="$TMP_DIR/coordinator.db"
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh:16:DB="$TMP/coordinator.db"
phase4-coordinator/dist/deploy-pearl-vps.sh:629:STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh:640:STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh:641:STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh:1994:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:1995:    chown root:root /etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/deploy-pearl-vps.sh:1996:    chmod 0600 /etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/deploy-pearl-vps.sh:1999:    echo "  /etc/macprovider-stats/stats-billing-mirror.env not yet present; stats billing mirror timer remains opt-in"
phase4-coordinator/dist/deploy-pearl-vps.sh:3094:  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
phase4-coordinator/dist/deploy-pearl-vps.sh:3114:  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
phase4-coordinator/dist/deploy-pearl-vps.sh:3115:  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3119:  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
phase4-coordinator/dist/deploy-pearl-vps.sh:3123:  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
phase4-coordinator/dist/deploy-pearl-vps.sh:3124:  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3197:  for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
phase4-coordinator/dist/deploy-pearl-vps.sh:3241:_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh:3259:  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3260:  "$STATS_BILLING_MIRROR_TIMER=stats-billing-mirror.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3299:$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh:3318:$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh:3319:$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh:3582:  # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
phase4-coordinator/dist/deploy-pearl-vps.sh:3585:  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
phase4-coordinator/dist/deploy-pearl-vps.sh:3586:     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3587:    echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:3590:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
phase4-coordinator/dist/deploy-pearl-vps.sh:3625:  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh:3626:  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4874:    systemctl enable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4875:    if ! systemctl start stats-billing-mirror.service; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4876:      systemctl disable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4877:      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:4878:      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
phase4-coordinator/dist/deploy-pearl-vps.sh:4881:    systemctl is-active stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4883:    systemctl start stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4884:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:10:SERVICE="$DIST_DIR/stats-billing-mirror.service"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:11:TIMER="$DIST_DIR/stats-billing-mirror.timer"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:12:ENV_EXAMPLE="$DIST_DIR/stats-billing-mirror.env.example"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:13:BOOTSTRAP_SQL="$DIST_DIR/stats-billing-mirror-bootstrap.sql"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:26:grep -qF 'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:28:grep -qF 'STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:30:grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:32:grep -qF '$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:38:grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:40:grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:42:grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:50:grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:52:grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:56:grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:58:grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:65:grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:69:grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:196:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:246:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:310:	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
specs/trust-roadmap/G0-measure-demand.md:49:`/var/lib/macprovider/coordinator.db` using `scripts/trust-g0-demand.sql`.
specs/trust-roadmap/G0-measure-demand.md:51:`/Users/augstar/macprovider-poc/phase4-coordinator/coordinator.db` produced
phase4-coordinator/dist/coordinator.yaml.example:151:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator.yaml.example:380:  # sqlite_payout_db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/stats/billingmirror/mirror.go:22:	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/stats/billingmirror/mirror.go:214:		opts.SQLitePath = DefaultSQLitePath
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
phase4-coordinator/internal/stats/billingmirror/mirror.go:647:	sum := sha256.Sum256([]byte("stats-billing-mirror\x00" + providerID))
phase4-coordinator/cmd/coordinator-cli/main_test.go:69:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:132:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:155:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/tools/spec032canary/main.go:297:	r.sqliteDB = filepath.Join(r.runRoot, "state", "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main.go:72:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:96:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:116:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:135:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:243:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:272:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:348:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:417:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:487:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
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
phase4-coordinator/cmd/coordinator-cli/referrals_test.go:15:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/referrals_test.go:99:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/onboarding_test.go:16:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/stats-billing-mirror/main.go:14:	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
phase4-coordinator/cmd/stats-billing-mirror/main.go:26:		fmt.Fprintf(os.Stderr, "stats-billing-mirror: %v\n", err)
phase4-coordinator/cmd/coordinator-cli/onboarding.go:17:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:18:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:29:	setReferralUsage(fs, "create-seed-referral", "coordinator-cli create-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 100 --apply --operation-id 11111111-1111-4111-8111-111111111111 --actor ops@malibu --reason 'open cohort'")
phase4-coordinator/cmd/coordinator-cli/referrals.go:81:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:92:	setReferralUsage(fs, "adjust-seed-referral", "coordinator-cli adjust-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 250 --apply --operation-id 22222222-2222-4222-8222-222222222222 --expect-state <dry-run-digest> --actor ops@malibu --reason 'expand cohort'")
phase4-coordinator/cmd/coordinator-cli/referrals.go:135:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:143:	setReferralUsage(fs, "revoke-referral", "coordinator-cli revoke-referral --db coordinator.db --campaign prebeta --issuer-id launch --apply --operation-id 33333333-3333-4333-8333-333333333333 --expect-state <dry-run-digest> --actor ops@malibu --reason 'abuse report'")
phase4-coordinator/cmd/coordinator-cli/referrals.go:180:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:193:	setReferralUsage(fs, "replace-seed-referral", "coordinator-cli replace-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --old-seed-id launch --new-seed-id launch2 --max-uses 100 --apply --operation-id 44444444-4444-4444-8444-444444444444 --expect-state <dry-run-digest> --actor ops@malibu --reason 'rotate invite'")
phase4-coordinator/internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql:1:-- Keep the deployed stats-billing-mirror binary and Postgres writer contract
phase4-coordinator/internal/requestlog/store.go:130:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(dbPath))
phase4-coordinator/internal/requestlog/store_test.go:379:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:540:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/cmd/coordinator/main_test.go:64:	reqLogStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
phase4-coordinator/cmd/coordinator/main_test.go:1477:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:27:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:123:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/coordinator.yaml.example:223:  db_path: "coordinator.db"

exec
/bin/bash -lc 'git diff --check 1148185e..ee061fc3 && git diff --find-renames --find-copies --unified=80 1148185e..ee061fc3 -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/internal/stats/billingmirror/mirror.go phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/test/check_deploy_static_feed_access.test.sh phase4-coordinator/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath
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
@@ -3061,163 +3061,163 @@ $SSH "set -e
       fi
       cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
       touch \"\$_rollback_stage/\$_marker\"
     fi
   }
   snapshot_active() {
     if systemctl is-active --quiet \"\$1\"; then
       touch \"\$_rollback_stage/\$2\"
     fi
   }
   snapshot_acl() {
     _source=\"\$1\"
     _snapshot=\"\$2\"
     _marker=\"\$3\"
     if [ -e \"\$_source\" ]; then
       getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
       touch \"\$_rollback_stage/\$_marker\"
     fi
   }
   snapshot_node /opt/macprovider/coordinator.prev coordinator.prev had-coordinator-prev
   if [ -x /opt/macprovider/coordinator ]; then
     cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
     touch \"\$_rollback_stage/had-coordinator\"
   fi
   snapshot_node /opt/macprovider/coordinator-cli coordinator-cli had-coordinator-cli
   snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
   printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
   snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
   snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
   snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
   printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
   snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
   snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
   snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
   snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
   if [ -f /opt/macprovider/coordinator.yaml ]; then
     cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
     touch \"\$_rollback_stage/had-config\"
   fi
   if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
     echo 'unsafe existing Tier-2 catalog path' >&2
     exit 1
   fi
   if [ -f /opt/macprovider/tier2-catalog.json ]; then
     cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
     touch \"\$_rollback_stage/had-tier2-catalog\"
   fi
   if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
     cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
     touch \"\$_rollback_stage/had-service-unit\"
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
   fi
   if [ ! -d /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME ]; then
     touch \"\$_rollback_stage/release-was-absent\"
   fi
   printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
   if systemctl is-active --quiet macprovider-coordinator; then
     touch \"\$_rollback_stage/service-was-active\"
   fi
   touch \"\$_rollback_stage/complete\"
   mv \"\$_rollback_stage\" \"\$_rollback\"
   trap - EXIT HUP INT TERM"
 COORDINATOR_DEPLOY_ARMED=1
 
 # Freeze sidecar execution for the release window. Their binaries and units are
 # transaction-owned, so allowing an old timer to fire after replacement could
 # create non-rollbackable database effects before the catalog canary passes.
 # NOTE: stats-inventory-sync is deliberately NOT in this loop — it is quiesced
 # earlier (before the onboarding migration preflight) because migration 019
 # makes the old inventory binary incompatible with the migrated schema, so it
 # must be down before the migration is exercised, not merely before install.
 $SSH 'set -eu
   exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
   flock -s 8
   for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
     load_state=$(systemctl show -p LoadState --value "$unit")
     [ "$load_state" = not-found ] && continue
     systemctl stop "$unit"
     active_state=$(systemctl show -p ActiveState --value "$unit")
     case "$active_state" in
       inactive|failed) ;;
       *) echo "sidecar unit did not stop: $unit state=$active_state" >&2; exit 1 ;;
     esac
   done
 '
 
 # Issue #244 R5 SEC CRITICAL — stage uploaded artifacts into a fresh
 # per-deploy root-owned 0700 directory instead of predictable /tmp/X
 # names. Otherwise any local user (including a compromised macprovider
 # UID) can race the SCP/install window and substitute their own
 # systemd unit, binary, or nginx config — which root then installs.
 # `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH
 # user (root). The wider /tmp permissions (1777) don't matter because
 # the fresh subdir denies traversal.
 DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX') || {
   echo "failed to create remote staging directory" >&2; exit 1;
 }
 case "$DEPLOY_TMP" in
   /tmp/macprovider-deploy.*) ;;
   *)
     echo "aborting deploy: mktemp produced unexpected path: '$DEPLOY_TMP'" >&2
@@ -3555,164 +3555,164 @@ $SSH "set -e
   fi
   install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli
   # stats-inventory-sync is an operator sidecar, not a coordinator child.
   # It runs under its own Unix identity and only receives execute access
   # to this binary; its Postgres writer DSN lives under /etc/macprovider-stats.
   # A pre-existing parity hold belongs to an earlier coordinator release. A
   # catalog-only deploy may carry the live binary through byte-for-byte, but it
   # must not silently promote a different sidecar before the signed matching
   # coordinator/sidecar release does so.
   if [ ! -r /opt/macprovider/.coordinator-deploy-sidecar-prior-state ]; then
     echo "refusing stats-inventory sidecar install: missing pre-quiesce parity state" >&2
     exit 1
   elif grep -qx "parity_required=present" /opt/macprovider/.coordinator-deploy-sidecar-prior-state; then
     if [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
        ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
       echo "refusing parity-held stats-inventory sidecar replacement: install the signed matching coordinator/sidecar release first" >&2
       exit 1
     fi
   elif ! grep -qx "parity_required=absent" /opt/macprovider/.coordinator-deploy-sidecar-prior-state; then
     echo "refusing stats-inventory sidecar install: invalid pre-quiesce parity state" >&2
     exit 1
   elif [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
        ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
     echo "refusing stats-inventory sidecar replacement from direct deploy: install the signed matching stats sidecar release first" >&2
     exit 1
   fi
   install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
   # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
   # dedicated macprovider-stats identity and gets read access only to the
   # SQLite ledger files via file ACLs below.
   if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
      ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
     echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
     exit 1
   fi
   install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
   # stats-hardware-verifier is an out-of-band stats sidecar. It promotes
   # queued autotune evidence after conservative verification.
   if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
      ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
     echo "refusing stats-hardware-verifier replacement from direct deploy: install the signed matching stats sidecar release first" >&2
     exit 1
   fi
   install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
   if [ '$CONFIG_MODE' = 'apply-tracked' ]; then
     install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml
   elif [ '${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}' = '1' ]; then
     install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.rate-card-migration.yaml /opt/macprovider/coordinator.yaml
   elif [ '$C2_TIMER_CONFIG_MIGRATION' = '1' ]; then
     install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.c2-timer-migration.yaml /opt/macprovider/coordinator.yaml
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
       exit 1
     fi
     rm -rf \$_autotune_stage
   else
     mv \$_autotune_stage \$_autotune_release
   fi
   python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
   # First rollout: the new on-disk coordinator config already points at
   # autotune/current. Establish that path as soon as the immutable release is
   # staged so an abort before the late restart gate cannot leave the next
   # service restart without feeds. Existing rollouts remain untouched here.
   if [ ! -e \$_autotune_root/current ] && [ ! -L \$_autotune_root/current ]; then
     ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \$_autotune_root/current.bootstrap
     mv -Tf \$_autotune_root/current.bootstrap \$_autotune_root/current
   fi
   rmdir \$_autotune_lock
   trap - EXIT
 "
 
 # nginx + Let's Encrypt strategy (issue #244 R1+R2+R3+R4 — TLS-safety hardening):
 #
 # Domain classification (step 4b) produces FOUR states:
 #   HAVE    fullchain.pem + privkey.pem present, openssl -checkend
 #           86400 valid → no stub, no certbot, full vhost reinstalled
 #           idempotently in step 6b.
 #   RENEW   files present, cert valid RIGHT NOW (openssl -checkend 0
 #           valid) but <24h to expiry → certbot needed, but the
 #           existing full TLS vhost is left in place. A certbot
 #           failure leaves the soon-expiring cert serving until next
 #           deploy (instead of being replaced with an HTTP-only stub).
 #   EXPIRED files present but cert is already invalid (openssl
 #           -checkend 0 fails) → treat like MISSING. Existing vhost
 #           would serve a broken cert; install stub + run certbot
 #           instead.
 #   MISSING fullchain.pem or privkey.pem absent → install stub + run
 #           certbot. (Always-stub: dropped the R2 vhost-flag gate
 #           after R3 audit showed a stale enabled vhost could lack
 #           /.well-known/acme-challenge/ and block first issuance.)
 #
 #   step 5   -> install the port-80 ACME-stub ONLY for DOMAINS_NEED_STUB
 #               (= EXPIRED ∪ MISSING). HAVE + RENEW production vhosts
 #               are untouched. This is the load-bearing change vs. the
 #               original bug: a downstream certbot failure cannot leave
 #               another domain's working TLS vhost broken because we
 #               never clobbered it in the first place.
 #   step 6   -> per-domain certbot certonly --webroot, FAIL-SOFT. A
 #               failure on ANY single domain (e.g. NXDOMAIN) is logged
 #               and recorded but does not abort the deploy. State-aware
 #               messaging tells the operator the per-domain fallback.
 #   step 6b  -> install the full TLS vhost ONLY for DOMAINS_FULL_TLS
@@ -4793,135 +4793,135 @@ if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
     exit 9
   else
     echo "  ok: $STATS_DOMAIN /v1/stats/leaderboard responded 200"
   fi
 else
   # Stats disabled in deployed config. If STATS_REQUIRED=1, the operator
   # explicitly asked for strict mode but disabled stats — that's
   # incoherent; refuse. Otherwise just log and skip.
   if [ "${STATS_REQUIRED:-0}" = "1" ]; then
     echo "  ABORT: STATS_REQUIRED=1 but stats.enabled is not true in $DEPLOY_CONFIG." >&2
     echo "         Enable stats in coordinator.yaml or drop STATS_REQUIRED=1." >&2
     exit 9
   fi
   echo "  stats.enabled is not true in $DEPLOY_CONFIG — skipping $STATS_DOMAIN smoke check"
 fi
 
 log "step 9/9: tail the coordinator journal for sanity"
 $SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'
 
 $SSH 'set -e
   exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
   flock -s 8
   # Sidecars remain frozen until every coordinator/catalog/canary check has
   # passed. Activate them as the final transaction mutation, immediately
   # before the commit marker.
   _sidecar_prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
   if [ ! -r "$_sidecar_prior" ]; then
     echo "aborting deploy: missing stats-inventory prior state at final activation" >&2
     exit 13
   fi
   assert_stats_inventory_quiescent() {
     _timer_enabled=$(systemctl is-enabled stats-inventory-sync.timer 2>/dev/null || true)
     _timer_active=$(systemctl is-active stats-inventory-sync.timer 2>/dev/null || true)
     _service_active=$(systemctl is-active stats-inventory-sync.service 2>/dev/null || true)
     if [ "$_timer_enabled" != disabled ] ||
        [ "$_timer_active" != inactive ]; then
       echo "aborting deploy: stats-inventory timer did not remain disabled/inactive after parity hold (enabled=$_timer_enabled active=$_timer_active)" >&2
       exit 13
     fi
     case "$_service_active" in
       inactive|failed) ;;
       *)
         echo "aborting deploy: stats-inventory service did not remain quiescent after parity hold (active=$_service_active)" >&2
         exit 13
         ;;
     esac
   }
   _parity_required=$(sed -n "s/^parity_required=//p" "$_sidecar_prior")
   case "$_parity_required" in
     present)
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
       if [ "$hardware_trust_approval_enabled" = 1 ]; then
         echo "aborting deploy: stats-hardware-verifier.service failed its initial run and hardware-trust approval is enabled; operator approvals would commit trust roots that never promote to verified" >&2
         exit 13
       fi
       echo "warning: stats-hardware-verifier.service failed; leaving coordinator deploy running"
     fi
     systemctl is-active stats-hardware-verifier.timer
   elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-timer-was-active ]; then
     systemctl start stats-hardware-verifier.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-service-was-active ] || systemctl start stats-hardware-verifier.service
   else
     echo "stats hardware verifier timer not enabled: missing /etc/macprovider-stats/stats-hardware-verifier.env"
   fi
   rm -f "$_sidecar_prior"
   touch /opt/macprovider/.coordinator-deploy-rollback/committed
   /opt/macprovider/coordinator-deploy-recover --recover-under-global
 '
 COORDINATOR_DEPLOY_ARMED=0
 log "DONE. coordinator is live at https://$DOMAIN"
 echo
 echo "Next steps:"
 echo "  - Stage 3: restart M4 phase3-binary with --coordinator wss://$DOMAIN/ws/provider"
 echo "  - Verify: providers should appear in /poolz (auth: bearer operator_key from coordinator.yaml)"
 echo "  - End-to-end: run harness against https://$DOMAIN"
diff --git a/phase4-coordinator/dist/stats-billing-mirror.service b/phase4-coordinator/dist/stats-billing-mirror.service
index 056cf4f47..9be817313 100644
--- a/phase4-coordinator/dist/stats-billing-mirror.service
+++ b/phase4-coordinator/dist/stats-billing-mirror.service
@@ -1,28 +1,27 @@
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
-InaccessiblePaths=-/var/lib/macprovider/coordinator.db
diff --git a/phase4-coordinator/internal/stats/billingmirror/mirror.go b/phase4-coordinator/internal/stats/billingmirror/mirror.go
index 5cc0c9506..1caffe167 100644
--- a/phase4-coordinator/internal/stats/billingmirror/mirror.go
+++ b/phase4-coordinator/internal/stats/billingmirror/mirror.go
@@ -1,102 +1,102 @@
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
 
 type RequestCredit struct {
 	SQLiteID                     int64
 	RequestID                    string
 	AttemptN                     int
 	ProviderID                   string
 	TSUTC                        time.Time
 	CreatedAtUTC                 time.Time
 	UpdatedAtUTC                 sql.NullTime
 	PromptTokens                 sql.NullInt64
 	CompletionTokens             sql.NullInt64
 	EstimatedCompletionTokens    sql.NullInt64
 	UsageSource                  string
 	ProviderCredits              int64
 	FaultFlag                    string
 	Quarantined                  bool
 	SettlementPolicyMode         string
 	Spec022Verified              bool
 	RequestedPrivacyMode         string
 	EffectivePrivacyOutcome      string
 	PositiveVerificationExcluded bool
 	RewardsExcluded              bool
 }
 
 type ProviderIdentity struct {
 	ProviderID   string
 	ProviderName string
 	CreatedAt    time.Time
 	LastUsedAt   sql.NullTime
 }
 
 type State struct {
 	LastRequestID int64
 	SweepAfterID  int64
 }
 
 func Run(parent context.Context, opts Options) (Result, error) {
 	opts = normalizeOptions(opts)
 	out := opts.Stdout
 	if out == nil {
 		out = io.Discard
 	}
 	if opts.SQLitePath == "" {
 		return Result{}, errors.New("sqlite path is required")
 	}
 	if opts.PostgresDSN == "" && !opts.DryRun {
 		return Result{}, errors.New("postgres dsn is required")
 	}
 
 	ctx, cancel := context.WithTimeout(parent, DefaultRunTimeout)

exec
/bin/bash -lc 'git log --oneline --decorate --no-merges -5 1148185e..ee061fc3 && git show --stat --oneline c6c32692 && git show --stat --oneline ee061fc3' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 51ms:
c6c326927 Point the stats billing mirror at the coordinator DB that holds the ledger
 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)
ee061fc3 Stop hiding the mirror's source DB from its own sandbox
 phase4-coordinator/dist/stats-billing-mirror.service              | 1 -
 .../dist/test/check_stats_billing_mirror_deploy_test.sh           | 8 ++++++++
 2 files changed, 8 insertions(+), 1 deletion(-)

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/stats-billing-mirror.service; printf '\\n--- deploy ACL/deploy guard ---\\n'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3130,3150p;3615,3650p;4855,4890p'; printf '\\n--- mirror open/default ---\\n'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '1,45p;190,280p'; printf '\\n--- tests ---\\n'; nl -ba phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh | sed -n '1,150p'; nl -ba phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh | sed -n '1,100p'" in /Users/augstar/macprovider-mirror-dbpath
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

--- deploy ACL/deploy guard ---
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
  3615	    echo 'refusing unsafe coordinator overlay path: /etc/macprovider/coordinator.pearl-overlays.yaml' >&2
  3616	    exit 1
  3617	  fi
  3618	  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
  3619	    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
  3620	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  3621	  fi
  3622	  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  3623	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
  3624	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
  3625	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
  3626	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
  3627	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
  3628	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
  3629	  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
  3630	    # Mutate only objects captured at the transaction boundary. WAL/SHM files
  3631	    # can appear while the old coordinator is still running; granting an ACL
  3632	    # to a newly appeared, unsnapshotted file would make exact rollback
  3633	    # impossible.
  3634	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
  3635	    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
  3636	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
  3637	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
  3638	  elif [ -f /var/lib/macprovider/coordinator.db ]; then
  3639	    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
  3640	  fi
  3641	  # Stage the complete immutable catalog release. Activation happens only
  3642	  # after the late connected-provider safeguard immediately before restart.
  3643	  _autotune_root=/opt/macprovider/autotune
  3644	  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
  3645	  _autotune_lock=\$_autotune_release.lock
  3646	  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
  3647	  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
  3648	  if ! mkdir \$_autotune_lock; then
  3649	    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
  3650	    exit 1
  4855	  if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
  4856	    systemctl enable --now stats-inventory-sync.timer
  4857	    if ! systemctl start stats-inventory-sync.service; then
  4858	      systemctl disable --now stats-inventory-sync.timer
  4859	      systemctl stop stats-inventory-sync.service
  4860	      assert_stats_inventory_quiescent
  4861	      echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
  4862	      journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
  4863	    else
  4864	      rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
  4865	      systemctl is-active stats-inventory-sync.timer
  4866	    fi
  4867	  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
  4868	    systemctl start stats-inventory-sync.timer
  4869	    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
  4870	  elif [ "$_parity_required" = absent ]; then
  4871	    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
  4872	  fi
  4873	  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
  4874	    systemctl enable --now stats-billing-mirror.timer
  4875	    if ! systemctl start stats-billing-mirror.service; then
  4876	      systemctl disable --now stats-billing-mirror.timer
  4877	      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
  4878	      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
  4879	      exit 13
  4880	    fi
  4881	    systemctl is-active stats-billing-mirror.timer
  4882	  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
  4883	    systemctl start stats-billing-mirror.timer
  4884	    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
  4885	  else
  4886	    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
  4887	  fi
  4888	  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
  4889	    systemctl enable --now stats-hardware-verifier.timer
  4890	    # FIX 7 (issue #582): when hardware-trust approval is enabled (both onboarding

--- mirror open/default ---
     1	package billingmirror
     2	
     3	import (
     4		"context"
     5		"crypto/sha256"
     6		"database/sql"
     7		"encoding/hex"
     8		"errors"
     9		"fmt"
    10		"io"
    11		"os"
    12		"sort"
    13		"strings"
    14		"time"
    15	
    16		"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
    17		_ "github.com/lib/pq"
    18		_ "modernc.org/sqlite"
    19	)
    20	
    21	const (
    22		DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
    23		DefaultBatchSize   = 5000
    24		DefaultOverlapRows = 1000
    25		DefaultRunTimeout  = 25 * time.Second
    26	
    27		StateSource = "sqlite-ledger-request-credits"
    28	)
    29	
    30	type Options struct {
    31		SQLitePath   string
    32		PostgresDSN  string
    33		BatchSize    int
    34		OverlapRows  int64
    35		SweepRows    int
    36		MaxBatches   int
    37		EnsureSchema bool
    38		DryRun       bool
    39		Stdout       io.Writer
    40	}
    41	
    42	type Result struct {
    43		RequestRowsRead     int
    44		RequestRowsUpserted int
    45		ProviderRowsRead    int
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

--- tests ---
     1	#!/usr/bin/env bash
     2	# check_stats_billing_mirror_deploy_test.sh — offline validation for the
     3	# stats billing mirror sidecar deploy wiring.
     4	
     5	set -euo pipefail
     6	
     7	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     8	DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
     9	DEPLOY_SH="$DIST_DIR/deploy-pearl-vps.sh"
    10	SERVICE="$DIST_DIR/stats-billing-mirror.service"
    11	TIMER="$DIST_DIR/stats-billing-mirror.timer"
    12	ENV_EXAMPLE="$DIST_DIR/stats-billing-mirror.env.example"
    13	BOOTSTRAP_SQL="$DIST_DIR/stats-billing-mirror-bootstrap.sql"
    14	MIGRATION_SQL="$DIST_DIR/../internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql"
    15	MIRROR_GO="$DIST_DIR/../internal/stats/billingmirror/mirror.go"
    16	
    17	fail() {
    18	  echo "FAIL: $*" >&2
    19	  exit 1
    20	}
    21	
    22	for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL" "$MIGRATION_SQL" "$MIRROR_GO"; do
    23	  [ -f "$f" ] || fail "missing required file: $f"
    24	done
    25	
    26	grep -qF 'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
    27	  fail "deploy script missing billing mirror binary variable"
    28	grep -qF 'STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"' "$DEPLOY_SH" ||
    29	  fail "deploy script missing billing mirror service variable"
    30	grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
    31	  fail "deploy script missing billing mirror timer variable"
    32	grep -qF '$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
    33	  fail "deploy script missing billing mirror binary upload"
    34	grep -qF 'for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY"' "$DEPLOY_SH" ||
    35	  fail "deploy preflight must require billing mirror binary"
    36	grep -qF '"$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER"' "$DEPLOY_SH" ||
    37	  fail "deploy preflight must require billing mirror unit files"
    38	grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
    39	  fail "deploy script missing billing mirror service upload"
    40	grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
    41	  fail "deploy script missing billing mirror timer upload"
    42	grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
    43	  fail "deploy script missing billing mirror binary install"
    44	grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
    45	  fail "deploy script must grant narrow SQLite file ACL"
    46	grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
    47	  fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
    48	grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
    49	  fail "deploy script must only enable mirror when stats user can read sqlite source"
    50	grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
    51	  fail "deploy script missing billing mirror service install"
    52	grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
    53	  fail "deploy script missing billing mirror timer install"
    54	grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
    55	  fail "deploy script must only enable timer when env and SQLite source exist"
    56	grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
    57	  fail "deploy script must disable the billing mirror timer after a failed initial run"
    58	grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
    59	  fail "deploy script must fail closed when the configured billing mirror cannot run"
    60	
    61	grep -qxF 'User=macprovider-stats' "$SERVICE" ||
    62	  fail "billing mirror must run as dedicated stats user"
    63	grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
    64	  fail "billing mirror must run with dedicated stats group"
    65	grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
    66	  fail "billing mirror service must be opt-in on env file"
    67	grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
    68	  fail "billing mirror service must require the SQLite source"
    69	grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
    70	  fail "billing mirror service must read isolated env file"
    71	grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
    72	  fail "billing mirror service must execute from deploy path"
    73	grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
    74	  fail "billing mirror service must read only the SQLite source"
    75	# The mirror's source DB must never also be inaccessible: systemd applies
    76	# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
    77	# deploy's initial mirror run.
    78	source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
    79	[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
    80	if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
    81	  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
    82	fi
    83	grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
    84	  fail "billing mirror service must not access coordinator secrets"
    85	grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||
    86	  fail "billing mirror timer must run frequently enough for public stats"
    87	grep -qF 'stats_billing_mirror_writer' "$ENV_EXAMPLE" ||
    88	  fail "env example must document dedicated writer role"
    89	grep -qF 'STATS_BILLING_MIRROR_DSN=' "$ENV_EXAMPLE" ||
    90	  fail "env example must define the expected DSN variable"
    91	grep -qF 'runs with --ensure-schema=false' "$ENV_EXAMPLE" ||
    92	  fail "env example must document bootstrap-before-service contract"
    93	grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credits' "$BOOTSTRAP_SQL" ||
    94	  fail "bootstrap SQL must create ledger_request_credits"
    95	grep -qF 'settlement_policy_mode TEXT' "$BOOTSTRAP_SQL" ||
    96	  fail "bootstrap SQL must carry settlement policy mode column"
    97	grep -qF 'spec022_verified BOOLEAN' "$BOOTSTRAP_SQL" ||
    98	  fail "bootstrap SQL must carry SPEC-022 verified column"
    99	grep -qF 'lrc_mirror_spec022_verified_enforce_check' "$BOOTSTRAP_SQL" ||
   100	  fail "bootstrap SQL must constrain SPEC-022 verified rows to enforce mode"
   101	grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credit_spec022_verified_audit' "$BOOTSTRAP_SQL" ||
   102	  fail "bootstrap SQL must create SPEC-022 verified audit table"
   103	if grep -qF "PASSWORD 'REPLACE_ME'" "$BOOTSTRAP_SQL"; then
   104	  fail "bootstrap SQL must not create a known default password"
   105	fi
   106	grep -qF 'RAISE EXCEPTION' "$BOOTSTRAP_SQL" ||
   107	  fail "bootstrap SQL must fail if writer role is missing"
   108	grep -qF 'CREATE TABLE IF NOT EXISTS provider_tokens' "$BOOTSTRAP_SQL" ||
   109	  fail "bootstrap SQL must create provider_tokens"
   110	grep -qF 'GRANT SELECT ON ledger_request_credits TO stats_rollup' "$BOOTSTRAP_SQL" ||
   111	  fail "bootstrap SQL must grant rollup read access"
   112	grep -qF 'GRANT SELECT ON ledger_request_credits TO rewards_writer' "$BOOTSTRAP_SQL" ||
   113	  fail "bootstrap SQL must grant rewards writer read access"
   114	grep -qF 'REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer' "$BOOTSTRAP_SQL" ||
   115	  fail "bootstrap SQL must revoke direct writer table DML"
   116	grep -qF 'REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer' "$BOOTSTRAP_SQL" ||
   117	  fail "bootstrap SQL must revoke direct writer audit table DML"
   118	grep -qF 'REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit' "$BOOTSTRAP_SQL" ||
   119	  fail "bootstrap SQL must revoke public function execute"
   120	MIRROR_UPSERT_SIGNATURE='stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN)'
   121	for sql in "$BOOTSTRAP_SQL" "$MIGRATION_SQL"; do
   122	  grep -qF "GRANT EXECUTE ON FUNCTION $MIRROR_UPSERT_SIGNATURE TO stats_billing_mirror_writer" "$sql" ||
   123	    fail "$sql must grant only the 20-argument mirror upsert function"
   124	  for column in requested_privacy_mode effective_privacy_outcome positive_verification_excluded rewards_excluded; do
   125	    grep -qF "$column" "$sql" || fail "$sql missing mirror column $column"
   126	  done
   127	done
   128	if grep -qF 'GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) TO stats_billing_mirror_writer' "$BOOTSTRAP_SQL" "$MIGRATION_SQL"; then
   129	  fail "bootstrap/migration must not grant the legacy 16-argument mirror upsert"
   130	fi
   131	LEGACY_16_WRITER_REVOKE='REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM stats_billing_mirror_writer'
   132	for source in "$BOOTSTRAP_SQL" "$MIGRATION_SQL" "$MIRROR_GO"; do
   133	  grep -qF "$LEGACY_16_WRITER_REVOKE" "$source" ||
   134	    fail "$source must revoke the legacy 16-argument SECURITY DEFINER function from the mirror writer"
   135	done
   136	
   137	if ! BOOTSTRAP_SQL="$BOOTSTRAP_SQL" MIGRATION_SQL="$MIGRATION_SQL" MIRROR_GO="$MIRROR_GO" python3 <<'PY'
   138	import os
   139	import re
   140	import sys
   141	
   142	expected = [
   143	    "p_sqlite_lrc_id", "p_request_id", "p_attempt_n", "p_provider_id",
   144	    "p_ts_utc", "p_created_at_utc", "p_updated_at_utc", "p_prompt_tokens",
   145	    "p_completion_tokens", "p_estimated_completion_tokens", "p_usage_source",
   146	    "p_provider_credits", "p_fault_flag", "p_quarantined",
   147	    "p_settlement_policy_mode", "p_spec022_verified", "p_requested_privacy_mode",
   148	    "p_effective_privacy_outcome", "p_positive_verification_excluded",
   149	    "p_rewards_excluded",
   150	]
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
     5	DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
     6	RECOVER_SH="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
     7	WATCHDOG_UNIT="$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-watchdog.service"
     8	CATALOG_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/catalog-release-provider-upgrade.md"
     9	PEARL_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/pearl-release-updater.md"
    10	
    11	fail() {
    12	  echo "FAIL: $*" >&2
    13	  exit 1
    14	}
    15	
    16	bash -n "$DEPLOY_SH"
    17	bash -n "$RECOVER_SH"
    18	[ -f "$WATCHDOG_UNIT" ] || fail "remote deploy watchdog unit is missing"
    19	
    20	grep -q '_autotune_release=\\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" ||
    21	  fail "deploy must stage a content-addressed immutable catalog envelope"
    22	
    23	grep -q 'AUTOTUNE_RELEASE_CONTENT_SHA256=' "$DEPLOY_SH" &&
    24	  grep -q 'trusted-keys.json' "$DEPLOY_SH" &&
    25	  grep -q 'asset_digest = hashlib.sha256(path.read_bytes()).hexdigest()' "$DEPLOY_SH" ||
    26	  fail "deploy must content-address catalog envelopes by the full catalog asset set"
    27	
    28	grep -q 'install .*tier2-catalog.json \\$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" &&
    29	  grep -q 'verify-directory --directory \\$_autotune_stage --tier2-public-key-file' "$DEPLOY_SH" ||
    30	  fail "deploy must stage and authenticate Tier-2 inside the release envelope"
    31	
    32	grep -q 'CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"' "$DEPLOY_SH" ||
    33	  fail "deploy must accept only the release-bound Tier-2 current path"
    34	
    35	grep -q 'never.*writes Tier-2 through the current symlink' "$DEPLOY_SH" &&
    36	  grep -q 'root-owned immutable release directories' "$DEPLOY_SH" ||
    37	  fail "deploy must explain root-owned immutable staging and pointer activation"
    38	
    39	activation_line=$(grep -nF 'ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
    40	stage_tier2_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
    41	legacy_remove_line=$(grep -nF 'rm -f /opt/macprovider/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
    42	restart_line=$(grep -nF 'systemctl restart macprovider-coordinator' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
    43	[ -n "$stage_tier2_line" ] && [ -n "$activation_line" ] &&
    44	  [ "$stage_tier2_line" -lt "$activation_line" ] ||
    45	  fail "Tier-2 must be staged in the immutable release before current activation"
    46	[ -n "$legacy_remove_line" ] && [ -n "$restart_line" ] &&
    47	  [ "$activation_line" -lt "$legacy_remove_line" ] && [ "$legacy_remove_line" -lt "$restart_line" ] ||
    48	  fail "deploy must remove the independent Tier-2 bridge after current activation and before coordinator restart"
    49	
    50	if grep -Eq 'install .* /opt/macprovider/tier2-catalog\.json|install .* \$CATALOG_REMOTE_PATH_CANONICAL' "$DEPLOY_SH"; then
    51	  fail "successful deploy must not install Tier-2 through the independent path or current symlink"
    52	fi
    53	
    54	grep -q '_tier2_migration_gate_remote_script()' "$DEPLOY_SH" &&
    55	  grep -q 'legacy Tier-2 catalog bytes differ from active autotune/current release' "$DEPLOY_SH" ||
    56	  fail "deploy must preflight legacy Tier-2 bridge byte equality before mutation"
    57	grep -q 'ROOT = "/opt/macprovider"' "$DEPLOY_SH" &&
    58	  ! grep -q 'MACPROVIDER_ROOT' "$DEPLOY_SH" &&
    59	  grep -q 'O_NOFOLLOW' "$DEPLOY_SH" &&
    60	  grep -q 'dir_fd=' "$DEPLOY_SH" &&
    61	  grep -q 'info.st_nlink != 1' "$DEPLOY_SH" ||
    62	  fail "Tier-2 migration gate must be fixed-root and no-follow/dirfd hardened"
    63	grep -q 'unsafe transient autotune/current.next exists before deploy activation' "$DEPLOY_SH" &&
    64	  grep -q 'unsafe autotune/.previous-target contents before Tier-2 migration' "$DEPLOY_SH" ||
    65	  fail "Tier-2 migration gate must reject unsafe current.next and .previous-target state"
    66	# #1688: scripts/autotune_window.py is the single .previous-target writer
    67	# (no-follow O_EXCL temp + atomic rename live there); deploy logs the plan and
    68	# applies it against the target it just read, before the current swap.
    69	window_plan='python3 -I $DEPLOY_TMP/scripts/autotune_window.py plan --root \"\$_catalog_root\" --incoming releases/$AUTOTUNE_RELEASE_DIR_NAME'
    70	window_apply='python3 -I $DEPLOY_TMP/scripts/autotune_window.py apply --root \"\$_catalog_root\" --incoming releases/$AUTOTUNE_RELEASE_DIR_NAME --expect-current \"\$_previous\"'
    71	plan_line=$(grep -nF "$window_plan" "$DEPLOY_SH" | cut -d: -f1)
    72	apply_line=$(grep -nF "$window_apply" "$DEPLOY_SH" | cut -d: -f1)
    73	swap_line=$(grep -nF 'mv -Tf \"\$_catalog_root/current.next\" \"\$_catalog_root/current\"' "$DEPLOY_SH" | cut -d: -f1)
    74	deploy_tmp_rm_line=$(grep -nF -x '  rm -rf $DEPLOY_TMP' "$DEPLOY_SH" | cut -d: -f1)
    75	[ -n "$plan_line" ] && [ -n "$apply_line" ] && [ -n "$swap_line" ] && [ -n "$deploy_tmp_rm_line" ] &&
    76	  [ "$plan_line" -lt "$apply_line" ] && [ "$apply_line" -lt "$swap_line" ] && [ "$swap_line" -lt "$deploy_tmp_rm_line" ] ||
    77	  fail "deploy must log then apply the autotune_window.py window before the current swap, keeping DEPLOY_TMP until after it"
    78	if grep -Eq "os\.rename\(tmp_name, '\.previous-target'|\.previous-target\.tmp\.|> *[^ ]*\.previous-target" "$DEPLOY_SH"; then
    79	  fail "deploy keeps an inline .previous-target writer; use scripts/autotune_window.py"
    80	fi
    81	
    82	grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json' "$DEPLOY_SH" ||
    83	  fail "deploy smoke must verify macprovider can read autotune feeds"
    84	grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json' "$DEPLOY_SH" ||
    85	  fail "deploy smoke must verify macprovider can read the signed rate-card feed"
    86	
    87	grep -q 'mv -Tf.*current.next.*current' "$DEPLOY_SH" ||
    88	  fail "deploy must atomically activate the verified release"
    89	
    90	grep -q 'restore_regular had-coordinator coordinator' "$RECOVER_SH" ||
    91	  fail "catalog rollback must restore the previous coordinator binary"
    92	
    93	grep -q 'restore_regular had-config coordinator.yaml' "$RECOVER_SH" ||
    94	  fail "catalog rollback must restore the previous coordinator config"
    95	grep -q 'snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay' "$DEPLOY_SH" &&
    96	  grep -q 'restore_regular had-overlay coordinator.pearl-overlays.yaml' "$RECOVER_SH" ||
    97	  fail "catalog rollback must restore the previous coordinator overlay"
    98	grep -q 'overlay-config-backup-name' "$DEPLOY_SH" &&
    99	  grep -q 'overlay-config-backup-name' "$RECOVER_SH" ||
   100	  fail "catalog rollback must preserve overlay dated backup collisions"

exec
/bin/bash -lc "rg -n -C 8 'had-request-log|request-log\\.sqlite|coordinator\\.db|setfacl|apply_acl|restore_acl' phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/coordinator-deploy-recover.sh phase4-coordinator/dist/test | sed -n '1,320p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/dist/coordinator-deploy-recover.sh-4-ROOT=${MACPROVIDER_ROOT:-/opt/macprovider}
phase4-coordinator/dist/coordinator-deploy-recover.sh-5-STATS_ROOT=${MACPROVIDER_STATS_ROOT:-/opt/macprovider-stats}
phase4-coordinator/dist/coordinator-deploy-recover.sh-6-SYSTEMD_ROOT=${MACPROVIDER_SYSTEMD_ROOT:-/etc/systemd/system}
phase4-coordinator/dist/coordinator-deploy-recover.sh-7-NGINX_ROOT=${MACPROVIDER_NGINX_ROOT:-/etc/nginx}
phase4-coordinator/dist/coordinator-deploy-recover.sh-8-ETC_MACPROVIDER_ROOT=${MACPROVIDER_ETC_ROOT:-/etc/macprovider}
phase4-coordinator/dist/coordinator-deploy-recover.sh-9-SYSTEMCTL=${MACPROVIDER_SYSTEMCTL:-systemctl}
phase4-coordinator/dist/coordinator-deploy-recover.sh-10-FLOCK=${MACPROVIDER_FLOCK:-flock}
phase4-coordinator/dist/coordinator-deploy-recover.sh-11-PYTHON=${MACPROVIDER_PYTHON:-python3}
phase4-coordinator/dist/coordinator-deploy-recover.sh:12:SETFACL=${MACPROVIDER_SETFACL:-setfacl}
phase4-coordinator/dist/coordinator-deploy-recover.sh-13-NGINX=${MACPROVIDER_NGINX:-nginx}
phase4-coordinator/dist/coordinator-deploy-recover.sh-14-GLOBAL_LOCK_FILE=${MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE:-/run/lock/macprovider-pearl-updater.lock}
phase4-coordinator/dist/coordinator-deploy-recover.sh-15-LOCK_FILE=${MACPROVIDER_DEPLOY_LOCK_FILE:-/opt/macprovider/.coordinator-deploy.lock}
phase4-coordinator/dist/coordinator-deploy-recover.sh-16-OPERATION_LOCK_FILE=${MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE:-/opt/macprovider/.coordinator-deploy-operation.lock}
phase4-coordinator/dist/coordinator-deploy-recover.sh-17-LOCK_REQUIRED_UID=${MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID:-0}
phase4-coordinator/dist/coordinator-deploy-recover.sh-18-LOCK_REQUIRED_GID=${MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID:-0}
phase4-coordinator/dist/coordinator-deploy-recover.sh-19-ROLLBACK="$ROOT/.coordinator-deploy-rollback"
phase4-coordinator/dist/coordinator-deploy-recover.sh-20-CATALOG_ROOT="$ROOT/autotune"
--
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
--
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
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3131-  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
phase4-coordinator/dist/deploy-pearl-vps.sh-3132-  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
phase4-coordinator/dist/deploy-pearl-vps.sh-3133-  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3134-  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3135-  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3136-  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3137-  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
phase4-coordinator/dist/deploy-pearl-vps.sh-3138-
phase4-coordinator/dist/deploy-pearl-vps.sh:3139:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
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
--
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
phase4-coordinator/dist/deploy-pearl-vps.sh:3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3639:    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh-3640-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3641-  # Stage the complete immutable catalog release. Activation happens only
phase4-coordinator/dist/deploy-pearl-vps.sh-3642-  # after the late connected-provider safeguard immediately before restart.
phase4-coordinator/dist/deploy-pearl-vps.sh-3643-  _autotune_root=/opt/macprovider/autotune
phase4-coordinator/dist/deploy-pearl-vps.sh-3644-  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
phase4-coordinator/dist/deploy-pearl-vps.sh-3645-  _autotune_lock=\$_autotune_release.lock
phase4-coordinator/dist/deploy-pearl-vps.sh-3646-  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh-3647-  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4865-      systemctl is-active stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4866-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4867-  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4868-    systemctl start stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4869-    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
phase4-coordinator/dist/deploy-pearl-vps.sh-4870-  elif [ "$_parity_required" = absent ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4871-    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
phase4-coordinator/dist/deploy-pearl-vps.sh-4872-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4874-    systemctl enable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4875-    if ! systemctl start stats-billing-mirror.service; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4876-      systemctl disable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4877-      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4878-      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
phase4-coordinator/dist/deploy-pearl-vps.sh-4879-      exit 13
phase4-coordinator/dist/deploy-pearl-vps.sh-4880-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4881-    systemctl is-active stats-billing-mirror.timer
--
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-143-for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-144-  had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-145-  had-nginx-stats-proxy-partner had-nginx-coordinator-site \
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-146-  had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-147-  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-148-    fail "nginx rollback coverage missing for $marker"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-149-done
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-150-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:152:  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-153-  fail "request-log ACL changes must be captured and restored"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-154-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-155-grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-156-  fail "rollback must validate and activate the restored nginx graph"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-157-
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-158-freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-159-binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh-160-sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
--
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-13-
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-14-ROOT="$TMP/opt/macprovider"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-15-STATS_ROOT="$TMP/opt/macprovider-stats"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-16-SYSTEMD="$TMP/etc/systemd/system"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-17-NGINX_ROOT="$TMP/etc/nginx"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-18-ETC_MACPROVIDER_ROOT="$TMP/etc/macprovider"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-19-ROLLBACK="$ROOT/.coordinator-deploy-rollback"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-20-SYSTEMCTL_LOG="$TMP/systemctl.log"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:21:SETFACL_LOG="$TMP/setfacl.log"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-22-mkdir -p "$ROOT/autotune/releases/new" "$STATS_ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-23-  "$SYSTEMD/multi-user.target.wants" "$SYSTEMD/timers.target.wants" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-24-  "$NGINX_ROOT/conf.d" "$NGINX_ROOT/sites-available" "$NGINX_ROOT/sites-enabled" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-25-  "$ETC_MACPROVIDER_ROOT" "$TMP/bin"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-26-
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-27-cat >"$TMP/bin/systemctl" <<'SH'
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-28-#!/bin/sh
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-29-printf '%s\n' "$*" >> "$MACPROVIDER_SYSTEMCTL_LOG"
--
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-60-#!/bin/sh
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-61-if [ "${1:-}" = "-n" ]; then
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-62-  exit 0
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-63-fi
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-64-while [ -f "$MACPROVIDER_OPERATION_BLOCK_SENTINEL" ]; do
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-65-  sleep 0.05
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-66-done
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-67-SH
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:68:cat >"$TMP/bin/setfacl" <<'SH'
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-69-#!/bin/sh
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-70-printf '%s\n' "$*" >> "$MACPROVIDER_SETFACL_LOG"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-71-SH
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-72-cat >"$TMP/bin/nginx" <<'SH'
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-73-#!/bin/sh
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-74-[ "${1:-}" = -t ]
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-75-[ "${MACPROVIDER_NGINX_FAIL:-0}" != 1 ]
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-76-SH
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-77-chmod +x "$TMP/bin/systemctl" "$TMP/bin/flock-free" "$TMP/bin/flock-busy" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:78:  "$TMP/bin/flock-operation-blocked" "$TMP/bin/setfacl" "$TMP/bin/nginx"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-79-
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-80-run_recover() {
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-81-  MACPROVIDER_ROOT="$ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-82-  MACPROVIDER_STATS_ROOT="$STATS_ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-83-	  MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-84-	  MACPROVIDER_NGINX_ROOT="$NGINX_ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-85-	  MACPROVIDER_ETC_ROOT="$ETC_MACPROVIDER_ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-86-	  MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-87-  MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-88-  MACPROVIDER_SYSTEMCTL_FAIL_STOP="${MACPROVIDER_SYSTEMCTL_FAIL_STOP:-0}" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-89-  MACPROVIDER_FLOCK="${MACPROVIDER_FLOCK_OVERRIDE:-$TMP/bin/flock-free}" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:90:  MACPROVIDER_SETFACL="$TMP/bin/setfacl" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-91-  MACPROVIDER_SETFACL_LOG="$SETFACL_LOG" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-92-  MACPROVIDER_NGINX="$TMP/bin/nginx" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-93-  MACPROVIDER_NGINX_FAIL="${MACPROVIDER_NGINX_FAIL:-0}" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-94-  MACPROVIDER_OPERATION_BLOCK_SENTINEL="${MACPROVIDER_OPERATION_BLOCK_SENTINEL:-}" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-95-  MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global-deploy.lock" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-96-  MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-97-  MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-98-  MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
--
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
--
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-304-seed_transaction
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-305-MACPROVIDER_ROOT="$ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-306-MACPROVIDER_STATS_ROOT="$STATS_ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-307-MACPROVIDER_SYSTEMD_ROOT="$SYSTEMD" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-308-MACPROVIDER_NGINX_ROOT="$NGINX_ROOT" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-309-MACPROVIDER_SYSTEMCTL="$TMP/bin/systemctl" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-310-MACPROVIDER_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-311-MACPROVIDER_FLOCK="$TMP/bin/flock-busy" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:312:MACPROVIDER_SETFACL="$TMP/bin/setfacl" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-313-MACPROVIDER_SETFACL_LOG="$SETFACL_LOG" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-314-MACPROVIDER_NGINX="$TMP/bin/nginx" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-315-MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$TMP/global-deploy.lock" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-316-MACPROVIDER_DEPLOY_LOCK_FILE="$TMP/deploy.lock" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-317-MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$TMP/deploy-operation.lock" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-318-MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-319-MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(id -g)" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh-320-  "$RECOVER" --pre-start
--
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-8-
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-9-fail() {
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-10-  echo "FAIL: $*" >&2
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-11-  exit 1
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-12-}
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-13-
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-14-[ -f "$RELIEF" ] || fail "missing relief script"
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-15-
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh:16:DB="$TMP/coordinator.db"
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-17-SQL_CAPTURE="$TMP/sql.txt"
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-18-touch "$DB"
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-19-mkdir -p "$TMP/bin"
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-20-cat >"$TMP/bin/sqlite3" <<'SH'
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-21-#!/usr/bin/env bash
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-22-set -euo pipefail
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-23-[ "$1" = "$MACPROVIDER_TEST_DB" ] || exit 11
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh-24-cat > "$MACPROVIDER_TEST_SQL_CAPTURE"
--
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-36-grep -qF '"$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-37-  fail "deploy preflight must require billing mirror unit files"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-38-grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-39-  fail "deploy script missing billing mirror service upload"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-40-grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-41-  fail "deploy script missing billing mirror timer upload"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-42-grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-43-  fail "deploy script missing billing mirror binary install"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-45-  fail "deploy script must grant narrow SQLite file ACL"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:46:grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:47:  fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-49-  fail "deploy script must only enable mirror when stats user can read sqlite source"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-50-grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-51-  fail "deploy script missing billing mirror service install"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-52-grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-53-  fail "deploy script missing billing mirror timer install"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-55-  fail "deploy script must only enable timer when env and SQLite source exist"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-56-grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-57-  fail "deploy script must disable the billing mirror timer after a failed initial run"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-58-grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-59-  fail "deploy script must fail closed when the configured billing mirror cannot run"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-60-
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-61-grep -qxF 'User=macprovider-stats' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-62-  fail "billing mirror must run as dedicated stats user"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-63-grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-64-  fail "billing mirror must run with dedicated stats group"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-65-grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-66-  fail "billing mirror service must be opt-in on env file"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-68-  fail "billing mirror service must require the SQLite source"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-69-grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-70-  fail "billing mirror service must read isolated env file"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-72-  fail "billing mirror service must execute from deploy path"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-74-  fail "billing mirror service must read only the SQLite source"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-75-# The mirror's source DB must never also be inaccessible: systemd applies
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-76-# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-77-# deploy's initial mirror run.
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-78-source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-79-[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-80-if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh-81-  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
--
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-12-  echo "FAIL: $*" >&2
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-13-  exit 1
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-14-}
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-15-
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-16-[ -f "$ROTATE" ] || fail "missing rotate script"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-17-[ -f "$RESTORE" ] || fail "missing restore script"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-18-command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not installed" >&2; exit 0; }
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-19-
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:20:DB="$TMP/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-21-AUDIT_DB="$TMP/coordinator-audit.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-22-ARCHIVE_DIR="$TMP/archive"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-23-
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-24-seed_db() {
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-25-  local db="$1"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-26-  sqlite3 "$db" <<'SQL'
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-27-PRAGMA foreign_keys=ON;
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh-28-CREATE TABLE request_log (

exec
/bin/bash -lc 'git diff --unified=20 1148185e..ee061fc3 -- phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go phase4-coordinator/cmd/stats-billing-mirror/main.go' in /Users/augstar/macprovider-mirror-dbpath
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
diff --git a/phase4-coordinator/dist/stats-billing-mirror.service b/phase4-coordinator/dist/stats-billing-mirror.service
index 056cf4f47..9be817313 100644
--- a/phase4-coordinator/dist/stats-billing-mirror.service
+++ b/phase4-coordinator/dist/stats-billing-mirror.service
@@ -1,28 +1,27 @@
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
-InaccessiblePaths=-/var/lib/macprovider/coordinator.db
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index 292e99c4c..4ac03a779 100755
--- a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
+++ b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
@@ -131,41 +131,41 @@ grep -q 'had-tier2-catalog' "$DEPLOY_SH" && grep -q 'restore_regular had-tier2-c
 
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
diff --git a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
index 9a2075ab5..9ae1b63e3 100755
--- a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
+++ b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
@@ -24,71 +24,79 @@ for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL" "$MIGR
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
+# The mirror's source DB must never also be inaccessible: systemd applies
+# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
+# deploy's initial mirror run.
+source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
+[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
+if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
+  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
+fi
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
diff --git a/phase4-coordinator/internal/stats/billingmirror/mirror.go b/phase4-coordinator/internal/stats/billingmirror/mirror.go
index 5cc0c9506..1caffe167 100644
--- a/phase4-coordinator/internal/stats/billingmirror/mirror.go
+++ b/phase4-coordinator/internal/stats/billingmirror/mirror.go
@@ -2,41 +2,41 @@ package billingmirror
 
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

exec
/bin/bash -lc "rg -n -C 20 'func ReadOnlyDSN|ReadOnlyDSN\\(' phase4-coordinator/internal/sqliteutil phase4-coordinator/internal/requestlog phase4-coordinator/internal/stats/billingmirror; printf '\\n--- coordinator DB config and open ---\\n'; rg -n -C 8 'db_path|OpenStore\\(|journal_mode|busy_timeout|WAL' phase4-coordinator/cmd/coordinator phase4-coordinator/internal/requestlog phase4-coordinator/internal/config | head -n 350" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/internal/sqliteutil/dsn.go-43-// WithManualWALCheckpointPragmas disables SQLite's autocheckpoint for a DB
phase4-coordinator/internal/sqliteutil/dsn.go-44-// handle whose owner starts an explicit off-hot-path checkpoint loop.
phase4-coordinator/internal/sqliteutil/dsn.go-45-func WithManualWALCheckpointPragmas(path string) string {
phase4-coordinator/internal/sqliteutil/dsn.go-46-	base := WithPragmas(path)
phase4-coordinator/internal/sqliteutil/dsn.go-47-	values := url.Values{}
phase4-coordinator/internal/sqliteutil/dsn.go-48-	values.Add("_pragma", "wal_autocheckpoint(0)")
phase4-coordinator/internal/sqliteutil/dsn.go-49-	separator := "?"
phase4-coordinator/internal/sqliteutil/dsn.go-50-	if strings.Contains(base, "?") {
phase4-coordinator/internal/sqliteutil/dsn.go-51-		separator = "&"
phase4-coordinator/internal/sqliteutil/dsn.go-52-	}
phase4-coordinator/internal/sqliteutil/dsn.go-53-	return base + separator + values.Encode()
phase4-coordinator/internal/sqliteutil/dsn.go-54-}
phase4-coordinator/internal/sqliteutil/dsn.go-55-
phase4-coordinator/internal/sqliteutil/dsn.go-56-// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
phase4-coordinator/internal/sqliteutil/dsn.go-57-// Opens with mode=ro and applies PRAGMA query_only=ON at connection
phase4-coordinator/internal/sqliteutil/dsn.go-58-// init via a pragma — no journal_mode toggle, no synchronous toggle,
phase4-coordinator/internal/sqliteutil/dsn.go-59-// no writable connection. SPEC-002 v1.5.1 R-2 / issue #197 R3 code:
phase4-coordinator/internal/sqliteutil/dsn.go-60-// used by `coordinator migrate-indexes --check` so the read-only
phase4-coordinator/internal/sqliteutil/dsn.go-61-// introspection never persists journal-mode metadata or runs ALTER
phase4-coordinator/internal/sqliteutil/dsn.go-62-// TABLE on a legacy DB.
phase4-coordinator/internal/sqliteutil/dsn.go:63:func ReadOnlyDSN(path string) string {
phase4-coordinator/internal/sqliteutil/dsn.go-64-	values := url.Values{}
phase4-coordinator/internal/sqliteutil/dsn.go-65-	values.Set("mode", "ro")
phase4-coordinator/internal/sqliteutil/dsn.go-66-	for _, pragma := range []string{
phase4-coordinator/internal/sqliteutil/dsn.go-67-		"busy_timeout=5000",
phase4-coordinator/internal/sqliteutil/dsn.go-68-		"query_only(true)",
phase4-coordinator/internal/sqliteutil/dsn.go-69-	} {
phase4-coordinator/internal/sqliteutil/dsn.go-70-		values.Add("_pragma", pragma)
phase4-coordinator/internal/sqliteutil/dsn.go-71-	}
phase4-coordinator/internal/sqliteutil/dsn.go-72-	separator := "?"
phase4-coordinator/internal/sqliteutil/dsn.go-73-	if strings.Contains(path, "?") {
phase4-coordinator/internal/sqliteutil/dsn.go-74-		separator = "&"
phase4-coordinator/internal/sqliteutil/dsn.go-75-	}
phase4-coordinator/internal/sqliteutil/dsn.go-76-	return path + separator + values.Encode()
phase4-coordinator/internal/sqliteutil/dsn.go-77-}
--
phase4-coordinator/internal/requestlog/store.go-110-	RelayBlindKID                   string
phase4-coordinator/internal/requestlog/store.go-111-	RelayBlindProviderBindingDigest string
phase4-coordinator/internal/requestlog/store.go-112-	RelayBlindInputTokenUpperBound  *int64
phase4-coordinator/internal/requestlog/store.go-113-	RelayBlindMaxOutputTokens       *int64
phase4-coordinator/internal/requestlog/store.go-114-	PositiveVerificationExcluded    bool
phase4-coordinator/internal/requestlog/store.go-115-	RewardsExcluded                 bool
phase4-coordinator/internal/requestlog/store.go-116-}
phase4-coordinator/internal/requestlog/store.go-117-
phase4-coordinator/internal/requestlog/store.go-118-// OpenStoreReadOnly opens the request-log DB without running ALTER
phase4-coordinator/internal/requestlog/store.go-119-// TABLE migrations or any other schema-mutating DDL. SPEC-002 v1.5.1
phase4-coordinator/internal/requestlog/store.go-120-// R-2 / issue #197 R2 code: the `coordinator migrate-indexes --check`
phase4-coordinator/internal/requestlog/store.go-121-// path MUST be read-only — running the daemon's migrate() inside
phase4-coordinator/internal/requestlog/store.go-122-// --check would silently advance a legacy DB to "unindexed" before
phase4-coordinator/internal/requestlog/store.go-123-// reporting state, defeating the operator's ability to inspect the
phase4-coordinator/internal/requestlog/store.go-124-// pre-migration state. `MigrationState` is the only supported
phase4-coordinator/internal/requestlog/store.go-125-// operation on a read-only store.
phase4-coordinator/internal/requestlog/store.go-126-func OpenStoreReadOnly(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-127-	if dbPath == "" {
phase4-coordinator/internal/requestlog/store.go-128-		return nil, fmt.Errorf("db path is required")
phase4-coordinator/internal/requestlog/store.go-129-	}
phase4-coordinator/internal/requestlog/store.go:130:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(dbPath))
phase4-coordinator/internal/requestlog/store.go-131-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-132-		return nil, err
phase4-coordinator/internal/requestlog/store.go-133-	}
phase4-coordinator/internal/requestlog/store.go-134-	db.SetMaxOpenConns(1)
phase4-coordinator/internal/requestlog/store.go-135-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/requestlog/store.go-136-	return &Store{db: db}, nil
phase4-coordinator/internal/requestlog/store.go-137-}
phase4-coordinator/internal/requestlog/store.go-138-
phase4-coordinator/internal/requestlog/store.go-139-func OpenStore(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-140-	return openStore(dbPath, false)
phase4-coordinator/internal/requestlog/store.go-141-}
phase4-coordinator/internal/requestlog/store.go-142-
phase4-coordinator/internal/requestlog/store.go-143-func OpenStoreWithManualWALCheckpoint(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-144-	return openStore(dbPath, true)
phase4-coordinator/internal/requestlog/store.go-145-}
phase4-coordinator/internal/requestlog/store.go-146-
phase4-coordinator/internal/requestlog/store.go-147-func openStore(dbPath string, manualWALCheckpoint bool) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-148-	if dbPath == "" {
phase4-coordinator/internal/requestlog/store.go-149-		return nil, fmt.Errorf("db path is required")
phase4-coordinator/internal/requestlog/store.go-150-	}
--
phase4-coordinator/internal/stats/billingmirror/mirror.go-234-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-235-	if opts.OverlapRows == 0 {
phase4-coordinator/internal/stats/billingmirror/mirror.go-236-		opts.OverlapRows = DefaultOverlapRows
phase4-coordinator/internal/stats/billingmirror/mirror.go-237-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-238-	if opts.OverlapRows > int64(opts.BatchSize) {
phase4-coordinator/internal/stats/billingmirror/mirror.go-239-		opts.OverlapRows = int64(opts.BatchSize)
phase4-coordinator/internal/stats/billingmirror/mirror.go-240-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-241-	if opts.SweepRows < 0 {
phase4-coordinator/internal/stats/billingmirror/mirror.go-242-		opts.SweepRows = 0
phase4-coordinator/internal/stats/billingmirror/mirror.go-243-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-244-	if opts.SweepRows == 0 {
phase4-coordinator/internal/stats/billingmirror/mirror.go-245-		opts.SweepRows = opts.BatchSize
phase4-coordinator/internal/stats/billingmirror/mirror.go-246-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-247-	if opts.SweepRows > opts.BatchSize {
phase4-coordinator/internal/stats/billingmirror/mirror.go-248-		opts.SweepRows = opts.BatchSize
phase4-coordinator/internal/stats/billingmirror/mirror.go-249-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-250-	return opts
phase4-coordinator/internal/stats/billingmirror/mirror.go-251-}
phase4-coordinator/internal/stats/billingmirror/mirror.go-252-
phase4-coordinator/internal/stats/billingmirror/mirror.go-253-func OpenSQLite(path string) (*sql.DB, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
phase4-coordinator/internal/stats/billingmirror/mirror.go-255-	if err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go-256-		return nil, fmt.Errorf("open sqlite: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go-257-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-258-	db.SetMaxOpenConns(1)
phase4-coordinator/internal/stats/billingmirror/mirror.go-259-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/stats/billingmirror/mirror.go-260-	return db, nil
phase4-coordinator/internal/stats/billingmirror/mirror.go-261-}
phase4-coordinator/internal/stats/billingmirror/mirror.go-262-
phase4-coordinator/internal/stats/billingmirror/mirror.go-263-func OpenPostgres(dsn string) (*sql.DB, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go-264-	db, err := sql.Open("postgres", dsn)
phase4-coordinator/internal/stats/billingmirror/mirror.go-265-	if err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go-266-		return nil, fmt.Errorf("open postgres: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go-267-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-268-	db.SetMaxOpenConns(1)
phase4-coordinator/internal/stats/billingmirror/mirror.go-269-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/stats/billingmirror/mirror.go-270-	db.SetConnMaxLifetime(5 * time.Minute)
phase4-coordinator/internal/stats/billingmirror/mirror.go-271-	db.SetConnMaxIdleTime(time.Minute)
phase4-coordinator/internal/stats/billingmirror/mirror.go-272-	return db, nil
phase4-coordinator/internal/stats/billingmirror/mirror.go-273-}
phase4-coordinator/internal/stats/billingmirror/mirror.go-274-

--- coordinator DB config and open ---
phase4-coordinator/internal/requestlog/store.go-131-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-132-		return nil, err
phase4-coordinator/internal/requestlog/store.go-133-	}
phase4-coordinator/internal/requestlog/store.go-134-	db.SetMaxOpenConns(1)
phase4-coordinator/internal/requestlog/store.go-135-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/requestlog/store.go-136-	return &Store{db: db}, nil
phase4-coordinator/internal/requestlog/store.go-137-}
phase4-coordinator/internal/requestlog/store.go-138-
phase4-coordinator/internal/requestlog/store.go:139:func OpenStore(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-140-	return openStore(dbPath, false)
phase4-coordinator/internal/requestlog/store.go-141-}
phase4-coordinator/internal/requestlog/store.go-142-
phase4-coordinator/internal/requestlog/store.go:143:func OpenStoreWithManualWALCheckpoint(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-144-	return openStore(dbPath, true)
phase4-coordinator/internal/requestlog/store.go-145-}
phase4-coordinator/internal/requestlog/store.go-146-
phase4-coordinator/internal/requestlog/store.go:147:func openStore(dbPath string, manualWALCheckpoint bool) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go-148-	if dbPath == "" {
phase4-coordinator/internal/requestlog/store.go-149-		return nil, fmt.Errorf("db path is required")
phase4-coordinator/internal/requestlog/store.go-150-	}
phase4-coordinator/internal/requestlog/store.go-151-	if dir := filepath.Dir(dbPath); dir != "." && dir != "" {
phase4-coordinator/internal/requestlog/store.go-152-		if err := os.MkdirAll(dir, 0o755); err != nil {
phase4-coordinator/internal/requestlog/store.go-153-			return nil, err
phase4-coordinator/internal/requestlog/store.go-154-		}
phase4-coordinator/internal/requestlog/store.go-155-	}
phase4-coordinator/internal/requestlog/store.go-156-	dsn := sqliteutil.WithPragmas(dbPath)
phase4-coordinator/internal/requestlog/store.go:157:	if manualWALCheckpoint {
phase4-coordinator/internal/requestlog/store.go:158:		dsn = sqliteutil.WithManualWALCheckpointPragmas(dbPath)
phase4-coordinator/internal/requestlog/store.go-159-	}
phase4-coordinator/internal/requestlog/store.go-160-	db, err := sql.Open("sqlite", dsn)
phase4-coordinator/internal/requestlog/store.go-161-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-162-		return nil, err
phase4-coordinator/internal/requestlog/store.go-163-	}
phase4-coordinator/internal/requestlog/store.go-164-	// SQLite supports one writer at a time; the pool-wide connection cap
phase4-coordinator/internal/requestlog/store.go-165-	// is the natural primitive for serializing writes and bounding the
phase4-coordinator/internal/requestlog/store.go-166-	// implicit Go-pool cap. Issue #21 / ARCH-3 / 2026-06-10 audit QW-5:
--
phase4-coordinator/internal/requestlog/store.go-171-	// patterns in internal/billing/{store,endpoints,recovery}.go — those
phase4-coordinator/internal/requestlog/store.go-172-	// were refactored to two-pass / tx-bound queryers in the same change
phase4-coordinator/internal/requestlog/store.go-173-	// as this cap so the requestlog + billing shared *sql.DB no longer
phase4-coordinator/internal/requestlog/store.go-174-	// deadlocks.
phase4-coordinator/internal/requestlog/store.go-175-	db.SetMaxOpenConns(1)
phase4-coordinator/internal/requestlog/store.go-176-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/requestlog/store.go-177-	s := &Store{db: db}
phase4-coordinator/internal/requestlog/store.go-178-	ctx := context.Background()
phase4-coordinator/internal/requestlog/store.go:179:	if _, err := s.db.ExecContext(ctx, `PRAGMA journal_mode=WAL`); err != nil {
phase4-coordinator/internal/requestlog/store.go-180-		_ = db.Close()
phase4-coordinator/internal/requestlog/store.go-181-		return nil, err
phase4-coordinator/internal/requestlog/store.go-182-	}
phase4-coordinator/internal/requestlog/store.go:183:	if _, err := s.db.ExecContext(ctx, `PRAGMA busy_timeout=5000`); err != nil {
phase4-coordinator/internal/requestlog/store.go-184-		_ = db.Close()
phase4-coordinator/internal/requestlog/store.go-185-		return nil, err
phase4-coordinator/internal/requestlog/store.go-186-	}
phase4-coordinator/internal/requestlog/store.go-187-	if err := s.migrate(ctx); err != nil {
phase4-coordinator/internal/requestlog/store.go-188-		_ = db.Close()
phase4-coordinator/internal/requestlog/store.go-189-		return nil, err
phase4-coordinator/internal/requestlog/store.go-190-	}
phase4-coordinator/internal/requestlog/store.go-191-	return s, nil
--
phase4-coordinator/internal/requestlog/store_test.go-423-	if _, err := db.Exec(`
phase4-coordinator/internal/requestlog/store_test.go-424-INSERT INTO request_idempotency_keys (idempotency_key, body_sha256, request_id, created_at_utc)
phase4-coordinator/internal/requestlog/store_test.go-425-VALUES ('idem-legacy', 'hash-a', 'req-legacy', ?)`,
phase4-coordinator/internal/requestlog/store_test.go-426-		now.UTC().Format(time.RFC3339Nano)); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-427-		t.Fatalf("seed idempotency key: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-428-	}
phase4-coordinator/internal/requestlog/store_test.go-429-	_ = db.Close()
phase4-coordinator/internal/requestlog/store_test.go-430-
phase4-coordinator/internal/requestlog/store_test.go:431:	store, err := OpenStore(dbPath)
phase4-coordinator/internal/requestlog/store_test.go-432-	if err != nil {
phase4-coordinator/internal/requestlog/store_test.go-433-		t.Fatalf("OpenStore: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-434-	}
phase4-coordinator/internal/requestlog/store_test.go-435-	defer store.Close()
phase4-coordinator/internal/requestlog/store_test.go-436-	requestID, replay, err := store.ReserveIdempotencyKey(context.Background(), "acct-legacy", "idem-legacy", "hash-a", "req-new", now.Add(time.Second))
phase4-coordinator/internal/requestlog/store_test.go-437-	if err != nil {
phase4-coordinator/internal/requestlog/store_test.go-438-		t.Fatalf("ReserveIdempotencyKey replay: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-439-	}
--
phase4-coordinator/internal/requestlog/store_test.go-453-	if err := store.db.QueryRowContext(context.Background(), `PRAGMA wal_autocheckpoint`).Scan(&got); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-454-		t.Fatalf("PRAGMA wal_autocheckpoint: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-455-	}
phase4-coordinator/internal/requestlog/store_test.go-456-	if got == 0 {
phase4-coordinator/internal/requestlog/store_test.go-457-		t.Fatal("request log store disabled wal_autocheckpoint without an explicit checkpoint owner")
phase4-coordinator/internal/requestlog/store_test.go-458-	}
phase4-coordinator/internal/requestlog/store_test.go-459-}
phase4-coordinator/internal/requestlog/store_test.go-460-
phase4-coordinator/internal/requestlog/store_test.go:461:func TestOpenStoreWithManualWALCheckpointAppliesSQLitePragmasViaDSN(t *testing.T) {
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go-463-	if err != nil {
phase4-coordinator/internal/requestlog/store_test.go-464-		t.Fatal(err)
phase4-coordinator/internal/requestlog/store_test.go-465-	}
phase4-coordinator/internal/requestlog/store_test.go-466-	defer store.Close()
phase4-coordinator/internal/requestlog/store_test.go-467-	ctx := context.Background()
phase4-coordinator/internal/requestlog/store_test.go-468-	for _, tc := range []struct {
phase4-coordinator/internal/requestlog/store_test.go-469-		query string
phase4-coordinator/internal/requestlog/store_test.go-470-		want  int
phase4-coordinator/internal/requestlog/store_test.go-471-	}{
phase4-coordinator/internal/requestlog/store_test.go:472:		{query: `PRAGMA busy_timeout`, want: 5000},
phase4-coordinator/internal/requestlog/store_test.go-473-		{query: `PRAGMA foreign_keys`, want: 1},
phase4-coordinator/internal/requestlog/store_test.go-474-		{query: `PRAGMA wal_autocheckpoint`, want: 0},
phase4-coordinator/internal/requestlog/store_test.go-475-	} {
phase4-coordinator/internal/requestlog/store_test.go-476-		var got int
phase4-coordinator/internal/requestlog/store_test.go-477-		if err := store.db.QueryRowContext(ctx, tc.query).Scan(&got); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-478-			t.Fatalf("%s: %v", tc.query, err)
phase4-coordinator/internal/requestlog/store_test.go-479-		}
phase4-coordinator/internal/requestlog/store_test.go-480-		if got != tc.want {
--
phase4-coordinator/internal/requestlog/store_test.go-582-		"session-pre",
phase4-coordinator/internal/requestlog/store_test.go-583-		200,
phase4-coordinator/internal/requestlog/store_test.go-584-		"127.0.0.1",
phase4-coordinator/internal/requestlog/store_test.go-585-	); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-586-		t.Fatalf("seed pre-migration row: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-587-	}
phase4-coordinator/internal/requestlog/store_test.go-588-	_ = db.Close()
phase4-coordinator/internal/requestlog/store_test.go-589-
phase4-coordinator/internal/requestlog/store_test.go:590:	store, err := OpenStore(dbPath)
phase4-coordinator/internal/requestlog/store_test.go-591-	// SPEC-002 v1.4.2 R-2 / ISS-188 R4 audit: OpenStore is column-only;
phase4-coordinator/internal/requestlog/store_test.go-592-	// the partial-NULL index ships via MigrateIndexes invoked from main.
phase4-coordinator/internal/requestlog/store_test.go-593-	// Tests asserting index presence call it synchronously here.
phase4-coordinator/internal/requestlog/store_test.go-594-	if err == nil {
phase4-coordinator/internal/requestlog/store_test.go-595-		if mErr := store.MigrateIndexes(context.Background()); mErr != nil {
phase4-coordinator/internal/requestlog/store_test.go-596-			t.Fatalf("MigrateIndexes: %v", mErr)
phase4-coordinator/internal/requestlog/store_test.go-597-		}
phase4-coordinator/internal/requestlog/store_test.go-598-	}
--
phase4-coordinator/internal/requestlog/store_test.go-752-	if olderLeft != 0 {
phase4-coordinator/internal/requestlog/store_test.go-753-		t.Fatalf("rows older than cutoff still present: %d", olderLeft)
phase4-coordinator/internal/requestlog/store_test.go-754-	}
phase4-coordinator/internal/requestlog/store_test.go-755-}
phase4-coordinator/internal/requestlog/store_test.go-756-
phase4-coordinator/internal/requestlog/store_test.go-757-// TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert runs PruneBefore
phase4-coordinator/internal/requestlog/store_test.go-758-// against a backlog while a writer goroutine inserts fresh rows. Both
phase4-coordinator/internal/requestlog/store_test.go-759-// must complete without SQLITE_BUSY — the batched DELETE keeps the
phase4-coordinator/internal/requestlog/store_test.go:760:// write lock short enough that the writer's busy_timeout absorbs each
phase4-coordinator/internal/requestlog/store_test.go-761-// release. Regression guard for M3-1: a single multi-second DELETE
phase4-coordinator/internal/requestlog/store_test.go:762:// would exceed busy_timeout under contention.
phase4-coordinator/internal/requestlog/store_test.go-763-func TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert(t *testing.T) {
phase4-coordinator/internal/requestlog/store_test.go-764-	store := openTestStore(t)
phase4-coordinator/internal/requestlog/store_test.go-765-	defer store.Close()
phase4-coordinator/internal/requestlog/store_test.go-766-	ctx := context.Background()
phase4-coordinator/internal/requestlog/store_test.go-767-	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
phase4-coordinator/internal/requestlog/store_test.go-768-	const old = 8000
phase4-coordinator/internal/requestlog/store_test.go-769-	for i := 0; i < old; i++ {
phase4-coordinator/internal/requestlog/store_test.go-770-		ts := cutoff.Add(-time.Duration(i+1) * time.Second)
--
phase4-coordinator/internal/requestlog/store_test.go-841-	plan := combined.String()
phase4-coordinator/internal/requestlog/store_test.go-842-	if !strings.Contains(plan, "idx_request_log_ts_utc") {
phase4-coordinator/internal/requestlog/store_test.go-843-		t.Fatalf("plan does not reference idx_request_log_ts_utc; full plan:\n%s", plan)
phase4-coordinator/internal/requestlog/store_test.go-844-	}
phase4-coordinator/internal/requestlog/store_test.go-845-}
phase4-coordinator/internal/requestlog/store_test.go-846-
phase4-coordinator/internal/requestlog/store_test.go-847-func openTestStore(t *testing.T) *Store {
phase4-coordinator/internal/requestlog/store_test.go-848-	t.Helper()
phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go-850-	if err != nil {
phase4-coordinator/internal/requestlog/store_test.go-851-		t.Fatalf("open store: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-852-	}
phase4-coordinator/internal/requestlog/store_test.go-853-	return store
phase4-coordinator/internal/requestlog/store_test.go-854-}
phase4-coordinator/internal/requestlog/store_test.go-855-
phase4-coordinator/internal/requestlog/store_test.go-856-// TestMigrationStateReportsPerKeyStatesAndAggregate exercises SPEC-002
phase4-coordinator/internal/requestlog/store_test.go-857-// v1.5.1 R-2 / issue #197: MigrationState MUST report per-key state
--
phase4-coordinator/internal/config/config_env_test.go-65-
phase4-coordinator/internal/config/config_env_test.go-66-// TestLoadResolvesPayoutSecurityEnvFields covers the Step 4 r1 [sec:r1-4]
phase4-coordinator/internal/config/config_env_test.go-67-// MEDIUM fix: env:NAME indirection must be expanded for payout.security.*
phase4-coordinator/internal/config/config_env_test.go-68-// string fields so operators can inject RPC URLs + wallet path via env vars.
phase4-coordinator/internal/config/config_env_test.go-69-func TestLoadResolvesPayoutSecurityEnvFields(t *testing.T) {
phase4-coordinator/internal/config/config_env_test.go-70-	t.Setenv("S4R1_TEST_OP_KEY", "0123456789abcdefABCDEFghijklmnop")
phase4-coordinator/internal/config/config_env_test.go-71-	t.Setenv("S4R1_PAYOUT_RPC_PRIMARY", "https://primary.rpc.example/v1")
phase4-coordinator/internal/config/config_env_test.go-72-	t.Setenv("S4R1_PAYOUT_RPC_SECONDARY", "https://secondary.rpc.example/v1")
phase4-coordinator/internal/config/config_env_test.go:73:	t.Setenv("S4R1_PAYOUT_HOT_WALLET", "0x8ba1f109551bD432803012645Ac136ddd64DBA72")
phase4-coordinator/internal/config/config_env_test.go:74:	t.Setenv("S4R1_PAYOUT_WALLET_PATH", "/var/lib/macprovider/wallet.enc")
phase4-coordinator/internal/config/config_env_test.go-75-
phase4-coordinator/internal/config/config_env_test.go-76-	cfg := writeMinimalConfig(t, `
phase4-coordinator/internal/config/config_env_test.go-77-auth:
phase4-coordinator/internal/config/config_env_test.go-78-  operator_key: env:S4R1_TEST_OP_KEY
phase4-coordinator/internal/config/config_env_test.go-79-  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_env_test.go-80-payout:
phase4-coordinator/internal/config/config_env_test.go-81-  enabled: true
phase4-coordinator/internal/config/config_env_test.go-82-  security:
phase4-coordinator/internal/config/config_env_test.go:83:    hot_wallet_address: env:S4R1_PAYOUT_HOT_WALLET
phase4-coordinator/internal/config/config_env_test.go-84-    rpc_url_primary:    env:S4R1_PAYOUT_RPC_PRIMARY
phase4-coordinator/internal/config/config_env_test.go-85-    rpc_url_secondary:  env:S4R1_PAYOUT_RPC_SECONDARY
phase4-coordinator/internal/config/config_env_test.go:86:    encrypted_wallet_path: env:S4R1_PAYOUT_WALLET_PATH
phase4-coordinator/internal/config/config_env_test.go-87-    per_payout_cap_usdc_base_units: 500000000
phase4-coordinator/internal/config/config_env_test.go-88-    per_day_cap_usdc_base_units:    5000000000
phase4-coordinator/internal/config/config_env_test.go-89-    cancel_max_tip_multiplier:      5.0
phase4-coordinator/internal/config/config_env_test.go-90-    cancel_max_gas_native_wei:      10000000000000000
phase4-coordinator/internal/config/config_env_test.go-91-    cancel_max_gas_native_wei_per_24h: 50000000000000000
phase4-coordinator/internal/config/config_env_test.go-92-    abandon_rate_per_hour:          3
phase4-coordinator/internal/config/config_env_test.go-93-    chain_recon_interval:           1h
phase4-coordinator/internal/config/config_env_test.go-94-    chain_recon_tolerance_usdc_base_units: 100000
--
phase4-coordinator/internal/config/config_env_test.go-303-	return Load(path)
phase4-coordinator/internal/config/config_env_test.go-304-}
phase4-coordinator/internal/config/config_env_test.go-305-
phase4-coordinator/internal/config/config_env_test.go-306-// TestLoadResolvesHotWalletEnvInRegistrationOnly covers #954:
phase4-coordinator/internal/config/config_env_test.go-307-// env:NAME for hot_wallet_address must resolve even when
phase4-coordinator/internal/config/config_env_test.go-308-// payout.enabled=false so registration-only can use secret indirection.
phase4-coordinator/internal/config/config_env_test.go-309-func TestLoadResolvesHotWalletEnvInRegistrationOnly(t *testing.T) {
phase4-coordinator/internal/config/config_env_test.go-310-	t.Setenv("S954_TEST_OP_KEY", "0123456789abcdefABCDEFghijklmnop")
phase4-coordinator/internal/config/config_env_test.go:311:	t.Setenv("S954_PAYOUT_HOT_WALLET", "0x8ba1f109551bD432803012645Ac136ddd64DBA72")
phase4-coordinator/internal/config/config_env_test.go-312-
phase4-coordinator/internal/config/config_env_test.go-313-	cfg := writeMinimalConfig(t, `
phase4-coordinator/internal/config/config_env_test.go-314-auth:
phase4-coordinator/internal/config/config_env_test.go-315-  operator_key: env:S954_TEST_OP_KEY
phase4-coordinator/internal/config/config_env_test.go-316-  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_env_test.go-317-payout:
phase4-coordinator/internal/config/config_env_test.go-318-  enabled: false
phase4-coordinator/internal/config/config_env_test.go-319-  security:
phase4-coordinator/internal/config/config_env_test.go:320:    hot_wallet_address: env:S954_PAYOUT_HOT_WALLET
phase4-coordinator/internal/config/config_env_test.go-321-  tuning:
phase4-coordinator/internal/config/config_env_test.go-322-    address_cooling_off_period: 24h
phase4-coordinator/internal/config/config_env_test.go-323-`)
phase4-coordinator/internal/config/config_env_test.go-324-	if cfg.Payout.Security.HotWalletAddress != "0x8ba1f109551bD432803012645Ac136ddd64DBA72" {
phase4-coordinator/internal/config/config_env_test.go-325-		t.Errorf("HotWalletAddress=%q, want resolved value in registration-only", cfg.Payout.Security.HotWalletAddress)
phase4-coordinator/internal/config/config_env_test.go-326-	}
phase4-coordinator/internal/config/config_env_test.go-327-	if cfg.Payout.Enabled {
phase4-coordinator/internal/config/config_env_test.go-328-		t.Fatal("enabled must stay false")
--
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-98-			}
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-99-		case "text", "":
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-100-			fmt.Fprintf(stdout, "migration_state: %s\n  null_count: %d\n  total_count: %d\n",
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-101-				status.MigrationState, status.NullCount, status.TotalCount)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-102-		}
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-103-		return 0
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-104-	}
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-105-
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:106:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-107-	if err != nil {
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-108-		fmt.Fprintf(stderr, "open request_log: %v\n", err)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-109-		return 1
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-110-	}
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-111-	defer store.Close()
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-112-
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-113-	if *dryRun {
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go-114-		started := time.Now()
--
phase4-coordinator/cmd/coordinator/main_test.go-56-	}
phase4-coordinator/cmd/coordinator/main_test.go-57-	if server.IdleTimeout == 0 {
phase4-coordinator/cmd/coordinator/main_test.go-58-		t.Fatal("IdleTimeout must be set")
phase4-coordinator/cmd/coordinator/main_test.go-59-	}
phase4-coordinator/cmd/coordinator/main_test.go-60-}
phase4-coordinator/cmd/coordinator/main_test.go-61-
phase4-coordinator/cmd/coordinator/main_test.go-62-func TestLoadTrustedPoolsDisablesPoolSupportOnReconstructionFailure(t *testing.T) {
phase4-coordinator/cmd/coordinator/main_test.go-63-	ctx := context.Background()
phase4-coordinator/cmd/coordinator/main_test.go:64:	reqLogStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
phase4-coordinator/cmd/coordinator/main_test.go-65-	if err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-66-		t.Fatalf("OpenStore: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-67-	}
phase4-coordinator/cmd/coordinator/main_test.go-68-	t.Cleanup(func() { _ = reqLogStore.Close() })
phase4-coordinator/cmd/coordinator/main_test.go-69-	if _, err := trustpool.NewStore(reqLogStore.DB()); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-70-		t.Fatalf("NewStore: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-71-	}
phase4-coordinator/cmd/coordinator/main_test.go-72-	if _, err := reqLogStore.DB().ExecContext(ctx, `
--
phase4-coordinator/cmd/coordinator/main_test.go-222-	if routeSnapshotSQLiteBusyTimeout < 250*time.Millisecond {
phase4-coordinator/cmd/coordinator/main_test.go-223-		t.Fatalf("route snapshot busy timeout=%s, want enough headroom for short SQLite writer overlap", routeSnapshotSQLiteBusyTimeout)
phase4-coordinator/cmd/coordinator/main_test.go-224-	}
phase4-coordinator/cmd/coordinator/main_test.go-225-	if routeSnapshotSQLiteBusyTimeout > time.Second {
phase4-coordinator/cmd/coordinator/main_test.go-226-		t.Fatalf("route snapshot busy timeout=%s, want bounded pre-dispatch latency", routeSnapshotSQLiteBusyTimeout)
phase4-coordinator/cmd/coordinator/main_test.go-227-	}
phase4-coordinator/cmd/coordinator/main_test.go-228-}
phase4-coordinator/cmd/coordinator/main_test.go-229-
phase4-coordinator/cmd/coordinator/main_test.go:230:func TestMoneySQLiteWALCheckpointerRunsWhileBusy(t *testing.T) {
phase4-coordinator/cmd/coordinator/main_test.go-231-	dbPath := filepath.Join(t.TempDir(), "checkpoint.db")
phase4-coordinator/cmd/coordinator/main_test.go-232-	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go-233-	if err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-234-		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-235-	}
phase4-coordinator/cmd/coordinator/main_test.go-236-	t.Cleanup(func() { _ = db.Close() })
phase4-coordinator/cmd/coordinator/main_test.go-237-	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-238-		t.Fatalf("create table: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-239-	}
phase4-coordinator/cmd/coordinator/main_test.go-240-	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a')`); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-241-		t.Fatalf("insert: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-242-	}
phase4-coordinator/cmd/coordinator/main_test.go-243-
phase4-coordinator/cmd/coordinator/main_test.go-244-	ctx, cancel := context.WithCancel(context.Background())
phase4-coordinator/cmd/coordinator/main_test.go-245-	defer cancel()
phase4-coordinator/cmd/coordinator/main_test.go-246-	observer := &walObserverStub{called: make(chan string, 16), durations: make(chan struct{}, 4)}
phase4-coordinator/cmd/coordinator/main_test.go:247:	startMoneySQLiteWALCheckpointerWithConfig(ctx, db, observer, zerolog.Nop(), fixedIdleTracker{idleFor: 0}, moneySQLiteWALCheckpointerConfig{
phase4-coordinator/cmd/coordinator/main_test.go-248-		PollInterval:   10 * time.Millisecond,
phase4-coordinator/cmd/coordinator/main_test.go-249-		IdleInterval:   time.Hour,
phase4-coordinator/cmd/coordinator/main_test.go-250-		MinTimeout:     time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-251-		MaxTimeout:     time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-252-		BusyTimeout:    10 * time.Millisecond,
phase4-coordinator/cmd/coordinator/main_test.go-253-		BytesPerSecond: moneySQLiteCheckpointBytesPerSecond,
phase4-coordinator/cmd/coordinator/main_test.go-254-		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go-255-	})
phase4-coordinator/cmd/coordinator/main_test.go-256-
phase4-coordinator/cmd/coordinator/main_test.go:257:	assertWALCheckpointObservations(t, observer)
phase4-coordinator/cmd/coordinator/main_test.go-258-}
phase4-coordinator/cmd/coordinator/main_test.go-259-
phase4-coordinator/cmd/coordinator/main_test.go:260:func TestMoneySQLiteWALCheckpointerRunsAfterIdle(t *testing.T) {
phase4-coordinator/cmd/coordinator/main_test.go-261-	dbPath := filepath.Join(t.TempDir(), "checkpoint.db")
phase4-coordinator/cmd/coordinator/main_test.go-262-	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go-263-	if err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-264-		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-265-	}
phase4-coordinator/cmd/coordinator/main_test.go-266-	t.Cleanup(func() { _ = db.Close() })
phase4-coordinator/cmd/coordinator/main_test.go-267-	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-268-		t.Fatalf("create table: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-269-	}
phase4-coordinator/cmd/coordinator/main_test.go-270-	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a')`); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-271-		t.Fatalf("insert: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-272-	}
phase4-coordinator/cmd/coordinator/main_test.go-273-
phase4-coordinator/cmd/coordinator/main_test.go-274-	ctx, cancel := context.WithCancel(context.Background())
phase4-coordinator/cmd/coordinator/main_test.go-275-	defer cancel()
phase4-coordinator/cmd/coordinator/main_test.go-276-	observer := &walObserverStub{called: make(chan string, 16), durations: make(chan struct{}, 4)}
phase4-coordinator/cmd/coordinator/main_test.go:277:	startMoneySQLiteWALCheckpointerWithConfig(ctx, db, observer, zerolog.Nop(), fixedIdleTracker{idleFor: time.Hour}, moneySQLiteWALCheckpointerConfig{
phase4-coordinator/cmd/coordinator/main_test.go-278-		PollInterval:   10 * time.Millisecond,
phase4-coordinator/cmd/coordinator/main_test.go-279-		IdleInterval:   10 * time.Millisecond,
phase4-coordinator/cmd/coordinator/main_test.go-280-		MinTimeout:     time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-281-		MaxTimeout:     time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-282-		BusyTimeout:    10 * time.Millisecond,
phase4-coordinator/cmd/coordinator/main_test.go-283-		BytesPerSecond: moneySQLiteCheckpointBytesPerSecond,
phase4-coordinator/cmd/coordinator/main_test.go-284-		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go-285-	})
phase4-coordinator/cmd/coordinator/main_test.go-286-
phase4-coordinator/cmd/coordinator/main_test.go:287:	assertWALCheckpointObservations(t, observer)
phase4-coordinator/cmd/coordinator/main_test.go-288-}
phase4-coordinator/cmd/coordinator/main_test.go-289-
phase4-coordinator/cmd/coordinator/main_test.go-290-func TestMoneySQLiteActiveCheckpointDoesNotEscalateToTruncate(t *testing.T) {
phase4-coordinator/cmd/coordinator/main_test.go-291-	dbPath := filepath.Join(t.TempDir(), "active-checkpoint.db")
phase4-coordinator/cmd/coordinator/main_test.go:292:	db, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go-293-	if err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-294-		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-295-	}
phase4-coordinator/cmd/coordinator/main_test.go-296-	t.Cleanup(func() { _ = db.Close() })
phase4-coordinator/cmd/coordinator/main_test.go-297-	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-298-		t.Fatalf("create table: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-299-	}
phase4-coordinator/cmd/coordinator/main_test.go-300-	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('active')`); err != nil {
phase4-coordinator/cmd/coordinator/main_test.go-301-		t.Fatalf("insert: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go-302-	}
phase4-coordinator/cmd/coordinator/main_test.go:303:	if size := sqliteutil.WALFileSize(dbPath); size == 0 {
phase4-coordinator/cmd/coordinator/main_test.go:304:		t.Fatal("WAL size before active checkpoint = 0, want frames to checkpoint")
phase4-coordinator/cmd/coordinator/main_test.go-305-	}
phase4-coordinator/cmd/coordinator/main_test.go-306-
phase4-coordinator/cmd/coordinator/main_test.go:307:	runMoneySQLiteWALCheckpoint(context.Background(), db, nil, zerolog.Nop(), fixedIdleTracker{idleFor: 0}, moneySQLiteWALCheckpointerConfig{
phase4-coordinator/cmd/coordinator/main_test.go-308-		IdleInterval:   time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-309-		MinTimeout:     time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-310-		MaxTimeout:     time.Second,
phase4-coordinator/cmd/coordinator/main_test.go-311-		BusyTimeout:    50 * time.Millisecond,
phase4-coordinator/cmd/coordinator/main_test.go-312-		BytesPerSecond: moneySQLiteCheckpointBytesPerSecond,
phase4-coordinator/cmd/coordinator/main_test.go-313-		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go-314-	})
phase4-coordinator/cmd/coordinator/main_test.go:315:	if size := sqliteutil.WALFileSize(dbPath); size == 0 {

exec
/bin/bash -lc "sed -n '1,130p' phase4-coordinator/internal/sqliteutil/dsn.go; sed -n '147,215p' phase4-coordinator/internal/requestlog/store.go; rg -n 'Storage\\.DBPath|DBPath|db_path|OpenStore\\(' phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/cmd/coordinator/*.go phase4-coordinator/internal/config -g '*.go' | head -n 220" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
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
func openStore(dbPath string, manualWALCheckpoint bool) (*Store, error) {
	if dbPath == "" {
		return nil, fmt.Errorf("db path is required")
	}
	if dir := filepath.Dir(dbPath); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	dsn := sqliteutil.WithPragmas(dbPath)
	if manualWALCheckpoint {
		dsn = sqliteutil.WithManualWALCheckpointPragmas(dbPath)
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// SQLite supports one writer at a time; the pool-wide connection cap
	// is the natural primitive for serializing writes and bounding the
	// implicit Go-pool cap. Issue #21 / ARCH-3 / 2026-06-10 audit QW-5:
	// auth.OpenStore and audit.OpenStore already cap at 1; requestlog
	// (which billing reuses via billing.NewStore(reqLogStore.DB()) at
	// cmd/coordinator/main.go) was the missing third store. PR #14's
	// previous attempt hung at this cap because of nested-cursor
	// patterns in internal/billing/{store,endpoints,recovery}.go — those
	// were refactored to two-pass / tx-bound queryers in the same change
	// as this cap so the requestlog + billing shared *sql.DB no longer
	// deadlocks.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	s := &Store{db: db}
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx, `PRAGMA journal_mode=WAL`); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `PRAGMA busy_timeout=5000`); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := s.migrate(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *Store) DB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS request_log (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc               TEXT    NOT NULL,
    request_id           TEXT    NOT NULL,
    external_request_id  TEXT    NULL,
    account_id           TEXT    NULL,
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:48:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:138:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:176:	baseDBPath := filepath.Join(dir, "base.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:177:	overlayDBPath := filepath.Join(dir, "overlay.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:181:	db, err := sql.Open("sqlite", overlayDBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:195:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+baseDBPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:198:	if err := os.WriteFile(overlayPath, []byte("storage:\n  db_path: "+overlayDBPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:217:	if _, err := os.Stat(baseDBPath); !os.IsNotExist(err) {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:218:		t.Fatalf("base db was touched despite overlay storage.db_path: stat err=%v", err)
phase4-coordinator/cmd/coordinator/main.go:230:	tokenStore, err := auth.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:236:	reqLogStore, err := requestlog.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:242:	moneyCheckpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:250:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:258:	routeSnapshotJournalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(routeSnapshotJournalDBPath(cfg.Storage.DBPath)))
phase4-coordinator/cmd/coordinator/main.go:287:	auditStore, err := audit.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:293:	settlementReceiptAuditStore, err := audit.OpenSettlementReceiptStore(audit.DefaultDBPath(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:323:	connectionEventStore, err := providerevents.Open(providerevents.DefaultDBPath(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:436:	startMoneySQLiteWALCheckpointer(shutdownCtx, moneyCheckpointDB, metricsHandle, logger, moneySQLiteActivity, cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:566:		sqlitePath := strings.TrimSpace(cfg.MalibuEmission.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:568:			sqlitePath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:581:			SQLitePayoutDBPath:           sqlitePath,
phase4-coordinator/cmd/coordinator/main.go:976:		if mdaStore, err := mdm.OpenMDAStoreWithManualWALCheckpoint(cfg.Storage.DBPath); err != nil {
phase4-coordinator/cmd/coordinator/main.go:980:			logger.Info().Str("db_path", cfg.Storage.DBPath).Msg("Phase 3 live MDA durable proof store wired")
phase4-coordinator/cmd/coordinator/main.go:990:		relayBlindStore, err = relayblind.OpenStore(cfg.RelayBlind.SQLitePath)
phase4-coordinator/cmd/coordinator/main.go:1436:			Source: referralapi.SQLiteServingEvidence{Path: cfg.Storage.DBPath},
phase4-coordinator/cmd/coordinator/main.go:1843:func routeSnapshotJournalDBPath(dbPath string) string {
phase4-coordinator/cmd/coordinator/main.go:1857:	DBPath         string
phase4-coordinator/cmd/coordinator/main.go:1868:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main.go:2062:	walBytes := sqliteutil.WALFileSize(cfg.DBPath)
phase4-coordinator/cmd/coordinator/main.go:3531:		SQLitePayoutDBPath:           cfg.MalibuEmission.SQLitePayoutDBPath,
phase4-coordinator/cmd/coordinator/main.go:3538:	if rewardsCfg.SQLitePayoutDBPath == "" {
phase4-coordinator/cmd/coordinator/main.go:3539:		rewardsCfg.SQLitePayoutDBPath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:3549:	payoutPath := strings.TrimSpace(rewardsCfg.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:3550:	if payoutPath == "" || sameFilePath(payoutPath, cfg.Storage.DBPath) {
phase4-coordinator/cmd/coordinator/main.go:3564:	readStore, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes.go:69:		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes.go:98:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:80:		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:106:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:230:	tokenStore, err := auth.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:236:	reqLogStore, err := requestlog.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:242:	moneyCheckpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:250:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:258:	routeSnapshotJournalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(routeSnapshotJournalDBPath(cfg.Storage.DBPath)))
phase4-coordinator/cmd/coordinator/main.go:287:	auditStore, err := audit.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:293:	settlementReceiptAuditStore, err := audit.OpenSettlementReceiptStore(audit.DefaultDBPath(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:323:	connectionEventStore, err := providerevents.Open(providerevents.DefaultDBPath(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:436:	startMoneySQLiteWALCheckpointer(shutdownCtx, moneyCheckpointDB, metricsHandle, logger, moneySQLiteActivity, cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:566:		sqlitePath := strings.TrimSpace(cfg.MalibuEmission.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:568:			sqlitePath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:581:			SQLitePayoutDBPath:           sqlitePath,
phase4-coordinator/cmd/coordinator/main.go:976:		if mdaStore, err := mdm.OpenMDAStoreWithManualWALCheckpoint(cfg.Storage.DBPath); err != nil {
phase4-coordinator/cmd/coordinator/main.go:980:			logger.Info().Str("db_path", cfg.Storage.DBPath).Msg("Phase 3 live MDA durable proof store wired")
phase4-coordinator/cmd/coordinator/main.go:990:		relayBlindStore, err = relayblind.OpenStore(cfg.RelayBlind.SQLitePath)
phase4-coordinator/cmd/coordinator/main.go:1436:			Source: referralapi.SQLiteServingEvidence{Path: cfg.Storage.DBPath},
phase4-coordinator/cmd/coordinator/main.go:1843:func routeSnapshotJournalDBPath(dbPath string) string {
phase4-coordinator/cmd/coordinator/main.go:1857:	DBPath         string
phase4-coordinator/cmd/coordinator/main.go:1868:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main.go:2062:	walBytes := sqliteutil.WALFileSize(cfg.DBPath)
phase4-coordinator/cmd/coordinator/main.go:3531:		SQLitePayoutDBPath:           cfg.MalibuEmission.SQLitePayoutDBPath,
phase4-coordinator/cmd/coordinator/main.go:3538:	if rewardsCfg.SQLitePayoutDBPath == "" {
phase4-coordinator/cmd/coordinator/main.go:3539:		rewardsCfg.SQLitePayoutDBPath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:3549:	payoutPath := strings.TrimSpace(rewardsCfg.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:3550:	if payoutPath == "" || sameFilePath(payoutPath, cfg.Storage.DBPath) {
phase4-coordinator/cmd/coordinator/main.go:3564:	readStore, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main_test.go:64:	reqLogStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
phase4-coordinator/cmd/coordinator/main_test.go:254:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:284:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:313:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:350:			DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:508:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:1100:	cfg.Storage.DBPath = "/tmp/provider.sqlite"
phase4-coordinator/cmd/coordinator/main_test.go:1108:	cfg.MalibuEmission.SQLitePayoutDBPath = ""
phase4-coordinator/cmd/coordinator/main_test.go:1119:	if got.SQLitePayoutDBPath != "/tmp/provider.sqlite" {
phase4-coordinator/cmd/coordinator/main_test.go:1120:		t.Fatalf("SQLitePayoutDBPath=%q, want storage fallback", got.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main_test.go:1149:	defaultStore, err := requestlog.OpenStore(defaultPath)
phase4-coordinator/cmd/coordinator/main_test.go:1156:	cfg.Storage.DBPath = defaultPath
phase4-coordinator/cmd/coordinator/main_test.go:1166:	cfg.MalibuEmission.SQLitePayoutDBPath = alternatePath
phase4-coordinator/cmd/coordinator/main_test.go:1183:	defaultStore, err := requestlog.OpenStore(path)
phase4-coordinator/cmd/coordinator/main_test.go:1194:	cfg.Storage.DBPath = path
phase4-coordinator/cmd/coordinator/main_test.go:1477:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/config/config.go:371:	SQLitePayoutDBPath           string   `yaml:"sqlite_payout_db_path"`
phase4-coordinator/internal/config/config.go:1223:	DBPath                   string `yaml:"db_path"`
phase4-coordinator/internal/config/config.go:1600:			DBPath:                   "coordinator.db",

codex
The source wiring is internally consistent so far: the unit now exposes `coordinator.db` plus optional WAL/SHM as read-only, while the mirror opens the same path through the shared `ReadOnlyDSN` (`mode=ro`, `query_only`, bounded busy timeout). The deploy snapshots and grants the same three files, and the recovery helper restores ACL snapshots by their embedded path. I’m now running the existing wiring, recovery, and package tests that cover these paths.
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'go test ./internal/stats/billingmirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'go test ./internal/sqliteutil ./internal/requestlog' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 exited 127 in 309ms:
bash: phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh: No such file or directory

 exited 127 in 397ms:
bash: phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh: No such file or directory

 exited 127 in 550ms:
bash: phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh: No such file or directory

 succeeded in 2041ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	(cached)

exec
/bin/bash -lc 'bash dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash dist/test/coordinator_deploy_recovery.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 854ms:
ok: stats billing mirror deploy wiring

 succeeded in 5968ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.c63mAfla3G: line 1: 17389 Alarm clock: 14         python3 -c '
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

 succeeded in 15820ms:
PASS: coordinator deploy recovery is durable and state-exact

 succeeded in 58208ms:
ok  	github.com/augstar/macprovider-coordinator/internal/sqliteutil	(cached)
ok  	github.com/augstar/macprovider-coordinator/internal/requestlog	55.068s

exec
/bin/bash -lc "nl -ba phase4-coordinator/internal/stats/billingmirror/mirror_test.go | sed -n '1,380p'; printf '\\n--- mirror Run lifecycle ---\\n'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '75,210p;275,430p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
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

--- mirror Run lifecycle ---
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
   301	
   302	type requestCreditSourceCapabilities struct {
   303		HasSettlementPolicyMode         bool
   304		HasSpec022PayableView           bool
   305		HasRequestedPrivacyMode         bool
   306		HasEffectivePrivacyOutcome      bool
   307		HasPositiveVerificationExcluded bool
   308		HasRewardsExcluded              bool
   309	}
   310	
   311	func detectRequestCreditSourceCapabilities(ctx context.Context, db *sql.DB) (requestCreditSourceCapabilities, error) {
   312		hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
   313		if err != nil {
   314			return requestCreditSourceCapabilities{}, err
   315		}
   316		hasPayable, err := sqliteObjectExists(ctx, db, "spec022_payable_request_credits")
   317		if err != nil {
   318			return requestCreditSourceCapabilities{}, err
   319		}
   320		hasRequestedPrivacyMode, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "requested_privacy_mode")
   321		if err != nil {
   322			return requestCreditSourceCapabilities{}, err
   323		}
   324		hasEffectivePrivacyOutcome, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "effective_privacy_outcome")
   325		if err != nil {
   326			return requestCreditSourceCapabilities{}, err
   327		}
   328		hasPositiveVerificationExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "positive_verification_excluded")
   329		if err != nil {
   330			return requestCreditSourceCapabilities{}, err
   331		}
   332		hasRewardsExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "rewards_excluded")
   333		if err != nil {
   334			return requestCreditSourceCapabilities{}, err
   335		}
   336		return requestCreditSourceCapabilities{
   337			HasSettlementPolicyMode:         hasPolicy,
   338			HasSpec022PayableView:           hasPayable,
   339			HasRequestedPrivacyMode:         hasRequestedPrivacyMode,
   340			HasEffectivePrivacyOutcome:      hasEffectivePrivacyOutcome,
   341			HasPositiveVerificationExcluded: hasPositiveVerificationExcluded,
   342			HasRewardsExcluded:              hasRewardsExcluded,
   343		}, nil
   344	}
   345	
   346	func requestCreditsQuery(caps requestCreditSourceCapabilities, bounded bool) string {
   347		policyExpr := "'legacy'"
   348		if caps.HasSettlementPolicyMode {
   349			policyExpr = "COALESCE(lrc.settlement_policy_mode, 'legacy')"
   350		}
   351		verifiedExpr := "0"
   352		if caps.HasSpec022PayableView {
   353			verifiedExpr = fmt.Sprintf(`CASE
   354	           WHEN %s = 'enforce'
   355	            AND EXISTS (SELECT 1 FROM spec022_payable_request_credits payable WHERE payable.id = lrc.id)
   356	           THEN 1 ELSE 0
   357	       END`, policyExpr)
   358		}
   359		requestedPrivacyExpr := "'none'"
   360		if caps.HasRequestedPrivacyMode {
   361			requestedPrivacyExpr = "COALESCE(lrc.requested_privacy_mode, 'none')"
   362		}
   363		effectivePrivacyExpr := "'plaintext'"
   364		if caps.HasEffectivePrivacyOutcome {
   365			effectivePrivacyExpr = "COALESCE(lrc.effective_privacy_outcome, 'plaintext')"
   366		}
   367		positiveExcludedExpr := "0"
   368		if caps.HasPositiveVerificationExcluded {
   369			positiveExcludedExpr = "COALESCE(lrc.positive_verification_excluded, 0)"
   370		}
   371		rewardsExcludedExpr := "0"
   372		if caps.HasRewardsExcluded {
   373			rewardsExcludedExpr = "COALESCE(lrc.rewards_excluded, 0)"
   374		}
   375		where := "WHERE lrc.id > ?"
   376		if bounded {
   377			where += "\n   AND lrc.id <= ?"
   378		}
   379		return fmt.Sprintf(`
   380	SELECT lrc.id, lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.ts_utc, lrc.created_at_utc, lrc.updated_at_utc,
   381	       lrc.prompt_tokens, lrc.completion_tokens, lrc.estimated_completion_tokens, lrc.usage_source,
   382	       lrc.provider_credits, lrc.fault_flag, lrc.quarantined,
   383	       %s AS settlement_policy_mode,
   384	       %s AS spec022_verified,
   385	       %s AS requested_privacy_mode, %s AS effective_privacy_outcome,
   386	       %s AS positive_verification_excluded, %s AS rewards_excluded
   387	  FROM ledger_request_credits lrc
   388	 %s
   389	 ORDER BY lrc.id
   390	 LIMIT ?`, policyExpr, verifiedExpr, requestedPrivacyExpr, effectivePrivacyExpr, positiveExcludedExpr, rewardsExcludedExpr, where)
   391	}
   392	
   393	func sqliteColumnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
   394		rows, err := db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
   395		if err != nil {
   396			return false, fmt.Errorf("inspect sqlite table %s: %w", table, err)
   397		}
   398		defer rows.Close()
   399		for rows.Next() {
   400			var cid int
   401			var name, typ string
   402			var notNull int
   403			var defaultValue sql.NullString
   404			var pk int
   405			if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
   406				return false, err
   407			}
   408			if name == column {
   409				return true, nil
   410			}
   411		}
   412		return false, rows.Err()
   413	}
   414	
   415	func sqliteObjectExists(ctx context.Context, db *sql.DB, name string) (bool, error) {
   416		var exists bool
   417		err := db.QueryRowContext(ctx, `
   418	        SELECT EXISTS (
   419	            SELECT 1 FROM sqlite_master
   420	             WHERE name = ?
   421	               AND type IN ('table', 'view')
   422	        )
   423	    `, name).Scan(&exists)
   424		return exists, err
   425	}
   426	
   427	func scanRequestCredits(ctx context.Context, db *sql.DB, q string, args ...any) ([]RequestCredit, error) {
   428		cur, err := db.QueryContext(ctx, q, args...)
   429		if err != nil {
   430			return nil, fmt.Errorf("select ledger_request_credits: %w", err)

exec
/bin/bash -lc "printf '%s\\n' '--- current former-path references in reviewed files ---'; rg -n 'request-log\\.sqlite' phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/internal/stats/billingmirror/mirror.go phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh || true; printf '%s\\n' '--- old/new path lines in diff ---'; git diff -U0 1148185e..ee061fc3 -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/internal/stats/billingmirror/mirror.go phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh | rg '"'^[+-].*(request-log'"\\.sqlite|coordinator\\.db|InaccessiblePaths|ReadOnlyPaths|snapshot_acl|restore_acl|setfacl|test -r)'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
--- current former-path references in reviewed files ---
--- old/new path lines in diff ---
-	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/request-log.sqlite")
+	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
-    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
-    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
-  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
+    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
+    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
+    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
+  elif [ -f /var/lib/macprovider/coordinator.db ]; then
-  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
+  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
-ConditionPathExists=/var/lib/macprovider/request-log.sqlite
+ConditionPathExists=/var/lib/macprovider/coordinator.db
-ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false
+ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
-ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite
-ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-wal
-ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-shm
+ReadOnlyPaths=/var/lib/macprovider/coordinator.db
+ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
+ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
-InaccessiblePaths=-/var/lib/macprovider/coordinator.db
-grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
+grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
-grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" ||
+grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
-grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats' "$DEPLOY_SH" ||
+grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
-grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ]' "$DEPLOY_SH" ||
+grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
-grep -qxF 'ConditionPathExists=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
+grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
-grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false' "$SERVICE" ||
+grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
-grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
+grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
+# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
+if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
+  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
-	DefaultSQLitePath  = "/var/lib/macprovider/request-log.sqlite"
+	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"

exec
/bin/bash -lc "rg -n -C 8 'ReadOnlyDSN|query_only|read-only|read only|WAL|concurrent|SQLITE_BUSY' phase4-coordinator/internal/sqliteutil/*_test.go phase4-coordinator/internal/requestlog/*_test.go phase4-coordinator/internal/stats/billingmirror/*_test.go | sed -n '1,500p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/internal/requestlog/store_test.go-453-	if err := store.db.QueryRowContext(context.Background(), `PRAGMA wal_autocheckpoint`).Scan(&got); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-454-		t.Fatalf("PRAGMA wal_autocheckpoint: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-455-	}
phase4-coordinator/internal/requestlog/store_test.go-456-	if got == 0 {
phase4-coordinator/internal/requestlog/store_test.go-457-		t.Fatal("request log store disabled wal_autocheckpoint without an explicit checkpoint owner")
phase4-coordinator/internal/requestlog/store_test.go-458-	}
phase4-coordinator/internal/requestlog/store_test.go-459-}
phase4-coordinator/internal/requestlog/store_test.go-460-
phase4-coordinator/internal/requestlog/store_test.go:461:func TestOpenStoreWithManualWALCheckpointAppliesSQLitePragmasViaDSN(t *testing.T) {
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go-463-	if err != nil {
phase4-coordinator/internal/requestlog/store_test.go-464-		t.Fatal(err)
phase4-coordinator/internal/requestlog/store_test.go-465-	}
phase4-coordinator/internal/requestlog/store_test.go-466-	defer store.Close()
phase4-coordinator/internal/requestlog/store_test.go-467-	ctx := context.Background()
phase4-coordinator/internal/requestlog/store_test.go-468-	for _, tc := range []struct {
phase4-coordinator/internal/requestlog/store_test.go-469-		query string
phase4-coordinator/internal/requestlog/store_test.go-470-		want  int
--
phase4-coordinator/internal/requestlog/store_test.go-751-	}
phase4-coordinator/internal/requestlog/store_test.go-752-	if olderLeft != 0 {
phase4-coordinator/internal/requestlog/store_test.go-753-		t.Fatalf("rows older than cutoff still present: %d", olderLeft)
phase4-coordinator/internal/requestlog/store_test.go-754-	}
phase4-coordinator/internal/requestlog/store_test.go-755-}
phase4-coordinator/internal/requestlog/store_test.go-756-
phase4-coordinator/internal/requestlog/store_test.go-757-// TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert runs PruneBefore
phase4-coordinator/internal/requestlog/store_test.go-758-// against a backlog while a writer goroutine inserts fresh rows. Both
phase4-coordinator/internal/requestlog/store_test.go:759:// must complete without SQLITE_BUSY — the batched DELETE keeps the
phase4-coordinator/internal/requestlog/store_test.go-760-// write lock short enough that the writer's busy_timeout absorbs each
phase4-coordinator/internal/requestlog/store_test.go-761-// release. Regression guard for M3-1: a single multi-second DELETE
phase4-coordinator/internal/requestlog/store_test.go-762-// would exceed busy_timeout under contention.
phase4-coordinator/internal/requestlog/store_test.go-763-func TestPruneBeforeNoSQLiteBusyUnderConcurrentInsert(t *testing.T) {
phase4-coordinator/internal/requestlog/store_test.go-764-	store := openTestStore(t)
phase4-coordinator/internal/requestlog/store_test.go-765-	defer store.Close()
phase4-coordinator/internal/requestlog/store_test.go-766-	ctx := context.Background()
phase4-coordinator/internal/requestlog/store_test.go-767-	cutoff := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
--
phase4-coordinator/internal/requestlog/store_test.go-781-			select {
phase4-coordinator/internal/requestlog/store_test.go-782-			case <-stop:
phase4-coordinator/internal/requestlog/store_test.go-783-				writerErr <- nil
phase4-coordinator/internal/requestlog/store_test.go-784-				return
phase4-coordinator/internal/requestlog/store_test.go-785-			default:
phase4-coordinator/internal/requestlog/store_test.go-786-			}
phase4-coordinator/internal/requestlog/store_test.go-787-			ts := base.Add(time.Duration(i) * time.Millisecond)
phase4-coordinator/internal/requestlog/store_test.go-788-			if err := store.Insert(ctx, Row{TSUtc: ts, RequestID: "w", Model: "m", Status: 200, BuyerIP: "1"}); err != nil {
phase4-coordinator/internal/requestlog/store_test.go:789:				if strings.Contains(err.Error(), "SQLITE_BUSY") || strings.Contains(err.Error(), "database is locked") {
phase4-coordinator/internal/requestlog/store_test.go-790-					writerErr <- err
phase4-coordinator/internal/requestlog/store_test.go-791-					return
phase4-coordinator/internal/requestlog/store_test.go-792-				}
phase4-coordinator/internal/requestlog/store_test.go-793-				writerErr <- err
phase4-coordinator/internal/requestlog/store_test.go-794-				return
phase4-coordinator/internal/requestlog/store_test.go-795-			}
phase4-coordinator/internal/requestlog/store_test.go-796-		}
phase4-coordinator/internal/requestlog/store_test.go-797-	}()
phase4-coordinator/internal/requestlog/store_test.go-798-
phase4-coordinator/internal/requestlog/store_test.go-799-	if _, err := store.PruneBefore(ctx, cutoff); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-800-		close(stop)
phase4-coordinator/internal/requestlog/store_test.go-801-		<-writerErr
phase4-coordinator/internal/requestlog/store_test.go:802:		if strings.Contains(err.Error(), "SQLITE_BUSY") || strings.Contains(err.Error(), "database is locked") {
phase4-coordinator/internal/requestlog/store_test.go-803-			t.Fatalf("PruneBefore hit lock contention: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-804-		}
phase4-coordinator/internal/requestlog/store_test.go-805-		t.Fatalf("PruneBefore: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-806-	}
phase4-coordinator/internal/requestlog/store_test.go-807-	close(stop)
phase4-coordinator/internal/requestlog/store_test.go-808-	if err := <-writerErr; err != nil {
phase4-coordinator/internal/requestlog/store_test.go:809:		t.Fatalf("concurrent writer: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-810-	}
phase4-coordinator/internal/requestlog/store_test.go-811-}
phase4-coordinator/internal/requestlog/store_test.go-812-
phase4-coordinator/internal/requestlog/store_test.go-813-// TestPruneBeforeUsesTsUtcIndex pins the DELETE's plan to the
phase4-coordinator/internal/requestlog/store_test.go-814-// idx_request_log_ts_utc index via EXPLAIN QUERY PLAN. A regression that
phase4-coordinator/internal/requestlog/store_test.go-815-// drops the index or rewrites the WHERE clause so the planner falls
phase4-coordinator/internal/requestlog/store_test.go-816-// back to a SCAN of request_log would break this assertion.
phase4-coordinator/internal/requestlog/store_test.go-817-func TestPruneBeforeUsesTsUtcIndex(t *testing.T) {
--
phase4-coordinator/internal/requestlog/store_test.go-1207-			}); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-1208-				errCh <- err
phase4-coordinator/internal/requestlog/store_test.go-1209-			}
phase4-coordinator/internal/requestlog/store_test.go-1210-		}(i)
phase4-coordinator/internal/requestlog/store_test.go-1211-	}
phase4-coordinator/internal/requestlog/store_test.go-1212-	wg.Wait()
phase4-coordinator/internal/requestlog/store_test.go-1213-	close(errCh)
phase4-coordinator/internal/requestlog/store_test.go-1214-	for err := range errCh {
phase4-coordinator/internal/requestlog/store_test.go:1215:		t.Fatalf("concurrent insert: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-1216-	}
phase4-coordinator/internal/requestlog/store_test.go-1217-
phase4-coordinator/internal/requestlog/store_test.go-1218-	// Every row in the group MUST have a distinct attempt_n in the
phase4-coordinator/internal/requestlog/store_test.go-1219-	// range [0, N-1]. If the race were present, two rows would share
phase4-coordinator/internal/requestlog/store_test.go-1220-	// the same attempt_n.
phase4-coordinator/internal/requestlog/store_test.go-1221-	rows, err := store.db.QueryContext(ctx, `SELECT attempt_n FROM request_log WHERE request_id='req-race' ORDER BY attempt_n`)
phase4-coordinator/internal/requestlog/store_test.go-1222-	if err != nil {
phase4-coordinator/internal/requestlog/store_test.go-1223-		t.Fatalf("query: %v", err)
--
phase4-coordinator/internal/requestlog/store_test.go-1225-	defer rows.Close()
phase4-coordinator/internal/requestlog/store_test.go-1226-	seen := map[int]bool{}
phase4-coordinator/internal/requestlog/store_test.go-1227-	for rows.Next() {
phase4-coordinator/internal/requestlog/store_test.go-1228-		var n sql.NullInt64
phase4-coordinator/internal/requestlog/store_test.go-1229-		if err := rows.Scan(&n); err != nil {
phase4-coordinator/internal/requestlog/store_test.go-1230-			t.Fatalf("scan: %v", err)
phase4-coordinator/internal/requestlog/store_test.go-1231-		}
phase4-coordinator/internal/requestlog/store_test.go-1232-		if !n.Valid {
phase4-coordinator/internal/requestlog/store_test.go:1233:			t.Fatalf("attempt_n NULL on concurrent insert")
phase4-coordinator/internal/requestlog/store_test.go-1234-		}
phase4-coordinator/internal/requestlog/store_test.go-1235-		v := int(n.Int64)
phase4-coordinator/internal/requestlog/store_test.go-1236-		if seen[v] {
phase4-coordinator/internal/requestlog/store_test.go:1237:			t.Fatalf("duplicate attempt_n=%d under concurrent insert (race not closed)", v)
phase4-coordinator/internal/requestlog/store_test.go-1238-		}
phase4-coordinator/internal/requestlog/store_test.go-1239-		seen[v] = true
phase4-coordinator/internal/requestlog/store_test.go-1240-	}
phase4-coordinator/internal/requestlog/store_test.go-1241-	if len(seen) != N {
phase4-coordinator/internal/requestlog/store_test.go-1242-		t.Fatalf("got %d distinct attempt_n values; want %d (rows missing)", len(seen), N)
phase4-coordinator/internal/requestlog/store_test.go-1243-	}
phase4-coordinator/internal/requestlog/store_test.go-1244-	for i := 0; i < N; i++ {
phase4-coordinator/internal/requestlog/store_test.go-1245-		if !seen[i] {
phase4-coordinator/internal/requestlog/store_test.go:1246:			t.Fatalf("attempt_n=%d missing from concurrent insert results", i)
phase4-coordinator/internal/requestlog/store_test.go-1247-		}
phase4-coordinator/internal/requestlog/store_test.go-1248-	}
phase4-coordinator/internal/requestlog/store_test.go-1249-}
phase4-coordinator/internal/requestlog/store_test.go-1250-
phase4-coordinator/internal/requestlog/store_test.go-1251-func slicesEqualInt(a, b []int) bool {
phase4-coordinator/internal/requestlog/store_test.go-1252-	if len(a) != len(b) {
phase4-coordinator/internal/requestlog/store_test.go-1253-		return false
phase4-coordinator/internal/requestlog/store_test.go-1254-	}
--
phase4-coordinator/internal/sqliteutil/wal_test.go-8-	"strings"
phase4-coordinator/internal/sqliteutil/wal_test.go-9-	"testing"
phase4-coordinator/internal/sqliteutil/wal_test.go-10-	"time"
phase4-coordinator/internal/sqliteutil/wal_test.go-11-)
phase4-coordinator/internal/sqliteutil/wal_test.go-12-
phase4-coordinator/internal/sqliteutil/wal_test.go-13-func openManualCheckpointDB(t *testing.T) (dbPath string, db *sql.DB) {
phase4-coordinator/internal/sqliteutil/wal_test.go-14-	t.Helper()
phase4-coordinator/internal/sqliteutil/wal_test.go-15-	dbPath = filepath.Join(t.TempDir(), "checkpoint.db")
phase4-coordinator/internal/sqliteutil/wal_test.go:16:	db, err := sql.Open("sqlite", WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/sqliteutil/wal_test.go-17-	if err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-18-		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-19-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-20-	t.Cleanup(func() { _ = db.Close() })
phase4-coordinator/internal/sqliteutil/wal_test.go-21-	db.SetMaxOpenConns(1)
phase4-coordinator/internal/sqliteutil/wal_test.go-22-	db.SetMaxIdleConns(1)
phase4-coordinator/internal/sqliteutil/wal_test.go-23-	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-24-		t.Fatalf("create table: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-25-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-26-	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a'), ('b'), ('c')`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-27-		t.Fatalf("insert: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-28-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-29-	return dbPath, db
phase4-coordinator/internal/sqliteutil/wal_test.go-30-}
phase4-coordinator/internal/sqliteutil/wal_test.go-31-
phase4-coordinator/internal/sqliteutil/wal_test.go:32:func TestRunWALCheckpointModeTruncateShrinksWAL(t *testing.T) {
phase4-coordinator/internal/sqliteutil/wal_test.go-33-	dbPath, db := openManualCheckpointDB(t)
phase4-coordinator/internal/sqliteutil/wal_test.go:34:	if size := WALFileSize(dbPath); size == 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go:35:		t.Fatal("WAL size before TRUNCATE = 0, want growth from inserts")
phase4-coordinator/internal/sqliteutil/wal_test.go-36-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-37-
phase4-coordinator/internal/sqliteutil/wal_test.go-38-	observer := &testObserver{}
phase4-coordinator/internal/sqliteutil/wal_test.go:39:	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, WALCheckpointTruncate)
phase4-coordinator/internal/sqliteutil/wal_test.go-40-	if err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-41-		t.Fatalf("TRUNCATE checkpoint: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-42-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-43-	if result.Busy != 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go-44-		t.Fatalf("TRUNCATE busy=%d want 0", result.Busy)
phase4-coordinator/internal/sqliteutil/wal_test.go-45-	}
phase4-coordinator/internal/sqliteutil/wal_test.go:46:	assertWALObservations(t, observer)
phase4-coordinator/internal/sqliteutil/wal_test.go:47:	if size := WALFileSize(dbPath); size != 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go:48:		t.Fatalf("WAL size after TRUNCATE=%d want 0", size)
phase4-coordinator/internal/sqliteutil/wal_test.go-49-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-50-}
phase4-coordinator/internal/sqliteutil/wal_test.go-51-
phase4-coordinator/internal/sqliteutil/wal_test.go:52:func TestRunWALCheckpointModePassiveIsValid(t *testing.T) {
phase4-coordinator/internal/sqliteutil/wal_test.go-53-	dbPath, db := openManualCheckpointDB(t)
phase4-coordinator/internal/sqliteutil/wal_test.go-54-	observer := &testObserver{}
phase4-coordinator/internal/sqliteutil/wal_test.go:55:	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, WALCheckpointPassive)
phase4-coordinator/internal/sqliteutil/wal_test.go-56-	if err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-57-		t.Fatalf("PASSIVE checkpoint: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-58-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-59-	if result.LogPages < 0 || result.CheckpointedPages < 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go-60-		t.Fatalf("PASSIVE result = %+v, want non-negative pages", result)
phase4-coordinator/internal/sqliteutil/wal_test.go-61-	}
phase4-coordinator/internal/sqliteutil/wal_test.go:62:	assertWALObservations(t, observer)
phase4-coordinator/internal/sqliteutil/wal_test.go-63-	if _, err := os.Stat(dbPath); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-64-		t.Fatalf("db missing after PASSIVE: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-65-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-66-}
phase4-coordinator/internal/sqliteutil/wal_test.go-67-
phase4-coordinator/internal/sqliteutil/wal_test.go:68:func TestRunWALCheckpointModeRejectsInvalidMode(t *testing.T) {
phase4-coordinator/internal/sqliteutil/wal_test.go-69-	_, db := openManualCheckpointDB(t)
phase4-coordinator/internal/sqliteutil/wal_test.go:70:	for _, mode := range []WALCheckpointMode{
phase4-coordinator/internal/sqliteutil/wal_test.go-71-		"RESTART",
phase4-coordinator/internal/sqliteutil/wal_test.go-72-		"TRUNCATE); DROP TABLE t; --",
phase4-coordinator/internal/sqliteutil/wal_test.go-73-	} {
phase4-coordinator/internal/sqliteutil/wal_test.go-74-		observer := &testObserver{}
phase4-coordinator/internal/sqliteutil/wal_test.go:75:		result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", observer, mode)
phase4-coordinator/internal/sqliteutil/wal_test.go-76-		if err == nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-77-			t.Fatalf("mode %q returned nil error", mode)
phase4-coordinator/internal/sqliteutil/wal_test.go-78-		}
phase4-coordinator/internal/sqliteutil/wal_test.go-79-		if !strings.Contains(err.Error(), "unsupported wal checkpoint mode") {
phase4-coordinator/internal/sqliteutil/wal_test.go-80-			t.Fatalf("mode %q error = %v, want unsupported", mode, err)
phase4-coordinator/internal/sqliteutil/wal_test.go-81-		}
phase4-coordinator/internal/sqliteutil/wal_test.go:82:		if result != (WALCheckpointResult{}) {
phase4-coordinator/internal/sqliteutil/wal_test.go-83-			t.Fatalf("mode %q result = %+v, want zero value", mode, result)
phase4-coordinator/internal/sqliteutil/wal_test.go-84-		}
phase4-coordinator/internal/sqliteutil/wal_test.go-85-		if len(observer.events) != 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go-86-			t.Fatalf("mode %q emitted observations: %+v", mode, observer.events)
phase4-coordinator/internal/sqliteutil/wal_test.go-87-		}
phase4-coordinator/internal/sqliteutil/wal_test.go-88-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-89-	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('still-there')`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-90-		t.Fatalf("table t should still exist after rejected mode: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-91-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-92-}
phase4-coordinator/internal/sqliteutil/wal_test.go-93-
phase4-coordinator/internal/sqliteutil/wal_test.go:94:func TestWALFileSizeMissingIsZero(t *testing.T) {
phase4-coordinator/internal/sqliteutil/wal_test.go:95:	if got := WALFileSize(filepath.Join(t.TempDir(), "missing.db")); got != 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go:96:		t.Fatalf("WALFileSize(missing)=%d want 0", got)
phase4-coordinator/internal/sqliteutil/wal_test.go-97-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-98-}
phase4-coordinator/internal/sqliteutil/wal_test.go-99-
phase4-coordinator/internal/sqliteutil/wal_test.go-100-func TestSetBusyTimeout(t *testing.T) {
phase4-coordinator/internal/sqliteutil/wal_test.go-101-	_, db := openManualCheckpointDB(t)
phase4-coordinator/internal/sqliteutil/wal_test.go-102-	if err := SetBusyTimeout(context.Background(), db, 15*time.Second); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-103-		t.Fatalf("SetBusyTimeout: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-104-	}
--
phase4-coordinator/internal/sqliteutil/wal_test.go-131-	if !rows.Next() {
phase4-coordinator/internal/sqliteutil/wal_test.go-132-		t.Fatal("reader select returned no rows")
phase4-coordinator/internal/sqliteutil/wal_test.go-133-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-134-
phase4-coordinator/internal/sqliteutil/wal_test.go-135-	if err := SetBusyTimeout(context.Background(), db, 50*time.Millisecond); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-136-		t.Fatalf("SetBusyTimeout: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-137-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-138-	started := time.Now()
phase4-coordinator/internal/sqliteutil/wal_test.go:139:	result, err := RunWALCheckpointMode(context.Background(), db, "wal_checkpoint", nil, WALCheckpointTruncate)
phase4-coordinator/internal/sqliteutil/wal_test.go-140-	elapsed := time.Since(started)
phase4-coordinator/internal/sqliteutil/wal_test.go-141-	if err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go-142-		t.Fatalf("TRUNCATE with held reader: %v", err)
phase4-coordinator/internal/sqliteutil/wal_test.go-143-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-144-	if result.Busy == 0 {
phase4-coordinator/internal/sqliteutil/wal_test.go-145-		t.Fatal("TRUNCATE busy=0 with held reader, want busy!=0")
phase4-coordinator/internal/sqliteutil/wal_test.go-146-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-147-	if elapsed > time.Second {
phase4-coordinator/internal/sqliteutil/wal_test.go-148-		t.Fatalf("TRUNCATE waited %s, want ~50ms busy_timeout not the 5s DSN default", elapsed)
phase4-coordinator/internal/sqliteutil/wal_test.go-149-	}
phase4-coordinator/internal/sqliteutil/wal_test.go-150-}
phase4-coordinator/internal/sqliteutil/wal_test.go-151-
phase4-coordinator/internal/sqliteutil/wal_test.go:152:func assertWALObservations(t *testing.T, observer *testObserver) {
phase4-coordinator/internal/sqliteutil/wal_test.go-153-	t.Helper()
phase4-coordinator/internal/sqliteutil/wal_test.go-154-	assertObserved(t, observer.events, observedEvent{kind: "wal:busy", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/wal_test.go-155-	assertObserved(t, observer.events, observedEvent{kind: "wal:log", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/wal_test.go-156-	assertObserved(t, observer.events, observedEvent{kind: "wal:checkpointed", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/wal_test.go-157-	assertObserved(t, observer.events, observedEvent{kind: "wal_duration", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/wal_test.go-158-}
--
phase4-coordinator/internal/sqliteutil/transact_test.go-24-func (o *testObserver) ObserveSQLiteConnectionWait(component, outcome string, _ time.Duration) {
phase4-coordinator/internal/sqliteutil/transact_test.go-25-	o.events = append(o.events, observedEvent{kind: "conn", component: component, outcome: outcome})
phase4-coordinator/internal/sqliteutil/transact_test.go-26-}
phase4-coordinator/internal/sqliteutil/transact_test.go-27-
phase4-coordinator/internal/sqliteutil/transact_test.go-28-func (o *testObserver) ObserveSQLiteTransactionDuration(component, outcome string, _ time.Duration) {
phase4-coordinator/internal/sqliteutil/transact_test.go-29-	o.events = append(o.events, observedEvent{kind: "tx", component: component, outcome: outcome})
phase4-coordinator/internal/sqliteutil/transact_test.go-30-}
phase4-coordinator/internal/sqliteutil/transact_test.go-31-
phase4-coordinator/internal/sqliteutil/transact_test.go:32:func (o *testObserver) ObserveSQLiteWALCheckpoint(component, pageClass, outcome string, _ int64) {
phase4-coordinator/internal/sqliteutil/transact_test.go-33-	o.events = append(o.events, observedEvent{kind: "wal:" + pageClass, component: component, outcome: outcome})
phase4-coordinator/internal/sqliteutil/transact_test.go-34-}
phase4-coordinator/internal/sqliteutil/transact_test.go-35-
phase4-coordinator/internal/sqliteutil/transact_test.go:36:func (o *testObserver) ObserveSQLiteWALCheckpointDuration(component, outcome string, _ time.Duration) {
phase4-coordinator/internal/sqliteutil/transact_test.go-37-	o.events = append(o.events, observedEvent{kind: "wal_duration", component: component, outcome: outcome})
phase4-coordinator/internal/sqliteutil/transact_test.go-38-}
phase4-coordinator/internal/sqliteutil/transact_test.go-39-
phase4-coordinator/internal/sqliteutil/transact_test.go-40-func openTestDB(t *testing.T) *sql.DB {
phase4-coordinator/internal/sqliteutil/transact_test.go-41-	t.Helper()
phase4-coordinator/internal/sqliteutil/transact_test.go-42-	db, err := sql.Open("sqlite", ":memory:")
phase4-coordinator/internal/sqliteutil/transact_test.go-43-	if err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go-44-		t.Fatalf("open sqlite: %v", err)
--
phase4-coordinator/internal/sqliteutil/transact_test.go-162-		t.Fatalf("TransactObserved returned %v, want sentinel", err)
phase4-coordinator/internal/sqliteutil/transact_test.go-163-	}
phase4-coordinator/internal/sqliteutil/transact_test.go-164-
phase4-coordinator/internal/sqliteutil/transact_test.go-165-	assertObserved(t, observer.events, observedEvent{kind: "conn", component: "billing_hot_path", outcome: "success"})
phase4-coordinator/internal/sqliteutil/transact_test.go-166-	assertObserved(t, observer.events, observedEvent{kind: "tx", component: "billing_hot_path", outcome: "success"})
phase4-coordinator/internal/sqliteutil/transact_test.go-167-	assertObserved(t, observer.events, observedEvent{kind: "tx", component: "billing_hot_path", outcome: "error"})
phase4-coordinator/internal/sqliteutil/transact_test.go-168-}
phase4-coordinator/internal/sqliteutil/transact_test.go-169-
phase4-coordinator/internal/sqliteutil/transact_test.go:170:func TestRunWALCheckpointEmitsPageClasses(t *testing.T) {
phase4-coordinator/internal/sqliteutil/transact_test.go-171-	dbPath := t.TempDir() + "/checkpoint.db"
phase4-coordinator/internal/sqliteutil/transact_test.go:172:	db, err := sql.Open("sqlite", WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/sqliteutil/transact_test.go-173-	if err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go-174-		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/sqliteutil/transact_test.go-175-	}
phase4-coordinator/internal/sqliteutil/transact_test.go-176-	t.Cleanup(func() { _ = db.Close() })
phase4-coordinator/internal/sqliteutil/transact_test.go-177-	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go-178-		t.Fatalf("create table: %v", err)
phase4-coordinator/internal/sqliteutil/transact_test.go-179-	}
phase4-coordinator/internal/sqliteutil/transact_test.go-180-	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a')`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go-181-		t.Fatalf("insert: %v", err)
phase4-coordinator/internal/sqliteutil/transact_test.go-182-	}
phase4-coordinator/internal/sqliteutil/transact_test.go-183-
phase4-coordinator/internal/sqliteutil/transact_test.go-184-	observer := &testObserver{}
phase4-coordinator/internal/sqliteutil/transact_test.go:185:	if err := RunWALCheckpoint(context.Background(), db, "wal_checkpoint", observer); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go:186:		t.Fatalf("RunWALCheckpoint returned err: %v", err)
phase4-coordinator/internal/sqliteutil/transact_test.go-187-	}
phase4-coordinator/internal/sqliteutil/transact_test.go-188-
phase4-coordinator/internal/sqliteutil/transact_test.go-189-	assertObserved(t, observer.events, observedEvent{kind: "wal:busy", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/transact_test.go-190-	assertObserved(t, observer.events, observedEvent{kind: "wal:log", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/transact_test.go-191-	assertObserved(t, observer.events, observedEvent{kind: "wal:checkpointed", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/transact_test.go-192-	assertObserved(t, observer.events, observedEvent{kind: "wal_duration", component: "wal_checkpoint", outcome: "success"})
phase4-coordinator/internal/sqliteutil/transact_test.go-193-	if info, err := os.Stat(dbPath + "-wal"); err == nil && info.Size() != 0 {
phase4-coordinator/internal/sqliteutil/transact_test.go:194:		t.Fatalf("WAL size after TRUNCATE checkpoint=%d want 0", info.Size())
phase4-coordinator/internal/sqliteutil/transact_test.go-195-	}
phase4-coordinator/internal/sqliteutil/transact_test.go-196-}
phase4-coordinator/internal/sqliteutil/transact_test.go-197-
phase4-coordinator/internal/sqliteutil/transact_test.go-198-func assertObserved(t *testing.T, events []observedEvent, want observedEvent) {
phase4-coordinator/internal/sqliteutil/transact_test.go-199-	t.Helper()
phase4-coordinator/internal/sqliteutil/transact_test.go-200-	for _, got := range events {
phase4-coordinator/internal/sqliteutil/transact_test.go-201-		if got == want {
phase4-coordinator/internal/sqliteutil/transact_test.go-202-			return

collab: Wait
exec
/bin/bash -lc 'go test ./cmd/stats-billing-mirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'go test -count=1 ./internal/stats/billingmirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 588ms:
?   	github.com/augstar/macprovider-coordinator/cmd/stats-billing-mirror	[no test files]

 succeeded in 2253ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	0.820s

codex
CODE lane review completed for `1148185e..ee061fc3`.

No CRITICAL, HIGH, or MEDIUM findings.

Verified:

- All production paths use `coordinator.db`, including ACL snapshots/grants and start guards.
- Rollback ACL restoration remains covered via `coordinator-deploy-recover.sh:229-232`.
- WAL/SHM read-only paths are present in `stats-billing-mirror.service:23-25`.
- The source DB is no longer inaccessible (`stats-billing-mirror.service:26-27`).
- Mirror access uses `ReadOnlyDSN` with `mode=ro`, `query_only`, and busy timeout (`mirror.go:253-260`).
- Existing wiring, rollback, Go tests, and `git diff --check` passed.

Counts: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

VERDICT: PASS
tokens used
123 537

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
