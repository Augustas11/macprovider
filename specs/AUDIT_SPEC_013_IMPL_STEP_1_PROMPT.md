# Implementation audit prompt — SPEC-013 Step 1 (autotune subcommand scaffolding)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / Swift-idiom review** of the Step 1 commit that
landed the `autotune` subcommand scaffolding on branch
`feat/cli-autotune-impl`.

Step 1 carries:

| Commit | Step | Scope |
|---|---|---|
| facbaef | 1 | `AutotuneCommand` parser scaffold + flag set + `--dry-run` + candidate-plan derivation + validation + tests |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line. Codex (the implementer) raised zero Open Questions.
The operator wants an independent adversarial pass BEFORE Step 2
(`--no-join` on `ServeCommand`) begins, so any contract or quality
defect in the Step 1 foundation is caught before later steps build
on it.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-25 min
(narrow scope — single Swift file + tests + one CLI registration
line). This is a **read-only review** — Codex MUST NOT modify any
file. Do not commit, do not push, do not create branches.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step 1
commit (facbaef) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked out
at `/Users/augstar/macprovider-poc`. Steps 2-11 of the build sequence
have NOT landed yet — your scope is exclusively the Step 1 commit and
its anti-regression impact on the existing `phase3-binary/`.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state in any way. Your only output is the
structured findings report at the end.

## Context

Step 1 of `specs/BUILD_SPEC_013_PROMPT.md` calls for adding an
`AutotuneCommand: ParsableCommand` Swift-Argument-Parser subcommand
to the existing `macprovider-cli` binary. The deliverable was:
"`macprovider-cli autotune --help` prints the full flag set;
`macprovider-cli autotune --dry-run` prints the default candidate
list and exits 0."

