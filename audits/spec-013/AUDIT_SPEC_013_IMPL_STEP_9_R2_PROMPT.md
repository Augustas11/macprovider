# Implementation audit prompt — SPEC-013 Step 9 round 2 (closure verification)

Round 1 (codex on 292b2f9) returned `0 CRITICAL / 0 MAJOR / 4 MINOR /
1 QUESTION`, verdict READY TO PROCEED TO STEP 10. Commit d6c634c
claims to close all 5 findings to satisfy the "until 0 findings"
loop discipline. Round 2 verifies the closures and spot-checks
the new surface: an optional `recipeHash`, an `O_CREAT | O_EXCL`
backup write, two stronger AC-9 tests, and the strengthened
launchd hint test.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-25
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 9 implementation audit on
branch `feat/cli-autotune-impl`. Round 1 (Codex on 292b2f9) is at
specs/SPEC-013-impl-audit.md § Round 16 and returned
0 CRITICAL / 0 MAJOR / 4 MINOR / 1 QUESTION. Commit d6c634c
closes all 5 findings.

Round 2 has two questions:
1. Did d6c634c actually close B.1 (QUESTION), E.1 (MINOR),
   G.1 (MINOR), I.1 (MINOR), and K.1 (MINOR)?
2. Did the fix-pass introduce any NEW precision gap? The new
   surface is:
   - `EmittedRecommendation.recipeHash: String?` (was
     `String`).
   - `RecommendationEmitter.recipeHash(_:)` returns `String?`
     (was `String`); nil when `inputs.recommendation == nil`.
   - JSON encoder emits literal `null` for `recipe_hash` when
     recipeHash is nil.
   - `ConfigApplier.writeBackupExclusively` (NEW) replaces
     `firstAvailableBackupPath` + `atomicWrite-to-backup`.
     Uses `open(O_CREAT | O_EXCL | O_WRONLY)` + raw `write(2)`
     loop with EINTR retry.
   - New error case `ConfigApplierError.backupWriteFailed(destination:, errno:)`.
   - 4 new tests: testRecipeHashIsNilWhenRecommendationIsNil,
     testApplyBackupUsesExclusiveCreateAgainstTOCTOURace,
     testApplyPreservesNonOwnedLinesByteIdentically,
     testApplyResultIsParseableByConfigLoader.
   - Renamed test: testLaunchdRestartHintIncludesBootoutAndBootstrap
     → testLaunchdRestartHintIncludesAllRequiredSubstrings.
   - Adjusted test: testApplyWriteIsAtomic now asserts
     tempPaths.count == 1 (was 2).

This is a **read-only review**.

## Required reading

1. The audit-response commit via `git show d6c634c`.
2. Round-1 report: specs/SPEC-013-impl-audit.md § Round 16.
3. Step 9 source as patched:
   - `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
     (recipeHash Optional, JSON null encoding).
   - `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
     (writeBackupExclusively, writeAll, backupWriteFailed).
   - `phase3-binary/Tests/macprovider-cliTests/RecommendationEmitterTests.swift`
     (testJSONOutputMatchesSpec013Schema rewritten,
     testRecipeHashIsNilWhenRecommendationIsNil added,
     testJSONOutputRecipeHashFormat updated for Optional unwrap).
   - `phase3-binary/Tests/macprovider-cliTests/ConfigApplierTests.swift`
     (testApplyBackupUsesExclusiveCreateAgainstTOCTOURace,
     testApplyPreservesNonOwnedLinesByteIdentically,
     testApplyResultIsParseableByConfigLoader,
     testApplyWriteIsAtomic adjusted,
     testLaunchdRestartHintIncludesAllRequiredSubstrings renamed).
   - `phase3-binary/implementation-notes.html` Step 9 round-1
     audit-response entry.

4. Run `swift test --package-path phase3-binary` — fix-pass
   claims 348 tests, 2 skipped, 0 failures.

## Severity definitions (unchanged)

- **CRITICAL** — B.1/E.1/G.1/I.1/K.1 closure is cosmetic; the
  O_EXCL backup write has a race or silently overwrites; the
  Optional recipeHash regression breaks an existing AC-12
  property; anti-regression broke a test.
- **MAJOR** — closure incomplete; new ConfigApplierError case
  is unreachable or hides a real failure mode; new tests pass
  tautologically without exercising the named branches; the
  `writeAll` EINTR loop is wrong.
- **MINOR** — quality issues.
- **QUESTION** — design choice.

## Round 2 audit categories

### Category Z-CLOSURE

**B.1 (QUESTION) — nil-recommendation recipe_hash policy.**
Round 1 asked Step 10 to choose between (a) persist degenerate
hash, (b) NULL in DB. d6c634c chose (b) and pre-committed it
at Step 9 by making `recipeHash` Optional. Verify:
- `EmittedRecommendation.recipeHash` is now `String?` (declared
  at `RecommendationEmitter.swift:42-48`).
