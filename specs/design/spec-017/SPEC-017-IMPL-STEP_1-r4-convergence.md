# SPEC-017 IMPL Step 1 — convergence (Round 4)

All three codex audit lanes locked at **0 CRITICAL + 0 HIGH +
0 MEDIUM** in round 4 per the BUILD §2.1 convergence gate.

PR: [Augustas11/macprovider#173](https://github.com/Augustas11/macprovider/pull/173)
HEAD at convergence: `00c5301` (impl/spec-017-step-1)
SPEC version: v0.1.8 LOCKED on `e816dff`

## Lane verdicts

| Lane | r1 | r2 | r3 | r4 |
|---|---|---|---|---|
| ARCH | 0C / 3H / 0M (NEEDS FIX) | 0C / 1H / 0M (NEEDS FIX) | 0C / 0H / 1M (NEEDS FIX) | **0 / 0 / 0 — READY TO LOCK** |
| CODE | 1C / 3H / 0M (NEEDS FIX) | 0C / 1H / 0M (NEEDS FIX) | 0C / 1H / 0M (NEEDS FIX) | **0 / 0 / 0 — READY TO LOCK** |
| SECURITY | 2C / 1H / 2M / 1I (NEEDS FIX) | 0C / 1H / 0M / 1I (NEEDS FIX) | 0C / 1H / 0M / 1I (NEEDS FIX) | **0 / 0 / 0 / 1I — READY TO LOCK** |

Round files:

- ARCH: [r1](SPEC-017-IMPL-STEP_1-arch-r1-audit.md), [r2](SPEC-017-IMPL-STEP_1-arch-r2-audit.md), [r3](SPEC-017-IMPL-STEP_1-arch-r3-audit.md), [r4](SPEC-017-IMPL-STEP_1-arch-r4-audit.md)
- CODE: [r1](SPEC-017-IMPL-STEP_1-code-r1-audit.md), [r2](SPEC-017-IMPL-STEP_1-code-r2-audit.md), [r3](SPEC-017-IMPL-STEP_1-code-r3-audit.md), [r4](SPEC-017-IMPL-STEP_1-code-r4-audit.md)
- SECURITY: [r1](SPEC-017-IMPL-STEP_1-security-r1-audit.md), [r2](SPEC-017-IMPL-STEP_1-security-r2-audit.md), [r3](SPEC-017-IMPL-STEP_1-security-r3-audit.md), [r4](SPEC-017-IMPL-STEP_1-security-r4-audit.md)

## Findings absorbed (r1 + r2 + r3) — fix-pass summary

### Round 1 (3 CRITICAL + 6 HIGH + 2 MEDIUM)
- **CRITICAL — migration runner race condition** (CODE r1 C1): added `pg_advisory_lock(5179378192876502983)` held on one conn for full `Apply` duration; `TestMigrationsConcurrent` proves no duplicate rows under parallel runs. Commit `0b3e87b`.
- **CRITICAL — committed runtime-role password literal** (SECURITY r1 CRIT-1): roles now created `NOLOGIN` with no password; deploy automation rotates via `ALTER ROLE LOGIN PASSWORD`. `TestNoLoginRoleDefault` verifies. Commit `0b3e87b`.
- **CRITICAL — boot-time migrations via `stats_rollup`** (SECURITY r1 CRIT-2 + CODE r1 HIGH C2 + ARCH r1 HIGH C1): removed entirely from coordinator boot; migrations are operator-side. Commit `0b3e87b`.
- **HIGH — startup smoke too thin** (ARCH r1 HIGH C2 + CODE r1 HIGH D1): smoke now asserts `current_user` per pool + role-distinct check + positive probe + deny-list probe. Commit `0b3e87b`.
- **HIGH — REVOKE FROM PUBLIC missing** (CODE r1 HIGH B1): added `REVOKE ALL ON SCHEMA public FROM PUBLIC` + tables/sequences/functions. Commit `0b3e87b`.
- **HIGH — AC-16 fixture test never runs in CI** (ARCH r1 HIGH E): `coordinator-lint` CI job now runs `TestAC16ForbiddenImportFails|TestForbidigoOSExitRule` after installing golangci-lint. Commit `0b3e87b`.
- **HIGH — trust-source decision not recorded** (SECURITY r1 HIGH 1): durable record at `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; PR body cross-links. Commit `21d3c2a` (file landed; round 1 tool-call parameter error had left it out) + PR #173 body.
- **MEDIUM — stats DSNs not env-resolved** (SECURITY r1 MED-1): `resolveEnv` now covers the 5 stats DSN fields. Commit `0b3e87b`.
- **MEDIUM — Postgres image not digest-pinned** (SECURITY r1 MED-2): pinned to `@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c`. Commit `0b3e87b`.

### Round 2 (2 HIGH)
- **HIGH — `.golangci.yml` v1/v2 schema mismatch** (ARCH r2 HIGH D + CODE r2 HIGH E1): rewrote to golangci-lint v2 schema (`version: "2"`, `linters.settings`, anchored forbidigo regexes, `linters.exclusions`); pinned binary updated from non-existent `v1.62.2` to `v2.12.2`. Commit `21d3c2a`.
- **HIGH — trust-source decision file missing** (SECURITY r2 HIGH 1): file lost during round-1 commit due to a malformed tool-call parameter; landed in this round. Commit `21d3c2a`.

### Round 3 (1 HIGH + 1 MEDIUM)
- **HIGH — invalid golangci-lint v2 module path** (CODE r3 HIGH E1): round-2 global s/v1/v2/ produced the bad path `…/cmd/golangci-lint/v2/cmd/golangci-lint`; corrected to `github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2`. Commit `00c5301`.
- **MEDIUM — rollup depguard missing `internal/auth` deny** (ARCH r3 MEDIUM D): added; the request-path rule already had it. Commit `00c5301`.
- **HIGH — trust-source decision not in PR body** (SECURITY r3 HIGH 1): addressed by opening draft PR #173 with the decision section in the body. SECURITY r4 verified via `gh pr view 173`.

## Deferred (INFO — explicitly NOT a Step 1 blocker)

- **OPS.md partner_keys backup runbook entry** (SECURITY r1/r2/r3/r4 INFO 1): naturally scoped to Step 4.C (`OPS.md` partner-key issuance runbook). The Step 4.C PR will document Postgres backup coverage of SPEC-017 tables (especially `partner_keys`) with restore/retention expectations.

## Verification at convergence

- `make vet-coordinator` — PASS
- `make test-coordinator` — PASS (unit + skipped integration without Docker)
- `make lint-coordinator` (golangci-lint v2.12.2) — PASS, `0 issues`
- `golangci-lint config verify --config=.golangci.yml` — PASS
- `go test -count=1 -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule' ./internal/stats/` — PASS (depguard + forbidigo fixture diagnostics fire by name with the `linttest_fixture` build tag)
- `make test-coordinator-integration` — runs in CI on the unconditional `coordinator-stats-integration` job (ubuntu-latest with Docker); local Docker daemon not available in this environment

## Step 1 PR ready-for-review

Per BUILD §2.0 + §3 the per-step audit-lane gate is the convergence check. With round-4 0/0/0 across all three lanes and the verification above, the Step 1 PR can be flipped from draft to ready.

Step 2 (rollup pipeline) kicks off from the squash-merged tip of Step 1 in a fresh worktree per BUILD §2.0.
