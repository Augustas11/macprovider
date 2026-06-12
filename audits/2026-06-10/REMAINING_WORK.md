# Remaining work — post-milestone audit verification 2026-06-10

_Companion to `VERIFICATION_REPORT.md`. Items in `RESOLVED` / `RESOLVED_DIFFERENTLY` / `SUPERSEDED` are NOT listed here. Severity reflects the original audit's calibration (a 2-person beta with live money), with per-item recalibration notes where post-milestone context changed the picture._

## Severity-ordered punch list

### [High] ARCH-1 — handleChatCompletions god-function with three diverging copies of failover state machine

- **Status:** `PARTIAL`
- **Recalibrated severity:** Medium — the live divergence bugs (state-marking + retry counter) are fixed and the most-duplicated extraction (advanceToNextProvider) is hoisted; remaining is structural duplication of three transport loops, not correctness drift
- **Detail:** **Evidence** PR #36 (27559ae) fixed the two confirmed divergences (queue-full→StateBusy now happens in the streaming path, see `buyer/server.go:1109-1111`; explicitRetries++ unified inside `advanceToNextProvider`). PR #48 (8f18f5a, M2-1a) extracted `advanceToNextProvider` helper at `buyer/server.go:1377-1399`. PR #36 / #48 close two of the three milestone sub-tasks; M2-1b (transportResult + 3 classifiers) exists only as draft commit `de58b9a` and is not merged; M2-1c not yet open per handoff. **Original citation** Audit cited `buyer/server.go:840-1350` and three loops at 1056-1153, 1154-1245, 1246-1349. Current function still spans 487 lines (`handleChatCompletions` 869 → ~1356), with three loop bodies preserved at 1085-1170 (streaming), 1172-1257 (WS-tunnel non-streaming), and 1264-135...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → ARCH-1

### [High] CODE-1 — Drift across three copies of failover state machine (merged with ARCH-1)

- **Status:** `PARTIAL`
- **Recalibrated severity:** Medium — same recalibration as ARCH-1 (merged finding)
- **Detail:** **Evidence** Same as ARCH-1. PR #36 unified the two confirmed drift bugs; PR #48 extracted the per-retry tail into `advanceToNextProvider`. The three loop bodies still exist at `buyer/server.go:1085-1170`, `1172-1257`, `1264-1356`. **Original citation** §3.1 item 3 / §3.3 CODE-1 merged into ARCH-1 in the audit. **Fix delta** Drift correctness fixes shipped; structural deduplication partial. **Notes** See ARCH-1 for details.
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → CODE-1

### [High] DEVE-2 — The 3am story — single Gmail channel co-hosted on VPS, no external check

- **Status:** `PARTIAL`
- **Recalibrated severity:** Medium (code-side fixed; external uptime is operator-pending)
- **Detail:** **Evidence** - PR #15 / commit 950c0e2: `m0: monitor — preserve state on alerting-transition SMTP failure (M0-4a)`. - `phase4-coordinator/dist/monitor/macprovider-monitor.py:163-191` now distinguishes `delivery == True/False/None`; `save_state()` is gated on `not alerting or delivery is not False`, so an SMTP failure during an alerting transition keeps the OLD state and refires next cycle (the audit-cited "state saved regardless of delivery" bug). - External healthcheck: `audits/2026-06-10/OPS_HEALTHCHECK_SETUP.md` shipped (QW-3, PR #11) — a documented operator checklist (healthchecks.io / UptimeRobot), explicitly noting Claude cannot register external accounts. **Original citation** > Alerting is one Gmail channel that silently degrades to journald-only without creds (`macprovider-moni...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → DEVE-2

### [High] XSEC-1 — Provider identity unauthenticated end-to-end

- **Status:** `CODE_SHIPPED_OPERATOR_PENDING`
- **Detail:** **Evidence** - PR #41 (89de1e6) `m1-1: provider_token plumbing + Bearer on WS connect (XSEC-1, pinned tier)` — Swift binary Authorization header. - PR #44 (e26b245) `M1-1 Q2: self-serve provisional tokens (closes XSEC-1 open-onboarding gate)` — coordinator-side FR-C9 self-serve mint. - Live coordinator deploy + rollback noted in orchestrator brief, 2026-06-12. Sub-aspect verification: (a) Swift Bearer header — **RESOLVED**. `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:122-138` declares `private var providerToken: String?`, init reads `config.providerToken` (line 182). At connect (line 304-305): `if let token = providerToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }`. Comment block at 122-128 explicitly tags `M1-1 / XSEC-1`. (b) Coordi...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → XSEC-1