- `RecommendationEmitter.recipeHash(_:)` returns `nil` when
  `inputs.recommendation == nil` (guard at the top of the
  function).
- JSON encoder emits literal `"recipe_hash":null` (not the
  string `"null"`) when recipeHash is nil. Walk
  `JSONRoot.encode(to:)` and verify the if-let / encodeNil
  branch.
- `testRecipeHashIsNilWhenRecommendationIsNil` asserts BOTH
  `emitted.recipeHash == nil` AND the parsed JSON
  `root["recipe_hash"] is NSNull`.
- The Optional change does NOT regress existing assertions
  (e.g. `testRecipeHashMatchesReferenceVector`,
  `testRecipeHashSensitiveTo*`, `testRecipeHashIgnoresObservationFields`)
  because these all have a non-nil recommendation. Verify by
  spot-check of one or two.

**E.1 (MINOR) — JSON schema test too weak.** d6c634c rewrote
`testJSONOutputMatchesSpec013Schema`. Verify:
- Every documented nested key is asserted with a primitive
  type assertion (e.g. `as? Int`, `as? String`, `as? Double`).
- `Set(dict.keys) == <expected>` is asserted for `machine`,
  `inputs`, `recommendation`, `recommendation.knobs`, and
  `infeasible[0]`. This catches any future field ADDITION
  that wasn't documented (and forces a deliberate schema bump).
- ISO-8601 regex is asserted on both `started_at` and
  `ended_at`.
- The alternates list and infeasible list assertions match
  the documented order and content.

**G.1 (MINOR) — TOCTOU race.** d6c634c replaces
`firstAvailableBackupPath` + `atomicWrite-to-backup` with
`writeBackupExclusively`. Verify:
- `writeBackupExclusively` opens each candidate counter path
  with `open(O_CREAT | O_EXCL | O_WRONLY, 0o644)`.
- On success: defers `close(fd)`, calls `writeAll(fd:, data:,
  destination:)`, returns the backup URL.
- On `EEXIST`: retries the next counter.
- On any other errno: throws
  `ConfigApplierError.backupWriteFailed(destination:, errno:)`.
- The candidate path construction is unchanged from round 1
  (same `<config>.bak-<unix-ts>-<counter>` pattern).
- The 0o644 permissions are appropriate.
- The `writeAll` loop correctly handles EINTR (retries) AND
  partial writes (advances the buffer pointer by `n` bytes).
  Walk the loop and verify the pointer arithmetic:
  `base.advanced(by: written)` and `data.count - written`.
- If `write(2)` returns 0 (rare but possible), the loop must
  not infinite-loop. Verify: `n == 0` would set `written += 0`,
  and the loop continues with the same `written`. If
  `data.count > 0` and `n == 0` is returned repeatedly, this
  IS an infinite loop. Flag as MAJOR if observed.
- `testApplyBackupUsesExclusiveCreateAgainstTOCTOURace`
  pre-creates 4 backup files, calls apply, asserts the new
  backup is at counter 4 AND all 4 pre-existing files retain
  their byte content. This catches a regression that would
  overwrite or truncate.

**I.1 (MINOR) — AC-9 preservation too weak.** d6c634c adds
two stronger tests. Verify:
- `testApplyPreservesNonOwnedLinesByteIdentically` uses a
  fixture with leading comment, blank lines, inline comment
  (`provider_token: keep-me  # inline keepalive`), block
  comment, trailing comment, and a SPEC-013 zone marker
  comment. The `nonOwnedLines` helper splits pre and post
  into lines, filters out the 4 owned keys, and asserts
  `preNonOwned == postNonOwned`. Walk the helper to verify
  it correctly identifies non-owned lines (top-level only,
  not indented, not a `key:` or `key: value` line for the 4
  owned keys).
- `testApplyResultIsParseableByConfigLoader` calls
  `ConfigLoader.load(cli: CLIOverrides(configPath: ...))`
  with `environment: [:]` and asserts the loaded config
  resolves `model`, `kvBitsOverride`, `maxContextOverride`,
  `maxConcurrencyOverride` to the recommendation values.
  This catches a future drift where Config.swift's YAML key
  names diverge from the applier's.
- The `import MacProviderCore` is added to the test file.

**K.1 (MINOR) — launchd hint test too narrow.** d6c634c
renames the test and adds two assertions. Verify:
- `testLaunchdRestartHintIncludesAllRequiredSubstrings`
  asserts ALL of:
  - `launchctl bootout`
  - `launchctl bootstrap`
  - `~/Library/LaunchAgents/live.streamvc.macprovider.plist`
  - `gui/$UID/live.streamvc.macprovider`
