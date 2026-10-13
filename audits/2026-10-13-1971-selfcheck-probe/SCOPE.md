# Freeze diff: FR-CB10 self-check exactness probe (#1971)

Audit the COMPLETE diff as it will land. Read it yourself (run the command; do
not rely on summaries). The cwd is this repository on branch
`fix/1971-selfcheck-probe`:

    git diff origin/main...HEAD -- . ':(exclude)audits'

Context (read as needed): issue #1971 (`gh issue view 1971 --comments`),
`docs/research/cb-decode-isolation/README.md` sections 1, 6 and 7 (Studio
evidence: 16 rows in one forward flip 30-38 greedy tokens without the FR-CB2
decode row bound; main's self-check granted 16 and accepted two near-ties at a
0.125 logit gap; with the bound every row is bitwise equal to its lone run),
`specs/SPEC-038-continuous-batching.md` FR-CB2 and FR-CB10 (the diff adds
v0.3.19), and the #1974 code it builds on: `ContinuousBatchDecodeRouteBound`
(`ContinuousBatchScheduler.swift`), `PagedKVVectorAttentionRoute`
(`PagedKVRuntimeBridge.swift`).

What the change is:

1. Scheduler (`ContinuousBatchScheduler.swift`): a self-check probe request may
   carry `selfCheckCohort` (rows submitted together). A cohort row is not
   admitted until that many cohort rows are present in the scheduler
   (`headMayTakeRow`); a cohort that never fills waits out the bounded queue
   wait. While every decoding row belongs to a cohort and another cohort row is
   waiting, admitting or prefilling, decode is held, but only while admission
   or prefill progressed on the previous pass (`pumpUntilIdle`). Per row, the
   scheduler counts decode tokens generated while at least `selfCheckCohort`
   rows, all probe rows, were decoding (`noteSelfCheckCohortDecodeStep`) and
   returns it as `ContinuousBatchSchedulerResult.selfCheckCohortDecodeTokens`.
2. Self-check (`ContinuousBatchingSelfCheck.swift`): each width k runs an
   exactness probe before its throughput passes: k prompts cut to exact token
   lengths (`exactnessPromptLength`, `fitPrompt`) on both sides of the device's
   vector-attention route boundary (`routeKeyBoundary`, 1024 on d/s GPUs, 4096
   otherwise), one crossing it mid-completion; run alone and as one cohort;
   compared row by row; a first difference is excused only within
   `nearTieLogitTolerance` (1/1024) instead of 1.0 (`divergenceVerdict`, moved
   from `ModelRuntime`). The ladder bound includes the widest probe shape the
   pool and per-request cap hold (`exactnessProbeBound`,
   `ladderUpperBound(target:...)`; `probe_shape_unavailable` below two rows). A
   conformant probe whose rows did not all reach
   `requiredCohortDecodeTokens` (max(16, decode window)) at full width ends the
   ladder on the verified prefix (`StepError.probeShapeUnmet`,
   `decide(probeShapeUnmetAt:)`, re-measure after 1 h). Throughput passes run
   only after a conformant probe.
3. Runtime (`ModelRuntime.swift`): the target carries the route boundary,
   per-request cap and pool size; the batch runner passes the cohort and
   returns per-row cohort decode tokens; the self-check key's runtime build
   gains `+cb-probe-v2`, so stored results re-run once while a stored grant
   keeps serving (`priorGrant`).
4. Tests in `ContinuousBatchSchedulerTests.swift` (kernel-route backend) and
   `ContinuousBatchingSelfCheckTests.swift`; SPEC-038 v0.3.19 FR-CB10 text,
   CONFORMANCE and index.

Constraints: no Swift build or test can run here (CI is the compile gate), so
evaluate by reading source; where you believe something does not compile, say
so with file:line. The FR-CB2 row bound remains the structural guard; this
check is defence in depth.

Output: findings as `SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line —
problem — concrete fix`, then a final line `VERDICT: <n> CRITICAL, <n> HIGH,
<n> MEDIUM, <n> LOW`.