### [Medium] ARCH-3 — Uncapped *sql.DB handles on coordinator while money path takes BEGIN IMMEDIATE

- **Status:** `NOT_RESOLVED`
- **Detail:** **Evidence** `grep -rn 'SetMaxOpenConns' /Users/augstar/macprovider-poc/phase4-coordinator/` returns ZERO hits. Gateway still caps at 1 (`phase5-gateway/internal/storage/sqlite/store.go:38`). M2-3 was listed in §5 task table but no commit references it; no entry in any handoff doc says M2-3 shipped. **Original citation** `cmd/coordinator/main.go:47-59` — opens `tokenStore`, `reqLogStore`, `auditStore` in sequence (now lines 57-74 post-drift) with no SetMaxOpenConns call. Sub-handles for `admissionStore` and `billingStore` (lines 75-84) also derive from the unconfigured `reqLogStore.DB()`. **Fix delta** Suggested fix (`SetMaxOpenConns(1)` on each of the three handles) — not applied. **Notes** Latent risk until coordinator concurrency rises (currently single-coordinator). The buyer hot-pa...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → ARCH-3

### [Medium] DOCS-4 — specs/README.md index 6 revisions stale on 3 of 12 spec families

- **Status:** `PARTIAL`
- **Recalibrated severity:** Low — drift admitted in-doc; partial mitigation acceptable
- **Detail:** **Evidence** - `specs/README.md:1-16` lists SPEC-001 v1.3 (actual v1.4 per `SPEC-001-phase3-binary.md:3`), SPEC-003 v0.7 (actual v0.9.2 per `SPEC-003-open-onboarding.md:3`); SPEC-002, SPEC-006 etc. match. - `specs/README.md:18` now contains an explicit drift disclaimer: `**Version of record is line 3 of each spec; do not trust this index for compatibility decisions — read the spec header.** This index drifts; the spec headers do not. When in doubt, grep -m1 '^\*\*Version' specs/SPEC-*.md.` - M3-7 in §5 was `Specs index regen + CLAUDE.md/AGENTS version pointers` — handoff lists no PR shipped; CLAUDE.md side (DOCS-5) is in but index regen not committed. **Original citation** Audit §3.9 DOCS-4: 'specs/README.md indexes 3 of 12 spec families at versions ~6 revisions stale'. **Fix delta** Su...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → DOCS-4

### [Medium] PERF-1 — Gateway DB can never shrink (8 event tables + concurrency_reservations have RAISE(ABORT) BEFORE-DELETE triggers, no archival story)

- **Status:** `PARTIAL`
- **Detail:** **Evidence** - PR #49 / commit aa4df53 — `m2-4 (Parts A+B): gateway read-only handle + reservation cleanup (PERF-1, PERF-4)` - New code at `phase5-gateway/internal/storage/sqlite/store.go:710-744` (DeleteTerminalQuotaReservations) - Test `TestDeleteTerminalQuotaReservationsKeepsActiveAndDropsOld` passes (verified via `go test ./internal/storage/sqlite -run TestDeleteTerminal -count=1` → ok) - Commit message explicitly notes `concurrency_reservations` and 8 event tables NOT touched — gated on Open Q4. **Original citation** audit `migrate.go:184-251`; current `phase5-gateway/internal/storage/sqlite/migrate.go:184-251` — the same 8 event-table `RAISE(ABORT)` BEFORE-DELETE triggers + `concurrency_reservations_no_delete` trigger still present verbatim (lines 184-251 unchanged). **Fix delta**...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → PERF-1

### [Medium] PERF-3 — Non-sargable unbatched retention DELETEs in coordinator request_log pruner

