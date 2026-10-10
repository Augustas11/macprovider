# Round 3 findings (2026-10-10, rebased onto #1947)

Diff: `git diff origin/main...458d7beba`. Raw lane output follows, unedited.

## CODE

```text
CODE gate passes: no CRITICAL, HIGH, or MEDIUM findings.

- **LOW — Carried coverage gap introduced by this diff:** [HybridDecodeWindowExactnessTests.swift:182](phase3-binary/Tests/macprovider-cliTests/HybridDecodeWindowExactnessTests.swift:182). The keyed test covers mid-window model-stop serial materialization without a contiguous retention bridge. A regression in checkpoint retirement after `commitTerminalKV` could silently suppress retained conversation-cache publication on length completion or a request stop at the final window step while these tests pass. **Fix:** add real-backend contiguous-retention tests for both boundaries, comparing retained recurrent states against window 1.

- **INFO — Introduced version-reference drift:** [CONFORMANCE.json:4799](specs/CONFORMANCE.json:4799) attributes hybrid window/checkpoint behavior to v0.3.11, although this change introduces it in v0.3.16. A conformance reader would trace the requirement to the wrong revision. **Fix:** change that reference to v0.3.16.

Stop matching, covered-count arithmetic, final-step handling, cancellation, native-MTP capture, compilation exclusion, probe indexing, and proof prerequisites show no additional correctness defect. Existing mid-window state comparisons would fail if checkpoints were removed or shifted.

The #1947 self-check uses the serve scheduler and its hybrid 16-step cap. Cached/provisional grants still require successful load-time attachment; updated isolation and parity probes prevent a hybrid from bypassing serve-window validation. The served-artifact proof remains a separate mandatory release prerequisite. SPEC v0.3.16 otherwise preserves v0.3.15’s default-on and revocation semantics.

Complete five-commit diff reviewed. Whitespace and shell-syntax checks passed. No edits, builds, runtime tests, or remote contact performed.

C/H/M/L = 0/0/0/1
```

## SECURITY

```text
No security findings in the complete five-commit diff and touched code. Security gate passes.

- Hybrid startup isolation decodes a full serve window, checks every step against its row’s serial reference, and requires distinguishing first-step and rejoin challenges. Probe failures prevent scheduler attachment; cached or provisional self-check grants cannot bypass this gate.
- New FR-CB10 self-check runs use the serve-path scheduler with a 48-token budget, exercising hybrid windows. Cached decisions may be reused, but startup window proofs still run.
- Stop-boundary checkpoints remain row-local and bounded to two per window. Unrecorded boundaries fail closed; strongly retained end-state arrays prevent identity reuse.
- Stop matching is bounded by admission limits of 16 sequences × 64 tokens. The environment override remains inside `#if MACPROVIDER_LAB_HARNESS`.
- SPEC-038 v0.3.16 preserves v0.3.15’s default-on, self-check, and revocation rules while adding hybrid-window requirements.

Validation passed: three lab-flag guard tests, script syntax, and diff whitespace checks. No edits, builds, or remote contact. Metal behavior was reviewed statically.

C/H/M/L = 0/0/0/0
```

## ARCHITECTURE

```text
Architecture gate fails on one MEDIUM finding.

- **MEDIUM — Pre-existing qualification-key omission exposed by this change.** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5142`; `ContinuousBatchingSelfCheck.swift:52,611`. A Mac with a stored hybrid W=1 grant can upgrade to W=16 without changing its model, metallib, kernel, OS or MLX pins. The key remains identical, so the stored decision is applied and the per-width self-check need not run again. Buyers can therefore use widths qualified only at W=1; the updated two-row startup probes do not establish isolation at every granted width. **Fix:** include the effective window and a scheduler/backend qualification revision in the key. Treat old grants as pending rechecks under v0.3.15’s continuation rules, and test this upgrade transition.

- **LOW — Carried coverage gap.** `phase3-binary/Tests/macprovider-cliTests/HybridDecodeWindowExactnessTests.swift:218`. The keyed test exercises serial materialization without the contiguous retention bridge. A retirement regression after `commitTerminalKV` could suppress conversation-cache retention on length completion or request-stop at the final window step while this test passes. **Fix:** add real-backend retention tests for both boundaries, comparing recurrent checkpoints against W=1.

- **INFO — Duplicated stop semantics.** `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift:2037`; `ContinuousBatchScheduler.swift:5942`. Both predicates agree today. A future scheduler-only change could terminate at a boundary the backend never checkpoints. **Fix:** share the matching-length helper or test equivalence between both implementations.

- **INFO — State replacement is an implicit lifetime invariant.** `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift:1572`. Strongly retained arrays prevent identity reuse, and current recurrent writeback replaces arrays. A future recurrent family or native-MTP path that mutates arrays in place could preserve identity and select an obsolete checkpoint. **Fix:** document replacement as mandatory, or introduce explicit state generations before supporting in-place updates.

Fresh FR-CB10 runs exercise the serve scheduler’s hybrid window. Serve scheduling, injected paged backends, startup probes and qualification share the window selector. The v0.3.16 first-step/rejoin challenge and per-step conformance requirements match the code. Its served-artifact/hardware W=16-versus-W=1 release proof remains distinct from tiny-model tests and FR-CB10; default-on activation does not replace that requirement.

Reviewed the complete five-commit diff and relevant surrounding code. Whitespace and shell syntax checks passed. No edits, builds, runtime tests or remote access performed.

C/H/M/L = 0/0/1/1
```

## Disposition

- ARCHITECTURE MEDIUM (self-check key omits the decode window, so a stored
  hybrid grant measured at window 1 would be reused at window 16): fixed in
  `aa1e5435b` ("Key the continuous-batching self-check on the decode
  window") and SPEC-038 v0.3.16 FR-CB10 item 2. Closure verification of this
  fix (build, XCTest, one lane check) is pending: the Studio is frozen for the
  1.8.238 canary.
- CODE INFO (CONFORMANCE rationale cited v0.3.11): fixed.
- LOW (carried): no real-backend retention test of checkpoint retirement after
  `commitTerminalKV`.
