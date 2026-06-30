# SPEC-020 v0.1.4 IMPL — Round 1 audit prompt (per-lane)

You are auditing the **IMPL** of SPEC-020 v0.1.4 LOCKED at commit
`37514b9` on `impl/spec-020-provider-autoupdate` in worktree
`/Users/augstar/macprovider-spec-020-impl`.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM before the IMPL PR opens.**
Findings get absorbed and another round fires.

## What you are auditing

The IMPL of SPEC-020 v0.1.4 provider autoupdate. The SPEC is normative
and is at `specs/SPEC-020-provider-autoupdate.md` (LOCKED, do not
audit). Your job: does the IMPL faithfully execute every R-N.M
normative requirement and every AC-V0.1-N acceptance criterion?

The IMPL changes (14 files, +1997 / -133):

**New Swift files** (`phase3-binary/Sources/macprovider-cli/`):
- `AutoUpdater.swift` (336 lines) — orchestrator
- `AutoUpdateTrustState.swift` (104 lines) — trust-state matrix + live predicate
- `AutoUpdateMarker.swift` (432 lines) — marker/backup/lock/recovery
- `AutoUpdateEvent.swift` (242 lines) — structured event envelope

**Modified Swift files**:
- `SelfUpdate.swift` (+148 lines) — added `runByTag` + `release_asset_missing`
- `CoordinatorClient.swift` (+193 lines) — auto-invocation wiring + `autoupdate_drain_extensions` parsing + `last_autoupdate_event` emission + binaryVersion 1.6.1 → 1.7.0
- `MacProviderCore/Config.swift` (+6) — opt-out compat for both legacy + SPEC keys

**Coordinator (Go)**:
- `internal/ws/messages.go` (+105) — `AutoupdateDrainExtensions` on HelloAck/AuthResponse; `LastAutoupdateEvent` on Heartbeat/StateUpdate; `timeout_skipped` drain phase accepted
- `internal/ws/messages_test.go` (+69) — tests for above
- `internal/ws/server.go` (+54) — advertise `AutoupdateDrainExtensions:true`; round-trip event
- `internal/pool/provider.go` (+30) — pool-side event accommodation

**Watchdog (shell)**:
- `ops/macprovider-watchdog/watchdog.sh` (+228) — rollback-observer extensions

