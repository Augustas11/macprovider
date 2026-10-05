LANE: CODE REVIEW (correctness, regressions, test adequacy).

Focus:
- Qwen35FusedMoE.forward (fork): the per-row guard (x.dim(-2) <= 7) versus flattened-token chunking; shapes for x of rank 2 and 3; reshape back to x.shape; contiguity of `flat[start ..< start+count]` slices passed to custom Metal kernels; that every chunk size 1...7 maps to a valid KernelKey; whether any production call shape (ordinary decode, native verify, CB lockstep windows, prefill, warm-up, self-test probes) now takes a different path than intended; kill switch behaviour.
- Fused kernels vs stock: expert selection, top-k ties, shared-expert gate, bf16 rounding points; batch invariance claims in the tests and whether the tests would catch a chunking bug (e.g. wrong offset, dropped tail chunk).
- Pin consistency: Package.swift, Package.resolved, KVBuildIdentity.mlxSwiftLMRevision, NativeMTPHardwareE2ERunner.upstreamRevision, read_swiftpm_pins.py, check-upstream-throughput-blockers.sh, UPSTREAM_WATCH.json all agree; any check that would pass with a stale or unreviewed revision.
- ModelRuntime.recordNativeMTPTokenBoundDowngrade and the lab-only hooks: production behaviour change beyond recording; double counting; compile-time gating of lab code (DEBUG || MACPROVIDER_LAB_HARNESS).
- ContinuousBatchScheduler lab batch-composition fence: can it ever engage in a release build, deadlock, or leak a held batch.
- Analyzers (r015, post-gateway replay, admission sidecar): vacuous passes, fail-open paths, Swift/Python disagreement.
