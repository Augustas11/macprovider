# Implementation BUILD prompt — SPEC-001 v1.3 Phase 1E (cooldown soft guard + --force bypass + AC matrix)

Operator-paste prompt for Codex GPT-5 to land the **final** of five
implementation sub-phases of SPEC-001 v1.3 in `phase3-binary/`.
This phase activates the CLI-side cooldown soft guard
(`last-switch.ts` read/write), wires `--force` to bypass it, and
adds end-to-end AC coverage that exercises the full SPEC-001 v1.3
binary surface (Phases 1A through 1E together).

**Scope: SPEC-001 v1.3 R-6.11.3 + SPEC-011 R-3.1.3 / R-3.1.4 +
end-to-end AC matrix.** No coordinator-side changes, no new
control-socket frame types, no heartbeat changes.

**One-line summary.** Implement `SwitchStateStore` (a tiny
read/write wrapper around the macOS-native
`$HOME/Library/Application Support/macprovider-cli/last-switch.ts`
file) and wire it into `ModelsSwitchCommand` between the pre-flight
validation (1A path) and the socket connect (1C path). On `now -
last_switch < 10s`, exit code 6 with the cooldown stderr UNLESS
`--force` is passed. On any successful or in-flight switch, write
the current timestamp. Add an `EndToEndAcceptanceTests.swift` file
that exercises AC-N.0 through AC-N.11 in a single hermetic test
matrix, treating the prior four phases as a unit under test.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.3 §6.11.3 R-6.11.5 — cooldown soft guard
- SPEC-001 v1.3 §6.2 `--switch-state-path` flag (added in 1C)
- SPEC-001 v1.3 §9 AC-N.0 through AC-N.11 (the AC matrix this
  phase pins end-to-end)
- SPEC-011 v0.5 §3.1 R-3.1.3 (`--force` semantics) + R-3.1.4 (CLI
  cooldown state file + default 10s window)
- 1A (commit 6744d7c) — `SupportedModels.validate`
- 1B (commit 5c03e88) — `RuntimeStateMachine`, `ModelRuntime.beginSwap`
- 1C (commit 9a4a6c5) — `ControlSocketServer`, `ModelsSwitchCommand`,
  `--switch-state-path` flag plumbing; `--force` accepted as no-op
- 1D (commit 3c1da34) — heartbeat / hello surface

Spec-text-only edits are FORBIDDEN. No edits under `specs/`
(operator-authored BUILD prompts excepted). Verify with
`git diff -- specs/` after edits.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~75-100 min
(one new small file, one file modified, one new end-to-end test
file).

Branch: `fix/spec-001-v1-3-binary` carries Phases 1A + 1B + 1C + 1D.
Codex MUST commit on this branch, MUST NOT create a new one, and
MUST NOT commit or push (operator audits before commit).

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1E of SPEC-001 v1.3 in the Swift binary
at /Users/augstar/macprovider-poc/phase3-binary/. SPEC-001 v1.3 is
LOCKED. SPEC-011 v0.5 is LOCKED. Phases 1A (6744d7c), 1B (5c03e88),
1C (9a4a6c5), and 1D (3c1da34) are already on this branch.

You will edit/create the following files (and ONLY these):

  phase3-binary/Sources/macprovider-cli/SwitchStateStore.swift           (NEW)
  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift           (extend)
  phase3-binary/Tests/macprovider-cliTests/SwitchStateStoreTests.swift   (NEW)
  phase3-binary/Tests/macprovider-cliTests/EndToEndAcceptanceTests.swift (NEW)

You will NOT edit any file under `specs/`, `phase4-coordinator/`,
`phase5-gateway/`, or any other Swift file beyond the list above.
You will NOT touch:
- `Sources/MacProviderCore/SupportedModels.swift` (1A)
- `Sources/MacProviderCore/Config.swift` (1A/1B/1C)
- `Sources/macprovider-cli/CoordinatorClient.swift` (1A/1D)
- `Sources/macprovider-cli/MacProviderCLI.swift` (1A/1B/1C)
- `Sources/macprovider-cli/RuntimeStateMachine.swift` (1B)
- `Sources/macprovider-cli/ModelRuntime.swift` (1B)
- `Sources/macprovider-cli/HTTPServer.swift` (1B)
- `Sources/macprovider-cli/ControlSocket.swift` (1C)
- Any 1A/1B/1C/1D test file beyond the two new files listed above