- **Status:** `PARTIAL`
- **Recalibrated severity:** Low — the high-blast-radius part (unbatched DELETE holding write lock across 6s billing budget) is resolved via batched LIMIT + yield. Remaining sub-aspect (julianday() non-sargable) is documented as deferred and only affects the worker-side scan, not the lock holding pattern.
- **Detail:** **Evidence** - PR #66 / commit 1511d18: `m3-1: batched retention DELETEs in coordinator pruners (PERF-3)` + fixup e6bff92 (`yield between prune batches + 90-day audit retention floor`). - Current `phase4-coordinator/internal/requestlog/store.go:189-228` — `const pruneBatchSize = 500`, `pruneBatchYieldMs = 10`, batched loop, returns when partial batch detected. - `go test ./internal/requestlog -run TestPrune -count=1` → ok. **Original citation** audit `requestlog/store.go:185-188` — single unbounded `DELETE … WHERE julianday(ts_utc) < julianday(?)`. Current `store.go:196`: `DELETE FROM request_idempotency_keys WHERE rowid IN (SELECT rowid FROM request_idempotency_keys WHERE julianday(created_at_utc) < julianday(?) LIMIT ?)` and `store.go:199`: equivalent for `request_log`. Batched + yiel...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → PERF-3

### [Medium] SECU-3 — Tier-2 posture defaults fully permissive; deploy gate doesn't assert flags

- **Status:** `PARTIAL`
- **Detail:** **Evidence** - PR #40 (0895d58) `m1-6: scripted gateway deploy + mandatory C2 + remote backup (DEVE-4/5, SECU-3)`. - M1-6 Parts A+B landed (scripted gateway deploy in `phase5-gateway/dist/deploy-pearl-vps.sh`, mandatory C2 cross-check in `phase4-coordinator/dist/check-deploy-config.sh` hard-failing on missing gateway.yaml). - **Part C explicitly DEFERRED.** `audits/2026-06-10/MILESTONE_1_HANDOFF.md:55-65`: "Open Q3 — Target tier-2 posture for this beta (still open, but with a decision recorded) ... **This autopilot run asked the operator and the answer was 'Defer Part C entirely.'** None of the five flags are asserted by the M1-6 deploy gate yet." - Confirmed empirically: `grep -n 'tier2\|require_encrypted\|require_hash\|require_attestation\|posture' phase4-coordinator/dist/check-deploy...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → SECU-3

### [Medium] TEST-3 — Wall-clock-coupled WS tests cause ~48s package runtime

