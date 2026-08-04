# SPEC-038 scaffold BUILD audit — ARCHITECT lane

First read the shared context file in this same directory:
`AUDIT_SPEC_038_SCAFFOLD_COMMON.md`. It defines the worktree, the diff range to
audit, what the scaffold intentionally is, and what NOT to flag.

You are the architect lane. Weight your review toward SPEC-038 conformance and
the durability of the engine-agnostic seam, each anchored to a diff line and,
where relevant, a `SPEC-038-R0xx` / `FR-CB*` requirement:

1. **SPEC conformance of what IS built.** The scaffold only claims to satisfy a
   subset of requirements: FR-CB9 (flag-off serial identity), FR-CB8 (explicit
   reason-coded rejection / permissive serial route, never silent downgrade),
   FR-CB10 (version-pin discipline: unreviewed API must not float into serve
   path — here enforced by `reviewedUpstreamBatchRevision == nil` + strict
   fail), FR-CB12 (SPEC-028 draft mutual exclusion), FR-CB14 (aggregate-TG as
   total tokens over common wall-clock). Verify the code actually upholds each of
   these it claims, and that it does NOT overclaim any requirement it does not
   implement (e.g. it must not report itself as doing a shared forward /
   continuous batching in telemetry — FR-CB3/FR-CB14).

2. **No contradiction with the merged normative SPEC.** Cross-check the outcome
   mode-matrix (SPEC §5) and the reason codes against the SPEC's named errors.
   The scaffold reuses `draft_model_capacity_shortfall` for the draft-exclusion
   reason and status 503 vs 400 split (unpinned = 503, kv_bits/draft = 400).
   Is that consistent with SPEC-038 FR-CB8/FR-CB12 and existing SPEC-028
   behavior? Flag any place the scaffold's behavior would contradict the SPEC a
   future engine PR must honor.

3. **Engine-agnostic seam quality.** Is the seam (`ContinuousBatchingPolicy`,
   `ContinuousBatchingCapability`, the `ModelRuntime` hooks) shaped so the real
   Approach-A upstream engine — or the Approach-B fallback — can be dropped in
   WITHOUT reworking config/CLI/telemetry or breaking flag-off parity? Call out
   seam decisions that will force churn or a breaking change when the engine
   lands (e.g. capability struct missing a field the engine needs, policy
   evaluated at the wrong lifecycle point, `shouldUseSerialPath` semantics that
   won't extend to a real supported-batch case).

4. **Capacity mapping direction (FR-CB11).** `maxActiveRows` is derived from
   `maxBatch` / Entry 110 `max_concurrency_override`. Confirm the scaffold does
   not synthesize capacity above Entry 110 and does not alter `slots_total` /
   `slots_free`. (The engine will own the live mapping; here only confirm the
   scaffold doesn't move it.)

5. **Independence & isolation (FR-CB7, FR-CB16).** The policy lives on the
   `ModelRuntime` actor. Confirm no new shared mutable state escapes the actor,
   and nothing here touches SPEC-037 KV persistence layout.

6. **Test adequacy for the seam.** Do the tests cover the requirement subset the
   scaffold claims (defaults, precedence, strict rejection reason precedence,
   permissive route, draft exclusion, queue-limit default/validation, runtime
   threading, MSB math)? Name any claimed-behavior gap with no test.

Report per the severity bar in the shared context. Anchor every finding to a
diff line and, where applicable, a requirement ID. State explicitly if a
weighting question above is clean.
