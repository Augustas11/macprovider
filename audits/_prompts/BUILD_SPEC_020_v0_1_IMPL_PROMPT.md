# BUILD_SPEC_020_v0_1_IMPL_PROMPT — Provider Autoupdate

You are implementing SPEC-020 v0.1.4 LOCKED in this worktree
(`/Users/augstar/macprovider-spec-020-impl`, branch
`impl/spec-020-provider-autoupdate`, based on `origin/main` at `ffb40dc`).

The SPEC is normative — every R-N.M numbered requirement and every
AC-V0.1-N acceptance criterion is in scope. Read
`specs/SPEC-020-provider-autoupdate.md` end-to-end before writing code.

## Scope summary (per SPEC §Goal)

Wire the existing manual `SelfUpdate` flow into automatic invocation
when the coordinator advertises a newer `recommended_binary_version`.
The cryptographic update mechanism already exists at
`phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`; this IMPL
adds:

- **Trigger semantics** — live trust-state predicate + version regex/length validation + NORMALIZED_TARGET normalization + GitHub release-by-tag resolution + cooldown backoff math
- **Drain semantics** — provider-initiated drain distinct from coord-initiated, `state_update.reason = "autoupdate_to_<NORMALIZED_TARGET>"` discriminator, `drain_status.phase:"timeout_skipped"` gated on `autoupdate_drain_extensions:true` capability
- **Trusted state root** — `$HOME/.local/share/macprovider/autoupdate/` provider-UID-owned mode 0700, no symlinks/ACLs/mount-crossings, `update.lock` (flock), `pending.json` (atomic write + fsync), rollback backup
- **Crash recovery state machine** — orphaned-pending-marker, orphaned-success-sentinel, rollback-backup-corrupt
- **Rollback observer** — extend `ops/macprovider-watchdog/watchdog.sh` (or equivalent in-process observer) to scan markers, restore on failure, validate hash/owner/mode
- **Observability** — structured `last_autoupdate_event` with `source`/`outcome`/`phase`/`failure_class` enums, 4096-byte bound on event object alone, redaction invariant
- **Opt-out** — accept BOTH `auto_update_enabled` / `MACPROVIDER_AUTO_UPDATE_ENABLED` (existing) AND `autoupdate.enabled` / `MACPROVIDER_AUTOUPDATE` (SPEC); explicit-disabled wins
- **Signed-policy monotonic persistence** — `persisted_signed_policy_minimum` (max) and `persisted_signed_policy_revoked` (union) write-once-grow-only
- **Coordinator wire amendments** — accept `autoupdate_drain_extensions:true` advertise from coord; accept `last_autoupdate_event` from provider on heartbeat / `state_update`

## What's already in place (do NOT rewrite)

The cryptographic update path is implemented and proven at:

- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` — GitHub Releases lookup (currently uses `/releases/latest`; you'll need to add release-by-tag for coord-triggered), ECDSA P-256 pinned-pubkey verification on `checksums.txt.sig`, SHA-256 against signed checksums, HTTPS + GitHub-host validation, path-traversal-safe tarball extraction, `self-test` invocation on new binary before swap, POSIX rename, launchctl bootout/bootstrap, 1h cached latest-release lookup.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1232-1236` — current notify-only branch (`"A newer version is available... Run 'macprovider-cli update' to upgrade."`). Wire this into automatic invocation.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:168` — `binaryVersion = "1.6.1"` constant. **Bump to `"1.7.0"`** as part of this IMPL (per operator decision: minor bump because autoupdate is a new operator-facing feature).
- `ops/macprovider-watchdog/watchdog.sh` — existing rollback observer candidate. Extend to handle SPEC-020 markers + rollback path.

## Concrete file-level deliverables

Add or modify (codex MUST decide actual file split based on Swift package boundaries; below is illustrative):

1. **`phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`** (new) — orchestrator for the autoupdate sequence: eligibility check → cooldown check → release-by-tag resolution → download via SelfUpdate primitives → drain → marker/backup creation → swap → restart. Holds `autoupdate_trust_state` and live-predicate hooks.

2. **`phase3-binary/Sources/macprovider-cli/AutoUpdateTrustState.swift`** (new) — trust-state matrix evaluator with live re-evaluation hooks. The 5 re-eval points (download / drain / marker / swap / launchctl bootstrap) call into this.

3. **`phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift`** (new) — pending.json schema + atomic write + lock acquisition + crash-recovery state machine + trusted-state-root invariants (O_NOFOLLOW, O_EXCL, mode 0700/0600, mount-boundary, ACL checks).

4. **`phase3-binary/Sources/macprovider-cli/AutoUpdateEvent.swift`** (new) — `last_autoupdate_event` JSON envelope with strict enums, 4096-byte bound, redaction priority list, optional-field-drop logic.

5. **`phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`** (modify) — add `runByTag(tag:)` and asset-missing handling (`failure_class:"release_asset_missing"`); existing `run(checkOnly:)` stays for manual command.

6. **`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`** (modify) — line 1232 notify-only branch now invokes AutoUpdater. Add `autoupdate_drain_extensions` parsing from `hello_ack` / v2 `auth_response`. Add `last_autoupdate_event` field emission on heartbeat / `state_update`. Bump `binaryVersion` line 168 to `"1.7.0"`.

7. **`phase3-binary/Sources/macprovider-cli/UpdateCommand.swift`** (modify if needed) — the existing manual `update` subcommand should share AutoUpdater primitives where it makes sense (per SPEC's comparator-binding requirement).

8. **`phase4-coordinator/internal/...`** (modify) — accept and round-trip `last_autoupdate_event` field on heartbeat / `state_update`; advertise `autoupdate_drain_extensions:true` in `hello_ack` and v2 `auth_response`; accept `drain_status.phase:"timeout_skipped"` (currently `ParseDrainStatus` rejects unknown values — extend).

9. **`ops/macprovider-watchdog/watchdog.sh`** (modify) — scan trusted state root for pending.json on each tick. If marker present + lock not held + observer-process not running → orphaned-recovery (validate backup hash, restore via launchctl bootstrap of prior binary, atomically clear marker). Add the various failure_class emissions.

10. **`ops/macprovider-watchdog/live.malibu.provider-watchdog.plist.template`** (probably modify) — if the watchdog gets new dependencies / paths to scan.

11. **Tests** — Swift tests under `phase3-binary/Tests/macprovider-cliTests/` covering AC-V0.1-1 through AC-V0.1-23. Coordinator Go tests under `phase4-coordinator/internal/...` for the wire extensions. Smoke shell script(s) under `phase3-binary/Scripts/` or `test/integration/` if useful.

## Specific normative invariants to honor (do NOT relax)

- **Live trust-state re-evaluation at 5 points** is the load-bearing safety invariant. If you find the IMPL only checks once, that is wrong.
- **`O_NOFOLLOW` + `O_EXCL` + `fsync` + atomic rename** for marker / backup / sentinel files. No `cp`. No naive `write_atomic` without O_NOFOLLOW.
- **`SelfUpdate.compareSemver`** is the ONE semver comparator. Do not introduce a parallel comparator anywhere (manual update, coord recommendation, downgrade refusal, status display, cooldown key all use this one).
- **`NORMALIZED_TARGET`** propagation to release lookup, marker, drain reason, cooldown key — must be consistent.
- **Cooldown formula**: `min(300s × 2^(attempt-1), 3600s)` keyed by `(NORMALIZED_TARGET, failure_class)`. 3600s cap is fixed in v0.1.0.
- **Crash-recovery state machine** must handle every documented scenario (orphan, success sentinel, corrupt backup).
- **`failure_class` enum exhaustive** — every `failure_class:"X"` in body must appear in R-6.5 enum and in the IMPL's emit-side enum/switch.
- **Opt-out compatibility** — BOTH legacy and SPEC config keys + env vars MUST be honored; explicit-disabled wins.
- **Signed-policy monotonic persistence** — `persisted_signed_policy_minimum`/`revoked` write-once-grow-only; signed releases CANNOT shrink.
- **Eligible only when v2 + pinned + encrypted-leg + (Tier2 satisfied or not required) + (token validated or not configured)** per the normative table. Notify-only otherwise.

## Process

1. Read the SPEC end-to-end. Read existing `SelfUpdate.swift`, `CoordinatorClient.swift`, and `ops/macprovider-watchdog/` to understand the foundation.
2. Implement IMPL in the worktree. Bias toward small Swift files with clear responsibility split (AutoUpdater orchestrator, TrustState evaluator, Marker manager, Event emitter).
3. Coordinator-side Go changes: accept `last_autoupdate_event`, advertise `autoupdate_drain_extensions:true`, accept `drain_status.phase:"timeout_skipped"`.
4. Bump `binaryVersion` constant `"1.6.1"` → `"1.7.0"`.
5. Add tests for every AC-V0.1-N. Coordinator tests for wire extensions.
6. Run `swift test` in `phase3-binary/` and `go test ./...` in `phase4-coordinator/`. Both green.
7. Output: a single commit (or small handful of well-scoped commits) on `impl/spec-020-provider-autoupdate`. No SPEC edits.

## Coordinator + watchdog config: required vs deferred

Some IMPL bits are operator-side and may live outside this PR (e.g., setting `coordinator_advertised_version.latest_binary_version` on the live coordinator). What MUST land in this PR vs what can ship as a deploy artifact:

- IN this PR: coordinator code accepting / round-tripping `last_autoupdate_event`, advertising `autoupdate_drain_extensions:true`, accepting `timeout_skipped` drain phase; provider code implementing the autoupdate orchestration; watchdog code implementing the rollback observer; binaryVersion bump to 1.7.0.
- OUTSIDE this PR (deploy-time only): the operator setting the actual `latest_binary_version` advertised by the production coordinator; the GitHub release v1.7.0 itself (created by the tag-triggered workflow after this PR merges).

## Output expectation

A complete, compilable IMPL in `/Users/augstar/macprovider-spec-020-impl`. Swift package builds. Go modules build. Tests pass. No TODO stubs in production code paths; if something is genuinely deferred, mark it via a structured event / `failure_class` rather than `// TODO`. SPEC §Open Questions are answered or explicitly deferred to v0.2 — they should NOT block IMPL completion.