Verify with `git diff -- specs/ phase4-coordinator/ phase5-gateway/`
— must be empty (excluding operator-authored
`specs/BUILD_SPEC_001_v1_3_IMPL_*` prompts and the pre-existing
`specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit).

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 AC-N.0.** Phase 1E
adds no new wire behavior. The cooldown soft guard lives entirely
CLI-side in `models switch`; the running `serve` process is
unaffected. A v1.3 binary started with `serve` WITHOUT
`--enable-warm-swap` continues to exhibit byte-identical on-the-wire
behavior to v1.2.4. The cooldown state file is read/written ONLY
during `models switch` invocations, never by `serve`.

**2. SPEC-011 R-3.1.4 — cooldown state file format.** The
`last-switch.ts` file contains a single line of UTF-8 text: the
epoch milliseconds of the most recent successful or in-flight
`models switch` invocation, as a base-10 integer string. No JSON,
no whitespace, no trailing newline (or a single optional trailing
`\n` — the reader MUST tolerate both). Example contents:
`1717696989123`. The reader returns nil if the file is missing OR
the file's content fails to parse as Int64 (resilient: do NOT
exit with an error if the file is corrupt; treat as "no recent
switch" and proceed).

**3. SPEC-011 R-3.1.4 — default cooldown window.** 10 seconds
(10_000 ms). The check is `now - last_switch < 10_000`. Equal-to
10_000 is NOT cooldown. The window value MUST live as a public
constant on `SwitchStateStore` so the AC test can introspect it.

**4. SPEC-011 R-3.1.4 — write timing.** The CLI writes the
timestamp AFTER pre-flight validation passes AND AFTER the
control-socket connect succeeds AND AFTER receiving
`switch_ack accepted: true`, but BEFORE waiting for the
`switch_progress` ladder. Rationale: the spec says "last successful
or in-flight" — by the time we have an accepted switch_ack, the
in-process state machine has transitioned to `.loading` (per 1B
R-3.2.4 step 1), making it "in-flight". Writing earlier would
falsely register a cooldown for a switch that was rejected at
pre-flight or by `switch_ack accepted:false`.

**5. SPEC-011 R-3.1.3 — `--force` semantics.** `--force` MUST
suppress ONLY the cooldown soft-guard check. It MUST NOT suppress:
  - The Phase 1A SPEC-010 pre-flight validation
    (`SupportedModels.validate` exit code 2)
  - The Phase 1C `loading_in_progress` server-side rejection
    (exit code 3)
  - The Phase 1C R-3.1.5.x detection precedence (exit code 4)
  - The Phase 1B atomic-swap rollback (exit code 5)

Tests MUST prove that `--force` lets cooldown through but does
NOT alter exits 2/3/4/5/6 behavior when their underlying
conditions hold.

**6. SPEC-011 R-3.1.4 cooldown exit code + stderr.** When the
cooldown soft guard fires (without `--force`), exit code 6 with
stderr `"swap on cooldown for <N>s. Re-issue with --force to
bypass"` where `<N>` is `ceil((10_000 - (now - last_switch)) /
1000)` (a positive integer 1-10 seconds). This stderr matches the
existing Phase 1C handler for the (currently unreachable)
server-side cooldown ack at
`phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift`
around line 125. The 1E CLI-side soft guard reuses the SAME
stderr message so the operator UX is consistent regardless of
which side detected the cooldown.

**7. Cooldown state file path — macOS native.** Default per
SPEC-011 R-3.1.4 and SPEC-001 v1.3 §6.2:
`$HOME/Library/Application Support/macprovider-cli/last-switch.ts`.
Resolved via
`FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/macprovider-cli/last-switch.ts")`.
Override via `--switch-state-path <path>` (the flag already exists
in 1C's `ModelsSwitchCommand`; only the *behavior* attached to it
is new in 1E). The parent directory is created with
`createDirectory(at:withIntermediateDirectories:true)` on write
(no special mode); the cooldown file itself is created with
default mode (no chmod needed — the file contains no secrets).

