# Implementation BUILD prompt — SPEC-001 v1.3 Phase 1A (SPEC-010 catalog surface)

Operator-paste prompt for Codex GPT-5 to land the **first** of five
implementation sub-phases of SPEC-001 v1.3 in `phase3-binary/`. This
phase is purely additive, defaults preserve byte-identical wire
behavior, and unblocks Phases 1B-1E (which build on the warm-swap
state machine and control socket).

**Scope: SPEC-010 v1.5 binary surface only.** No SPEC-011 warm-swap,
no state machine, no control socket, no heartbeat extension, no
`models` subcommand. Those are 1B-1E.

**One-line summary.** Add the two SPEC-010 CLI flags
(`--supported-models`, `--publish-supported-models`) plumbed through
the existing CLI > ENV > YAML config priority; create a new
`SupportedModels.swift` library with pre-flight validation per
SPEC-010 v1.5 R-3.6.1 / R-3.6.3; wire the two optional fields onto
the v2 `auth_request` initial-stage frame at
`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:644`
per SPEC-001 v1.3 §6.7.1 / R-6.7.3. Add tests proving (a) the L-1
byte-identical default (R-6.7.3: `supported_models: [model_id]`
single-entry; `publishes_supported_models` omitted), (b) pre-flight
exit-code-2 on `--model` not in `--supported-models`, (c) explicit
catalog emitted when flag set.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.3 (the spec this implements — read §6.2 CLI flag
  additions and §6.7 v2 `auth_request` handshake)
- SPEC-010 v1.5 (binding source for §3.1.A field table, §3.6 CLI
  flags, R-3.1.1-R-3.1.10 wire rules, R-3.6.1-R-3.6.4 binary CLI
  rules, §4.1 observable-indistinguishability lemma)
- SPEC-002 v1.3.5 (coordinator parser truth — do not edit; this
  phase emits fields that v1.3.5 already accepts)

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~60-90 min
(2 new Swift files, 1 file modified, 1 file extended with flag
plumbing, 1 test file new, 1 test file extended).