- The implementation at
  `RecommendationEmitter.launchdRestartHint()` still
  contains all four substrings (didn't drift).

### Category R-REGRESSION-V09F1

- swift test reports 348 + 2 skipped, 0 failures.
- Pre-existing Step 1-8 tests still pass.
- The recipeHash Optional change does NOT break any prior
  test (verify by spot-checking 2-3 tests that use
  `emitted.recipeHash`).
- The testApplyWriteIsAtomic adjustment (tempPaths.count == 1)
  is correct: only the config write uses temp+rename now.

### Category N-NEWGAPS-V09F1

- **writeAll EINTR / partial-write correctness.** Walk
  `writeAll` line by line. The loop terminates when
  `written == data.count`. Each iteration: `write(fd, base
  + written, data.count - written)`. If `n < 0` and `errno
  == EINTR`, continue (retry). If `n < 0` and other errno,
  throw `backupWriteFailed`. If `n >= 0`, increment
  `written` by `n`. Verify the `n == 0` case is acceptable
  (POSIX allows write(2) to return 0 for zero-length writes
  but `data.count - written > 0` here, so a 0 return would
  be a benign no-op; the loop would advance only via the
  next non-zero return). For unbuffered file writes this is
  not an issue in practice. Acceptable as-is for v1.
- **Optional recipeHash callers in Step 10.** Step 10 will
  consume `EmittedRecommendation.recipeHash` and persist
  it to `tune_runs.recipe_hash`. The Step 10 wiring must
  bind NULL when recipeHash is nil. Step 9 cannot test
  this directly, but verify Step 9's
  `EmittedRecommendation` is the load-bearing seam — no
  static state, no caching.
- **Concurrent backup race surface.** With O_EXCL, two
  concurrent applies on the same `<config>.bak-<ts>-0` path
  will result in one succeeding and one retrying counter 1.
  Both still succeed; no overwrite. Acceptable.
- **Optional recipeHash JSON encoding edge.** Walk the
  encoder for the case when recipeHash is nil. The
  `if let recipeHash` branch calls `encode(recipeHash,
  forKey: .recipeHash)`; the else branch calls
  `encodeNil(forKey: .recipeHash)`. Both should produce
  the same key in the output JSON (one as string, one as
  null). The new test
  `testRecipeHashIsNilWhenRecommendationIsNil` confirms
  via `NSNull` parsing.
- **`nonOwnedLines` helper false positives.** What if an
  operator's non-owned key happens to be named identically
  to an owned key but at indentation? The helper's
  `first?.isWhitespace != true` guard excludes indented
  lines — they're treated as non-owned (returned in the
  filtered list). This is correct for our case but mention
  if the test would fail to detect a dropped indented
  owned-key-named line. Not a real concern since YAML
  doesn't recurse the owned key set.

### Category O-OTHER-V09F1

Use sparingly.

## Output structure

APPEND to specs/SPEC-013-impl-audit.md:

```
---

## Round 17 audit (Codex on d6c634c — Step 9 round 2 closure verification)

**Audited:** commit d6c634c on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 9, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 5 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 9 readiness:** [READY TO PROCEED TO STEP 10 / NARROW V3 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

B.1, E.1, G.1, I.1, K.1: closure verdict + short paragraph each.

### Round-2 new findings

Group by category Z / R / N / O.

### Step 9 readiness verdict

State READY TO PROCEED TO STEP 10 or NARROW V3 REQUIRED.
```

## Out of scope

- Re-litigating Steps 1-8 (LOCKED)
- Auditing Steps 10-11 (not yet started)
- Re-litigating round-1 closures already verified
- Inspecting d-inference source

## Done criteria

- New `## Round 17 audit ...` section appended
- Earlier rounds (1-16) unchanged
- B.1 + E.1 + G.1 + I.1 + K.1 closure verdicts
- `swift test --package-path phase3-binary` run
- Verdict line states READY TO PROCEED TO STEP 10 or
  NARROW V3 REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~15-25 min.
- The `writeBackupExclusively` (G.1 fix) is the highest-risk
  new surface — POSIX `open(O_EXCL)` + manual `write(2)` loop
  needs scrutiny.
- The Optional `recipeHash` (B.1 fix) ripples through three
  surfaces (struct, JSON encoder, test); a tautological
  closure here would be silent.
- If verdict is READY TO PROCEED TO STEP 10: Claude commits and
  fires Step 10 (failure modes + signal handling +
  AutotuneCommand.run() wiring + tune_runs persistence +
  size-ordered candidatesBySize for Stage 1).
- If verdict is NARROW V3 REQUIRED: tiny fix-pass + round-3.
