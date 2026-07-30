# R2 BUILD prompt — Phase 1A fix for finding M.1

Round-1 audit verdict on the Phase 1A implementation: 0 CRITICAL / **1 MAJOR** / 0 MINOR.

**M.1 (MAJOR) — Pre-flight gate fires on bare `serve`, regressing L-1 byte-identical default.**

- Location: `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:64-72` (the `do { let catalog = try SupportedModels.validate(...) } catch ...` block in `ServeCommand.run()`).
- Repro: `macprovider-cli serve` with neither `--model` nor `--supported-models` calls `SupportedModels.validate(model: "", supportedModels: nil)` which throws `.modelMissing`, the catch writes "--supported-models requires --model to be set" to stderr, and the process exits code 2.
- Why MAJOR: SPEC-001 v1.3 AC-N.0 mandates that a v1.3 binary invoked WITHOUT `--supported-models` AND WITHOUT `--enable-warm-swap` must exhibit byte-identical on-the-wire AND off-the-wire behavior to a v1.2.4 binary. v1.2.4 had no SPEC-010 pre-flight gate. v1.3 introduces one only for the case where the operator OPTED INTO `--supported-models`. The current code fires the gate even when the operator did not opt in.
- Binding rules: SPEC-001 v1.3 AC-N.0 (L-1 byte-identical default), SPEC-010 v1.5 R-3.6.3 (pre-flight is the validation gate for the OPERATOR-PROVIDED catalog; default `[model_id]` is a wire-emit-time fallback, not subject to pre-flight).

## Required fix

Gate the pre-flight on `resolved.supportedModels != nil`. Skip pre-flight entirely when the operator did not pass `--supported-models` (and ENV / YAML did not set it either).

### Patch — `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`

Locate the block introduced by Phase 1A R1:

```swift
do {
    let catalog = try SupportedModels.validate(
        model: resolved.model ?? "",
        supportedModels: resolved.supportedModels
    )
    resolved.supportedModels = catalog
} catch let error as SupportedModelsValidationError {
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    throw ExitCode(2)
}
```

Replace it with the gated form:

```swift
if resolved.supportedModels != nil {
    do {
        let catalog = try SupportedModels.validate(
            model: resolved.model ?? "",
            supportedModels: resolved.supportedModels
        )
        resolved.supportedModels = catalog
    } catch let error as SupportedModelsValidationError {
        FileHandle.standardError.write(Data(("\(error)\n").utf8))
        throw ExitCode(2)
    }
}
```

### Required new test — `phase3-binary/Tests/macprovider-cliTests/SupportedModelsTests.swift`

Add an XCTest that pins the L-1 invariant: when `--supported-models` is unset, pre-flight does NOT fire even if `--model` is also unset.

```swift
func testServeCommandSkipsPreflightWhenSupportedModelsUnset() async throws {
    // SPEC-001 v1.3 AC-N.0: a v1.3 binary invoked without --supported-models
    // must not exit code 2 from the SPEC-010 pre-flight gate even when --model
    // is also unset. (v1.2.4 surfaces missing-model elsewhere, not via
    // SPEC-010 exit 2.) Without this gate, Phase 1A regressed bare `serve`.

    let command = try ServeCommand.parse([])

    do {
        try await command.run()
        // run() will fail downstream (no coordinator, no model runtime in test
        // environment); that's expected. The only thing this test pins is that
        // the failure is NOT an ExitCode(2) thrown from the pre-flight gate.
        XCTFail("expected downstream failure, not clean exit")
    } catch let error as ExitCode {
        XCTAssertNotEqual(
            error, ExitCode(2),
            "pre-flight gate must NOT exit code 2 when --supported-models is unset"
        )
    } catch {
        // Any non-ExitCode error (config error, model runtime error, network
        // error, etc.) is fine — it proves we got past the pre-flight gate.
    }
}
```

If `ServeCommand.run()` blocks indefinitely in the test environment (e.g.
waits on a coordinator connection), wrap the call in a `Task` with a
2-second timeout and treat timeout as "got past pre-flight" (success).
A simpler alternative: factor the pre-flight block into a static helper
`static func runSupportedModelsPreflight(_ resolved: inout AppConfig)
throws` and test that helper directly with the three cases:

1. `model = nil, supportedModels = nil` → no throw
2. `model = nil, supportedModels = ["A"]` → throws `ExitCode(2)`
3. `model = "A", supportedModels = nil` → no throw

The static-helper refactor is preferred because it isolates the gate
from the rest of `ServeCommand.run()` and makes the regression test
deterministic. If you take that path, also update the existing
`testServeCommandExits2WhenModelNotInSupportedModels` to call the helper
directly (or keep both — helper test + end-to-end test).

## Out of scope for R2

- DO NOT change `SupportedModels.validate` semantics. The behavior of
  validate(model: "", supportedModels: nil) throwing `.modelMissing`
  is correct — that case represents a programmer error in the pre-flight
  caller, not a user-facing condition. The fix is in the CALLER, not
  the library.
- DO NOT change `Config.swift`, `CoordinatorClient.swift`, or any other
  file from R1. Only `MacProviderCLI.swift` (one block) and the test
  file (one new test, optionally a refactor).
- DO NOT introduce new CLI flags, ENV vars, or YAML keys.

## Done criteria

- The new test `testServeCommandSkipsPreflightWhenSupportedModelsUnset`
  (or the equivalent static-helper test trio) is GREEN.
- All pre-R1 tests still GREEN (52/52 including the new one, or
  more if you chose the helper-trio).
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0.
- `git diff specs/ phase4-coordinator/ phase5-gateway/` shows only the
  pre-existing `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged
  edit and the operator-authored `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1A_*` files.
  No NEW spec edits.
- The grep checks from R1 still hold:
  - `grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/` → zero
  - `grep -rn "enable-warm-swap\|enableWarmSwap" phase3-binary/Sources/` → zero

Report back with: (a) the resulting diff, (b) the final `swift test`
summary line, (c) confirmation that
`testServeCommandSkipsPreflightWhenSupportedModelsUnset` (or its
helper-trio equivalent) is in the suite and green.

Do NOT commit. Do NOT push.
