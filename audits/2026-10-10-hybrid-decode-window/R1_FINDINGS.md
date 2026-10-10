# Round 1 findings (2026-10-10)

Diff: `git diff origin/main...f5bce5517` (4 commits). Raw lane output follows, unedited.

## CODE

```text
- **MEDIUM — Introduced: proof can PASS without exercising or repeating the claimed window.** [MSBThroughputCommand.swift:1889](phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1889), [pass condition:1940](phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1940). With `--decode-window 16 --decode-tokens 1 --runs 1`, both arms actually execute one step, and `referenceRepeatsExactly` remains true without a repeat. A backend broken on steps 2–16 can therefore produce a successful hybrid-window proof. Smaller row counts also PASS despite SPEC-038 requiring at least 16. **Fix:** require at least two runs, at least one complete production window, and at least 16 rows for qualification PASS; distinguish reduced diagnostic comparisons from release proof.

- **LOW — Introduced coverage gap: checkpoint retirement is untested.** [HybridDecodeWindowExactnessTests.swift:218](phase3-binary/Tests/macprovider-cliTests/HybridDecodeWindowExactnessTests.swift:218). The keyed test exercises serial materialization after a model stop, without the contiguous retention bridge. It does not exercise `commitTerminalKV` replacing recurrent arrays after the last window. A regression removing the identity-based retirement check could deny the fresh terminal snapshot for length completion or a request stop at the final step, silently losing conversation-cache retention while these tests pass. **Fix:** add real-backend retention tests for those boundaries, comparing the resulting recurrent checkpoint against window 1.

No additional correctness defect found in stop matching, covered-count arithmetic, cancellation handling, native-MTP column capture, hybrid compilation exclusion, or probe indexing. The existing state comparisons would detect removed or shifted mid-window checkpoints.

Read-only review completed over all four commits and touched code. `git diff --check` passed; no builds, tests, edits, or remote access performed. Gate fails on the MEDIUM finding.

C/H/M/L = 0/0/1/1
```

## SECURITY

```text
No security findings in the complete four-commit diff and touched code. Reviewed row isolation, checkpoint labeling and retirement, cache publication/resume, fail-closed probe gating, release exclusion of the lab override, and bounded stop/checkpoint resource use.

Local validation passed: lab-flag guard tests (3), shell syntax, and diff whitespace checks. No files edited, builds run, or remote hosts contacted. Metal-dependent runtime behavior was reviewed statically, not re-executed.

C/H/M/L = 0/0/0/0
```

## ARCHITECTURE

```text
- **MEDIUM — `phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:1889,1940` — PASS does not establish the mandated release proof.** With `--rows 1 --runs 1 --decode-tokens 1 --decode-window 16`, both arms execute a single one-step call, reference repeatability remains vacuously true, and matching tokens yield PASS. The default two-row invocation also falls below SPEC-038’s 16-row requirement. **Fix:** require at least 16 rows, two reference runs, the production window from `servePathDecodeLockstepWindow`, and enough decode tokens to exercise that window before declaring release-proof PASS. Separate exploratory exactness results from release qualification.

- **LOW — `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift:609,1569` — Object identity is not a durable state-generation token.** The record retains identifiers without retaining their arrays. After a later forward replaces and releases those arrays, address reuse can make new arrays compare equal to the old identifiers. The snapshot path can then select an obsolete checkpoint or reject a valid new boundary. In-place state updates would likewise evade retirement, constraining future recurrent implementations. **Fix:** explicitly retire the record on committed state mutation, using a row generation counter across ordinary decode, terminal commit, prefill, restore, and native-MTP finalization; test those transitions.

Read-only inspection and `git diff --check` completed; no builds or remote contact. Architecture gate fails on the MEDIUM finding.

C/H/M/L = 0/0/1/1
```

## Disposition

- CODE MEDIUM and ARCHITECTURE MEDIUM (same defect: the hybrid-window proof
  could PASS without 16 rows, a repeated reference, or a full serve window):
  fixed. `runHybridWindow` now refuses to run unless rows >= 16, runs >= 2,
  `--decode-window` equals `ModelRuntime.servePathDecodeLockstepWindow`, and
  `--decode-tokens` >= 2 x window (`MSBThroughputCommand.swift`).
- ARCHITECTURE LOW (ObjectIdentifier of freed arrays can be reused): fixed.
  `RecurrentWindowRecord` holds the window-end state arrays strongly, so a
  replacement array cannot take their identity (`PagedKVRuntimeBridge.swift`).
- CODE LOW (checkpoint retirement after `commitTerminalKV` is not covered by a
  real-backend retention test): carried. The retirement path is exercised by
  the keyed model-stop test only through serial materialization; a
  contiguous-retention test is follow-up coverage, not a defect.
