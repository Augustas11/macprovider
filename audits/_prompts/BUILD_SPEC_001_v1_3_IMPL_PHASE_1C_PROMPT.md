# Implementation BUILD prompt — SPEC-001 v1.3 Phase 1C (control socket + `models` subcommand)

Operator-paste prompt for Codex GPT-5 to land the **third** of five
implementation sub-phases of SPEC-001 v1.3 in `phase3-binary/`.
This phase wires the operator-facing surfaces for warm swap: a
macOS-native Unix-domain control socket protocol (`$TMPDIR/macprovider-cli/ctl.sock`,
NDJSON, typed frames) and a new `models` CLI subcommand with
`list / switch <id> [--force] / status` actions.

**Scope: SPEC-011 v0.5 §3.1.5 control socket protocol + §3.1.1 /
§3.1.2 / §3.1.6 `models` subcommand surface.** No heartbeat extension
(1D), no cooldown soft guard (1E), no WS drop policies (1E).
`--force` is parsed and accepted but is a no-op in 1C — its only
real effect (bypassing cooldown) lands in 1E.

**One-line summary.** Create `ControlSocket.swift` (Unix-domain
socket server hosted by `serve` when `--enable-warm-swap` is set,
parent dir 0700, socket 0600, NDJSON frames with REQUIRED `type`
field per SPEC-011 R-3.1.5); create `ModelsSubcommand.swift`
(`models list / switch <id> [--force] / status` per SPEC-011
R-3.1.1 / R-3.1.2 / R-3.1.6); plumb `--ctl-socket-path` and
`--switch-state-path` flags (the latter only stored, used in 1E);
wire the socket server to `ModelRuntime.beginSwap` (consume the
`RuntimeStateMachine.signalStream()` from 1B to translate swap
signals into `switch_progress` frames per SPEC-011 R-3.1.5). L-1
byte-identical default preserved: in disabled mode the socket is
absent and `models <any>` exits code 4 with the R-3.1.5.x case-1
stderr.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.3 §6.9 (lines 1811-1865) — this phase's normative
  section, citing SPEC-011 R-3.1.5 / R-3.1.5.x / R-3.7.3
- SPEC-011 v0.5 §3.1 R-3.1.0 through R-3.1.6 (CLI + control
  socket), §3.7 R-3.7.x (concurrent switch policy — only the
  *server reply* side, not the queue/retry policy which is 1E)
- SPEC-010 v1.5 R-3.6.1 / R-3.6.3 (pre-flight reuse — 1C calls
  the existing `SupportedModels.validate` from Phase 1A)
- 1A (commit 6744d7c) — `SupportedModels` library + flag plumbing
- 1B (commit 5c03e88) — `RuntimeStateMachine`, `ModelRuntime.beginSwap`,
  `swapSignals()`, `currentSnapshot()`

Spec-text-only edits are FORBIDDEN. No edits under `specs/`
(operator-authored BUILD prompts are exceptions; you don't edit
them). Verify with `git diff -- specs/` after edits.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~120-150 min
(2 new Swift files of nontrivial size, ~2 files modified, ~3 test
files new).

Branch: `fix/spec-001-v1-3-binary` already carries Phases 1A + 1B.
Codex MUST commit on this branch, not create a new one, and MUST
NOT commit or push (operator audits before commit).

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1C of SPEC-001 v1.3 in the Swift binary
at /Users/augstar/macprovider-poc/phase3-binary/. SPEC-001 v1.3 is
LOCKED. SPEC-011 v0.5 is LOCKED. Phases 1A (commit 6744d7c) and 1B
(commit 5c03e88) are already on this branch.

You will edit/create the following files (and ONLY these):

  phase3-binary/Sources/MacProviderCore/Config.swift                    (extend)
  phase3-binary/Sources/macprovider-cli/ControlSocket.swift             (NEW)
  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift          (NEW)
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift            (extend)
  phase3-binary/Tests/macprovider-cliTests/ControlSocketTests.swift     (NEW)
  phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift  (NEW)

You will NOT edit any file under `specs/`, `phase4-coordinator/`,
`phase5-gateway/`, or any other Swift file beyond the list above.
You will NOT touch:
- `Sources/MacProviderCore/SupportedModels.swift` (1A)
- `Sources/macprovider-cli/CoordinatorClient.swift` (1A / 1D)
- `Sources/macprovider-cli/ModelRuntime.swift` (1B; the swap API is
  consumed unchanged via existing `beginSwap`, `currentSnapshot`,
  `swapSignals` methods)