- **Status:** `PARTIAL`
- **Recalibrated severity:** Low (most of the wall-clock burn is gone; remaining sleeps are intrinsic to heartbeat-boundary regressions)
- **Detail:** **Evidence** - Partial fix: commit 324c561 (PR #13, M0-3b) addressed the wake-gap sleep specifically. - `phase4-coordinator/internal/ws/server_test.go:1520` is now `time.Sleep(50 * time.Millisecond)` (was 1100ms) — wake-gap threshold dropped to 25ms via test-only `WakeGapThresholdMs`. - Two other sleeps remain at lines 1742 (`200ms` in TestActiveProviderWithoutHeartbeatStaysConnected) and 1786 (`150ms` in TestProviderClosedAfterActivityStops). These tests pin the Phase 6 heartbeat-liveness regression (see project memory `phase6-heartbeat-liveness-regression`) and intentionally drive ~3s of activity at sub-second cadence to cross the heartbeat-miss threshold. - Package runtime: `go test ./internal/ws/ -count=1` → `ok 9.536s`. Down from audit-era ~48s. **Original citation** Audit: `uncond...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → TEST-3

### [Medium] XPERF-2 — Provisional admission state never pruned; whole-state JSON marshal per mutation

- **Status:** `PARTIAL`
- **Recalibrated severity:** Low-Medium — `ProvisionalRetentionDays` is now implemented and wired (the audit's headline complaint of "specified and dropped" is resolved), and rate-limiter state is now bounded. Remaining sub-aspect: whole-state `json.Marshal` per provisional mutation is unchanged. This is the lower-impact half (write-cost-per-mutation vs unbounded-growth) at current provisional pool sizes.
- **Detail:** **Evidence** - PR #47 / commit 128cd9e (M2-5). - Current `phase4-coordinator/internal/ws/admission.go:221-271`: `Prune(cutoff)` drops records with `LastSeenAt` before cutoff, orphan rejections, and per-provider request windows; comment cites `M2-5 / XPERF-2`. - Wired into the daily retention loop: `phase4-coordinator/cmd/coordinator/main.go:268` calls `startAdmissionRetentionPruner(shutdownCtx, wsServer.Admission(), cfg.Admission.ProvisionalRetentionDays, logger)`. Pruner helper at `main.go:371`. - `cfg.Admission.ProvisionalRetentionDays` consumed (`config.go:123`, default 30 at `:303`). - `TestAdmissionManagerPruneShrinksStateBeyondCutoff` passes (`go test ./internal/ws -run TestAdmissionManagerPrune -count=1 -v` → PASS). **Original citation** audit `admission.go:99-152,209-221` — whol...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → XPERF-2

### [Medium] SECU-4 — One shared operator key spans gateway admin, coordinator operator API, and sticky buyer path

- **Status:** `CODE_SHIPPED_OPERATOR_PENDING`
- **Detail:** **Evidence** - PR #73 (11f7c0c) `m3-2: operator-key split + coordinator env-file + de-root monitor (SECU-4 + DEVE-7)`. - New auth helpers in `phase4-coordinator/internal/auth/tokens.go`: `OperatorOnlyBearerMatches` (line 106) for human-admin endpoints, `GatewayInternalBearerMatches` (line 129) for service-to-service `/internal/*` paths with `BearerKindServiceToken` preferred over legacy `BearerKindOperatorKey` fallback. - `phase4-coordinator/internal/ws/server.go:2161` — `authorizedOperator` uses `OperatorOnlyBearerMatches` (operator-only, no service-token acceptance). Comment block 2138-2160 records codex security audit HIGH-1 reasoning: admin endpoints accepting service token would silently grant human-admin power to gateway post-rotation. - `phase4-coordinator/internal/billing/endpoi...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → SECU-4

### [Medium] TEST-6 — No cross-service integration test between gateway and coordinator

- **Status:** `DEFERRED`
- **Detail:** **Evidence** - Deferral record: `audits/2026-06-10/MILESTONE_2_HANDOFF.md:117-150`: ``` ### M2-9 — cross-service integration test (TEST-6) Deferred to M3. Rationale: the audit's M2-9 spec calls for a new ... Recommend ticketing M2-9 as `M3-11` ... - **M3-11** (NEW) cross-service integration test — deferred from M2-9 ``` - Sticky header contract at `phase5-gateway/internal/router/server.go:1401-1405` (or its post-M3-9 location) and coordinator `internalBearerAuthorized` (`buyer/server.go:2754`) still has no cross-boundary `test/integration/` harness. - `phase5-gateway/internal/router/integration_test.go` exists but is within-gateway (mocks coordinator via `cfg.Coordinator.BuyerURL = "http://coordinator.test"` + httptest stubs at lines 43, 154, 184, 221, 271, 312, 349, 381). It does not e...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → TEST-6

### [Low] ARCH-5 — Cross-service duplication (sqlite DSN helper, bearer compare) — document conscious debt

- **Status:** `NOT_RESOLVED`
- **Detail:** **Evidence** `phase4-coordinator/internal/sqliteutil/dsn.go:8-23` and `phase5-gateway/internal/storage/sqlite/dsn.go:8-22` still hold byte-identical `WithPragmas`/`sqliteDSN` bodies (same four pragmas, same order). `grep -rn 'ARCH-5'` in *.md returns only the audit file itself; no documentation lookup of the conscious-debt rationale was added to OPS.md / coordinator README / gateway README. PR #50 (M2-8 OPS.md) shipped general ops docs but did not call this out. **Original citation** Audit asked these be documented as 'conscious-debt copies'. **Fix delta** No code change expected, but the *document* part of the recommendation was not done. Counts as not_resolved per the audit's own wording. **Notes** Low impact; mention-it-once fix.
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → ARCH-5

### [Low] CODE-3 — Tier-2 trust disclosure parsed from untyped map[string]any with silent zero-fallbacks (Phase-1 fallback path)

- **Status:** `NOT_RESOLVED`
- **Detail:** **Evidence** `phase5-gateway/internal/router/disclosure.go:318-422` — `tier2BodyMetadataActive`, `tier2ModelHashState`, `intFromModelField` and friends still drill through `body map[string]any` with `_, _ := tier2Raw['model_hash'].(map[string]any)` zero-default-on-miss patterns (lines 319, 323, 328, 333, 338, 378, 383). No commit references CODE-3 explicitly; not on any milestone task list. **Original citation** Audit cited `server.go:1020-1080`. Code moved to `disclosure.go` during M3-9 file split; map[string]any pattern preserved verbatim. **Fix delta** Verifier-downgraded Low; team chose not to act (consistent with downgrade reasoning that the typed `/internal/routing` path now dominates). **Notes** Strictly the Phase-1 fallback path; three golden tests pin the shape per the audit. A...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → CODE-3

### [Low] DEPE-5 — yaml.v3 officially archived/unmaintained

- **Status:** `NOT_RESOLVED`
- **Detail:** **Evidence** Both go.mod files still require `gopkg.in/yaml.v3 v3.0.1`: - `phase4-coordinator/go.mod:11` - `phase5-gateway/go.mod:7` **Original citation** Audit: "yaml.v3 officially archived/unmaintained (operator-config-only input; note and move on)." **Fix delta** No migration. The audit explicitly said "note and move on" — no milestone PR was planned for this. **Notes** Low severity remains correct: input scope is operator config (root-owned), not buyer-attacker-controlled. Staying with the archived package is acceptable until a replacement (e.g. `go-yaml/yaml.v3` fork or `goccy/go-yaml`) is adopted.
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → DEPE-5

### [Low] DEPE-8 — gobwas/ws upstream dormant; StatusCode leaked in admission signature

- **Status:** `NOT_RESOLVED`
- **Detail:** **Evidence** `phase4-coordinator/go.mod:7` still pins `github.com/gobwas/ws v1.4.0`. The signature leak the audit called out persists at `phase4-coordinator/internal/ws/admission.go:78-80`: ``` func (a *AdmissionManager) Admit(hello Hello, pinned bool, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) { if pinned { return pool.TierPinned, 0, "" ``` **Original citation** Audit: "gobwas/ws upstream dormant since May 2024 (current version; contingency note only — and `admission.go` leaks its `StatusCode` type in a signature, so a swap is slightly more than `internal/ws`-contained)." **Fix delta** No change. Audit framed this as "contingency note only" — no milestone task scheduled. Path B not triggered (gobwas still functional). **Notes** Low severity remains correct. If a s...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → DEPE-8

### [Low] SECU-6 — Provider-reported token counts trusted for billing within a cap

- **Status:** `NOT_RESOLVED`
- **Detail:** **Evidence** - No PR found in `git log --grep` for SECU-6 specifically; not listed in any milestone handoff as targeted for this audit cycle. - §5 task table does not assign SECU-6 to M1/M2/M3. - Audit text already classifies as Low: "Buyer over-charge is correctly impossible (usageFromJSON caps at promptEstimate+max_tokens, server.go:2356-2369); the coordinator additionally clamps completion to byte-estimate (formula.go:214); the gateway settlement path lacks that cross-check. Residual: provider revenue gaming — compounded by XSEC-1." - XSEC-1 amplification reduces as PR #41+#44 close provider identity (provider gaming becomes attributable rather than anonymous), but the gateway settlement path's missing byte-estimate cross-check at `phase5-gateway/internal/router/server.go:1607-1611` ...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → SECU-6

### [Low] DOCS-7 — Version-drift cluster (README badge, gateway README SPEC-006 pin, SPEC-002 dep self-contradiction)

- **Status:** `PARTIAL`
- **Detail:** **Evidence** - README: PR #12 dropped the hardcoded v1.2.5 string; `README.md:13` now uses a dynamic shields.io badge (`shields.io/github/v/release/augustas11/macprovider`) and no body text contradicts it. Resolved. - Gateway README: `/Users/augstar/macprovider-poc/phase5-gateway/README.md:3` reads `Phase 5 gateway implementation for SPEC-006 v0.8.3.` Matches actual SPEC-006 v0.8.3 (specs/SPEC-006-buyer-api.md:3). Resolved. - SPEC-002 dep line: `specs/SPEC-002-coordinator.md:4` says `Depends on: SPEC-001 v1.3 (Phase 3 binary wire protocol, locked)`. SPEC-001 actual is v1.4 (specs/SPEC-001-phase3-binary.md:3, '1.4 (2026-06-12, custom model selection')). The audit-era self-contradiction line at v1.2.1 (line 50, changelog) is preserved as history; the current header is internally consisten...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → DOCS-7

### [Low] DEVE-7 — Coordinator secret handling weak half of asymmetric pattern (plaintext YAML, root-monitor)

- **Status:** `CODE_SHIPPED_OPERATOR_PENDING`
- **Detail:** **Evidence** - PR #73 / commit 11f7c0c `m3-2: operator-key split + coordinator env-file + de-root monitor (SECU-4 + DEVE-7)`, plus codex fixups c99f1ca and 55bb5c0. - `phase4-coordinator/dist/monitor/macprovider-monitor.service`: `User=macprovider`, `Group=macprovider`, `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `PrivateDevices=true`, `ReadOnlyPaths=/opt/macprovider`, `StateDirectory=macprovider-monitor`, `EnvironmentFile=-/etc/macprovider/coordinator.env` (the env file the coordinator unit also reads — symmetric with gateway). - `macprovider-monitor.py:54-61, 107`: `operator_key()` returns `os.environ.get("OPERATOR_KEY", "")` — no more regex-against-yaml-as-root. - `deploy-pearl-vps.sh:194-208`: enforces `coordinator.env` perms `root:macprovi...
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → DEVE-7

### [Low] ARCH-6 — Billing/request-log persistence orchestration lives inline in handler closures

- **Status:** `DEFERRED`
- **Detail:** **Evidence** Handoff lists M3-10 as DEFERRED, pairing with M2-1c. No commit references ARCH-6 or `logRowWithBilling` extraction. `buyer/server.go:869-974` still defines `logRowWithBilling` as an inline closure inside `handleChatCompletions` (lines 880-974). The gateway pattern the audit pointed at as the goal remains the contrast. **Original citation** Audit cited `buyer/server.go:851-945`; the closure now spans 880-974 (drifted but same shape). **Fix delta** Explicit deferral, paired with the M2-1 ARCH-1 work-stream so the extraction lands once the failover loops collapse to one. Justified sequencing. **Notes** No regression risk while deferred (money math in `formula.go` is the high-stakes part and stays isolated).
- **Evidence trail:** `VERIFICATION_REPORT.md` → Findings → ARCH-6

## §5 tasks not in RESOLVED state

Tasks that did not reach `RESOLVED` (each maps to one or more findings above; this view is by task ID).

| Task | Status | Title |
|---|---|---|
| M2-3 | `NOT_RESOLVED` | SetMaxOpenConns(1) on coordinator stores |
| QW-5 | `NOT_RESOLVED` | SetMaxOpenConns(1) on coordinator stores |
| M1-6 | `PARTIAL` | Deploy-gate hardening |
| M2-1 | `PARTIAL` | Extract single forwardWithFailover (strangler) |
| M2-4 | `PARTIAL` | Gateway retention/archival + RO handle |
| M3-9 | `PARTIAL` | Gateway server.go file split (Phase 1) |
| M1-1 | `CODE_SHIPPED_OPERATOR_PENDING` | Wire provider tokens end-to-end |
| M1-7 | `CODE_SHIPPED_OPERATOR_PENDING` | Bump modernc.org/sqlite |
| M3-2 | `CODE_SHIPPED_OPERATOR_PENDING` | Operator key split + de-root monitor |
| M3-4 | `CODE_SHIPPED_OPERATOR_PENDING` | swift-nio bump + drop swift-log + Swift CI |
| M2-9 | `DEFERRED` | Cross-service integration test |
| M3-10 | `DEFERRED` | Hoist logRowWithBilling into billing-recorder type |

## Operator-pending items (require human action, not code)

Code is merged; resolution depends on operator action on Pearl, in GitHub branch-protection, or in production config. Ordered as a checklist.

1. **M1-1 / XSEC-1 token migration + flag flip** — Issue tokens via `coordinator-cli issue-token --provider-id M1` (and same for M4, air8gb) against Pearl; update each provider's `macprovider.yaml` with `auth.provider_token`; `chmod 0600` the file; restart provider service. Verify all 3 heartbeat with `provider_token_validated` in coordinator logs. Then flip `require_provider_tokens=true` in Pearl's `coordinator.yaml`; SIGHUP. Verify a fresh tokenless connect attempt is rejected. Self-serve provisional path (PR #44) is merged so the strangers tier survives the flip. Record date + verification in `beta/DECISION_CRITERIA.md`.
2. **Q3 tier-2 posture ruling + M1-6 Part C** — Decide which of the five enforcement flags (`RequireEncryptedLeg`, `RequireHashVerified`, `RequireAttestation`, `BehavioralSafetyEnabled`, `EncodingValidationEnabled`) production should assert now vs at scale. Then add `g(coord, "<flag>")` lines to `check-deploy-config.sh`. Currently silently deferred — the deferral lives only in `MILESTONE_1_HANDOFF.md`, with no canonical `DECISION_CRITERIA` entry. File one even if the decision is 'still deferred until X.'
3. **Q4 ruling — merge PR #58** — Decision in PR #58 body (archive-rotate to cold storage) needs to land as a `DECISION_CRITERIA` entry on main so M2-4 Part C has authoritative reference. Until then PERF-1 stays PARTIAL and the 8 RAISE(ABORT)-triggered event tables grow unbounded by design.
4. **M1-7 modernc/sqlite v1.52.0 canary day** — Deploy bumped coordinator binary during a quiet window via the M1-6 script (`.prev` rollback ready). Watch `monitor.py` + `journalctl -u macprovider-coordinator` for 24 h for `SQLITE_BUSY` / `database is locked` / ledger-write failures. If clean, log canary outcome in `DECISION_CRITERIA.md`. Gateway already at v1.52.0; cycle it on next deploy to confirm reproducibility.
5. **M3-2 operator-key cutover** — Per `MILESTONE_3_PHASE23_HANDOFF.md` cutover table: `openssl rand -hex 32` for service token → stash → set `GATEWAY_SERVICE_TOKEN` in `/etc/macprovider/coordinator.env` AND `COORDINATOR_SERVICE_TOKEN` in `/etc/macprovider/gateway.env` (both mode 0600) → SIGHUP both services → watch `journalctl -u macprovider-coordinator -f | grep internal_bearer_accepted` for `key=service_token` from gateway origin → wait 24 h with zero `key=operator_key` from gateway origin → rotate legacy `OperatorKey`. Cutover-watch query exists in OPS.md (PR #86 path-filtered to `/internal/*`).
6. **M3-4 `swift-tests` branch-protection flip** — After the `swift-tests` macos-15 job runs cleanly on 3–5 PRs that touch `phase3-binary/`, GitHub → Repo Settings → Branches → `main` branch-protection → add `phase3-binary (swift test)` to required checks. Currently non-blocking so macos-runner minute cost can be measured first.
7. **DEVE-2 external healthcheck confirmation** — `OPS_HEALTHCHECK_SETUP.md` ships the runbook (PR #11 / QW-3). Operator confirm: an external service (UptimeRobot / healthchecks.io) is actually configured against both `/healthz` endpoints with a non-Pearl notification channel (SMS / Telegram / phone). Repo cannot prove this; absence of confirmation is the gap that keeps DEVE-2 at `PARTIAL`.
8. **DEVE-7 monitor de-root verification on Pearl** — M3-2 PR #73 de-roots the monitor and routes `OPERATOR_KEY` via `EnvironmentFile`. Verify on Pearl: the systemd unit now uses `User=macprovider`, `/etc/macprovider/coordinator.env` exists at mode 0600, and the regex over `coordinator.yaml` is gone from the deployed monitor script.
9. **SECU-4 legacy OperatorKey rotation** — After M3-2 cutover stable for 24 h+, rotate the legacy `OperatorKey` value (separate from the new service token). The split is code-shipped; blast-radius reduction lands only after the cutover completes.
10. **M1-4 nginx rate-limit rollout** — Copy `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf` to Pearl; `nginx -t`; `systemctl reload nginx`. Verify rate-limit headers; confirm no legitimate provider trips the 10 req/min cap (per M1 handoff §4).
11. **OPS.md TBD callouts** — After the first M0-5 / M1-6 deploy, refresh OPS.md §2 (coordinator restart `/healthz` provenance poll timing) and §3 (`.prev` artifact filename layout) against observed behaviour. Replace the explicit `TBD after first M0-5/M1-6 deploy` blocks.

## Deferred items

Confirmed-as-deferred findings, tasks, and Open Questions, with deferral citation.

- **TEST-6** (Medium) — No cross-service integration test between gateway and coordinator. Cited in: `VERIFICATION_REPORT.md` Findings section.
- **ARCH-6** (Low) — Billing/request-log persistence orchestration lives inline in handler closures. Cited in: `VERIFICATION_REPORT.md` Findings section.
- **M2-9** — Cross-service integration test. Cited in: `VERIFICATION_REPORT.md` §5 Task cross-check.
- **M3-10** — Hoist logRowWithBilling into billing-recorder type. Cited in: `VERIFICATION_REPORT.md` §5 Task cross-check.
- **Q3** — Target tier-2 posture for this beta. Cited in: `VERIFICATION_REPORT.md` Open Questions section.

## New issues surfaced (severity-ordered)

- **[Medium]** M2-1b draft + M2-1c pending — three failover loops remain on main — _Where:_ `phase4-coordinator/internal/buyer/server.go handleChatCompletions; PR #61 DRAFT`. _Why:_ Audit's centerpiece refactor (ARCH-1/CODE-1) is in-flight but three near-duplicate failover loops still exist on main (HEAD fd3c652). Every retry-semantics change must be hand-synced across copies until M2-1c lands. Recalibrating Medium because M1-2 already fixed the two confirmed divergences.
- **[Low]** DECISION_CRITERIA Entry-number collisions (60, 67, 68, 71 multi-claimed) — _Where:_ `beta/DECISION_CRITERIA.md:344 Entry 60 renumbered; :366 Entry 68 (originally 60) renumber note; Entry 67/71 collisions called out in :354/:356`. _Why:_ Parallel autopilot/manual sessions independently claimed the same monotonic entry numbers (60 for both M2 batch and Open-Q2 ruling; 67/71 collisions). PR #83 (7ce7faf) partially addressed. Process gap: entry-number reservation isn't enforced; cross-references can drift.
- **[Low]** PR #58 (Open Q4 ruling) still OPEN — ruling not on main — _Where:_ `PR #58 state=OPEN; beta/DECISION_CRITERIA.md Entry 63 on main is M3-5, not Q4`. _Why:_ Q4 ruled in PR body (archive-rotate to cold storage) but canonical decision-log entry has not landed. Future PERF-1 / M2-4 Part C work lacks authoritative on-main reference until #58 merges.
- **[Low]** M3-1 follow-up: sargable RFC3339Nano comparison still pending — _Where:_ `phase4-coordinator/internal/requestlog/store.go (julianday predicate retained per MILESTONE_3_PHASE23_HANDOFF.md:64-68)`. _Why:_ RFC3339Nano writes are variable-width (`.` 0x2E < `Z` 0x5A) so lexicographic compare is silently wrong at fractional-second boundaries. PERF-3 batched-DELETE shipped, but the index is still defeated by julianday(). Low risk now; degrades as request_log grows.
- **[Low]** Q3 (tier-2 posture) silently deferred — no DECISION_CRITERIA entry — _Where:_ `beta/DECISION_CRITERIA.md (no entry); MILESTONE_1_HANDOFF.md:55-65`. _Why:_ Operator instructed 'Defer Part C entirely' during M1 autopilot but the deferral survives only inside an audit handoff doc, not a dated decision-log entry. Same pattern as Q6. Future agent sessions can't grep DECISION_CRITERIA for tier-2 posture status.
- **[Medium]** Verifier-surfaced: QW-5/M2-3 (`SetMaxOpenConns(1)` on coordinator) marked done in MILESTONE_2_HANDOFF.md but never shipped — _Where:_ `phase4-coordinator/cmd/coordinator/main.go:57-84`. _Why:_ Trivial three-line fix matching gateway's `internal/storage/sqlite/store.go:38` pattern; underlying ARCH-3 risk (latent SQLITE_BUSY tail-latency under coordinator write contention) is not yet mitigated.

## Recommended re-audit cadence

Three triggers should drive the next verification pass:

1. **After M1-1 / XSEC-1 production migration completes** (`require_provider_tokens=true` flipped + all 3 providers heartbeat with validated tokens) — verify closure of XSEC-1 residuals (c), (d) on the audit's verification checklist. Estimated within 2–4 weeks.
2. **After M2-1c lands** (the strangler refactor's final loop unification) — re-run the buyer test suite under `-race -count=5` and confirm `attempt_n` numbering, `logAttempt` ordering, and `failoverCandidate` semantics are byte-identical to PR #48 baseline. This is when ARCH-1/CODE-1 moves from `PARTIAL` → `RESOLVED`.
3. **After M3-2 cutover stable for 30 days** AND M3-4 swift-tests required-checks flip — verify SECU-4 reduces operator-key blast radius and DEVE-7 monitor de-root holds in production. Pairs naturally with the operator's planned follow-up to remove the legacy `OperatorKey` fallback.

Until at least the first trigger fires, treat the verification status counts in `VERIFICATION_REPORT.md` as the current state of record. The next full multi-agent audit can wait until the live money path materially changes (Phase-3 onboarding, real receipts implementation per Q1, coordinator HA work) or a quarter elapses — whichever comes first.
