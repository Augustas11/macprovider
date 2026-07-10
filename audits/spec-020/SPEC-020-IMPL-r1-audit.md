# SPEC-020 v0.1.4 IMPL — Round 1 audit narrative

**Audited IMPL:** commit `37514b9` on `impl/spec-020-provider-autoupdate`
**Worktree:** `/Users/augstar/macprovider-spec-020-impl`
**Round:** r1
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect | NEEDS REVISION | 0 | 4 | 0 |
| B code | NEEDS REVISION | 0 | 6 | 1 |
| C security | NEEDS REVISION | 0 | 2 | 5 |

**Totals: 0 CRITICAL, 12 HIGH, 6 MEDIUM.**

Smoke status: swift test 651/0, go test ws+pool PASS, watchdog syntax PASS, binaryVersion 1.7.0, SPEC unmodified. IMPL is structurally correct; the audit findings target specific normative-invariant violations.

## Convergent themes

### T-1: Trust-state lifecycle broken (3 lanes, all HIGH)

A-r1-H-1 + A-r1-H-2 + A-r1-H-3 + C-r1-H-1. The single load-bearing safety invariant from SPEC R-1 / live trust-state predicate is not faithfully implemented.

- **A-r1-H-1**: `acceptCoordinatorSession` ([CoordinatorClient.swift:1287](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1287)) calls `runAutoupdateIfEligible` unconditionally even for notify-only trust states. `runAutoupdateIfEligible` inserts the target into `autoupdateAttemptedTargets` ([CoordinatorClient.swift:1631](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1631)) BEFORE trust gating, then `AutoUpdater` performs trusted-root/observer/cooldown work BEFORE `ensureEligible` ([AutoUpdater.swift:96](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:96)). Initial ineligible trust falls into `trustStateLost` which records cooldown ([AutoUpdater.swift:150,246](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:150)). SPEC line 106 says notify-only MUST NOT trigger cooldown/state mutation. **Fix**: pre-gate before calling `runAutoupdateIfEligible`; for initial notify-only verdicts, emit notify/status only.

- **A-r1-H-2 + C-r1-H-1** (convergent): late trust-loss between marker/backup commit and launchctl bootstrap does NOT execute rollback. `preserveMarkerAndSwap` commits backup + `pending.json` then renames the live binary ([AutoUpdater.swift:167](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:167)); if trust lost at line 145 or 179, the catch at line 150 only records `trust_state_lost` failure — does NOT call `restoreBackup`, clear pending, or remove backup. SPEC lines 64-90 + AC-V0.1-22 require rollback. **Fix**: track committed state through pipeline; on `trustStateLost`, if any of marker/backup/swap committed, restore via `AutoUpdateMarkerStore.restoreBackup`, clear marker/backup, release lock, suppress launchctl bootstrap.

- **A-r1-H-3**: `autoupdateTrustState` is computed once from auth payload ([CoordinatorClient.swift:1264](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1264)) and never updated. `currentAutoupdateTrustState` returns the stored value ([CoordinatorClient.swift:1658](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1658)). AEAD decrypt failure in relay sends NAK but doesn't demote trust ([InferenceRelay.swift:57](phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:57)). SPEC line 64 explicitly says NOT a handshake-time snapshot. **Fix**: recompute trust from current session facts at each predicate call, or update/demote on encrypted-leg/token/attestation/session invalidation events with stable reasons (`encrypted_leg_invalidated`, etc.).

### T-2: Rollback backup crash-safety (B+C convergent)

B-r1-H-2 + C-r1-M-1. `AutoUpdater.copyNoFollow()` fsyncs file then renames ([AutoUpdater.swift:229-231](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:229)) but never fsyncs the parent directory. Also doesn't lstat/verify binary-dir ancestry as provider-owned mode 0700 before placing the backup. SPEC R-4.7 requires fsync(file) + fsync(parent) and trusted-ancestry. **Fix**: route backup preservation through `AutoUpdateMarkerStore.atomicCopyNoFollow` (the hardened helper) or add parent-dir fsync + ancestry check.