Branch: `fix/spec-001-v1-3-binary` (already checked out by
operator). Codex MUST NOT create a new branch.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1A of SPEC-001 v1.3 in the Swift binary
at /Users/augstar/macprovider-poc/phase3-binary/. SPEC-001 v1.3 is
LOCKED (merged to main in PR #4 commit b4d87b5). SPEC-010 v1.5 is
LOCKED. SPEC-011 v0.5 is LOCKED but OUT OF SCOPE for this phase.

You will edit/create the following files (and ONLY these):

  phase3-binary/Sources/MacProviderCore/Config.swift          (extend)
  phase3-binary/Sources/MacProviderCore/SupportedModels.swift (NEW)
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift  (extend)
  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift (extend)
  phase3-binary/Tests/macprovider-cliTests/SupportedModelsTests.swift (NEW)
  phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift (extend)

You will NOT edit any file under specs/, phase4-coordinator/,
phase5-gateway/, or any other Swift file. Verify with
`git diff specs/ phase4-coordinator/ phase5-gateway/` — must be
empty before you finish.

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 R-6.7.3.**
With neither `--supported-models` nor `--publish-supported-models`
set, the v2 `auth_request` initial-stage frame MUST carry
`supported_models: [model_id]` (single-entry, lower-cased exactly
as `--model`) and MUST OMIT `publishes_supported_models` entirely
(field absent from the JSON object, not `null` / not `false`).
Tests MUST prove this by reading the serialized JSON.

**2. SPEC-010 fields are NOT gated by `--enable-warm-swap`.** Per
SPEC-001 v1.3 §6.7.3 + SPEC-010 v1.5 R-3.6.1 / R-3.6.4, the two
SPEC-010 fields are controlled by their own flags, independent of
the SPEC-011 warm-swap opt-in. Do not introduce
`--enable-warm-swap` in this phase. (It lands in Phase 1B.)

**3. CLI > ENV > YAML priority.** Mirror the existing
`AppConfig` / `ConfigLoader` pattern in
`phase3-binary/Sources/MacProviderCore/Config.swift`. Add YAML
keys `supported_models: [string]` and `publishes_supported_models:
bool`. Add ENV vars `MACPROVIDER_SUPPORTED_MODELS` (comma-
separated) and `MACPROVIDER_PUBLISHES_SUPPORTED_MODELS` (bool).
Add CLI flags `--supported-models <ids>` (comma-separated) and
`--publish-supported-models <bool>` on the `ServeCommand` struct
in `MacProviderCLI.swift`. CLI overrides ENV; ENV overrides YAML;
default is unset.

**4. Pre-flight validation per SPEC-010 v1.5 R-3.6.3.** Inside a
new pure module `MacProviderCore/SupportedModels.swift`,
implement:

  - `func validate(model: String, supportedModels: [String]?)
     throws -> [String]`
    - Returns the RESOLVED catalog (the array to put on the wire).
    - Default rule (R-3.6.2 + R-6.7.3): if `supportedModels` is
      nil OR empty after parsing, return `[model]` (single-entry,
      preserving `model` case verbatim).
    - When `supportedModels` is non-empty:
      - Trim whitespace from each entry.
      - Drop empty entries after trimming.
      - Reject (throw) if any entry length > 256 UTF-8 bytes
        (R-3.6.3).
      - Reject (throw) if total entry count > 64 (R-3.6.3).
      - Reject (throw) if `model` is not present in the list under
        a CASE-FOLDED comparison (R-3.6.3 — Swift
        `.lowercased(with: nil)` is fine for this; the comparison
        is canonical lower-case folding, NOT Unicode NFKC).
      - On success return the original (pre-trim NOT, post-trim
        YES; preserve entry case as the operator provided it).
    - The throw type is a new public enum
      `SupportedModelsValidationError` with the cases:
      - `.modelNotInCatalog(model: String, catalog: [String])`
      - `.entryTooLong(entry: String, byteCount: Int)`
      - `.catalogTooLarge(count: Int)`
      - `.modelMissing` (caller passes empty string for model)
    - Each case's `CustomStringConvertible` message MUST match
      these exact patterns (acceptance tests will assert on
      substring match):
      - `"--model <X> not in --supported-models"`
      - `"--supported-models entry exceeds 256 UTF-8 bytes: ..."`
      - `"--supported-models exceeds 64 entries (got N)"`
      - `"--supported-models requires --model to be set"`

  - `static func parseCSV(_ raw: String?) -> [String]?` —
    parses comma-separated CLI/ENV input. Returns nil for
    nil/whitespace-only; returns the trimmed-non-empty list
    otherwise. Preserves entry case.

**5. Pre-flight runs BEFORE WS connection.** Per SPEC-010 v1.5
R-3.6.3 / AC-N.2: a validation failure MUST exit code 2 BEFORE
the coordinator WebSocket is opened. Wire this into
`ServeCommand.run()` in `MacProviderCLI.swift` between
`ConfigLoader.load(...)` and `ModelRuntime(...)` instantiation.
On `SupportedModelsValidationError`, print the error description
to stderr (`FileHandle.standardError`) and call `throw
ExitCode(2)` (ArgumentParser's exit-code wrapper) so the process
exits 2.

**6. v2 `auth_request` initial-stage emission.** In
`CoordinatorClient.authInitialMessage(attempt:)` at
`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:644`,
ALWAYS set `supported_models` and conditionally set
`publishes_supported_models`:

  - Carry the resolved catalog through `AppConfig` (add fields
    `var supportedModels: [String]?` and `var
    publishesSupportedModels: Bool` to `AppConfig`; default the
    bool to `false`; the array stays Optional<[String]>).
  - Plumb both into `CoordinatorClient` via its existing
    `config: AppConfig` field (no new init args).
  - In `authInitialMessage`, after the existing dictionary
    construction:
    - Compute `resolvedCatalog` via
      `SupportedModels.validate(model: snapshot.modelID ?? "",
      supportedModels: config.supportedModels)`. If this throws
      at runtime, that is a programmer error (pre-flight should
      have caught it); the WS connect attempt that produced the
      auth_request should NEVER have started. Use `try?` and fall
      back to `[snapshot.modelID ?? ""]` so the wire frame is
      well-formed even in the impossible case.
    - Set `message["supported_models"] = resolvedCatalog`.
    - If `config.publishesSupportedModels == true`, set
      `message["publishes_supported_models"] = true`. Otherwise
      do NOT touch the key (per constraint 1).

**7. v2 `auth_request` proof-stage.** Per SPEC-001 v1.3 R-6.7.6,
if the binary re-sends the SPEC-010 fields on the proof stage
they MUST be byte-identical to the initial stage. For Phase 1A,
do NOT re-send them on the proof stage. The proof stage emits
only the existing fields. (We may add proof-stage re-send in a
later phase if a CRITICAL audit finding requires it; SPEC-010
v1.5 §3.1.C marks both fields "optional, absent is not a
mismatch".)

**8. Legacy `hello` UNTOUCHED.** Per SPEC-001 v1.3 AC-N.11 and
§6.5 byte-identical guarantee, do NOT modify
`CoordinatorClient.helloMessage()` at line 675 in this phase.
Phase 1D will revisit `hello` for SPEC-011 heartbeat reconnect
source-of-truth.

**9. No d-inference inspection.** Do not read any file under
`phase3-binary/.build/checkouts/`. Use only the public SPEC + the
in-repo Swift sources for grounding.

**10. Compile + tests pass.** After your edits:
  - `cd phase3-binary && swift build` MUST succeed.
  - `cd phase3-binary && swift test` MUST succeed (existing
    tests untouched + your new tests).
  - The macOS Swift toolchain is the only target; do not add
    Linux conditionals.

## Required reading (in this order — read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   §6.7 (lines 1594-1747) — the v2 `auth_request` handshake
   normative section. R-6.7.1 through R-6.7.10 are binding.

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   - §3.1.A (parser-required field table)
   - §3.1.B (wire example)
   - §3.6 R-3.6.1 through R-3.6.4 (binary CLI rules)
   - §4.1 (observable-indistinguishability lemma — explains why
     single-entry default preserves L-1)

3. `/Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCore/Config.swift`
   — full file. Mirror the existing `assign(...)` helper pattern
   exactly for the two new YAML keys and two new ENV vars. Do
   NOT introduce a new pattern.

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
   lines 1-120 — the `ServeCommand` struct. Add the two new
   `@Option` fields at the end of the existing options list,
   mirroring the existing help-string style. Pass them through
   `CLIOverrides` to `ConfigLoader.load(...)`.

5. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
   - `authInitialMessage(attempt:)` at line 644 — the v2 initial-
     stage builder
   - `authProofMessage(challenge:attempt:)` at line 397 — the
     proof-stage builder (DO NOT modify in this phase)
   - `helloMessage()` at line 675 — legacy hello (DO NOT modify
     in this phase)

6. `/Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`
   — existing test patterns; mirror them for your new assertions.

7. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions
   (commit identity is already correct on this branch; do NOT
   change git config).

## Required edits — exact shape

### A. `Config.swift` — extend `AppConfig` + `CLIOverrides` + loader

In `AppConfig` (after `tier2MDAArtifactPath`):

```swift
public var supportedModels: [String]?
public var publishesSupportedModels: Bool
```

In `AppConfig.defaults(...)`:
- `supportedModels: nil`
- `publishesSupportedModels: false`

In `CLIOverrides`:

```swift
public var supportedModels: [String]?
public var publishesSupportedModels: Bool?
```

Extend `CLIOverrides.init(...)` accordingly (new params at the
end of the param list; default to nil).

In `applyYAMLConfig`: handle keys `supported_models` (array of
strings) and `publishes_supported_models` (bool). Add a new
`assign` overload for `inout [String]?` from a YAML dictionary
if one does not already exist; it MUST accept a YAML sequence of
strings or a single string (split on `,`). Reject other shapes
with `ConfigError.invalidValue`.

In `applyEnvironment`: handle `MACPROVIDER_SUPPORTED_MODELS`
(parsed via `SupportedModels.parseCSV`) and
`MACPROVIDER_PUBLISHES_SUPPORTED_MODELS` (bool).

In `applyCLI`: assign from `cli.supportedModels` and
`cli.publishesSupportedModels` if non-nil.

### B. `SupportedModels.swift` — NEW file under MacProviderCore

```swift
import Foundation

public enum SupportedModelsValidationError: Error,
    CustomStringConvertible, Equatable
{
    case modelMissing
    case modelNotInCatalog(model: String, catalog: [String])
    case entryTooLong(entry: String, byteCount: Int)
    case catalogTooLarge(count: Int)

    public var description: String { /* per constraint 4 */ }
}

public enum SupportedModels {
    public static let maxEntryByteLength = 256
    public static let maxCatalogEntries = 64

    public static func parseCSV(_ raw: String?) -> [String]? {
        // returns nil for nil / whitespace-only input;
        // returns trimmed non-empty entries otherwise
    }

    public static func validate(
        model: String,
        supportedModels: [String]?
    ) throws -> [String] {
        // per constraint 4
    }
}
```

The exact wording of the `description` strings is asserted by
tests — match constraint 4 literally.

### C. `MacProviderCLI.swift` — extend `ServeCommand`

After `var logLevel: String?` (line ~43), add:

```swift
@Option(parsing: .singleValue, help: "Comma-separated list of HuggingFace model IDs (or local paths) this provider can serve. Overrides MACPROVIDER_SUPPORTED_MODELS and config key supported_models. When unset, the binary publishes supported_models: [model_id] (single-entry, per SPEC-010 v1.5 R-3.6.2).")
var supportedModels: String?

@Flag(name: .customLong("publish-supported-models"), inversion: .prefixedNo, help: "Opt into publishing the supported_models catalog to the coordinator's /v1/status echo (SPEC-010 v1.5 R-3.6.4). Default off.")
var publishSupportedModels: Bool?
```

Note the `Bool?` (tri-state) so that unset means "fall through to
ENV / YAML / default-false". `ArgumentParser` `@Flag` with
`inversion: .prefixedNo` accepts `--publish-supported-models` /
`--no-publish-supported-models`. If unset, the value is `nil`.

In `ServeCommand.run()`:
- Build `CLIOverrides` with
  `supportedModels: SupportedModels.parseCSV(supportedModels)`
  and `publishesSupportedModels: publishSupportedModels`.
- After `ConfigLoader.load(...)` returns `resolved`:
  - Call `let catalog = try SupportedModels.validate(model:
    resolved.model ?? "", supportedModels:
    resolved.supportedModels)`.
  - On `SupportedModelsValidationError`, do:
    `FileHandle.standardError.write(Data(("\(error)\n").utf8))`
    then `throw ExitCode(2)`.
  - Store the resolved catalog back into a local variable, OR
    overwrite `resolved.supportedModels` with the validated
    catalog. (Either is fine; downstream
    `CoordinatorClient.authInitialMessage` re-validates with
    `try?`.)

### D. `CoordinatorClient.swift` — extend `authInitialMessage`

After the existing dictionary literal (around line 665), before
the existing `if let endpointURL` block:

```swift
let resolvedCatalog: [String]
do {
    resolvedCatalog = try SupportedModels.validate(
        model: snapshot.modelID ?? "",
        supportedModels: config.supportedModels
    )
} catch {
    resolvedCatalog = [snapshot.modelID ?? ""]
}
message["supported_models"] = resolvedCatalog
if config.publishesSupportedModels {
    message["publishes_supported_models"] = true
}
```

DO NOT modify `helloMessage()` or `authProofMessage(...)`.

### E. `SupportedModelsTests.swift` — NEW test target file

Cover (each as a separate XCTest):

- `testParseCSVNilInput` — nil/empty/whitespace yields nil.
- `testParseCSVTrimsAndDropsEmpty` — `" A , ,B,  "` → `["A","B"]`.
- `testValidateDefaultsToSingleEntry` —
  `validate(model: "A", supportedModels: nil) == ["A"]`.
- `testValidateDefaultSingleEntryPreservesCase` —
  `validate(model: "MlX/Foo", supportedModels: nil) ==
  ["MlX/Foo"]`.
- `testValidateRejectsMissingModel` —
  `validate(model: "", supportedModels: nil)` throws
  `.modelMissing`.
- `testValidateAcceptsCaseFoldedMatch` —
  `validate(model: "MLX/FOO", supportedModels: ["mlx/foo",
  "B"])` returns `["mlx/foo", "B"]` (entry case preserved).
- `testValidateRejectsModelNotInCatalog` —
  `validate(model: "C", supportedModels: ["A","B"])` throws
  `.modelNotInCatalog`; description contains `"--model C not
  in --supported-models"`.
- `testValidateRejectsTooLongEntry` — 257-byte entry throws
  `.entryTooLong`; description contains
  `"--supported-models entry exceeds 256 UTF-8 bytes"`.
- `testValidateRejectsTooManyEntries` — 65 entries throws
  `.catalogTooLarge`; description contains `"exceeds 64
  entries"`.
- `testValidateCountsUTF8BytesNotCharacters` — a 130-character
  string of emoji (e.g. `String(repeating: "😀", count: 65)` is
  260 UTF-8 bytes) MUST throw `.entryTooLong`.

### F. `CoordinatorClientTests.swift` — extend

Add four new XCTests. Each constructs a `CoordinatorClient`
with a hand-rolled `AppConfig`, calls
`authInitialMessage(attempt:)` with a dummy `Tier2AuthAttempt`,
serializes the returned dictionary to JSON, and asserts on the
JSON.

- `testAuthInitialDefaultsToSingleEntryCatalog` —
  `AppConfig.supportedModels = nil`,
  `publishesSupportedModels = false`. The JSON MUST contain
  `"supported_models":["model-id-from-snapshot"]` AND MUST NOT
  contain the substring `"publishes_supported_models"`.
- `testAuthInitialEmitsExplicitCatalogWhenSet` —
  `AppConfig.supportedModels = ["A","B"]`,
  `model = "A"`,
  `publishesSupportedModels = true`. The JSON MUST contain
  `"supported_models":["A","B"]` AND
  `"publishes_supported_models":true`.
- `testAuthInitialOmitsPublishesWhenFalse` —
  `supportedModels = ["A","B"]`,
  `publishesSupportedModels = false`. The JSON MUST contain
  `"supported_models":["A","B"]` AND MUST NOT contain
  `"publishes_supported_models"`.
- `testHelloMessageUnchangedByPhase1A` — call
  `helloMessage()`, serialize to JSON, assert that the substring
  `"supported_models"` does NOT appear and
  `"publishes_supported_models"` does NOT appear. This pins
  AC-N.11 byte-identical §6.5 guarantee.

If `CoordinatorClient` initialization requires fixtures (mock
`ProviderStatus`, mock attestation generator, etc.), reuse what
`CoordinatorClientTests.swift` already does. DO NOT change
production code to make testing easier.

## Done criteria

You are done when:

- `git diff specs/ phase4-coordinator/ phase5-gateway/` is empty.
- `git diff phase3-binary/Sources/macprovider-cli/HTTPServer.swift
  phase3-binary/Sources/macprovider-cli/InferenceRelay.swift
  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
  phase3-binary/Sources/macprovider-cli/ProviderStatus.swift
  phase3-binary/Sources/macprovider-cli/SelfUpdate.swift
  phase3-binary/Sources/macprovider-cli/Tier2Attestation.swift
  phase3-binary/Sources/macprovider-cli/Tier2ProviderSession.swift
  phase3-binary/Sources/macprovider-cli/UninstallCommand.swift
  phase3-binary/Sources/macprovider-cli/AsyncSemaphore.swift` is
  empty.
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with all new tests
  GREEN and all pre-existing tests still GREEN.
- The new `SupportedModels.swift` file has no `import` other
  than `Foundation`.
- `grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/` returns
  zero matches.
- `grep -rn "enable-warm-swap\|enableWarmSwap" phase3-binary/
  Sources/` returns zero matches (Phase 1B introduces that flag,
  not 1A).

## Out of scope (do NOT do these in Phase 1A)

- `--enable-warm-swap`, `--swap-drain-timeout-seconds`,
  `--ctl-socket-path`, `--switch-state-path` — Phase 1B.
- `ModelRuntime` refactor from `let container` to actor-isolated
  `current_container` — Phase 1B.
- `RuntimeStateMachine.swift` — Phase 1B.
- `ControlSocket.swift` — Phase 1C.
- `ModelsSubcommand.swift` (`models list / switch / status`) —
  Phase 1C.
- Heartbeat `model_hash` / `loading` fields — Phase 1D.
- `helloMessage()` source-of-truth rule for WS-drop reconnect —
  Phase 1D.
- Modifying `phase4-coordinator/` for SPEC-002 v1.3.5 — Phase 2.

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -5) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | tail -20) && \
  echo "----" && \
  grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/ || echo "no XDG_RUNTIME_DIR (correct)" && \
  echo "----" && \
  grep -rn "enable-warm-swap\|enableWarmSwap" phase3-binary/Sources/ || echo "no warm-swap surface (correct)"
```

Return:
- A brief diff summary (files touched, +/- lines).
- The output of `swift test` final summary line.
- Any spec rule you were unable to satisfy exactly, with the
  binding rule number and your interpretation.

Do NOT commit. Do NOT push. The operator audits the working tree
before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 60-90 min for Codex GPT-5 on a fresh
  context. Phase 1B (state machine + ModelRuntime refactor) is
  the heavy phase; 1A is intentionally small to validate the
  draft-build-audit loop before scaling up.
- Audit pass (Claude Opus) reads the diff, asserts the 10
  constraints + 11 done-criteria items, and reports findings as
  `R1` (round 1) verdict: `0 CRITICAL / 0 MAJOR / 0 MINOR` is
  LOCK; non-zero spawns a round-2 Codex prompt that cites the
  open findings.
- After LOCK, operator commits the diff with a conventional
  message and opens the PR via the per-repo `Augustas11` credential
  helper (per project CLAUDE.md).
- Phase 1B prompt is drafted only after Phase 1A LOCKs and
  merges, mirroring the SPEC-010 / SPEC-011 sequential discipline.
