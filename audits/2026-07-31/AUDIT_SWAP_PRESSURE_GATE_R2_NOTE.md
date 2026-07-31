# Round-2 shared context (all lanes)

Round-1 codex audit produced these findings; verify each is RESOLVED in the
current full diff `/Users/augstar/macprovider-poc/scratchpad/swap-pressure-fulldiff.patch`
(source of truth: files under `/Users/augstar/macprovider-swap-pressure-gate/`):

RESOLVED-TO-VERIFY:
1. (MED) Fail-open on <3 samples / no final synchronous sample. FIX: after the
   probe returns, the sampler is cancelled AND awaited (`_ = await samplingTask.value`)
   then a final synchronous sample is appended before snapshot; cadence 250ms.
   `assess` now: swapDetected = criticalCount >= 2 AND criticalCount*2 >= readable.count
   (readable = non-.unknown), so a 2-sample short probe of sustained CRITICAL blocks.
2. (MED) `.unknown` diluting the denominator. FIX: denominator is now `readable.count`.
3. (LOW) probe-safety.log unbounded. FIX: rotates to .1 at ~5 MiB.
4. (LOW) SPEC AC-12 wording on when `swap_observed_under_load` emits. FIX: SPEC now
   says the top-level warning emits only when the disqualification leaves no paid row.

KNOWN / OUT-OF-SCOPE (do NOT re-raise as a blocker on THIS diff — it is a
pre-existing policy gap tracked as a data-driven follow-up, not introduced by
this diff's code): the buyer-TTFT ceiling (`--buyer-ttft-ceiling-ms`) defaults to
0/disabled (shipped in #744), so a slow-but-not-thrashing node can be paid-eligible.
This fix intentionally admits functional low-throughput 8GB nodes (the growth goal)
and cannot calibrate a default TTFT floor until real 8GB throughput telemetry exists
(which this fix produces). Assess only whether THIS diff's code/logic is otherwise sound.

Your job: (a) confirm the four fixes above actually hold in code, (b) find any NEW
correctness/security/architecture defect introduced by the round-1 changes
(e.g. the await-on-cancelled-Task, the >=2-critical rule edge cases, the readable
denominator with all-warning or all-critical, the log rotation race). Report
C/H/M/L/INFO with file:line. If 0 C/H/M, say so explicitly.