**Tests**:
- `phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift` (173 lines, new)
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift` (+10)

## Smoke status

- `swift test` 651 tests pass / 0 fail
- `go test ./internal/ws/... ./internal/pool/...` PASS
- `bash -n ops/macprovider-watchdog/watchdog.sh` PASS
- `binaryVersion` constant: 1.7.0 ✓
- SPEC file unmodified ✓

## How to return your verdict

`VERDICT: READY TO MERGE` if zero blocking findings. Otherwise
`VERDICT: NEEDS REVISION` with C/H/M counts + ID-prefixed findings
(`A-r1-H-1`, `B-r1-M-1`, etc.) including file:line citations + the
SPEC R-N.M or AC-V0.1-N being violated + a concrete fix.

## Lane-specific focus

### Lane A — Codex architect

- **Live trust-state predicate completeness**: does the IMPL actually
  re-evaluate trust before EACH of the 5 phases (download, drain,
  marker, swap, launchctl bootstrap)? Or does it check once at the
  top of `AutoUpdater.run()`? File:line citations.
- **Comparator binding**: every place that compares versions
  (recommendation check, downgrade refusal, status display, cooldown
  key) MUST use `SelfUpdate.compareSemver` (per SPEC R-1.1 +
  A-r1-M-3 from SPEC audit). Trace each call site. Flag any duplicate
  comparator implementation.
- **NORMALIZED_TARGET propagation**: target normalization at one site,
  used everywhere downstream (release lookup, marker `target_version`,
  drain reason `state_update.reason`, cooldown key). Trace every use.
- **Drain protocol**: is the autoupdate drain (provider-initiated)
  distinguishable from coord-initiated drain at the wire level? Does
  it emit `state_update.reason = "autoupdate_to_<NORMALIZED_TARGET>"`?
- **Capability gate**: provider only emits `drain_status.phase:"timeout_skipped"`
  when coord has advertised `autoupdate_drain_extensions:true`. If
  capability missing, fall back to `complete`. Confirm.
- **Convergence boundary**: are opt-out + watchdog-disabled paths
  handled per SPEC's convergence-boundary paragraph?
- **Cross-spec interaction**: in-flight SPEC-018/019 streaming
  requests during drain — does the IMPL honor "in-flight takes
  precedence" per the SPEC?

### Lane B — Codex code

- **Citation verify**: any SPEC R-N.M cite in code comments must
  resolve to the SPEC's actual line numbers.
- **Trusted state root invariants**: `O_NOFOLLOW` + `O_EXCL` + mode
  0600/0700 + `fsync` + atomic rename + lstat ancestor checks for
  marker, backup, sentinel, lock. Are ALL invariants present in the
  Swift code? Specifically:
  - `AutoUpdateMarker.swift` should `open(..., O_CREAT|O_EXCL|O_NOFOLLOW)`
    on create paths.
  - `flock(LOCK_EX|LOCK_NB)` (or `fcntl(F_SETLK)`) for `update.lock`.
  - `fsync()` file + parent dir before rename.
  - lstat each ancestor of `$HOME/.local/share/macprovider/autoupdate/`
    to reject symlinks / non-owner ownership / unexpected mount
    boundaries.
- **Marker JSON schema**: `pending.json` field types match SPEC
  (update_id UUIDv4 36-char, target_version normalized, mode decimal
  int of octal, sha256 lowercase 64-hex, marker_deadline RFC3339).
- **Cooldown formula**: `min(300s × 2^(attempt-1), 3600s)`. Where
  is `attempt` stored across restarts? Is the persistence
  crash-safe?
- **Crash recovery state machine**: on every provider startup, IMPL
  scans for success sentinel + orphaned pending marker + corrupt
  rollback backup. Trace AutoUpdateMarker / watchdog code paths.
  Verify the 5-step ordered cleanup sequence on success
  (sentinel → unlink pending → delete backup → release lock → emit
  event) is atomic-recoverable on crash between any pair of steps.
- **Watchdog interaction**: `ops/macprovider-watchdog/watchdog.sh`
  must lstat marker/backup, reject symlinks, validate backup SHA-256
  before restore. Spot-check the shell.
- **failure_class enum exhaustive**: every emit-side `failure_class`
  string is in the SPEC's R-6.5 enum AND in the IMPL's enum/switch.
  No raw "other" used where a specific class would fit.
- **Event payload bound**: 4096 bytes on `last_autoupdate_event`
  object alone before embedding. Where is the size check? Where is
  optional-field-drop logic? Test coverage for `event_payload_too_large`
  fallback path.
- **Test coverage for AC-V0.1-1..23**: do `AutoUpdateTests.swift` +
  watchdog tests cover EVERY AC? Specifically:
  - AC-22 trust-state-lost between auth_response and swap
  - AC-23 success-cleanup happy path + each crash-between-step path
  - AC-10 (post_start_crash / post_start_health_failed / post_start_rejoin_timeout)
  - Orphaned-marker recovery
  - Rollback-backup-corrupt recovery
- **Opt-out compat**: BOTH `auto_update_enabled` AND `autoupdate.enabled`
  honored; BOTH `MACPROVIDER_AUTO_UPDATE_ENABLED` AND `MACPROVIDER_AUTOUPDATE`
  honored. Explicit-disabled wins. Trace `Config.swift` changes.
- **Compiler warnings**: any `warning:` in Swift build output for
  the new files? Sendable, Result-builder, deprecated APIs?

### Lane C — Codex security

- **`O_NOFOLLOW` + `O_EXCL` on all file creates**: marker, backup,
  sentinel, lock. Audit every `open()`, `creat()`, `FileManager.create*`
  in the new files. Any missed?
- **`lstat` (NOT `stat`) on ancestor checks**: stat follows symlinks,
  lstat doesn't. The trusted-state-root invariant requires lstat.
  Confirm `AutoUpdateMarker.swift` uses lstat-based checks.
- **SHA-256 verification before restore**: watchdog rollback path
  MUST hash-verify the backup before invoking restore. Audit
  `watchdog.sh` for the verification step.
- **Live trust-state matrix coverage**: does
  `AutoUpdateTrustState.swift` actually distinguish (a) v2 accepted +
  pinned + encrypted-leg succeeded + attestation satisfied + token
  validated = eligible from (b) v2 accepted + pinned + encrypted-leg
  failed = notify-only? Trace the trust-state evaluator.
- **`update_id` randomness**: UUIDv4 from cryptographic RNG (Swift
  `UUID()` uses `arc4random` which is CSPRNG — verify) vs predictable
  source. If predictable, attacker can pre-stage a success sentinel.
- **Persisted monotonic signed-policy state**: where is
  `persisted_signed_policy_minimum` / `persisted_signed_policy_revoked`
  written? Same trusted-state-root invariants apply. Audit.
- **Event payload secret-leak**: redaction priority list (drop
  `extra_metadata`, `attempt_history`, `release_url`, free-text
  `reason`) implemented? Tests for no-leak invariant?
- **Coordinator-attacker DoS**: malicious coord advertises 5000-byte
  `recommended_binary_version` → SPEC mandates 32-byte cap +
  redaction. Where is the check? Test coverage?

---

## Output format

`VERDICT: READY TO MERGE` if 0/0/0. Else `VERDICT: NEEDS REVISION`
with counts + findings. Include file:line citations for every
finding. Convergent cross-lane findings = strongest signal.
