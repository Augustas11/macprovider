# SPEC-038 scaffold BUILD audit — SECURITY / CORRECTNESS lane

First read the shared context file in this same directory:
`AUDIT_SPEC_038_SCAFFOLD_COMMON.md`. It defines the worktree, the diff range to
audit, what the scaffold intentionally is, and what NOT to flag.

You are the security/correctness lane. This is a **money-path** repo. Weight your
review toward these questions, each tied to a concrete line of the diff:

1. **Flag-OFF must be truly inert.** When `continuous_batching` is `off` (the
   default), is the per-request serve path (preflight / non-streaming /
   streaming in `ModelRuntime.swift`) byte-for-byte identical to today? Verify
   `applyContinuousBatchingPolicy` performs NO side effect, NO stderr write, NO
   usage/receipt/billing/slots mutation when mode is `off`. Confirm it cannot
   throw in `off` mode. If off-mode adds any observable behavior, that is a
   FR-CB9 regression — flag it.

2. **Strict fail-closed guard cannot be bypassed.** In `on` mode with no pinned
   upstream revision (the only real state today), can any input make
   `validateStrictStartup` NOT throw, or make the serve path proceed as if
   batching were available? Check the reason-precedence ordering in
   `ContinuousBatchingPolicy.capability` (draft → kv_bits → unpinned) for a hole
   that yields `reason == nil` while `mode == .on`. Check startup preflight AND
   the per-request `applyContinuousBatchingPolicy` are consistent (no path that
   serves under `on` without the guard).

3. **Permissive canary is observable, never a silent downgrade.** In `canary`
   mode does every serial-route emit the `event=continuous_batching_unsupported
   action=serial_routed reason=...` signal (FR-CB8 requires BOTH branches
   observable)? Conversely, is there uncontrolled/duplicate logging — e.g. the
   policy is invoked at preflight AND non-streaming AND streaming, so a single
   request may emit the line multiple times, or every request re-emits it
   (unbounded stderr volume) where the SPEC's AC-7 expects a once-per-attach
   notice. Assess whether per-request repeated logging is a correctness/operability
   defect and at what severity.

4. **No money-path regression.** Confirm the diff touches no billing, receipt,
   settlement, coordinator, router, or auth code, and that the receipt/usage
   tuple is untouched. Confirm the new `APIError` strict-rejection path returns a
   fail-closed error and never a partial/settled result.

5. **MSB helper ships no unmeasured throughput claim.** `msbAggregateThroughput`
   in `DecodeBenchCommand.swift`: confirm it only computes math on caller-supplied
   samples, is not wired into any advertised/persisted capacity or heartbeat
   signal, and that its validation (empty, non-monotonic, negative tokens,
   zero-wall) is sound. Flag any integer/float edge (overflow, div-by-zero,
   negative interval) that is actually reachable.

6. **Input validation of the new knobs.** Queue-limit and mode parsing across
   CLI/env/YAML: any injection, unbounded value, or precedence bug
   (CLI > env > YAML) that lets an invalid/unsafe config through? Confirm the
   `< 1` queue-limit rejection fires on every source.

Report per the severity bar in the shared context. Anchor every finding to a
diff line. State explicitly if a weighting question above is clean.
