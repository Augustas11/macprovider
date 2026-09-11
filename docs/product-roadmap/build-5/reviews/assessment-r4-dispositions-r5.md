# Product Build 5 assessment R4 finding dispositions

Date: 2026-09-11

Source review: `assessment-r4-sol.md`

Source review SHA-256:
`21399619f980cb5964d6fd2e98472b32fe9f9f6a815d2277985083b8540bef8e`

Correction revision: assessment/evidence/benchmark/checkpoint R5

This record does not approve R5. A fresh independent GPT-5.6 Sol reviewer must
recompute the committed R5 digests, inspect the governing code and specs, and
report zero Critical, High, and Medium findings before the assessment gate
passes.

| Finding | R5 correction | Disposition |
|---|---|---|
| H1 circular pre-calibration safety | Added an independent signed `precalibration-budget-v1`. Before loaded-idle measurement, immutable weight metadata and dtype expansion feed a separate pre-load ledger; unknown conversion/allocation forbids model load. The target bound then uses safely measured loaded idle, analytical full-pool KV, bounded queues, a generated maximum-live ledger for every non-KV allocation site, a fixed `max(4 GiB, 25%)` runtime reserve, and a separate 25% bootstrap allowance; it never consumes the future calibrated peak. An opaque/unbounded allocation forbids the run. Three 25/50/75% fresh-worker ramps precede exact shape. A separate child, proven `RLIMIT_AS` coverage for MLX/Metal allocations, a 10 ms supervisor watchdog, pressure events, SIGKILL, and observed exit form the hard-stop boundary; inability to prove the cap forbids target-shaped calibration. | Corrected without changing the five exact-shape maxima, final 10% allowance, 85% hard limit, pressure/swap/thermal gates, or recovery limits. |
| H2 backlog arithmetic and fence ownership | Chose one mode-epoch algorithm and one process topology. The common pre-admission queue is `2 * slots_total`; snapshot acceptance happens only with a funded lease, so no accepted backlog can add serial 900-second intervals. Opposite-mode selection closes the epoch, rejects later same-mode work before acceptance, resolves migrated accepted-queued entries under the old snapshot within 250 ms, and drains at most Entry 110 already granted requests under their original enqueue-to-terminal deadline. The waiter is granted within one second after quiescence only while its deadline remains, or receives `mode_wait_timeout` by 900 seconds; old accepted work is fenced and reconciled by 915 seconds. The controller owns admission/durable dispositions; a separate inference worker owns MLX/Metal/scheduler state; and a launchd-owned lifecycle supervisor owns the worker PID/process group. Replacement requires SIGKILL if needed, supervisor-observed `waitpid` exit, and durable terminal outcomes, including controller-loss reconciliation. | Corrected; a callback alone cannot fence execution or authorize reuse/publication. The selected FR-CB13 acceptance policy, supervisor topology, and worker IPC must become normative before implementation. |
| M1 incomplete loader closure and cooperative lock | The manifest now enumerates every regular file under `/model`, `/runtime`, and `/campaign`. Static closure scans every runtime Mach-O and runtime closure captures actual dyld/plugin/metallib images at each load boundary; every non-platform image must resolve inside the image. A privilege-separated broker has sole write custody, closes every write descriptor, attaches once read-only, unlinks the backing path, and proves no writable descriptor or attachment exists before launching an unprivileged network-denied worker. Pre/post manifest, attachment, mount, and loaded-image recapture remains mandatory. | Corrected within an explicit unprivileged-local-writer threat model; kernel/root/physical compromise remains outside the qualification claim. |
| M2 nondeterministic disturbance injection | Slow-consumer cells now freeze and verify the socket receive buffer, 500 ms first-read offset, exact 256-byte reads every 100 ms, 16-frame server queue, occupancy transition, and producer suspension on frame 17. Cancellation fixes 256-token prefill chunks, exact token 512 before chunk three, exact generated-token indices, and delivery cancellation after occupancy 16 plus blocked frame 17. The harness records each boundary before injection and fails if it is skipped or never reached. | Corrected; a cell ID now selects one reproducible lifecycle path. |
| M3 correlated latency inference | Promotion requires at least ten clean-start clusters. The independent decision unit is the clean start and a batch repetition is indivisible. Exactly 50,000 hierarchical resamples select starts, then complete repetitions, preserving every row and paired arm together. Reports include start/repetition/request counts and batch sizes. Request-level bootstrap output is descriptive and cannot support go/no-go. | Corrected without reducing repetition, request, p95/p99, CV, or CI-width thresholds. |

No runtime, scheduler, configuration, conformance, release, hardware,
procurement, remote-transfer, or production-enablement change is part of R5.