**8. SPEC-011 R-3.1.4 — atomic-ish write.** The write MUST use
the write-to-temp-then-rename pattern to avoid leaving a
half-written file if the process is killed mid-write. Suggested
implementation: write to `<path>.tmp`, then `rename(<path>.tmp,
<path>)`. The reader MUST be resilient to the rename being
interrupted (file missing → nil; corrupt → nil).

**9. d-inference clean-room.** Do NOT read any file under
`phase3-binary/.build/checkouts/`.

**10. Compile + tests pass.** `swift build` and `swift test` MUST
both exit 0. Cumulative test count after this phase SHOULD be
≥ 120 (105 from 1A+1B+1C+1D + ≥ 15 new in 1E). All pre-existing
tests still GREEN.

**11. No drift in 1A/1B/1C/1D surfaces.** Do NOT modify any prior-
phase file beyond the two new files and the extension to
`ModelsSubcommand.swift`. If a 1E requirement seems to need a
prior-phase change, STOP and surface the conflict at the top of
your final report.

**12. End-to-end AC matrix uses the existing test infra.** The
`EndToEndAcceptanceTests.swift` file builds on the patterns from
1B (`ModelRuntime` test loader injection), 1C (`ControlSocketServer`
hermetic socket on a tmp path, `captureOutput` stdout/stderr
trapping), and 1D (`CoordinatorFrameRecorder` for heartbeat shape
assertions). Each AC test asserts the OBSERVABLE invariant (wire
bytes, exit codes, file presence/absence) — NOT the internal
implementation choice. Tests are hermetic (no network, no real
MLX, no real coordinator).

## Required reading (in this order — read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   - §6.11.3 R-6.11.5 (cooldown soft guard normative)
   - §9 AC-N.0 through AC-N.11 — the AC matrix (locate by
     `grep -n "AC-N\." specs/SPEC-001-phase3-binary.md`)

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   - §3.1 R-3.1.3 (`--force` semantics) and R-3.1.4 (state file +
     default 10s window) — full text

3. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift`
   - Full file. Extension goes into `ModelsSwitchCommand.run()`
     between the existing pre-flight validation (line ~96) and
     the existing socket connect (line ~106). Also wire the
     timestamp write after `switch_ack accepted: true` is
     received (line ~117).
   - The `--force` flag at line ~67 currently is a no-op; wire
     it to skip the cooldown check.
   - The `--switch-state-path` flag at line ~83 is currently
     stored only; wire it to feed `SwitchStateStore`.

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
   - `ControlSocketPaths.defaultSwitchStatePath(...)` static
     helper at line ~187 exists from 1C; use it (or extend if it
     doesn't have a `resolve(:)` form similar to the
     `ctlSocketPath` resolver).

5. `/Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift`
   - `captureOutput` helper at line ~177 — reuse for 1E tests.
   - `makeSocketPath` / `makeRuntime` helpers at lines ~144-160.

6. `/Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`
   - `CoordinatorFrameRecorder` (or equivalent record-on-
     sendOverride pattern) — locate via grep.

## Required edits — exact shape

### A. `SwitchStateStore.swift` — NEW

A small Foundation-only module. Public surface:

```swift
import Foundation

public struct SwitchStateStore: Sendable {
    /// Default cooldown window per SPEC-011 v0.5 R-3.1.4.
    public static let defaultCooldownWindowMs: Int64 = 10_000

    public let path: URL
    public let cooldownWindowMs: Int64

    public init(path: URL, cooldownWindowMs: Int64 = SwitchStateStore.defaultCooldownWindowMs) {
        self.path = path
        self.cooldownWindowMs = cooldownWindowMs
    }

    /// Returns the recorded last-switch timestamp (epoch ms), or nil
    /// if the file does not exist OR cannot be parsed as Int64.
    public func readLastSwitchMs() -> Int64? { ... }

    /// Writes the given timestamp atomically (write-to-temp-then-rename).
    /// Creates the parent directory if missing. Throws on filesystem
    /// errors that prevent the write.
    public func writeLastSwitchMs(_ value: Int64) throws { ... }

    /// Returns the cooldown decision:
    /// - .clear        — no recent switch (file missing or > window)
    /// - .cooldown(s)  — within the window; `secondsRemaining` is
    ///                   ceil((window - elapsed) / 1000), clamped to
    ///                   [1, cooldownWindowMs / 1000]
    public func cooldownDecision(now: Int64) -> CooldownDecision { ... }

