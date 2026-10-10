# Round 2 findings (2026-10-10)

Diff: `git diff origin/main...5df809e5d` (4 commits, round-1 fixes folded in). Raw lane output follows, unedited.

## CODE

```text
- **LOW — Carried from round 1: terminal checkpoint retirement lacks real-backend retention coverage.** [HybridDecodeWindowExactnessTests.swift:218](phase3-binary/Tests/macprovider-cliTests/HybridDecodeWindowExactnessTests.swift:218). The keyed test verifies serial materialization after a mid-window model stop, without the contiguous retention bridge. A regression in retirement after `commitTerminalKV` could therefore suppress conversation-cache retention on length completion or a request stop at the final window step while these tests pass. **Fix:** add real-backend contiguous-retention tests for both boundaries, comparing retained recurrent states against window 1.

Round 1 fixes verified: qualification requires ≥16 rows, ≥2 runs, the serve window, and ≥2 complete windows; retained end-state arrays prevent ObjectIdentifier reuse. No new correctness defect found in stop matching, covered-count arithmetic, checkpoint capture, cancellation, native-MTP capture, compilation exclusion, or probe indexing. Existing mid-window state assertions would detect removed or shifted checkpoints.

Complete four-commit diff and touched code reviewed. `git diff --check` and script shell syntax passed. No edits, builds, runtime tests, or remote access performed. Gate passes with the carried LOW coverage gap.

C/H/M/L = 0/0/0/1
```

## SECURITY

```text
No security findings in the complete four-commit diff and touched code. Gate passes.

Round-one fixes verified: proof prerequisites enforce 16+ rows, repeated references, and two complete serve windows; retained window-end arrays prevent ObjectIdentifier reuse. No new security defect found in row isolation, checkpoint labeling/publication, probe gating, lab override exclusion, or resource bounds.

Validation passed: lab-flag guard tests (3), shell syntax, and diff whitespace checks. No edits, builds, or remote contact. Metal-dependent behavior reviewed statically; the carried real-backend checkpoint-retirement coverage gap remains.

C/H/M/L = 0/0/0/0
```

## ARCHITECTURE

```text
Architecture gate passes: no CRITICAL, HIGH, or MEDIUM findings.

- **LOW — Carried from round 1:** `phase3-binary/Tests/macprovider-cliTests/HybridDecodeWindowExactnessTests.swift:218`. The keyed test covers serial materialization, without the contiguous retention bridge. A regression in retirement after `commitTerminalKV` could silently lose retained conversation caches for length completion or request-stop at the final window step while this test passes. **Fix:** add real-backend contiguous-retention tests for both boundaries, comparing checkpoints with window 1.

- **INFO — Introduced maintenance coupling:** `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift:2037` duplicates the scheduler’s suffix-stop predicate at `ContinuousBatchScheduler.swift:5901`. They agree today, including overlapping sequences: the backend needs only whether a match exists. A future scheduler-only stop-rule change could terminate at a boundary the backend did not checkpoint. **Fix:** share a matching-length helper or add equivalence coverage across both implementations.

- **INFO — Future recurrent-family constraint:** `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift:1572`. Retirement assumes forwards replace recurrent `MLXArray` objects. Strong retention fixes round 1’s address-reuse defect, and current writeback replaces arrays. A future in-place recurrent update could preserve identity and return an obsolete checkpoint. **Fix:** document replacement as a backend invariant; use explicit state generations before supporting in-place mutation.

Round-1 fixes verified: `MSBThroughputCommand.swift:1893` rejects undersized proofs and requires two complete serve windows plus repeated references; `PagedKVRuntimeBridge.swift:610` strongly retains the identity-bearing arrays.

Serve scheduling, injected paged backends, hybrid probes, and qualification use the same window selector. SPEC-038’s first-step/rejoin isolation rule and per-step reference checks match the implementation. Tiny-model tests establish unit coverage; the mandated served-artifact/hardware proof remains a separate pending release gate.

Reviewed the complete four-commit diff and touched code. Diff whitespace and shell syntax checks passed. No edits, builds, runtime tests, or remote contact.

C/H/M/L = 0/0/0/1
```

## Verdict

Gate met: 0 CRITICAL / 0 HIGH / 0 MEDIUM in all three lanes.

Carried:
- LOW (code, architecture): no real-backend contiguous-retention test of
  checkpoint retirement after `commitTerminalKV` (length completion, request
  stop at the final window step).
- INFO (architecture): `endsWithStopSequence` mirrors the scheduler's suffix
  stop rule; they agree today, including overlapping sequences.
- INFO (architecture): retirement relies on forwards replacing recurrent
  `MLXArray` objects; an in-place recurrent update would need explicit state
  generations.
