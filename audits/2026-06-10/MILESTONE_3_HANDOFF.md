# Milestone 3 — Phase 1 handoff (shipped)

Milestone 3 from `audits/2026-06-10/REPO_AUDIT.md` is the "polish and residual
debt" milestone — eight low-risk tasks the audit graded Medium or Low because
they don't affect live money or security exposure today. This handoff covers
**Phase 1**: the four zero-risk hygiene & docs PRs, all of which are now merged
to `main` (squash commits noted below).

Phase 2 (five code-polish PRs) and Phase 3 (two multi-system PRs including the
operator-key split) are still queued; re-invoke `/autopilot` with the same M3
brief to open them. The GATE A decision below is locked in advance.

## Phase 1 PR list (all merged)

| # | PR | Squash | Audit refs | Touches |
|---|---|---|---|---|
| M3-3 | [#54](https://github.com/Augustas11/macprovider/pull/54) | `65e6199` | DEPE-4 | `scripts/gather-third-party-notices.sh` (new), `phase3-binary/dist/package.sh` |
| M3-5 | [#52](https://github.com/Augustas11/macprovider/pull/52) | `925af43` | DEVE-8, DEPE-7 | `git rm logs/` + `git rm results/`, `git mv results/REPORT.md → doc/PHASE1_REPORT.md`, `beta/requirements.txt` (new), `beta/README.md`, `.gitignore`, cross-doc REPORT.md references |
| M3-6 | [#53](https://github.com/Augustas11/macprovider/pull/53) | `18f76c0` | DOCS-6 | `doc/provider-economics.md` (canonical, relocated out of audits/ during fixup), `phase3-binary/README.md` (appendix pointer) |
| M3-9 | [#55](https://github.com/Augustas11/macprovider/pull/55) | `c33ed08` | ARCH-4 | pure file moves inside `phase5-gateway/internal/router/`: new `oauth.go`, `disclosure.go`, `chat_proxy.go`, `admin.go`, `auth_helpers.go`; `server.go` slimmed (and post-fixup boundary-cleaned: `authResult` moved to `auth_helpers.go`, chat helpers migrated to `chat_proxy.go`) |

All four landed via squash-merge; CI was green pre-merge on each branch.

## Audit-fixup round (between open and merge)

Between opening and merging, each PR went through a codex audit (code-reviewer
+ security-reviewer + architect lenses) producing 12 reviews total. 9 came back
`REQUEST_CHANGES`, 2 `APPROVE`, 1 `COMMENT`. Notable HIGH findings, all fixed in
the PR branches before merge:

- **M3-3 / PR #54** — supply-chain risk: the `gather-third-party-notices.sh`
  followed symlinks under `find` and `cat`, so a hostile SwiftPM dependency
  shipping `NOTICE.txt -> /Users/builder/.netrc` (or similar) would have
  exfiltrated that file into the public release tarball. Fixed by realpath
  containment + `find -P -type f` + per-file containment check. Also: the
  script accepted a hardcoded `.build/checkouts` path, but `package.sh` uses
  `xcodebuild -derivedDataPath ./build-release` which resolves SwiftPM under
  `build-release/SourcePackages/checkouts` — fixed by passing the checkout
  root as an argument. Added `NOTICE.md` to the recognized-file list and a
  "Missing license/notice files" footer section so packages with no
  recognized attribution leave a record in the artifact.
- **M3-5 / PR #52** — `psutil` was missing from `beta/requirements.txt`
  despite `beta/companion.py` importing it (HANDOFF.md called companion a
  beta runtime dep). `requests>=2.31` allowed CVE-2024-35195/47081 +
  CVE-2026-25645; bumped to `>=2.34.2`. `.gitignore` patterns were
  unanchored so `logs/` and `results/` would match nested directories
  anywhere — anchored to `/logs/` and `/results/`. HANDOFF.md file map
  still listed the deleted directories; updated. Two living references to
  `results/REPORT.md` (in `beta/harness.py:15` and
  `phase3-binary/implementation-notes.html:591`) were updated to the new
  `doc/PHASE1_REPORT.md` path.
- **M3-6 / PR #53** — the doc claimed `rate_card_excerpt` JSON keys were
  snake_case (`prompt_credits_per_mtok`); actually `RateCardEntry` has only
  yaml tags, so Go's `encoding/json` emits PascalCase (`PromptCreditsPerMtok`).
  Doc corrected. The worked-example intermediate formula was inconsistent
  with `ComputeCredits` (`1000000000 ÷ 1000000000000000` was wrong by orders
  of magnitude); fixed to match `formula.go`. The architect lens flagged the
  canonical doc as misplaced — `audits/2026-06-10/` is for dated audit
  deliverables, not standing provider reference docs. Moved to
  `doc/provider-economics.md` (matched the house `doc/` casing established
  by M3-5's `doc/PHASE1_REPORT.md`). Added the SPEC-005 payout-boundary
  sentence ("v1 accrues credits; actual payout requires SPEC-007 +
  operator decision") to the "When do I get paid?" section. Footer
  commit-hash drift + `provisonal` typo also fixed.
- **M3-9 / PR #55** — auth-boundary inversion: `authResult` was declared in
  `chat_proxy.go` but returned by `auth_helpers.go`'s `authenticateAny`.
  Moved the type to `auth_helpers.go`. `server.go` also still owned several
  chat-only helpers (`parseChatRequest`, `usageFromJSON`,
  `completionFromHeader`, `estimatePromptTokens`, `readLimitedBody`,
  `writeSSEError`, `copyForwardHeaders`, `contentTypeOrJSON`,
  `maxUpstreamResponseBodyBytes`, `statusWriter`) used only by
  `chat_proxy.go` — migrated. `go test ./internal/router/... -count=2
  -race` green after fixup. PR also rebased onto the in-flight M2-4 merge
  (`aa4df53`, which added the `ReadStore` interface to the same
  `server.go`).

The security-reviewer lens approved M3-6 and M3-9 outright; M3-6's INFO
notes confirmed the doc disclosed only public values (rate limits,
heartbeat thresholds) that don't enable any privilege escalation, and
M3-9's security pass verified the file split preserved every fail-closed
auth predicate, OAuth state/CSRF handling, and the `operatorBearerAuthorized`
constant-time compare.

## Items intentionally NOT in this milestone

- **M3-7** (specs index + CLAUDE.md de-version) — already shipped as **QW-7**.
- **M3-10** (billing-recorder type extraction) — deferred until M2-1
  (`logRowWithBilling`) settles. Pairs naturally with that work; doing it
  before risks merge churn on `phase4-coordinator/internal/buyer/server.go`.

## What's still queued — Phase 2 + Phase 3 (5 + 2 PRs)

Open these in a follow-up `/autopilot` session.

### Phase 2 — code polish

| Task | Branch | Audit refs | Risk |
|---|---|---|---|
| M3-1 | `fix/m3-1-sargable-batched-prunes` | PERF-3 | Money-path adjacent (retention DELETEs). Human review required. |
| M3-8a | `refactor/m3-8a-unify-writeerror` | CODE-4 | Client-facing error envelope shape. Human review (API surface). |
| M3-8b | `refactor/m3-8b-swift-dead-code` | CODE-5 | Swift — provably-dead branch deletion. |
| M3-8c | `refactor/m3-8c-capacity-tier-json` | CODE-6 | Gateway storage round-trip refactor. |
| M3-8d | `refactor/m3-8d-tier2-catalog-di` | TEST-4 + SECU-3 hardening | Security-relevant (model-hash verification path). Human review required. |

### Phase 3 — multi-system / external touch

| Task | Branch | Audit refs | Notes |
|---|---|---|---|
| M3-4 | `chore/m3-4-swift-nio-bump-and-ci` | DEPE-3, DEPE-6, TEST-7 | Reconcile with the in-flight Dependabot `swift-nio-2.101.0` PR (rebase on top, or close it in favor of M3-4). |
| M3-2 | `feat/m3-2-operator-key-split` | SECU-4 + DEVE-7 | Security migration. **GATE A names locked**: `auth.gateway_service_token` (coordinator), `coordinator.service_token` (gateway), env vars `GATEWAY_SERVICE_TOKEN` / `COORDINATOR_SERVICE_TOKEN`. |

## Operator decisions locked this session

### GATE A — M3-2 config key names

The operator-key split needs new config field names on both sides. Locked:

- **Coordinator side:** `auth.gateway_service_token` (env: `GATEWAY_SERVICE_TOKEN`)
- **Gateway side:** `coordinator.service_token` (env: `COORDINATOR_SERVICE_TOKEN`)

The next autopilot session writes M3-2 against these names verbatim — no
re-confirmation needed.

### GATE B — M3-6 doc placement

Default was applied (canonical doc + short README pointer) and then refined
during the audit-fixup round: the canonical doc moved out of
`audits/2026-06-10/` into `doc/provider-economics.md` so it's a long-lived
provider reference rather than a dated audit deliverable. The console-page
alternative is still deferred — needs DOM work the prospective-provider
audience does not yet require.

## Operator actions before re-invoking autopilot

1. **Future operator action (Phase 3, after M3-2 merges)** — the actual
   credential cutover. M3-2 ships only a backward-compatible bridge; the
   operator runs the live cutover on Pearl:
   - Mint a new service token (32 random bytes).
   - Set `GATEWAY_SERVICE_TOKEN=<new>` in `/etc/macprovider/coordinator.env`.
   - Set `COORDINATOR_SERVICE_TOKEN=<new>` in `/etc/macprovider/gateway.env`.
   - SIGHUP both services.
   - Watch the coordinator audit log: every gateway-originated internal call
     should now report `key=service_token` (not `key=operator_key`).
   - After 24 h with zero `key=operator_key` entries from gateway origin,
     rotate the legacy `OperatorKey` value.
2. **Future operator action (Phase 3, after M3-4 merges)** — once the new
   `swift-tests` CI job has run cleanly on a few PRs, flip it to required in
   GitHub branch-protection settings for `main`. M3-4 ships the job as
   non-blocking to let the team confirm macos-runner minute cost first.

## Suite status

- **phase3-binary (Swift):** not exercised by Phase 1 (no Swift code
  touched). M3-4 (Phase 3) will run `swift test --parallel`.
- **phase4-coordinator (Go):** not exercised by Phase 1. M3-1 (Phase 2)
  will exercise it.
- **phase5-gateway (Go):** `go test ./internal/router/... -count=2 -race`
  green on PR #55 pre-merge; no behavior change.

## Quick links

- Audit: [`audits/2026-06-10/REPO_AUDIT.md`](./REPO_AUDIT.md)
- Milestone 1 handoff: [`MILESTONE_1_HANDOFF.md`](./MILESTONE_1_HANDOFF.md)
- Milestone 2 handoff: PR [#51](https://github.com/Augustas11/macprovider/pull/51) (merged as `7c8ea80`)
- Decision log: [`beta/DECISION_CRITERIA.md`](../../beta/DECISION_CRITERIA.md) — Entries 63 (M3-5), 64 (M3-3), 65 (M3-6), 66 (M3-9)