### T-3: Recovery state machine gaps (B internal cluster + C-r1-M-2)

- **B-r1-H-3**: `readPending()` ([AutoUpdateMarker.swift:157](phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift:157)) only rejects symlink/hardlink + JSON-decodes. Missing: UUIDv4 validation, normalized target check, absolute-path/no-trailing-slash check, decimal mode bounds, lowercase 64-hex SHA, RFC3339 deadline tolerance. `validateBackup()` even accepts uppercase SHA via `.lowercased()` ([AutoUpdateMarker.swift:182](phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift:182)). Watchdog `read_marker()` same issue ([watchdog.sh:199](ops/macprovider-watchdog/watchdog.sh:199)). **Fix**: add shared marker validator; malformed → R-4.10 orphan-recovery path.

- **B-r1-H-4**: Provider startup recovery scan runs AFTER coordinator handshake instead of BEFORE. `completeSuccessfulAutoupdateIfPending()` called only after auth/session setup ([CoordinatorClient.swift:1285](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1285)) and only when both `pending.json` exists AND `targetVersion == binaryVersion` ([CoordinatorClient.swift:1312](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1312)). Watchdog exits immediately if `pending.json` absent ([watchdog.sh:328](ops/macprovider-watchdog/watchdog.sh:328)), so sentinel-without-pending and stale-backup-without-pending are NOT recovered. SPEC R-4.10a requires scan-before-handshake covering all 3 states. **Fix**: dedicated startup recovery routine BEFORE handshake; scan pending markers, success sentinels, stale rollback backups; handle all 3 invariant states.

- **B-r1-H-5**: `completeSuccessfulUpdate()` ([AutoUpdateMarker.swift:240](phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift:240)) writes sentinel → unlink pending → delete backup → remove lock → DELETES sentinel; the success event is emitted only after this helper returns. Crash after pending unlink OR after sentinel deletion leaves no recoverable success state. SPEC R-4.10a says sentinel MUST be durable recovery anchor until event emission, and on next startup, sentinel-only / sentinel-binary-mismatch states must be handled. **Fix**: keep sentinel until AFTER event emission; handle sentinel-only states on next startup recovery scan.

- **B-r1-H-6**: Watchdog restore emits only `orphaned_pending_marker` ([watchdog.sh:299](ops/macprovider-watchdog/watchdog.sh:299)). Enum has the 3 post-start classes ([AutoUpdateEvent.swift:53](phase3-binary/Sources/macprovider-cli/AutoUpdateEvent.swift:53)) but observer doesn't classify by crash / start / health / rejoin per AC-V0.1-10. **Fix**: add post-start observation state and map each rollback trigger to the required failure class (`post_start_crash`, `post_start_health_failed`, `post_start_rejoin_timeout`).

- **C-r1-M-2**: Watchdog `restore` ([watchdog.sh:299](ops/macprovider-watchdog/watchdog.sh:299)) trusts marker-supplied `backup_path` + `target_path` without deriving expected `.macprovider-cli.rollback-<update_id>` shape, and without rejecting paths outside binary/trusted dirs. **Fix**: derive expected backup path from `target_path` + `update_id`, require exact match, canonicalize/validate parent directories.

### T-4: Convergence boundary not enforced (A-r1-H-4, standalone HIGH)

Rollback-observer availability is only `fileExists` for the watchdog plist or a test env var ([AutoUpdater.swift:301](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:301)); does NOT detect a disabled/unloaded watchdog. Separately, `restartLaunchdIfInstalled` silently returns when LaunchAgent plist is absent ([AutoUpdater.swift:308](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:308)) — AFTER the binary may have been swapped. SPEC line 36 + R-4.4 + R-3.7 require fail-closed before download/drain/swap. **Fix**: eligibility requires launchd-managed provider + loaded/enabled rollback observer; else fail closed with `rollback_observer_unavailable` / unsupported-topology reason before any state mutation.

