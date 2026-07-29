# SPEC-038 scaffold BUILD audit — CODE lane

First read the shared context file in this same directory:
`AUDIT_SPEC_038_SCAFFOLD_COMMON.md`. It defines the worktree, the diff range to
audit, what the scaffold intentionally is, and what NOT to flag.

You are the code-quality/correctness lane. Weight your review toward ordinary
software-engineering defects in the diff, each anchored to a line:

1. **Correctness of the policy logic.** `ContinuousBatchingPolicy.capability`,
   `queueLimit`, `defaultQueueLimit`, `validateStrictStartup`,
   `strictMessage`, `logSerialRouteIfNeeded`: off-by-one, wrong precedence,
   wrong default (`2 * maxActiveRows`), `max(1, …)` clamping, mode/reason
   mismatch. Verify the `guard`/`if` branch logic returns exactly the intended
   outcome for every (mode, draft, kv_bits, revision) tuple.

2. **Config plumbing correctness.** The new `assign` overloads for
   `ContinuousBatchingMode` from YAML dict (bool→on/off coercion, NSNull skip,
   lowercase parse) and from env; CLI→env→YAML precedence in `ConfigLoader`;
   the CLI `--continuous-batching` invalid-value throw; the `CLIOverrides`
   round-trip. Look for a source (YAML/env/CLI) that silently ignores the knob,
   a case-sensitivity bug, or a precedence inversion. Confirm the YAML bool
   coercion is intended and cannot mis-parse a string like "on"/"off".

3. **Error handling.** Every throw path (`ConfigError.invalidValue`, `APIError`,
   `ExitCode(2)`, `MSBAggregateThroughputError`) surfaces an actionable message;
   no swallowed error; the `do/catch let error as APIError` in
   `runContinuousBatchingPreflight` cannot leak a non-APIError or crash.

4. **MSB helper.** `msbAggregateThroughput`: seeding `start`/`end` from
   `samples[0]` then min/max over all — correct? Empty-guard first. The
   per-sample guard (`decodedTokens >= 0`, `decodeEndedAt > decodeStartedAt`)
   and the final `commonWallSeconds > 0` guard: any reachable division-by-zero,
   negative, or silently-wrong aggregate? Are `Date` min/max and
   `timeIntervalSince` used correctly?

5. **Test adequacy & quality.** Do the new tests in `ScaffoldTests.swift` and
   `ServingKnobsConfigTests.swift` actually assert the behavior (not just
   no-throw)? Any missing case: strict `on` unpinned throwing the right
   `code`/status, canary emitting the telemetry line, invalid-mode rejection at
   each source, queue-limit `< 1` at each source, MSB invalid samples. Flag weak
   assertions or untested branches (e.g. the `off`-mode inert path, the env-only
   `assign` overload, `strictMessage` text).

6. **General hygiene.** Dead code, unreachable branches, misleading names,
   `Sendable`/actor-isolation mistakes introduced by THIS diff (not pre-existing
   warnings elsewhere), resource/handle misuse in the `FileHandle.standardError`
   writes.

Report per the severity bar in the shared context. Anchor every finding to a
diff line. State explicitly if a weighting question above is clean.
