# Milestone 3 — Phase 2 + 3 handoff (open)

Closes out Milestone 3 from `audits/2026-06-10/REPO_AUDIT.md`. Phase 1 (M3-3,
M3-5, M3-6, M3-9) is on `main` per [`MILESTONE_3_HANDOFF.md`](./MILESTONE_3_HANDOFF.md);
this doc covers the 7 PRs opened by the Phase 2 + 3 autopilot run. All seven need
human review before merge.

## PR list

### Phase 2 — code polish (5 PRs)

| # | PR | Branch | Audit refs | Notes |
|---|---|---|---|---|
| M3-1 | [#66](https://github.com/Augustas11/macprovider/pull/66) | `fix/m3-1-sargable-batched-prunes` | PERF-3 | **Option A applied** — kept `julianday()` predicate because `time.RFC3339Nano` writes are variable-width (`.` < `Z` makes lexicographic compare silently wrong at the boundary). Added batched LIMIT-5000 loop releasing the write lock between batches. Three pruners updated: `requestlog/store.go` (request_log + request_idempotency_keys), `audit/store.go` (audit_log). 12k-row + concurrent-INSERT tests green; no SQLITE_BUSY. Sargable comparison deferred — file as M3 follow-up. |
| M3-8a | [#64](https://github.com/Augustas11/macprovider/pull/64) | `refactor/m3-8a-unify-writeerror` | CODE-4 | 4-field envelope (`message`/`type`/`param`/`code`) locked across buyer/gateway/billing. Gateway router `server.go:732` adds `param:nil`; billing `endpoints.go:527` adds `billingErrorType(status)` helper. Per-service struct duplication kept intentional per audit guidance. |
| M3-8b | [#65](https://github.com/Augustas11/macprovider/pull/65) | `refactor/m3-8b-swift-dead-code` | CODE-5 | Single callsite verified — `connectAndRunLegacy` is only called from inside the `else { wsTunneledMode == false }` branch, so the inner `if wsTunneledMode { ... }` true-branch was provably dead. Deleted + the no-op do/catch rethrow wrapper. 172 Swift tests green. |
| M3-8c | [#63](https://github.com/Augustas11/macprovider/pull/63) | `refactor/m3-8c-capacity-tier-json` | CODE-6 | `GetCapacityTier`/`SetCapacityTier` moved from `fmt.Sscanf`/`Sprintf` with hand-rolled `{"tier":%d,"signals":%q}` format to `encoding/json` via a `capacityTierDTO`. Matches the sibling `KillSwitchState` pattern in the same file. Edge-case test (`\n`, `\t`, `"`, `\\`, `™`) + the JSON-format-mismatch failure-mode test documented. |
| M3-8d | [#68](https://github.com/Augustas11/macprovider/pull/68) | `refactor/m3-8d-tier2-catalog-di` | TEST-4 (supports SECU-3 hardening) | tier2 `var global` promoted into a `Catalog` struct + `atomic.Pointer[Catalog]` shim preserving SIGHUP reload semantics. Functional options on `ws.Server` and `pool.Registry` via `WithCatalog(*Catalog)`. Existing wiring unchanged via default-to-singleton. New `TestCatalogParallel` + atomic-swap reload test both pass under `-race`. `ResetForTest` retained, deprecated-in-comment. **Touches model-hash verification — human review required per AGENTS.md.** |

### Phase 3 — multi-system / external touch (2 PRs)

| # | PR | Branch | Audit refs | Notes |
|---|---|---|---|---|
| M3-4 | [#71](https://github.com/Augustas11/macprovider/pull/71) | `chore/m3-4-swift-nio-bump-and-ci` | DEPE-3, DEPE-6, TEST-7 | **Part A (swift-nio 2.65→2.101) already shipped via Dependabot PR #25 + Sendable fix #32.** This PR delivers Part B (drop `swift-log` — `grep -rn "import Logging" phase3-binary/Sources/` returned empty, dep was declared/linked/never used) and Part C (new non-blocking `swift-tests` macos-15 CI job). 172 Swift tests green. **Operator: flip `swift-tests` to required-checks in branch protection after the job runs cleanly on 3-5 PRs.** |
| M3-2 | [#73](https://github.com/Augustas11/macprovider/pull/73) | `feat/m3-2-operator-key-split` | SECU-4, DEVE-7 | **Three parts in one PR.** Part A: coordinator `env:NAME` config indirection + `EnvironmentFile=/etc/macprovider/coordinator.env` on the systemd unit + dual-form example. Part B: monitor de-rooted (`User=macprovider`); script reads `os.environ["OPERATOR_KEY"]` via the same EnvironmentFile (Option 1) — regex over `coordinator.yaml` removed. Part C: backward-compatible bridge for the operator-key split — coordinator accepts EITHER `OperatorKey` OR `gateway_service_token` on internal endpoints, gateway prefers `service_token` if set with fallback to `OperatorKey`, gateway admin plane stays on `OperatorKey`. **GATE A locked names used verbatim:** `auth.gateway_service_token` (coordinator side, env `GATEWAY_SERVICE_TOKEN`) + `coordinator.service_token` (gateway side, env `COORDINATOR_SERVICE_TOKEN`). Audit-log line `event=internal_bearer_accepted key=<service_token\|operator_key>` lets operator watch the cutover converge. Test `TestPoolzAcceptsServiceTokenAndAuditLogs` covers all three rows (accepted operator_key, accepted service_token, rejected wrong bearer). **Touches auth path — human review required per AGENTS.md.** |

## Operator cutover procedures

### M3-2 cutover (post-merge, operator action on Pearl)

Step | Command / change | Verify
---|---|---
1. Deploy code with both new fields unset | (normal deploy) | Behavior identical to today (uses `OperatorKey` for everything).
2. Mint a service token | `openssl rand -hex 32` | Stash securely.
3. Plumb the token (BOTH services) | Set `GATEWAY_SERVICE_TOKEN=<new>` in `/etc/macprovider/coordinator.env` AND `COORDINATOR_SERVICE_TOKEN=<new>` in `/etc/macprovider/gateway.env` | Both env files exist, mode 0600.
4. SIGHUP both | `systemctl reload macprovider-coordinator macprovider-gateway` | (no-op if reload not implemented; restart instead).
5. Watch the audit log | `journalctl -u macprovider-coordinator -f \| grep internal_bearer_accepted` | Every gateway-origin internal call should now show `key=service_token`.
6. Wait 24h with zero `key=operator_key` from gateway origin | passive monitoring | Confirms cutover stable.
7. Rotate `OperatorKey` | regenerate value, set in `/etc/macprovider/coordinator.env` + `/etc/macprovider/gateway.env`, SIGHUP both | Gateway admin plane keeps working (reads new value); gateway upstream keeps working (unchanged `service_token`).

The legacy `OperatorKey` path is NOT removed in this milestone; removing the
fallback is a follow-up after at least one full cutover cycle.

### M3-4 branch-protection flip (post-merge, after 3-5 clean runs)

The `swift-tests` CI job ships **non-blocking** so macos-runner minute cost can
be measured before commitment. Operator action:

1. Confirm the job runs cleanly on 3-5 subsequent PRs (any PR touching
   `phase3-binary/` or its dependencies will exercise it).
2. GitHub → Repo Settings → Branches → `main` branch-protection rule → add
   `phase3-binary (swift test)` to the required checks list.

## Items intentionally NOT in this milestone

- **M3-7** (specs index + CLAUDE.md de-version) — already shipped as **QW-7**.
- **M3-10** (billing-recorder type extraction) — deferred until M2-1
  (`logRowWithBilling`) fully settles. The M2-1a (`advanceToNextProvider` extract)
  PR has merged but the M2-1b (`transportResult` + classifiers) PR was still
  draft at the time of this run.

## Follow-ups filed by Phase 2 / 3 work

- **M3-1 follow-up:** sargable `ts_utc` direct comparison. The variable-width
  `time.RFC3339Nano` makes lexicographic compare silently wrong at the boundary
  (`.` ASCII 0x2E < `Z` ASCII 0x5A). Normalizing every INSERT to fixed-width
  `Format("2006-01-02T15:04:05.000000000Z07:00")` is doable but touches every
  billing log/audit INSERT site. File as a dedicated PR after a quiet window.
- **M3-2 follow-up:** remove the legacy `OperatorKey` fallback path from both
  services. Cannot run until at least one full cutover cycle is observed.
- **M3-9 follow-up** (carried from Phase 1): disclosure-as-subpackage extraction
  in `phase5-gateway/internal/router/`; server_test.go cluster split.

## Suite status

- **phase3-binary (Swift):** `swift test --parallel` → 172 tests, 0 failures.
- **phase4-coordinator (Go):** `go test ./... -count=2 -race` green on every
  PR; `go vet ./...` clean.
- **phase5-gateway (Go):** `go test ./... -count=2 -race` green on every PR;
  `go vet ./...` clean.

## Quick links

- Audit: [`REPO_AUDIT.md`](./REPO_AUDIT.md)
- Phase 1 handoff: [`MILESTONE_3_HANDOFF.md`](./MILESTONE_3_HANDOFF.md)
- Milestone 1 handoff: [`MILESTONE_1_HANDOFF.md`](./MILESTONE_1_HANDOFF.md)
- Decision log: [`beta/DECISION_CRITERIA.md`](../../beta/DECISION_CRITERIA.md) — Entries 67 (M3-1), 68 (M3-8a), 69 (M3-8b), 70 (M3-8c), 71 (M3-8d), 72 (M3-4), 73 (M3-2)
