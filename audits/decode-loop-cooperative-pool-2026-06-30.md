# Decode Loop Cooperative-Pool Bounce — Hypothesis Test

**Date:** 2026-06-30
**Branch:** `hypothesis/decode-loop-gcd`
**Spec:** [specs/hypothesis-decode-loop-gcd.md](../specs/hypothesis-decode-loop-gcd.md)
**Reference fix:** Darkbloom / Layr-Labs/d-inference [PR #481](https://github.com/Layr-Labs/d-inference/pull/481) (v0.6.28)

## TL;DR

**Verdict: ABSENT.** Neither macprovider-poc's wrapper nor the upstream
`mlx-swift-examples` 2.29.1 generation primitive that we actually call
contains the Task/await/continuation/DispatchQueue bounce pattern.
No instrumentation run. No fix branch.

The Darkbloom bounce was introduced by their `Layr-Labs/mlx-swift-lm`
engine wrapper (a fork on top of mlx-swift-examples), then fixed in
that wrapper. We do not depend on that wrapper. We depend directly on
upstream `mlx-swift-examples` exact `2.29.1`, and we call the
**synchronous-callback** flavor of `generate(...)`, which iterates a
plain `Sequence`.

## Phase 1 — Structural Probe

### Hot-path entry points in our wrapper

Both call the same upstream sync-callback `generate(...)`:

- Streaming: [phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:715](../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift#L715)
- Non-streaming: [phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:593](../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift#L593)

The streaming call shape (excerpt):

```swift
// ModelRuntime.swift:715
let result: GenerateResult = try generate(
    input: lmInput, parameters: parameters, context: context
) { tokens in                                    // ← synchronous closure
    if Task.isCancelled || shouldCancel() || ... { return .stop }
    let decoded = context.tokenizer.decode(tokens: tokens)
    ...
    onChunk(.content(delta))                     // enqueue into ring buffer
    return .more
}
```

Closure body: no `await`, no `Task`, no continuation, no
`DispatchQueue.async`. It runs in-line on whatever thread upstream is
iterating the `TokenIterator` on.

### Pattern scan, our wrapper

| Pattern | In wrapper? |
|---------|-------------|
| A. `Task { while running { await ... } }` | ✗ not present |
| B. `withCheckedContinuation` + `DispatchQueue.async` + `continuation.resume()` | ✗ not present in hot path. Only use is `DrainCancelToken.waitUntilFired()` (ModelRuntime.swift:1568–1582), which is a one-shot cancellation gate, not per-token. |
| C. `for await token in stream { ... }` consumer bounce | ✗ not present per-token. InferenceRelay.swift:405–451 has a producer/consumer Task draining a ring buffer to the WS sender, but that hop is per-chunk-batch in transport, decoupled from generation. It is *not* in the per-token decode loop. |
| D. Per-step actor hop (`await someActor.method()` / `await MainActor.run`) | ✗ not present in the per-token callback |
| E. Upstream `mlx-swift-examples` | See below — also ✗ |

### Pattern scan, upstream `mlx-swift-examples` 2.29.1

Source: `phase3-binary/.build/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/Evaluate.swift`,
rev `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631` (per Package.resolved).

The synchronous-callback `generate(...)` we invoke
(`Evaluate.swift:577` → `Evaluate.swift:597`) is structurally:

```swift
// Evaluate.swift:597 — the body we actually run
public func generate(
    input: LMInput, context: ModelContext,
    iterator: TokenIterator,
    didGenerate: ([Int]) -> GenerateDisposition       // ← non-async
) -> GenerateResult {
    ...
    for token in iterator {                            // ← Sequence, not AsyncSequence
        ...
        if didGenerate(tokens) == .stop { break }
    }
    Stream().synchronize()                             // MLX stream barrier on exit
    return GenerateResult(...)
}
```

And `TokenIterator` itself:

```swift
// Evaluate.swift:266
public struct TokenIterator: Sequence, IteratorProtocol {
    ...
    // Evaluate.swift:423
    mutating public func next() -> Int? {              // ← synchronous
        ...
        let token = step(previous: previousY)
        y = .init(tokens: token)
        asyncEval(token)                               // MLX pipelining (see note)
        tokenCount += 1
        return previousY.tokens.item(Int.self)
    }
}
```

Findings:

- `TokenIterator` is a synchronous `Sequence` / `IteratorProtocol`, not
  an `AsyncSequence`. Iteration is a plain `for token in iterator` —
  no `await`, no Swift Concurrency involvement at all.
- `asyncEval(token)` is an **MLX** primitive (MLX framework's lazy/async
  graph evaluation that keeps the GPU pipeline full). It is not a
  Swift `Task`, not a continuation, and does not touch the Swift
  Concurrency cooperative pool.
- There are async wrappers in the same file (`AsyncStream`-based
  `generate(...) async -> AsyncStream<...>`) — we do not call them.
- The Darkbloom-style anti-pattern (`Task { while running { await
  withCheckedContinuation { engineQueue.async { ... }}}}`) is **not
  present** in upstream's sync-callback generate.

### Why Darkbloom had it and we don't

Darkbloom's d-inference fork is built on `Layr-Labs/mlx-swift-lm`, a
fork that added an engine layer around `mlx-swift-examples` to support
their multi-tenant scheduler. That engine layer wrapped GPU step calls
in `withCheckedContinuation` + `engineQueue.async` and drove iteration
from a `Task { while running { await engineLoop() } }`. PR #481 was
the fix for that wrapper.

macprovider-poc depends on upstream `ml-explore/mlx-swift-examples` at
exact `2.29.1` (see `phase3-binary/Package.resolved`), not on the
Layr-Labs fork, and it calls the sync-callback API directly. The
bounce was never added in our stack.

## Phase 2 — Impact Measurement

**Not run.** Phase 1 verdict is STRUCTURAL MISS, and the spec
explicitly says: *"If STRUCTURAL MISS: stop here. Write the report,
push the branch, recommend ABSENT. Don't invent measurements to
justify the test."*

## Phase 3 — A/B Fix

**Not implemented.** Phase 2 gate not met.

## Final Verdict

**ABSENT.**

There is no Darkbloom-shaped cooperative-pool bounce to fix. The
~2× decode TPS lift they reported is not available to us via this
mechanism. Decode-loop scheduling is not the bottleneck to attack.

## Two-sentence recommendation

Do not pursue a GCD self-rescheduling swap — the upstream sync-callback
`generate(...)` we already use has no Task/await/continuation bounce
to remove. The next decode-perf lever to evaluate is engine-side
optimization (`mx.compile`, bf16 KV cache, etc.) per
[specs/perf-mlx-compile-bf16-upgrade.md](../specs/perf-mlx-compile-bf16-upgrade.md),
not the per-token scheduler.

## Branch and commits

- Branch: `hypothesis/decode-loop-gcd`
- Commits: this report only (no instrumentation, no fix). Safe to leave
  unmerged or delete after review.

## Open watch item (low priority)

If we ever migrate to:

- the `AsyncStream`-based variants of `generate(...)` in
  `Evaluate.swift`, OR
- a custom engine wrapper around `TokenIterator` modeled on Darkbloom's
  for multi-tenant scheduling,

re-run this hypothesis test before shipping. Both shapes are where
Darkbloom's bounce was originally introduced.