- `Sources/macprovider-cli/RuntimeStateMachine.swift` (1B)
- `Sources/macprovider-cli/HTTPServer.swift` (1B)
- Any 1A/1B test file

Verify with `git diff -- specs/ phase4-coordinator/ phase5-gateway/`
— must be empty (excluding operator-authored
`specs/BUILD_SPEC_001_v1_3_IMPL_*` prompts and the pre-existing
`specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit).

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 AC-N.0 + AC-N.3.**
A v1.3 binary started with `serve` WITHOUT `--enable-warm-swap`
MUST NOT create any file at `$TMPDIR/macprovider-cli/ctl.sock`
(or anywhere on disk for control-socket purposes). A
`macprovider-cli models list / switch / status` invocation against
such a binary MUST exit code 4 via the R-3.1.5.x case-1 path:
`stat()` returns ENOENT → stderr
`"macprovider-cli serve is not running on this host (no control
socket at <socket_path>)"`. There is NO secondary disabled-mode
detection that requires the binary to acknowledge "you didn't pass
--enable-warm-swap"; the socket's *absence* is the signal.

**2. macOS-native paths.** The default control socket path is
`$TMPDIR/macprovider-cli/ctl.sock`, resolved via
`FileManager.default.temporaryDirectory.appendingPathComponent("macprovider-cli/ctl.sock")`.
NEVER use `$XDG_RUNTIME_DIR` (that's a Linux/freedesktop
convention; unset on macOS). `grep -rn "XDG_RUNTIME_DIR"
phase3-binary/Sources/` MUST return zero matches.

**3. Permissions.** Parent directory mode MUST be `0700` and
socket mode MUST be `0600` per SPEC-011 R-3.1.5 and SPEC-001 v1.3
R-6.9.6. If the parent directory already exists with a different
mode, the serve process MUST chmod it to 0700 before binding.
If the socket file already exists (stale from a previous run
that died), `bind()` will fail with EADDRINUSE; the serve process
MUST NOT silently unlink the stale file and re-bind — instead it
MUST log an error and exit non-zero with stderr
`"control socket <path> already exists; remove the stale file
and restart serve"`. Rationale: silent unlink masks a
diagnostically-important condition (a second `serve` running on
the same socket path). Tests cover this case.

**4. NDJSON wire format with REQUIRED `type` field per SPEC-011
R-3.1.5.** Every frame is one line of JSON terminated by `\n`.
Every frame MUST include a `type` field. Receivers MUST discard
frames with missing/unknown `type` AND close the connection with
an error log line. JSON serialization MUST use
`[.withoutEscapingSlashes]` to keep wire bytes minimal and avoid
gratuitous `\/` escapes; tests assert on exact wire bytes.