    public enum CooldownDecision: Equatable, Sendable {
        case clear
        case cooldown(secondsRemaining: Int)
    }
}
```

Key implementation notes:
- `writeLastSwitchMs` creates the parent dir with
  `createDirectory(at:withIntermediateDirectories:true)`. Does NOT
  chmod (no secrets in the file).
- The temp file path is `<path>.tmp`. Use
  `FileManager.default.removeItem(at: tmpURL)` to clean a stale
  temp before writing, then write the new content, then
  `FileManager.default.moveItem(at: tmpURL, to: path)`. If `path`
  already exists, `moveItem` fails — use
  `FileManager.default.replaceItem(at: path, withItemAt: tmpURL,
  backupItemName: nil, options: [], resultingItemURL: nil)` for the
  atomic replace, OR fall back to a remove-then-move pattern if
  `replaceItem` is unavailable on the target macOS API level.
- `readLastSwitchMs` MUST NOT throw. File-not-found → nil. Read
  error → nil. Parse error → nil. The caller treats nil as "no
  recent switch".

### B. `ModelsSubcommand.swift` — extend `ModelsSwitchCommand.run()`

Add the cooldown check + timestamp write. The full target shape
of `ModelsSwitchCommand.run()`:

```swift
func run() async throws {
    let options = ModelsSwitchOptions(force: force, switchStatePath: switchStatePath)
    let resolved = try loadModelsConfig(
        config: config,
        model: model,
        supportedModels: supportedModels,
        ctlSocketPath: ctlSocketPath,
        switchStatePath: switchStatePath
    )

    // Step 2 — SPEC-010 pre-flight (unchanged from Phase 1C)
    do {
        _ = try SupportedModels.validate(
            model: targetModelID,
            supportedModels: resolved.supportedModels
        )
    } catch SupportedModelsValidationError.modelNotInCatalog {
        writeStderr("switch target \(targetModelID) not in --supported-models")
        throw ExitCode(2)
    } catch let error as SupportedModelsValidationError {
        writeStderr("\(error)")
        throw ExitCode(2)
    }

    // Step 2.5 — SPEC-011 R-3.1.4 cooldown soft guard (NEW in 1E)
    if !options.force {
        let storePath = ControlSocketPaths.defaultSwitchStatePath(resolved.switchStatePath)
        let store = SwitchStateStore(path: storePath)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch store.cooldownDecision(now: nowMs) {
        case .clear:
            break
        case .cooldown(let secondsRemaining):
            writeStderr("swap on cooldown for \(secondsRemaining)s. Re-issue with --force to bypass")
            throw ExitCode(6)
        }
    }

    // Step 3 — connect (unchanged)
    let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
    let (connection, _) = try await connectAndReadStatusOrExit(socketPath: socketPath)
    let requestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

    // Step 4 — switch_request + switch_ack (unchanged for branches;
    //          NEW for the accepted branch: record the timestamp)
    try await connection.send(.switchRequest(targetModelID: targetModelID, requestedAtMs: requestedAtMs))
    let ack = try await connection.receive()
    guard case let .switchAck(accepted, reason, currentTarget, secondsRemaining) = ack else {
        writeStderr("expected switch_ack")
        await connection.close()
        throw ExitCode(4)
    }

    guard accepted else {
        await connection.close()
        switch reason {
        case .loadingInProgress:
            let currentTarget = currentTarget ?? "<unknown>"
            writeStderr("provider is already loading \(currentTarget); refusing to start a second swap. Wait for current switch to complete (macprovider-cli models status)")
            throw ExitCode(3)
        case .cooldown:
            writeStderr("swap on cooldown for \(secondsRemaining ?? 0)s. Re-issue with --force to bypass")
            throw ExitCode(6)
        default:
            writeStderr("switch rejected")
            throw ExitCode(4)
        }
    }

    // Step 4.5 — record the in-flight switch timestamp (NEW in 1E)
    let storePath = ControlSocketPaths.defaultSwitchStatePath(resolved.switchStatePath)
    let store = SwitchStateStore(path: storePath)
    do {
        try store.writeLastSwitchMs(requestedAtMs)
    } catch {
        // Non-fatal: log to stderr but proceed with the switch.
        // A swap that succeeds without writing the timestamp will
        // simply not gate the next attempt's cooldown.
        writeStderr("warning: could not write switch state file at \(storePath.path): \(error)")
    }

    // Step 5 — stream switch_progress (unchanged)
    while true {
        // ... existing 1C code unchanged ...
    }
}
```

The KEY semantic additions:
- New "Step 2.5" cooldown check between pre-flight and connect
- New "Step 4.5" timestamp write between accepted ack and progress stream
- The `--force` flag now actually bypasses Step 2.5 (and ONLY Step 2.5)

### C. `SwitchStateStoreTests.swift` — NEW

Cover the store in isolation. Each test uses a hermetic tmp file
path so tests don't interfere.

- `testReadReturnsNilWhenFileMissing` — fresh tmp path; read
  returns nil
- `testReadReturnsNilWhenFileCorrupt` — write `"not a number"`
  to path; read returns nil
- `testWriteAndReadRoundTrip` — write 1717696989123; read returns
  1717696989123
- `testWriteCreatesParentDirectory` — tmp path under a non-
  existent grandparent; write succeeds
- `testWriteIsAtomic` — write 1, then write 2; assert no `.tmp`
  file remains in the parent dir after both writes; assert read
  returns 2
- `testCooldownDecisionClearWhenNeverSet` — fresh tmp path;
  decision(now: 1000) returns .clear
- `testCooldownDecisionClearWhenWellOutsideWindow` — write `0`,
  decision(now: 1_000_000) returns .clear
- `testCooldownDecisionCooldownWhenInsideWindow` — write
  `1_000_000`, decision(now: 1_005_000) returns
  `.cooldown(secondsRemaining: 5)`
- `testCooldownDecisionCooldownWhenJustInsideWindow` — write
  `1_000_000`, decision(now: 1_009_999) returns
  `.cooldown(secondsRemaining: 1)`
- `testCooldownDecisionClearAtExactlyWindowBoundary` — write
  `1_000_000`, decision(now: 1_010_000) returns .clear (the
  boundary is exclusive: `<` not `<=`)
- `testCustomCooldownWindow` — construct with
  `cooldownWindowMs: 5_000`; verify boundary is at 5_000

### D. `EndToEndAcceptanceTests.swift` — NEW

End-to-end matrix tests pinning SPEC-001 v1.3 AC-N.0 through
AC-N.11. Each test is hermetic (no real MLX, no real WS, no real
filesystem outside `/tmp`).

Use these conventions:
- Tmp socket path under `/tmp/mpm-<pid>-<random>/ctl.sock`
- Tmp cooldown state path under `/tmp/mpm-<pid>-<random>/last-switch.ts`
- `ModelRuntime` via the 1B test init with `loader` + `testLoader`
- `ControlSocketServer` from 1C hosted on the tmp socket path
- `CoordinatorClient` with `sendOverride` + `connectAndRunOverride`
  for heartbeat / hello capture (1A/1D pattern)
- `captureOutput` for stdout/stderr from `ModelsSubcommand` runs

Required tests (mapping to AC numbers per SPEC-001 v1.3 §9):

- `testAC_N_0_L1ByteIdenticalDefault_WireSurface` — instantiate a
  `CoordinatorClient` with `AppConfig` defaults (no flags set),
  capture the `authInitialMessage` and `helloMessage` and the
  first `heartbeat` via `sendOverride`. Assert: the JSON byte-
  strings contain `supported_models: [model_id]` (single-entry),
  do NOT contain `publishes_supported_models`, do NOT contain
  `model_hash` on heartbeat, do NOT contain `loading` on
  heartbeat. This is the canonical L-1 assertion.

- `testAC_N_1_SPEC010_OptIn_ExplicitCatalog` — `enableWarmSwap =
  false` (irrelevant), `supportedModels = ["A","B","C"]`,
  `model = "A"`, `publishesSupportedModels = true`. Assert
  `authInitialMessage` contains both fields with the expected
  values.

- `testAC_N_2_SPEC010_PreFlight_ExitCode2` — invoke
  `ModelsSwitchCommand` parse + run with `--model A
  --supported-models A,B`, target `C`. Capture output, assert
  `ExitCode(2)` and stderr containing `"switch target C not in
  --supported-models"`. Verify the socket path is NOT touched
  (no socket file created).

