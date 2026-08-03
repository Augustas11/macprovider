Audit the architecture and specification conformance of the complete staged SPEC-038 v0.2 diff.

Read CLAUDE.md, specs/SPEC-038-continuous-batching.md, audits/_prompts/BUILD_SPEC_038_V0_2_SCHEDULER_IMPL_PROMPT.md, and git diff --cached origin/main.

Treat the prompt's 2026-08-03 head update as controlling: the first cut batches only fresh conversations; FR-CB4 cross-turn reuse and the sticky portion of AC-19 are deferred to issue 887. Merged code must remain default-off and runtime-inert until packaged capability plus real-hardware evidence are available.

Evaluate:
- Whether the scheduler consumes SPEC-039 descriptor, allocator, binding, and block-table handles without redefining engine storage or inventing a parallel support matrix.
- Whether ownership boundaries make one shared decode forward real, while keeping serial and batched model access mutually safe.
- Admission, decode-first prompt scheduling, dynamic batching, pool-pressure behavior, warm-swap drain, snapshot binding, reconnect idempotence, and failure-domain boundaries.
- Whether config/runtime integration honestly represents the current capability, preserves the serial path, and avoids dead or misleading activation gates.
- Whether tests and operator documentation distinguish merged-inert readiness from later enablement and real-hardware evidence.

Return only actionable findings, ordered by severity, with file and line references. Classify each as CRITICAL, HIGH, MEDIUM, LOW, or INFO. If there are no CRITICAL/HIGH/MEDIUM findings, say exactly: BAR: 0 C/H/M.
