# Retention lock descriptor ownership evidence

During read-only diagnosis of Swift26's intermittent unsafe-evidence failures, the lock initializer was observed to assign its sole stored descriptor property before the remaining checks. Its failed `flock` branch explicitly closed that descriptor and threw. Its deinitializer also unlocked and closed the stored descriptor.

An isolated local Swift reproduction established the language lifetime mechanism. It does not itself prove that every previous unsafe-evidence failure had this cause.

Exact command, run from the Build 1 worktree (no SwiftPM or package resolution):

```bash
swift -e 'enum Failure: Error { case failed }; final class Probe { let value: Int; init() throws { value = 7; print("initialized"); throw Failure.failed }; deinit { print("deinitialized") } }; do { _ = try Probe() } catch { print("caught") }'
```

Observed exit code: `0`. Exact output:

```text
initialized
deinitialized
caught
```

This demonstrates that throwing after all stored properties have been initialized invokes the class deinitializer. In the former lock constructor, the explicit close followed by deinitializer close therefore allowed the same numeric descriptor to be released twice. If another thread reused that descriptor between closes, the second close/unlock could affect unrelated evidence or locking. That concurrency consequence is an inference from the verified lifetime behavior and the observed constructor, to be checked by the CLI owner's deterministic descriptor-reuse regression.

The correction keeps the opened descriptor local until all validation and lock acquisition succeed, closes the local descriptor once on failure, and transfers it into the stored property only after success. Swift27's focused run was still active when this artifact was written. Neither this reproduction nor the earlier failed owner tests are represented as a passing owner integration result. The parent owns the Swift27 outcome and complete combined review.

Fresh coordinated follow-up: Swift27 completed with exit `0`, seven tests and zero failures in 39.591 seconds (`/tmp/build1-joint-swift27.log`, result reported by the root). The selection included the deterministic reused-descriptor regression, cancellation during authority fetch, and the measured owner integration scenarios. This supports the correction; it does not retroactively classify every earlier failure as the same defect.
