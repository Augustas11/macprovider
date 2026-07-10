# perf/mlx-compile-bf16 — ARCHITECT-lane audit (round 1)

You are the **architect** lane of a three-lane audit. Stay narrowly in
your lane.

## Branch / commit
- Branch: `perf/mlx-compile-bf16`
- Worktree: `/Users/augstar/macprovider-perf-mlx` (rebased on origin/main HEAD = 1ba48fa)
- Spec: `specs/perf-mlx-compile-bf16-upgrade.md`
- Reference design: https://github.com/Layr-Labs/d-inference/pull/482

## Files in scope (`git diff origin/main`)
- New: `phase3-binary/Sources/macprovider-cli/{WeightCast,CompiledDecode,DecodeBenchCommand}.swift`
- Modified: `phase3-binary/Sources/macprovider-cli/{MacProviderCLI,ModelRuntime}.swift`
- Tests: `phase3-binary/Tests/macprovider-cliTests/WeightCastTests.swift`
- Audits (read-only): `audits/2026-06-30/{mlx-upgrade-report,perf-deferred,perf-mlx-engine}.md`

## What this change does
See `audits/2026-06-30/perf-mlx-engine.md` for the roll-up. Summary:
- Phase 1 (MLX upgrade): Path C (stay) on `mlx-swift-examples 2.29.1` after SwiftPM resolution rejected the override attempt.
- Phase 2 (bench harness): `decode-bench` subcommand shipped.
- Phase 3 (bf16 cast): shipped behind `MACPROVIDER_BF16_WEIGHTS=1`.
- Phase 4 (`compile()` decode wrapper): scaffolding shipped behind `MACPROVIDER_COMPILED_DECODE=1`; runtime wire-in deferred to follow-up PR (correctness gate needs live M-series).
- Phase 5: documented as deferred (model-family gated).

## Architect-lane scope