- `testAC_N_3_SPEC011_OptInGate_DisabledMode` — start a `serve`
  scenario WITHOUT `--enable-warm-swap` (i.e., construct a
  `ServeCommand`-like setup; for the test, just verify that
  `ControlSocketServer` is NOT instantiated when
  `AppConfig.enableWarmSwap == false`, and a `ModelsListCommand`
  pointed at the absent socket path exits 0 with the disabled-
  mode message). Verify `models switch` against the same setup
  exits 4 with R-3.1.5.x case-1 stderr.

- `testAC_N_4_SPEC011_OptInGate_EnabledMode_FilePermissions` —
  start a `ControlSocketServer` on a tmp path; assert the parent
  dir mode is `0700` and the socket file mode is `0600` via
  `stat()`.

- `testAC_N_5_MacOSNativePath` — verify
  `ControlSocketPaths.resolve(ctlSocketPath: nil)` resolves under
  `FileManager.default.temporaryDirectory` (and that the path
  contains `macprovider-cli/ctl.sock`). Verify
  `ControlSocketPaths.defaultSwitchStatePath(nil)` resolves
  under `FileManager.default.homeDirectoryForCurrentUser` and
  contains `Library/Application Support/macprovider-cli/last-switch.ts`.
  Verify the source code contains zero matches for
  `XDG_RUNTIME_DIR` (this is a meta-check; assert via a string
  search of the file contents OR delegate to a shell-out).

