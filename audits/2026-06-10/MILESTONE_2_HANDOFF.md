# Milestone 2 — handoff

Milestone 2 from `audits/2026-06-10/REPO_AUDIT.md` ships as six PRs against
`Augustas11/macprovider`. M2-3 (gateway `SetMaxOpenConns(1)` parity) and M2-7
(dependabot + tidy) were already covered by Quick Wins QW-5 and QW-6 from
Milestone 0 and were intentionally skipped per the autopilot brief. M2-9
(cross-service integration test) is deferred to the M3 backlog — rationale
below.

All PRs:

- branched from the latest `origin/main` (post-Milestone 1)
- pass the full Go suite (`go test ./...`); money-path PRs additionally pass
  `-race -count=1` across both modules
- need human review per AGENTS.md before merge (do not self-merge)
- the M2-1 sub-PR chain must be merged serially (1a → 1b → 1c); 1b/1c are
  not yet open per the brief's serial-merge requirement

## PR list

| # | PR | Branch | Audit refs | Risk | Touches |
|---|---|---|---|---|---|
| M2-6 | [#45](https://github.com/Augustas11/macprovider/pull/45) | `docs/m2-6-coordinator-readme-makefile` | DEVE-6, DOCS-8 | docs/devex | `phase4-coordinator/README.md` (new), `/Makefile` (new), `.github/workflows/ci.yml` |
| M2-2 | [#46](https://github.com/Augustas11/macprovider/pull/46) | `fix/m2-2-swap-audit-off-pool-lock` | ARCH-2, CODE-2, PERF-2 | concurrency | `phase4-coordinator/internal/pool/provider.go{,_test.go}`, `cmd/coordinator/main.go` |
| M2-5 | [#47](https://github.com/Augustas11/macprovider/pull/47) | `fix/m2-5-provisional-retention-bounded` | XPERF-2, PERF-5 | memory | `phase4-coordinator/internal/ws/admission.go{,_test.go}`, `internal/pool/provider.go{,_test.go}`, `cmd/coordinator/main.go` |
| M2-1a | [#48](https://github.com/Augustas11/macprovider/pull/48) | `refactor/m2-1a-extract-advance-helper` | ARCH-1, CODE-1 (sub-PR 1 of 3) | money path | `phase4-coordinator/internal/buyer/server.go` |
| M2-4 | [#49](https://github.com/Augustas11/macprovider/pull/49) | `fix/m2-4-gateway-retention` | PERF-1 (Parts A+B), PERF-4 | money path | `phase5-gateway/internal/storage/sqlite/{dsn,store,store_test}.go`, `internal/storage/interfaces.go`, `internal/router/{server,explorer}.go`, `cmd/gateway/main.go` |
| M2-8 | [#50](https://github.com/Augustas11/macprovider/pull/50) | `docs/m2-8-ops-md` | DOCS-3, DOCS-5 | docs | `OPS.md` (new), `RUNBOOK.md`, `CONTINUE_RUNBOOK.md`, `HANDOFF.md` |

## Pending sub-PRs (M2-1)

M2-1 is the audit's centerpiece refactor — the 510-line `handleChatCompletions`
function with three diverging copies of the failover state machine. The audit
asked for a strangler approach in three sub-PRs:

- **M2-1a (PR #48 — open).** Pure mechanical extraction of the
  `advanceToNextProvider` helper. Zero behaviour diff. Inlined at 4 of the
  5 audit-identified sites; the 5th (WS-tunneled queue-full / disconnect at
  the old line 1246-1258) stays inline because its shape differs and folding
  it would change behaviour. Sub-PR 1c collapses it naturally.
- **M2-1b — NOT YET OPEN.** Will introduce `transportResult` and three
  classifier functions (`classifyHTTPResult`, `classifyWSResult`,
  `classifyStreamResult`) routing the existing three loops through the
  unified type. The audit-confirmed differences (per-attempt context
  timeout HTTP-only; `failoverCandidate` WS-non-streaming-only) become
  explicit `transportResult` fields. Three loops still exist after 1b
  but talk via the unified type.
- **M2-1c — NOT YET OPEN.** Collapses to one loop in commit-per-transport
  order (HTTP → non-streaming WS → streaming WS). Critical invariants from
  the brief: byte-identical `attempt_n` numbering, byte-identical
  `logAttempt` ordering (billing ledger keys off them), and preservation
  of the per-transport differences identified in 1b.

Per the brief and AGENTS.md sensitive-paths discipline, M2-1b will not
open until M2-1a merges; M2-1c will not open until M2-1b merges.

## Decision gates surfaced (audit Open Questions)

### Gate A — Open Q4 (M2-4 Part C, still open)

> "Gateway append-only-forever: compliance requirement or default? Is
> tamper-evidence-in-place a deliberate compliance posture (→ archive-rotate
> with cold storage), or is aged-out deletion of event rows acceptable
> (→ trigger amendment)?"

M2-4 ships **Parts A + B only**:
- Part A (PERF-4) — read-only DB handle for explorer + `/v1/usage` GETs
- Part B (PERF-1 partial) — `DeleteTerminalQuotaReservations` for the
  one reservation table whose schema permits DELETE

**Part C (event-table archival)** stays gated on Q4. Eight tables —
`usage_events`, `feedback_events`, `audit_events`, `api_key_events`,
`demo_usage_events`, `capacity_signal_events`, `signup_events`,
`demo_session_events` — all `RAISE(ABORT)` on DELETE per
`phase5-gateway/internal/storage/sqlite/migrate.go:184-251`, plus
`concurrency_reservations` (same trigger; the audit prompt incorrectly
listed this as deletable). Until Q4 is answered, `migrate.go:184-251` is
untouched. The two branches of Q4:

- **Archive-rotate** → cron job that rolls the DB file at a size/age
  threshold and ships the old file to cold storage (preserves tamper
  evidence per the spirit of the existing append-only design).
- **Aged-delete amendment** → migrate.go trigger rewrites that permit
  `DELETE` for rows older than N days while still forbidding UPDATE.

Decision needed before any further work on PERF-1.

### Gate B — M0-5/M1-6 first real deploy (M2-8 callouts)

OPS.md (PR #50) is written assuming the operator has **not yet run** a
production deploy with the M0-5 (version-stamped + `.prev`) and M1-6
(scripted gateway deploy + mandatory C2) scripts. Two sections are marked
**"TBD after first M0-5/M1-6 deploy"**:

- §2 (coordinator restart) — exact timing of the `/healthz` provenance
  poll loop.
- §3 (gateway restart) — confirm the `.prev` artifact filename layout.

After the first real deploy, these should be tightened against observed
behaviour. Suggested follow-up: 5-min operator post-deploy doc-update note.

### Open Q2 (carried from M1) — still relevant for OPS.md §8

Provider provisioning OPS.md section §8 documents the pinned-tier path
(M1-1) as production-ready and notes the stranger-tier path is gated on
Open Q2 with PR #44 (`feat/m1-1-self-serve-provisional-tokens`) as the
proposed self-serve implementation. Q2 ruling decision still pending in
that PR's review.

### Open Q3 (carried from M1) — still relevant for tier-2

No M2 PR touches tier-2 posture; Open Q3 (which of the five enforcement
flags to assert in production) remains operator-deferred per the M1 handoff.

## Deferred to M3 backlog

### M2-9 — cross-service integration test (TEST-6)

Deferred to M3. Rationale: the audit's M2-9 spec calls for a new
top-level `/test/integration/` Go module with `replace` directives for
both phase4-coordinator and phase5-gateway, a subprocess-managed
mockprovider, ephemeral-port `httptest.Server`s for both Go services,
fake-OAuth signup → API-key mint → POST `/v1/chat/completions` → assertions
across both DBs, plus a sticky-route HMAC contract scenario. This is a
~1-day piece of work that needs both services' test conventions plus
careful handling of subprocess lifecycles and parallel-port conflicts.
Defering it to M3 lets it land in a dedicated PR with proper test review
rather than rushing it in alongside this milestone.

The existing test corpus already pins the money-path invariants the
integration test would cover at the unit/handler level — the integration
test's value is **anti-regression on the cross-service contract**, e.g. a
silent header rename like deleting `X-MacProvider-Internal-Conv` from the
gateway's forwarded headers. Recommend ticketing M2-9 as `M3-11` and
scheduling it as the first M3 PR.

## M3 backlog (recap from the audit § 5)

In approximate operator-priority order:
- **M3-1** sargable prunes (existing pruners scan with non-indexed predicates)
- **M3-2** operator-key split (coordinator vs gateway, currently shared)
- **M3-3** d-inference license notice in repo root
- **M3-4** Swift CI + nio bump
- **M3-5** Phase-1 artifact cleanup (RUNBOOK / CONTINUE_RUNBOOK / `state/`)
- **M3-6** provider economics doc
- **M3-7** specs/CLAUDE polish (version-pin sweep, audit-finding cross-refs)
- **M3-8** code polish (the `writeError` 3-variant divergence, etc.)
- **M3-9** gateway server.go file split (the 2,495-line god-file)
- **M3-10** billing recorder typed wrapper
- **M3-11** (NEW) cross-service integration test — deferred from M2-9

## Operator actions, in execution order

1. **Review and merge the six PRs.** Phase 1 first (no-decision, can land in any order): #45, #46, #47, #49, #50. The centerpiece refactor (#48) gates the next two sub-PRs and should be reviewed carefully against the "zero behaviour diff" claim before merging.
2. **After #48 merges**, ask for sub-PR 1b (`refactor/m2-1b-unify-result-classification`). After 1b merges, ask for 1c. Each is its own sensitive-paths review.
3. **Answer Open Q4** before any further PERF-1 work. The decision determines whether M2-4 Part C ships as archive-rotate or trigger-amendment.
4. **First real M0-5 / M1-6 deploy** — once done, refresh OPS.md §2 and §3 against observed behaviour and remove the TBD callouts.
5. **Decide M1-1 production migration timing** (carried from M1 handoff) and run the migration choreography (issue-token per pinned provider → restart provider services → flip `require_provider_tokens=true` → SIGHUP coordinator).

## M2 complete criteria

Declare Milestone 2 done when:

- All six PRs in the table above are merged.
- M2-1 sub-PR chain (1a → 1b → 1c) is merged through.
- Open Q4 is answered (in `beta/DECISION_CRITERIA.md`) and either:
  - M2-4 Part C lands as archive-rotate (preferred per "compliance posture"), or
  - M2-4 Part C lands as trigger-amendment (per "default tamper-evidence").
- OPS.md TBD callouts are removed after the first M0-5/M1-6 deploy.
- A new entry in `beta/DECISION_CRITERIA.md` (Entry 68; originally
  numbered 60 at commit time, renumbered on 2026-06-12 to resolve a
  collision with the Open Q2 ruling entry from a parallel session)
  records the M2 PR list, the decisions taken vs deferred, and the
  M3 follow-ups.

## Audit refs

- Full audit: `audits/2026-06-10/REPO_AUDIT.md`
- §5 Task Plan: tasks M2-1 through M2-9
- §6 Open Questions: Q4
- Theme 4 (de-risk money-path hot spot) — M2-1 is the centerpiece
- Theme 3 (docs truth sweep) — M2-8 lands OPS.md