**5. Frame schemas (SPEC-011 R-3.1.5 verbatim).** Implement all
seven schemas:

  CLI → serve:
  - `{"type": "switch_request", "target_model_id": "<X>",
     "requested_at_ms": <epoch-ms>}`
  - `{"type": "status_request"}`

  serve → CLI:
  - `{"type": "switch_ack", "accepted": true}`
  - `{"type": "switch_ack", "accepted": false,
     "reason": "loading_in_progress",
     "current_target": "<Y>"}`
  - `{"type": "switch_ack", "accepted": false,
     "reason": "cooldown", "seconds_remaining": <N>}`
    NOTE: 1C does NOT emit this `cooldown` ack from the serve
    side (cooldown is CLI-side per L-7, lands in 1E). The
    Swift type MUST nonetheless model the case so 1E can wire
    it without an additional type change.
  - `{"type": "switch_progress", "state": "loading",
     "elapsed_ms": <N>}`
  - `{"type": "switch_progress", "state": "draining",
     "elapsed_ms": <N>}`
  - `{"type": "switch_progress", "state": "loaded",
     "elapsed_ms": <N>}`
  - `{"type": "switch_progress", "state": "failed",
     "elapsed_ms": <N>, "reason": "<reason-text>"}`
  - `{"type": "status_response",
     "current_model_id": "<X>",
     "runtime_state": "ready" | "loading" | "draining"}`

  Notes:
  - `target_model_id` and `current_model_id` are HuggingFace IDs
    or local paths per SPEC-001 §6.1.
  - `requested_at_ms` is `Int64` epoch ms (CLI clock).
  - `elapsed_ms` is `Int` ms since the CLI's
    `requested_at_ms`.
  - `reason` enum on `switch_ack`: `loading_in_progress`,
    `cooldown`, `not_in_supported_models`, `other`. 1C only
    emits `loading_in_progress` from the serve side
    (`not_in_supported_models` is CLI-side pre-flight before
    the socket is even contacted; `cooldown` is 1E; `other`
    is reserved). All four MUST be representable.
  - `state` enum on `switch_progress`: `loading`, `draining`,
    `loaded`, `failed`. 1C emits all four.
  - `runtime_state` enum on `status_response`: `ready`,
    `loading`, `draining` (no `failed` — that state is
    transient per 1B's RuntimeStateMachine.failSwap).

**6. Detection precedence (SPEC-011 R-3.1.5.x).** The CLI side
of `models <subcommand>` MUST distinguish three connect failure
modes:
  - **Case 1 — ENOENT** (`stat(socketPath)` returns ENOENT,
    or `FileManager.default.fileExists(atPath:)` returns
    false): exit code 4, stderr `"macprovider-cli serve is
    not running on this host (no control socket at
    <socket_path>)"`.
  - **Case 2 — ECONNREFUSED** (socket file exists but
    `connect()` returns ECONNREFUSED): exit code 4, stderr
    `"stale control socket at <socket_path> (no listener);
    remove the file and restart serve"`.
  - **Case 3 — handshake timeout** (`connect` succeeds but no
    `status_response` arrives within 2 seconds of sending
    `status_request`): exit code 4, stderr `"serve is
    running but warm-swap is not enabled (or serve is
    unresponsive); restart serve with --enable-warm-swap"`.

The CLI MUST send a `status_request` frame IMMEDIATELY upon
successful connect to drive Case 3 detection; only AFTER receiving
the `status_response` is the connection considered healthy and the
CLI proceeds with the subcommand-specific frame (e.g.,
`switch_request` for `models switch`).

**7. `models switch <model-id> [--force]` (SPEC-011 R-3.1.2).**
The sequence is:
  Step 1 — Resolve effective `supported_models` via existing
    `ConfigLoader.load` from
    `Sources/MacProviderCore/Config.swift` (CLI > ENV > YAML).
    The `models switch` subcommand MUST accept the SAME
    `--supported-models` / `--config` flags as `serve` to drive
    this resolution.
  Step 2 — Call existing `SupportedModels.validate(model:
    <X>, supportedModels: resolved.supportedModels)` (from 1A);
    on `.modelNotInCatalog`, exit code 2 with stderr
    `"switch target <X> not in --supported-models"` BEFORE
    contacting the socket.
  Step 3 — Connect via R-3.1.5.x detection precedence; exit 4
    on Case 1 / 2 / 3 with the prescribed stderr.
  Step 4 — Send `switch_request` frame. Read the `switch_ack`
    reply.
    - `{accepted: true}` → proceed to Step 5.
    - `{accepted: false, reason: "loading_in_progress",
       current_target: "<Y>"}` → exit code 3 with stderr
       `"provider is already loading <Y>; refusing to start a
       second swap. Wait for current switch to complete
       (macprovider-cli models status)"`.
    - `{accepted: false, reason: "cooldown", seconds_remaining:
       <N>}` → exit code 6 with stderr `"swap on cooldown for
       <N>s. Re-issue with --force to bypass"`. (1C will not
       emit this ack from the server side, but the CLI MUST
       handle it correctly in case a future server/coordinator
       does.)
  Step 5 — Stream `switch_progress` frames to stderr as they
    arrive. Exit code 0 on receipt of `{state: "loaded"}`;
    exit code 5 on `{state: "failed", reason: "<R>"}` with
    stderr `"swap failed: <R>"`.

The CLI MUST set a `requested_at_ms` based on its own clock
(`Int64(Date().timeIntervalSince1970 * 1000)`). The serve side
echoes this back in `elapsed_ms` calculations.

`--force` is parsed and ACCEPTED in 1C but has NO observable
behavior (cooldown bypass is 1E). The CLI flag is plumbed into
a `ModelsSwitchOptions` struct; the struct field is unused in
1C beyond storage. A comment near the field MUST cite the
deferral to Phase 1E.

**8. `models list` (SPEC-011 R-3.1.1).** Implement a minimal
version:
  - Attempt R-3.1.5.x case-1 connect to the socket.
  - If Case 1 (ENOENT) — print `"serve not running; warm-swap
    disabled"` to stdout and a single-row table indicating only
    the YAML / ENV / CLI-resolved `model_id` with `state: idle`
    (no warm). Exit code 0.
  - If connected and `status_response` received — print a
    two-column table: `model_id`, `state`. `state` is `warm`
    for the currently-loaded model (from `status_response.
    current_model_id`); other entries from
    `--supported-models` (resolved) are `idle`. Exit code 0.

The full HF-cache directory inspection (R-3.1.1 `disk_size_gb`
column) is OUT OF SCOPE for 1C (deferred to a future polish
pass; the spec lists `disk_size_gb` as "optional"). Tests cover
the two cases above only.

**9. `models status` (SPEC-011 R-3.1.6).** Print the
`status_response` JSON-ish summary to stdout. Cite the
detection-precedence stderr verbatim if connect fails.

**10. Serve-side socket lifecycle.** When `serve` is invoked
with `--enable-warm-swap`:
  - On startup, BEFORE returning from `ServeCommand.run`'s
    boot phase, create the parent dir at the resolved socket
    path with `mkdir -p` + chmod 0700, then bind a Unix-
    domain stream socket at the path, listen, and accept
    connections in a long-running task.
  - On shutdown (sigterm / sigint received by the existing
    `installTerminationHandler` machinery), close the listener
    and `unlink(socketPath)`.
  - On each accepted connection, spawn a task that:
    1. Reads NDJSON frames line-by-line.
    2. Dispatches based on `type`.
    3. For `status_request` → reply with `status_response`
       from a fresh `currentSnapshot()` call.
    4. For `switch_request` → call `modelRuntime.beginSwap(...)`;
       on success, reply `switch_ack accepted:true` and stream
       `switch_progress` frames driven by the `swapSignals()`
       AsyncStream; on `RuntimeStateMachineError.notReady` →
       reply `switch_ack accepted:false reason:loading_in_progress
       current_target:<X>`; on `WarmSwapDisabledError` → this
       should be UNREACHABLE because the socket only exists when
       warm-swap is enabled, but if hit, reply
       `switch_ack accepted:false reason:other`.
    5. For unknown / malformed `type` → log + close connection.
    6. On `\n`-delimited stream end (peer closed) → close.

The serve-side socket accept loop MUST run on a `Task.detached`
(NOT on the `ModelRuntime` actor's executor) per the SPEC-011
R-3.2.5 no-starve discipline carried forward from 1B. Tests
verify that the accept loop survives a slow inference and a
slow swap.

**11. `--ctl-socket-path` flag (serve-side override).** Plumbed
via existing CLI > ENV > YAML pattern. ENV var
`MACPROVIDER_CTL_SOCKET_PATH`; YAML key `ctl_socket_path`.
Default: `nil`, which resolves to
`$TMPDIR/macprovider-cli/ctl.sock` at use time. Only meaningful
when `--enable-warm-swap` is set.

**12. `--switch-state-path` flag (CLI-side cooldown file path).**
Plumbed via the same pattern. ENV
`MACPROVIDER_SWITCH_STATE_PATH`; YAML `switch_state_path`.
Default: `nil`, which resolves to
`$HOME/Library/Application Support/macprovider-cli/last-switch.ts`
at use time. The cooldown file itself is NOT read or written in
1C; only the flag is plumbed. 1E will implement the cooldown
soft-guard logic. A comment near each flag MUST cite the
deferral.

**13. `models` subcommand reuses `--config`, `--supported-models`,
`--ctl-socket-path` from `ServeCommand` config.** The pattern is:
the `models` subcommand parses the same flags as `serve` for
config-resolution purposes (so the operator can `macprovider-cli
models switch foo --supported-models a,b` and have the same
priority chain as `serve`). Only the cooldown / socket-path flags
make sense on `models` subcommands; do NOT add `--enable-warm-swap`
to `models` subcommands (it's a serve-only flag — `models`
subcommands ALWAYS act as if warm-swap is the goal, and detection
precedence handles the disabled case).

**14. d-inference clean-room.** Do NOT read any file under
`phase3-binary/.build/checkouts/`.

**15. Compile + tests pass.** `swift build` and `swift test` MUST
both exit 0. Cumulative test count after this phase SHOULD be
≥ 90 (73 from 1A+1B + ≥ 17 new in 1C). All pre-existing tests
still GREEN.

**16. No drift in 1A/1B surfaces.** Do NOT modify any 1A/1B file
listed in the constraint preamble. If a 1C requirement seems to
need a 1A/1B change, STOP and surface the conflict at the top of
your final report — DO NOT modify those files without operator
acknowledgement.

## Required reading (in this order — read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   §6.9 (lines 1811-1865) — control socket protocol normative.
   R-6.9.1 through R-6.9.6 are binding.

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   - §3.1 R-3.1.0 through R-3.1.6 (full text of the `models`
     subcommand rules, including R-3.1.2 exit codes and stderr
     messages)
   - §3.1.5 (control socket protocol — full frame schemas + field
     reference table)
   - §3.1.5.x (detection precedence three-case table)
   - §3.7 R-3.7.x (concurrent switch reply — serve-side only)

3. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
   — full file. Add `ModelsCommand` (parent) and three child
   subcommands (`ModelsListCommand`, `ModelsSwitchCommand`,
   `ModelsStatusCommand`) following the existing
   `AsyncParsableCommand` patterns. The parent is registered on
   `MacProviderCLI.configuration.subcommands` alongside the
   existing `ServeCommand`, etc.

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   — actor surface from 1B. You will call:
   - `beginSwap(targetModelID:) async throws -> Task<Void, Error>`
   - `currentSnapshot() async -> RuntimeSnapshot`
   - `swapSignals() async -> AsyncStream<SwapSignal>`
   You do NOT modify this file.

5. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift`
   — `SwapState`, `SwapSignal`, `SwapSignal.Outcome` types from 1B.

6. `/Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCore/SupportedModels.swift`
   — pre-flight library from 1A; used unchanged by `models switch`
   step 2.

7. `/Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCore/Config.swift`
   — extend with `ctlSocketPath: String?` and `switchStatePath:
   String?` per constraints 11/12.

8. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   — DO NOT MODIFY. Read only to understand how the serve loop is
   structured; the control socket accept loop runs alongside, NOT
   inside the HTTPServer.

## Required edits — exact shape

### A. `ControlSocket.swift` — NEW

Public types and one server class. Suggested skeleton:

```swift
import Foundation

public enum ControlSocketFrame: Equatable, Sendable {
    case switchRequest(targetModelID: String, requestedAtMs: Int64)
    case statusRequest
    case switchAck(accepted: Bool, reason: SwitchAckReason?, currentTarget: String?, secondsRemaining: Int?)
    case switchProgress(state: SwitchProgressState, elapsedMs: Int, reason: String?)
    case statusResponse(currentModelID: String, runtimeState: SwapState)
}

public enum SwitchAckReason: String, Sendable, Equatable {
    case loadingInProgress = "loading_in_progress"
    case cooldown
    case notInSupportedModels = "not_in_supported_models"
    case other
}

public enum SwitchProgressState: String, Sendable, Equatable {
    case loading, draining, loaded, failed
}

public enum ControlSocketCodec {
    public static func encode(_ frame: ControlSocketFrame) throws -> Data
    public static func decode(_ line: Data) throws -> ControlSocketFrame
}

public enum ControlSocketError: Error, Equatable {
    case missingType
    case unknownType(String)
    case missingRequiredField(String)
    case invalidEnumValue(field: String, value: String)
}

actor ControlSocketServer {
    init(socketPath: URL, modelRuntime: ModelRuntime) { ... }
    func start() async throws { ... }   // bind + listen + accept loop on Task.detached
    func stop() async { ... }           // close listener + unlink socket
}

public enum ControlSocketClient {
    public static func connect(socketPath: URL, timeout: TimeInterval = 2.0)
        async throws -> ControlSocketConnection
}

public actor ControlSocketConnection {
    func send(_ frame: ControlSocketFrame) async throws { ... }
    func receive() async throws -> ControlSocketFrame { ... }
    func close() async { ... }
}

public enum ControlSocketConnectError: Error, Equatable {
    case socketAbsent(path: String)         // R-3.1.5.x case 1
    case connectionRefused(path: String)    // R-3.1.5.x case 2
    case handshakeTimeout(path: String)     // R-3.1.5.x case 3
    case other(underlying: String)
}
```

Choose the Unix-domain socket primitive that's already on the
project's allowed import path. Options, in preference order:
  1. `SwiftNIO` `NIOPosix.ServerBootstrap` with
     `.serverChannelInitializer` + `NIOPipeBootstrap` — heavyweight
     but already a transitive dep via `HTTPServer.swift`.
  2. Raw Darwin POSIX (`Darwin.socket`, `Darwin.bind`,
     `Darwin.listen`, `Darwin.accept`) wrapped in async — minimal
     deps but more code.
Prefer option 2 if it keeps the file under ~500 lines; the surface
is small enough to handle directly. The `Foundation.Process` /
`FileHandle` route does NOT support Unix-domain sockets cleanly
on macOS.

Encoding rules:
- Serialize each frame as a single line: `{...}\n`.
- Use `JSONSerialization.data(withJSONObject: ..., options:
  [.withoutEscapingSlashes])` to match the project's other JSON
  wire bytes (CoordinatorClient uses these options).
- For `switchAck`, fields are conditional per the schema:
  - `reason` present iff `accepted == false`
  - `currentTarget` present iff `reason == loadingInProgress`
  - `secondsRemaining` present iff `reason == cooldown`
- For `switchProgress`, `reason` present iff `state == failed`.

Decoding rules:
- Reject frames with missing `type` → throw `.missingType`.
- Reject unknown `type` strings → throw `.unknownType(...)`.
- Reject missing required fields → throw `.missingRequiredField(...)`.
- Reject malformed enum values → throw `.invalidEnumValue(...)`.

### B. `ModelsSubcommand.swift` — NEW

Define `ModelsCommand` (parent) and three subcommands. The
parent has no `run()` — it delegates via
`CommandConfiguration(subcommands:)`. Each subcommand:

```swift
struct ModelsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List models known to this provider (warm/idle)."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
    var ctlSocketPath: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(
            configPath: config,
            supportedModels: SupportedModels.parseCSV(supportedModels),
            ctlSocketPath: ctlSocketPath
        ))
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        do {
            let connection = try await ControlSocketClient.connect(socketPath: socketPath)
            try await connection.send(.statusRequest)
            let response = try await connection.receive()
            guard case let .statusResponse(currentModelID, runtimeState) = response else {
                FileHandle.standardError.write(Data(("expected status_response\n").utf8))
                throw ExitCode(4)
            }
            await connection.close()
            printTable(currentModelID: currentModelID, runtimeState: runtimeState,
                       supportedModels: resolved.supportedModels)
        } catch ControlSocketConnectError.socketAbsent(let path) {
            print("serve not running; warm-swap disabled")
            FileHandle.standardError.write(Data(
                ("macprovider-cli serve is not running on this host (no control socket at \(path))\n").utf8))
            printTable(currentModelID: nil, runtimeState: nil,
                       supportedModels: resolved.supportedModels)
            // NOTE: per spec R-3.1.1 — exit 0 in disabled case (table still printed)
            return
        } catch ControlSocketConnectError.connectionRefused(let path) {
            FileHandle.standardError.write(Data(
                ("stale control socket at \(path) (no listener); remove the file and restart serve\n").utf8))
            throw ExitCode(4)
        } catch ControlSocketConnectError.handshakeTimeout(let path) {
            FileHandle.standardError.write(Data(
                ("serve is running but warm-swap is not enabled (or serve is unresponsive); restart serve with --enable-warm-swap\n").utf8))
            throw ExitCode(4)
        }
    }
}
```

(`ModelsSwitchCommand` and `ModelsStatusCommand` follow the same
pattern; each handles the three R-3.1.5.x error cases identically.)

The static helper `ControlSocketPaths.resolve(...)` lives in
`ControlSocket.swift` and applies the default
`$TMPDIR/macprovider-cli/ctl.sock` when `nil` is passed.

### C. `MacProviderCLI.swift` — extend

After the existing 1A/1B flags on `ServeCommand`, add:

```swift
@Option(help: "Control socket path. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock. Only meaningful when --enable-warm-swap is set.")
var ctlSocketPath: String?

@Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/macprovider-cli/last-switch.ts. Cooldown soft guard lands in Phase 1E.")
var switchStatePath: String?
```

Plumb both into `CLIOverrides` and `ConfigLoader.load`. The
resolved `AppConfig.ctlSocketPath` flows into `ControlSocketServer`
instantiation in `ServeCommand.run` when `resolved.enableWarmSwap`
is true:

```swift
let controlSocket: ControlSocketServer?
if resolved.enableWarmSwap {
    let socketURL = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
    controlSocket = ControlSocketServer(socketPath: socketURL, modelRuntime: modelRuntime)
    try await controlSocket?.start()
} else {
    controlSocket = nil
}
// ... defer { Task { await controlSocket?.stop() } }
```

Register `ModelsCommand` as a subcommand of `MacProviderCLI`:

```swift
subcommands: [
    ServeCommand.self,
    SelfTestCommand.self,
    StatusCommand.self,
    UpdateCommand.self,
    UninstallCommand.self,
    ModelsCommand.self,
],
```

### D. `Config.swift` — extend

Add to `AppConfig`:

```swift
public var ctlSocketPath: String?
public var switchStatePath: String?
```

Both default `nil`. Plumb YAML keys `ctl_socket_path` and
`switch_state_path` (strings), ENV vars
`MACPROVIDER_CTL_SOCKET_PATH` and `MACPROVIDER_SWITCH_STATE_PATH`,
and CLI overrides per existing pattern.

### E. `ControlSocketTests.swift` — NEW

Cover frame round-trip and decode rejection cases. Each test
encodes a frame, decodes the bytes back, and asserts equality
on the value. Plus the decode-side rejections:

- `testEncodeDecodeSwitchRequest`
- `testEncodeDecodeStatusRequest`
- `testEncodeDecodeSwitchAckAccepted`
- `testEncodeDecodeSwitchAckLoadingInProgress` — verifies
  `current_target` field present
- `testEncodeDecodeSwitchAckCooldown` — verifies
  `seconds_remaining` field present
- `testEncodeDecodeSwitchProgressLoading`
- `testEncodeDecodeSwitchProgressFailed` — verifies `reason`
  field present
- `testEncodeDecodeStatusResponseReady`
- `testDecodeRejectsMissingType` — `{"target_model_id": "X"}`
  throws `.missingType`
- `testDecodeRejectsUnknownType` — `{"type": "wat"}` throws
  `.unknownType("wat")`
- `testDecodeRejectsSwitchRequestMissingTarget` — throws
  `.missingRequiredField("target_model_id")`
- `testDecodeRejectsSwitchAckUnknownReason` — throws
  `.invalidEnumValue(field: "reason", value: "xyz")`
- `testEncodedBytesHaveNoForwardSlashEscaping` — encodes a
  switchRequest with `target_model_id: "mlx-community/Llama"`,
  asserts the resulting bytes contain `mlx-community/Llama`
  literally (NOT `mlx-community\/Llama`)

Plus serve-side socket lifecycle tests (using a temp directory):
- `testServerBindsAndAcceptsConnection` — start a server on a
  tmp socket path, connect via Darwin POSIX from the test,
  send `status_request`, receive `status_response`, assert
  current_model_id matches
- `testServerRefusesStartIfSocketAlreadyExists` — pre-create
  the socket file path with empty content, attempt
  `server.start()`, assert it throws and the stderr message
  matches constraint 3
- `testServerSocketParentDirIs0700AndSocketIs0600` — after
  `start()`, `stat` the parent dir and socket file and
  assert modes
- `testServerStopUnlinksSocket` — start, stop, assert
  socket file no longer exists

### F. `ModelsSubcommandTests.swift` — NEW

Cover the CLI side. Each test stands up a `ControlSocketServer`
on a tmp path against a stub `ModelRuntime` (use 1B's test
loader injection), then runs the parsed subcommand and asserts
on exit code + stdout/stderr.

- `testModelsStatusReturnsStatusResponse` — connect to a
  running server, receive status_response, assert stdout
  contains the model ID
- `testModelsStatusCase1ENOENT` — point ctl-socket-path at a
  non-existent file, run `models status`, expect ExitCode(4)
  and stderr containing `"is not running on this host"`
- `testModelsStatusCase2ECONNREFUSED` — create a regular
  file at the socket path (not a real listener), run
  `models status`, expect ExitCode(4) and stderr containing
  `"stale control socket"`
- `testModelsSwitchSuccess` — start a server with warm-swap-
  enabled stub runtime + 50ms stub loader, run `models switch
  new-model --supported-models old,new --model old`, expect
  ExitCode(0), stderr contains a `switch_progress` ladder
  (loading → loaded), stdout/stderr contains "loaded"
- `testModelsSwitchPreFlightRejection` — run `models switch
  C --supported-models A,B --model A`, expect ExitCode(2) and
  stderr containing `"switch target C not in
  --supported-models"`, AND assert NO socket connection
  occurred (e.g., point ctl-socket-path at a non-existent
  file and verify it's still absent after the command)
- `testModelsSwitchConcurrentRejection` — start a server,
  drive a slow swap to put state in loading, then run a
  second `models switch other-model`, expect ExitCode(3)
  and stderr containing `"provider is already loading"`

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` shows
  only the operator-authored BUILD prompts under
  `specs/BUILD_SPEC_001_v1_3_IMPL_*` and the pre-existing
  `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit.
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 90 tests
  green.
- All Phase 1A + 1B tests still GREEN (no regressions).
- `grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/` returns
  zero matches.
- `grep -rn "ctl.sock" phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  returns zero matches (the control socket is NOT wired into
  the WS coordinator client; they are independent surfaces).
- A v1.3 binary started with `serve` WITHOUT
  `--enable-warm-swap` does NOT create any file at
  `$TMPDIR/macprovider-cli/ctl.sock` (verifiable by checking
  the `ControlSocketServer` is only instantiated when
  `resolved.enableWarmSwap == true`).
- `models <subcommand>` invoked against a non-existent socket
  exits 4 with the R-3.1.5.x case-1 stderr.

## Out of scope (do NOT do these in Phase 1C)

- Cooldown soft guard + cooldown state file read/write —
  Phase 1E (1C plumbs the `--switch-state-path` flag only;
  no read/write logic)
- `--force` cooldown bypass logic — Phase 1E (1C accepts the
  flag as a no-op)
- Server-side `switch_ack accepted:false reason:cooldown`
  emission — Phase 1E
- Heartbeat extension (`model_hash` / `loading`) — Phase 1D
- `helloMessage()` source-of-truth rule on WS reconnect —
  Phase 1D
- WS drop policies mid-load — Phase 1E
- HF cache `disk_size_gb` column in `models list` — out of
  scope for 1C (spec marks `disk_size_gb` as optional;
  future polish)
- Modifying `phase4-coordinator/` — Phase 2

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -5) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/ || echo "no XDG_RUNTIME_DIR (correct)" && \
  echo "----" && \
  grep -rn "model_hash.*loading\|loading.*model_hash" phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift || echo "no heartbeat extension wired (correct — 1D)"
```

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

- Expected wall-clock: 120-150 min. 1C touches the operator-facing
  surface (socket protocol + CLI subcommand) and the integration
  surface (serve-side accept loop + signal-stream → progress
  frame translation).
- Audit pass (Claude Opus) reads the diff and tests against the
  16 constraints + done criteria. Key audit foci:
  - **Constraint 1 (L-1)** — verify the `ControlSocketServer` is
    only instantiated when `resolved.enableWarmSwap == true`.
  - **Constraint 3 (stale socket)** — verify the `bind()` failure
    is surfaced rather than silently unlinking.
  - **Constraint 4 (NDJSON)** — verify frames are line-terminated
    and rejected on missing `type`.
  - **Constraint 6 (detection precedence)** — verify all three
    R-3.1.5.x cases match the prescribed stderr exactly.
  - **Constraint 7 (switch exit codes)** — verify all five exit
    codes (0/2/3/4/5/6) are reachable in tests.
- R2 prompt is drafted only if R1 audit surfaces findings.
- After 1C LOCKs and commits to the branch, draft 1D (heartbeat
  extension + `hello.model_hash` source-of-truth on reconnect)
  referencing the actual signal-stream consumption pattern from
  1C.