- `testAC_N_6_AtomicSwap_InFlightVsNewRequest` — start a
  `ControlSocketServer` with a stub runtime + 100ms loader.
  Begin a long-running stub `complete(...)` call against the
  runtime (using `testCompletion`); concurrently drive a
  `models switch` to a new model; assert the in-flight call
  returns the OLD model's content; a fresh inference after the
  swap completes returns NEW model's content. (Reuses the 1B
  `testInFlightInferenceUsesOldSnapshot` pattern but driven
  through the control-socket path.)

- `testAC_N_7_NoStarveHeartbeat` — start a `CoordinatorClient`
  with `enableWarmSwap = true` and `sendOverride` capture; begin
  a 200ms swap; assert that AT LEAST one regular `heartbeat`
  frame appears in the capture buffer during the load (proving
  the heartbeat cadence is not paused).

- `testAC_N_8_HeartbeatHashFormat` — with warm-swap enabled and
  a known `model_hash = "abc...64chars..."` (the test sets a
  raw lowercase hex string via the runtime's modelHash field),
  capture a heartbeat, parse the JSON, assert
  `model_hash` value is exactly 64 chars, all lowercase hex,
  no `sha256:` prefix. Regex: `^[a-f0-9]{64}$`.

- `testAC_N_9_FourMatrixCells_AuthInitial` — for each of the
  four cells of the SPEC-010 × SPEC-011 opt-in matrix
  (unset/unset, set/unset, unset/set, set/set), construct an
  `AppConfig`, instantiate `CoordinatorClient`, call
  `authInitialMessage`, and assert on the expected wire fields:
  - cell 1: `supported_models: [model_id]`, no
    `publishes_supported_models`
  - cell 2: explicit `supported_models`,
    `publishes_supported_models: true` (when bool flag set)
  - cell 3: same as cell 1 (warm-swap doesn't change SPEC-010
    field shape — the warm-swap fields go on heartbeat, not
    auth_request)
  - cell 4: explicit `supported_models` +
    `publishes_supported_models: true`
  Plus a heartbeat capture per cell asserting the model_hash /
  loading presence/absence according to the matrix.

- `testAC_N_10_V2HandshakeFieldsMatchSPEC010_3_1_A` — invoke
  `authInitialMessage` with `enableWarmSwap = false`,
  `supportedModels = ["X","Y"]`, `publishesSupportedModels =
  true`. Serialize to JSON. Assert every parser-required field
  from SPEC-010 §3.1.A is present: `type`, `version`, `stage`,
  `provider_id`, `hostname`, `model_id`, `model_params_b`,
  `ram_gb`, `max_context_tokens`, `max_concurrency`,
  `throughput_tps_estimate`, `binary_version`,
  `provider_ecdh_public_key`, `tier2_capabilities`,
  `supported_models`, `publishes_supported_models`. List the
  expected keys explicitly in the test and iterate.

- `testAC_N_11_LegacyHelloByteIdenticalToV124` — call
  `helloMessage()` with `enableWarmSwap = false` and capture
  the JSON. Compare against a canonical hardcoded baseline
  string (or assert key-by-key that ONLY the v1.2.4 fields are
  present — `type`, `version`, `tier`, `provider_id`,
  `hostname`, `model_id`, `model_params_b`, `ram_gb`,
  `max_context_tokens`, `max_concurrency`,
  `throughput_tps_estimate`, `binary_version`, `attestation`,
  and conditionally `endpoint_url`, `model_hash`). Assert NO
  v1.3 fields (`supported_models`, `publishes_supported_models`,
  `loading`) appear in the hello frame.

If the test file grows beyond ~600 lines, you may split into
two files (`EndToEndAcceptanceTests.swift` for AC-N.0 through
AC-N.5 and `EndToEndAcceptanceTestsWireMatrix.swift` for
AC-N.6 through AC-N.11), but the prompt's preference is one
file.

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` shows
  only operator-authored BUILD prompts and the pre-existing
  `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit.
- `git diff -- phase3-binary/Sources/MacProviderCore/
  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
  phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift
  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
  phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
  is empty (1E does not touch any of these).
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 120 tests
  green.
- All Phase 1A + 1B + 1C + 1D tests still GREEN (no regressions).
- A `models switch` invocation within 10s of a prior accepted
  switch exits 6 with the cooldown stderr.
- The same invocation with `--force` proceeds past the cooldown
  check.
- The cooldown file is written atomically (no `.tmp` file
  remnants on success).
- The CLI does NOT exit on a corrupt `last-switch.ts` — it
  treats the corruption as "no recent switch" and proceeds.

## Out of scope (do NOT do these in Phase 1E)

- Server-side `switch_ack accepted:false reason:cooldown`
  emission — cooldown is CLI-side only per SPEC-011 L-7
- Coordinator-side `phase4-coordinator/` changes — Phase 2
- HF cache `disk_size_gb` column on `models list` — out of
  scope (spec marks optional)
- Any new CLI flags, ENV vars, or YAML keys
- Any modification to the wire protocol (heartbeat, hello,
  auth_request, control socket frames)

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  git diff --stat -- phase3-binary/Sources/MacProviderCore/ phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/HTTPServer.swift phase3-binary/Sources/macprovider-cli/ControlSocket.swift && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -5) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/ || echo "no XDG_RUNTIME_DIR (correct)"
```

The second diff stat MUST show 0 files changed (no out-of-scope
edits).

Return:
- A brief diff summary (files touched, +/- lines).
- The final `swift test` summary line (Executed N tests, ...).
- Any spec rule you were unable to satisfy exactly, with the
  binding rule number and your interpretation.

Do NOT commit. Do NOT push. The operator audits the working tree
before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 75-100 min. 1E is the smallest scope (one
  small new module + one extension to ModelsSubcommand) but the
  end-to-end AC matrix file is the largest test artifact yet.
- Audit pass (Claude Opus) reads the diff and tests against the
  12 constraints + done criteria. Key audit foci:
  - **Constraint 4 (write timing)** — verify the timestamp write
    happens AFTER `switch_ack accepted: true`, not earlier.
  - **Constraint 5 (--force semantics)** — verify --force does
    NOT suppress pre-flight (exit 2), concurrent reject (exit 3),
    or socket detection (exit 4).
  - **Constraint 8 (atomic write)** — verify the
    write-to-temp-then-rename pattern and no stale `.tmp` file
    on success.
  - **AC matrix coverage** — verify each AC-N.X test actually
    asserts on the observable invariant, not just the
    implementation detail.
- R2 prompt is drafted only if R1 audit surfaces findings.
- After 1E LOCKs, PR #5 is the final reviewable artifact for
  SPEC-001 v1.3 binary implementation. Operator reviews and
  squash-merges; main gets one tidy commit with all five phases.
