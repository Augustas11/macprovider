Perform a security and abuse-resistance review of the complete staged SPEC-038 v0.2 diff.

Read CLAUDE.md, specs/SPEC-038-continuous-batching.md, and audits/_prompts/BUILD_SPEC_038_V0_2_SCHEDULER_IMPL_PROMPT.md. Review git diff --cached origin/main, not only the latest working-tree slice.

The 2026-08-03 scope update is controlling: fresh conversations only; sticky and cross-turn requests must fail closed or explicit-policy serial-route until issue 887. The feature remains default-off and runtime-inert until promotion.

Real `ModelRuntime`/MLX parity, live MoE behavior, and MSB-01..05 are post-merge enable-gate evidence under BUILD prompt section 7 because the production SPEC-039 bridge is absent. Their absence is not itself a security finding when activation remains impossible and the evidence gap is documented; any bypass, false proof claim, or premature capability is in scope.

Concentrate on:
- Cross-request data, token, sampler, stop-state, block-table, conversation-key, snapshot, usage, and receipt isolation.
- Memory and queue denial of service, integer overflow, unbounded retention, continuation leaks, actor reentrancy, cancellation races, malformed backend responses, and cleanup after partial or whole-batch failures.
- Fail-open activation, capability spoofing, descriptor mismatch, unsupported KV or MoE tuples, speculative-decode mutual exclusion, and accidental silent downgrade.
- Secret or private-data leakage in diagnostics, runbooks, tests, or committed artifacts.
- Any path that could stitch failed batched output into serial output or misattribute settlement-relevant usage.

Return only actionable findings, ordered by severity, with file and line references. Classify each as CRITICAL, HIGH, MEDIUM, LOW, or INFO. If there are no CRITICAL/HIGH/MEDIUM findings, say exactly: BAR: 0 C/H/M.
