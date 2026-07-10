# Implementation audit prompt — SPEC-013 Step 6 round 3 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-2 N.1
closure landed in commit dcd7f63 on branch
`feat/cli-autotune-impl`.

Round 2 (codex on 682abe8) returned `0 CRITICAL anti-regression
/ 1 MAJOR new (N.1) / 0 MINOR new`, verdict NARROW V2 REQUIRED.
The MAJOR was: two unanchored integrity markers
(`"incomplete metadata"`, `"invalid or corrupted"`) could
over-classify benign transient lines from HF API metadata
hiccups or local cache rebuild prompts.

Round 3 verifies the single N.1 closure (markers removed +
negative-lock tests added) and confirms no new gap was
introduced.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~8-12
min (narrowest round so far — single MAJOR closure + 2 new
tests + production diff is 2 lines removed). **Read-only**.

---

```
=== BEGIN PROMPT ===

You are running round 3 of the Step 6 implementation audit on
branch `feat/cli-autotune-impl`.

Round 1 (codex on e7bfab5) returned 1 CRITICAL + 1 MAJOR + 2
MINOR. Round-1 fix-pass (682abe8) closed all 4. Round 2 (codex
on 682abe8) confirmed all 4 closed but found N.1 MAJOR — vague
markers introduced by the round-1 fix-pass could over-abort
benign transients.

Round-2 fix-pass (dcd7f63) is the audit-response: it removes
the two vague markers AND adds 2 negative-lock tests pinning
the benign-line behavior.

Round 3 has one question: did dcd7f63 close N.1 without
introducing new precision gaps?

This is a **read-only review**.

## Required reading (narrow)

1. The audit-response commit via `git show dcd7f63`.

2. The round-2 report:
   `specs/SPEC-013-impl-audit.md` § Round 10 (and § Round 9 for
   context).

3. The Step 6 source under audit (post-fix):
   - `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift`
     — final 13-marker integrity list.
   - `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift`
     — 2 new negative-lock test methods.
   - `phase3-binary/implementation-notes.html` — Step 6 round-2
     audit-response entry.

4. Run `swift test --package-path phase3-binary` and report the
   result. Fix-pass claims 299 tests (297 baseline + 2 new
   negative locks), 2 skipped integration-gated.

## Severity definitions (unchanged)

- **CRITICAL** — N.1 closure claim is COSMETIC and the
  false-positive failure mode still applies; OR the marker
  removal opened a NEW integrity gap (the SPEC-named integrity
  classes are no longer covered); OR anti-regression broke a
  test.
- **MAJOR** — closure is incomplete; new test passes by
  tautology; new precision gap.
- **MINOR** — quality issues.
- **QUESTION** — design choice.

## Critical constraints (unchanged)

1. SPEC-013 v0.3 is LOCKED.
2. Biggest-fit, not max-tps.
3. Anti-regression discipline — 299 tests must pass.
4. Strict clean-room on d-inference.
5. Read-only.
6. Integrity classification is asymmetric.

## Round 3 audit categories

### Category Z-CLOSURE

**N.1 (MAJOR)** Vague markers over-classify benign transients
→ dcd7f63 REMOVED `"incomplete metadata"` and
`"invalid or corrupted"` from the integrity list. Verify:

- The two markers are gone from the integrity-markers array.
- The 2 new tests
  (`testPreWarmerClassifiesIncompleteMetadataDownloadErrorAsTransient`
  and `testPreWarmerClassifiesCacheRebuildHintAsTransient`)
  feed the EXACT benign lines codex named in round 2 and
  assert `.transient`.
- These tests would FAIL if either marker is reintroduced.
- The 4 round-1 closure tests (tokenizer, invalid-json-header,
  mixed-case, deterministic-clock) STILL PASS under the
  narrower marker list. Run the test suite to confirm.

Also verify the SPEC-named integrity coverage didn't regress:
the 13 remaining markers MUST still cover:
- signature mismatch ✓
- weight hash mismatch ✓ (via "hash mismatch")
- missing tokenizer.json ✓ (4 markers)
- safetensors header/metadata corruption ✓ (2 markers)
- tampering signal ✓ (via signature/hash/checksum class)

### Category R-REGRESSION-V06F2

- Run `swift test --package-path phase3-binary` and verify
  299 tests + 2 skipped, 0 failures.
- The round-1 closure tests still pass.
- No Step 1-5 regressions.

### Category N-NEWGAPS-V06F2

The removal narrowed the integrity surface. Did any SPEC-named
integrity example LOSE coverage by the removal?

- SPEC-013 §5.4 FR-D.2 named examples:
  - "signature mismatch" — still covered ✓
  - "weight hash mismatch" — still covered via "hash mismatch" ✓
  - "repository contents inconsistent with expected shape (e.g.
    missing tokenizer.json)" — still covered by 4 tokenizer
    markers ✓
  - "any tampering signal" — partially covered by
    signature/hash/checksum class

Is there any concrete tampering signal (NOT signature/hash/
checksum/tokenizer/safetensors) that the removal would now
silently advance? Spot-check by looking for "incomplete" or
"corrupted" usage in mlx-swift or swift-transformers error
paths that the now-removed markers would have caught. If you
find a concrete mlx-swift integrity error that the narrower
list misses = MAJOR finding.

### Category O-OTHER-V06F2

Use sparingly.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 11 audit (Codex on dcd7f63 — Step 6 round 3 closure verification)

**Audited:** commit dcd7f63 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 6, round 3 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] for N.1
**Round-3 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 6 readiness:** [READY TO PROCEED TO STEP 7 / NARROW V3 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-2 finding closures

N.1 verdict + paragraph.

### Round-3 new findings

Group by category Z / R / N / O.

### Step 6 readiness verdict

State READY TO PROCEED TO STEP 7 or NARROW V3 REQUIRED.
```

## Out of scope

- Re-litigating closed findings (round-1 B.1/B.2/B.3/E.1)
- Re-litigating Shape A vs Shape B
- Re-litigating the defer-stop architectural choice
- Auditing Steps 7-11
- Inspecting d-inference source

## Done criteria

- New `## Round 11 audit ...` section appended
- Earlier rounds (1-10) unchanged
- N.1 has closure verdict
- Each round-3 new finding (if any) has severity, location,
  what / why / recommendation
- `swift test --package-path phase3-binary` was run
- Verdict line states READY TO PROCEED TO STEP 7 or NARROW V3
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~8-12 min.
- If verdict is READY TO PROCEED TO STEP 7: Claude commits and
  fires Step 7 (Stage 1 iteration).
- If verdict is NARROW V3 REQUIRED: another fix-pass + round-4.
