# Implementation audit prompt — SPEC-013 Step 6 round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-1 audit
closures landed in commit 682abe8 on branch
`feat/cli-autotune-impl`.

Round 1 (codex on e7bfab5) returned `1 CRITICAL / 1 MAJOR / 2
MINOR / 0 QUESTION`, verdict FIX REQUIRED. The CRITICAL was the
asymmetric FR-D.2 failure mode the audit prompt explicitly named:
the missing-tokenizer integrity marker did not match the actual
swift-transformers Hub error string, silently classifying a
SPEC-named integrity failure as transient.

Round 2 verifies the 4 closures (B.1 + B.2 + B.3 + E.1) and
spot-checks the new integrity-marker list for new false-positive
risk.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~12-18
min. This is a **read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 6 implementation audit on
branch `feat/cli-autotune-impl`.

Round 1 was you (Codex) on commit e7bfab5; the report is at
specs/SPEC-013-impl-audit.md § Round 9. Round 1 returned
1 CRITICAL (B.1) / 1 MAJOR (B.2) / 2 MINOR (B.3, E.1) /
0 QUESTION, verdict FIX REQUIRED. Commit 682abe8 is the
audit-response fix-pass; it claims to close all 4.

Round 2 has two questions:

1. Did 682abe8 actually close each of the 4 round-1 findings?
2. Did the fix-pass introduce any NEW contract precision gap?
   The expanded integrity-marker list (15 markers vs 8) is the
   highest-risk new surface: short markers like `"invalid header"`
   could match benign log lines. Check the false-positive risk.

This is a **read-only review**.

## Required reading (narrow)

1. The audit-response commit via `git show 682abe8`.

2. The round-1 report:
   `specs/SPEC-013-impl-audit.md` § Round 9.

3. The Step 6 source under audit (post-fix):
   - `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift`
     — expanded integrity-marker list.
   - `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift`
     — 4 new test methods.
   - `phase3-binary/implementation-notes.html` — Step 6
     audit-response entry.

4. Run `swift test --package-path phase3-binary` and report the
   result. Fix-pass claims 297 tests passing (293 baseline + 4
   new), 2 skipped integration-gated.

## Severity definitions (unchanged)