### T-5: ACL checks missing (C-r1-H-2, standalone HIGH)

Both `AutoUpdateMarker.swift:273` and `watchdog.sh:167` check lstat + UID + mode + chmod only; SPEC R-4.9 + AC-V0.1-21 require rejecting non-owner-write ACLs. **Fix**: inspect ACLs for every trusted-root ancestor in both Swift (`acl_get_link_np()` + check entries) and watchdog (`ls -le` parse).

## Cooldown bug (B-r1-H-1, standalone HIGH)

`recordCooldown()` increments attempt + applies formula ([AutoUpdateMarker.swift:225](phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift:225)), AND callers `fail()` records again ([AutoUpdater.swift:120,129,137,153,246](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:120)). Double-counted: first failure becomes attempt 2 / 600s instead of attempt 1 / 300s. Violates R-1.6 + R-4.2. **Fix**: make exactly one path own cooldown persistence per failed attempt.

## Non-convergent MEDIUMs

- **C-r1-M-3**: Persisted signed-policy state: `updateSignedPolicy` defined ([AutoUpdateMarker.swift:253](phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift:253)) but never called. `GitHubRelease` decodes only `tag_name` + assets ([SelfUpdate.swift:416](phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:416)); `prepareValidatedUpdate` never persists observed signed policy. **Fix**: decode signed policy from signed release metadata, persist max/union after validation, add tests for attempted lowering/removal.

- **C-r1-M-4**: Event reasons can include raw URLs/paths/error data. `String(describing: error)` ([AutoUpdater.swift:130,154](phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:130)); `UpdateError.description` includes URLs, checksum values, archive entries ([SelfUpdate.swift:453](phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:453)). Redactor narrow pattern list ([AutoUpdateEvent.swift:214](phase3-binary/Sources/macprovider-cli/AutoUpdateEvent.swift:214)). **Fix**: map errors to stable reason codes before coordinator emission; strip URL queries/fragments, absolute paths, raw checksum material; add no-leak tests.

- **C-r1-M-5**: Marker/backup reads use lstat-then-open TOCTOU. `readPending` lstat-checks then `Data(contentsOf:)` ([AutoUpdateMarker.swift:157,178,409](phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift:157)). **Fix**: replace with `open(O_RDONLY|O_NOFOLLOW)` + `fstat` + verify inode/mode/link/owner + read from fd.

- **B-r1-M-1**: AC coverage below AC-V0.1-1..23. `AutoUpdateTests.swift` covers version validation, optional event-field drops, opt-out, cooldown keying, happy-path success cleanup, release tag fallback. Missing: AC-10 rollback classifications, AC-17 `event_payload_too_large` fallback, AC-19 orphan recovery, AC-20 corrupt backup recovery, AC-22 trust-loss after auth, AC-23 crash-between-cleanup-step recovery. **Fix**: add focused unit/integration tests for each missing AC including watchdog recovery tests.

## Trend

This is the first IMPL round. 12H is a meaningful count but they cluster into 5 themes, 3 of which are convergent across lanes (T-1 trust lifecycle is the dominant one and it's the SAME root cause that took 3 SPEC audit rounds to converge — IMPL inherited the same understanding gap). The fixes are all concrete with file:line citations.

Expect r2 to land at 0/0/0–2H if absorption is faithful.

## Next action

Absorb r1 findings into the IMPL → commit on top of `37514b9`. Then fire r2 audit across all three lanes.

Absorption prompt: `specs/AUDIT_SPEC_020_v0_1_IMPL_r1_ABSORPTION_PROMPT.md`.

## Raw artifacts

- Lane A: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-1-audit-prompt-per-lane-you-are-a-2026-06-29T16-25-04-521Z.md`
- Lane B: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-1-audit-prompt-per-lane-you-are-a-2026-06-29T16-25-41-678Z.md`
- Lane C: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-1-audit-prompt-per-lane-you-are-a-2026-06-29T16-24-38-191Z.md`
