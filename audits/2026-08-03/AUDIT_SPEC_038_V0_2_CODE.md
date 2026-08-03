Review the complete staged SPEC-038 v0.2 implementation diff in this worktree.

Authority and scope:
- Read CLAUDE.md, specs/SPEC-038-continuous-batching.md, and audits/_prompts/BUILD_SPEC_038_V0_2_SCHEDULER_IMPL_PROMPT.md.
- Review git diff --cached origin/main, including the inherited scaffold and every staged implementation file.
- The 2026-08-03 head update is controlling: only fresh-conversation batching is in scope; sticky or cross-turn cache reuse must never batch until issue 887 supplies FR-PKV10. Per locked FR-CB8/FR-CB10, canary may reason-code serial-route it, while strict `on` fails closed.
- The feature must remain default-off and runtime-inert until packaged capability and real-hardware promotion gates pass.
- This merge cannot supply real `ModelRuntime`/MLX parity, live MoE router evidence, or MSB-01..05 measurements because the production SPEC-039 runtime bridge is not installed. Under BUILD prompt section 7, treat their absence as an enable-gate gap rather than a merge defect only if the diff keeps every affected tuple impossible to activate, documents the missing evidence, and makes no claim that a local fake is production proof. Flag any bypass, false claim, or premature capability as a defect.

Code-review focus:
- Swift actor isolation, FCFS queueing, decode-first ordering, dynamic insertion/removal, cancellation, drain, idempotence, and exactly-once terminal completion.
- PagedKVBlockAllocator handle lifecycle, reservations, extension failure isolation, release balance, overflow, malformed backend output, and partial multi-row failure paths.
- Per-row token, stop, sampler, snapshot, and usage isolation.
- Configuration precedence, strict versus canary behavior, serial-path preservation, and absence of an upstream-pin success gate.
- Test determinism and whether assertions actually prove the claimed acceptance criteria.

Return only actionable findings, ordered by severity, with file and line references. Classify each as CRITICAL, HIGH, MEDIUM, LOW, or INFO. If there are no CRITICAL/HIGH/MEDIUM findings, say exactly: BAR: 0 C/H/M.