- **CRITICAL** — round-1 closure claim is COSMETIC and the
  failure mode still applies (e.g. the new tokenizer markers
  STILL don't match the real Hub error); fix-pass introduced
  a contract violation; anti-regression broke a test.
- **MAJOR** — closure is incomplete; fix-pass introduced a new
  precision gap (e.g. a new integrity marker has high false-
  positive risk on benign log lines).
- **MINOR** — quality issues.
- **QUESTION** — design choice.

## Critical constraints (unchanged)

1. SPEC-013 v0.3 is LOCKED.
2. Biggest-fit, not max-tps.
3. Anti-regression discipline — 297 tests must pass.
4. Strict clean-room on d-inference.
5. Read-only.
6. Integrity classification is asymmetric: integrity-as-transient
   = CRITICAL; transient-as-integrity = MAJOR.

## Round 2 audit categories

### Category Z-CLOSURE

- **B.1 (CRITICAL)** Tokenizer error mismatch → 682abe8 added
  3 new markers and 1 new test. Verify:
  - The new marker `"configuration file missing: tokenizer.json"`
    matches the lowercased actual Hub error string
    `"required configuration file missing: tokenizer.json"`.
  - The new test
    `testPreWarmerClassifiesConfigurationFileMissingTokenizerAsIntegrity`
    feeds the EXACT string from swift-transformers
    `.build/checkouts/swift-transformers/Sources/Hub/Hub.swift:69` /
    `:260` (or close enough that the substring match catches it).
  - The original marker `"missing tokenizer.json"` is kept as
    fallback.

- **B.2 (MAJOR)** Malformed safetensors → 682abe8 added 4 new
  markers. Verify:
  - `"invalid json header"` matches the lowercased mlx-swift
    error `"[load_safetensors] invalid json header length ..."`.
  - `"invalid json metadata"` matches
    `"[load_safetensors] invalid json metadata ..."`.
  - The new test
    `testPreWarmerClassifiesInvalidJsonHeaderAsIntegrity`
    uses the actual format `"[load_safetensors] Invalid json
    header length 0"`.
  - Confirm no clean-room violation: mlx-swift is MIT-licensed,
    not Darkbloom; reading its source is permitted.

- **B.3 (MINOR)** Mixed-case integrity not tested → 682abe8 added
  `testPreWarmerClassifiesMixedCaseIntegrityCorrectly` with
  `"SIGNATURE Mismatch on Model Weights"`. Verify the test
  exercises the case-insensitive `.lowercased()` matcher.

- **E.1 (MINOR)** `now` injection unused → 682abe8 added
  `testPreWarmerLoadDurationReflectsInjectedClock` with a
  deterministic 7-second clock advance. Verify:
  - The test injects a closure that advances by exactly 7s
    between the start and end calls.
  - The assertion is `loadDurationSec == 7.0` with accuracy
    0.001 (not just `>= 0`).
  - A regression that records the end time before
    `waitForReady` returns or always returns 0 would fail this
    test.

### Category R-REGRESSION-V06F1

- Run `swift test --package-path phase3-binary` and verify 297
  tests + 2 skipped, 0 failures.
- Confirm the original Step 6 happy-path / cold-cache / network-
  transient / signature-mismatch-integrity / timeout-transient
  tests still pass under the expanded marker list.
- Confirm no Step 4 / Step 5 test failures.

### Category N-NEWGAPS-V06F1

The expanded integrity-marker list has 15 patterns vs the
original 8. Spot-check each NEW marker for false-positive risk:

- `"configuration file missing: tokenizer.json"` — long + specific.
  Low FP risk.
- `"missing: tokenizer.json"` — narrower than the original; OK.
- `"missing required tokenizer files"` — long phrase. Low FP.
- `"invalid json header"` — moderate FP risk. Could match a
  log line like "no invalid json header detected" or a
  benign warning. Verify.
- `"invalid json metadata"` — moderate FP risk. Same shape.
- `"incomplete metadata"` — VAGUE. Could match benign log lines
  about HTTP responses or other JSON parsing in non-weight
  contexts. Audit's call: is this too broad?
- `"invalid or corrupted"` — VERY vague. Could match almost
  any error message. Audit's call: is this too broad?

For each, ask: would a benign log line plausibly contain this
substring? The asymmetric FR-D.2 risk model BIASES toward
integrity (transient-as-integrity is recoverable; integrity-as-
transient is silent failure), so a wider integrity net is
defensible. But a marker that fires on routine transient
errors would over-abort runs.

If you find a plausible benign log line that matches any new
marker = MAJOR finding (new precision gap from the fix-pass).
If a marker is broad but no concrete benign-line example
exists = MINOR.

### Category O-OTHER-V06F1

Use sparingly.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 10 audit (Codex on 682abe8 — Step 6 round 2 closure verification)

**Audited:** commit 682abe8 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 6, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 4 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 6 readiness:** [READY TO PROCEED TO STEP 7 / NARROW V2 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

For each of B.1, B.2, B.3, E.1: closure verdict + one paragraph
rationale.

### Round-2 new findings

Group by category Z / R / N / O. Empty: `(no findings)`.

### Step 6 readiness verdict

State READY TO PROCEED TO STEP 7 or NARROW V2 REQUIRED.
```

## Out of scope

- Re-litigating round-1 findings already closed
- Re-litigating Shape A vs Shape B (decided in BUILD prompt)
- Re-litigating the defer-stop architectural choice (G.2
  RESOLVED in round 1)
- Auditing Steps 7-11 (not yet started)
- Inspecting d-inference source

## Done criteria

- New `## Round 10 audit ...` section appended
- Earlier rounds (1-9) unchanged
- Each of 4 round-1 findings has closure verdict
- Each round-2 new finding (if any) has severity, location,
  what / why / recommendation
- `swift test --package-path phase3-binary` was run
- Verdict line states READY TO PROCEED TO STEP 7 or NARROW V2
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~12-18 min.
- If verdict is READY TO PROCEED TO STEP 7: Claude commits and
  fires Step 7 (Stage 1 iteration — the heaviest BUILD step).
- If verdict is NARROW V2 REQUIRED: fix-pass + round-3 prompt.