### ARCH-1. Phase 1 decision — Path C is the right call?
Re-derive the decision from first principles. `mlx-swift-examples` 2.29.1
is the latest tag. Its `Package.swift` pins mlx-swift via
`.upToNextMinor(from: "0.29.1")` = `[0.29.1, 0.30.0)`. Latest mlx-swift
is 0.31.4. The override attempt with `from: "0.31.0"` fails SwiftPM
intersection. Question:
- Are there any alternatives the report did NOT consider that stay
  within scope ("Do NOT switch dependency to `Layr-Labs/mlx-swift-lm`.
  Stay on `mlx-swift-examples`. Do NOT vendor MLX.")?
- Specifically: does a `branch:` / `revision:` override of `mlx-swift`
  inside the same `mlx-swift-examples` constraint count as "patching
  upstream"? Or as a clean override? The spec doesn't directly say.
  Recommend: accept Path C, or recommend a deferred-decision note?
- Is the follow-up trigger ("re-check when next `mlx-swift-examples`
  release drops") concrete enough, or should it be a tracking issue?

### ARCH-2. Phase 4 split — scaffolding now, wire-in later
The PR ships `CompiledDecode.swift` (the wrapper class) but does NOT
wire it into `ModelRuntime`'s decode loop. The justification given in
`perf-mlx-engine.md` is that the correctness gate (token-exact
equivalence vs uncompiled) requires live M-series execution that this
session cannot perform.

- Is shipping inert scaffolding the right call, or should the PR ALSO
  have shipped the wire-in (gated, defaults OFF) with the same
  correctness-gate caveat in the spec?
- The `CompiledDecodeStep` class as written is constructed per-request
  (the comment says "discard at end-of-request"). When the runtime
  follow-up wires this in, will the per-request compile-trace warmup
  cost negate the per-token decode win? The spec calls this out:
  "compile has a warmup cost on the first request — make sure to
  measure steady-state across at least 3 runs after warmup". Trace
  whether the per-request lifetime in this class will require
  amortization across many decoded tokens to break even, and recommend
  either accepting the per-request lifetime or proposing a session-
  scoped compile cache.
- The `KVCacheUpdatableAdapter` is a clean adapter pattern, but it
  hides the fact that `KVCacheSimple.update(...)` reallocates its
  backing buffer when full (step boundary at 256 tokens by default).
  When the backing array reallocates, the `MLXArray` references the
  cache holds change. The adapter's `innerState()` calls the cache's
  `innerState()` which returns the CURRENT references — so the
  adapter is consistent with the cache. BUT — does MLX's compile()
  re-trace when the inputs' array IDs change? If yes, the compile
  benefit will be lost every 256 tokens for long generations. Worth
  flagging this for the wire-in PR.

### ARCH-3. bf16 cast — default-OFF discipline
- The spec says "default OFF in this branch — flip default in a
  follow-up PR after live evidence." The implementation honors this:
  bf16 cast only runs when the env flag is set, and the runtime is
  unchanged otherwise. Confirm: no production semantics change in this
  PR when both flags are unset.
- The cast walks `Module.apply { ... }` with the default filter
  `filterValidParameters`. Architecturally, is there a risk that the
  cast could land on a quantization scale/bias array (which IS fp16)
  that the quantized linear layer expects to remain fp16? The default
  filter SHOULD exclude these, but the filter's contract is "valid
  parameters," not "non-quantization-metadata parameters." Worth
  digging into.
- The cast emits a one-line stderr diagnostic. Is stderr the right
  destination, or should it use the same logging facility as the rest
  of the runtime (`logger.notice(...)` patterns elsewhere in
  ModelRuntime.swift)?

### ARCH-4. `decode-bench` subcommand fit
- The bench is registered as a peer of `serve`, `self-test`, `status`,
  etc. in the CLI's subcommand list. Is this the right fit, given
  that bench is a developer / SRE tool rather than an operator
  workflow? Alternatives: hide behind a `--internal` flag, gate via
  `MACPROVIDER_DEV_TOOLS=1`, document as "operator-only" in the help
  text.
- The bench command duplicates some of `measureStartupThroughput`'s
  shape (line ~816 of ModelRuntime.swift). Is there an opportunity for
  shared infrastructure, or is the duplication intentional (bench
  measures decode TPS, the runtime helper measures startup throughput)?
- The JSON output schema (`BenchReport`) is versioned. Is there a
  precedent for versioned JSON outputs elsewhere in the repo? (If yes,
  align with it. If no, this PR is setting one.)

### ARCH-5. Audit documentation density
- Three audit notes (`mlx-upgrade-report`, `perf-deferred`,
  `perf-mlx-engine`) for one PR is heavier than the repo's average
  (typical SPEC-N audit folder has 1-2 notes). Is the density
  justified by Phase 5's three explicit deferral records, or is
  there over-documentation that should be consolidated?
- The audit notes contain forward-looking checklists (e.g. "live
  execution checklist" in `perf-mlx-engine.md`). Architecturally,
  should those checklists live in a tracking issue instead of the
  audit folder?

### ARCH-6. Forward compatibility
- When `mlx-swift-examples` cuts its next release (call it 2.30.0)
  and it pins `mlx-swift ≥ 0.30`, the Phase 1 decision should
  trigger a re-evaluation. Is there a concrete signal in this PR
  (a CI check, a markdown TODO, a tracking issue) that will trigger
  the re-evaluation, or is it manual operator vigilance?
- The hardcoded `"mlxsx-2.29.1"` pin tag in `DecodeBenchCommand.swift`
  is asserted by a test that just compares the constant. If the pin
  is bumped without bumping the tag, the test passes but the bench
  JSON misattributes. Trace: is the test pinning the value, or the
  source-of-truth alignment?

## Out of scope for THIS lane
- Code correctness: defer to code lane.
- Security implications: defer to security lane.

## Required output format

For each finding:
```
- id: ARCH-<n>
  severity: CRITICAL | HIGH | MEDIUM | LOW | NIT
  file: path/to/file.swift (or audit doc)
  lines: "L:M" or "L:M..L:N" (or "n/a" for doc-level)
  finding: <one paragraph>
  recommendation: <concrete fix or accept/reject>
```

End with: `# tally: critical=<n> high=<n> medium=<n> low=<n>`.
Bar: 0 CRITICAL/HIGH/MEDIUM.