SPEC-013 v0.3 is LOCKED (3 codex audit rounds converged; see
specs/SPEC-013-audit.md). The implementing PR (Option A, Swift-
native) is downstream of the SPEC PR (#108) and stacked on branch
`spec/cli-autotune-v1`.

The locked product framing: **biggest-fit, not max-tps**. Stage 1
of autotune iterates a curated largest-first candidate list and
STOPS on the first feasible model. Stage 2 hill-climbs knobs WITHIN
the chosen model. Step 1 implements only the CLI parser + dry-run
candidate-plan derivation; the runtime tuning logic is Step 6+ work.

The repo's binary is Swift; the local style guide is the existing
sources under `phase3-binary/Sources/macprovider-cli/` —
particularly `MacProviderCLI.swift`, `SelfUpdate.swift`,
`UninstallCommand.swift`, and `ModelsSubcommand.swift`. Match
their idioms.

## Required reading (in this order)

1. The Step 1 commit via `git show facbaef`. The commit message
   contains the testing claims and rationale.

2. The locked SPEC (READ-ONLY, do not edit):
   - `specs/SPEC-013-cli-autotune.md` v0.3 — focus on:
     - §5.1 FR-A.1 ("Candidate list is ordered, largest-first")
       — Step 1 must honor operator-supplied order verbatim at
       the parser level.
     - §5.2 FR-B.1 ("Knob search space") — Step 1 implements the
       `--kv-bits-axis`, `--max-batch-axis`, `--max-context-axis`
       parse rules. Note especially the v0.3 round-2 Z-B.1 closure:
       `--max-context-axis` MUST reject below-target cells at
       flag-parse time, sort ascending, reject duplicates, empty
       = single cell at `--target-context`.
     - §5.3 FR-C.1 (default candidate list — 5 entries
       largest-first) and FR-C.2 (operator override + size flags
       + warning).
     - §7 CLI surface summary (23 flags, defaults, `unset` kv-bits
       representation table). Note §7 is REFERENCE-ONLY; §5 wins
       on any conflict per the round-2 Z-B.1 closure.

3. The BUILD prompt that produced the code:
   - `specs/BUILD_SPEC_013_PROMPT.md` Step 1 — the binding step
     contract.

4. The Step 1 code under audit:
   - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
     (291 lines, NEW)
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     (1-line diff registering the subcommand)
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift`
     (61 lines, NEW)
   - `phase3-binary/implementation-notes.html` (21-line SPEC-013
     Step 1 section appended)

5. Local style guide (the patterns the audit verifies the
   implementation MATCHES):
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     — the top-level CLI registration pattern, ArgumentParser
     idioms, the existing flag-name conventions.
   - `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` and
     `UninstallCommand.swift` — error handling, `FileHandle.standardError`
     usage, `ExitCode` patterns.
   - `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift`
     — a sibling subcommand's structure, flag naming, validation.

You do NOT need to re-read SPEC-001, SPEC-002, SPEC-003, etc. — the
audit scope is Step 1 only.

## Severity definitions

- **CRITICAL** — silent contract violation of an FR Step 1 was
  supposed to cover (e.g. `--max-context-axis` parser does NOT
  reject below-target cells, breaking the v0.3 Z-B.1 closure);
  anti-regression broke an existing passing test; introduces a
  security hole (command injection, path traversal in
  `--db-path`, etc.); paints Step 2+ into a corner from which it
  cannot satisfy a later FR.

- **MAJOR** — Step 1 contract gap (an FR the build prompt assigned
  to Step 1 that the commit does NOT cover); Swift-idiom mismatch
  that would fail code review (e.g. force-unwraps, missing
  `[weak self]`, blocking calls on the main thread, etc., where
  applicable); test gap that lets a silent regression land
  (e.g. no test for `--max-context-axis` empty case = single
  cell); validation error messages that don't match user
  expectation; mishandled cases that an operator will hit on day
  one.

- **MINOR** — quality issues that don't block the next step. Naming
  inconsistencies, missing doc comments where the rest of the file
  has them, edge cases that won't fire frequently, prose drift in
  help strings.

- **QUESTION** — design choices Step 1 made where the spec was
  silent and the operator may prefer a different default. Flag as
  QUESTION only if there's a real ambiguity, not just stylistic
  preference.

## Critical constraints

1. **SPEC-013 v0.3 is LOCKED.** Findings that recommend SPEC edits
   are out of scope. If Step 1 contradicts the SPEC, the SPEC is
   right; file as MAJOR / CRITICAL accordingly.

2. **Biggest-fit, not max-tps.** Step 1 implements parser-level
   only; the runtime guard for FR-A.1 (operator-supplied order
   honored verbatim) is Step 7's AC-17. But Step 1 MUST NOT
   introduce a parser-level re-rank that Step 7 would have to
   undo. If the candidate plan is internally re-sorted at parse
   time = CRITICAL.

3. **Anti-regression discipline.** The existing
   `phase3-binary/Tests/macprovider-cliTests/` suite was passing
   before Step 1. Run `swift test --package-path phase3-binary` to
   verify all tests still pass. Any new failure = CRITICAL
   anti-regression.

4. **Strict clean-room on d-inference** (DARKBLOOM LICENSE
   AGREEMENT). Do NOT inspect d-inference source. SPEC-013 is
   not attestation-adjacent so this is unlikely to come up.

5. **Read-only.** Do not modify any file; do not commit; do not
   create branches.

## Audit categories — work through each

### Category A: SPEC-013 FR coverage for Step 1 scope

A.1  §7 CLI flag set: does `AutotuneCommand.swift` declare every
     flag named in SPEC-013 §7 with the documented default value?
     Walk each of the 23 flags. A flag missing entirely = MAJOR;
     a default value that disagrees with §7 = MAJOR;
     `--restart-foreground` and `--drain-grace` are newly added in
     v0.3 — verify both are present.

A.2  FR-A.1 operator-supplied order: `candidatePlan()` returns
     `AutotunePlan.explicit` for `--candidate-models`. Verify the
     order is preserved verbatim (no internal sort, no dedup, no
     case-fold). The test `testExplicitCandidateOrderBeatsSizeFlags`
     covers the basic case; verify it actually proves order
     preservation by inspecting `parseCSV`. If `parseCSV` collapses
     whitespace or strips a token that the operator intended = MAJOR.

A.3  FR-B.1 `--kv-bits-axis` parse rules: defaults to
     `'unset,4,8'`, accepts `unset` token, accepts `{4, 8}`,
     rejects everything else with a clear error. Cross-check
     `parseKvBitsAxis` against §7 representation table (terminal
     display `unset`, JSON `null`, SQL `NULL`, YAML omitted,
     serve_command flag omitted).

A.4  FR-B.1 `--max-context-axis` v0.3 Z-B.1 parse rules
     (NORMATIVE): absolute positive integers, sorted ascending
     after parse, each cell ≥ `--target-context`, duplicate
     rejection, empty = `[--target-context]`, all violations
     fail at flag-parse time with `config_error`. Walk
     `parseMaxContextAxis` line by line. If sort is not applied,
     if duplicates are not rejected, if empty case is wrong, if
     below-target case is allowed, or if errors fire at runtime
     rather than parse-time = MAJOR per gap.

A.5  FR-C.1 default candidate list: 5 entries in the exact order
     32B → 14B → 7B → 3B → 1B with the exact HuggingFace IDs from
     SPEC-013 §5.3. Walk `defaultCandidates`. A typo'd HF ID, a
     wrong order, or a missing entry = MAJOR.

A.6  FR-C.2 operator override + size flags + warning: with both
     `--candidate-models X` and `--max-model-size Y`, the explicit
     list MUST win and the size flag MUST be ignored WITH a stderr
     warning. Cross-check the `testExplicitCandidateOrderBeatsSizeFlags`
     test. If the warning emits to stdout instead of stderr, the
     `tee` workflow breaks = MINOR (or MAJOR if it would mislead
     `--json` ingestion).

A.7  Validation precision: `validateBasicInputs` rejects every
     out-of-range numeric input (`--target-context <= 0`,
     `--port` out of `1..65535`, `--retain-runs < 1`, etc.).
     Walk each guard. A missing guard = MAJOR; a misplaced bound
     (e.g. `--target-context > 0` is too loose — should be a
     minimum like 256 for any realistic prompt) = QUESTION.

A.8  Step 1 boundary: the BUILD prompt said Step 1 deliverable is
     "`autotune --help` prints flag set; `autotune --dry-run` prints
     candidate list and exits 0." Non-dry-run paths should exit
     with a clear "not implemented yet" error (FR forward-prom).
     Cross-check `run()` — does it correctly exit non-zero when
     called without `--dry-run`? An execution-path that silently
     does nothing or proceeds toward Step 2 work = CRITICAL.

### Category B: Code quality (Swift idioms vs local style guide)

B.1  Match against `SelfUpdate.swift` / `UninstallCommand.swift`
     patterns:
     - `FileHandle.standardError.write(Data((...).utf8))` is the
       local stderr pattern. Step 1 uses this — verify
       consistency.
     - `ExitCode(N)` for non-zero exits. Step 1 uses `ExitCode(2)`
       for "not implemented yet" — is `2` the convention for
       "stub not implemented"? Cross-check existing sites.
     - Static helpers vs instance methods: the local style is
       `static func` for parse helpers. Step 1 follows this.
       Verify no instance methods that should be static.

B.2  Error handling: `validate()` is called BOTH by ArgumentParser
     (via the `mutating func validate()` protocol) AND manually
     at the top of `run()`. Is the double-call intentional? If
     ArgumentParser already calls `validate()` before `run()`,
     the manual call in `run()` is redundant = MINOR. If
     `validate()` is NOT called by ArgumentParser in the current
     swift-argument-parser version pinned (1.5.0), the manual
     call is correct = no finding.

B.3  Number formatting: `var maxDuration = 7_200` uses Swift
     underscore separators — matches local style. `var
     gateTTFTMS = 60_000` same. Verify no overflow risks
     (`Int` is 64-bit on Apple Silicon; not an issue).

B.4  Force-unwraps: search for `!` outside type ascription. The
     code has none in this commit — verify by reading.

B.5  String parsing: `parseSizeB` accepts a trailing `b` /
     `B` suffix. Does it correctly handle `"7B"`, `"7b"`, `"7"`,
     `"32B"`, `"32.5B"`? `parseCSV` collapses on commas but
     does it survive `"a,,b"` (empty-cell case from a typo)? If
     `"a,,b"` parses as `["a", "b"]` silently, an operator typo
     becomes hidden = MINOR. If it throws clearly = no finding.

B.6  Empty-list edge cases: `parseCSV("   ,  , ")` — what does
     `candidatePlan` do? If the empty list reaches
     `AutotunePlan.explicit` with `[]` candidates, the operator
     gets a confusing "no candidates" error later. Verify the
     `parseCSV` empty path is guarded.

B.7  Help string quality: do the `@Option(help: ...)` strings
     match the help text style of the rest of the binary? Are
     they self-explanatory or do they require reading the SPEC?
     Hit-rate target: an operator running `autotune --help` for
     the first time should understand 80% of the flags without
     a SPEC read.

### Category C: Test coverage

C.1  Walk `AutotuneCommandTests.swift`. The 5 tests cover:
     - default candidate plan (FR-C.1)
     - explicit candidate order beats size flags (FR-C.2)
     - `--max-model-size` trims default list (FR-C.2)
     - `--max-context-axis` rejects below-target cell (FR-B.1
       Z-B.1)
     - `--kv-bits-axis` accepts `unset,4,8` (FR-B.1)

C.2  Coverage gaps for Step 1's scope:
     - Is there a test for `--max-context-axis` sorted ascending?
     - Is there a test for `--max-context-axis` duplicate
       rejection?
     - Is there a test for `--max-context-axis` empty case
       (= single cell)?
     - Is there a test for the `--restart-foreground` flag
       being parsed (Step 1 just wires it; later steps act on
       it)?
     - Is there a test for `--candidate-models` order
       preservation BEYOND `["one", "two"]` (e.g. a 5-element
       list with a SMALLER size SECOND, to catch the case
       where a future re-sort regression would silently reorder)?
     - Is there a test for `--dry-run` actually printing the
       candidate plan to stdout (the deliverable)?
     Each missing test for a Step 1 contract = MINOR; a missing
     test for FR-A.1 order-preservation = MAJOR.

C.3  Test naming + structure: do the tests follow the existing
     XCTest naming convention in the suite? Look at sibling
     test files for the pattern.

C.4  Anti-regression check: run `swift test --package-path
     phase3-binary` and verify ALL existing tests pass. A new
     test failure that's not from `AutotuneCommandTests` =
     CRITICAL anti-regression.

### Category D: Anti-regression on the existing CLI

D.1  Read the `MacProviderCLI.swift` diff: a single line
     registering `AutotuneCommand.self` in the subcommands list.
     Verify no other change. Any unintended change = MAJOR.

D.2  Does adding `autotune` to subcommands change the help
     output for other subcommands? E.g. shift in column
     alignment, surprise alphabetization? Run
     `macprovider-cli --help` mentally; if `autotune` appears
     at position N where N is non-default, flag if it would
     confuse documentation pinned to the prior help shape.

D.3  Does the new subcommand affect compile-time? Test compile
     time shouldn't regress noticeably; if Step 1 added a heavy
     import to a shared module = MINOR.

### Category E: Forward-compatibility (does Step 1 paint Step 2-11 into a corner?)

E.1  Provider-conflict pre-flight (Step 5, FR-E.1): the
     `--drain` flag is declared. Does Step 1 leave room for
     `--drain` to call out to launchd / SIGTERM logic in Step
     5? The flag is just a `@Flag(...)` boolean; no early
     binding. = no finding.

E.2  SQLite layer (Step 3, FR-G): `--db-path` defaults to
     `~/.config/macprovider/autotune.sqlite`. The default is
     computed at `static var defaultDBPath` evaluation time.
     What happens if `HOME` is unset? `FileManager.default.homeDirectoryForCurrentUser`
     on macOS returns the user's home reliably; on a misconfigured
     environment (e.g. CI without a home), this might fail. Step
     3 will catch this on DB open, so v0.1 is acceptable =
     QUESTION if the audit thinks it's load-bearing.

E.3  Pre-warm (Step 6, FR-D): `--candidate-models` reaches
     Stage 1's iteration. The parser's `candidatePlan()` is
     called by `--dry-run` only in Step 1; the runtime path in
     Step 7 will call the same function. Verify the function
     is reusable from Step 7 (it's a `func`, not nested under
     a `dryRun`-only branch). Step 1 placed it as an instance
     method on `AutotuneCommand`; that's correct.

E.4  Test infrastructure: future steps will need integration
     tests (real `serve` spawn, AC-6, AC-7). Step 1's test
     file is a vanilla XCTest unit-test file. Verify it doesn't
     accidentally pull in a heavy runtime dependency that would
     slow `swift test`. The file currently imports only
     `ArgumentParser`, `XCTest`, and the package — clean.

E.5  `AutotunePlan` and `AutotuneCandidate` are top-level types
     in `AutotuneCommand.swift`. Will Step 3+ need to put them
     in a separate `AutotuneTypes.swift` or `AutotuneCore`
     module? Step 1 inlined them, which is fine for a small
     scaffold. If Step 7's Stage 1 needs the same types from a
     different file, a moved type definition is a minor
     refactor cost = no finding.

### Category O: Anything else

Anything the operator should know about that doesn't fit A-E.
Examples:
- The implementation-notes.html SPEC-013 section is well-formed
  but does it follow the existing HTML structure (entry / time /
  meta classes)? Check the existing SPEC-008 section for
  comparison.
- Does the Step 1 commit message follow the project's commit
  style (visible in `git log --oneline -20`)?

## Output structure

Write findings to a NEW file:
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`.

This is the FIRST implementation audit for SPEC-013. Top-of-file
frontmatter:

```
# SPEC-013 implementation audit — Step 1

**Audited:** commit facbaef on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 1, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 1 readiness:** [READY TO PROCEED TO STEP 2 / FIX REQUIRED]

---

## Executive summary

[2-3 paragraphs. Was Step 1 implemented to the BUILD prompt's
contract? Are there blockers for Step 2? Be specific.]
```

Then for each category A-E + O, write a section. For each finding:

```
### A.4  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: AutotuneCommand.swift line N-M (or test file, or notes file)

[What the code does or fails to do. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences. Don't rewrite the code.]
```

If a category has zero findings, write `(no findings)` under the
category header — don't omit the section.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Modifying any file
- Re-litigating SPEC-013 v0.3 LOCK (closed; see specs/SPEC-013-audit.md)
- Auditing Steps 2-11 (they haven't been written yet)
- Re-litigating Option A vs Option B (decided in BUILD prompt)
- Re-litigating Shape A vs Shape B for FR-D (Step 6 territory)

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md exists
- Every category A-E + O has a section (even if "(no findings)")
- Every finding has severity, location, what / why / recommendation
- Executive summary states "READY TO PROCEED TO STEP 2" or "FIX
  REQUIRED" with specifics
- `swift test --package-path phase3-binary` was actually run and
  the result is reported in the executive summary

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 15-25 min (narrow scope — single Swift file
  + tests + one CLI registration line).
- Claude (the build orchestrator) closes findings on
  `feat/cli-autotune-impl`. Each fix is one commit with message
  `fix(autotune): close <audit-finding-id> — <short summary>`.
- After Claude addresses findings, a round-2 audit prompt
  (`AUDIT_SPEC_013_IMPL_STEP_1_R2_PROMPT.md`) verifies closure.
  Loop until 0 CRITICAL / 0 MAJOR.
- Only after the Step 1 loop converges does Step 2 (`--no-join`
  on `ServeCommand`) begin.
- The audit prompt + each round's report committed to `specs/`
  is the historical record (matches the SPEC-002 v1.3.5 IMPL
  pattern visible in `specs/AUDIT_SPEC_002_v1_3_5_IMPL_*`).
